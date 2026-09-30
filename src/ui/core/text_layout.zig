/// 文本折行计算模块
///
/// 在布局阶段根据可用宽度计算断行点，支持 word 和 char 两种模式。
/// 折行结果缓存在 TextLayout 中，仅 content/available_width 变化时重算。
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const TextWrap = types.TextWrap;
const TextSpan = types.TextSpan;
const grapheme = @import("text_core").grapheme;

const native_text = if (builtin.os.tag == .macos and !builtin.is_test) struct {
    extern fn coretext_measure_text_width_utf8(text: [*]const u8, len: c_int, font_size: f32) f32;
    extern fn coretext_measure_text_width_weighted(text: [*]const u8, len: c_int, font_size: f32, font_weight: c_int) f32;
} else struct {};

fn usePlatformTextMeasure() bool {
    return comptime (builtin.os.tag == .macos and !builtin.is_test);
}

/// 外部注入的测量函数（使用预加载字体，与渲染一致）
/// 参数: text_ptr, text_len, font_size, font_weight, use_italic
///
/// 线程安全约束：在 runApp 初始化时通过 setMeasureFn 设置一次，之后只读。
/// 当前单线程架构下安全。若未来引入多线程布局，需改为 atomic 或线程局部变量。
pub const MeasureFn = *const fn ([*]const u8, usize, f32, u16, bool) f32;
var external_measure_fn: ?MeasureFn = null;
var external_monospace_measure_fn: ?MeasureFn = null;

/// 带 context 的测量回调 —— 多 App / 多窗口所需。
///
/// 旧的 `MeasureFn` 不带 context，调用方（zenit_app.runtime）只能用一个
/// **进程级全局** `g_font_selector_for_measure` 把字体选择器偷渡进来；
/// 两个 App 并存时后者会覆盖前者，导致前一个窗口的文本用错字体测量。
/// 这是多窗口最后两处非 World 全局依赖之一（另一处是 a11y active context）。
///
/// 有 context 版本优先于无 context 版本；两者都没设时走平台/回退路径。
pub const MeasureCtxFn = *const fn (ctx: *anyopaque, [*]const u8, usize, f32, u16, bool) f32;
var external_measure_ctx_fn: ?MeasureCtxFn = null;
var external_measure_ctx: ?*anyopaque = null;

/// 当前测量上下文的身份，并进 MeasureKey。无 ctx 时为 0。
fn currentMeasureCtxId() u64 {
    const ctx = external_measure_ctx orelse return 0;
    return @intFromPtr(ctx);
}

pub fn setMeasureCtxFn(f: ?MeasureCtxFn, ctx: ?*anyopaque) void {
    if (external_measure_ctx_fn == f and external_measure_ctx == ctx) return;
    external_measure_ctx_fn = f;
    external_measure_ctx = ctx;
    // 不再清表：ctx 身份已经是 MeasureKey 的一部分（见 measure_ctx_id），
    // 不同 ctx 的条目天然不会互相命中。此前这里无条件 invalidate，导致
    // MultiWindowApp 每帧顺序跑各窗口 layout() 时每次都清空整张 16384 条
    // 的表，多窗口下命中率恒为 0。
    //
    // 注意残留前提：ctx 指针相同但其内容被原地改掉（比如把同一个
    // FontSelector 换族/换态）时，旧宽度仍会被复用。框架内 setFontSelector
    // 的用法都是传入新对象指针，不会踩到；宿主若要原地改，需自行调用
    // invalidateMeasureCache()。
}

pub fn setMeasureFn(f: ?MeasureFn) void {
    // 幂等：Cx.layout() 每次布局都会调本 fn 同步 measure_fn。fn 没变时绝不能
    // invalidate —— 否则 measure cache 每次 layout 被整体清空，形同虚设
    //（列表场景每帧 N 次未缓存 CoreText 调用的真根因）。
    if (external_measure_fn == f) return;
    external_measure_fn = f;
    invalidateMeasureCache();
}

/// 设置 monospace 专用测量函数（用于等宽文本场景）
pub fn setMonospaceMeasureFn(f: ?MeasureFn) void {
    if (external_monospace_measure_fn == f) return;
    external_monospace_measure_fn = f;
    invalidateMeasureCache();
}

