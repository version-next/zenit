/// Image Renderer - GPU 图片渲染管线
///
/// 基于 image.metal 的纹理渲染:
/// - 纹理采样 + SDF 圆角裁剪
/// - 着色 (tint) 和不透明度
/// - 纹理缓存管理
///
/// 用法:
/// 1. init() 创建渲染器
/// 2. loadTexture() 加载纹理（从 RGBA 像素数据）
/// 3. addImage() 添加图片实例
/// 4. render() 提交到 GPU
const std = @import("std");
const gpu = @import("gpu");

const MAX_CLIP_POLYGON_POINTS = 32;
const MAX_CLIP_POLYGON_CONTOURS = 8;

extern fn macos_load_image_from_url(url: [*:0]const u8, out_width: *u32, out_height: *u32) ?[*]u8;
extern fn macos_free_image_data(data: [*]u8) void;

/// Image Shader 源码（单一事实源）
const image_shader_source: []const u8 = @embedFile("shaders/image.metal");

/// Uniforms 结构，与 SDF renderer 相同
const Uniforms = extern struct {
    viewport_size: [2]f32,
    scale_factor: f32,
    clip_shape_kind: u32 = 0,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radius: f32 = 0,
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = [_]u32{0} ** MAX_CLIP_POLYGON_CONTOURS,
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = [_][2]f32{.{ 0, 0 }} ** MAX_CLIP_POLYGON_POINTS,
};

/// 图片实例数据，对齐 image.metal ImageInstanceData
pub const ImageInstance = extern struct {
    rect: [4]f32, // x, y, w, h (逻辑像素)
    uv_rect: [4]f32, // u0, v0, u1, v1 (纹理坐标)
    tint_color: [4]f32, // RGBA float (1,1,1,1 = 无着色)
    transform_linear: [4]f32 = .{ 1, 0, 0, 1 }, // a, b, c, d
    transform_translation: [2]f32 = .{ 0, 0 }, // tx, ty
    corner_radius: f32,
    opacity: f32,
    source_premultiplied: f32 = 0,
    // MSL aligns the trailing float4 to 16 bytes; keep CPU/GPU instance layout identical.
    _rect_clip_padding: [3]f32 = .{ 0, 0, 0 },
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 }, // x, y, w, h (逻辑像素); negative size = disabled

    comptime {
        if (@offsetOf(ImageInstance, "rect_clip") != 96) {
            @compileError("ImageInstance.rect_clip must start at byte 96 to match image.metal");
        }
        if (@sizeOf(ImageInstance) != 112) {
            @compileError("ImageInstance must be 112 bytes to match image.metal");
        }
    }
};

/// 纹理 ID
pub const TextureId = u32;

/// 纹理槽位
const TextureSlot = struct {
    kind: TextureKind,
    binding: gpu.Backend.TextureBinding,
    owned_texture: ?gpu.Backend.Texture = null,
    width: u32,
    height: u32,
    mip_level_count: u32,
    atlas_page_index: u16 = 0,
    uv_rect: [4]f32 = .{ 0, 0, 1, 1 },
};

const AtlasPage = struct {
    texture: gpu.Backend.Texture,
    next_x: u32 = 0,
    next_y: u32 = 0,
    shelf_height: u32 = 0,
    live_entries: u32 = 0,
};

const AtlasAllocation = struct {
    page_index: usize,
    x: u32,
    y: u32,
};

/// 最大实例数
const MAX_INSTANCES = 4096;
const MAX_UNIFORM_UPDATES = 256;

/// Triple buffering 常量
const BUFFER_COUNT = 3;

/// 最大纹理数
const MAX_TEXTURES = 4096;
const ATLAS_PAGE_SIZE = 2048;
const ATLAS_MAX_TEXTURE_SIZE = 256;
const ATLAS_GUTTER = 1;

/// 白色常量
const WHITE: [4]f32 = .{ 1, 1, 1, 1 };

const TextureKind = enum {
    standalone,
    stream,
    atlas_region,
    external,
};

/// Metal Image Renderer
/// 图片管线累计计数器（进程级单调递增；帧值 = 与上帧快照的差）。
/// 图片画布场景 N 张截图 ≈ N 次 draw call + N 次纹理绑定，
/// 这些计数是验证合批/图集优化是否生效的依据。
pub var image_draw_calls: u64 = 0;
pub var image_instances_drawn: u64 = 0;
pub var image_texture_binds: u64 = 0;

/// 纹理内存用量快照（供应用侧 LRU 预算驱逐决策，避免影子记账漂移）。
pub const TextureMemoryStats = struct {
    /// 独立纹理数（不含 atlas 页）
    texture_count: u32,
    /// RGBA8 texel bytes over every mip level, including whole atlas pages.
    /// Excludes driver padding and storage retained by pending/in-flight draws.
    estimated_bytes: u64,
    atlas_page_count: u32,
    slots_used: u32,
    slots_total: u32,
};

/// Private and shared handles occupy disjoint namespaces; generation bits stop
/// a released slot from turning a cached display-list handle into another image.
const SHARED_TEXTURE_BIT: u32 = 0x80000000;
const SLOT_BITS = 12;
const SLOT_MASK = MAX_TEXTURES - 1;
const MAX_GENERATION = (SHARED_TEXTURE_BIT - 1) >> SLOT_BITS;

/// 借用型（external）绑定专用槽位区间 [EXTERNAL_SLOT_BASE, MAX_TEXTURES)。
///
/// 背景：offscreen / retained / glass 合成每帧 register+unregister 数十次，
/// 每次 unregister 都 bump 槽位 generation；generation 到 MAX_GENERATION 的
/// 槽位永久退役。按 20-30 次/帧 @120Hz，全部 4096×2^19 次注册约一周耗尽，
/// 之后所有离屏层 TooManyTextures（整片 overlay 消失）。
///
/// 解法：external 槽位与持久纹理槽位隔离，且 external 槽位的 generation
/// **允许回绕**。ABA 论证：
///   - generation 的作用是让缓存在 display list 里的**旧句柄**失效。持久纹理
///     句柄可以被 app 长期持有，所以持久槽位仍然"耗尽即退役"，绝不回绕。
///   - external 句柄的生命周期严格限于一次编码（register -> draw -> flush ->
///     unregister，调用点见 opacity_layer / backdrop_blur），从不跨帧缓存。
///     回绕后要与某个旧句柄撞号，需要该旧句柄在同一槽位又经历 2^19 次
///     register/unregister 之后仍被使用，远超单帧可能的注册次数。
///   - 区间隔离保证持久句柄永远不会落在会回绕的槽位上（否则持久句柄可能
///     被回绕后的新 external 绑定"复活"成别的纹理）。
const EXTERNAL_SLOT_COUNT = 256;
const EXTERNAL_SLOT_BASE = MAX_TEXTURES - EXTERNAL_SLOT_COUNT;

