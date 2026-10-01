/// Path Renderer，矢量路径 GPU 渲染（D5：含边缘 AA）
///
/// 流程：
///   1. `addFillPath()` 接收 Contour 列表（来自 PathTessellator）
///   2. CPU Earcut 生成填充三角形
///   3. 沿轮廓边生成 AA fringe strip（外侧 alpha_scale=0，内侧=1）
///   4. `flush()` 时通过 vertex buffer 上传 GPU，draw 绘制
const std = @import("std");
const gpu = @import("gpu");
const Contour = @import("path_tessellator.zig").Contour;
const TPoint = @import("path_tessellator.zig").TPoint;

pub const max_polygon_points: usize = 32;
pub const max_polygon_contours: usize = 8;

pub const LineJoin = enum {
    miter,
    bevel,
    round,
};

pub const PathPolygon = struct {
    point_count: u32 = 0,
    contour_count: u32 = 0,
    fill_rule: u32 = 0,
    contour_end_points: [max_polygon_contours]u32 = [_]u32{0} ** max_polygon_contours,
    points: [max_polygon_points][2]f32 = [_][2]f32{.{ 0, 0 }} ** max_polygon_points,

    pub fn fromClipPolygon(polygon: anytype) PathPolygon {
        var out = PathPolygon{
            .point_count = polygon.point_count,
            .contour_count = polygon.contour_count,
            .fill_rule = @intFromEnum(polygon.fill_rule),
        };
        const contour_count = @min(@as(usize, polygon.contour_count), max_polygon_contours);
        for (0..contour_count) |i| out.contour_end_points[i] = polygon.contour_end_points[i];
        const point_count = @min(@as(usize, polygon.point_count), max_polygon_points);
        for (0..point_count) |i| out.points[i] = polygon.points[i];
        return out;
    }
};

const path_shader_source: []const u8 = @embedFile("shaders/path.metal");

// ============================================================================
// Uniforms，与 path.metal PathUniforms 对齐
// ============================================================================

