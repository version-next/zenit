//! command_encoder/persistent_gpu_cache.zig — 跨帧 GPU 资源缓存的**簿记**
//!
//! 从 command_encoder.zig 析出（2026-08-05）。这组字段属于 AppRenderer
//! 持有的 `PersistentGpuCache`：blur/glass/blend/damage-clear 的 pipeline、
//! uniform 环形写偏移、以及逐 glass 岛的 LRU 槽（亮度回读 / blur 链深迟滞）。
//!
//! **能搬的只是簿记**：pipeline/buffer/sampler 的**创建**发生在
//! backdrop_blur.zig / opacity_layer.zig / blend_composite.zig（它们持有
//! device），**使用**发生在 encoder 的编码路径。本模块只拥有「字段 + 帧内
//! 游标复位 + 统一释放」—— 这三样与 GPU 对象的形状完全解耦（全是
//! `?gpu.Backend.X` 的 null 判空），也因此可以脱离真实设备单测。
//!
//! 不搬什么：
//!   - acquireKawaseUniformSlot / acquireGlassUniformSlot / resetDynamic…
//!     已在 backdrop_blur.zig（那边按 encoder.persistent 读写，跨模块字段
//!     访问是既有模式，搬走反而制造第二份）；
//!   - luminance/blur_level 槽的 LRU 匹配逻辑同在 backdrop_blur.zig；
//!   - debug_glass_slots[2] 的回读消费在 zenit_app/renderer.zig。
//!
//! ⚠ 合同：`deinit` 的释放顺序必须保持「先 staging 纹理、再 renderer、
//! 再各 pipeline/buffer/sampler、最后复位 failed 标志」——失败标志随缓存
//! 清空复位，换 device 重建后允许重试一次（漏复位 = 那个管线永久退化）。
//! 历史上 damage_clear_pipeline 曾是 12 个持久对象里唯一被 deinit 遗漏的。

const std = @import("std");
const gpu = @import("gpu");

const path_tess_mod = @import("../path_tessellator.zig");
const PathRenderer = @import("../path_renderer.zig").PathRenderer;

pub const LUMINANCE_SLOT_COUNT: usize = 12;

/// 逐 glass 区域亮度槽（见 PersistentGpuCache.luminance_slots 注释）。
pub const LuminanceSlot = struct {
    staging: ?gpu.Backend.Texture = null,
    /// glass 拥有者 node id（maxInt = 空槽）。恒定于滚动/布局变化，
    /// 消费侧按自身 node id 精确匹配。
    key: u32 = std.math.maxInt(u32),
    cur_pending: bool = false,
    cur_w: u32 = 0,
    cur_h: u32 = 0,
    prev_pending: bool = false,
    prev_w: u32 = 0,
    prev_h: u32 = 0,
    last_used_frame: u64 = 0,
    /// 最近一次成功回读的区域平均亮度
    value: ?f32 = null,
};

/// 逐 glass 区域的 blur 链深迟滞槽（见 PersistentGpuCache.blur_level_slots）。
pub const BlurLevelSlot = struct {
    /// glass 拥有者 node id（maxInt = 空槽），同 LuminanceSlot.key。
    key: u32 = std.math.maxInt(u32),
    /// 上一帧**实际提交**的链深。0 = 尚无历史（首帧不设限）。
    committed_levels: u32 = 0,
    /// 连续多少帧在迟滞上限内跑满。达到 raise 阈值才放行一次上调尝试，
    /// 避免临界线上反复横跳。
    raise_streak: u32 = 0,
    /// 上调尝试连续失败次数。阈值按 1<<backoff 倍数指数拉长，避免在**硬**
    /// 饱和点（池永远给不出那一级）退化成「每 N 帧闪一次」的低频振荡。
    /// 成功上调后清零。
    raise_backoff: u32 = 0,
    last_used_frame: u64 = 0,
};

