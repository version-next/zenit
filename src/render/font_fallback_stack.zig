//! font_fallback_stack.zig, CSS font-family 式的显式字体回退栈
//!
//! == 为什么需要它（背景是一场真实事故）==
//! 此前 CJK 字形全靠 CoreText 的 run 级联 fallback：主字体（Inter/Lora 等
//! 全拉丁字体）shape 不出的码点由 CoreText 现场级联到系统字体。三个结构性问题：
//!   1. run 级 fallback 的 CTFontRef **不是稳定实例**, wrapper 曾用指针作
//!      缓存键，同一字形被当成无数"新字体"重复收录，glyph atlas 32 页耗尽、
//!      大规模丢字（见 text_renderer.getOrCreateGlyphFallbackFont 的注释）。
//!      identity hash 修掉了键，但 fallback 本身仍不可控。
//!   2. 级联选择不可控：hint 想要 PingFang SC，CoreText 实际可能给
//!      `.AppleSystemUIFont`。
//!   3. 每个 CJK 字形都走慢路径（run 级 fallback 解析 + wrapper 查找），
//!      ASCII 一步命中。
//!
//! == 语义 ==
//! 应用声明一个**有序**字体族栈（如 ["Inter", "PingFang SC"]）。运行期
//! FontSelector 选出的主字体是栈的**隐式首位**（判「primary 是否覆盖该码点」
//! 的职责在渲染器 TextRenderer.selectSegmentFont，不在本结构）；本结构管理
//! 首位之后的回退族。shaping 前按段首码点显式选族：第一个 cmap 覆盖该码点
//! 的族胜出，从族内按（字号优先、字重档最近）取一个**我们自己持有**的
//! *Font 直接 shape，字体选择确定、CTFont 指针稳定、跳过级联开销。
//! 栈内无族覆盖的码点（emoji、罕见符号）仍交 CoreText 级联兜底。
//!
//! == per-OS 系统兜底 ==
//! defaultSystemFamilyName() 按目标 OS 给出默认系统 CJK 族名（macOS =
//! PingFang SC）。字体**加载**仍由应用完成（应用才知道自己的 FontManager 与
//! 字号表），本模块只提供"该平台默认该用谁"这一决策。
//!
//! == 脚本优先级 ==
//! 纯覆盖優先会踩中「PingFang 也覆盖部分谚文」一类的陷阱：韩文文本必须优先
//! 用韩文字体（Hangul glyph 风格与中文字体不一致）。族可声明 priority
//! （hangul / han_kana），同类脚本的码点先在声明了该优先级的族里找，
//! 找不到再按栈序做纯覆盖遍历，与 script_detect 的既有语义按码点对齐。

const std = @import("std");
const builtin = @import("builtin");
const text_module = @import("text");
const Font = text_module.Font;

/// 各 OS 的默认系统 CJK 兜底族名。null = 该平台未定义（应用自行决定或
/// 交平台级联）。本项目当前 macOS-only，其他平台在此处补名字即可接入：
///   .windows -> "Microsoft YaHei"、.linux -> "Noto Sans CJK SC"（未验证，
///   接入时以目标发行版实测为准）。
pub fn defaultSystemFamilyName() ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => "PingFang SC",
        else => null,
    };
}

/// 码点脚本分类，只区分「回退策略不同」的三类。
/// 范围与 command_encoder/script_detect.zig 的判定语义对齐（那边按整段文本
/// 回答"要不要回退"，这边按单码点回答"优先找哪类族"）。
pub const ScriptClass = enum { hangul, han_kana, other };

pub fn classifyCodepoint(cp: u21) ScriptClass {
    // Hangul 优先判：3130-318F（Compatibility Jamo）落在下面 han_kana 的
    // 大区间边上，必须先拦。
    if ((cp >= 0x1100 and cp <= 0x11FF) or // Hangul Jamo
        (cp >= 0x3130 and cp <= 0x318F) or // Hangul Compatibility Jamo
        (cp >= 0xAC00 and cp <= 0xD7AF)) return .hangul; // Hangul Syllables
    if ((cp >= 0x2E80 and cp <= 0x2FDF) or // CJK/Kangxi Radicals
        (cp >= 0x3000 and cp <= 0x312F) or // CJK Symbols + Kana + Bopomofo
        (cp >= 0x31A0 and cp <= 0x33FF) or // Bopomofo Ext + Kana Ext + Enclosed + Compat
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK Compatibility Forms
        (cp >= 0xFF00 and cp <= 0xFFEF) or // Halfwidth and Fullwidth Forms
        (cp >= 0x20000 and cp <= 0x2FA1F)) return .han_kana; // Ext B..Compat Supplement
    return .other;
}

