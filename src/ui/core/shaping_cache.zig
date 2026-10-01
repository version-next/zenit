//! ShapingCache, Phase 6 (text_hash, font, width) -> cached GlyphRun
//!
//! TextShaper.shape() 在 CoreText 后端单次 ~10-100µs；同文本第二次 shape 是
//! 浪费。ShapingCache 用 (content_hash, font_id, max_width) 三元组 key 缓存
//! shaping 结果。命中率 > 95% 是 plan 矩阵指标。
//!
//! 设计参照：HarfBuzz hb_shape_plan_t 缓存 + Skia 内部 SkTextBlob 缓存。
//!
//! 历史债避免：
//! - **不**让 cache entry 持有 Allocator-owned []GlyphPosition；用 arena
//!   per-frame 重用 buffer，cache 只存指针 slice 视图。entry deinit 释放。
//! - **不**把 cache 容量设硬上限太小（v0.1 MAX_LINES=64 类硬上限教训）；
//!   默认 4096 entries + LRU eviction
//! - **不**让 cache key 用 `[]const u8`（slice ptr 不稳定）；用 hash + length
//!   作 key，命中时 caller 传原文件内容验证（避免哈希碰撞误命中）

const std = @import("std");
const testing = std.testing;
const glyph_run = @import("glyph_run.zig");
const text_coordinates = @import("text_core").text_coordinates;

pub const GlyphRun = glyph_run.GlyphRun;
pub const GlyphPosition = glyph_run.GlyphPosition;
pub const Cluster = glyph_run.Cluster;
pub const FontMetrics = glyph_run.FontMetrics;

/// Shaping cache key
pub const ShapingKey = struct {
    /// 原文 hash（caller 用 std.hash.Wyhash 或类似生成）
    text_hash: u64,
    /// 文本长度（防哈希碰撞 + 大小估算）
    text_len: u32,
    /// 字体 id（zenit FontSystem 内部 id；0 = 默认）
    font_id: u32,
    /// max_width（用于 line break；0 = 单行不折）
    max_width: f32,
    /// 字号
    font_size: f32,

    pub fn hash(self: ShapingKey) u64 {
        var h = std.hash.Wyhash.init(0xDEADBEEFCAFEBABE);
        h.update(std.mem.asBytes(&self.text_hash));
        h.update(std.mem.asBytes(&self.text_len));
        h.update(std.mem.asBytes(&self.font_id));
        h.update(std.mem.asBytes(&self.max_width));
        h.update(std.mem.asBytes(&self.font_size));
        return h.final();
    }

    pub fn eq(a: ShapingKey, b: ShapingKey) bool {
        return a.text_hash == b.text_hash and
            a.text_len == b.text_len and
            a.font_id == b.font_id and
            a.max_width == b.max_width and
            a.font_size == b.font_size;
    }
};

/// Cache entry, owned glyph + cluster slices（arena allocated）
pub const Entry = struct {
    key: ShapingKey,
    /// arena-allocated glyph 序列
    glyphs: []GlyphPosition,
    /// arena-allocated cluster 序列
    clusters: []Cluster,
    metrics: FontMetrics,
    direction: glyph_run.Direction,
    total_advance: f32,
    /// LRU 时间戳：最近使用的 frame index
    last_used_frame: u64,

    pub fn toRun(self: Entry) GlyphRun {
        return .{
            .glyphs = self.glyphs,
            .clusters = self.clusters,
            .metrics = self.metrics,
            .direction = self.direction,
            .total_advance = self.total_advance,
        };
    }
};

pub const ShapingCacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    pub fn hitRate(self: ShapingCacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: ShapingKey) u64 {
        return k.hash();
    }
    pub fn eql(_: KeyContext, a: ShapingKey, b: ShapingKey) bool {
        return ShapingKey.eq(a, b);
    }
};

const VisualEntry = struct {
    caret_stops: []text_coordinates.CaretStop,
    width: f32,
    ascent: f32,
    descent: f32,
    leading: f32,
    base_direction: text_coordinates.Direction,
    last_used_frame: u64,

    fn toLine(self: VisualEntry, text_len: usize) text_coordinates.VisualLine {
        return .{
            .source_start = .{ .value = 0 },
            .source_end = .{ .value = text_len },
            .caret_stops = self.caret_stops,
            .width = self.width,
            .ascent = self.ascent,
            .descent = self.descent,
            .leading = self.leading,
            .base_direction = self.base_direction,
        };
    }
};

