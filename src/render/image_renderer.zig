/// Image Renderer - GPU image rendering pipeline. Based on image.metal:
/// texture sampling + SDF rounded clip, tinting and opacity, texture caching.
/// Usage: (1) init() create renderer, (2) loadTexture() load from RGBA pixel data,
/// (3) addImage() add instance, (4) render() submit to GPU
const std = @import("std");
const idle_storage = @import("idle_storage.zig");
const SlotBuffer = @import("slot_buffer.zig").SlotBuffer;
const gpu = @import("gpu");
const shape_clip_pair = @import("shape_clip_pair.zig");
const corner_radii_mod = @import("zenit_corner_radii");

const MAX_CLIP_POLYGON_POINTS = 32;
const MAX_CLIP_POLYGON_CONTOURS = 8;

extern fn macos_load_image_from_url(url: [*:0]const u8, out_width: *u32, out_height: *u32) ?[*]u8;
extern fn macos_free_image_data(data: [*]u8) void;

/// Image Shader source (single source of truth)
const image_shader_source: []const u8 = @import("shader_sources.zig").image;

/// Uniforms struct, same as SDF renderer
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

/// Image instance data, aligned with image.metal ImageInstanceData
pub const ImageInstance = extern struct {
    rect: [4]f32, // x, y, w, h (logical pixels)
    uv_rect: [4]f32, // u0, v0, u1, v1 (texture coordinates)
    tint_color: [4]f32, // RGBA float (1,1,1,1 = no tinting)
    transform_linear: [4]f32 = .{ 1, 0, 0, 1 }, // a, b, c, d
    /// Rounded mask radii TL, TR, BR, BL (logical pixels): an image's corner radius, or a rounded
    /// layer's (possibly per-corner) clip when compositing an offscreen surface.
    corner_radii: [4]f32,
    transform_translation: [2]f32 = .{ 0, 0 }, // tx, ty
    opacity: f32,
    source_premultiplied: f32 = 0,
    /// xy = max sampled UV (0 = unclamped); zw padding. MSL aligns the trailing float4 to 16 bytes.
    sampling: [4]f32 = .{ 0, 0, 0, 0 },
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 }, // x, y, w, h (logical pixels); negative size = disabled

    comptime {
        if (@offsetOf(ImageInstance, "corner_radii") != 64) {
            @compileError("ImageInstance.corner_radii must start at byte 64 to match image.metal");
        }
        if (@offsetOf(ImageInstance, "rect_clip") != 112) {
            @compileError("ImageInstance.rect_clip must start at byte 112 to match image.metal");
        }
        if (@sizeOf(ImageInstance) != 128) {
            @compileError("ImageInstance must be 128 bytes to match image.metal");
        }
    }
};

/// Texture ID
pub const TextureId = u32;

/// Texture slot
const TextureSlot = struct {
    kind: TextureKind,
    binding: gpu.Backend.TextureBinding,
    owned_texture: ?gpu.Backend.Texture = null,
    width: u32,
    height: u32,
    mip_level_count: u32,
    atlas_page_index: u16 = 0,
    sampling_max: [2]f32 = .{ 0, 0 },
    uv_rect: [4]f32 = .{ 0, 0, 1, 1 },
};

