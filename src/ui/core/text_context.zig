//! 文本上下文，从 `Cx` 析出的字体/塑形/测量子系统。
//!
//! 聚了五个原本平铺在 `Cx` 上的字段：
//!   - `font_system`    宿主注入的字体后端（null 时塑形走 fallback）
//!   - `shaping_cache`  塑形结果与 VisualLine 缓存
//!   - `measure_fn`     legacy 无 context 测量钩子（进程级，多窗口会串台）
//!   - `measure_ctx_fn` / `measure_ctx`  带 context 的测量钩子（多窗口正确的那个）
//!
//! 为什么要搬：这五个字段和它们的方法是一个闭环，但因为挂在 `Cx` 上，
//! 任何要测文本测量的代码都得先造一个完整的 `Cx`。D 号审查指出的
//! 「`layoutChildren` 依赖 `Cx.visualLine` / `Cx.measureTextWidth` 而无法
//! 脱离完整 `Cx` 单测」正是这条耦合的直接后果。
//!
//! 搬出来之后 `TextContext` 可以单独构造（`init(allocator)` 即可，字体后端
//! 与测量钩子都是可选的），测量降级链路因此第一次有了真正的单测。
//!
//! **测量优先级**（`measureTextWidth`）：
//!   1. GlyphRun pipeline（有 `font_system` 时），与渲染、光标/选区同一套
//!      字体与塑形，是唯一不会产生排版漂移的那条
//!   2. `measure_ctx_fn` + `measure_ctx`，多窗口安全的宿主钩子
//!   3. `measure_fn`, legacy 进程级钩子
//!   4. `text_layout.measureTextWidthByFontKind`，最后的估算兜底

const std = @import("std");
const text_module = @import("text");
const text_core_module = @import("text_core");
const i18n = @import("i18n");

const shaping_cache_mod = @import("shaping_cache.zig");
const text_layout = @import("text_layout.zig");
const text_shaper_adapter = @import("text_shaper_adapter.zig");
const text_shaping = @import("text_shaping.zig");
const layout_engine = @import("layout_engine.zig");

const FontSystem = text_module.FontSystem;
const FontDescriptor = text_module.FontDescriptor;
const TextShaper = text_module.TextShaper;
const ShapedGlyph = text_module.ShapedGlyph;
const FontMetrics = @import("glyph_run.zig").FontMetrics;
const GlyphRun = @import("glyph_run.zig").GlyphRun;

pub const ShapeTextOpts = text_shaping.ShapeTextOpts;

/// 释放 shape 产物里 fallback 字体的引用（与 core.zig 同名 helper 一致）。
fn releaseShapedFallbackFontRefs(glyphs: []const ShapedGlyph) void {
    for (glyphs) |glyph| {
        if (glyph.fallback_font_ref) |font_ref| {
            text_module.releaseFallbackFontRef(font_ref);
        }
    }
}

