//! command_encoder_test.zig — RenderCommandEncoder 的单元测试
//!
//! 从 command_encoder.zig 析出（2026-07-31）。测试占了原文件 679 行，
//! 与被测代码放同一文件除了撑大文件没有别的作用；Zig 的 test 块在
//! 独立文件里同样被 `zig build test-render` 收集（见 build.zig 的
//! render_tests 模块）。
//!
//! ⚠ 这里测的是 encoder 的**内部**行为，所以引用了若干非 pub 符号需要的
//! 限定路径。若某个被测函数改名/降级为私有，编译期就会报错 —— 这是有意的：
//! 测试与实现同步失效，好过静默失去覆盖。

const std = @import("std");
const ce = @import("command_encoder.zig");
const RenderCommandEncoder = ce.RenderCommandEncoder;
const PersistentGpuCache = ce.PersistentGpuCache;
const lsort = @import("command_encoder/local_sort.zig");
const paint_fp = @import("command_encoder/paint_fingerprint.zig");
const ClipShapeKind = ce.ClipShapeKind;
const OffscreenLayer = ce.OffscreenLayer;
const backdrop_blur = @import("backdrop_blur.zig");
const GlassUniforms = backdrop_blur.GlassUniforms;
const text_module = @import("text");
const Font = text_module.Font;
const icon_ir = @import("icon_ir");
const FontSelector = ce.FontSelector;

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

    // 纹理分配尺寸落 64px 桶（性能：几何动画期同桶帧共享池纹理）。
    // 逻辑 capture 160x120 → alloc 192x128；copy/dst 语义不变。
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

    // 60x40 → 64px 桶 → 64x64。
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

test "activeRoundedClip skips pure rect ancestors" {
    var encoder: RenderCommandEncoder = undefined;
    encoder.clip_depth = 3;
    encoder.logical_clip_stack[0] = .{ .x = 0, .y = 0, .w = 200, .h = 120, .radius = 0, .shape_kind = .rect };
    encoder.logical_clip_stack[1] = .{ .x = 8, .y = 8, .w = 160, .h = 90, .radius = 12, .shape_kind = .rounded_rect };
    encoder.logical_clip_stack[2] = .{ .x = 12, .y = 12, .w = 120, .h = 60, .radius = 0, .shape_kind = .rect };

    try std.testing.expect(encoder.activeRoundedClip() != null);
    const clip = encoder.activeRoundedClip().?;
    try std.testing.expectEqual(ClipShapeKind.rounded_rect, clip.shape_kind);
    try std.testing.expectApproxEqAbs(@as(f32, 12), clip.radius, 0.001);
}

test "restoreSavedClipState preserves parent clip stack after offscreen mutation" {
    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    encoder.clip_depth = 2;
    encoder.logical_clip_stack[0] = .{ .x = 10, .y = 20, .w = 300, .h = 200, .radius = 0, .shape_kind = .rect };
    encoder.logical_clip_stack[1] = .{ .x = 30, .y = 40, .w = 120, .h = 80, .radius = 12, .shape_kind = .rounded_rect };
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
    encoder.logical_clip_stack[0] = .{ .x = 0, .y = 0, .w = 40, .h = 20, .radius = 0, .shape_kind = .rect };
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
    // 回归：pushClip 在 depth>=64 时静默忽略，popClip 却无条件弹栈 ——
    // 溢出段的每个 pop 都会弹掉一层**父级真实 clip**，之后的内容裁剪错位。
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
        try encoder.pushClip(@floatFromInt(i), 0, 500, 500, 0, .rect, empty_poly);
    }
    try std.testing.expectEqual(@as(usize, 64), encoder.clip_depth);
    try std.testing.expectEqual(@as(u32, 2), encoder.clip_overflow_depth);
    // 弹两次：只抵消两个被忽略的 push，真实栈不动
    try encoder.popClip();
    try encoder.popClip();
    try std.testing.expectEqual(@as(usize, 64), encoder.clip_depth);
    try std.testing.expectEqual(@as(u32, 0), encoder.clip_overflow_depth);
    // 第三次才弹真实的第 64 层
    try encoder.popClip();
    try std.testing.expectEqual(@as(usize, 63), encoder.clip_depth);
    try std.testing.expectApproxEqAbs(@as(f32, 62), encoder.logical_clip_stack[encoder.clip_depth - 1].x, 0.001);
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
    // 与 storybook 实测一致：层 geom 从 (-10,-10) 起（阴影余量），合成矩阵
    // scale 0.8、纹理原点落在世界 (382,321)。玻璃在层内 (0,0,300,90)。
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

    // 嵌套：外层平移-only 离屏（非矩阵，draw 矩形放大 2 倍），内层矩阵平移。
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
    // 内层矩阵输出「外层帧未本地化」坐标：外层内 (110,60) = 外层纹理局部 (10,10)。
    encoder.offscreen_stack[1].draw_transform = .{ 1, 0, 0, 1, 110, 60 };
    const n = backdrop_blur.offscreenLocalRectToWorld(&encoder, 0, 0, 20, 10);
    try std.testing.expect(n[2] > 39.9 and n[2] < 40.1); // 外层 2 倍放大：宽 20 → 40
    try std.testing.expect(n[3] > 19.9 and n[3] < 20.1);
}

