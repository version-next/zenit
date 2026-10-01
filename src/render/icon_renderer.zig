const std = @import("std");
const gpu = @import("gpu");
const svg = @import("svg");
const icon_ir = @import("icon_ir");

const icon_shader_source: []const u8 = @embedFile("shaders/icon.metal");
const MAX_CLIP_POLYGON_POINTS = 32;
const MAX_CLIP_POLYGON_CONTOURS = 8;

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

pub const IconInstance = extern struct {
    rect: [4]f32,
    tint_color: [4]f32,
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    corner_radius: f32,
    opacity: f32,
    rotate: f32 = 0, // 旋转角度（弧度），以中心为 transform origin
    _padding2: f32 = 0,

    comptime {
        if (@sizeOf(IconInstance) != 64) @compileError("IconInstance must be 64 bytes");
    }
};

const TextureSlot = struct {
    texture: gpu.Backend.Texture,
    width: u32,
    height: u32,
    bytes: usize,
};

const IconMaskKey = struct {
    icon_id: u16,
    rep_size: u8,
    physical_width: u32,
    physical_height: u32,
};

const CacheEntry = struct {
    slot_id: u32,
    bytes: usize,
    last_used_frame: u64,
};

pub const Stats = struct {
    cache_hit: u64 = 0,
    cache_miss: u64 = 0,
    rasterize_count: u64 = 0,
    eviction_count: u64 = 0,
};

const MAX_INSTANCES = 4096;
const MAX_CACHE_ENTRIES = 4096;
const MAX_TEXTURES = 4096;
const MAX_UNIFORM_UPDATES = 256;
const BUFFER_COUNT = 3;
const MAX_CACHE_BYTES = 32 * 1024 * 1024;

/// icon 批次诊断计数器（累计）。
///
/// 审查报告 P2 担心"每个图标一个独立 texture + 只合并**连续**相同 texture ->
/// 大型 icon grid 会退化成逐图标 draw"。实测（storybook 全 51 项 e2e）：
/// 累计 draws=274 / instances=370 = **0.74 draws/icon**，即多数相邻图标
/// 已被成功合批，最坏局部是 4 draws/4 icons。
///
/// 之所以**没有**改成"按 texture id 排序后再合批"：icon 走 alpha blending
/// （见下方 blend_state），重排会改变重叠图标的绘制顺序 -> 视觉回归。
/// 真正的解法是 R8 atlas / texture array（让所有图标共用一张纹理，
/// 天然单批次），那是独立的较大改动，留待后续。
/// 这两个计数器用于在做那件事之前/之后量化收益，也便于回归监控。
pub var icon_draw_calls: u64 = 0;
pub var icon_instances_drawn: u64 = 0;

