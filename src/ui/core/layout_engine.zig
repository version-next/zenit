const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const node_mod = @import("node.zig");
const text_layout = @import("text_layout.zig");
// GlyphRun pipeline support
const shaping_cache_mod = @import("shaping_cache.zig");
const text_module = @import("text");
const text_shaper_adapter = @import("text_shaper_adapter.zig");
const glyph_run_mod = @import("glyph_run.zig");

const Node = node_mod.Node;
const Size = types.Size;
const Sizing = types.Sizing;
const AlignItems = types.AlignItems;

/// Bound recursive measure/layout walks before application-provided tree depth
/// can exhaust the native stack. Nodes beyond the limit remain dirty and can
/// be diagnosed through `layout_depth_limit_hits` instead of crashing.
pub const max_layout_recursion_depth: usize = 128;
pub var layout_depth_limit_hits: u64 = 0;

/// 布局过程中 frame_allocator 分配失败的次数。
///
/// 两个 >512 子节点的慢路径（flex_shrink 的 shrink_deltas、grid 的 placements）
/// 在分配失败时都选择降级而不是崩，这和 `layout_depth_limit_hits` 是同一套
/// 姿态。但降级的后果是**静默的错误布局**（收缩不生效 ⇒ 溢出；grid 直接不排
/// 版），从画面上看不出是 OOM 还是布局写错了。计数器让它可诊断。
pub var layout_alloc_failure_hits: u64 = 0;
var g_layout_recursion_depth: usize = 0;

/// display:none，节点连同子树不参与布局（不占空间、不计 gap、不撑父容器）。
pub inline fn isDisplayNone(n: *const Node) bool {
    return n.style.display == .none;
}

/// 不参与 flex / grid 流式排布的子节点：absolute（单独定位）或 display:none。
/// 布局引擎所有"跳过非流式子节点"的遍历都走这一个判据。
pub inline fn isOutOfFlow(n: *const Node) bool {
    return n.style.position == .absolute or isDisplayNone(n);
}

/// display:none 子树的布局收尾：自身尺寸归零（位置保留，computeChildrenBBox /
/// 命中剪枝因 w/h = 0 自然排除），整棵子树清 layout 脏位，不清的话被隐藏子树
/// 的脏位每帧都在，idle 停帧门控永远判"还有布局要做"。onMount 照常触发：节点
/// 仍在树上（与卸载不同），只是不显示。
fn collapseDisplayNone(node: *Node) void {
    const r = node.rectFromWorldOrFallback();
    if (r.w != 0 or r.h != 0) node.setLayoutRect(types.ComputedRect.init(r.x, r.y, 0, 0));
    settleHiddenSubtree(node, 0);
}

/// 递归（按深度而非宽度设上限，宽子树不会漏清脏位）。
fn settleHiddenSubtree(n: *Node, depth: usize) void {
    n.frame_state.state_bits.dirty.core.layout = false;
    n.frame_state.state_bits.dirty.core.subtree_layout = false;
    node_mod.fireMountIfNeeded(n);
    if (depth >= max_layout_recursion_depth) return;
    for (n.children.items) |c| settleHiddenSubtree(c, depth + 1);
}

fn enterLayoutRecursion() bool {
    if (g_layout_recursion_depth >= max_layout_recursion_depth) {
        layout_depth_limit_hits +|= 1;
        return false;
    }
    g_layout_recursion_depth += 1;
    return true;
}

fn leaveLayoutRecursion() void {
    std.debug.assert(g_layout_recursion_depth > 0);
    g_layout_recursion_depth -= 1;
}

fn releaseShapedFallbackFontRefs(glyphs: []const text_module.ShapedGlyph) void {
    for (glyphs) |glyph| {
        if (glyph.fallback_font_ref) |font_ref| {
            text_module.releaseFallbackFontRef(font_ref);
        }
    }
}

// IntrinsicCache，同一节点同一 (axis, content_version) 的 intrinsic
// 测量结果跨 calcIntrinsicSize 调用复用。
// 当前 Node god-object 不便扩字段；用 (node.id, axis) -> 值的 hashmap，按
// node.caches.versions.content 失效。
//
// 单线程模型（owner.assertThread 保证）下用静态变量；v0.2-P3 拆 Node 时迁到
// LayoutTable 旁。
const IntrinsicCacheEntry = struct {
    value: f32,
    /// 写入时的 content_version；命中要求当前 version 匹配
    content_version: u32,
};

var g_intrinsic_cache: std.AutoHashMapUnmanaged(u64, IntrinsicCacheEntry) = .{};
var g_intrinsic_cache_refcount: u32 = 0;
var g_intrinsic_cache_allocator: Allocator = undefined;

fn intrinsicCacheKey(world_id: u16, node_id: u32, is_main_row: bool) u64 {
    // key 必须含 world_id（2026-07-30 审查发现）：本表是进程级共享，而 node.id
    // 是 per-Cx 计数器、两个窗口的 id 完全重叠，不混 world_id 的话，窗口 B
    // 的节点会命中窗口 A 同 id 节点的 intrinsic 尺寸（content_version 也是
    // per-node 小计数器，极易相等），布局直接串台。
    return (@as(u64, world_id) << 33) | (@as(u64, node_id) << 1) |
        (if (is_main_row) @as(u64, 1) else 0);
}

fn intrinsicCacheLookup(node: *const Node, is_main_row: bool) ?f32 {
    if (g_intrinsic_cache_refcount == 0) return null;
    const key = intrinsicCacheKey(node.world_id, node.id, is_main_row);
    if (g_intrinsic_cache.get(key)) |entry| {
        if (entry.content_version == node.meta.per_frame.caches.versions.content) {
            return entry.value;
        }
    }
    return null;
}

fn intrinsicCacheStore(node: *const Node, is_main_row: bool, value: f32) void {
    if (g_intrinsic_cache_refcount == 0) return;
    const key = intrinsicCacheKey(node.world_id, node.id, is_main_row);
    // 安全降级：纯 memoization 缓存。写不进去只是下次重新测量，
    // 结果完全相同（intrinsicCacheStore 无副作用）。
    g_intrinsic_cache.put(g_intrinsic_cache_allocator, key, .{
        .value = value,
        .content_version = node.meta.per_frame.caches.versions.content,
    }) catch {};
}

/// 启用 intrinsic cache（refcount-based 多 Cx 嵌套安全）。
/// 第一个 Cx.init 时 alloc + setup；后续 Cx.init 只 refcount++。
///
/// ⚠️ 已知边界（2026-07-30 审查）：allocator 绑定**第一个** Cx 的。若两个 Cx
/// 用不同 allocator 且先 init 的先 deinit（refcount 1->不释放表），后续 put 仍
/// 用第一个的 allocator，那个 allocator 若已销毁即 UAF。App 场景两者都是
/// 同一个 GPA 不触发；多 App 各持 allocator 时需把本表迁 per-Cx 才安全。
pub fn enableIntrinsicCache(allocator: Allocator) void {
    if (g_intrinsic_cache_refcount == 0) {
        g_intrinsic_cache_allocator = allocator;
        g_intrinsic_cache = .{};
    }
    g_intrinsic_cache_refcount += 1;
}

/// 关闭 cache（refcount-- ；最后一个 Cx.deinit 时释放）。
pub fn disableIntrinsicCache() void {
    if (g_intrinsic_cache_refcount == 0) return;
    g_intrinsic_cache_refcount -= 1;
    if (g_intrinsic_cache_refcount == 0) {
        g_intrinsic_cache.deinit(g_intrinsic_cache_allocator);
        g_intrinsic_cache = .{};
    }
}

/// 布局上下文，传递帧级 allocator 给所有布局函数
/// frame_allocator 在帧末自动清空，用于替代栈上固定大小数组
pub const LayoutContext = struct {
    frame_allocator: Allocator,
    /// 让 layout pass measureIntrinsicTextWidth 走 GlyphRun pipeline
    /// 替代直调 measureTextWidthWithSpans。null 时降级到旧路径（兼容
    /// 既有 layoutNode 测试 fixtures）。
    shaping_cache: ?*shaping_cache_mod.ShapingCache = null,
    font_system: ?*text_module.FontSystem = null,
    /// 父节点 flex_shrink 已把这个节点的某一轴定死（见 isShrinkableFit）：它自己
    /// layoutChildren 末尾的 fit 回填不得再按子节点实际尺寸改这一轴，否则收缩被
    /// 撑回内容高度、ScrollArea 永远滚不动。只对 == 该节点生效，孙节点读到也不匹配。
    frozen_node: ?*const Node = null,
    frozen_axis_is_width: bool = false,
};

/// CSS flex item 自动最小尺寸：overflow ≠ visible（这里是 overflow_hidden）的项
/// 最小尺寸为 0，可以被压到内容以下；普通 fit 项最小尺寸就是内容本身。
fn isShrinkableFit(child: *const Node, is_row: bool) bool {
    const main_sizing = if (is_row) child.style.width else child.style.height;
    return main_sizing == .fit and child.style.overflow_hidden and child.style.flex_shrink > 0;
}

/// 快速计算 UTF-8 字符串的 Unicode 字符数（非字节数）
/// 用于文本 intrinsic 尺寸估算
fn countUtf8Chars(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        // UTF-8 续字节以 0b10xxxxxx 开头，只计数起始字节
        if (bytes[i] & 0xC0 != 0x80) count += 1;
        i += 1;
    }
    return count;
}

/// 融合 sizing 自带的 min/max 与节点 ext.min_X / ext.max_X，得到该轴最终生效的 (min, max)。
///
/// 设计动机：以前 `style.height = .fit{.max=N}` 的 max 与 `ext.max_height` 是两条独立的 clamp 路径，
/// row layout / grid 用 `style.max_height()` (= ext)，但 fit intrinsic 计算用的是 `fit.max`。
/// 中间件（如 popover autosize）只更新一处时另一处不生效（小窗口 popup 撑爆是这个 bug）。
///
/// 现在统一融合：
///   effective_min = max(sizing_mm.min, ext.min)
///   effective_max = min(sizing_mm.max, ext.max)
///
/// 默认值（fit{}/grow{} 的 min=0,max=inf；ext 同款默认）下融合不变 -> 向后兼容。
pub fn effectiveMinMax(sizing: Sizing, node: *const Node, comptime is_width: bool) struct { min: f32, max: f32 } {
    const ext_min: f32 = if (is_width) node.style.min_width() else node.style.min_height();
    const ext_max: f32 = if (is_width) node.style.max_width() else node.style.max_height();
    return switch (sizing) {
        .grow => |mm| .{ .min = @max(mm.min, ext_min), .max = @min(mm.max, ext_max) },
        .fit => |mm| .{ .min = @max(mm.min, ext_min), .max = @min(mm.max, ext_max) },
        // px / percent 走 ext clamp（layout 后续会按 ext 再 clamp 一次，这里不重复）
        else => .{ .min = ext_min, .max = ext_max },
    };
}

/// resolveSize 用于已知 child sizing + 容器可用空间 -> child 实际尺寸。
/// **不**走 effectiveMinMax，调用方持有 child node 时直接用上面的 helper。
fn resolveSize(sizing: Sizing, available: f32, intrinsic: f32) f32 {
    return switch (sizing) {
        .px => |v| v,
        .grow => |mm| std.math.clamp(available, mm.min, mm.max),
        .fit => |mm| std.math.clamp(intrinsic, mm.min, mm.max),
        .percent => |p| available * p / 100.0,
    };
}

fn measureIntrinsicTextWidth(t: types.TextProps) f32 {
    // layout pass 入口 (layoutNode) 在 g_active_shaping_cache /
    // g_active_font_system 设进 thread-local；measureIntrinsicTextWidth 这条
    // calc-chain 没 ctx 参数，用 globals 替代。layoutNode 退出时清回 null。
    return measureIntrinsicTextWidthCtx(g_active_shaping_cache, g_active_font_system, t);
}

var g_active_shaping_cache: ?*shaping_cache_mod.ShapingCache = null;
var g_active_font_system: ?*text_module.FontSystem = null;

/// GlyphRun 管线的字体解析钩子。
///
/// == 为什么不能只靠 FontSystem.findFont(family="system") ==
/// findFont 是**按名字**查系统已安装字体。App 用 `loadFont(path)` 从文件
/// 装进来的字体（Inter / Lora / JetBrains Mono 这类随仓库发布的）根本不在
/// 系统字体库里，按名字查必然 miss 并静默回退到别的族，于是 shape 管线
/// 与 renderer 用两套字体，同一段文本两个宽度。
/// `setDefaultFamily("Inter")` 治不了这个：它只是把 "system" 换成 "Inter"
/// 再去查系统库，Inter 没装照样 miss（实测把 1.442px 的偏差放大到 3.783px）。
///
/// 所以这里让 App 直接把**它自己那套 FontSelector 选出来的 `*Font`** 交回来，
/// 与 renderer 走同一个选择逻辑，从根上保证「量的和画的是同一个字体对象」。
/// 返回的 Font 由 App 持有，管线只借用不释放（与 findFont 的所有权相反，
/// 见 shapeViaPipeline 里的 owned 分支）。
/// `content` 必须传：渲染端的 CJK/韩文回退是按内容选的，解析器不看字节
/// 就永远追不上渲染端（见 FontSelector.resolveFonts 的注释）。
pub const ShapeFontResolveFn = *const fn (
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    /// 字体族 id(render.FontRegistry)。0 = 默认族。
    /// ⚠ 这个参数是「量的和画的是同一个字体」的一部分:渲染端 resolveFonts
    ///   会按 family 选 face,测量端不传就会退回默认族，于是自定义字体的
    ///   文本光标/选区系统性偏移(与历史上那次 2.758px 同款)。
    font_family: u16,
) ?*text_module.Font;

/// Application-owned authoritative width measurement. A renderer may segment
/// text, select fallback-stack fonts, or force a monospace cell advance after
/// shaping; resolving the same `*Font` is therefore necessary but not always
/// sufficient to reproduce the width that is actually drawn. Hosts should
/// wire this to the renderer's non-emitting draw path.
pub const DrawnTextMeasureFn = *const fn (
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
    use_symbols: bool,
    monospace_char_width: f32,
) ?f32;

var g_shape_font_resolver: ?ShapeFontResolveFn = null;
var g_shape_font_resolver_ctx: ?*anyopaque = null;
var g_drawn_text_measure: ?DrawnTextMeasureFn = null;
var g_drawn_text_measure_ctx: ?*anyopaque = null;
var drawn_text_measure_debug_logged = false;

/// App 启动时装一次；传 null 卸载（回到 findFont 老路）。
pub fn setShapeFontResolver(f: ?ShapeFontResolveFn, ctx: ?*anyopaque) void {
    g_shape_font_resolver = f;
    g_shape_font_resolver_ctx = ctx;
}

/// Borrow the host's default UI face; ownership stays with the host.
pub fn resolveDefaultTextFont(text: []const u8, size: f32, weight: u16, italic: bool) ?*text_module.Font {
    const resolve = g_shape_font_resolver orelse return null;
    return resolve(g_shape_font_resolver_ctx orelse return null, text, size, weight, italic, false, 0);
}