const PathUniforms = extern struct {
    viewport_size: [2]f32,
    scale_factor: f32,
    draw_mode: u32 = 0,
    color: [4]f32 = .{ 0, 0, 0, 0 },
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    fill_rule: u32 = 0,
    point_count: u32 = 0,
    contour_count: u32 = 0,
    _pad0: u32 = 0,
    contour_end_points: [max_polygon_contours]u32 = [_]u32{0} ** max_polygon_contours,
    polygon_points: [max_polygon_points][2]f32 = [_][2]f32{.{ 0, 0 }} ** max_polygon_points,
    // shape clip mask（与 path.metal PathUniforms 对齐；kind 0=none/1=rounded_rect/2=ellipse）
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radius: f32 = 0,
    clip_shape_kind: u32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

// ============================================================================
// 顶点格式，与 path.metal PathVertex 对齐
// ============================================================================

const PathVertex = extern struct {
    x: f32,
    y: f32,
    /// AA 权重：填充三角形 = 1.0；fringe 外侧顶点 = 0.0，内侧 = 1.0
    alpha_scale: f32,
    /// linear RGB + alpha（非预乘；shader 端做预乘）。per-vertex 色使相邻
    /// triangles draw call 可合并为一次 draw。add* 入口统一回填。
    color: [4]f32 = .{ 0, 0, 0, 0 },
};

// ============================================================================
// 单次绘制命令（一个 fill path call）
// ============================================================================

const DrawCall = struct {
    mode: DrawMode = .triangles,
    vertex_start: u32, // 在 vertex_buf 中的起始索引
    vertex_count: u32, // 顶点数量（= index_count，因为三角形列表）
    color: [4]f32, // RGBA linear + alpha（polygon_fill 经 uniforms 用；triangles 已 per-vertex）
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    polygon: PathPolygon = .{},
    /// add 时刻的 rect clip（w/h < 0 = 无裁剪）。合批后 flush 跨 clip 变化，
    /// scissor 必须按 draw call 分组应用而非取 flush 时刻的单一状态。
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
};

const DrawMode = enum(u32) {
    triangles = 0,
    polygon_fill = 1,
};

/// 最大顶点数（单帧，动态分配）。
///
/// 65K 只能承载约一千条带双端 marker 的矢量连接线；画布在 fit/pan 时会
/// 合法地一次挂载更多路径，旧上限会把正常文档变成 TooManyPathVertices
/// 致命错误。缓冲仍按实际用量增长；这里把安全阀提高到最多约 56 MiB 原始
/// 顶点数据，足以覆盖 42×42 endpoint gallery 的 fit-all 场景。
const MAX_VERTICES_PER_FRAME = 2097152;

// Phase C mesh 缓存参数：总顶点预算 + 闲置逐出 TTL（帧）
const MESH_CACHE_MAX_VERTICES = 262144;
const MESH_CACHE_TTL_FRAMES = 240;

// ── 顶点 buffer 高水位收缩 ──
//
// ensureVertexBufferCapacity 只扩不缩：大画布 fit-all 一次冲到 ~56MiB 后
// 峰值即永久驻留。收缩判据 = **连续** SHRINK_FRAMES 帧用量低于
// capacity/SHRINK_DIVISOR 才释放。单帧判据会抖动，pan/zoom 场景帧间用量
// 波动大，任何一帧回到高水位都重置计数，振荡负载永远触发不了建销循环；
// 触发后也只在下一次真的有路径内容时按需重建一次 buffer。
const SHRINK_DIVISOR: usize = 4;
/// ~4s @60fps，与 MESH_CACHE_TTL_FRAMES 同阶。
const SHRINK_FRAMES: u32 = 240;
/// 低于该容量不值得收缩（重建开销 > 内存收益）。
const SHRINK_MIN_CAPACITY: usize = 256 * 1024;

/// 与 glyph_atlas.MAX_FRAMES_IN_FLIGHT 同一合同（FrameSync 三重缓冲）：
/// buffer retire 后至少隔这么多帧才真正 destroy，保证在飞的 command buffer
/// 不会引用已释放的 GPU buffer。
const BUFFER_MAX_FRAMES_IN_FLIGHT: u64 = 3;

/// 收缩判据状态机。设备无关的纯逻辑，单测确定性验证触发帧边界。
/// 每帧调用一次 `noteFrame(上一帧字节用量, 当前容量)`；返回 true = 本帧应收缩。
pub const ShrinkPolicy = struct {
    low_frames: u32 = 0,

    pub fn noteFrame(self: *ShrinkPolicy, used_bytes: usize, capacity: usize) bool {
        if (capacity <= SHRINK_MIN_CAPACITY or
            used_bytes >= capacity / SHRINK_DIVISOR)
        {
            self.low_frames = 0;
            return false;
        }
        self.low_frames += 1;
        if (self.low_frames < SHRINK_FRAMES) return false;
        self.low_frames = 0;
        return true;
    }
};

/// 已从 vertex_buffer 摘除、但可能仍被在飞 command buffer 引用的 buffer。
/// 语义同 glyph_atlas.RetiredTexture：epoch 延迟回收。
const RetiredBuffer = struct {
    buffer: gpu.Backend.Buffer,
    retired_at_frame: u64,
};

/// retire 帧号是否已飞过 in-flight 窗口，可安全 destroy。
fn retiredBufferReady(retired_at_frame: u64, current_frame: u64) bool {
    return current_frame -| retired_at_frame >= BUFFER_MAX_FRAMES_IN_FLIGHT;
}

const MeshEntry = struct {
    verts: []PathVertex,
    last_used: u64,
};

/// 矢量填充的渐变规格（可选）。存在的理由：`fill_path` 的 GPU 侧**早就支持
/// per-vertex 颜色**（`PathVertex.color`，path.metal 的 fragment 直接插值
/// `in.fill_color`），只是 CPU 侧一直把统一色回填进每个顶点。多边形（三角/
/// 星形）的渐变填充就卡在这一步，之前只能退化成纯色。
///
/// 做法：三角化之后，按每个顶点在 bbox 内的归一化位置求 t，再按 stop 插值
/// 写进 `PathVertex.color`。顶点级插值对凸多边形与三角化后的凹多边形都成立
/// （光栅器在三角形内做线性插值，与渐变本身的线性性一致）。
///
/// 已知偏差：radial/conic 在**顶点**求值，弯曲等值线只在三角形内被线性近似。
/// 三角/星形顶点少，径向渐变会略显棱角，真要精确需要 fragment 侧求值
/// （给 path.metal 加 gradient uniform），那是独立一笔。
pub const FillGradient = struct {
    /// 与 sdf_renderer.GradientDir 同序（1=vertical 2=horizontal 3=diagonal
    /// 4=radial 5=conic）。0/none 表示不用渐变。
    dir: u32 = 0,
    stops: []const GradientStopIn = &.{},
    /// radial/conic 的中心（bbox 归一化，0.5,0.5 = 正中）
    center_x: f32 = 0.5,
    center_y: f32 = 0.5,
    /// conic 起始角（弧度）
    start_angle: f32 = 0,

    pub const GradientStopIn = struct { color: [4]f32, position: f32 };

    /// 求某个归一化位置 (u,v ∈ [0,1]) 的渐变 t 值。
    fn tAt(self: *const FillGradient, u: f32, v: f32) f32 {
        return switch (self.dir) {
            1 => v, // vertical
            2 => u, // horizontal
            3 => (u + v) * 0.5, // diagonal
            4 => blk: { // radial：到中心的归一化距离（×2 让边缘 ≈ 1）
                const dx = u - self.center_x;
                const dy = v - self.center_y;
                break :blk std.math.clamp(@sqrt(dx * dx + dy * dy) * 2.0, 0, 1);
            },
            5 => blk: { // conic：绕中心的角度
                const dx = u - self.center_x;
                const dy = v - self.center_y;
                var ang = std.math.atan2(dy, dx) - self.start_angle;
                const tau = std.math.tau;
                ang = @mod(ang, tau);
                if (ang < 0) ang += tau;
                break :blk @as(f32, @floatCast(ang / tau));
            },
            else => 0,
        };
    }

    /// 按 stop 列表插值出颜色（stops 必须按 position 升序；pad 语义）。
    fn colorAt(self: *const FillGradient, t_in: f32) [4]f32 {
        if (self.stops.len == 0) return .{ 0, 0, 0, 0 };
        if (self.stops.len == 1) return self.stops[0].color;
        const t = std.math.clamp(t_in, 0, 1);
        if (t <= self.stops[0].position) return self.stops[0].color;
        const last = self.stops[self.stops.len - 1];
        if (t >= last.position) return last.color;
        var i: usize = 1;
        while (i < self.stops.len) : (i += 1) {
            const a = self.stops[i - 1];
            const b = self.stops[i];
            if (t <= b.position) {
                const span = b.position - a.position;
                const k: f32 = if (span > 1e-6) (t - a.position) / span else 0;
                var out: [4]f32 = undefined;
                for (0..4) |c| out[c] = a.color[c] + (b.color[c] - a.color[c]) * k;
                return out;
            }
        }
        return last.color;
    }
};

pub const PathRenderer = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    pipeline: gpu.Backend.RenderPipeline,
    /// 当前帧槽位的顶点 buffer。
    ///
    /// 曾经是**单个** buffer 且每帧把 buffer_write_offset 归零：三帧在飞时第
    /// N+1 帧的 memcpy 覆写 GPU 尚未消费的第 N 帧顶点（与 icon_renderer 修过的
    /// 是同一类 bug）。现在按帧槽位轮转：本帧用的 buffer 在 beginFrame 停到
    /// `parked_buffers[buffer_slot]`，BUFFER_MAX_FRAMES_IN_FLIGHT 帧后才轮回来复用。
    vertex_buffer: ?gpu.Backend.Buffer,
    vertex_buffer_capacity: usize,
    buffer_write_offset: usize,
    parked_buffers: [BUFFER_MAX_FRAMES_IN_FLIGHT]?gpu.Backend.Buffer = [_]?gpu.Backend.Buffer{null} ** BUFFER_MAX_FRAMES_IN_FLIGHT,
    parked_capacities: [BUFFER_MAX_FRAMES_IN_FLIGHT]usize = [_]usize{0} ** BUFFER_MAX_FRAMES_IN_FLIGHT,
    buffer_slot: usize = 0,

    // CPU 端三角形顶点累积（每帧重置）
    vertices: std.ArrayList(PathVertex),
    draw_calls: std.ArrayList(DrawCall),
    // earclip 逐 contour 的临时点表，跨 addFillPath 复用
    earclip_pts: std.ArrayList(TPoint) = .{},

    // ── Phase C：跨帧 mesh 缓存 ──
    // key = wyhash(path 命令逐 tag payload + fill/stroke 判别 + scale +
    // stroke 参数)（encoder 侧算）。value = **path-local** 顶点（offset 去除、
    // 平移不变，earclip/fringe/stroke expand 全是加性平移）。
    // 命中 = 跳过 flatten + earclip/stroke expand，直接平移回填。
    mesh_cache: std.AutoHashMapUnmanaged(u64, MeshEntry) = .{},
    mesh_cache_vertex_total: usize = 0,
    current_frame: u64 = 0,
    frame_mesh_hits: u32 = 0,
    frame_mesh_misses: u32 = 0,
    /// 最近一次 flush 实际发出的 GPU draw 数（合批后 ≤ draw_calls 数），debug 探针用
    last_flush_draw_count: u32 = 0,
    /// damage-rect 部分重绘：当前 pass 的脏区 scissor（物理像素 x,y,w,h）。
    /// path renderer 自管 per-DrawCall scissor，每次 setScissorRect 都必须
    /// 与它取交，否则会把脏区外应保留的旧像素画穿。由 encoder 在 pass 切换/
    /// 恢复时维护（beginOpacityLayerInto / applyOffscreenTargetViewport）。
    damage_scissor: ?[4]u32 = null,
    /// 帧累计：add* 提交的逻辑 draw call 数 / 合批后实际 draw 数（beginFrame 清零）
    frame_call_count: u32 = 0,
    frame_draw_count: u32 = 0,

    // ── 顶点 buffer 高水位收缩状态 ──
    /// beginFrame 递增的本地帧计数。与 Phase C 的 current_frame 不同：那个由
    /// encoder setFrame 驱动，无路径内容的帧不推进；而收缩判据与延迟释放
    /// 恰恰要把"空帧"也计成低水位帧，所以必须每帧都走表。
    shrink_frame: u64 = 0,
    shrink_policy: ShrinkPolicy = .{},
    /// 延迟释放队列（见 RetiredBuffer / drainRetiredBuffers）。
    retired_buffers: std.ArrayListUnmanaged(RetiredBuffer) = .{},

    viewport_width: f32,
    viewport_height: f32,
    scale_factor: f32,
    current_rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radius: f32 = 0,
    clip_shape_kind: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !PathRenderer {
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, path_shader_source);
        defer shader.deinit();

        var vertex_func = try shader.getFunction("path_vertex_main");
        defer vertex_func.deinit();
        var fragment_func = try shader.getFunction("path_fragment_main");
        defer fragment_func.deinit();

        const pipeline = try gpu.Backend.createRenderPipeline(device, .{
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

        return PathRenderer{
            .allocator = allocator,
            .device = device,
            .pipeline = pipeline,
            .vertex_buffer = null,
            .vertex_buffer_capacity = 0,
            .buffer_write_offset = 0,
            .vertices = .{},
            .draw_calls = .{},
            .viewport_width = 800,
            .viewport_height = 600,
            .scale_factor = 1.0,
            .current_rect_clip = .{ 0, 0, -1, -1 },
        };
    }

    pub fn deinit(self: *PathRenderer) void {
        var it = self.mesh_cache.valueIterator();
        while (it.next()) |e| self.allocator.free(e.verts);
        self.mesh_cache.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.draw_calls.deinit(self.allocator);
        self.earclip_pts.deinit(self.allocator);
        if (self.vertex_buffer) |*buffer| buffer.destroy();
        for (&self.parked_buffers) |*maybe| {
            if (maybe.*) |*buffer| buffer.destroy();
        }
        // deinit 合同与 offscreen_pool 相同：owner 须在 GPU drain 之后调用，
        // 此时同步 destroy retired buffer 是安全的。
        for (self.retired_buffers.items) |*entry| entry.buffer.destroy();
        self.retired_buffers.deinit(self.allocator);
        self.pipeline.deinit();
    }

    pub fn setViewport(self: *PathRenderer, w: f32, h: f32, scale: f32) void {
        self.viewport_width = w;
        self.viewport_height = h;
        self.scale_factor = scale;
    }

    pub fn beginFrame(self: *PathRenderer, w: f32, h: f32, scale: f32) void {
        self.setViewport(w, h, scale);
        self.shrink_frame += 1;
        self.drainRetiredBuffers();
        // buffer_write_offset 此刻仍是上一帧的累计字节用量（跨 pass 多次
        // flush 的总和），正是收缩判据的输入；随后才清零。
        // 判据用各槽位的最大容量：轮转后槽位容量各异，用当前槽位会被空槽
        // （容量 0 -> 视为"不需要收缩"）每帧重置计数，永远收缩不了。
        if (self.shrink_policy.noteFrame(self.buffer_write_offset, self.peakSlotCapacity())) {
            // 各槽容量可能各异，统一退役（走延迟释放，在飞帧不受影响）；需要时按实际用量重建。
            self.retireVertexBuffer();
            self.retireParkedBuffers();
            // CPU 侧顶点/draw call 表同为峰值驻留（56MiB 量级同源），一并放掉
            // 容量。此处两表已被上一帧 flush 清空，free 的只是闲置 capacity。
            self.vertices.clearAndFree(self.allocator);
            self.draw_calls.clearAndFree(self.allocator);
        }
        self.rotateVertexBufferSlot();
        self.buffer_write_offset = 0;
        self.current_rect_clip = .{ 0, 0, -1, -1 };
        self.frame_call_count = 0;
        self.frame_draw_count = 0;
    }

    pub fn setRectClip(self: *PathRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
    }

    /// shape clip mask。path 只支持 rounded_rect(1)/ellipse(2)；polygon(3) 对
    /// path pipeline 不生效（调用方保证 polygon clip 场景不走 shader clip 转换）。
    pub fn setClipMask(self: *PathRenderer, shape_kind: u32, rect: ?[4]f32, radius: f32) void {
        if (rect) |mask_rect| {
            self.clip_rect = mask_rect;
            self.clip_radius = radius;
            self.clip_shape_kind = if (shape_kind <= 2) shape_kind else 0;
        } else {
            self.clip_rect = .{ 0, 0, 0, 0 };
            self.clip_radius = 0;
            self.clip_shape_kind = 0;
        }
    }

    /// 添加一条填充路径（轮廓 -> Earcut + AA fringe -> 追加三角形顶点）
    /// 返回产出的顶点区间（Phase C storeMesh 用）；null = 无有效三角形
    pub fn addFillPath(
        self: *PathRenderer,
        contours: []const Contour,
        color_rgba: [4]f32,
        offset_x: f32,
        offset_y: f32,
    ) !?[2]u32 {
        return self.addFillPathGradient(contours, color_rgba, offset_x, offset_y, null);
    }

    /// 同 `addFillPath`，但可选按渐变逐顶点着色（`grad == null` 即统一色）。
    pub fn addFillPathGradient(
        self: *PathRenderer,
        contours: []const Contour,
        color_rgba: [4]f32,
        offset_x: f32,
        offset_y: f32,
        grad: ?FillGradient,
    ) !?[2]u32 {
        const vertex_start: u32 = @intCast(self.vertices.items.len);

        for (contours) |contour| {
            const point_count = contour.pointCount();
            if (point_count < 3 or point_count > MAX_EARCLIP_POINTS) continue;
            const contour_vertex_start = self.vertices.items.len;
            // 填充三角形（alpha_scale = 1.0）
            try earclipFill(self.allocator, &self.earclip_pts, &self.vertices, contour, offset_x, offset_y);
            // 三角化拒绝了非有限/病态输入时，fringe 也必须跳过；否则它会
            // 重新把 NaN 顶点送进 GPU，且绕过上面的 earclip 工作量上限。
            if (self.vertices.items.len == contour_vertex_start) continue;
            // AA fringe strip 沿轮廓边（外侧 alpha_scale = 0.0）
            try buildAaFringe(self.allocator, &self.vertices, contour, offset_x, offset_y, self.scale_factor);
        }

        const vertex_end: u32 = @intCast(self.vertices.items.len);
        if (vertex_end == vertex_start) return null; // 无有效三角形
        if (self.vertices.items.len > MAX_VERTICES_PER_FRAME) return error.TooManyPathVertices;

        if (grad) |g| if (g.dir != 0 and g.stops.len > 0) {
            // 逐顶点求渐变色：先取本次新增顶点的 bbox（几何已含 offset），
            // 再按归一化位置求 t -> 颜色。GPU 侧线性插值，fragment 不用改。
            var min_x: f32 = std.math.floatMax(f32);
            var min_y: f32 = std.math.floatMax(f32);
            var max_x: f32 = -std.math.floatMax(f32);
            var max_y: f32 = -std.math.floatMax(f32);
            for (self.vertices.items[vertex_start..]) |v| {
                min_x = @min(min_x, v.x);
                min_y = @min(min_y, v.y);
                max_x = @max(max_x, v.x);
                max_y = @max(max_y, v.y);
            }
            const span_x = @max(max_x - min_x, 1e-6);
            const span_y = @max(max_y - min_y, 1e-6);
            for (self.vertices.items[vertex_start..]) |*v| {
                const uu = (v.x - min_x) / span_x;
                const vv = (v.y - min_y) / span_y;
                var c = g.colorAt(g.tAt(uu, vv));
                // alpha 再乘调用方的整体不透明度；AA fringe 的 alpha_scale
                // 由 shader 另乘，这里不碰。
                c[3] *= color_rgba[3];
                v.color = c;
            }
            try self.draw_calls.append(self.allocator, DrawCall{
                .mode = .triangles,
                .vertex_start = vertex_start,
                .vertex_count = vertex_end - vertex_start,
                .color = color_rgba,
                .rect_clip = self.current_rect_clip,
            });
            return .{ vertex_start, vertex_end };
        };

        for (self.vertices.items[vertex_start..]) |*v| v.color = color_rgba;
        try self.draw_calls.append(self.allocator, DrawCall{
            .mode = .triangles,
            .vertex_start = vertex_start,
            .vertex_count = vertex_end - vertex_start,
            .color = color_rgba,
            .rect_clip = self.current_rect_clip,
        });
        return .{ vertex_start, vertex_end };
    }

    pub fn addPolygonFillPath(
        self: *PathRenderer,
        polygon: PathPolygon,
        color_rgba: [4]f32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) !void {
        if (w <= 0 or h <= 0) return;
        if (polygon.point_count < 3 or polygon.contour_count == 0) return;

        const vertex_start: u32 = @intCast(self.vertices.items.len);

        try self.vertices.append(self.allocator, .{ .x = x, .y = y, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x + w, .y = y, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x, .y = y + h, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x + w, .y = y, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x + w, .y = y + h, .alpha_scale = 1.0 });
        try self.vertices.append(self.allocator, .{ .x = x, .y = y + h, .alpha_scale = 1.0 });

        if (self.vertices.items.len > MAX_VERTICES_PER_FRAME) return error.TooManyPathVertices;

        try self.draw_calls.append(self.allocator, DrawCall{
            .mode = .polygon_fill,
            .vertex_start = vertex_start,
            .vertex_count = 6,
            .color = color_rgba,
            .rect = .{ x, y, w, h },
            .polygon = polygon,
            .rect_clip = self.current_rect_clip,
        });
    }

    /// 添加一条描边路径（轮廓 -> 沿边展开矩形 quad + AA fringe -> 追加三角形顶点）
    pub fn addStrokePath(
        self: *PathRenderer,
        contours: []const Contour,
        color_rgba: [4]f32,
        stroke_width: f32,
        line_join: LineJoin,
        offset_x: f32,
        offset_y: f32,
    ) !?[2]u32 {
        const vertex_start: u32 = @intCast(self.vertices.items.len);
        const half_w = stroke_width * 0.5;

        for (contours) |contour| {
            if (contour.pointCount() < 2) continue;
            try buildStrokeExpand(self.allocator, &self.vertices, contour, offset_x, offset_y, half_w, self.scale_factor, line_join);
        }

        const vertex_end: u32 = @intCast(self.vertices.items.len);
        if (vertex_end == vertex_start) return null;
        if (self.vertices.items.len > MAX_VERTICES_PER_FRAME) return error.TooManyPathVertices;

        for (self.vertices.items[vertex_start..]) |*v| v.color = color_rgba;
        try self.draw_calls.append(self.allocator, DrawCall{
            .mode = .triangles,
            .vertex_start = vertex_start,
            .vertex_count = vertex_end - vertex_start,
            .color = color_rgba,
            .rect_clip = self.current_rect_clip,
        });
        return .{ vertex_start, vertex_end };
    }

    /// Phase C：帧推进 + 周期性逐出闲置 mesh。encoder 每帧编码前调。
    pub fn setFrame(self: *PathRenderer, frame: u64) void {
        if (frame == self.current_frame) return;
        self.current_frame = frame;
        self.frame_mesh_hits = 0;
        self.frame_mesh_misses = 0;
        if (frame % 120 != 0) return;
        var stale: [64]u64 = undefined;
        var n: usize = 0;
        var it = self.mesh_cache.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.last_used + MESH_CACHE_TTL_FRAMES < frame and n < stale.len) {
                stale[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| {
            if (self.mesh_cache.fetchRemove(k)) |kv| {
                self.mesh_cache_vertex_total -= kv.value.verts.len;
                self.allocator.free(kv.value.verts);
            }
        }
    }

    /// Phase C：缓存命中路径，平移回填 + 补色 + 记 draw call。
    /// 返回 false = 未命中（caller 走 flatten + add*Path，然后 storeMesh）。
    pub fn appendCachedMesh(self: *PathRenderer, key: u64, color_rgba: [4]f32, offset_x: f32, offset_y: f32) !bool {
        const e = self.mesh_cache.getPtr(key) orelse {
            self.frame_mesh_misses += 1;
            return false;
        };
        e.last_used = self.current_frame;
        const vertex_start: u32 = @intCast(self.vertices.items.len);
        if (self.vertices.items.len + e.verts.len > MAX_VERTICES_PER_FRAME) return error.TooManyPathVertices;
        try self.vertices.ensureUnusedCapacity(self.allocator, e.verts.len);
        for (e.verts) |v| {
            self.vertices.appendAssumeCapacity(.{
                .x = v.x + offset_x,
                .y = v.y + offset_y,
                .alpha_scale = v.alpha_scale,
                .color = color_rgba,
            });
        }
        try self.draw_calls.append(self.allocator, DrawCall{
            .mode = .triangles,
            .vertex_start = vertex_start,
            .vertex_count = @intCast(e.verts.len),
            .color = color_rgba,
            .rect_clip = self.current_rect_clip,
        });
        self.frame_mesh_hits += 1;
        return true;
    }

    /// Phase C：把刚 add*Path 产出的顶点区间（本帧 vertices 里）以 path-local
    /// 形式存入缓存。任何失败静默放弃（缓存是纯优化）。
    pub fn storeMesh(self: *PathRenderer, key: u64, vertex_start: u32, vertex_end: u32, offset_x: f32, offset_y: f32) void {
        if (vertex_end <= vertex_start) return;
        if (self.mesh_cache.contains(key)) return;
        const n = vertex_end - vertex_start;
        if (self.mesh_cache_vertex_total + n > MESH_CACHE_MAX_VERTICES) return;
        const copy = self.allocator.alloc(PathVertex, n) catch return;
        for (self.vertices.items[vertex_start..vertex_end], 0..) |v, i| {
            copy[i] = .{ .x = v.x - offset_x, .y = v.y - offset_y, .alpha_scale = v.alpha_scale };
        }
        self.mesh_cache.put(self.allocator, key, .{ .verts = copy, .last_used = self.current_frame }) catch {
            self.allocator.free(copy);
            return;
        };
        self.mesh_cache_vertex_total += n;
    }

    /// 提交本帧所有路径绘制命令
    pub fn flush(self: *PathRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        defer {
            self.vertices.clearRetainingCapacity();
            self.draw_calls.clearRetainingCapacity();
        }

        if (self.draw_calls.items.len == 0) return;

        render_pass.setPipeline(&self.pipeline);
        render_pass.setViewport(
            0,
            0,
            self.viewport_width * self.scale_factor,
            self.viewport_height * self.scale_factor,
            0,
            1,
        );

        if (self.vertices.items.len > 0) {
            const vertex_bytes = std.mem.sliceAsBytes(self.vertices.items);
            const byte_offset = self.buffer_write_offset;
            try self.ensureVertexBufferCapacity(byte_offset + vertex_bytes.len);
            if (self.vertex_buffer) |*vertex_buffer| {
                const mapped = try vertex_buffer.getMappedRange(byte_offset, vertex_bytes.len);
                @memcpy(mapped, vertex_bytes);
                render_pass.setVertexBuffer(0, vertex_buffer, @intCast(byte_offset));
            } else unreachable;
            self.buffer_write_offset = byte_offset + vertex_bytes.len;
        }

        // 按 rect_clip 分组应用 scissor；相邻同 clip 的 triangles call
        // （顶点区间连续，颜色已 per-vertex）合并为一次 draw。
        var draws_issued: u32 = 0;
        var applied_scissor: ?[4]f32 = null;
        var triangles_uniforms_bound = false;
        var i: usize = 0;
        while (i < self.draw_calls.items.len) {
            const dc = self.draw_calls.items[i];

            if (applied_scissor == null or !std.mem.eql(f32, &applied_scissor.?, &dc.rect_clip)) {
                self.applyScissor(render_pass, dc.rect_clip);
                applied_scissor = dc.rect_clip;
            }

            if (dc.mode == .triangles) {
                if (!triangles_uniforms_bound) {
                    // triangles 组共享一份 uniforms（颜色走 per-vertex）
                    const uniforms = PathUniforms{
                        .viewport_size = .{ self.viewport_width, self.viewport_height },
                        .scale_factor = self.scale_factor,
                        .draw_mode = @intFromEnum(DrawMode.triangles),
                        .clip_rect = self.clip_rect,
                        .clip_radius = self.clip_radius,
                        .clip_shape_kind = self.clip_shape_kind,
                    };
                    render_pass.setVertexBytes(1, std.mem.asBytes(&uniforms));
                    render_pass.setFragmentBytes(1, std.mem.asBytes(&uniforms));
                    triangles_uniforms_bound = true;
                }
                var merged_count: u32 = dc.vertex_count;
                var j = i + 1;
                while (j < self.draw_calls.items.len and
                    canCoalesce(dc, merged_count, self.draw_calls.items[j])) : (j += 1)
                {
                    merged_count += self.draw_calls.items[j].vertex_count;
                }
                render_pass.draw(merged_count, 1, dc.vertex_start, 0);
                draws_issued += 1;
                i = j;
            } else {
                const uniforms = PathUniforms{
                    .viewport_size = .{ self.viewport_width, self.viewport_height },
                    .scale_factor = self.scale_factor,
                    .draw_mode = @intFromEnum(dc.mode),
                    .color = dc.color,
                    .rect = dc.rect,
                    .fill_rule = dc.polygon.fill_rule,
                    .point_count = dc.polygon.point_count,
                    .contour_count = dc.polygon.contour_count,
                    .contour_end_points = dc.polygon.contour_end_points,
                    .polygon_points = dc.polygon.points,
                    .clip_rect = self.clip_rect,
                    .clip_radius = self.clip_radius,
                    .clip_shape_kind = self.clip_shape_kind,
                };
                render_pass.setVertexBytes(1, std.mem.asBytes(&uniforms));
                render_pass.setFragmentBytes(1, std.mem.asBytes(&uniforms));
                render_pass.draw(dc.vertex_count, 1, dc.vertex_start, 0);
                draws_issued += 1;
                triangles_uniforms_bound = false;
                i += 1;
            }
        }
        // 还原 pass 的 scissor：path 是唯一用硬件 scissor 做矩形裁剪的管线，其余
        // 管线（sdf/text/icon/image）在 shader 里按 rect_clip 裁、默认 pass scissor
        // 是整个 drawable（或 damage 区）。不还原的话，本次 flush 最后一组 draw 的
        // scissor 会留给之后所有批次，编辑器里一张矢量图之后，视口外的状态栏、
        // 卡片以下的正文整段消失（2026-09-04 下游编辑器 chart block 实测）。
        if (applied_scissor != null) self.applyScissor(render_pass, .{ 0, 0, -1, -1 });
        self.last_flush_draw_count = draws_issued;
        self.frame_call_count += @intCast(self.draw_calls.items.len);
        self.frame_draw_count += draws_issued;
    }

    /// rect_clip: 逻辑像素 x,y,w,h；w/h < 0 = 无裁剪（全 viewport）
    fn applyScissor(self: *PathRenderer, render_pass: *gpu.Backend.RenderPass, rect_clip: [4]f32) void {
        var sx: u32 = 0;
        var sy: u32 = 0;
        var sw = nonNegativeFloatToU32(self.viewport_width * self.scale_factor);
        var sh = nonNegativeFloatToU32(self.viewport_height * self.scale_factor);
        if (rect_clip[2] >= 0 and rect_clip[3] >= 0) {
            const clip_x0 = std.math.clamp(rect_clip[0], 0, self.viewport_width);
            const clip_y0 = std.math.clamp(rect_clip[1], 0, self.viewport_height);
            const clip_x1 = std.math.clamp(rect_clip[0] + rect_clip[2], clip_x0, self.viewport_width);
            const clip_y1 = std.math.clamp(rect_clip[1] + rect_clip[3], clip_y0, self.viewport_height);
            sx = nonNegativeFloatToU32(clip_x0 * self.scale_factor);
            sy = nonNegativeFloatToU32(clip_y0 * self.scale_factor);
            sw = nonNegativeFloatToU32(@max(0, clip_x1 - clip_x0) * self.scale_factor);
            sh = nonNegativeFloatToU32(@max(0, clip_y1 - clip_y0) * self.scale_factor);
        }
        // 部分重绘 pass：与脏区 scissor 取交，脏区外像素绝不能被触碰
        if (self.damage_scissor) |d| {
            const x1 = @min(sx +| sw, d[0] +| d[2]);
            const y1 = @min(sy +| sh, d[1] +| d[3]);
            sx = @max(sx, d[0]);
            sy = @max(sy, d[1]);
            sw = x1 -| sx;
            sh = y1 -| sy;
        }
        render_pass.setScissorRect(sx, sy, sw, sh);
    }

    pub fn clearRetainingCapacity(self: *PathRenderer) void {
        self.vertices.clearRetainingCapacity();
        self.draw_calls.clearRetainingCapacity();
    }

    fn ensureVertexBufferCapacity(self: *PathRenderer, required_size: usize) !void {
        if (required_size == 0) return;
        if (self.vertex_buffer_capacity >= required_size and self.vertex_buffer != null) return;

        var new_capacity: usize = if (self.vertex_buffer_capacity == 0)
            4096
        else
            self.vertex_buffer_capacity;
        while (new_capacity < required_size) {
            new_capacity *= 2;
        }

        const new_buffer = try self.device.createBuffer(self.allocator, .{
            .label = "Zenit.Path.Vertices",
            .size = new_capacity,
            .usage = .{ .vertex = true, .map_write = true },
        });
        // 旧 buffer 可能被本帧早前 pass（setVertexBuffer 已录进当前 command
        // buffer）或仍在飞的前几帧引用，走 retire 延迟 destroy，而不是像
        // 旧实现那样同步释放（与 glyph_atlas evictPage 修过的是同一类 bug）。
        self.retireVertexBuffer();
        self.vertex_buffer = new_buffer;
        self.vertex_buffer_capacity = new_capacity;
    }

    /// 摘除当前 vertex buffer，进入延迟释放队列。容量归零后，下一次
    /// flush 需要时由 ensureVertexBufferCapacity 按实际用量重建。
    fn retireVertexBuffer(self: *PathRenderer) void {
        const buffer = self.vertex_buffer orelse return;
        self.vertex_buffer = null;
        self.vertex_buffer_capacity = 0;
        self.retired_buffers.append(self.allocator, .{
            .buffer = buffer,
            .retired_at_frame = self.shrink_frame,
        }) catch {
            // OOM 兜底：同步 destroy。Metal command buffer 默认 retain 引用
            // 资源，实际不会悬垂；这里只是放弃我们自己的保守时序。
            var b = buffer;
            b.destroy();
        };
    }

    /// 把本帧 buffer 停进当前槽位，切到下一个槽位的 buffer（可能为 null，
    /// 首次 flush 时按需创建）。下一个槽位上次被写是 BUFFER_MAX_FRAMES_IN_FLIGHT
    /// 帧之前，frame_sync 保证 GPU 已消费完。
    fn rotateVertexBufferSlot(self: *PathRenderer) void {
        self.parked_buffers[self.buffer_slot] = self.vertex_buffer;
        self.parked_capacities[self.buffer_slot] = self.vertex_buffer_capacity;
        self.buffer_slot = (self.buffer_slot + 1) % BUFFER_MAX_FRAMES_IN_FLIGHT;
        self.vertex_buffer = self.parked_buffers[self.buffer_slot];
        self.vertex_buffer_capacity = self.parked_capacities[self.buffer_slot];
        self.parked_buffers[self.buffer_slot] = null;
        self.parked_capacities[self.buffer_slot] = 0;
    }

    fn peakSlotCapacity(self: *const PathRenderer) usize {
        var peak = self.vertex_buffer_capacity;
        for (self.parked_capacities) |cap| peak = @max(peak, cap);
        return peak;
    }

    /// 当前 + 停放槽位中存活的顶点 buffer 数（测试/诊断用）。
    fn liveSlotBufferCount(self: *const PathRenderer) usize {
        var n: usize = @intFromBool(self.vertex_buffer != null);
        for (self.parked_buffers) |maybe| n += @intFromBool(maybe != null);
        return n;
    }

    fn retireParkedBuffers(self: *PathRenderer) void {
        for (&self.parked_buffers, &self.parked_capacities) |*maybe, *cap| {
            const buffer = maybe.* orelse continue;
            maybe.* = null;
            cap.* = 0;
            self.retired_buffers.append(self.allocator, .{
                .buffer = buffer,
                .retired_at_frame = self.shrink_frame,
            }) catch {
                var b = buffer;
                b.destroy();
            };
        }
    }

    /// 释放已飞过 in-flight 窗口的 retired buffer。每帧 beginFrame 调用。
    fn drainRetiredBuffers(self: *PathRenderer) void {
        var i: usize = 0;
        while (i < self.retired_buffers.items.len) {
            if (retiredBufferReady(self.retired_buffers.items[i].retired_at_frame, self.shrink_frame)) {
                var entry = self.retired_buffers.swapRemove(i);
                entry.buffer.destroy();
            } else {
                i += 1;
            }
        }
    }
};

// ============================================================================
// Ear-clipping 三角剖分
//
// 简单 O(N²) 实现，适用于路径轮廓（通常 < 200 顶点）。
// - 仅处理无空洞的单多边形
// - 支持 CW 和 CCW 绕向（自动检测符号面积）
//
// 多个 contour 各自独立三角化。
// ============================================================================

const MAX_EARCLIP_POINTS: usize = 4096;
const MAX_EARCLIP_POINT_TESTS: usize = 8_000_000;

/// 相邻 triangles draw call 是否可合并为一次 draw：同 clip 且顶点区间连续。
/// prev_count 是 prev 起点起已累计的合并顶点数。
fn canCoalesce(prev: DrawCall, prev_count: u32, next: DrawCall) bool {
    return prev.mode == .triangles and next.mode == .triangles and
        std.mem.eql(f32, &prev.rect_clip, &next.rect_clip) and
        next.vertex_start == prev.vertex_start + prev_count;
}

/// 将 contour 三角化后追加到 vertices（三角形列表，无索引）。
/// scratch: 调用方持有的临时点表，跨调用复用容量。
fn earclipFill(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(TPoint),
    out: *std.ArrayList(PathVertex),
    contour: Contour,
    off_x: f32,
    off_y: f32,
) !void {
    const n = contour.pointCount();
    if (n < 3 or n > MAX_EARCLIP_POINTS) return;
    if (!std.math.isFinite(off_x) or !std.math.isFinite(off_y)) return;
    const out_start = out.items.len;
    errdefer out.shrinkRetainingCapacity(out_start);

    // 拷贝顶点到可变列表（ear-clip 过程中会移除已处理顶点）
    scratch.clearRetainingCapacity();
    const pts = scratch;
    try pts.ensureTotalCapacity(allocator, n);
    for (0..n) |i| {
        const p = contour.point(i);
        const x = p.x + off_x;
        const y = p.y + off_y;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) {
            pts.clearRetainingCapacity();
            return;
        }
        pts.appendAssumeCapacity(.{ .x = x, .y = y });
    }

    // 确保 CCW 绕向（签名面积 > 0）
    ensureCCW(pts.items);

    // Ear-clipping 主循环
    var remaining: usize = pts.items.len;
    // 去除末尾与起点重合的点（close 路径可能产生）
    while (remaining > 3) {
        const last = pts.items[remaining - 1];
        const first = pts.items[0];
        if (@abs(last.x - first.x) < 1e-3 and @abs(last.y - first.y) < 1e-3) {
            remaining -= 1;
        } else break;
    }

    var point_test_budget = MAX_EARCLIP_POINT_TESTS;
    var completed = true;
    clip_loop: while (remaining > 3) {
        var found_ear = false;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            if (point_test_budget < remaining) {
                completed = false;
                break :clip_loop;
            }
            point_test_budget -= remaining;
            const prev = if (i == 0) remaining - 1 else i - 1;
            const next = (i + 1) % remaining;

            if (isEar(pts.items[0..remaining], prev, i, next)) {
                // 输出三角形（填充，alpha_scale = 1.0）
                try out.append(allocator, .{ .x = pts.items[prev].x, .y = pts.items[prev].y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = pts.items[i].x, .y = pts.items[i].y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = pts.items[next].x, .y = pts.items[next].y, .alpha_scale = 1.0 });

                // 移除 ear 顶点
                _ = pts.orderedRemove(i);
                remaining -= 1;
                found_ear = true;
                break;
            }
        }
        if (!found_ear) {
            // 浮点误差下可能一个"合法" ear 都测不出来（顶点恰落在候选三角形边上等）。
            // 与其提前放弃留下未填充楔形，不如强制剪掉最凸的顶点，对简单多边形
            // 结果仍正确，病态自交输入最多产生轻微过绘。
            var best: ?usize = null;
            var best_cross: f32 = 0;
            var k: usize = 0;
            while (k < remaining) : (k += 1) {
                const prev = if (k == 0) remaining - 1 else k - 1;
                const next = (k + 1) % remaining;
                const a = pts.items[prev];
                const b = pts.items[k];
                const c = pts.items[next];
                const cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
                if (std.math.isFinite(cross) and cross > best_cross) {
                    best_cross = cross;
                    best = k;
                }
            }
            const clip_idx = best orelse {
                completed = false;
                break :clip_loop;
            }; // 无凸顶点（全退化），放弃
            const prev = if (clip_idx == 0) remaining - 1 else clip_idx - 1;
            const next = (clip_idx + 1) % remaining;
            try out.append(allocator, .{ .x = pts.items[prev].x, .y = pts.items[prev].y, .alpha_scale = 1.0 });
            try out.append(allocator, .{ .x = pts.items[clip_idx].x, .y = pts.items[clip_idx].y, .alpha_scale = 1.0 });
            try out.append(allocator, .{ .x = pts.items[next].x, .y = pts.items[next].y, .alpha_scale = 1.0 });
            _ = pts.orderedRemove(clip_idx);
            remaining -= 1;
        }
    }

    if (!completed) {
        out.shrinkRetainingCapacity(out_start);
        return;
    }

    // 最后三角形
    if (remaining >= 3) {
        const cross = triangleCross(pts.items[0], pts.items[1], pts.items[2]);
        if (!std.math.isFinite(cross) or @abs(cross) <= std.math.floatEps(f32)) {
            out.shrinkRetainingCapacity(out_start);
            return;
        }
        try out.append(allocator, .{ .x = pts.items[0].x, .y = pts.items[0].y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = pts.items[1].x, .y = pts.items[1].y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = pts.items[2].x, .y = pts.items[2].y, .alpha_scale = 1.0 });
    }
}