/// GPU image storage, independent of a window's pipeline and frame buffers.
/// All access is on the render thread. Its owner must drain GPU work before
/// destruction. A shared instance must outlive all borrowing ImageRenderers.
pub const ImageTextureStore = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    namespace: u32,
    textures: [MAX_TEXTURES]?TextureSlot = [_]?TextureSlot{null} ** MAX_TEXTURES,
    generations: [MAX_TEXTURES]u32 = [_]u32{0} ** MAX_TEXTURES,
    texture_count: u32 = 0,
    atlas_pages: std.ArrayList(AtlasPage) = .{},
    /// Admission limit for resident storage; configure before the first upload.
    memory_budget_bytes: u64 = std.math.maxInt(u64),

    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device, shared: bool) ImageTextureStore {
        return .{ .allocator = allocator, .device = device, .namespace = if (shared) SHARED_TEXTURE_BIT else 0 };
    }

    pub fn deinit(self: *ImageTextureStore) void {
        for (&self.textures) |*entry| {
            if (entry.*) |slot| if (slot.owned_texture) |owned| {
                var texture = owned;
                texture.destroy();
            };
            entry.* = null;
        }
        for (self.atlas_pages.items) |*page| page.texture.destroy();
        self.atlas_pages.deinit(self.allocator);
        self.atlas_pages = .{};
    }

    fn handle(self: *const ImageTextureStore, index: u32) TextureId {
        return self.namespace | (self.generations[index] << SLOT_BITS) | index;
    }

    pub fn getTextureSize(self: *const ImageTextureStore, id: TextureId) ?[2]u32 {
        const slot = self.resolveTextureSlot(id) orelse return null;
        return .{ slot.width, slot.height };
    }

    pub fn unloadTexture(self: *ImageTextureStore, id: TextureId) void {
        const slot = self.resolveTextureSlot(id) orelse return;
        const index = id & SLOT_MASK;
        if (slot.owned_texture) |owned| {
            var texture = owned;
            texture.destroy();
        }
        if (slot.kind == .atlas_region) {
            const page = &self.atlas_pages.items[slot.atlas_page_index];
            page.live_entries -= 1;
            if (page.live_entries == 0) {
                // Retire storage instead of overwriting texels sampled by an
                // in-flight frame. Submitted Metal command buffers retain it.
                const removed: usize = slot.atlas_page_index;
                var old = self.atlas_pages.swapRemove(removed);
                old.texture.destroy();
                if (removed < self.atlas_pages.items.len) {
                    for (&self.textures) |*entry| if (entry.*) |*other| {
                        if (other.kind == .atlas_region and other.atlas_page_index == self.atlas_pages.items.len)
                            other.atlas_page_index = @intCast(removed);
                    };
                }
            }
        }
        self.textures[index] = null;
        if (index >= EXTERNAL_SLOT_BASE) {
            // external 专用槽位：generation 回绕（ABA 论证见 EXTERNAL_SLOT_BASE）。
            self.generations[index] = if (self.generations[index] >= MAX_GENERATION) 0 else self.generations[index] + 1;
        } else {
            self.generations[index] += 1; // exhausted persistent slots are never reused
        }
    }

    /// 加载纹理（从 RGBA 像素数据）
    /// 返回纹理 ID
    pub fn loadTexture(self: *ImageTextureStore, width: u32, height: u32, rgba_data: []const u8) !TextureId {
        const expected_len = try pixelLength(width, height);
        if (rgba_data.len < expected_len) return error.InvalidPixelData;
        if (width == 0 or height == 0) return error.InvalidPixelData;
        if (!self.canLoadTexture(width, height)) return error.TextureMemoryBudgetExceeded;
        if (canAtlasTexture(width, height)) {
            return self.loadAtlasTexture(width, height, rgba_data);
        }
        return self.loadStandaloneTexture(width, height, rgba_data);
    }

    /// Same admission calculation as loadTexture, without allocating or changing
    /// atlas shelves. Callers may evict their own handles and check again.
    pub fn canLoadTexture(self: *const ImageTextureStore, width: u32, height: u32) bool {
        _ = pixelLength(width, height) catch return false;
        var additional = textureByteLength(width, height, calcMipLevelCount(width, height));
        if (canAtlasTexture(width, height)) {
            additional = ATLAS_PAGE_SIZE * ATLAS_PAGE_SIZE * 4;
            for (self.atlas_pages.items) |page| {
                var candidate = page;
                if (allocAtlasOnPage(&candidate, width, height) != null) {
                    additional = 0;
                    break;
                }
            }
        }
        return self.hasMemoryRoom(additional);
    }

    fn hasMemoryRoom(self: *const ImageTextureStore, additional: u64) bool {
        const used = self.getTextureMemoryStats().estimated_bytes;
        return used <= self.memory_budget_bytes and additional <= self.memory_budget_bytes - used;
    }

    fn loadStandaloneTexture(self: *ImageTextureStore, width: u32, height: u32, rgba_data: []const u8) !TextureId {
        const mip_level_count = calcMipLevelCount(width, height);

        // 创建 RGBA8 sRGB 纹理（带 mipmap）
        var texture = try self.device.createTexture(self.allocator, .{
            .label = "Zenit.Image.Standalone",
            .size = .{ .width = width, .height = height },
            .mip_level_count = mip_level_count,
            .format = .rgba8_unorm_srgb,
            .usage = .{ .copy_dst = true, .texture_binding = true },
            .memory = .host_upload,
        });
        errdefer texture.destroy();

        // 上传 base level
        try texture.writeRegion(0, 0, 0, width, height, rgba_data, width * 4);

        // 生成并上传 mip levels（CPU box filter）
        if (mip_level_count > 1) {
            try self.uploadMipChain(&texture, width, height, rgba_data, mip_level_count);
        }

        const id = try self.allocateTextureSlot();
        self.textures[id] = TextureSlot{
            .kind = .standalone,
            .binding = texture.binding(),
            .owned_texture = texture,
            .width = width,
            .height = height,
            .mip_level_count = mip_level_count,
        };

        self.texture_count = @max(self.texture_count, id + 1);
        return self.handle(id);
    }

    fn loadAtlasTexture(self: *ImageTextureStore, width: u32, height: u32, rgba_data: []const u8) !TextureId {
        const id = try self.allocateTextureSlot();
        const padded = try makePaddedAtlasPixels(self.allocator, width, height, rgba_data, ATLAS_GUTTER);
        defer self.allocator.free(padded);
        const allocation = try self.allocateAtlasRegion(width, height);

        const page = &self.atlas_pages.items[allocation.page_index];
        try page.texture.writeRegion(
            0,
            allocation.x - ATLAS_GUTTER,
            allocation.y - ATLAS_GUTTER,
            width + ATLAS_GUTTER * 2,
            height + ATLAS_GUTTER * 2,
            padded,
            (width + ATLAS_GUTTER * 2) * 4,
        );

        page.live_entries += 1;
        self.textures[id] = TextureSlot{
            .kind = .atlas_region,
            .binding = page.texture.binding(),
            .width = width,
            .height = height,
            .mip_level_count = 1,
            .atlas_page_index = @intCast(allocation.page_index),
            .uv_rect = atlasRegionUvRect(allocation.x, allocation.y, width, height, ATLAS_PAGE_SIZE),
        };
        self.texture_count = @max(self.texture_count, id + 1);
        return self.handle(id);
    }

    /// Register a borrowed backend texture binding. The caller owns its lifetime.
    /// Used to sample an offscreen render target through the image pipeline.
    /// 句柄只在本次编码内有效（必须在同一帧 unregister），见 EXTERNAL_SLOT_BASE。
    pub fn registerTextureBinding(self: *ImageTextureStore, binding: gpu.Backend.TextureBinding, width: u32, height: u32) !TextureId {
        const id = try self.allocateExternalSlot();
        self.textures[id] = TextureSlot{
            .kind = .external,
            .binding = binding,
            .width = width,
            .height = height,
            .mip_level_count = 1,
        };
        // texture_count 只覆盖持久区间（内存统计用）；external 槽位不计入。
        return self.handle(id);
    }

    /// Unregister a borrowed binding without destroying the caller-owned texture.
    pub fn unregisterTextureBinding(self: *ImageTextureStore, id: TextureId) void {
        const slot = self.resolveTextureSlot(id) orelse return;
        if (slot.kind == .external) self.unloadTexture(id);
    }

    pub fn createStreamTexture(self: *ImageTextureStore, width: u32, height: u32) !TextureId {
        _ = try pixelLength(width, height);
        if (!self.hasMemoryRoom(textureByteLength(width, height, 1))) return error.TextureMemoryBudgetExceeded;
        const index = try self.allocateTextureSlot();
        var texture = try self.device.createTexture(self.allocator, .{
            .label = "Zenit.Image.Stream",
            .size = .{ .width = width, .height = height },
            .mip_level_count = 1,
            .format = .rgba8_unorm_srgb,
            .usage = .{ .copy_dst = true, .texture_binding = true },
            .memory = .host_upload,
        });
        errdefer texture.destroy();
        self.textures[index] = .{ .kind = .stream, .binding = texture.binding(), .owned_texture = texture, .width = width, .height = height, .mip_level_count = 1 };
        self.texture_count = @max(self.texture_count, index + 1);
        return self.handle(index);
    }

    pub fn updateStreamTexture(self: *ImageTextureStore, id: TextureId, rgba: []const u8) !void {
        const slot = self.resolveTextureSlot(id) orelse return error.InvalidTexture;
        if (slot.kind != .stream) return error.TextureNotWritable;
        const expected = try pixelLength(slot.width, slot.height);
        if (rgba.len != expected) return error.InvalidPixelData;
        var texture = slot.owned_texture.?;
        try texture.writeRegion(0, 0, 0, slot.width, slot.height, rgba, slot.width * 4);
    }

    /// Resident RGBA8 texel bytes, including exact mip dimensions and atlas pages.
    pub fn getTextureMemoryStats(self: *const ImageTextureStore) TextureMemoryStats {
        var stats = TextureMemoryStats{
            .texture_count = 0,
            .estimated_bytes = 0,
            .atlas_page_count = @intCast(self.atlas_pages.items.len),
            .slots_used = 0,
            .slots_total = EXTERNAL_SLOT_BASE,
        };
        for (self.textures[0..self.texture_count]) |maybe_slot| {
            const slot = maybe_slot orelse continue;
            stats.slots_used += 1;
            // atlas 槽位共享页纹理，页内存在下面按页统计，避免重复计入
            if (slot.kind == .atlas_region) continue;
            stats.texture_count += 1;
            stats.estimated_bytes +|= textureByteLength(slot.width, slot.height, slot.mip_level_count);
        }
        const page_bytes: u64 = @as(u64, ATLAS_PAGE_SIZE) * ATLAS_PAGE_SIZE * 4;
        stats.estimated_bytes +|= page_bytes * stats.atlas_page_count;
        return stats;
    }

    fn resolveTextureSlot(self: *const ImageTextureStore, id: TextureId) ?TextureSlot {
        if (id & SHARED_TEXTURE_BIT != self.namespace) return null;
        const index = id & SLOT_MASK;
        if (self.generations[index] > MAX_GENERATION or self.handle(index) != id) return null;
        return self.textures[index];
    }

    /// 持久纹理槽位（[0, EXTERNAL_SLOT_BASE)），耗尽 generation 的槽位跳过。
    fn allocateTextureSlot(self: *ImageTextureStore) !u32 {
        for (self.textures[0..EXTERNAL_SLOT_BASE], 0..) |slot, index| {
            if (slot == null and self.generations[index] <= MAX_GENERATION) return @intCast(index);
        }
        return error.TooManyTextures;
    }

    /// external（帧内借用）槽位：[EXTERNAL_SLOT_BASE, MAX_TEXTURES)，generation 回绕。
    fn allocateExternalSlot(self: *ImageTextureStore) !u32 {
        for (self.textures[EXTERNAL_SLOT_BASE..], EXTERNAL_SLOT_BASE..) |slot, index| {
            if (slot == null) return @intCast(index);
        }
        return error.TooManyTextures;
    }

    fn allocateAtlasRegion(self: *ImageTextureStore, width: u32, height: u32) !AtlasAllocation {
        for (self.atlas_pages.items, 0..) |*page, i| {
            if (allocAtlasOnPage(page, width, height)) |pos| {
                return .{ .page_index = i, .x = pos[0], .y = pos[1] };
            }
        }

        var texture = try self.createAtlasTexture(self.atlas_pages.items.len);
        errdefer texture.destroy();
        try self.atlas_pages.append(self.allocator, .{ .texture = texture });
        const page = &self.atlas_pages.items[self.atlas_pages.items.len - 1];
        const pos = allocAtlasOnPage(page, width, height) orelse return error.AtlasAllocationFailed;
        return .{ .page_index = self.atlas_pages.items.len - 1, .x = pos[0], .y = pos[1] };
    }

    fn createAtlasTexture(self: *ImageTextureStore, page_index: usize) !gpu.Backend.Texture {
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "Zenit.Image.Atlas[{d}]", .{page_index});
        return self.device.createTexture(self.allocator, .{
            .label = label,
            .size = .{ .width = ATLAS_PAGE_SIZE, .height = ATLAS_PAGE_SIZE },
            .format = .rgba8_unorm_srgb,
            .usage = .{ .copy_dst = true, .texture_binding = true },
            .memory = .host_upload,
        });
    }

    fn uploadMipChain(
        self: *ImageTextureStore,
        texture: *gpu.Backend.Texture,
        base_width: u32,
        base_height: u32,
        base_rgba: []const u8,
        mip_level_count: u32,
    ) !void {
        var prev_pixels: ?[]u8 = null;
        defer if (prev_pixels) |buf| self.allocator.free(buf);

        var src_pixels: []const u8 = base_rgba;
        var src_w = base_width;
        var src_h = base_height;

        var level: u32 = 1;
        while (level < mip_level_count) : (level += 1) {
            const dst_w: u32 = @max(1, src_w / 2);
            const dst_h: u32 = @max(1, src_h / 2);
            const dst_len: usize = @as(usize, dst_w) * @as(usize, dst_h) * 4;
            const dst_pixels = try self.allocator.alloc(u8, dst_len);
            errdefer self.allocator.free(dst_pixels);
            downsampleRgbaBox(src_pixels, src_w, src_h, dst_pixels, dst_w, dst_h);

            try texture.writeRegion(level, 0, 0, dst_w, dst_h, dst_pixels, dst_w * 4);

            if (prev_pixels) |old| self.allocator.free(old);
            prev_pixels = dst_pixels;
            src_pixels = dst_pixels;
            src_w = dst_w;
            src_h = dst_h;
        }
    }
};

