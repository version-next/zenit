//! font_catalog.zig，系统字体目录（字体选择器的数据层）
//!
//! 职责：枚举系统已安装的字体家族，并为每个家族回答一个问题,
//! **「这一行该画什么，才能让用户看出这个字体长什么样？」**
//!
//! == 为什么这件事不是「把家族名用该字体画出来」那么简单 ==
//!
//! 本机实测（macOS，272 family / 990 face）：
//!   · **47 个家族（17%）渲染不了自己的名字**，阿拉伯/希伯来/天城文/
//!     CJK/缅甸/藏文… 它们的名字是拉丁字母，字体里却没有拉丁字形。
//!     直接用自身渲染 = 一片空白或豆腐块。
//!   · **9 个符号字体**（Wingdings/Webdings/Zapf Dingbats/…）更阴险：
//!     它们**有** 'A' 的字形，字形覆盖检查会「通过」，但画出来是图形。
//!     唯一可靠判据是 symbolic class。
//!
//! 所以 `previewPlan()` 把每个家族归到四条路线之一，实测 272 个家族
//! **100% 有解**（见 tests）：
//!
//!   1. `.self`，名字用字体自身渲染（拉丁字体，主流路线）
//!   2. `.glyph_sample`，符号字体：名字用 UI 字体，另附字形示例
//!                          （抄 CorelDRAW，是调研里唯一文档化此处理的一家）
//!   3. `.lang_sample`，非拉丁：名字用 UI 字体，另附该语言样例串
//!   4. `.codepoints`，兜底：从字体自己的 character set 取可渲染码点
//!                          （实测只有 Noto Sans Batak / Tagalog 落到这里）
//!
//! == 用法 ==
//! ```zig
//! var cat = try FontCatalog.scan(allocator);   // ~40ms，建议后台线程
//! defer cat.deinit();
//! for (cat.families) |fam| {
//!     switch (fam.previewPlan()) { ... }
//! }
//! ```
//!
//! 相关：字体族轴在 zenit 渲染管线里还不存在（TextProps / DisplayItem.text_run /
//! FontSelector 都没有 family 字段），这一层只负责**枚举与元数据**，
//! 不负责把字体接到渲染管线上。

const std = @import("std");
const builtin = @import("builtin");
const bridge = @import("coretext/coretext_bridge.zig");

pub const FamilyClass = bridge.FamilyClass;

/// 预览这一行时该画什么。
pub const PreviewPlan = union(enum) {
    /// 用字体自身渲染家族名。
    self,
    /// 符号字体：家族名走 UI 字体，另外用该字体画一小段字形示例。
    /// 附带的码点是从字体自身 character set 取的，保证画得出来。
    glyph_sample: []const u32,
    /// 非拉丁字体：家族名走 UI 字体，另附该语言的样例串（UTF-8）。
    lang_sample: []const u8,
    /// 最终兜底：家族名走 UI 字体，另附这些码点。
    codepoints: []const u32,
};

pub const Family = struct {
    /// 家族名，catalog 拥有。
    name: []const u8,
    is_symbolic: bool,
    can_render_name: bool,
    is_variable: bool,
    face_count: u16,
    class: FamilyClass,
    /// BCP-47 语言标签（如 "ar" / "zh-Hans"），空 = 未知。
    lang: []const u8,
    /// 有没有基本拉丁字形。false = 用它打英文得到空白/豆腐块。
    has_latin: bool,
    /// 兜底码点，仅在 lang 为空且需要样例时非空。
    sample_cps: []const u32,

    /// 这个字体**选了对普通文本有没有意义**。
    ///
    /// 全部 272 个家族在 CoreText 层面都能正常解析(实测 substituted=0),
    /// 所以没有"真的不可用"的字体。但两类选了会让用户困惑:
    ///   · 符号字体(9 个):打 "hello" 出来是一串图形;
    ///   · 无拉丁字形(43 个):打英文得到空白/豆腐块。
    /// 这两类在 UI 上给 disabled 视觉(仍可点，用户可能就是要打阿拉伯语),
    /// 属于**提示**而不是**禁止**。
    pub fn isUsableForLatinText(self: Family) bool {
        return self.has_latin and !self.is_symbolic;
    }

    /// 这一行该怎么画。判定顺序有讲究，见文件头注释。
    pub fn previewPlan(self: Family) PreviewPlan {
        // 符号字体优先：它 can_render_name 可能是 true，但那是假的。
        if (self.is_symbolic) return .{ .glyph_sample = self.sample_cps };
        if (self.can_render_name) return .self;
        if (sampleForLang(self.lang)) |s| return .{ .lang_sample = s };
        return .{ .codepoints = self.sample_cps };
    }
};