const AtlasPage = struct {
    texture: gpu.Backend.Texture,
    size: u32 = ATLAS_PAGE_SIZE,
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

/// Max instance count
/// Starting per-slot instance capacity; slots grow with the frame's demand.
const MIN_INSTANCE_BYTES = @sizeOf(ImageInstance) * 128;
const MAX_UNIFORM_UPDATES = 256;
// D3D12 CBV addresses require 256-byte alignment. Append aligned slots so
// normal shared draws can bind the retained frame buffer without snapshots.
// D3D12 CBV addresses need 256-byte alignment; Metal buffer offsets need 16.
const UNIFORM_STRIDE = std.mem.alignForward(usize, @sizeOf(Uniforms), if (gpu.is_direct3d) 256 else 16);

/// Triple buffering constant
const BUFFER_COUNT = 3;

/// Max texture count
const MAX_TEXTURES = 4096;
/// Atlas pages grow with demand: the first page is small so an app showing a
/// few icons (or only the 1x1 fallback) does not pay for a 16 MiB page; each
/// further page doubles up to the maximum.
const ATLAS_PAGE_SIZE = 2048;
const ATLAS_MIN_PAGE_SIZE = 512;
const ATLAS_FIRST_PAGE_MIN = 128;
const ATLAS_MAX_TEXTURE_SIZE = 256;
const ATLAS_GUTTER = 1;

/// White constant
const WHITE: [4]f32 = .{ 1, 1, 1, 1 };

const TextureKind = enum {
    standalone,
    stream,
    atlas_region,
    external,
};

/// Metal Image Renderer. Accumulated counters per pipeline (process-level
/// monotonic; frame value = delta from previous frame). N images/screenshots ~=
/// N draw calls + N texture binds; these verify batch/atlas optimizations work.
pub var image_draw_calls: u64 = 0;
pub var image_instances_drawn: u64 = 0;
pub var image_texture_binds: u64 = 0;

/// Texture memory snapshot (app-side LRU eviction budget avoids shadow drift).
pub const TextureMemoryStats = struct {
    /// Standalone texture count (excludes atlas pages)
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

/// External (borrowed) bindings use a dedicated slot range [EXTERNAL_SLOT_BASE, MAX_TEXTURES).
/// Offscreen/retained/glass composite register+unregister tens of times per frame, and each
/// unregister bumps the generation; slots at MAX_GENERATION retire forever. At 20-30x/frame
/// @120Hz that exhausts all 4096*2^19 registrations in ~1 week, after which every offscreen
/// layer hits TooManyTextures (overlay vanishes). So external slots are isolated from
/// persistent ones and their generation wraps.
/// ABA argument: generation invalidates old *cached* handles in display lists. External
/// lifetime spans one encoding (register->draw->flush->unregister) and is never cached, so a
/// wraparound collision needs the same slot after 2^19 more register/unregisters while still
/// in use, which exceeds single-frame registrations. Persistent handles (held long-term by the
/// app) never wrap; slot isolation keeps them out of wrapping slots, else a new external
/// registration after wraparound would revive a persistent handle.
const EXTERNAL_SLOT_COUNT = 256;
const EXTERNAL_SLOT_BASE = MAX_TEXTURES - EXTERNAL_SLOT_COUNT;

/// GPU image storage, independent of a window's pipeline and frame buffers.
/// All access is on the render thread. Its owner must drain GPU work before
/// destruction. A shared instance must outlive all borrowing ImageRenderers.
pub const ImageTextureStore = struct {
    const Slot = struct { texture: ?TextureSlot = null, generation: u32 = 0 };

    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    namespace: u32,
    /// Persistent slots [0, EXTERNAL_SLOT_BASE), grown on demand (a full
    /// inline table kept ~430 KiB resident per renderer).
    persistent: std.ArrayList(Slot) = .empty,
    /// External (frame-borrowed) slots [EXTERNAL_SLOT_BASE, MAX_TEXTURES).
    external: [EXTERNAL_SLOT_COUNT]Slot = @splat(.{}),
    texture_count: u32 = 0,
    atlas_pages: std.ArrayList(AtlasPage) = .empty,
    /// Admission limit for resident storage; configure before the first upload.
    memory_budget_bytes: u64 = std.math.maxInt(u64),

    pub fn init(self: *ImageTextureStore, allocator: std.mem.Allocator, device: *gpu.Backend.Device, shared: bool) void {
        self.allocator = allocator;
        self.device = device;
        self.namespace = if (shared) SHARED_TEXTURE_BIT else 0;
        self.persistent = .empty;
        self.external = @splat(.{});
        self.texture_count = 0;
        self.atlas_pages = .empty;
        self.memory_budget_bytes = std.math.maxInt(u64);
    }

    pub fn deinit(self: *ImageTextureStore) void {
        for ([_][]Slot{ self.persistent.items, &self.external }) |slots| for (slots) |*entry| {
            if (entry.texture) |slot| if (slot.owned_texture) |owned| {
                var texture = owned;
                texture.destroy();
            };
            entry.texture = null;
        };
        self.persistent.deinit(self.allocator);
        self.persistent = .empty;
        for (self.atlas_pages.items) |*page| page.texture.destroy();
        self.atlas_pages.deinit(self.allocator);
        self.atlas_pages = .empty;
    }

    /// Slot storage for an index handed out by this store.
    fn slotPtr(self: *ImageTextureStore, index: u32) *Slot {
        return if (index >= EXTERNAL_SLOT_BASE) &self.external[index - EXTERNAL_SLOT_BASE] else &self.persistent.items[index];
    }

    /// Any index (a stale or foreign handle may name a slot never grown).
    fn slotAt(self: *const ImageTextureStore, index: u32) Slot {
        if (index >= EXTERNAL_SLOT_BASE) return self.external[index - EXTERNAL_SLOT_BASE];
        return if (index < self.persistent.items.len) self.persistent.items[index] else .{};
    }

    fn handle(self: *const ImageTextureStore, index: u32) TextureId {
        return self.namespace | (self.slotAt(index).generation << SLOT_BITS) | index;
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
                    for (self.persistent.items) |*entry| if (entry.texture) |*other| {
                        if (other.kind == .atlas_region and other.atlas_page_index == self.atlas_pages.items.len)
                            other.atlas_page_index = @intCast(removed);
                    };
                }
            }
        }
        const entry = self.slotPtr(index);
        entry.texture = null;
        if (index >= EXTERNAL_SLOT_BASE) {
            // External-only slot: generation wraps (ABA argument in EXTERNAL_SLOT_BASE).
            entry.generation = if (entry.generation >= MAX_GENERATION) 0 else entry.generation + 1;
        } else {
            entry.generation += 1; // exhausted persistent slots are never reused
        }
    }

    /// Load texture from RGBA pixel data. Return texture ID.
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
            const next = atlasPageSizeFor(self.atlas_pages.items.len, width, height);
            additional = @as(u64, next) * next * 4;
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

        // Create RGBA8 sRGB texture (with mipmap)
        var texture = try self.device.createTexture(self.allocator, .{
            .label = "Zenit.Image.Standalone",
            .size = .{ .width = width, .height = height },
            .mip_level_count = mip_level_count,
            .format = .rgba8_unorm,
            .usage = .{ .copy_dst = true, .texture_binding = true },
            .memory = .host_upload,
            // Upload-only: no CPU path reads image pixels back.
            .host_access = .write_only,
        });
        errdefer texture.destroy();

        // Upload base level
        try texture.writeRegion(0, 0, 0, width, height, rgba_data, width * 4);

        // Generate and upload mip levels (CPU box filter)
        if (mip_level_count > 1) {
            try self.uploadMipChain(&texture, width, height, rgba_data, mip_level_count);
        }

        const id = try self.allocateTextureSlot();
        self.slotPtr(id).texture = TextureSlot{
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
        self.slotPtr(id).texture = TextureSlot{
            .kind = .atlas_region,
            .binding = page.texture.binding(),
            .width = width,
            .height = height,
            .mip_level_count = 1,
            .atlas_page_index = @intCast(allocation.page_index),
            .uv_rect = atlasRegionUvRect(allocation.x, allocation.y, width, height, page.size),
        };
        self.texture_count = @max(self.texture_count, id + 1);
        return self.handle(id);
    }

    /// Register a borrowed backend texture binding. The caller owns its lifetime.
    /// Used to sample an offscreen render target through the image pipeline.
    /// Handle valid only this encoding (must unregister same frame), see EXTERNAL_SLOT_BASE.
    pub fn registerTextureBinding(self: *ImageTextureStore, binding: gpu.Backend.TextureBinding, width: u32, height: u32) !TextureId {
        const id = try self.allocateExternalSlot();
        self.slotPtr(id).texture = TextureSlot{
            .kind = .external,
            .binding = binding,
            .width = width,
            .height = height,
            .mip_level_count = 1,
        };
        // texture_count covers only persistent range (memory stats);
        // external slots not included.
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
            .format = .rgba8_unorm,
            .usage = .{ .copy_dst = true, .texture_binding = true },
            .memory = .host_upload,
            // Upload-only: no CPU path reads image pixels back.
            .host_access = .write_only,
        });
        errdefer texture.destroy();
        self.slotPtr(index).texture = .{ .kind = .stream, .binding = texture.binding(), .owned_texture = texture, .width = width, .height = height, .mip_level_count = 1 };
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
        for (self.persistent.items[0..self.texture_count]) |entry| {
            const slot = entry.texture orelse continue;
            stats.slots_used += 1;
            // atlas slots share page texture; page memory accounted below
            // per-page to avoid duplication.
            if (slot.kind == .atlas_region) continue;
            stats.texture_count += 1;
            stats.estimated_bytes +|= textureByteLength(slot.width, slot.height, slot.mip_level_count);
        }
        for (self.atlas_pages.items) |page| stats.estimated_bytes +|= @as(u64, page.size) * page.size * 4;
        return stats;
    }

    fn resolveTextureSlot(self: *const ImageTextureStore, id: TextureId) ?TextureSlot {
        if (id & SHARED_TEXTURE_BIT != self.namespace) return null;
        const index = id & SLOT_MASK;
        const entry = self.slotAt(index);
        if (entry.generation > MAX_GENERATION or self.handle(index) != id) return null;
        return entry.texture;
    }

    /// Persistent texture slots ([0, EXTERNAL_SLOT_BASE));
    /// slots with exhausted generation are skipped.
    fn allocateTextureSlot(self: *ImageTextureStore) !u32 {
        for (self.persistent.items, 0..) |entry, index| {
            if (entry.texture == null and entry.generation <= MAX_GENERATION) return @intCast(index);
        }
        if (self.persistent.items.len >= EXTERNAL_SLOT_BASE) return error.TooManyTextures;
        try self.persistent.append(self.allocator, .{});
        return @intCast(self.persistent.items.len - 1);
    }

    /// external (frame-borrowed) slots: [EXTERNAL_SLOT_BASE, MAX_TEXTURES);
    /// generation wraps.
    fn allocateExternalSlot(self: *ImageTextureStore) !u32 {
        for (self.external, EXTERNAL_SLOT_BASE..) |entry, index| {
            if (entry.texture == null) return @intCast(index);
        }
        return error.TooManyTextures;
    }

    fn allocateAtlasRegion(self: *ImageTextureStore, width: u32, height: u32) !AtlasAllocation {
        for (self.atlas_pages.items, 0..) |*page, i| {
            if (allocAtlasOnPage(page, width, height)) |pos| {
                return .{ .page_index = i, .x = pos[0], .y = pos[1] };
            }
        }

        const size = atlasPageSizeFor(self.atlas_pages.items.len, width, height);
        var texture = try self.createAtlasTexture(self.atlas_pages.items.len, size);
        errdefer texture.destroy();
        try self.atlas_pages.append(self.allocator, .{ .texture = texture, .size = size });
        const page = &self.atlas_pages.items[self.atlas_pages.items.len - 1];
        const pos = allocAtlasOnPage(page, width, height) orelse return error.AtlasAllocationFailed;
        return .{ .page_index = self.atlas_pages.items.len - 1, .x = pos[0], .y = pos[1] };
    }

    fn createAtlasTexture(self: *ImageTextureStore, page_index: usize, size: u32) !gpu.Backend.Texture {
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "Zenit.Image.Atlas[{d}]", .{page_index});
        return self.device.createTexture(self.allocator, .{
            .label = label,
            .size = .{ .width = size, .height = size },
            .format = .rgba8_unorm,
            .usage = .{ .copy_dst = true, .texture_binding = true },
            .memory = .host_upload,
            // Upload-only: no CPU path reads image pixels back.
            .host_access = .write_only,
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
    // Owned by texture_store, released with all other renderer textures.
    solid_fallback_texture: ?TextureId = null,
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    pipeline: gpu.Backend.RenderPipeline,
    unmasked_pipeline: ?gpu.Backend.RenderPipeline = null,
    /// Triple-buffered uniform buffers must rotate per-frame like instance
    /// buffers. Previously single buffer resetting uniform_write_offset per frame:
    /// with 3 frames in flight, frame N+1 overwrites N's viewport/clip/scale still
    /// unconsumed, causing random flicker/wrong clips.
    uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    uniform_write_offset: usize = 0,
    /// Single-frame uniform slot overflow count (diagnostic)
    uniform_overflow_count: u64 = 0,
    /// Triple-buffered instance storage sized by demand (see SlotBuffer).
    instance_buffers: SlotBuffer(BUFFER_COUNT) = .init("Zenit.Image.InstanceBuffer", MIN_INSTANCE_BYTES),
    current_buffer: usize = 0,

    /// Overflowed uniform buffer (one per frame slot, retained). Same as text_renderer: batches are
    /// not dropped when slots are exhausted (otherwise instances stay dirty and the next batch
    /// overflows the old ones, leaving the rest invisible). Grown on demand, retained across
    /// frames.
    uniform_overflow: SlotBuffer(BUFFER_COUNT) = .init("Zenit.Image.OverflowUniforms", UNIFORM_STRIDE * 64),
    uniform_overflow_used: usize = 0,
    sampler: ?gpu.Backend.Sampler,

    // Texture management
    texture_store: ImageTextureStore,
    shared_texture_store: ?*ImageTextureStore = null,

    // Instance grouping (group render by texture ID)
    instances: std.ArrayList(ImageInstance),
    /// Advances whenever the pending instances are dropped (see TextRenderer.pending_generation).
    pending_generation: u64 = 0,
    instance_textures: std.ArrayList(struct { binding: gpu.Backend.TextureBinding, view: gpu.Backend.TextureView }),

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
    /// flush offset: multiple flushes in same frame append,
    /// not overwrite previous draw call data
    buffer_write_offset: usize = 0,

    /// Initialization
    pub fn init(self: *ImageRenderer, allocator: std.mem.Allocator, device: *gpu.Backend.Device) !void {
        self.solid_fallback_texture = null;
        self.unmasked_pipeline = null;
        self.uniform_write_offset = 0;
        self.uniform_overflow_count = 0;
        self.current_buffer = 0;
        self.uniform_overflow = .init("Zenit.Image.OverflowUniforms", UNIFORM_STRIDE * 64);
        self.uniform_overflow_used = 0;
        self.instance_buffers = .init("Zenit.Image.InstanceBuffer", MIN_INSTANCE_BYTES);
        self.shared_texture_store = null;
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

        // Compile shader
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, image_shader_source);
        defer shader.deinit();

        var vertex_func = try shader.getFunction("image_vertex_main");
        defer vertex_func.deinit();
        var fragment_func = try shader.getFunction("image_fragment_main");
        defer fragment_func.deinit();

        // Create pipeline (with alpha blending)
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
        var unmasked_pipeline: ?gpu.Backend.RenderPipeline = null;
        errdefer if (unmasked_pipeline) |*value| value.deinit();
        if (gpu.is_direct3d) {
            var unmasked_fragment = try shader.getFunction("image_unmasked_fragment_main");
            defer unmasked_fragment.deinit();
            unmasked_pipeline = try gpu.Backend.createRenderPipeline(device, .{
                .vertex_function = &vertex_func,
                .fragment_function = &unmasked_fragment,
                .color_attachment_formats = &.{gpu.color_format},
                .blend_state = .{ .source_rgb = .one, .destination_rgb = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha },
            });
        }

        // Uniform buffer (errdefer must be outside loop; inside loop body
        // it dies with iteration scope = dead code; was the bug here once)
        var uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var uniform_created: usize = 0;
        errdefer for (uniform_buffers[0..uniform_created]) |*ub| ub.destroy();
        for (&uniform_buffers) |*ubuf| {
            ubuf.* = try device.createBuffer(allocator, .{
                .label = "Zenit.Image.Uniforms",
                .size = UNIFORM_STRIDE * MAX_UNIFORM_UPDATES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            uniform_created += 1;
        }

        // Create Linear + Mip sampler (reduce flicker when image shrinks)
        const sampler = try device.createSampler(allocator, .{
            .label = "Zenit.Image.LinearMipSampler",
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_filter = .linear,
        });

        std.log.info("[ImageRenderer] Initialized (64-byte image pipeline)", .{});

        self.allocator = allocator;
        self.device = device;
        self.pipeline = pipeline;
        self.unmasked_pipeline = unmasked_pipeline;
        self.uniform_buffers = uniform_buffers;
        self.sampler = sampler;
        self.texture_store.init(allocator, device, false);
        self.instances = .empty;
        self.instance_textures = .empty;
        self.viewport_width = 800;
        self.viewport_height = 600;
        self.scale_factor = 1.0;
    }

    /// Destruction
    /// Per-slot scratch storage is rewritten every frame; see idle_storage.
    pub fn setScratchVolatile(self: *ImageRenderer, make_volatile: bool) void {
        idle_storage.setBuffersVolatile(&self.uniform_buffers, make_volatile);
        self.instance_buffers.setVolatile(make_volatile);
        self.uniform_overflow.setVolatile(make_volatile);
    }

    /// Drop demand-sized scratch so the next frame regrows it to what it
    /// draws. Only while no submitted frame is executing.
    pub fn releaseScratch(self: *ImageRenderer) void {
        self.instance_buffers.release();
        self.uniform_overflow.release();
    }

    pub fn deinit(self: *ImageRenderer) void {
        self.clearInstances();
        self.texture_store.deinit();
        if (self.sampler) |*sampler| sampler.destroy();
        self.instances.deinit(self.allocator);
        self.instance_textures.deinit(self.allocator);
        self.instance_buffers.deinit(self.allocator);
        self.uniform_overflow.deinit(self.allocator);
        for (&self.uniform_buffers) |*ubuf| ubuf.destroy();
        if (self.unmasked_pipeline) |*value| value.deinit();
        self.pipeline.deinit();
        std.log.info("[ImageRenderer] Destroyed", .{});
    }

    pub fn solidFallbackTexture(self: *ImageRenderer) !TextureId {
        if (self.solid_fallback_texture) |id| return id;
        const id = try self.loadTexture(1, 1, &.{ 255, 255, 255, 255 });
        self.solid_fallback_texture = id;
        return id;
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

    /// Clamp borrowed opacity surfaces to their used texel centers on Metal.
    /// Stored in existing instance padding: other backend shader ABIs are unchanged.
    pub fn setTextureSamplingExtent(self: *ImageRenderer, id: TextureId, width: u32, height: u32) void {
        const slot = self.texture_store.resolveTextureSlot(id) orelse return;
        const index = id & SLOT_MASK;
        self.texture_store.slotPtr(index).texture.?.sampling_max = .{
            (@as(f32, @floatFromInt(width)) - 0.5) / @as(f32, @floatFromInt(slot.width)),
            (@as(f32, @floatFromInt(height)) - 0.5) / @as(f32, @floatFromInt(slot.height)),
        };
    }

    pub fn getTextureSize(self: *const ImageRenderer, id: TextureId) ?[2]u32 {
        const slot = self.resolveTextureSlot(id) orelse return null;
        return .{ slot.width, slot.height };
    }

    fn clearInstances(self: *ImageRenderer) void {
        for (self.instance_textures.items) |*entry| entry.view.destroy();
        self.instance_textures.clearRetainingCapacity();
        self.instances.clearRetainingCapacity();
        self.pending_generation +%= 1;
    }

    /// Start new frame
    /// Start a GPU frame.
    pub fn beginFrame(self: *ImageRenderer, width: f32, height: f32, scale: f32) void {
        self.beginFrameFor(width, height, scale, true);
    }

    /// `gpu_frame` false: a CPU patch encode (cpu_flat), which reads only the
    /// CPU-side batches: the triple-buffered GPU slots keep rotating with GPU
    /// frames alone, so a slot an in-flight frame reads is never reused.
    pub fn beginFrameFor(self: *ImageRenderer, width: f32, height: f32, scale: f32, gpu_frame: bool) void {
        self.clearInstances();
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
    }

    /// Update only viewport size (used when offscreen composite
    /// render pass switches)
    pub fn setViewport(self: *ImageRenderer, width: f32, height: f32, scale: f32) void {
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
    }

    /// Second shape clip intersected with the primary one (shape_clip_pair.zig).
    pub fn setPartnerClip(self: *ImageRenderer, clip: shape_clip_pair.Uniform) void {
        self.clip2 = clip;
    }

    pub fn setClipMask(self: *ImageRenderer, shape_kind: u32, rect: ?[4]f32, radii: [4]f32, fill_rule: u32, point_count: u32, contour_count: u32, contour_end_points: [MAX_CLIP_POLYGON_CONTOURS]u8, polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32) void {
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

    pub fn setRectClip(self: *ImageRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
    }

    /// Add image instance
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
            @as([4]f32, @splat(corner_radius)),
            opacity,
            transform,
            false,
        );
    }

    /// Add image instance (custom UV region, for atlas)
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
            @as([4]f32, @splat(corner_radius)),
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
        corner_radii: [4]f32,
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
            corner_radii,
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
        corner_radii: [4]f32,
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
            // The mask is the instance rect (0, 0, w, h): fit the radii to it like every other
            // rounded shape, so an offscreen composite traces the same outline as the direct clip.
            .corner_radii = corner_radii_mod.normalize(corner_radii, w, h),
            .opacity = opacity,
            .source_premultiplied = if (source_premultiplied) 1 else 0,
            .sampling = .{ slot.sampling_max[0], slot.sampling_max[1], 0, 0 },
            .rect_clip = self.current_rect_clip,
        });
        self.instance_textures.appendAssumeCapacity(.{ .binding = slot.binding, .view = slot.binding.createView() });
    }

    fn affineTranslation(x: f32, y: f32) [6]f32 {
        return .{ 1, 0, 0, 1, x, y };
    }

    /// Quad (x, y, w, h) rotated about its centre; the blend composite inverts
    /// this same affine (blend_composite.rectRotateAffine).
    pub fn affineRectRotate(x: f32, y: f32, w: f32, h: f32, rotate: f32) [6]f32 {
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

    /// Render all instances (group by texture, auto-batch overflow-safe,
    /// supports buffer_write_offset accumulation).
    /// Ensure frame slot's overflow uniform buffer fits `slots` Uniforms.
    fn ensureUniformOverflowCapacity(self: *ImageRenderer, slots: usize) !*gpu.Backend.Buffer {
        return (try self.uniform_overflow.ensure(self.allocator, self.device, self.current_buffer, slots * UNIFORM_STRIDE)).buffer;
    }

    pub fn render(self: *ImageRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        if (self.instances.items.len == 0) return;

        // Update uniforms. Overflow can't clamp to last slot -- aliases
        // with this batch/subsequent draw calls, silent corruption. Drop batch
        // and alert instead.
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

        // Set pipeline
        render_pass.setPipeline(if (self.clip_shape_kind == 0 and self.clip2.kind == 0 and self.unmasked_pipeline != null) &self.unmasked_pipeline.? else &self.pipeline);
        // One uniform slot, not the rest of the ring: Direct3D snapshots the bound
        // range per draw (constant buffers over 4 KiB are copied into a new buffer).
        gpu.setVertexBufferRange(render_pass, 0, uniform_buffer, @intCast(uniform_byte_offset), UNIFORM_STRIDE);
        gpu.setFragmentBufferRange(render_pass, 0, uniform_buffer, @intCast(uniform_byte_offset), UNIFORM_STRIDE);

        // Bind sampler
        if (self.sampler) |smp| {
            render_pass.setFragmentSampler(0, &smp);
        }

        const total = self.instances.items.len;
        self.instance_high_water_mark = @max(self.instance_high_water_mark, total);
        image_instances_drawn += total;

        // Batch upload, append to buffer (don't overwrite previous flush)
        var global_offset: usize = 0;
        while (global_offset < total) {
            const chunk_count = total - global_offset;
            const chunk_size = @sizeOf(ImageInstance) * chunk_count;
            const byte_offset = self.buffer_write_offset * @sizeOf(ImageInstance);
            const storage = try self.instance_buffers.ensure(self.allocator, self.device, self.current_buffer, byte_offset + chunk_size);
            const chunk_data = try storage.buffer.getMappedRange(byte_offset, chunk_size);
            @memcpy(chunk_data, std.mem.sliceAsBytes(self.instances.items[global_offset .. global_offset + chunk_count]));
            gpu.setVertexBufferRange(render_pass, 1, storage.buffer, @intCast(byte_offset), @intCast(chunk_size));
            gpu.setFragmentBufferRange(render_pass, 1, storage.buffer, @intCast(byte_offset), @intCast(chunk_size));
            self.buffer_write_offset += chunk_count;

            // Group by texture within current chunk
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

    /// Flush
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

fn atlasPageSizeAfter(existing_pages: usize) u32 {
    const shift: u5 = @intCast(@min(existing_pages, 2));
    return @min(ATLAS_PAGE_SIZE, @as(u32, ATLAS_MIN_PAGE_SIZE) << shift);
}

/// First page: just large enough for the first image (most windows show a
/// few small images; a 512 px page is 1 MiB resident). Later pages grow.
fn atlasPageSizeFor(existing_pages: usize, width: u32, height: u32) u32 {
    if (existing_pages > 0) return atlasPageSizeAfter(existing_pages);
    const needed = @max(width, height) + ATLAS_GUTTER * 2;
    return @max(ATLAS_FIRST_PAGE_MIN, std.math.ceilPowerOfTwo(u32, needed) catch ATLAS_PAGE_SIZE);
}

fn canAtlasTexture(width: u32, height: u32) bool {
    return width <= ATLAS_MAX_TEXTURE_SIZE and height <= ATLAS_MAX_TEXTURE_SIZE;
}

fn allocAtlasOnPage(page: *AtlasPage, width: u32, height: u32) ?[2]u32 {
    const padded_w = width + ATLAS_GUTTER * 2;
    const padded_h = height + ATLAS_GUTTER * 2;
    if (padded_w > page.size or padded_h > page.size) return null;

    if (page.next_x + padded_w > page.size) {
        page.next_x = 0;
        page.next_y += page.shelf_height;
        page.shelf_height = 0;
    }
    if (page.next_y + padded_h > page.size) return null;

    const inner_x = page.next_x + ATLAS_GUTTER;
    const inner_y = page.next_y + ATLAS_GUTTER;
    page.next_x += padded_w;
    page.shelf_height = @max(page.shelf_height, padded_h);
    return .{ inner_x, inner_y };
}

/// The region's exact edges. The gutter around it replicates the edge texels,
/// so linear filtering at the edge equals clamp-to-edge and never reaches a
/// neighbouring region. Insetting half a texel instead maps texel centres onto
/// the quad edges: every image is shrunk by one texel, and a 2x2 texture turns
/// into a full gradient (each quadrant centre must sample its own texel).
fn atlasRegionUvRect(x: u32, y: u32, width: u32, height: u32, page_size: u32) [4]f32 {
    const inv = 1.0 / @as(f32, @floatFromInt(page_size));
    return .{
        @as(f32, @floatFromInt(x)) * inv,
        @as(f32, @floatFromInt(y)) * inv,
        @as(f32, @floatFromInt(x + width)) * inv,
        @as(f32, @floatFromInt(y + height)) * inv,
    };
}

test "image atlas pages start small and double up to the maximum page size" {
    try std.testing.expectEqual(@as(u32, 512), atlasPageSizeAfter(0));
    try std.testing.expectEqual(@as(u32, 1024), atlasPageSizeAfter(1));
    try std.testing.expectEqual(@as(u32, 2048), atlasPageSizeAfter(2));
    try std.testing.expectEqual(@as(u32, 2048), atlasPageSizeAfter(9));
    try std.testing.expectEqual(@as(u32, 128), atlasPageSizeFor(0, 24, 24));
    try std.testing.expectEqual(@as(u32, 512), atlasPageSizeFor(0, 256, 200));
    try std.testing.expectEqual(@as(u32, 1024), atlasPageSizeFor(1, 24, 24));
    // The largest atlas-eligible image plus its gutter fits the first page.
    var small = AtlasPage{ .texture = undefined, .size = ATLAS_MIN_PAGE_SIZE };
    try std.testing.expect(allocAtlasOnPage(&small, ATLAS_MAX_TEXTURE_SIZE, ATLAS_MAX_TEXTURE_SIZE) != null);
}

test "atlasRegionUvRect maps texel centres to their own positions in the quad" {
    // 2x2 region at (8, 4) on a 64 page: the centre of the top-left quadrant
    // (quad fraction 0.25) must land on the first texel's centre.
    const uv = atlasRegionUvRect(8, 4, 2, 2, 64);
    const u = uv[0] + (uv[2] - uv[0]) * 0.25;
    try std.testing.expectApproxEqAbs(@as(f32, 8.5), u * 64, 1e-4);
    const v = uv[1] + (uv[3] - uv[1]) * 0.75;
    try std.testing.expectApproxEqAbs(@as(f32, 5.5), v * 64, 1e-4);
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

            // RGB in linear space box filter, re-encode to sRGB; avoids mip graying
            var c: usize = 0;
            while (c < 3) : (c += 1) {
                const l0 = srgb8ToLinear(src[idx00 + c]);
                const l1 = srgb8ToLinear(src[idx10 + c]);
                const l2 = srgb8ToLinear(src[idx01 + c]);
                const l3 = srgb8ToLinear(src[idx11 + c]);
                const lavg = (l0 + l1 + l2 + l3) * 0.25;
                dst[di + c] = linearToSrgb8(lavg);
            }

            // Alpha averaged in linear scalar space
            const alpha_sum: u32 = @as(u32, src[idx00 + 3]) + @as(u32, src[idx10 + 3]) + @as(u32, src[idx01 + 3]) + @as(u32, src[idx11 + 3]);
            dst[di + 3] = @intCast(alpha_sum / 4);
        }
    }
}

// sRGB <-> linear conversion LUT.
//
// Mip chain generation (uploadMipChain -> downsampleRgbaBox) round-trips every pixel channel;
// std.math.pow per call stalls the main thread (6016x3384 full-screen: ~68M pow calls,
// 1195ms ReleaseFast). Forward input is 256 values -> shared 256-entry LUT, using
// the same single-rounded curve as command encoding. Reverse input is f32, 12-bit quantized approximation; the mip is a
// thumbnail, max error <1/255 is invisible. ReleaseFast full mip chain: pow 1195ms,
// forward-only LUT 88ms (13.6x), both LUTs 21ms (57x).

/// Inverse table quantization bins (12bit). +1 lets v==1.0 index final
/// entry, skips clamp branch.
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
    return @import("color_conversion.zig").srgbByteToLinear(v);
}