pub const TextContext = struct {
    allocator: std.mem.Allocator,

    /// 外部注入的字体测量函数（统一测量与渲染字体）
    measure_fn: ?text_layout.MeasureFn = null,
    /// 带 context 的测量回调（多窗口所需，无 context 版本只能读进程级全局，
    /// 两个 App 并存时会串台）。设了它就优先于 measure_fn。
    measure_ctx_fn: ?text_layout.MeasureCtxFn = null,
    measure_ctx: ?*anyopaque = null,
    /// CoreText shape 调用缓存。
    shaping_cache: shaping_cache_mod.ShapingCache,
    /// 宿主注入的字体后端；null 时 shapeText 返 error.NoFontProvider。
    font_system: ?*FontSystem = null,

    pub fn init(allocator: std.mem.Allocator, cache_capacity: u32) TextContext {
        return .{
            .allocator = allocator,
            .shaping_cache = shaping_cache_mod.ShapingCache.init(allocator, cache_capacity),
        };
    }

    pub fn deinit(self: *TextContext) void {
        self.shaping_cache.deinit();
    }

    /// 帧开始时推进缓存的代际。
    pub fn beginFrame(self: *TextContext) void {
        self.shaping_cache.beginFrame();
    }

    /// 把当前测量钩子同步进 text_layout 的进程级槽位（legacy 布局路径要用）。
    pub fn syncLegacyMeasureHooks(self: *const TextContext) void {
        text_layout.setMeasureFn(self.measure_fn);
        text_layout.setMeasureCtxFn(self.measure_ctx_fn, self.measure_ctx);
    }

    /// 挂载 FontSystem，让 cx.shapeText 能找 Font + 调 TextShaper。
    /// zenit_app 在 init 后调用（与 setSystemSdk 同时序）。
    pub fn setFontSystem(self: *TextContext, fs: *FontSystem) void {
        self.font_system = fs;
    }

    pub fn clearFontSystem(self: *TextContext) void {
        self.font_system = null;
    }

    /// GlyphRun pipeline 入口，取代 text_layout 旧 measure API。
    ///
    /// 内部：1) build ShapingKey；2) ShapingCache lookup；3) miss 时 TextShaper
    /// .shape() 出 []ShapedGlyph，经 text_shaper_adapter.fromShapedGlyphs 翻成
    /// GlyphRun，存进 ShapingCache 的 arena；4) hit/miss 都返 GlyphRun。
    ///
    /// 当前 ShapingCache.insert 把 GlyphRun.glyphs/clusters 复制到内部 arena，
    /// 所以 caller 无需关心 slice lifetime。返回的 GlyphRun 有效到下次
    /// beginFrame 后阈值帧（默认 2 帧）。
    ///
    /// 错误:
    ///   - error.NoFontProvider: cx.font_system == null
    ///   - error.FontLookupFailed / TextShapingFailed / OutOfMemory: passthrough
    pub fn shapeText(self: *TextContext, opts: ShapeTextOpts) !GlyphRun {
        const fs = self.font_system orelse return error.NoFontProvider;
        if (opts.text.len == 0) {
            return GlyphRun{
                .glyphs = &.{},
                .clusters = &.{},
                .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = opts.font_size },
                .direction = .ltr,
                .total_advance = 0,
            };
        }

        // ShapingKey 当前 schema 不区分 weight/italic（v0.5 设计 limitation）。
        // 用 text_hash 把 weight + italic 信息塞进去，避免 different style 命中
        // 同 entry。font_id 暂全 0（FontSystem 内部 *Font 句柄当前不暴露 id）。
        const key = text_shaping.shapingKey(opts);
        if (self.shaping_cache.lookup(key)) |run| return run;

        // miss: 找 Font -> shape -> adapt -> cache.insert
        const desc = FontDescriptor{
            .family = opts.font_family,
            .size = opts.font_size,
            .weight = text_shaping.mapFontWeight(opts.font_weight),
            .style = if (opts.use_italic) .italic else .normal,
        };
        const borrowed = if (std.mem.eql(u8, opts.font_family, "system"))
            layout_engine.resolveDefaultTextFont(opts.text, opts.font_size, opts.font_weight, opts.use_italic)
        else
            null;
        const font = borrowed orelse try fs.findFont(desc);
        defer if (borrowed == null) font.deinit();

        var shaper = try TextShaper.init(self.allocator);
        defer shaper.deinit();
        const shaped = try shaper.shapeWithOptions(opts.text, font, opts.use_italic);
        defer self.allocator.free(shaped);
        defer releaseShapedFallbackFontRefs(shaped);

        // FontMetrics: 当前 Font 没暴露 ascent/descent；先用 0 占位（caller 主要
        // 关心 total_advance）。Phase B/C 切换后再补 Font.metrics()。
        const metrics = FontMetrics{
            .ascent = 0,
            .descent = 0,
            .line_gap = 0,
            .font_size = opts.font_size,
        };
        var run = try text_shaper_adapter.fromShapedGlyphs(self.allocator, shaped, metrics, .ltr);
        const scale = if (font.pixelSize() > 0) opts.font_size / font.pixelSize() else 1;
        for (@constCast(run.glyphs)) |*glyph| {
            glyph.x_advance *= scale;
            glyph.y_advance *= scale;
            glyph.x_offset *= scale;
            glyph.y_offset *= scale;
        }
        run.total_advance *= scale;
        // adapter alloc 的 glyphs/clusters 在 cache.insert 后由 cache 的 arena
        // 复制管理，原 slice 释放。
        defer self.allocator.free(run.glyphs);
        defer self.allocator.free(run.clusters);

        try self.shaping_cache.insert(key, run.glyphs, run.clusters, run.metrics, run.direction, run.total_advance);
        // cache.insert 把 slice 复制到 arena 后，再 lookup 一次拿 cache 内副本。
        // (避免返回 caller-allocator slice 已 free。)
        return self.shaping_cache.lookup(key) orelse unreachable;
    }

    /// Build a CoreText-authoritative single visual line. Grapheme boundaries
    /// come from text_core; glyph/bidi caret x positions come from the same
    /// platform line object used for shaping and measurement.
    pub fn shapeVisualLine(self: *TextContext, opts: ShapeTextOpts) !text_core_module.OwnedVisualLine {
        const fs = self.font_system orelse return error.NoFontProvider;
        const desc = FontDescriptor{
            .family = opts.font_family,
            .size = opts.font_size,
            .weight = text_shaping.mapFontWeight(opts.font_weight),
            .style = if (opts.use_italic) .italic else .normal,
        };
        const borrowed = if (std.mem.eql(u8, opts.font_family, "system"))
            layout_engine.resolveDefaultTextFont(opts.text, opts.font_size, opts.font_weight, opts.use_italic)
        else
            null;
        const font = borrowed orelse try fs.findFont(desc);
        defer if (borrowed == null) font.deinit();
        const scale = if (font.pixelSize() > 0) opts.font_size / font.pixelSize() else 1;

        var boundary_count: usize = 1;
        var byte: usize = 0;
        var count_cursor = text_core_module.grapheme.BoundaryCursor.init(opts.text);
        while (byte < opts.text.len) : (boundary_count += 1) {
            byte = count_cursor.next(byte);
        }
        const boundaries = try self.allocator.alloc(u32, boundary_count);
        defer self.allocator.free(boundaries);
        boundaries[0] = 0;
        byte = 0;
        var boundary_index: usize = 1;
        var fill_cursor = text_core_module.grapheme.BoundaryCursor.init(opts.text);
        while (byte < opts.text.len) : (boundary_index += 1) {
            byte = fill_cursor.next(byte);
            boundaries[boundary_index] = @intCast(byte);
        }

        const native_stops = try self.allocator.alloc(text_module.LineCaretStop, boundary_count);
        defer self.allocator.free(native_stops);
        const metrics = try font.lineCaretStops(opts.text, boundaries, native_stops);
        var stop_count: usize = boundary_count;
        for (native_stops) |stop| if (stop.has_secondary) {
            stop_count += 1;
        };
        const stops = try self.allocator.alloc(text_core_module.text_coordinates.CaretStop, stop_count);
        errdefer self.allocator.free(stops);
        var write: usize = 0;
        // CoreText owns glyph and caret geometry, while paragraph direction is
        // a Unicode text property.  The first CTRun is not authoritative here:
        // leading isolates/controls can make its run direction differ from P2/P3.
        const base_direction: text_core_module.text_coordinates.Direction = switch (i18n.detectParagraphDirection(opts.text)) {
            .ltr => .ltr,
            .rtl => .rtl,
        };
        for (native_stops) |stop| {
            stops[write] = .{
                .position = .{ .byte = .{ .value = stop.byte_offset }, .affinity = .downstream },
                .x = .{ .value = stop.primary_x * scale },
                .strong_direction = base_direction,
            };
            write += 1;
            if (stop.has_secondary) {
                stops[write] = .{
                    .position = .{ .byte = .{ .value = stop.byte_offset }, .affinity = .upstream },
                    .x = .{ .value = stop.secondary_x * scale },
                    .strong_direction = base_direction,
                };
                write += 1;
            }
        }
        std.mem.sort(text_core_module.text_coordinates.CaretStop, stops, {}, struct {
            fn lessThan(_: void, a: text_core_module.text_coordinates.CaretStop, b: text_core_module.text_coordinates.CaretStop) bool {
                if (a.x.value != b.x.value) return a.x.value < b.x.value;
                if (a.position.byte.value != b.position.byte.value) return a.position.byte.value < b.position.byte.value;
                return a.position.affinity == .upstream and b.position.affinity == .downstream;
            }
        }.lessThan);

        // Derive the strong direction from visual-neighbour logical order. At a
        // duplicate bidi caret, fall back to the paragraph base direction.
        for (stops, 0..) |*stop, i| {
            var direction = base_direction;
            var next = i + 1;
            while (next < stops.len and stops[next].position.byte.value == stop.position.byte.value) : (next += 1) {}
            if (next < stops.len) {
                direction = if (stops[next].position.byte.value < stop.position.byte.value) .rtl else .ltr;
            } else if (i > 0) {
                var previous = i;
                while (previous > 0) {
                    previous -= 1;
                    if (stops[previous].position.byte.value != stop.position.byte.value) {
                        direction = if (stop.position.byte.value < stops[previous].position.byte.value) .rtl else .ltr;
                        break;
                    }
                }
            }
            stop.strong_direction = direction;
        }

        const line = text_core_module.VisualLine{
            .source_start = .{ .value = 0 },
            .source_end = .{ .value = opts.text.len },
            .caret_stops = stops,
            .width = metrics.width * scale,
            .ascent = metrics.ascent * scale,
            .descent = metrics.descent * scale,
            .leading = metrics.leading * scale,
            .base_direction = base_direction,
        };
        try line.validate(opts.text);
        return .{ .allocator = self.allocator, .value = line };
    }

    /// Cached production entry point for consumers that only need a borrowed
    /// immutable line during the current context lifetime.
    pub fn visualLine(self: *TextContext, opts: ShapeTextOpts) !text_core_module.VisualLine {
        const key = text_shaping.shapingKey(opts);
        if (self.shaping_cache.lookupVisual(key)) |line| return line;
        var owned = try self.shapeVisualLine(opts);
        defer owned.deinit();
        try self.shaping_cache.insertVisual(key, owned.value);
        return self.shaping_cache.lookupVisual(key) orelse unreachable;
    }

    /// Measure text through this context's font selector. Unlike the legacy
    /// `measure_fn` field, this preserves the owning window's font context when
    /// several Cx instances coexist in one process.
    pub fn measureTextWidth(self: *TextContext, content: []const u8, font_size: f32, font_weight: u16, italic: bool) f32 {
        if (content.len == 0) return 0;
        // 调用方按字节切前缀时可能落在多字节序列中间（半个 CJK/emoji）。非法
        // UTF-8 让 CoreText NSString 构造失败：shape 层报 TextShapingFailed、
        // FontSelector 桥（coretext_measure_text_width_with_font）静默返 0.0f，
        // 最终宽度 0.00 直接塌掉 bbox（下游应用实测：emoji 后切在 CJK 首字节
        // 的"前缀"全部量出 0.00）。先裁到最长合法前缀，与渲染端实际能显示
        // 的内容一致；合法输入零开销原样通过。
        const safe = text_shaping.validUtf8Prefix(content);
        if (safe.len == 0) return 0;
        // GlyphRun pipeline 优先：与渲染（text_item_render 的 visualLine）和输入
        // 光标/选区（input/text_utils 的 shapeText）同一字体与塑形。旧 FontSelector
        // 桥用的是 fallback_families 首选字体（Helvetica Neue），拉丁字宽比 "system"
        // 宽 ~1.5%, WrapMap 换行点与显示排版漂移、编辑提交 bbox 偏宽皆源于此。
        // pipeline 不可用（无 font_system / shape 失败）时保留旧路径兜底。
        if (self.font_system != null) {
            if (self.shapeText(.{
                .text = safe,
                .font_family = "system",
                .font_size = font_size,
                .font_weight = font_weight,
                .use_italic = italic,
            })) |run| {
                return run.total_advance;
            } else |_| {}
        }
        if (self.measure_ctx_fn) |measure| {
            if (self.measure_ctx) |ctx| {
                return measure(ctx, safe.ptr, safe.len, font_size, font_weight, italic);
            }
        }
        if (self.measure_fn) |measure| {
            return measure(safe.ptr, safe.len, font_size, font_weight, italic);
        }
        return text_layout.measureTextWidthByFontKind(safe, font_size, font_weight, italic, false);
    }

    // 这里**刻意不提供** measureTextWidthCallback（擦除指针的回调适配器）。
    //
    // 它只能存在一个版本：WrapMap 那类 API 收的是 `*anyopaque` + 一个函数
    // 指针，两者必须配对。既有调用点传的 ctx 全是 `cx`（见 input/textarea.zig
    // 与 input/editable_text.zig），所以适配器留在 `Cx` 上、强转 `*Cx`。
    //
    // 若这里再放一个强转 `*TextContext` 的同名函数，它和 `Cx` 版签名完全
    // 相同、编译期无从区分，配错不会报错，`text` 字段在 Cx 里不在偏移 0，
    // 拿 `*Cx` 当 `*TextContext` 解引用读到的是别的字段，静默算出垃圾宽度。
    // 与其留个陷阱，不如不提供。
    /// 外部（非 layout pass 内）做塑形测量时的守卫，保证用的是本上下文的
    /// 缓存与字体后端。
    pub fn beginExternalTextMeasure(self: *TextContext) layout_engine.ExternalShapeMeasureGuard {
        return layout_engine.beginExternalShapeMeasure(&self.shaping_cache, self.font_system);
    }
};