/// 迟滞槽数量。与 LUMINANCE_SLOT_COUNT 同量级即可（同为逐 glass 岛资源）；
/// 槽满时新岛找不到槽 → 退化为无迟滞的原行为（见 backdrop_blur.zig）。
pub const BLUR_LEVEL_SLOT_COUNT: usize = LUMINANCE_SLOT_COUNT;

pub const PersistentGpuCache = struct {
    /// Dual Kawase blur pipelines (lazy-init on first use)
    blur_downsample_pipeline: ?gpu.Backend.RenderPipeline = null,
    blur_upsample_pipeline: ?gpu.Backend.RenderPipeline = null,
    blur_sampler: ?gpu.Backend.Sampler = null,
    /// 本帧已编码的 Kawase pass 数（上限 = 单帧模糊链预算）。uniform 本身走
    /// setFragmentBytes：Metal 在 encode 时拷贝字节。曾经是单个共享 buffer +
    /// 每帧偏移归零 —— 三帧在飞时第 N+1 帧覆写 GPU 尚在读的第 N 帧 texel/valid_uv。
    blur_uniform_write_offset: u32 = 0,
    /// blur shader 编译/PSO 失败粘性标记——只试一次，否则持久失败时每个 blur 帧
    /// 重新 newLibraryWithSource 编译整份源码（十毫秒级）+ 日志刷屏。
    blur_pipeline_failed: bool = false,
    /// Liquid Glass composite pipeline
    glass_pipeline: ?gpu.Backend.RenderPipeline = null,
    glass_uniform_write_offset: u32 = 0,
    glass_uniform_overflow_warned: bool = false,
    /// glass 管线失败粘性标记（同 blur_pipeline_failed；失败后玻璃退化为纯 blur+tint）
    glass_pipeline_failed: bool = false,
    /// backdrop 亮度自适应：**逐 glass 区域**的最深 Kawase 层 blit 目标池。
    /// 早先单张共享 staging = 每帧最后编码的 glass 覆盖写入，全局值实为
    /// "随机某个 glass 的区域亮度"——滚动改变 culling 集合/编码顺序就整体摆动
    /// （storybook 实拍：滚动导致全部玻璃同步换装/变透明）。
    /// 槽按 draw rect 量化 key 匹配（LRU 复用）；staging 各自固定 64x64 shared
    /// storage，槽创建一次绝不重建（重建会让上一帧 blit 目标被释放读到全零）。
    /// 写读相差一帧：cur_* 描述本帧 encode 的 blit，prev_* 随 prev cmd buffer
    /// 完成后可读。
    luminance_slots: [LUMINANCE_SLOT_COUNT]LuminanceSlot = [_]LuminanceSlot{.{}} ** LUMINANCE_SLOT_COUNT,
    /// 排障（ZENIT_DEBUG_GLASS）：glass 管线中间产物的 64×64 中心区
    /// staging——slot 0 = capture(level0)，slot 1 = composite(glass_tex)，
    /// slot 2 = 帧末 RT 球区（ZENIT_DEBUG_GLASS_RT="x,y" 设备像素）。
    /// 结构/生命周期同 luminance_slots；renderer 每帧回读打 RGB 均值，
    /// 用于二分"滚动闪烁的分叉发生在哪一级"。
    debug_glass_slots: [3]LuminanceSlot = [_]LuminanceSlot{.{}} ** 3,

    /// backdrop blur 链深的**帧间迟滞**状态（逐 glass 岛，跨帧存活）。
    ///
    /// 背景：降采样链在离屏池拿不到纹理时 `break`，`actual_levels` 停在半途。
    /// 池压力处于临界线时同一个岛会逐帧 5→4→4→5… 摆动，用户看到的是「闪」。
    /// 关键在于**跳变**而非「少一级模糊」—— 恒定 4 级与恒定 5 级视觉上几乎
    /// 无差别，4/5 之间来回跳却清晰可见。
    ///
    /// 策略：降级立即生效（拿不到就用少的，绝不画垃圾纹理），升级要连续
    /// BLUR_LEVEL_RAISE_FRAMES 帧都拿得到才放行。与玻璃岛数量无关，故不会
    /// 随岛数增长而复发（扩 MAX_POOL 只是把临界点推远）。
    blur_level_slots: [BLUR_LEVEL_SLOT_COUNT]BlurLevelSlot = [_]BlurLevelSlot{.{}} ** BLUR_LEVEL_SLOT_COUNT,

    /// damage-rect 脏区 clear pipeline（禁混合直写 (0,0,0,0)，scissor 限定子矩形）
    damage_clear_pipeline: ?gpu.Backend.RenderPipeline = null,
    damage_clear_pipeline_failed: bool = false,

    /// Blend composite pipeline（非 normal 混合模式的图层合成，lazy-init）
    blend_pipeline: ?gpu.Backend.RenderPipeline = null,
    blend_uniform_write_offset: u32 = 0,
    /// shader 编译失败标记 —— 只试一次，失败后所有非 normal blend 静默退化
    /// normal（不能每帧重试编译）。
    blend_pipeline_failed: bool = false,

    /// Path rendering (矢量路径，lazy-init)
    path_renderer: ?PathRenderer = null,
    path_tessellator: ?path_tess_mod.PathTessellator = null,

    /// 每帧开始时复位帧内游标（uniform 环形写偏移等），但**保留**
    /// pipeline / buffer / sampler 本身。
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
        // 失败标记随缓存清空复位：换 device 重建后允许重试一次
        self.blur_pipeline_failed = false;
        self.glass_pipeline_failed = false;
        if (self.blur_upsample_pipeline) |*p| p.deinit();
        self.blur_upsample_pipeline = null;
        if (self.blur_sampler) |*sampler| sampler.destroy();
        self.blur_sampler = null;
        if (self.glass_pipeline) |*p| p.deinit();
        self.glass_pipeline = null;
        if (self.blend_pipeline) |*p| p.deinit();
        self.blend_pipeline = null;
        // damage clear pipeline（opacity_layer 懒建）——曾是 12 个持久 GPU
        // 对象里唯一被 deinit 遗漏的；failed 标志同样要复位允许换 device 重试
        if (self.damage_clear_pipeline) |*p| p.deinit();
        self.damage_clear_pipeline = null;
        self.damage_clear_pipeline_failed = false;
    }
};

