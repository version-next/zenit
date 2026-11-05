/// Metal Glyph Atlas - GPU texture atlas management (Multi-Page)
///
/// Manages glyph storage and caching in GPU textures.
/// Uses Shelf Packing for texture space allocation.
/// Multi-page atlas + frame-level GC avoids resetAtlas stalls.
const std = @import("std");
const idle_storage = @import("idle_storage.zig");
const gpu = @import("gpu");
const text = @import("text");
const Font = text.Font;
const GlyphBitmap = text.GlyphBitmap;
const text_trace = @import("trace").text_flicker;

/// Pixel format per page. Gray and color pages share the same pages array and page_index
/// numbering (no "collision": one page_index uniquely identifies a page and its format),
/// but pack independently. allocateInPages only places color glyphs in color pages.
pub const PageFormat = enum(u8) {
    /// R8Unorm, 1 byte/pixel, coverage mask.
    gray,
    /// RGBA8Unorm, RGB channel coverage in monitor pixel order.
    cleartype,
    /// BGRA8Unorm_sRGB, 4 bytes/pixel, premultiplied color (emoji).
    color,

    pub fn bytesPerPixel(self: PageFormat) u32 {
        return switch (self) {
            .gray => 1,
            .color, .cleartype => 4,
        };
    }
};

/// Evicted but delayed-release textures.
///
/// evictPage must not release synchronously: GC runs at beginFrame, but command buffers submitted
/// earlier may still be executing on the GPU and hold references. Epoch-based delayed reclaim:
/// record the retire frame at eviction, release after MAX_FRAMES_IN_FLIGHT frames.
///
/// Why not src/gpu/resource_pool.zig retire(): that pool only manages handles it allocated, while
/// atlas textures are created independently by the backend; integrating would require changing the
/// atlas ownership model. This uses the same epoch semantics as a minimal self-contained version;
/// color pages follow the same path as gray pages.
const RetiredTexture = struct {
    texture: gpu.Backend.Texture,
    retired_at_frame: u64,
};

/// Single-page atlas.
const AtlasPage = struct {
    texture: gpu.Backend.Texture,
    packer: RectPacker,
    last_used_frame: u64,
    format: PageFormat,
};