/// 注入式 GlyphRun pipeline 测量回调。
///
/// 当 caller (layoutNode 入口) 在测量上下文激活时设这个回调，
/// measureProportional 内部优先调它走 GlyphRun cache → ShapingCache hit /
/// TextShaper.shape miss-path。返 NaN 表示 pipeline 不可用 (cache 未挂、
/// font lookup 失败等)，自动 fallback 到 platform measure。
///
/// 这是真正让 layout/findLineBreak/computeTextLayout 等 *所有* legacy 路径
/// 自动走 GlyphRun pipeline 的关键 hook —— 不用改一堆 caller。
///
/// 线程安全约束同 setMeasureFn：layoutNode 入口设、退出还原。
pub const ShapeMeasureFn = *const fn (text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32;
var g_shape_measure_fn: ?ShapeMeasureFn = null;

pub fn setShapeMeasureFn(f: ?ShapeMeasureFn) void {
    g_shape_measure_fn = f;
}

/// 诊断用:当前是否装着 GlyphRun 测量钩子。
///
/// 为什么需要它:钩子只在 `layoutNode` 期间装着(见上面的线程安全约束),
/// **draw / overlay 阶段是空的**。于是同一段文字在布局期按 shaping 宽度算、
/// 在 overlay 期按平台 fallback 算,两者不一致 —— 选区高亮与光标就会与
/// 字形错位。谁要在 layout 之外测量文字,先用这个断言自己处在哪种世界。
pub fn hasShapeMeasure() bool {
    return g_shape_measure_fn != null;
}

/// 清空 measure cache。在 measure fn 变更时必须调（不同 fn 同 key 应给不同 width）。
pub fn invalidateMeasureCache() void {
    for (&g_measure_cache) |*e| e.valid = false;
}

// measure cache —— text_hash + font params → width。
// 矩阵 #8：shape cache > 95%。命中跳过 CoreText shape 调用（~10-100µs）。
// 单线程，2-way set-assoc，LRU eviction。同帧内同文本被复用是高频路径
// （列表里 100 行同 "Item N" 文本各自布局时 measure_x 调 N 次）。
// 容量依据（2026-08）：表格密集 40KB 中文文档单次冷开产生 ~16.5k 个独特
// (segment, font) key——4096 容量在一次打开内就被驱逐两轮，回滚/重开时同串
// 全部重 shape。16384 × ~48B ≈ 786KB，让整篇文档的 segment 常驻。
const MEASURE_CACHE_CAP: usize = 16384;
const MeasureKey = packed struct {
    text_hash: u64,
    font_size_bits: u32, // f32 reinterpret 用作整 key 部分
    font_weight: u16,
    use_italic: u8, // bool 0/1
    text_len_low: u8, // text length 低 8 位（防短碰撞）
    /// mono 与 proportional 同 (text,size,weight) 宽度不同，必须分 key，
    /// 否则谁先测谁的值就被另一方错误复用。
    use_monospace: u8 = 0,
    /// 测量上下文身份（`external_measure_ctx` 的指针值，无 ctx 时为 0）。
    ///
    /// 多窗口下每个 App 的 measure_ctx 是各自 `&app.font_selector` 的地址，
    /// 天然互不相同。把它并进 key 之后，不同窗口的测量结果可以在同一张表里
    /// 共存；否则只能靠"ctx 一变就清全表"来保证不串味，而 MultiWindowApp
    /// 每帧顺序跑每个窗口的 layout()，等于每帧每窗口清一次表，命中率归零。
    measure_ctx_id: u64 = 0,
};
const MeasureEntry = struct {
    key: MeasureKey,
    width: f32,
    last_used: u64,
    valid: bool = false,
};
var g_measure_cache: [MEASURE_CACHE_CAP]MeasureEntry = [_]MeasureEntry{.{ .key = undefined, .width = 0, .last_used = 0, .valid = false }} ** MEASURE_CACHE_CAP;
var g_measure_cache_clock: u64 = 0;
var g_measure_cache_hits: u64 = 0;
var g_measure_cache_misses: u64 = 0;

pub const MeasureCacheStats = struct {
    hits: u64,
    misses: u64,
    pub fn hitRate(self: MeasureCacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

pub fn measureCacheStats() MeasureCacheStats {
    return .{ .hits = g_measure_cache_hits, .misses = g_measure_cache_misses };
}

pub fn resetMeasureCacheStats() void {
    g_measure_cache_hits = 0;
    g_measure_cache_misses = 0;
}

inline fn measureKeyEq(a: MeasureKey, b: MeasureKey) bool {
    return a.text_hash == b.text_hash and
        a.font_size_bits == b.font_size_bits and
        a.font_weight == b.font_weight and
        a.use_italic == b.use_italic and
        a.text_len_low == b.text_len_low and
        a.use_monospace == b.use_monospace and
        // 注意：本函数逐字段比较而非按整体比特比较，新增 MeasureKey 字段时
        // 必须同步加在这里，否则该字段等于没进 key（不同值会互相命中）。
        a.measure_ctx_id == b.measure_ctx_id;
}

// 2-way set-associative：direct-mapped 时热键冲突互相踢（反复重测 CoreText），
// 组内两槽 + 组内 LRU 覆盖显著降低 thrash，容量不变。
fn measureCacheLookup(key: MeasureKey) ?f32 {
    const base = (key.text_hash % MEASURE_CACHE_CAP) & ~@as(u64, 1);
    inline for (0..2) |way| {
        const e = &g_measure_cache[base + way];
        if (e.valid and measureKeyEq(e.key, key)) {
            g_measure_cache_clock += 1;
            e.last_used = g_measure_cache_clock;
            g_measure_cache_hits += 1;
            return e.width;
        }
    }
    g_measure_cache_misses += 1;
    return null;
}

fn measureCacheStore(key: MeasureKey, width: f32) void {
    const base = (key.text_hash % MEASURE_CACHE_CAP) & ~@as(u64, 1);
    const e0 = &g_measure_cache[base];
    const e1 = &g_measure_cache[base + 1];
    const target = if (!e0.valid) e0 else if (!e1.valid) e1 else if (e0.last_used <= e1.last_used) e0 else e1;
    g_measure_cache_clock += 1;
    target.* = .{
        .key = key,
        .width = width,
        .last_used = g_measure_cache_clock,
        .valid = true,
    };
}

/// 内部 proportional 测量 + cache。是 measureTextWidthByFontKind /
/// measureMonospaceTextWidth fallback 的唯一聚集点。
///
/// **历史**：原 pub fn (已物理删除 Phase E commit)。整条
/// ASCII-first measure API 的 *外部* 入口现在统一是 measureTextWidthByFontKind；
/// GlyphRun pipeline 主路径在 cx.shapeText / measureSegmentWidthCtx /
/// measureIntrinsicTextWidthCtx 接管，本 fn 只是 fallback 的最后一站。
fn measureProportional(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool) f32 {
    if (text.len == 0) return 0;
    // GlyphRun pipeline fast path（命中即返 cache 内
    // total_advance；miss 时 callback 内 shape + insert 然后返）。NaN 视为
    // 不可用 (pipeline 没挂或 shape 失败)，回到 platform measure。
    if (g_shape_measure_fn) |shape_fn| {
        const w = shape_fn(text, font_size, font_weight, use_italic, false);
        if (!std.math.isNan(w)) return w;
    }
    // measure cache lookup
    const text_hash = std.hash.Wyhash.hash(0, text);
    const key = MeasureKey{
        .text_hash = text_hash,
        .font_size_bits = @bitCast(font_size),
        .font_weight = font_weight,
        .use_italic = if (use_italic) 1 else 0,
        .text_len_low = @truncate(text.len),
        .measure_ctx_id = currentMeasureCtxId(),
    };
    if (measureCacheLookup(key)) |w| return w;

    const computed: f32 = blk: {
        // 带 context 的回调优先 —— 它能定位到**具体那个 App** 的字体选择器，
        // 而无 context 版本只能读进程级全局（多窗口下会串台）。
        if (external_measure_ctx_fn) |f| {
            if (external_measure_ctx) |ctx| {
                break :blk f(ctx, text.ptr, text.len, font_size, font_weight, use_italic);
            }
        }
        if (external_measure_fn) |f| {
            break :blk f(text.ptr, text.len, font_size, font_weight, use_italic);
        }
        if (comptime usePlatformTextMeasure()) {
            if (font_weight > 400) {
                break :blk native_text.coretext_measure_text_width_weighted(text.ptr, @intCast(text.len), font_size, @intCast(font_weight));
            }
            break :blk native_text.coretext_measure_text_width_utf8(text.ptr, @intCast(text.len), font_size);
        }
        // 回退: 按 codepoint 粗估(ASCII 0.6em,非 ASCII 视为全宽 1.0em)。
        // 不能按字节数——CJK 每字符 3 字节,按字节会超测 ~3×(选区/光标错位)。
        var est: f32 = 0;
        const view = std.unicode.Utf8View.init(text) catch
            break :blk @as(f32, @floatFromInt(text.len)) * font_size * 0.6;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            est += if (cp < 0x80) font_size * 0.6 else font_size;
        }
        break :blk est;
    };
    measureCacheStore(key, computed);
    return computed;
}

/// monospace 文本宽度测量（优先走 monospace 专用函数）
pub fn measureMonospaceTextWidth(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool) f32 {
    if (text.len == 0) return 0;
    // 同 proportional 路径优先走 GlyphRun pipeline。
    if (g_shape_measure_fn) |shape_fn| {
        const w = shape_fn(text, font_size, font_weight, use_italic, true);
        if (!std.math.isNan(w)) return w;
    }
    if (external_monospace_measure_fn) |f| {
        // 走缓存（use_monospace=1 分 key）：外部 mono 测量同样是 FFI/shaping 级
        // 开销，之前这条腿完全没缓存。
        const key = MeasureKey{
            .text_hash = std.hash.Wyhash.hash(0, text),
            .font_size_bits = @bitCast(font_size),
            .font_weight = font_weight,
            .use_italic = if (use_italic) 1 else 0,
            .text_len_low = @truncate(text.len),
            .use_monospace = 1,
            .measure_ctx_id = currentMeasureCtxId(),
        };
        if (measureCacheLookup(key)) |w| return w;
        const computed = f(text.ptr, text.len, font_size, font_weight, use_italic);
        measureCacheStore(key, computed);
        return computed;
    }
    return measureProportional(text, font_size, font_weight, use_italic);
}

/// 按 font kind 测量文本宽度（monospace fast path）。
/// 公开作 render_engine + input components 的统一入口，避免重复 wrapper。
///
/// GlyphRun pipeline 主路径在 cx.shapeText / measureSegmentWidthCtx /
/// measureIntrinsicTextWidthCtx 接管。本 fn 是 fallback 的最后一站（无 cx
/// / shape 失败时降级路径）。
pub inline fn measureTextWidthByFontKind(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32 {
    return if (use_monospace)
        measureMonospaceTextWidth(text, font_size, font_weight, use_italic)
    else
        measureProportional(text, font_size, font_weight, use_italic);
}

pub const InlineBoxMetrics = struct {
    leading_advance: f32 = 0,
    trailing_advance: f32 = 0,
    inset_top: f32 = 0,
    inset_bottom: f32 = 0,
    corner_radius: f32 = 0,

    pub fn totalHorizontalAdvance(self: InlineBoxMetrics) f32 {
        return self.leading_advance + self.trailing_advance;
    }
};

pub fn spanHasInlineBox(span: TextSpan) bool {
    return span.inline_box_padding_left > 0 or
        span.inline_box_padding_right > 0 or
        span.inline_box_inset_top > 0 or
        span.inline_box_inset_bottom > 0 or
        span.inline_box_corner_radius > 0;
}

pub fn inlineBoxMetricsForFragment(span: TextSpan, frag_start: u32, frag_end: u32) InlineBoxMetrics {
    if (!spanHasInlineBox(span) or frag_start >= frag_end) return .{};
    return .{
        .leading_advance = if (frag_start == span.start) span.inline_box_padding_left else 0,
        .trailing_advance = if (frag_end == span.end) span.inline_box_padding_right else 0,
        .inset_top = span.inline_box_inset_top,
        .inset_bottom = span.inline_box_inset_bottom,
        .corner_radius = span.inline_box_corner_radius,
    };
}

/// 按 TextSpan 分段测量文本宽度
/// 与 renderLineWithSpans 逻辑一致：遍历 [start..end] 范围，
/// 有 span 覆盖的段用 span.font_weight/italic，无覆盖的用 base_fw/base_italic。
pub fn measureTextWidthWithSpans(
    content: []const u8,
    start: u32,
    end: u32,
    font_size: f32,
    base_fw: u16,
    base_italic: bool,
    base_use_monospace: bool,
    spans: []const TextSpan,
) f32 {
    if (start >= end) return 0;
    if (spans.len == 0) return measureTextWidthByFontKind(content[start..end], font_size, base_fw, base_italic, base_use_monospace);

    var total: f32 = 0;
    var pos: u32 = start;

    for (spans) |span| {
        if (span.end <= start) continue;
        if (span.start >= end) break;

        const seg_start = @max(span.start, start);
        const seg_end = @min(span.end, end);
        if (seg_start >= seg_end) continue;

        // span 之前的间隙用 base_fw/base_italic
        if (pos < seg_start) {
            total += measureTextWidthByFontKind(content[pos..seg_start], font_size, base_fw, base_italic, base_use_monospace);
        }

        // span 段用 span 自己的 fw/italic/monospace
        const seg_fw = span.font_weight orelse base_fw;
        const seg_italic = span.use_italic_font or base_italic;
        const seg_monospace = span.use_monospace_font or base_use_monospace;
        const box_metrics = inlineBoxMetricsForFragment(span, seg_start, seg_end);
        total += measureTextWidthByFontKind(content[seg_start..seg_end], font_size, seg_fw, seg_italic, seg_monospace);
        total += box_metrics.totalHorizontalAdvance();
        pos = seg_end;
    }

    // 尾部无 span 覆盖的文本
    if (pos < end) {
        total += measureTextWidthByFontKind(content[pos..end], font_size, base_fw, base_italic, base_use_monospace);
    }

    return total;
}

/// 一条视觉行在内容宽 `avail_w` 内按 `text_align` 的起点偏移（px，≥ 0）。
/// 渲染（text_item_render）与宿主的光标 / 命中 / 选区换算必须共用这一个公式，
/// 否则居中文字上的光标会与字形错位。行比可用宽还宽（溢出）时不偏移。
pub fn alignLineOffset(text_align: types.TextAlign, avail_w: f32, line_w: f32) f32 {
    if (text_align == .start) return 0;
    if (!std.math.isFinite(avail_w) or !std.math.isFinite(line_w)) return 0;
    const slack = avail_w - line_w;
    if (slack <= 0) return 0;
    return switch (text_align) {
        .start => 0,
        .center => slack / 2,
        .end => slack,
    };
}

test "alignLineOffset: start/center/end, overflow and non-finite input" {
    try std.testing.expectEqual(@as(f32, 0), alignLineOffset(.start, 100, 40));
    try std.testing.expectEqual(@as(f32, 30), alignLineOffset(.center, 100, 40));
    try std.testing.expectEqual(@as(f32, 60), alignLineOffset(.end, 100, 40));
    try std.testing.expectEqual(@as(f32, 0), alignLineOffset(.center, 40, 100));
    try std.testing.expectEqual(@as(f32, 0), alignLineOffset(.center, std.math.nan(f32), 10));
    try std.testing.expectEqual(@as(f32, 0), alignLineOffset(.end, std.math.inf(f32), 10));
}

/// 斜体字形常有 typographic advance 之外的右侧 overhang。
/// 这里提供一个统一的启发式 padding，专门用于背景/选区矩形的视觉扩展，
/// 不参与 hit-test 或光标定位，避免逻辑宽度漂移。
pub fn estimateItalicOverhangPadding(font_size: f32, use_italic: bool) f32 {
    if (!use_italic) return 0;
    return std.math.clamp(font_size * 0.12, 1.0, 4.0);
}

// Phase 5: 上限 64 → 1024。完整 ArrayList 化在 Phase 6 文本管线重写时做
//（届时与 text_core PieceTree 整合一起切换）；当前 1024 已远超任何 UI 文本场景。
pub const MAX_LINES = 1024;
pub const INTERACTION_PREFIX_MAX_CHARS: usize = 1024;
const INTERACTION_PREFIX_CACHE_SIZE: usize = 512;
// Sidecar hash table (open addressing). >= 2x cache size for low collision rate.
const INTERACTION_PREFIX_INDEX_SIZE: usize = 2048;
const INTERACTION_PREFIX_INDEX_MASK: usize = INTERACTION_PREFIX_INDEX_SIZE - 1;
const INTERACTION_PREFIX_INDEX_PROBE_LIMIT: usize = 8;
/// 哨兵：sidecar 槽空 / 已驱逐
const INVALID_CACHE_IDX: u16 = std.math.maxInt(u16);

pub const LineInfo = struct {
    byte_start: u32,
    byte_end: u32,
    width: f32,
};

pub const TextLayout = struct {
    lines: [MAX_LINES]LineInfo = undefined,
    line_count: u16 = 0,
    total_height: f32 = 0,
    max_line_width: f32 = 0,
    // 缓存 key — 使用 ptr+len+hash 三重校验
    cached_content_ptr: [*]const u8 = undefined,
    cached_content_len: usize = 0,
    cached_content_hash: u64 = 0,
    cached_available_width: f32 = 0,
    cached_font_weight: u16 = 400,
    cached_font_size: f32 = 0,
    cached_use_italic: bool = false,
    cached_use_monospace: bool = false,
    cached_wrap: TextWrap = .none,
    cached_max_lines: u16 = 0,
    cached_spans_hash: u64 = 0,
};

// Hot header — accessed every lookup. ~64 bytes（一个 cache line）。
// 旧实现把 ~4.2MB 的 boundaries+prefix_widths 和 metadata 混在一个 entry 里，
// linear scan 时每个 entry 都 cache miss。先做 header/payload split（~32KB headers
// 装入 L1），再用 sidecar hash 索引把 lookup 从 O(N) 降到 O(1)。
const InteractionPrefixCacheHeader = struct {
    valid: bool = false,
    use_italic: bool = false,
    use_monospace: bool = false,
    _pad0: u8 = 0,
    boundary_count: u16 = 0,
    font_weight: u16 = 0,
    node_id: u32 = 0,
    content_version: u32 = 0,
    range_start: u32 = 0,
    range_end: u32 = 0,
    font_size: f32 = 0,
    last_used_gen: u32 = 0,
    spans_hash: u64 = 0,
    key_hash: u64 = 0, // 完整 key 的预算 hash，sidecar lookup 用
};

const InteractionPrefixCachePayload = struct {
    boundaries: [INTERACTION_PREFIX_MAX_CHARS + 1]u32 = [_]u32{0} ** (INTERACTION_PREFIX_MAX_CHARS + 1),
    prefix_widths: [INTERACTION_PREFIX_MAX_CHARS + 1]f32 = [_]f32{0} ** (INTERACTION_PREFIX_MAX_CHARS + 1),
};

/// 构建失败（range 超长）的 key memo：失败一次后同 key 不再重试整表构建。
/// 32 条环形覆盖"同屏若干条超长行被反复交互"的场景；key 含 content_version，
/// 编辑后自动失效。
var g_prefix_build_failed_ring: [32]u64 = [_]u64{0} ** 32;
var g_prefix_build_failed_cursor: usize = 0;

var interaction_prefix_cache_headers: [INTERACTION_PREFIX_CACHE_SIZE]InteractionPrefixCacheHeader =
    [_]InteractionPrefixCacheHeader{.{}} ** INTERACTION_PREFIX_CACHE_SIZE;
var interaction_prefix_cache_payloads: [INTERACTION_PREFIX_CACHE_SIZE]InteractionPrefixCachePayload =
    [_]InteractionPrefixCachePayload{.{}} ** INTERACTION_PREFIX_CACHE_SIZE;
/// sidecar：bucket → entry index in headers/payloads。INVALID_CACHE_IDX 表示空槽。
var interaction_prefix_cache_index: [INTERACTION_PREFIX_INDEX_SIZE]u16 =
    [_]u16{INVALID_CACHE_IDX} ** INTERACTION_PREFIX_INDEX_SIZE;
var interaction_prefix_cache_gen: u32 = 1;

inline fn computeInteractionPrefixKeyHash(
    node_id: u32,
    content_version: u32,
    range_start: u32,
    range_end: u32,
    spans_hash: u64,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&node_id));
    hasher.update(std.mem.asBytes(&content_version));
    hasher.update(std.mem.asBytes(&range_start));
    hasher.update(std.mem.asBytes(&range_end));
    hasher.update(std.mem.asBytes(&spans_hash));
    hasher.update(std.mem.asBytes(&font_size));
    hasher.update(std.mem.asBytes(&font_weight));
    const flags: u8 = (if (use_italic) @as(u8, 1) else 0) | (if (use_monospace) @as(u8, 2) else 0);
    hasher.update(std.mem.asBytes(&flags));
    return hasher.final();
}

inline fn cacheIndexBucket(key_hash: u64) usize {
    return @as(usize, @intCast(key_hash & INTERACTION_PREFIX_INDEX_MASK));
}

/// sidecar 中查找 key_hash → entry idx
fn sidecarLookup(key_hash: u64) ?u16 {
    var probe: usize = 0;
    while (probe < INTERACTION_PREFIX_INDEX_PROBE_LIMIT) : (probe += 1) {
        const bucket = (cacheIndexBucket(key_hash) + probe) & INTERACTION_PREFIX_INDEX_MASK;
        const idx = interaction_prefix_cache_index[bucket];
        if (idx == INVALID_CACHE_IDX) return null;
        const h = &interaction_prefix_cache_headers[idx];
        if (h.valid and h.key_hash == key_hash) return idx;
    }
    return null;
}

fn sidecarInsert(key_hash: u64, entry_idx: u16) void {
    var probe: usize = 0;
    while (probe < INTERACTION_PREFIX_INDEX_PROBE_LIMIT) : (probe += 1) {
        const bucket = (cacheIndexBucket(key_hash) + probe) & INTERACTION_PREFIX_INDEX_MASK;
        const slot = interaction_prefix_cache_index[bucket];
        if (slot == INVALID_CACHE_IDX or slot == entry_idx) {
            interaction_prefix_cache_index[bucket] = entry_idx;
            return;
        }
        const existing = &interaction_prefix_cache_headers[slot];
        if (!existing.valid) {
            interaction_prefix_cache_index[bucket] = entry_idx;
            return;
        }
    }
    // 探测溢出：覆盖第一个 bucket（罕见，PROBE_LIMIT=8 已留充足空间）
    interaction_prefix_cache_index[cacheIndexBucket(key_hash)] = entry_idx;
}

/// 当 entry 被驱逐时清除 sidecar 中指向它的所有 bucket。
fn sidecarRemoveByIndex(entry_idx: u16) void {
    for (&interaction_prefix_cache_index) |*slot| {
        if (slot.* == entry_idx) slot.* = INVALID_CACHE_IDX;
    }
}

fn nextInteractionCacheGen() u32 {
    interaction_prefix_cache_gen +%= 1;
    if (interaction_prefix_cache_gen == 0) {
        interaction_prefix_cache_gen = 1;
    }
    return interaction_prefix_cache_gen;
}

fn findInteractionPrefixCacheIndexByHash(key_hash: u64) ?usize {
    if (sidecarLookup(key_hash)) |idx| {
        const h = &interaction_prefix_cache_headers[idx];
        h.last_used_gen = nextInteractionCacheGen();
        return @as(usize, idx);
    }
    return null;
}

fn allocInteractionPrefixCacheIndex() usize {
    var lru_idx: usize = 0;
    var lru_gen: u32 = std.math.maxInt(u32);

    // O(N) LRU 扫描在 alloc 路径上仍然存在，但 alloc 只在 cache miss 时调用，
    // 远比 lookup 频率低。N=512 的扫描 ~512 cycles，可接受。
    for (&interaction_prefix_cache_headers, 0..) |*h, idx| {
        if (!h.valid) {
            h.* = .{};
            h.last_used_gen = nextInteractionCacheGen();
            return idx;
        }
        if (h.last_used_gen <= lru_gen) {
            lru_gen = h.last_used_gen;
            lru_idx = idx;
        }
    }

    // 驱逐：先从 sidecar 中清除指向该 entry 的 bucket
    sidecarRemoveByIndex(@intCast(lru_idx));
    interaction_prefix_cache_headers[lru_idx] = .{};
    interaction_prefix_cache_headers[lru_idx].last_used_gen = nextInteractionCacheGen();
    return lru_idx;
}

pub fn buildPrefixWidthsForRange(
    content: []const u8,
    range_start: u32,
    range_end: u32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
    boundaries: []u32,
    prefix_widths: []f32,
) ?usize {
    if (range_end <= range_start or range_end > content.len) return null;
    if (boundaries.len == 0 or boundaries.len != prefix_widths.len) return null;

    const text = content[range_start..range_end];
    boundaries[0] = 0;
    prefix_widths[0] = 0;

    // 分块增量测量。旧实现每个 grapheme 都从 range_start 重测整个前缀：
    // O(N²) shaped bytes，且每个前缀是不同字符串 → measure cache 命中率恒 0，
    // 500 字符行的首次构建 = 500 次对平均 250 字节串的全价 CoreText。
    // 现在每 PREFIX_CHUNK_GRAPHEMES 个 grapheme 落一个 checkpoint，块内只测
    // [checkpoint, next_off)（span 语义不变：measureTextWidthWithSpans 本来就按
    // content 全局偏移收 span），前缀宽度 = checkpoint 累计 + 块内宽度。
    // 代价：checkpoint 边界处的 kerning 丢失（CJK 为 0，拉丁 pair 亚像素级、
    // 每 64 字素至多一次）；binary search 需要的单调性不受影响。
    var off: usize = 0;
    var count: usize = 1;
    var chunk_base_off: u32 = 0;
    var chunk_base_w: f32 = 0;
    var since_checkpoint: usize = 0;
    var grapheme_cursor = grapheme.BoundaryCursor.init(text);
    while (off < text.len and count < boundaries.len) {
        const next_off = grapheme_cursor.next(off);
        const chunk_w = measureTextWidthWithSpans(
            content,
            range_start + chunk_base_off,
            range_start + @as(u32, @intCast(next_off)),
            font_size,
            font_weight,
            use_italic,
            use_monospace,
            spans,
        );
        const prefix_w = chunk_base_w + chunk_w;
        boundaries[count] = @intCast(next_off);
        prefix_widths[count] = prefix_w;
        off = next_off;
        count += 1;
        since_checkpoint += 1;
        if (since_checkpoint >= PREFIX_CHUNK_GRAPHEMES) {
            chunk_base_off = @intCast(off);
            chunk_base_w = prefix_w;
            since_checkpoint = 0;
        }
    }

    if (off < text.len) return null;
    return count;
}

/// buildPrefixWidthsForRange 的 checkpoint 间隔。越小越接近整前缀测量的
/// kerning 语义，越大单次测量串越长；64 字素 ≈ 256 字节 CJK / 64 字节 ASCII，
/// 块内子串短到 measure cache miss 也便宜。
const PREFIX_CHUNK_GRAPHEMES: usize = 64;

pub fn hitTestPrefixBoundaries(
    boundaries: []const u32,
    prefix_widths: []const f32,
    boundary_count: usize,
    target_x: f32,
) usize {
    if (boundary_count <= 1 or target_x <= 0) return 0;

    const total_w = prefix_widths[boundary_count - 1];
    if (target_x >= total_w) return boundaries[boundary_count - 1];

    var lo: usize = 1;
    var hi: usize = boundary_count - 1;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (prefix_widths[mid] <= target_x) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    const prev_idx = lo - 1;
    const prev_w = prefix_widths[prev_idx];
    const cur_w = prefix_widths[lo];
    const char_w = cur_w - prev_w;
    if (target_x < prev_w + char_w / 2.0) {
        return boundaries[prev_idx];
    }
    return boundaries[lo];
}

pub fn measurePrefixWidthFromBoundaries(
    boundaries: []const u32,
    prefix_widths: []const f32,
    boundary_count: usize,
    local_end: u32,
) ?f32 {
    if (local_end == 0 or boundary_count == 0) return 0;

    var lo: usize = 0;
    var hi: usize = boundary_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (boundaries[mid] < local_end) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo < boundary_count and boundaries[lo] == local_end) {
        return prefix_widths[lo];
    }
    return null;
}