inline fn linearToSrgb8(v: f32) u8 {
    const clamped = @max(0.0, @min(v, 1.0));
    const idx: usize = @intFromFloat(@round(clamped * @as(f32, LINEAR_TO_SRGB_STEPS)));
    return LINEAR_TO_SRGB_LUT[idx];
}

/// Whether slot kind owns texture storage (destroyed by this renderer).
/// atlas_region shares atlas page (page freed by atlas_pages rotation,
/// refree -> crash exit regression); external remains caller-owned.
fn slotOwnsTexture(kind: TextureKind) bool {
    return kind == .standalone or kind == .stream;
}

test "deinit texture ownership: standalone and stream own storage (downstream regression)" {
    try std.testing.expect(slotOwnsTexture(.standalone));
    try std.testing.expect(slotOwnsTexture(.stream));
    try std.testing.expect(!slotOwnsTexture(.atlas_region));
    try std.testing.expect(!slotOwnsTexture(.external));
}

test "srgb8ToLinear LUT is bit-exact vs single-rounded f64 reference" {
    // Require every stored bit, using higher precision for intermediate math.
    // This is stable across debug/safe builds without a tolerance escape hatch.
    for (0..256) |i| {
        const v: u8 = @intCast(i);
        const c: f64 = @as(f32, @floatFromInt(v)) / 255.0;
        const reference: f32 = @floatCast(if (c <= 0.04045)
            c / 12.92
        else
            std.math.pow(f64, (c + 0.055) / 1.055, 2.4));
        try std.testing.expectEqual(@as(u32, @bitCast(reference)), @as(u32, @bitCast(srgb8ToLinear(v))));
    }
    // Independent fixed values also pin the branch boundary and midrange.
    for ([_]struct { u8, u32 }{ .{ 0, 0 }, .{ 10, 0x3b46eb61 }, .{ 11, 0x3b5b518e }, .{ 128, 0x3e5d0a8b }, .{ 255, 0x3f800000 } }) |sample|
        try std.testing.expectEqual(sample[1], @as(u32, @bitCast(srgb8ToLinear(sample[0]))));
}