pub const ImageRenderer = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    pipeline: gpu.Backend.RenderPipeline,
    /// Triple-buffered uniform buffers，必须与 instance buffers 一样按帧轮转。
    /// 曾经是**单个** buffer 而每帧把 uniform_write_offset 归零：三帧在飞时第 N+1
    /// 帧会覆写 GPU 尚未消费的第 N 帧 viewport/clip/scale，表现为偶发闪烁/错误裁剪。
    uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    uniform_write_offset: usize = 0,
    /// 单帧 uniform 槽位溢出次数（诊断用）
    uniform_overflow_count: u64 = 0,
    /// Triple-buffered instance buffers
    instance_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    current_buffer: usize = 0,

    /// 溢出实例缓冲（每帧槽位各一个，随需增长后**保留**）。
    ///
    /// 旧实现在 MAX_INSTANCES 用尽后对**每一批**都 createBuffer + destroy,
    /// 重内容帧每帧多次 driver 分配（走驱动，非 malloc）。改为按帧槽位持有
    /// 一个可增长的 buffer：容量够就直接复用，不够才重建一次。槽位随
    /// current_buffer 轮转，因此不会覆写 GPU 尚在消费的在飞帧数据。
    /// 与 sdf_renderer 的保留池同款。
    /// 溢出 uniform 缓冲（每帧槽位各一个，随需增长后**保留**）。
    /// 与 text_renderer 同款：槽位用尽不再丢批（丢批时 instances 不清空，
    /// 下一批带着旧实例再溢出，该帧剩余内容全部不画），改为切到按需增长、
    /// 跨帧保留的溢出 buffer 继续画。
    uniform_overflow_buffers: [BUFFER_COUNT]?gpu.Backend.Buffer = [_]?gpu.Backend.Buffer{null} ** BUFFER_COUNT,
    uniform_overflow_capacities: [BUFFER_COUNT]usize = [_]usize{0} ** BUFFER_COUNT,
    uniform_overflow_used: usize = 0,
    overflow_buffers: [BUFFER_COUNT]?gpu.Backend.Buffer = [_]?gpu.Backend.Buffer{null} ** BUFFER_COUNT,
    overflow_capacities: [BUFFER_COUNT]usize = [_]usize{0} ** BUFFER_COUNT,
    /// 本帧槽位内溢出缓冲的写入游标（字节），保证同帧多批次不互相覆写。
    overflow_write_offset: usize = 0,
    sampler: ?gpu.Backend.Sampler,

    // 纹理管理
    texture_store: ImageTextureStore,
    shared_texture_store: ?*ImageTextureStore = null,

    // 实例分组（按纹理 ID 分组渲染）
    instances: std.ArrayList(ImageInstance),
    instance_textures: std.ArrayList(struct { binding: gpu.Backend.TextureBinding, view: gpu.Backend.TextureView }),

    viewport_width: f32,
    viewport_height: f32,
    scale_factor: f32,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radius: f32 = 0,
    clip_shape_kind: u32 = 0,
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = [_]u32{0} ** MAX_CLIP_POLYGON_CONTOURS,
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = [_][2]f32{.{ 0, 0 }} ** MAX_CLIP_POLYGON_POINTS,
    current_rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    instance_high_water_mark: usize = 0,
    /// flush 偏移：同一帧内多次 flush 时追加写入，避免覆盖前面的 draw call 数据
    buffer_write_offset: usize = 0,

    /// 初始化
    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !ImageRenderer {
        // 编译 shader
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, image_shader_source);
        defer shader.deinit();

        var vertex_func = try shader.getFunction("image_vertex_main");
        defer vertex_func.deinit();
        var fragment_func = try shader.getFunction("image_fragment_main");
        defer fragment_func.deinit();

        // 创建 pipeline（带 alpha 混合）
        var pipeline = try gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex_func,
            .fragment_function = &fragment_func,
            .color_attachment_formats = &[_]gpu.TextureFormat{.bgra8_unorm_srgb},
            .blend_state = .{
                .source_rgb = .one,
                .destination_rgb = .one_minus_src_alpha,
                .rgb_operation = .add,
                .source_alpha = .one,
                .destination_alpha = .one_minus_src_alpha,
                .alpha_operation = .add,
            },
        });

        errdefer pipeline.deinit();

        // Uniform buffer（errdefer 必须在循环外，循环体内的 errdefer 随迭代
        // 作用域失效，等于死代码，这里曾经就是这么写的）
        var uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var uniform_created: usize = 0;
        errdefer for (uniform_buffers[0..uniform_created]) |*ub| ub.destroy();
        for (&uniform_buffers) |*ubuf| {
            ubuf.* = try device.createBuffer(allocator, .{
                .label = "Zenit.Image.Uniforms",
                .size = @sizeOf(Uniforms) * MAX_UNIFORM_UPDATES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            uniform_created += 1;
        }

        // Triple-buffered instance buffers
        var instance_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var instance_created: usize = 0;
        errdefer for (instance_buffers[0..instance_created]) |*ib| ib.destroy();
        for (&instance_buffers, 0..) |*buf, i| {
            const label = try std.fmt.allocPrint(allocator, "Zenit.Image.InstanceBuffer[{d}]", .{i});
            defer allocator.free(label);
            buf.* = try device.createBuffer(allocator, .{
                .label = label,
                .size = @sizeOf(ImageInstance) * MAX_INSTANCES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            instance_created += 1;
        }

        // 创建 Linear + Mip 采样器（图片缩小时减少闪烁）
        const sampler = try device.createSampler(allocator, .{
            .label = "Zenit.Image.LinearMipSampler",
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_filter = .linear,
        });

        std.log.info("[ImageRenderer] Initialized (64-byte image pipeline)", .{});

        return ImageRenderer{
            .allocator = allocator,
            .device = device,
            .pipeline = pipeline,
            .uniform_buffers = uniform_buffers,
            .instance_buffers = instance_buffers,
            .sampler = sampler,
            .texture_store = ImageTextureStore.init(allocator, device, false),
            .instances = .{},
            .instance_textures = .{},
            .viewport_width = 800,
            .viewport_height = 600,
            .scale_factor = 1.0,
        };
    }

    /// 销毁
    pub fn deinit(self: *ImageRenderer) void {
        self.clearInstances();
        self.texture_store.deinit();
        if (self.sampler) |*sampler| sampler.destroy();
        self.instances.deinit(self.allocator);
        self.instance_textures.deinit(self.allocator);
        for (&self.instance_buffers) |*buf| buf.destroy();
        for (&self.overflow_buffers) |*maybe_buf| {
            if (maybe_buf.*) |*buf| buf.destroy();
        }
        for (&self.uniform_overflow_buffers) |*maybe_buf| {
            if (maybe_buf.*) |*buf| buf.destroy();
        }
        for (&self.uniform_buffers) |*ubuf| ubuf.destroy();
        self.pipeline.deinit();
        std.log.info("[ImageRenderer] Destroyed", .{});
    }

    pub fn loadTexture(self: *ImageRenderer, width: u32, height: u32, rgba: []const u8) !TextureId {
        return self.texture_store.loadTexture(width, height, rgba);
    }

    pub fn registerTextureBinding(self: *ImageRenderer, binding: gpu.Backend.TextureBinding, width: u32, height: u32) !TextureId {
        return self.texture_store.registerTextureBinding(binding, width, height);
    }

    pub fn unregisterTextureBinding(self: *ImageRenderer, id: TextureId) void {
        self.texture_store.unregisterTextureBinding(id);
    }

    pub fn unloadTexture(self: *ImageRenderer, id: TextureId) void {
        self.texture_store.unloadTexture(id);
    }

    pub fn getTextureSize(self: *const ImageRenderer, id: TextureId) ?[2]u32 {
        const slot = self.resolveTextureSlot(id) orelse return null;
        return .{ slot.width, slot.height };
    }

    fn clearInstances(self: *ImageRenderer) void {
        for (self.instance_textures.items) |*entry| entry.view.destroy();
        self.instance_textures.clearRetainingCapacity();
        self.instances.clearRetainingCapacity();
    }

    /// 开始新帧
    pub fn beginFrame(self: *ImageRenderer, width: f32, height: f32, scale: f32) void {
        self.clearInstances();
        self.buffer_write_offset = 0;
        self.current_buffer = (self.current_buffer + 1) % BUFFER_COUNT;
        self.uniform_write_offset = 0;
        self.uniform_overflow_used = 0;
        // 新槽位的溢出缓冲从头写起（该槽位上一次使用已隔了 BUFFER_COUNT 帧）
        self.overflow_write_offset = 0;
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
        self.clip_rect = .{ 0, 0, 0, 0 };
        self.clip_radius = 0;
        self.clip_shape_kind = 0;
        self.clip_fill_rule = 0;
        self.clip_point_count = 0;
        self.clip_contour_count = 0;
        self.clip_polygon_end_points = [_]u32{0} ** MAX_CLIP_POLYGON_CONTOURS;
        self.clip_polygon_points = [_][2]f32{.{ 0, 0 }} ** MAX_CLIP_POLYGON_POINTS;
        self.current_rect_clip = .{ 0, 0, -1, -1 };
    }

    /// 仅更新 viewport 尺寸（离屏合成 render pass 切换时使用）
    pub fn setViewport(self: *ImageRenderer, width: f32, height: f32, scale: f32) void {
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
    }

    pub fn setClipMask(self: *ImageRenderer, shape_kind: u32, rect: ?[4]f32, radius: f32, fill_rule: u32, point_count: u32, contour_count: u32, contour_end_points: [MAX_CLIP_POLYGON_CONTOURS]u8, polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32) void {
        if (rect) |mask_rect| {
            self.clip_rect = mask_rect;
            self.clip_radius = radius;
            self.clip_shape_kind = shape_kind;
            self.clip_fill_rule = fill_rule;
            self.clip_point_count = point_count;
            self.clip_contour_count = contour_count;
            for (0..MAX_CLIP_POLYGON_CONTOURS) |i| self.clip_polygon_end_points[i] = contour_end_points[i];
            self.clip_polygon_points = polygon_points;
        } else {
            self.clip_rect = .{ 0, 0, 0, 0 };
            self.clip_radius = 0;
            self.clip_shape_kind = 0;
            self.clip_fill_rule = 0;
            self.clip_point_count = 0;
            self.clip_contour_count = 0;
            self.clip_polygon_end_points = [_]u32{0} ** MAX_CLIP_POLYGON_CONTOURS;
            self.clip_polygon_points = [_][2]f32{.{ 0, 0 }} ** MAX_CLIP_POLYGON_POINTS;
        }
    }

    pub fn setRectClip(self: *ImageRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
    }

    /// 添加图片实例
    pub fn addImage(
        self: *ImageRenderer,
        texture_id: TextureId,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        corner_radius: f32,
        opacity: f32,
    ) !void {
        const transform = affineTranslation(x, y);
        return self.addImageUVWithTransform(
            texture_id,
            w,
            h,
            .{ 0, 0, 1, 1 },
            WHITE,
            corner_radius,
            opacity,
            transform,
            false,
        );
    }

    /// 添加图片实例（自定义 UV 区域，用于图集）
    pub fn addImageUV(
        self: *ImageRenderer,
        texture_id: TextureId,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        uv: [4]f32, // u0, v0, u1, v1
        tint: [4]f32,
        corner_radius: f32,
        opacity: f32,
        rotate: f32,
    ) !void {
        const transform = affineRectRotate(x, y, w, h, rotate);
        return self.addImageUVWithTransform(
            texture_id,
            w,
            h,
            uv,
            tint,
            corner_radius,
            opacity,
            transform,
            false,
        );
    }

    pub fn addImageUVPremultiplied(
        self: *ImageRenderer,
        texture_id: TextureId,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        uv: [4]f32,
        tint: [4]f32,
        corner_radius: f32,
        opacity: f32,
        rotate: f32,
    ) !void {
        const transform = affineRectRotate(x, y, w, h, rotate);
        return self.addImageUVWithTransform(
            texture_id,
            w,
            h,
            uv,
            tint,
            corner_radius,
            opacity,
            transform,
            true,
        );
    }

    pub fn addImageUVWithTransform(
        self: *ImageRenderer,
        texture_id: TextureId,
        w: f32,
        h: f32,
        uv: [4]f32,
        tint: [4]f32,
        corner_radius: f32,
        opacity: f32,
        transform: [6]f32,
        source_premultiplied: bool,
    ) !void {
        const slot = self.resolveTextureSlot(texture_id) orelse return error.UnknownTexture;
        try self.instances.ensureUnusedCapacity(self.allocator, 1);
        try self.instance_textures.ensureUnusedCapacity(self.allocator, 1);
        self.instances.appendAssumeCapacity(.{
            .rect = .{ 0, 0, w, h },
            .uv_rect = composeUvRect(slot.uv_rect, uv),
            .tint_color = tint,
            .transform_linear = .{ transform[0], transform[1], transform[2], transform[3] },
            .transform_translation = .{ transform[4], transform[5] },
            .corner_radius = corner_radius,
            .opacity = opacity,
            .source_premultiplied = if (source_premultiplied) 1 else 0,
            .rect_clip = self.current_rect_clip,
        });
        self.instance_textures.appendAssumeCapacity(.{ .binding = slot.binding, .view = slot.binding.createView() });
    }

    fn affineTranslation(x: f32, y: f32) [6]f32 {
        return .{ 1, 0, 0, 1, x, y };
    }

    fn affineRectRotate(x: f32, y: f32, w: f32, h: f32, rotate: f32) [6]f32 {
        if (@abs(rotate) <= 0.0001) return affineTranslation(x, y);
        const cos_r = @cos(rotate);
        const sin_r = @sin(rotate);
        const origin_x = w * 0.5;
        const origin_y = h * 0.5;
        return .{
            cos_r,
            sin_r,
            -sin_r,
            cos_r,
            x + origin_x - cos_r * origin_x + sin_r * origin_y,
            y + origin_y - sin_r * origin_x - cos_r * origin_y,
        };
    }

    /// 渲染所有实例（按纹理分组，自动分批防溢出，支持 buffer_write_offset 累加）
    /// 保证本帧槽位的溢出 uniform buffer 至少能放下 `slots` 个 Uniforms。
    fn ensureUniformOverflowCapacity(self: *ImageRenderer, slots: usize) !*gpu.Backend.Buffer {
        const needed = slots * @sizeOf(Uniforms);
        if (self.uniform_overflow_capacities[self.current_buffer] < needed) {
            var new_capacity = @max(self.uniform_overflow_capacities[self.current_buffer], @sizeOf(Uniforms) * 64);
            while (new_capacity < needed) new_capacity *= 2;
            const replacement = try self.device.createBuffer(self.allocator, .{
                .label = "Zenit.Image.OverflowUniforms",
                .size = new_capacity,
                .usage = .{ .vertex = true, .map_write = true },
            });
            if (self.uniform_overflow_buffers[self.current_buffer]) |*old| old.destroy();
            self.uniform_overflow_buffers[self.current_buffer] = replacement;
            self.uniform_overflow_capacities[self.current_buffer] = new_capacity;
        }
        return &self.uniform_overflow_buffers[self.current_buffer].?;
    }

    pub fn render(self: *ImageRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        if (self.instances.items.len == 0) return;

        // 更新 uniforms
        // 溢出**不能** clamp 到最后一槽，那会让本批及后续 draw 别名同一块随后
        // 被覆写的内存，静默画错。宁可丢掉这一批并计数告警。
        const uniform_buffer, const uniform_byte_offset = blk: {
            if (self.uniform_write_offset < MAX_UNIFORM_UPDATES) {
                const slot = self.uniform_write_offset;
                self.uniform_write_offset += 1;
                break :blk .{ &self.uniform_buffers[self.current_buffer], slot * @sizeOf(Uniforms) };
            }
            self.uniform_overflow_count += 1;
            const slot = self.uniform_overflow_used;
            self.uniform_overflow_used += 1;
            const buf = try self.ensureUniformOverflowCapacity(slot + 1);
            break :blk .{ buf, slot * @sizeOf(Uniforms) };
        };
        const uniforms = Uniforms{
            .viewport_size = .{ self.viewport_width, self.viewport_height },
            .scale_factor = self.scale_factor,
            .clip_shape_kind = self.clip_shape_kind,
            .clip_rect = self.clip_rect,
            .clip_radius = self.clip_radius,
            .clip_fill_rule = self.clip_fill_rule,
            .clip_point_count = self.clip_point_count,
            .clip_contour_count = self.clip_contour_count,
            .clip_polygon_end_points = self.clip_polygon_end_points,
            .clip_polygon_points = self.clip_polygon_points,
        };
        const uniform_data = try uniform_buffer.getMappedRange(uniform_byte_offset, @sizeOf(Uniforms));
        @memcpy(uniform_data, std.mem.asBytes(&uniforms));

        // 设置 pipeline
        render_pass.setPipeline(&self.pipeline);
        render_pass.setVertexBuffer(0, uniform_buffer, @intCast(uniform_byte_offset));
        render_pass.setFragmentBuffer(0, uniform_buffer, @intCast(uniform_byte_offset));

        // 绑定 sampler
        if (self.sampler) |smp| {
            render_pass.setFragmentSampler(0, &smp);
        }

        const total = self.instances.items.len;
        self.instance_high_water_mark = @max(self.instance_high_water_mark, total);
        image_instances_drawn += total;

        // 分批上传，追加写入 buffer（不覆盖前面 flush 的数据）
        var global_offset: usize = 0;
        while (global_offset < total) {
            const remaining_total = total - global_offset;
            const remaining_capacity = MAX_INSTANCES - self.buffer_write_offset;
            const chunk_count = if (remaining_capacity == 0)
                remaining_total
            else
                @min(remaining_total, remaining_capacity);
            const chunk_size = @sizeOf(ImageInstance) * chunk_count;
            if (remaining_capacity == 0) {
                // 复用本帧槽位的溢出缓冲；容量不足才重建（几何增长，避免抖动）。
                const needed = self.overflow_write_offset + chunk_size;
                if (self.overflow_capacities[self.current_buffer] < needed) {
                    var new_capacity = @max(self.overflow_capacities[self.current_buffer], chunk_size);
                    while (new_capacity < needed) new_capacity *= 2;
                    const replacement = try self.device.createBuffer(self.allocator, .{
                        .label = "Zenit.Image.OverflowInstanceBuffer",
                        .size = new_capacity,
                        .usage = .{ .vertex = true, .map_write = true },
                    });
                    if (self.overflow_buffers[self.current_buffer]) |*old| old.destroy();
                    self.overflow_buffers[self.current_buffer] = replacement;
                    self.overflow_capacities[self.current_buffer] = new_capacity;
                }
                const overflow_buffer = &self.overflow_buffers[self.current_buffer].?;
                const overflow_data = try overflow_buffer.getMappedRange(self.overflow_write_offset, chunk_size);
                @memcpy(overflow_data, std.mem.sliceAsBytes(self.instances.items[global_offset .. global_offset + chunk_count]));
                render_pass.setVertexBuffer(1, overflow_buffer, @intCast(self.overflow_write_offset));
                render_pass.setFragmentBuffer(1, overflow_buffer, @intCast(self.overflow_write_offset));
                self.overflow_write_offset += chunk_size;
            } else {
                const byte_offset = self.buffer_write_offset * @sizeOf(ImageInstance);
                const chunk_data = try self.instance_buffers[self.current_buffer].getMappedRange(byte_offset, chunk_size);
                @memcpy(chunk_data, std.mem.sliceAsBytes(self.instances.items[global_offset .. global_offset + chunk_count]));
                render_pass.setVertexBuffer(1, &self.instance_buffers[self.current_buffer], @intCast(byte_offset));
                render_pass.setFragmentBuffer(1, &self.instance_buffers[self.current_buffer], @intCast(byte_offset));
                self.buffer_write_offset += chunk_count;
            }

            // 在当前 chunk 内按纹理分组
            var i: usize = 0;
            while (i < chunk_count) {
                const current_texture = self.instance_textures.items[global_offset + i].binding;
                var batch_end = i + 1;
                while (batch_end < chunk_count and
                    self.instance_textures.items[global_offset + batch_end].binding.eql(current_texture))
                {
                    batch_end += 1;
                }
                render_pass.setFragmentTextureBinding(0, current_texture);
                render_pass.draw(6, @intCast(batch_end - i), 0, @intCast(i));
                image_texture_binds += 1;
                image_draw_calls += 1;
                i = batch_end;
            }
            global_offset += chunk_count;
        }
    }

    /// 刷新
    pub fn flush(self: *ImageRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        try self.render(render_pass);
        self.clearInstances();
    }

    pub fn getTextureMemoryStats(self: *const ImageRenderer) TextureMemoryStats {
        return self.texture_store.getTextureMemoryStats();
    }

    /// The application owns shared storage until every renderer and GPU frame
    /// using it has finished. Private SVG/offscreen handles remain local.
    pub fn setSharedTextureStore(self: *ImageRenderer, store: ?*ImageTextureStore) !void {
        if (store) |shared| {
            if (shared.device != self.device or shared.namespace != SHARED_TEXTURE_BIT) return error.InvalidTextureStore;
        }
        self.shared_texture_store = store;
    }

    fn resolveTextureSlot(self: *const ImageRenderer, id: TextureId) ?TextureSlot {
        const store = if (id & SHARED_TEXTURE_BIT != 0) self.shared_texture_store orelse return null else &self.texture_store;
        return store.resolveTextureSlot(id);
    }
};

fn pixelLength(width: u32, height: u32) !usize {
    if (width == 0 or height == 0) return error.InvalidPixelData;
    const row = std.math.mul(u32, width, 4) catch return error.InvalidPixelData;
    return std.math.mul(usize, row, height) catch return error.InvalidPixelData;
}

fn calcMipLevelCount(width: u32, height: u32) u32 {
    var m: u32 = @max(width, height);
    var levels: u32 = 1;
    while (m > 1) : (m /= 2) levels += 1;
    return levels;
}

fn textureByteLength(width: u32, height: u32, levels: u32) u64 {
    var w: u64 = width;
    var h: u64 = height;
    var total: u64 = 0;
    for (0..levels) |_| {
        total +|= w *| h *| 4;
        w = @max(1, w / 2);
        h = @max(1, h / 2);
    }
    return total;
}

fn canAtlasTexture(width: u32, height: u32) bool {
    return width <= ATLAS_MAX_TEXTURE_SIZE and height <= ATLAS_MAX_TEXTURE_SIZE;
}

fn allocAtlasOnPage(page: *AtlasPage, width: u32, height: u32) ?[2]u32 {
    const padded_w = width + ATLAS_GUTTER * 2;
    const padded_h = height + ATLAS_GUTTER * 2;
    if (padded_w > ATLAS_PAGE_SIZE or padded_h > ATLAS_PAGE_SIZE) return null;

    if (page.next_x + padded_w > ATLAS_PAGE_SIZE) {
        page.next_x = 0;
        page.next_y += page.shelf_height;
        page.shelf_height = 0;
    }
    if (page.next_y + padded_h > ATLAS_PAGE_SIZE) return null;

    const inner_x = page.next_x + ATLAS_GUTTER;
    const inner_y = page.next_y + ATLAS_GUTTER;
    page.next_x += padded_w;
    page.shelf_height = @max(page.shelf_height, padded_h);
    return .{ inner_x, inner_y };
}

fn atlasRegionUvRect(x: u32, y: u32, width: u32, height: u32, page_size: u32) [4]f32 {
    const inv = 1.0 / @as(f32, @floatFromInt(page_size));
    return .{
        (@as(f32, @floatFromInt(x)) + 0.5) * inv,
        (@as(f32, @floatFromInt(y)) + 0.5) * inv,
        (@as(f32, @floatFromInt(x + width)) - 0.5) * inv,
        (@as(f32, @floatFromInt(y + height)) - 0.5) * inv,
    };
}

fn composeUvRect(base: [4]f32, uv: [4]f32) [4]f32 {
    const du = base[2] - base[0];
    const dv = base[3] - base[1];
    return .{
        base[0] + du * uv[0],
        base[1] + dv * uv[1],
        base[0] + du * uv[2],
        base[1] + dv * uv[3],
    };
}

fn makePaddedAtlasPixels(allocator: std.mem.Allocator, width: u32, height: u32, rgba_data: []const u8, gutter: u32) ![]u8 {
    const padded_w = width + gutter * 2;
    const padded_h = height + gutter * 2;
    const dst_len = @as(usize, padded_w) * @as(usize, padded_h) * 4;
    var dst = try allocator.alloc(u8, dst_len);
    @memset(dst, 0);

    var y: u32 = 0;
    while (y < padded_h) : (y += 1) {
        const src_y = clampEdgeIndex(y, gutter, height);
        var x: u32 = 0;
        while (x < padded_w) : (x += 1) {
            const src_x = clampEdgeIndex(x, gutter, width);
            const src_index = (@as(usize, src_y) * @as(usize, width) + @as(usize, src_x)) * 4;
            const dst_index = (@as(usize, y) * @as(usize, padded_w) + @as(usize, x)) * 4;
            @memcpy(dst[dst_index .. dst_index + 4], rgba_data[src_index .. src_index + 4]);
        }
    }
    return dst;
}

fn clampEdgeIndex(coord: u32, gutter: u32, span: u32) u32 {
    if (coord < gutter) return 0;
    if (coord >= gutter + span) return span - 1;
    return coord - gutter;
}

fn downsampleRgbaBox(src: []const u8, src_w: u32, src_h: u32, dst: []u8, dst_w: u32, dst_h: u32) void {
    var y: u32 = 0;
    while (y < dst_h) : (y += 1) {
        var x: u32 = 0;
        while (x < dst_w) : (x += 1) {
            const sx0: u32 = @min(src_w - 1, x * 2);
            const sy0: u32 = @min(src_h - 1, y * 2);
            const sx1: u32 = @min(src_w - 1, sx0 + 1);
            const sy1: u32 = @min(src_h - 1, sy0 + 1);

            const idx00 = (@as(usize, sy0) * @as(usize, src_w) + @as(usize, sx0)) * 4;
            const idx10 = (@as(usize, sy0) * @as(usize, src_w) + @as(usize, sx1)) * 4;
            const idx01 = (@as(usize, sy1) * @as(usize, src_w) + @as(usize, sx0)) * 4;
            const idx11 = (@as(usize, sy1) * @as(usize, src_w) + @as(usize, sx1)) * 4;
            const di = (@as(usize, y) * @as(usize, dst_w) + @as(usize, x)) * 4;

            // RGB 在 linear 空间做 box filter，再编码回 sRGB，避免 mip 偏灰
            var c: usize = 0;
            while (c < 3) : (c += 1) {
                const l0 = srgb8ToLinear(src[idx00 + c]);
                const l1 = srgb8ToLinear(src[idx10 + c]);
                const l2 = srgb8ToLinear(src[idx01 + c]);
                const l3 = srgb8ToLinear(src[idx11 + c]);
                const lavg = (l0 + l1 + l2 + l3) * 0.25;
                dst[di + c] = linearToSrgb8(lavg);
            }

            // Alpha 在线性标量空间做平均
            const alpha_sum: u32 = @as(u32, src[idx00 + 3]) + @as(u32, src[idx10 + 3]) + @as(u32, src[idx01 + 3]) + @as(u32, src[idx11 + 3]);
            dst[di + 3] = @intCast(alpha_sum / 4);
        }
    }
}

// ============================================================================
// sRGB ↔ linear 转换查表
//
// mip 链生成（uploadMipChain -> downsampleRgbaBox）对**每个像素的每个通道**
// 都要做一次往返转换。原实现每次调 std.math.pow，一张 6016×3384 的 Retina
// 全屏截图整条 mip 链约需 6800 万次 pow，实测 ReleaseFast 下耗时 1195ms，
// 主线程直接卡死一秒多。
//
// 正向输入是 u8，只有 256 种取值 -> 256 项表，**与原实现逐位相同，无精度损失**。
// 反向输入是 f32，用 12bit 量化表近似；mip 是缩略图，该精度绰绰有余
// （最大误差 < 1/255，肉眼与逐位比对均不可见）。
//
// 实测（ReleaseFast，6016×3384 完整 mip 链）：
//   原实现          1195 ms
//   仅正向 LUT        88 ms   (13.6×)
//   正反向都 LUT      21 ms   (57×)
// ============================================================================

const SRGB_TO_LINEAR_LUT: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*e, i| {
        const c = @as(f32, @floatFromInt(i)) / 255.0;
        e.* = if (c <= 0.04045)
            c / 12.92
        else
            std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
    break :blk table;
};

/// 反向表的量化档数（12bit）。+1 是为了让 v==1.0 能直接索引到末项，
/// 省掉一次 clamp 分支。
const LINEAR_TO_SRGB_STEPS = 4096;

const LINEAR_TO_SRGB_LUT: [LINEAR_TO_SRGB_STEPS + 1]u8 = blk: {
    @setEvalBranchQuota(3_000_000);
    var table: [LINEAR_TO_SRGB_STEPS + 1]u8 = undefined;
    for (&table, 0..) |*e, i| {
        const c = @as(f32, @floatFromInt(i)) / @as(f32, LINEAR_TO_SRGB_STEPS);
        const srgb = if (c <= 0.0031308)
            c * 12.92
        else
            1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
        e.* = @intFromFloat(@round(@max(0.0, @min(srgb, 1.0)) * 255.0));
    }
    break :blk table;
};

inline fn srgb8ToLinear(v: u8) f32 {
    return SRGB_TO_LINEAR_LUT[v];
}

inline fn linearToSrgb8(v: f32) u8 {
    const clamped = @max(0.0, @min(v, 1.0));
    const idx: usize = @intFromFloat(@round(clamped * @as(f32, LINEAR_TO_SRGB_STEPS)));
    return LINEAR_TO_SRGB_LUT[idx];
}

/// Whether a slot kind owns its texture storage (destroyed by this renderer).
/// atlas_region 共享图集页（页由 atlas_pages 循环统一释放，再放就是 double-release
/// -> 退出必崩，下游回归）；external storage remains caller-owned.
fn slotOwnsTexture(kind: TextureKind) bool {
    return kind == .standalone or kind == .stream;
}

test "deinit texture ownership: standalone and stream own storage (downstream regression)" {
    try std.testing.expect(slotOwnsTexture(.standalone));
    try std.testing.expect(slotOwnsTexture(.stream));
    try std.testing.expect(!slotOwnsTexture(.atlas_region));
    try std.testing.expect(!slotOwnsTexture(.external));
}

test "srgb8ToLinear LUT is bit-exact vs reference pow implementation" {
    // 正向输入只有 256 种取值，查表必须与直算**逐位相同**（不是近似）。
    for (0..256) |i| {
        const v: u8 = @intCast(i);
        const c = @as(f32, @floatFromInt(v)) / 255.0;
        const reference = if (c <= 0.04045)
            c / 12.92
        else
            std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
        try std.testing.expectEqual(reference, srgb8ToLinear(v));
    }
}

test "linearToSrgb8 LUT stays within 1/255 of reference" {
    // 反向是 12bit 量化近似；断言误差不超过 1 个 u8 级差。
    var i: u32 = 0;
    while (i <= 2048) : (i += 1) {
        const v = @as(f32, @floatFromInt(i)) / 2048.0;
        const reference_srgb = if (v <= 0.0031308)
            v * 12.92
        else
            1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
        const reference: u8 = @intFromFloat(@round(@max(0.0, @min(reference_srgb, 1.0)) * 255.0));
        const actual = linearToSrgb8(v);
        const diff = @abs(@as(i16, actual) - @as(i16, reference));
        try std.testing.expect(diff <= 1);
    }
}

test "sRGB round-trip preserves endpoints exactly" {
    // 端点必须精确：全黑/全白经过 mip 降采样不能漂移。
    try std.testing.expectEqual(@as(u8, 0), linearToSrgb8(srgb8ToLinear(0)));
    try std.testing.expectEqual(@as(u8, 255), linearToSrgb8(srgb8ToLinear(255)));
}

test "atlas allocator packs shelves and wraps rows" {
    var page = AtlasPage{ .texture = undefined };
    try std.testing.expectEqual([2]u32{ 1, 1 }, allocAtlasOnPage(&page, 16, 16).?);
    try std.testing.expectEqual([2]u32{ 19, 1 }, allocAtlasOnPage(&page, 8, 8).?);

    page.next_x = ATLAS_PAGE_SIZE - (8 + ATLAS_GUTTER * 2) + 1;
    page.next_y = 32;
    page.shelf_height = 20;
    try std.testing.expectEqual([2]u32{ 1, 53 }, allocAtlasOnPage(&page, 8, 8).?);
}

test "composeUvRect remaps sub-uv into atlas region" {
    const base = [4]f32{ 0.25, 0.5, 0.75, 1.0 };
    const uv = [4]f32{ 0.1, 0.2, 0.6, 0.8 };
    const out = composeUvRect(base, uv);
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), out[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.60), out[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), out[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.90), out[3], 0.0001);
}

