//! command_encoder/persistent_gpu_cache.zig: bookkeeping for cross-frame GPU resource caching.
//!
//! Fields belong to AppRenderer's `PersistentGpuCache`: blur/glass/blend/damage-clear
//! pipelines, uniform ring write offsets, and per-glass-island LRU slots (luminance readback /
//! blur chain depth hysteresis).
//!
//! **Only bookkeeping lives here**: pipeline/buffer/sampler **creation** happens in
//! backdrop_blur.zig / opacity_layer.zig / blend_composite.zig (they own the device),
//! **usage** in the encoder's encode path. This module owns only 'fields + per-frame cursor
//! reset + unified teardown', fully decoupled from GPU object shape (all `?gpu.Backend.X`
//! null checks), so it is testable without a real device.
//!
//! Not here:
//!   - acquireKawaseUniformSlot / acquireGlassUniformSlot / resetDynamic... live in
//!     backdrop_blur.zig (reads encoder.persistent cross-module);
//!   - luminance/blur_level slot LRU logic, also in backdrop_blur.zig;
//!   - debug_glass_slots[2] readback consumption, in zenit_app/renderer.zig.
//!
//! WARNING: deinit teardown order must be: staging textures, then renderer, then
//! pipelines/buffers/samplers, finally reset the failed flags. Failed flags reset with the
//! cache so a retry is allowed after device rebuild (a missed reset leaves that pipeline
//! permanently degraded). Every persistent object must be released in deinit,
//! including damage_clear_pipeline.

const std = @import("std");
const gpu = @import("gpu");

const path_tess_mod = @import("../path_tessellator.zig");
const PathRenderer = @import("../path_renderer.zig").PathRenderer;

/// Max number of glass (single / container) whose backdrop luminance can be read back at the
/// same time on screen. With 12 slots, a page with slightly more glass (16 blocks) made them
/// steal slots from each other so none could be read (the first-frame probe of a newly created
/// glass timed out); one 64x64 staging texture (16 KiB) per slot.
pub const LUMINANCE_SLOT_COUNT: usize = 32;

/// A specialized glass composite pipeline (backdrop_blur.glassPipelineFor),
/// built on a background thread: `pipeline` is published by `state` (release).
pub const GlassVariant = struct {
    pub const building: u8 = 0;
    pub const ready: u8 = 1;
    pub const failed: u8 = 2;
    key: u16,
    state: std.atomic.Value(u8) = .init(building),
    pipeline: ?gpu.Backend.RenderPipeline = null,
    thread: ?std.Thread = null,
};

/// Per-glass luminance slot (see PersistentGpuCache.luminance_slots).
pub const LuminanceSlot = struct {
    staging: ?gpu.Backend.Texture = null,
    /// glass owner node id (maxInt = empty slot). Constant across scroll/layout change, consumer
    /// matches by own node id exactly.
    key: u32 = std.math.maxInt(u32),
    cur_pending: bool = false,
    cur_w: u32 = 0,
    cur_h: u32 = 0,
    prev_pending: bool = false,
    prev_w: u32 = 0,
    prev_h: u32 = 0,
    last_used_frame: u64 = 0,
    /// The glass's own rect inside the staging texture {u0, v0, uw, vh}: the
    /// capture is padded for blur/lens bleed, and the mean must cover only
    /// the backdrop under the glass (a 100px glass over white read 0.3 with
    /// the dark surroundings of the padding included).
    content_uv: [4]f32 = .{ 0, 0, 1, 1 },
    /// Latest successful readback avg luminance in area (linear light)
    value: ?f32 = null,
    /// Same readback's sRGB-encoded luminance (0..1): native light/dark flip decides by this
    /// magnitude.
    value_srgb: ?f32 = null,
    /// GlassGroup: per-shape sub-rect (staging uv) and readings, key = member surface
    shape_count: u8 = 0,
    shape_keys: [8]u32 = @as([8]u32, @splat(std.math.maxInt(u32))),
    shape_uv: [8][4]f32 = @as([8][4]f32, @splat(.{ 0, 0, 1, 1 })),
    shape_value_count: u8 = 0,
    shape_value: [8]f32 = @as([8]f32, @splat(0)),
    shape_value_srgb: [8]f32 = @as([8]f32, @splat(0)),
};

