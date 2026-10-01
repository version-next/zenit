/// AppRenderer - 顶层渲染协调器
///
/// 封装完整的 UI -> 屏幕管线:
///   1. cx.layout()，计算布局
///   2. cx.render(), paint pass，填 cx.display_list
///   3. encoder.encodeDisplay(cx)，编码到 sdf/text/image renderer
///   4. flush(render_pass)，提交 GPU
///   5. surface.present()，显示帧
///
/// 用法:
/// ```
/// var app_renderer = try AppRenderer.init(allocator, &device, &queue, &surface, &window);
/// defer app_renderer.deinit();
///
/// // 设置字体
/// app_renderer.setFonts(&font_selector);
///
/// // 渲染循环
/// while (window.pollEvents()) {
///     try app_renderer.frame(cx, viewport_w, viewport_h, scale);
/// }
/// ```
const std = @import("std");
const gpu = @import("gpu");
const render = @import("render");
const render_pacing = @import("render_pacing.zig");
const SdfRenderer = render.SdfRenderer;
const ImageRenderer = render.ImageRenderer;
const IconRenderer = render.IconRenderer;
const TextRenderer = render.TextRenderer;
const RenderCommandEncoder = render.RenderCommandEncoder;
const FontSelector = render.FontSelector;
const TextFontProps = render.TextFontProps;

/// Stable FontSelector -> TextRenderer bridge.
///
/// AppRenderer owns TextRenderer for its whole lifetime, while frame encoders
/// are stack temporaries. Keeping this binding here makes `setFonts` the one
/// framework-level place that establishes the measure == draw contract.
fn measureWidthAsDrawn(ctx: *anyopaque, text: []const u8, font: *render.Font, props: TextFontProps) ?f32 {
    const text_renderer: *TextRenderer = @ptrCast(@alignCast(ctx));
    var fixed_advance: f32 = 0;
    if (props.use_monospace and props.monospace_char_width > 0) {
        var all_ascii = true;
        for (text) |byte| {
            if (byte >= 0x80) {
                all_ascii = false;
                break;
            }
        }
        if (all_ascii) fixed_advance = props.monospace_char_width;
    }
    return text_renderer.measureTextWidthAsDrawn(
        text,
        font,
        props.font_size,
        props.use_italic,
        fixed_advance,
    ) catch null;
}

/// Keep CPU in-flight slots aligned with the renderers' triple-buffered
/// instance storage. Dropping this below 3 made frame pacing depend too much
/// on CAMetalLayer drawable availability and pushed jitter into acquireTexture.
const FRAME_BUFFER_COUNT = render_pacing.frames_in_flight;
/// 帧性能统计，每帧自动收集，通过 getLastFrameStats() 暴露给 DevTools
pub const FrameStats = struct {
    /// 布局计算耗时（微秒）
    layout_us: u64 = 0,
    /// 渲染命令生成耗时（微秒）
    render_gen_us: u64 = 0,
    /// GPU 编码 + 提交耗时（微秒）
    gpu_encode_us: u64 = 0,
    /// 等待上一帧 GPU 完成/下一帧配额的耗时（微秒）
    wait_for_frame_us: u64 = 0,
    /// 获取 drawable / surface texture 的耗时（微秒）
    acquire_texture_us: u64 = 0,
    /// 纯 CPU 管线耗时（layout + render + encode + flush，不含 wait/acquire）
    cpu_frame_us: u64 = 0,
    /// **真 GPU 执行时间**（微秒），取自 backend command-buffer timestamp
    /// interval。区别于 gpu_encode_us（那是 CPU 侧编码+提交
    /// 的墙钟，混入 wait/acquire）。
    /// 时序说明：GPU 时间戳只有在 command buffer **完成之后**才有效，
    /// 而本帧的 buffer 刚提交，故这里报告的是**上一帧**的 GPU 时间,
    /// 稳态下这正是想要的量级信息；0 表示尚未有已完成的帧。
    gpu_execute_us: u64 = 0,
    /// 编码耗时（encodeDisplay，微秒）
    encode_us: u64 = 0,
    /// flush + end render pass 耗时（微秒）
    flush_us: u64 = 0,
    /// path 管线本帧实际发出的 GPU draw 数（合批后）
    path_draw_calls: u32 = 0,
    /// GPU retained 合成：本帧整层缓存命中 / 重画 / damage-rect 部分重画次数
    retained_hits: u32 = 0,
    retained_misses: u32 = 0,
    retained_partial_repaints: u32 = 0,
    /// icon 管线本帧 GPU draw 数
    icon_draw_calls: u32 = 0,
    /// image 管线本帧 GPU draw 数（连续同纹理合批后）
    image_draw_calls: u32 = 0,
    /// image 管线本帧实例数
    image_instances: u32 = 0,
    /// image 管线本帧纹理绑定切换次数，图片密集画布的真实瓶颈指标
    texture_binds: u32 = 0,
    /// SDF 管线本帧 GPU draw 数
    sdf_draw_calls: u32 = 0,
    /// text 管线本帧 GPU draw 数
    text_draw_calls: u32 = 0,
    /// 本帧实际发出的 GPU draw call 总数（sdf + text + path + icon + image 累加）
    draw_calls: u32 = 0,
    /// SDF 实例数
    sdf_instances: u32 = 0,
    /// 文本字形实例数
    text_instances: u32 = 0,
    /// 渲染命令总数
    command_count: u32 = 0,
    /// 帧总耗时（微秒）
    total_frame_us: u64 = 0,
};

/// 跨帧计时采样环（P95 门禁用）。实现与单测在 timing_ring.zig,
/// 那里不依赖 Metal/ObjC 桥，才能被 `zig build test` 真正覆盖。
pub const TimingRing = @import("timing_ring.zig").TimingRing;

