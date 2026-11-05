//! SDF pass offscreen GPU benchmark (real Metal device, MTLCommandBuffer GPUStart/EndTime).
//!
//! Skipped by default; `ZENIT_SDF_GPU_BENCH=1 zig build test-metal` runs and prints
//! GPU time median/p10/p90 (microseconds) per scenario. Scenarios follow the pixel load profile of
//! storybook full e2e (1100x1000 logical window, 2x): solid rect ~56%, stroked ~17%,
//! rounded ~13%, shadow-only ~12% (shadow quad ~84% inside body).
//! Tests only the SDF pass itself, bypassing window/drawable/compositor.

const std = @import("std");
const gpu = @import("gpu");
const SdfRenderer = @import("sdf_renderer.zig").SdfRenderer;

const W: f32 = 1100;
const H: f32 = 1000;
const SCALE: f32 = 2;
const WARMUP = 30;
const ITERS = 300;

const Scene = enum { mix, plain, rounded, bordered, shadow, clipped };

fn rgba(r: f32, g: f32, b: f32, a: f32) [4]f32 {
    return .{ r * a, g * a, b * a, a };
}

fn emitPlain(r: *SdfRenderer) !void {
    const none = [4]f32{ 0, 0, 0, 0 };
    try r.addRoundedRect(0, 0, W, H, rgba(0.97, 0.97, 0.98, 1), none);
    try r.addRoundedRect(0, 0, 280, H, rgba(0.94, 0.95, 0.96, 1), none);
    try r.addRoundedRect(280, 60, 820, 940, rgba(1, 1, 1, 1), none);
    try r.addRoundedRect(280, 0, 820, 60, rgba(0.98, 0.98, 0.99, 1), none);
    for (0..30) |i| try r.addRoundedRect(10, 120 + @as(f32, @floatFromInt(i)) * 28, 260, 26, rgba(0.2, 0.4, 1, 0.08), none);
    for (0..12) |i| try r.addRoundedRect(300, 100 + @as(f32, @floatFromInt(i)) * 70, 780, 60, rgba(0.95, 0.96, 0.97, 1), none);
}

fn emitRounded(r: *SdfRenderer) !void {
    for (0..10) |row| for (0..10) |col| {
        const x = 300 + @as(f32, @floatFromInt(col)) * 78;
        const y = 120 + @as(f32, @floatFromInt(row)) * 70;
        try r.addRoundedRect(x, y, 70, 30, rgba(0.2, 0.45, 1, 1), .{ 6, 6, 6, 6 });
    };
    for (0..20) |i| try r.addRoundedRect(300 + @as(f32, @floatFromInt(i % 10)) * 78, 60 + @as(f32, @floatFromInt(i / 10)) * 30, 64, 22, rgba(0.9, 0.92, 0.95, 1), .{ 11, 11, 11, 11 });
}

fn emitBordered(r: *SdfRenderer) !void {
    for (0..24) |i| {
        const x = 300 + @as(f32, @floatFromInt(i % 2)) * 390;
        const y = 100 + @as(f32, @floatFromInt(i / 2)) * 74;
        try r.addBorderedRect(x, y, 370, 36, rgba(1, 1, 1, 1), rgba(0.8, 0.82, 0.86, 1), 1, .{ 6, 6, 6, 6 });
    }
    for (0..6) |i| {
        const x = 300 + @as(f32, @floatFromInt(i % 2)) * 390;
        const y = 120 + @as(f32, @floatFromInt(i / 2)) * 260;
        try r.addBorderedRect(x, y, 370, 230, rgba(1, 1, 1, 1), rgba(0.86, 0.88, 0.9, 1), 1, .{ 10, 10, 10, 10 });
    }
}

fn emitShadow(r: *SdfRenderer) !void {
    // Matches real emission: shadow is transparent fill, separate instance; body drawn by
    // rounded instance after.
    for (0..6) |i| {
        const x = 320 + @as(f32, @floatFromInt(i % 2)) * 390;
        const y = 120 + @as(f32, @floatFromInt(i / 2)) * 260;
        try r.addShadowRect(x, y, 350, 220, .{ 0, 0, 0, 0 }, rgba(0, 0, 0, 0.18), 12, 0, 4, .{ 10, 10, 10, 10 });
    }
    try r.addShadowRect(310, 250, 480, 320, .{ 0, 0, 0, 0 }, rgba(0, 0, 0, 0.25), 40, 0, 16, .{ 14, 14, 14, 14 });
}