test "makePaddedAtlasPixels duplicates edge texels into gutter" {
    const allocator = std.testing.allocator;
    const rgba = [_]u8{
        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,
    };
    const padded = try makePaddedAtlasPixels(allocator, 2, 2, &rgba, 1);
    defer allocator.free(padded);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), padded.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, padded[0..4]);
    const bottom_right = ((@as(usize, 3) * 4) + 3) * 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 13, 14, 15, 16 }, padded[bottom_right .. bottom_right + 4]);
}

test "ImageInstance ABI matches image shader layout" {
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(ImageInstance, "rect_clip"));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(ImageInstance));
}

test "texture namespaces and generations reject released handles and wrong owners" {
    var device: gpu.Backend.Device = undefined;
    var local = ImageTextureStore.init(std.testing.allocator, &device, false);
    defer local.deinit();
    var shared = ImageTextureStore.init(std.testing.allocator, &device, true);
    defer shared.deinit();
    const binding = gpu.Backend.TextureBinding.testBinding(16, 1, 1);
    const local_id = try local.registerTextureBinding(binding, 1, 1);
    const shared_id = try shared.registerTextureBinding(binding, 2, 3);
    try std.testing.expect(local_id != shared_id);
    try std.testing.expect(local.getTextureSize(shared_id) == null);
    try std.testing.expect(shared.getTextureSize(local_id) == null);
    local.unloadTexture(shared_id);
    try std.testing.expectEqual([2]u32{ 1, 1 }, local.getTextureSize(local_id).?);
    shared.unregisterTextureBinding(shared_id);
    const replacement = try shared.registerTextureBinding(binding, 4, 5);
    try std.testing.expect(replacement != shared_id);
    shared.unloadTexture(shared_id);
    try std.testing.expect(shared.getTextureSize(shared_id) == null);
    try std.testing.expectEqual([2]u32{ 4, 5 }, shared.getTextureSize(replacement).?);
    shared.unregisterTextureBinding(replacement);
    // 持久槽位：generation 耗尽即退役（旧句柄可能被 app 长期缓存，不能回绕）。
    shared.textures[0] = .{ .kind = .standalone, .binding = binding, .width = 1, .height = 1, .mip_level_count = 1 };
    shared.generations[0] = MAX_GENERATION;
    const last_persistent = shared.handle(0);
    shared.unloadTexture(last_persistent);
    try std.testing.expect(shared.getTextureSize(last_persistent) == null);
    try std.testing.expectEqual(@as(u32, 1), try shared.allocateTextureSlot());
}

