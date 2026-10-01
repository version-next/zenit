/// SDF Renderer - GPU 实例化 SDF 图元渲染
///
/// 基于 sdf_primitives.metal 的完整 SDF 渲染管线:
/// - 真正 SDF 阴影（模糊边缘、形状内不渲染）
/// - 空心圆角边框（单 draw call）
/// - 圆角矩形/圆形/线条
///
/// 基于 SDF 的统一图元渲染管线
const std = @import("std");
const gpu = @import("gpu");

const MAX_CLIP_POLYGON_POINTS = 32;
const MAX_CLIP_POLYGON_CONTOURS = 8;

/// SDF Shader 源码（单一事实源）
const sdf_shader_source: []const u8 = @embedFile("shaders/sdf_primitives.metal");

/// Uniforms 结构，对齐 sdf_primitives.metal
const Uniforms = extern struct {
    viewport_size: [2]f32, // 物理像素
    scale_factor: f32,
    clip_shape_kind: u32 = 0,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radius: f32 = 0,
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = [_]u32{0} ** MAX_CLIP_POLYGON_CONTOURS,
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = [_][2]f32{.{ 0, 0 }} ** MAX_CLIP_POLYGON_POINTS,
    /// 每帧递增的种子，供 film_grain shader 产生逐帧变化的噪声图案
    frame_seed: u32 = 0,
};

/// SDF 实例数据，对齐 sdf_primitives.metal InstanceData（176 bytes）
pub const SDFInstance = extern struct {
    rect: [4]f32, // x, y, w, h (逻辑像素)
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 }, // x, y, w, h；negative size = disabled
    fill_color: [4]f32, // RGBA float (gradient: from color)
    border_color: [4]f32, // RGBA float
    shadow_color: [4]f32, // RGBA float（外阴影 + inset shadow 复用）
    gradient_to_color: [4]f32, // RGBA float (gradient: to color，stop_count=0 时用)
    corner_radii: [4]f32, // TL, TR, BR, BL
    border_width: f32,
    shadow_blur: f32,
    shadow_offset_x: f32,
    shadow_offset_y: f32,
    shape_type: u32, // 0=rect, 1=circle, 2=line, 3=arc
    /// packed_flags 编码：
    ///   bit 0-7:   gradient_direction (GradientDir)
    ///   bit 8-15:  noise_mode (NoiseMode)
    ///   bit 16-23: noise_seed (0-255)
    ///   bit 24:    inset_shadow (0/1)
    ///   bit 25:    has_shadow2  (0/1)
    packed_flags: u32 = 0,
    noise_scale: f32 = 0, // 噪声格点间距（逻辑像素，0=关闭）
    noise_intensity: f32 = 0, // 噪声强度 [0..1]
    border_widths: [4]f32 = .{ 0, 0, 0, 0 }, // per-side: top, right, bottom, left
    gradient_stop_offset: u32 = 0, // GradientStop buffer 起始索引
    gradient_stop_count: u32 = 0, // 0 = 旧两色模式（向后兼容）
    shadow2_index: u32 = 0, // ShadowParam buffer 中第二阴影的索引
    _ext_reserved: u32 = 0,

    comptime {
        // 7×float4(112) + 4×float(16) + 2×uint(8) + 2×float(8) + 1×float4(16) + 4×uint(16) = 176 bytes
        if (@sizeOf(SDFInstance) != 176) @compileError("SDFInstance must be 176 bytes (Metal float4 aligned)");
    }

    /// 打包 gradient_direction + noise_mode + noise_seed + extend_mode 到 packed_flags
    /// packed_flags 布局:
    ///   bit 0-7:   gradient_direction (GradientDir)
    ///   bit 8-15:  noise_mode (NoiseMode)
    ///   bit 16-23: noise_seed (0-255)
    ///   bit 24:    inset_shadow (0/1)
    ///   bit 25:    has_shadow2  (0/1)
    ///   bit 26-27: extend_mode (GradientExtendMode: 0=pad, 1=repeat, 2=reflect)
    ///   bit 28-31: 保留
    pub fn packFlags(
        grad_dir: GradientDir,
        noise_mode: NoiseMode,
        noise_seed: u8,
        inset_shadow: bool,
        has_shadow2: bool,
    ) u32 {
        return packFlagsEx(grad_dir, noise_mode, noise_seed, inset_shadow, has_shadow2, .pad);
    }

    /// 带 extend_mode 的完整版本
    pub fn packFlagsEx(
        grad_dir: GradientDir,
        noise_mode: NoiseMode,
        noise_seed: u8,
        inset_shadow: bool,
        has_shadow2: bool,
        extend_mode: GradientExtendMode,
    ) u32 {
        return @intFromEnum(grad_dir) |
            (@as(u32, @intFromEnum(noise_mode)) << 8) |
            (@as(u32, noise_seed) << 16) |
            (if (inset_shadow) @as(u32, 1) << 24 else 0) |
            (if (has_shadow2) @as(u32, 1) << 25 else 0) |
            (@as(u32, @intFromEnum(extend_mode)) << 26);
    }
};