/// 确保顶点列表为 CCW 绕向（若为 CW 则反转）
fn ensureCCW(pts: []TPoint) void {
    var area2: f32 = 0;
    const n = pts.len;
    for (0..n) |i| {
        const j = (i + 1) % n;
        area2 += pts[i].x * pts[j].y;
        area2 -= pts[j].x * pts[i].y;
    }
    if (area2 < 0) {
        // CW -> 反转为 CCW
        std.mem.reverse(TPoint, pts);
    }
}

/// 判断顶点 i 是否为 ear（凸角 + 无其他顶点在三角形内）
fn isEar(pts: []const TPoint, prev: usize, i: usize, next: usize) bool {
    const a = pts[prev];
    const b = pts[i];
    const c = pts[next];

    // 叉积判断是否为凸角（CCW 时叉积 > 0 为凸）
    const cross = triangleCross(a, b, c);
    if (!std.math.isFinite(cross) or cross <= 0) return false;

    // 判断没有其他顶点在三角形 abc 内
    for (pts, 0..) |p, j| {
        if (j == prev or j == i or j == next) continue;
        if (pointInTriangle(p, a, b, c)) return false;
    }
    return true;
}

/// 判断点 p 是否严格在三角形 abc 内部（不含边界）
fn pointInTriangle(p: TPoint, a: TPoint, b: TPoint, c: TPoint) bool {
    const d1 = sign(p, a, b);
    const d2 = sign(p, b, c);
    const d3 = sign(p, c, a);
    // Non-finite predicates must block this candidate ear. Treating NaN as
    // "outside" accepts a corrupt triangle and forwards it to the GPU.
    if (!std.math.isFinite(d1) or !std.math.isFinite(d2) or !std.math.isFinite(d3)) return true;
    // 严格内部：三个符号必须全部同号且非零
    // 使用 <= 排除共线点（在边上的点不算"在三角形内"）
    const all_pos = (d1 > 0) and (d2 > 0) and (d3 > 0);
    const all_neg = (d1 < 0) and (d2 < 0) and (d3 < 0);
    return all_pos or all_neg;
}