/// PingFang 一类**固定字重档**字体的最近档映射：
/// 400->Regular、500->Medium、600+->Semibold。
/// （可变字体如 Inter 用不到这条，它们在 FontSelector 侧按精确字重加载。）
pub fn archiveWeight(weight: u16) u16 {
    return if (weight >= 600) 600 else if (weight >= 500) 500 else 400;
}

pub const FontFallbackStack = struct {
    pub const MAX_FAMILIES = 4;
    pub const MAX_FONTS_PER_FAMILY = 40;
    /// coverage 缓存容量上限。码点空间有限（一份文档的字表通常几千），
    /// 撞顶只可能是恶意/极端输入，直接清空重来，不做精细淘汰。
    const COVERAGE_CACHE_MAX = 16384;

    pub const Priority = enum { none, han_kana, hangul };

    pub const Family = struct {
        /// 族名（诊断用；不参与运行期匹配）。指向的内存须比 stack 活得久
        /// （字符串常量即可）。
        name: []const u8,
        priority: Priority = .none,
        /// 该族已加载的字号/字重档位。*Font 由应用持有，本结构只借用。
        fonts: [MAX_FONTS_PER_FAMILY]?*Font = [_]?*Font{null} ** MAX_FONTS_PER_FAMILY,
        count: u8 = 0,
    };

    families: [MAX_FAMILIES]Family = undefined,
    family_count: u8 = 0,
    /// cp -> 命中的族下标 + 1；0 = 栈内无族覆盖（级联兜底）。
    /// cmap 覆盖与字号/字重无关，所以键只需码点本身。
    coverage_cache: std.AutoHashMap(u21, u8),

    pub fn init(allocator: std.mem.Allocator) FontFallbackStack {
        return .{ .coverage_cache = std.AutoHashMap(u21, u8).init(allocator) };
    }

    /// 只释放自身缓存；*Font 归应用，不 deinit。
    pub fn deinit(self: *FontFallbackStack) void {
        self.coverage_cache.deinit();
    }

    /// 追加一个族到栈尾。返回族下标；栈满返回 null。
    pub fn addFamily(self: *FontFallbackStack, name: []const u8, priority: Priority) ?u8 {
        if (self.family_count >= MAX_FAMILIES) return null;
        const idx = self.family_count;
        self.families[idx] = .{ .name = name, .priority = priority };
        self.family_count = idx + 1;
        // 族集合变化 = 覆盖答案可能变化。
        self.coverage_cache.clearRetainingCapacity();
        return idx;
    }

    /// 向族内追加一个已加载档位（与 font_compat.addToGroup 同款：满了静默丢弃，
    /// 选择逻辑会就近命中已有档位）。
    pub fn addFont(self: *FontFallbackStack, family_idx: u8, font: *Font) void {
        if (family_idx >= self.family_count) return;
        const fam = &self.families[family_idx];
        if (fam.count >= MAX_FONTS_PER_FAMILY) return;
        fam.fonts[fam.count] = font;
        fam.count += 1;
    }

    /// 显式选字体：cp -> 覆盖它的族（脚本优先 + 栈序）-> 族内最近档。
    /// null = 栈内无族覆盖，调用方交 CoreText 级联兜底。
    pub fn selectForCodepoint(self: *FontFallbackStack, cp: u21, size: f32, weight: u16) ?*Font {
        const fam_idx = self.familyForCodepoint(cp) orelse return null;
        return selectFromFamily(&self.families[fam_idx], size, weight);
    }

    fn familyForCodepoint(self: *FontFallbackStack, cp: u21) ?u8 {
        if (self.family_count == 0) return null;
        if (self.coverage_cache.get(cp)) |v| {
            return if (v == 0) null else v - 1;
        }
        var chosen: u8 = 0;
        const cls = classifyCodepoint(cp);
        found: {
            // 第一遍：该脚本的优先族（韩文码点先问韩文族，即使中文族也覆盖）。
            if (cls != .other) {
                const want: Priority = if (cls == .hangul) .hangul else .han_kana;
                for (self.families[0..self.family_count], 0..) |*fam, i| {
                    if (fam.priority == want and familyCovers(fam, cp)) {
                        chosen = @as(u8, @intCast(i)) + 1;
                        break :found;
                    }
                }
            }
            // 第二遍：按栈序纯覆盖。
            for (self.families[0..self.family_count], 0..) |*fam, i| {
                if (familyCovers(fam, cp)) {
                    chosen = @as(u8, @intCast(i)) + 1;
                    break :found;
                }
            }
        }
        if (self.coverage_cache.count() >= COVERAGE_CACHE_MAX) {
            self.coverage_cache.clearRetainingCapacity();
        }
        self.coverage_cache.put(cp, chosen) catch {};
        return if (chosen == 0) null else chosen - 1;
    }

    fn familyCovers(fam: *const Family, cp: u21) bool {
        // cmap 与字号无关：用首个档位探测即可。
        const probe = fam.fonts[0] orelse return false;
        return probe.glyphIndexForCodepoint(cp) != 0;
    }

    /// 族内选档：**字号优先**（沿用 FontSelector.selectFromGroup 的语义,
    /// 应用可能故意让某个字号档用不同字重，如 14px 正文用 Medium 提亮 CJK，
    /// 字重优先会打翻这类设计），字号并列时取距目标**档位字重**最近的；
    /// 档距再并列时，粗体请求（≥600）取更粗、其余取更细（CSS font-weight
    /// 匹配方向的简化版）。
    fn selectFromFamily(fam: *const Family, size: f32, weight: u16) ?*Font {
        const size_epsilon: f32 = 0.01;
        const target_w = archiveWeight(weight);
        var best: ?*Font = null;
        var best_size_diff: f32 = std.math.inf(f32);
        var best_w_diff: u16 = std.math.maxInt(u16);
        for (fam.fonts[0..fam.count]) |maybe_font| {
            const font = maybe_font orelse continue;
            const size_diff = @abs(font.pixelSize() - size);
            const w_diff = if (font.weight >= target_w) font.weight - target_w else target_w - font.weight;
            const better = blk: {
                if (best == null) break :blk true;
                if (size_diff + size_epsilon < best_size_diff) break :blk true;
                if (size_diff > best_size_diff + size_epsilon) break :blk false;
                if (w_diff != best_w_diff) break :blk w_diff < best_w_diff;
                const b = best.?;
                break :blk if (target_w >= 600) font.weight > b.weight else font.weight < b.weight;
            };
            if (better) {
                best = font;
                best_size_diff = size_diff;
                best_w_diff = w_diff;
            }
        }
        return best;
    }
};