/// 形状类型
///
/// ⚠ 序号与 `sdf_primitives.metal` 的 4 个 `switch (inst.shape_type)` 一一对应
/// （主填充 / 外阴影 / 第二外阴影 / 内阴影）。**加成员必须四处都补 case**：
/// 三处 default 值并不一致，填充与两个外阴影 default 是 `1.0`（漏改 ⇒ 形状或
/// 阴影**静默消失**），内阴影 default 是 `-1.0`（漏改 ⇒ 内阴影**铺满整个形状**）。
/// 症状相反，按同一个思路排查会被带偏。
pub const ShapeType = enum(u32) {
    rect = 0,
    circle = 1,
    line = 2,
    arc = 3,
    /// 内接 rect 的椭圆（半轴 = w/2, h/2）。描边走 uniform 快速路径
    /// （`sdf + border_width`，inside 语义，与 rect 一致）；per-side 描边
    /// 在 shader 侧被门禁掉，入口负责折叠成统一宽度。
    ellipse = 4,
};

/// 渐变方向 (shader packed_flags bit 0-7)
pub const GradientDir = enum(u32) {
    none = 0,
    vertical = 1,
    horizontal = 2,
    diagonal = 3,
    radial = 4,
    conic = 5,
};

/// 渐变延伸模式 (shader packed_flags bit 26-27)
/// 控制渐变 t 值超出 [0,1] 时的处理方式
pub const GradientExtendMode = enum(u2) {
    pad = 0, // 夹制到边界颜色（默认）
    repeat = 1, // 循环重复
    reflect = 2, // 镜像反射
};

/// 程序性噪声模式 (shader packed_flags bit 8-15)
/// 枚举值必须与 src/ui/core/types.zig 的 NoiseMode 保持同步（通过 u8 传递）
pub const NoiseMode = enum(u8) {
    none = 0,
    value = 1, // Value Noise（格点插值，适合粗糙材质）
    film_grain = 2, // Film Grain（高频屏幕颗粒，适合玻璃/纸张感）
};
// 编译期断言：枚举值数量正确（修改 types.zig 时同步更新这里）
comptime {
    std.debug.assert(@intFromEnum(NoiseMode.none) == 0);
    std.debug.assert(@intFromEnum(NoiseMode.value) == 1);
    std.debug.assert(@intFromEnum(NoiseMode.film_grain) == 2);
}

/// 多色渐变色标（triple-buffered GradientStop buffer，slot 2）
pub const GradientStop = extern struct {
    color: [4]f32, // RGBA linear float
    position: f32, // [0.0, 1.0]
    _pad0: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,

    comptime {
        if (@sizeOf(GradientStop) != 32) @compileError("GradientStop must be 32 bytes");
    }
};

/// 第二阴影参数（triple-buffered ShadowParam buffer，slot 3）
pub const ShadowParam = extern struct {
    color: [4]f32,
    blur: f32,
    offset_x: f32,
    offset_y: f32,
    _pad: f32 = 0,

    comptime {
        if (@sizeOf(ShadowParam) != 32) @compileError("ShadowParam must be 32 bytes");
    }
};

/// 最大实例数（从 2048 增大到 8192，支持复杂 UI 减少分批次数）
const MAX_INSTANCES = 8192;
const MAX_UNIFORM_UPDATES = 256;

/// TRANSPARENT 颜色
const TRANSPARENT: [4]f32 = .{ 0, 0, 0, 0 };

/// Triple buffering 常量，消除 CPU/GPU buffer 竞争 (参考 Zed 120fps 方案)
const BUFFER_COUNT = 3;

/// 每帧最多支持的渐变 stops 总数（8192 instances × 平均 4 stops）
const MAX_GRADIENT_STOPS = 32768;
/// 每帧最多支持的第二阴影数
const MAX_SHADOW2 = 8192;

/// Metal SDF Renderer
/// SDF 管线模块级累计 GPU draw 数（FrameStats 取每帧增量用）
pub var sdf_draw_calls: u64 = 0;

