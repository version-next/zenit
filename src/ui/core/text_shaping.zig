//! 文本塑形的纯函数部分 —— 从 `Cx` 析出。
//!
//! `Cx` 上的 `shapeText` / `shapeVisualLine` / `visualLine` / `measureTextWidth`
//! 本身要碰 `font_system` + `shaping_cache` + 分配器，留在 `Cx` 上是合理的
//! （它们就是 `Cx` 对外的文本能力）。但它们依赖的三个 helper 是**纯函数**：
//! 输入定，输出定，不碰任何上下文状态。
//!
//! 把它们搬出来有两个实际收益：
//!   1. 可以直接单测。这三个函数各自都藏着一条踩过坑的不变量（见各自注释），
//!      以前只能通过"跑一整个 Cx 再观察副作用"间接验证，等于没有验证。
//!   2. `Cx` 少三个私有方法，且这些不变量有了显式的归属地。

const std = @import("std");
const shaping_cache = @import("shaping_cache.zig");
const text_module = @import("text");
const utf8 = @import("text_core").utf8;

pub const ShapingKey = shaping_cache.ShapingKey;

/// 塑形输入。`font_family` 参与缓存 key，见 `shapingKey`。
pub const ShapeTextOpts = struct {
    text: []const u8,
    font_family: []const u8,
    font_size: f32,
    font_weight: u16 = 400,
    use_italic: bool = false,
};

/// 截取最长的合法 UTF-8 前缀。
///
/// ⚠ 为什么需要它：调用方按**字节**切前缀时可能落在多字节序列中间（半个
/// CJK/emoji）。非法 UTF-8 会让 CoreText 的 NSString 构造失败 —— shape 层
/// 报 TextShapingFailed，FontSelector 桥则**静默返回 0.0f**，最终宽度 0.00
/// 直接把 bbox 压塌（下游应用实测：emoji 之后切在 CJK 首字节的"前缀"全部量出
/// 0.00）。先裁到最长合法前缀，与渲染端实际能显示的内容一致；合法输入零
/// 开销原样通过。
pub fn validUtf8Prefix(bytes: []const u8) []const u8 {
    return utf8.validPrefix(bytes);
}

/// 计算塑形缓存 key。
///
/// ⚠ family 必须进 key。
///
/// 历史上这里 font_id 恒写 0、family 也不参与哈希 —— 因为全部生产调用点都传
/// 字面量 "system"（唯一 family，永远自洽，于是这个洞一直没被触发）。一旦有
/// 第二个 family（字体选择器的预览列表就是），同一段文本换族 shape 会命中
/// **上一族**的缓存条目，第 2 行起全部退化成第 1 行的字体。
///
/// family 单独哈希进 font_id（而不是并进 text_hash）：ShapingKey.eq 会逐字段
/// 比，分成两个字段能让碰撞概率更低，也让 key 的语义更直白。
pub fn shapingKey(opts: ShapeTextOpts) ShapingKey {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(opts.text);
    var weight_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &weight_buf, opts.font_weight, .little);
    hasher.update(&weight_buf);
    const italic_byte: [1]u8 = .{if (opts.use_italic) 1 else 0};
    hasher.update(&italic_byte);
    var fam_hasher = std.hash.Wyhash.init(0x46414d49); // "FAMI"
    fam_hasher.update(opts.font_family);
    return .{
        .text_hash = hasher.final(),
        .text_len = @intCast(opts.text.len),
        .font_id = @truncate(fam_hasher.final()),
        .max_width = 0,
        .font_size = opts.font_size,
    };
}

/// CSS 数值字重 → 平台字重枚举。
pub fn mapFontWeight(weight: u16) text_module.FontWeight {
    return if (weight <= 100) .thin else if (weight <= 300) .light else if (weight <= 400) .regular else if (weight <= 500) .medium else if (weight <= 600) .semibold else if (weight <= 700) .bold else if (weight <= 800) .heavy else .black;
}