pub const ShapingCache = struct {
    allocator: std.mem.Allocator,
    /// arena for glyph/cluster slices；每次 evict + cache.deinit 时整 arena 重置
    arena: std.heap.ArenaAllocator,
    /// HashMap key -> entry index
    map: std.HashMapUnmanaged(ShapingKey, Entry, KeyContext, 80),
    visual_map: std.HashMapUnmanaged(ShapingKey, VisualEntry, KeyContext, 80),
    capacity: u32,
    current_frame: u64 = 0,
    stats: ShapingCacheStats = .{},

    pub fn init(parent_allocator: std.mem.Allocator, capacity: u32) ShapingCache {
        return .{
            .allocator = parent_allocator,
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .map = .{},
            .visual_map = .{},
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *ShapingCache) void {
        self.map.deinit(self.allocator);
        self.visual_map.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn beginFrame(self: *ShapingCache) void {
        self.current_frame +%= 1;
    }

    /// 查询 cache。命中 -> 返回 GlyphRun + bump last_used_frame；未命中 -> null。
    pub fn lookup(self: *ShapingCache, key: ShapingKey) ?GlyphRun {
        if (self.map.getPtr(key)) |entry| {
            entry.last_used_frame = self.current_frame;
            self.stats.hits += 1;
            return entry.toRun();
        }
        self.stats.misses += 1;
        return null;
    }

    pub fn lookupVisual(self: *ShapingCache, key: ShapingKey) ?text_coordinates.VisualLine {
        if (self.visual_map.getPtr(key)) |entry| {
            entry.last_used_frame = self.current_frame;
            return entry.toLine(key.text_len);
        }
        return null;
    }

    pub fn insertVisual(self: *ShapingCache, key: ShapingKey, line: text_coordinates.VisualLine) !void {
        if (self.visual_map.count() >= self.capacity) {
            // Caret geometry is small and cheap to rebuild. A bounded wholesale
            // reset avoids per-entry arena ownership and keeps lookup O(1).
            self.visual_map.clearRetainingCapacity();
        }
        if (self.arena.queryCapacity() >= ARENA_CLEAR_BYTES and self.map.count() == 0) {
            self.visual_map.clearRetainingCapacity();
            _ = self.arena.reset(.retain_capacity);
        }
        const owned = try self.arena.allocator().alloc(text_coordinates.CaretStop, line.caret_stops.len);
        @memcpy(owned, line.caret_stops);
        try self.visual_map.put(self.allocator, key, .{
            .caret_stops = owned,
            .width = line.width,
            .ascent = line.ascent,
            .descent = line.descent,
            .leading = line.leading,
            .base_direction = line.base_direction,
            .last_used_frame = self.current_frame,
        });
    }

    /// 插入 cache 条目。caller 提供 shaping 结果（glyph/cluster slice 由 cache
    /// 内部的 arena 复制存储，所以 caller 可以传 stack-allocated 的）。
    /// 容量满时按 LRU 驱逐。
    pub fn insert(
        self: *ShapingCache,
        key: ShapingKey,
        glyphs: []const GlyphPosition,
        clusters: []const Cluster,
        metrics: FontMetrics,
        direction: glyph_run.Direction,
        total_advance: f32,
    ) !void {
        if (self.map.count() >= self.capacity) {
            self.evictBatch();
        }

        const arena_alloc = self.arena.allocator();
        const owned_glyphs = try arena_alloc.alloc(GlyphPosition, glyphs.len);
        @memcpy(owned_glyphs, glyphs);
        const owned_clusters = try arena_alloc.alloc(Cluster, clusters.len);
        @memcpy(owned_clusters, clusters);

        try self.map.put(self.allocator, key, .{
            .key = key,
            .glyphs = owned_glyphs,
            .clusters = owned_clusters,
            .metrics = metrics,
            .direction = direction,
            .total_advance = total_advance,
            .last_used_frame = self.current_frame,
        });
    }

    /// 超过该帧数未使用的条目视为 stale，批量驱逐优先清它们。
    const STALE_FRAMES: u64 = 120;
    /// entry slices 挂在内部 arena 上、逐条驱逐不回收内存；arena 超过该阈值时
    /// 整体 clear（map + arena 一起重置），下一帧热集重新 shape 一轮。
    const ARENA_CLEAR_BYTES: usize = 32 * 1024 * 1024;

    /// 批量驱逐：老的逐条 LRU 满载后每 miss 都 O(capacity) 全表扫描，且 arena
    /// 内存永不回收。这里一次腾出至少 capacity/4，把扫描成本均摊到 O(4)/miss。
    fn evictBatch(self: *ShapingCache) void {
        if (self.map.count() == 0) return;

        if (self.arena.queryCapacity() >= ARENA_CLEAR_BYTES) {
            // arena 无界增长兜底：整体重置。代价是下一帧 shape 峰值，频率极低。
            self.stats.evictions += self.map.count();
            self.map.clearRetainingCapacity();
            self.visual_map.clearRetainingCapacity();
            _ = self.arena.reset(.retain_capacity);
            return;
        }

        const target: u64 = @max(self.capacity / 4, 1);
        // 逐步收紧的年龄阈值：每轮一次全扫、批量 removeByPtr（remove 不 rehash，
        // 迭代期间删除是 std.HashMap 支持的模式）。先清 STALE_FRAMES 未用的，
        // 不够则阈值减半再扫，最坏 O(log(STALE_FRAMES)) 轮后 cutoff=当前帧，
        // 必然腾够 target。
        var age_threshold: u64 = STALE_FRAMES;
        var removed: u64 = 0;
        while (removed < target) {
            const cutoff = self.current_frame -| age_threshold;
            var iter = self.map.iterator();
            while (iter.next()) |kv| {
                if (kv.value_ptr.last_used_frame <= cutoff) {
                    self.map.removeByPtr(kv.key_ptr);
                    removed += 1;
                }
            }
            if (removed >= target or age_threshold == 0) break;
            age_threshold /= 2;
        }
        self.stats.evictions += removed;
    }

    pub fn count(self: *const ShapingCache) u32 {
        return @intCast(self.map.count());
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ShapingKey eq + hash stable" {
    const a = ShapingKey{ .text_hash = 0xCAFE, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 14 };
    const b = ShapingKey{ .text_hash = 0xCAFE, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 14 };
    try testing.expect(ShapingKey.eq(a, b));
    try testing.expectEqual(a.hash(), b.hash());
}

test "ShapingKey different params → different hash" {
    const a = ShapingKey{ .text_hash = 1, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 14 };
    const b = ShapingKey{ .text_hash = 1, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 16 };
    try testing.expect(!ShapingKey.eq(a, b));
}

test "ShapingCache: insert + lookup hit" {
    var cache = ShapingCache.init(testing.allocator, 16);
    defer cache.deinit();

    const key = ShapingKey{ .text_hash = 0x1, .text_len = 5, .font_id = 0, .max_width = 0, .font_size = 14 };
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
    };
    const metrics = FontMetrics{ .ascent = 12, .descent = 4, .line_gap = 0, .font_size = 14 };

    try cache.insert(key, &glyphs, &clusters, metrics, .ltr, 10);

    const got = cache.lookup(key);
    try testing.expect(got != null);
    try testing.expectEqual(@as(usize, 1), got.?.glyphs.len);
    try testing.expectEqual(@as(f32, 10), got.?.total_advance);
    try testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try testing.expectEqual(@as(u64, 0), cache.stats.misses);
}

test "ShapingCache: lookup miss" {
    var cache = ShapingCache.init(testing.allocator, 16);
    defer cache.deinit();

    const key = ShapingKey{ .text_hash = 0x1, .text_len = 5, .font_id = 0, .max_width = 0, .font_size = 14 };
    try testing.expect(cache.lookup(key) == null);
    try testing.expectEqual(@as(u64, 1), cache.stats.misses);
}

test "ShapingCache: batch eviction keeps recently-used, drops stale" {
    var cache = ShapingCache.init(testing.allocator, 4);
    defer cache.deinit();

    const empty_glyphs: []const GlyphPosition = &.{};
    const empty_clusters: []const Cluster = &.{};
    const m = FontMetrics{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 };
    const k1 = ShapingKey{ .text_hash = 1, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k2 = ShapingKey{ .text_hash = 2, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k3 = ShapingKey{ .text_hash = 3, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k4 = ShapingKey{ .text_hash = 4, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k5 = ShapingKey{ .text_hash = 5, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };

    cache.beginFrame();
    try cache.insert(k1, empty_glyphs, empty_clusters, m, .ltr, 0);
    try cache.insert(k2, empty_glyphs, empty_clusters, m, .ltr, 0);
    try cache.insert(k3, empty_glyphs, empty_clusters, m, .ltr, 0);
    try cache.insert(k4, empty_glyphs, empty_clusters, m, .ltr, 0);
    try testing.expectEqual(@as(u32, 4), cache.count());

    // 推进 200 帧，只有 k1 持续被使用，其余变 stale
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        cache.beginFrame();
        _ = cache.lookup(k1);
    }

    // 容量已满；插入 k5 触发批量驱逐，stale 的 k2/k3/k4 被清，k1 幸存
    try cache.insert(k5, empty_glyphs, empty_clusters, m, .ltr, 0);
    try testing.expect(cache.lookup(k1) != null);
    try testing.expect(cache.lookup(k2) == null);
    try testing.expect(cache.lookup(k3) == null);
    try testing.expect(cache.lookup(k4) == null);
    try testing.expect(cache.lookup(k5) != null);
    try testing.expect(cache.stats.evictions >= 3);
}

test "ShapingCache: hit rate calculation" {
    var stats = ShapingCacheStats{ .hits = 95, .misses = 5 };
    try testing.expectApproxEqAbs(@as(f64, 0.95), stats.hitRate(), 0.001);
}

test "ShapingCache: stats hits + misses tracked" {
    var cache = ShapingCache.init(testing.allocator, 16);
    defer cache.deinit();

    const key = ShapingKey{ .text_hash = 1, .text_len = 5, .font_id = 0, .max_width = 0, .font_size = 14 };
    _ = cache.lookup(key); // miss
    _ = cache.lookup(key); // miss
    try cache.insert(key, &.{}, &.{}, .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 }, .ltr, 0);
    _ = cache.lookup(key); // hit
    _ = cache.lookup(key); // hit
    _ = cache.lookup(key); // hit

    try testing.expectEqual(@as(u64, 3), cache.stats.hits);
    try testing.expectEqual(@as(u64, 2), cache.stats.misses);
    try testing.expectApproxEqAbs(@as(f64, 0.6), cache.stats.hitRate(), 0.001);
}