/// Viewport-spanning content crossing viewport edge (real UI ~12% pixels fall outside clip).
fn emitClipped(r: *SdfRenderer) !void {
    r.setRectClip(.{ 300, 120, 780, 520 });
    for (0..5) |i| {
        const y = 20 + @as(f32, @floatFromInt(i)) * 160;
        try r.addBorderedRect(300, y, 780, 150, rgba(1, 1, 1, 1), rgba(0.85, 0.86, 0.9, 1), 1, .{ 10, 10, 10, 10 });
        try r.addRoundedRect(320, y + 20, 740, 40, rgba(0.95, 0.96, 0.98, 1), .{ 0, 0, 0, 0 });
    }
    r.setRectClip(null);
}

fn emit(r: *SdfRenderer, scene: Scene) !void {
    switch (scene) {
        .plain => try emitPlain(r),
        .rounded => try emitRounded(r),
        .bordered => try emitBordered(r),
        .shadow => try emitShadow(r),
        .clipped => try emitClipped(r),
        .mix => {
            try emitClipped(r);
            try emitPlain(r);
            try emitShadow(r);
            try emitBordered(r);
            try emitRounded(r);
        },
    }
}

const Stats = struct { median: u64, p10: u64, p90: u64 };

fn measure(dq: anytype, r: *SdfRenderer, view: anytype, scene: Scene) !Stats {
    var samples: [ITERS]u64 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < WARMUP + ITERS) : (i += 1) {
        r.beginFrame(W, H, SCALE, @intCast(i));
        try emit(r, scene);
        var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        }} });
        try r.flush(&pass);
        pass.end();
        var cb = try encoder.finish();
        defer cb.deinit();
        cb.submit();
        cb.waitUntilCompleted();
        if (i < WARMUP) continue;
        if (cb.gpuElapsedMicros()) |us| {
            samples[n] = us;
            n += 1;
        }
    }
    if (n == 0) return error.NoGpuTimestamps;
    std.mem.sort(u64, samples[0..n], {}, std.sort.asc(u64));
    return .{ .median = samples[n / 2], .p10 = samples[n / 10], .p90 = samples[n * 9 / 10] };
}