fn sign(p1: TPoint, p2: TPoint, p3: TPoint) f32 {
    return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
}

fn triangleCross(a: TPoint, b: TPoint, c: TPoint) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

/// 沿多边形轮廓生成 AA fringe strip。
///
/// 每条轮廓边 [P_i, P_{i+1}] 往外扩 fringe_w 像素（沿外法线方向），
/// 生成 2 个三角形（quad），外侧顶点 alpha_scale=0，内侧=1。
fn buildAaFringe(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(PathVertex),
    contour: Contour,
    off_x: f32,
    off_y: f32,
    scale_factor: f32,
) !void {
    const n = contour.pointCount();
    if (n < 2) return;
    const edge_count: usize = if (contour.closed and n >= 2) n else n - 1;
    if (edge_count == 0) return;

    const fringe_w = 1.0 / @max(scale_factor, 0.001);

    for (0..edge_count) |i| {
        const j = i + 1;
        const pi = contour.point(i);
        const pj = contour.point(if (j < n) j else 0);

        const ax = pi.x + off_x;
        const ay = pi.y + off_y;
        const bx = pj.x + off_x;
        const by = pj.y + off_y;

        const ex = bx - ax;
        const ey = by - ay;
        const len = @sqrt(ex * ex + ey * ey);
        if (len < 1e-6) continue;

        // 外法线（CCW 多边形的右侧为外侧）：旋转 +90° -> (ey, -ex)
        const nx = ey / len * fringe_w;
        const ny = -ex / len * fringe_w;

        const a_inner = PathVertex{ .x = ax, .y = ay, .alpha_scale = 1.0 };
        const b_inner = PathVertex{ .x = bx, .y = by, .alpha_scale = 1.0 };
        const a_outer = PathVertex{ .x = ax + nx, .y = ay + ny, .alpha_scale = 0.0 };
        const b_outer = PathVertex{ .x = bx + nx, .y = by + ny, .alpha_scale = 0.0 };

        try out.append(allocator, a_inner);
        try out.append(allocator, b_inner);
        try out.append(allocator, a_outer);

        try out.append(allocator, b_inner);
        try out.append(allocator, b_outer);
        try out.append(allocator, a_outer);
    }
}