test "linearToSrgb8 LUT stays within 1/255 of reference" {
    // Inverse is 12bit quantized approximate; assert error <= 1 u8 step.
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
    // Endpoints exact: full-black/white through mip downsampling can't drift.
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
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(ImageInstance, "corner_radii"));
    try std.testing.expectEqual(@as(usize, 112), @offsetOf(ImageInstance, "rect_clip"));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(ImageInstance));
}

test "texture namespaces and generations reject released handles and wrong owners" {
    var device: gpu.Backend.Device = undefined;
    const local = try std.testing.allocator.create(ImageTextureStore);
    defer std.testing.allocator.destroy(local);
    local.init(std.testing.allocator, &device, false);
    defer local.deinit();
    const shared = try std.testing.allocator.create(ImageTextureStore);
    defer std.testing.allocator.destroy(shared);
    shared.init(std.testing.allocator, &device, true);
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
    // Persistent slots: generation exhausted, slot retires (old handle
    // might be cached long-term, can't wrap).
    try std.testing.expectEqual(@as(u32, 0), try shared.allocateTextureSlot());
    shared.slotPtr(0).* = .{ .texture = .{ .kind = .standalone, .binding = binding, .width = 1, .height = 1, .mip_level_count = 1 }, .generation = MAX_GENERATION };
    const last_persistent = shared.handle(0);
    shared.unloadTexture(last_persistent);
    try std.testing.expect(shared.getTextureSize(last_persistent) == null);
    try std.testing.expectEqual(@as(u32, 1), try shared.allocateTextureSlot());
}