/// 帧清除颜色
pub const ClearColor = struct {
    r: f32 = 0.08,
    g: f32 = 0.08,
    b: f32 = 0.10,
    a: f32 = 1.0,
};

/// AppRenderer 配置
pub const Config = struct {
    clear_color: ClearColor = .{},
    /// Optional eager glyph upload; draw encoding still resolves missing glyphs.
    prewarm_text: bool = true,
};

pub const RecordingFrameFn = *const fn (texture: *const gpu.Backend.Texture) bool;

/// AppRenderer - 封装完整渲染管线
pub const AppRenderer = struct {
    allocator: std.mem.Allocator,

    // GPU 基础设施 (借用，不拥有)
    device: *gpu.Backend.Device,
    queue: *gpu.Backend.Queue,
    surface: *gpu.Backend.Surface,

    // 渲染器 (拥有)
    sdf_renderer: SdfRenderer,
    image_renderer: ImageRenderer,
    icon_renderer: IconRenderer,
    text_renderer: TextRenderer,

    // 字体（借用，不拥有）
    fonts: ?*FontSelector = null,

    // 配置
    config: Config,

    // 帧统计
    frame_count: u64 = 0,
    /// 累计 retained 计数（跨帧单调递增；/stats 用，per-frame 值会被后续
    /// settle/idle 帧覆盖，e2e 断言需要累计量）
    total_retained_hits: u64 = 0,
    total_retained_misses: u64 = 0,
    total_retained_partial_repaints: u64 = 0,
    /// backdrop 亮度自适应：上一帧玻璃 backdrop 的平均 luminance（linear 0~1）
    backdrop_luminance: ?f32 = null,
    /// 上一帧性能统计
    last_frame_stats: FrameStats = .{},
    /// 跨帧计时采样环（P95 门禁用）。`last_frame_stats` 只是单帧快照，
    /// 而单帧计时噪声极大，e2e 想要的是"最近 N 帧的 P95"这种抗噪统计量。
    timing_ring: TimingRing = .{},
    /// 上一**渲染**帧的起始时刻（idle 跳帧不更新），DevTools FPS 的帧间隔
    /// 采样基准。用 renderer 自己的墙钟而非 cx.frame_dt_seconds：后者被钳到
    /// 0.1s，区分不出「100ms 卡帧」和「idle 停帧 5s 后恢复」。
    prev_frame_start: ?std.time.Instant = null,

    // GPU 帧同步，防止 CPU 覆盖 GPU 正在读取的 triple buffer
    // 平台抽象：Metal 用 dispatch_semaphore，未来 Vulkan 用 VkFence
    frame_sync: gpu.Backend.FrameSync,

    // 离屏纹理池 + 帧计数，必须活在 AppRenderer（跨帧持久）。encoder 是逐帧
    // 局部值：池若内嵌其中，每帧 deinit 整池释放，跨帧纹理复用从未发生；
    // frame_index 每帧从 0 重来，池的 REUSE_LAG_FRAMES in-flight 保护同样失效。
    offscreen_pool: render.OffscreenTexturePool = .{},
    /// 跨帧持久的 path/blur/glass GPU 资源（PSO、buffer、sampler、tessellator）。
    /// 与 offscreen_pool 同理必须活在 AppRenderer，内嵌进逐帧 encoder 会每帧
    /// 重新 runtime 编译 MSL，连续 path/blur 动画每帧抖动（审查报告 P1）。
    persistent_gpu: render.PersistentGpuCache = .{},
    frame_counter: u64 = 0,
    /// icon 管线 draw 计数是模块级累计值；存上帧总量以取每帧增量
    prev_icon_draw_calls_total: u64 = 0,
    prev_image_draw_calls_total: u64 = 0,
    prev_sdf_draw_calls_total: u64 = 0,
    prev_text_draw_calls_total: u64 = 0,
    prev_image_instances_total: u64 = 0,
    prev_texture_binds_total: u64 = 0,

    /// 上一帧已提交的 command buffer（仅用于**下一帧**读取其 GPU 时间戳,
    /// GPUStartTime/GPUEndTime 必须在 buffer 完成后才有效）。
    /// 包装器持有额外引用，随下一帧读完即释放；上层不观察 native handle。
    prev_frame_cmd_buffer: ?gpu.Backend.CommandBuffer = null,

    // ── e2e:上一次**真实呈现**帧的保留拷贝 ──────────────────────────
    // /screenshot 曾经"驱动一帧新渲染再 readback"，新帧会把 pending 的
    // 布局/标脏顺带跑完,截到的画面比屏幕上的新。呈现层 bug(Layers 残影)
    // 期间:屏幕满是残影、截图完全干净,e2e 全绿,误判持续了三天。
    // 修法:每帧 present 前把 drawable blit 到保留纹理;截图直接读它,
    // 不再驱动帧。仅 harness 模式开启(blit 每帧 ~0.1ms GPU,不进 CPU 帧预算)。
    retain_present_copy: bool = false,
    retained_tex: ?gpu.Backend.Texture = null,
    retained_w: u32 = 0,
    retained_h: u32 = 0,
    retained_valid: bool = false,

    // E2E 截图请求，由 test harness 的 screenshot callback 设置（test-mode）。
    // 实际像素读取在 frame() 内 present 前做（drawable 仍有效 + GPU 已完成）。
    // 单帧只服务一次请求；读完即清空。容量 512 与 RPC payload 路径上限一致。
    pending_screenshot_path: ?[512]u8 = null,
    pending_screenshot_len: usize = 0,
    last_screenshot_ok: bool = false,

    // Harness video recording. The callback receives a completed drawable and
    // immediately GPU-blits it into the platform encoder's pixel-buffer pool.
    recording_active: bool = false,
    recording_frame_fn: ?RecordingFrameFn = null,

    /// 初始化 AppRenderer
    ///
    /// 创建 sdf/image/text renderer，封装渲染管线。
    pub fn init(
        allocator: std.mem.Allocator,
        device: *gpu.Backend.Device,
        queue: *gpu.Backend.Queue,
        surface: *gpu.Backend.Surface,
        config: Config,
    ) !AppRenderer {
        var sdf_renderer = try SdfRenderer.init(allocator, device);
        errdefer sdf_renderer.deinit();

        var image_renderer = try ImageRenderer.init(allocator, device);
        errdefer image_renderer.deinit();

        var icon_renderer = try IconRenderer.init(allocator, device);
        errdefer icon_renderer.deinit();

        var text_renderer = try TextRenderer.init(allocator, device);
        errdefer text_renderer.deinit();

        return AppRenderer{
            .allocator = allocator,
            .device = device,
            .queue = queue,
            .surface = surface,
            .sdf_renderer = sdf_renderer,
            .image_renderer = image_renderer,
            .icon_renderer = icon_renderer,
            .text_renderer = text_renderer,
            .config = config,
            .frame_sync = gpu.Backend.FrameSync.init(FRAME_BUFFER_COUNT),
        };
    }

    /// 获取已正确绑定的 RenderCommandEncoder（自动携带字体 + 持久离屏纹理池）
    pub fn getEncoder(self: *AppRenderer) RenderCommandEncoder {
        var enc = RenderCommandEncoder.initWithImageAndIcon(&self.sdf_renderer, &self.text_renderer, &self.image_renderer, &self.icon_renderer, &self.offscreen_pool, &self.persistent_gpu);
        // 复位帧内游标（uniform 环形写偏移等），但保留 pipeline/buffer 本身。
        self.persistent_gpu.beginFrame();
        // 帧计数由 AppRenderer 承载（encoder 逐帧新建，自增会每帧归零）。
        self.frame_counter += 1;
        enc.frame_index = self.frame_counter;
        if (self.fonts) |f| enc.setFonts(f);
        return enc;
    }

    /// 设置字体选择器，并把测量绑定到生命周期稳定的 TextRenderer。
    /// 任何经 AppRenderer 绘制的字体都因此默认满足 measure == draw；宿主不再
    /// 需要另装一份容易漏掉或误绑到逐帧 encoder 的 callback。
    pub fn setFonts(self: *AppRenderer, fonts: *FontSelector) void {
        if (self.fonts) |previous| {
            if (previous.drawn_width_ctx == @as(*anyopaque, @ptrCast(&self.text_renderer))) {
                previous.setDrawnWidthSource(null, null);
            }
        }
        self.fonts = fonts;
        fonts.setDrawnWidthSource(&measureWidthAsDrawn, @ptrCast(&self.text_renderer));
    }

    pub fn setRecordingFrameCallback(self: *AppRenderer, callback: RecordingFrameFn) void {
        self.recording_frame_fn = callback;
    }

    pub fn setRecordingActive(self: *AppRenderer, active: bool) void {
        self.recording_active = active;
    }

    /// E2E：请求在下一帧 present 前把当前 drawable 像素截图到 PNG。
    /// 真实读取发生在 frame() 内（见 captureSurfaceToPng）。返回 true 表示已登记请求。
    /// 注意：drawable 必须 framebufferOnly=false（test-mode 下 surface 用
    /// .color_target_and_read 配置），否则 getBytes 读不到像素。
    /// 纹理内存用量快照（图片画布做 LRU 预算驱逐用）。
    pub fn textureMemoryStats(self: *const AppRenderer) render.TextureMemoryStats {
        return self.image_renderer.getTextureMemoryStats();
    }

    pub fn requestCapture(self: *AppRenderer, path: []const u8) bool {
        if (path.len == 0 or path.len >= 512) return false;
        var buf: [512]u8 = undefined;
        @memcpy(buf[0..path.len], path);
        self.pending_screenshot_path = buf;
        self.pending_screenshot_len = path.len;
        self.last_screenshot_ok = false;
        return true;
    }

    /// 从 surface 纹理读 BGRA8 -> 转 RGBA8 -> 写 PNG。present 前调用。
    /// cmd_buffer 必须已 waitUntilCompleted，保证渲染结果已落到纹理。
    fn captureSurfaceToPng(self: *AppRenderer, texture: *const gpu.Backend.Texture, width: u32, height: u32) bool {
        if (width == 0 or height == 0) return false;
        const px = @as(usize, width) * @as(usize, height);
        const bytes_per_row: u32 = width * 4;

        const bgra = self.allocator.alloc(u8, px * 4) catch return false;
        defer self.allocator.free(bgra);
        const rgba = self.allocator.alloc(u8, px * 4) catch return false;
        defer self.allocator.free(rgba);

        texture.readBgra8(width, height, bgra, bytes_per_row) catch return false;

        // BGRA -> RGBA 字节交换
        var i: usize = 0;
        while (i < px * 4) : (i += 4) {
            rgba[i] = bgra[i + 2]; // R ← B 位置
            rgba[i + 1] = bgra[i + 1]; // G
            rgba[i + 2] = bgra[i]; // B ← R 位置
            rgba[i + 3] = bgra[i + 3]; // A
        }

        const path_slice = self.pending_screenshot_path.?[0..self.pending_screenshot_len];
        var path_z: [512:0]u8 = undefined;
        @memcpy(path_z[0..path_slice.len], path_slice);
        path_z[path_slice.len] = 0;

        return gpu.Backend.writePngRgba(&path_z, rgba, width, height, bytes_per_row);
    }

    /// 读任意 BGRA8 纹理 -> RGBA8 -> 写 PNG(与 captureSurfaceToPng 同管线,
    /// 但 path 显式传入,不依赖 pending_screenshot_* 状态)。
    fn textureToPng(self: *AppRenderer, texture: *const gpu.Backend.Texture, width: u32, height: u32, path: []const u8) bool {
        if (width == 0 or height == 0 or path.len == 0 or path.len >= 512) return false;
        const px = @as(usize, width) * @as(usize, height);
        const bytes_per_row: u32 = width * 4;
        const bgra = self.allocator.alloc(u8, px * 4) catch return false;
        defer self.allocator.free(bgra);
        const rgba = self.allocator.alloc(u8, px * 4) catch return false;
        defer self.allocator.free(rgba);
        texture.readBgra8(width, height, bgra, bytes_per_row) catch return false;
        var i: usize = 0;
        while (i < px * 4) : (i += 4) {
            rgba[i] = bgra[i + 2];
            rgba[i + 1] = bgra[i + 1];
            rgba[i + 2] = bgra[i];
            rgba[i + 3] = bgra[i + 3];
        }
        var path_z: [512:0]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        return gpu.Backend.writePngRgba(&path_z, rgba, width, height, bytes_per_row);
    }

    /// e2e 截图的**首选路径**:读上一次真实呈现帧的保留拷贝。
    /// 返回 false = 还没有保留帧(启动初期/未开启),调用方走旧路径兜底。
    pub fn captureRetainedToPng(self: *AppRenderer, path: []const u8) bool {
        if (!self.retained_valid) return false;
        const tex = &(self.retained_tex orelse return false);
        // blit 编在上一帧的 command stream 里,读之前必须确认 GPU 已完成,
        // 否则读到半写的内容(稳态下早已完成,这里只是边缘竞态保险)。
        if (self.prev_frame_cmd_buffer) |*prev| prev.waitUntilCompleted();
        return self.textureToPng(tex, self.retained_w, self.retained_h, path);
    }

    /// 保证保留纹理与当前 surface 尺寸一致(resize 时重建)。
    fn ensureRetainedTexture(self: *AppRenderer, width: u32, height: u32) bool {
        if (self.retained_tex != null and self.retained_w == width and self.retained_h == height) return true;
        if (self.retained_tex) |*t| t.destroy();
        self.retained_tex = null;
        self.retained_valid = false;
        const tex = self.device.createTexture(self.allocator, .{
            .label = "e2e-retained-present",
            .size = .{ .width = width, .height = height, .depth = 1 },
            .format = .bgra8_unorm,
            .usage = .{ .copy_src = true, .copy_dst = true },
            // ⚠ 必须 host_upload(CPU 可读的 shared storage)。默认 device_local
            // 在 Apple Silicon 上是 GPU 私有压缩布局,getBytes 直接 SIGSEGV
            // (实测崩在 AGX processCompressedRegion2D)。
            .memory = .host_upload,
        }) catch return false;
        self.retained_tex = tex;
        self.retained_w = width;
        self.retained_h = height;
        return true;
    }

    /// 初始化 AppRenderer 内部 FontSelector 的 lazy derived font cache
    /// FontSelector 为借用引用，调用方负责生命周期
    pub fn initFontDerivedCache(self: *AppRenderer, allocator: std.mem.Allocator) void {
        if (self.fonts) |fs| {
            fs.initDerivedCache(allocator);
        }
    }

    /// 释放 AppRenderer 内部 FontSelector 的 lazy derived font cache
    /// FontSelector 为借用引用，调用方应仅在全局销毁点调用一次
    pub fn deinitFontDerivedCache(self: *AppRenderer) void {
        if (self.fonts) |fs| {
            fs.deinitDerivedCache();
        }
    }

    /// 渲染一帧，使用 UI Cx 上下文
    ///
    /// 完整流程:
    ///   1. cx.layout()
    ///   2. cx.render(), paint pass 填 cx.display_list
    ///   3. encode -> rect/text renderer
    ///   4. 创建 GPU encoder + render pass
    ///   5. flush + present
    pub fn frame(self: *AppRenderer, cx: anytype, viewport_width: f32, viewport_height: f32, scale: f32) !void {
        const frame_start = std.time.Instant.now() catch null;
        var wait_start: ?std.time.Instant = null;
        var wait_end: ?std.time.Instant = null;

        // 0. 推进帧时钟（必须在 layout/render 之前，before_render hooks / overlay
        // enter-exit / spinner 等动画都读 frame_time_ms）。advanceFrameClock 内部对
        // idle 帧（整树 clean + 无浮层动画 + 无 needs_redraw）跳过推进，保持零脏帧
        // 快速路径成立；任一活跃信号（含 spinner 的 markRenderDirty 让树非 clean）会
        // 让时钟前进，驱动连续动画。没有这一步，frame_time_ms 永远冻结 -> spinner/
        // overlay 动画全静止。
        cx.advanceFrameClock();

        // 1. 布局
        const layout_start = std.time.Instant.now() catch null;
        cx.layout();
        const layout_end = std.time.Instant.now() catch null;

        // 2. 生成渲染命令
        // cx.render() 跑 paint pass 填 cx.display_list；encoder 通过 enc.encodeDisplay(cx)
        // 自己调 cx.lowerForEncoder() 拿 lowered DisplayItem 切片。调用方不持有 IR。
        const render_start = std.time.Instant.now() catch null;
        _ = cx.render();
        const render_end = std.time.Instant.now() catch null;

        var enc = self.getEncoder();
        defer enc.deinit();
        enc.beginFrame(viewport_width, viewport_height, scale);
        if (self.config.prewarm_text) try enc.prewarmDisplay(cx);

        // Delay the in-flight buffer wait until right before we touch the
        // triple-buffered GPU instance storage. This lets layout/render overlap
        // with the previous frame's GPU completion instead of idling at frame start.
        wait_start = std.time.Instant.now() catch null;
        self.frame_sync.waitForNextFrame();
        wait_end = std.time.Instant.now() catch null;
        // 错误路径归还 slot，防止连续失败后 semaphore 耗尽导致永久阻塞
        errdefer self.frame_sync.signal();

        // 3. 准备 GPU 提交
        const acquire_start = std.time.Instant.now() catch null;
        var surface_texture = try self.surface.acquireTexture(self.allocator);
        const acquire_end = std.time.Instant.now() catch null;
        defer surface_texture.deinit();

        var gpu_encoder = try gpu.Backend.CommandEncoder.init(self.queue);
        // 错误路径兜底：下面的 encodeDisplay / flush 都可能抛错提前返回，此时
        // finish() 从未被调用（state != .finished），command buffer 无人 release。
        // CommandEncoder.deinit 正是为这种"未 finish"的情况准备的，成功路径上
        // finish() 会把 state 置为 .finished，deinit 变成 no-op，所有权移交
        // cmd_buffer，不会重复释放。
        errdefer gpu_encoder.deinit();

        var texture_view = surface_texture.texture.binding().createView();
        defer texture_view.destroy();

        const cc = self.config.clear_color;
        var render_pass = try gpu_encoder.beginRenderPass(.{
            .color_attachments = &[_]gpu.RenderPassColorAttachment{
                .{
                    .view = texture_view,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{ .r = cc.r, .g = cc.g, .b = cc.b, .a = cc.a },
                },
            },
        });

        // 4. 编码（encoder 持有 render_pass 引用，clip stack 可用）
        const encode_start = std.time.Instant.now() catch null;
        // **关键（2026-06-07 CA-surface revamp 发现的根因）**：必须把 gpu_command_encoder +
        // main_render_target 绑给 encoder，否则 opacity_layer.beginOpacityLayer /
        // backdrop_blur 在 `gpu_command_encoder == null` 处直接 early-return -> 所有 offscreen
        // surface（modal/sheet opacity group fade、GlassBox backdrop blur）静默不工作，content
        // 退化成内联渲染、错位。缺了这两行绑定时 surface 路径"从未真正跑过",
        // 这正是 overlay fade 一直坏的真根因。
        enc.gpu_command_encoder = &gpu_encoder;
        enc.main_render_target = surface_texture.texture.binding();
        enc.render_pass = &render_pass;
        try enc.encodeDisplay(cx);
        const encode_end = std.time.Instant.now() catch null;
        const pending_sdf_instances = self.sdf_renderer.instances.items.len;
        const pending_text_instances = self.text_renderer.getPendingInstanceCount();

        // 5. 刷新到 GPU
        // 离屏合成（opacity surface / backdrop blur）会 end 原 render_pass 并新建一个
        // restored_pass，写回 enc.render_pass。故必须 flush/end **encoder 当前持有的 pass**
        // （可能已被替换），而不是本地 `render_pass`，否则会对已 end 的本地 pass 再 end 一次，
        // 触发 Metal `endEncoding has already been called` 断言崩溃。
        const flush_start = std.time.Instant.now() catch null;
        if (enc.render_pass) |rp| {
            try enc.flush(rp);
            rp.end();
        } else {
            // The original local value may already have been ended by an
            // offscreen effect. Never fall back to it: Metal can recycle its
            // Objective-C address for a blit encoder in the meantime.
            return error.MissingActiveRenderPass;
        }
        const flush_end = std.time.Instant.now() catch null;

        // e2e:把即将 present 的内容 blit 进保留纹理(见 retain_present_copy)。
        // 必须在 finish 之前编进同一 command stream。
        if (self.retain_present_copy) {
            const src = surface_texture.texture.binding();
            if (self.ensureRetainedTexture(src.width, src.height)) {
                if (gpu_encoder.beginBlitPass()) |*bp_const| {
                    var bp = bp_const.*;
                    // ⚠ 拷贝失败**不能**继续标 valid：captureRetainedToPng 是
                    // e2e 截图的首选路径，标了 valid 它就直接返回这张纹理，
                    // 内容却是上一帧（或全新纹理的未定义内容）。e2e 的像素
                    // 断言全建立在"截图 == 刚呈现的那帧"上，静默读旧帧会让
                    // 断言假绿，比截图失败更糟。
                    // 失败时清掉 valid，captureRetainedToPng 返回 false，
                    // 调用方回退到"重新渲染一帧"的旧路径。
                    if (bp.copyTextureRegion(src, 0, 0, src.width, src.height, self.retained_tex.?.binding(), 0, 0)) {
                        bp.end();
                        self.retained_valid = true;
                    } else |err| {
                        bp.end();
                        self.retained_valid = false;
                        std.log.warn("[renderer] retained present copy failed: {s}; e2e 截图回退到重渲染路径", .{@errorName(err)});
                    }
                } else |_| {}
            }
        }

        // 排障（ZENIT_DEBUG_GLASS_RT="x,y" 设备像素）：帧末 RT 指定区 64×64
        // blit 进 debug slot 2，renderer 下一帧回读 RGB 均值，与 capture/
        // composite 两级恒定值对照，三明治定位分叉阶段。
        if (std.posix.getenv("ZENIT_DEBUG_GLASS_RT")) |spec| blk: {
            var it = std.mem.splitScalar(u8, spec, ',');
            const rx = std.fmt.parseInt(u32, it.next() orelse break :blk, 10) catch break :blk;
            const ry = std.fmt.parseInt(u32, it.next() orelse break :blk, 10) catch break :blk;
            const slot = &self.persistent_gpu.debug_glass_slots[2];
            if (slot.staging == null) {
                slot.staging = self.device.createTexture(self.allocator, .{
                    .label = "Zenit.GlassDebugRtStaging",
                    .size = .{ .width = 64, .height = 64 },
                    .format = .bgra8_unorm_srgb,
                    .usage = .{ .copy_dst = true },
                    .memory = .host_upload,
                }) catch null;
            }
            const staging = &(slot.staging orelse break :blk);
            const src = surface_texture.texture.binding();
            if (rx + 64 > src.width or ry + 64 > src.height) break :blk;
            if (gpu_encoder.beginBlitPass()) |*bp_const| {
                var bp = bp_const.*;
                const copied = inner: {
                    bp.copyTextureRegion(src, rx, ry, 64, 64, staging.binding(), 0, 0) catch break :inner false;
                    break :inner true;
                };
                bp.end();
                if (copied) {
                    slot.cur_pending = true;
                    slot.cur_w = 64;
                    slot.cur_h = 64;
                    slot.last_used_frame = self.frame_counter;
                    std.debug.print("[glassrt-blit] frame={d} src={d}x{d} at=({d},{d})\n", .{ self.frame_counter, src.width, src.height, rx, ry });
                }
            } else |_| {}
        }
        var cmd_buffer = try gpu_encoder.finish();
        defer cmd_buffer.deinit();

        // 注册 GPU 完成回调，释放 buffer slot
        self.frame_sync.signalOnCompletion(&cmd_buffer);

        // 读取**上一帧**的真 GPU 执行时间（GPUStartTime/GPUEndTime 只有在
        // command buffer 完成后才有效；本帧的刚提交，读不到）。
        // 稳态下上一帧早已完成，因此这是零等待的。
        var gpu_execute_us: u64 = 0;
        if (self.prev_frame_cmd_buffer) |*prev| {
            gpu_execute_us = prev.gpuElapsedMicros() orelse 0;
            // backdrop 亮度自适应：逐槽读 staging 求各区域平均 luminance。
            // 本帧 encode 刚排的 blit 还没执行，用 prev_* 拍存的维度。
            //
            // 机会式读回：只有上一帧**已经**完成才读 staging。
            //
            // 这里以前是无条件 waitUntilCompleted。注释假设"稳态下上一帧早已
            // 完成，所以是零等待", GPU 跟得上时确实如此，但一旦一帧的 GPU
            // 工作超过一帧预算（两万对象的画布实测 260–360ms），它就变成硬性
            // CPU↔GPU 串行点：主线程每帧都钉在这里等 GPU，UI 完全无法交互，
            // 而且流水线再也无法重叠，情况只会继续恶化。
            // backdrop 亮度是纯装饰性的自适应量，晚一帧甚至跳几帧都无所谓，
            // 绝不值得为它牺牲整条流水线；未完成时沿用上一次的值即可。
            const prev_ready = prev.isCompleted();
            var lum_sum: f64 = 0;
            var lum_n: usize = 0;
            for (&self.persistent_gpu.luminance_slots) |*slot| {
                if (slot.prev_pending and prev_ready) {
                    if (slot.staging) |*staging| {
                        slot.value = readAverageLuminance(staging, slot.prev_w, slot.prev_h) orelse slot.value;
                        if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) {
                            std.debug.print("[lumslot] node={d} v={d:.3}\n", .{ slot.key, slot.value orelse -1 });
                        }
                    }
                }
                slot.prev_pending = slot.cur_pending;
                slot.prev_w = slot.cur_w;
                slot.prev_h = slot.cur_h;
                slot.cur_pending = false;
                if (slot.value) |v| {
                    lum_sum += v;
                    lum_n += 1;
                }
            }
            if (lum_n > 0) self.backdrop_luminance = @floatCast(lum_sum / @as(f64, @floatFromInt(lum_n)));
            // 排障（ZENIT_DEBUG_GLASS）：glass 中间产物 RGB 均值回读
            if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) {
                for (&self.persistent_gpu.debug_glass_slots, 0..) |*slot, si| {
                    if (slot.prev_pending and prev_ready) {
                        if (slot.staging) |*staging| {
                            if (readAverageRgb(staging, slot.prev_w, slot.prev_h)) |rgb| {
                                const stage_name = switch (si) {
                                    0 => "capture",
                                    1 => "composite",
                                    else => "endrt",
                                };
                                std.debug.print("[glassdbg] stage={s} rgb=({d:.1},{d:.1},{d:.1})\n", .{
                                    stage_name, rgb[0], rgb[1], rgb[2],
                                });
                            }
                        }
                    }
                    slot.prev_pending = slot.cur_pending;
                    slot.prev_w = slot.cur_w;
                    slot.prev_h = slot.cur_h;
                    slot.cur_pending = false;
                }
            }
            prev.deinit();
            self.prev_frame_cmd_buffer = null;
        }
        // backdrop 亮度自适应：把实测值递给组件层（GlassBox before_render 平滑）。
        // 全局均值作 fallback；逐区域列表供组件按自身 rect 就近匹配。
        cx.backdrop_luminance = self.backdrop_luminance;
        cx.backdrop_luminance_region_count = 0;
        for (&self.persistent_gpu.luminance_slots) |*slot| {
            if (slot.value) |v| {
                if (slot.key != std.math.maxInt(u32) and cx.backdrop_luminance_region_count < cx.backdrop_luminance_regions.len) {
                    cx.backdrop_luminance_regions[cx.backdrop_luminance_region_count] = .{
                        .node_id = slot.key,
                        .lum = v,
                    };
                    cx.backdrop_luminance_region_count += 1;
                }
            }
        }

        // 留住本帧 buffer 供下一帧读取（额外 retain 一次，与上面的 release 配对；
        // cmd_buffer 自己的所有权仍由本帧的 defer deinit 负责）。
        self.prev_frame_cmd_buffer = cmd_buffer.retained();

        surface_texture.preparePresent(&cmd_buffer);
        cmd_buffer.submit();

        // E2E 截图：present 前读 drawable 像素。需等 GPU 完成渲染再 getBytes。
        if (self.pending_screenshot_path != null) {
            cmd_buffer.waitUntilCompleted();
            self.last_screenshot_ok = self.captureSurfaceToPng(
                &surface_texture.texture,
                surface_texture.texture.size.width,
                surface_texture.texture.size.height,
            );
            self.pending_screenshot_path = null;
            self.pending_screenshot_len = 0;
        }

        if (self.recording_active) {
            if (self.recording_frame_fn) |record_frame| {
                // The encoder uses a separate Metal queue. Waiting establishes
                // an explicit cross-queue ownership boundary for this drawable.
                cmd_buffer.waitUntilCompleted();
                if (!record_frame(&surface_texture.texture)) self.recording_active = false;
            }
        }

        surface_texture.presentAfterSubmit(&cmd_buffer);

        // 收集帧性能统计
        const frame_end = std.time.Instant.now() catch null;
        // FrameStats 此前声明了 wait/acquire/cpu 三个字段却**从不赋值**
        // （审查报告 §4），三个 timerDelta 结果被 `_ =` 直接丢弃，
        // 于是 gpu_encode_us 混进了 wait + acquire + CPU encode + 提交，
        // 读数无法归因。这里补齐拆分。
        const encode_us = timerDelta(encode_start, encode_end);
        const flush_us = timerDelta(flush_start, flush_end);
        const wait_us = timerDelta(wait_start, wait_end);
        const acquire_us = timerDelta(acquire_start, acquire_end);
        const total_us = timerDelta(frame_start, frame_end);
        const layout_us = timerDelta(layout_start, layout_end);
        const render_gen_us = timerDelta(render_start, render_end);
        const icon_total = render.iconDrawCallsTotal();
        const icon_draws: u32 = @intCast(icon_total -| self.prev_icon_draw_calls_total);
        self.prev_icon_draw_calls_total = icon_total;
        const image_total = render.imageDrawCallsTotal();
        const image_draws: u32 = @intCast(image_total -| self.prev_image_draw_calls_total);
        self.prev_image_draw_calls_total = image_total;
        const image_inst_total = render.imageInstancesTotal();
        const image_insts: u32 = @intCast(image_inst_total -| self.prev_image_instances_total);
        self.prev_image_instances_total = image_inst_total;
        const bind_total = render.imageTextureBindsTotal();
        const tex_binds: u32 = @intCast(bind_total -| self.prev_texture_binds_total);
        self.prev_texture_binds_total = bind_total;
        const sdf_total = render.sdfDrawCallsTotal();
        const sdf_draws: u32 = @intCast(sdf_total -| self.prev_sdf_draw_calls_total);
        self.prev_sdf_draw_calls_total = sdf_total;
        const text_total = render.textDrawCallsTotal();
        const text_draws: u32 = @intCast(text_total -| self.prev_text_draw_calls_total);
        self.prev_text_draw_calls_total = text_total;
        const path_draws: u32 = if (self.persistent_gpu.path_renderer) |*pr| pr.frame_draw_count else 0;
        self.last_frame_stats = .{
            .layout_us = layout_us,
            .render_gen_us = render_gen_us,
            // 注意：这仍是"CPU 侧编码+提交"墙钟，**不是 GPU 执行时间**,
            // 真正的 GPU 时间需要 command buffer timestamp / counter sample，
            // 尚未接入（审查报告 §4 待办）。
            .gpu_encode_us = timerDelta(render_end, frame_end),
            .wait_for_frame_us = wait_us,
            .acquire_texture_us = acquire_us,
            // 纯 CPU 管线：总耗时扣掉阻塞等待与 drawable 获取。
            .cpu_frame_us = total_us -| wait_us -| acquire_us,
            .gpu_execute_us = gpu_execute_us,
            .encode_us = encode_us,
            .flush_us = flush_us,
            .path_draw_calls = path_draws,
            .retained_hits = enc.retained_hits,
            .retained_misses = enc.retained_misses,
            .retained_partial_repaints = enc.retained_partial_repaints,
            .icon_draw_calls = icon_draws,
            .image_draw_calls = image_draws,
            .image_instances = image_insts,
            .texture_binds = tex_binds,
            .sdf_draw_calls = sdf_draws,
            .text_draw_calls = text_draws,
            .draw_calls = path_draws + icon_draws + image_draws + sdf_draws + text_draws,
            .sdf_instances = @intCast(pending_sdf_instances),
            .text_instances = @intCast(pending_text_instances),
            .command_count = @intCast(cx.lowerForEncoderPaintTable().len),
            .total_frame_us = total_us,
        };

        // 只有走到这里的帧才是"真渲染过"的帧，idle 跳帧不会到达此处，
        // 因此环里不会混入近零样本（否则 P95 会被稀释成假绿）。
        self.timing_ring.push(.{
            .gpu_execute_us = self.last_frame_stats.gpu_execute_us,
            .cpu_frame_us = self.last_frame_stats.cpu_frame_us,
            .total_frame_us = self.last_frame_stats.total_frame_us,
        });

        // DevTools（Cx 侧）帧性能回填。devtools panel 的 Performance 页读的是
        // target Cx 上的 frame_*_history / perf.layout_us / perf.render_us,
        // 这条链在从下游编辑器抽出时断了（下游原本由自己的窗口渲染代码喂），
        // 缺了它面板 FPS 恒 0、Timing 恒 0。写点必须在 cx.render() 之后：
        // perf.resetFrame() 发生在 render() 开头，这里写的值可存活到下一帧，
        // 供 DevTools 窗口跨 Cx 读取。
        cx.frame_perf.pushFrameTotalUs(total_us);
        cx.frame_perf.acquire.push(acquire_us);
        cx.perf.layout_us = layout_us;
        cx.perf.render_us = render_gen_us;
        if (frame_start) |fs| {
            if (self.prev_frame_start) |prev| {
                const raw_interval_us = fs.since(prev) / std.time.ns_per_us;
                const display_period_us: u64 = @intFromFloat(1_000_000.0 / @as(f64, @floatCast(@max(1.0, cx.display_refresh_hz))));
                if (@import("timing_ring.zig").frameIntervalSampleUs(raw_interval_us, display_period_us)) |sample| {
                    cx.frame_perf.pushFrameIntervalUs(sample);
                }
            }
            self.prev_frame_start = fs;
        }

        self.total_retained_hits += enc.retained_hits;
        self.total_retained_misses += enc.retained_misses;
        self.total_retained_partial_repaints += enc.retained_partial_repaints;
        self.frame_count += 1;
    }

    /// 获取上一帧的性能统计
    /// backdrop 亮度自适应：读 shared staging（BGRA8 sRGB 字节）求平均
    /// linear luminance。失败返回 null（保持旧值）。
    fn readAverageLuminance(staging: *const gpu.Backend.Texture, w: u32, h: u32) ?f32 {
        if (w == 0 or h == 0 or w > 64 or h > 64) return null;
        var buf: [64 * 64 * 4]u8 = undefined;
        const bpr = w * 4;
        staging.readBgra8(w, h, &buf, bpr) catch return null;
        if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) {
            std.debug.print("[lum] read {d}x{d} px0=({d},{d},{d},{d}) pxmid=({d},{d},{d},{d})\n", .{ w, h, buf[0], buf[1], buf[2], buf[3], buf[(w * h / 2) * 4], buf[(w * h / 2) * 4 + 1], buf[(w * h / 2) * 4 + 2], buf[(w * h / 2) * 4 + 3] });
        }
        var sum: f64 = 0;
        var i: usize = 0;
        const n = @as(usize, w) * @as(usize, h);
        while (i < n) : (i += 1) {
            const b = srgbByteToLinear(buf[i * 4 + 0]);
            const g = srgbByteToLinear(buf[i * 4 + 1]);
            const r = srgbByteToLinear(buf[i * 4 + 2]);
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
        }
        return @floatCast(sum / @as(f64, @floatFromInt(n)));
    }

    /// 排障：staging 的原始 sRGB 字节均值（BGRA -> 返回 [r,g,b]，0..255），
    /// 与截图 PNG 均值同一量纲，直接对比。
    fn readAverageRgb(staging: *const gpu.Backend.Texture, w: u32, h: u32) ?[3]f64 {
        if (w == 0 or h == 0 or w > 64 or h > 64) return null;
        var buf: [64 * 64 * 4]u8 = undefined;
        const bpr = w * 4;
        staging.readBgra8(w, h, &buf, bpr) catch return null;
        var rs: f64 = 0;
        var gs: f64 = 0;
        var bs: f64 = 0;
        var i: usize = 0;
        const n = @as(usize, w) * @as(usize, h);
        while (i < n) : (i += 1) {
            bs += @floatFromInt(buf[i * 4 + 0]);
            gs += @floatFromInt(buf[i * 4 + 1]);
            rs += @floatFromInt(buf[i * 4 + 2]);
        }
        const nf = @as(f64, @floatFromInt(n));
        return .{ rs / nf, gs / nf, bs / nf };
    }

    fn srgbByteToLinear(c: u8) f64 {
        const v = @as(f64, @floatFromInt(c)) / 255.0;
        if (v <= 0.04045) return v / 12.92;
        return std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
    }

    pub fn getLastFrameStats(self: *const AppRenderer) FrameStats {
        return self.last_frame_stats;
    }

    /// 渲染一帧，手动控制模式
    ///
    /// 不使用 Cx，允许手动积累渲染命令后提交。
    /// 返回 encoder 供外部使用。
    pub fn beginFrame(self: *AppRenderer, viewport_width: f32, viewport_height: f32, scale: f32) RenderCommandEncoder {
        var enc = self.getEncoder();
        enc.beginFrame(viewport_width, viewport_height, scale);
        return enc;
    }

    /// 销毁
    pub fn deinit(self: *AppRenderer) void {
        // 等待所有 in-flight 帧完成，防止销毁时 GPU 仍在读取 buffer
        self.frame_sync.drain(FRAME_BUFFER_COUNT);
        // 释放为读 GPU 时间戳而额外 retain 的上一帧 command buffer
        // （不放这里会漏掉最后一帧那一个）。
        if (self.prev_frame_cmd_buffer) |*prev| {
            prev.deinit();
            self.prev_frame_cmd_buffer = null;
        }
        // 池纹理与持久 PSO 可能被最后几帧的 command buffer 引用，必须在 drain 之后释放
        self.offscreen_pool.deinit();
        self.persistent_gpu.deinit();
        // test-harness 模式（retain_present_copy）下的窗口尺寸 present 副本：
        // 此前只在 ensureRetainedTexture 换尺寸时销毁，关窗即泄漏一整张
        // 窗口大小的 BGRA 纹理（2880×1800 ≈ 20 MB）。
        if (self.retained_tex) |*tex| tex.destroy();
        self.retained_tex = null;
        if (self.fonts) |fonts| {
            if (fonts.drawn_width_ctx == @as(*anyopaque, @ptrCast(&self.text_renderer))) {
                fonts.setDrawnWidthSource(null, null);
            }
        }
        self.text_renderer.deinit();
        self.icon_renderer.deinit();
        self.image_renderer.deinit();
        self.sdf_renderer.deinit();
        // drain 已平衡 slot，此时 release 安全（多窗口反复开关不再累积泄漏）
        self.frame_sync.deinit();
    }
};

/// 计算两个时间点之间的微秒差值
fn timerDelta(start: ?std.time.Instant, end: ?std.time.Instant) u64 {
    if (start) |s| {
        if (end) |e| {
            return e.since(s) / 1000; // ns → us
        }
    }
    return 0;
}