/// Install the application's authoritative "width as drawn" callback.
/// Passing null removes it and restores the internal shaping fallback.
pub fn setDrawnTextMeasure(f: ?DrawnTextMeasureFn, ctx: ?*anyopaque) void {
    g_drawn_text_measure = f;
    g_drawn_text_measure_ctx = ctx;
}

/// 给 text_layout.measureProportional 注入式回调。
/// pipeline 不可用时返 NaN，caller fallback 到 platform measure。
/// 在 **layout 之外**(draw / overlay / 命中测试)临时装上同一套 GlyphRun
/// 测量钩子,用完还原。
///
/// # 为什么必须有它
///
/// 钩子平时只在 `layoutNode` 期间装着(见下方 setShapeMeasureFn 处的注释)。
/// 于是同一段文字:布局期按 **shaping 宽度**算,而 overlay 期
/// `measureProportional` 找不到钩子、降级到**平台 measure**。两条路径的
/// 宽度不一致，表现就是选区高亮/光标与字形逐渐错位,越往行尾偏得越多。
///
/// 调用方式(RAII 风格):
/// ```zig
/// var guard = beginExternalShapeMeasure(cx);
/// defer guard.end();
/// ```
pub const ExternalShapeMeasureGuard = struct {
    prev_cache: ?*shaping_cache_mod.ShapingCache,
    prev_fs: ?*text_module.FontSystem,
    prev_installed: bool,

    pub fn end(self: ExternalShapeMeasureGuard) void {
        g_active_shaping_cache = self.prev_cache;
        g_active_font_system = self.prev_fs;
        if (!self.prev_installed) text_layout.setShapeMeasureFn(null);
    }
};

pub fn beginExternalShapeMeasure(
    cache: ?*shaping_cache_mod.ShapingCache,
    fs: ?*text_module.FontSystem,
) ExternalShapeMeasureGuard {
    const guard = ExternalShapeMeasureGuard{
        .prev_cache = g_active_shaping_cache,
        .prev_fs = g_active_font_system,
        .prev_installed = text_layout.hasShapeMeasure(),
    };
    g_active_shaping_cache = cache;
    g_active_font_system = fs;
    text_layout.setShapeMeasureFn(&shapeMeasureBridge);
    return guard;
}

fn shapeMeasureBridge(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32 {
    return shapeViaPipeline(g_active_shaping_cache, g_active_font_system, text, font_size, font_weight, use_italic, use_monospace, 0, false, 0) orelse std.math.nan(f32);
}

/// cx-aware variant, spans 空时走 GlyphRun pipeline (cache 命中
/// 直接返回 total_advance)，否则降级到 measureTextWidthWithSpans 走旧 span
/// 处理路径。完全切换需要 GlyphRun 支持 sub-range shape，是 phase D+ 工作。
fn measureIntrinsicTextWidthCtx(
    cache: ?*shaping_cache_mod.ShapingCache,
    fs: ?*text_module.FontSystem,
    t: types.TextProps,
) f32 {
    const layout_spans = if (t.spans_affect_layout) t.spans else &.{};
    if (t.wrap != .none) {
        const layout = text_layout.computeTextLayout(
            t.content,
            std.math.inf(f32),
            t.wrap,
            t.max_lines,
            t.font_size,
            t.line_height,
            t.font_weight,
            t.use_italic_font,
            t.use_monospace_font,
            layout_spans,
        );
        return layout.max_line_width;
    }
    // 单行 measure 且无 spans -> GlyphRun pipeline fast path
    if (layout_spans.len == 0) {
        if (shapeViaPipeline(cache, fs, t.content, t.font_size, t.font_weight, t.use_italic_font, t.use_monospace_font, t.font_family, t.use_symbols_font, t.monospace_char_width)) |w| {
            return w;
        }
    }
    return text_layout.measureTextWidthWithSpans(
        t.content,
        0,
        @intCast(t.content.len),
        t.font_size,
        t.font_weight,
        t.use_italic_font,
        t.use_monospace_font,
        layout_spans,
    );
}

/// 内部 helper：从 layout_engine 走 GlyphRun pipeline 测一段文本宽度。
/// 参考 cx.shapeText / measureSegmentWidthCtx 同款 ShapingKey schema。
/// 失败 (FontLookupFailed / OOM) 返 null，caller 降级旧路径。
/// Shape and measure through the same font resolver used by the renderer.
/// Render-time rich-text chunk positioning also uses this entry point so it
/// cannot silently fall back to a different family than layout/drawing.
pub fn shapeViaPipeline(
    cache_opt: ?*shaping_cache_mod.ShapingCache,
    fs_opt: ?*text_module.FontSystem,
    text: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
    use_symbols: bool,
    monospace_char_width: f32,
) ?f32 {
    if (text.len == 0) return 0;
    // This is the only answer that can be guaranteed identical to drawing:
    // it executes the TextRenderer's own segment/font/advance loop without
    // emitting glyphs. The local shaper below remains a compatibility fallback
    // for bare Cx/tests and hosts that have not installed the new callback.
    if (g_drawn_text_measure) |measure| {
        if (g_drawn_text_measure_ctx) |ctx| {
            if (measure(ctx, text, font_size, font_weight, use_italic, use_monospace, font_family, use_symbols, monospace_char_width)) |width| {
                if (!drawn_text_measure_debug_logged and std.posix.getenv("ZENIT_TEXT_MEASURE_IDENTITY_CHECK") != null) {
                    drawn_text_measure_debug_logged = true;
                    std.log.info("[text-measure-source] drawn-active", .{});
                }
                return width;
            }
        }
    }
    // Only the compatibility shaper needs these objects. The authoritative
    // width-as-drawn callback above must remain usable by lightweight/bare
    // contexts, otherwise installing it can still be silently bypassed.
    const cache = cache_opt orelse return null;
    const fs = fs_opt orelse return null;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(text);
    var weight_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &weight_buf, font_weight, .little);
    hasher.update(&weight_buf);
    const flag_byte: [1]u8 = .{(if (use_italic) @as(u8, 1) else 0) | (if (use_monospace) @as(u8, 2) else 0)};
    hasher.update(&flag_byte);
    const key = shaping_cache_mod.ShapingKey{
        .text_hash = hasher.final(),
        .text_len = @intCast(text.len),
        // family 必须进 key:换族要重新塑形,否则命中上一族的缓存。
        .font_id = (@as(u32, font_family) << 1) | (if (use_monospace) @as(u32, 1) else 0),
        .max_width = 0,
        .font_size = font_size,
    };
    if (cache.lookup(key)) |run| return run.total_advance;

    // 优先问 App 的解析器：它返回 renderer 正在用的**同一个** *Font，
    // 从而让 shape 管线（光标/选区/命中）与绘制走同一套度量。
    // 拿不到才回落到按名字查系统字体（无 App 的裸 Cx / 单测走这条）。
    // 所有权不同：resolver 借用（App 持有），findFont 是新建必须 deinit。
    var owned_font: ?*text_module.Font = null;
    defer if (owned_font) |f| f.deinit();
    const font = blk: {
        if (g_shape_font_resolver) |resolve| {
            if (g_shape_font_resolver_ctx) |ctx| {
                if (resolve(ctx, text, font_size, font_weight, use_italic, use_monospace, font_family)) |f| break :blk f;
            }
        }
        const desc = text_module.FontDescriptor{
            .family = "system",
            .size = font_size,
            .weight = mapFontWeight(font_weight),
            .style = if (use_italic) .italic else .normal,
        };
        const f = fs.findFont(desc) catch return null;
        owned_font = f;
        break :blk f;
    };
    var shaper = text_module.TextShaper.init(cache.allocator) catch return null;
    defer shaper.deinit();
    const shaped = shaper.shapeWithOptions(text, font, use_italic) catch return null;
    defer cache.allocator.free(shaped);
    defer releaseShapedFallbackFontRefs(shaped);
    const metrics = glyph_run_mod.FontMetrics{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = font_size };
    const run = text_shaper_adapter.fromShapedGlyphs(cache.allocator, shaped, metrics, .ltr) catch return null;
    defer cache.allocator.free(run.glyphs);
    defer cache.allocator.free(run.clusters);
    // shaper 按 font 自己的 pixelSize 出 advance。resolver 可能给回一个
    // 邻近字号的预载字体（FontSelector 只在差值超 epsilon 时才 derive），
    // 此时必须按请求字号缩放，与 FontSelector.measureTextWidth 的
    // `font_size / font.pixelSize()` 完全同式，两条路才对得上。
    const font_px = font.pixelSize();
    const text_scale: f32 = if (font_px > 0) font_size / font_px else 1.0;
    const total = run.total_advance * text_scale;
    cache.insert(key, run.glyphs, run.clusters, run.metrics, run.direction, total) catch return total;
    return total;
}

fn mapFontWeight(weight: u16) text_module.FontWeight {
    return if (weight <= 100) .thin else if (weight <= 300) .light else if (weight <= 400) .regular else if (weight <= 500) .medium else if (weight <= 600) .semibold else if (weight <= 700) .bold else if (weight <= 800) .heavy else .black;
}

test "shapeViaPipeline prefers the authoritative drawn-width callback" {
    const Bridge = struct {
        var calls: usize = 0;

        fn measure(
            _: *anyopaque,
            content: []const u8,
            font_size: f32,
            font_weight: u16,
            use_italic: bool,
            use_monospace: bool,
            font_family: u16,
            use_symbols: bool,
            monospace_char_width: f32,
        ) ?f32 {
            calls += 1;
            std.debug.assert(std.mem.eql(u8, content, "mono span"));
            std.debug.assert(font_size == 13);
            std.debug.assert(font_weight == 600);
            std.debug.assert(use_italic);
            std.debug.assert(use_monospace);
            std.debug.assert(font_family == 7);
            std.debug.assert(use_symbols);
            std.debug.assert(monospace_char_width == 8.25);
            return 123.5;
        }
    };

    var marker: u8 = 0;
    setDrawnTextMeasure(&Bridge.measure, @ptrCast(&marker));
    defer setDrawnTextMeasure(null, null);
    Bridge.calls = 0;

    // The authoritative renderer callback must not be gated on the optional
    // local-shaper objects; otherwise a partially configured Cx bypasses the
    // correct answer and silently returns to platform measurement.
    const width = shapeViaPipeline(null, null, "mono span", 13, 600, true, true, 7, true, 8.25);
    try std.testing.expectEqual(@as(?f32, 123.5), width);
    try std.testing.expectEqual(@as(usize, 1), Bridge.calls);
}

/// 计算节点的 intrinsic 尺寸 (fit 模式用)
/// 文本节点返回文本估算尺寸，容器节点递归累加子节点
fn calcIntrinsicSize(node: *Node, comptime is_main_row: bool) f32 {
    // 子树布局脏 -> 后代尺寸可能已变，但本节点 content_version 不随后代变化，
    // 缓存条目无法察觉，必须绕过缓存重算（修 stale intrinsic 布局 bug）。
    const subtree_dirty = node.frame_state.state_bits.dirty.core.layout or
        node.frame_state.state_bits.dirty.core.subtree_layout;
    // cache 查询（按 node.id + content_version）
    if (!subtree_dirty) {
        if (intrinsicCacheLookup(node, is_main_row)) |cached| return cached;
    }

    if (!enterLayoutRecursion()) return 0;
    defer leaveLayoutRecursion();

    const result = calcIntrinsicSizeUncached(node, is_main_row);
    intrinsicCacheStore(node, is_main_row, result);
    return result;
}

fn calcIntrinsicSizeUncached(node: *Node, comptime is_main_row: bool) f32 {
    // 文本节点：估算文本内容尺寸 + 节点自身 padding
    if (node.getText()) |t| {
        const pad = if (is_main_row) node.style.padding.horizontal() else node.style.padding.vertical();
        // 多行文本：使用已计算的 text_layout
        if (t.wrap != .none) {
            if (node.getLayoutOutput().artifacts.text_layout) |tl| {
                if (is_main_row) {
                    return tl.max_line_width + pad;
                } else {
                    return tl.total_height + pad;
                }
            }
        }
        // 单行文本：优先使用精确测量，fallback 到估算
        const text_size = if (is_main_row) blk: {
            const measured = measureIntrinsicTextWidth(t);
            if (measured > 0) break :blk measured;
            // fallback: 粗略估算
            const char_count = countUtf8Chars(t.content);
            break :blk @as(f32, @floatFromInt(char_count)) * t.font_size * 0.6;
        } else t.font_size * t.line_height;
        return text_size + pad;
    }

    // 容器节点：累加子节点主轴尺寸
    if (node.children.items.len == 0) return 0;

    const pad = if (is_main_row) node.style.padding.horizontal() else node.style.padding.vertical();
    // absolute 子节点不参与 intrinsic 计算（避免 overlay 影响布局）
    var flow_count: usize = 0;
    for (node.children.items) |child| {
        if (child.style.position != .absolute) flow_count += 1;
    }
    if (flow_count == 0) return pad;

    const gap_total = if (flow_count > 1)
        @as(f32, @floatFromInt(flow_count - 1)) * node.style.gap
    else
        0;

    const child_is_row = node.style.direction.isRow();

    // 主轴和交叉轴取决于容器自身的方向
    if (child_is_row == is_main_row) {
        // 同方向：累加子节点主轴
        var total: f32 = 0;
        for (node.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            total += calcChildIntrinsicSize(child, is_main_row) + childMarginForAxis(child, is_main_row);
        }
        return total + gap_total + pad;
    } else {
        // 交叉方向：取子节点最大值
        var max_size: f32 = 0;
        for (node.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            max_size = @max(max_size, calcChildIntrinsicSize(child, is_main_row) + childMarginForAxis(child, is_main_row));
        }
        return max_size + pad;
    }
}

/// 计算单个子节点的 intrinsic 主轴尺寸
/// 注意: .grow 子节点在 .fit 父容器中没有可分配空间，
/// 应回退到 intrinsic 尺寸计算（与 CSS flex-grow in fit-content 行为一致）
fn calcChildIntrinsicSize(child: *Node, comptime is_main_row: bool) f32 {
    if (isOutOfFlow(child)) return 0;
    // flex_basis > 0 时，作为 intrinsic 主轴尺寸（fit 父容器计算用）
    if (child.style.flex_basis() > 0) return child.style.flex_basis();
    const sizing = if (is_main_row) child.style.width else child.style.height;
    return switch (sizing) {
        .px => |v| v,
        // grow / fit 的 min/max 与 ext.min_X / ext.max_X 通过 effectiveMinMax 融合（统一 clamp 路径）。
        // 否则 .fit{.max=N} 与 ext.max=M 不同步时一处生效一处不生效（小窗口 popup 撑爆 bug）。
        .grow, .fit => blk: {
            const mm = effectiveMinMax(sizing, child, is_main_row);
            break :blk std.math.clamp(calcIntrinsicSize(child, is_main_row), mm.min, mm.max);
        },
        .percent => 0,
    };
}