/// 语言标签 -> 该语言的短样例串。
///
/// 只覆盖实测中真正出现过的标签（macOS 上渲染不了自己名字的 47 个家族里，
/// 41 个能给出标签，分布：ar×20 he×5 my×2 bo×2 bgc×2 gu×2 zh/hy/kn/or/pa/
/// brx/nqo/syr 各 1）。命中不了就返回 null，走码点兜底，所以这张表
/// **不需要穷举世界上所有语言**，漏了也不会出现空白行。
fn sampleForLang(tag: []const u8) ?[]const u8 {
    if (tag.len == 0) return null;
    // 按主语言子标签比对（"zh-Hans" -> "zh"）。
    const primary = blk: {
        const dash = std.mem.indexOfScalar(u8, tag, '-') orelse break :blk tag;
        break :blk tag[0..dash];
    };
    const table = [_]struct { tag: []const u8, sample: []const u8 }{
        .{ .tag = "ar", .sample = "أبجد هوز" },
        .{ .tag = "he", .sample = "אבגד הוז" },
        .{ .tag = "fa", .sample = "الفبا" },
        .{ .tag = "ur", .sample = "الف بے" },
        .{ .tag = "syr", .sample = "ܐܒܓܕ" },
        .{ .tag = "nqo", .sample = "ߒߞߏ" },
        .{ .tag = "hi", .sample = "अआइई" },
        .{ .tag = "brx", .sample = "अआइई" },
        .{ .tag = "bgc", .sample = "अआइई" },
        .{ .tag = "mr", .sample = "अआइई" },
        .{ .tag = "ne", .sample = "अआइई" },
        .{ .tag = "kok", .sample = "अआइई" },
        .{ .tag = "gu", .sample = "અઆઇઈ" },
        .{ .tag = "pa", .sample = "ਅਆਇਈ" },
        .{ .tag = "bn", .sample = "অআইঈ" },
        .{ .tag = "or", .sample = "ଅଆଇଈ" },
        .{ .tag = "ta", .sample = "அஆஇஈ" },
        .{ .tag = "te", .sample = "అఆఇఈ" },
        .{ .tag = "kn", .sample = "ಅಆಇಈ" },
        .{ .tag = "ml", .sample = "അആഇഈ" },
        .{ .tag = "si", .sample = "අආඇඈ" },
        .{ .tag = "th", .sample = "กขคง" },
        .{ .tag = "lo", .sample = "ກຂຄງ" },
        .{ .tag = "my", .sample = "ကခဂဃ" },
        .{ .tag = "km", .sample = "កខគឃ" },
        .{ .tag = "bo", .sample = "ཀཁགང" },
        .{ .tag = "hy", .sample = "ԱԲԳԴ" },
        .{ .tag = "ka", .sample = "აბგდ" },
        .{ .tag = "am", .sample = "አለሐመ" },
        .{ .tag = "chr", .sample = "ᏣᎳᎩ" },
        .{ .tag = "iu", .sample = "ᐊᐃᐅ" },
        .{ .tag = "zh", .sample = "字体预览" },
        .{ .tag = "ja", .sample = "字体サンプル" },
        .{ .tag = "ko", .sample = "글꼴 견본" },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.tag, primary)) return e.sample;
    }
    return null;
}