// ── 测试 ───────────────────────────────────────────────────────────────

test "validUtf8Prefix: 合法输入原样返回" {
    try std.testing.expectEqualStrings("hello", validUtf8Prefix("hello"));
    try std.testing.expectEqualStrings("中文", validUtf8Prefix("中文"));
    try std.testing.expectEqualStrings("", validUtf8Prefix(""));
}

test "validUtf8Prefix: 切在多字节序列中间时裁到上一个完整字符" {
    // "中" = E4 B8 AD，切掉最后一字节
    const cut = "\xE4\xB8";
    try std.testing.expectEqualStrings("", validUtf8Prefix(cut));

    // "a中" 砍掉 "中" 的尾字节 → 只剩 "a"
    const mixed = "a\xE4\xB8";
    try std.testing.expectEqualStrings("a", validUtf8Prefix(mixed));
}

test "validUtf8Prefix: emoji 后切在 CJK 首字节（下游应用实测塌 bbox 的那个形状）" {
    // 😀 = F0 9F 98 80，随后是半个 "中"
    const s = "\xF0\x9F\x98\x80\xE4";
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", validUtf8Prefix(s));
}

test "validUtf8Prefix: 完全非法的首字节返回空" {
    try std.testing.expectEqualStrings("", validUtf8Prefix("\xFF\xFE"));
}

test "shapingKey: family 必须参与 key（换族不得命中旧条目）" {
    const a = shapingKey(.{ .text = "Ag", .font_family = "system", .font_size = 14 });
    const b = shapingKey(.{ .text = "Ag", .font_family = "Menlo", .font_size = 14 });
    try std.testing.expect(a.font_id != b.font_id);
}

test "shapingKey: text/size/weight/italic 各自参与 key" {
    const base = ShapeTextOpts{ .text = "Ag", .font_family = "system", .font_size = 14, .font_weight = 400 };
    const k = shapingKey(base);

    var other = base;
    other.text = "Ah";
    try std.testing.expect(shapingKey(other).text_hash != k.text_hash);

    other = base;
    other.font_weight = 700;
    try std.testing.expect(shapingKey(other).text_hash != k.text_hash);

    other = base;
    other.use_italic = true;
    try std.testing.expect(shapingKey(other).text_hash != k.text_hash);

    other = base;
    other.font_size = 18;
    try std.testing.expect(shapingKey(other).font_size != k.font_size);
}

test "shapingKey: 相同输入稳定复现" {
    const o = ShapeTextOpts{ .text = "stable", .font_family = "system", .font_size = 13, .font_weight = 500 };
    const a = shapingKey(o);
    const b = shapingKey(o);
    try std.testing.expectEqual(a.text_hash, b.text_hash);
    try std.testing.expectEqual(a.font_id, b.font_id);
    try std.testing.expectEqual(a.text_len, b.text_len);
}

test "mapFontWeight: CSS 数值落到正确的枚举档位" {
    try std.testing.expectEqual(text_module.FontWeight.thin, mapFontWeight(100));
    try std.testing.expectEqual(text_module.FontWeight.light, mapFontWeight(300));
    try std.testing.expectEqual(text_module.FontWeight.regular, mapFontWeight(400));
    try std.testing.expectEqual(text_module.FontWeight.medium, mapFontWeight(500));
    try std.testing.expectEqual(text_module.FontWeight.semibold, mapFontWeight(600));
    try std.testing.expectEqual(text_module.FontWeight.bold, mapFontWeight(700));
    try std.testing.expectEqual(text_module.FontWeight.heavy, mapFontWeight(800));
    try std.testing.expectEqual(text_module.FontWeight.black, mapFontWeight(900));
    // 边界：档位是「<=」，所以 401 应落进下一档
    try std.testing.expectEqual(text_module.FontWeight.medium, mapFontWeight(401));
}