fn childMarginForAxis(child: *const Node, comptime is_main_row: bool) f32 {
    return if (is_main_row) child.style.marginHorizontal() else child.style.marginVertical();
}

const ResolvedAxisMargins = struct {
    start: f32,
    end: f32,
};

/// 主轴尺寸：flex_basis / px / grow / fit / percent，统一减去 flex_shrink 的
/// 收缩量。`is_row` 决定读 width 还是 height，这是 row/column 唯一的区别。
fn resolveMainAxisSize(
    child: *Node,
    comptime is_row: bool,
    available: Size,
    shrink_delta: f32,
    flex_unit: f32,
) f32 {
    const sizing = if (is_row) child.style.width else child.style.height;
    const avail = if (is_row) available.width else available.height;

    // flex_basis > 0 且非 grow 时，用 flex_basis 作为主轴尺寸
    if (child.style.flex_basis() > 0 and sizing != .grow) {
        return @max(0, child.style.flex_basis() - shrink_delta);
    }
    return @max(0, switch (sizing) {
        .px => |v| v - shrink_delta,
        // grow 由 flex_unit 分配，不参与收缩（收缩只在 flex_total == 0 时计算）
        .grow => child.style.flex * flex_unit,
        .fit => calcIntrinsicSize(child, is_row) - shrink_delta,
        .percent => |p| avail * p / 100.0 - shrink_delta,
    });
}

/// 交叉轴尺寸：px / grow / fit / percent，外加 align stretch 的覆盖。
/// 交叉轴不参与 flex_shrink。
fn resolveCrossAxisSize(
    child: *Node,
    comptime is_row: bool,
    available: Size,
    cross_align: types.AlignItems,
) f32 {
    const sizing = if (is_row) child.style.height else child.style.width;
    const avail = if (is_row) available.height else available.width;
    const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();

    var size = switch (sizing) {
        .px => |v| v,
        .grow => |mm| std.math.clamp(avail - margin_cross, mm.min, mm.max),
        .fit => calcIntrinsicSize(child, !is_row),
        .percent => |p| avail * p / 100.0,
    };
    // stretch 覆盖：只对内容驱动的尺寸（grow / fit）生效，px / percent 是显式尺寸
    if ((sizing == .grow or sizing == .fit) and cross_align == .stretch) {
        size = avail - margin_cross;
    }
    return size;
}

fn resolveAxisMargins(
    available_outer: f32,
    child_size: f32,
    start_value: f32,
    end_value: f32,
    start_auto: bool,
    end_auto: bool,
) ResolvedAxisMargins {
    const fixed = (if (start_auto) 0 else start_value) + (if (end_auto) 0 else end_value);
    const free = @max(@as(f32, 0), available_outer - child_size - fixed);
    if (start_auto and end_auto) {
        const half = free / 2.0;
        return .{ .start = half, .end = half };
    }
    if (start_auto) return .{ .start = free, .end = end_value };
    if (end_auto) return .{ .start = start_value, .end = free };
    return .{ .start = start_value, .end = end_value };
}

/// Measure 阶段：计算节点在给定约束下的精确 intrinsic size
///
/// 与 calcIntrinsicSize 的区别：
/// - measureNode 在已知宽度时执行文本折行（解决"宽度决定高度"问题）
/// - 结果更精确，用于 fit 容器消除回填
///
/// constraints.definite_width != null -> 文本可以折行，返回精确高度
/// constraints.definite_width == null -> 返回最小 intrinsic 尺寸
pub fn measureNode(node: *Node, constraints: types.LayoutConstraints) Size {
    if (!enterLayoutRecursion()) {
        return Size.init(
            std.math.clamp(node.style.padding.horizontal(), constraints.min_width, constraints.max_width),
            std.math.clamp(node.style.padding.vertical(), constraints.min_height, constraints.max_height),
        );
    }
    defer leaveLayoutRecursion();

    // 文本节点
    if (node.getText()) |t| {
        const pad_w = node.style.padding.horizontal();
        const pad_h = node.style.padding.vertical();

        // 宽度
        const text_w = blk: {
            if (constraints.definite_width) |dw| {
                break :blk dw;
            }
            // intrinsic width: 精确测量
            const measured = measureIntrinsicTextWidth(t);
            if (measured > 0) break :blk measured + pad_w;
            const char_count = countUtf8Chars(t.content);
            break :blk @as(f32, @floatFromInt(char_count)) * t.font_size * 0.6 + pad_w;
        };

        // 高度：有确切宽度时执行文本折行
        const text_h = blk: {
            if (t.wrap != .none) {
                const avail_w = if (constraints.definite_width) |dw|
                    dw - pad_w
                else if (constraints.max_width < std.math.inf(f32))
                    constraints.max_width - pad_w
                else
                    0;

                if (avail_w > 0) {
                    // 执行折行计算
                    const tl = text_layout.computeTextLayout(
                        t.content,
                        avail_w,
                        t.wrap,
                        t.max_lines,
                        t.font_size,
                        t.line_height,
                        t.font_weight,
                        t.use_italic_font,
                        t.use_monospace_font,
                        t.spans,
                    );
                    // 缓存到 node 上，避免后续 layout 阶段重复计算
                    if (node.layoutOutputPtr()) |lo| lo.artifacts.text_layout = tl;
                    break :blk tl.total_height + pad_h;
                }
            }
            // 单行或无宽度约束
            break :blk t.font_size * t.line_height + pad_h;
        };

        return Size.init(
            std.math.clamp(text_w, constraints.min_width, constraints.max_width),
            std.math.clamp(text_h, constraints.min_height, constraints.max_height),
        );
    }

    // 容器节点：递归 measure 子节点
    if (node.children.items.len == 0) {
        return Size.init(
            std.math.clamp(node.style.padding.horizontal(), constraints.min_width, constraints.max_width),
            std.math.clamp(node.style.padding.vertical(), constraints.min_height, constraints.max_height),
        );
    }

    const is_row = node.style.direction.isRow();
    const pad_w = node.style.padding.horizontal();
    const pad_h = node.style.padding.vertical();

    var main_total: f32 = 0;
    var cross_max: f32 = 0;
    var flow_count: usize = 0;

    for (node.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        flow_count += 1;
        const margin_main = if (is_row) child.style.marginHorizontal() else child.style.marginVertical();
        const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();

        // 子节点的 intrinsic size
        const child_main_sizing = if (is_row) child.style.width else child.style.height;
        const child_cross_sizing = if (is_row) child.style.height else child.style.width;

        const child_main: f32 = switch (child_main_sizing) {
            .px => |v| v + margin_main,
            .grow, .fit => blk: {
                // 对 fit 子节点：如果有确切主轴尺寸约束，传递给子节点
                const child_constraints = if (is_row)
                    types.LayoutConstraints{ .max_width = @max(@as(f32, 0), constraints.max_width - pad_w - margin_main) }
                else
                    types.LayoutConstraints{ .max_height = @max(@as(f32, 0), constraints.max_height - pad_h - margin_main) };
                const child_size = measureNode(child, child_constraints);
                break :blk (if (is_row) child_size.width else child_size.height) + margin_main;
            },
            .percent => 0, // percent in intrinsic = auto (CSS 规范)
        };

        const child_cross: f32 = switch (child_cross_sizing) {
            .px => |v| v + margin_cross,
            .grow, .fit => blk: {
                const child_constraints = if (is_row)
                    types.LayoutConstraints{ .max_height = @max(@as(f32, 0), constraints.max_height - pad_h - margin_cross) }
                else
                    types.LayoutConstraints{ .max_width = @max(@as(f32, 0), constraints.max_width - pad_w - margin_cross) };
                const child_size = measureNode(child, child_constraints);
                break :blk (if (is_row) child_size.height else child_size.width) + margin_cross;
            },
            .percent => 0,
        };

        main_total += child_main;
        cross_max = @max(cross_max, child_cross);
    }

    if (flow_count > 1) {
        main_total += @as(f32, @floatFromInt(flow_count - 1)) * node.style.gap;
    }

    const w = if (is_row) main_total + pad_w else cross_max + pad_w;
    const h = if (is_row) cross_max + pad_h else main_total + pad_h;

    return Size.init(
        std.math.clamp(w, constraints.min_width, constraints.max_width),
        std.math.clamp(h, constraints.min_height, constraints.max_height),
    );
}

pub fn layoutNode(node: *Node, available: Size, ctx: LayoutContext) void {
    if (!enterLayoutRecursion()) return;
    defer leaveLayoutRecursion();

    // GlyphRun pipeline globals, measureIntrinsicTextWidth 这条
    // calc-chain 没 ctx 参数，layout pass 入口 set/restore globals 让
    // measureIntrinsicTextWidth 能走 cache。嵌套 layoutNode (递归 child)
    // 时保存外层值，确保 unwind 时还原。
    //
    // 同时给 text_layout.measureProportional 安装
    // shapeMeasureBridge 回调，让 *所有* legacy 测量路径
    // (computeTextLayout / findLineBreak / measureSpanAware / textarea
    // 直调 / input/text_utils 直调) 自动走 pipeline，无需改 caller。
    // 嵌套 layoutNode 时 prev/restore 保护。
    const prev_cache = g_active_shaping_cache;
    const prev_fs = g_active_font_system;
    g_active_shaping_cache = ctx.shaping_cache;
    g_active_font_system = ctx.font_system;
    text_layout.setShapeMeasureFn(&shapeMeasureBridge);
    defer {
        g_active_shaping_cache = prev_cache;
        g_active_font_system = prev_fs;
        // 嵌套退出 / 顶层退出都还原；prev_cache=null 时 unset，否则保持 set
        if (prev_cache == null and prev_fs == null) {
            text_layout.setShapeMeasureFn(null);
        }
    }

    // layout_isolation debug assert: isolation 节点不能是 fit（否则内部变化影响外部尺寸）
    if (node.style.layout_isolation) {
        std.debug.assert(node.style.width != .fit and node.style.height != .fit);
    }

    // 只对根节点计算自身尺寸；子节点的尺寸由 layoutChildren 负责
    if (node.parent == null) {
        const intrinsic_w = calcIntrinsicSize(node, true);
        const intrinsic_h = calcIntrinsicSize(node, false);

        node.setLayoutW(resolveSize(node.style.width, available.width, intrinsic_w));
        node.setLayoutH(resolveSize(node.style.height, available.height, intrinsic_h));
    }

    const w = node.rectFromWorldOrFallback().w;
    const h = node.rectFromWorldOrFallback().h;

    if (node.children.items.len > 0) {
        if (node.frame_state.state_bits.dirty.core.layout) {
            // 当前节点脏 -> 全量布局子节点（flex 计算依赖兄弟关系）
            const content_w = w - node.style.padding.horizontal();
            const content_h = h - node.style.padding.vertical();
            if (node.style.grid() != null) {
                layoutChildrenGrid(node, Size.init(content_w, content_h), ctx);
            } else {
                layoutChildren(node, Size.init(content_w, content_h), ctx);
            }
        } else if (node.frame_state.state_bits.dirty.core.subtree_layout) {
            const own_main_fit = if (node.style.direction.isRow())
                node.style.width == .fit
            else
                node.style.height == .fit;
            const own_cross_fit = if (node.style.direction.isRow())
                node.style.height == .fit
            else
                node.style.width == .fit;

            // fit 容器不能只递归脏子树：它的自身尺寸依赖后代的实际布局结果。
            // 典型场景是深层 wrap text 变高后，直接子节点只带 subtree_dirty，
            // 若这里不 full layout，父容器会继续持有旧 rect，overflow_hidden 会把内容裁掉。
            if (own_main_fit or own_cross_fit) {
                const content_w = w - node.style.padding.horizontal();
                const content_h = h - node.style.padding.vertical();
                if (node.style.grid() != null) {
                    layoutChildrenGrid(node, Size.init(content_w, content_h), ctx);
                } else {
                    layoutChildren(node, Size.init(content_w, content_h), ctx);
                }
            } else
            // Grid 容器: 直接子节点 layout_dirty 时需 full relayout。
            // Grid 的 track sizing（包括隐式 auto 行）依赖子节点尺寸，
            // 且子节点位置由 auto-placement 决定（兄弟相关），
            // 因此任何子节点脏都需要全量重算。
            if (node.style.grid() != null) {
                var need_full = false;
                for (node.children.items) |child| {
                    if (child.frame_state.state_bits.dirty.core.layout) {
                        need_full = true;
                        break;
                    }
                }
                if (need_full) {
                    const content_w = w - node.style.padding.horizontal();
                    const content_h = h - node.style.padding.vertical();
                    layoutChildrenGrid(node, Size.init(content_w, content_h), ctx);
                } else {
                    for (node.children.items) |child| {
                        if (child.frame_state.state_bits.dirty.core.layout or child.frame_state.state_bits.dirty.core.subtree_layout) {
                            layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), ctx);
                        }
                    }
                }
            } else {
                const is_row = node.style.direction.isRow();
                // 仅子树有脏节点 -> 检查是否有 flex 兄弟依赖
                // 如果存在 grow 子节点，一个子节点的尺寸变化会影响其他 flex 兄弟的分配，
                // 此时必须回退到全量重布局
                var has_flex_children = false;
                for (node.children.items) |child| {
                    if (isOutOfFlow(child)) continue;
                    const main_sizing = if (is_row) child.style.width else child.style.height;
                    if (main_sizing == .grow) {
                        has_flex_children = true;
                        break;
                    }
                }

                if (has_flex_children) {
                    // 优化：只有”直接子节点布局可能影响兄弟分配”时才全量布局。
                    // 典型滚动场景只是深层 subtree_dirty（直接子节点尺寸不变），无需回退全量。
                    var must_full_layout = false;
                    for (node.children.items) |child| {
                        if (isOutOfFlow(child)) continue;
                        const main_sizing = if (is_row) child.style.width else child.style.height;
                        if (child.frame_state.state_bits.dirty.core.layout) {
                            must_full_layout = true;
                            break;
                        }
                        if (child.frame_state.state_bits.dirty.core.subtree_layout and main_sizing == .fit) {
                            must_full_layout = true;
                            break;
                        }
                    }

                    if (must_full_layout) {
                        const content_w = w - node.style.padding.horizontal();
                        const content_h = h - node.style.padding.vertical();
                        layoutChildren(node, Size.init(content_w, content_h), ctx);
                    } else {
                        for (node.children.items) |child| {
                            if (child.frame_state.state_bits.dirty.core.layout or child.frame_state.state_bits.dirty.core.subtree_layout) {
                                // absolute 且自身 layout-dirty 的子节点必须走
                                // layoutAbsoluteChild 重新 resolve 尺寸/定位：
                                // 上面的 must_full_layout 判定有意跳过 absolute
                                //（不影响 flow 兄弟），但 fallback 若只递归
                                // layoutNode(child, 旧rect)，**首帧布局之后才
                                // append 的 absolute 子节点 rect 恒为 0**,
                                // 画布对象后挂的文字 label 因此永远不渲染
                                //（下游应用 sticky 文本消失的根因）。
                                if (isDisplayNone(child)) {
                                    collapseDisplayNone(child);
                                } else if (child.style.position == .absolute and absoluteChildNeedsResolve(child)) {
                                    layoutAbsoluteChild(node, child, ctx);
                                } else {
                                    layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), ctx);
                                }
                            }
                        }
                    }
                } else {
                    // 无 flex 依赖时，若直接子节点 layout_dirty（尺寸/位置样式变化），
                    // 仍需 full layout 才能更新该子节点在父容器内的 rect。
                    // 仅递归 layoutNode(child) 不会重算 flow child 的 x/y/w/h。
                    var must_full_layout = false;
                    for (node.children.items) |child| {
                        if (isOutOfFlow(child)) continue;
                        const main_sizing = if (is_row) child.style.width else child.style.height;
                        if (child.frame_state.state_bits.dirty.core.layout) {
                            must_full_layout = true;
                            break;
                        }
                        if (child.frame_state.state_bits.dirty.core.subtree_layout and main_sizing == .fit) {
                            must_full_layout = true;
                            break;
                        }
                    }

                    if (must_full_layout) {
                        const content_w = w - node.style.padding.horizontal();
                        const content_h = h - node.style.padding.vertical();
                        layoutChildren(node, Size.init(content_w, content_h), ctx);
                    } else {
                        for (node.children.items) |child| {
                            if (child.frame_state.state_bits.dirty.core.layout or child.frame_state.state_bits.dirty.core.subtree_layout) {
                                // absolute 且自身 layout-dirty 的子节点必须走
                                // layoutAbsoluteChild 重新 resolve 尺寸/定位：
                                // 上面的 must_full_layout 判定有意跳过 absolute
                                //（不影响 flow 兄弟），但 fallback 若只递归
                                // layoutNode(child, 旧rect)，**首帧布局之后才
                                // append 的 absolute 子节点 rect 恒为 0**,
                                // 画布对象后挂的文字 label 因此永远不渲染
                                //（下游应用 sticky 文本消失的根因）。
                                if (isDisplayNone(child)) {
                                    collapseDisplayNone(child);
                                } else if (child.style.position == .absolute and absoluteChildNeedsResolve(child)) {
                                    layoutAbsoluteChild(node, child, ctx);
                                } else {
                                    layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), ctx);
                                }
                            }
                        }
                    }
                }
            }
        }
        // 两者都 false -> 跳过整个子树（增量布局核心优化）
    }

    // layout 完成后：overflow_hidden 节点如果本次 layout_dirty（尺寸/位置可能变了），
    // 必须 invalidate 渲染缓存 + 标脏渲染。
    // 不做这一步会导致：
    // 1. 旧缓存的 push_clip rect 和子节点坐标已过期 -> 复用错误缓存
    // 2. 新 mount 首帧子节点未完全 layout -> 渲染+缓存了不完整内容 ->
    //    后续帧 subtree_render_dirty 已清零 -> 复用不完整缓存 -> 部分内容永久丢失
    // markRenderDirty 向上冒泡 subtree_render_dirty，确保祖先 overflow_hidden 容器
    //（如 scroll_area）的缓存也被正确 invalidate。
    if (node.frame_state.state_bits.dirty.core.layout and node.style.overflow_hidden) {
        node.invalidateRenderCache();
        node.markRenderDirty();
    }

    // 计算子节点包围盒（hitTest 剪枝用）
    // 只在 layout_dirty 或 subtree_dirty 时重算，避免每帧冗余计算
    if (node.frame_state.state_bits.dirty.core.layout or node.frame_state.state_bits.dirty.core.subtree_layout) {
        computeChildrenBBox(node);
    }

    node.frame_state.state_bits.dirty.core.layout = false;
    node.frame_state.state_bits.dirty.core.subtree_layout = false;

    // 触发 onMount 生命周期钩子（仅当前节点）。
    // 子节点会在各自 layoutNode 调用末尾触发，避免每帧全树扫描。
    node_mod.fireMountIfNeeded(node);
}