test "external 绑定槽位 generation 回绕：高频 register/unregister 不会耗尽" {
    // Regression: each unregister bumps generation; slots reaching
    // MAX_GENERATION retire forever. Offscreen/retained/glass composite
    // register ~10s of times/frame -> ~1 week TooManyTextures, all opacity
    // layers vanish.
    var device: gpu.Backend.Device = undefined;
    const store = try std.testing.allocator.create(ImageTextureStore);
    defer std.testing.allocator.destroy(store);
    store.init(std.testing.allocator, &device, false);
    defer store.deinit();
    const binding = gpu.Backend.TextureBinding.testBinding(16, 1, 1);

    // Push all external slots to generation max: old implementation had
    // them all retire.
    for (&store.external) |*entry| entry.generation = MAX_GENERATION;
    var i: usize = 0;
    var prev: TextureId = 0;
    while (i < EXTERNAL_SLOT_COUNT * 2) : (i += 1) {
        const id = try store.registerTextureBinding(binding, 8, 8);
        try std.testing.expect((id & SLOT_MASK) >= EXTERNAL_SLOT_BASE);
        try std.testing.expectEqual([2]u32{ 8, 8 }, store.getTextureSize(id).?);
        store.unregisterTextureBinding(id);
        // After unregister, old handle invalid immediately
        // (wraparound to 0 != old generation)
        try std.testing.expect(store.getTextureSize(id) == null);
        if (i > 0) try std.testing.expect(id != prev);
        prev = id;
    }
    // No persistent slot occupied by external
    try std.testing.expectEqual(@as(usize, 0), store.persistent.items.len);
}

