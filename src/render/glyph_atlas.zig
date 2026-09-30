/// Metal Glyph Atlas - GPU 纹理图集管理 (Multi-Page)
///
/// 管理字形在 GPU 纹理中的存储和缓存
/// 使用 Shelf Packing 算法分配纹理空间
/// 支持多页 Atlas + 帧级 GC，彻底消除 resetAtlas 导致的卡顿
const std = @import("std");
const gpu = @import("gpu");
const text = @import("text");
const Font = text.Font;
const GlyphBitmap = text.GlyphBitmap;
const text_trace = @import("trace").text_flicker;

/// 页的像素格式。灰度页与彩色页共用同一个 pages 数组、同一套 page_index
/// 编号（因此不存在"串号"问题：一个 page_index 唯一确定一页及其格式），
/// 但各自独立打包 —— allocateInPages 只会把彩色字形放进彩色页。
pub const PageFormat = enum(u8) {
    /// R8Unorm，1 字节/像素，覆盖率掩码。
    gray,
    /// BGRA8Unorm_sRGB，4 字节/像素，premultiplied 彩色（emoji）。
    color,

    pub fn bytesPerPixel(self: PageFormat) u32 {
        return switch (self) {
            .gray => 1,
            .color => 4,
        };
    }
};

/// 已驱逐但延迟释放的纹理。
///
/// 修一个既存 bug：evictPage 此前是**同步**释放 —— GC 发生在
/// beginFrame，而本帧之前提交的 command buffer 可能仍在 GPU 上执行并引用
/// 该纹理，同步释放等于在飞行中抽掉资源。这里改成 epoch 延迟回收：
/// 摘除时只记录 retire 帧号，等 MAX_FRAMES_IN_FLIGHT 帧后再真正 release。
///
/// 为什么不直接用 src/gpu/resource_pool.zig 的 retire()：那个 pool 只管理
/// 经它 alloc 出来的 handle，而 atlas 的纹理此前由 backend 独立创建，接进去
/// 要改动 atlas 的所有权模型。这里用同样的 epoch
/// 语义做了自洽的最小实现，新增的彩色页与既有灰度页走同一条路径。
const RetiredTexture = struct {
    texture: gpu.Backend.Texture,
    retired_at_frame: u64,
};

/// 单页 Atlas
const AtlasPage = struct {
    texture: gpu.Backend.Texture,
    packer: RectPacker,
    last_used_frame: u64,
    format: PageFormat,
};