pub const PrefixBoundaryFloorResult = struct {
    byte_end: u32,
    width: f32,
};

pub fn floorPrefixBoundaryByWidth(
    boundaries: []const u32,
    prefix_widths: []const f32,
    boundary_count: usize,
    target_x: f32,
) PrefixBoundaryFloorResult {
    if (boundary_count == 0 or target_x <= 0) {
        return .{ .byte_end = 0, .width = 0 };
    }

    const last_idx = boundary_count - 1;
    if (target_x >= prefix_widths[last_idx]) {
        return .{
            .byte_end = boundaries[last_idx],
            .width = prefix_widths[last_idx],
        };
    }

    var lo: usize = 0;
    var hi: usize = last_idx;
    while (lo < hi) {
        const mid = lo + ((hi - lo + 1) / 2);
        if (prefix_widths[mid] <= target_x) {
            lo = mid;
        } else if (mid == 0) {
            break;
        } else {
            hi = mid - 1;
        }
    }

    return .{
        .byte_end = boundaries[lo],
        .width = prefix_widths[lo],
    };
}

fn buildInteractionPrefixCacheEntryAt(
    idx: usize,
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?usize {
    if (range_end <= range_start or range_end > content.len) return null;

    const h = &interaction_prefix_cache_headers[idx];
    h.* = .{
        .valid = false,
        .node_id = node_id,
        .content_version = content_version,
        .range_start = range_start,
        .range_end = range_end,
        .spans_hash = hashSpans(spans),
        .font_size = font_size,
        .font_weight = font_weight,
        .use_italic = use_italic,
        .use_monospace = use_monospace,
        .boundary_count = 1,
        .last_used_gen = nextInteractionCacheGen(),
    };
    const p = &interaction_prefix_cache_payloads[idx];
    const count = buildPrefixWidthsForRange(
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
        p.boundaries[0..],
        p.prefix_widths[0..],
    ) orelse return null;

    h.boundary_count = @intCast(count);
    h.valid = true;
    return idx;
}

fn getInteractionPrefixCacheIndex(
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?usize {
    if (range_end <= range_start or range_end > content.len) return null;

    const spans_hash = hashSpans(spans);
    const key_hash = computeInteractionPrefixKeyHash(
        node_id,
        content_version,
        range_start,
        range_end,
        spans_hash,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
    );
    if (findInteractionPrefixCacheIndexByHash(key_hash)) |idx| return idx;
    // 失败 memo：超过 INTERACTION_PREFIX_MAX_CHARS 的 range 构建必然失败，
    // 但失败前已经烧掉一整表的测量。同 key 的失败只烧一次——命中 memo 直接
    // 走调用方 fallback。key 含 content_version/spans/字体，内容一变自然重试。
    for (g_prefix_build_failed_ring) |fk| {
        if (fk == key_hash) return null;
    }

    const idx = allocInteractionPrefixCacheIndex();
    const built = buildInteractionPrefixCacheEntryAt(
        idx,
        node_id,
        content_version,
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
    ) orelse {
        g_prefix_build_failed_ring[g_prefix_build_failed_cursor] = key_hash;
        g_prefix_build_failed_cursor = (g_prefix_build_failed_cursor + 1) % g_prefix_build_failed_ring.len;
        return null;
    };
    interaction_prefix_cache_headers[idx].key_hash = key_hash;
    sidecarInsert(key_hash, @intCast(idx));
    return built;
}

pub fn hitTestPrefixWidthRangeCached(
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    target_x: f32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?usize {
    if (target_x <= 0 or range_end <= range_start) return 0;

    const idx = getInteractionPrefixCacheIndex(
        node_id,
        content_version,
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
    ) orelse return null;

    const h = &interaction_prefix_cache_headers[idx];
    const p = &interaction_prefix_cache_payloads[idx];
    const count = @as(usize, h.boundary_count);
    return hitTestPrefixBoundaries(p.boundaries[0..count], p.prefix_widths[0..count], count, target_x);
}

pub fn measurePrefixWidthRangeCached(
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    byte_end: u32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?f32 {
    if (byte_end <= range_start) return 0;
    if (range_end <= range_start) return 0;

    const idx = getInteractionPrefixCacheIndex(
        node_id,
        content_version,
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
    ) orelse return null;

    const h = &interaction_prefix_cache_headers[idx];
    const p = &interaction_prefix_cache_payloads[idx];
    const local_end = byte_end - range_start;
    const count = @as(usize, h.boundary_count);
    return measurePrefixWidthFromBoundaries(p.boundaries[0..count], p.prefix_widths[0..count], count, local_end);
}

pub fn floorPrefixBoundaryByWidthCached(
    node_id: u32,
    content_version: u32,
    content: []const u8,
    range_start: u32,
    range_end: u32,
    target_x: f32,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) ?PrefixBoundaryFloorResult {
    if (range_end <= range_start or target_x <= 0) {
        return .{ .byte_end = range_start, .width = 0 };
    }

    const idx = getInteractionPrefixCacheIndex(
        node_id,
        content_version,
        content,
        range_start,
        range_end,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        spans,
    ) orelse return null;

    const h = &interaction_prefix_cache_headers[idx];
    const p = &interaction_prefix_cache_payloads[idx];
    const count = @as(usize, h.boundary_count);
    const result = floorPrefixBoundaryByWidth(
        p.boundaries[0..count],
        p.prefix_widths[0..count],
        count,
        target_x,
    );
    return .{
        .byte_end = range_start + result.byte_end,
        .width = result.width,
    };
}

/// 判断是否为 CJK 字符（中日韩统一表意文字范围，可在任意位置断行）。
/// 实现收敛在 i18n.linebreak.isCJK（WrapMap precise 断点共用同一判定）。
pub fn isCJK(codepoint: u21) bool {
    const i18n = @import("i18n");
    return i18n.linebreak.isCJK(codepoint);
}

/// cluster-aware 是否可断（UAX #14，接 i18n.linebreak）。
pub fn isBreakableCluster(prev_cp: u32, next_cp: u32) bool {
    const i18n = @import("i18n");
    const prev_class = i18n.linebreak.classify(prev_cp);
    const next_class = i18n.linebreak.classify(next_cp);
    return i18n.linebreak.canBreakBetween(prev_class, next_class);
}

/// 获取 UTF-8 字符的字节长度
pub fn utf8CharLen(first_byte: u8) u3 {
    if (first_byte < 0x80) return 1;
    if (first_byte & 0xE0 == 0xC0) return 2;
    if (first_byte & 0xF0 == 0xE0) return 3;
    if (first_byte & 0xF8 == 0xF0) return 4;
    return 1; // invalid, treat as single byte
}

/// 解码 UTF-8 code point
pub fn decodeUtf8(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0;
    const b0 = bytes[0];
    if (b0 < 0x80) return b0;
    if (b0 & 0xE0 == 0xC0 and bytes.len >= 2) {
        return (@as(u21, b0 & 0x1F) << 6) | @as(u21, bytes[1] & 0x3F);
    }
    if (b0 & 0xF0 == 0xE0 and bytes.len >= 3) {
        return (@as(u21, b0 & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | @as(u21, bytes[2] & 0x3F);
    }
    if (b0 & 0xF8 == 0xF0 and bytes.len >= 4) {
        return (@as(u21, b0 & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) | (@as(u21, bytes[2] & 0x3F) << 6) | @as(u21, bytes[3] & 0x3F);
    }
    return 0xFFFD; // replacement character
}

/// 计算文本折行布局
///
/// 参数:
/// - content: UTF-8 文本内容
/// - available_width: 可用宽度（像素）
/// - wrap: 折行模式
/// - max_lines: 最大行数限制（0=无限制）
/// - font_size: 字体大小
/// - line_height: 行高倍数
/// - use_italic: 基础 italic 开关
/// - spans: TextSpan 数组，有 span 覆盖时用 span.font_weight/italic 测量
pub fn computeTextLayout(
    content: []const u8,
    available_width: f32,
    wrap: TextWrap,
    max_lines: u16,
    font_size: f32,
    line_height: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) TextLayout {
    var layout = TextLayout{};

    if (content.len == 0 or available_width <= 0) {
        layout.line_count = 1;
        layout.lines[0] = .{ .byte_start = 0, .byte_end = 0, .width = 0 };
        layout.total_height = font_size * line_height;
        return layout;
    }

    if (wrap == .none) {
        // 不换行：单行
        layout.line_count = 1;
        layout.lines[0] = .{
            .byte_start = 0,
            .byte_end = @intCast(content.len),
            .width = measureSpanAware(content, 0, @intCast(content.len), font_size, font_weight, use_italic, use_monospace, spans),
        };
        layout.max_line_width = layout.lines[0].width;
        layout.total_height = font_size * line_height;
        return layout;
    }

    if (wrap == .newline_only) {
        // 只在 \n 断行，不做宽度折行（code fence 等场景）
        var line_start: u32 = 0;
        var lc: u16 = 0;
        var mw: f32 = 0;
        while (line_start <= content.len and lc < MAX_LINES) {
            // 找到行尾（\n 或 EOF）
            var line_end: u32 = line_start;
            while (line_end < content.len and content[line_end] != '\n') line_end += 1;

            const w = measureSpanAware(content, line_start, line_end, font_size, font_weight, use_italic, use_monospace, spans);
            layout.lines[lc] = .{ .byte_start = line_start, .byte_end = line_end, .width = w };
            mw = @max(mw, w);
            lc += 1;

            if (line_end >= content.len) break;
            line_start = line_end + 1; // 跳过 \n
        }
        if (lc == 0) {
            lc = 1;
            layout.lines[0] = .{ .byte_start = 0, .byte_end = 0, .width = 0 };
        }
        layout.line_count = lc;
        layout.max_line_width = mw;
        layout.total_height = @as(f32, @floatFromInt(lc)) * font_size * line_height;

        layout.cached_content_ptr = content.ptr;
        layout.cached_content_len = content.len;
        layout.cached_content_hash = std.hash.Wyhash.hash(0, content);
        layout.cached_available_width = available_width;
        layout.cached_font_weight = font_weight;
        layout.cached_font_size = font_size;
        layout.cached_use_italic = use_italic;
        layout.cached_use_monospace = use_monospace;
        layout.cached_wrap = wrap;
        layout.cached_max_lines = max_lines;
        layout.cached_spans_hash = hashSpans(spans);
        return layout;
    }

    const effective_max: u16 = if (max_lines == 0) MAX_LINES else @min(max_lines, MAX_LINES);

    var line_start: u32 = 0;
    var line_count: u16 = 0;
    var max_width: f32 = 0;

    while (line_start < content.len and line_count < effective_max) {
        // 寻找当前行的断行点
        const result = findLineBreak(content, line_start, available_width, wrap, font_size, font_weight, use_italic, use_monospace, spans);
        const line_end = line_start + result.byte_len;
        const line_width = result.width;

        layout.lines[line_count] = .{
            .byte_start = line_start,
            .byte_end = @intCast(line_end),
            .width = line_width,
        };
        max_width = @max(max_width, line_width);
        line_count += 1;

        line_start = @intCast(line_end);

        // 跳过断行后的空格（word wrap 模式）
        if (wrap == .word) {
            while (line_start < content.len and content[line_start] == ' ') {
                line_start += 1;
            }
        }

        // A hard newline terminates the line we just emitted; it is not a
        // second, empty line of its own.  Leaving it for the next iteration
        // made `one\ntwo` occupy rows 0 and 2, so a three-row editor clipped
        // the third paragraph at row 4.  Consume exactly one separator here.
        // A trailing separator still creates the expected final empty line.
        if (line_start < content.len and content[line_start] == '\n') {
            line_start += 1;
            if (line_start == content.len and line_count < effective_max) {
                layout.lines[line_count] = .{
                    .byte_start = line_start,
                    .byte_end = line_start,
                    .width = 0,
                };
                line_count += 1;
            }
        }
    }

    if (line_count == 0) {
        line_count = 1;
        layout.lines[0] = .{ .byte_start = 0, .byte_end = 0, .width = 0 };
    }

    layout.line_count = line_count;
    layout.max_line_width = max_width;
    layout.total_height = @as(f32, @floatFromInt(line_count)) * font_size * line_height;

    // 缓存 key（ptr+len 快速路径 + hash 防止指针复用时误命中）
    layout.cached_content_ptr = content.ptr;
    layout.cached_content_len = content.len;
    layout.cached_content_hash = std.hash.Wyhash.hash(0, content);
    layout.cached_available_width = available_width;
    layout.cached_font_weight = font_weight;
    layout.cached_font_size = font_size;
    layout.cached_use_italic = use_italic;
    layout.cached_use_monospace = use_monospace;
    layout.cached_wrap = wrap;
    layout.cached_max_lines = max_lines;
    layout.cached_spans_hash = hashSpans(spans);

    return layout;
}

/// 内部辅助：span 感知测量（有 spans 时分段，无 spans 时直接测量）
fn measureSpanAware(content: []const u8, start: u32, end: u32, font_size: f32, base_fw: u16, use_italic: bool, use_monospace: bool, spans: []const TextSpan) f32 {
    if (spans.len == 0) return measureTextWidthByFontKind(content[start..end], font_size, base_fw, use_italic, use_monospace);
    return measureTextWidthWithSpans(content, start, end, font_size, base_fw, use_italic, use_monospace, spans);
}

fn hashSpans(spans: []const TextSpan) u64 {
    if (spans.len == 0) return 0;
    const bytes = std.mem.sliceAsBytes(spans);
    return std.hash.Wyhash.hash(0, bytes);
}

const LineBreakResult = struct {
    byte_len: u32,
    width: f32,
};

/// 在给定宽度内找到一行的断行点
/// content: 完整文本, line_start: 本行在 content 中的起始偏移
fn findLineBreak(
    content: []const u8,
    line_start: u32,
    available_width: f32,
    wrap: TextWrap,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    spans: []const TextSpan,
) LineBreakResult {
    const text = content[line_start..];

    // 快速路径：先找到本行的自然结束位置（\n 或 EOF）
    var natural_end: u32 = 0;
    while (natural_end < text.len and text[natural_end] != '\n') natural_end += 1;
    // 整行测量一次：如果整行宽度 <= available_width，直接返回，
    // 避免逐字符推进（从 O(N) 次 CoreText 调用降到 O(1)）
    if (natural_end > 0) {
        const full_width = measureSpanAware(content, line_start, line_start + natural_end, font_size, font_weight, use_italic, use_monospace, spans);
        if (full_width <= available_width) {
            return .{ .byte_len = natural_end, .width = full_width };
        }
    }

    // 分块增量测量（与 buildPrefixWidthsForRange 同方案）：旧实现每个
    // grapheme 从 line_start 重测整个前缀 = O(N²) shaped bytes 且每个前缀
    // 都是唯一字符串（measure cache 恒 miss）。首帧布局对每个折行文本节点
    // 都要走到这里——md 打开帧 215ms 布局成本的主力。每 64 字素落一个
    // checkpoint，块内只测 [checkpoint, next)，前缀宽 = 累计 + 块内宽。
    // checkpoint 边界 kerning 损失：CJK=0，拉丁亚像素级（G3 同款取舍）。
    var pos: u32 = 0;
    var width_so_far: f32 = 0;
    var last_break_pos: u32 = 0;
    var last_break_width: f32 = 0;
    var has_break_point = false;
    var chunk_base: u32 = 0;
    var chunk_base_w: f32 = 0;
    var since_checkpoint: usize = 0;
    var grapheme_cursor = grapheme.BoundaryCursor.init(text);

    while (pos < text.len) {
        // 遇到换行符，在此结束本行
        if (text[pos] == '\n') {
            return .{ .byte_len = pos, .width = width_so_far };
        }

        const next_pos: u32 = @intCast(grapheme_cursor.next(pos));
        if (next_pos > text.len) break;

        const previous_width = width_so_far;
        width_so_far = chunk_base_w + measureSpanAware(
            content,
            line_start + chunk_base,
            line_start + @as(u32, @intCast(next_pos)),
            font_size,
            font_weight,
            use_italic,
            use_monospace,
            spans,
        );
        since_checkpoint += 1;
        if (since_checkpoint >= PREFIX_CHUNK_GRAPHEMES) {
            chunk_base = @intCast(next_pos);
            chunk_base_w = width_so_far;
            since_checkpoint = 0;
        }

        if (width_so_far > available_width and pos > 0) {
            // 超出可用宽度
            if (wrap == .word and has_break_point) {
                // word 模式：回退到上一个断行点
                return .{ .byte_len = last_break_pos, .width = last_break_width };
            }
            // char 模式或无断行点：在当前字符前断行
            return .{ .byte_len = pos, .width = previous_width };
        }

        // 记录可能的断行点
        if (wrap == .word) {
            const cp = decodeUtf8(text[pos..@min(pos + 4, @as(u32, @intCast(text.len)))]);
            if (isCJK(cp)) {
                // CJK 字符后可断行
                last_break_pos = @intCast(next_pos);
                last_break_width = width_so_far;
                has_break_point = true;
            } else if (next_pos < text.len) {
                // UAX #14：当前 cp 与下一 cp 之间是否可断
                const next_cp_bytes = text[@intCast(next_pos)..@min(@as(usize, @intCast(next_pos)) + 4, text.len)];
                const next_cp = decodeUtf8(next_cp_bytes);
                if (isBreakableCluster(cp, next_cp)) {
                    last_break_pos = @intCast(next_pos);
                    last_break_width = width_so_far;
                    has_break_point = true;
                }
            }
        }

        pos = @intCast(next_pos);
    }

    // 未超出宽度，整段放在一行
    return .{ .byte_len = pos, .width = width_so_far };
}

/// 检查缓存是否有效
/// 使用 ptr+len 快速路径 + hash 校验防止指针复用时误命中
/// 宽度使用 0.5px epsilon 比较，避免浮点精度导致的无效重计算
pub fn isCacheValid(layout: *const TextLayout, content: []const u8, available_width: f32, font_weight: u16, font_size: f32, use_italic: bool, use_monospace: bool, wrap: TextWrap, max_lines: u16, spans: []const TextSpan) bool {
    if (layout.line_count == 0) return false;
    if (layout.cached_content_len != content.len) return false;
    if (@abs(layout.cached_available_width - available_width) > 0.5) return false;
    if (layout.cached_font_weight != font_weight) return false;
    if (layout.cached_font_size != font_size) return false;
    if (layout.cached_use_italic != use_italic) return false;
    if (layout.cached_use_monospace != use_monospace) return false;
    if (layout.cached_wrap != wrap) return false;
    if (layout.cached_max_lines != max_lines) return false;
    if (layout.cached_spans_hash != hashSpans(spans)) return false;

    // 快速路径：ptr 相同且 hash 匹配
    if (layout.cached_content_ptr == content.ptr) return true;

    // 慢路径：ptr 不同但内容可能相同（内存重新分配后）
    return layout.cached_content_hash == std.hash.Wyhash.hash(0, content);
}

test "interaction prefix cache matches direct prefix measurement" {
    const content = "hello world";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};

    const direct = measureTextWidthWithSpans(content, 0, 5, font_size, font_weight, use_italic, false, spans);
    const cached = measurePrefixWidthRangeCached(101, 1, content, 0, @intCast(content.len), 5, font_size, font_weight, use_italic, false, spans);

    try std.testing.expect(cached != null);
    try std.testing.expectApproxEqAbs(direct, cached.?, 0.001);
}

test "build prefix widths supports direct hit testing without cache" {
    const content = "hello world";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};
    var boundaries: [INTERACTION_PREFIX_MAX_CHARS + 1]u32 = undefined;
    var prefix_widths: [INTERACTION_PREFIX_MAX_CHARS + 1]f32 = undefined;

    const count = buildPrefixWidthsForRange(
        content,
        0,
        @intCast(content.len),
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
        boundaries[0..],
        prefix_widths[0..],
    );

    try std.testing.expect(count != null);
    try std.testing.expectApproxEqAbs(
        measureTextWidthWithSpans(content, 0, 5, font_size, font_weight, use_italic, false, spans),
        measurePrefixWidthFromBoundaries(boundaries[0..count.?], prefix_widths[0..count.?], count.?, 5).?,
        0.001,
    );
    try std.testing.expectEqual(@as(usize, 2), hitTestPrefixBoundaries(boundaries[0..count.?], prefix_widths[0..count.?], count.?, prefix_widths[2] - 0.01));
}

test "interaction prefix cache hit test matches expected boundary" {
    const content = "hello";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};
    const char_w = measureProportional("h", font_size, font_weight, use_italic);

    const left_half = hitTestPrefixWidthRangeCached(
        202,
        1,
        content,
        0,
        @intCast(content.len),
        char_w * 2.4,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );
    const right_half = hitTestPrefixWidthRangeCached(
        202,
        1,
        content,
        0,
        @intCast(content.len),
        char_w * 2.6,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );

    try std.testing.expectEqual(@as(?usize, 2), left_half);
    try std.testing.expectEqual(@as(?usize, 3), right_half);
}

test "interaction prefix cache invalidates on content change" {
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};

    const first = measurePrefixWidthRangeCached(303, 1, "abc", 0, 3, 3, font_size, font_weight, use_italic, false, spans);
    const second = measurePrefixWidthRangeCached(303, 2, "abcdef", 0, 6, 6, font_size, font_weight, use_italic, false, spans);

    try std.testing.expect(first != null);
    try std.testing.expect(second != null);
    try std.testing.expect(second.? > first.?);
}

test "interaction prefix cache can floor prefix boundary by width" {
    const content = "hello world";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};
    const target_boundary: u32 = 5;
    const target_w = measureTextWidthWithSpans(content, 0, target_boundary, font_size, font_weight, use_italic, false, spans);

    const exact = floorPrefixBoundaryByWidthCached(
        404,
        1,
        content,
        0,
        @intCast(content.len),
        target_w,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );
    const just_before = floorPrefixBoundaryByWidthCached(
        404,
        1,
        content,
        0,
        @intCast(content.len),
        target_w - 0.01,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );

    try std.testing.expect(exact != null);
    try std.testing.expectEqual(target_boundary, exact.?.byte_end);
    try std.testing.expectApproxEqAbs(target_w, exact.?.width, 0.001);
    try std.testing.expect(just_before != null);
    try std.testing.expect(just_before.?.byte_end < target_boundary);
    try std.testing.expect(just_before.?.width < target_w);
}

test "word wrap consumes each hard newline exactly once" {
    const layout = computeTextLayout(
        "one\ntwo\nthree",
        1000,
        .word,
        0,
        14,
        1.25,
        400,
        false,
        false,
        &.{},
    );

    try std.testing.expectEqual(@as(u16, 3), layout.line_count);
    try std.testing.expectEqual(@as(u32, 0), layout.lines[0].byte_start);
    try std.testing.expectEqual(@as(u32, 3), layout.lines[0].byte_end);
    try std.testing.expectEqual(@as(u32, 4), layout.lines[1].byte_start);
    try std.testing.expectEqual(@as(u32, 7), layout.lines[1].byte_end);
    try std.testing.expectEqual(@as(u32, 8), layout.lines[2].byte_start);
    try std.testing.expectEqual(@as(u32, 13), layout.lines[2].byte_end);
}

test "word wrap preserves intentional empty and trailing hard-newline rows" {
    const middle_empty = computeTextLayout("a\n\nb", 1000, .word, 0, 14, 1.25, 400, false, false, &.{});
    try std.testing.expectEqual(@as(u16, 3), middle_empty.line_count);
    try std.testing.expectEqual(middle_empty.lines[1].byte_start, middle_empty.lines[1].byte_end);

    const trailing_empty = computeTextLayout("a\n", 1000, .word, 0, 14, 1.25, 400, false, false, &.{});
    try std.testing.expectEqual(@as(u16, 2), trailing_empty.line_count);
    try std.testing.expectEqual(@as(u32, 2), trailing_empty.lines[1].byte_start);
    try std.testing.expectEqual(@as(u32, 2), trailing_empty.lines[1].byte_end);
}

test "findLineBreak preserves word wrap boundary with incremental width accumulation" {
    const content = "abc def";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{};
    const break_width = measureTextWidthWithSpans(content, 0, 4, font_size, font_weight, use_italic, false, spans);

    const result = findLineBreak(
        content,
        0,
        break_width + 0.01,
        .word,
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
    );

    try std.testing.expectEqual(@as(u32, 4), result.byte_len);
    try std.testing.expectApproxEqAbs(break_width, result.width, 0.001);
}

test "findLineBreak never splits an extended grapheme cluster" {
    const content = "A👩‍💻B";
    const after_a: u32 = 1;
    const after_emoji: u32 = @intCast(grapheme.nextBoundary(content, after_a));
    const width_a = measureTextWidthWithSpans(content, 0, after_a, 10, 400, false, false, &.{});
    const width_through_emoji = measureTextWidthWithSpans(content, 0, after_emoji, 10, 400, false, false, &.{});
    const result = findLineBreak(content, 0, (width_a + width_through_emoji) * 0.5, .char, 10, 400, false, false, &.{});
    try std.testing.expectEqual(after_a, result.byte_len);
    try std.testing.expect(grapheme.nextBoundary(content, grapheme.prevBoundary(content, result.byte_len)) == result.byte_len);
}

test "measureTextWidthWithSpans respects base monospace across gaps and spans" {
    const Helpers = struct {
        fn proportionalMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size * 0.5;
        }
        fn monospaceMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size;
        }
    };

    setMeasureFn(Helpers.proportionalMeasure);
    defer setMeasureFn(null);
    setMonospaceMeasureFn(Helpers.monospaceMeasure);
    defer setMonospaceMeasureFn(null);

    const content = "ab";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const spans: []const TextSpan = &.{
        .{
            .start = 1,
            .end = 2,
            .color = types.Color.rgba(255, 0, 0, 255),
        },
    };

    const measured = measureTextWidthWithSpans(content, 0, 2, font_size, font_weight, false, true, spans);
    try std.testing.expectApproxEqAbs(@as(f32, 20), measured, 0.001);
}