// ── 测试 ───────────────────────────────────────────────────────────────
//
// 这些测试此前一条都写不了：measureTextWidth 的降级链路挂在 Cx 上，要测它
// 得先造一个完整的 Cx（含节点树、focus、dispatcher…）。现在 TextContext
// 可以独立构造，降级链路终于可以被钉住。

const TestHooks = struct {
    var ctx_calls: u32 = 0;
    var plain_calls: u32 = 0;
    var marker: u8 = 0;

    fn reset() void {
        ctx_calls = 0;
        plain_calls = 0;
    }

    fn withCtx(_: *anyopaque, _: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
        ctx_calls += 1;
        return @as(f32, @floatFromInt(len)) * 7;
    }

    fn plain(_: [*]const u8, len: usize, _: f32, _: u16, _: bool) f32 {
        plain_calls += 1;
        return @as(f32, @floatFromInt(len)) * 3;
    }
};

test "TextContext: 空文本宽度为 0，不碰任何钩子" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;

    try std.testing.expectEqual(@as(f32, 0), tc.measureTextWidth("", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 0), TestHooks.plain_calls);
}

test "TextContext: 无字体后端时落到 measure_fn" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;

    try std.testing.expectEqual(@as(f32, 12), tc.measureTextWidth("abcd", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 1), TestHooks.plain_calls);
}