/// Glyph Atlas 管理 GPU 纹理图集 (Multi-Page)
/// 模块级累计：因 atlas 页分配失败而被**静默跳过**的字形数。
/// 恒为 0 是健康态。> 0 = 屏幕上出现过逐字丢字（未缓存字形不画、位置留白），
/// 典型诱因是显存/内存压力下纹理创建失败。见 allocateInPages 的注释。
pub var glyphs_dropped_total: u64 = 0;

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    sampler_nearest: ?gpu.Backend.Sampler,
    sampler_linear: ?gpu.Backend.Sampler,
    pages: [MAX_PAGES]?AtlasPage,
    page_count: u32,
    current_frame: u64,
    /// 本帧已执行的“缓存未命中并实际光栅化”次数
    frame_insert_count: u32,
    cache: std.AutoHashMap(GlyphKey, AtlasRegion),
    /// GC 回收页面后递增，通知渲染缓存失效（防止缓存命令引用已释放的纹理页）
    gc_generation: u32 = 0,
    /// 上次执行周期 GC 的帧号（见 maybeCollect）。
    last_gc_frame: u64 = 0,
    /// 已从页表摘除、但可能仍被在飞的 command buffer 引用的纹理。
    /// 见 RetiredTexture / drainRetired。
    retired: [MAX_RETIRED]?RetiredTexture = [_]?RetiredTexture{null} ** MAX_RETIRED,

    pub const ATLAS_SIZE: u32 = 4096;
    pub const MAX_PAGES: u32 = 32;
    /// 页面闲置多少帧后可被回收（~30 秒 @60fps）。
    pub const EVICT_THRESHOLD: u64 = 1800;
    /// 每页字节数：4096×4096 R8 = 16 MiB。
    pub const PAGE_BYTES: u64 = @as(u64, ATLAS_SIZE) * @as(u64, ATLAS_SIZE);
    /// 字节预算。超出即触发 age-based GC。
    ///
    /// 此前**没有**任何预算：MAX_PAGES=32 × 16 MiB = **512 MiB** 才开始驱逐，
    /// 而 EVICT_THRESHOLD 虽已声明却从未被使用（审查报告 P1：
    /// "声明的 eviction threshold 没有真正接入周期 GC"）。
    /// 128 MiB = 8 页，对正常 UI 绰绰有余（实测 storybook 全组件 1 页）。
    pub const BYTE_BUDGET: u64 = 128 * 1024 * 1024;
    /// GC 检查周期（帧）。避免每帧扫描页表。
    pub const GC_INTERVAL_FRAMES: u64 = 120;
    /// 与渲染器的三重缓冲一致：retire 后至少隔这么多帧才真正 release，
    /// 保证在飞的 command buffer 不会引用已释放的纹理。
    pub const MAX_FRAMES_IN_FLIGHT: u64 = 3;
    /// retire 队列容量。一次 GC 最多摘 MAX_PAGES 页，留同等余量。
    pub const MAX_RETIRED: u32 = MAX_PAGES;
    const ATLAS_LOG_ENABLED = false;

    /// 初始化 GlyphAtlas
    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !GlyphAtlas {
        // 创建采样器 — Linear 在缩放时更平滑，减少笔画粗细抖动
        var sampler_linear = device.createSampler(allocator, .{
            .label = "Zenit.Text.GlyphAtlas.Linear",
            .min_filter = .linear,
            .mag_filter = .linear,
            .address_mode_u = .clamp_to_border,
            .address_mode_v = .clamp_to_border,
        }) catch return error.SamplerCreationFailed;

        // 创建采样器 — Nearest 保持 1:1 时的锐利度
        const sampler_nearest = device.createSampler(allocator, .{
            .label = "Zenit.Text.GlyphAtlas.Nearest",
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .address_mode_u = .clamp_to_border,
            .address_mode_v = .clamp_to_border,
        }) catch {
            sampler_linear.destroy();
            return error.SamplerCreationFailed;
        };

        var self = GlyphAtlas{
            .allocator = allocator,
            .device = device,
            .sampler_nearest = sampler_nearest,
            .sampler_linear = sampler_linear,
            .pages = [_]?AtlasPage{null} ** MAX_PAGES,
            .page_count = 0,
            .current_frame = 0,
            .frame_insert_count = 0,
            .cache = std.AutoHashMap(GlyphKey, AtlasRegion).init(allocator),
        };

        // 创建第一页（灰度 —— 绝大多数文本走这条路；彩色页按需惰性创建）
        try self.addNewPage(.gray);

        if (ATLAS_LOG_ENABLED) {
            std.log.info("[GlyphAtlas] Created multi-page atlas (page 0: {d}x{d})", .{ ATLAS_SIZE, ATLAS_SIZE });
        }

        return self;
    }

    /// 销毁
    pub fn deinit(self: *GlyphAtlas) void {
        self.cache.deinit();
        if (self.sampler_nearest) |*sampler| sampler.destroy();
        if (self.sampler_linear) |*sampler| sampler.destroy();
        for (self.pages[0..self.page_count]) |*maybe_page| {
            if (maybe_page.*) |*page| page.texture.destroy();
        }
        // 关窗路径：此时不再有新的 command buffer，retire 队列必须无条件排空，
        // 否则未过安全期的纹理会随 atlas 一起泄漏。
        for (&self.retired) |*slot| {
            if (slot.*) |*entry| {
                entry.texture.destroy();
                slot.* = null;
            }
        }
        if (ATLAS_LOG_ENABLED) {
            std.log.info("[GlyphAtlas] Destroyed ({d} pages)", .{self.page_count});
        }
    }

    /// 新增一页 Atlas
    /// 不做全量清零（避免 16MB memset 开销），靠 RectPacker 的 padding 保证安全
    fn addNewPage(self: *GlyphAtlas, format: PageFormat) !void {
        // 已达上限 → 回收最老页腾出空间（子像素降维后此分支极少触发）。
        // 驱逐失败（所有页本帧都在用）必须报错：继续写 pages[page_count]
        // 会越界，且驱逐 in-flight 页在 retire 队列满时是 use-after-free。
        if (self.page_count >= MAX_PAGES) {
            if (!self.forceEvictOldestPage()) return error.AtlasFull;
        }

        const texture = self.device.createTexture(self.allocator, .{
            .label = switch (format) {
                .gray => "Zenit.Text.GlyphAtlas.Gray",
                .color => "Zenit.Text.GlyphAtlas.Color",
            },
            .size = .{ .width = ATLAS_SIZE, .height = ATLAS_SIZE },
            .format = switch (format) {
                .gray => .r8_unorm,
                // _sRGB：CoreGraphics 写进来的 emoji 像素是 sRGB 编码值，而
                // layer 是 BGRA8Unorm_sRGB（输出时再做 linear→sRGB 编码）。
                // 用无 _sRGB 的格式采样 = 不解码就当 linear 用，等于编码两次，
                // 中间调被抬亮 —— 表现为 emoji 掉色/发白（纯色块几乎看不出，
                // 中间调最明显）。灰度页是覆盖率不是颜色，必须保持 R8Unorm。
                .color => .bgra8_unorm_srgb,
            },
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .memory = .host_upload,
        }) catch return error.TextureCreationFailed;

        // 注意：不做全量清零。Metal Shared 存储模式下新纹理内容是未定义的，
        // 但 RectPacker 的 2px padding 保证了 glyph 之间不会采样到邻居。
        // 对于 Linear 采样在纹理边缘的情况，ClampToZero 采样模式兜底。

        const page_idx = self.page_count;
        self.pages[page_idx] = AtlasPage{
            .texture = texture,
            .packer = RectPacker.init(ATLAS_SIZE, ATLAS_SIZE),
            .last_used_frame = self.current_frame,
            .format = format,
        };
        self.page_count += 1;

        if (ATLAS_LOG_ENABLED) {
            std.log.info("[GlyphAtlas] New page {d} created (total: {d}, cache: {d})", .{ page_idx, self.page_count, self.cache.count() });
        }
    }

    /// 当前占用字节数（诊断 / 预算判定）。
    /// 彩色页是 BGRA8，每像素 4 字节 —— 必须按页格式加权，否则 GC 预算
    /// 会把 64 MiB 的彩色页当成 16 MiB 记账，形成 4× 的隐形超支。
    pub fn bytesUsed(self: *const GlyphAtlas) u64 {
        var total: u64 = 0;
        for (self.pages[0..self.page_count]) |maybe_page| {
            const page = maybe_page orelse continue;
            total += PAGE_BYTES * page.format.bytesPerPixel();
        }
        return total;
    }

    /// 周期性 age-based GC —— 由 beginFrame 驱动。
    ///
    /// 触发条件：距上次检查满 GC_INTERVAL_FRAMES **且**已超字节预算。
    /// 回收对象：`last_used_frame` 距今超过 EVICT_THRESHOLD 的页。
    /// 永远保留至少 1 页（避免刚回收就重建的抖动）。
    ///
    /// 这补上了此前完全缺失的一环：EVICT_THRESHOLD 声明了但没有任何调用者，
    /// 实际只有 page_count 撞到 MAX_PAGES(=512 MiB) 才会驱逐。
    pub fn maybeCollect(self: *GlyphAtlas) void {
        // 先排空已过安全期的 retire 纹理 —— 必须在下面的 early return 之前，
        // 否则不触发 GC 的帧永远不会真正释放上一轮驱逐的纹理（那就是泄漏）。
        self.drainRetired();

        if (self.current_frame < self.last_gc_frame + GC_INTERVAL_FRAMES) return;
        self.last_gc_frame = self.current_frame;
        if (self.bytesUsed() <= BYTE_BUDGET) return;

        var idx: u32 = 0;
        while (idx < self.page_count) : (idx += 1) {
            if (self.page_count <= 1) break;
            const page = self.pages[idx] orelse continue;
            const age = self.current_frame -| page.last_used_frame;
            if (age < EVICT_THRESHOLD) continue;
            self.evictPage(idx);
            self.gc_generation +%= 1;
            if (self.bytesUsed() <= BYTE_BUDGET) break;
        }
    }

    /// 强制回收最老的页（page_count 达上限时调用）。
    /// 只考虑**本帧未使用**的页：last_used_frame == current_frame 的页可能
    /// 正被本帧已编码的 draw 引用，retire 队列有 in-flight 安全期兜底，但
    /// 队列满退化为同步释放时就是 use-after-free。全部页都在本帧用过 →
    /// 返回 false，caller 放弃加页（跳过 glyph，比崩溃/花屏安全）。
    fn forceEvictOldestPage(self: *GlyphAtlas) bool {
        var oldest_idx: ?u32 = null;
        var oldest_frame: u64 = std.math.maxInt(u64);
        for (self.pages[0..self.page_count], 0..) |maybe_page, i| {
            if (maybe_page) |page| {
                if (page.last_used_frame >= self.current_frame) continue;
                if (page.last_used_frame < oldest_frame) {
                    oldest_frame = page.last_used_frame;
                    oldest_idx = @intCast(i);
                }
            }
        }
        const idx = oldest_idx orelse {
            std.log.warn("[GlyphAtlas] page limit reached but every page was used this frame; refusing eviction", .{});
            return false;
        };
        const last_idx = self.page_count - 1;
        if (idx != last_idx) {
            // evictPage compacts by moving the last page into `idx`. Even when
            // the victim is cold, moving a last page already referenced by
            // this frame's encoded instances invalidates their baked u8 page
            // indices. Only swap two pages that are both unused this frame,
            // then evict the last slot without renumbering any live instance.
            const last_page = self.pages[last_idx] orelse return false;
            if (last_page.last_used_frame >= self.current_frame) {
                std.log.warn("[GlyphAtlas] page limit reached but compacting would renumber a page used this frame; refusing eviction", .{});
                return false;
            }
            std.mem.swap(?AtlasPage, &self.pages[idx], &self.pages[last_idx]);
            var cache_iter = self.cache.iterator();
            while (cache_iter.next()) |entry| {
                if (entry.value_ptr.page_index == @as(u8, @intCast(idx))) {
                    entry.value_ptr.page_index = @intCast(last_idx);
                } else if (entry.value_ptr.page_index == @as(u8, @intCast(last_idx))) {
                    entry.value_ptr.page_index = @intCast(idx);
                }
            }
        }
        self.evictPage(last_idx);
        self.gc_generation +%= 1;
        return true;
    }

    /// 把纹理推入延迟释放队列。队列满时（极端情况）退化为同步释放 ——
    /// 那仍然不比修复前更糟，且有日志可查。
    fn retireTexture(self: *GlyphAtlas, texture: gpu.Backend.Texture) void {
        var oldest_idx: usize = 0;
        var oldest_frame: u64 = std.math.maxInt(u64);
        for (&self.retired, 0..) |*slot, i| {
            const entry = slot.* orelse {
                slot.* = .{ .texture = texture, .retired_at_frame = self.current_frame };
                return;
            };
            if (entry.retired_at_frame < oldest_frame) {
                oldest_frame = entry.retired_at_frame;
                oldest_idx = i;
            }
        }
        // 队列满：同步释放**最老**的 retire 条目给新纹理腾位 —— 它离安全期
        // 最近；同步释放刚驱逐的新纹理（几乎必然仍 in-flight）风险最大。
        std.log.warn("[GlyphAtlas] retire queue full, releasing oldest retired texture synchronously", .{});
        var victim = self.retired[oldest_idx].?;
        victim.texture.destroy();
        self.retired[oldest_idx] = .{ .texture = texture, .retired_at_frame = self.current_frame };
    }

    /// 释放已过安全期的 retire 纹理。由 maybeCollect（即每帧 beginFrame）驱动。
    fn drainRetired(self: *GlyphAtlas) void {
        for (&self.retired) |*slot| {
            const entry = if (slot.*) |*value| value else continue;
            if (self.current_frame -| entry.retired_at_frame < MAX_FRAMES_IN_FLIGHT) continue;
            entry.texture.destroy();
            slot.* = null;
        }
    }

    /// 回收指定页
    fn evictPage(self: *GlyphAtlas, page_idx: u32) void {
        const page = self.pages[page_idx] orelse return;

        // 从 cache 中删除所有指向该页的条目（动态数组，一次收集完）
        var keys_to_remove = std.ArrayList(GlyphKey){};
        defer keys_to_remove.deinit(self.allocator);
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.page_index == @as(u8, @intCast(page_idx))) {
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }
        for (keys_to_remove.items) |key| {
            _ = self.cache.remove(key);
        }

        // 延迟释放纹理（不能同步 release —— 在飞的 command buffer 可能仍引用它）
        self.retireTexture(page.texture);

        // 将最后一页 swap 到此位置（compact 数组）
        const last_idx = self.page_count - 1;
        if (page_idx != last_idx) {
            self.pages[page_idx] = self.pages[last_idx];
            // 更新 cache 中被 swap 页的 page_index
            var cache_iter = self.cache.iterator();
            while (cache_iter.next()) |entry| {
                if (entry.value_ptr.page_index == @as(u8, @intCast(last_idx))) {
                    entry.value_ptr.page_index = @intCast(page_idx);
                }
            }
        }
        self.pages[last_idx] = null;
        self.page_count -= 1;

        if (ATLAS_LOG_ENABLED) {
            std.log.info("[GlyphAtlas] GC: reclaimed page {d} (remaining: {d}, cache: {d})", .{ page_idx, self.page_count, self.cache.count() });
        }
    }

    /// 在当前页或新页中分配空间
    fn allocateInPages(self: *GlyphAtlas, w: u32, h: u32, format: PageFormat) ?struct { rect: RectPacker.Rect, page_idx: u8 } {
        // 从后往前找**同格式**的最热页。灰度与彩色页混在同一个数组里，
        // 只看最后一页会在两种格式交替出现时反复新建页。
        var probe = self.page_count;
        while (probe > 0) {
            probe -= 1;
            if (self.pages[probe]) |*page| {
                if (page.format != format) continue;
                if (page.packer.allocate(w, h)) |rect| {
                    page.last_used_frame = self.current_frame;
                    return .{ .rect = rect, .page_idx = @intCast(probe) };
                } else |_| {
                    // 这页满了 —— 同格式只保留最热一页作为分配目标，
                    // 满了就直接新建，不再回溯更老的页（与原行为一致）。
                    break;
                }
            }
        }

        // 无可用同格式页 → 新增一页
        self.addNewPage(format) catch {
            // 纹理创建失败（典型：显存/内存压力）→ 返回 null，调用方跳过此 glyph。
            //
            // ⚠️ 这条路径的用户可见后果是**逐字丢字**：未缓存的字形（CJK 长尾）
            // 该帧直接不画、位置留白，压力缓解后自愈 → 表现为闪烁。ASCII 因为
            // 早已驻留第 0 页而不受影响。此前这里完全静默，线上发生过疑似此症状
            // 却无从取证 —— 必须留下日志（限频，压力期可能每帧成百上千次）。
            glyphs_dropped_total += 1;
            if (glyphs_dropped_total == 1 or glyphs_dropped_total % 256 == 0) {
                std.log.warn("[GlyphAtlas] atlas page alloc failed; dropping glyphs (total dropped: {d}, pages: {d})", .{ glyphs_dropped_total, self.page_count });
            }
            return null;
        };
        const new_page_idx = self.page_count - 1;
        if (self.pages[new_page_idx]) |*page| {
            const rect = page.packer.allocate(w, h) catch {
                return null;
            };
            page.last_used_frame = self.current_frame;
            return .{ .rect = rect, .page_idx = @intCast(new_page_idx) };
        }
        return null;
    }

    /// 获取或插入字形到图集
    pub fn getOrInsert(
        self: *GlyphAtlas,
        font: *Font,
        glyph_index: u32,
    ) !AtlasRegion {
        const key = GlyphKey{
            .font_ptr = @intFromPtr(font),
            .glyph_index = glyph_index,
            .scale_q = quantizeScale(font.scale_factor),
        };

        // 检查缓存
        if (self.cache.get(key)) |region| {
            // 更新页的 last_used_frame
            if (region.page_index < self.page_count) {
                if (self.pages[region.page_index]) |*page| {
                    page.last_used_frame = self.current_frame;
                }
            }
            return region;
        }

        self.frame_insert_count += 1;

        // 缓存未命中: 光栅化并上传
        const bitmap = try font.rasterizeGlyph(glyph_index);
        defer bitmap.deinit(self.allocator);

        // 空字形 (如空格)
        if (bitmap.width == 0 or bitmap.height == 0) {
            const region = AtlasRegion{
                .uv_min = .{ 0, 0 },
                .uv_max = .{ 0, 0 },
                .bearing_x = bitmap.bearing_x,
                .bearing_y = bitmap.bearing_y,
                .advance = bitmap.advance,
                .width = 0,
                .height = 0,
                .page_index = 0,
            };
            try self.cache.put(key, region);
            return region;
        }

        const page_format: PageFormat = if (bitmap.is_color) .color else .gray;

        // 分配空间（多页），null 表示无法分配（极端情况）→ 返回空 region
        const alloc_result = self.allocateInPages(bitmap.width, bitmap.height, page_format) orelse {
            text_trace.log(
                self.current_frame,
                "atlas-alloc-failed glyph={d} page_count={d} cache={d} bitmap={d}x{d}",
                .{
                    glyph_index,
                    self.page_count,
                    self.cache.count(),
                    bitmap.width,
                    bitmap.height,
                },
            );
            const empty = AtlasRegion{
                .uv_min = .{ 0, 0 },
                .uv_max = .{ 0, 0 },
                .bearing_x = bitmap.bearing_x,
                .bearing_y = bitmap.bearing_y,
                .advance = bitmap.advance,
                .width = 0,
                .height = 0,
                .page_index = 0,
            };
            return empty;
        };

        // 上传到 GPU
        try self.uploadToTexture(alloc_result.page_idx, bitmap, alloc_result.rect);

        // 计算 UV 坐标
        const region = AtlasRegion{
            .uv_min = .{
                @as(f32, @floatFromInt(alloc_result.rect.x)) / @as(f32, @floatFromInt(ATLAS_SIZE)),
                @as(f32, @floatFromInt(alloc_result.rect.y)) / @as(f32, @floatFromInt(ATLAS_SIZE)),
            },
            .uv_max = .{
                @as(f32, @floatFromInt(alloc_result.rect.x + bitmap.width)) / @as(f32, @floatFromInt(ATLAS_SIZE)),
                @as(f32, @floatFromInt(alloc_result.rect.y + bitmap.height)) / @as(f32, @floatFromInt(ATLAS_SIZE)),
            },
            .bearing_x = bitmap.bearing_x,
            .bearing_y = bitmap.bearing_y,
            .advance = bitmap.advance,
            .width = bitmap.width,
            .height = bitmap.height,
            .page_index = alloc_result.page_idx,
            .is_color = bitmap.is_color,
        };

        try self.cache.put(key, region);
        return region;
    }

    /// R6: 获取或插入字形（带子像素偏移）
    pub fn getOrInsertSubpixel(
        self: *GlyphAtlas,
        font: *Font,
        glyph_index: u32,
        subpixel_bin_packed: u8,
    ) !AtlasRegion {
        // **先查缓存，再问 hasColorGlyphs。**
        //
        // hasColorGlyphs 每次调用都进 CoreText（CTFontGetSymbolicTraits +
        // 最多 3 次 CTFontCopyTable —— 非彩色字体必然 fall through 把三张表
        // 都查一遍），而这个函数在滚动时每 glyph 每帧都会被 emit 路径调用。
        // 放在缓存查找之前，等于给全部命中帧白付一次 CoreText 查表；采样里
        // CTFontCopyTable 直接出现在 emitGlyphInstance 的热路径上。
        // 非彩色字体命中后完全不触 CoreText；彩色字体（emoji，量极小）的
        // 条目存在 bin=0 键下，这里必然 miss、照旧走下面的降级分支。
        const key = GlyphKey{
            .font_ptr = @intFromPtr(font),
            .glyph_index = glyph_index,
            .subpixel_bin = subpixel_bin_packed,
            .scale_q = quantizeScale(font.scale_factor),
        };

        if (self.cache.get(key)) |region| {
            // 更新页的 last_used_frame
            if (region.page_index < self.page_count) {
                if (self.pages[region.page_index]) |*page| {
                    page.last_used_frame = self.current_frame;
                }
            }
            return region;
        }

        // 子像素分箱对彩色字形没有意义：emoji 是位图/分层矢量，没有需要靠
        // 亚像素相位改善的细笔画，分箱只会把同一个 emoji 复制 4 份进 4×
        // 内存的 BGRA 页。直接降级到无偏移路径（bin=0），与 getOrInsert 共用
        // 同一份缓存条目。
        if (font.hasColorGlyphs()) {
            return self.getOrInsert(font, glyph_index);
        }

        self.frame_insert_count += 1;

        // 从 packed bin 提取 x/y 偏移
        const x_bin: u4 = @intCast(subpixel_bin_packed >> 4);
        const y_bin: u4 = @intCast(subpixel_bin_packed & 0x0F);
        const offset_x = subpixelOffset(x_bin);
        const offset_y = subpixelOffset(y_bin);

        const bitmap = try font.rasterizeGlyphSubpixel(glyph_index, offset_x, offset_y);
        defer bitmap.deinit(self.allocator);

        if (bitmap.width == 0 or bitmap.height == 0) {
            const region = AtlasRegion{
                .uv_min = .{ 0, 0 },
                .uv_max = .{ 0, 0 },
                .bearing_x = bitmap.bearing_x,
                .bearing_y = bitmap.bearing_y,
                .advance = bitmap.advance,
                .width = 0,
                .height = 0,
                .page_index = 0,
            };
            try self.cache.put(key, region);
            return region;
        }

        const page_format: PageFormat = if (bitmap.is_color) .color else .gray;

        // 分配空间（多页），null → 返回空 region
        const alloc_result = self.allocateInPages(bitmap.width, bitmap.height, page_format) orelse {
            text_trace.log(
                self.current_frame,
                "atlas-subpixel-alloc-failed glyph={d} bin=0x{x} page_count={d} cache={d} bitmap={d}x{d}",
                .{
                    glyph_index,
                    subpixel_bin_packed,
                    self.page_count,
                    self.cache.count(),
                    bitmap.width,
                    bitmap.height,
                },
            );
            return AtlasRegion{
                .uv_min = .{ 0, 0 },
                .uv_max = .{ 0, 0 },
                .bearing_x = bitmap.bearing_x,
                .bearing_y = bitmap.bearing_y,
                .advance = bitmap.advance,
                .width = 0,
                .height = 0,
                .page_index = 0,
            };
        };
        try self.uploadToTexture(alloc_result.page_idx, bitmap, alloc_result.rect);

        const region = AtlasRegion{
            .uv_min = .{
                @as(f32, @floatFromInt(alloc_result.rect.x)) / @as(f32, @floatFromInt(ATLAS_SIZE)),
                @as(f32, @floatFromInt(alloc_result.rect.y)) / @as(f32, @floatFromInt(ATLAS_SIZE)),
            },
            .uv_max = .{
                @as(f32, @floatFromInt(alloc_result.rect.x + bitmap.width)) / @as(f32, @floatFromInt(ATLAS_SIZE)),
                @as(f32, @floatFromInt(alloc_result.rect.y + bitmap.height)) / @as(f32, @floatFromInt(ATLAS_SIZE)),
            },
            .bearing_x = bitmap.bearing_x,
            .bearing_y = bitmap.bearing_y,
            .advance = bitmap.advance,
            .width = bitmap.width,
            .height = bitmap.height,
            .page_index = alloc_result.page_idx,
        };

        try self.cache.put(key, region);
        return region;
    }

    /// 上传位图数据到指定页的纹理。
    ///
    /// ⚠ 失败必须往上传，**不能吞**：页纹理是刻意不清零的（见 ensurePage
    /// 的注释「新纹理内容是未定义的」），而调用方在上传之后会把 region 连同
    /// 真实 UV 写进 cache（键含 font_ptr/glyph/scale，命中即短路，永不重传）。
    /// 一旦上传失败还照常缓存，那个字形就会**每帧采样未定义的 GPU 内存**，
    /// 表现为永久花字，且没有任何日志 —— 是典型的「吞掉真错误导致 UI 静默
    /// 损坏」。writeRegion 的失败是真实可达的：bitmap 尺寸字段与像素缓冲长度
    /// 不一致时返回 error.InvalidTextureData（gpu/metal/resources.zig）。
    fn uploadToTexture(self: *GlyphAtlas, page_idx: u8, bitmap: GlyphBitmap, rect: RectPacker.Rect) !void {
        if (page_idx < self.page_count) {
            if (self.pages[page_idx]) |*page| {
                // BGRA 页每像素 4 字节 —— bytes_per_row 用 width 会让 Metal
                // 按 1/4 行宽读取，画面变成斜切的乱码。
                try page.texture.writeRegion(
                    0,
                    rect.x,
                    rect.y,
                    bitmap.width,
                    bitmap.height,
                    bitmap.pixels,
                    bitmap.width * bitmap.bytesPerPixel(),
                );
            }
        }
    }

    /// 获取缓存大小
    /// 摘除某个 Font 指针名下的全部缓存条目。
    ///
    /// GlyphKey 以 `font_ptr`（Font 的堆地址）为身份。Font 被销毁后，
    /// c_allocator / smp_allocator 会立刻把同一地址分给下一个 Font —— 若旧
    /// 条目还在，新字体会以相同键命中旧字体的位图，画出**别的字体的字形**。
    /// 所以任何在 atlas 仍存活时销毁 Font 的路径（典型：fallback wrapper 驱逐）
    /// 都必须先调这里。只删 cache 条目，不动页：页内空间由 age-based GC 回收，
    /// 在飞 command buffer 仍可安全采样旧 region。
    ///
    /// 迭代中 removeByPtr 是安全的：std.HashMap 删除只打 tombstone、不搬移条目。
    pub fn forgetFont(self: *GlyphAtlas, font_ptr: usize) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.key_ptr.font_ptr == font_ptr) self.cache.removeByPtr(entry.key_ptr);
        }
    }

    pub fn getCacheSize(self: *GlyphAtlas) usize {
        return self.cache.count();
    }

    /// 获取指定页的纹理
    pub fn getPageTexture(self: *GlyphAtlas, page_idx: u8) ?gpu.Backend.TextureBinding {
        if (page_idx < self.page_count) {
            if (self.pages[page_idx]) |page| {
                return page.texture.binding();
            }
        }
        return null;
    }

    /// 获取指定页的像素格式（渲染侧据此决定绑到灰度还是彩色纹理槽）
    pub fn getPageFormat(self: *GlyphAtlas, page_idx: u8) ?PageFormat {
        if (page_idx < self.page_count) {
            if (self.pages[page_idx]) |page| return page.format;
        }
        return null;
    }

    /// 获取页数
    pub fn getPageCount(self: *GlyphAtlas) u32 {
        return self.page_count;
    }

    /// 获取采样器
    pub fn getSamplerNearest(self: *GlyphAtlas) ?*gpu.Backend.Sampler {
        return if (self.sampler_nearest) |*sampler| sampler else null;
    }

    pub fn getSamplerLinear(self: *GlyphAtlas) ?*gpu.Backend.Sampler {
        return if (self.sampler_linear) |*sampler| sampler else null;
    }
};