test "layerMagnification: only magnifying composites raise the raster scale (capped at 4)" {
    const ol = @import("opacity_layer.zig");
    // 矩阵缩放 2：按 2 倍光栅化（放大合成不再拉伸 1× 位图）。
    try std.testing.expectApproxEqAbs(@as(f32, 2), ol.layerMagnification(true, .{ 2, 0, 0, 2, 10, 10 }, 100, 50, 0, 0), 1e-5);
    // 缩小不降分辨率。
    try std.testing.expectApproxEqAbs(@as(f32, 1), ol.layerMagnification(true, .{ 0.5, 0, 0, 0.5, 0, 0 }, 100, 50, 0, 0), 1e-5);
    // 旋转 + 缩放：取列向量长度。
    const c: f32 = 1.5 * @cos(@as(f32, 0.3));
    const sn: f32 = 1.5 * @sin(@as(f32, 0.3));
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), ol.layerMagnification(true, .{ c, sn, -sn, c, 0, 0 }, 100, 50, 0, 0), 1e-4);
    // 非矩阵层按 draw 尺寸 / 源尺寸；上限 4。
    try std.testing.expectApproxEqAbs(@as(f32, 3), ol.layerMagnification(false, .{ 1, 0, 0, 1, 0, 0 }, 100, 50, 300, 50), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4), ol.layerMagnification(true, .{ 9, 0, 0, 9, 0, 0 }, 100, 50, 0, 0), 1e-5);
}

test "local sort text bounds stay conservative for mixed width scripts" {
    const latin = lsort.localSortTextBounds(0, 20, "Hello", 16);
    const cjk = lsort.localSortTextBounds(0, 20, "你好世界", 16);
    const mixed = lsort.localSortTextBounds(0, 20, "Hello世界", 16);

    try std.testing.expect(latin[2] >= 16);
    try std.testing.expect(cjk[2] > latin[2] * 0.6);
    try std.testing.expect(mixed[2] >= latin[2]);
    // 基线以上 1.5em + 以下 0.5em（下伸部）
    try std.testing.expectApproxEqAbs(@as(f32, 20 - 24), latin[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 32), latin[3], 0.001);
    try std.testing.expect(latin[1] + latin[3] >= 20 + 16 * 0.25);
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
    // 回归：耗尽后曾钳到 511 继续复用——draw 已 encode 未提交，后写覆盖
    // 前一 pass 的 uniform（静默坏帧）。正确语义是 null → 调用方终止模糊链。
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

    // 帧边界 reset 后恢复可分配
    backdrop_blur.resetDynamicUniformOffsets(&encoder);
    try std.testing.expectEqual(@as(?u32, 0), backdrop_blur.acquireKawaseUniformSlot(&encoder));
}

test "blur chain params: continuous, monotonic, DPI-invariant" {
    // 等效物理足迹 offset_scale·3·2^levels 必须恒等于 r_phys（连续 + 单调
    // 由此直接成立），且逻辑半径相同在 1x/2x/3x 下等效逻辑糊度一致
    const scales = [_]f32{ 1.0, 2.0, 3.0 };
    var r: f32 = 0.5;
    while (r <= 96.0) : (r += 0.5) {
        for (scales) |s| {
            const c = backdrop_blur.blurChainParams(r, s);
            try std.testing.expect(c.levels >= 1 and c.levels <= 6);
            const effective_logical = c.offset_scale * 3.0 * std.math.pow(f32, 2.0, @floatFromInt(c.levels)) / s;
            // 6 级封顶后饱和（3x 屏大半径），饱和前必须严格等于 r
            const cap_logical = 3.0 * 64.0 / s;
            if (r <= cap_logical) {
                try std.testing.expectApproxEqRel(r, effective_logical, 1e-5);
            } else {
                try std.testing.expect(c.levels == 6);
            }
        }
    }
    // 量程外 clamp：> 96 与 96 等参
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
    try std.testing.expectEqual(@as(usize, 208), @sizeOf(GlassUniforms));
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
        .size = 12,
        .size_px = 12,
        .weight = 400,
    };
    var font14 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .size = 14,
        .size_px = 14,
        .weight = 400,
    };
    var font16 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
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

test "HiDPI: FontSelector.setScaleFactor 传播到基准字体与扩展槽位" {
    // scale 变化时若只更新 small/medium/large，扩展槽位（bold/mono/cjk/…）
    // 会永远停在旧 scale —— 表现为"部分字号变清晰了、另一些依旧糊"。
    var font12 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .size = 12,
        .size_px = 12,
        .weight = 400,
    };
    var font14 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .size = 14,
        .size_px = 14,
        .weight = 400,
    };
    var font16 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .size = 16,
        .size_px = 16,
        .weight = 400,
    };
    var bold20 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .size = 20,
        .size_px = 20,
        .weight = 700,
    };
    var mono13 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .size = 13,
        .size_px = 13,
        .weight = 400,
    };
    var symbols = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
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

    // 前提：初始都是默认 1.0。
    try std.testing.expectEqual(@as(f32, 1.0), font12.scale_factor);
    try std.testing.expectEqual(@as(f32, 1.0), bold20.scale_factor);

    selector.setScaleFactor(2.0);

    try std.testing.expectEqual(@as(f32, 2.0), font12.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), font14.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), font16.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), bold20.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), mono13.scale_factor);
    try std.testing.expectEqual(@as(f32, 2.0), symbols.scale_factor);

    // 回到 1x 也必须传播（拖回非 Retina 屏）。
    selector.setScaleFactor(1.0);
    try std.testing.expectEqual(@as(f32, 1.0), bold20.scale_factor);
    try std.testing.expectEqual(@as(f32, 1.0), mono13.scale_factor);
}

