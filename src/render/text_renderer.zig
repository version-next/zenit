/// Metal Text Renderer - GPU 实例化文本渲染
///
/// 使用 HarfBuzz 进行文本塑形，FreeType 光栅化字形
/// GPU 实例化渲染实现高性能文本绘制
const std = @import("std");
const gpu = @import("gpu");
const text_module = @import("text");
const Font = text_module.Font;
const TextShaper = text_module.TextShaper;
const atlas_mod = @import("glyph_atlas.zig");
const GlyphAtlas = atlas_mod.GlyphAtlas;
const font_stack_mod = @import("font_fallback_stack.zig");
const FontFallbackStack = font_stack_mod.FontFallbackStack;
const text_trace = @import("trace").text_flicker;

/// Text Shader 源码（单一事实源）
const text_shader_source: []const u8 = @embedFile("shaders/text.metal");
const MAX_CLIP_POLYGON_POINTS = 32;
const MAX_CLIP_POLYGON_CONTOURS = 8;

/// Uniforms 结构（必须与 shader 匹配）
const Uniforms = extern struct {
    viewport_size: [2]f32, // 物理像素
    scale_factor: f32,
    clip_shape_kind: u32 = 0,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radius: f32 = 0,
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = [_]u32{0} ** MAX_CLIP_POLYGON_CONTOURS,
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = [_][2]f32{.{ 0, 0 }} ** MAX_CLIP_POLYGON_POINTS,
};

/// 字形实例数据（必须与 shader 匹配）
const GlyphInstance = extern struct {
    position: [2]f32, // 字形左下角位置
    size: [2]f32, // 字形尺寸
    uv_rect: [4]f32, // UV 矩形 (u_min, v_min, u_max, v_max)
    color: [4]f32, // 颜色 RGBA
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 }, // x, y, w, h (逻辑像素); negative size = disabled
    skew_x: f32 = 0, // 合成斜体 x 偏移（逻辑像素）
    page_index: f32 = 0, // Atlas 页号（CPU 分桶用，shader 不读）
    /// >0.5 = 该字形在 BGRA 彩色页；shader 据此选采样路径（彩色直接输出
    /// 采样值，不乘文字颜色）。
    is_color: f32 = 0,
    /// >0.5 = vertex shader 把 position 吸附到物理像素（round）。
    /// direct_animated 文本必须置 0：各 glyph 的小数部分不同，逐 glyph round
    /// 会让相邻字形在不同帧跨越取整阈值，产生字距/基线跳动。
    /// per-instance 而非 per-draw：nearest/linear 两个列表内混装多种策略
    /// （静态合成斜体、静态缩放文本也走 linear 列表）。
    shader_snap: f32 = 1,
};

/// 单帧实例 buffer 容量（一帧内所有 flush 共享同一个 buffer）
/// 编辑器 ~1000 + minimap text 模式 ~12000 + UI ~100 = ~13100 glyphs/帧
/// Metal command buffer 是延迟执行，回绕覆写会破坏先前 draw call 引用的数据
const MAX_INSTANCES = 32768;
const MAX_UNIFORM_UPDATES = 512;

/// Triple buffering 常量
const BUFFER_COUNT = 3;

/// 颜色常量
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const WHITE = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const BLACK = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const RED = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const GREEN = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const BLUE = Color{ .r = 0, .g = 0, .b = 1, .a = 1 };

    pub fn toArray(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }
};

// ── 段级 Shaping Cache ──────────────────────────────────────────────
// 借鉴 Chrome/Blink 词级缓存：将文本按 shaping 等价性切分为最小段，
// CJK 单字独立缓存（无 ligature），ASCII 词+尾部空白为一段。
// 内联存储消灭所有 alloc/free，确定性内存 ~5.5MB。

/// 段分割结果
const Segment = struct {
    start: u32,
    end: u32,
};

/// 栈上最大段数（超过则 fallback 到整行缓存）
const MAX_SEGMENTS = 256;

/// 段级缓存 — 每个段最多内联存储的 glyph 数。
///
/// 这个上限决定了哪些段能进缓存：超过的段每帧现场 shape。代码文本里
/// 最长的段（`compute(alpha_00042,` 这类标识符/调用表达式，一段就是
/// 一行的大半字节）普遍在 12～32 之间 —— 取 12 时它们全部逐帧重 shape，
/// git diff 滚动实测 encode 的 ~85% 都烧在 CTLineCreateWithAttributedString
/// 上。32 覆盖绝大多数代码 token；更长的段默认走 owned 路径，
/// 显式开启 cache_long_segments 时可进入有界 spill cache。
const MAX_SEGMENT_GLYPHS = 32;

/// 段级缓存键
const SegmentCacheKey = struct {
    content_hash: u64, // Wyhash(段文本)
    font_ptr: usize, // 字体指针
    flags: u8, // bit0: use_italic
};

/// 段级缓存条目（全内联，无 alloc）
const SegmentCacheEntry = struct {
    glyphs_buf: [MAX_SEGMENT_GLYPHS]text_module.ShapedGlyph = undefined,
    glyph_count: u8 = 0,
    frame_last_used: u64 = 0,
};

/// Bounded spill cache for long shaped segments. Ownership transfers only on
/// successful insertion; glyph fallback font refs remain owned by that slice.
const LongSegmentCache = struct {
    const max_entries = 64;
    const max_glyphs = 1024;
    const Entry = struct {
        text: []u8,
        glyphs: []text_module.ShapedGlyph,
        frame: u64,
    };
    entries: std.AutoHashMapUnmanaged(SegmentCacheKey, Entry) = .{},

    fn get(self: *LongSegmentCache, key: SegmentCacheKey, text: []const u8, frame: u64) ?[]const text_module.ShapedGlyph {
        const entry = self.entries.getPtr(key) orelse return null;
        if (!std.mem.eql(u8, entry.text, text)) return null;
        entry.frame = frame;
        return entry.glyphs;
    }

    fn release(allocator: std.mem.Allocator, entry: Entry) void {
        TextRenderer.releaseGlyphFallbackFontRefs(entry.glyphs);
        allocator.free(entry.glyphs);
        allocator.free(entry.text);
    }

    fn adopt(self: *LongSegmentCache, allocator: std.mem.Allocator, key: SegmentCacheKey, text: []const u8, glyphs: []text_module.ShapedGlyph, frame: u64) bool {
        if (glyphs.len > max_glyphs or text.len > max_glyphs * 4) return false;
        const owned_text = allocator.dupe(u8, text) catch return false;
        self.entries.ensureUnusedCapacity(allocator, 1) catch {
            allocator.free(owned_text);
            return false;
        };
        if (self.entries.fetchRemove(key)) |old| release(allocator, old.value);
        if (self.entries.count() >= max_entries) {
            var oldest: ?SegmentCacheKey = null;
            var oldest_frame: u64 = std.math.maxInt(u64);
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (oldest == null or entry.value_ptr.frame < oldest_frame) {
                    oldest = entry.key_ptr.*;
                    oldest_frame = entry.value_ptr.frame;
                }
            }
            if (self.entries.fetchRemove(oldest.?)) |old| release(allocator, old.value);
        }
        self.entries.putAssumeCapacity(key, .{ .text = owned_text, .glyphs = glyphs, .frame = frame });
        return true;
    }

    fn deinit(self: *LongSegmentCache, allocator: std.mem.Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| release(allocator, entry.*);
        self.entries.deinit(allocator);
        self.* = .{};
    }
};

/// 段级缓存最大条目数。条目是内联数组：32 glyph × 40B + 头 ≈ 1.3KB，
/// 8K 条 ≈ 10.6MB 确定性内存（约 16 屏代码的工作集）。
/// MAX_SEGMENT_GLYPHS 提到 32 时同步从 16K 降下来，总内存与旧配置持平。
const SEGMENT_CACHE_MAX = 8192;

/// CoreText fallback font wrapper 缓存上限。
/// run 级 CTFontRef 可能不是稳定指针，必须限制增长。
const FALLBACK_FONT_CACHE_MAX = 256;
var font_debug_budget: u32 = 12;

const FallbackFontCacheEntry = struct {
    font: *Font,
    frame_last_used: u64,
};

/// 主字体覆盖判定缓存的键：cmap 覆盖是 (字体, 码点) 的纯函数。
/// 只有长命字体（selector 档位 / derived cache）会当 primary 进来，
/// 指针作键安全 —— 与 fallback wrapper 那个「run 级 CTFontRef 指针不稳定」
/// 的教训不冲突：那是 CoreText 现场造的临时实例，这里是我们持有的。
const PrimaryCovKey = struct { font_ptr: usize, cp: u21 };
const PRIMARY_COVERAGE_CACHE_MAX = 16384;

fn containsEnclosedDigit(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            i += seq_len;
            continue;
        };
        if (cp >= 0x2460 and cp <= 0x2473) return true;
        i += seq_len;
    }
    return false;
}

/// 判断 codepoint 是否为 CJK 表意文字（无 ligature，可独立 shape）
fn isCJK(cp: u21) bool {
    return (cp >= 0x2E80 and cp <= 0x2EFF) or // CJK Radicals Supplement
        (cp >= 0x2F00 and cp <= 0x2FDF) or // Kangxi Radicals
        (cp >= 0x3000 and cp <= 0x303F) or // CJK Symbols and Punctuation
        (cp >= 0x3040 and cp <= 0x309F) or // Hiragana
        (cp >= 0x30A0 and cp <= 0x30FF) or // Katakana
        (cp >= 0x3100 and cp <= 0x312F) or // Bopomofo
        (cp >= 0x3130 and cp <= 0x318F) or // Hangul Compatibility Jamo
        (cp >= 0x31A0 and cp <= 0x31BF) or // Bopomofo Extended
        (cp >= 0x31F0 and cp <= 0x31FF) or // Katakana Phonetic Extensions
        (cp >= 0x3200 and cp <= 0x32FF) or // Enclosed CJK Letters
        (cp >= 0x3300 and cp <= 0x33FF) or // CJK Compatibility
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Unified Ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs
        (cp >= 0xA000 and cp <= 0xA48F) or // Yi Syllables
        (cp >= 0xA490 and cp <= 0xA4CF) or // Yi Radicals
        (cp >= 0xAC00 and cp <= 0xD7AF) or // Hangul Syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK Compatibility Forms
        (cp >= 0xFF00 and cp <= 0xFFEF) or // Halfwidth and Fullwidth Forms
        (cp >= 0x20000 and cp <= 0x2A6DF) or // CJK Unified Ext B
        (cp >= 0x2A700 and cp <= 0x2B73F) or // CJK Unified Ext C
        (cp >= 0x2B740 and cp <= 0x2B81F) or // CJK Unified Ext D
        (cp >= 0x2B820 and cp <= 0x2CEAF) or // CJK Unified Ext E
        (cp >= 0x2CEB0 and cp <= 0x2EBEF) or // CJK Unified Ext F
        (cp >= 0x2F800 and cp <= 0x2FA1F); // CJK Compatibility Supplement
}

/// BMP 内可带 emoji 表现的码点（U+1F000 以下）。这些字符本身是普通符号，
/// 跟上 VS16(U+FE0F) 才转成彩色 emoji（如 ❤ U+2764 → ❤️）。
///
/// 必须和 `cp >= 0x1F000` 一起进 emoji 分支：否则它们落到"其他 Unicode
/// 逐码点独立"分支，基字与 VS16 被切成两段分别 shape，CoreText 看不到
/// 这个组合 → 退回单色文本形态，且宽度按窄字形算（12.742 vs 19.0），
/// 光标随之偏移。
fn isEmojiCapable(cp: u21) bool {
    return (cp >= 0x2190 and cp <= 0x21FF) or // 箭头
        (cp >= 0x2300 and cp <= 0x23FF) or // 技术符号（⌚⏰⏳…）
        (cp >= 0x2460 and cp <= 0x24FF) or // 带圈字母数字
        (cp >= 0x25A0 and cp <= 0x25FF) or // 几何图形
        (cp >= 0x2600 and cp <= 0x27BF) or // 杂项符号 + Dingbats（☀★❤✅✨…）
        (cp >= 0x2B00 and cp <= 0x2BFF) or // 杂项符号与箭头
        (cp >= 0x1F000 and cp <= 0x1FAFF) or // 主 emoji 区（保险，实际由调用处 >= 0x1F000 覆盖）
        cp == 0x203C or cp == 0x2049 or // ‼ ⁉
        cp == 0x2122 or cp == 0x2139 or // ™ ℹ
        cp == 0x3030 or cp == 0x303D or
        cp == 0x3297 or cp == 0x3299;
}

/// 判断 codepoint 是否为 ZWJ/Variation Selector（Emoji 序列连接符）
fn isJoiner(cp: u21) bool {
    return cp == 0x200D or // ZWJ
        (cp >= 0xFE00 and cp <= 0xFE0F) or // Variation Selectors
        (cp >= 0xE0100 and cp <= 0xE01EF); // Variation Selectors Supplement
}

/// RTL 脚本码点（阿拉伯/希伯来及其扩展区），含这些脚本内部会用到的
/// 结合符号。RTL **必须整段交给 CoreText**：
///   1. bidi（UAX #9）重排是 CTLine 级别的行为，逐码点 shape 拿不到；
///   2. 阿拉伯字母的连写形态（isolated/initial/medial/final）取决于左右
///      邻居，切碎后每个字母都会退化成孤立形；
///   3. 变音符号（harakat / niqqud）要挂到基字上，切开就变成独立字形。
fn isRtlScript(cp: u21) bool {
    return (cp >= 0x0590 and cp <= 0x05FF) or // Hebrew
        (cp >= 0x0600 and cp <= 0x06FF) or // Arabic
        (cp >= 0x0700 and cp <= 0x074F) or // Syriac
        (cp >= 0x0750 and cp <= 0x077F) or // Arabic Supplement
        (cp >= 0x0780 and cp <= 0x07BF) or // Thaana
        (cp >= 0x08A0 and cp <= 0x08FF) or // Arabic Extended-A
        (cp >= 0xFB1D and cp <= 0xFB4F) or // Hebrew Presentation Forms
        (cp >= 0xFB50 and cp <= 0xFDFF) or // Arabic Presentation Forms-A
        (cp >= 0xFE70 and cp <= 0xFEFF); // Arabic Presentation Forms-B
}