/// 字形在图集中的位置和度量信息
pub const AtlasRegion = struct {
    uv_min: [2]f32,
    uv_max: [2]f32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i32,
    width: u32,
    height: u32,
    page_index: u8,
    /// true = 该 region 位于 BGRA8 彩色页，shader 必须直接输出采样到的 RGBA，
    /// 不能乘文字颜色（emoji 自带颜色）。
    is_color: bool = false,
};

/// 字形缓存键
const GlyphKey = struct {
    font_ptr: usize,
    glyph_index: u32,
    /// R6: 子像素 bin (高 4 位 = x bin, 低 4 位 = y bin, 各 0-3)
    /// 0 = 无子像素偏移 (兼容旧 API)
    subpixel_bin: u8 = 0,
    /// HiDPI：量化后的 `Font.scale_factor`（见 quantizeScale）。
    ///
    /// 必须入键。`Font.scale_factor` 是**就地可变**字段，`setScaleFactor`
    /// 不改变 Font 指针 —— 所以若键里没有 scale，把窗口从 Retina 拖到非
    /// Retina（或反之）后，同一 font_ptr 的已缓存字形会以完全相同的 key
    /// 命中，永远不会按新 scale 重新光栅化：
    ///   1x → 2x：复用半分辨率位图 = 糊；
    ///   2x → 1x：复用双倍分辨率位图 = 尺寸/bearing 错位（bearing 在
    ///            text_renderer 里按**当前** scale_factor 回除）。
    scale_q: u32 = quantizeScale(1.0),
};