test "HiDPI: FontSelector.setScaleFactor 传播到 lazy derived font" {
    // 最容易漏的一条：Font.derive 只在**创建那一刻**拷贝 scale_factor，
    // 而派生字体常驻 derived_cache 被复用。若 setScaleFactor 不遍历这个
    // cache，非标准字号的文本会永远按旧 scale 光栅化。
    // 需要真实 CoreText 字体（derive 会调用 CoreText）。
    var fs = try text_module.FontSystem.init(std.testing.allocator);
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

    // 触发一次 lazy derive：选一个不等于任何预载档位的字号。
    const derived = selector.select(23.5);
    // 确认真的走了 derive（拿到的不是三个基准字体之一）。
    try std.testing.expect(derived != base and derived != med and derived != big);
    try std.testing.expect(selector.derived_cache.count() >= 1);
    try std.testing.expectEqual(@as(f32, 1.0), derived.scale_factor);

    selector.setScaleFactor(2.0);

    // 派生字体必须跟着变 —— 这正是本测试的靶心。
    try std.testing.expectEqual(@as(f32, 2.0), derived.scale_factor);
    // 且不能把 cache 清空（键与 scale 无关，就地更新即可）。
    try std.testing.expect(selector.derived_cache.count() >= 1);
    // 同字号再 select 必须还命中同一个对象。
    try std.testing.expectEqual(derived, selector.select(23.5));
}