// ── 单元测试 ────────────────────────────────────────────────────────
const testing = std.testing;

fn dummyFont(size: f32, weight: u16) Font {
    return .{
        .allocator = undefined,
        .ct_font = undefined,
        .size = @intFromFloat(size),
        .size_px = size,
        .weight = weight,
    };
}

test "archiveWeight: 固定档最近映射 400/500/600+" {
    try testing.expectEqual(@as(u16, 400), archiveWeight(100));
    try testing.expectEqual(@as(u16, 400), archiveWeight(400));
    try testing.expectEqual(@as(u16, 400), archiveWeight(450));
    try testing.expectEqual(@as(u16, 500), archiveWeight(500));
    try testing.expectEqual(@as(u16, 500), archiveWeight(550));
    try testing.expectEqual(@as(u16, 600), archiveWeight(600));
    try testing.expectEqual(@as(u16, 600), archiveWeight(700));
    try testing.expectEqual(@as(u16, 600), archiveWeight(900));
}

test "classifyCodepoint: 汉字/假名/谚文/其他" {
    try testing.expectEqual(ScriptClass.han_kana, classifyCodepoint(0x4E2D)); // 中
    try testing.expectEqual(ScriptClass.han_kana, classifyCodepoint(0x3042)); // あ
    try testing.expectEqual(ScriptClass.han_kana, classifyCodepoint(0x30A2)); // ア
    try testing.expectEqual(ScriptClass.hangul, classifyCodepoint(0xAC00)); // 가
    try testing.expectEqual(ScriptClass.hangul, classifyCodepoint(0x3131)); // ㄱ (compat jamo)
    try testing.expectEqual(ScriptClass.other, classifyCodepoint('A'));
    try testing.expectEqual(ScriptClass.other, classifyCodepoint(0x1F600)); // 😀
    try testing.expectEqual(ScriptClass.other, classifyCodepoint(0x05D0)); // א
}

