const std = @import("std");
const idle_storage = @import("idle_storage.zig");
const SlotBuffer = @import("slot_buffer.zig").SlotBuffer;
const gpu = @import("gpu");
const shape_clip_pair = @import("shape_clip_pair.zig");
const svg = @import("svg");
const icon_ir = @import("icon_ir");

const icon_shader_source: []const u8 = @import("shader_sources.zig").icon;
const MAX_CLIP_POLYGON_POINTS = 32;
const MAX_CLIP_POLYGON_CONTOURS = 8;

const Uniforms = extern struct {
    viewport_size: [2]f32,
    scale_factor: f32,
    clip_shape_kind: u32 = 0,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    /// Keeps the polygon arrays on a 16-byte (cbuffer register) boundary after `clip_radii`.
    _clip_pad: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0)),
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 })),
    /// Second shape clip (shape_clip_pair.zig); zero-sized off Metal.
    clip2: shape_clip_pair.Field = shape_clip_pair.none,
};

// Shared clip header ABI (Metal struct / HLSL cbuffer / GLSL std140): per-corner radii sit on their own
// 16-byte register and the polygon arrays start at the next one.
comptime {
    std.debug.assert(@offsetOf(Uniforms, "clip_rect") == 16);
    std.debug.assert(@offsetOf(Uniforms, "clip_radii") == 32);
    std.debug.assert(@offsetOf(Uniforms, "clip_fill_rule") == 48);
    std.debug.assert(@offsetOf(Uniforms, "clip_polygon_end_points") == 64);
    std.debug.assert(@offsetOf(Uniforms, "clip_polygon_points") == 96);
}