test "FontSelector derived cache init is idempotent" {
    var font12 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .size = 12,
        .size_px = 12,
        .weight = 400,
    };
    var font14 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
        .size = 14,
        .size_px = 14,
        .weight = 400,
    };
    var font16 = Font{
        .allocator = std.testing.allocator,
        .ct_font = undefined,
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
    // 回归守卫：字体族缺某个字重时 loader 返回 null，此前没有负缓存 ——
    // 每次选字体（每帧、每次测量）都重走 CoreText 查找，native 侧还每次 NSLog。
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
    var font12 = Font{ .allocator = std.testing.allocator, .ct_font = undefined, .size = 12, .size_px = 12, .weight = 400 };
    var font14 = Font{ .allocator = std.testing.allocator, .ct_font = undefined, .size = 14, .size_px = 14, .weight = 400 };
    var font16 = Font{ .allocator = std.testing.allocator, .ct_font = undefined, .size = 16, .size_px = 16, .weight = 400 };
    var counter = Counter{};
    var selector = FontSelector{ .small = &font12, .medium = &font14, .large = &font16 };
    selector.weight_loader = .{ .context = @ptrCast(&counter), .load = Counter.load };
    selector.initDerivedCache(std.testing.allocator);
    defer selector.deinitDerivedCache();

    // 14px 是预载档位：未命中后退回 medium，不触发派生（不碰 CoreText）。
    try std.testing.expectEqual(&font14, selector.selectWeighted(14, 700));
    try std.testing.expectEqual(@as(u32, 1), counter.calls);
    try std.testing.expectEqual(&font14, selector.selectWeighted(14, 700));
    try std.testing.expectEqual(&font14, selector.selectWeighted(14, 690)); // 量化后同为 700
    try std.testing.expectEqual(@as(u32, 1), counter.calls);

    // 不同键仍各查一次。
    _ = selector.selectWeighted(14, 500);
    try std.testing.expectEqual(@as(u32, 2), counter.calls);

    // 换 loader（换字体族）必须失效负缓存。
    var counter2 = Counter{};
    selector.weight_loader = .{ .context = @ptrCast(&counter2), .load = Counter.load };
    _ = selector.selectWeighted(14, 700);
    try std.testing.expectEqual(@as(u32, 1), counter2.calls);

    // 与正缓存一起失效：deinit + 重新 init 后重新查。
    selector.deinitDerivedCache();
    selector.initDerivedCache(std.testing.allocator);
    _ = selector.selectWeighted(14, 700);
    try std.testing.expectEqual(@as(u32, 2), counter2.calls);

    // 有界：3 个预载字号 × 8 个非常规字重 = 24 个不同键，超过负缓存容量，
    // 不越界；最新写入的键仍被记住。（只用预载字号：派生会碰 CoreText。）
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

test "retained_begin_seq stays aligned when no-op structural blocks are skipped" {
    // 回归守卫（2026-07-30 审查发现的 P0）：encodeCommands 会把"空结构块"
    // （begin..end 之间无任何绘制命令）整块跳过、不经过 dispatchCommand。
    // 修复前，被跳过的 begin_opacity_layer 不推进 retained_begin_seq，而指纹
    // 预扫描已经给它编了号 —— 后续所有层拿到前移一位的错误指纹，内容变了却
    // 判命中，画面停在陈旧内容。
    //
    // 用 duck-typed mock 命令列表驱动（encoder 全程 anytype，render 模块不
    // import ui 侧的 paint_table）。两个空 opacity block 都会被折叠跳过；
    // 断言跳过后 seq 仍与预扫描的编号总数一致。
    const MockColor = extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 0 };
    const MockGlass = struct {
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
        specular_angle: f32 = 0,
        magnification: f32 = 0,
        scale_ratio: f32 = 1,
        edge_field_strength: f32 = 0,
        center_zoom_radius: f32 = 0,
        center_zoom_falloff: f32 = 0,
        backdrop_distance: f32 = 0,
        blur_gradient_direction: u8 = 0,
        blur_gradient_strength: f32 = 0,
        blur_gradient_stop_pos: [4]f32 = .{ 0, 1, 1, 1 },
        blur_gradient_stop_str: [4]f32 = .{ 1, 0, 0, 0 },
        blur_gradient_stop_count: u8 = 2,
    };
    const MockSpan = struct {
        start: u32 = 0,
        end: u32 = 0,
        color: ?MockColor = null,
        font_weight: ?u16 = null,
        use_italic_font: bool = false,
        use_monospace_font: bool = false,
        strikethrough: bool = false,
        bg_color: ?MockColor = null,
    };
    const MockPt = struct { x: f32 = 0, y: f32 = 0 };
    const MockPathCmd = union(enum) {
        move_to: MockPt,
        line_to: MockPt,
        quad_to: struct { ctrl: MockPt = .{}, end: MockPt = .{} },
        cubic_to: struct { ctrl1: MockPt = .{}, ctrl2: MockPt = .{}, end: MockPt = .{} },
        close: void,
    };
    const MockPathGeom = struct {
        fill_rule: enum(u8) { nonzero, evenodd } = .nonzero,
        commands: []const MockPathCmd = &.{},
    };
    const Kind = enum { none, rect, text, image, shadow, gradient, path, control };
    const CtrlKind = enum {
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
    const Geom = struct { x: f32 = 0, y: f32 = 0, w: f32 = 100, h: f32 = 100 };
    const Radii = struct {
        tl: f32 = 0,
        tr: f32 = 0,
        br: f32 = 0,
        bl: f32 = 0,
        pub fn toArray(self: @This()) [4]f32 {
            return .{ self.tl, self.tr, self.br, self.bl };
        }
    };
    const MockItem = struct {
        kind: Kind = .control,
        control_kind: CtrlKind = .none,
        geom: Geom = .{},
        color: MockColor = .{},
        radii: Radii = .{},
        opacity: f32 = 1.0,
        rotate: f32 = 0,
        blend_mode: u8 = 0,
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
        mg_stop_colors: [16]MockColor = [_]MockColor{.{}} ** 16,
        mg_stop_positions: [16]f32 = [_]f32{0} ** 16,
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
        icon_corner_clip_radius: f32 = 0,
        clip_polygon_ptr: ?*const MockClipPolygon = null,
        glass_ptr: ?*const MockGlass = null,
        icon_rep_ptr: ?*const icon_ir.Rep = null,
        path_geometry_ptr: ?*const MockPathGeom = null,
        surface_stable_id: u32 = 42,
        surface_content_version: u32 = 1,
    };

    const begin = MockItem{ .control_kind = .begin_opacity_layer, .opacity = 0.5 };
    const end = MockItem{ .control_kind = .end_opacity_layer };
    // 两个空 opacity block —— tryFindNoOpStructuralBlock 会把它们整块折叠。
    const commands = [_]MockItem{ begin, end, begin, end };

    var encoder = RenderCommandEncoder{
        .sdf_renderer = undefined,
        .text_renderer = undefined,
        .offscreen_pool = undefined,
        .persistent = undefined,
    };
    // render_pass == null：即使某个 begin 走到 dispatch，tryBeginRetained /
    // beginOpacityLayer 都会安全 early-return，不触碰 GPU。
    try encoder.encodeCommands(commands[0..]);

    // 预扫描给两个 begin 各编了一个号；跳过路径必须把 seq 推到同样的位置。
    try std.testing.expectEqual(@as(usize, 2), encoder.retained_hash_count);
    try std.testing.expectEqual(@as(usize, 2), encoder.retained_begin_seq);
}

/// 与 command_encoder.ClipPolygon 同形（指纹按内容 hash 需要这些字段）。
const MockClipPolygon = struct {
    point_count: u8 = 0,
    contour_count: u8 = 0,
    fill_rule: enum(u8) { nonzero, evenodd } = .evenodd,
    contour_end_points: [4]u8 = .{ 0, 0, 0, 0 },
    points: [16][2]f32 = [_][2]f32{.{ 0, 0 }} ** 16,
};

/// damage-rect / 指纹测试共用的 duck-typed paint 命令 mock（encoder 全程
/// anytype，render 模块不 import ui 侧的 paint_table）。
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
        mg_stop_colors: [16]u32 = [_]u32{0} ** 16,
        mg_stop_positions: [16]f32 = [_]f32{0} ** 16,
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

    // 平坦层：两条 rect → 捕获 2 条 item，safe
    const flat = [_]MockItem{ begin, rect_a, rect_b, end };
    encoder.computeRetainedContentHashes(flat[0..]);
    try std.testing.expect(encoder.damage_ranges[0].captured);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expect(!encoder.damage_ranges[0].overflow);
    try std.testing.expectEqual(@as(u32, 2), encoder.damage_ranges[0].len);
    // bounds 含 2px pad
    const b0 = encoder.damage_scratch[0].bounds;
    try std.testing.expectEqual(@as(f32, 8), b0[0]);
    try std.testing.expectEqual(@as(f32, 54), b0[2]);
    // 同内容重扫 → digest 稳定；改颜色 → digest 变
    const d0 = encoder.damage_scratch[0].digest;
    encoder.computeRetainedContentHashes(flat[0..]);
    try std.testing.expectEqual(d0, encoder.damage_scratch[0].digest);
    var rect_a2 = rect_a;
    rect_a2.color = 0x123456FF;
    const flat2 = [_]MockItem{ begin, rect_a2, rect_b, end };
    encoder.computeRetainedContentHashes(flat2[0..]);
    try std.testing.expect(encoder.damage_scratch[0].digest != d0);
    try std.testing.expectEqual(encoder.damage_scratch[1].digest, encoder.damage_scratch[1].digest);

    // 平移-only 嵌套 opacity 子层 → 递归逐条捕获（2026-07-30 非平坦层扩展）：
    // rect_a + begin + rect_b + end = 4 items，外层保持 safe
    const nested = [_]MockItem{ begin, rect_a, begin, rect_b, end, end };
    encoder.computeRetainedContentHashes(nested[0..]);
    try std.testing.expect(encoder.damage_ranges[0].captured);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expectEqual(@as(u32, 4), encoder.damage_ranges[0].len);
    // 子树内某条内容变化 → 只有对应 item 的 digest 变（细粒度脏区的前提）
    const inner_digest = encoder.damage_scratch[2].digest;
    const outer_digest = encoder.damage_scratch[1].digest;
    var rect_b2 = rect_b;
    rect_b2.color = 0x123456FF;
    const nested2 = [_]MockItem{ begin, rect_a, begin, rect_b2, end, end };
    encoder.computeRetainedContentHashes(nested2[0..]);
    try std.testing.expect(encoder.damage_scratch[2].digest != inner_digest);
    try std.testing.expect(encoder.damage_scratch[1].digest == outer_digest);
    // 含背景模糊（玻璃）的层：指纹恒为 0 = 永不复用缓存纹理。玻璃像素取决于
    // 层身后的画面，内容指纹看不见身后；复用会烘进旧背景（实测：合成组里的玻璃
    // 条纹被拉伸 + 叠着上一帧自己的残影）。外层也一起失效（像素烤在父纹理里）。
    const glass_begin = MockItem{ .control_kind = .begin_blur_layer };
    const glass_end = MockItem{ .control_kind = .end_blur_layer };
    const glassy = [_]MockItem{ begin, rect_a, begin, glass_begin, rect_b, glass_end, end, end };
    encoder.computeRetainedContentHashes(glassy[0..]);
    try std.testing.expectEqual(@as(u64, 0), encoder.retained_hashes[0]);
    try std.testing.expectEqual(@as(u64, 0), encoder.retained_hashes[1]);
    encoder.computeRetainedContentHashes(flat[0..]);
    try std.testing.expect(encoder.retained_hashes[0] != 0);

    // plain 嵌套（无 dt）：draw==geom → 内容坐标与父同系，偏移 0
    var begin_off = begin;
    begin_off.geom = .{ .x = 30, .y = 40, .w = 100, .h = 100 };
    const nested_off = [_]MockItem{ begin, rect_a, begin_off, rect_b, end, end };
    encoder.computeRetainedContentHashes(nested_off[0..]);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    // rect_b (10,40) - pad 2 = (8,38)（嵌套偏移 = 0）
    try std.testing.expectApproxEqAbs(@as(f32, 8), encoder.damage_scratch[2].bounds[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 38), encoder.damage_scratch[2].bounds[1], 0.001);

    // 平移-only draw_transform 的嵌套（promoted surface 常态）→ 也递归：
    // 内容坐标 = 嵌套-local + (tx - geom.x)
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

    // 带缩放的轴对齐 transform 嵌套 → 整棵折叠成单个 item：rect_a + fold = 2；
    // fold bounds 只由 transform 矩形决定（t4,t5,a·w,d·h）
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

    // 旋转的嵌套子层：合成范围无法界定 → unsafe
    var begin_rot = begin;
    begin_rot.rotate = 0.5;
    const nested_rot = [_]MockItem{ begin, rect_a, begin_rot, rect_b, end, end };
    encoder.computeRetainedContentHashes(nested_rot[0..]);
    try std.testing.expect(!encoder.damage_ranges[0].safe);

    // path 命令 → 捕获为 item，bounds 从点集算（+pad）
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

    // push/pop_clip（矩形）→ 捕获为 item；pop 的 bounds = 配对 push 的矩形
    const clip_push = MockItem{ .control_kind = .push_clip, .geom = .{ .x = 20, .y = 20, .w = 40, .h = 30 } };
    const clip_pop = MockItem{ .control_kind = .pop_clip };
    const with_clip = [_]MockItem{ begin, clip_push, rect_a, clip_pop, end };
    encoder.computeRetainedContentHashes(with_clip[0..]);
    try std.testing.expect(encoder.damage_ranges[0].safe);
    try std.testing.expectEqual(@as(u32, 3), encoder.damage_ranges[0].len);
    try std.testing.expectEqual(encoder.damage_scratch[0].bounds, encoder.damage_scratch[2].bounds);

    // polygon clip / 不配对 pop / blur 子树 → unsafe
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
    // 回归：arc 复用 .path kind 但无 path_geometry_ptr，pathItemBounds 曾返回
    // {cx,cy,0,0} → retained 层（Modal/Sheet/Popover）里的 Spinner 部分重绘
    // 时 scissor 只剩圆心 ~2px，整个环被裁掉，转圈冻结。
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
    // 环的外缘 [188, 212] 必须整个落在脏区内
    try std.testing.expect(b[0] <= 200 - 12 - 3);
    try std.testing.expect(b[1] <= 200 - 12 - 3);
    try std.testing.expect(b[0] + b[2] >= 200 + 12 + 3);
    try std.testing.expect(b[1] + b[3] >= 200 + 12 + 3);
}

