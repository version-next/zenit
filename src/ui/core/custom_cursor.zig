//! 自定义位图光标存储，从 `Cx` 析出。
//!
//! 原本是 `Cx` 上的四个字段（custom_cursors / active_custom_cursor /
//! current_custom_key / custom_cursor_fallback）加两个方法，依赖只有
//! `allocator` 与 SVG 光栅化。下发到系统那一步需要 `system_sdk` / `window_id`，
//! 那是 `Cx.updateCursorShape` 的职责，接口因此切在：
//!
//!   **store 负责「把 desc 光栅化成位图并按内容寻址缓存」，下发留在 Cx。**
//!
//! 搬出来之后，预乘 alpha、内容寻址键、同 key 幂等、光栅化失败/插入失败的
//! 清理，全都可以脱离 SystemSdk mock 单测。

const std = @import("std");
const types = @import("types.zig");

const CursorShape = types.CursorShape;

/// 宿主提交的自定义光标描述（输入）。
pub const CustomCursorDesc = struct {
    svg_data: []const u8,
    size_pt: f32,
    scale: f32 = 2.0,
    hot_x: f32 = 0,
    hot_y: f32 = 0,

    /// 内容寻址键：同 SVG + 同参数 ⇒ 同位图。native 侧也以此键缓存光标对象。
    pub fn contentKey(self: CustomCursorDesc) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(self.svg_data);
        const params = [_]f32{ self.size_pt, self.scale, self.hot_x, self.hot_y };
        h.update(std.mem.asBytes(&params));
        return h.final();
    }
};

/// 已光栅化的自定义光标位图（预乘 RGBA）。hot 为像素坐标（左上原点）。
pub const CustomCursorEntry = struct {
    width: u32,
    height: u32,
    scale: f32,
    hot_x: f32,
    hot_y: f32,
    pixels: []u8,
};

/// svg.rasterize 输出 straight-alpha RGBA；位图光标走 CGBitmapContext 的
/// kCGImageAlphaPremultipliedLast，拷入前原地预乘。
pub fn premultiplyRgbaInPlace(pixels: []u8) void {
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const a: u16 = pixels[i + 3];
        pixels[i + 0] = @intCast((@as(u16, pixels[i + 0]) * a + 127) / 255);
        pixels[i + 1] = @intCast((@as(u16, pixels[i + 1]) * a + 127) / 255);
        pixels[i + 2] = @intCast((@as(u16, pixels[i + 2]) * a + 127) / 255);
    }
}

pub const CustomCursorStore = struct {
    entries: std.AutoHashMapUnmanaged(u64, CustomCursorEntry) = .{},
    /// 当前被选中的自定义光标（还没必然下发到系统）。
    active: ?u64 = null,
    /// 已下发到系统的 key。幂等判据是「shape 相同**且** key 相同」,
    /// shape 停在 `.custom` 期间换位图内容也必须重新下发。
    submitted: ?u64 = null,
    /// 后端不支持位图光标（或未注册位图）时 `.custom` 的降级形状。
    /// 默认 crosshair：自定义光标的典型用途是精确绘制工具。
    fallback: CursorShape = .crosshair,

    pub fn deinit(self: *CustomCursorStore, allocator: std.mem.Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.pixels);
        self.entries.deinit(allocator);
    }

    /// 光栅化产物（与 `svg.rasterize` 的返回形状一致，但本模块不 import svg：
    /// 光栅化函数由调用方注入，store 因此可以脱离 SVG 管线独立单测）。
    pub const Raster = struct { width: u32, height: u32, pixels: []u8 };
    pub const RasterizeFn = *const fn (
        allocator: std.mem.Allocator,
        svg_data: []const u8,
        target_width: u32,
    ) anyerror!Raster;

    /// 光栅化并登记一个自定义光标，随后把它设为 active。
    ///
    /// 失败（光栅化失败 / 插入失败）时静默保持原状：光标只是观感，拿不到
    /// 位图就继续用当前光标，不该让宿主崩。同 key 重复提交是 no-op。
    pub fn set(
        self: *CustomCursorStore,
        allocator: std.mem.Allocator,
        desc: CustomCursorDesc,
        rasterize: RasterizeFn,
    ) void {
        const key = desc.contentKey();
        if (self.active == key) return;
        if (!self.entries.contains(key)) {
            const w_px: u32 = @intFromFloat(@max(1.0, @round(desc.size_pt * desc.scale)));
            const img = rasterize(allocator, desc.svg_data, w_px) catch return;
            premultiplyRgbaInPlace(img.pixels);
            self.entries.put(allocator, key, .{
                .width = img.width,
                .height = img.height,
                .scale = desc.scale,
                .hot_x = desc.hot_x * desc.scale,
                .hot_y = desc.hot_y * desc.scale,
                .pixels = img.pixels,
            }) catch {
                allocator.free(img.pixels);
                return;
            };
        }
        self.active = key;
    }

    pub fn activeKey(self: *const CustomCursorStore) ?u64 {
        return self.active;
    }

    /// 取 active 对应的位图；没有 active 或位图未登记时返回 null
    /// （调用方应当降级到 `fallback`）。
    pub fn activeEntry(self: *const CustomCursorStore) ?CustomCursorEntry {
        const key = self.active orelse return null;
        return self.entries.get(key);
    }
};