/// Glyph Atlas manages GPU texture atlas (Multi-Page).
/// Module-level accumulation: glyphs **silently skipped** due to atlas page allocation failure.
/// 0 is healthy. > 0 = character-by-character loss on screen (unfilled positions), typical cause
/// is memory/VRAM pressure on texture creation. See allocateInPages comment.
pub var glyphs_dropped_total: u64 = 0;

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    sampler_nearest: ?gpu.Backend.Sampler,
    sampler_linear: ?gpu.Backend.Sampler,
    pages: [MAX_PAGES]?AtlasPage,
    page_count: u32,
    current_frame: u64,
    /// This frame's count of "cache miss AND actual rasterization".
    frame_insert_count: u32,
    had_transient_failure: bool = false,
    cache: GlyphCache,
    raster_context: ?*anyopaque = null,
    failures: @import("raster_failure_cache.zig").Cache(GlyphKey, 256) = .{},
    /// Incremented after GC drains pages, signals render cache invalidation
    /// (prevent cached commands from referencing released texture pages).
    gc_generation: u32 = 0,
    /// Frame number of last GC cycle execution (see maybeCollect).
    last_gc_frame: u64 = 0,
    /// Textures removed from page table but potentially still referenced by in-flight command
    /// buffers.
    /// See RetiredTexture / drainRetired.
    retired: [MAX_RETIRED]?RetiredTexture = @as([MAX_RETIRED]?RetiredTexture, @splat(null)),

    page_size: u32 = ATLAS_SIZE,

    /// Largest physical page and the fixed UV wire grid. Glyphs too big for a
    /// default page still get a lazily allocated page of this size.
    pub const ATLAS_SIZE: u32 = 4096;
    /// Default physical page on every backend: 4 MiB gray instead of 16 MiB.
    /// Metal's packed UVs encode 2048 texels as even coordinates on the 4096
    /// grid; the other backends carry float UVs normalized by each page's own
    /// width, and no shader assumes a page size.
    pub const SMALL_ATLAS_SIZE: u32 = 2048;

    /// First page of each format at the default page size: a window's glyphs
    /// rarely fill more than a few percent of a 2048 page (300k-line sqlite
    /// editor on Windows: at most 13% of the rows, about half of a 1024 page),
    /// and every window keeps its pages for its lifetime: 1 MiB gray + 4 MiB
    /// ClearType instead of 4 + 16 MiB. A window whose glyphs outgrow it adds
    /// default-size pages as before.
    pub const FIRST_PAGE_SIZE: u32 = 1024;

    /// `ZENIT_GLYPH_ATLAS_4096=1` restores 4096 default pages.
    pub fn selectedPageSize(force_large: ?[]const u8) u32 {
        return if (std.mem.eql(u8, force_large orelse "", "1")) ATLAS_SIZE else SMALL_ATLAS_SIZE;
    }

    pub const MAX_PAGES: u32 = 32;
    /// Pages idle for this many frames before becoming collectable (~30 sec at 60fps).
    pub const EVICT_THRESHOLD: u64 = 1800;
    /// Bytes per page: 4096x4096 R8 = 16 MiB.
    pub const PAGE_BYTES: u64 = @as(u64, ATLAS_SIZE) * @as(u64, ATLAS_SIZE);
    /// Byte budget. Exceeding triggers age-based GC.
    ///
    /// Without a budget, MAX_PAGES=32 * 16 MiB = **512 MiB** could accumulate before eviction
    /// started. EVICT_THRESHOLD alone is not wired to periodic GC.
    /// 128 MiB = 8 pages, plenty for normal UI (full storybook components fit in 1 page).
    pub const BYTE_BUDGET: u64 = 128 * 1024 * 1024;
    /// GC check interval (frames). Avoid scanning page table every frame.
    pub const GC_INTERVAL_FRAMES: u64 = 120;
    /// Matches renderer triple-buffer: at least this many frames after retire before truly release,
    /// ensures in-flight command buffers don't reference freed textures.
    pub const MAX_FRAMES_IN_FLIGHT: u64 = 3;
    /// Retire queue capacity. GC evicts at most MAX_PAGES per cycle, reserve same capacity.
    pub const MAX_RETIRED: u32 = MAX_PAGES;
    const ATLAS_LOG_ENABLED = false;

    /// Initialize GlyphAtlas.
    pub fn resetFrameStats(self: *GlyphAtlas) void {
        self.frame_insert_count = 0;
        self.had_transient_failure = false;
    }

    pub fn invalidateRaster(self: *GlyphAtlas) void {
        // Old pages may still be in flight; invalidate keys, leave retirement to GC.
        self.cache.clearRetainingCapacity();
        self.failures = .{};
        self.gc_generation +%= 1;
    }

    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !GlyphAtlas {
        var buf: [64]u8 = undefined;
        return initWithPageSize(allocator, device, selectedPageSize(@import("zenit_environment").getInto("ZENIT_GLYPH_ATLAS_4096", &buf)));
    }

    /// Preferred size is immutable. Oversized glyphs retain 4096-page fallback.
    pub fn initWithPageSize(allocator: std.mem.Allocator, device: *gpu.Backend.Device, page_size: u32) !GlyphAtlas {
        if (page_size != ATLAS_SIZE and page_size != SMALL_ATLAS_SIZE) return error.UnsupportedAtlasSize;
        // Create sampler, Linear smooths scaling, reduces stroke weight jitter.
        var sampler_linear = device.createSampler(allocator, .{
            .label = "Zenit.Text.GlyphAtlas.Linear",
            .min_filter = .linear,
            .mag_filter = .linear,
            .address_mode_u = .clamp_to_border,
            .address_mode_v = .clamp_to_border,
        }) catch return error.SamplerCreationFailed;

        // Create sampler, Nearest preserves sharpness at 1:1 scale.
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
            .page_size = page_size,
            .sampler_nearest = sampler_nearest,
            .sampler_linear = sampler_linear,
            .pages = @as([MAX_PAGES]?AtlasPage, @splat(null)),
            .page_count = 0,
            .current_frame = 0,
            .frame_insert_count = 0,
            .cache = GlyphCache.init(allocator),
        };
        errdefer self.deinit();

        // Create first page (grayscale, most text uses this; color pages created lazily on-demand).
        try self.addNewPage(.gray, self.newPageSize(.gray, 0, 0));

        if (ATLAS_LOG_ENABLED) {
            std.log.info("[GlyphAtlas] Created multi-page atlas (page 0: {d}x{d})", .{ self.page_size, self.page_size });
        }

        return self;
    }

    /// Destroy.
    pub fn deinit(self: *GlyphAtlas) void {
        self.cache.deinit();
        if (self.sampler_nearest) |*sampler| sampler.destroy();
        if (self.sampler_linear) |*sampler| sampler.destroy();
        for (self.pages[0..self.page_count]) |*maybe_page| {
            if (maybe_page.*) |*page| page.texture.destroy();
        }
        // Window-close path: no new command buffers issued after this. Retire queue must drain
        // fully,
        // otherwise textures not yet in safe period leak with atlas.
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

    /// Add new atlas page. No full zero-fill (avoid 16MB memset cost), RectPacker padding ensures
    /// safety.
    fn addNewPage(self: *GlyphAtlas, format: PageFormat, physical_size: u32) !void {
        // Hit page limit -> evict oldest to make room (subpixel-reduced this branch rarely
        // triggers).
        // Eviction failure (all pages used this frame) must error: continuing to write
        // pages[page_count]
        // overflows, and evicting in-flight page with full retire queue is use-after-free.
        if (self.page_count >= MAX_PAGES) {
            if (!self.forceEvictOldestPage()) return error.AtlasFull;
        }

        const texture = self.device.createTexture(self.allocator, .{
            .label = switch (format) {
                .gray => "Zenit.Text.GlyphAtlas.Gray",
                .cleartype => "Zenit.Text.GlyphAtlas.ClearType",
                .color => "Zenit.Text.GlyphAtlas.Color",
            },
            .size = .{ .width = physical_size, .height = physical_size },
            .format = switch (format) {
                .gray => .r8_unorm,
                .cleartype => .rgba8_unorm,
                // _sRGB: CoreGraphics writes emoji pixels as sRGB-encoded values to layer
                // BGRA8Unorm_sRGB
                // (sRGB decode on output). Sample without _sRGB = treat encoded value as linear,
                // double-encode,
                // lifts midtones (emoji looks desaturated/blown-out; pure blocks barely visible,
                // midtones worst).
                // Grayscale page is coverage not color, must stay R8Unorm.
                .color => gpu.color_format,
            },
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .memory = .host_upload,
            // Gray pages are read on the CPU by the flat CPU rasterizer
            // (native/macos/cpu_flat.inc getBytes); color/ClearType pages are
            // upload-only and may be write-combined.
            .host_access = if (format == .gray) .read_write else .write_only,
        }) catch return error.TextureCreationFailed;

        // Note: no full zero-fill. Under Metal Shared storage, new texture content is undefined,
        // but RectPacker's 2px padding ensures glyphs don't sample each other. For Linear sampling
        // at texture edges, ClampToZero mode provides fallback.

        const page_idx = self.page_count;
        self.pages[page_idx] = AtlasPage{
            .texture = texture,
            .packer = RectPacker.init(physical_size, physical_size),
            .last_used_frame = self.current_frame,
            .format = format,
        };
        self.page_count += 1;

        if (ATLAS_LOG_ENABLED) {
            std.log.info("[GlyphAtlas] New page {d} created (total: {d}, cache: {d})", .{ page_idx, self.page_count, self.cache.count() });
        }
    }

    /// ZENIT_DEBUG_ATLAS_FILL: each page's format, size, used rows and glyph count.
    pub fn debugPrintFill(self: *const GlyphAtlas) void {
        for (self.pages[0..self.page_count], 0..) |maybe_page, index| {
            const page = maybe_page orelse continue;
            const used = page.packer.current_y + page.packer.current_row_height;
            std.debug.print("[atlas-fill] page={d} format={s} size={d} used_rows={d} fill={d:.1}% glyphs={d}\n", .{ index, @tagName(page.format), page.packer.width, used, @as(f64, @floatFromInt(used)) * 100 / @as(f64, @floatFromInt(page.packer.height)), self.cache.count() });
        }
    }

    /// Current byte usage (diagnostics/budget check). Color pages are BGRA8, 4 bytes/pixel,
    /// must weight by format; otherwise GC budget treats 64 MiB color page as 16 MiB,
    /// creating 4x hidden overspend.
    pub fn bytesUsed(self: *const GlyphAtlas) u64 {
        var total: u64 = 0;
        for (self.pages[0..self.page_count]) |maybe_page| {
            const page = maybe_page orelse continue;
            total += @as(u64, page.texture.size.width) * page.texture.size.height * page.format.bytesPerPixel();
        }
        return total;
    }

    /// Periodic age-based GC driven by beginFrame.
    ///
    /// Trigger: GC_INTERVAL_FRAMES elapsed **and** budget exceeded. Target: pages with
    /// last_used_frame > EVICT_THRESHOLD frames ago. Always keep >= 1 page (avoid thrash).
    pub fn maybeCollect(self: *GlyphAtlas) void {
        // Drain retired textures past safe window first. Must run before early return below,
        // else frames without GC never actually release previous cycle's evicted textures (leak).
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

    /// Force evict oldest page (called when page_count hits limit). Only consider pages
    /// **not used this frame**: last_used_frame == current_frame may be referenced by this
    /// frame's encoded draws. Retire queue has in-flight safety, but a full queue degrades to
    /// sync release = use-after-free. All pages used this frame -> return false, caller skips
    /// glyph (safer than crash/corruption).
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

    /// Enqueue texture for delayed release. Queue full (edge case) degrades to sync free,
    /// still not worse than pre-fix, and logged.
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
        // Queue full: sync-free the **oldest** retire entry to make room (closest to safe window).
        // Sync-freeing newly evicted texture (almost certainly still in-flight) is riskiest.
        std.log.warn("[GlyphAtlas] retire queue full, releasing oldest retired texture synchronously", .{});
        var victim = self.retired[oldest_idx].?;
        victim.texture.destroy();
        self.retired[oldest_idx] = .{ .texture = texture, .retired_at_frame = self.current_frame };
    }

    /// Release retired textures past safe window. Driven by maybeCollect (each beginFrame).
    /// Idle storage policy (see idle_storage). Call only when no submitted
    /// command can still sample a page. Going volatile also frees retired
    /// pages early: the GPU has finished with them. If waking finds any page
    /// discarded, every cached region is forgotten and all pages are repacked,
    /// so glyphs re-rasterize on demand and render caches see a new generation.
    pub fn setStorageVolatile(self: *GlyphAtlas, make_volatile: bool) void {
        if (make_volatile) {
            for (&self.retired) |*slot| {
                if (slot.*) |*entry| entry.texture.destroy();
                slot.* = null;
            }
        }
        var lost = false;
        for (self.pages[0..self.page_count]) |*maybe_page| {
            const page = if (maybe_page.*) |*value| value else continue;
            if (idle_storage.setTextureVolatile(&page.texture, make_volatile)) lost = true;
        }
        if (!lost) return;
        self.invalidateRaster();
        for (self.pages[0..self.page_count]) |*maybe_page| {
            const page = if (maybe_page.*) |*value| value else continue;
            page.packer = RectPacker.init(page.texture.size.width, page.texture.size.height);
        }
    }

    fn drainRetired(self: *GlyphAtlas) void {
        for (&self.retired) |*slot| {
            const entry = if (slot.*) |*value| value else continue;
            if (self.current_frame -| entry.retired_at_frame < MAX_FRAMES_IN_FLIGHT) continue;
            entry.texture.destroy();
            slot.* = null;
        }
    }

    /// Evict specified page.
    fn evictPage(self: *GlyphAtlas, page_idx: u32) void {
        const page = self.pages[page_idx] orelse return;

        // Eviction must not allocate: it often runs under memory pressure, and
        // every victim UV must disappear before another page takes this index.
        // HashMap deletion only tombstones; remaining iterator entries stay put.
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.page_index == @as(u8, @intCast(page_idx))) {
                self.cache.removeByPtr(entry.key_ptr);
            }
        }

        // Enqueue texture for delayed release (can't sync release; in-flight command buffer may
        // reference it).
        self.retireTexture(page.texture);

        // Swap last page to this position (compact array).
        const last_idx = self.page_count - 1;
        if (page_idx != last_idx) {
            self.pages[page_idx] = self.pages[last_idx];
            // Update page_index in cache for the swapped page.
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

    /// Physical size of the next page of `format` that must hold a `w`x`h`
    /// glyph: the 4096 fallback for glyphs larger than a default page, the
    /// small first page while the format has none (default 2048 pages only),
    /// else the default page.
    fn newPageSize(self: *const GlyphAtlas, format: PageFormat, w: u32, h: u32) u32 {
        if (w > self.page_size - 2 or h > self.page_size - 2) return ATLAS_SIZE;
        if (self.page_size != SMALL_ATLAS_SIZE) return self.page_size;
        if (w > FIRST_PAGE_SIZE - 2 or h > FIRST_PAGE_SIZE - 2) return self.page_size;
        for (self.pages[0..self.page_count]) |maybe_page| {
            if (maybe_page) |page| if (page.format == format) return self.page_size;
        }
        return FIRST_PAGE_SIZE;
    }

    /// Allocate space in current or new page.
    fn allocateInPages(self: *GlyphAtlas, w: u32, h: u32, format: PageFormat) ?struct { rect: RectPacker.Rect, page_idx: u8 } {
        // Search back for hottest page of **same format**. Gray and color pages mix in one array;
        // checking last page only causes repeated new-page creation when formats alternate.
        var probe = self.page_count;
        while (probe > 0) {
            probe -= 1;
            if (self.pages[probe]) |*page| {
                if (page.format != format) continue;
                if (page.packer.allocate(w, h)) |rect| {
                    page.last_used_frame = self.current_frame;
                    return .{ .rect = rect, .page_idx = @intCast(probe) };
                } else |_| {
                    // This page full; keep only hottest same-format page as allocation target. Full
                    // ->
                    // create new directly, don't backtrack to older pages (matches old behavior).
                    break;
                }
            }
        }

        // No available same-format page -> create new.
        self.addNewPage(format, self.newPageSize(format, w, h)) catch {
            // Texture creation failed (typical: VRAM/memory pressure) -> return null, caller skips
            // glyph.
            //
            // User-visible result: **character-by-character loss** (uncached glyphs not drawn,
            // blanks remain),
            // self-heals when pressure eases -> appears as flicker. ASCII unaffected (resident in
            // page 0).
            // Must log (rate-limited; pressure periods may trigger hundreds per frame).
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

    /// The region getOrInsert would return without rasterizing anything: null
    /// when the glyph is not resident (a later insert may rasterize it, or a
    /// remembered failure may expire). Touches no page or cache state.
    pub fn peek(self: *const GlyphAtlas, font: *Font, glyph_index: u32) ?AtlasRegion {
        return self.cache.get(.{ .font_ptr = @intFromPtr(font), .glyph_index = glyph_index, .scale_q = rasterKey(font) });
    }

    /// The region getOrInsertSubpixel would return, without rasterizing (see peek).
    pub fn peekSubpixel(self: *const GlyphAtlas, font: *Font, glyph_index: u32, subpixel_bin_packed: u32) ?AtlasRegion {
        if (self.cache.get(.{ .font_ptr = @intFromPtr(font), .glyph_index = glyph_index, .subpixel_bin = subpixel_bin_packed, .scale_q = rasterKey(font) })) |region| return region;
        // Color glyphs share the unshifted entry (getOrInsertSubpixel).
        if (font.hasColorGlyphs()) return self.peek(font, glyph_index);
        return null;
    }

    /// Get or insert glyph into atlas.
    pub fn getOrInsert(
        self: *GlyphAtlas,
        font: *Font,
        glyph_index: u32,
    ) !AtlasRegion {
        const key = GlyphKey{
            .font_ptr = @intFromPtr(font),
            .glyph_index = glyph_index,
            .scale_q = rasterKey(font),
        };

        // Check cache.
        if (self.cache.get(key)) |region| {
            // Update page's last_used_frame.
            if (region.page_index < self.page_count) {
                if (self.pages[region.page_index]) |*page| {
                    page.last_used_frame = self.current_frame;
                }
            }
            return region;
        }

        // Cache miss: rasterize and upload.
        if (self.failures.contains(key, self.gc_generation, self.current_frame)) return emptyRegion();
        self.frame_insert_count += 1;
        const bitmap = if (comptime @import("builtin").os.tag == .windows) font.rasterizeGlyphWithContext(glyph_index, 0, 0, self.raster_context) catch |err| {
            self.failures.remember(key, self.gc_generation, self.current_frame, err == error.GlyphTooLarge);
            if (@as(anyerror, err) != error.GlyphTooLarge) self.had_transient_failure = true;
            return emptyRegion();
        } else try font.rasterizeGlyph(glyph_index);
        defer bitmap.deinit(self.allocator);

        // Empty glyph (e.g., space).
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

        if (bitmap.width > ATLAS_SIZE - 2 or bitmap.height > ATLAS_SIZE - 2) {
            self.failures.remember(key, self.gc_generation, self.current_frame, true);
            return emptyRegion();
        }
        const page_format: PageFormat = if (bitmap.is_color) .color else if (bitmap.is_cleartype) .cleartype else .gray;

        // Allocate space (multi-page), null = can't allocate (edge case) -> return empty region.
        const alloc_result = self.allocateInPages(bitmap.width, bitmap.height, page_format) orelse {
            self.failures.remember(key, self.gc_generation, self.current_frame, false);
            self.had_transient_failure = true;
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

        // Upload to GPU.
        try self.uploadToTexture(alloc_result.page_idx, bitmap, alloc_result.rect);

        // Calculate UV coordinates.
        const region = AtlasRegion{
            .uv_min = .{
                @as(f32, @floatFromInt(alloc_result.rect.x)) / @as(f32, @floatFromInt(self.pages[alloc_result.page_idx].?.texture.size.width)),
                @as(f32, @floatFromInt(alloc_result.rect.y)) / @as(f32, @floatFromInt(self.pages[alloc_result.page_idx].?.texture.size.width)),
            },
            .uv_max = .{
                @as(f32, @floatFromInt(alloc_result.rect.x + bitmap.width)) / @as(f32, @floatFromInt(self.pages[alloc_result.page_idx].?.texture.size.width)),
                @as(f32, @floatFromInt(alloc_result.rect.y + bitmap.height)) / @as(f32, @floatFromInt(self.pages[alloc_result.page_idx].?.texture.size.width)),
            },
            .bearing_x = bitmap.bearing_x,
            .bearing_y = bitmap.bearing_y,
            .advance = bitmap.advance,
            .width = bitmap.width,
            .height = bitmap.height,
            .page_index = alloc_result.page_idx,
            .is_color = bitmap.is_color,
            .is_cleartype = bitmap.is_cleartype,
        };

        try self.cache.put(key, region);
        return region;
    }

    /// R6: Get or insert glyph (with subpixel offset).
    pub fn getOrInsertSubpixel(
        self: *GlyphAtlas,
        font: *Font,
        glyph_index: u32,
        subpixel_bin_packed: u32,
    ) !AtlasRegion {
        // **Check cache first, then hasColorGlyphs.**
        //
        // hasColorGlyphs calls CoreText each time (CTFontGetSymbolicTraits + up to 3
        // CTFontCopyTable calls; non-color fonts scan all three). This function is called per glyph
        // per frame during scroll via the emit path, so calling it before the cache lookup wastes a
        // CoreText table lookup on every hit. Non-color fonts hit the cache and never touch
        // CoreText.
        // Color fonts (emoji, few) are cached under the bin=0 key, so they always miss here and
        // fall through.
        const key = GlyphKey{
            .font_ptr = @intFromPtr(font),
            .glyph_index = glyph_index,
            .subpixel_bin = subpixel_bin_packed,
            .scale_q = rasterKey(font),
        };

        if (self.cache.get(key)) |region| {
            // Update page's last_used_frame.
            if (region.page_index < self.page_count) {
                if (self.pages[region.page_index]) |*page| {
                    page.last_used_frame = self.current_frame;
                }
            }
            return region;
        }

        // Subpixel binning meaningless for color glyphs: emoji are bitmaps/layered vectors,
        // no fine strokes needing subpixel phase. Binning just copies one emoji 4x into 4x-VRAM
        // BGRA page. Downgrade to un-offset path (bin=0), share cache entry with getOrInsert.
        if (font.hasColorGlyphs()) {
            return self.getOrInsert(font, glyph_index);
        }

        // Extract x/y offset from packed bin.
        const x_bin: u32 = subpixel_bin_packed >> 4;
        const y_bin: u32 = subpixel_bin_packed & 0x0F;
        const offset_x = subpixelOffset(x_bin);
        const offset_y = subpixelOffset(y_bin);

        if (self.failures.contains(key, self.gc_generation, self.current_frame)) return emptyRegion();
        self.frame_insert_count += 1;
        const bitmap = if (comptime @import("builtin").os.tag == .windows) font.rasterizeGlyphWithContext(glyph_index, offset_x, offset_y, self.raster_context) catch |err| {
            self.failures.remember(key, self.gc_generation, self.current_frame, err == error.GlyphTooLarge);
            if (@as(anyerror, err) != error.GlyphTooLarge) self.had_transient_failure = true;
            return emptyRegion();
        } else try font.rasterizeGlyphSubpixel(glyph_index, offset_x, offset_y);
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

        if (bitmap.width > ATLAS_SIZE - 2 or bitmap.height > ATLAS_SIZE - 2) {
            self.failures.remember(key, self.gc_generation, self.current_frame, true);
            return emptyRegion();
        }
        const page_format: PageFormat = if (bitmap.is_color) .color else if (bitmap.is_cleartype) .cleartype else .gray;

        // Allocate space (multi-page), null -> return empty region.
        const alloc_result = self.allocateInPages(bitmap.width, bitmap.height, page_format) orelse {
            self.failures.remember(key, self.gc_generation, self.current_frame, false);
            self.had_transient_failure = true;
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
                @as(f32, @floatFromInt(alloc_result.rect.x)) / @as(f32, @floatFromInt(self.pages[alloc_result.page_idx].?.texture.size.width)),
                @as(f32, @floatFromInt(alloc_result.rect.y)) / @as(f32, @floatFromInt(self.pages[alloc_result.page_idx].?.texture.size.width)),
            },
            .uv_max = .{
                @as(f32, @floatFromInt(alloc_result.rect.x + bitmap.width)) / @as(f32, @floatFromInt(self.pages[alloc_result.page_idx].?.texture.size.width)),
                @as(f32, @floatFromInt(alloc_result.rect.y + bitmap.height)) / @as(f32, @floatFromInt(self.pages[alloc_result.page_idx].?.texture.size.width)),
            },
            .bearing_x = bitmap.bearing_x,
            .bearing_y = bitmap.bearing_y,
            .advance = bitmap.advance,
            .width = bitmap.width,
            .height = bitmap.height,
            .page_index = alloc_result.page_idx,
            .is_color = bitmap.is_color,
            .is_cleartype = bitmap.is_cleartype,
        };

        try self.cache.put(key, region);
        return region;
    }

    /// Upload bitmap data to texture in specified page.
    ///
    /// WARN: failures must propagate, **never suppress**. Page texture intentionally not
    /// zero-filled (see ensurePage comment), and caller writes region with real UV to cache
    /// (key contains font_ptr/glyph/scale; hit short-circuits, never retransmit). Failed upload
    /// still cached = glyph samples **undefined GPU memory every frame** = permanent garbled
    /// text, zero logs. writeRegion failure is real: bitmap size fields mismatching pixel
    /// buffer length returns error.InvalidTextureData (gpu/metal/resources.zig).
    fn uploadToTexture(self: *GlyphAtlas, page_idx: u8, bitmap: GlyphBitmap, rect: RectPacker.Rect) !void {
        if (page_idx < self.page_count) {
            if (self.pages[page_idx]) |*page| {
                // BGRA page 4 bytes/pixel; bytes_per_row using width makes Metal read 1/4 line
                // width,
                // image becomes slanted garbage.
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

    /// Remove all cache entries under a Font pointer.
    ///
    /// GlyphKey uses `font_ptr` (Font heap address) as identity. After a Font is destroyed, the
    /// allocator may reuse the address for the next Font; stale entries then make the new font hit
    /// the old font's bitmap = **different font's glyphs**. Any path destroying a Font while the
    /// atlas is alive (typical: fallback wrapper eviction) must call this first. Only deletes cache
    /// entries, leaves pages (space reclaimed by age-based GC, in-flight buffers safe to sample).
    ///
    /// Safe to removeByPtr during iteration: HashMap deletion only tombstones, never relocates.
    pub fn forgetFont(self: *GlyphAtlas, font_ptr: usize) void {
        self.failures.forgetFont(font_ptr);
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.key_ptr.font_ptr == font_ptr) self.cache.removeByPtr(entry.key_ptr);
        }
    }

    pub fn getCacheSize(self: *GlyphAtlas) usize {
        return self.cache.count();
    }

    /// Get texture for specified page.
    pub fn getPageTexture(self: *GlyphAtlas, page_idx: u8) ?gpu.Backend.TextureBinding {
        if (page_idx < self.page_count) {
            if (self.pages[page_idx]) |page| {
                return page.texture.binding();
            }
        }
        return null;
    }

    /// Get pixel format of specified page (render uses this to choose grayscale or color texture
    /// slot).
    pub fn getPageFormat(self: *GlyphAtlas, page_idx: u8) ?PageFormat {
        if (page_idx < self.page_count) {
            if (self.pages[page_idx]) |page| return page.format;
        }
        return null;
    }

    /// Get page count.
    pub fn getPageCount(self: *GlyphAtlas) u32 {
        return self.page_count;
    }

    /// Get sampler.
    pub fn getSamplerNearest(self: *GlyphAtlas) ?*gpu.Backend.Sampler {
        return if (self.sampler_nearest) |*sampler| sampler else null;
    }

    pub fn getSamplerLinear(self: *GlyphAtlas) ?*gpu.Backend.Sampler {
        return if (self.sampler_linear) |*sampler| sampler else null;
    }
};

/// Glyph position and metric data in atlas.
pub const AtlasRegion = struct {
    uv_min: [2]f32,
    uv_max: [2]f32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i32,
    width: u32,
    height: u32,
    page_index: u8,
    /// true = region on BGRA8 color page, shader must output sampled RGBA directly,
    /// can't multiply by text color (emoji self-colored).
    is_color: bool = false,
    is_cleartype: bool = false,
};

fn emptyRegion() AtlasRegion {
    return .{ .uv_min = .{ 0, 0 }, .uv_max = .{ 0, 0 }, .bearing_x = 0, .bearing_y = 0, .advance = 0, .width = 0, .height = 0, .page_index = 0 };
}

/// Glyph cache key.
const GlyphKey = struct {
    font_ptr: usize,
    glyph_index: u32,
    /// Packed quarter-pixel phase bins. Zero is an unshifted raster.
    subpixel_bin: u32 = 0,
    /// HiDPI: quantized `Font.scale_factor` (see quantizeScale).
    ///
    /// Must be in key. `Font.scale_factor` is **in-place mutable**; setScaleFactor doesn't
    /// change the Font pointer. Without scale in key, dragging a window Retina <-> non-Retina
    /// hits cached glyphs with an identical key and never rasterizes at the new scale:
    ///   1x -> 2x: reuse half-resolution bitmap = blurry.
    ///   2x -> 1x: reuse double-resolution bitmap = size/bearing misaligned (bearing
    ///             back-divided by **current** scale_factor in text_renderer).
    scale_q: u32 = quantizeScale(1.0),
};

// Hash the integer fields together rather than invoking generic field hashing
// for every glyph. Padding never participates in either hash or equality.
const GlyphKeyContext = struct {
    pub fn hash(_: @This(), key: GlyphKey) u64 {
        const words = [_]u64{ key.font_ptr, @as(u64, key.glyph_index) | (@as(u64, key.subpixel_bin) << 32), key.scale_q };
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&words));
    }
    pub fn eql(_: @This(), a: GlyphKey, b: GlyphKey) bool {
        return a.font_ptr == b.font_ptr and a.glyph_index == b.glyph_index and a.subpixel_bin == b.subpixel_bin and a.scale_q == b.scale_q;
    }
};
const GlyphCache = std.HashMap(GlyphKey, AtlasRegion, GlyphKeyContext, 80);

/// Quantize f32 scale to integer safe for AutoHashMap key (1/100 precision).
///
/// Why quantize vs raw f32: HashMap does bitwise hash and equality. Float -0.0/+0.0, NaN,
/// and the same logical scale via different float paths differing in the last bit give
/// "logically same, key different" phantom entries = permanent cache miss + unbounded atlas.
///
/// Why 1/100 vs fixed tiers (1x/2x only): macOS `backingScaleFactor` is usually 1.0/2.0,
/// but scaled-resolution modes and external displays give others. Fixed tiers silently
/// collapse different real scales to one, bringing back the bug. 1/100 is lossless on all
/// real values and much coarser than float noise.
pub fn quantizeScale(scale: f32) u32 {
    const clamped = @max(0.01, @min(scale, 64.0));
    return @intFromFloat(@round(clamped * 100.0));
}

/// A font's raster key: its quantized scale, plus the top bit when it rasterizes without font
/// smoothing (the same glyph at the same scale is a different bitmap; Font.smooth_fonts). A
/// backend whose rasterizer has no smoothing to turn off (`honors_smoothing = false`) keys both
/// alike, so the flag does not store the same bitmap twice.
pub fn rasterKey(font: anytype) u32 {
    const F = @TypeOf(font.*);
    const honored = @hasField(F, "smooth_fonts") and (!@hasDecl(F, "honors_smoothing") or F.honors_smoothing);
    const smooth: bool = if (honored) font.smooth_fonts else true;
    const lcd: u32 = if (@hasField(F, "cleartype")) (if (font.cleartype) @as(u32, 1) << 30 else 0) else 0;
    return quantizeScale(font.scale_factor) | lcd | (if (smooth) @as(u32, 0) else @as(u32, 1) << 31);
}

/// R6: Number of subpixel bins (4 per axis = 16 variants).
pub const SUBPIXEL_BINS: u32 = 4;

/// R6: Pen position rounded to the nearest 1/SUBPIXEL_BINS pixel: the integer pixel the
/// bitmap is placed from and the bin it is rasterized in. Bin 0 is an unshifted raster, so a
/// pen on the pixel grid gets the hinted glyph exactly (a bin-center offset would move every
/// hinted stem off the grid by 1/8 px and smear it across two pixels).
// Windows uses the same bounded quarter-pixel phase grid as Skia.
pub const SubpixelPen = @import("text_phase.zig").Pen;

pub fn subpixelPen(pen_px: f32) SubpixelPen {
    if (@import("builtin").os.tag == .windows) return @import("text_phase.zig").windowsPen(pen_px);
    const bins: f32 = @floatFromInt(SUBPIXEL_BINS);
    const quantized = @round(pen_px * bins) / bins;
    const pixel = @floor(quantized);
    const bin: u4 = @intFromFloat(@min(@max(@round((quantized - pixel) * bins), 0), bins - 1));
    return .{ .pixel = pixel, .bin = bin };
}

/// R6: Raster offset of a bin. Bin 0 is the unshifted glyph.
pub fn subpixelOffset(bin: u32) f32 {
    return @as(f32, @floatFromInt(bin)) / @as(f32, @floatFromInt(SUBPIXEL_BINS));
}

/// R6: Pack x/y bin to u8.
pub fn packSubpixelBin(x_bin: u32, y_bin: u32) u32 {
    return (x_bin << 4) | y_bin;
}

/// Simple rectangle packer (Shelf packing algorithm).
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
        // Add 1px padding to avoid texture sample bleed.
        if (self.width < 2 or self.height < 2) return error.AtlasFull;
        if (w > self.width - 2 or h > self.height - 2) return error.AtlasFull;
        const padded_w = w + 2;
        const padded_h = h + 2;

        // Newline check.
        if (self.current_x > self.width or padded_w > self.width - self.current_x) {
            self.current_x = 0;
            self.current_y = std.math.add(u32, self.current_y, self.current_row_height) catch return error.AtlasFull;
            self.current_row_height = 0;
        }

        // Space insufficient.
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
    var fs = try text.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fs.deinit();

    // Apple Color Emoji has sbix table -> must mark as color. Else emoji rasterizes to
    // single-channel coverage mask (gray block); color lost at rasterization.
    const emoji = try fs.findFont(.{ .family = "Apple Color Emoji", .size = 32 });
    defer emoji.deinit();
    try testing.expect(emoji.hasColorGlyphs());

    // Normal text fonts must mark non-color. Else wastes 4x VRAM for BGRA page,
    // loses subpixel antialiasing.
    const helvetica = try fs.findFont(.{ .family = "Helvetica", .size = 32 });
    defer helvetica.deinit();
    try testing.expect(!helvetica.hasColorGlyphs());

    const menlo = try fs.findFont(.{ .family = "Menlo", .size = 32 });
    defer menlo.deinit();
    try testing.expect(!menlo.hasColorGlyphs());
}