test "TextContext: 带 context 的钩子优先于 legacy 钩子（多窗口正确性）" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;
    tc.measure_ctx_fn = TestHooks.withCtx;
    tc.measure_ctx = @ptrCast(&TestHooks.marker);

    // 7/字符 = ctx 版；3/字符 = legacy 版
    try std.testing.expectEqual(@as(f32, 28), tc.measureTextWidth("abcd", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 1), TestHooks.ctx_calls);
    try std.testing.expectEqual(@as(u32, 0), TestHooks.plain_calls);
}

test "TextContext: 设了 measure_ctx_fn 但没给 ctx 时不当作可用" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;
    tc.measure_ctx_fn = TestHooks.withCtx;
    tc.measure_ctx = null; // 半配置状态

    try std.testing.expectEqual(@as(f32, 12), tc.measureTextWidth("abcd", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 0), TestHooks.ctx_calls);
    try std.testing.expectEqual(@as(u32, 1), TestHooks.plain_calls);
}

test "TextContext: 非法 UTF-8 前缀先裁再测（不把半个字符喂给钩子）" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;

    // "a" + 半个 "中" -> 只应量 "a" 这 1 字节
    try std.testing.expectEqual(@as(f32, 3), tc.measureTextWidth("a\xE4\xB8", 14, 400, false));
}