pub const SdfRenderer = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    pipeline: gpu.Backend.RenderPipeline,
    /// Triple-buffered uniform buffers，必须与 instance_buffers 一样按帧轮转。
    /// 曾经这里是**单个** buffer 而每帧把 uniform_write_offset 归零：三帧在飞时
    /// 第 N+1 帧会覆写 GPU 尚未消费的第 N 帧 viewport/clip/scale/frame_seed，
    /// 表现为偶发闪烁、错误裁剪、参数串帧（只在 GPU 落后时触发，极难归因）。
    uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    uniform_write_offset: usize = 0,
    /// 单帧 uniform 槽位溢出次数（诊断用）。溢出时旧实现直接 clamp 到最后一槽，
    /// 导致多次 draw 别名同一块随后被覆写的内存，静默出错；后来改成返回
    /// error.UniformSlotsExhausted，但 opacity layer / encoder.flush 等调用点
    /// `try` 透传，一帧超过 256 次 flush 就把 App.run 整个打崩。现在与
    /// TextRenderer 同款：槽位不够切到按需增长、跨帧保留的溢出 uniform buffer。
    uniform_overflow_count: u64 = 0,
    uniform_overflow_buffers: [BUFFER_COUNT]?gpu.Backend.Buffer = [_]?gpu.Backend.Buffer{null} ** BUFFER_COUNT,
    uniform_overflow_capacities: [BUFFER_COUNT]usize = [_]usize{0} ** BUFFER_COUNT,
    /// 本帧已用的溢出 uniform 槽位数。
    uniform_overflow_used: usize = 0,
    /// Triple-buffered instance buffers，每帧轮转，CPU/GPU 不竞争
    instance_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    /// Triple-buffered GradientStop buffers（slot 2）
    stop_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    /// Triple-buffered ShadowParam buffers（slot 3）
    shadow2_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    current_buffer: usize = 0,
    /// 本帧已上传到当前 stop/shadow2 buffer 的条目数。stops 在帧内跨 flush 只增
    /// 不减、字节位置稳定，flush 只需追加上传新增尾部（旧实现每次 flush 从 0
    /// 重传全量，多次 flush 时 O(flush_count × total_stops) 冗余拷贝）。
    grad_stops_uploaded: usize = 0,
    shadow2_uploaded: usize = 0,

    instances: std.ArrayList(SDFInstance),
    /// 当前帧积累的 GradientStop 数组
    grad_stops: std.ArrayList(GradientStop),
    /// 当前帧积累的 ShadowParam 数组
    shadow2_params: std.ArrayList(ShadowParam),
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
    /// 形状覆盖：非 `.rect` 时，下面所有 `add*Rect` 系列产出的实例都改用这个
    /// 形状的 SDF。存在的理由是**渐变/噪声/阴影各有一套入口**（11 个 add*
    /// 函数），逐个加形状参数会把签名炸开，且调用方全要跟着改；而形状是
    /// "当前这个节点画成什么样"的上下文，与 rect_clip 同性质。
    ///
    /// 纪律：由 encoder 在**每条命令前后**设置与复位（同 rect_clip 的模式），
    /// 绝不跨命令残留，残留会让后面无关的矩形被画成椭圆。
    current_shape: ShapeType = .rect,
    instance_high_water_mark: usize = 0,
    /// 当前帧种子，每帧从外部传入，驱动 film_grain 动态噪声
    frame_seed: u32 = 0,
    /// flush 偏移：同一帧内多次 flush 时追加写入
    buffer_write_offset: usize = 0,

    /// 溢出实例缓冲（每帧槽位各一个，随需增长后**保留**）。
    ///
    /// 旧实现在 MAX_INSTANCES 用尽后对**每一批**都 createBuffer + destroy。
    /// 两万对象的画布一帧要走上千次这条路径，每次都是一次 driver 分配 +
    /// page_allocator mmap，既是 CPU 热点，也让 RSS 无界增长（Metal 不会
    /// 立刻归还刚被 GPU 引用过的分配）。改为按帧槽位持有一个可增长的 buffer：
    /// 容量够就直接复用，不够才重建一次。槽位随 current_buffer 轮转，因此
    /// 仍然不会覆写 GPU 尚在消费的在飞帧数据。
    overflow_buffers: [BUFFER_COUNT]?gpu.Backend.Buffer = [_]?gpu.Backend.Buffer{null} ** BUFFER_COUNT,
    overflow_capacities: [BUFFER_COUNT]usize = [_]usize{0} ** BUFFER_COUNT,
    /// 本帧槽位内溢出缓冲的写入游标（字节），保证同帧多批次不互相覆写。
    overflow_write_offset: usize = 0,

    /// 初始化
    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !SdfRenderer {
        // 编译 shader (内联源码)
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, sdf_shader_source);
        defer shader.deinit();

        // 获取函数
        var vertex_func = try shader.getFunction("sdf_vertex_main");
        defer vertex_func.deinit();
        var fragment_func = try shader.getFunction("sdf_fragment_main");
        defer fragment_func.deinit();

        // 创建 pipeline（带 alpha 混合）。此行之后每步失败都要回收已建 GPU 对象；
        // errdefer 必须在循环外（循环体内的 errdefer 随迭代作用域失效，死代码）。
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

        // 创建 triple-buffered uniform buffers（与 instance buffers 同步轮转）
        var uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var uniform_created: usize = 0;
        errdefer for (uniform_buffers[0..uniform_created]) |*b| b.destroy();
        for (&uniform_buffers) |*buf| {
            buf.* = try device.createBuffer(allocator, .{
                .label = "Zenit.SDF.Uniforms",
                .size = @sizeOf(Uniforms) * MAX_UNIFORM_UPDATES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            uniform_created += 1;
        }

        // 创建 triple-buffered instance buffers
        var instance_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var instance_created: usize = 0;
        errdefer for (instance_buffers[0..instance_created]) |*b| b.destroy();
        for (&instance_buffers, 0..) |*buf, i| {
            const label = try std.fmt.allocPrint(allocator, "Zenit.SDF.InstanceBuffer[{d}]", .{i});
            defer allocator.free(label);
            buf.* = try device.createBuffer(allocator, .{
                .label = label,
                .size = @sizeOf(SDFInstance) * MAX_INSTANCES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            instance_created += 1;
        }

        // 创建 triple-buffered GradientStop buffers（slot 2）
        var stop_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var stop_created: usize = 0;
        errdefer for (stop_buffers[0..stop_created]) |*b| b.destroy();
        for (&stop_buffers, 0..) |*buf, i| {
            const label = try std.fmt.allocPrint(allocator, "Zenit.SDF.StopBuffer[{d}]", .{i});
            defer allocator.free(label);
            buf.* = try device.createBuffer(allocator, .{
                .label = label,
                .size = @sizeOf(GradientStop) * MAX_GRADIENT_STOPS,
                .usage = .{ .vertex = true, .map_write = true },
            });
            stop_created += 1;
        }

        // 创建 triple-buffered ShadowParam buffers（slot 3）
        var shadow2_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var shadow2_created: usize = 0;
        errdefer for (shadow2_buffers[0..shadow2_created]) |*b| b.destroy();
        for (&shadow2_buffers, 0..) |*buf, i| {
            const label = try std.fmt.allocPrint(allocator, "Zenit.SDF.Shadow2Buffer[{d}]", .{i});
            defer allocator.free(label);
            buf.* = try device.createBuffer(allocator, .{
                .label = label,
                .size = @sizeOf(ShadowParam) * MAX_SHADOW2,
                .usage = .{ .vertex = true, .map_write = true },
            });
            shadow2_created += 1;
        }

        std.log.info("[SdfRenderer] Initialized (triple-buffered SDF pipeline)", .{});

        return SdfRenderer{
            .allocator = allocator,
            .device = device,
            .pipeline = pipeline,
            .uniform_buffers = uniform_buffers,
            .instance_buffers = instance_buffers,
            .stop_buffers = stop_buffers,
            .shadow2_buffers = shadow2_buffers,
            .instances = .{},
            .grad_stops = .{},
            .shadow2_params = .{},
            .viewport_width = 800,
            .viewport_height = 600,
            .scale_factor = 1.0,
        };
    }

    /// 销毁
    pub fn deinit(self: *SdfRenderer) void {
        self.instances.deinit(self.allocator);
        self.grad_stops.deinit(self.allocator);
        self.shadow2_params.deinit(self.allocator);
        for (&self.instance_buffers) |*buf| buf.destroy();
        for (&self.stop_buffers) |*buf| buf.destroy();
        for (&self.shadow2_buffers) |*buf| buf.destroy();
        for (&self.uniform_buffers) |*buf| buf.destroy();
        for (&self.overflow_buffers) |*maybe_buf| {
            if (maybe_buf.*) |*buf| buf.destroy();
        }
        for (&self.uniform_overflow_buffers) |*maybe_buf| {
            if (maybe_buf.*) |*buf| buf.destroy();
        }
        self.pipeline.deinit();
        std.log.info("[SdfRenderer] Destroyed", .{});
    }

    /// 保证本帧槽位的溢出 uniform buffer 至少能放下 `slots` 个 Uniforms。
    /// 几何增长、跨帧保留；同帧重建时旧 buffer 由在飞 command buffer 持有引用，
    /// 早先批次的数据不受影响。
    fn ensureUniformOverflowCapacity(self: *SdfRenderer, slots: usize) !*gpu.Backend.Buffer {
        const needed = slots * @sizeOf(Uniforms);
        if (self.uniform_overflow_capacities[self.current_buffer] < needed) {
            var new_capacity = @max(
                self.uniform_overflow_capacities[self.current_buffer],
                @sizeOf(Uniforms) * 64,
            );
            while (new_capacity < needed) new_capacity *= 2;
            if (self.uniform_overflow_buffers[self.current_buffer]) |*old| old.destroy();
            self.uniform_overflow_buffers[self.current_buffer] = null;
            self.uniform_overflow_capacities[self.current_buffer] = 0;
            self.uniform_overflow_buffers[self.current_buffer] = try self.device.createBuffer(self.allocator, .{
                .label = "Zenit.SDF.OverflowUniforms",
                .size = new_capacity,
                .usage = .{ .vertex = true, .map_write = true },
            });
            self.uniform_overflow_capacities[self.current_buffer] = new_capacity;
        }
        return &self.uniform_overflow_buffers[self.current_buffer].?;
    }

    /// 开始新帧
    /// width/height: 逻辑像素; scale: DPI 缩放因子 (Retina=2.0)
    pub fn beginFrame(self: *SdfRenderer, width: f32, height: f32, scale: f32, frame_seed: u32) void {
        self.instances.clearRetainingCapacity();
        self.grad_stops.clearRetainingCapacity();
        self.shadow2_params.clearRetainingCapacity();
        self.grad_stops_uploaded = 0;
        self.shadow2_uploaded = 0;
        self.buffer_write_offset = 0;
        // 轮转到下一个 buffer（triple buffering，CPU/GPU 不竞争）
        self.current_buffer = (self.current_buffer + 1) % BUFFER_COUNT;
        self.uniform_write_offset = 0;
        self.uniform_overflow_used = 0;
        // 新槽位的溢出缓冲从头写起（该槽位上一次使用已隔了 BUFFER_COUNT 帧）
        self.overflow_write_offset = 0;
        // viewport_size 传物理像素给 shader
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
        self.current_shape = .rect;
        self.frame_seed = frame_seed;
    }

    /// 仅更新 viewport 尺寸（离屏合成 render pass 切换时使用）
    /// 不重置 buffer/instances/轮转，帧内状态保持连续
    pub fn setViewport(self: *SdfRenderer, width: f32, height: f32, scale: f32) void {
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
    }

    pub fn setClipMask(self: *SdfRenderer, shape_kind: u32, rect: ?[4]f32, radius: f32, fill_rule: u32, point_count: u32, contour_count: u32, contour_end_points: [MAX_CLIP_POLYGON_CONTOURS]u8, polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32) void {
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

    pub fn setRectClip(self: *SdfRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
    }

    /// clamp corner radii 到 min(w,h)/2，防止超大圆角导致 SDF 全 discard
    inline fn clampRadii(radii: [4]f32, w: f32, h: f32) [4]f32 {
        const max_r = @min(w, h) / 2;
        return .{ @min(radii[0], max_r), @min(radii[1], max_r), @min(radii[2], max_r), @min(radii[3], max_r) };
    }

    /// 添加圆角矩形（简化 API）
    pub fn addRoundedRect(self: *SdfRenderer, x: f32, y: f32, w: f32, h: f32, color: [4]f32, radii: [4]f32) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = 0,
        });
    }

    // ========== SDF 原生 API ==========

    /// 添加带边框的圆角矩形（单 draw call 空心边框）
    pub fn addBorderedRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        border_color: [4]f32,
        border_width: f32,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = border_color,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = border_width,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = 0,
        });
    }

    /// 添加 per-side border 圆角矩形（单 draw call，无需 clipping）
    /// border_widths: [top, right, bottom, left]
    pub fn addBorderedRectPerSide(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        border_color: [4]f32,
        border_widths: [4]f32,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = border_color,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = 0,
            .border_widths = border_widths,
        });
    }

    /// 添加带阴影的圆角矩形
    pub fn addShadowRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        shadow_color: [4]f32,
        shadow_blur: f32,
        shadow_offset_x: f32,
        shadow_offset_y: f32,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = shadow_color,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = shadow_blur,
            .shadow_offset_x = shadow_offset_x,
            .shadow_offset_y = shadow_offset_y,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = 0,
        });
    }

    /// 带 CSS spread 的外阴影。spread 放在 noise_scale（纯阴影实例不画填充、不用
    /// 噪声），由 packed_flags bit 28 标记；spread == 0 时与 addShadowRect 完全一致。
    pub fn addShadowRectSpread(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        shadow_color: [4]f32,
        shadow_blur: f32,
        shadow_offset_x: f32,
        shadow_offset_y: f32,
        spread: f32,
        radii: [4]f32,
    ) !void {
        if (spread == 0) return self.addShadowRect(x, y, w, h, fill_color, shadow_color, shadow_blur, shadow_offset_x, shadow_offset_y, radii);
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = shadow_color,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = shadow_blur,
            .shadow_offset_x = shadow_offset_x,
            .shadow_offset_y = shadow_offset_y,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = shadow_spread_flag,
            .noise_scale = spread,
        });
    }

    /// packed_flags bit 28：外阴影带 spread（数值在 noise_scale）。
    pub const shadow_spread_flag: u32 = 1 << 28;

    /// 添加渐变矩形（单 instance，shader 原生插值）
    pub fn addGradientRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from_color: [4]f32,
        to_color: [4]f32,
        direction: GradientDir,
        radii: [4]f32,
    ) !void {
        return self.addGradientRectEx(x, y, w, h, from_color, to_color, direction, radii, .pad);
    }

    /// 添加渐变矩形（带延伸模式）
    pub fn addGradientRectEx(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from_color: [4]f32,
        to_color: [4]f32,
        direction: GradientDir,
        radii: [4]f32,
        extend_mode: GradientExtendMode,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = from_color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = to_color,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = SDFInstance.packFlagsEx(direction, .none, 0, false, false, extend_mode),
        });
    }

    /// 添加径向渐变矩形，支持自定义圆心位置和延伸模式
    /// center_x/center_y: UV 空间偏移，0,0 = 中心；范围建议 [-0.5, 0.5]
    /// 注意：径向渐变与外阴影互斥（shadow_offset 字段被复用为圆心参数）
    pub fn addRadialGradientRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from_color: [4]f32,
        to_color: [4]f32,
        radii: [4]f32,
        center_x: f32,
        center_y: f32,
        extend_mode: GradientExtendMode,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = from_color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = to_color,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = center_x, // 复用为圆心 UV X 偏移
            .shadow_offset_y = center_y, // 复用为圆心 UV Y 偏移
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = SDFInstance.packFlagsEx(.radial, .none, 0, false, false, extend_mode),
        });
    }

    /// 添加圆锥渐变矩形，支持自定义起始角和延伸模式
    /// start_angle_rad: 起始角（弧度，0 = 右方向，顺时针为正）
    pub fn addConicGradientRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from_color: [4]f32,
        to_color: [4]f32,
        radii: [4]f32,
        start_angle_rad: f32,
        extend_mode: GradientExtendMode,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = from_color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = to_color,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = SDFInstance.packFlagsEx(.conic, .none, 0, false, false, extend_mode),
            ._ext_reserved = @bitCast(start_angle_rad), // 复用为起始角
        });
    }

    /// 添加多色渐变矩形（多 stop，无 banding）
    /// radial_center_x/y: radial 方向时的圆心 UV 偏移（0,0 = 中心）
    /// conic_start_angle: conic 方向时的起始角（弧度）
    /// extend_mode: 渐变延伸模式（pad/repeat/reflect）
    pub fn addMultiGradientRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        stops: []const GradientStop,
        direction: GradientDir,
        radii: [4]f32,
        radial_center_x: f32,
        radial_center_y: f32,
        conic_start_angle: f32,
        extend_mode: GradientExtendMode,
        /// 径向椭圆半径（UV；0.5 = 内切）。非默认值经 bit 29 + noise_scale/intensity 传递。
        radial_radius: [2]f32,
    ) !void {
        const stop_offset: u32 = @intCast(self.grad_stops.items.len);
        // 防止 u32 下溢：stop_offset 满时直接跳过
        if (stop_offset >= MAX_GRADIENT_STOPS) {
            std.log.warn("[SDFRenderer] GradientStop buffer full ({} stops used), skipping multi_gradient", .{stop_offset});
            return;
        }
        const available = MAX_GRADIENT_STOPS - stop_offset;
        const stop_count: u32 = @intCast(@min(stops.len, available));
        if (stop_count < stops.len) {
            std.log.warn("[SDFRenderer] GradientStop clamped: requested {}, available {}", .{ stops.len, available });
        }
        try self.grad_stops.appendSlice(self.allocator, stops[0..stop_count]);
        // radial/conic 复用 shadow_offset 和 _ext_reserved
        const custom_radius = direction == .radial and
            (@abs(radial_radius[0] - 0.5) > 1e-4 or @abs(radial_radius[1] - 0.5) > 1e-4) and
            radial_radius[0] > 0 and radial_radius[1] > 0;
        const shadow_offset_x: f32 = if (direction == .radial) radial_center_x else 0;
        const shadow_offset_y: f32 = if (direction == .radial) radial_center_y else 0;
        const ext_reserved: u32 = if (direction == .conic) @bitCast(conic_start_angle) else 0;
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = if (stops.len > 0) stops[0].color else TRANSPARENT,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = if (stops.len > 1) stops[stops.len - 1].color else TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = shadow_offset_x,
            .shadow_offset_y = shadow_offset_y,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = SDFInstance.packFlagsEx(direction, .none, 0, false, false, extend_mode) |
                (if (custom_radius) radial_radius_flag else 0),
            .noise_scale = if (custom_radius) radial_radius[0] else 0,
            .noise_intensity = if (custom_radius) radial_radius[1] else 0,
            .gradient_stop_offset = stop_offset,
            .gradient_stop_count = stop_count,
            ._ext_reserved = ext_reserved,
        });
    }

    /// packed_flags bit 29：径向渐变带自定义椭圆半径（noise_scale = rx, noise_intensity = ry）。
    pub const radial_radius_flag: u32 = 1 << 29;

    /// 添加带噪声纹理的圆角矩形
    pub fn addNoiseRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        noise_mode: NoiseMode,
        noise_scale: f32,
        noise_intensity: f32,
        noise_seed: u8,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = SDFInstance.packFlags(.none, noise_mode, noise_seed, false, false),
            .noise_scale = @max(noise_scale, 1.0),
            .noise_intensity = noise_intensity,
        });
    }

    /// 添加带内阴影的圆角矩形
    /// shadow_color: 内阴影颜色；shadow_blur/offset_x/y: 内阴影参数
    pub fn addInsetShadowRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        shadow_color: [4]f32,
        shadow_blur: f32,
        shadow_offset_x: f32,
        shadow_offset_y: f32,
        radii: [4]f32,
    ) !void {
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = shadow_color,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = shadow_blur,
            .shadow_offset_x = shadow_offset_x,
            .shadow_offset_y = shadow_offset_y,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = SDFInstance.packFlags(.none, .none, 0, true, false),
        });
    }

    /// 添加带双阴影的圆角矩形（外阴影1 + 外阴影2）
    pub fn addDualShadowRect(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        shadow1_color: [4]f32,
        shadow1_blur: f32,
        shadow1_offset_x: f32,
        shadow1_offset_y: f32,
        shadow2: ShadowParam,
        radii: [4]f32,
    ) !void {
        const s2_index: u32 = @intCast(self.shadow2_params.items.len);
        if (s2_index >= MAX_SHADOW2) {
            std.log.warn("[SDFRenderer] ShadowParam buffer full ({} params), skipping dual_shadow", .{s2_index});
            return;
        }
        try self.shadow2_params.append(self.allocator, shadow2);
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = TRANSPARENT,
            .shadow_color = shadow1_color,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = clampRadii(radii, w, h),
            .border_width = 0,
            .shadow_blur = shadow1_blur,
            .shadow_offset_x = shadow1_offset_x,
            .shadow_offset_y = shadow1_offset_y,
            .shape_type = @intFromEnum(self.current_shape),
            .packed_flags = SDFInstance.packFlags(.none, .none, 0, false, true),
            .shadow2_index = s2_index,
        });
    }

    /// 添加圆弧（圆环的一段）
    /// cx, cy: 圆心（逻辑像素）
    /// outer_radius: 外半径
    /// stroke_width: 线宽
    /// start_angle: 起始角（弧度，0 = 右侧/3点钟，逆时针为正）
    /// end_angle: 结束角（弧度）
    /// color: 弧线颜色
    /// 内接 (x,y,w,h) 的椭圆。`border_width <= 0` 即无描边。
    ///
    /// per-side 描边对椭圆无意义（椭圆没有"四条边"），且 shader 的 per-side
    /// 分支硬编码矩形内轮廓，传进去会画出"矩形描边套椭圆填充"。所以入口
    /// 统一折叠：取四值的 **max** 而不是第一个（`{0,0,0,4}` 取第一个会静默
    /// 变成 0 宽描边，描边直接消失）。
    pub fn addEllipse(
        self: *SdfRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill_color: [4]f32,
        border_color: [4]f32,
        border_width: f32,
        border_widths: [4]f32,
    ) !void {
        const uniform_w = @max(border_width, @max(
            @max(border_widths[0], border_widths[1]),
            @max(border_widths[2], border_widths[3]),
        ));
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .rect_clip = self.current_rect_clip,
            .fill_color = fill_color,
            .border_color = border_color,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            // 椭圆不读 corner_radii（SDF 由半轴决定），置零避免误导。
            .corner_radii = .{ 0, 0, 0, 0 },
            .border_width = uniform_w,
            .shadow_blur = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shape_type = @intFromEnum(ShapeType.ellipse),
            .packed_flags = 0,
        });
    }

    pub fn addArc(
        self: *SdfRenderer,
        cx: f32,
        cy: f32,
        outer_radius: f32,
        stroke_width: f32,
        start_angle: f32,
        end_angle: f32,
        color: [4]f32,
    ) !void {
        // bounding box: 圆心为中心，边长 = 2 * outer_radius
        const size = outer_radius * 2;
        try self.instances.append(self.allocator, .{
            .rect = .{ cx - outer_radius, cy - outer_radius, size, size },
            .rect_clip = self.current_rect_clip,
            .fill_color = color,
            .border_color = TRANSPARENT,
            .shadow_color = TRANSPARENT,
            .gradient_to_color = TRANSPARENT,
            .corner_radii = .{ outer_radius, outer_radius, outer_radius, outer_radius },
            .border_width = stroke_width,
            .shadow_blur = 0,
            .shadow_offset_x = start_angle,
            .shadow_offset_y = end_angle,
            .shape_type = @intFromEnum(ShapeType.arc),
            .packed_flags = 0,
        });
    }

    /// 渲染所有实例（自动分批，防止 buffer 溢出）
    pub fn render(self: *SdfRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        if (self.instances.items.len == 0) return;
        self.instance_high_water_mark = @max(self.instance_high_water_mark, self.instances.items.len);

        // 更新 uniform buffer（只做一次）。
        // 溢出**不能** clamp 到最后一槽，那会让本次及后续所有 draw 别名同一块
        // 内存，随后被下一次 flush 覆写，静默画错。也不能报错丢批：调用方大多
        // `try` 透传，会把整帧乃至 App.run 打崩。槽位不够就用溢出 buffer 继续画。
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
            .frame_seed = self.frame_seed,
        };
        const uniform_data = try uniform_buffer.getMappedRange(uniform_byte_offset, @sizeOf(Uniforms));
        @memcpy(uniform_data, std.mem.asBytes(&uniforms));

        // 设置管线（只做一次）
        render_pass.setPipeline(&self.pipeline);
        render_pass.setVertexBuffer(0, uniform_buffer, @intCast(uniform_byte_offset));
        render_pass.setFragmentBuffer(0, uniform_buffer, @intCast(uniform_byte_offset));

        // 上传 GradientStop 数据到 slot 2（追加式：只传本次 flush 新增尾部）
        {
            const stop_buf = &self.stop_buffers[self.current_buffer];
            const stop_count = self.grad_stops.items.len;
            if (stop_count > self.grad_stops_uploaded) {
                const byte_off = @sizeOf(GradientStop) * self.grad_stops_uploaded;
                const new_bytes = @sizeOf(GradientStop) * (stop_count - self.grad_stops_uploaded);
                if (stop_buf.getMappedRange(byte_off, new_bytes)) |stop_data| {
                    @memcpy(stop_data, std.mem.sliceAsBytes(self.grad_stops.items[self.grad_stops_uploaded..]));
                    self.grad_stops_uploaded = stop_count;
                } else |_| {}
            }
            render_pass.setFragmentBuffer(2, stop_buf, 0);
        }

        // 上传 ShadowParam 数据到 slot 3（追加式，同上）
        {
            const s2_buf = &self.shadow2_buffers[self.current_buffer];
            const s2_count = self.shadow2_params.items.len;
            if (s2_count > self.shadow2_uploaded) {
                const byte_off = @sizeOf(ShadowParam) * self.shadow2_uploaded;
                const new_bytes = @sizeOf(ShadowParam) * (s2_count - self.shadow2_uploaded);
                if (s2_buf.getMappedRange(byte_off, new_bytes)) |s2_data| {
                    @memcpy(s2_data, std.mem.sliceAsBytes(self.shadow2_params.items[self.shadow2_uploaded..]));
                    self.shadow2_uploaded = s2_count;
                } else |_| {}
            }
            render_pass.setFragmentBuffer(3, s2_buf, 0);
            // vertex 阶段也读 shadow_params（双层阴影 quad 扩边取两层 max）
            render_pass.setVertexBuffer(3, s2_buf, 0);
        }

        // 分批渲染，每批不超过 buffer 剩余容量
        var offset: usize = 0;
        while (offset < self.instances.items.len) {
            const remaining_total = self.instances.items.len - offset;
            const remaining_capacity = MAX_INSTANCES - self.buffer_write_offset;
            const batch_count = if (remaining_capacity == 0)
                remaining_total
            else
                @min(remaining_total, remaining_capacity);
            const instance_size = @sizeOf(SDFInstance) * batch_count;

            if (remaining_capacity == 0) {
                // 复用本帧槽位的溢出缓冲；容量不足才重建（几何增长，避免抖动）。
                const needed = self.overflow_write_offset + instance_size;
                if (self.overflow_capacities[self.current_buffer] < needed) {
                    var new_capacity = @max(self.overflow_capacities[self.current_buffer], instance_size);
                    while (new_capacity < needed) new_capacity *= 2;
                    if (self.overflow_buffers[self.current_buffer]) |*old| old.destroy();
                    self.overflow_buffers[self.current_buffer] = try self.device.createBuffer(self.allocator, .{
                        .label = "Zenit.SDF.OverflowInstanceBuffer",
                        .size = new_capacity,
                        .usage = .{ .vertex = true, .map_write = true },
                    });
                    self.overflow_capacities[self.current_buffer] = new_capacity;
                }
                const overflow_buffer = &self.overflow_buffers[self.current_buffer].?;
                const overflow_data = try overflow_buffer.getMappedRange(self.overflow_write_offset, instance_size);
                @memcpy(overflow_data, std.mem.sliceAsBytes(self.instances.items[offset .. offset + batch_count]));
                render_pass.setVertexBuffer(1, overflow_buffer, @intCast(self.overflow_write_offset));
                render_pass.setFragmentBuffer(1, overflow_buffer, @intCast(self.overflow_write_offset));
                self.overflow_write_offset += instance_size;
            } else {
                const byte_offset = self.buffer_write_offset * @sizeOf(SDFInstance);
                const instance_data = try self.instance_buffers[self.current_buffer].getMappedRange(byte_offset, instance_size);
                @memcpy(instance_data, std.mem.sliceAsBytes(self.instances.items[offset .. offset + batch_count]));
                render_pass.setVertexBuffer(1, &self.instance_buffers[self.current_buffer], @intCast(byte_offset));
                render_pass.setFragmentBuffer(1, &self.instance_buffers[self.current_buffer], @intCast(byte_offset));
                self.buffer_write_offset += batch_count;
            }

            render_pass.draw(6, @intCast(batch_count), 0, 0);
            sdf_draw_calls += 1;
            offset += batch_count;
        }
    }

    /// 刷新当前实例到 GPU，然后清空实例列表
    /// 用于 clip stack 切换时需要先绘制当前实例
    pub fn flush(self: *SdfRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        if (self.instances.items.len == 0) return;
        // render() 内部已更新 buffer_write_offset，无需再追加
        try self.render(render_pass);
        self.instances.clearRetainingCapacity();
    }
};

