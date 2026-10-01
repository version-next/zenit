//! font_registry.zig，进程级「字体族 id ↔ 族名」注册表 + 按需 face 缓存。
//!
//! == 为什么需要它 ==
//!
//! zenit 的字体决策原本只认 `(size, weight, italic, mono, symbols)`,
//! 整个 `FontSelector` 描述的是**一个**字体族。要让画布上不同对象用不同字体,
//! 就得给这套决策加一根 family 轴。
//!
//! 加轴有两种做法:
//!   A. 在 `TextProps` / `DisplayItem.text_run` / `TextFontProps` 里塞族名字符串
//!   B. 塞一个 u16 id,族名集中在本表
//!
//! 选 B。`text_run` 是**每帧重建**的高频结构,里面存 slice 意味着那块字节
//! 必须活过整帧，这正是本项目 setText 悬垂、on_cleanup UAF 的同一个形状。
//! u16 是自足的值,不指向任何地方,顺带还小 14 字节。
//!
//! == 与下游应用文档级 FontStore 的关系 ==
//!
//! 两张表,**故意不共用 id**:
//!   · 下游应用 `doc/font_store.zig` 是**文档级**的,随文档存盘,id 在文档内稳定;
//!   · 本表是**进程级**的,随进程生灭,给渲染管线用。
//! 宿主在投影时做一次 `文档 id -> 族名 -> 进程 id` 的翻译。
//! 这样文档不会被进程内的枚举顺序污染(换机器/装新字体就错位的那类坑)。
//!
//! == face 缓存 ==
//!
//! 每个 (family, size, weight, italic) 组合对应一个 `*Font`。
//! 实测冷启一个 face 0.28~4.87ms、warm 0.03ms(macOS 全局缓存 face),
//! 所以这里只做一层薄缓存避免重复 `findFont`,不做预热也不做淘汰
//! 字体族数量级是几十,不是几万。

const std = @import("std");
const text_module = @import("text");
const Font = text_module.Font;

/// 0 = 跟随 FontSelector 的默认族(即宿主启动时装的那套)。
pub const FamilyId = enum(u16) { default = 0, _ };

pub const NAME_CAP = 64;

const FaceKey = struct {
    family: u16,
    /// 字号量化到 0.25px，与 FontSelector 的 derived cache 同粒度,
    /// 避免浮点噪声把缓存打穿。
    size_q: u32,
    weight: u16,
    italic: bool,
};

const FaceCtx = struct {
    pub fn hash(_: FaceCtx, k: FaceKey) u64 {
        var h = std.hash.Wyhash.init(0xFACE);
        h.update(std.mem.asBytes(&k.family));
        h.update(std.mem.asBytes(&k.size_q));
        h.update(std.mem.asBytes(&k.weight));
        h.update(std.mem.asBytes(&k.italic));
        return h.final();
    }
    pub fn eql(_: FaceCtx, a: FaceKey, b: FaceKey) bool {
        return a.family == b.family and a.size_q == b.size_q and
            a.weight == b.weight and a.italic == b.italic;
    }
};

const Entry = struct {
    name: [NAME_CAP]u8 = [_]u8{0} ** NAME_CAP,
    len: u8 = 0,
    pub fn slice(self: *const Entry) []const u8 {
        return self.name[0..self.len];
    }
};