test "external 绑定槽位 generation 回绕：高频 register/unregister 不会耗尽" {
    // 回归：每次 unregister 都 bump generation，到 MAX_GENERATION 的槽位永久
    // 退役。离屏/retained/glass 合成每帧注册数十次 -> 约一周后 TooManyTextures，
    // 所有 opacity 层消失。
    var device: gpu.Backend.Device = undefined;
    var store = ImageTextureStore.init(std.testing.allocator, &device, false);
    defer store.deinit();
    const binding = gpu.Backend.TextureBinding.testBinding(16, 1, 1);

    // 把全部 external 槽位推到 generation 上限：旧实现下它们全部退役。
    for (EXTERNAL_SLOT_BASE..MAX_TEXTURES) |i| store.generations[i] = MAX_GENERATION;
    var i: usize = 0;
    var prev: TextureId = 0;
    while (i < EXTERNAL_SLOT_COUNT * 2) : (i += 1) {
        const id = try store.registerTextureBinding(binding, 8, 8);
        try std.testing.expect((id & SLOT_MASK) >= EXTERNAL_SLOT_BASE);
        try std.testing.expectEqual([2]u32{ 8, 8 }, store.getTextureSize(id).?);
        store.unregisterTextureBinding(id);
        // 注销后旧句柄立即失效（回绕到 0 也不等于旧 generation）
        try std.testing.expect(store.getTextureSize(id) == null);
        if (i > 0) try std.testing.expect(id != prev);
        prev = id;
    }
    // 持久区间一个槽位都没被 external 占用
    for (store.textures[0..EXTERNAL_SLOT_BASE]) |slot| try std.testing.expect(slot == null);
    try std.testing.expectEqual(@as(u32, 0), store.generations[0]);
}