/// 把 f32 scale 量化成可安全用作 AutoHashMap 键的整数（1/100 精度）。
///
/// 为什么量化而不是直接放 f32：AutoHashMap 对键做逐位（bitwise）哈希与
/// 相等比较，浮点的 -0.0/+0.0、NaN、以及同一逻辑 scale 经不同浮点运算
/// 路径得到的最后一位差异，都会产生"逻辑相同但键不等"的幽灵条目 ——
/// 那是缓存永久 miss + 图集无限增长，比原 bug 更糟。
///
/// 为什么是 1/100 精度而不是固定档位（如只认 1x/2x）：macOS
/// `backingScaleFactor` 实践中虽多为 1.0/2.0，但缩放分辨率模式与外接屏
/// 可以给出其它值；固定档位会把不同的真实 scale 静默折叠到同一档，等于
/// 把本 bug 换个形式保留。1/100 对所有现实取值都无损，而远粗于浮点噪声。
pub fn quantizeScale(scale: f32) u32 {
    const clamped = @max(0.01, @min(scale, 64.0));
    return @intFromFloat(@round(clamped * 100.0));
}

/// R6: 子像素 bin 数量 (每轴 4 个 = 16 个变体)
pub const SUBPIXEL_BINS: u32 = 4;

/// R6: 计算子像素 bin
pub fn subpixelBin(fractional: f32) u4 {
    const clamped = @max(0.0, @min(fractional, 0.999));
    return @intFromFloat(clamped * @as(f32, @floatFromInt(SUBPIXEL_BINS)));
}