pub const FontRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    faces: std.HashMapUnmanaged(FaceKey, *Font, FaceCtx, 80) = .{},
    font_system: ?*text_module.FontSystem = null,
    /// 当前 HiDPI 缩放。**新建的 face 必须立刻套上它**,否则 2x 屏上
    /// 这些字体按 1x 光栅化，表现就是"别的文字清楚,字体选择器里糊"。
    /// FontSelector 的槽位由 App 统一 setScaleFactor,但本表的 face 是
    /// 独立创建的,不在那条链上,必须自己管。
    scale_factor: f32 = 1.0,

    pub fn init(allocator: std.mem.Allocator) FontRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FontRegistry) void {
        var it = self.faces.iterator();
        while (it.next()) |kv| kv.value_ptr.*.deinit();
        self.faces.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// 宿主启动时装一次。没装时 `resolve` 恒返 null(回退到默认族)。
    pub fn setFontSystem(self: *FontRegistry, fs: *text_module.FontSystem) void {
        self.font_system = fs;
    }

    /// 族名 -> 进程内 id。已存在则复用。空名字 = `.default`。
    pub fn intern(self: *FontRegistry, name: []const u8) !FamilyId {
        if (name.len == 0) return .default;
        for (self.entries.items, 0..) |*e, i| {
            if (std.mem.eql(u8, e.slice(), name)) return @enumFromInt(i + 1);
        }
        var e = Entry{};
        var n = @min(name.len, NAME_CAP);
        while (n > 0 and n < name.len and (name[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(e.name[0..n], name[0..n]);
        e.len = @intCast(n);
        try self.entries.append(self.allocator, e);
        return @enumFromInt(self.entries.items.len);
    }

    pub fn nameOf(self: *const FontRegistry, id: FamilyId) ?[]const u8 {
        const raw = @intFromEnum(id);
        if (raw == 0 or raw > self.entries.items.len) return null;
        return self.entries.items[raw - 1].slice();
    }

    /// 取 (family, size, weight, italic) 对应的 face。
    /// 返回 null = 用默认族(id 为 0 / 没装 FontSystem / 该族解析不出来)。
    /// 返回的 `*Font` 由本表持有,调用方**借用不释放**。
    pub fn resolve(
        self: *FontRegistry,
        family: FamilyId,
        size: f32,
        weight: u16,
        italic: bool,
    ) ?*Font {
        if (family == .default) return null;
        const fs = self.font_system orelse return null;
        const name = self.nameOf(family) orelse return null;

        const key = FaceKey{
            .family = @intFromEnum(family),
            .size_q = @intFromFloat(@round(@max(1.0, size) * 4.0)),
            .weight = weight,
            .italic = italic,
        };
        if (self.faces.get(key)) |f| return f;

        const desc = text_module.FontDescriptor{
            .family = name,
            .size = size,
            .weight = mapWeight(weight),
            .style = if (italic) .italic else .normal,
        };
        const font = fs.findFont(desc) catch return null;
        // ⚠ 必须在入缓存前套上当前 scale。漏了它 = 2x 屏上按 1x 光栅化,
        //   字形糊(与 FontSelector.setScaleFactor 注释里记的同一个症状)。
        font.setScaleFactor(self.scale_factor);
        self.faces.put(self.allocator, key, font) catch {
            font.deinit();
            return null;
        };
        return font;
    }

    /// 屏幕 DPI 变了(拖到另一块屏)。就地改所有 face 的 scale,
    /// 不清缓存:派生键与 scale 无关,真正按 scale 分桶的是下游
    /// glyph atlas 的 GlyphKey.scale_q(同 FontSelector.setScaleFactor)。
    pub fn setScaleFactor(self: *FontRegistry, scale: f32) void {
        if (self.scale_factor == scale) return;
        self.scale_factor = scale;
        var it = self.faces.valueIterator();
        while (it.next()) |f| f.*.setScaleFactor(scale);
    }

    fn mapWeight(w: u16) text_module.FontWeight {
        return if (w <= 100) .thin else if (w <= 300) .light else if (w <= 400) .regular else if (w <= 500) .medium else if (w <= 600) .semibold else if (w <= 700) .bold else if (w <= 800) .heavy else .black;
    }
};

test "intern 去重、id 从 1 起、default 为 0" {
    var r = FontRegistry.init(std.testing.allocator);
    defer r.deinit();

    try std.testing.expectEqual(FamilyId.default, try r.intern(""));
    const a = try r.intern("Zapfino");
    const b = try r.intern("Menlo");
    const a2 = try r.intern("Zapfino");

    try std.testing.expectEqual(a, a2);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(u16, 1), @intFromEnum(a));
    try std.testing.expectEqualStrings("Zapfino", r.nameOf(a).?);
    try std.testing.expect(r.nameOf(.default) == null);
    // 越界 id 不能返回别人的名字
    try std.testing.expect(r.nameOf(@enumFromInt(999)) == null);
}

test "没装 FontSystem 时 resolve 安全返回 null" {
    var r = FontRegistry.init(std.testing.allocator);
    defer r.deinit();
    const id = try r.intern("Zapfino");
    try std.testing.expect(r.resolve(id, 16, 400, false) == null);
    try std.testing.expect(r.resolve(.default, 16, 400, false) == null);
}