test "atlas page format: bytes-per-pixel drives budget accounting" {
    const testing = @import("std").testing;
    // Color page is BGRA8 = 4 bytes/pixel. Unweighted bytesUsed: 64 MiB page recorded as
    // 16 MiB, GC budget 4x overspend.
    try testing.expectEqual(@as(u32, 1), PageFormat.gray.bytesPerPixel());
    try testing.expectEqual(@as(u32, 4), PageFormat.color.bytesPerPixel());
}

test "atlas retire queue: 延迟释放窗口覆盖三重缓冲" {
    const testing = @import("std").testing;
    const A = GlyphAtlas;
    // Delay window must be >= in-flight frame count, else sync-free bug still exists.
    try testing.expect(A.MAX_FRAMES_IN_FLIGHT >= 3);
    // Retire queue must hold all pages GC can evict at once.
    try testing.expect(A.MAX_RETIRED >= A.MAX_PAGES);
}

test "glyph atlas: GC policy constants are self-consistent" {
    const testing = @import("std").testing;
    const A = GlyphAtlas;

    // Budget must be < hard limit, else GC never triggers (pre-fix state: only page_count
    // hitting MAX_PAGES (32 * 16 MiB = 512 MiB) triggered, EVICT_THRESHOLD unused).
    const hard_cap_bytes: u64 = @as(u64, A.MAX_PAGES) * A.PAGE_BYTES;
    try testing.expect(A.BYTE_BUDGET < hard_cap_bytes);

    // Budget should hold several pages, else each GC clears working set (thrash).
    try testing.expect(A.BYTE_BUDGET >= 4 * A.PAGE_BYTES);

    // Page size arithmetic correct: 4096x4096 R8 = 16 MiB.
    try testing.expectEqual(@as(u64, 16 * 1024 * 1024), A.PAGE_BYTES);

    // GC interval and age threshold positive; else scan every frame or evict live pages.
    try testing.expect(A.GC_INTERVAL_FRAMES > 0);
    try testing.expect(A.EVICT_THRESHOLD > A.GC_INTERVAL_FRAMES);
}