/// R6: 从 bin 值反算子像素偏移 (bin 中心值)
pub fn subpixelOffset(bin: u4) f32 {
    return (@as(f32, @floatFromInt(bin)) + 0.5) / @as(f32, @floatFromInt(SUBPIXEL_BINS));
}

/// R6: 打包 x/y bin 到 u8
pub fn packSubpixelBin(x_bin: u4, y_bin: u4) u8 {
    return (@as(u8, x_bin) << 4) | @as(u8, y_bin);
}

/// 简单的矩形打包器 (Shelf packing algorithm)
const RectPacker = struct {
    width: u32,
    height: u32,
    current_y: u32,
    current_x: u32,
    current_row_height: u32,

    pub const Rect = struct {
        x: u32,
        y: u32,
    };

    pub fn init(width: u32, height: u32) RectPacker {
        return .{
            .width = width,
            .height = height,
            .current_y = 0,
            .current_x = 0,
            .current_row_height = 0,
        };
    }

    pub fn allocate(self: *RectPacker, w: u32, h: u32) !Rect {
        // 添加 1px padding 避免纹理采样出血
        if (self.width < 2 or self.height < 2) return error.AtlasFull;
        if (w > self.width - 2 or h > self.height - 2) return error.AtlasFull;
        const padded_w = w + 2;
        const padded_h = h + 2;

        // 换行检查
        if (self.current_x > self.width or padded_w > self.width - self.current_x) {
            self.current_x = 0;
            self.current_y = std.math.add(u32, self.current_y, self.current_row_height) catch return error.AtlasFull;
            self.current_row_height = 0;
        }

        // 空间不足
        if (self.current_y > self.height or padded_h > self.height - self.current_y) {
            return error.AtlasFull;
        }

        const result = Rect{ .x = self.current_x + 1, .y = self.current_y + 1 }; // +1 for padding

        self.current_x += padded_w;
        self.current_row_height = @max(self.current_row_height, padded_h);

        return result;
    }
};

