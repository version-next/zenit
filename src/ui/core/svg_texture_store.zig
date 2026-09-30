//! SVG 贴图缓存与命中几何 —— 从 `Cx` 析出的有状态子系统。
//!
//! 管两张表：
//!   - `hit_shapes`   texture_id → PathGeometry，贴图的精确命中形状
//!   - `texture_cache` (svg 内容哈希, w, h) → texture_id，避免同一张图重复栅格化
//!
//! 这两张表加上 `loader` 原本是 `Cx` 上的三个字段 + 六个方法。它们自成一个
//! 所有权闭环（geometry 要 free、texture 要经 loader 的 unload 回调释放），
//! 和 `Cx` 的其余状态没有耦合，所以整体搬出来。
//!
//! **所有权合同**：
//!   - `hit_shapes` 里的每个 PathGeometry 由本 store 拥有，覆盖与清空时负责释放
//!   - `texture_cache` 里的 texture_id 由 `loader` 拥有；store 只在清空缓存时
//!     调 `unload_fn` 通知它，自己不做别的假设
//!   - 换 loader 必须先清缓存，否则旧 loader 发的 id 会被新 loader 误 unload

const std = @import("std");
const types = @import("types.zig");
const svg_path = @import("svg_path.zig");
const svg_geometry = @import("svg_geometry.zig");

const PathGeometry = types.PathGeometry;

/// 宿主提供的 SVG 栅格化后端。
pub const SvgTextureLoader = struct {
    context: ?*anyopaque = null,
    load_fn: *const fn (context: ?*anyopaque, svg_data: []const u8, width: u32, height: u32) anyerror!u32,
    unload_fn: ?*const fn (context: ?*anyopaque, texture_id: u32) void = null,
};

const CacheKey = struct {
    hash: u64,
    width: u32,
    height: u32,
};

pub const SvgTextureStore = struct {
    allocator: std.mem.Allocator,
    hit_shapes: std.AutoHashMap(u32, PathGeometry),
    texture_cache: std.AutoHashMap(CacheKey, u32),
    loader: ?SvgTextureLoader = null,

    pub fn init(allocator: std.mem.Allocator) SvgTextureStore {
        return .{
            .allocator = allocator,
            .hit_shapes = std.AutoHashMap(u32, PathGeometry).init(allocator),
            .texture_cache = std.AutoHashMap(CacheKey, u32).init(allocator),
        };
    }

    pub fn deinit(self: *SvgTextureStore) void {
        self.clearTextureCache();
        self.texture_cache.deinit();
        self.clearHitShapes();
        self.hit_shapes.deinit();
    }

    /// 解析 SVG 的 path 几何并登记为该贴图的命中形状。重复登记会释放旧几何。
    pub fn registerHit(self: *SvgTextureStore, texture_id: u32, svg_data: []const u8) !void {
        var geometry = try svg_path.createSvgDocumentPathGeometry(self.allocator, svg_data, .nonzero);
        errdefer svg_path.freePathGeometry(self.allocator, &geometry);

        const gop = try self.hit_shapes.getOrPut(texture_id);
        if (gop.found_existing) {
            var old = gop.value_ptr.*;
            svg_path.freePathGeometry(self.allocator, &old);
        }
        gop.value_ptr.* = geometry;
    }

    pub fn lookupHit(self: *const SvgTextureStore, texture_id: u32) ?PathGeometry {
        return self.hit_shapes.get(texture_id);
    }

    /// 摘掉单个贴图的命中几何并释放它。没有该条目时是 no-op。
    pub fn dropHit(self: *SvgTextureStore, texture_id: u32) void {
        if (self.hit_shapes.fetchRemove(texture_id)) |kv| {
            var geometry = kv.value;
            svg_path.freePathGeometry(self.allocator, &geometry);
        }
    }

    pub fn clearHitShapes(self: *SvgTextureStore) void {
        var it = self.hit_shapes.iterator();
        while (it.next()) |entry| {
            var geometry = entry.value_ptr.*;
            svg_path.freePathGeometry(self.allocator, &geometry);
        }
        self.hit_shapes.clearRetainingCapacity();
    }

    /// 换 loader 前必须先清空缓存：缓存里的 texture_id 属于旧 loader，
    /// 留给新 loader 会导致它 unload 一个自己没发过的 id。
    pub fn setLoader(self: *SvgTextureStore, loader: ?SvgTextureLoader) void {
        self.clearTextureCache();
        self.loader = loader;
    }

    pub fn clearTextureCache(self: *SvgTextureStore) void {
        if (self.loader) |loader| {
            if (loader.unload_fn) |unload_fn| {
                var it = self.texture_cache.iterator();
                while (it.next()) |entry| unload_fn(loader.context, entry.value_ptr.*);
            }
        }
        self.texture_cache.clearRetainingCapacity();
    }

    /// 取（或栅格化）一张 SVG 贴图。命中缓存时顺带补齐可能缺失的命中形状。
    pub fn load(self: *SvgTextureStore, svg_data: []const u8, width: u32, height: u32) !u32 {
        if (width == 0 or height == 0) return error.InvalidSvgRasterSize;
        const loader = self.loader orelse return error.SvgTextureLoaderUnavailable;
        const key = CacheKey{
            .hash = svg_geometry.hashSvgTexture(svg_data),
            .width = width,
            .height = height,
        };
        if (self.texture_cache.get(key)) |texture_id| {
            if (self.lookupHit(texture_id) == null) {
                try self.registerHit(texture_id, svg_data);
            }
            return texture_id;
        }

        const texture_id = try loader.load_fn(loader.context, svg_data, width, height);
        errdefer if (loader.unload_fn) |unload_fn| unload_fn(loader.context, texture_id);
        try self.registerHit(texture_id, svg_data);
        // put 失败时必须连命中几何一起摘掉：errdefer 已经把 texture_id 还给
        // loader 了，几何再留在表里就是一条「指向已卸载贴图」的残留条目。
        // loader 若复用 id（完全合法，它就是个 u32 句柄），下一张 SVG 拿到
        // 同一个 id 时 lookupHit 会命中**上一张图的几何** —— 命中区域错位，
        // 不崩不报错。
        errdefer self.dropHit(texture_id);
        try self.texture_cache.put(key, texture_id);
        return texture_id;
    }
};