// HiDPI (Retina) audit regression test, 2026-07-31
//
// Background: entire repo had zero HiDPI test coverage (grep scale/dpi/retina only hit transform
// scale and theme spacing scale, both unrelated to device pixel ratio). Tests below lock in audit
// facts to prevent regression.

test "HiDPI: 字形在 2x 下按物理像素光栅化（非逻辑尺寸再由 GPU 放大）" {
    const testing = @import("std").testing;
    // Most common HiDPI bug: blurry text on Retina because rasterized at logical size,
    // GPU upsamples on display. This test runs **real CoreText path** measuring actual bitmap size.
    var fs = try text.FontSystem.init(testing.allocator, @import("std").testing.io);
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

    // coretext_bridge.m formula: ceil(bbox * scale + subpixel) + 2 (2px padding),
    // so 2x bitmap ≈ 2 * 1x, but padding/ceil not strict multiple. Criterion: significantly
    // larger than 1x (rules out "scale not passed"), not > 2x by much.
    const w1: f32 = @floatFromInt(b1.width);
    const w2: f32 = @floatFromInt(b2.width);
    const h1: f32 = @floatFromInt(b1.height);
    const h2: f32 = @floatFromInt(b2.height);
    const ratio_w = w2 / w1;
    const ratio_h = h2 / h1;

    // 1.7 lower bound: 2x same as 1x size (ratio ≈ 1.0) means scale_factor never reached
    // CoreText rasterize = classic Retina blur bug. Real data (2026-07-31, Helvetica 'M' @32pt):
    // 1x=24x25px, 2x=46x48px, ratio=1.917/1.920 (diff is constant +2px padding).
    try testing.expect(ratio_w > 1.7);
    try testing.expect(ratio_h > 1.7);
    // Upper bound guards against scale multiplied twice (4x).
    try testing.expect(ratio_w < 2.4);
    try testing.expect(ratio_h < 2.4);
}