/// 描边展开：单遍 per-edge 发射，每个顶点计算 miter/bevel/round join。
///
/// 对每条边 [Pi, Pj]，先在 Pi 处计算 join 展开点，再发射该边的 quad + fringe。
/// Bevel/round 通过在 join 处发射额外的扇形三角形来连接。
fn buildStrokeExpand(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(PathVertex),
    contour: Contour,
    off_x: f32,
    off_y: f32,
    half_w: f32,
    scale_factor: f32,
    line_join: LineJoin,
) !void {
    const n = contour.pointCount();
    if (n < 2) return;

    const fringe_w = 1.0 / @max(scale_factor, 0.001);
    const is_closed = contour.closed and n >= 3;
    const edge_count: usize = if (is_closed) n else n - 1;
    const MITER_LIMIT: f32 = 4.0;

    // ---- Phase 1: 计算每条边的单位法线 ----
    const edge_norms = try allocator.alloc([2]f32, edge_count);
    defer allocator.free(edge_norms);

    for (0..edge_count) |i| {
        const j = (i + 1) % n;
        const pi = contour.point(i);
        const pj = contour.point(j);
        const ex = pj.x - pi.x;
        const ey = pj.y - pi.y;
        const len = @sqrt(ex * ex + ey * ey);
        if (len < 1e-6) {
            edge_norms[i] = .{ 0, 0 };
        } else {
            edge_norms[i] = .{ ey / len, -ex / len };
        }
    }

    // ---- Phase 2: 对每条边发射三角形 ----
    // 每条边都使用该边自身的法线来展开两侧，保证同一条边的起点和终点
    // 完全平行于原始边。join 的衔接通过额外的三角形扇形来处理。
    for (0..edge_count) |ei| {
        const ej = (ei + 1) % n;
        const pi = contour.point(ei);
        const pj = contour.point(ej);

        const ax = pi.x + off_x;
        const ay = pi.y + off_y;
        const bx = pj.x + off_x;
        const by = pj.y + off_y;

        const nn = edge_norms[ei];
        if (nn[0] == 0 and nn[1] == 0) continue;

        const nx = nn[0];
        const ny = nn[1];

        // 该边的四个实心顶点
        const a0x = ax - nx * half_w;
        const a0y = ay - ny * half_w;
        const a1x = ax + nx * half_w;
        const a1y = ay + ny * half_w;
        const b0x = bx - nx * half_w;
        const b0y = by - ny * half_w;
        const b1x = bx + nx * half_w;
        const b1y = by + ny * half_w;

        // 实心 quad
        try out.append(allocator, .{ .x = a0x, .y = a0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = a1x, .y = a1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = a1x, .y = a1y, .alpha_scale = 1.0 });

        // AA fringe，外侧 (+n)
        const ao_x = ax + nx * (half_w + fringe_w);
        const ao_y = ay + ny * (half_w + fringe_w);
        const bo_x = bx + nx * (half_w + fringe_w);
        const bo_y = by + ny * (half_w + fringe_w);
        try out.append(allocator, .{ .x = a1x, .y = a1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = ao_x, .y = ao_y, .alpha_scale = 0.0 });
        try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
        try out.append(allocator, .{ .x = ao_x, .y = ao_y, .alpha_scale = 0.0 });

        // AA fringe，内侧 (-n)
        const ai_x = ax - nx * (half_w + fringe_w);
        const ai_y = ay - ny * (half_w + fringe_w);
        const bi_x = bx - nx * (half_w + fringe_w);
        const bi_y = by - ny * (half_w + fringe_w);
        try out.append(allocator, .{ .x = a0x, .y = a0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = ai_x, .y = ai_y, .alpha_scale = 0.0 });
        try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
        try out.append(allocator, .{ .x = ai_x, .y = ai_y, .alpha_scale = 0.0 });
        try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });

        // ---- Join at vertex Pj (连接当前边和下一条边) ----
        const next_edge = (ei + 1) % edge_count;
        if (!is_closed and ej == n - 1) continue; // 开放路径末端无 join

        const nn2 = edge_norms[next_edge];
        if (nn2[0] == 0 and nn2[1] == 0) continue;

        // 计算 miter
        const mx = nx + nn2[0];
        const my = ny + nn2[1];
        const mlen_sq = mx * mx + my * my;
        if (mlen_sq < 1e-6) continue; // ~180 度折弯

        const inv_mlen = 1.0 / @sqrt(mlen_sq);
        const mdx = mx * inv_mlen;
        const mdy = my * inv_mlen;
        const cos_half = @max(mdx * nx + mdy * ny, 1e-4);
        const miter_scale = half_w / cos_half;
        const cross = nx * nn2[1] - ny * nn2[0];
        const outside_right = cross >= 0;

        const use_miter = line_join == .miter and miter_scale <= half_w * MITER_LIMIT;

        if (use_miter) {
            // Miter join：仅在外侧发射 miter，避免在凹角/自交路径上双侧外扩。
            const mr_x = bx + mdx * miter_scale;
            const mr_y = by + mdy * miter_scale;
            const ml_x = bx - mdx * miter_scale;
            const ml_y = by - mdy * miter_scale;
            const fringe_scale = @min((half_w + fringe_w) / cos_half, (half_w + fringe_w) * MITER_LIMIT);

            if (outside_right) {
                const fr_x = bx + mdx * fringe_scale;
                const fr_y = by + mdy * fringe_scale;
                const nr_x = bx + nn2[0] * half_w;
                const nr_y = by + nn2[1] * half_w;
                const nfr_x = bx + nn2[0] * (half_w + fringe_w);
                const nfr_y = by + nn2[1] * (half_w + fringe_w);

                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nr_x, .y = nr_y, .alpha_scale = 1.0 });

                try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fr_x, .y = fr_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = mr_x, .y = mr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nr_x, .y = nr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fr_x, .y = fr_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = nr_x, .y = nr_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nfr_x, .y = nfr_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = fr_x, .y = fr_y, .alpha_scale = 0.0 });
            } else {
                const fl_x = bx - mdx * fringe_scale;
                const fl_y = by - mdy * fringe_scale;
                const nl_x = bx - nn2[0] * half_w;
                const nl_y = by - nn2[1] * half_w;
                const nfl_x = bx - nn2[0] * (half_w + fringe_w);
                const nfl_y = by - nn2[1] * (half_w + fringe_w);

                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nl_x, .y = nl_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });

                try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = fl_x, .y = fl_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = ml_x, .y = ml_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fl_x, .y = fl_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = nl_x, .y = nl_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = nl_x, .y = nl_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fl_x, .y = fl_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = nfl_x, .y = nfl_y, .alpha_scale = 0.0 });
            }

            // 内侧连接只做补片，避免双侧都外扩成 spike。
            {
                const inner_scale = @min(miter_scale, half_w * 2.0);
                var mi_x: f32 = undefined;
                var mi_y: f32 = undefined;
                if (outside_right) {
                    mi_x = bx - mdx * inner_scale;
                    mi_y = by - mdy * inner_scale;
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx - nn2[0] * half_w, .y = by - nn2[1] * half_w, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                } else {
                    mi_x = bx + mdx * inner_scale;
                    mi_y = by + mdy * inner_scale;
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx + nn2[0] * half_w, .y = by + nn2[1] * half_w, .alpha_scale = 1.0 });
                }
            }
        } else {
            // Bevel / Round join：用扇形连接两条边端点
            // 确定外侧（发射扇形的一侧）
            // cross > 0 -> 左转 -> 外侧在右 (+n)
            // cross < 0 -> 右转 -> 外侧在左 (-n)

            // 外侧：当前边终点 -> 下条边起点
            var s0_x: f32 = undefined;
            var s0_y: f32 = undefined;
            var s1_x: f32 = undefined;
            var s1_y: f32 = undefined;
            var fs0_x: f32 = undefined;
            var fs0_y: f32 = undefined;
            var fs1_x: f32 = undefined;
            var fs1_y: f32 = undefined;
            if (outside_right) {
                s0_x = b1x;
                s0_y = b1y;
                s1_x = bx + nn2[0] * half_w;
                s1_y = by + nn2[1] * half_w;
                fs0_x = bo_x;
                fs0_y = bo_y;
                fs1_x = bx + nn2[0] * (half_w + fringe_w);
                fs1_y = by + nn2[1] * (half_w + fringe_w);
            } else {
                s0_x = b0x;
                s0_y = b0y;
                s1_x = bx - nn2[0] * half_w;
                s1_y = by - nn2[1] * half_w;
                fs0_x = bi_x;
                fs0_y = bi_y;
                fs1_x = bx - nn2[0] * (half_w + fringe_w);
                fs1_y = by - nn2[1] * (half_w + fringe_w);
            }

            // 内侧：用 miter 补两个三角形连接
            {
                const inner_scale = @min(miter_scale, half_w * 2.0);
                var mi_x: f32 = undefined;
                var mi_y: f32 = undefined;
                if (outside_right) {
                    // 内侧在左 (-n)，miter 方向是 -mdx,-mdy
                    mi_x = bx - mdx * inner_scale;
                    mi_y = by - mdy * inner_scale;
                    // 当前边左端 -> miter -> 下条边左端
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx - nn2[0] * half_w, .y = by - nn2[1] * half_w, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    // 内侧 fringe
                    const fi_scale = @min((half_w + fringe_w) / cos_half, (half_w + fringe_w) * MITER_LIMIT);
                    const fmi_x = bx - mdx * fi_scale;
                    const fmi_y = by - mdy * fi_scale;
                    try out.append(allocator, .{ .x = b0x, .y = b0y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bi_x, .y = bi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    const nl = bx - nn2[0] * half_w;
                    const nly = by - nn2[1] * half_w;
                    const nfl = bx - nn2[0] * (half_w + fringe_w);
                    const nfly = by - nn2[1] * (half_w + fringe_w);
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = nl, .y = nly, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = nl, .y = nly, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = nfl, .y = nfly, .alpha_scale = 0.0 });
                } else {
                    // 内侧在右 (+n)，miter 方向是 +mdx,+mdy
                    mi_x = bx + mdx * inner_scale;
                    mi_y = by + mdy * inner_scale;
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bx + nn2[0] * half_w, .y = by + nn2[1] * half_w, .alpha_scale = 1.0 });
                    // 内侧 fringe
                    const fi_scale = @min((half_w + fringe_w) / cos_half, (half_w + fringe_w) * MITER_LIMIT);
                    const fmi_x = bx + mdx * fi_scale;
                    const fmi_y = by + mdy * fi_scale;
                    try out.append(allocator, .{ .x = b1x, .y = b1y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = bo_x, .y = bo_y, .alpha_scale = 0.0 });
                    const nr = bx + nn2[0] * half_w;
                    const nry = by + nn2[1] * half_w;
                    const nfr = bx + nn2[0] * (half_w + fringe_w);
                    const nfry = by + nn2[1] * (half_w + fringe_w);
                    try out.append(allocator, .{ .x = mi_x, .y = mi_y, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = nr, .y = nry, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = nr, .y = nry, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = nfr, .y = nfry, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = fmi_x, .y = fmi_y, .alpha_scale = 0.0 });
                }
            }

            // 外侧扇形
            const segments: usize = if (line_join == .round) blk: {
                const angle0 = std.math.atan2(s0_y - by, s0_x - bx);
                var angle1 = std.math.atan2(s1_y - by, s1_x - bx);
                if (outside_right) {
                    while (angle1 < angle0) angle1 += std.math.pi * 2.0;
                } else {
                    while (angle1 > angle0) angle1 -= std.math.pi * 2.0;
                }
                const sweep = @abs(angle1 - angle0);
                break :blk roundJoinSegmentCount(sweep);
            } else 1;

            if (segments == 1) {
                // Bevel：直接用精确坐标
                try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = s0_x, .y = s0_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = s1_x, .y = s1_y, .alpha_scale = 1.0 });
                // fringe
                try out.append(allocator, .{ .x = s0_x, .y = s0_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = s1_x, .y = s1_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fs0_x, .y = fs0_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = s1_x, .y = s1_y, .alpha_scale = 1.0 });
                try out.append(allocator, .{ .x = fs1_x, .y = fs1_y, .alpha_scale = 0.0 });
                try out.append(allocator, .{ .x = fs0_x, .y = fs0_y, .alpha_scale = 0.0 });
            } else {
                // Round：圆弧扇形
                const angle0 = std.math.atan2(s0_y - by, s0_x - bx);
                var angle1 = std.math.atan2(s1_y - by, s1_x - bx);
                if (outside_right) {
                    while (angle1 < angle0) angle1 += std.math.pi * 2.0;
                } else {
                    while (angle1 > angle0) angle1 -= std.math.pi * 2.0;
                }
                const step = (angle1 - angle0) / @as(f32, @floatFromInt(segments));
                const fr = half_w + fringe_w;

                var px = s0_x;
                var py = s0_y;
                var fx = fs0_x;
                var fy = fs0_y;

                for (0..segments) |si| {
                    var cx: f32 = undefined;
                    var cy: f32 = undefined;
                    var cfx: f32 = undefined;
                    var cfy: f32 = undefined;
                    if (si == segments - 1) {
                        cx = s1_x;
                        cy = s1_y;
                        cfx = fs1_x;
                        cfy = fs1_y;
                    } else {
                        const a = angle0 + step * @as(f32, @floatFromInt(si + 1));
                        cx = bx + @cos(a) * half_w;
                        cy = by + @sin(a) * half_w;
                        cfx = bx + @cos(a) * fr;
                        cfy = by + @sin(a) * fr;
                    }

                    try out.append(allocator, .{ .x = bx, .y = by, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = px, .y = py, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = cx, .y = cy, .alpha_scale = 1.0 });

                    try out.append(allocator, .{ .x = px, .y = py, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = cx, .y = cy, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = fx, .y = fy, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = cx, .y = cy, .alpha_scale = 1.0 });
                    try out.append(allocator, .{ .x = cfx, .y = cfy, .alpha_scale = 0.0 });
                    try out.append(allocator, .{ .x = fx, .y = fy, .alpha_scale = 0.0 });

                    px = cx;
                    py = cy;
                    fx = cfx;
                    fy = cfy;
                }
            }
        }
    }
}