test "monospace measurement handles CJK fallback correctly" {
    // 模拟一个真 monospace measure：ASCII 1 byte = font_size，CJK 3 byte = 2 * font_size
    // 这是 Menlo + PingFang fallback 的典型行为：CJK 占两个 cell。
    const Helpers = struct {
        fn monospaceMeasure(text_ptr: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            const slice = text_ptr[0..text_len];
            var width: f32 = 0;
            var i: usize = 0;
            while (i < slice.len) {
                const b = slice[i];
                if (b < 0x80) {
                    width += font_size;
                    i += 1;
                } else {
                    // UTF-8 multibyte —— 模拟 CJK 占两个 cell
                    const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                    width += font_size * 2;
                    i += cp_len;
                }
            }
            return width;
        }
    };

    setMonospaceMeasureFn(Helpers.monospaceMeasure);
    defer setMonospaceMeasureFn(null);

    const font_size: f32 = 10;
    const font_weight: u16 = 400;

    // 纯 ASCII —— 应该 = len * font_size
    const ascii_only = measureMonospaceTextWidth("hello", font_size, font_weight, false);
    try std.testing.expectApproxEqAbs(@as(f32, 50), ascii_only, 0.001);

    // 纯 CJK 3 个字符 = 9 字节 —— 应该 = 3 * 2 * font_size = 60
    const cjk_only = measureMonospaceTextWidth("你好啊", font_size, font_weight, false);
    try std.testing.expectApproxEqAbs(@as(f32, 60), cjk_only, 0.001);

    // 混合：5 ASCII + 2 CJK = 5 * 10 + 2 * 20 = 90
    const mixed = measureMonospaceTextWidth("hello你好", font_size, font_weight, false);
    try std.testing.expectApproxEqAbs(@as(f32, 90), mixed, 0.001);

    // 至关重要：含 CJK 的字符串绝不能走 ASCII fast path
    // （fast path 会把 8 字节算成 8 * font_size = 80，比正确值 90 少 10）
    try std.testing.expect(mixed != 80);
}