// ============================================================================
// Tests
// ============================================================================

/// `sdf_primitives.metal` 的 `sdf_ellipse` 在 CPU 侧的**逐字复刻**。
/// 存在的唯一理由：shader 是 `@embedFile` 运行时编译的，`zig build` 全绿
/// 并不代表 shader 数值正确。把公式钉一份在这里，后人若把它"优化"回
/// `(length(p/r)-1) * min(rx,ry)` 这类无量纲/错量纲写法，下面的断言会红。
fn sdfEllipseRef(px: f64, py: f64, rx: f64, ry: f64) f64 {
    const r_x = @max(rx, 0.001);
    const r_y = @max(ry, 0.001);
    const qx = px / r_x;
    const qy = py / r_y;
    const k = @sqrt(qx * qx + qy * qy);
    if (k < 1e-6) return -@min(r_x, r_y);
    const gx = px / (r_x * r_x);
    const gy = py / (r_y * r_y);
    const g = @sqrt(gx * gx + gy * gy) / k;
    return (k - 1.0) / @max(g, 1e-6);
}

test "sdf_ellipse 返回真实像素距离（而不是无量纲值或错量纲）" {
    const testing = std.testing;
    // 正圆：解析解精确，这一条钉住"量纲是像素"
    try testing.expectApproxEqAbs(@as(f64, 10.0), sdfEllipseRef(60, 0, 50, 50), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -10.0), sdfEllipseRef(40, 0, 50, 50), 1e-9);

    // 10:1 扁椭圆的长轴端点：真实距离 = 20。
    // 旧的 `* min(rx,ry)` 写法在这里会得到 2.0（差 10 倍），AA 过渡带被拉宽
    // 10 倍，长轴两端肉眼可见发虚。误差放宽到 10% 容纳一阶近似本身。
    const d = sdfEllipseRef(220, 0, 200, 20);
    try testing.expect(d > 18.0 and d < 22.0);

    // 短轴端点同样要对（各向异性下两轴不能只对一边）
    const d2 = sdfEllipseRef(0, 24, 200, 20);
    try testing.expect(d2 > 3.6 and d2 < 4.4);

    // 中心：梯度为 0，退化成最短半轴的负距离
    try testing.expectApproxEqAbs(@as(f64, -20.0), sdfEllipseRef(0, 0, 200, 20), 1e-9);
}