// Above "GlyphKey lacks scale (known bug)" locking test deleted per its own comment;
// bug fixed (GlyphKey.scale_q). Below three are forward-looking replacements.

test "HiDPI: 不同 scale 必须产生不同 GlyphKey（动态 scale 变化不再命中过期位图）" {
    const testing = @import("std").testing;
    // Forward replacement for prior bug lock. `Font.scale_factor` in-place mutable,
    // setScaleFactor doesn't change pointer, so scale must enter key; else Retina <->
    // non-Retina toggle permanently reuses old bitmap.
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
    // Keys identical except scale must be unequal; that's the core fix.
    try testing.expect(!std.meta.eql(k1x, k2x));

    // Same scale still hits same entry (else cache all-miss).
    const k1x_again = GlyphKey{
        .font_ptr = 0xDEAD,
        .glyph_index = 7,
        .subpixel_bin = 0,
        .scale_q = quantizeScale(1.0),
    };
    try testing.expect(std.meta.eql(k1x, k1x_again));

    // Structural assertion: scale dimension exists in key.
    const fields = @import("zenit_reflection").fields(GlyphKey);
    var has_scale = false;
    inline for (fields) |fld| {
        if (std.mem.eql(u8, fld.name, "scale_q")) has_scale = true;
    }
    try testing.expect(has_scale);
}