// 矩阵 #8 —— shape cache > 95%
test "measure cache produces > 95% hit rate on repeated text" {
    const Helpers = struct {
        fn fakeMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size * 0.6;
        }
    };
    setMeasureFn(Helpers.fakeMeasure);
    defer setMeasureFn(null);

    invalidateMeasureCache();
    resetMeasureCacheStats();

    // 模拟列表场景：100 行同 text 各测一次（cache miss 第 1 次，hit 后 99 次）
    const sample_text = "Hello World";
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        _ = measureProportional(sample_text, 14, 400, false);
    }

    const stats = measureCacheStats();
    try std.testing.expect(stats.hits >= 99);
    try std.testing.expect(stats.hitRate() > 0.95);
}

test "interaction prefix cache distinguishes monospace base font" {
    const Helpers = struct {
        fn proportionalMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size * 0.5;
        }
        fn monospaceMeasure(_: [*]const u8, text_len: usize, font_size: f32, _: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(text_len)) * font_size;
        }
    };

    setMeasureFn(Helpers.proportionalMeasure);
    defer setMeasureFn(null);
    setMonospaceMeasureFn(Helpers.monospaceMeasure);
    defer setMonospaceMeasureFn(null);

    const content = "abc";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const spans: []const TextSpan = &.{};

    const proportional = measurePrefixWidthRangeCached(505, 1, content, 0, @intCast(content.len), 3, font_size, font_weight, false, false, spans);
    const monospace = measurePrefixWidthRangeCached(505, 1, content, 0, @intCast(content.len), 3, font_size, font_weight, false, true, spans);

    try std.testing.expect(proportional != null);
    try std.testing.expect(monospace != null);
    try std.testing.expectApproxEqAbs(@as(f32, 15), proportional.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), monospace.?, 0.001);
}