/// Per-glass blur-chain-depth hysteresis slot (see PersistentGpuCache.blur_level_slots).
pub const BlurLevelSlot = struct {
    /// glass owner node id (maxInt = empty slot), same as LuminanceSlot.key
    key: u32 = std.math.maxInt(u32),
    /// Blur-chain depth actually submitted last frame. 0 = no history (first frame unconstrained).
    committed_levels: u32 = 0,
    /// Requested blur/DPI tier. A changed request is a material edit, not a
    /// resource-pressure recovery; it must not wait for six unrelated frames.
    requested_levels: u32 = 0,
    /// How many frames running at or below hysteresis cap. Reach raise threshold to allow one raise
    /// attempt, avoid rapid churn on threshold.
    raise_streak: u32 = 0,
    /// Consecutive raise-attempt failures. Threshold stretches exponentially by 1<<backoff factor,
    /// avoid oscillation at hard saturation point (pool never provides that tier) degrading to
    /// 'flash once per N frames'.
    raise_backoff: u32 = 0,
    last_used_frame: u64 = 0,
};

/// Hysteresis slot count, same order as LUMINANCE_SLOT_COUNT (both per-glass-island); when full,
/// new islands degrade to non-hysteretic behavior (see backdrop_blur.zig).
pub const BLUR_LEVEL_SLOT_COUNT: usize = LUMINANCE_SLOT_COUNT;

/// Pipelines of the batched native glass bank passes (backdrop_blur bank
/// batch; Metal only): fragment forms that write their target in a render
/// pass without attachments.
pub const bank_batch_supported = gpu.backend_kind == .metal;
pub const BankBatch = if (bank_batch_supported) struct {
    /// Indexed by backdrop_blur.BankKind; all built or none.
    pipelines: [5]?gpu.Backend.RenderPipeline = @splat(null),

    pub fn deinit(self: *@This()) void {
        for (&self.pipelines) |*slot| if (slot.*) |*p| p.deinit();
        self.* = .{};
    }
} else struct {
    pub fn deinit(_: *@This()) void {}
};