test "image instance preparation failure cannot leave mismatched instance and texture arrays" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var renderer: ImageRenderer = undefined;
        renderer.allocator = failing.allocator();
        renderer.shared_texture_store = null;
        renderer.texture_store = ImageTextureStore.init(std.testing.allocator, undefined, false);
        defer renderer.texture_store.deinit();
        renderer.instances = .{};
        defer renderer.instances.deinit(renderer.allocator);
        renderer.instance_textures = .{};
        defer renderer.instance_textures.deinit(renderer.allocator);
        renderer.current_rect_clip = .{ 0, 0, -1, -1 };
        const id = try renderer.texture_store.registerTextureBinding(gpu.Backend.TextureBinding.testBinding(16, 1, 1), 1, 1);
        try std.testing.expectError(error.OutOfMemory, renderer.addImage(id, 0, 0, 1, 1, 0, 1));
        try std.testing.expectEqual(@as(usize, 0), renderer.instances.items.len);
        try std.testing.expectEqual(@as(usize, 0), renderer.instance_textures.items.len);
    }
}

test "invalid image dimensions fail before touching the GPU" {
    var store = ImageTextureStore.init(std.testing.allocator, undefined, true);
    defer store.deinit();
    try std.testing.expectError(error.InvalidPixelData, store.loadTexture(0, 2, &.{}));
    try std.testing.expectError(error.InvalidPixelData, store.loadTexture(std.math.maxInt(u32), 2, &.{}));
    try std.testing.expectError(error.InvalidPixelData, store.createStreamTexture(std.math.maxInt(u32), 2));
    try std.testing.expectEqual(@as(u32, 0), store.texture_count);
}

test "resident texture bytes include exact thin and odd mip levels" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 16380), textureByteLength(2048, 1, calcMipLevelCount(2048, 1)));
    try t.expectEqual(@as(u64, 16380), textureByteLength(1, 2048, calcMipLevelCount(1, 2048)));
    try t.expectEqual(@as(u64, 60 + 8 + 4), textureByteLength(5, 3, calcMipLevelCount(5, 3)));
    try t.expectEqual(@as(u64, 22369620), textureByteLength(2048, 2048, calcMipLevelCount(2048, 2048)));
    try t.expectEqual(@as(u64, 16), textureByteLength(2, 2, 1));
}