test "measureTextWidthWithSpans includes inline box horizontal padding" {
    const content = "code";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{
        .{
            .start = 0,
            .end = 4,
            .use_monospace_font = true,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .inline_box_padding_left = 4,
            .inline_box_padding_right = 4,
            .inline_box_inset_top = 1,
            .inline_box_inset_bottom = 1,
            .inline_box_corner_radius = 3,
        },
    };

    const text_only = measureMonospaceTextWidth(content, font_size, font_weight, use_italic);
    const measured = measureTextWidthWithSpans(content, 0, 4, font_size, font_weight, use_italic, false, spans);

    try std.testing.expectApproxEqAbs(text_only + 8, measured, 0.001);
}

test "inline box prefix widths include leading and trailing padding exactly once" {
    const content = "code";
    const font_size: f32 = 10;
    const font_weight: u16 = 400;
    const use_italic = false;
    const spans: []const TextSpan = &.{
        .{
            .start = 0,
            .end = 4,
            .use_monospace_font = true,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .inline_box_padding_left = 4,
            .inline_box_padding_right = 4,
            .inline_box_inset_top = 1,
            .inline_box_inset_bottom = 1,
            .inline_box_corner_radius = 3,
        },
    };
    var boundaries: [INTERACTION_PREFIX_MAX_CHARS + 1]u32 = undefined;
    var prefix_widths: [INTERACTION_PREFIX_MAX_CHARS + 1]f32 = undefined;

    const count = buildPrefixWidthsForRange(
        content,
        0,
        @intCast(content.len),
        font_size,
        font_weight,
        use_italic,
        false,
        spans,
        boundaries[0..],
        prefix_widths[0..],
    ) orelse return error.TestUnexpectedResult;

    const first_char = measureMonospaceTextWidth("c", font_size, font_weight, use_italic);
    const full_text = measureMonospaceTextWidth(content, font_size, font_weight, use_italic);

    try std.testing.expectApproxEqAbs(first_char + 4, prefix_widths[1], 0.001);
    try std.testing.expectApproxEqAbs(full_text + 8, prefix_widths[count - 1], 0.001);
    try std.testing.expectEqual(@as(usize, 0), hitTestPrefixBoundaries(boundaries[0..count], prefix_widths[0..count], count, 1.0));
}