test "RectPacker rejects dimensions that would overflow padding" {
    var packer = RectPacker.init(4096, 4096);
    try std.testing.expectError(error.AtlasFull, packer.allocate(std.math.maxInt(u32), 1));
    try std.testing.expectError(error.AtlasFull, packer.allocate(1, std.math.maxInt(u32)));
}

test "color glyph detection: emoji font yes, text fonts no" {
    const testing = @import("std").testing;
    var fs = try text.FontSystem.init(testing.allocator);
    defer fs.deinit();

    // Apple Color Emoji 有 sbix 表 → 必须判为彩色，否则 emoji 会被光栅化成
    // 单通道覆盖率掩码（灰块），颜色在光栅化那一刻就丢了。
    const emoji = try fs.findFont(.{ .family = "Apple Color Emoji", .size = 32 });
    defer emoji.deinit();
    try testing.expect(emoji.hasColorGlyphs());

    // 普通文本字体必须判为非彩色，否则会白白走 4× 内存的 BGRA 页，
    // 并丢掉子像素抗锯齿。
    const helvetica = try fs.findFont(.{ .family = "Helvetica", .size = 32 });
    defer helvetica.deinit();
    try testing.expect(!helvetica.hasColorGlyphs());

    const menlo = try fs.findFont(.{ .family = "Menlo", .size = 32 });
    defer menlo.deinit();
    try testing.expect(!menlo.hasColorGlyphs());
}