test "retained：含玻璃（begin_blur）的层及其外层指纹恒 0，永不复用缓存" {
    // 回归：玻璃像素取决于层**身后**的画面，而层指纹只看层内命令。含玻璃的
    // retained 层命中时背景被冻结在缓存纹理里，身后内容滚动/动画而玻璃不变。
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

    // 外层 [ 内层 [ 玻璃 ] ]，之后一个不含玻璃的兄弟层
    const cmds = [_]MockItem{
        begin, rect, begin, blur_begin, rect, blur_end, end, end,
        begin, rect, end,
    };
    encoder.computeRetainedContentHashes(cmds[0..]);
    try std.testing.expectEqual(@as(usize, 3), encoder.retained_hash_count);
    try std.testing.expectEqual(@as(u64, 0), encoder.retained_hashes[0]); // 外层
    try std.testing.expectEqual(@as(u64, 0), encoder.retained_hashes[1]); // 直接含玻璃
    try std.testing.expect(encoder.retained_hashes[2] != 0); // 兄弟层不受影响
}

test "computeBackdropCaptureRegion clamps src to source texture bottom/right edge" {
    // 瓦片跨视口底边：capture rect 底部超出 RT——clamp 后部分捕获而非整体失败
    //（未 clamp 时 blit 报 InvalidTextureRegion → 玻璃合成整体被静默跳过）。
    const region = RenderCommandEncoder.computeBackdropCaptureRegion(
        100,
        450, // 采样起点靠近底部
        80,
        120, // 高度越过 RT 底边（RT 高 500*2=1000 物理，采样底 450+120=570 逻辑 → 1140 物理）
        2,
        null,
        1000,
        1000,
    ).?;
    try std.testing.expect(region.src_y + region.copy_h <= 1000);
    try std.testing.expect(region.copy_h > 0);
}