fn nonNegativeFloatToU32(value: f32) u32 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    const max_u32_f64: f64 = @floatFromInt(std.math.maxInt(u32));
    if (@as(f64, value) >= max_u32_f64) return std.math.maxInt(u32);
    return @intFromFloat(value);
}

fn roundJoinSegmentCount(sweep: f32) usize {
    if (!std.math.isFinite(sweep) or sweep <= 0) return 2;
    const raw = @ceil(sweep / (std.math.pi / 12.0));
    if (!std.math.isFinite(raw) or raw >= 64) return 64;
    return @max(2, @as(usize, @intFromFloat(raw)));
}

// ============================================================================
// 单元测试
// ============================================================================

test "round join and scissor conversions bound non-finite values" {
    try std.testing.expectEqual(@as(usize, 2), roundJoinSegmentCount(std.math.nan(f32)));
    try std.testing.expectEqual(@as(usize, 2), roundJoinSegmentCount(std.math.inf(f32)));
    try std.testing.expectEqual(@as(u32, 0), nonNegativeFloatToU32(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 0), nonNegativeFloatToU32(std.math.inf(f32)));
}

test "earclipFill star polygon produces correct triangle count" {
    const alloc = std.testing.allocator;
    var star_verts = [_]f32{
        60.0, 5.0,  73.0, 43.0,  113.0, 43.0, 82.0, 67.0, 93.0, 107.0,
        60.0, 85.0, 27.0, 107.0, 40.0,  67.0, 5.0,  43.0, 47.0, 43.0,
    };
    const contour = Contour{ .vertices = &star_verts };
    var scratch = std.ArrayList(TPoint){};
    defer scratch.deinit(alloc);
    var out = std.ArrayList(PathVertex){};
    defer out.deinit(alloc);
    try earclipFill(alloc, &scratch, &out, contour, 0, 0);
    try std.testing.expectEqual(@as(usize, 24), out.items.len);
    // scratch 复用：第二次调用结果一致
    out.clearRetainingCapacity();
    try earclipFill(alloc, &scratch, &out, contour, 0, 0);
    try std.testing.expectEqual(@as(usize, 24), out.items.len);
}