pub const PersistentGpuCache = struct {
    bank_batch: BankBatch = .{},
    /// Dual Kawase blur pipelines (lazy-init on first use)
    blur_downsample_pipeline: ?gpu.Backend.RenderPipeline = null,
    blur_upsample_pipeline: ?gpu.Backend.RenderPipeline = null,
    gaussian_pipeline: ?gpu.Backend.RenderPipeline = null,
    gaussian_gamma_pipeline: ?gpu.Backend.RenderPipeline = null,
    gaussian_encode_pipeline: ?gpu.Backend.RenderPipeline = null,
    gaussian_box_gamma_pipeline: ?gpu.Backend.RenderPipeline = null,
    gaussian_downsample_pipeline: ?gpu.Backend.RenderPipeline = null,
    blur_sampler: ?gpu.Backend.Sampler = null,
    /// Kawase pass count encoded this frame (limit = single-frame blur chain budget). Uniform via
    /// setFragmentBytes: Metal copies bytes during encode. Previously a single shared buffer with
    /// per-frame offset reset; with 3 frames in flight, frame N+1 overwrites frame N's
    /// texel/valid_uv still being read by GPU.
    blur_uniform_write_offset: u32 = 0,
    /// Blur shader/PSO compilation failure sticky flag: try once only. On persistent failure, every
    /// blur frame recompiles full source via newLibraryWithSource (10ms+) + log spam.
    blur_pipeline_failed: bool = false,
    /// Liquid Glass composite pipeline
    glass_pipeline: ?gpu.Backend.RenderPipeline = null,
    /// The tab lens's field table (tab_lens_field.zig), the composite's fragment buffer 1:
    /// uploaded with the pipeline, never rewritten, so frames in flight share it.
    tab_lens_field: ?gpu.Backend.Buffer = null,
    /// Specialized composite pipelines by backdrop_blur.glassVariantKey
    /// (Metal; null pipeline = build failed, the general one serves).
    glass_variants: [16]*GlassVariant = undefined,
    glass_variant_count: usize = 0,
    glass_uniform_write_offset: u32 = 0,
    glass_uniform_overflow_warned: bool = false,
    /// Glass pipeline failure sticky flag (like blur_pipeline_failed; degrades to pure blur+tint).
    glass_pipeline_failed: bool = false,
    /// Backdrop brightness auto-adapt: per-glass-region deepest Kawase level blit target pool.
    /// Previously single shared staging = each frame's last-encoded glass overwrites, global value
    /// was 'random glass area luminance', scrolling changes culling/ordering -> whole scene
    /// oscillates (storybook: scroll causes all glass to sync recolor/fade). Slots quantize by draw
    /// rect key (LRU reuse); each staging is fixed 64x64 shared storage, created once never rebuilt
    /// (rebuild frees prev frame's blit target). Write-read lag one frame: cur_* describes this
    /// frame's blit, prev_* readable after prev cmd buffer completes.
    luminance_slots: [LUMINANCE_SLOT_COUNT]LuminanceSlot = @as([LUMINANCE_SLOT_COUNT]LuminanceSlot, @splat(.{})),
    /// Luminance readback in flight (renderer holds write-frame command buffer, not yet read): stop
    /// writing to staging, else in-flight GPU write interleaves with later frame writes, read
    /// result belongs to no single frame.
    luminance_locked: bool = false,
    /// Debug (ZENIT_DEBUG_GLASS): 64x64 center region of glass pipeline intermediates staging, slot
    /// 0 = capture(level0), slot 1 = composite(glass_tex), slot 2 = frame-end RT region
    /// (ZENIT_DEBUG_GLASS_RT='x,y' in device pixels). Same structure/lifetime as luminance_slots;
    /// renderer reads RGB mean per frame to binary-search 'scroll flicker fork point happens at
    /// which level'.
    debug_glass_slots: [3]LuminanceSlot = @as([3]LuminanceSlot, @splat(.{})),

    /// Backdrop blur chain depth inter-frame hysteresis state (per glass island, survives across
    /// frames). Background: downsample chain breaks when offscreen pool exhausts textures,
    /// actual_levels stalls mid-chain. At pool pressure threshold, same island oscillates
    /// 5->4->4->5 per frame; flicker is perceptible. Strategy: downgrade instant (use less, never
    /// emit garbage), upgrade requires BLUR_LEVEL_RAISE_FRAMES consecutive successful frames.
    /// Independent of island count, no oscillation regression as pool expands.
    blur_level_slots: [BLUR_LEVEL_SLOT_COUNT]BlurLevelSlot = @as([BLUR_LEVEL_SLOT_COUNT]BlurLevelSlot, @splat(.{})),

    /// Last backdrop key per glass owner: a composite is retained for reuse
    /// only once its key repeats (glass_reuse.History).
    glass_history: @import("../glass_reuse.zig").History = .{},

    /// Damage-rect dirty region clear pipeline (no-blend direct write (0,0,0,0), scissor to
    /// sub-rectangle).
    damage_clear_pipeline: ?gpu.Backend.RenderPipeline = null,
    damage_clear_pipeline_failed: bool = false,
    /// Main-target damage fill (clear colour into the damage scissor, Metal).
    damage_fill_pipeline: ?gpu.Backend.RenderPipeline = null,
    /// Main-target damage copy (the presented frame drawn under the damage, Metal).
    damage_copy_pipeline: ?gpu.Backend.RenderPipeline = null,
    damage_fill_pipeline_failed: bool = false,

    /// Blend composite pipeline (non-normal blend modes, lazy-init).
    blend_pipeline: ?gpu.Backend.RenderPipeline = null,
    blend_uniform_write_offset: u32 = 0,
    /// Shader compilation failure flag: try once, fail persists silently to normal (no per-frame
    /// recompile).
    blend_pipeline_failed: bool = false,

    /// Path rendering (vector paths, lazy-init).
    path_renderer: ?PathRenderer = null,
    path_tessellator: ?path_tess_mod.PathTessellator = null,

    /// Reset per-frame cursor at frame start (uniform ring write offset etc.), but preserve
    /// pipeline/buffer/sampler.
    pub fn beginFrame(self: *PersistentGpuCache) void {
        self.blur_uniform_write_offset = 0;
        self.blend_uniform_write_offset = 0;
        self.glass_uniform_write_offset = 0;
        self.glass_uniform_overflow_warned = false;
        if (self.path_renderer) |*pr| {
            pr.frame_call_count = 0;
            pr.frame_draw_count = 0;
        }
    }

    pub fn deinit(self: *PersistentGpuCache) void {
        for (&self.luminance_slots) |*slot| {
            if (slot.staging) |*texture| texture.destroy();
            slot.staging = null;
        }
        for (&self.debug_glass_slots) |*slot| {
            if (slot.staging) |*texture| texture.destroy();
            slot.staging = null;
        }
        if (self.path_renderer) |*pr| pr.deinit();
        self.path_renderer = null;
        if (self.path_tessellator) |*tess| tess.deinit();
        self.path_tessellator = null;
        if (self.blur_downsample_pipeline) |*p| p.deinit();
        self.blur_downsample_pipeline = null;
        // Failure flag resets on cache clear: device swap allows one retry.
        self.blur_pipeline_failed = false;
        self.glass_pipeline_failed = false;
        if (self.blur_upsample_pipeline) |*p| p.deinit();
        self.blur_upsample_pipeline = null;
        if (self.gaussian_pipeline) |*p| p.deinit();
        self.gaussian_pipeline = null;
        if (self.gaussian_gamma_pipeline) |*p| p.deinit();
        self.gaussian_gamma_pipeline = null;
        if (self.gaussian_encode_pipeline) |*p| p.deinit();
        self.gaussian_encode_pipeline = null;
        if (self.gaussian_box_gamma_pipeline) |*p| p.deinit();
        self.gaussian_box_gamma_pipeline = null;
        if (self.gaussian_downsample_pipeline) |*p| p.deinit();
        self.gaussian_downsample_pipeline = null;
        if (self.blur_sampler) |*sampler| sampler.destroy();
        self.blur_sampler = null;
        self.bank_batch.deinit();
        if (self.glass_pipeline) |*p| p.deinit();
        self.glass_pipeline = null;
        if (self.tab_lens_field) |*b| b.destroy();
        self.tab_lens_field = null;
        for (self.glass_variants[0..self.glass_variant_count]) |v| {
            if (v.thread) |t| t.join();
            if (v.pipeline) |*p| p.deinit();
            std.heap.page_allocator.destroy(v);
        }
        self.glass_variant_count = 0;
        if (self.blend_pipeline) |*p| p.deinit();
        self.blend_pipeline = null;
        // Damage clear pipeline (opacity_layer lazy), previously only missing from 12 persistent
        // GPU objects' deinit; failed flag must reset to allow device swap retry.
        if (self.damage_clear_pipeline) |*p| p.deinit();
        self.damage_clear_pipeline = null;
        self.damage_clear_pipeline_failed = false;
        if (self.damage_fill_pipeline) |*p| p.deinit();
        self.damage_fill_pipeline = null;
        if (self.damage_copy_pipeline) |*p| p.deinit();
        self.damage_copy_pipeline = null;
        self.damage_fill_pipeline_failed = false;
    }
};