test "measure 端与 render 端必须是同一个 FontSelector（度量≠渲染回归锚）" {
    // == 这个测试在防什么 ==
    // 「一段文本有多宽」在 zenit_app.runtime 里有三个出口，init() 时一起
    // 绑到内建的 app.font_selector 上：
    //   renderer.fonts / cx.measure_ctx / g_font_selector_for_measure
    // 消费方要换字体（下游编辑器换 Inter+Lora+Mono）时，如果只调
    // renderer.setFonts()，就只换掉了第一个 —— 画字用 Inter，量宽还用
    // runtime 默认那套。两套字体的 advance 不一样，于是光标和选区端点
    // 系统性地落在字形边缘之外，且越长的行偏得越多（误差逐字符累积）。
    //
    // 实测数据（fs=14 / fw=450 / "ssdf x"）：
    //   Inter-Regular  = 40.348
    //   HelveticaNeue  = 37.590   ← runtime 默认，差 2.758px
    // 这个缺口在行尾有 emoji 时最扎眼（emoji 本身 advance 19.000 两边一致，
    // 错的一直是拉丁部分），历史上被误报成「emoji 光栅化太窄」查了很久。
    //
    // ⚠ FontSelector 只是四个字体出口中的三个。第四个是 GlyphRun shape
    // 管线（光标/选区/命中走它），它**不经过 FontSelector**，由
    // layout_engine.setShapeFontResolver 单独接线。那条路的回归锚在
    // ui/core.zig "光标测量：shape 钩子装与不装必须同宽"。两个测试合起来
    // 才覆盖全部四个出口 —— 只看本测试会漏掉光标偏移那一半。
    //
    // == 为什么断言「两个 selector 测出不同宽度」而不是断言某个具体数值 ==
    // 具体数值随系统字体版本漂移，钉死会变成脆测试。真正要钉的是**机制**：
    // 不同 selector 必然给出不同宽度，所以「测量用哪个 selector」不是无关
    // 紧要的实现细节 —— 拿错就是错的，App.setFontSelector 必须一次换齐。
    var fs = try text_module.FontSystem.init(std.testing.allocator);
    defer fs.deinit();

    // 两套字体扮演「runtime 默认」与「App 自带」。用系统一定装了的两个族，
    // 避免测试依赖仓库里的 Inter/Lora 资源文件。
    const helv = try fs.findFont(.{ .family = "Helvetica Neue", .size = 14 });
    defer helv.deinit();
    const menlo = try fs.findFont(.{ .family = "Menlo", .size = 14 });
    defer menlo.deinit();

    var runtime_selector = FontSelector{ .small = helv, .medium = helv, .large = helv };
    var app_selector = FontSelector{ .small = menlo, .medium = menlo, .large = menlo };

    // 1) 前提：两套 selector 对同一段文本给出**不同**宽度。
    //    这一条若不成立，后面的断言就没有鉴别力（测试会静默变成恒真）。
    const sample = "ssdf x";
    const w_runtime = runtime_selector.measureTextWidth(sample, 14, 450, false);
    const w_app = app_selector.measureTextWidth(sample, 14, 450, false);
    try std.testing.expect(w_runtime > 0 and w_app > 0);
    try std.testing.expect(@abs(w_runtime - w_app) > 1.0);

    // 2) 核心不变式：**渲染端读的 selector** 与 **测量端读的 selector**
    //    必须是同一个对象。这里用 encoder 的 fonts 字段代表渲染端，
    //    用一个 measure_ctx 风格的间接调用代表测量端。
    const Bridge = struct {
        fn measure(ctx: *anyopaque, ptr: [*]const u8, len: usize, size: f32, weight: u16, italic: bool) f32 {
            const sel: *FontSelector = @ptrCast(@alignCast(ctx));
            return sel.measureTextWidth(ptr[0..len], size, weight, italic);
        }
    };

    // 模拟 runtime.init()：三处都指向内建 selector。
    var render_side: *FontSelector = &runtime_selector;
    var measure_ctx: *anyopaque = @ptrCast(&runtime_selector);
    try std.testing.expectApproxEqAbs(
        render_side.measureTextWidth(sample, 14, 450, false),
        Bridge.measure(measure_ctx, sample.ptr, sample.len, 14, 450, false),
        0.001,
    );

    // 模拟「只调 renderer.setFonts」这个 bug：render 端换了，measure 端没换。
    render_side = &app_selector;
    const rendered_w = render_side.measureTextWidth(sample, 14, 450, false);
    const measured_w = Bridge.measure(measure_ctx, sample.ptr, sample.len, 14, 450, false);
    // 这就是 bug 的形状 —— 两端分叉。断言它确实分叉，证明本测试测得到。
    try std.testing.expect(@abs(rendered_w - measured_w) > 1.0);

    // 模拟 App.setFontSelector：两端一起换，分叉消失。
    measure_ctx = @ptrCast(&app_selector);
    try std.testing.expectApproxEqAbs(
        render_side.measureTextWidth(sample, 14, 450, false),
        Bridge.measure(measure_ctx, sample.ptr, sample.len, 14, 450, false),
        0.001,
    );
}