// ── 测试 ───────────────────────────────────────────────────────────────

const tiny_svg = "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0 L8 0 L8 8 Z\" fill=\"#ff0000\"/></svg>";

/// 假光栅化器：产出全不透明的 w×w RGBA。注入它之后，这组测试完全不依赖
/// 真实 SVG 管线，这正是把 rasterize 做成参数的收益。
fn fakeRasterize(allocator: std.mem.Allocator, svg_data: []const u8, target_width: u32) anyerror!CustomCursorStore.Raster {
    if (std.mem.eql(u8, svg_data, "FAIL")) return error.RasterizeFailed;
    const w = @max(target_width, 1);
    const px = try allocator.alloc(u8, w * w * 4);
    @memset(px, 255);
    return .{ .width = w, .height = w, .pixels = px };
}

test "premultiplyRgbaInPlace: alpha 全不透明时像素不变" {
    var px = [_]u8{ 200, 100, 50, 255 };
    premultiplyRgbaInPlace(&px);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 200, 100, 50, 255 }, &px);
}

test "premultiplyRgbaInPlace: alpha 全透明时 RGB 归零" {
    var px = [_]u8{ 200, 100, 50, 0 };
    premultiplyRgbaInPlace(&px);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &px);
}

test "premultiplyRgbaInPlace: 半透明按 round 而非截断" {
    // 200 * 128 / 255 = 100.4；加 127 再整除 = 100（四舍五入）
    var px = [_]u8{ 200, 200, 200, 128 };
    premultiplyRgbaInPlace(&px);
    try std.testing.expectEqual(@as(u8, 100), px[0]);
    try std.testing.expectEqual(@as(u8, 128), px[3]);
}

test "premultiplyRgbaInPlace: 尾部不足 4 字节不越界" {
    var px = [_]u8{ 10, 20, 30 }; // 只有 3 字节
    premultiplyRgbaInPlace(&px);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30 }, &px);
}

test "contentKey: 同内容同参数得同键，任一参数变则换键" {
    const base = CustomCursorDesc{ .svg_data = tiny_svg, .size_pt = 16 };
    try std.testing.expectEqual(base.contentKey(), base.contentKey());

    var other = base;
    other.size_pt = 24;
    try std.testing.expect(base.contentKey() != other.contentKey());

    other = base;
    other.scale = 1.0;
    try std.testing.expect(base.contentKey() != other.contentKey());

    other = base;
    other.hot_x = 3;
    try std.testing.expect(base.contentKey() != other.contentKey());

    other = base;
    other.svg_data = "<svg viewBox=\"0 0 8 8\"></svg>";
    try std.testing.expect(base.contentKey() != other.contentKey());
}

test "store: 登记后 active 指向该位图，重复提交是 no-op" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);

    const desc = CustomCursorDesc{ .svg_data = tiny_svg, .size_pt = 16 };
    store.set(alloc, desc, fakeRasterize);
    try std.testing.expectEqual(@as(?u64, desc.contentKey()), store.activeKey());
    try std.testing.expectEqual(@as(u32, 1), store.entries.count());

    // 同 desc 再来一次：不应重复光栅化
    store.set(alloc, desc, fakeRasterize);
    try std.testing.expectEqual(@as(u32, 1), store.entries.count());
}

test "store: 换参数产出第二个条目，两者共存" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);

    store.set(alloc, .{ .svg_data = tiny_svg, .size_pt = 16 }, fakeRasterize);
    store.set(alloc, .{ .svg_data = tiny_svg, .size_pt = 32 }, fakeRasterize);
    try std.testing.expectEqual(@as(u32, 2), store.entries.count());
}

test "store: 光栅化失败时保持原状而不是崩" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);

    store.set(alloc, .{ .svg_data = "FAIL", .size_pt = 16 }, fakeRasterize);
    // 失败路径：不登记、不设 active
    try std.testing.expectEqual(@as(u32, 0), store.entries.count());
    try std.testing.expectEqual(@as(?u64, null), store.activeKey());
}

test "store: activeEntry 在无 active 时返回 null" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(?CustomCursorEntry, null), store.activeEntry());

    store.set(alloc, .{ .svg_data = tiny_svg, .size_pt = 16 }, fakeRasterize);
    const e = store.activeEntry();
    try std.testing.expect(e != null);
    try std.testing.expect(e.?.pixels.len > 0);
}

test "store: hot 点按 scale 换算成像素坐标" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);

    store.set(alloc, .{ .svg_data = tiny_svg, .size_pt = 16, .scale = 2.0, .hot_x = 3, .hot_y = 4 }, fakeRasterize);
    const e = store.activeEntry().?;
    try std.testing.expectEqual(@as(f32, 6), e.hot_x);
    try std.testing.expectEqual(@as(f32, 8), e.hot_y);
}