test "HiDPI: scale 量化保持不同真实 scale 可区分、同一 scale 稳定" {
    const testing = @import("std").testing;
    // Quantization must not collapse different real scales (would preserve bug in disguise).
    try testing.expect(quantizeScale(1.0) != quantizeScale(2.0));
    try testing.expect(quantizeScale(1.0) != quantizeScale(1.5));
    try testing.expect(quantizeScale(1.5) != quantizeScale(2.0));
    // Non-integer scale under scaled-resolution mode must also distinguish.
    try testing.expect(quantizeScale(1.25) != quantizeScale(1.5));

    // Same logical scale via different float paths must quantize to same (else cache
    // all-miss + unbounded atlas). 2.0 vs 4.0/2.0 vs 1.0+1.0.
    try testing.expectEqual(quantizeScale(2.0), quantizeScale(4.0 / 2.0));
    try testing.expectEqual(quantizeScale(2.0), quantizeScale(1.0 + 1.0));
    // Float noise << 1/100 must not create new tier.
    try testing.expectEqual(quantizeScale(2.0), quantizeScale(2.0 + 1e-6));
}

test "HiDPI: 同一 Font 指针改 scale 后 getOrInsert 的键随之改变" {
    const testing = @import("std").testing;
    // End-to-end anchor that "setScaleFactor doesn't change pointer" yet key changes.
    // Real CoreText Font, only verify key construction (no Metal device needed).
    var fs = try text.FontSystem.init(testing.allocator, @import("std").testing.io);
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
    // Premise check: pointer stays same, this is why scale must be in key.
    try testing.expectEqual(ptr_before, @intFromPtr(f));
    const key_2x = GlyphKey{
        .font_ptr = @intFromPtr(f),
        .glyph_index = g,
        .scale_q = quantizeScale(f.scale_factor),
    };

    try testing.expect(!std.meta.eql(key_1x, key_2x));
    // unsmoothed glyphs are a different bitmap: a different key at the same scale
    const smooth_key = rasterKey(f);
    f.smooth_fonts = false;
    defer f.smooth_fonts = true;
    try testing.expect(rasterKey(f) != smooth_key);
}