// Test: field checklist for beginFrame/deinit was cover only by 'compiles + real run'
// (command_encoder_test.zig only covers uniform offset fields). These assertions pin field names;
// forgetting a persistent field in beginFrame/deinit causes compile error, not silent omission like
// damage_clear.

test "PersistentGpuCache 零值构造即合法（AppRenderer.init 依赖全 lazy）" {
    var pgc = PersistentGpuCache{};
    pgc.deinit(); // All null: deinit is no-op and never crashes.
}

test "beginFrame 复位帧内游标但保留对象槽位内容" {
    var pgc = PersistentGpuCache{};
    defer pgc.deinit();

    pgc.blur_uniform_write_offset = 100;
    pgc.blend_uniform_write_offset = 200;
    pgc.glass_uniform_write_offset = 300;
    pgc.glass_uniform_overflow_warned = true;
    pgc.luminance_slots[0] = .{ .key = 7, .last_used_frame = 42, .value = 0.5 };
    pgc.blur_level_slots[0] = .{ .key = 7, .committed_levels = 5, .raise_streak = 3 };

    pgc.beginFrame();

    try std.testing.expectEqual(@as(u32, 0), pgc.blur_uniform_write_offset);
    try std.testing.expectEqual(@as(u32, 0), pgc.blend_uniform_write_offset);
    try std.testing.expectEqual(@as(u32, 0), pgc.glass_uniform_write_offset);
    try std.testing.expectEqual(false, pgc.glass_uniform_overflow_warned);
    // Per-frame cursor reset != clearing cross-frame slots: LRU key / hysteresis history must
    // survive frames, else strategy degrades to 'every frame starts fresh', exactly the flicker it
    // cures.
    try std.testing.expectEqual(@as(u32, 7), pgc.luminance_slots[0].key);
    try std.testing.expectEqual(@as(u64, 42), pgc.luminance_slots[0].last_used_frame);
    try std.testing.expectEqual(@as(?f32, 0.5), pgc.luminance_slots[0].value);
    try std.testing.expectEqual(@as(u32, 5), pgc.blur_level_slots[0].committed_levels);
}