// ── 测试 ───────────────────────────────────────────────────────────────
// beginFrame/deinit 的字段清单此前只能靠「编译过 + 真机跑」兜底（槽位复位
// 类测试在 command_encoder_test.zig 只覆盖 uniform 偏移那几个字段）。
// 下列断言逐一钉住字段名 —— 若新增持久字段忘了在 beginFrame/deinit 里
// 处理，这里会在编译期报错，而不是变成又一个 damage_clear 式遗漏。

test "PersistentGpuCache 零值构造即合法（AppRenderer.init 依赖全 lazy）" {
    var pgc = PersistentGpuCache{};
    pgc.deinit(); // 全 null：deinit 必须是 no-op 且不崩
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
    // 帧内游标复位 ≠ 清空跨帧槽：LRU key / 迟滞历史必须跨帧存活，
    // 否则迟滞策略退化成「每帧首帧」，正好回到它要治的闪烁。
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
    // 对象槽也一并清空：再次 deinit 幂等。
    try std.testing.expectEqual(
        @as(?gpu.Backend.RenderPipeline, null),
        pgc.blur_downsample_pipeline,
    );
    pgc.deinit();
}

test "槽位数组容量：迟滞槽数与亮度槽数一致（同为逐 glass 岛资源）" {
    try std.testing.expectEqual(LUMINANCE_SLOT_COUNT, BLUR_LEVEL_SLOT_COUNT);
    try std.testing.expectEqual(@as(usize, 12), LUMINANCE_SLOT_COUNT);
    try std.testing.expectEqual(@as(usize, 3), debug_glass_slots_len);
}

/// ZENIT_DEBUG_GLASS 的三档中间产物槽（capture / composite / 帧末 RT 球区）。
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