// ── 测试 ───────────────────────────────────────────────────────────────

const TestLoader = struct {
    var next_id: u32 = 1;
    var load_calls: u32 = 0;
    var unloaded: [32]u32 = undefined;
    var unload_count: usize = 0;
    var fail_load: bool = false;

    fn reset() void {
        next_id = 1;
        load_calls = 0;
        unload_count = 0;
        fail_load = false;
    }

    fn load(_: ?*anyopaque, _: []const u8, _: u32, _: u32) anyerror!u32 {
        if (fail_load) return error.LoadFailed;
        load_calls += 1;
        const id = next_id;
        next_id += 1;
        return id;
    }

    fn unload(_: ?*anyopaque, texture_id: u32) void {
        if (unload_count < unloaded.len) {
            unloaded[unload_count] = texture_id;
            unload_count += 1;
        }
    }

    fn loader() SvgTextureLoader {
        return .{ .load_fn = load, .unload_fn = unload };
    }
};

const test_svg = "<svg><path d=\"M0 0 L10 10\"/></svg>";

test "没有 loader 时 load 明确报错，而不是静默成功" {
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.SvgTextureLoaderUnavailable, store.load(test_svg, 16, 16));
}

test "尺寸为 0 时拒绝栅格化" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());
    try std.testing.expectError(error.InvalidSvgRasterSize, store.load(test_svg, 0, 16));
    try std.testing.expectError(error.InvalidSvgRasterSize, store.load(test_svg, 16, 0));
    try std.testing.expectEqual(@as(u32, 0), TestLoader.load_calls);
}

test "同一张图同尺寸只栅格化一次；换尺寸重新栅格化" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    const a = try store.load(test_svg, 16, 16);
    const b = try store.load(test_svg, 16, 16);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(u32, 1), TestLoader.load_calls);

    const c = try store.load(test_svg, 32, 32);
    try std.testing.expect(c != a);
    try std.testing.expectEqual(@as(u32, 2), TestLoader.load_calls);
}

test "load 顺带登记命中几何" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    const id = try store.load(test_svg, 16, 16);
    const hit = store.lookupHit(id);
    try std.testing.expect(hit != null);
    try std.testing.expect(hit.?.commands.len > 0);
}

test "清缓存时通过 unload_fn 归还贴图" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    const id = try store.load(test_svg, 16, 16);
    store.clearTextureCache();
    try std.testing.expectEqual(@as(usize, 1), TestLoader.unload_count);
    try std.testing.expectEqual(id, TestLoader.unloaded[0]);
}

test "换 loader 先清旧缓存，避免新 loader 收到不属于它的 id" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    const id = try store.load(test_svg, 16, 16);
    store.setLoader(null); // 换 loader
    try std.testing.expectEqual(@as(usize, 1), TestLoader.unload_count);
    try std.testing.expectEqual(id, TestLoader.unloaded[0]);
    try std.testing.expectEqual(@as(u32, 0), store.texture_cache.count());
}

test "重复登记同一 texture_id 的命中几何不泄漏" {
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    // 第二次登记必须释放第一次的几何；泄漏会被 testing.allocator 抓到
    try store.registerHit(7, test_svg);
    try store.registerHit(7, "<svg><path d=\"M0 0 L20 20 L30 5\"/></svg>");
    try std.testing.expectEqual(@as(u32, 1), store.hit_shapes.count());
}

test "loader 失败时不写缓存也不留命中几何" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());
    TestLoader.fail_load = true;

    try std.testing.expectError(error.LoadFailed, store.load(test_svg, 16, 16));
    try std.testing.expectEqual(@as(u32, 0), store.texture_cache.count());
    try std.testing.expectEqual(@as(u32, 0), store.hit_shapes.count());
}

test "put 失败时不留下指向已卸载贴图的残留命中条目" {
    // glmx 交叉审查发现（2026-09-22，既有行为非重构引入）：
    // load() 的 errdefer 只把 texture_id 还给 loader，命中几何却留在
    // hit_shapes 里。loader 复用 id（它就是个 u32 句柄，复用完全合法）时，
    // 下一张 SVG 拿到同一 id 会命中上一张图的几何 —— 命中区域错位，不崩不报错。
    TestLoader.reset();

    // 让 texture_cache.put 的那次分配失败：前面的分配都放行，之后失败
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 5 });
    var store = SvgTextureStore.init(failing.allocator());
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    // fail_index=5 是实测选的：2..5 命中 texture_cache.put 那次分配，7+ 会在
    // 更早的分配就失败导致走不到断言。这里**直接断言 load 必须失败**而不是
    // 在成功时 SkipZigTest —— 若将来分配次数变了，这个测试要当场红，好过
    // 悄悄变成永远跳过的空壳。
    try std.testing.expectError(error.OutOfMemory, store.load(test_svg, 16, 16));

    // 失败后两张表必须一致：贴图已还给 loader，几何不得留下
    try std.testing.expect(TestLoader.unload_count >= 1);
    try std.testing.expectEqual(@as(u32, 0), store.hit_shapes.count());
    try std.testing.expectEqual(@as(u32, 0), store.texture_cache.count());
}