test "deinit 复位失败粘性标志（换 device 后允许重试一次）" {
    var pgc = PersistentGpuCache{};
    pgc.blur_pipeline_failed = true;
    pgc.glass_pipeline_failed = true;
    pgc.damage_clear_pipeline_failed = true;
    pgc.deinit();
    try std.testing.expect(!pgc.blur_pipeline_failed);
    try std.testing.expect(!pgc.glass_pipeline_failed);
    try std.testing.expect(!pgc.damage_clear_pipeline_failed);
    // Clear object slots too: re-deinit is idempotent.
    try std.testing.expectEqual(
        @as(?gpu.Backend.RenderPipeline, null),
        pgc.blur_downsample_pipeline,
    );
    pgc.deinit();
}

test "槽位数组容量：迟滞槽数与亮度槽数一致（同为逐 glass 岛资源）" {
    try std.testing.expectEqual(LUMINANCE_SLOT_COUNT, BLUR_LEVEL_SLOT_COUNT);
    try std.testing.expectEqual(@as(usize, 32), LUMINANCE_SLOT_COUNT);
    try std.testing.expectEqual(@as(usize, 3), debug_glass_slots_len);
}

/// ZENIT_DEBUG_GLASS three-level intermediate slots (capture / composite / frame-end RT region).
const debug_glass_slots_len = 3;

test "空槽哨兵：key = maxInt(u32) 表示未占用" {
    var pgc = PersistentGpuCache{};
    defer pgc.deinit();
    for (pgc.luminance_slots) |slot| {
        try std.testing.expectEqual(std.math.maxInt(u32), slot.key);
        try std.testing.expectEqual(@as(?f32, null), slot.value);
    }
    for (pgc.blur_level_slots) |slot| {
        try std.testing.expectEqual(std.math.maxInt(u32), slot.key);
        try std.testing.expectEqual(@as(u32, 0), slot.committed_levels);
    }
}