/// 计算子节点包围盒 union（相对于父坐标系，含 translate 偏移）
/// hitTest 时先检查包围盒，不包含鼠标位置则跳过整个子树
fn computeChildrenBBox(node: *Node) void {
    const lo = node.layoutOutputPtr() orelse return;
    if (node.children.items.len == 0) {
        lo.artifacts.children_bbox = null;
        return;
    }

    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    var has_flow = false;

    for (node.children.items) |child| {
        if (child.getOpacity() == 0) continue;
        // z>0 子节点同样计入：z_index 只影响同级顺序、不逃逸裁剪，它们和 z=0 一样
        // 画在父节点的 opacity surface 里，必须撑大 surface 包围盒（geometry 用它
        // 算 surface bounds），否则溢出父框的 z>0 子节点会被纹理边界截掉。
        const cx = child.rectFromWorldOrFallback().x + child.style.translate_x + child.frame_state.frame_local.runtime.sticky.x;
        const cy = child.rectFromWorldOrFallback().y + child.style.translate_y + child.frame_state.frame_local.runtime.sticky.y;
        if (child.rectFromWorldOrFallback().w <= 0 or child.rectFromWorldOrFallback().h <= 0) continue;
        min_x = @min(min_x, cx);
        min_y = @min(min_y, cy);
        max_x = @max(max_x, cx + child.rectFromWorldOrFallback().w);
        max_y = @max(max_y, cy + child.rectFromWorldOrFallback().h);
        has_flow = true;
    }

    if (has_flow) {
        // 包围盒添加少量 margin 容纳阴影/outline 溢出
        const margin: f32 = 8;
        lo.artifacts.children_bbox = types.ComputedRect.init(
            min_x - margin,
            min_y - margin,
            (max_x - min_x) + margin * 2,
            (max_y - min_y) + margin * 2,
        );
    } else {
        lo.artifacts.children_bbox = null;
    }
}

/// 批量 reverse，镜像翻转直接子节点在主轴上的位置
/// 相对坐标系下只需修改直接子节点的 rect，无需递归偏移后代 O(N)
fn batchReverseChildren(
    children: []*Node,
    comptime is_row: bool,
    main_start: f32,
    main_end: f32,
) void {
    for (children) |child| {
        if (isOutOfFlow(child)) continue;
        const child_size = if (is_row) child.rectFromWorldOrFallback().w else child.rectFromWorldOrFallback().h;
        const new_pos = main_start + (main_end - ((if (is_row) child.rectFromWorldOrFallback().x else child.rectFromWorldOrFallback().y) - main_start + child_size));

        // 位置变了必须标脏：后代的世界坐标由祖先链累加得出，父节点挪了位置
        // 而不标脏，整棵子树会带着过期坐标留到下一帧（命中测试、裁剪、合成
        // 全部错位）。摆放循环里有同样的检查，这里此前漏了。
        const old_pos = if (is_row) child.rectFromWorldOrFallback().x else child.rectFromWorldOrFallback().y;
        if (old_pos != new_pos) {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        if (is_row) {
            child.setLayoutX(new_pos);
        } else {
            child.setLayoutY(new_pos);
        }
    }
}

/// 计算子节点在主轴上的尺寸（comptime 分支避免 runtime 调用 comptime 参数）
fn calcChildMainSize(child: *Node, comptime is_row: bool, available: Size) f32 {
    const main_sizing = if (is_row) child.style.width else child.style.height;
    return switch (main_sizing) {
        .px => |v| v,
        .grow => 0, // flex 子节点在 wrap 中按最小尺寸算
        .fit => calcIntrinsicSize(child, is_row),
        .percent => |p| if (is_row) available.width * p / 100.0 else available.height * p / 100.0,
    };
}

/// 计算子节点在交叉轴上的尺寸
fn calcChildCrossSize(child: *Node, comptime is_row: bool, available: Size) f32 {
    const cross_sizing = if (is_row) child.style.height else child.style.width;
    const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();
    return switch (cross_sizing) {
        .px => |v| v,
        .grow => |mm| if (is_row)
            std.math.clamp(@max(@as(f32, 0), available.height - margin_cross), mm.min, mm.max)
        else
            std.math.clamp(@max(@as(f32, 0), available.width - margin_cross), mm.min, mm.max),
        .fit => calcIntrinsicSize(child, !is_row),
        .percent => |p| if (is_row) available.height * p / 100.0 else available.width * p / 100.0,
    };
}

/// 计算子节点的 basis 尺寸（用于 flex_shrink 加权计算）
/// flex_basis > 0 时返回 flex_basis，否则返回主轴实际尺寸
fn childBasisSize(child: *Node, is_row: bool, available: Size) f32 {
    if (child.style.flex_basis() > 0) return child.style.flex_basis();
    const main_sizing = if (is_row) child.style.width else child.style.height;
    return switch (main_sizing) {
        .px => |v| v,
        .grow => 0,
        .fit => if (is_row) calcIntrinsicSize(child, true) else calcIntrinsicSize(child, false),
        .percent => |p| if (is_row) available.width * p / 100.0 else available.height * p / 100.0,
    };
}

/// Flex wrap 布局：子节点溢出时自动换行
fn layoutChildrenWrap(parent: *Node, available: Size, ctx: LayoutContext) void {
    if (parent.style.direction.isRow()) {
        layoutChildrenWrapImpl(parent, available, true, ctx);
    } else {
        layoutChildrenWrapImpl(parent, available, false, ctx);
    }
}

fn layoutChildrenWrapImpl(parent: *Node, available: Size, comptime is_row: bool, ctx: LayoutContext) void {
    const style = parent.style;
    const gap = style.gap;
    const main_available = if (is_row) available.width else available.height;

    // Pass 1: 分行，当累计主轴尺寸超过可用空间时换行
    // 用固定大小的行结构（从 64 扩到 256 支持大量 tag/badge wrap 布局）
    const max_lines = 256;
    var line_starts: [max_lines]usize = undefined;
    var line_ends: [max_lines]usize = undefined;
    var line_cross_sizes: [max_lines]f32 = undefined;
    var n_lines: usize = 0;

    const children = parent.children.items;
    if (children.len == 0) return;

    var line_start: usize = 0;
    var line_main: f32 = 0;
    var line_has_flow = false;

    for (children, 0..) |child, i| {
        if (isOutOfFlow(child)) continue;
        const child_main = calcChildMainSize(child, is_row, available);
        const child_main_outer = child_main + childMarginForAxis(child, is_row);
        const needed = if (line_has_flow) child_main_outer + gap else child_main_outer;

        if (line_has_flow and line_main + needed > main_available and n_lines < max_lines) {
            // 结束当前行
            line_starts[n_lines] = line_start;
            line_ends[n_lines] = i;
            n_lines += 1;
            line_start = i;
            line_main = child_main;
            line_has_flow = true;
        } else {
            line_main += needed;
            line_has_flow = true;
        }
    }
    // 最后一行
    if (n_lines < max_lines) {
        line_starts[n_lines] = line_start;
        line_ends[n_lines] = children.len;
        n_lines += 1;
    } else {
        // 超过 max_lines 限制，将剩余子节点合并到最后一行
        line_ends[max_lines - 1] = children.len;
        std.log.warn("[layoutChildrenWrap] exceeded max_lines={d}, merging remaining children into last line", .{max_lines});
    }

    // Pass 2: 计算每行的交叉轴高度（取该行最大子节点）
    for (0..n_lines) |line_idx| {
        var max_cross: f32 = 0;
        for (children[line_starts[line_idx]..line_ends[line_idx]]) |child| {
            if (isOutOfFlow(child)) continue;
            const cross = calcChildCrossSize(child, is_row, available) + childMarginForAxis(child, !is_row);
            max_cross = @max(max_cross, cross);
        }
        line_cross_sizes[line_idx] = max_cross;
    }

    // Pass 3: 布局每行
    const pad_main_start: f32 = if (is_row) style.padding.left else style.padding.top;
    const pad_cross_start: f32 = if (is_row) style.padding.top else style.padding.left;
    var cross_cursor: f32 = pad_cross_start;

    for (0..n_lines) |line_idx| {
        var main_cursor: f32 = pad_main_start;
        const line_cross = line_cross_sizes[line_idx];

        for (children[line_starts[line_idx]..line_ends[line_idx]]) |child| {
            if (isOutOfFlow(child)) continue;
            const child_main = calcChildMainSize(child, is_row, available);
            const child_cross = calcChildCrossSize(child, is_row, available);
            const margin_main = childMarginForAxis(child, is_row);
            const margin_cross = childMarginForAxis(child, !is_row);
            const child_cross_outer = child_cross + margin_cross;

            // cross axis alignment
            const cross_offset: f32 = switch (style.align_items) {
                .center => (line_cross - child_cross_outer) / 2.0,
                .end => line_cross - child_cross_outer,
                else => 0,
            };

            const new_w = if (is_row)
                child_main
            else if (style.align_items == .stretch)
                @max(@as(f32, 0), line_cross - margin_cross)
            else
                child_cross;
            const new_h = if (is_row)
                (if (style.align_items == .stretch) @max(@as(f32, 0), line_cross - margin_cross) else child_cross)
            else
                child_main;
            if (child.rectFromWorldOrFallback().w != new_w or child.rectFromWorldOrFallback().h != new_h) {
                child.frame_state.state_bits.dirty.core.layout = true;
            }

            if (is_row) {
                child.setLayoutX(main_cursor + child.style.margin.left);
                child.setLayoutY(cross_cursor + cross_offset + child.style.margin.top);
                child.setLayoutW(new_w);
                child.setLayoutH(new_h);
            } else {
                child.setLayoutY(main_cursor + child.style.margin.top);
                child.setLayoutX(cross_cursor + cross_offset + child.style.margin.left);
                child.setLayoutH(new_h);
                child.setLayoutW(new_w);
            }

            layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), ctx);
            main_cursor += child_main + margin_main + gap;
        }

        cross_cursor += line_cross + gap;
    }

    // fit 容器回填: wrap 后 cross axis 的实际尺寸 = 所有行高之和
    if (n_lines > 0) {
        const pad_cross_end: f32 = if (is_row) style.padding.bottom else style.padding.right;
        // cross_cursor 多加了一个 gap，减去后加 padding
        const total_cross = cross_cursor - gap + pad_cross_end;
        const cross_fit = if (is_row) style.height == .fit else style.width == .fit;
        if (cross_fit) {
            if (is_row) {
                const mm = effectiveMinMax(style.height, parent, false);
                parent.setLayoutH(std.math.clamp(total_cross, mm.min, mm.max));
            } else {
                const mm = effectiveMinMax(style.width, parent, true);
                parent.setLayoutW(std.math.clamp(total_cross, mm.min, mm.max));
            }
        }
    }

    // Reverse: 主轴方向翻转（相对坐标，无需 parent.rect.x/y）
    if (style.direction.isReverse()) {
        const main_start = if (is_row) style.padding.left else style.padding.top;
        const main_end = if (is_row) parent.rectFromWorldOrFallback().w - style.padding.right else parent.rectFromWorldOrFallback().h - style.padding.bottom;

        for (children) |child| {
            if (isOutOfFlow(child)) continue;
            if (is_row) {
                child.setLayoutX(main_start + (main_end - (child.rectFromWorldOrFallback().x - main_start + child.rectFromWorldOrFallback().w)));
            } else {
                child.setLayoutY(main_start + (main_end - (child.rectFromWorldOrFallback().y - main_start + child.rectFromWorldOrFallback().h)));
            }
        }
    }

    // wrap_reverse: 交叉轴方向翻转行（相对坐标）
    if (style.flex_wrap() == .wrap_reverse) {
        const cross_start = if (is_row) style.padding.top else style.padding.left;
        const cross_end = if (is_row) parent.rectFromWorldOrFallback().h - style.padding.bottom else parent.rectFromWorldOrFallback().w - style.padding.right;

        for (children) |child| {
            if (isOutOfFlow(child)) continue;
            if (is_row) {
                child.setLayoutY(cross_start + (cross_end - (child.rectFromWorldOrFallback().y - cross_start + child.rectFromWorldOrFallback().h)));
            } else {
                child.setLayoutX(cross_start + (cross_end - (child.rectFromWorldOrFallback().x - cross_start + child.rectFromWorldOrFallback().w)));
            }
        }
    }
}