test "earclipFill 40-point burst star fills completely" {
    const alloc = std.testing.allocator;
    var verts: [80]f32 = undefined;
    for (0..40) |i| {
        const outer: f32 = 29.44;
        const inner: f32 = 29.44 * 0.72;
        const radius = if (i % 2 == 0) outer else inner;
        const angle = @as(f32, @floatFromInt(i)) * (std.math.pi / 20.0);
        verts[i * 2] = 32.0 + std.math.cos(angle) * radius;
        verts[i * 2 + 1] = 32.0 + std.math.sin(angle) * radius;
    }
    const contour = Contour{ .vertices = &verts, .closed = true };
    var scratch = std.ArrayList(TPoint){};
    defer scratch.deinit(alloc);
    var out = std.ArrayList(PathVertex){};
    defer out.deinit(alloc);
    try earclipFill(alloc, &scratch, &out, contour, 0, 0);
    // n=40 简单多边形完整三角化 = (n-2)*3 = 114 顶点
    try std.testing.expectEqual(@as(usize, 114), out.items.len);
}

test "earclipFill rejects non-finite and oversized contours" {
    const alloc = std.testing.allocator;
    var scratch = std.ArrayList(TPoint){};
    defer scratch.deinit(alloc);
    var out = std.ArrayList(PathVertex){};
    defer out.deinit(alloc);

    var invalid = [_]f32{ 0, 0, std.math.nan(f32), 1, 1, 0 };
    try earclipFill(alloc, &scratch, &out, .{ .vertices = &invalid, .closed = true }, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    var overflowed_predicate = [_]f32{ -std.math.floatMax(f32), 0, std.math.floatMax(f32), 0, 0, std.math.floatMax(f32) };
    try earclipFill(alloc, &scratch, &out, .{ .vertices = &overflowed_predicate, .closed = true }, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    const oversized = try alloc.alloc(f32, (MAX_EARCLIP_POINTS + 1) * 2);
    defer alloc.free(oversized);
    @memset(oversized, 0);
    try earclipFill(alloc, &scratch, &out, .{ .vertices = oversized, .closed = true }, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "canCoalesce merges only contiguous same-clip triangles calls" {
    const clip_a = [4]f32{ 0, 0, -1, -1 };
    const clip_b = [4]f32{ 10, 10, 50, 50 };
    const t0 = DrawCall{ .vertex_start = 0, .vertex_count = 30, .color = .{ 1, 0, 0, 1 }, .rect_clip = clip_a };
    const t1 = DrawCall{ .vertex_start = 30, .vertex_count = 12, .color = .{ 0, 1, 0, 1 }, .rect_clip = clip_a };
    const t2 = DrawCall{ .vertex_start = 42, .vertex_count = 6, .color = .{ 0, 0, 1, 1 }, .rect_clip = clip_b };
    const p0 = DrawCall{ .mode = .polygon_fill, .vertex_start = 42, .vertex_count = 6, .color = .{ 0, 0, 1, 1 }, .rect_clip = clip_a };

    // 不同色但同 clip、区间连续 -> 可合并（颜色 per-vertex）
    try std.testing.expect(canCoalesce(t0, t0.vertex_count, t1));
    // 合并 t0+t1 后与 t2：clip 不同 -> 不可合并
    try std.testing.expect(!canCoalesce(t0, t0.vertex_count + t1.vertex_count, t2));
    // polygon_fill 永不参与合并
    try std.testing.expect(!canCoalesce(t0, t0.vertex_count + t1.vertex_count, p0));
    // 区间不连续 -> 不可合并
    try std.testing.expect(!canCoalesce(t0, t0.vertex_count, t2));
}

test "buildStrokeExpand open contour does not add implicit closing edge" {
    const alloc = std.testing.allocator;
    var open_verts = [_]f32{
        0.0,  0.0,
        10.0, 10.0,
        20.0, 0.0,
    };
    var closed_verts = open_verts;

    const open_contour = Contour{ .vertices = &open_verts, .closed = false };
    const closed_contour = Contour{ .vertices = &closed_verts, .closed = true };

    var open_out = std.ArrayList(PathVertex){};
    defer open_out.deinit(alloc);
    try buildStrokeExpand(alloc, &open_out, open_contour, 0, 0, 2.0, 1.0, .miter);

    var closed_out = std.ArrayList(PathVertex){};
    defer closed_out.deinit(alloc);
    try buildStrokeExpand(alloc, &closed_out, closed_contour, 0, 0, 2.0, 1.0, .miter);

    try std.testing.expect(open_out.items.len > 0);
    try std.testing.expect(closed_out.items.len > open_out.items.len);
}

test "buildStrokeExpand miter join stays near bevel bounds for star contour" {
    const alloc = std.testing.allocator;
    var star_verts = [_]f32{
        60.0, 5.0,  73.0, 43.0,  113.0, 43.0, 82.0, 67.0, 93.0, 107.0,
        60.0, 83.0, 27.0, 107.0, 38.0,  67.0, 7.0,  43.0, 47.0, 43.0,
    };
    const contour = Contour{ .vertices = &star_verts, .closed = true };

    var bevel_out = std.ArrayList(PathVertex){};
    defer bevel_out.deinit(alloc);
    try buildStrokeExpand(alloc, &bevel_out, contour, 0, 0, 3.0, 1.0, .bevel);

    var miter_out = std.ArrayList(PathVertex){};
    defer miter_out.deinit(alloc);
    try buildStrokeExpand(alloc, &miter_out, contour, 0, 0, 3.0, 1.0, .miter);

    try std.testing.expect(bevel_out.items.len > 0);
    try std.testing.expect(miter_out.items.len > 0);

    const bevel_bounds = vertexBounds(bevel_out.items);
    const miter_bounds = vertexBounds(miter_out.items);
    const allowance: f32 = 14.0;

    try std.testing.expect(miter_bounds.min_x >= bevel_bounds.min_x - allowance);
    try std.testing.expect(miter_bounds.max_x <= bevel_bounds.max_x + allowance);
    try std.testing.expect(miter_bounds.min_y >= bevel_bounds.min_y - allowance);
    try std.testing.expect(miter_bounds.max_y <= bevel_bounds.max_y + allowance);
}

const VertexBounds = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
};

fn vertexBounds(vertices: []const PathVertex) VertexBounds {
    std.debug.assert(vertices.len > 0);
    var bounds = VertexBounds{
        .min_x = vertices[0].x,
        .min_y = vertices[0].y,
        .max_x = vertices[0].x,
        .max_y = vertices[0].y,
    };
    for (vertices[1..]) |v| {
        bounds.min_x = @min(bounds.min_x, v.x);
        bounds.min_y = @min(bounds.min_y, v.y);
        bounds.max_x = @max(bounds.max_x, v.x);
        bounds.max_y = @max(bounds.max_y, v.y);
    }
    return bounds;
}

test "Phase C mesh cache: store → 平移回填命中 → TTL 逐出" {
    const alloc = std.testing.allocator;
    var r = PathRenderer{
        .allocator = alloc,
        .device = undefined,
        .pipeline = undefined,
        .vertex_buffer = null,
        .vertex_buffer_capacity = 0,
        .buffer_write_offset = 0,
        .vertices = .{},
        .draw_calls = .{},
        .viewport_width = 800,
        .viewport_height = 600,
        .scale_factor = 1.0,
        .current_rect_clip = .{ 0, 0, -1, -1 },
    };
    defer {
        var it = r.mesh_cache.valueIterator();
        while (it.next()) |e| alloc.free(e.verts);
        r.mesh_cache.deinit(alloc);
        r.vertices.deinit(alloc);
        r.draw_calls.deinit(alloc);
    }

    // 未命中
    try std.testing.expect(!try r.appendCachedMesh(42, .{ 1, 1, 1, 1 }, 0, 0));

    // 模拟 addFillPath 产出的顶点（世界坐标 = local + offset(10,20)）
    try r.vertices.append(alloc, .{ .x = 10, .y = 20, .alpha_scale = 1 });
    try r.vertices.append(alloc, .{ .x = 15, .y = 26, .alpha_scale = 1 });
    try r.vertices.append(alloc, .{ .x = 12, .y = 30, .alpha_scale = 0 });
    r.storeMesh(42, 0, 3, 10, 20);
    try std.testing.expectEqual(@as(usize, 3), r.mesh_cache_vertex_total);

    // 命中：新 offset (100,200) 平移回填 + 补色 + 记 draw call
    r.vertices.clearRetainingCapacity();
    r.draw_calls.clearRetainingCapacity();
    try std.testing.expect(try r.appendCachedMesh(42, .{ 0.5, 0, 0, 1 }, 100, 200));
    try std.testing.expectEqual(@as(usize, 3), r.vertices.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 100), r.vertices.items[0].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), r.vertices.items[0].y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 105), r.vertices.items[1].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.vertices.items[2].alpha_scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.vertices.items[0].color[0], 0.001);
    try std.testing.expectEqual(@as(usize, 1), r.draw_calls.items.len);
    try std.testing.expectEqual(DrawMode.triangles, r.draw_calls.items[0].mode);

    // TTL 逐出：last_used=0，360 帧（120 的倍数触发 sweep）时 0+240 < 360 -> 移除
    r.setFrame(360);
    try std.testing.expect(!try r.appendCachedMesh(42, .{ 1, 1, 1, 1 }, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), r.mesh_cache_vertex_total);
}