// v0.5 §5 GlyphRun-B 测试用 mock callback
const TestShapeContext = struct {
    var call_count: u32 = 0;
    var last_text: []const u8 = "";
    var return_value: f32 = 0;
};

fn testShapeMeasureMock(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32 {
    _ = font_size;
    _ = font_weight;
    _ = use_italic;
    _ = use_monospace;
    TestShapeContext.call_count += 1;
    TestShapeContext.last_text = text;
    return TestShapeContext.return_value;
}

test "shape measure callback intercepts measureProportional when set" {
    invalidateMeasureCache();
    TestShapeContext.call_count = 0;
    TestShapeContext.return_value = 42.0;
    setShapeMeasureFn(&testShapeMeasureMock);
    defer setShapeMeasureFn(null);

    const w = measureProportional("hello", 14.0, 400, false);
    try std.testing.expectApproxEqAbs(@as(f32, 42), w, 0.001);
    try std.testing.expectEqual(@as(u32, 1), TestShapeContext.call_count);
    try std.testing.expectEqualStrings("hello", TestShapeContext.last_text);
}

test "shape measure callback NaN return falls back to platform measure" {
    invalidateMeasureCache();
    TestShapeContext.call_count = 0;
    TestShapeContext.return_value = std.math.nan(f32);
    setShapeMeasureFn(&testShapeMeasureMock);
    defer setShapeMeasureFn(null);

    const w = measureProportional("test", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 1), TestShapeContext.call_count);
    // NaN fallback → 走 platform measure，结果 > 0 (回退估算 4 * 14 * 0.6 = 33.6)
    try std.testing.expect(w > 0);
    try std.testing.expect(!std.math.isNan(w));
}