test "emoji advance 与拉丁 advance 不随 base selector 变化而混淆" {
    // 配套锚点：emoji 走 coretext_bridge 的 AppleColorEmoji 强制回退，
    // 不受 base font 影响 —— 任何 base selector 下 advance 都一样。
    // 钉住这条是为了把「光标偏移」的责任范围**排除**掉 emoji：
    // 以后再出现类似偏移，这个测试仍绿就说明错的是拉丁段/base 字体，
    // 不必再重查一遍光栅化路径（历史上在那里空转过一轮）。
    var fs = try text_module.FontSystem.init(std.testing.allocator);
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
    // 同一个 emoji，两套 base selector 必须给出同一个 advance。
    try std.testing.expectApproxEqAbs(ea, eb, 0.001);

    // 而拉丁段必须**不同** —— 这正是上一个测试里那 2.758px 的来源。
    const la = sel_a.measureTextWidth("ssdf x", 14, 450, false);
    const lb = sel_b.measureTextWidth("ssdf x", 14, 450, false);
    try std.testing.expect(@abs(la - lb) > 1.0);
}

test "stack_mode: 脚本回退让位给显式字体栈，shapingFont 恒为 primary" {
    // == 这个测试在防什么 ==
    // 显式字体栈接入后，字体选择的分工是：
    //   FontSelector（本测试对象）—— 不再按整段内容挑 CJK/韩文回退字体；
    //   TextRenderer.selectSegmentFont —— shaping 前按码点在栈内显式选。
    // 若 stack_mode 下 resolveFonts 仍返回脚本回退，measure 端会整段换成
    // 回退字体（shapingFont() 的历史行为），而 draw 端只换 CJK 段 ——
    // 「量出来和画出来不一样宽」的老病换个入口复发。
    var fs = try text_module.FontSystem.init(std.testing.allocator);
    defer fs.deinit();
    const helv = try fs.findFont(.{ .family = "Helvetica Neue", .size = 14 });
    defer helv.deinit();
    const pingfang = try fs.findFont(.{ .family = "PingFang SC", .size = 14 });
    defer pingfang.deinit();

    var sel = FontSelector{ .small = helv, .medium = helv, .large = helv };
    sel.cjk_fonts[0] = pingfang;
    sel.cjk_count = 1;

    const cjk_text = "中文 mixed";

    // 关闭（默认）：维持既有行为 —— 内容相关脚本回退 + 整段按回退字体 shape。
    const legacy = sel.resolveFonts(cjk_text, .{ .font_size = 14 });
    try std.testing.expect(legacy.fallback_is_script);
    try std.testing.expectEqual(pingfang, legacy.fallback.?);
    try std.testing.expectEqual(pingfang, legacy.shapingFont());

    // 打开：脚本回退不再由 selector 决定，shaping 字体恒为 primary。
    sel.stack_mode = true;
    const stacked = sel.resolveFonts(cjk_text, .{ .font_size = 14 });
    try std.testing.expectEqual(@as(?*Font, null), stacked.fallback);
    try std.testing.expect(!stacked.fallback_is_script);
    try std.testing.expectEqual(stacked.primary, stacked.shapingFont());

    // 纯拉丁文本不受 stack_mode 影响。
    const latin_off = blk: {
        sel.stack_mode = false;
        break :blk sel.resolveFonts("hello", .{ .font_size = 14 }).primary;
    };
    sel.stack_mode = true;
    try std.testing.expectEqual(latin_off, sel.resolveFonts("hello", .{ .font_size = 14 }).primary);
}

test "damage-rect: 文本脏区必须覆盖整串，不能只有绘制原点那一小块" {
    // 回归（下游编辑器插入菜单表格尺寸标签："3 × 4" → "3 × 5" 屏幕上停在 "3 × 4"，
    // 再 → "4 × 5" 变成 "4 × 4"）：
    //
    // text 命令的 geom.w/h **恒为 0** —— lowering 只填绘制原点
    // （render_engine/gpu_draw_shadow.zig 的 .text_run 分支写死 .w=0/.h=0）。
    // damageItemBounds 直接拿它算脏区，于是 retained 层做部分重绘时脏区只有
    // 原点周围 pad×2 ≈ 20px：一行字里只有开头一两个字形落在脏区内被重画，
    // 后面的字形保留上一帧像素。
    //
    // 实测坐标（等宽 11px，原点 x=341）：旧脏区 x∈[331,351]，
    //   首字形 x=341 → 在脏区内，会更新；
    //   末字形 x=368 → 在脏区外，永远陈旧。
    // 这就是「第一段更新、× 之后的段不更新」的真正原因 —— 与字体回退分段
    // 无关，× 只是恰好把变化推到了尾段。
    //
    // 合同是**宁大宁小**（见 paint_fingerprint 文件头）：高估只多重绘几个
    // 像素，低估就是屏幕上的陈旧字。
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

    // 复现现场：11px 等宽、6 字节内容、原点 x=341；末字形落在 x≈368。
    const it = MockItem{
        .kind = .text,
        .geom = .{ .x = 341, .y = 84.3, .w = 0, .h = 0 },
        .text_content = "3 \xc3\x97 5",
        .text_font_size = 11,
    };

    const b = paint_fp.damageItemBounds(it);
    const left = b[0];
    const right = b[0] + b[2];

    // 末字形的右缘（保守取 x=368+13）必须落在脏区内。
    try std.testing.expect(left <= 341);
    try std.testing.expect(right >= 381);
}

test "damage-rect: 文本脏区纵向以基线为准，覆盖上伸部与下伸部" {
    // 回归：text 命令的 geom.y 是**基线**（text_item_render 填 baseline_y），
    // 字形画在基线上方（glyph_y = cursor_y - bearing_y）。旧 bounds 纵向是
    // [y-10, y+2fs+10] —— fs≥14 时字形顶部（y - ascent）落在脏区外，retained
    // 层部分重绘后变化文本的上半截保留陈旧像素。
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
        // 上伸部（含大写重音 / CJK ascent ≈ 1.2em）
        try std.testing.expect(b[1] <= baseline - fs * 1.2);
        // 下伸部（g/j/y ≈ 0.3em）
        try std.testing.expect(b[1] + b[3] >= baseline + fs * 0.4);
    }
}