test "uniform 槽位用尽后继续画（溢出 buffer），不再返回 UniformSlotsExhausted" {
    // 回归：单帧 >256 次 flush 时旧实现返回 error.UniformSlotsExhausted，
    // opacity layer / encoder.flush 等调用点 `try` 透传，打崩 App.run。
    // SKIP-REASON: 需要 Null 后端的确定性 createBuffer/stats（Metal 下是 test-metal 的领域）
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    const created_base = gpu.Backend.stats.buffers_created;
    const destroyed_base = gpu.Backend.stats.buffers_destroyed;
    {
        var r = try SdfRenderer.init(alloc, &device);
        defer r.deinit();
        var encoder = try gpu.Backend.CommandEncoder.init(&queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{} });

        // 两帧：第二帧落到另一个帧槽位，验证溢出 buffer 按槽位独立分配。
        for (0..2) |frame| {
            r.beginFrame(800, 600, 2.0, @intCast(frame));
            for (0..MAX_UNIFORM_UPDATES + 40) |i| {
                try r.addRoundedRect(@floatFromInt(i % 100), 0, 10, 10, .{ 1, 0, 0, 1 }, .{ 2, 2, 2, 2 });
                try r.flush(&pass);
            }
        }
        try std.testing.expectEqual(@as(usize, 40), r.uniform_overflow_used);
        try std.testing.expect(r.uniform_overflow_buffers[r.current_buffer] != null);
        pass.end();
    }
    // deinit 必须释放溢出 uniform buffer（Null 后端计数平衡）。
    try std.testing.expectEqual(
        gpu.Backend.stats.buffers_created - created_base,
        gpu.Backend.stats.buffers_destroyed - destroyed_base,
    );
}