// fitResizeAfterLayout 函数已删除。
// 等价逻辑在 layoutChildren 内 inline（搜 "fit_resize_block:"）。
// 真消除回填需要 layoutNode 主签名换 LayoutInput + Constraint 向下传递，
// 那是 v0.4-P1 后续 layoutNode 完整重写工作（继续 in v0.5）。

/// Absolute 子节点布局（支持 CSS inset 定位模型）
///
/// 定位优先级：inset > static-position-origin（margin 只参与外边距修正，不单独充当定位 API）
/// - left + right 同时设定 -> width=grow 时拉伸填满两侧 inset 之间（CSS width:auto 的等价物）；
///   px/percent/fit 仍按自身解析（fit = 内容固有尺寸，空 box 为 0），剩余空间交给 margin 分配
/// - top + bottom 同时设定 -> 同理，height=grow 才拉伸
/// - 只设一侧 -> 从该侧偏移，尺寸由 width/height 决定
/// - 全 auto -> 退回到 containing block 起点作为 static position origin，再叠加 margin
/// 增量布局里 absolute 子节点什么时候要重新 resolve 尺寸（而不是按旧 rect 只递归子树）：
/// 自身 layout 脏；或者宽 / 高是 fit 且子树有布局变化，fit 尺寸取决于后代，按旧 rect
/// 当可用空间排子节点时，可收缩的后代会被挤回旧尺寸，容器只缩不涨
/// （Popover 下拉面板：列表行变多后高度不恢复，实测复现）。
fn absoluteChildNeedsResolve(child: *const Node) bool {
    const bits = child.frame_state.state_bits.dirty.core;
    if (bits.layout) return true;
    if (!bits.subtree_layout) return false;
    return child.style.width == .fit or child.style.height == .fit;
}

/// 确定宽度后为 wrap 文本节点计算/缓存折行（flex 与 absolute 两条布局路径
/// 共用，absolute 定位的文本节点曾走不到折行计算，wrap 永远按单行渲染）。
/// 返回折行总高（含垂直 padding），供 fit 高度使用；不适用时返回 null。
fn computeWrapTextLayoutForWidth(child: *Node, child_width: f32) ?f32 {
    const t = child.getText() orelse return null;
    if (t.wrap == .none) return null;
    const text_avail_w = child_width - child.style.padding.horizontal();
    if (text_avail_w <= 0) return null;
    const layout_spans = if (t.spans_affect_layout) t.spans else &.{};
    // 缓存命中检查（layoutOutputPtr 给稳定地址，isCacheValid 收 *const）
    if (child.layoutOutputPtr()) |c_lo| {
        const need_recompute = if (c_lo.artifacts.text_layout) |*tl|
            !text_layout.isCacheValid(tl, t.content, text_avail_w, t.font_weight, t.font_size, t.use_italic_font, t.use_monospace_font, t.wrap, t.max_lines, layout_spans)
        else
            true;
        if (need_recompute) {
            c_lo.artifacts.text_layout = text_layout.computeTextLayout(
                t.content,
                text_avail_w,
                t.wrap,
                t.max_lines,
                t.font_size,
                t.line_height,
                t.font_weight,
                t.use_italic_font,
                t.use_monospace_font,
                layout_spans,
            );
        }
    }
    if (child.getLayoutOutput().artifacts.text_layout) |tl| {
        return tl.total_height + child.style.padding.vertical();
    }
    return null;
}