test "TextContext: 完全非法的输入量出 0 而不是喂给钩子" {
    TestHooks.reset();
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.measure_fn = TestHooks.plain;

    try std.testing.expectEqual(@as(f32, 0), tc.measureTextWidth("\xFF\xFE", 14, 400, false));
    try std.testing.expectEqual(@as(u32, 0), TestHooks.plain_calls);
}

test "TextContext: 没有字体后端时 shapeText 明确报错" {
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    try std.testing.expectError(
        error.NoFontProvider,
        tc.shapeText(.{ .text = "hi", .font_family = "system", .font_size = 14 }),
    );
}

test "TextContext: host face and logical size govern mixed input caret and glyph widths" {
    var fs = try FontSystem.init(std.testing.allocator);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica Neue", .size = 26 });
    defer font.deinit();
    const Bridge = struct {
        fn resolve(raw: *anyopaque, _: []const u8, _: f32, _: u16, _: bool, _: bool, _: u16) ?*text_module.Font {
            return @ptrCast(@alignCast(raw));
        }
    };
    layout_engine.setShapeFontResolver(&Bridge.resolve, @ptrCast(font));
    defer layout_engine.setShapeFontResolver(null, null);
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    tc.setFontSystem(&fs);
    const content = "asfdsfsdadfa工asdf工 中文 English";
    const opts = ShapeTextOpts{ .text = content, .font_family = "system", .font_size = 13 };
    const line = try tc.visualLine(opts);
    const run = try tc.shapeText(opts);
    const expected = font.measureWidth(content) * 13 / font.pixelSize();
    try std.testing.expectApproxEqAbs(expected, line.width, 0.01);
    try std.testing.expectApproxEqAbs(expected, run.total_advance, 0.01);
    const caret = try line.positionToCaret(.{ .byte = .{ .value = content.len }, .affinity = .downstream });
    try std.testing.expectApproxEqAbs(expected, caret.x.value, 0.01);
}

test "TextContext: 无字体后端时连空文本也报错（取后端在长度短路之前）" {
    var tc = TextContext.init(std.testing.allocator, 64);
    defer tc.deinit();
    // 钉住现有求值顺序：font_system 检查在 text.len == 0 短路之前。
    // 调换两者会改变无后端宿主看到的行为，这里当作合同锁住。
    try std.testing.expectError(
        error.NoFontProvider,
        tc.shapeText(.{ .text = "", .font_family = "system", .font_size = 14 }),
    );
}