test "atlas page format: bytes-per-pixel drives budget accounting" {
    const testing = @import("std").testing;
    // 彩色页是 BGRA8 = 4 字节/像素。bytesUsed 若不按格式加权，一页 64 MiB
    // 会被当成 16 MiB 记账，GC 预算形成 4× 隐形超支。
    try testing.expectEqual(@as(u32, 1), PageFormat.gray.bytesPerPixel());
    try testing.expectEqual(@as(u32, 4), PageFormat.color.bytesPerPixel());
}

test "atlas retire queue: 延迟释放窗口覆盖三重缓冲" {
    const testing = @import("std").testing;
    const A = GlyphAtlas;
    // 延迟窗口必须 >= 在飞帧数，否则同步释放的既有 bug 依然存在。
    try testing.expect(A.MAX_FRAMES_IN_FLIGHT >= 3);
    // retire 队列要装得下一次 GC 摘掉的所有页。
    try testing.expect(A.MAX_RETIRED >= A.MAX_PAGES);
}

test "glyph atlas: GC policy constants are self-consistent" {
    const testing = @import("std").testing;
    const A = GlyphAtlas;

    // 预算必须小于硬上限，否则 GC 永远不触发 —— 那正是修复前的状态：
    // 只有 page_count 撞到 MAX_PAGES（32 × 16 MiB = 512 MiB）才驱逐，
    // EVICT_THRESHOLD 声明了却无人调用。
    const hard_cap_bytes: u64 = @as(u64, A.MAX_PAGES) * A.PAGE_BYTES;
    try testing.expect(A.BYTE_BUDGET < hard_cap_bytes);

    // 预算至少要容得下若干页，否则每次 GC 都会把工作集清空导致抖动。
    try testing.expect(A.BYTE_BUDGET >= 4 * A.PAGE_BYTES);

    // 页大小换算正确：4096×4096 R8 = 16 MiB。
    try testing.expectEqual(@as(u64, 16 * 1024 * 1024), A.PAGE_BYTES);

    // GC 间隔与老化阈值都必须为正，否则要么每帧扫描、要么立刻驱逐活跃页。
    try testing.expect(A.GC_INTERVAL_FRAMES > 0);
    try testing.expect(A.EVICT_THRESHOLD > A.GC_INTERVAL_FRAMES);
}

// ══════════════════════════════════════════════════════════════════════
// HiDPI (Retina) 审计回归测试 —— 2026-07-31
//
// 背景：此前全仓 **零** HiDPI 测试覆盖（grep scale/dpi/retina 只命中
// transform scale 与 theme spacing scale，都与设备像素比无关）。
// 下面两条把审计实测到的事实钉住，防回退。
// ══════════════════════════════════════════════════════════════════════

test "HiDPI: 字形在 2x 下按物理像素光栅化（非逻辑尺寸再由 GPU 放大）" {
    const testing = @import("std").testing;
    // 这是最常见的 HiDPI bug：Retina 下文字糊，根因是光栅化用逻辑尺寸、
    // 采样时被 GPU 上采样。本测试走**真实 CoreText 路径**实测位图尺寸。
    var fs = try text.FontSystem.init(testing.allocator);
    defer fs.deinit();

    const f1 = try fs.findFont(.{ .family = "Helvetica", .size = 32 });
    defer f1.deinit();
    const f2 = try fs.findFont(.{ .family = "Helvetica", .size = 32 });
    defer f2.deinit();

    f1.setScaleFactor(1.0);
    f2.setScaleFactor(2.0);

    const g = f1.glyphIndexForCodepoint('M');
    try testing.expect(g != 0);

    var b1 = try f1.rasterizeGlyph(g);
    defer b1.deinit(testing.allocator);
    var b2 = try f2.rasterizeGlyph(g);
    defer b2.deinit(testing.allocator);

    try testing.expect(b1.width > 0 and b1.height > 0);

    // coretext_bridge.m 的公式是 ceil(bbox * scale + subpixel) + 2（2px padding），
    // 所以 2x 位图 ≈ 2 × 1x 位图，但因 padding/ceil 不是严格整倍。
    // 判据：必须显著大于 1x（排除"没按 scale 光栅化"），且不超过 2 倍太多。
    const w1: f32 = @floatFromInt(b1.width);
    const w2: f32 = @floatFromInt(b2.width);
    const h1: f32 = @floatFromInt(b1.height);
    const h2: f32 = @floatFromInt(b2.height);
    const ratio_w = w2 / w1;
    const ratio_h = h2 / h1;

    // 1.7 下界：若 2x 与 1x 尺寸相同（ratio≈1.0），说明 scale_factor 根本
    // 没传进 CoreText 光栅化 —— 那就是 Retina 糊字的经典 bug。
    // 实测（2026-07-31，Helvetica 'M' @32pt）：1x=24×25px，2x=46×48px，
    // ratio=1.917/1.920（差的那点正是常数 +2px padding）。
    try testing.expect(ratio_w > 1.7);
    try testing.expect(ratio_h > 1.7);
    // 上界防"重复乘 scale"（4x）。
    try testing.expect(ratio_w < 2.4);
    try testing.expect(ratio_h < 2.4);
}