test "vertex buffer 收缩判据：连续低水位在精确帧边界触发" {
    var p = ShrinkPolicy{};
    const cap: usize = 8 * 1024 * 1024;

    // 高水位（用量 ≥ cap/4）：永不触发
    var i: u32 = 0;
    while (i < SHRINK_FRAMES * 2) : (i += 1) {
        try std.testing.expect(!p.noteFrame(cap / 2, cap));
    }

    // 低水位 SHRINK_FRAMES-1 帧：未达阈值不收缩
    i = 0;
    while (i < SHRINK_FRAMES - 1) : (i += 1) {
        try std.testing.expect(!p.noteFrame(cap / SHRINK_DIVISOR - 1, cap));
    }
    // 恰第 SHRINK_FRAMES 帧：收缩
    try std.testing.expect(p.noteFrame(cap / SHRINK_DIVISOR - 1, cap));
    // 触发后计数清零：下一帧不会再次收缩
    try std.testing.expect(!p.noteFrame(0, cap));
}

test "vertex buffer 收缩判据：中途一帧回到高水位即重置计数（防帧间抖动）" {
    var p = ShrinkPolicy{};
    const cap: usize = 8 * 1024 * 1024;

    var i: u32 = 0;
    while (i < SHRINK_FRAMES - 1) : (i += 1) _ = p.noteFrame(0, cap);
    // 差一帧到阈值时插入一帧高用量（恰好 cap/4 也算高）-> 重置
    try std.testing.expect(!p.noteFrame(cap / SHRINK_DIVISOR, cap));
    // 重新数满整个窗口才触发
    i = 0;
    while (i < SHRINK_FRAMES - 1) : (i += 1) {
        try std.testing.expect(!p.noteFrame(0, cap));
    }
    try std.testing.expect(p.noteFrame(0, cap));
}

test "vertex buffer 收缩判据：小容量不收缩" {
    var p = ShrinkPolicy{};
    var i: u32 = 0;
    while (i < SHRINK_FRAMES * 2) : (i += 1) {
        try std.testing.expect(!p.noteFrame(0, SHRINK_MIN_CAPACITY));
    }
}

test "retired buffer 延迟释放：满 in-flight 窗口才可 destroy" {
    // retire 于帧 10：帧 10/11/12 仍可能在飞，帧 13 起才安全
    try std.testing.expect(!retiredBufferReady(10, 10));
    try std.testing.expect(!retiredBufferReady(10, 11));
    try std.testing.expect(!retiredBufferReady(10, 12));
    try std.testing.expect(retiredBufferReady(10, 13));
}

test "vertex buffer 高水位收缩：beginFrame 序列驱动 retire → 延迟 destroy" {
    // 需要真实 createBuffer/destroy 与 stats 计数，只在 Null 后端下可确定性
    // 运行（Metal 下要真设备，那是 test-metal 的领域）。
    // 实跑：`zig build test-render -Dgpu-backend=null`。
    // SKIP-REASON: 只在 -Dgpu-backend=null 下有意义（Metal 后端跑的是真实管线）
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var device = gpu.Backend.Device{};
    var r = PathRenderer{
        .allocator = alloc,
        .device = &device,
        .pipeline = undefined,
        .vertex_buffer = null,
        .vertex_buffer_capacity = 0,
        .buffer_write_offset = 0,
        .vertices = .{},
        .draw_calls = .{},
        .viewport_width = 800,
        .viewport_height = 600,
        .scale_factor = 1.0,
    };
    defer {
        if (r.vertex_buffer) |*b| b.destroy();
        for (&r.parked_buffers) |*m| if (m.*) |*b| b.destroy();
        for (r.retired_buffers.items) |*e| e.buffer.destroy();
        r.retired_buffers.deinit(alloc);
        r.vertices.deinit(alloc);
        r.draw_calls.deinit(alloc);
    }

    const destroyed_base = gpu.Backend.stats.buffers_destroyed;

    // 增长到高水位（> SHRINK_MIN_CAPACITY）
    try r.ensureVertexBufferCapacity(2 * 1024 * 1024);
    try std.testing.expect(r.vertex_buffer_capacity >= 2 * 1024 * 1024);

    // 扩容路径也走延迟释放：再扩一档，旧 buffer 进 retired 队列而非同步 destroy
    try r.ensureVertexBufferCapacity(4 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1), r.retired_buffers.items.len);
    try std.testing.expectEqual(destroyed_base, gpu.Backend.stats.buffers_destroyed);

    // 连续低水位 SHRINK_FRAMES-1 帧：不收缩
    var i: u32 = 0;
    while (i < SHRINK_FRAMES - 1) : (i += 1) {
        r.buffer_write_offset = 1024; // 模拟上一帧仅用 1KiB « cap/4
        r.beginFrame(800, 600, 1.0);
        // 峰值 buffer 仍停在某个槽位里（轮转不丢 buffer）
        try std.testing.expectEqual(@as(usize, 1), r.liveSlotBufferCount());
    }
    // 前面扩容 retire 的旧 buffer 此时早已 drain（3 帧后）
    try std.testing.expectEqual(destroyed_base + 1, gpu.Backend.stats.buffers_destroyed);

    // 恰第 SHRINK_FRAMES 帧：收缩发生，buffer 摘除进 retired，容量归零
    r.buffer_write_offset = 1024;
    r.beginFrame(800, 600, 1.0);
    try std.testing.expectEqual(@as(usize, 0), r.liveSlotBufferCount());
    try std.testing.expectEqual(@as(usize, 0), r.peakSlotCapacity());
    try std.testing.expectEqual(@as(usize, 1), r.retired_buffers.items.len);
    // 收缩帧当帧不 destroy（可能仍在飞）
    try std.testing.expectEqual(destroyed_base + 1, gpu.Backend.stats.buffers_destroyed);

    // 再过 2 帧仍不 destroy（in-flight 窗口 = 3）
    r.beginFrame(800, 600, 1.0);
    r.beginFrame(800, 600, 1.0);
    try std.testing.expectEqual(destroyed_base + 1, gpu.Backend.stats.buffers_destroyed);

    // 第 3 帧：drain 真正释放
    r.beginFrame(800, 600, 1.0);
    try std.testing.expectEqual(destroyed_base + 2, gpu.Backend.stats.buffers_destroyed);
    try std.testing.expectEqual(@as(usize, 0), r.retired_buffers.items.len);
}

test "顶点 buffer 按帧槽位轮转：在飞窗口内相邻帧不共用同一块 buffer" {
    // 回归：单 buffer + 每帧 write offset 归零时，第 N+1 帧 memcpy 覆写 GPU
    // 尚在消费的第 N 帧顶点。
    // SKIP-REASON: 需要 Null 后端确定性 createBuffer（Metal 下是 test-metal 的领域）
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var device = gpu.Backend.Device{};
    var r = PathRenderer{
        .allocator = alloc,
        .device = &device,
        .pipeline = undefined,
        .vertex_buffer = null,
        .vertex_buffer_capacity = 0,
        .buffer_write_offset = 0,
        .vertices = .{},
        .draw_calls = .{},
        .viewport_width = 800,
        .viewport_height = 600,
        .scale_factor = 1.0,
    };
    defer {
        if (r.vertex_buffer) |*b| b.destroy();
        for (&r.parked_buffers) |*m| if (m.*) |*b| b.destroy();
        for (r.retired_buffers.items) |*e| e.buffer.destroy();
        r.retired_buffers.deinit(alloc);
        r.vertices.deinit(alloc);
        r.draw_calls.deinit(alloc);
    }

    var seen: [BUFFER_MAX_FRAMES_IN_FLIGHT + 2]?[*]u8 = undefined;
    for (&seen) |*slot| {
        r.beginFrame(800, 600, 1.0);
        try r.ensureVertexBufferCapacity(4096);
        slot.* = (try r.vertex_buffer.?.getMappedRange(0, 1)).ptr;
        r.buffer_write_offset = 4096;
    }
    // 任意 BUFFER_MAX_FRAMES_IN_FLIGHT 个连续帧的 buffer 两两不同
    for (0..seen.len) |i| {
        for (i + 1..@min(seen.len, i + BUFFER_MAX_FRAMES_IN_FLIGHT)) |j| {
            try std.testing.expect(seen[i] != seen[j]);
        }
    }
    // 轮满一圈后复用（不是每帧新建）
    try std.testing.expectEqual(seen[0], seen[BUFFER_MAX_FRAMES_IN_FLIGHT]);
}