test "rasterKey: a backend without smoothing (honors_smoothing = false) keys both alike" {
    const Honoring = struct { scale_factor: f32 = 2, smooth_fonts: bool = true };
    const Ignoring = struct {
        scale_factor: f32 = 2,
        smooth_fonts: bool = true,
        pub const honors_smoothing = false;
    };
    var h = Honoring{};
    var n = Ignoring{};
    const h_on = rasterKey(&h);
    const n_on = rasterKey(&n);
    h.smooth_fonts = false;
    n.smooth_fonts = false;
    try std.testing.expect(rasterKey(&h) != h_on);
    try std.testing.expectEqual(n_on, rasterKey(&n));
}

test "page eviction removes every victim glyph without allocating and remaps survivors" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var atlas: GlyphAtlas = undefined;
    atlas.allocator = failing.allocator();
    atlas.cache = GlyphCache.init(testing.allocator);
    defer atlas.cache.deinit();
    atlas.pages = @as([GlyphAtlas.MAX_PAGES]?AtlasPage, @splat(null));
    atlas.retired = @as([GlyphAtlas.MAX_RETIRED]?RetiredTexture, @splat(null));
    atlas.current_frame = 100;
    atlas.page_count = 3;
    for (atlas.pages[0..3]) |*page| page.* = .{
        .texture = gpu.Backend.Texture.fakeForTesting(1, 1, .r8_unorm),
        .packer = RectPacker.init(1, 1),
        .last_used_frame = 0,
        .format = .gray,
    };
    // Fake textures are only enqueued, never destroyed or sampled by this test.
    var region = AtlasRegion{
        .uv_min = .{ 0, 0 },
        .uv_max = .{ 1, 1 },
        .bearing_x = 0,
        .bearing_y = 0,
        .advance = 1,
        .width = 1,
        .height = 1,
        .page_index = 0,
    };
    for (0..3) |page| {
        region.page_index = @intCast(page);
        for (0..200) |glyph| try atlas.cache.put(.{
            .font_ptr = 1,
            .glyph_index = @intCast(page * 200 + glyph),
        }, region);
    }
    atlas.evictPage(0);
    try testing.expectEqual(@as(u32, 400), atlas.cache.count());
    try testing.expectEqual(@as(u32, 2), atlas.page_count);
    for (0..200) |glyph| try testing.expect(atlas.cache.get(.{
        .font_ptr = 1,
        .glyph_index = @intCast(glyph),
    }) == null);
    for (200..600) |glyph| {
        const survivor = atlas.cache.get(.{ .font_ptr = 1, .glyph_index = @intCast(glyph) }).?;
        try testing.expectEqual(@as(u8, if (glyph < 400) 1 else 0), survivor.page_index);
    }
    try testing.expect(atlas.retired[0] != null);
    try testing.expect(!failing.has_induced_failure);
}