test "SDF pass GPU bench（ZENIT_SDF_GPU_BENCH=1 时运行）" {
    // SKIP-REASON: Opt-in GPU benchmark; enable ZENIT_SDF_GPU_BENCH to run.
    if (!@import("zenit_environment").flag("ZENIT_SDF_GPU_BENCH")) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var inst = try gpu.Backend.Instance.init(allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    var target = try dq.device.createTexture(allocator, .{
        .size = .{ .width = @intFromFloat(W * SCALE), .height = @intFromFloat(H * SCALE) },
        .format = gpu.color_format,
        .usage = .{ .render_attachment = true },
    });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();

    var r = try SdfRenderer.init(allocator, &dq.device);
    defer r.deinit();

    // Preheat once (GPU frequency ramped), then alternate A/B in same process:
    // general = force generic pipeline (pre-optimization baseline), specialized = Metal
    // specialization entry.
    const saved = r.specialized_shape_pipelines;
    inline for (.{ Scene.mix, Scene.plain, Scene.rounded, Scene.bordered, Scene.shadow, Scene.clipped }) |scene| _ = try measure(&dq, &r, view, scene);
    for (0..3) |round| {
        inline for (.{ Scene.mix, Scene.plain, Scene.rounded, Scene.bordered, Scene.shadow, Scene.clipped }) |scene| {
            r.specialized_shape_pipelines = @splat(null);
            const g = try measure(&dq, &r, view, scene);
            r.specialized_shape_pipelines = saved;
            const sp = try measure(&dq, &r, view, scene);
            std.debug.print("SDF-GPU-BENCH r{d} {s:>9}: general={d:>5}us specialized={d:>5}us ({d:.0}%)\n", .{ round, @tagName(scene), g.median, sp.median, @as(f64, @floatFromInt(sp.median)) / @as(f64, @floatFromInt(g.median)) * 100 });
        }
    }
    r.specialized_shape_pipelines = saved;
}

// ── Equivalence: specialized entry identical to generic entry byte-for-byte ──────────────

const EQ_W: f32 = 400;
const EQ_H: f32 = 300;

/// Cover boundary cases of each specialization class, and instances that must stay generic
/// (interleaved with specialized to verify pipeline batching doesn't reorder).
fn emitEquivalenceScene(r: *SdfRenderer) !void {
    const none = [4]f32{ 0, 0, 0, 0 };
    // fill: non-integer coordinates, semi-transparent, per-corner radius, subpixel size, giant
    // radius (clamped)
    try r.addRoundedRect(10.3, 7.7, 120.4, 40.2, rgba(0.2, 0.4, 0.9, 0.7), none);
    try r.addRoundedRect(20.5, 60.25, 90, 50, rgba(0.9, 0.3, 0.2, 1), .{ 3, 12, 0, 25 });
    try r.addRoundedRect(140.1, 10.1, 0.6, 0.6, rgba(0, 0, 0, 1), none);
    try r.addRoundedRect(150, 20, 30, 30, rgba(0.1, 0.8, 0.3, 0.5), .{ 99, 99, 99, 99 });
    // bordered: uniform stroke (integer/non-integer width), per-side stroke, fill-less stroke
    try r.addBorderedRect(200.4, 10.6, 80, 30, rgba(1, 1, 1, 1), rgba(0.3, 0.3, 0.3, 1), 1, .{ 6, 6, 6, 6 });
    try r.addBorderedRect(200, 50, 80, 30, rgba(0.95, 0.9, 0.8, 0.8), rgba(0.8, 0.1, 0.1, 0.9), 1.5, .{ 0, 10, 0, 10 });
    try r.addBorderedRectPerSide(290.2, 10.2, 90, 60, rgba(1, 1, 0.9, 1), rgba(0, 0, 0.6, 1), .{ 0, 2, 1, 3 }, .{ 8, 0, 8, 0 });
    try r.addBorderedRect(290, 80, 90, 40, .{ 0, 0, 0, 0 }, rgba(0.2, 0.7, 0.2, 1), 2, .{ 12, 12, 12, 12 });
    // shadow_only: normal, positive/negative spread, offset > blur
    try r.addShadowRect(30, 140, 120, 70, .{ 0, 0, 0, 0 }, rgba(0, 0, 0, 0.3), 12, 0, 4, .{ 10, 10, 10, 10 });
    try r.addShadowRectSpread(180, 140, 100, 60, .{ 0, 0, 0, 0 }, rgba(0.2, 0, 0.4, 0.4), 8, 3, -2, 6, .{ 4, 4, 4, 4 });
    try r.addShadowRectSpread(300, 150, 80, 50, .{ 0, 0, 0, 0 }, rgba(0, 0, 0, 0.5), 5, 0, 12, -3, .{ 0, 0, 0, 0 });
    // Must stay generic: shadow with fill, gradient, ellipse, inner shadow; interleaved with
    // specialized
    try r.addShadowRect(30, 230, 100, 50, rgba(1, 1, 1, 1), rgba(0, 0, 0, 0.25), 10, 2, 3, .{ 8, 8, 8, 8 });
    try r.addRoundedRect(40, 240, 80, 30, rgba(0.3, 0.6, 1, 0.6), .{ 4, 4, 4, 4 });
    try r.addGradientRect(150, 230, 100, 50, rgba(1, 0, 0, 1), rgba(0, 0, 1, 1), .horizontal, .{ 6, 6, 6, 6 });
    try r.addEllipse(270, 225, 60, 60, rgba(0.9, 0.7, 0.1, 1), rgba(0, 0, 0, 1), 1.5, .{ 0, 0, 0, 0 });
    try r.addInsetShadowRect(340, 230, 50, 50, rgba(0.9, 0.9, 0.9, 1), rgba(0, 0, 0, 0.5), 6, 0, 2, .{ 8, 8, 8, 8 });
    // Various instances under rectangular clip
    r.setRectClip(.{ 0, 0, 220, 130 });
    try r.addBorderedRect(100, 90, 150, 60, rgba(0.6, 0.9, 0.6, 0.9), rgba(0.1, 0.4, 0.1, 1), 1, .{ 10, 10, 10, 10 });
    try r.addShadowRect(150, 100, 100, 50, .{ 0, 0, 0, 0 }, rgba(0, 0, 0, 0.4), 9, 0, 3, .{ 6, 6, 6, 6 });
    // Centered clip region: specialized instances each cross its left/top/right/bottom edge
    r.setRectClip(.{ 120.5, 150.25, 150, 90 });
    try r.addRoundedRect(100, 160, 60, 30, rgba(0.2, 0.3, 0.9, 0.9), .{ 5, 5, 5, 5 }); // Left edge
    try r.addBorderedRect(170, 135, 60, 40, rgba(1, 0.9, 0.7, 1), rgba(0.5, 0.2, 0, 1), 1.5, .{ 6, 6, 6, 6 }); // Top edge
    try r.addRoundedRect(250, 200, 50, 20, rgba(0.1, 0.6, 0.4, 1), .{ 0, 0, 0, 0 }); // Right edge
    try r.addShadowRect(160, 215, 70, 40, .{ 0, 0, 0, 0 }, rgba(0, 0, 0, 0.45), 8, 0, 3, .{ 6, 6, 6, 6 }); // Bottom edge
    try r.addShadowRect(110, 140, 40, 30, .{ 0, 0, 0, 0 }, rgba(0.3, 0, 0, 0.4), 6, -2, -2, .{ 4, 4, 4, 4 }); // Top-left corner
    r.setRectClip(null);
}

fn renderEquivalence(dq: anytype, r: *SdfRenderer, target: anytype, staging: anytype, out: []u8) !void {
    var view = target.binding().createView();
    defer view.destroy();
    var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
    {
        r.beginFrame(EQ_W, EQ_H, SCALE, 7);
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 },
        }} });
        try emitEquivalenceScene(r);
        try r.flush(&pass);
        // Second flush: rounded-corner clipping active (clip_shape_kind = 1)
        var end_points = @as([8]u8, @splat(0));
        _ = &end_points;
        r.setClipMask(1, .{ 210, 120, 180, 170 }, @splat(24), 0, 0, 0, end_points, @as([32][2]f32, @splat(.{ 0, 0 })));
        try emitEquivalenceScene(r);
        try r.flush(&pass);
        r.setClipMask(0, null, @splat(0), 0, 0, 0, end_points, @as([32][2]f32, @splat(.{ 0, 0 })));
        pass.end();
    }
    var blit = try encoder.beginBlitPass();
    try blit.copyTextureRegion(target.binding(), 0, 0, target.size.width, target.size.height, staging.binding(), 0, 0);
    blit.end();
    var cb = try encoder.finish();
    defer cb.deinit();
    cb.submit();
    cb.waitUntilCompleted();
    try staging.readBgra8(staging.size.width, staging.size.height, out, staging.size.width * 4);
}