test "damage-rect: 旋转的 image/icon 脏区覆盖旋转后的四角" {
    // 回归：damageItemBounds 忽略 rotate，按轴对齐 geom 算脏区 —— 45° 旋转
    // 后四角伸出 geom 外，旋转动画在 retained 层里留下拖影。
    const MockItem = DamageMock.MockItem;
    const it = MockItem{
        .kind = .image,
        .geom = .{ .x = 100, .y = 100, .w = 40, .h = 40 },
        .rotate = std.math.pi / 4.0,
        .resource_handle = 7,
    };
    const b = paint_fp.damageItemBounds(it);
    // 中心 (120,120)，外接圆半径 = 20√2 ≈ 28.28
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

test "指纹：polygon clip 按内容 hash（同指针新点集必须 miss）" {
    // 回归：clip_polygon_ptr 只喂指针值。点集活在 frame_arena，每帧 reset 后
    // 同地址复用 —— 多边形形变（同指针新内容）被判命中，retained 层停在旧
    // 裁剪形状。
    const MockItem = DamageMock.MockItem;
    var poly = MockClipPolygon{ .point_count = 3, .contour_count = 1 };
    poly.contour_end_points[0] = 3;
    poly.points[0] = .{ 0, 0 };
    poly.points[1] = .{ 10, 0 };
    poly.points[2] = .{ 5, 8 };
    const it = MockItem{ .control_kind = .push_clip, .clip_shape_kind = 3, .clip_polygon_ptr = &poly };
    const d0 = digestOf(it);
    try std.testing.expectEqual(d0, digestOf(it));
    poly.points[2] = .{ 5, 9 }; // 同一指针，内容变了
    try std.testing.expect(digestOf(it) != d0);
    poly.points[2] = .{ 5, 8 };
    poly.fill_rule = .nonzero;
    try std.testing.expect(digestOf(it) != d0);
    poly.fill_rule = .evenodd;
    // 有效区间外的点不影响像素 → 不影响指纹
    poly.points[10] = .{ 99, 99 };
    try std.testing.expectEqual(d0, digestOf(it));
    // 内容相同、地址不同 → 指纹相同（不因 arena 地址抖动 miss）
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
    // 回归：此前「是不是 arc」有两份判据 —— dispatchCommand 顶部用
    // arc_outer_radius <= 0 决定要不要 flushPathPending，.path 分支却用
    // (radius>0 and stroke>0 and alpha>0) 决定走不走 addArc。两者的差值
    // （零宽 / 全透明的 arc）既不被当作 arc，也没有 path_geometry_ptr，
    // 于是掉进 fill_path 分支被 `orelse return` 静默吞掉。
    //
    // Spinner.strokeWidth(0) 就能构造出这个形状；display_list_lowering 里
    // stroke_width 还会乘 scale，scale 趋近 0 时同样下溢到 0。

    const zero_stroke_arc = .{ .kind = .path, .arc_outer_radius = @as(f32, 10), .stroke_width = @as(f32, 0) };
    const transparent_arc = .{ .kind = .path, .arc_outer_radius = @as(f32, 10), .stroke_width = @as(f32, 3) };
    const normal_arc = .{ .kind = .path, .arc_outer_radius = @as(f32, 10), .stroke_width = @as(f32, 3) };
    const fill_path = .{ .kind = .path, .arc_outer_radius = @as(f32, 0), .stroke_width = @as(f32, 0) };
    const rect = .{ .kind = .rect, .arc_outer_radius = @as(f32, 0), .stroke_width = @as(f32, 0) };

    // 零宽 / 全透明的 arc 仍然**是** arc —— 画不出来不等于类型变了
    try std.testing.expect(ce.isArcCommand(zero_stroke_arc));
    try std.testing.expect(ce.isArcCommand(transparent_arc));
    try std.testing.expect(ce.isArcCommand(normal_arc));
    // 非 arc
    try std.testing.expect(!ce.isArcCommand(fill_path));
    try std.testing.expect(!ce.isArcCommand(rect));
}

test "image with an unknown texture is skipped instead of aborting the frame" {
    const img = @import("image_renderer.zig");
    // addImageUV 在查纹理槽失败时先于任何 GPU 访问返回，store 之外的字段不会被读到。
    var ir: img.ImageRenderer = undefined;
    ir.texture_store = img.ImageTextureStore.init(std.testing.allocator, undefined, false);
    ir.shared_texture_store = null;
    const stale_handle: u64 = 0x8000_1003;
    try ce.addImageOrSkip(&ir, stale_handle, 0, 0, 10, 10, .{ 1, 1, 1, 1 }, 0, 1, 0);
    try ce.addImageOrSkip(&ir, 7, 0, 0, 10, 10, .{ 1, 1, 1, 1 }, 0, 1, 0);
}

test "encoder.deinit 归还帧中途中止时 offscreen 栈上层借用的 external 纹理槽位" {
    // 回归：encodeDisplay/flush 的 try 在层 begin 之后失败时，逐帧 encoder 直接
    // deinit，栈上层的 texture_id 从未 unregister。external 槽位只有 256 个
    // 且句柄不跨帧，漏还即永久少一个槽。
    const img = @import("image_renderer.zig");
    var ir: img.ImageRenderer = undefined;
    ir.texture_store = img.ImageTextureStore.init(std.testing.allocator, undefined, false);
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
    encoder.image_renderer = &ir;
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