pub const IconInstance = extern struct {
    rect: [4]f32,
    tint_color: [4]f32,
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    corner_radius: f32,
    opacity: f32,
    rotate: f32 = 0, // rotation angle in radians; centered transform origin
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

/// Starting per-slot instance capacity; slots grow with the frame's demand.
const MIN_INSTANCE_BYTES = @sizeOf(IconInstance) * 256;
const MAX_CACHE_ENTRIES = 4096;
const MAX_TEXTURES = 4096;
const MAX_UNIFORM_UPDATES = 256;
// D3D12 CBV addresses require 256-byte alignment. Append aligned slots so
// normal shared draws can bind the retained frame buffer without snapshots.
// D3D12 CBV addresses need 256-byte alignment; Metal buffer offsets need 16.
const UNIFORM_STRIDE = std.mem.alignForward(usize, @sizeOf(Uniforms), if (gpu.is_direct3d) 256 else 16);
const BUFFER_COUNT = 3;
const MAX_CACHE_BYTES = 32 * 1024 * 1024;

/// icon batch diagnostic counters (cumulative). Audit concern: per-icon textures + batch only
/// consecutive same texture -> large grids degrade to per-icon draws. Measured (51 e2e stories):
/// 274 draws / 370 instances = 0.74 draws/icon; adjacent icons mostly merged, worst local case 4
/// draws/4 icons.
/// Not changed to sort-by-texture-id strategy: icon uses alpha blending (see blend_state below);
/// reordering changes draw order of overlapping icons -> visual regression. Proper fix is R8 atlas
/// / texture array (all icons share one texture, naturally single batch); that is independent
/// larger work for later.
/// These counters quantify benefit before/after and enable regression monitoring.
pub var icon_draw_calls: u64 = 0;
pub var icon_instances_drawn: u64 = 0;

pub const IconRenderer = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    pipeline: gpu.Backend.RenderPipeline,
    /// Triple-buffered uniform buffers must rotate per-frame like instance buffers. Was single
    /// buffer with uniform_write_offset reset each frame: with 3 frames in flight, frame N+1
    /// overwrites frame N's viewport/clip/scale still unconsumed by GPU, manifesting as occasional
    /// flicker/incorrect clipping.
    uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    uniform_write_offset: usize = 0,
    /// single-frame uniform slot overflow count (diagnostic)
    uniform_overflow_count: u64 = 0,
    /// Per-slot instance storage sized by demand (see SlotBuffer).
    instance_buffers: SlotBuffer(BUFFER_COUNT) = .init("Zenit.Icon.InstanceBuffer", MIN_INSTANCE_BYTES),
    current_buffer: usize = 0,

    /// uniform buffer overflow (one slot per frame, grows-and-retains). Same as text_renderer: no
    /// longer drops batches on exhaustion (when dropping, instances not cleared, next batch carries
    /// stale instances and fails to draw); instead switch to growable-on-demand,
    /// cross-frame-retained overflow buffer.
    uniform_overflow: SlotBuffer(BUFFER_COUNT) = .init("Zenit.Icon.OverflowUniforms", UNIFORM_STRIDE * 64),
    uniform_overflow_used: usize = 0,
    sampler: ?gpu.Backend.Sampler,

    /// Mask texture slots, grown on demand up to MAX_TEXTURES (an inline
    /// 4096-slot table kept ~220 KiB resident in every renderer).
    textures: std.ArrayList(?TextureSlot) = .empty,
    cache: std.AutoHashMap(IconMaskKey, CacheEntry),
    cache_bytes: usize = 0,
    frame_index: u64 = 0,
    stats: Stats = .{},

    instances: std.ArrayList(IconInstance),
    /// Advances whenever the pending instances are dropped (see TextRenderer.pending_generation).
    pending_generation: u64 = 0,
    instance_texture_ids: std.ArrayList(u32),

    viewport_width: f32,
    viewport_height: f32,
    scale_factor: f32,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    clip_shape_kind: u32 = 0,
    clip2: shape_clip_pair.Uniform = .{},
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0)),
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 })),
    current_rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    instance_high_water_mark: usize = 0,
    buffer_write_offset: usize = 0,

    pub fn init(self: *IconRenderer, allocator: std.mem.Allocator, device: *gpu.Backend.Device) !void {
        self.uniform_write_offset = 0;
        self.uniform_overflow_count = 0;
        self.current_buffer = 0;
        self.uniform_overflow = .init("Zenit.Icon.OverflowUniforms", UNIFORM_STRIDE * 64);
        self.uniform_overflow_used = 0;
        self.instance_buffers = .init("Zenit.Icon.InstanceBuffer", MIN_INSTANCE_BYTES);
        self.cache_bytes = 0;
        self.frame_index = 0;
        self.stats = .{};
        self.clip_rect = .{ 0, 0, 0, 0 };
        self.clip_radii = .{ 0, 0, 0, 0 };
        self.clip_shape_kind = 0;
        self.clip2 = .{};
        self.clip_fill_rule = 0;
        self.clip_point_count = 0;
        self.clip_contour_count = 0;
        @memset(&self.clip_polygon_end_points, 0);
        @memset(&self.clip_polygon_points, .{ 0, 0 });
        self.current_rect_clip = .{ 0, 0, -1, -1 };
        self.instance_high_water_mark = 0;
        self.buffer_write_offset = 0;

        var shader = try gpu.Backend.ShaderModule.initFromSource(device, icon_shader_source);
        defer shader.deinit();

        var vertex_func = try shader.getFunction("icon_vertex_main");
        defer vertex_func.deinit();
        var fragment_func = try shader.getFunction("icon_fragment_main");
        defer fragment_func.deinit();

        var pipeline = try gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex_func,
            .fragment_function = &fragment_func,
            .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
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

        // errdefer must be outside loop; errdefer inside loop body becomes dead code (exits with
        // iteration scope)
        var uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var uniform_created: usize = 0;
        errdefer for (uniform_buffers[0..uniform_created]) |*ub| ub.destroy();
        for (&uniform_buffers) |*ubuf| {
            ubuf.* = try device.createBuffer(allocator, .{
                .label = "Zenit.Icon.Uniforms",
                .size = UNIFORM_STRIDE * MAX_UNIFORM_UPDATES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            uniform_created += 1;
        }

        const sampler = try device.createSampler(allocator, .{
            .label = "Zenit.Icon.LinearSampler",
            .min_filter = .linear,
            .mag_filter = .linear,
        });

        self.allocator = allocator;
        self.device = device;
        self.pipeline = pipeline;
        self.uniform_buffers = uniform_buffers;
        self.sampler = sampler;
        self.textures = .empty;
        self.cache = std.AutoHashMap(IconMaskKey, CacheEntry).init(allocator);
        self.instances = .empty;
        self.instance_texture_ids = .empty;
        self.viewport_width = 800;
        self.viewport_height = 600;
        self.scale_factor = 1.0;
    }

    /// Per-slot scratch storage is rewritten every frame; see idle_storage.
    pub fn setScratchVolatile(self: *IconRenderer, make_volatile: bool) void {
        idle_storage.setBuffersVolatile(&self.uniform_buffers, make_volatile);
        self.instance_buffers.setVolatile(make_volatile);
        self.uniform_overflow.setVolatile(make_volatile);
    }

    /// Drop demand-sized scratch so the next frame regrows it to what it
    /// draws. Only while no submitted frame is executing.
    pub fn releaseScratch(self: *IconRenderer) void {
        self.instance_buffers.release();
        self.uniform_overflow.release();
    }

    pub fn deinit(self: *IconRenderer) void {
        var cache_it = self.cache.iterator();
        while (cache_it.next()) |_| {}
        self.cache.deinit();
        for (self.textures.items) |*slot| {
            if (slot.*) |owned| {
                var texture = owned.texture;
                texture.destroy();
                slot.* = null;
            }
        }
        self.textures.deinit(self.allocator);
        if (self.sampler) |*sampler| sampler.destroy();
        self.instances.deinit(self.allocator);
        self.instance_texture_ids.deinit(self.allocator);
        self.instance_buffers.deinit(self.allocator);
        for (&self.uniform_buffers) |*ubuf| ubuf.destroy();
        self.uniform_overflow.deinit(self.allocator);
        self.pipeline.deinit();
    }

    /// Start a GPU frame.
    pub fn beginFrame(self: *IconRenderer, width: f32, height: f32, scale: f32) void {
        self.beginFrameFor(width, height, scale, true);
    }

    /// `gpu_frame` false: a CPU patch encode (cpu_flat), which reads only the
    /// CPU-side batches: the triple-buffered GPU slots keep rotating with GPU
    /// frames alone, so a slot an in-flight frame reads is never reused.
    pub fn beginFrameFor(self: *IconRenderer, width: f32, height: f32, scale: f32, gpu_frame: bool) void {
        self.instances.clearRetainingCapacity();
        self.pending_generation +%= 1;
        self.instance_texture_ids.clearRetainingCapacity();
        self.buffer_write_offset = 0;
        if (gpu_frame) {
            self.current_buffer = (self.current_buffer + 1) % BUFFER_COUNT;
            self.instance_buffers.beginSlot(self.current_buffer);
            self.uniform_overflow.beginSlot(self.current_buffer);
        }
        self.uniform_write_offset = 0;
        self.uniform_overflow_used = 0;
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
        self.clip_rect = .{ 0, 0, 0, 0 };
        self.clip_radii = .{ 0, 0, 0, 0 };
        self.clip_shape_kind = 0;
        self.clip2 = .{};
        self.clip_fill_rule = 0;
        self.clip_point_count = 0;
        self.clip_contour_count = 0;
        self.clip_polygon_end_points = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0));
        self.clip_polygon_points = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 }));
        self.current_rect_clip = .{ 0, 0, -1, -1 };
        self.frame_index += 1;
    }

    pub fn setViewport(self: *IconRenderer, width: f32, height: f32, scale: f32) void {
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
    }

    /// Second shape clip intersected with the primary one (shape_clip_pair.zig).
    pub fn setPartnerClip(self: *IconRenderer, clip: shape_clip_pair.Uniform) void {
        self.clip2 = clip;
    }

    pub fn setClipMask(self: *IconRenderer, shape_kind: u32, rect: ?[4]f32, radii: [4]f32, fill_rule: u32, point_count: u32, contour_count: u32, contour_end_points: [MAX_CLIP_POLYGON_CONTOURS]u8, polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32) void {
        if (rect) |mask_rect| {
            self.clip_rect = mask_rect;
            self.clip_radii = radii;
            self.clip_shape_kind = shape_kind;
            self.clip_fill_rule = fill_rule;
            self.clip_point_count = point_count;
            self.clip_contour_count = contour_count;
            for (0..MAX_CLIP_POLYGON_CONTOURS) |i| self.clip_polygon_end_points[i] = contour_end_points[i];
            self.clip_polygon_points = polygon_points;
        } else {
            self.clip_rect = .{ 0, 0, 0, 0 };
            self.clip_radii = .{ 0, 0, 0, 0 };
            self.clip_shape_kind = 0;
            self.clip2 = .{};
            self.clip_fill_rule = 0;
            self.clip_point_count = 0;
            self.clip_contour_count = 0;
            self.clip_polygon_end_points = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0));
            self.clip_polygon_points = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 }));
        }
    }

    pub fn setRectClip(self: *IconRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
    }

    /// The mask is rasterized at whole physical pixels. Drawing it at a
    /// fractional device offset (or a fractional device size) makes bilinear
    /// sampling smear every stroke over two pixels: snap the origin to the
    /// device pixel grid and size the quad to the mask, one texel per pixel.
    pub fn snappedIconRect(x: f32, y: f32, physical_width: u32, physical_height: u32, scale: f32) [4]f32 {
        if (!(scale > 0) or !std.math.isFinite(x) or !std.math.isFinite(y)) return .{ x, y, @as(f32, @floatFromInt(physical_width)) / scale, @as(f32, @floatFromInt(physical_height)) / scale };
        return .{
            @round(x * scale) / scale,
            @round(y * scale) / scale,
            @as(f32, @floatFromInt(physical_width)) / scale,
            @as(f32, @floatFromInt(physical_height)) / scale,
        };
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
        snap: bool,
    ) !void {
        const physical_width = clampPhysicalSize(w * self.scale_factor);
        const physical_height = clampPhysicalSize(h * self.scale_factor);
        const quad = if (snap and rotate == 0)
            snappedIconRect(x, y, physical_width, physical_height, self.scale_factor)
        else
            [4]f32{ x, y, w, h };
        const key = IconMaskKey{
            .icon_id = icon_id,
            .rep_size = rep.size,
            .physical_width = physical_width,
            .physical_height = physical_height,
        };

        const texture_id = try self.acquireMaskTexture(key, rep);
        try self.instances.append(self.allocator, .{
            .rect = quad,
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
                // masks used this frame cannot be evicted: unflushed instances still reference by
                // slot_id, and createMaskTexture immediately reuses freed slots -> those instances
                // draw with new icon's mask (guarded like glyph_atlas.forceEvictOldestPage).
                if (entry.value_ptr.last_used_frame >= self.frame_index) continue;
                if (entry.value_ptr.last_used_frame < oldest_frame) {
                    oldest_frame = entry.value_ptr.last_used_frame;
                    oldest_key = entry.key_ptr.*;
                }
            }
            // remainder all in use this frame: temporarily over budget, reclaim next frame
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
            // Stays CPU-cached (read_write): the flat CPU rasterizer reads
            // masks back with getBytes (native/macos/cpu_flat.inc).
            .memory = .host_upload,
        });
        errdefer texture.destroy();
        try texture.writeRegion(0, 0, 0, width, height, alpha_data, width);

        var id: u32 = @intCast(self.textures.items.len);
        for (self.textures.items, 0..) |slot, i| {
            if (slot == null) {
                id = @intCast(i);
                break;
            }
        }
        if (id == self.textures.items.len) {
            if (self.textures.items.len >= MAX_TEXTURES) {
                return error.TooManyTextures;
            }
            try self.textures.append(self.allocator, null);
        }

        self.textures.items[id] = .{
            .texture = texture,
            .width = width,
            .height = height,
            .bytes = alpha_data.len,
        };
        return id;
    }

    fn destroyTextureSlot(self: *IconRenderer, slot_id: u32) void {
        if (slot_id >= self.textures.items.len) return;
        if (self.textures.items[slot_id]) |slot| {
            var texture = slot.texture;
            texture.destroy();
            self.textures.items[slot_id] = null;
        }
    }

    /// ensure frame slot overflow uniform buffer can fit at least `slots` Uniforms
    fn ensureUniformOverflowCapacity(self: *IconRenderer, slots: usize) !*gpu.Backend.Buffer {
        return (try self.uniform_overflow.ensure(self.allocator, self.device, self.current_buffer, slots * UNIFORM_STRIDE)).buffer;
    }

    pub fn render(self: *IconRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        if (self.instances.items.len == 0) return;

        // overflow cannot clamp to last slot; doing so aliases this batch and later draws to memory
        // that gets overwritten next -> silent render corruption. Better to drop this batch and
        // warn.
        const uniform_buffer, const uniform_byte_offset = blk: {
            if (self.uniform_write_offset < MAX_UNIFORM_UPDATES) {
                const slot = self.uniform_write_offset;
                self.uniform_write_offset += 1;
                break :blk .{ &self.uniform_buffers[self.current_buffer], slot * UNIFORM_STRIDE };
            }
            self.uniform_overflow_count += 1;
            const slot = self.uniform_overflow_used;
            const buf = try self.ensureUniformOverflowCapacity(slot + 1);
            self.uniform_overflow_used += 1;
            break :blk .{ buf, slot * UNIFORM_STRIDE };
        };
        const uniforms = Uniforms{
            .viewport_size = .{ self.viewport_width, self.viewport_height },
            .scale_factor = self.scale_factor,
            .clip_shape_kind = self.clip_shape_kind,
            .clip2 = shape_clip_pair.field(self.clip2),
            .clip_rect = self.clip_rect,
            .clip_radii = self.clip_radii,
            .clip_fill_rule = self.clip_fill_rule,
            .clip_point_count = self.clip_point_count,
            .clip_contour_count = self.clip_contour_count,
            .clip_polygon_end_points = self.clip_polygon_end_points,
            .clip_polygon_points = self.clip_polygon_points,
        };
        const uniform_data = try uniform_buffer.getMappedRange(uniform_byte_offset, @sizeOf(Uniforms));
        @memcpy(uniform_data, std.mem.asBytes(&uniforms));

        render_pass.setPipeline(&self.pipeline);
        // One uniform slot, not the rest of the ring: Direct3D snapshots the bound
        // range per draw (constant buffers over 4 KiB are copied into a new buffer).
        gpu.setVertexBufferRange(render_pass, 0, uniform_buffer, @intCast(uniform_byte_offset), UNIFORM_STRIDE);
        gpu.setFragmentBufferRange(render_pass, 0, uniform_buffer, @intCast(uniform_byte_offset), UNIFORM_STRIDE);
        if (self.sampler) |sampler| {
            render_pass.setFragmentSampler(0, &sampler);
        }

        const total = self.instances.items.len;
        self.instance_high_water_mark = @max(self.instance_high_water_mark, total);
        var global_offset: usize = 0;
        while (global_offset < total) {
            const chunk_count = total - global_offset;
            const chunk_size = @sizeOf(IconInstance) * chunk_count;
            const byte_offset = self.buffer_write_offset * @sizeOf(IconInstance);
            const storage = try self.instance_buffers.ensure(self.allocator, self.device, self.current_buffer, byte_offset + chunk_size);
            const chunk_data = try storage.buffer.getMappedRange(byte_offset, chunk_size);
            @memcpy(chunk_data, std.mem.sliceAsBytes(self.instances.items[global_offset .. global_offset + chunk_count]));
            render_pass.setVertexBuffer(1, storage.buffer, @intCast(byte_offset));
            render_pass.setFragmentBuffer(1, storage.buffer, @intCast(byte_offset));
            self.buffer_write_offset += chunk_count;

            var i: usize = 0;
            while (i < chunk_count) {
                const current_tex_id = self.instance_texture_ids.items[global_offset + i];
                var batch_end = i + 1;
                while (batch_end < chunk_count and self.instance_texture_ids.items[global_offset + batch_end] == current_tex_id) {
                    batch_end += 1;
                }
                if (current_tex_id < self.textures.items.len) {
                    if (self.textures.items[current_tex_id]) |slot| {
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
        self.pending_generation +%= 1;
    }
};

fn clampPhysicalSize(value: f32) u32 {
    const finite = if (std.math.isFinite(value)) value else 1;
    const rounded = @round(finite);
    const clamped = std.math.clamp(rounded, 1.0, 4096.0);
    return @intFromFloat(clamped);
}

test "evictToFit 不驱逐本帧在用的 mask（待 flush 实例仍按 slot 引用它）" {
    // SKIP-REASON: needs Null backend deterministic createTexture (Metal domain is test-metal)
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;

    var device = gpu.Backend.Device{};
    const r = try std.testing.allocator.create(IconRenderer);
    defer std.testing.allocator.destroy(r);
    try r.init(std.testing.allocator, &device);
    defer r.deinit();
    r.beginFrame(100, 100, 1);
    r.beginFrame(100, 100, 1);

    const pixels = @as([16]u8, @splat(0xff));
    const hot_key = IconMaskKey{ .icon_id = 1, .rep_size = 16, .physical_width = 4, .physical_height = 4 };
    const cold_key = IconMaskKey{ .icon_id = 2, .rep_size = 16, .physical_width = 4, .physical_height = 4 };
    const hot_slot = try r.createMaskTexture(4, 4, &pixels);
    try r.cache.put(hot_key, .{ .slot_id = hot_slot, .bytes = pixels.len, .last_used_frame = r.frame_index });
    const cold_slot = try r.createMaskTexture(4, 4, &pixels);
    try r.cache.put(cold_key, .{ .slot_id = cold_slot, .bytes = pixels.len, .last_used_frame = r.frame_index - 1 });
    r.cache_bytes = 2 * pixels.len;

    // free up full budget: cold evicted, hot retained (temporarily over budget)
    try r.evictToFit(MAX_CACHE_BYTES);
    try std.testing.expect(r.cache.contains(hot_key));
    try std.testing.expect(!r.cache.contains(cold_key));
    try std.testing.expect(r.textures.items[hot_slot] != null);
    // new mask cannot reuse hot mask's slot
    const new_slot = try r.createMaskTexture(4, 4, &pixels);
    try std.testing.expect(new_slot != hot_slot);
    r.destroyTextureSlot(new_slot);
}

test "snappedIconRect puts the mask on whole device pixels, one texel per pixel" {
    // Glass toolbar at 1x: the share icon sat at x = 352.75, so every stroke
    // was sampled half a pixel off and smeared over two pixels.
    const r1 = IconRenderer.snappedIconRect(352.75, 371.2, 20, 20, 1);
    try std.testing.expectEqual([4]f32{ 353, 371, 20, 20 }, r1);
    // 2x: origin on the half-point grid; size from the physical mask.
    const r2 = IconRenderer.snappedIconRect(10.3, 4.8, 33, 33, 2);
    try std.testing.expectEqual([4]f32{ 10.5, 5, 16.5, 16.5 }, r2);
    // 1.75x: snapped origin times the scale is a whole pixel.
    const r3 = IconRenderer.snappedIconRect(7.1, 3.3, 28, 28, 1.75);
    try std.testing.expectApproxEqAbs(@round(r3[0] * 1.75), r3[0] * 1.75, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 16), r3[2], 1e-4);
}