/// 将文本按 shaping 等价性切分为最小缓存单元
/// 返回段数（0 = 空文本），超过 MAX_SEGMENTS 时返回 MAX_SEGMENTS + 1 表示溢出
fn segmentText(text: []const u8, out: *[MAX_SEGMENTS]Segment) u32 {
    if (text.len == 0) return 0;
    var seg_count: u32 = 0;
    var i: u32 = 0;
    const len: u32 = @intCast(text.len);

    while (i < len) {
        if (seg_count >= MAX_SEGMENTS) return MAX_SEGMENTS + 1; // 溢出

        const byte = text[i];
        // 判断首字节得到 codepoint 长度
        const cp_len: u32 = if (byte < 0x80)
            1
        else if (byte < 0xE0)
            2
        else if (byte < 0xF0)
            3
        else
            4;

        if (i + cp_len > len) break; // 截断的 UTF-8，跳过

        // 解码 codepoint
        const cp: u21 = switch (cp_len) {
            1 => @intCast(byte),
            2 => (@as(u21, byte & 0x1F) << 6) | @as(u21, text[i + 1] & 0x3F),
            3 => (@as(u21, byte & 0x0F) << 12) | (@as(u21, text[i + 1] & 0x3F) << 6) | @as(u21, text[i + 2] & 0x3F),
            4 => (@as(u21, byte & 0x07) << 18) | (@as(u21, text[i + 1] & 0x3F) << 12) | (@as(u21, text[i + 2] & 0x3F) << 6) | @as(u21, text[i + 3] & 0x3F),
            else => unreachable,
        };

        if (isCJK(cp)) {
            // CJK: 每个码点独立一段
            out[seg_count] = .{ .start = i, .end = i + cp_len };
            seg_count += 1;
            i += cp_len;
        } else if (byte < 0x80 and byte > 0x20) {
            // ASCII 可见字符：连续扫描直到非 ASCII 可见或结束，包含尾部空白
            const seg_start = i;
            i += 1;
            while (i < len and text[i] > 0x20 and text[i] < 0x80) {
                i += 1;
            }
            // 吞掉尾部 ASCII 空白（与下一个词的间距属于当前段）
            while (i < len and text[i] == 0x20) {
                i += 1;
            }
            out[seg_count] = .{ .start = seg_start, .end = i };
            seg_count += 1;
        } else if (cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F)) {
            // ZWJ/VS 出现在段首 = 前一个基字没把它吞进去。**必须仍然成段**：
            // 直接 `i += cp_len` 会让这几个字节从所有段里消失，后续段的
            // start/end 与原文错位（实测 "abc❤️def" 会漏掉一整段）。
            // 交给 shaper 时它的 advance 是 0，不影响排版。
            out[seg_count] = .{ .start = i, .end = i + cp_len };
            seg_count += 1;
            i += cp_len;
        } else if (cp >= 0x1F000 or isEmojiCapable(cp)) {
            // Emoji 范围：连续扫描 ZWJ 连接的序列
            const seg_start = i;
            i += cp_len;
            while (i < len) {
                const nb = text[i];
                const ncl: u32 = if (nb < 0x80) 1 else if (nb < 0xE0) 2 else if (nb < 0xF0) 3 else 4;
                if (i + ncl > len) break;
                const ncp: u21 = switch (ncl) {
                    1 => @intCast(nb),
                    2 => (@as(u21, nb & 0x1F) << 6) | @as(u21, text[i + 1] & 0x3F),
                    3 => (@as(u21, nb & 0x0F) << 12) | (@as(u21, text[i + 1] & 0x3F) << 6) | @as(u21, text[i + 2] & 0x3F),
                    4 => (@as(u21, nb & 0x07) << 18) | (@as(u21, text[i + 1] & 0x3F) << 12) | (@as(u21, text[i + 2] & 0x3F) << 6) | @as(u21, text[i + 3] & 0x3F),
                    else => unreachable,
                };
                // 只在**前一个码点是 ZWJ** 时才接受 BMP emoji 基字
                // （如 ❤‍🔥 = U+1F525 ZWJ U+2764）。无条件接受 isEmojiCapable
                // 会把紧跟 emoji 的普通符号（→ ■ 等）误吞进同一段。
                const prev_was_zwj = i >= 3 and text[i - 3] == 0xE2 and text[i - 2] == 0x80 and text[i - 1] == 0x8D;
                if (isJoiner(ncp) or ncp >= 0x1F000 or (prev_was_zwj and isEmojiCapable(ncp))) {
                    i += ncl;
                } else break;
            }
            out[seg_count] = .{ .start = seg_start, .end = i };
            seg_count += 1;
        } else if (byte == 0x20) {
            // 前导/孤立空格：生成段（shaper 会给空格正确的 advance，确保 cursor_x 推进）
            const seg_start = i;
            while (i < len and text[i] == 0x20) {
                i += 1;
            }
            out[seg_count] = .{ .start = seg_start, .end = i };
            seg_count += 1;
        } else if (byte == 0x09 or byte == 0x0A or byte == 0x0D) {
            // tab/换行：跳过（tab 应在上游被展开为空格）
            i += 1;
        } else if (isRtlScript(cp)) {
            // RTL：连续的 RTL 码点**整段**扫下来交给 CoreText。
            // 不能像下面 else 那样逐码点切 —— 那会同时毁掉 bidi 重排、
            // 阿拉伯连写形态和变音符号挂载（见 isRtlScript 注释）。
            // 段内允许夹空格：RTL 词间空格属于同一个 bidi run，单独成段
            // 会把一句话切成多个 run 并按 LTR 累加 cursor 拼回去。
            const seg_start = i;
            i += cp_len;
            while (i < len) {
                const nb = text[i];
                const ncl: u32 = if (nb < 0x80) 1 else if (nb < 0xE0) 2 else if (nb < 0xF0) 3 else 4;
                if (i + ncl > len) break;
                const ncp: u21 = switch (ncl) {
                    1 => @intCast(nb),
                    2 => (@as(u21, nb & 0x1F) << 6) | @as(u21, text[i + 1] & 0x3F),
                    3 => (@as(u21, nb & 0x0F) << 12) | (@as(u21, text[i + 1] & 0x3F) << 6) | @as(u21, text[i + 2] & 0x3F),
                    4 => (@as(u21, nb & 0x07) << 18) | (@as(u21, text[i + 1] & 0x3F) << 12) | (@as(u21, text[i + 2] & 0x3F) << 6) | @as(u21, text[i + 3] & 0x3F),
                    else => unreachable,
                };
                // 尾随空格不吞：留给后面的空格分支，避免把 RTL 段末尾
                // 的空格算进 RTL run（那会让 LTR 续接位置偏移）。
                if (isRtlScript(ncp) or isJoiner(ncp)) {
                    i += ncl;
                } else if (ncp == 0x20) {
                    // 只有当空格后面仍是 RTL 时才并入本段。
                    var j = i + 1;
                    while (j < len and text[j] == 0x20) j += 1;
                    if (j >= len) break;
                    const fb = text[j];
                    const fcl: u32 = if (fb < 0x80) 1 else if (fb < 0xE0) 2 else if (fb < 0xF0) 3 else 4;
                    if (j + fcl > len) break;
                    const fcp: u21 = switch (fcl) {
                        1 => @intCast(fb),
                        2 => (@as(u21, fb & 0x1F) << 6) | @as(u21, text[j + 1] & 0x3F),
                        3 => (@as(u21, fb & 0x0F) << 12) | (@as(u21, text[j + 1] & 0x3F) << 6) | @as(u21, text[j + 2] & 0x3F),
                        4 => (@as(u21, fb & 0x07) << 18) | (@as(u21, text[j + 1] & 0x3F) << 12) | (@as(u21, text[j + 2] & 0x3F) << 6) | @as(u21, text[j + 3] & 0x3F),
                        else => unreachable,
                    };
                    if (isRtlScript(fcp)) i = j else break;
                } else break;
            }
            out[seg_count] = .{ .start = seg_start, .end = i };
            seg_count += 1;
        } else {
            // 其他 Unicode：每个码点独立
            out[seg_count] = .{ .start = i, .end = i + cp_len };
            seg_count += 1;
            i += cp_len;
        }
    }
    return seg_count;
}

/// Metal Text Renderer
/// text 管线模块级累计 GPU draw 数（FrameStats 取每帧增量用）
pub var text_draw_calls: u64 = 0;

/// 模块级累计：uniform 槽位溢出到备用 buffer 的次数。
///
/// 溢出本身**不再丢字**（见 TextRenderer.flush 的注释），但它是「一帧内 clip
/// 切换次数超出预期」的直接信号 —— 那正是 2026-08 那轮 clip flush 风暴的
/// 特征。恒为 0 是健康态；持续增长说明该去查 clip 链是否又在逐行重发。
/// 导出到这里是为了让 e2e / /perf 能断言它，而不是只能靠翻日志。
pub var text_uniform_overflow_total: u64 = 0;
/// 模块级累计：fallback wrapper Font 的创建次数。
/// 健康态下它应当与「不同 (字体,字号,traits) 组合数」同量级（几十以内）。
/// 持续增长 = fallback 身份键失效回退成指针键，上面描述的丢字灾难会复发。
pub var fallback_wrappers_created_total: u64 = 0;