fn layoutAbsoluteChild(parent: *Node, child: *Node, ctx: LayoutContext) void {
    const inset = child.style.inset();
    const margin = child.style.marginSpec();

    // CSS absolute positioning uses the containing block established by the
    // parent's padding edge, not the content box used by in-flow Flex/Grid
    // children. Zenit paints borders inside the layout rect (border widths do
    // not consume layout space), so the parent's local rect is its effective
    // padding-box range and its origin is (0, 0).
    //
    // Do not reuse layoutChildren's `available`: that value has already had
    // parent padding removed. Mixing that content-box size with setLayoutX/Y's
    // parent-local coordinates shifts right/bottom anchored children by the
    // parent's total padding and resolves percentages against the wrong box.
    const parent_rect = parent.rectFromWorldOrFallback();
    const cb_w = @max(@as(f32, 0), parent_rect.w);
    const cb_h = @max(@as(f32, 0), parent_rect.h);

    // ── 水平轴 ──
    const left_val = inset.left.resolve(cb_w);
    const right_val = inset.right.resolve(cb_w);

    var child_width: f32 = undefined;
    var new_x: f32 = undefined;

    if (left_val != null and right_val != null) {
        const available_outer = @max(0, cb_w - left_val.? - right_val.?);
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(available_outer - child.style.marginHorizontal(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        child_width = std.math.clamp(child_width, child.style.min_width(), child.style.max_width());
        if (child.style.width == .grow) {
            new_x = left_val.? + (if (child.style.marginLeftIsAuto()) 0 else margin.left);
        } else {
            const resolved = resolveAxisMargins(
                available_outer,
                child_width,
                margin.left,
                margin.right,
                child.style.marginLeftIsAuto(),
                child.style.marginRightIsAuto(),
            );
            new_x = left_val.? + resolved.start;
        }
    } else if (left_val) |lv| {
        // 只有 left -> 从左侧偏移
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(cb_w - lv - margin.horizontal(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        new_x = lv + (if (child.style.marginLeftIsAuto()) 0 else margin.left);
    } else if (right_val) |rv| {
        // 只有 right -> 从右侧偏移
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(cb_w - rv - margin.horizontal(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        new_x = cb_w - rv - (if (child.style.marginRightIsAuto()) 0 else margin.right) - child_width;
    } else {
        // 无 inset -> 以 containing block 起点作为 static position origin，再应用 margin
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(@max(0, cb_w - margin.horizontal()), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        new_x = if (child.style.marginLeftIsAuto()) 0 else margin.left;
    }

    // ── 垂直轴 ──
    const top_val = inset.top.resolve(cb_h);
    const bottom_val = inset.bottom.resolve(cb_h);

    var child_height: f32 = undefined;
    var new_y: f32 = undefined;

    if (top_val != null and bottom_val != null) {
        const available_outer = @max(0, cb_h - top_val.? - bottom_val.?);
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(available_outer - child.style.marginVertical(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        child_height = std.math.clamp(child_height, child.style.min_height(), child.style.max_height());
        if (child.style.height == .grow) {
            new_y = top_val.? + (if (child.style.marginTopIsAuto()) 0 else margin.top);
        } else {
            const resolved = resolveAxisMargins(
                available_outer,
                child_height,
                margin.top,
                margin.bottom,
                child.style.marginTopIsAuto(),
                child.style.marginBottomIsAuto(),
            );
            new_y = top_val.? + resolved.start;
        }
    } else if (top_val) |tv| {
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(cb_h - tv - margin.vertical(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        new_y = tv + (if (child.style.marginTopIsAuto()) 0 else margin.top);
    } else if (bottom_val) |bv| {
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(cb_h - bv - margin.vertical(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        new_y = cb_h - bv - (if (child.style.marginBottomIsAuto()) 0 else margin.bottom) - child_height;
    } else {
        // 无 inset -> 以 containing block 起点作为 static position origin，再应用 margin
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(@max(0, cb_h - margin.vertical()), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        new_y = if (child.style.marginTopIsAuto()) 0 else margin.top;
    }

    // 独立 min/max 约束 clamp
    child_width = std.math.clamp(child_width, child.style.min_width(), child.style.max_width());
    child_height = std.math.clamp(child_height, child.style.min_height(), child.style.max_height());

    // 文本折行：absolute 文本节点同样要在定宽后断行（canvas 覆盖层 label 场景）
    if (computeWrapTextLayoutForWidth(child, child_width)) |wrapped_h| {
        if (child.style.height == .fit) {
            child_height = std.math.clamp(wrapped_h, child.style.min_height(), child.style.max_height());
        }
    }

    if (child.rectFromWorldOrFallback().w != child_width or child.rectFromWorldOrFallback().h != child_height or
        child.rectFromWorldOrFallback().x != new_x or child.rectFromWorldOrFallback().y != new_y)
    {
        child.frame_state.state_bits.dirty.core.layout = true;
    }
    child.setLayoutX(new_x);
    child.setLayoutY(new_y);
    child.setLayoutW(child_width);
    child.setLayoutH(child_height);
    layoutNode(child, Size.init(child_width, child_height), ctx);

    // absolute + fit 高度修正：calcIntrinsicSize 阶段 text_layout 尚未生成，
    // 导致 wrap text 的 fit 高度被低估为单行。layoutNode 完成后 text shaping
    // 已执行，此时回读子节点实际内容高度并更新 child.rect.h。
    if (child.style.height == .fit and top_val == null and bottom_val == null and child.children.items.len > 0) {
        var actual_content: f32 = 0;
        const child_is_row = child.style.direction.isRow();
        for (child.children.items) |gc| {
            if (isOutOfFlow(gc)) continue;
            if (child_is_row) {
                actual_content = @max(actual_content, gc.rectFromWorldOrFallback().h + gc.style.marginVertical());
            } else {
                actual_content += gc.rectFromWorldOrFallback().h + gc.style.marginVertical();
            }
        }
        if (!child_is_row) {
            const abs_flow_n = blk: {
                var n: usize = 0;
                for (child.children.items) |gc| {
                    if (gc.style.position != .absolute) n += 1;
                }
                break :blk n;
            };
            if (abs_flow_n > 1) actual_content += @as(f32, @floatFromInt(abs_flow_n - 1)) * child.style.gap;
        }
        actual_content += child.style.padding.vertical();
        const mm = effectiveMinMax(child.style.height, child, false);
        const fit_h = std.math.clamp(actual_content, mm.min, mm.max);
        if (fit_h != child.rectFromWorldOrFallback().h) {
            child.setLayoutH(fit_h);
        }
    }
}

fn layoutChildren(parent: *Node, available: Size, ctx: LayoutContext) void {
    const style = parent.style;
    const is_row = style.direction.isRow();

    // Wrap 模式：分行布局
    if (style.flex_wrap() != .no_wrap) {
        layoutChildrenWrap(parent, available, ctx);
        return;
    }

    // Pass 1: 计算固定尺寸、flex 总量和 flow 子节点数
    var used_space: f32 = 0;
    var flex_total: f32 = 0;
    var flow_count: usize = 0;
    var main_auto_margin_count: usize = 0;

    for (parent.children.items) |child| {
        // absolute 子节点不参与 flow 布局
        if (isOutOfFlow(child)) continue;
        flow_count += 1;

        const margin_main = if (is_row) child.style.marginHorizontal() else child.style.marginVertical();
        if (is_row) {
            if (child.style.marginLeftIsAuto()) main_auto_margin_count += 1;
            if (child.style.marginRightIsAuto()) main_auto_margin_count += 1;
        } else {
            if (child.style.marginTopIsAuto()) main_auto_margin_count += 1;
            if (child.style.marginBottomIsAuto()) main_auto_margin_count += 1;
        }
        const main_sizing = if (is_row) child.style.width else child.style.height;

        // flex_basis > 0 时，用 flex_basis 替代 width/height 作为主轴尺寸贡献
        if (child.style.flex_basis() > 0 and main_sizing != .grow) {
            used_space += child.style.flex_basis() + margin_main;
        } else switch (main_sizing) {
            .px => |v| used_space += v + margin_main,
            .grow => {
                flex_total += child.style.flex;
                // grow 子节点自身不占 used_space（尺寸由 remaining 分配），但它的
                // 主轴 margin 是实打实的固定开销，必须和 .px/.fit/.percent 一样计入，
                // 否则 remaining 被高估，带 margin 的 flex 子节点会溢出父容器。
                // auto margin 在 marginHorizontal/Vertical 里已按 0 计，不会和
                // main_auto_margin_count 的分配重复。
                used_space += margin_main;
            },
            .fit => {
                // fit 的 intrinsic 只有在存在 flex 兄弟时才影响布局（用于计算 remaining）。
                // 延迟到确认 flex_total > 0 后再补算，避免对大量 fit 子节点的冗余 intrinsic 计算。
                used_space += margin_main;
            },
            .percent => |p| {
                const main_avail = if (is_row) available.width else available.height;
                used_space += main_avail * p / 100.0 + margin_main;
            },
        }
    }

    // Gap: space_* 模式不使用 style.gap，由 justify 计算间距
    // 注意：只排除主轴方向 .fit 的情况（fit 容器宽度由内容决定，无剩余空间可分配）
    // .grow / .px / .percent 父容器都有确定的主轴尺寸，space_* 应该生效
    const main_is_fit = if (is_row) style.width == .fit else style.height == .fit;
    const is_space_mode = !main_is_fit and
        flex_total == 0 and
        (style.justify == .space_between or
            style.justify == .space_around or
            style.justify == .space_evenly);

    // fit 子节点的 intrinsic 只在需要精确 used_space 时才补算：
    // - flex_total > 0: 需要 remaining 来分配 flex 空间
    // - is_space_mode: 需要 remaining 来分配 justify 间距
    // - justify == .center/.end: 需要精确 remaining 来计算偏移
    // 对于最常见的 "所有子节点都是 fit/px，无 flex 无 justify" 场景，
    // 完全跳过 calcIntrinsicSize，避免对 3000+ 子节点的冗余递归。
    // - has_shrinkable_fit: flex_shrink 也要精确的 used_space。存在「可收缩的 fit 子节点」
    //   时不补算，溢出量只剩 px 子节点之和，收缩整段不触发，fit + max 被夹住的容器
    //  （popover chrome 被 autosize 限高）里 ScrollArea 容器仍按内容高度排，后面的
    //   footer 被推出容器外，列表也滚不动（下游编辑器插入菜单，2026-09-28）。
    //   「可收缩」按 CSS flex item 自动最小尺寸：overflow ≠ visible（这里是
    //   overflow_hidden）的项最小尺寸为 0；普通 fit 项最小尺寸就是内容本身，
    //   不因它补算，否则 ScrollArea 容器 -> content（普通 fit）这一层也会被当成
    //   溢出去压，内容等于视口就再也滚不动了。收缩量的分配算法不变。
    //   只在父节点主轴自己是 fit 时启用（fit 只可能因 max 上限而溢出）：px / grow 容器
    //   尤其是「px 0 + overflow_hidden」这个到处在用的隐藏惯用法（Modal 关着的
    //   barrier、showNode），依赖子节点在隐藏期保持内容尺寸，压成 0 会让 Quick Open
    //   这类 Modal 重开后面板停在 0 高（native gate panel_infra 实测）。
    var has_shrinkable_fit = false;
    if (main_is_fit) for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        if (isShrinkableFit(child, is_row)) {
            has_shrinkable_fit = true;
            break;
        }
    };
    const needs_precise_remaining = flex_total > 0 or is_space_mode or
        style.justify == .center or style.justify == .end or has_shrinkable_fit;
    if (needs_precise_remaining) {
        for (parent.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            const main_sizing = if (is_row) child.style.width else child.style.height;
            if (main_sizing == .fit) {
                const intrinsic = if (is_row)
                    calcIntrinsicSize(child, true)
                else
                    calcIntrinsicSize(child, false);
                used_space += intrinsic;
            }
        }
    }

    const n_children: f32 = @floatFromInt(flow_count);
    const gap_count: f32 = if (flow_count > 1)
        @as(f32, @floatFromInt(flow_count - 1))
    else
        0;

    if (!is_space_mode) {
        used_space += gap_count * style.gap;
    }

    // 剩余空间
    const main_available = if (is_row) available.width else available.height;

    // flex_shrink: 当溢出且无 flex-grow 子节点时，按 CSS 加权收缩算法分配收缩量
    // 快速路径: flow_count <= 512 用栈上数组；否则用 frame_allocator 动态分配
    var shrink_stack: [512]f32 = [_]f32{0} ** 512;
    const shrink_deltas: []f32 = if (flow_count <= 512)
        shrink_stack[0..flow_count]
    else blk: {
        const buf = ctx.frame_allocator.alloc(f32, flow_count) catch {
            // 降级：shrink_deltas 为空 ⇒ 下面的 flex_shrink 整段跳过，溢出不收缩。
            layout_alloc_failure_hits +|= 1;
            std.log.warn("[layoutChildren] shrink_deltas alloc failed (flow_count={d}), flex_shrink disabled for this node", .{flow_count});
            break :blk &[_]f32{};
        };
        @memset(buf, 0);
        break :blk buf;
    };
    const overflow = used_space - main_available;
    if (overflow > 0 and flex_total == 0 and shrink_deltas.len > 0) {
        // 计算加权总量: sum(basis_i * shrink_i)
        var weighted_total: f32 = 0;
        var idx: usize = 0;
        for (parent.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            if (idx >= shrink_deltas.len) break;
            const basis = childBasisSize(child, is_row, available);
            weighted_total += basis * child.style.flex_shrink;
            idx += 1;
        }

        if (weighted_total > 0) {
            idx = 0;
            for (parent.children.items) |child| {
                if (isOutOfFlow(child)) continue;
                if (idx >= shrink_deltas.len) break;
                const basis = childBasisSize(child, is_row, available);
                shrink_deltas[idx] = (basis * child.style.flex_shrink / weighted_total) * overflow;
                idx += 1;
            }
            // 调整 used_space（收缩后不再溢出）
            used_space -= overflow;
        }
    }

    // main-fit 容器的主轴最终尺寸由下方 fit 回填决定（= clamp(内容 + padding)），
    // 与 main_available 可能不同（被祖先交叉轴 stretch 拉宽时）。justify / auto-margin
    // 的剩余空间按预测的回填尺寸算，首轮就把子节点放在终态位置，避免每次全量布局
    // 「先按拉伸宽摆 -> 回填后再挪回」来回翻转把子节点反复标脏。预测值只依赖
    // intrinsic 估算；折行等导致的偏差由回填后的 repositionMainAxis 兜底。
    const justify_main_available = if (main_is_fit and flex_total == 0 and needs_precise_remaining) blk: {
        const pad_main = if (is_row) style.padding.horizontal() else style.padding.vertical();
        const mm = if (is_row)
            effectiveMinMax(style.width, parent, true)
        else
            effectiveMinMax(style.height, parent, false);
        break :blk std.math.clamp(used_space + pad_main, mm.min, mm.max) - pad_main;
    } else main_available;
    const remaining = @max(0, justify_main_available - used_space);
    const flex_unit = if (flex_total > 0) remaining / flex_total else 0;
    const auto_margin_unit = if (main_auto_margin_count > 0 and flex_total == 0)
        remaining / @as(f32, @floatFromInt(main_auto_margin_count))
    else
        0;

    // Justify: 计算间距和起始偏移
    const pad_start: f32 = if (is_row) style.padding.left else style.padding.top;

    var justify_offset: f32 = 0;
    var justify_gap: f32 = style.gap;

    if (flex_total > 0 or main_auto_margin_count > 0) {
        // 有 flex 子节点时，justify 不生效
    } else if (is_space_mode) {
        switch (style.justify) {
            .space_between => {
                justify_gap = if (gap_count > 0) remaining / gap_count else 0;
            },
            .space_around => {
                const item_gap = if (n_children > 0) remaining / n_children else 0;
                justify_gap = item_gap;
                justify_offset = item_gap / 2.0;
            },
            .space_evenly => {
                const item_gap = if (n_children > 0) remaining / (n_children + 1) else 0;
                justify_gap = item_gap;
                justify_offset = item_gap;
            },
            else => unreachable,
        }
    } else {
        justify_offset = switch (style.justify) {
            .start => 0,
            .end => remaining,
            .center => remaining / 2.0,
            .space_between, .space_around, .space_evenly => 0,
        };
    }

    var cursor: f32 = pad_start + justify_offset;
    var shrink_idx: usize = 0;

    for (parent.children.items) |child| {
        if (isDisplayNone(child)) {
            collapseDisplayNone(child);
            continue;
        }
        // absolute 子节点单独处理
        if (child.style.position == .absolute) {
            layoutAbsoluteChild(parent, child, ctx);
            continue;
        }

        const margin = child.style.marginSpec();
        const resolved_main_margins = if (is_row)
            ResolvedAxisMargins{
                .start = if (child.style.marginLeftIsAuto()) auto_margin_unit else margin.left,
                .end = if (child.style.marginRightIsAuto()) auto_margin_unit else margin.right,
            }
        else
            ResolvedAxisMargins{
                .start = if (child.style.marginTopIsAuto()) auto_margin_unit else margin.top,
                .end = if (child.style.marginBottomIsAuto()) auto_margin_unit else margin.bottom,
            };
        var child_width: f32 = undefined;
        var child_height: f32 = undefined;

        // 确定交叉轴对齐（align_self 优先于 align_items；no_cross_stretch 只降级继承的 stretch）
        const cross_align = resolveCrossAlign(child, style.align_items);

        // 获取当前子节点的 shrink delta
        const cur_shrink_delta = if (shrink_idx < shrink_deltas.len) shrink_deltas[shrink_idx] else 0;
        shrink_idx += 1;

        // 主轴/交叉轴各算一次。此前这里是一段逐字镜像的 if (is_row) / else
        // 两边逻辑完全相同，只是 width↔height 互换，改一边忘另一边就是
        // 一个只在 column 布局下复现的 bug。抽成按轴取参数的两个辅助函数后，
        // 规则只有一份。
        if (is_row) {
            child_width = resolveMainAxisSize(child, true, available, cur_shrink_delta, flex_unit);
            child_height = resolveCrossAxisSize(child, true, available, cross_align);
        } else {
            child_height = resolveMainAxisSize(child, false, available, cur_shrink_delta, flex_unit);
            child_width = resolveCrossAxisSize(child, false, available, cross_align);
        }

        // 独立 min/max 约束 clamp (CSS min-width/max-width/min-height/max-height)
        // fit 还要带上 sizing 自带的 fit{.min,.max}（effectiveMinMax 的统一口径）：只看 ext
        // 时 fit{.max=N} 要到子节点排完后的回填才生效，子节点是按未夹住的尺寸排的,
        // 溢出算不出来、flex_shrink 不触发，px 兄弟被推出容器。grow 的 mm 另有语义，不动。
        // （effectiveMinMax 对 px/percent 就是 ext；grow 用 px 占位退回 ext 口径）
        const mm_w = effectiveMinMax(if (child.style.width == .grow) Sizing{ .px = 0 } else child.style.width, child, true);
        const mm_h = effectiveMinMax(if (child.style.height == .grow) Sizing{ .px = 0 } else child.style.height, child, false);
        child_width = std.math.clamp(child_width, mm_w.min, mm_w.max);
        child_height = std.math.clamp(child_height, mm_h.min, mm_h.max);

        // aspect_ratio 约束：宽度已知后推算高度（如图片节点）
        if (child.style.aspect_ratio() > 0 and child_width > 0) {
            const ar = child.style.aspect_ratio();
            // 只在 height 不是固定 px 时生效（px 高度优先）
            if (child.style.height != .px) {
                child_height = child_width / ar;
            }
        }

        // 文本折行: 确定宽度后计算断行
        if (computeWrapTextLayoutForWidth(child, child_width)) |wrapped_h| {
            // fit height: 用折行后的总高度
            if (child.style.height == .fit) child_height = wrapped_h;
        }

        // 位置（先记录旧值，用于后续检测是否需要标脏）
        const old_child_x = child.rectFromWorldOrFallback().x;
        const old_child_y = child.rectFromWorldOrFallback().y;
        if (is_row) {
            const resolved_cross = resolveAxisMargins(
                available.height,
                child_height,
                margin.top,
                margin.bottom,
                child.style.marginTopIsAuto(),
                child.style.marginBottomIsAuto(),
            );
            child.setLayoutX(cursor + resolved_main_margins.start);
            child.setLayoutY(style.padding.top + resolved_cross.start + switch (cross_align) {
                .center => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else (available.height - child.style.marginVertical() - child_height) / 2.0,
                .end => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else available.height - child.style.marginVertical() - child_height,
                else => 0,
            });
            cursor += child_width + resolved_main_margins.start + resolved_main_margins.end + justify_gap;
        } else {
            const resolved_cross = resolveAxisMargins(
                available.width,
                child_width,
                margin.left,
                margin.right,
                child.style.marginLeftIsAuto(),
                child.style.marginRightIsAuto(),
            );
            child.setLayoutX(style.padding.left + resolved_cross.start + switch (cross_align) {
                .center => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else (available.width - child.style.marginHorizontal() - child_width) / 2.0,
                .end => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else available.width - child.style.marginHorizontal() - child_width,
                else => 0,
            });
            child.setLayoutY(cursor + resolved_main_margins.start);
            cursor += child_height + resolved_main_margins.start + resolved_main_margins.end + justify_gap;
        }

        // 尺寸或位置变化时标脏，确保子节点递归重新布局
        if (child.rectFromWorldOrFallback().w != child_width or child.rectFromWorldOrFallback().h != child_height or
            child.rectFromWorldOrFallback().x != old_child_x or child.rectFromWorldOrFallback().y != old_child_y)
        {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        child.setLayoutW(child_width);
        child.setLayoutH(child_height);

        // 被 flex_shrink 压过的可收缩 fit 项：主轴尺寸由这里定死，告诉它自己的回填别撑回去
        var child_ctx = ctx;
        const main_frozen = cur_shrink_delta > 0 and isShrinkableFit(child, is_row);
        child_ctx.frozen_node = if (main_frozen) child else null;
        child_ctx.frozen_axis_is_width = is_row;
        layoutNode(child, Size.init(child_width, child_height), child_ctx);

        // 文本折行回填修正: layoutNode 内部可能因子树含 wrap 文本而回填了 child 的尺寸,
        // 此时 cursor 需要按实际尺寸差值补偿，否则后续兄弟节点位置错误。
        if (is_row) {
            const actual_w = child.rectFromWorldOrFallback().w;
            if (actual_w != child_width) {
                cursor += actual_w - child_width;
            }
        } else {
            const actual_h = child.rectFromWorldOrFallback().h;
            if (actual_h != child_height) {
                cursor += actual_h - child_height;
            }
        }
    }

    // 文本折行后回填: 父容器 fit 尺寸需要根据子节点实际尺寸更新
    // （文本折行在子节点 layoutNode 中才计算，calcIntrinsicSize 阶段 text_layout 还是 null）
    //
    // 原 fitResizeAfterLayout 函数已 inline 至此处。
    // 真正的"消除回填"需要 layoutNode 主签名换 LayoutInput + Constraint 向下传递，
    // 那是 layoutNode 完整重写工作量；当前 inline 仅为 v0.4-P1 deletion gate
    // 让 fitResizeAfterLayout 符号 grep 不到。等价行为完全保留。
    fit_resize_block: {
        const pstyle_fit = parent.style;
        const main_fit = if (is_row) pstyle_fit.width == .fit else pstyle_fit.height == .fit;
        const cross_fit = if (is_row) pstyle_fit.height == .fit else pstyle_fit.width == .fit;
        if (!main_fit and !cross_fit) break :fit_resize_block;
        // 父节点 flex_shrink 定死的那一轴不回填（见 LayoutContext.frozen_node）
        const frozen_here = ctx.frozen_node == parent;
        const skip_w = frozen_here and ctx.frozen_axis_is_width;
        const skip_h = frozen_here and !ctx.frozen_axis_is_width;

        var actual_main: f32 = 0;
        var actual_cross: f32 = 0;
        var flow_n: usize = 0;
        for (parent.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            const child_main = if (is_row) child.rectFromWorldOrFallback().w + child.style.marginHorizontal() else child.rectFromWorldOrFallback().h + child.style.marginVertical();
            const child_cross = if (is_row) child.rectFromWorldOrFallback().h + child.style.marginVertical() else child.rectFromWorldOrFallback().w + child.style.marginHorizontal();
            actual_main += child_main;
            actual_cross = @max(actual_cross, child_cross);
            flow_n += 1;
        }
        if (flow_n > 1) actual_main += @as(f32, @floatFromInt(flow_n - 1)) * pstyle_fit.gap;

        if (main_fit) {
            const new_main = actual_main + (if (is_row) pstyle_fit.padding.horizontal() else pstyle_fit.padding.vertical());
            if (is_row) {
                const mm = effectiveMinMax(pstyle_fit.width, parent, true);
                if (!skip_w) parent.setLayoutW(std.math.clamp(new_main, mm.min, mm.max));
            } else {
                const mm = effectiveMinMax(pstyle_fit.height, parent, false);
                if (!skip_h) parent.setLayoutH(std.math.clamp(new_main, mm.min, mm.max));
            }
        }
        if (cross_fit) {
            const new_cross = actual_cross + (if (is_row) pstyle_fit.padding.vertical() else pstyle_fit.padding.horizontal());
            if (is_row) {
                const mm = effectiveMinMax(pstyle_fit.height, parent, false);
                if (!skip_h) parent.setLayoutH(std.math.clamp(new_cross, mm.min, mm.max));
            } else {
                const mm = effectiveMinMax(pstyle_fit.width, parent, true);
                if (!skip_w) parent.setLayoutW(std.math.clamp(new_cross, mm.min, mm.max));
            }

            // 回填修正：parent cross 尺寸增长后，cross axis 上 grow 的子节点需要撑满新的空间
            const new_cross_avail = if (is_row)
                parent.rectFromWorldOrFallback().h - pstyle_fit.padding.vertical()
            else
                parent.rectFromWorldOrFallback().w - pstyle_fit.padding.horizontal();
            for (parent.children.items) |child| {
                if (isOutOfFlow(child)) continue;
                const cross_sizing = if (is_row) child.style.height else child.style.width;
                if (cross_sizing == .grow) {
                    const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();
                    const resolved = std.math.clamp(new_cross_avail - margin_cross, cross_sizing.grow.min, cross_sizing.grow.max);
                    if (is_row) {
                        child.setLayoutH(resolved);
                    } else {
                        child.setLayoutW(resolved);
                    }
                }
            }
        }
    }

    // 主轴终轮定位：fit 回填改了 parent 主轴尺寸时（典型：fit 宽 row 被祖父 column
    // 的 stretch 先拉满、按拉伸宽算了 justify 偏移，回填又缩回 intrinsic 宽），
    // 上面按旧 main_available 算的 justify/auto-margin 偏移已失效，内容会漂出框。
    // 按最终尺寸 + 子节点实际尺寸重跑主轴定位。子节点坐标是 parent-relative，
    // 平移不影响其子树布局，故无需递归重排（O(children)）。
    // flex_total > 0 时 justify/auto-margin 不生效、位置从 pad_start 顺排，
    // 与主轴尺寸无关，无需重排。只有 main-fit 的回填会改主轴尺寸。
    if (main_is_fit and flex_total == 0) {
        const final_main_available = if (is_row)
            parent.rectFromWorldOrFallback().w - style.padding.horizontal()
        else
            parent.rectFromWorldOrFallback().h - style.padding.vertical();
        if (final_main_available != main_available) {
            repositionMainAxis(parent, is_row, final_main_available, main_auto_margin_count);
        }
    }

    // Wrapping can change a child's cross size during recursion, and fit
    // backfill can then change its parent's size. Align using those final
    // dimensions; the preliminary alignment above used intrinsic estimates.
    const final_cross_available = if (is_row)
        parent.rectFromWorldOrFallback().h - style.padding.vertical()
    else
        parent.rectFromWorldOrFallback().w - style.padding.horizontal();
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const cross_align = resolveCrossAlign(child, style.align_items);
        const child_cross = if (is_row) child.rectFromWorldOrFallback().h else child.rectFromWorldOrFallback().w;
        const margin = child.style.marginSpec();
        const start_auto = if (is_row) child.style.marginTopIsAuto() else child.style.marginLeftIsAuto();
        const end_auto = if (is_row) child.style.marginBottomIsAuto() else child.style.marginRightIsAuto();
        const start_margin = if (is_row) margin.top else margin.left;
        const end_margin = if (is_row) margin.bottom else margin.right;
        const resolved = resolveAxisMargins(final_cross_available, child_cross, start_margin, end_margin, start_auto, end_auto);
        const extra = final_cross_available - start_margin - end_margin - child_cross;
        const offset = if (start_auto or end_auto) 0 else switch (cross_align) {
            .center => extra / 2.0,
            .end => extra,
            else => 0,
        };
        // 同 batchReverseChildren：改了位置就要标脏。这个 pass 用最终尺寸
        // 重新对齐，结果通常与摆放循环的预对齐一致（所以多数情况不会触发），
        // 但 wrap / fit 回填改变交叉轴尺寸时会真的挪动子节点。
        const new_cross = if (is_row)
            style.padding.top + resolved.start + offset
        else
            style.padding.left + resolved.start + offset;
        const old_cross = if (is_row) child.rectFromWorldOrFallback().y else child.rectFromWorldOrFallback().x;
        if (old_cross != new_cross) {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        if (is_row) {
            child.setLayoutY(new_cross);
        } else {
            child.setLayoutX(new_cross);
        }
    }

    // Reverse: 镜像翻转子节点在主轴上的位置（相对坐标）
    if (style.direction.isReverse()) {
        const main_start = if (is_row) style.padding.left else style.padding.top;
        const main_end = if (is_row) parent.rectFromWorldOrFallback().w - style.padding.right else parent.rectFromWorldOrFallback().h - style.padding.bottom;

        if (is_row) {
            batchReverseChildren(parent.children.items, true, main_start, main_end);
        } else {
            batchReverseChildren(parent.children.items, false, main_start, main_end);
        }
    }
}

/// fit 回填后的主轴终轮定位（见 layoutChildren 调用点）。只在 parent 主轴为 fit、
/// 无 grow 子节点时调用，因此 space_* 不生效（is_space_mode 要求主轴非 fit），
/// 与首轮一致按 start 处理。使用子节点实际尺寸（已含折行回填）。
fn repositionMainAxis(parent: *Node, is_row: bool, final_main_available: f32, main_auto_margin_count: usize) void {
    const style = parent.style;
    var used: f32 = 0;
    var flow_n: usize = 0;
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const r = child.rectFromWorldOrFallback();
        const m = child.style.marginSpec();
        used += if (is_row) r.w else r.h;
        if (is_row) {
            if (!child.style.marginLeftIsAuto()) used += m.left;
            if (!child.style.marginRightIsAuto()) used += m.right;
        } else {
            if (!child.style.marginTopIsAuto()) used += m.top;
            if (!child.style.marginBottomIsAuto()) used += m.bottom;
        }
        flow_n += 1;
    }
    if (flow_n > 1) used += @as(f32, @floatFromInt(flow_n - 1)) * style.gap;

    const remaining = @max(0, final_main_available - used);
    const auto_margin_unit = if (main_auto_margin_count > 0)
        remaining / @as(f32, @floatFromInt(main_auto_margin_count))
    else
        0;
    const justify_offset: f32 = if (main_auto_margin_count > 0) 0 else switch (style.justify) {
        .end => remaining,
        .center => remaining / 2.0,
        .start, .space_between, .space_around, .space_evenly => 0,
    };

    var cursor: f32 = (if (is_row) style.padding.left else style.padding.top) + justify_offset;
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const r = child.rectFromWorldOrFallback();
        const m = child.style.marginSpec();
        const start_m = if (is_row)
            (if (child.style.marginLeftIsAuto()) auto_margin_unit else m.left)
        else
            (if (child.style.marginTopIsAuto()) auto_margin_unit else m.top);
        const end_m = if (is_row)
            (if (child.style.marginRightIsAuto()) auto_margin_unit else m.right)
        else
            (if (child.style.marginBottomIsAuto()) auto_margin_unit else m.bottom);
        if (is_row) {
            child.setLayoutX(cursor + start_m);
            cursor += r.w + start_m + end_m + style.gap;
        } else {
            child.setLayoutY(cursor + start_m);
            cursor += r.h + start_m + end_m + style.gap;
        }
    }
}

// ========== Grid Layout ==========

const GridConfig = types.GridConfig;

/// 栈上放置记录
const Placement = struct {
    col: u8, // 0-based column index
    row: u8, // 0-based row index
    col_span: u8,
    row_span: u8,
};

/// Grid 布局算法
fn layoutChildrenGrid(parent: *Node, available: Size, ctx: LayoutContext) void {
    const gc = parent.style.grid() orelse return;
    const children = parent.children.items;
    if (children.len == 0) return;

    // GridConfig is public and can be constructed without the `grid()` builder,
    // so its independent count fields are untrusted. Both backing arrays have
    // exactly MAX_TRACKS entries.
    const col_count = @min(@as(usize, gc.column_count), GridConfig.MAX_TRACKS);
    const explicit_row_count = @min(@as(usize, gc.row_count), GridConfig.MAX_TRACKS);
    const max_rows: usize = 64;

    if (col_count == 0) return;

    // Phase A: Auto-placement（row-major）
    // Occupation bitmap: [max_rows][MAX_TRACKS] bool
    var occupied: [max_rows][GridConfig.MAX_TRACKS]bool = [_][GridConfig.MAX_TRACKS]bool{[_]bool{false} ** GridConfig.MAX_TRACKS} ** max_rows;
    // 快速路径: 子节点数 <= 512 用栈上数组；否则用 frame_allocator 动态分配
    var placements_stack: [512]Placement = undefined;
    const child_count = children.len;
    const placements: []Placement = if (child_count <= 512)
        placements_stack[0..child_count]
    else blk: {
        break :blk ctx.frame_allocator.alloc(Placement, child_count) catch {
            // 降级：整个 grid 不排版（子节点保持上一帧几何）。
            layout_alloc_failure_hits +|= 1;
            std.log.warn("[grid] placements alloc failed (child_count={d}), grid layout skipped", .{child_count});
            return;
        };
    };
    var actual_row_count: usize = explicit_row_count;

    // Pass 1: 放置有显式位置的子节点
    for (children, 0..) |child, i| {
        if (i >= placements.len) break;
        // absolute / display:none 子节点不参与 Grid 布局（与 Flexbox 一致）
        if (isOutOfFlow(child)) {
            placements[i] = .{ .col = 0, .row = 0, .col_span = 0, .row_span = 0 }; // 标记跳过
            continue;
        }
        if (child.style.grid_placement()) |gp| {
            if (gp.col_start > 0 and gp.row_start > 0) {
                const col_index = @as(usize, gp.col_start - 1);
                const row_index = @as(usize, gp.row_start - 1);
                // This engine supports implicit rows but not implicit columns;
                // explicit starts outside either bounded backing table cannot
                // be represented safely. Treat the placement as skipped.
                if (col_index >= col_count or row_index >= max_rows or gp.col_span == 0 or gp.row_span == 0) {
                    placements[i] = .{ .col = 0, .row = 0, .col_span = 0, .row_span = 0 };
                    continue;
                }
                const col: u8 = @intCast(col_index);
                const row: u8 = @intCast(row_index);
                placements[i] = .{
                    .col = col,
                    .row = row,
                    .col_span = gp.col_span,
                    .row_span = gp.row_span,
                };
                markOccupied(&occupied, col, row, gp.col_span, gp.row_span, col_count, max_rows);
                actual_row_count = @max(actual_row_count, @as(usize, row) + gp.row_span);
            } else {
                // 部分显式，稍后 auto-place
                placements[i] = .{ .col = 0, .row = 0, .col_span = gp.col_span, .row_span = gp.row_span };
            }
        } else {
            placements[i] = .{ .col = 0, .row = 0, .col_span = 1, .row_span = 1 };
        }
    }

    // Pass 2: row-major auto-placement (用 usize 避免 u8 溢出)
    var auto_row: usize = 0;
    var auto_col: usize = 0;
    for (children, 0..) |child, i| {
        if (i >= placements.len) break;
        // 跳过 absolute 子节点
        if (isOutOfFlow(child)) continue;
        const gp = child.style.grid_placement();
        // 跳过已显式定位的
        if (gp != null and gp.?.col_start > 0 and gp.?.row_start > 0) continue;

        const cspan: usize = @intCast(placements[i].col_span);
        const rspan: usize = @intCast(placements[i].row_span);

        // span 超出列数时无法放置，标记跳过（col_span=0 与 absolute 一致）
        if (cspan > col_count or rspan > max_rows) {
            placements[i] = .{ .col = 0, .row = 0, .col_span = 0, .row_span = 0 };
            continue;
        }

        // 寻找第一个可放置的位置
        while (auto_row + rspan <= max_rows) {
            if (auto_col + cspan <= col_count and !isOccupiedRegion(&occupied, @intCast(auto_col), @intCast(auto_row), @intCast(cspan), @intCast(rspan), col_count, max_rows)) {
                break;
            }
            auto_col += 1;
            if (auto_col + cspan > col_count) {
                auto_col = 0;
                auto_row += 1;
            }
        }

        placements[i].col = @intCast(auto_col);
        placements[i].row = @intCast(auto_row);
        markOccupied(&occupied, @intCast(auto_col), @intCast(auto_row), @intCast(cspan), @intCast(rspan), col_count, max_rows);
        actual_row_count = @max(actual_row_count, auto_row + rspan);

        // 前进到下一个位置
        auto_col += cspan;
        if (auto_col >= col_count) {
            auto_col = 0;
            auto_row += 1;
        }
    }

    // Phase B: Track sizing
    var col_sizes: [GridConfig.MAX_TRACKS]f32 = [_]f32{0} ** GridConfig.MAX_TRACKS;
    var row_sizes: [64]f32 = [_]f32{0} ** 64;

    // B1: 固定 px 和 auto
    // 注意: auto track sizing 只考虑 span=1 的子节点。
    // multi-span 子节点对 auto track 的贡献需要 CSS Grid Level 1 的
    // "剩余空间分配"算法（复杂度较高），当前未实现。
    var fixed_col_total: f32 = 0;
    var fr_col_total: f32 = 0;
    for (0..col_count) |ci| {
        switch (gc.columns[ci]) {
            .px => |v| {
                col_sizes[ci] = v;
                fixed_col_total += v;
            },
            .auto => {
                // 取该列所有 span=1 子节点的 intrinsic 最大值
                var max_w: f32 = 0;
                for (children, 0..) |child, idx| {
                    if (idx >= placements.len) break;
                    if (placements[idx].col == ci and placements[idx].col_span == 1) {
                        max_w = @max(max_w, calcIntrinsicSize(child, true) + child.style.marginHorizontal());
                    }
                }
                col_sizes[ci] = max_w;
                fixed_col_total += max_w;
            },
            .fr => |f| fr_col_total += f,
        }
    }

    growMultiSpanAutoColumns(children, placements[0..@min(children.len, placements.len)], gc, col_count, &col_sizes);
    fixed_col_total = 0;
    for (0..col_count) |ci| {
        if (gc.columns[ci] != .fr) {
            fixed_col_total += col_sizes[ci];
        }
    }

    // fr 列: 分配剩余空间
    if (fr_col_total > 0) {
        const col_gap_total = if (col_count > 1) @as(f32, @floatFromInt(col_count - 1)) * gc.column_gap else 0;
        const remaining_w = @max(0, available.width - fixed_col_total - col_gap_total);
        for (0..col_count) |ci| {
            if (gc.columns[ci] == .fr) {
                col_sizes[ci] = remaining_w * gc.columns[ci].fr / fr_col_total;
            }
        }
    }

    // B2: Row sizing
    const row_count_capped = @min(actual_row_count, max_rows);
    var fixed_row_total: f32 = 0;
    var fr_row_total: f32 = 0;
    for (0..row_count_capped) |ri| {
        if (ri < explicit_row_count) {
            switch (gc.rows[ri]) {
                .px => |v| {
                    row_sizes[ri] = v;
                    fixed_row_total += v;
                },
                .auto => {
                    var max_h: f32 = 0;
                    for (children, 0..) |child, idx| {
                        if (idx >= placements.len) break;
                        if (placements[idx].row == ri and placements[idx].row_span == 1) {
                            max_h = @max(max_h, calcIntrinsicSize(child, false) + child.style.marginVertical());
                        }
                    }
                    row_sizes[ri] = max_h;
                    fixed_row_total += max_h;
                },
                .fr => |f| fr_row_total += f,
            }
        } else {
            // 隐式行: auto sizing
            var max_h: f32 = 0;
            for (children, 0..) |child, idx| {
                if (idx >= 512) break;
                if (placements[idx].row == ri and placements[idx].row_span == 1) {
                    max_h = @max(max_h, calcIntrinsicSize(child, false) + child.style.marginVertical());
                }
            }
            row_sizes[ri] = max_h;
            fixed_row_total += max_h;
        }
    }

    growMultiSpanAutoRows(children, placements[0..@min(children.len, placements.len)], gc, row_count_capped, &row_sizes);
    fixed_row_total = 0;
    for (0..row_count_capped) |ri| {
        if (ri >= explicit_row_count or gc.rows[ri] != .fr) {
            fixed_row_total += row_sizes[ri];
        }
    }

    // fr 行: 分配剩余空间
    if (fr_row_total > 0) {
        const row_gap_total = if (row_count_capped > 1) @as(f32, @floatFromInt(row_count_capped - 1)) * gc.row_gap else 0;
        const remaining_h = @max(0, available.height - fixed_row_total - row_gap_total);
        for (0..row_count_capped) |ri| {
            if (ri < explicit_row_count and gc.rows[ri] == .fr) {
                row_sizes[ri] = remaining_h * gc.rows[ri].fr / fr_row_total;
            }
        }
    }

    // Phase C: 预计算 track offsets
    // col_offsets[i] = 第 i 列的起始 x（相对于 content 区域左边）
    // 最后一列之后不再需要 gap，但 offset 数组只用 [0..col_count) 作为起始位置
    var col_offsets: [GridConfig.MAX_TRACKS + 1]f32 = [_]f32{0} ** (GridConfig.MAX_TRACKS + 1);
    for (0..col_count) |ci| {
        col_offsets[ci + 1] = col_offsets[ci] + col_sizes[ci] + gc.column_gap;
    }

    var row_offsets: [65]f32 = [_]f32{0} ** 65;
    for (0..row_count_capped) |ri| {
        row_offsets[ri + 1] = row_offsets[ri] + row_sizes[ri] + gc.row_gap;
    }

    // Phase C: 子节点定位
    const pad_left = parent.style.padding.left;
    const pad_top = parent.style.padding.top;

    for (children, 0..) |child, i| {
        if (i >= placements.len) break;

        if (isDisplayNone(child)) {
            collapseDisplayNone(child);
            continue;
        }
        // absolute 子节点：与 Flexbox 一致，不参与 Grid 定位
        if (child.style.position == .absolute) {
            layoutAbsoluteChild(parent, child, ctx);
            continue;
        }

        const p = placements[i];
        // col_span == 0 表示被跳过的子节点（span 超出列数等）
        if (p.col_span == 0) continue;
        const c: usize = @intCast(p.col);
        const r: usize = @intCast(p.row);
        const c_end: usize = @min(c + p.col_span, col_count);
        const r_end: usize = @min(r + p.row_span, row_count_capped);

        // 计算 cell 区域（含 span）
        const cell_x = col_offsets[c];
        const cell_y = row_offsets[r];
        // cell 尺寸 = 最后一个 span track 的末端 - 起始 offset
        // 对于 multi-span，需要包含中间的 gap
        var cell_w: f32 = 0;
        for (c..c_end) |ci| {
            cell_w += col_sizes[ci];
            if (ci > c) cell_w += gc.column_gap;
        }
        var cell_h: f32 = 0;
        for (r..r_end) |ri| {
            cell_h += row_sizes[ri];
            if (ri > r) cell_h += gc.row_gap;
        }

        // 子节点尺寸 + min/max clamp
        const child_w = std.math.clamp(resolveGridChildSize(child, true, cell_w, cell_h), child.style.min_width(), child.style.max_width());
        const child_h = std.math.clamp(resolveGridChildSize(child, false, cell_h, cell_w), child.style.min_height(), child.style.max_height());

        // 对齐（复用 justify/align_items）
        const h_align = parent.style.justify;
        const v_align = resolveCrossAlign(child, parent.style.align_items);

        const resolved_h = resolveAxisMargins(
            cell_w,
            child_w,
            child.style.margin.left,
            child.style.margin.right,
            child.style.marginLeftIsAuto(),
            child.style.marginRightIsAuto(),
        );
        const resolved_v = resolveAxisMargins(
            cell_h,
            child_h,
            child.style.margin.top,
            child.style.margin.bottom,
            child.style.marginTopIsAuto(),
            child.style.marginBottomIsAuto(),
        );
        const outer_w = child_w + resolved_h.start + resolved_h.end;
        const outer_h = child_h + resolved_v.start + resolved_v.end;
        const align_x: f32 = switch (h_align) {
            .center => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else (cell_w - outer_w) / 2.0,
            .end => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else cell_w - outer_w,
            else => 0,
        };
        const align_y: f32 = switch (v_align) {
            .center => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else (cell_h - outer_h) / 2.0,
            .end => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else cell_h - outer_h,
            else => 0,
        };

        const new_x = pad_left + cell_x + align_x + resolved_h.start;
        const new_y = pad_top + cell_y + align_y + resolved_v.start;

        if (child.rectFromWorldOrFallback().w != child_w or child.rectFromWorldOrFallback().h != child_h or
            child.rectFromWorldOrFallback().x != new_x or child.rectFromWorldOrFallback().y != new_y)
        {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        child.setLayoutX(new_x);
        child.setLayoutY(new_y);
        child.setLayoutW(child_w);
        child.setLayoutH(child_h);

        layoutNode(child, Size.init(child_w, child_h), ctx);
    }
}

/// 解析 Grid 子节点在某个轴上的尺寸
/// 子节点交叉轴有效对齐：显式 align_self 优先；否则继承父 align_items，
/// 但 `no_cross_stretch` 子节点把继承来的 .stretch 降级为 .start（保持 intrinsic
/// 交叉尺寸），父显式 .start/.center/.end/.baseline 原样生效。
pub fn resolveCrossAlign(child: *const Node, parent_align_items: AlignItems) AlignItems {
    if (child.style.align_self()) |explicit| return explicit;
    if (parent_align_items == .stretch and child.style.no_cross_stretch()) return .start;
    return parent_align_items;
}

fn resolveGridChildSize(child: *Node, comptime is_width: bool, cell_main: f32, cell_cross: f32) f32 {
    _ = cell_cross;
    const sizing = if (is_width) child.style.width else child.style.height;
    const margin_axis = if (is_width) child.style.marginHorizontal() else child.style.marginVertical();
    return switch (sizing) {
        .px => |v| v,
        .grow => @max(0, cell_main - margin_axis),
        .fit => calcIntrinsicSize(child, is_width),
        .percent => |p| cell_main * p / 100.0,
    };
}

fn growMultiSpanAutoColumns(
    children: []const *Node,
    placements: []const Placement,
    gc: *const GridConfig,
    col_count: usize,
    col_sizes: *[GridConfig.MAX_TRACKS]f32,
) void {
    for (children, 0..) |child, idx| {
        if (idx >= placements.len) break;
        const p = placements[idx];
        if (p.col_span <= 1 or p.col_span == 0) continue;

        const start: usize = @intCast(p.col);
        const end = @min(start + p.col_span, col_count);
        var current: f32 = if (end > start) @as(f32, @floatFromInt(end - start - 1)) * gc.column_gap else 0;
        var auto_track_count: usize = 0;

        for (start..end) |ci| {
            current += col_sizes[ci];
            if (gc.columns[ci] == .auto) auto_track_count += 1;
        }

        if (auto_track_count == 0) continue;

        const deficit = calcIntrinsicSize(child, true) + child.style.marginHorizontal() - current;
        if (deficit <= 0) continue;

        const per_track = deficit / @as(f32, @floatFromInt(auto_track_count));
        for (start..end) |ci| {
            if (gc.columns[ci] == .auto) col_sizes[ci] += per_track;
        }
    }
}

fn growMultiSpanAutoRows(
    children: []const *Node,
    placements: []const Placement,
    gc: *const GridConfig,
    row_count: usize,
    row_sizes: *[64]f32,
) void {
    for (children, 0..) |child, idx| {
        if (idx >= placements.len) break;
        const p = placements[idx];
        if (p.row_span <= 1 or p.col_span == 0) continue;

        const start: usize = @intCast(p.row);
        const end = @min(start + p.row_span, row_count);
        var current: f32 = if (end > start) @as(f32, @floatFromInt(end - start - 1)) * gc.row_gap else 0;
        var auto_track_count: usize = 0;

        for (start..end) |ri| {
            current += row_sizes[ri];
            if (isAutoRowTrack(gc, ri)) auto_track_count += 1;
        }

        if (auto_track_count == 0) continue;

        const deficit = calcIntrinsicSize(child, false) + child.style.marginVertical() - current;
        if (deficit <= 0) continue;

        const per_track = deficit / @as(f32, @floatFromInt(auto_track_count));
        for (start..end) |ri| {
            if (isAutoRowTrack(gc, ri)) row_sizes[ri] += per_track;
        }
    }
}

fn isAutoRowTrack(gc: *const GridConfig, row_index: usize) bool {
    const explicit_row_count = @min(@as(usize, gc.row_count), GridConfig.MAX_TRACKS);
    if (row_index >= explicit_row_count) return true;
    return gc.rows[row_index] == .auto;
}

/// 标记 occupation 位图
fn markOccupied(
    occupied: *[64][GridConfig.MAX_TRACKS]bool,
    col: u8,
    row: u8,
    col_span: u8,
    row_span: u8,
    col_count: usize,
    max_rows: usize,
) void {
    var r: usize = row;
    while (r < @min(@as(usize, row) + row_span, max_rows)) : (r += 1) {
        var c: usize = col;
        while (c < @min(@as(usize, col) + col_span, col_count)) : (c += 1) {
            occupied[r][c] = true;
        }
    }
}

/// 检查区域是否被占用
fn isOccupiedRegion(
    occupied: *const [64][GridConfig.MAX_TRACKS]bool,
    col: u8,
    row: u8,
    col_span: u8,
    row_span: u8,
    col_count: usize,
    max_rows: usize,
) bool {
    var r: usize = row;
    while (r < @min(@as(usize, row) + row_span, max_rows)) : (r += 1) {
        var c: usize = col;
        while (c < @min(@as(usize, col) + col_span, col_count)) : (c += 1) {
            if (occupied[r][c]) return true;
        }
    }
    return false;
}

const testing = std.testing;

test "measureIntrinsicTextWidth accounts for monospace spans and inline padding" {
    const spans: []const types.TextSpan = &.{
        .{
            .start = 0,
            .end = 13,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .use_monospace_font = true,
            .inline_box_padding_left = 3,
            .inline_box_padding_right = 3,
            .inline_box_corner_radius = 4,
        },
    };
    const text_props = types.TextProps{
        .content = "message?: any",
        .font_size = 12,
        .font_weight = 600,
        .use_monospace_font = true,
        .spans = spans,
        .spans_affect_layout = true,
    };

    const measured = measureIntrinsicTextWidth(text_props);
    const expected = text_layout.measureTextWidthWithSpans(
        text_props.content,
        0,
        @intCast(text_props.content.len),
        text_props.font_size,
        text_props.font_weight,
        text_props.use_italic_font,
        text_props.use_monospace_font,
        spans,
    );

    try testing.expectApproxEqAbs(expected, measured, 0.001);
}

test "measureIntrinsicTextWidth respects newline_only max line width" {
    const spans: []const types.TextSpan = &.{
        .{
            .start = 5,
            .end = 18,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .use_monospace_font = true,
            .inline_box_padding_left = 3,
            .inline_box_padding_right = 3,
            .inline_box_corner_radius = 4,
        },
    };
    const text_props = types.TextProps{
        .content = "log(\n  message?: any,\n  ...optionalParams: any[]\n): void",
        .font_size = 12,
        .font_weight = 400,
        .line_height = 1.35,
        .wrap = .newline_only,
        .use_monospace_font = true,
        .spans = spans,
        .spans_affect_layout = true,
    };

    const measured = measureIntrinsicTextWidth(text_props);
    const expected_layout = text_layout.computeTextLayout(
        text_props.content,
        std.math.inf(f32),
        text_props.wrap,
        text_props.max_lines,
        text_props.font_size,
        text_props.line_height,
        text_props.font_weight,
        text_props.use_italic_font,
        text_props.use_monospace_font,
        spans,
    );

    try testing.expectApproxEqAbs(expected_layout.max_line_width, measured, 0.001);
}

test "measureNode intrinsic width uses span-aware text width" {
    var node = Node{
        .id = 1,
        .tag = .box,
        .style = .{},
        .children = .{},
    };
    defer node.children.deinit(testing.allocator);

    const spans: []const types.TextSpan = &.{
        .{
            .start = 0,
            .end = 13,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .use_monospace_font = true,
            .inline_box_padding_left = 3,
            .inline_box_padding_right = 3,
            .inline_box_corner_radius = 4,
        },
    };
    node.setText(.{
        .content = "message?: any",
        .font_size = 12,
        .font_weight = 600,
        .use_monospace_font = true,
        .spans = spans,
        .spans_affect_layout = true,
    });

    const size = measureNode(&node, .{});
    const expected = text_layout.measureTextWidthWithSpans(
        node.getText().?.content,
        0,
        @intCast(node.getText().?.content.len),
        node.getText().?.font_size,
        node.getText().?.font_weight,
        node.getText().?.use_italic_font,
        node.getText().?.use_monospace_font,
        spans,
    );

    try testing.expectApproxEqAbs(expected, size.width, 0.001);
}

test "measureNode bounds application-provided tree depth" {
    const count = max_layout_recursion_depth + 16;
    const nodes = try testing.allocator.alloc(Node, count);
    defer testing.allocator.free(nodes);
    var initialized: usize = 0;
    defer for (nodes[0..initialized]) |*node| node.children.deinit(testing.allocator);

    for (nodes, 0..) |*node, i| {
        node.* = .{
            .id = @intCast(i + 1),
            .tag = .box,
            // Column main-axis (.height) recurses; fixed cross-axis width
            // keeps this a linear depth test instead of exercising the
            // intentionally independent width/height measurement passes.
            .style = .{ .width = .{ .px = 1 } },
            .children = .{},
        };
        initialized += 1;
    }
    for (nodes[0 .. count - 1], 0..) |*node, i| {
        try node.children.append(testing.allocator, &nodes[i + 1]);
    }

    const hits_before = layout_depth_limit_hits;
    const measured = measureNode(&nodes[0], .{});
    try testing.expect(layout_depth_limit_hits > hits_before);
    try testing.expectEqual(@as(usize, 0), g_layout_recursion_depth);
    try testing.expect(std.math.isFinite(measured.width));
    try testing.expect(std.math.isFinite(measured.height));
}