test "SDF Metal 特化入口与通用入口输出一致（≤1 LSB 的浮点舍入差）" {
    // SKIP-REASON: Requires Metal-specific shader entry points and readback.
    if (comptime gpu.backend_kind != .metal) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var inst = try gpu.Backend.Instance.init(allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    const pw: u32 = @intFromFloat(EQ_W * SCALE);
    const ph: u32 = @intFromFloat(EQ_H * SCALE);
    var target = try dq.device.createTexture(allocator, .{
        .size = .{ .width = pw, .height = ph },
        .format = gpu.color_format,
        .usage = .{ .render_attachment = true, .copy_src = true },
    });
    defer target.destroy();
    var staging = try dq.device.createTexture(allocator, .{
        .size = .{ .width = pw, .height = ph },
        .format = gpu.color_format,
        .usage = .{ .copy_dst = true },
        .memory = .host_upload,
    });
    defer staging.destroy();

    var r = try SdfRenderer.init(allocator, &dq.device);
    defer r.deinit();
    try std.testing.expect(r.specialized_shape_pipelines[0] != null and r.specialized_shape_pipelines[1] != null and r.specialized_shape_pipelines[2] != null);

    // Scenario covers each specialization class and generic class (else comparison below is
    // vacuous).
    r.beginFrame(EQ_W, EQ_H, SCALE, 7);
    try emitEquivalenceScene(&r);
    var seen = @as([4]usize, @splat(0));
    for (r.instances.items) |item| seen[@backingInt(SdfRenderer.metalKind(item))] += 1;
    for (seen) |count| try std.testing.expect(count > 0);

    const specialized = try allocator.alloc(u8, pw * ph * 4);
    defer allocator.free(specialized);
    const general = try allocator.alloc(u8, pw * ph * 4);
    defer allocator.free(general);

    try renderEquivalence(&dq, &r, &target, &staging, specialized);
    const saved = r.specialized_shape_pipelines;
    r.specialized_shape_pipelines = @splat(null);
    try renderEquivalence(&dq, &r, &target, &staging, general);
    r.specialized_shape_pipelines = saved;

    // Equivalence: every byte diff <= 1, diff byte <= 0.01%. Two entries same source, but Metal
    // default fast-math; after inlining constants, fused multiply-add can differ, occasionally
    // rounding on quantized 8-bit boundary flips 1 LSB (real app 5 stories, ~22M pixels same state:
    // 1 pixel diff by 1). Semantic error (missing stroke, dropped pixel, clip mismatch) diff >> 1,
    // count >> threshold.
    var diff: usize = 0;
    var max_delta: u8 = 0;
    var first: ?usize = null;
    for (specialized, general, 0..) |a, b, i| if (a != b) {
        diff += 1;
        max_delta = @max(max_delta, if (a > b) a - b else b - a);
        if (first == null) first = i;
    };
    if (diff != 0) {
        std.debug.print("SDF 特化与通用差异：{d} 字节（最大差 {d}），首个在像素 ({d},{d})\n", .{ diff, max_delta, (first.? / 4) % pw, (first.? / 4) / pw });
    }
    try std.testing.expect(max_delta <= 1);
    try std.testing.expect(diff * 10_000 <= specialized.len);
    // Scenario non-empty (really drew something)
    var non_bg: usize = 0;
    for (0..pw * ph) |p| if (general[p * 4] != general[0] or general[p * 4 + 2] != general[2]) {
        non_bg += 1;
    };
    try std.testing.expect(non_bg > 10000);
}