pub const TextRenderer = struct {
    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    pipeline: gpu.Backend.RenderPipeline,
    /// Triple-buffered uniform buffers —— 必须与 instance buffers 一样按帧轮转。
    /// 曾经是**单个** buffer 而每帧把 uniform_write_offset 归零：三帧在飞时第 N+1
    /// 帧会覆写 GPU 尚未消费的第 N 帧 viewport/clip/scale，表现为偶发闪烁/错误裁剪。
    uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    uniform_write_offset: usize = 0,
    /// 单帧 uniform 槽位溢出次数（诊断用）
    uniform_overflow_count: u64 = 0,

    /// 溢出 uniform 缓冲（每帧槽位各一个，随需增长后**保留**）。
    ///
    /// 曾经：槽位用尽直接 `return error.UniformSlotsExhausted` 丢掉整批字。
    /// 因为 flush 失败时 instances **不清空**，下一批带着旧实例再来一次、
    /// 再次溢出 —— 从耗尽那一刻起该帧剩余文本**全部不画**。用户可见症状是
    /// 「大段文字消失但位置留白、逐帧闪烁」，而节点树/布局 rect 全对，
    /// 只看 app_state 永远查不出来。
    ///
    /// 现在与 overflow_buffers（实例侧）同款：槽位不够就用一块按需增长、
    /// 跨帧保留的溢出 buffer 继续画。容量够直接复用，不够才重建一次。
    /// 槽位随 current_buffer 轮转，不会覆写 GPU 尚在消费的在飞帧数据。
    uniform_overflow_buffers: [BUFFER_COUNT]?gpu.Backend.Buffer = [_]?gpu.Backend.Buffer{null} ** BUFFER_COUNT,
    uniform_overflow_capacities: [BUFFER_COUNT]usize = [_]usize{0} ** BUFFER_COUNT,
    /// 本帧内已用掉的溢出 uniform 槽数
    uniform_overflow_used: usize = 0,
    /// 本帧 flush 次数峰值（诊断用，导出到 /perf）
    uniform_peak_slots: usize = 0,
    /// Triple-buffered instance buffers
    instance_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    current_buffer: usize = 0,

    /// 溢出实例缓冲（每帧槽位各一个，随需增长后**保留**）。
    ///
    /// 旧实现在 MAX_INSTANCES 用尽后对**每一批**都 createBuffer + destroy ——
    /// 重文本帧每帧多次 driver 分配（走驱动，非 malloc）。改为按帧槽位持有
    /// 一个可增长的 buffer：容量够就直接复用，不够才重建一次。槽位随
    /// current_buffer 轮转，因此不会覆写 GPU 尚在消费的在飞帧数据。
    /// 与 sdf_renderer 的保留池同款。
    overflow_buffers: [BUFFER_COUNT]?gpu.Backend.Buffer = [_]?gpu.Backend.Buffer{null} ** BUFFER_COUNT,
    overflow_capacities: [BUFFER_COUNT]usize = [_]usize{0} ** BUFFER_COUNT,
    /// 本帧槽位内溢出缓冲的写入游标（字节），保证同帧多批次不互相覆写。
    overflow_write_offset: usize = 0,

    // 字体和图集
    atlas: GlyphAtlas,

    /// 显式字体回退栈（应用注入；null = 维持纯 CoreText 级联行为）。
    /// 见 font_fallback_stack.zig 的文件头注释。
    fallback_stack: ?*FontFallbackStack = null,
    /// (primary 字体, 码点) → 是否覆盖。selectSegmentFont 的热路径缓存：
    /// 命中后每个非 ASCII 段只付一次 hash 查找，不再走 CoreText FFI。
    primary_coverage_cache: std.AutoHashMap(PrimaryCovKey, bool),

    /// Prewarm 模式：只做 shaping + glyph 光栅化入 atlas，**不产出实例**。
    ///
    /// 帧初的 prewarm pass 目的是把缺失字形提前上传到 atlas（避开 GPU 关键路径），
    /// 但此前它调用完整的 encodeText，把实例全部生成出来再整体丢弃
    /// （shrinkRetainingCapacity），于是长文本/复杂 spans 的实例构造与 append
    /// 被**白做一遍**（审查报告 P1：文本几乎编码两遍）。
    /// 打开此开关后，emitGlyphInstance 在完成 atlas 插入后立即返回 advance，
    /// 跳过所有实例构造与 append。
    glyph_only: bool = false,

    /// 上一次真正跑完 prewarm 的命令流文本签名 + 当时的 atlas GC 代号。
    ///
    /// prewarm 唯一的产物是「缺失字形进 atlas」。若本帧的文本负载与上一帧
    /// 逐字节相同、且期间没有发生 atlas 页驱逐，那么所需字形**必然**已经
    /// 全部驻留，整趟 prewarm 是纯粹的空转（实测滚动 448 帧里 434 帧
    /// inserts=0，白烧 8ms/帧 —— 比 encode 本身还贵）。
    /// 签名一致 + gc_generation 一致 → 直接跳过。
    /// 任一不符（文本变了 / 页被驱逐）都退回完整 prewarm，方向是安全的。
    prewarm_signature: u64 = 0,
    prewarm_signature_valid: bool = false,
    prewarm_gc_generation: u32 = 0,
    shaper: TextShaper,

    // 段级塑形缓存 — 词/CJK 单字粒度，内联存储无 alloc
    segment_cache: std.AutoHashMap(SegmentCacheKey, SegmentCacheEntry),
    cache_long_segments: bool = false,
    long_segment_cache: LongSegmentCache = .{},
    // 整行 fallback 缓存 — 段溢出时使用
    // CoreText 实际 fallback CTFontRef -> borrowed Font wrapper。
    // run 级 CTFontRef 可能每次 shape 都重新 materialize，故必须做容量控制。
    fallback_font_cache: std.AutoHashMap(u64, FallbackFontCacheEntry),
    current_frame: u64 = 0,
    /// GC 本帧回收了 atlas 页面 → 上层需要清除渲染命令缓存
    atlas_gc_happened: bool = false,

    // 当前帧的实例数据
    instances_nearest: std.ArrayList(GlyphInstance),
    instances_linear: std.ArrayList(GlyphInstance),
    viewport_width: f32,
    viewport_height: f32,
    scale_factor: f32,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radius: f32 = 0,
    clip_shape_kind: u32 = 0,
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = [_]u32{0} ** MAX_CLIP_POLYGON_CONTOURS,
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = [_][2]f32{.{ 0, 0 }} ** MAX_CLIP_POLYGON_POINTS,
    current_rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    /// 当前 clip 区域的水平范围（逻辑像素），用于跳过视口外的 glyph
    clip_x_min: f32 = 0,
    clip_x_max: f32 = std.math.inf(f32),
    /// 当前 pass 目标的**逻辑像素**宽（beginFrame/setViewport 的 width 参数）。
    /// setRectClip(null) 要把 clip_x_min/max 恢复成整个目标宽度，
    /// 不能用 viewport_width —— 那是乘过 scale 的物理像素。
    viewport_logical_width: f32 = 0,
    /// 右端淡出遮罩窗口（逻辑像素，与 draw x 同空间；类 CSS mask-image 的
    /// 文本专用最小实现）：glyph 左缘落在 [fade_x0, fade_x1] 内时 alpha 按
    /// 位置线性降到 0，越过 fade_x1 全透明。inf/inf = 关闭。
    /// 由 command_encoder 按 text 命令逐条设置并复位（同 clip_x_* 模式）。
    fade_x0: f32 = std.math.inf(f32),
    fade_x1: f32 = std.math.inf(f32),
    instance_high_water_mark: usize = 0,
    /// flush 偏移：中间 flush 后追加写入，避免 GPU 异步执行时数据被覆盖
    buffer_write_offset: usize = 0,

    /// 初始化 Text Renderer
    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !TextRenderer {
        // 编译 shader
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, text_shader_source);
        defer shader.deinit();

        // 获取函数
        var vertex_func = try shader.getFunction("text_vertex_main");
        defer vertex_func.deinit();
        var fragment_func = try shader.getFunction("text_fragment_main");
        defer fragment_func.deinit();

        // 创建 pipeline。此行之后每个可失败步骤都必须有 errdefer 覆盖已建
        // 资源——GPU 对象 GPA 检测不到，泄漏的是 MTLBuffer/PSO/CoreText 资源。
        // 注意：errdefer 声明在 for 循环体内会随迭代作用域失效（等于死代码，
        // 这里曾经就是这么写的），计数必须放在循环外。
        var pipeline = try gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex_func,
            .fragment_function = &fragment_func,
            .color_attachment_formats = &[_]gpu.TextureFormat{.bgra8_unorm_srgb},
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

        // 创建 uniform buffer
        var uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var uniform_created: usize = 0;
        errdefer for (uniform_buffers[0..uniform_created]) |*ub| ub.destroy();
        for (&uniform_buffers) |*ubuf| {
            ubuf.* = try device.createBuffer(allocator, .{
                .label = "Zenit.Text.Uniforms",
                .size = @sizeOf(Uniforms) * MAX_UNIFORM_UPDATES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            uniform_created += 1;
        }

        // 创建 triple-buffered instance buffers
        var instance_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var instance_created: usize = 0;
        errdefer for (instance_buffers[0..instance_created]) |*ib| ib.destroy();
        for (&instance_buffers, 0..) |*buf, i| {
            const label = try std.fmt.allocPrint(allocator, "Zenit.Text.InstanceBuffer[{d}]", .{i});
            defer allocator.free(label);
            buf.* = try device.createBuffer(allocator, .{
                .label = label,
                .size = @sizeOf(GlyphInstance) * MAX_INSTANCES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            instance_created += 1;
        }

        // 创建字形图集
        var atlas = try GlyphAtlas.init(allocator, device);
        errdefer atlas.deinit();

        // 创建文本塑形器
        const shaper = try TextShaper.init(allocator);

        std.log.info("[TextRenderer] Initialized", .{});

        return TextRenderer{
            .allocator = allocator,
            .device = device,
            .pipeline = pipeline,
            .uniform_buffers = uniform_buffers,
            .instance_buffers = instance_buffers,
            .atlas = atlas,
            .shaper = shaper,
            .segment_cache = std.AutoHashMap(SegmentCacheKey, SegmentCacheEntry).init(allocator),
            .fallback_font_cache = std.AutoHashMap(u64, FallbackFontCacheEntry).init(allocator),
            .primary_coverage_cache = std.AutoHashMap(PrimaryCovKey, bool).init(allocator),
            .instances_nearest = .{},
            .instances_linear = .{},
            .viewport_width = 800,
            .viewport_height = 600,
            .scale_factor = 1.0,
        };
    }

    /// 销毁
    pub fn deinit(self: *TextRenderer) void {
        var seg_iter = self.segment_cache.iterator();
        while (seg_iter.next()) |entry| {
            releaseGlyphFallbackFontRefs(entry.value_ptr.glyphs_buf[0..entry.value_ptr.glyph_count]);
        }
        self.segment_cache.deinit();
        self.long_segment_cache.deinit(self.allocator);
        var fallback_font_iter = self.fallback_font_cache.iterator();
        while (fallback_font_iter.next()) |entry| {
            entry.value_ptr.font.deinit();
        }
        self.fallback_font_cache.deinit();
        self.primary_coverage_cache.deinit();
        self.instances_nearest.deinit(self.allocator);
        self.instances_linear.deinit(self.allocator);
        self.shaper.deinit();
        self.atlas.deinit();
        for (&self.instance_buffers) |*buf| buf.destroy();
        for (&self.uniform_buffers) |*ubuf| ubuf.destroy();
        for (&self.overflow_buffers) |*maybe_buf| {
            if (maybe_buf.*) |*buf| buf.destroy();
        }
        for (&self.uniform_overflow_buffers) |*maybe_buf| {
            if (maybe_buf.*) |*buf| buf.destroy();
        }
        self.pipeline.deinit();
        std.log.info("[TextRenderer] Destroyed", .{});
    }

    /// 开始新帧
    /// width/height: 逻辑像素; scale: DPI 缩放因子 (Retina=2.0)
    pub fn beginFrame(self: *TextRenderer, width: f32, height: f32, scale: f32) void {
        self.instances_nearest.clearRetainingCapacity();
        self.instances_linear.clearRetainingCapacity();
        self.buffer_write_offset = 0;
        self.current_buffer = (self.current_buffer + 1) % BUFFER_COUNT;
        self.uniform_write_offset = 0;
        // 新槽位的溢出缓冲从头写起（该槽位上一次使用已隔了 BUFFER_COUNT 帧）
        self.overflow_write_offset = 0;
        self.uniform_overflow_used = 0;
        self.uniform_peak_slots = 0;
        self.current_frame += 1;
        // DPI 变了（跨屏拖窗）会改字形光栅尺寸与 subpixel 分箱键，
        // prewarm 的跳过基线随之失效。
        if (self.scale_factor != scale) self.prewarm_signature_valid = false;
        // viewport_size 传物理像素给 shader
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
        self.clip_rect = .{ 0, 0, 0, 0 };
        self.clip_radius = 0;
        self.clip_shape_kind = 0;
        self.clip_fill_rule = 0;
        self.clip_point_count = 0;
        self.clip_contour_count = 0;
        self.clip_polygon_end_points = [_]u32{0} ** MAX_CLIP_POLYGON_CONTOURS;
        self.clip_polygon_points = [_][2]f32{.{ 0, 0 }} ** MAX_CLIP_POLYGON_POINTS;
        self.current_rect_clip = .{ 0, 0, -1, -1 };
        // 重置 clip 为全视口（逻辑像素）
        self.viewport_logical_width = width;
        self.clip_x_min = 0;
        self.clip_x_max = width;

        // 同步帧号到 atlas（用于页级 GC 的 last_used_frame 判断）
        self.atlas.current_frame = self.current_frame;
        self.atlas.frame_insert_count = 0;
        // 周期性 age-based GC（内部自带间隔 + 预算门控，非每帧扫描）。
        // 此前 atlas 只在页数撞到 MAX_PAGES(=512 MiB) 时才驱逐，
        // EVICT_THRESHOLD 形同虚设（审查报告 P1）。
        self.atlas.maybeCollect();

        // Atlas 页级 GC 已移至 window_render.zig 的 render() 之前执行
        // 确保 GC 回收页面后能在同帧 invalidate 渲染缓存，避免引用已释放的纹理
        self.atlas_gc_happened = false;

        // 段级缓存清理：降频 + 更长保留窗口，减少滚动抖动
        if (self.current_frame % 900 == 0) {
            self.evictStaleSegments();
            self.evictStaleFallbackFonts();
            // fallback font 被释放后，atlas 的 GlyphKey.font_ptr 可能被新 Font
            // 复用同一地址。prewarm 的跳过基线不能跨过这个点，强制下一帧重跑。
            self.prewarm_signature_valid = false;
        }
    }

    /// 仅更新 viewport 尺寸（离屏合成 render pass 切换时使用）
    /// 不重置 buffer/instances/轮转——帧内状态保持连续
    pub fn setViewport(self: *TextRenderer, width: f32, height: f32, scale: f32) void {
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
        self.viewport_logical_width = width;
        self.clip_x_min = 0;
        self.clip_x_max = width;
    }

    pub fn setClipMask(self: *TextRenderer, shape_kind: u32, rect: ?[4]f32, radius: f32, fill_rule: u32, point_count: u32, contour_count: u32, contour_end_points: [MAX_CLIP_POLYGON_CONTOURS]u8, polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32) void {
        if (rect) |mask_rect| {
            self.clip_rect = mask_rect;
            self.clip_radius = radius;
            self.clip_shape_kind = shape_kind;
            self.clip_fill_rule = fill_rule;
            self.clip_point_count = point_count;
            self.clip_contour_count = contour_count;
            for (0..MAX_CLIP_POLYGON_CONTOURS) |i| self.clip_polygon_end_points[i] = contour_end_points[i];
            self.clip_polygon_points = polygon_points;
        } else {
            self.clip_rect = .{ 0, 0, 0, 0 };
            self.clip_radius = 0;
            self.clip_shape_kind = 0;
            self.clip_fill_rule = 0;
            self.clip_point_count = 0;
            self.clip_contour_count = 0;
            self.clip_polygon_end_points = [_]u32{0} ** MAX_CLIP_POLYGON_CONTOURS;
            self.clip_polygon_points = [_][2]f32{.{ 0, 0 }} ** MAX_CLIP_POLYGON_POINTS;
        }
    }

    /// 除了记录 per-instance 的 rect_clip，还把它的 x 范围并进
    /// clip_x_min/x_max —— draw 路径的 emit 循环按这对边界做左跳过/右截断。
    /// 此前这对边界只在 beginFrame 设为整窗宽：rect clip 内的长行（split
    /// 视图的半宽代码列、横滚窗口）会一路 emit 到窗口右缘，每个不可见
    /// glyph 白付一次 atlas 查找 + instance append，最后由 GPU 按
    /// per-instance rect_clip 丢弃。CPU 侧提前截断不改变可见结果：shader
    /// 本来就画不出 rect 外的东西（负 bearing 探出的一丝与既有窗口右缘
    /// 截断同类，已被容忍）。
    ///
    /// rect 与 cursor_x 同为目标坐标系的逻辑像素（离屏 pass 下同为
    /// layer-local；encoder 的 syncRectClipState 在 pass 切换后会重推）。
    pub fn setRectClip(self: *TextRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
        if (rect) |r| {
            self.clip_x_min = @max(0, r[0]);
            self.clip_x_max = @min(self.viewport_logical_width, r[0] + r[2]);
        } else {
            self.clip_x_min = 0;
            self.clip_x_max = self.viewport_logical_width;
        }
    }

    /// 清理超过 1800 帧未使用的段级缓存条目（约 30 秒 @60fps）
    fn evictStaleSegments(self: *TextRenderer) void {
        const evict_threshold = 1800;
        var keys_buf: [128]SegmentCacheKey = undefined;
        var remove_count: usize = 0;

        var iter = self.segment_cache.iterator();
        while (iter.next()) |entry| {
            if (self.current_frame - entry.value_ptr.frame_last_used > evict_threshold) {
                if (remove_count < keys_buf.len) {
                    keys_buf[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }
        for (keys_buf[0..remove_count]) |key| {
            if (self.segment_cache.fetchRemove(key)) |kv| {
                releaseGlyphFallbackFontRefs(kv.value.glyphs_buf[0..kv.value.glyph_count]);
            }
        }
    }

    fn destroyFallbackFontEntry(self: *TextRenderer, entry: FallbackFontCacheEntry) void {
        // atlas 以 Font 堆地址为键；wrapper 释放后地址会被下一个 wrapper 复用，
        // 不先摘条目就会让新字体命中旧字体的位图（画错字形）。
        self.atlas.forgetFont(@intFromPtr(entry.font));
        entry.font.deinit();
    }

    fn evictStaleFallbackFonts(self: *TextRenderer) void {
        const evict_threshold = 1800;
        var keys_buf: [64]usize = undefined;
        var remove_count: usize = 0;

        var iter = self.fallback_font_cache.iterator();
        while (iter.next()) |entry| {
            if (self.current_frame - entry.value_ptr.frame_last_used > evict_threshold) {
                if (remove_count < keys_buf.len) {
                    keys_buf[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }

        for (keys_buf[0..remove_count]) |key| {
            if (self.fallback_font_cache.fetchRemove(key)) |kv| {
                self.destroyFallbackFontEntry(kv.value);
            }
        }
    }

    /// 段级缓存满时驱逐：先删 >300 帧未用的；若仍满，清除一半
    fn evictSegmentCacheOnFull(self: *TextRenderer) void {
        // 第一轮：删除 >300 帧未使用的条目
        const threshold = 300;
        var keys_buf: [256]SegmentCacheKey = undefined;
        var remove_count: usize = 0;

        var iter = self.segment_cache.iterator();
        while (iter.next()) |entry| {
            if (self.current_frame - entry.value_ptr.frame_last_used > threshold) {
                if (remove_count < keys_buf.len) {
                    keys_buf[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }
        for (keys_buf[0..remove_count]) |key| {
            if (self.segment_cache.fetchRemove(key)) |kv| {
                releaseGlyphFallbackFontRefs(kv.value.glyphs_buf[0..kv.value.glyph_count]);
            }
        }

        // 若仍满，暴力清除一半
        if (self.segment_cache.count() >= SEGMENT_CACHE_MAX) {
            var iter2 = self.segment_cache.iterator();
            var half = self.segment_cache.count() / 2;
            var keys2: [256]SegmentCacheKey = undefined;
            var c2: usize = 0;
            while (half > 0) {
                if (iter2.next()) |entry| {
                    if (c2 < keys2.len) {
                        keys2[c2] = entry.key_ptr.*;
                        c2 += 1;
                        half -= 1;
                    }
                    if (c2 == keys2.len) {
                        for (keys2[0..c2]) |k| {
                            if (self.segment_cache.fetchRemove(k)) |kv| {
                                releaseGlyphFallbackFontRefs(kv.value.glyphs_buf[0..kv.value.glyph_count]);
                            }
                        }
                        c2 = 0;
                    }
                } else break;
            }
            for (keys2[0..c2]) |k| {
                if (self.segment_cache.fetchRemove(k)) |kv| {
                    releaseGlyphFallbackFontRefs(kv.value.glyphs_buf[0..kv.value.glyph_count]);
                }
            }
        }
    }

    fn evictFallbackFontsOnFull(self: *TextRenderer) void {
        var keys_buf: [64]u64 = undefined;
        var remove_count: usize = 0;
        const threshold = 300;

        var iter = self.fallback_font_cache.iterator();
        while (iter.next()) |entry| {
            if (self.current_frame - entry.value_ptr.frame_last_used > threshold) {
                if (remove_count < keys_buf.len) {
                    keys_buf[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }

        for (keys_buf[0..remove_count]) |key| {
            if (self.fallback_font_cache.fetchRemove(key)) |kv| {
                self.destroyFallbackFontEntry(kv.value);
            }
        }

        if (self.fallback_font_cache.count() >= FALLBACK_FONT_CACHE_MAX) {
            var iter2 = self.fallback_font_cache.iterator();
            var half = self.fallback_font_cache.count() / 2;
            var keys2: [64]u64 = undefined;
            var c2: usize = 0;
            while (half > 0) {
                if (iter2.next()) |entry| {
                    if (c2 < keys2.len) {
                        keys2[c2] = entry.key_ptr.*;
                        c2 += 1;
                        half -= 1;
                    }
                    if (c2 == keys2.len) {
                        for (keys2[0..c2]) |k| {
                            if (self.fallback_font_cache.fetchRemove(k)) |kv| {
                                self.destroyFallbackFontEntry(kv.value);
                            }
                        }
                        c2 = 0;
                    }
                } else break;
            }
            for (keys2[0..c2]) |k| {
                if (self.fallback_font_cache.fetchRemove(k)) |kv| {
                    self.destroyFallbackFontEntry(kv.value);
                }
            }
        }
    }

    /// 绘制文本
    fn getOrCreateGlyphFallbackFont(self: *TextRenderer, fallback_font_ref: *anyopaque, prototype: *Font) !*Font {
        // 键必须是字体**身份**（PS 名+size+traits），不能是 CTFontRef 指针：
        // CoreText 每次 shape 给的 run 级 fallback ref 不是稳定实例。指针作键
        // 的实测后果（2026-08-22 定案，用户可见 bug）：
        //   1. wrapper 每帧全量 miss —— 滚动 CJK 文档 240 帧创建 36.8 万个
        //      wrapper Font（缓存 256 上限被打成 130↔194 的驱逐抖动）；
        //   2. wrapper 堆地址进 GlyphKey.font_ptr → 同一字形以无数“新字体”
        //      重复收录进 glyph atlas → 32 页耗尽 → AtlasFull → 后续 CJK 字形
        //      被静默丢弃（中文逐字消失、位置留白、ASCII 因主字体指针稳定而
        //      不受影响）；地址被 allocator 复用时则是键混叠，指鹿为马。
        const key = text_module.fallbackFontRefIdentityHash(fallback_font_ref);
        if (self.fallback_font_cache.getPtr(key)) |cached| {
            cached.frame_last_used = self.current_frame;
            cached.font.scale_factor = prototype.scale_factor;
            return cached.font;
        }

        if (self.fallback_font_cache.count() >= FALLBACK_FONT_CACHE_MAX) {
            self.evictFallbackFontsOnFull();
        }

        fallback_wrappers_created_total += 1;
        const ct_size = text_module.fallbackFontRefSize(fallback_font_ref);
        const requested_size = if (std.math.isFinite(ct_size) and ct_size > 0) ct_size else prototype.pixelSize();
        const size_px: f32 = if (std.math.isFinite(requested_size)) std.math.clamp(requested_size, 1, 4096) else 1;
        const fallback_font = try self.allocator.create(Font);
        // Font wrapper 独立 retain CTFontRef，不依赖段级缓存的引用生命周期。
        // 段级缓存淘汰时会 release 自己的 retain，不影响此处的引用。
        text_module.retainFallbackFontRef(fallback_font_ref);
        fallback_font.* = .{
            .allocator = self.allocator,
            .ct_font = fallback_font_ref,
            .size = @intFromFloat(@round(size_px)),
            .size_px = size_px,
            .weight = prototype.weight,
            .scale_factor = prototype.scale_factor,
        };
        // Font.deinit 既 release 上面那次 retain，也 destroy wrapper 堆块本身
        // （见 font_system.zig Font.deinit）；这里再 destroy 一次就是 double free。
        errdefer fallback_font.deinit();
        try self.fallback_font_cache.put(key, .{
            .font = fallback_font,
            .frame_last_used = self.current_frame,
        });
        return fallback_font;
    }

    /// 接上应用的显式字体回退栈。传 null 断开（回到纯级联行为）。
    /// 栈必须比本 renderer 活得久（应用层持有）。
    pub fn setFallbackStack(self: *TextRenderer, stack: ?*FontFallbackStack) void {
        if (self.fallback_stack == stack) return;
        self.fallback_stack = stack;
        self.primary_coverage_cache.clearRetainingCapacity();
        // 字体选择变了 → prewarm 的「上一帧字形必然已驻留」基线失效。
        self.prewarm_signature_valid = false;
    }

    fn primaryCoversCodepoint(self: *TextRenderer, font: *Font, cp: u21) bool {
        const key = PrimaryCovKey{ .font_ptr = @intFromPtr(font), .cp = cp };
        if (self.primary_coverage_cache.get(key)) |covered| return covered;
        const covered = font.glyphIndexForCodepoint(cp) != 0;
        if (self.primary_coverage_cache.count() >= PRIMARY_COVERAGE_CACHE_MAX) {
            self.primary_coverage_cache.clearRetainingCapacity();
        }
        self.primary_coverage_cache.put(key, covered) catch {};
        return covered;
    }

    /// shaping **前**的显式字体选择（CSS font-family 语义）：
    /// 段首码点 → primary 覆盖则 primary（隐式栈首），否则问回退栈拿第一个
    /// 覆盖它的族的字体，用它直接 shape —— 选择确定、CTFont 由我们持有
    /// （指针稳定）、跳过 CoreText 级联开销。都答不上才维持 primary，
    /// 让 run 级联做最后兜底（emoji、罕见符号）。
    ///
    /// 判定只看段首码点：segmentText 已把 CJK 切成单码点段，混脚本段
    /// （RTL/emoji 序列）本来就该整段一个字体。ASCII 段第一字节 < 0x80
    /// 直接短路 —— ASCII 热路径零开销。
    ///
    /// ⚠ draw（shapeAndEmitSegment*）与 measure（measureTextWidthAsDrawn）
    /// 必须都走这里 —— 单边接入就是「量出来和画出来不一样宽」的老病复发。
    fn selectSegmentFont(self: *TextRenderer, seg_text: []const u8, font: *Font, requested_size: f32) *Font {
        const stack = self.fallback_stack orelse return font;
        if (seg_text.len == 0 or seg_text[0] < 0x80) return font;
        const seq_len = std.unicode.utf8ByteSequenceLength(seg_text[0]) catch return font;
        if (seq_len > seg_text.len) return font;
        const cp = std.unicode.utf8Decode(seg_text[0..seq_len]) catch return font;
        if (self.primaryCoversCodepoint(font, cp)) return font;
        if (stack.selectForCodepoint(cp, requested_size, font.weight)) |stack_font| {
            // 与 fallback wrapper 同款的 scale 跟随：栈字体是共享实例，
            // 光栅尺寸必须跟当前绘制上下文的 DPI 走。
            stack_font.scale_factor = font.scale_factor;
            return stack_font;
        }
        return font;
    }

    /// selectSegmentFont 之上的 EmitParams 适配：栈字体与主字体可能是不同
    /// pixelSize 的实例，advance/offset 的 shaping 缩放必须按段字体重算。
    /// use_subpixel 关闭：维持与既有级联回退一致的整像素光栅路径，避免
    /// CJK 大字符集 × 亚像素分箱把 glyph atlas 撑爆（那是本功能要埋葬的
    /// 事故，不能换个姿势再来一次）。
    fn emitParamsForSegmentFont(p: EmitParams, seg_font: *Font) EmitParams {
        var seg_p = p;
        seg_p.font = seg_font;
        seg_p.fallback_font = seg_font;
        const seg_px = seg_font.pixelSize();
        if (p.requested_size > 0 and seg_px > 0) {
            seg_p.layout_scale = p.requested_size / seg_px;
        }
        seg_p.use_subpixel = false;
        return seg_p;
    }

    fn selectRenderFontForGlyph(self: *TextRenderer, glyph: text_module.ShapedGlyph, p: EmitParams) !*Font {
        if (glyph.is_fallback_font) {
            if (glyph.fallback_font_ref) |fallback_font_ref| {
                return self.getOrCreateGlyphFallbackFont(fallback_font_ref, p.font);
            }
            if (p.fallback_font) |fallback_font| {
                return fallback_font;
            }
        }
        if (glyph.is_synthetic_italic and p.fallback_font != null) {
            return p.fallback_font.?;
        }
        return p.font;
    }

    fn releaseGlyphFallbackFontRefs(glyphs: []const text_module.ShapedGlyph) void {
        for (glyphs) |glyph| {
            if (glyph.fallback_font_ref) |fallback_font_ref| {
                text_module.releaseFallbackFontRef(fallback_font_ref);
            }
        }
    }

    fn logEnclosedDigitFontDebug(
        self: *TextRenderer,
        seg_text: []const u8,
        font: *Font,
        use_italic: bool,
        fallback_hint: ?*Font,
        glyphs: []const text_module.ShapedGlyph,
        source: []const u8,
    ) void {
        if (font_debug_budget == 0 or !containsEnclosedDigit(seg_text)) return;
        font_debug_budget -= 1;

        const base_name_owned = font.debugName(self.allocator);
        defer if (base_name_owned) |name| self.allocator.free(name);
        const fallback_hint_owned = if (fallback_hint) |f| f.debugName(self.allocator) else null;
        defer if (fallback_hint_owned) |name| self.allocator.free(name);

        const base_name = base_name_owned orelse "<base-font-name-unavailable>";
        const hint_name = fallback_hint_owned orelse "<no-fallback-hint>";

        std.log.warn("[FontDebug] seg=\"{s}\" source={s} base={s} hint={s} italic={} glyphs={d}", .{
            seg_text,
            source,
            base_name,
            hint_name,
            use_italic,
            glyphs.len,
        });

        for (glyphs, 0..) |glyph, idx| {
            const run_name_owned = if (glyph.fallback_font_ref) |font_ref|
                text_module.fallbackFontRefDebugName(self.allocator, font_ref)
            else
                null;
            defer if (run_name_owned) |name| self.allocator.free(name);

            const run_name = run_name_owned orelse if (glyph.is_fallback_font) hint_name else base_name;
            std.log.warn("[FontDebug] seg=\"{s}\" glyph#{d} cluster={d} gid={d} adv={d:.2} fallback={} synth_italic={} run={s}", .{
                seg_text,
                idx,
                glyph.cluster,
                glyph.glyph_index,
                glyph.x_advance,
                glyph.is_fallback_font,
                glyph.is_synthetic_italic,
                run_name,
            });
        }
    }

    /// Glyph emit 参数包（避免函数参数过多）
    const EmitParams = struct {
        requested_size: f32,
        /// Shaping 空间缩放（用于 x_advance / x_offset / y_offset）
        layout_scale: f32,
        scale: f32,
        use_subpixel: bool,
        snap_to_device_pixels: bool,
        /// vertex shader 是否对 position 做物理像素 round（写进 GlyphInstance.shader_snap）。
        /// 与 snap_to_device_pixels 必须同源派生：CPU 吸附 + shader 吸附是幂等组合，
        /// CPU 不吸附 + shader 吸附是 direct_animated 抖动根因（两侧合同见 text_blob.TextRasterPolicy）。
        shader_snap: bool,
        synthetic_skew: f32,
        font: *Font,
        fallback_font: ?*Font,
        instance_list: *std.ArrayList(GlyphInstance),
        fixed_advance: f32 = 0,
    };

    /// 取 glyphs[i] 的 cluster_span = next_cluster - cur_cluster，最后一个 glyph 用 segment 末尾 byte 偏移。
    /// fixed_advance 模式下用此 span 把 ligature glyph 推进 N 格，保持 byte_col → pixel_x 恒等式。
    fn clusterSpanAt(glyphs: []const text_module.ShapedGlyph, idx: usize, segment_end_byte: u32) u32 {
        const cur = glyphs[idx].cluster;
        const next = if (idx + 1 < glyphs.len) glyphs[idx + 1].cluster else segment_end_byte;
        return if (next > cur) next - cur else 1;
    }

    /// `cluster_span` 是该 glyph 覆盖的源 byte 数 (`next_cluster - glyph.cluster`)。
    /// 在 fixed_advance 模式下，ligature glyph 的 cluster_span > 1，需要按 N × cell 推进
    /// 以保持 byte_col → pixel_x = byte_col × cell_width 的恒等式。
    fn glyphAdvance(glyph: text_module.ShapedGlyph, cluster_span: u32, p: EmitParams) f32 {
        const advance = glyph.x_advance * p.layout_scale;
        if (p.fixed_advance > 0 and !glyph.is_fallback_font) {
            const cells: f32 = @floatFromInt(@max(cluster_span, 1));
            return p.fixed_advance * cells;
        }
        return advance;
    }

    /// 注意：fixed_advance 模式下不能强制 clamp glyph_x >= cell_x。
    /// JetBrains Mono 的 calt overhang（如 `less_slash.liga` xMin=-470）依赖
    /// 字形从 cell 起点向左延伸来形成 `</` 视觉连字 — 强行 clamp 会让 alt 字形
    /// 被推回 cell 内，与右侧字符重叠。让字体自己负 bearing 决定位置。
    fn clampFixedAdvanceGlyphX(x: f32, cell_x: f32, glyph: text_module.ShapedGlyph, p: EmitParams) f32 {
        _ = cell_x;
        _ = glyph;
        _ = p;
        return x;
    }

    /// 将单个 ShapedGlyph 转为 GlyphInstance 并追加到 instance list
    /// 返回 cursor_x 增量 (glyph.x_advance * text_scale)
    fn emitGlyphInstance(
        self: *TextRenderer,
        glyph: text_module.ShapedGlyph,
        cluster_span: u32,
        cursor_x: f32,
        cursor_y: f32,
        raw_glyph_color: Color,
        p: EmitParams,
    ) !f32 {
        // 右端淡出遮罩：逐 glyph 按左缘位置调制 alpha（见 fade_x0/x1 注释）。
        // 所有 draw 路径（含 spans 逐 glyph 着色）都汇到这里，单点生效。
        var glyph_color = raw_glyph_color;
        if (cursor_x >= self.fade_x0) {
            const span_w = self.fade_x1 - self.fade_x0;
            const keep: f32 = if (span_w > 0)
                std.math.clamp((self.fade_x1 - cursor_x) / span_w, 0, 1)
            else
                0;
            glyph_color.a *= keep;
        }
        const render_font = try self.selectRenderFontForGlyph(glyph, p);
        const layout_scale = p.layout_scale;
        const render_font_px = render_font.pixelSize();
        // bitmap_scale 只作用于 bearing/bitmap 尺寸；layout_scale 继续作用于 shaping 偏移与 advance。
        const bitmap_scale: f32 = if (p.requested_size > 0 and render_font_px > 0)
            p.requested_size / render_font_px
        else
            layout_scale;

        const cur_instance_list = if (glyph.is_synthetic_italic)
            &self.instances_linear
        else
            p.instance_list;

        if (p.use_subpixel and !glyph.is_synthetic_italic and !glyph.is_fallback_font) {
            const phys_x = (cursor_x + glyph.x_offset * layout_scale) * p.scale;
            const fract_x = phys_x - @floor(phys_x);
            const x_bin = atlas_mod.subpixelBin(fract_x);
            const bin_packed = atlas_mod.packSubpixelBin(x_bin, 0);

            const region = self.atlas.getOrInsertSubpixel(render_font, glyph.glyph_index, bin_packed) catch {
                return glyphAdvance(glyph, cluster_span, p);
            };
            if (region.width == 0 or region.height == 0) {
                return glyphAdvance(glyph, cluster_span, p);
            }
            // prewarm：字形已进 atlas，实例不用产（见 glyph_only 注释）。
            if (self.glyph_only) return glyphAdvance(glyph, cluster_span, p);

            const sp_bearing_x: f32 = @as(f32, @floatFromInt(region.bearing_x)) / render_font.scale_factor;
            const sp_bearing_y: f32 = @as(f32, @floatFromInt(region.bearing_y)) / render_font.scale_factor;
            const raw_final_x = cursor_x + glyph.x_offset * layout_scale + sp_bearing_x * bitmap_scale;
            const final_x = clampFixedAdvanceGlyphX(raw_final_x, cursor_x, glyph, p);
            const final_y = cursor_y + glyph.y_offset * layout_scale - sp_bearing_y * bitmap_scale;
            const snap_x = if (p.snap_to_device_pixels) @round(final_x * p.scale) / p.scale else final_x;
            const snap_y = if (p.snap_to_device_pixels) @round(final_y * p.scale) / p.scale else final_y;

            const region_w: f32 = @floatFromInt(region.width);
            const region_h: f32 = @floatFromInt(region.height);
            try p.instance_list.append(self.allocator, .{
                .position = .{ snap_x, snap_y },
                .size = .{
                    (region_w / render_font.scale_factor) * bitmap_scale,
                    (region_h / render_font.scale_factor) * bitmap_scale,
                },
                .uv_rect = .{
                    region.uv_min[0],
                    region.uv_min[1],
                    region.uv_max[0],
                    region.uv_max[1],
                },
                .color = glyph_color.toArray(),
                .rect_clip = self.current_rect_clip,
                .page_index = @floatFromInt(region.page_index),
                .is_color = if (region.is_color) 1 else 0,
                .shader_snap = if (p.shader_snap) 1 else 0,
            });
        } else {
            const region = try self.atlas.getOrInsert(render_font, glyph.glyph_index);
            if (region.width == 0 or region.height == 0) {
                return glyphAdvance(glyph, cluster_span, p);
            }
            // prewarm：同上，只要字形进了 atlas 就够了。
            if (self.glyph_only) return glyphAdvance(glyph, cluster_span, p);

            const bearing_x: f32 = @as(f32, @floatFromInt(region.bearing_x)) / render_font.scale_factor;
            const bearing_y: f32 = @as(f32, @floatFromInt(region.bearing_y)) / render_font.scale_factor;
            const raw_glyph_x = cursor_x + glyph.x_offset * layout_scale + bearing_x * bitmap_scale;
            const glyph_x = clampFixedAdvanceGlyphX(raw_glyph_x, cursor_x, glyph, p);
            const glyph_y = cursor_y + glyph.y_offset * layout_scale - bearing_y * bitmap_scale;
            const snap_x = if (p.snap_to_device_pixels) @round(glyph_x * p.scale) / p.scale else glyph_x;
            const snap_y = if (p.snap_to_device_pixels) @round(glyph_y * p.scale) / p.scale else glyph_y;

            const region_w: f32 = @floatFromInt(region.width);
            const region_h: f32 = @floatFromInt(region.height);
            try cur_instance_list.append(self.allocator, .{
                .position = .{ snap_x, snap_y },
                .size = .{
                    (region_w / render_font.scale_factor) * bitmap_scale,
                    (region_h / render_font.scale_factor) * bitmap_scale,
                },
                .uv_rect = .{
                    region.uv_min[0],
                    region.uv_min[1],
                    region.uv_max[0],
                    region.uv_max[1],
                },
                .color = glyph_color.toArray(),
                .rect_clip = self.current_rect_clip,
                .skew_x = if (glyph.is_synthetic_italic) p.synthetic_skew else 0,
                .page_index = @floatFromInt(region.page_index),
                .is_color = if (region.is_color) 1 else 0,
                .shader_snap = if (p.shader_snap) 1 else 0,
            });
        }

        return glyphAdvance(glyph, cluster_span, p);
    }

    /// lookupOrShapeSegment 的返回值：glyphs 要么借自缓存、要么归调用方所有。
    ///
    /// owned=true 时调用方必须 `releaseGlyphFallbackFontRefs` + `free`；
    /// owned=false 时内存与其中 fallback_font_ref 的 retain 都归缓存，
    /// 由 evict/deinit 统一释放，调用方只在本次 draw 内借用。
    const SegmentGlyphs = struct {
        glyphs: []const text_module.ShapedGlyph,
        owned: bool,
    };

    /// 段级缓存查找/插入。miss 时 shape 一次：能进缓存就进缓存（借出），
    /// 进不了（超长 / put 失败）就把这次 shape 的结果**连所有权一起交给
    /// 调用方**，绝不丢弃重来 —— 旧实现对超长段先 shape、发现超限后 free
    /// 掉返回 null，调用方拿到 null 再 shape 一遍：代码行里最长的那几个段
    /// （标识符/调用表达式）每帧每行付两次 CTLine 创建，git diff 滚动实测
    /// encode 的大头就是它。丢弃路径还只 free 不 release fallback_font_ref，
    /// 含 fallback 字形的长段会泄漏 CTFontRef 的 retain。
    fn lookupOrShapeSegment(
        self: *TextRenderer,
        seg_text: []const u8,
        font: *Font,
        use_italic: bool,
    ) !SegmentGlyphs {
        const italic_flag: u8 = if (use_italic) 1 else 0;
        const cache_key = SegmentCacheKey{
            .content_hash = std.hash.Wyhash.hash(@as(u64, italic_flag), seg_text),
            .font_ptr = @intFromPtr(font),
            .flags = italic_flag,
        };

        if (self.segment_cache.getPtr(cache_key)) |entry| {
            entry.frame_last_used = self.current_frame;
            return .{ .glyphs = entry.glyphs_buf[0..entry.glyph_count], .owned = false };
        }

        if (self.cache_long_segments) {
            if (self.long_segment_cache.get(cache_key, seg_text, self.current_frame)) |glyphs|
                return .{ .glyphs = glyphs, .owned = false };
        }

        // cache miss — shape 这个段
        const shaped = try self.shaper.shapeWithOptions(seg_text, font, use_italic);

        // 超过内联容量时尝试有界长段缓存；失败仍把所有权交给调用方。
        if (shaped.len > MAX_SEGMENT_GLYPHS) {
            const cached = self.cache_long_segments and self.long_segment_cache.adopt(self.allocator, cache_key, seg_text, shaped, self.current_frame);
            return .{ .glyphs = shaped, .owned = !cached };
        }

        // 缓存满时驱逐
        if (self.segment_cache.count() >= SEGMENT_CACHE_MAX) {
            self.evictSegmentCacheOnFull();
        }

        var entry = SegmentCacheEntry{
            .glyph_count = @intCast(shaped.len),
            .frame_last_used = self.current_frame,
        };
        @memcpy(entry.glyphs_buf[0..shaped.len], shaped);
        const gop = self.segment_cache.getOrPut(cache_key) catch {
            // put 失败（极罕见）：条目没进缓存，refs 无人接管，所有权交回调用方。
            // 旧实现在这里把栈上 entry 连同已 memcpy 进去的 fallback refs 一起
            // 丢掉 —— 每个 ref 泄漏一个 retain。
            return .{ .glyphs = shaped, .owned = true };
        };
        gop.value_ptr.* = entry;
        // fallback_font_ref 的 retain 已随 memcpy 进缓存条目（唯一一份，
        // 由 evict/deinit release）；heap slice 本身不再承载所有权，直接还。
        self.allocator.free(shaped);
        return .{ .glyphs = gop.value_ptr.glyphs_buf[0..gop.value_ptr.glyph_count], .owned = false };
    }

    /// 一段文本**实际会被画成多宽** —— 与 drawTextWithOptions 的 emit 循环
    /// 同一套分段、同一个 shaper、同一份 glyphAdvance 公式，只是不 emit。
    ///
    /// == 为什么布局必须用这个,而不是另测一次 ==
    /// `.fit` 宽度本质是「先测一次、再画一次」,两次答案不一致 = 容器按 A 收紧、
    /// 字按 B 画,尾部被裁。而绘制端的宽度并不是"文本 + 字号"的纯函数,它还取决于:
    ///   1. 用哪个 *Font shape（italic/mono/symbols/脚本回退各选各的）
    ///   2. **分段方式** —— 绘制按 segmentText 逐段 shape(CJK 逐码点、ASCII 成词),
    ///      整串一次 shape 会多出跨段 kerning/连字,与逐段累加的结果不等
    ///   3. fixed_advance(等宽网格)对 ligature 的按格推进
    /// 任何"重新实现一遍测量"的函数都必须同时复刻这三条才可能对得上,而它们会
    /// 各自演进 —— 于是分岔是必然的,不是偶然的。所以这里不提供第二套算法,
    /// 只提供**同一套算法的不 emit 版本**。
    ///
    /// 参数与 drawTextWithOptions 一一对应,调用方必须原样传它给渲染时会传的值。
    pub fn measureTextWidthAsDrawn(
        self: *TextRenderer,
        text: []const u8,
        font: *Font,
        requested_size: f32,
        use_italic: bool,
        fixed_advance: f32,
    ) !f32 {
        if (text.len == 0) return 0;
        const font_physical_size = font.pixelSize();
        const text_scale: f32 = if (requested_size > 0 and font_physical_size > 0)
            requested_size / font_physical_size
        else
            1.0;

        var total: f32 = 0;
        var seg_buf: [MAX_SEGMENTS]Segment = undefined;
        var text_pos: u32 = 0;
        while (text_pos < text.len) {
            const remaining = text[text_pos..];
            const seg_count = segmentText(remaining, &seg_buf);
            const effective_count = @min(seg_count, MAX_SEGMENTS);
            for (seg_buf[0..effective_count]) |seg| {
                const seg_text = remaining[seg.start..seg.end];
                const seg_end_byte: u32 = @intCast(seg_text.len);
                // 显式字体栈：与 draw 的 emit 循环**同一个** selectSegmentFont。
                // 单边接入 = 量的和画的不是一个字体，.fit 容器裁尾巴的老病复发。
                const seg_font = self.selectSegmentFont(seg_text, font, requested_size);
                const seg_px = seg_font.pixelSize();
                const seg_scale: f32 = if (requested_size > 0 and seg_px > 0)
                    requested_size / seg_px
                else
                    text_scale;
                const shaped = try self.lookupOrShapeSegment(seg_text, seg_font, use_italic);
                defer if (shaped.owned) {
                    releaseGlyphFallbackFontRefs(shaped.glyphs);
                    self.allocator.free(shaped.glyphs);
                };
                for (shaped.glyphs, 0..) |g, i| {
                    const span = clusterSpanAt(shaped.glyphs, i, seg_end_byte);
                    // glyphAdvance 只用到 layout_scale / fixed_advance 两项,
                    // 其余 emit 相关字段与宽度无关,给零值即可。
                    total += glyphAdvance(g, span, .{
                        .requested_size = requested_size,
                        .layout_scale = seg_scale,
                        .scale = self.scale_factor,
                        .use_subpixel = false,
                        .snap_to_device_pixels = false,
                        .shader_snap = false,
                        .synthetic_skew = 0,
                        .font = font,
                        .fallback_font = null,
                        .instance_list = &self.instances_nearest,
                        .fixed_advance = fixed_advance,
                    });
                }
            }
            if (effective_count > 0) {
                text_pos += seg_buf[effective_count - 1].end;
            } else break;
            if (seg_count <= MAX_SEGMENTS) break;
        }
        return total;
    }

    pub fn drawTextWithOptions(
        self: *TextRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        font: *Font,
        color: Color,
        requested_size: f32,
        use_italic: bool,
        fallback_font: ?*Font,
        force_linear: bool,
        shader_snap: bool,
        fixed_advance: f32,
    ) !void {
        const instances_before = self.instances_nearest.items.len + self.instances_linear.items.len;

        // 计算缩放因子: UI 请求大小 / 字体物理大小
        const font_physical_size = font.pixelSize();
        const text_scale: f32 = if (requested_size > 0 and font_physical_size > 0)
            requested_size / font_physical_size
        else
            1.0;
        const use_nearest = !force_linear and @abs(text_scale - 1.0) <= 0.01;
        const use_subpixel = use_nearest and self.scale_factor > 0;
        const scale = self.scale_factor;
        const synthetic_skew: f32 = requested_size * 0.75 * 0.2126;
        const instance_list = if (use_nearest) &self.instances_nearest else &self.instances_linear;

        const emit_params = EmitParams{
            .requested_size = requested_size,
            .layout_scale = text_scale,
            .scale = scale,
            .use_subpixel = use_subpixel,
            .snap_to_device_pixels = !force_linear,
            .shader_snap = shader_snap,
            .synthetic_skew = synthetic_skew,
            .font = font,
            .fallback_font = fallback_font,
            .instance_list = instance_list,
            .fixed_advance = fixed_advance,
        };

        // 水平视口裁剪边界（逻辑像素）
        const clip_left = self.clip_x_min;
        const clip_right = self.clip_x_max;

        // 段分割 + 逐段渲染（统一路径，溢出时自动续分）
        var cursor_x = x;
        var seg_buf: [MAX_SEGMENTS]Segment = undefined;
        var text_pos: u32 = 0; // 已处理到的字节偏移

        while (text_pos < text.len) {
            if (cursor_x > clip_right) break;

            // 对剩余文本做段分割
            const remaining = text[text_pos..];
            const seg_count = segmentText(remaining, &seg_buf);
            const effective_count = @min(seg_count, MAX_SEGMENTS);

            for (seg_buf[0..effective_count]) |seg| {
                if (cursor_x > clip_right) break;

                const seg_text = remaining[seg.start..seg.end];
                cursor_x = try self.shapeAndEmitSegment(seg_text, cursor_x, y, color, clip_left, text_scale, font, use_italic, emit_params);
            }

            // 更新已处理偏移
            if (effective_count > 0) {
                text_pos += seg_buf[effective_count - 1].end;
            } else {
                break; // 无法分段（空文本），退出
            }

            // 未溢出则已处理完全部文本
            if (seg_count <= MAX_SEGMENTS) break;
        }

        const instances_after = self.instances_nearest.items.len + self.instances_linear.items.len;
        if (text.len > 0 and instances_after == instances_before) {
            text_trace.log(
                self.current_frame,
                "draw-text-no-instances hash=0x{x} len={d} x={d:.1} y={d:.1} size={d:.1} linear={} clip=[{d:.1},{d:.1}]",
                .{
                    std.hash.Wyhash.hash(0, text),
                    text.len,
                    x,
                    y,
                    requested_size,
                    force_linear,
                    clip_left,
                    clip_right,
                },
            );
        }
    }

    /// 辅助：shape 并 emit 单个文本段（无 span），返回更新后的 cursor_x。
    /// 支持左边界跳过（shape 后不 emit）和段级缓存。
    fn shapeAndEmitSegment(
        self: *TextRenderer,
        seg_text: []const u8,
        cursor_x_in: f32,
        y: f32,
        color: Color,
        clip_left: f32,
        _: f32,
        font: *Font,
        use_italic: bool,
        p: EmitParams,
    ) !f32 {
        var cursor_x = cursor_x_in;

        const seg_end_byte: u32 = @intCast(seg_text.len);
        // 显式字体栈：shaping 前按段首码点选字体（见 selectSegmentFont）。
        const seg_font = self.selectSegmentFont(seg_text, font, p.requested_size);
        const seg_p = if (seg_font != font) emitParamsForSegmentFont(p, seg_font) else p;
        const seg = try self.lookupOrShapeSegment(seg_text, seg_font, use_italic);
        defer if (seg.owned) {
            releaseGlyphFallbackFontRefs(seg.glyphs);
            self.allocator.free(seg.glyphs);
        };
        const glyphs = seg.glyphs;
        self.logEnclosedDigitFontDebug(seg_text, seg_font, use_italic, seg_p.fallback_font, glyphs, if (seg.owned) "fresh-shape" else "segment-cache");
        if (cursor_x < clip_left) {
            var adv: f32 = 0;
            for (glyphs, 0..) |g, i| adv += glyphAdvance(g, clusterSpanAt(glyphs, i, seg_end_byte), seg_p);
            if (cursor_x + adv < clip_left) return cursor_x + adv;
        }
        for (glyphs, 0..) |g, i| {
            const span = clusterSpanAt(glyphs, i, seg_end_byte);
            cursor_x += try self.emitGlyphInstance(g, span, cursor_x, y, color, seg_p);
        }
        return cursor_x;
    }

    /// 文本颜色 span — 用于 drawTextWithSpans 逐 glyph 着色
    pub const ColorSpan = struct {
        start: u32, // content 中的字节偏移
        end: u32,
        color: Color,
    };

    /// 整行一次塑形 + 逐 glyph 按 span 着色（段级缓存版）
    pub fn drawTextWithSpans(
        self: *TextRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        font: *Font,
        base_color: Color,
        requested_size: f32,
        use_italic: bool,
        fallback_font: ?*Font,
        force_linear: bool,
        shader_snap: bool,
        fixed_advance: f32,
        spans: []const ColorSpan,
    ) !void {
        const font_physical_size = font.pixelSize();
        const text_scale: f32 = if (requested_size > 0 and font_physical_size > 0)
            requested_size / font_physical_size
        else
            1.0;
        const use_nearest = !force_linear and @abs(text_scale - 1.0) <= 0.01;
        const use_subpixel = use_nearest and self.scale_factor > 0;
        const scale = self.scale_factor;
        const synthetic_skew: f32 = requested_size * 0.75 * 0.2126;
        const instance_list = if (use_nearest) &self.instances_nearest else &self.instances_linear;

        const emit_params = EmitParams{
            .requested_size = requested_size,
            .layout_scale = text_scale,
            .scale = scale,
            .use_subpixel = use_subpixel,
            .snap_to_device_pixels = !force_linear,
            .shader_snap = shader_snap,
            .synthetic_skew = synthetic_skew,
            .font = font,
            .fallback_font = fallback_font,
            .instance_list = instance_list,
            .fixed_advance = fixed_advance,
        };

        // 水平视口裁剪边界（逻辑像素）
        const clip_left = self.clip_x_min;
        const clip_right = self.clip_x_max;

        // 段分割 + 逐段渲染（统一路径，溢出时自动续分）
        var cursor_x = x;
        var span_idx: usize = 0;
        var seg_buf: [MAX_SEGMENTS]Segment = undefined;
        var text_pos: u32 = 0;

        while (text_pos < text.len) {
            if (cursor_x > clip_right) break;

            const remaining = text[text_pos..];
            const seg_count = segmentText(remaining, &seg_buf);
            const effective_count = @min(seg_count, MAX_SEGMENTS);

            for (seg_buf[0..effective_count]) |seg| {
                if (cursor_x > clip_right) break;

                const seg_text = remaining[seg.start..seg.end];
                // 全局字节偏移 = text_pos + seg 内偏移（用于 span 匹配）
                const global_start = text_pos + seg.start;
                const global_end = text_pos + seg.end;
                cursor_x = try self.shapeAndEmitSegmentWithSpans(seg_text, global_start, cursor_x, y, base_color, clip_left, text_scale, font, use_italic, emit_params, spans, &span_idx, global_end);
            }

            if (effective_count > 0) {
                text_pos += seg_buf[effective_count - 1].end;
            } else {
                break;
            }

            if (seg_count <= MAX_SEGMENTS) break;
        }
    }

    /// 辅助：shape 并 emit 单个带 spans 的文本段，返回更新后的 cursor_x。
    fn shapeAndEmitSegmentWithSpans(
        self: *TextRenderer,
        seg_text: []const u8,
        global_byte_start: u32,
        cursor_x_in: f32,
        y: f32,
        base_color: Color,
        clip_left: f32,
        _: f32,
        font: *Font,
        use_italic: bool,
        p: EmitParams,
        spans: []const ColorSpan,
        span_idx: *usize,
        global_byte_end: u32,
    ) !f32 {
        var cursor_x = cursor_x_in;

        // 显式字体栈：与 shapeAndEmitSegment 同一套 shaping 前选择。
        const seg_font = self.selectSegmentFont(seg_text, font, p.requested_size);
        const seg_p = if (seg_font != font) emitParamsForSegmentFont(p, seg_font) else p;
        // Shape：缓存借出或本次独有（owned），owned 时本函数负责释放。
        const seg = try self.lookupOrShapeSegment(seg_text, seg_font, use_italic);
        defer if (seg.owned) {
            releaseGlyphFallbackFontRefs(seg.glyphs);
            self.allocator.free(seg.glyphs);
        };
        const glyphs = seg.glyphs;
        self.logEnclosedDigitFontDebug(seg_text, seg_font, use_italic, seg_p.fallback_font, glyphs, if (seg.owned) "fresh-shape-spans" else "segment-cache-spans");

        const seg_end_byte: u32 = @intCast(seg_text.len);
        // 左边界裁剪：整段在视口左侧则跳过 emit
        if (cursor_x < clip_left) {
            var adv: f32 = 0;
            for (glyphs, 0..) |g, i| adv += glyphAdvance(g, clusterSpanAt(glyphs, i, seg_end_byte), seg_p);
            if (cursor_x + adv < clip_left) {
                while (span_idx.* < spans.len and spans[span_idx.*].end <= global_byte_end) span_idx.* += 1;
                return cursor_x + adv;
            }
        }

        // Emit with per-glyph span coloring
        for (glyphs, 0..) |glyph, i| {
            const global_cluster = glyph.cluster + global_byte_start;
            var glyph_color = base_color;
            while (span_idx.* < spans.len and spans[span_idx.*].end <= global_cluster) span_idx.* += 1;
            if (span_idx.* < spans.len and spans[span_idx.*].start <= global_cluster and global_cluster < spans[span_idx.*].end) {
                glyph_color = spans[span_idx.*].color;
            }
            const span = clusterSpanAt(glyphs, i, seg_end_byte);
            cursor_x += try self.emitGlyphInstance(glyph, span, cursor_x, y, glyph_color, seg_p);
        }
        return cursor_x;
    }

    /// 中间 flush：绘制当前积累的字形实例并清空缓冲区
    /// 用于 scissor rect 变更前确保文本按正确 clip 区域绘制
    /// Multi-Page: 按 page_index 分桶，每桶切换纹理后 draw
    pub fn flush(self: *TextRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        const nearest_count = self.instances_nearest.items.len;
        const linear_count = self.instances_linear.items.len;
        if (nearest_count == 0 and linear_count == 0) return;

        // 更新 uniform buffer
        //
        // 溢出**不能** clamp 到最后一槽 —— 那会让本批及后续 draw 别名同一块随后
        // 被覆写的内存，静默画错。也**不能**丢掉这一批：flush 失败时下面的
        // clearRetainingCapacity 到不了，实例留在原地，下一批带着它再溢出一次，
        // 于是该帧从此刻起一个字都画不出来（症状：整段中文消失、位置留白、闪烁）。
        //
        // 正确做法是继续画：槽位不够就切到按需增长、跨帧保留的溢出 buffer，
        // 与实例侧的 overflow_buffers 同款。
        const uniform_buffer, const uniform_byte_offset = blk: {
            if (self.uniform_write_offset < MAX_UNIFORM_UPDATES) {
                const slot = self.uniform_write_offset;
                self.uniform_write_offset += 1;
                break :blk .{ &self.uniform_buffers[self.current_buffer], slot * @sizeOf(Uniforms) };
            }
            self.uniform_overflow_count += 1;
            text_uniform_overflow_total += 1;
            const slot = self.uniform_overflow_used;
            self.uniform_overflow_used += 1;
            const buf = try self.ensureUniformOverflowCapacity(slot + 1);
            break :blk .{ buf, slot * @sizeOf(Uniforms) };
        };
        const peak = self.uniform_write_offset + self.uniform_overflow_used;
        if (peak > self.uniform_peak_slots) self.uniform_peak_slots = peak;
        const uniforms = Uniforms{
            .viewport_size = .{ self.viewport_width, self.viewport_height },
            .scale_factor = self.scale_factor,
            .clip_shape_kind = self.clip_shape_kind,
            .clip_rect = self.clip_rect,
            .clip_radius = self.clip_radius,
            .clip_fill_rule = self.clip_fill_rule,
            .clip_point_count = self.clip_point_count,
            .clip_contour_count = self.clip_contour_count,
            .clip_polygon_end_points = self.clip_polygon_end_points,
            .clip_polygon_points = self.clip_polygon_points,
        };
        const uniform_data = try uniform_buffer.getMappedRange(uniform_byte_offset, @sizeOf(Uniforms));
        @memcpy(uniform_data, std.mem.asBytes(&uniforms));

        // 设置管线
        render_pass.setPipeline(&self.pipeline);

        // Text fragment shader 也会读取 buffer(0) 里的 clip/uniform。
        // 这里只绑 vertex buffer 会让 fragment stage 读到陈旧或未定义的状态，
        // 在离屏/clip 切换场景下会表现成文字首帧被错误裁掉。
        render_pass.setVertexBuffer(0, uniform_buffer, @intCast(uniform_byte_offset));
        render_pass.setFragmentBuffer(0, uniform_buffer, @intCast(uniform_byte_offset));

        // Nearest pass (1:1 缩放) — 按 page_index 分桶
        if (nearest_count > 0) {
            if (self.atlas.getSamplerNearest()) |sampler| {
                render_pass.setFragmentSampler(0, sampler);
            }
            try self.flushInstanceList(&self.instances_nearest, render_pass);
        }

        // Linear pass (非 1:1 缩放) — 按 page_index 分桶
        if (linear_count > 0) {
            if (self.atlas.getSamplerLinear()) |sampler| {
                render_pass.setFragmentSampler(0, sampler);
            }
            try self.flushInstanceList(&self.instances_linear, render_pass);
        }

        // 清空实例缓冲区继续收集后续文本
        self.instances_nearest.clearRetainingCapacity();
        self.instances_linear.clearRetainingCapacity();
    }

    /// 保证本帧槽位的溢出 uniform buffer 至少能放下 `slots` 个 Uniforms。
    /// 与实例侧 overflow_buffers 同款：几何增长、跨帧保留、容量够就复用。
    fn ensureUniformOverflowCapacity(self: *TextRenderer, slots: usize) !*gpu.Backend.Buffer {
        const needed = slots * @sizeOf(Uniforms);
        if (self.uniform_overflow_capacities[self.current_buffer] < needed) {
            var new_capacity = @max(
                self.uniform_overflow_capacities[self.current_buffer],
                @sizeOf(Uniforms) * 64,
            );
            while (new_capacity < needed) new_capacity *= 2;
            if (self.uniform_overflow_buffers[self.current_buffer]) |*old| old.destroy();
            self.uniform_overflow_buffers[self.current_buffer] = try self.device.createBuffer(self.allocator, .{
                .label = "Zenit.Text.OverflowUniforms",
                .size = new_capacity,
                .usage = .{ .vertex = true, .map_write = true },
            });
            self.uniform_overflow_capacities[self.current_buffer] = new_capacity;
        }
        return &self.uniform_overflow_buffers[self.current_buffer].?;
    }

    /// 按 page_index 分桶 flush 一个 instance list
    /// 遍历 instances，找连续相同 page_index 的段，每段切换纹理后 draw
    fn flushInstanceList(self: *TextRenderer, list: *std.ArrayList(GlyphInstance), render_pass: *gpu.Backend.RenderPass) !void {
        const items = list.items;
        const total = items.len;
        if (total == 0) return;
        self.instance_high_water_mark = @max(self.instance_high_water_mark, total);

        var batch_start: usize = 0;
        while (batch_start < total) {
            const cur_page: u8 = @intFromFloat(items[batch_start].page_index);
            var batch_end = batch_start + 1;
            while (batch_end < total and @as(u8, @intFromFloat(items[batch_end].page_index)) == cur_page) {
                batch_end += 1;
            }

            // 绑定该页的纹理。
            // 批次已按 page_index 分好，而一个 page_index 唯一确定一页的格式，
            // 所以一个批次内格式必然一致：灰度页绑 texture(0)、彩色页绑
            // texture(1)，与 shader 的两个绑定点对应。
            //
            // 两个槽都必须始终绑着**有效**纹理：Metal 下未绑定的 texture 槽被
            // 采样是未定义行为，而 fragment shader 里两条分支虽然只有一条会
            // 产出结果，编译器仍可能对另一条做投机采样。所以另一个槽用 page 0
            // （init 保证存在的灰度页）兜底，纯占位、不影响输出。
            const texture = self.atlas.getPageTexture(cur_page) orelse {
                // A stale page index must never draw with the previous batch's
                // binding. The atlas normally pins pages used in this frame;
                // skipping is the fail-closed fallback if that invariant ever
                // regresses.
                //
                // ⚠️ 跳过 = 这一页桶里的字形**全部不画**（用户可见：整页范围内
                // 同一批字消失、位置留白）。这条路径按设计永远不该走到 ——
                // 走到了必须大声报出来，否则又是一个只能靠截图猜的静默丢字点。
                std.log.warn("[TextRenderer] stale atlas page index {d} (pages: {d}); dropping batch segment of {d} glyphs", .{ cur_page, self.atlas.getPageCount(), batch_end - batch_start });
                batch_start = batch_end;
                continue;
            };
            const is_color_page = (self.atlas.getPageFormat(cur_page) orelse .gray) == .color;
            const fallback = self.atlas.getPageTexture(0) orelse texture;
            if (is_color_page) {
                render_pass.setFragmentTextureBinding(0, fallback);
                render_pass.setFragmentTextureBinding(1, texture);
            } else {
                render_pass.setFragmentTextureBinding(0, texture);
                render_pass.setFragmentTextureBinding(1, fallback);
            }

            // 写入 instance buffer 并 draw
            // 注意：Metal command buffer 延迟执行，同一帧内不能回绕覆写 —
            // 否则 commit 时先前 draw call 引用的 offset 处数据已被覆盖
            var seg_offset = batch_start;
            while (seg_offset < batch_end) {
                const remaining_total = batch_end - seg_offset;
                const remaining = MAX_INSTANCES - self.buffer_write_offset;
                const batch = if (remaining == 0)
                    remaining_total
                else
                    @min(remaining_total, remaining);
                const instance_size = @sizeOf(GlyphInstance) * batch;
                if (remaining == 0) {
                    // 复用本帧槽位的溢出缓冲；容量不足才重建（几何增长，避免抖动）。
                    const needed = self.overflow_write_offset + instance_size;
                    if (self.overflow_capacities[self.current_buffer] < needed) {
                        var new_capacity = @max(self.overflow_capacities[self.current_buffer], instance_size);
                        while (new_capacity < needed) new_capacity *= 2;
                        if (self.overflow_buffers[self.current_buffer]) |*old| old.destroy();
                        self.overflow_buffers[self.current_buffer] = try self.device.createBuffer(self.allocator, .{
                            .label = "Zenit.Text.OverflowInstanceBuffer",
                            .size = new_capacity,
                            .usage = .{ .vertex = true, .map_write = true },
                        });
                        self.overflow_capacities[self.current_buffer] = new_capacity;
                    }
                    const overflow_buffer = &self.overflow_buffers[self.current_buffer].?;
                    const overflow_data = try overflow_buffer.getMappedRange(self.overflow_write_offset, instance_size);
                    @memcpy(overflow_data, std.mem.sliceAsBytes(items[seg_offset .. seg_offset + batch]));
                    render_pass.setVertexBuffer(1, overflow_buffer, @intCast(self.overflow_write_offset));
                    render_pass.setFragmentBuffer(1, overflow_buffer, @intCast(self.overflow_write_offset));
                    self.overflow_write_offset += instance_size;
                } else {
                    const byte_offset = self.buffer_write_offset * @sizeOf(GlyphInstance);
                    const instance_data = try self.instance_buffers[self.current_buffer].getMappedRange(byte_offset, instance_size);
                    @memcpy(instance_data, std.mem.sliceAsBytes(items[seg_offset .. seg_offset + batch]));
                    render_pass.setVertexBuffer(1, &self.instance_buffers[self.current_buffer], @intCast(byte_offset));
                    render_pass.setFragmentBuffer(1, &self.instance_buffers[self.current_buffer], @intCast(byte_offset));
                    self.buffer_write_offset += batch;
                }
                render_pass.draw(6, @intCast(batch), 0, 0);
                text_draw_calls += 1;
                seg_offset += batch;
            }

            batch_start = batch_end;
        }
    }

    /// 结束帧并渲染
    pub fn endFrame(self: *TextRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        try self.flush(render_pass);
        if (self.atlas.frame_insert_count > 0 or self.atlas_gc_happened) {
            text_trace.log(
                self.current_frame,
                "text-frame-summary inserts={d} gc={} atlas_pages={d} atlas_cache={d} nearest={d} linear={d}",
                .{
                    self.atlas.frame_insert_count,
                    self.atlas_gc_happened,
                    self.atlas.page_count,
                    self.atlas.getCacheSize(),
                    self.instances_nearest.items.len,
                    self.instances_linear.items.len,
                },
            );
        }
    }

    /// 获取图集缓存大小
    pub fn getAtlasCacheSize(self: *TextRenderer) usize {
        return self.atlas.getCacheSize();
    }

    pub fn getPendingInstanceCount(self: *TextRenderer) usize {
        return self.instances_nearest.items.len + self.instances_linear.items.len;
    }
};

// ── segmentText: RTL 整段化单测 ──
//
// RTL 必须整段交给 CoreText，否则 bidi 重排 / 阿拉伯连写 / 变音符号挂载
// 三样全毁。这里钉死分段边界，防止有人为了缓存粒度把 RTL 切碎。
const seg_testing = std.testing;

fn segCountOf(text: []const u8, out: *[MAX_SEGMENTS]Segment) u32 {
    return segmentText(text, out);
}

test "segmentText: 纯阿拉伯语整串为单段（连写形态依赖左右邻居）" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{645}\u{631}\u{62D}\u{628}\u{627}";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 1), n);
    try seg_testing.expectEqual(@as(u32, 0), buf[0].start);
    try seg_testing.expectEqual(@as(u32, s.len), buf[0].end);
}

test "segmentText: 纯希伯来语整串为单段" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{5E9}\u{5DC}\u{5D5}\u{5DD}";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 1), n);
    try seg_testing.expectEqual(@as(u32, s.len), buf[0].end);
}

test "segmentText: RTL 词间空格并入同一段（同一 bidi run 不可拆）" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{5E9}\u{5DC} \u{5D5}\u{5DD}";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 1), n);
    try seg_testing.expectEqual(@as(u32, s.len), buf[0].end);
}

test "segmentText: RTL 尾随空格不并入 RTL 段" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{5E9}\u{5DC}  ";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 2), n);
    // 第一段只含 RTL 字母（2 字符 × 2 字节）。
    try seg_testing.expectEqual(@as(u32, 4), buf[0].end);
}

test "segmentText: 混排 latin+arabic+latin 切成三段且 RTL 段完整" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "ab\u{645}\u{631}\u{62D}cd";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 3), n);
    try seg_testing.expectEqual(@as(u32, 0), buf[0].start);
    try seg_testing.expectEqual(@as(u32, 2), buf[0].end); // "ab"
    try seg_testing.expectEqual(@as(u32, 2), buf[1].start);
    try seg_testing.expectEqual(@as(u32, 8), buf[1].end); // 3 个阿拉伯字母 × 2 字节
    try seg_testing.expectEqual(@as(u32, 8), buf[2].start);
    try seg_testing.expectEqual(@as(u32, 10), buf[2].end); // "cd"
}

test "segmentText: LTR 未退化 —— ASCII 仍按词分段" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const n = segCountOf("hello world", &buf);
    try seg_testing.expectEqual(@as(u32, 2), n);
    try seg_testing.expectEqual(@as(u32, 6), buf[0].end); // "hello " 含尾空格
}

test "segmentText: CJK 未退化 —— 仍每码点独立" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const n = segCountOf("\u{4F60}\u{597D}", &buf);
    try seg_testing.expectEqual(@as(u32, 2), n);
}

// ── segmentText: 字节覆盖完整性 + VS16 emoji presentation ──
//
// 这两类 bug 都是"静默"的：分段丢字节不会报错，只会让后续段的
// start/end 与原文错位；VS16 被切走也不会报错，只会让 ❤️ 退回单色 ❤
// 且宽度按窄字形算（12.742 vs 19.0），表现为光标偏移。

/// 所有段必须**恰好**拼回原文：无空洞、无重叠、总长相等。
fn expectFullCoverage(text: []const u8) !void {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const n = segCountOf(text, &buf);
    var prev_end: u32 = 0;
    var covered: usize = 0;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        try seg_testing.expectEqual(prev_end, buf[k].start); // 无空洞/重叠
        covered += buf[k].end - buf[k].start;
        prev_end = buf[k].end;
    }
    try seg_testing.expectEqual(text.len, covered);
    if (n > 0) try seg_testing.expectEqual(@as(u32, @intCast(text.len)), prev_end);
}

test "segmentText: VS16 与基字同段（❤+FE0F 不可拆，否则退回单色窄字形）" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{2764}\u{FE0F}";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 1), n);
    try seg_testing.expectEqual(@as(u32, 0), buf[0].start);
    try seg_testing.expectEqual(@as(u32, 6), buf[0].end); // 3(❤) + 3(VS16)
}

test "segmentText: 字节覆盖完整 —— VS16 序列不得吞字节" {
    try expectFullCoverage("\u{2764}\u{FE0F}");
    try expectFullCoverage("abc\u{2764}\u{FE0F}def");
    try expectFullCoverage("a\u{FE0F}b"); // 孤立 VS16 也要成段
    try expectFullCoverage("abc\u{1F62D}def\u{9876}\u{8D77}\u{2764}\u{FE0F}\u{2705}\u{2728}");
}

test "segmentText: 字节覆盖完整 —— 实测丢字文档的原文行（下游编辑器滚动丢字回归）" {
    // 这些行在下游编辑器渲染一份画布引擎调研文档时实测丢中段/丢行尾
    try expectFullCoverage("Figma 说自己是 tile-based，但没说怎么做。我们要不要跟？");
    try expectFullCoverage("代价是：一套持久 tile 池 + 失效逻辑 + 额外显存。");
    try expectFullCoverage("**但 300 draw call 在 Apple Silicon 上依然是很小的负载**（量级参考：");
    try expectFullCoverage("超过则应先做**按纹理排序**（把同纹理对象排到一起，在 z 序允许时合并），");
    try expectFullCoverage("\"连续同纹理的 instance 合成一次 draw\"（`image_renderer.zig:640`）。");
}

test "segmentText: emoji 后的普通符号不被吞进 emoji 段" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    // 🔥 后跟箭头 →（U+2192，在 isEmojiCapable 范围内但非 ZWJ 连接）
    const n = segCountOf("\u{1F525}\u{2192}", &buf);
    try seg_testing.expectEqual(@as(u32, 2), n);
}

test "long segment cache bounds ownership and rejects hash collisions" {
    const allocator = std.testing.allocator;
    var cache: LongSegmentCache = .{};
    defer cache.deinit(allocator);
    for (0..LongSegmentCache.max_entries + 8) |i| {
        const key = SegmentCacheKey{ .content_hash = i, .font_ptr = 1, .flags = 0 };
        const glyphs = try allocator.alloc(text_module.ShapedGlyph, 103);
        @memset(glyphs, std.mem.zeroes(text_module.ShapedGlyph));
        glyphs[0].glyph_index = @intCast(i);
        try std.testing.expect(cache.adopt(allocator, key, "long segment", glyphs, i));
        try std.testing.expect(cache.entries.count() <= LongSegmentCache.max_entries);
        try std.testing.expectEqual(@as(u32, @intCast(i)), cache.get(key, "long segment", i).?[0].glyph_index);
        try std.testing.expect(cache.get(key, "different content", i) == null);
    }
    const first = SegmentCacheKey{ .content_hash = 0, .font_ptr = 1, .flags = 0 };
    try std.testing.expect(cache.get(first, "long segment", 100) == null);
    const live = SegmentCacheKey{ .content_hash = 8, .font_ptr = 1, .flags = 0 };
    try std.testing.expect(cache.get(live, "long segment", 100) != null);
    const replacement = try allocator.alloc(text_module.ShapedGlyph, 40);
    @memset(replacement, std.mem.zeroes(text_module.ShapedGlyph));
    try std.testing.expect(cache.adopt(allocator, first, "replacement", replacement, 101));
    try std.testing.expect(cache.get(live, "long segment", 102) != null);
    const huge = try allocator.alloc(text_module.ShapedGlyph, LongSegmentCache.max_glyphs + 1);
    defer allocator.free(huge);
    try std.testing.expect(!cache.adopt(allocator, first, "too large", huge, 103));
    try std.testing.expect(cache.get(first, "replacement", 104) != null);
}

test "long segment cache allocation failures leave glyph ownership with caller" {
    const allocator = std.testing.allocator;
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var cache: LongSegmentCache = .{};
        defer cache.deinit(failing.allocator());
        const glyphs = try allocator.alloc(text_module.ShapedGlyph, 103);
        defer allocator.free(glyphs);
        @memset(glyphs, std.mem.zeroes(text_module.ShapedGlyph));
        const key = SegmentCacheKey{ .content_hash = 1, .font_ptr = 1, .flags = 0 };
        try std.testing.expect(!cache.adopt(failing.allocator(), key, "text", glyphs, 0));
        try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
        glyphs[0].glyph_index = 42;
        try std.testing.expectEqual(@as(u32, 42), glyphs[0].glyph_index);
    }
}

test "long segment cache preserves real shaped glyphs including fallback fonts" {
    // SKIP-REASON: 需要真实 CoreText 字体系统（findFont/shape），非 macOS 上没有
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fs = try text_module.FontSystem.init(allocator);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Menlo", .size = 14 });
    defer font.deinit();
    var shaper = try TextShaper.init(allocator);
    defer shaper.deinit();
    var cache: LongSegmentCache = .{};
    defer cache.deinit(allocator);
    const sample = "A" ** 80 ++ "中文🙂";
    const shaped = try shaper.shapeWithOptions(sample, font, false);
    var caller_owned = true;
    defer if (caller_owned) {
        TextRenderer.releaseGlyphFallbackFontRefs(shaped);
        allocator.free(shaped);
    };
    const key = SegmentCacheKey{ .content_hash = 1, .font_ptr = @intFromPtr(font), .flags = 0 };
    caller_owned = !cache.adopt(allocator, key, sample, shaped, 1);
    try std.testing.expect(!caller_owned);
    const cached = cache.get(key, sample, 2).?;
    try std.testing.expect(cached.ptr == shaped.ptr);
    const reference = try shaper.shapeWithOptions(sample, font, false);
    defer {
        TextRenderer.releaseGlyphFallbackFontRefs(reference);
        allocator.free(reference);
    }
    try std.testing.expectEqual(reference.len, cached.len);
    var fallback_refs: usize = 0;
    for (reference, cached) |expected, actual| {
        inline for (.{ "glyph_index", "cluster", "x_advance", "y_advance", "x_offset", "y_offset", "is_synthetic_italic", "is_fallback_font" }) |field| {
            try std.testing.expectEqual(@field(expected, field), @field(actual, field));
        }
        if (actual.fallback_font_ref != null) fallback_refs += 1;
    }
    try std.testing.expect(fallback_refs > 0);
}

/// 只装配 fallback wrapper 路径用到的字段（allocator / fallback_font_cache /
/// current_frame / atlas.cache），其余 GPU 资源保持 undefined —— 被测函数不碰它们。
fn fallbackOnlyRendererForTest(allocator: std.mem.Allocator) TextRenderer {
    var tr: TextRenderer = undefined;
    tr.allocator = allocator;
    tr.current_frame = 0;
    tr.fallback_font_cache = std.AutoHashMap(u64, FallbackFontCacheEntry).init(allocator);
    tr.atlas.cache = @TypeOf(tr.atlas.cache).init(std.testing.allocator);
    return tr;
}

test "fallback wrapper: cache put OOM 时 errdefer 不 double free" {
    // SKIP-REASON: 需要真实 CTFontRef 作为 fallback ref
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fs = try text_module.FontSystem.init(allocator);
    defer fs.deinit();
    const proto = try fs.findFont(.{ .family = "Helvetica", .size = 14 });
    defer proto.deinit();

    // fail_index 0 = create(Font) 成功，1 = fallback_font_cache.put 扩容失败。
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var tr = fallbackOnlyRendererForTest(failing.allocator());
    defer tr.atlas.cache.deinit();
    defer tr.fallback_font_cache.deinit();
    try std.testing.expectError(error.OutOfMemory, tr.getOrCreateGlyphFallbackFont(proto.ct_font, proto));
    // create 过的 wrapper 恰好释放一次（testing allocator 会对 double free / 泄漏报错）。
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
}

test "fallback wrapper 驱逐时摘除其 atlas 条目（地址复用不命中旧位图）" {
    // SKIP-REASON: 需要真实 CTFontRef 作为 fallback ref
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fs = try text_module.FontSystem.init(allocator);
    defer fs.deinit();
    const proto = try fs.findFont(.{ .family = "Helvetica", .size = 14 });
    defer proto.deinit();

    var tr = fallbackOnlyRendererForTest(allocator);
    defer tr.atlas.cache.deinit();
    defer {
        var it = tr.fallback_font_cache.iterator();
        while (it.next()) |e| e.value_ptr.font.deinit();
        tr.fallback_font_cache.deinit();
    }
    const wrapper = try tr.getOrCreateGlyphFallbackFont(proto.ct_font, proto);
    const region = atlas_mod.AtlasRegion{
        .uv_min = .{ 0, 0 },
        .uv_max = .{ 1, 1 },
        .bearing_x = 0,
        .bearing_y = 0,
        .advance = 0,
        .width = 1,
        .height = 1,
        .page_index = 0,
    };
    const Key = @FieldType(@TypeOf(tr.atlas.cache).KV, "key");
    const wrapper_key = Key{ .font_ptr = @intFromPtr(wrapper), .glyph_index = 42 };
    const other_key = Key{ .font_ptr = @intFromPtr(proto), .glyph_index = 42 };
    try tr.atlas.cache.put(wrapper_key, region);
    try tr.atlas.cache.put(other_key, region);

    // 走真实驱逐路径：老化超过阈值后 evictStaleFallbackFonts 销毁 wrapper。
    tr.current_frame = 100_000;
    tr.evictStaleFallbackFonts();
    try std.testing.expectEqual(@as(u32, 0), tr.fallback_font_cache.count());
    try std.testing.expect(tr.atlas.cache.get(wrapper_key) == null);
    try std.testing.expect(tr.atlas.cache.get(other_key) != null);
}

test "CoreText 桥：开头 UTF-8 BOM 不打乱 cluster 映射与 caret stops" {
    // SKIP-REASON: 走真实 CoreText 桥（initWithBytes 吃 BOM 是 Foundation 行为）
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fs = try text_module.FontSystem.init(allocator);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 14 });
    defer font.deinit();
    const sample = "\u{FEFF}ab"; // EF BB BF 61 62

    var shaper = try TextShaper.init(allocator);
    defer shaper.deinit();
    const shaped = try shaper.shapeWithOptions(sample, font, false);
    defer {
        TextRenderer.releaseGlyphFallbackFontRefs(shaped);
        allocator.free(shaped);
    }
    // 'a' 在字节 3、'b' 在字节 4（BOM 自身可能有也可能没有 glyph）。
    try std.testing.expect(shaped.len >= 2);
    try std.testing.expectEqual(@as(u32, 3), shaped[shaped.len - 2].cluster);
    try std.testing.expectEqual(@as(u32, 4), shaped[shaped.len - 1].cluster);
    for (shaped) |g| try std.testing.expect(g.cluster < sample.len);

    const boundaries = [_]u32{ 0, 3, 4, 5 };
    var stops: [boundaries.len]text_module.LineCaretStop = undefined;
    _ = try font.lineCaretStops(sample, &boundaries, &stops);
    try std.testing.expectEqual(@as(u32, 3), stops[1].byte_offset);
    // 'a' 和 'b' 各有正宽度：caret 单调前进。
    try std.testing.expect(stops[2].primary_x > stops[1].primary_x);
    try std.testing.expect(stops[3].primary_x > stops[2].primary_x);
}