// 上面那条「GlyphKey 不含 scale（已知缺陷）」的锁定测试已按其自身注释的
// 指示删除 —— 缺陷已修（GlyphKey.scale_q）。下面三条是替代的正向测试。

test "HiDPI: 不同 scale 必须产生不同 GlyphKey（动态 scale 变化不再命中过期位图）" {
    const testing = @import("std").testing;
    // 这是上一条缺陷锁定测试的正向替代。`Font.scale_factor` 就地可变、
    // setScaleFactor 不改变 Font 指针，所以 scale 必须自己进键，否则
    // Retina ↔ 非 Retina 切换后旧位图会被永久复用。
    const k1x = GlyphKey{
        .font_ptr = 0xDEAD,
        .glyph_index = 7,
        .subpixel_bin = 0,
        .scale_q = quantizeScale(1.0),
    };
    const k2x = GlyphKey{
        .font_ptr = 0xDEAD,
        .glyph_index = 7,
        .subpixel_bin = 0,
        .scale_q = quantizeScale(2.0),
    };
    // 除 scale 外完全相同的两个键必须不等 —— 这正是修复的核心。
    try testing.expect(!std.meta.eql(k1x, k2x));

    // 同一 scale 仍须命中同一条目（否则等于缓存全 miss）。
    const k1x_again = GlyphKey{
        .font_ptr = 0xDEAD,
        .glyph_index = 7,
        .subpixel_bin = 0,
        .scale_q = quantizeScale(1.0),
    };
    try testing.expect(std.meta.eql(k1x, k1x_again));

    // 结构性断言：scale 维度确实存在于键里。
    const fields = @typeInfo(GlyphKey).@"struct".fields;
    var has_scale = false;
    inline for (fields) |fld| {
        if (std.mem.eql(u8, fld.name, "scale_q")) has_scale = true;
    }
    try testing.expect(has_scale);
}

test "HiDPI: scale 量化保持不同真实 scale 可区分、同一 scale 稳定" {
    const testing = @import("std").testing;
    // 量化不能把不同的真实 scale 折叠到一档（那等于把 bug 换个形式保留）。
    try testing.expect(quantizeScale(1.0) != quantizeScale(2.0));
    try testing.expect(quantizeScale(1.0) != quantizeScale(1.5));
    try testing.expect(quantizeScale(1.5) != quantizeScale(2.0));
    // 缩放分辨率模式下的非整数 scale 也必须可区分。
    try testing.expect(quantizeScale(1.25) != quantizeScale(1.5));

    // 同一逻辑 scale 经不同浮点路径算出，必须量化到同一档（否则缓存永久
    // miss + 图集无限增长）。2.0 vs 4.0/2.0 vs 1.0+1.0。
    try testing.expectEqual(quantizeScale(2.0), quantizeScale(4.0 / 2.0));
    try testing.expectEqual(quantizeScale(2.0), quantizeScale(1.0 + 1.0));
    // 远小于 1/100 的浮点噪声不应产生新档位。
    try testing.expectEqual(quantizeScale(2.0), quantizeScale(2.0 + 1e-6));
}

test "HiDPI: 同一 Font 指针改 scale 后 getOrInsert 的键随之改变" {
    const testing = @import("std").testing;
    // 端到端地钉住「setScaleFactor 不改变 Font 指针」这个前提下键仍会变。
    // 走真实 CoreText Font，只验键的构造（不需要 Metal device）。
    var fs = try text.FontSystem.init(testing.allocator);
    defer fs.deinit();
    const f = try fs.findFont(.{ .family = "Helvetica", .size = 32 });
    defer f.deinit();

    const g = f.glyphIndexForCodepoint('M');
    try testing.expect(g != 0);

    f.setScaleFactor(1.0);
    const ptr_before = @intFromPtr(f);
    const key_1x = GlyphKey{
        .font_ptr = ptr_before,
        .glyph_index = g,
        .scale_q = quantizeScale(f.scale_factor),
    };

    f.setScaleFactor(2.0);
    // 前提复核：指针确实没变 —— 这正是 scale 必须入键的原因。
    try testing.expectEqual(ptr_before, @intFromPtr(f));
    const key_2x = GlyphKey{
        .font_ptr = @intFromPtr(f),
        .glyph_index = g,
        .scale_q = quantizeScale(f.scale_factor),
    };

    try testing.expect(!std.meta.eql(key_1x, key_2x));
}

test "forgetFont 只摘除该 font_ptr 的全部条目（含各 scale / subpixel 变体）" {
    const testing = std.testing;
    // forgetFont 只触碰 cache，不需要 Metal device。
    var atlas: GlyphAtlas = undefined;
    atlas.cache = std.AutoHashMap(GlyphKey, AtlasRegion).init(testing.allocator);
    defer atlas.cache.deinit();
    const region = AtlasRegion{
        .uv_min = .{ 0, 0 },
        .uv_max = .{ 1, 1 },
        .bearing_x = 0,
        .bearing_y = 0,
        .advance = 0,
        .width = 1,
        .height = 1,
        .page_index = 0,
    };
    const doomed: usize = 0x1000;
    const survivor: usize = 0x2000;
    var g: u32 = 0;
    while (g < 200) : (g += 1) {
        try atlas.cache.put(.{ .font_ptr = doomed, .glyph_index = g }, region);
        try atlas.cache.put(.{ .font_ptr = doomed, .glyph_index = g, .subpixel_bin = 3, .scale_q = quantizeScale(2.0) }, region);
        try atlas.cache.put(.{ .font_ptr = survivor, .glyph_index = g }, region);
    }
    atlas.forgetFont(doomed);
    try testing.expectEqual(@as(u32, 200), atlas.cache.count());
    var iter = atlas.cache.iterator();
    while (iter.next()) |entry| try testing.expectEqual(survivor, entry.key_ptr.font_ptr);
    // 地址复用后的新字体必须 miss，而不是命中旧位图。
    try testing.expect(atlas.cache.get(.{ .font_ptr = doomed, .glyph_index = 7 }) == null);
    try testing.expect(atlas.cache.get(.{ .font_ptr = survivor, .glyph_index = 7 }) != null);
}