test "forgetFont 只摘除该 font_ptr 的全部条目（含各 scale / subpixel 变体）" {
    const testing = std.testing;
    // forgetFont only touches cache, no Metal device needed.
    var atlas: GlyphAtlas = undefined;
    atlas.cache = GlyphCache.init(testing.allocator);
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
    // New font at reused address must miss, not hit old bitmap.
    try testing.expect(atlas.cache.get(.{ .font_ptr = doomed, .glyph_index = 7 }) == null);
    try testing.expect(atlas.cache.get(.{ .font_ptr = survivor, .glyph_index = 7 }) != null);
}

test "transient raster failure expires at the next frame's prewarm" {
    var atlas: GlyphAtlas = undefined;
    atlas.had_transient_failure = true;
    atlas.frame_insert_count = 12;
    atlas.resetFrameStats();
    try std.testing.expect(!atlas.had_transient_failure);
    try std.testing.expectEqual(@as(u32, 0), atlas.frame_insert_count);
}

test "small atlas pages are the default with an exact 4096 override" {
    try std.testing.expectEqual(@as(u32, 4096), GlyphAtlas.selectedPageSize("1"));
    for ([_]?[]const u8{ null, "", "0", "true", "2" }) |value| {
        try std.testing.expectEqual(@as(u32, 2048), GlyphAtlas.selectedPageSize(value));
    }
}