pub const FontCatalog = struct {
    allocator: std.mem.Allocator,
    families: []Family,
    /// 所有家族名/码点的实际存储，统一释放。
    arena: std.heap.ArenaAllocator,

    /// 扫描系统字体。实测 ~40ms（272 family），**建议后台线程调用**。
    ///
    /// 非 macOS 返回空目录，枚举桥只在 CoreText 后端有实现。
    pub fn scan(allocator: std.mem.Allocator) !FontCatalog {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        if (builtin.target.os.tag != .macos) {
            return .{
                .allocator = allocator,
                .families = &.{},
                .arena = arena,
            };
        }

        const a = arena.allocator();
        const total = bridge.coretext_family_count();
        if (total <= 0) {
            return .{ .allocator = allocator, .families = &.{}, .arena = arena };
        }
        const count: usize = @intCast(total);

        // C 侧 strdup 出来的裸指针，逐条 copy 进 arena 后立刻释放。
        const raw = try allocator.alloc(?[*:0]u8, count);
        defer allocator.free(raw);
        @memset(raw, null);
        const got = bridge.coretext_copy_family_names(raw.ptr, @intCast(count));
        defer for (raw[0..@intCast(got)]) |p| {
            if (p) |nn| bridge.coretext_free_c_string(nn);
        };

        var list = try std.ArrayList(Family).initCapacity(a, @intCast(got));

        var i: usize = 0;
        while (i < @as(usize, @intCast(got))) : (i += 1) {
            const cname = raw[i] orelse continue;

            var info: bridge.CoreTextFamilyInfo = undefined;
            if (bridge.coretext_family_info(cname, &info) != 0) continue;
            // descriptor 查不到 face 的（如 SF Pro）不进列表，选中了也用不了。
            if (info.face_count == 0) continue;

            const name = try a.dupe(u8, std.mem.span(cname));

            const lang_len = std.mem.indexOfScalar(u8, &info.lang, 0) orelse info.lang.len;
            const lang = try a.dupe(u8, info.lang[0..lang_len]);

            const is_symbolic = info.is_symbolic != 0;
            const can_render = info.can_render_name != 0;

            // 只有真正需要样例的行才去取码点（多一次 CoreText 往返）。
            var cps: []const u32 = &.{};
            const needs_sample = is_symbolic or !can_render;
            if (needs_sample) {
                var buf: [8]u32 = undefined;
                const n = bridge.coretext_family_sample_codepoints(cname, &buf, buf.len);
                if (n > 0) cps = try a.dupe(u32, buf[0..@intCast(n)]);
            }

            try list.append(a, .{
                .name = name,
                .is_symbolic = is_symbolic,
                .can_render_name = can_render,
                .is_variable = info.is_variable != 0,
                .face_count = @intCast(@min(info.face_count, std.math.maxInt(u16))),
                .class = @enumFromInt(info.classification),
                .lang = lang,
                .has_latin = info.has_latin != 0,
                .sample_cps = cps,
            });
        }

        const families = try list.toOwnedSlice(a);
        std.mem.sort(Family, families, {}, struct {
            fn lt(_: void, x: Family, y: Family) bool {
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.lt);

        return .{ .allocator = allocator, .families = families, .arena = arena };
    }

    pub fn deinit(self: *FontCatalog) void {
        self.arena.deinit();
        self.families = &.{};
    }

    pub fn find(self: *const FontCatalog, name: []const u8) ?*const Family {
        for (self.families) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

/// 用户存盘的字体名是否**真的**能解析回同一个字体。
///
/// ⚠ 必须用它，不能只看 `coretext_find_font` 是否返回非 null,
/// 那个函数对不存在的家族会静默返回一个替身，于是「字体丢失」会
/// 伪装成「字体正常」，用户看到的是另一个字体却没有任何提示。
pub fn familyExists(name: [:0]const u8) bool {
    if (builtin.target.os.tag != .macos) return false;
    return bridge.coretext_family_exists(name.ptr) != 0;
}

/// 一个家族最多回报多少个字重档位。
/// 实测最宽的 Helvetica Neue 是 14 个 face / 7 个去重字重；
/// 可变字体按 100~900 铺满也只有 9 个。16 给足余量。
pub const MAX_WEIGHTS: usize = 16;

/// 标准字重档位的显示名（CSS 数值 -> UI 文案）。
/// 与 CoreText 的 style name 不同：CT 给的是"Demi Bold"/"Heavy"这类
/// **家族自定名**，同一个 600 在不同家族叫法不一。下拉要的是统一刻度。
pub fn weightLabel(css: u16) []const u8 {
    return switch (css) {
        100 => "Thin",
        200 => "Extra Light",
        300 => "Light",
        400 => "Regular",
        500 => "Medium",
        600 => "Semibold",
        700 => "Bold",
        800 => "Extra Bold",
        900 => "Black",
        else => "Regular",
    };
}

/// 该家族**实际可用**的字重档位（CSS 100~900，升序去重）。
///
/// ⚠ 必须用它来生成字重下拉，不能挂一张固定的 100~900 列表,
/// CoreText 对拿不到的字重**静默降级且不报错**：实测 Zapfino 只有一个
/// face，问它要 Bold 会安静地返回 Regular；Menlo 要 Light 同样回 Regular。
/// 给出字体没有的档位 = 用户选了画面纹丝不动，且没有任何失败信号。
///
/// 非 macOS 与查不到 face 的家族一律回退成单档 400，空列表会让
/// 下拉变成一个点不开的死控件。
pub fn familyWeights(name: [:0]const u8, out: []u16) usize {
    if (out.len == 0) return 0;
    if (builtin.target.os.tag != .macos) {
        out[0] = 400;
        return 1;
    }
    var raw: [MAX_WEIGHTS]c_int = undefined;
    const cap: c_int = @intCast(@min(out.len, MAX_WEIGHTS));
    const n = bridge.coretext_family_weights(name.ptr, &raw, cap);
    if (n <= 0) {
        out[0] = 400;
        return 1;
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(n)) and i < out.len) : (i += 1) {
        out[i] = @intCast(@max(100, @min(900, raw[i])));
    }
    return i;
}

// ===========================================================================
// tests
//
// 这些断言钉的是**本机实测基线**（见下游应用侧调研文档）。
// 换一台机器装了不同字体，数字会变，所以断言写成「结构性不变量」
// （每个家族都有解、符号字体不为零…），而不是硬编码 272/9/47。
// ===========================================================================

test "CoreTextFamilyInfo 的 Zig 声明与 C 侧布局一致" {
    // ⚠ 这个结构体跨语言共享,字段顺序/数量必须逐位对齐。
    // 我改过一次:Zig 侧加了 has_latin、C 侧的 patch 却因为脚本断言失败
    // 没落盘，编译**照样通过**,但 lang 会读到错位的字节。
    // 这条测试钉住大小与关键字段偏移,ABI 一旦漂移立刻红。
    const I = bridge.CoreTextFamilyInfo;
    // 6 个 c_int(is_symbolic/can_render_name/is_variable/face_count/
    // classification/has_latin) + char[16]。
    try std.testing.expectEqual(@as(usize, 6 * @sizeOf(c_int) + 16), @sizeOf(I));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(I, "is_symbolic"));
    try std.testing.expectEqual(@as(usize, 6 * @sizeOf(c_int)), @offsetOf(I, "lang"));

    // 真实调用一次:lang 必须是合法 UTF-8 且 NUL 结尾内(错位会读出乱码)。
    if (builtin.target.os.tag != .macos) return;
    var info: I = undefined;
    if (bridge.coretext_family_info("PingFang SC", &info) == 0) {
        const n = std.mem.indexOfScalar(u8, &info.lang, 0) orelse info.lang.len;
        try std.testing.expect(std.unicode.utf8ValidateSlice(info.lang[0..n]));
        try std.testing.expect(info.has_latin == 0 or info.has_latin == 1);
    }
}

test "catalog: 每个家族都能给出可渲染的预览内容" {
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();

    try std.testing.expect(cat.families.len > 0);

    for (cat.families) |fam| {
        switch (fam.previewPlan()) {
            .self => try std.testing.expect(fam.can_render_name and !fam.is_symbolic),
            // 三条兜底路线都必须真的带上内容，否则那一行会是空白。
            .glyph_sample => |cps| try std.testing.expect(cps.len > 0),
            .lang_sample => |s| try std.testing.expect(s.len > 0),
            .codepoints => |cps| try std.testing.expect(cps.len > 0),
        }
    }
}

test "catalog: 符号字体走 glyph_sample 而不是 self" {
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();

    // Wingdings 的 can_render_name 实测是 true（它有 'A' 的字形，
    // 只不过画出来是图形），如果 previewPlan 的判定顺序被人调换，
    // 这条会立刻红。这正是本测试存在的理由。
    if (cat.find("Wingdings")) |w| {
        try std.testing.expect(w.is_symbolic);
        try std.testing.expect(w.previewPlan() == .glyph_sample);
    }
}

test "catalog: 非拉丁字体不走 self" {
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();

    for ([_][]const u8{ "Geeza Pro", "Arial Hebrew" }) |n| {
        if (cat.find(n)) |f| {
            try std.testing.expect(!f.can_render_name);
            try std.testing.expect(f.previewPlan() != .self);
        }
    }
}

test "catalog: 列表里没有 face_count == 0 的死项" {
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();
    for (cat.families) |f| try std.testing.expect(f.face_count > 0);
    // SF Pro 实测 descriptor 查不到 face，必须已被过滤。
    try std.testing.expect(cat.find("SF Pro") == null);
}

test "familyExists: 不存在的家族不能伪装成存在" {
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(familyExists("Helvetica Neue"));
    try std.testing.expect(!familyExists("NoSuchFontXYZ__"));
}

test "sampleForLang: 主子标签匹配" {
    try std.testing.expect(sampleForLang("zh-Hans") != null);
    try std.testing.expect(sampleForLang("ar") != null);
    try std.testing.expect(sampleForLang("") == null);
    try std.testing.expect(sampleForLang("xx-nonesuch") == null);
}

test "familyWeights: 每个家族至少一档，升序去重，落在 100~900" {
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    var cat = try FontCatalog.scan(std.testing.allocator);
    defer cat.deinit();

    var buf: [MAX_WEIGHTS]u16 = undefined;
    var name_buf: [128]u8 = undefined;
    var checked: usize = 0;
    for (cat.families) |f| {
        if (f.name.len + 1 > name_buf.len) continue;
        @memcpy(name_buf[0..f.name.len], f.name);
        name_buf[f.name.len] = 0;
        const z: [:0]const u8 = name_buf[0..f.name.len :0];

        const n = familyWeights(z, &buf);
        // 空列表 = 下拉是个点不开的死控件,必须至少回退一档。
        try std.testing.expect(n >= 1);
        var prev: u16 = 0;
        for (buf[0..n]) |w| {
            try std.testing.expect(w >= 100 and w <= 900);
            try std.testing.expect(w > prev); // 升序且严格去重
            prev = w;
        }
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}

test "familyWeights: 单 face 家族只给一档（不谎报字体没有的字重）" {
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    // Zapfino 实测只有 1 个 face。CoreText 对它要 Bold 会静默返回 Regular,
    // 所以下拉里绝不能出现 Bold，这条就是钉住"不谎报"。
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (!familyExists("Zapfino")) return error.SkipZigTest;
    var buf: [MAX_WEIGHTS]u16 = undefined;
    const n = familyWeights("Zapfino", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 400), buf[0]);
}

test "familyWeights: 多 face 家族给出多档且含 Regular/Bold" {
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (!familyExists("Helvetica Neue")) return error.SkipZigTest;
    var buf: [MAX_WEIGHTS]u16 = undefined;
    const n = familyWeights("Helvetica Neue", &buf);
    try std.testing.expect(n >= 4); // 实测 7 档
    var has400 = false;
    var has700 = false;
    for (buf[0..n]) |w| {
        if (w == 400) has400 = true;
        if (w == 700) has700 = true;
    }
    try std.testing.expect(has400);
    try std.testing.expect(has700);
}

test "weightLabel 覆盖全部标准档位" {
    try std.testing.expectEqualStrings("Regular", weightLabel(400));
    try std.testing.expectEqualStrings("Bold", weightLabel(700));
    try std.testing.expectEqualStrings("Black", weightLabel(900));
    // 非标准值不能返回空串（UI 会显示成空白行）
    try std.testing.expect(weightLabel(450).len > 0);
}