pub const IconRenderer = struct {
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

    textures: [MAX_TEXTURES]?TextureSlot,
    texture_count: u32,
    cache: std.AutoHashMap(IconMaskKey, CacheEntry),
    cache_bytes: usize = 0,
    frame_index: u64 = 0,
    stats: Stats = .{},

    instances: std.ArrayList(IconInstance),
    instance_texture_ids: std.ArrayList(u32),

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
    buffer_write_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !IconRenderer {
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, icon_shader_source);
        defer shader.deinit();

        var vertex_func = try shader.getFunction("icon_vertex_main");
        defer vertex_func.deinit();
        var fragment_func = try shader.getFunction("icon_fragment_main");
        defer fragment_func.deinit();

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

        // errdefer 必须在循环外，循环体内的 errdefer 随迭代作用域失效（死代码）
        var uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var uniform_created: usize = 0;
        errdefer for (uniform_buffers[0..uniform_created]) |*ub| ub.destroy();
        for (&uniform_buffers) |*ubuf| {
            ubuf.* = try device.createBuffer(allocator, .{
                .label = "Zenit.Icon.Uniforms",
                .size = @sizeOf(Uniforms) * MAX_UNIFORM_UPDATES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            uniform_created += 1;
        }

        var instance_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var instance_created: usize = 0;
        errdefer for (instance_buffers[0..instance_created]) |*ib| ib.destroy();
        for (&instance_buffers, 0..) |*buf, i| {
            const label = try std.fmt.allocPrint(allocator, "Zenit.Icon.InstanceBuffer[{d}]", .{i});
            defer allocator.free(label);
            buf.* = try device.createBuffer(allocator, .{
                .label = label,
                .size = @sizeOf(IconInstance) * MAX_INSTANCES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            instance_created += 1;
        }

        const sampler = try device.createSampler(allocator, .{
            .label = "Zenit.Icon.LinearSampler",
            .min_filter = .linear,
            .mag_filter = .linear,
        });

        return .{
            .allocator = allocator,
            .device = device,
            .pipeline = pipeline,
            .uniform_buffers = uniform_buffers,
            .instance_buffers = instance_buffers,
            .sampler = sampler,
            .textures = [_]?TextureSlot{null} ** MAX_TEXTURES,
            .texture_count = 0,
            .cache = std.AutoHashMap(IconMaskKey, CacheEntry).init(allocator),
            .instances = .{},
            .instance_texture_ids = .{},
            .viewport_width = 800,
            .viewport_height = 600,
            .scale_factor = 1.0,
        };
    }

    pub fn deinit(self: *IconRenderer) void {
        var cache_it = self.cache.iterator();
        while (cache_it.next()) |_| {}
        self.cache.deinit();
        for (&self.textures) |*slot| {
            if (slot.*) |owned| {
                var texture = owned.texture;
                texture.destroy();
                slot.* = null;
            }
        }
        if (self.sampler) |*sampler| sampler.destroy();
        self.instances.deinit(self.allocator);
        self.instance_texture_ids.deinit(self.allocator);
        for (&self.instance_buffers) |*buf| buf.destroy();
        for (&self.uniform_buffers) |*ubuf| ubuf.destroy();
        for (&self.overflow_buffers) |*maybe_buf| {
            if (maybe_buf.*) |*buf| buf.destroy();
        }
        for (&self.uniform_overflow_buffers) |*maybe_buf| {
            if (maybe_buf.*) |*buf| buf.destroy();
        }
        self.pipeline.deinit();
    }

    pub fn beginFrame(self: *IconRenderer, width: f32, height: f32, scale: f32) void {
        self.instances.clearRetainingCapacity();
        self.instance_texture_ids.clearRetainingCapacity();
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
        self.frame_index += 1;
    }

    pub fn setViewport(self: *IconRenderer, width: f32, height: f32, scale: f32) void {
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
    }

    pub fn setClipMask(self: *IconRenderer, shape_kind: u32, rect: ?[4]f32, radius: f32, fill_rule: u32, point_count: u32, contour_count: u32, contour_end_points: [MAX_CLIP_POLYGON_CONTOURS]u8, polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32) void {
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

    pub fn setRectClip(self: *IconRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
    }

    pub fn addIcon(
        self: *IconRenderer,
        icon_id: u16,
        rep: icon_ir.Rep,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        tint: [4]f32,
        corner_radius: f32,
        opacity: f32,
        rotate: f32,
    ) !void {
        const physical_width = clampPhysicalSize(w * self.scale_factor);
        const physical_height = clampPhysicalSize(h * self.scale_factor);
        const key = IconMaskKey{
            .icon_id = icon_id,
            .rep_size = rep.size,
            .physical_width = physical_width,
            .physical_height = physical_height,
        };

        const texture_id = try self.acquireMaskTexture(key, rep);
        try self.instances.append(self.allocator, .{
            .rect = .{ x, y, w, h },
            .tint_color = tint,
            .rect_clip = self.current_rect_clip,
            .corner_radius = corner_radius,
            .opacity = opacity,
            .rotate = rotate,
        });
        try self.instance_texture_ids.append(self.allocator, texture_id);
    }

    fn acquireMaskTexture(self: *IconRenderer, key: IconMaskKey, rep: icon_ir.Rep) !u32 {
        if (self.cache.getPtr(key)) |entry| {
            entry.last_used_frame = self.frame_index;
            self.stats.cache_hit += 1;
            return entry.slot_id;
        }

        self.stats.cache_miss += 1;
        self.stats.rasterize_count += 1;
        var mask = try svg.rasterizeIconMask(self.allocator, rep, key.physical_width, key.physical_height, 2);
        defer mask.deinit(self.allocator);

        try self.evictToFit(mask.pixels.len);
        const slot_id = try self.createMaskTexture(mask.width, mask.height, mask.pixels);
        try self.cache.put(key, .{
            .slot_id = slot_id,
            .bytes = mask.pixels.len,
            .last_used_frame = self.frame_index,
        });
        self.cache_bytes += mask.pixels.len;
        return slot_id;
    }

    fn evictToFit(self: *IconRenderer, incoming_bytes: usize) !void {
        while ((self.cache.count() >= MAX_CACHE_ENTRIES or self.cache_bytes + incoming_bytes > MAX_CACHE_BYTES)) {
            var oldest_key: ?IconMaskKey = null;
            var oldest_frame: u64 = std.math.maxInt(u64);
            var it = self.cache.iterator();
            while (it.next()) |entry| {
                // 本帧用过的 mask 不能驱逐：尚未 flush 的实例仍按 slot_id 引用它，
                // 而 createMaskTexture 会立刻复用刚空出的槽位，这些实例就会画成
                // 新图标的 mask（glyph_atlas.forceEvictOldestPage 同款守卫）。
                if (entry.value_ptr.last_used_frame >= self.frame_index) continue;
                if (entry.value_ptr.last_used_frame < oldest_frame) {
                    oldest_frame = entry.value_ptr.last_used_frame;
                    oldest_key = entry.key_ptr.*;
                }
            }
            // 剩下的全是本帧在用的：暂时超预算，下一帧再回收。
            const key = oldest_key orelse return;
            const removed = self.cache.fetchRemove(key) orelse return error.IconCacheExhausted;
            self.destroyTextureSlot(removed.value.slot_id);
            self.cache_bytes -|= removed.value.bytes;
            self.stats.eviction_count += 1;
        }
    }

    fn createMaskTexture(self: *IconRenderer, width: u32, height: u32, alpha_data: []const u8) !u32 {
        var texture = try self.device.createTexture(self.allocator, .{
            .label = "Zenit.Icon.Mask",
            .size = .{ .width = width, .height = height },
            .format = .r8_unorm,
            .usage = .{ .copy_dst = true, .texture_binding = true },
            .memory = .host_upload,
        });
        errdefer texture.destroy();
        try texture.writeRegion(0, 0, 0, width, height, alpha_data, width);

        var id: u32 = self.texture_count;
        for (self.textures[0..self.texture_count], 0..) |slot, i| {
            if (slot == null) {
                id = @intCast(i);
                break;
            }
        }
        if (id == self.texture_count) {
            if (self.texture_count >= MAX_TEXTURES) {
                return error.TooManyTextures;
            }
            self.texture_count += 1;
        }

        self.textures[id] = .{
            .texture = texture,
            .width = width,
            .height = height,
            .bytes = alpha_data.len,
        };
        return id;
    }

    fn destroyTextureSlot(self: *IconRenderer, slot_id: u32) void {
        if (slot_id >= MAX_TEXTURES) return;
        if (self.textures[slot_id]) |slot| {
            var texture = slot.texture;
            texture.destroy();
            self.textures[slot_id] = null;
        }
    }

    /// 保证本帧槽位的溢出 uniform buffer 至少能放下 `slots` 个 Uniforms。
    fn ensureUniformOverflowCapacity(self: *IconRenderer, slots: usize) !*gpu.Backend.Buffer {
        const needed = slots * @sizeOf(Uniforms);
        if (self.uniform_overflow_capacities[self.current_buffer] < needed) {
            var new_capacity = @max(self.uniform_overflow_capacities[self.current_buffer], @sizeOf(Uniforms) * 64);
            while (new_capacity < needed) new_capacity *= 2;
            if (self.uniform_overflow_buffers[self.current_buffer]) |*old| old.destroy();
            self.uniform_overflow_buffers[self.current_buffer] = try self.device.createBuffer(self.allocator, .{
                .label = "Zenit.Icon.OverflowUniforms",
                .size = new_capacity,
                .usage = .{ .vertex = true, .map_write = true },
            });
            self.uniform_overflow_capacities[self.current_buffer] = new_capacity;
        }
        return &self.uniform_overflow_buffers[self.current_buffer].?;
    }

    pub fn render(self: *IconRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        if (self.instances.items.len == 0) return;

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

        render_pass.setPipeline(&self.pipeline);
        render_pass.setVertexBuffer(0, uniform_buffer, @intCast(uniform_byte_offset));
        render_pass.setFragmentBuffer(0, uniform_buffer, @intCast(uniform_byte_offset));
        if (self.sampler) |sampler| {
            render_pass.setFragmentSampler(0, &sampler);
        }

        const total = self.instances.items.len;
        self.instance_high_water_mark = @max(self.instance_high_water_mark, total);
        var global_offset: usize = 0;
        while (global_offset < total) {
            const remaining_total = total - global_offset;
            const remaining_capacity = MAX_INSTANCES - self.buffer_write_offset;
            const chunk_count = if (remaining_capacity == 0)
                remaining_total
            else
                @min(remaining_total, remaining_capacity);
            const chunk_size = @sizeOf(IconInstance) * chunk_count;
            if (remaining_capacity == 0) {
                // 复用本帧槽位的溢出缓冲；容量不足才重建（几何增长，避免抖动）。
                const needed = self.overflow_write_offset + chunk_size;
                if (self.overflow_capacities[self.current_buffer] < needed) {
                    var new_capacity = @max(self.overflow_capacities[self.current_buffer], chunk_size);
                    while (new_capacity < needed) new_capacity *= 2;
                    if (self.overflow_buffers[self.current_buffer]) |*old| old.destroy();
                    self.overflow_buffers[self.current_buffer] = try self.device.createBuffer(self.allocator, .{
                        .label = "Zenit.Icon.OverflowInstanceBuffer",
                        .size = new_capacity,
                        .usage = .{ .vertex = true, .map_write = true },
                    });
                    self.overflow_capacities[self.current_buffer] = new_capacity;
                }
                const overflow_buffer = &self.overflow_buffers[self.current_buffer].?;
                const overflow_data = try overflow_buffer.getMappedRange(self.overflow_write_offset, chunk_size);
                @memcpy(overflow_data, std.mem.sliceAsBytes(self.instances.items[global_offset .. global_offset + chunk_count]));
                render_pass.setVertexBuffer(1, overflow_buffer, @intCast(self.overflow_write_offset));
                render_pass.setFragmentBuffer(1, overflow_buffer, @intCast(self.overflow_write_offset));
                self.overflow_write_offset += chunk_size;
            } else {
                const byte_offset = self.buffer_write_offset * @sizeOf(IconInstance);
                const chunk_data = try self.instance_buffers[self.current_buffer].getMappedRange(byte_offset, chunk_size);
                @memcpy(chunk_data, std.mem.sliceAsBytes(self.instances.items[global_offset .. global_offset + chunk_count]));
                render_pass.setVertexBuffer(1, &self.instance_buffers[self.current_buffer], @intCast(byte_offset));
                render_pass.setFragmentBuffer(1, &self.instance_buffers[self.current_buffer], @intCast(byte_offset));
                self.buffer_write_offset += chunk_count;
            }

            var i: usize = 0;
            while (i < chunk_count) {
                const current_tex_id = self.instance_texture_ids.items[global_offset + i];
                var batch_end = i + 1;
                while (batch_end < chunk_count and self.instance_texture_ids.items[global_offset + batch_end] == current_tex_id) {
                    batch_end += 1;
                }
                if (current_tex_id < MAX_TEXTURES) {
                    if (self.textures[current_tex_id]) |slot| {
                        render_pass.setFragmentTexture(0, &slot.texture);
                    }
                }
                render_pass.draw(6, @intCast(batch_end - i), 0, @intCast(i));
                icon_draw_calls += 1;
                icon_instances_drawn += @as(u64, @intCast(batch_end - i));
                i = batch_end;
            }
            global_offset += chunk_count;
        }
    }

    pub fn flush(self: *IconRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        try self.render(render_pass);
        self.instances.clearRetainingCapacity();
        self.instance_texture_ids.clearRetainingCapacity();
    }
};

fn clampPhysicalSize(value: f32) u32 {
    const finite = if (std.math.isFinite(value)) value else 1;
    const rounded = @round(finite);
    const clamped = std.math.clamp(rounded, 1.0, 4096.0);
    return @intFromFloat(clamped);
}

test "evictToFit 不驱逐本帧在用的 mask（待 flush 实例仍按 slot 引用它）" {
    // SKIP-REASON: 需要 Null 后端确定性 createTexture（Metal 下是 test-metal 的领域）
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;

    var device = gpu.Backend.Device{};
    var r = try IconRenderer.init(std.testing.allocator, &device);
    defer r.deinit();
    r.beginFrame(100, 100, 1);
    r.beginFrame(100, 100, 1);

    const pixels = [_]u8{0xff} ** 16;
    const hot_key = IconMaskKey{ .icon_id = 1, .rep_size = 16, .physical_width = 4, .physical_height = 4 };
    const cold_key = IconMaskKey{ .icon_id = 2, .rep_size = 16, .physical_width = 4, .physical_height = 4 };
    const hot_slot = try r.createMaskTexture(4, 4, &pixels);
    try r.cache.put(hot_key, .{ .slot_id = hot_slot, .bytes = pixels.len, .last_used_frame = r.frame_index });
    const cold_slot = try r.createMaskTexture(4, 4, &pixels);
    try r.cache.put(cold_key, .{ .slot_id = cold_slot, .bytes = pixels.len, .last_used_frame = r.frame_index - 1 });
    r.cache_bytes = 2 * pixels.len;

    // 需要腾出全部预算：冷的被驱逐，热的必须留下（暂时超预算）。
    try r.evictToFit(MAX_CACHE_BYTES);
    try std.testing.expect(r.cache.contains(hot_key));
    try std.testing.expect(!r.cache.contains(cold_key));
    try std.testing.expect(r.textures[hot_slot] != null);
    // 新 mask 不能复用热 mask 的槽位
    const new_slot = try r.createMaskTexture(4, 4, &pixels);
    try std.testing.expect(new_slot != hot_slot);
    r.destroyTextureSlot(new_slot);
}