test "monospace measure also routes through shape callback" {
    invalidateMeasureCache();
    TestShapeContext.call_count = 0;
    TestShapeContext.return_value = 99.0;
    setShapeMeasureFn(&testShapeMeasureMock);
    defer setShapeMeasureFn(null);

    const w = measureMonospaceTextWidth("x", 14.0, 400, false);
    try std.testing.expectApproxEqAbs(@as(f32, 99), w, 0.001);
    try std.testing.expectEqual(@as(u32, 1), TestShapeContext.call_count);
}

// ── 折行结果必须与视图缩放无关 ──────────────────────────────────────────
//
// 缩放是纯几何变换：整体等比缩小时，"第几个字断行"不该改变。宿主（下游应用白板）
// 的回归点是：字号有 6px 下限，若换行宽度仍按 scale 继续缩小，两者不再成比例，
// 文字就会在缩小时被重新换行、甚至溢出框外。
//
// 这里锁住的是**公式的不变量**：只要 `可用宽度 / 字号` 恒定，断行点就恒定。
// 宿主 syncObjectLabel 用同一个 eff 换算宽度与字号，故满足该前提。

/// 复刻宿主的"有效几何缩放"：字号触到下限后，布局几何一起停在同一档。
fn hostEffectiveScale(world_font: f32, scale: f32, min_font_px: f32) f32 {
    if (!(world_font > 0)) return scale;
    return @max(scale, min_font_px / world_font);
}

test "text wrap is invariant under view scale (downstream zoom regression)" {
    const min_font_px: f32 = 6.0;
    const world_font: f32 = 16.0;
    const line_height: f32 = 1.25;

    const Case = struct {
        name: []const u8,
        content: []const u8,
        world_w: f32,
        inset_world: f32,
    };
    // 用户报告的两个真实对象
    const cases = [_]Case{
        .{ .name = "textbox", .content = "asdfsdfasdfasdf asdfsdf", .world_w = 240, .inset_world = 4 },
        .{ .name = "sticky", .content = "杠杆顶起 asdfsd塔顶", .world_w = 180, .inset_world = 10 },
    };
    const scales = [_]f32{ 1.0, 0.75, 0.5, 0.375, 0.25, 0.12, 0.10, 0.05, 0.02 };

    for (cases) |c| {
        // 基准：scale = 1（世界坐标下的真实断行）
        const base = computeTextLayout(
            c.content,
            (c.world_w - c.inset_world * 2),
            .word,
            0,
            world_font,
            line_height,
            400,
            false,
            false,
            &.{},
        );
        try std.testing.expect(base.line_count >= 1);

        for (scales) |s| {
            const eff = hostEffectiveScale(world_font, s, min_font_px);
            const font_px = world_font * eff;
            const avail = (c.world_w - c.inset_world * 2) * eff;

            const got = computeTextLayout(
                c.content,
                avail,
                .word,
                0,
                font_px,
                line_height,
                400,
                false,
                false,
                &.{},
            );

            // 1) 行数与 scale 无关
            if (got.line_count != base.line_count) {
                std.debug.print(
                    "[{s}] scale={d}: line_count {d} != base {d} (font_px={d:.2} avail={d:.2})\n",
                    .{ c.name, s, got.line_count, base.line_count, font_px, avail },
                );
                return error.LineCountChangedWithScale;
            }
            // 2) 断行位置（byte 偏移）与 scale 无关
            var i: u16 = 0;
            while (i < base.line_count) : (i += 1) {
                if (got.lines[i].byte_start != base.lines[i].byte_start or
                    got.lines[i].byte_end != base.lines[i].byte_end)
                {
                    std.debug.print(
                        "[{s}] scale={d} line {d}: [{d}:{d}] != base [{d}:{d}]\n",
                        .{ c.name, s, i, got.lines[i].byte_start, got.lines[i].byte_end, base.lines[i].byte_start, base.lines[i].byte_end },
                    );
                    return error.WrapPositionChangedWithScale;
                }
            }
            // 3) 每一档都必须有"可见的文字表达"：完整文字（字号够大）
            //    或像素块（宿主按 LineInfo.width 画条带）。两者都要求本档
            //    量出了非空的行几何 —— 不允许某一档什么都没有。
            try std.testing.expect(got.line_count > 0);
            try std.testing.expect(got.max_line_width > 0);
        }
    }
}

// 多窗口 measure cache 共存测试用的假测量回调：按 ctx 返回不同宽度，
// 以此验证两个 ctx 的条目既能共存、又不会互相串味。
const TestCtxMeasure = struct {
    var calls: u32 = 0;
    var ctx_a: u8 = 0;
    var ctx_b: u8 = 0;

    fn measure(ctx: *anyopaque, text: [*]const u8, len: usize, size: f32, weight: u16, italic: bool) f32 {
        _ = text;
        _ = size;
        _ = weight;
        _ = italic;
        calls += 1;
        // ctx_a 记 10/字符，ctx_b 记 20/字符
        const is_a = ctx == @as(*anyopaque, @ptrCast(&ctx_a));
        return @as(f32, @floatFromInt(len)) * (if (is_a) @as(f32, 10) else @as(f32, 20));
    }
};

test "切换 measure ctx 不清空缓存，且两个 ctx 的条目互不串味" {
    invalidateMeasureCache();
    TestCtxMeasure.calls = 0;

    const a: *anyopaque = @ptrCast(&TestCtxMeasure.ctx_a);
    const b: *anyopaque = @ptrCast(&TestCtxMeasure.ctx_b);
    defer setMeasureCtxFn(null, null);

    // 窗口 A 测一次 —— miss，真调
    setMeasureCtxFn(&TestCtxMeasure.measure, a);
    const wa1 = measureProportional("abcd", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 1), TestCtxMeasure.calls);
    try std.testing.expectEqual(@as(f32, 40), wa1);

    // 切到窗口 B 测同一串 —— 必须 miss（不能复用 A 的宽度），真调
    setMeasureCtxFn(&TestCtxMeasure.measure, b);
    const wb1 = measureProportional("abcd", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 2), TestCtxMeasure.calls);
    try std.testing.expectEqual(@as(f32, 80), wb1);

    // 切回 A —— A 的条目必须还在（这正是修复点：此前切 ctx 会清全表）
    setMeasureCtxFn(&TestCtxMeasure.measure, a);
    const wa2 = measureProportional("abcd", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 2), TestCtxMeasure.calls); // 没有新增真调 = 命中
    try std.testing.expectEqual(@as(f32, 40), wa2);

    // 再切回 B —— 同样应命中
    setMeasureCtxFn(&TestCtxMeasure.measure, b);
    const wb2 = measureProportional("abcd", 14.0, 400, false);
    try std.testing.expectEqual(@as(u32, 2), TestCtxMeasure.calls);
    try std.testing.expectEqual(@as(f32, 80), wb2);
}