test "image instance preparation failure cannot leave mismatched instance and texture arrays" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const renderer = try std.testing.allocator.create(ImageRenderer);
        defer std.testing.allocator.destroy(renderer);
        renderer.allocator = failing.allocator();
        renderer.shared_texture_store = null;
        renderer.texture_store.init(std.testing.allocator, undefined, false);
        defer renderer.texture_store.deinit();
        renderer.instances = .empty;
        defer renderer.instances.deinit(renderer.allocator);
        renderer.instance_textures = .empty;
        defer renderer.instance_textures.deinit(renderer.allocator);
        renderer.current_rect_clip = .{ 0, 0, -1, -1 };
        const id = try renderer.texture_store.registerTextureBinding(gpu.Backend.TextureBinding.testBinding(16, 1, 1), 1, 1);
        try std.testing.expectError(error.OutOfMemory, renderer.addImage(id, 0, 0, 1, 1, 0, 1));
        try std.testing.expectEqual(@as(usize, 0), renderer.instances.items.len);
        try std.testing.expectEqual(@as(usize, 0), renderer.instance_textures.items.len);
    }
}

test "invalid image dimensions fail before touching the GPU" {
    const store = try std.testing.allocator.create(ImageTextureStore);
    defer std.testing.allocator.destroy(store);
    store.init(std.testing.allocator, undefined, true);
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