test "selectFromFamily: 字号优先，档内字重最近，粗体请求并列取更粗" {
    var f14m = dummyFont(14, 500); // 14px 档故意用 Medium（应用的提亮设计）
    var f14b = dummyFont(14, 700);
    var f16r = dummyFont(16, 400);
    var f16m = dummyFont(16, 500);
    var f16b = dummyFont(16, 700);

    var stack = FontFallbackStack.init(testing.allocator);
    defer stack.deinit();
    const fi = stack.addFamily("Test CJK", .han_kana).?;
    for ([_]*Font{ &f14m, &f14b, &f16r, &f16m, &f16b }) |f| stack.addFont(fi, f);
    const fam = &stack.families[fi];

    // 450@14 -> 14px 档里离 400 档最近的是 Medium（字号优先，不越档去别的字号）
    try testing.expectEqual(@as(?*Font, &f14m), FontFallbackStack.selectFromFamily(fam, 14, 450));
    // 400@16 -> Regular
    try testing.expectEqual(@as(?*Font, &f16r), FontFallbackStack.selectFromFamily(fam, 16, 400));
    // 500@16 -> Medium
    try testing.expectEqual(@as(?*Font, &f16m), FontFallbackStack.selectFromFamily(fam, 16, 500));
    // 620@16 -> 目标档 600，500/700 档距并列 -> 粗体请求取更粗（真实 Semibold 面）
    try testing.expectEqual(@as(?*Font, &f16b), FontFallbackStack.selectFromFamily(fam, 16, 620));
    // 700@15 -> 无 15px 档，14/16 并列时按字重档就近（都有 700）-> 先到的 14px bold
    try testing.expectEqual(@as(?*Font, &f14b), FontFallbackStack.selectFromFamily(fam, 15, 700));
}

test "defaultSystemFamilyName: macOS = PingFang SC" {
    if (builtin.os.tag == .macos) {
        try testing.expectEqualStrings("PingFang SC", defaultSystemFamilyName().?);
    }
}

test "familyForCodepoint: 真实系统字体的覆盖与脚本优先（macOS）" {
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fs = try text_module.FontSystem.init(testing.allocator);
    defer fs.deinit();
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    const pf = fs.findFont(.{ .family = "PingFang SC", .size = 14, .weight = .regular, .style = .normal }) catch return error.SkipZigTest;
    defer pf.deinit();
    // SKIP-REASON: 依赖本机安装了特定字体家族，精简/CI 镜像可能没有
    const gothic = fs.findFont(.{ .family = "Apple SD Gothic Neo", .size = 14, .weight = .regular, .style = .normal }) catch return error.SkipZigTest;
    defer gothic.deinit();

    var stack = FontFallbackStack.init(testing.allocator);
    defer stack.deinit();
    const ci = stack.addFamily("PingFang SC", .han_kana).?;
    stack.addFont(ci, pf);
    const ki = stack.addFamily("Apple SD Gothic Neo", .hangul).?;
    stack.addFont(ki, gothic);

    // 汉字 -> PingFang（第一遍脚本优先命中）
    try testing.expectEqual(@as(?*Font, pf), stack.selectForCodepoint(0x4E2D, 14, 400));
    // 谚文 -> Gothic：即使 PingFang 在栈序上靠前且可能覆盖，也要走 hangul 优先族
    try testing.expectEqual(@as(?*Font, gothic), stack.selectForCodepoint(0xAC00, 14, 400));
    // emoji -> 两族都不覆盖 -> null（级联兜底）
    try testing.expectEqual(@as(?*Font, null), stack.selectForCodepoint(0x1F600, 14, 400));
    // 二次查询走 coverage 缓存，答案必须一致
    try testing.expectEqual(@as(?*Font, pf), stack.selectForCodepoint(0x4E2D, 14, 400));
}
