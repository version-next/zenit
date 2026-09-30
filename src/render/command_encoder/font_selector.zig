//! command_encoder/font_selector.zig — 字体档位选择 + lazy derived font 缓存
//!
//! 从 command_encoder.zig 析出（2026-07-31）。FontSelector 与 encoder 之间
//! 零耦合（原文件里对 RenderCommandEncoder 的引用数为 0），只是历史上放在
//! 同一个文件里。外部一直通过 `render.FontSelector` re-export 使用，
//! 析出不改变任何调用方。
//!
//! 职责：按 font_size + font_weight 选最接近的预加载字体档位
//! （regular / bold 各最多 12 档），未命中时 lazy 派生任意字号的精确字体
//! 并缓存。另含等宽 ASCII advance 的小 LRU（8 槽），避免逐字符重复测量。

const std = @import("std");
const text_module = @import("text");
const Font = text_module.Font;
const script_detect = @import("script_detect.zig");

/// 一段文本的完整字体决策结果。
///
/// 渲染早就是「主字体 + 内容相关的 CJK/韩文回退」两件套，测量却只认主字体。
/// 把两者打成一个结构体一起返回，是为了让「测量拿不到回退字体」这件事在
/// 类型层面就不可能发生。
/// 渲染器回答「这段文字会被画成多宽」的回调（见 FontSelector.drawn_width_fn）。
/// 返回 null = 本次答不上来（shape 失败），调用方走 CoreText 兜底。
pub const DrawnWidthFn = *const fn (ctx: *anyopaque, text: []const u8, font: *Font, props: TextFontProps) ?f32;

/// 按族 id + 字号/字重/斜体取 face。返回 null = 该族解析不出来,用默认族。
/// 返回的 `*Font` 由 registry 持有,selector 借用不释放。
pub const FamilyResolveFn = *const fn (ctx: *anyopaque, family: u16, size: f32, weight: u16, italic: bool) ?*Font;

pub const ResolvedFonts = struct {
    /// 主字体（symbols 覆盖 / italic / mono / regular 决策后的结果）
    primary: *Font,
    /// 内容相关回退：文本含汉字/假名/谚文时渲染会改用它画那些字形。
    /// null = 本段文本不需要回退。
    fallback: ?*Font = null,
    /// `fallback` 是不是**按内容**选出来的脚本回退（CJK / 韩文）。
    /// false 表示它只是 italic 面缺字形时的直立兜底 —— 那不是整段的字体。
    fallback_is_script: bool = false,

    /// 整段 shaping / 测量该用的字体 —— 与渲染端 encodeText 交给 shaper 的
    /// 那一个必须完全一致。
    ///
    /// 脚本回退（CJK/韩文）沿用历史行为：整段按回退字体测，与渲染实测对齐
    /// （"asdfasdf磊dfasdfsdfdsf" 曾差 2.38px）。
    /// italic 的直立兜底则**不能**当整段字体：它只是给 italic 面缺的字形补漏，
    /// 拿它测量会让每一段斜体文本按直立宽度收紧，斜体字被 `.fit` 容器裁掉。
    pub fn shapingFont(self: ResolvedFonts) *Font {
        if (self.fallback_is_script) {
            if (self.fallback) |f| return f;
        }
        return self.primary;
    }
};

/// 决定一段文本用什么字体的**全部**输入。
///
/// `content` 是必需的，不是可选优化：渲染端的 CJK/韩文回退是**按内容**选的
/// （selectCjkFallbackFont 读 text 里有没有汉字/假名/谚文）。一个只接受
/// (size, weight, italic, mono) 的测量函数**永远**追不上一个还看字节的
/// 渲染器 —— 这正是"量出来和画出来不一样宽"的结构性根因。
pub const TextFontProps = struct {
    font_size: f32,
    font_weight: u16 = 400,
    /// 字体族 id(render.FontRegistry)。0 = 用本 selector 的默认族槽位。
    /// 非 0 时由 encoder 先向 registry 要 face,要不到再退回槽位决策。
    font_family: u16 = 0,
    use_italic: bool = false,
    use_monospace: bool = false,
    /// Fixed ASCII cell advance used by terminal/code-grid drawing. Zero means
    /// normal glyph advances. It is part of measurement identity even though
    /// it does not affect font selection.
    monospace_char_width: f32 = 0,
    /// 渲染端可以整段改用 symbols_font（Menlo，画箭头/制表符等）。
    use_symbols: bool = false,
    /// 缩放期走 *Stable 变体（避免逐帧换档位导致文字抖动）。
    /// 渲染与测量必须传同一个值，否则两边选到不同 Font 实例。
    force_linear: bool = false,
};

const MonoAsciiAdvanceSlot = struct {
    font_ptr: ?*const Font = null,
    font_size: f32 = 0,
    font_weight: u16 = 0,
    use_italic: bool = false,
    advance: f32 = 0,
    last_used: u32 = 0,
};
var mono_ascii_advance_lru_tick: u32 = 0;

/// 字体选择器 — 根据 font_size + font_weight 选择最接近的字体
/// 支持 regular (weight < 600) 和 bold (weight >= 600) 两组字体
/// 每组最多 12 个预加载档位 + lazy derived font cache（任意字号精确匹配）
pub const FontSelector = struct {
    const exact_size_epsilon: f32 = 0.01;
    pub const weight_miss_capacity = 16;

    small: *Font, // 向后兼容：最小档 (regular)
    medium: *Font, // 向后兼容：中档 (regular)
    large: *Font, // 向后兼容：最大档 (regular)
    /// 扩展字体槽位（可选，用于更精确的字号/字重匹配）
    extra_fonts: [24]?*Font = .{null} ** 24,
    extra_count: u8 = 0,
    /// Bold 字体槽位（weight >= 650）
    bold_fonts: [16]?*Font = .{null} ** 16,
    bold_count: u8 = 0,
    /// 符号字体（用于渲染 list marker 等特殊 Unicode 符号）
    symbols_font: ?*Font = null,
    /// Monospace Regular 字体槽位
    mono_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    mono_count: u8 = 0,
    /// Monospace Bold 字体槽位
    mono_bold_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    mono_bold_count: u8 = 0,
    /// Monospace Italic 字体槽位
    mono_italic_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    mono_italic_count: u8 = 0,
    /// Monospace Bold Italic 字体槽位
    mono_bold_italic_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    mono_bold_italic_count: u8 = 0,
    /// Italic 字体槽位
    italic_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    italic_count: u8 = 0,
    /// Bold Italic 字体槽位
    bold_italic_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    bold_italic_count: u8 = 0,
    /// CJK 回退字体组
    cjk_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    cjk_count: u8 = 0,
    /// CJK Bold 回退字体组
    cjk_bold_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    cjk_bold_count: u8 = 0,
    /// 韩文字体回退组
    korean_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    korean_count: u8 = 0,
    /// 韩文字体 Bold 回退组
    korean_bold_fonts: [12]?*Font = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    korean_bold_count: u8 = 0,

    /// Lazy derived font cache — 按需派生精确字号字体
    /// key: hash(src_font_ptr, group_idx, size_hundredths)
    derived_cache: std.AutoHashMap(u64, *Font) = undefined,
    derived_cache_inited: bool = false,
    /// 按字重加载字体（App 注入：同一字体族 + 目标字重）。未注入时常规组只能派生
    /// 字号、拿不到真字重——600/700 会静默退回常规体（storybook 实测：所有粗体
    /// 标题都是常规体）。加载结果进 derived_cache，随其一起管理生命周期与缩放。
    weight_loader: ?WeightLoader = null,
    /// weight_loader 的**负缓存**：记住「这个 (字重, 字号) 键该族没有」。
    /// 缺字重时 loader 每次都返回 null，没有负缓存就意味着每次选字体（每帧、
    /// 每次测量）都重走一遍 CoreText 查找，native 侧还每次 NSLog。
    /// 定长环形表（满了覆盖最老的一条，被挤掉的键最多再查一次）；与
    /// derived_cache 同生命周期（init/deinit 时清空），并绑定写入时的 loader
    /// 身份 —— 换 loader（换字体族）自动整表失效。
    weight_misses: [weight_miss_capacity]u64 = undefined,
    weight_miss_len: u8 = 0,
    weight_miss_next: u8 = 0,
    weight_miss_loader: ?WeightLoader = null,
    /// allocator 用于 derived_cache 和派生 Font 分配
    allocator: ?std.mem.Allocator = null,

    /// Monospace ASCII advance cache —— 缓存 (font, font_size, font_weight, italic) 对应
    /// 的字符宽度。等宽 ASCII 文本场景下 CoreText 测量是渲染的最大热路径之一：典型代码场景
    /// 每帧可达 600+ 次 measureMonospaceTextWidth 调用，全部走 CoreText FFI。
    /// 由于这类场景通常只用一种 monospace 字体 + 少量 size/weight 组合，8-slot LRU
    /// 就能 100% 命中。命中后 ASCII-only 字符串走 len * advance 算术，完全跳过 CoreText 调用。
    ascii_advance_cache: [8]MonoAsciiAdvanceSlot = [_]MonoAsciiAdvanceSlot{.{}} ** 8,

    /// 「这段文字会被画成多宽」的权威回答者 —— 由 RenderCommandEncoder.setFonts
    /// 装上，指向该 renderer 的 TextRenderer.measureTextWidthAsDrawn。
    /// 没装时（裸 FontSelector / 单测）退回 CoreText 的整串排版宽度，那只是兜底：
    /// 见 measureTextWidthWithProps 的注释。
    drawn_width_fn: ?DrawnWidthFn = null,
    drawn_width_ctx: ?*anyopaque = null,

    /// 字体族解析钩子(render.FontRegistry)。装上后 `props.font_family != 0`
    /// 的文本会先向它要 face,要不到才退回下面的槽位决策。
    ///
    /// ⚠ 必须挂在 **FontSelector** 上而不是 encodeText 里 —— resolveFonts 是
    /// 测量与渲染**共用**的唯一入口,在调用点补 if 就会让量的和画的不是同一个
    /// 字体(本文件上方注释记的就是这个教训)。
    family_resolve_fn: ?FamilyResolveFn = null,
    family_resolve_ctx: ?*anyopaque = null,

    /// 显式字体回退栈模式。应用把 FontFallbackStack 接到 TextRenderer
    /// （setFallbackStack）后置 true。语义变化只有一处：内容相关的脚本回退
    /// （CJK/韩文）不再由本 selector 按**整段内容**挑一个回退字体，而是由
    /// 渲染器在 shaping 前**按码点**在栈内显式选（TextRenderer.
    /// selectSegmentFont —— draw 与 measureTextWidthAsDrawn 共用）。
    /// 于是 resolveFonts 的 fallback 恒为 null（脚本场景）、shapingFont()
    /// 恒为 primary：测量与渲染都按「主字体 + 栈内逐段显式回退」同一套
    /// 决策走。italic 直立兜底与脚本无关，保持原样。
    /// ⚠ 两个开关必须成对：只开 stack_mode 不接栈 = CJK 直接交级联
    /// （行为等同回退被删）；只接栈不开 stack_mode = 测量端仍整段换字体，
    /// 量的和画的又不是一个字体。
    stack_mode: bool = false,

    /// 查找/计算单个字符的 ASCII advance（仅用于 monospace 字体 + ASCII 字符串）。
    /// 返回 0 表示该 font/size/weight 不可缓存（罕见路径）。
    inline fn lookupOrInsertAsciiAdvance(
        self: *FontSelector,
        font: *Font,
        font_size: f32,
        font_weight: u16,
        use_italic: bool,
    ) f32 {
        mono_ascii_advance_lru_tick +%= 1;
        const tick = mono_ascii_advance_lru_tick;
        var lru_idx: usize = 0;
        var lru_tick: u32 = std.math.maxInt(u32);
        for (&self.ascii_advance_cache, 0..) |*slot, i| {
            if (slot.font_ptr == font and
                slot.font_size == font_size and
                slot.font_weight == font_weight and
                slot.use_italic == use_italic)
            {
                slot.last_used = tick;
                return slot.advance;
            }
            if (slot.last_used <= lru_tick) {
                lru_tick = slot.last_used;
                lru_idx = i;
            }
        }
        // 未命中：测一次 "M" 的宽度作为 cell width，并自检字体确实是严格 monospace。
        const text_scale = font_size / font.pixelSize();
        const m_width = font.measureWidth("M") * text_scale;
        if (m_width <= 0) return 0;
        // 自检：测 "MMiM " 5 字符。真等宽字体里它必须等于 5 * m_width。
        // 如果字体被错配（如 fallback 到 proportional），i / space 的 advance 会
        // 偏离 M，我们必须 return 0 让上层走 CoreText 全量测量。
        // 选 "MMiM " 这种组合是为了同时覆盖 cap letter / lowercase / space 这三种最容易
        // 偏窄的 glyph —— 真等宽字体不应该让它们偏离同一 cell。
        const probe_width = font.measureWidth("MMiM ") * text_scale;
        const expected = m_width * 5.0;
        const epsilon: f32 = 0.5; // 半个像素的容差，避免子像素 rounding 误判
        if (@abs(probe_width - expected) > epsilon) {
            // 字体实际不是严格 monospace —— 不缓存，让上层每次走 CoreText
            return 0;
        }
        self.ascii_advance_cache[lru_idx] = .{
            .font_ptr = font,
            .font_size = font_size,
            .font_weight = font_weight,
            .use_italic = use_italic,
            .advance = m_width,
            .last_used = tick,
        };
        return m_width;
    }

    inline fn isAllAscii(text: []const u8) bool {
        for (text) |b| {
            if (b >= 0x80) return false;
        }
        return true;
    }

    /// 初始化 lazy cache（setFonts 之后调用）
    pub fn initDerivedCache(self: *FontSelector, allocator: std.mem.Allocator) void {
        if (self.derived_cache_inited) return;
        self.allocator = allocator;
        self.derived_cache = std.AutoHashMap(u64, *Font).init(allocator);
        self.derived_cache_inited = true;
        self.clearWeightMisses();
    }

    /// HiDPI：把新的 backing scale 传播给 derived cache 里所有已派生字体。
    ///
    /// 为什么必须单独做一遍：`Font.derive` 只在**创建那一刻**拷贝
    /// `scale_factor`，而派生字体会一直留在 cache 里被复用。窗口移到另一块
    /// DPI 不同的屏幕后，只更新 `app.fonts` 三个基准字体是不够的 —— 任何
    /// 非标准字号走的都是 derived font，它们会永远停在旧 scale 上，表现为
    /// "大部分文字变清晰了，但某些字号依旧糊/错位"。
    ///
    /// 不清空 cache 而是就地改 scale：派生字体的 cache 键是 (src_ptr, 字号)，
    /// 与 scale 无关，就地更新即可；真正按 scale 分桶的是下游 glyph atlas 的
    /// GlyphKey.scale_q，那里会自然产生新条目。清空反而会白白丢掉 CoreText
    /// 字体对象、下一帧再全部重建。
    pub fn setScaleFactor(self: *FontSelector, scale: f32) void {
        self.small.setScaleFactor(scale);
        self.medium.setScaleFactor(scale);
        self.large.setScaleFactor(scale);
        if (self.symbols_font) |f| f.setScaleFactor(scale);

        const groups = [_][]const ?*Font{
            &self.extra_fonts,
            &self.bold_fonts,
            &self.mono_fonts,
            &self.mono_bold_fonts,
            &self.mono_italic_fonts,
            &self.mono_bold_italic_fonts,
            &self.italic_fonts,
            &self.bold_italic_fonts,
            &self.cjk_fonts,
            &self.cjk_bold_fonts,
            &self.korean_fonts,
            &self.korean_bold_fonts,
        };
        for (groups) |group| {
            for (group) |maybe_font| {
                if (maybe_font) |f| f.setScaleFactor(scale);
            }
        }

        if (!self.derived_cache_inited) return;
        var it = self.derived_cache.valueIterator();
        while (it.next()) |font_ptr| {
            font_ptr.*.setScaleFactor(scale);
        }
    }

    pub const WeightLoader = struct {
        context: *anyopaque,
        load: *const fn (context: *anyopaque, font_size: f32, font_weight: u16) ?*Font,
    };

    /// CSS 字重取整到 100 的整数倍（590 → 600，650 → 700）。
    pub fn quantizeWeight(w: u16) u16 {
        const clamped = std.math.clamp(w, 100, 900);
        return @intCast(((@as(u32, clamped) + 50) / 100) * 100);
    }

    /// 取指定字号 + 字重的字体（经 weight_loader，按 (字重, 字号) 缓存）。
    fn loadWeightedCached(self: *FontSelector, font_size: f32, weight: u16) ?*Font {
        if (!self.derived_cache_inited) return null;
        const loader = self.weight_loader orelse return null;
        const target_size = @max(font_size, 1.0);
        const size_hundredths: u32 = @intFromFloat(@round(target_size * 100));
        // seed 高位打上字重标记，与 (src_ptr, group) 派生键空间不相交。
        const seed: u64 = (@as(u64, 0xF0) << 56) | @as(u64, weight);
        const key = std.hash.Wyhash.hash(seed, std.mem.asBytes(&size_hundredths));
        if (self.derived_cache.get(key)) |cached| return cached;
        if (self.isWeightMiss(loader, key)) return null;
        const font = loader.load(loader.context, target_size, weight) orelse {
            self.recordWeightMiss(loader, key);
            return null;
        };
        font.setScaleFactor(self.small.scale_factor);
        self.derived_cache.put(key, font) catch {
            font.deinit();
            return null;
        };
        return font;
    }

    fn sameLoader(a: WeightLoader, b: WeightLoader) bool {
        return a.context == b.context and a.load == b.load;
    }

    fn clearWeightMisses(self: *FontSelector) void {
        self.weight_miss_len = 0;
        self.weight_miss_next = 0;
        self.weight_miss_loader = null;
    }

    fn isWeightMiss(self: *FontSelector, loader: WeightLoader, key: u64) bool {
        const owner = self.weight_miss_loader orelse return false;
        if (!sameLoader(owner, loader)) {
            // loader 换了（换字体族）：旧的「没有」不再成立。
            self.clearWeightMisses();
            return false;
        }
        return std.mem.indexOfScalar(u64, self.weight_misses[0..self.weight_miss_len], key) != null;
    }

    fn recordWeightMiss(self: *FontSelector, loader: WeightLoader, key: u64) void {
        if (self.weight_miss_loader) |owner| {
            if (!sameLoader(owner, loader)) self.clearWeightMisses();
        }
        self.weight_miss_loader = loader;
        self.weight_misses[self.weight_miss_next] = key;
        self.weight_miss_next = @intCast((@as(usize, self.weight_miss_next) + 1) % weight_miss_capacity);
        if (self.weight_miss_len < weight_miss_capacity) self.weight_miss_len += 1;
    }

    /// 释放 derived cache 中所有动态创建的字体
    pub fn deinitDerivedCache(self: *FontSelector) void {
        if (!self.derived_cache_inited) return;
        var it = self.derived_cache.valueIterator();
        while (it.next()) |font_ptr| {
            font_ptr.*.deinit();
        }
        self.derived_cache.deinit();
        self.derived_cache_inited = false;
        self.clearWeightMisses();
    }

    pub fn select(self: *FontSelector, font_size: f32) *Font {
        return self.selectWeighted(font_size, 400);
    }

    /// 根据 font_size 和 font_weight 选择最佳字体
    /// 若无精确匹配（超过 epsilon）且已初始化 lazy cache，则派生精确字号
    pub fn selectWeighted(self: *FontSelector, font_size: f32, font_weight: u16) *Font {
        if (font_weight >= 650 and self.bold_count > 0) {
            return self.selectOrDerive(&self.bold_fonts, self.bold_count, font_size, 1, font_weight);
        }
        return self.selectOrDeriveRegular(font_size, font_weight);
    }

    /// 使用预加载字体测量文本宽度（与渲染一致）
    /// **唯一**的字体决策点 —— 渲染与测量都必须走它。
    ///
    /// == 为什么必须统一（这是本项目反复复发的一整类 bug 的根）==
    /// 历史上渲染端（command_encoder.drawText）和测量端（measureTextWidth）
    /// 各写了一套选字体的分支，于是同一段文字「量出来」和「画出来」用的
    /// 不是一个字体，宽度自然对不上：光标短在字形里侧、选区高亮不到行尾。
    /// 每次只修宽度函数都只堵住一个洞，因为**分岔在字体选择，不在测量算法**。
    /// 三处已知分岔，全部由本函数收口：
    ///   1. use_symbols —— 渲染可整段改用 symbols_font(Menlo)，测量端原先没有这个分支
    ///   2. CJK/韩文回退 —— 渲染**按内容**选回退字体，测量端原先完全内容盲。
    ///      实测 "asdfasdf磊dfasdfsdfdsf" 测量(Inter)=155.894、
    ///      渲染(PingFang 回退)=153.514，差 2.38px ≈ 用户看到的"短一个字"
    ///   3. force_linear —— 缩放期走 *Stable 变体，两边不一致会选到不同实例
    ///
    /// 加新的字体决策规则时**只改这里**；任何在调用点补 if 的做法都会
    /// 立刻重新制造上面那类静默错位。
    pub fn resolveFonts(self: *FontSelector, content: []const u8, props: TextFontProps) ResolvedFonts {
        const fs = props.font_size;
        const fw = props.font_weight;

        // 字体族覆写：显式指定了族就用族里的 face。
        // symbols 优先级更高(list marker 等必须用符号字体画),mono 亦然
        // —— 这两档是**语义**要求,不是用户的字体偏好。
        if (props.font_family != 0 and !props.use_symbols and !props.use_monospace) {
            if (self.family_resolve_fn) |resolve| {
                if (self.family_resolve_ctx) |ctx| {
                    if (resolve(ctx, props.font_family, fs, fw, props.use_italic)) |f| {
                        // 脚本回退仍走原逻辑：用户选的族未必覆盖 CJK。
                        const fb = self.resolveContentFallback(content, props, f, f);
                        return .{
                            .primary = f,
                            .fallback = fb.font,
                            .fallback_is_script = fb.is_script,
                        };
                    }
                }
            }
        }

        const regular_font = if (props.use_monospace)
            (if (props.force_linear)
                self.selectMonospaceWeightedStable(fs, fw, props.use_italic)
            else
                self.selectMonospaceWeighted(fs, fw, props.use_italic))
        else if (props.force_linear)
            self.selectWeightedStable(fs, fw)
        else
            self.selectWeighted(fs, fw);

        const primary = if (props.use_symbols and self.symbols_font != null)
            self.symbols_font.?
        else if (props.use_monospace)
            regular_font
        else if (props.use_italic and fw >= 650 and self.bold_italic_count > 0)
            (if (props.force_linear)
                self.selectStableFromGroup(&self.bold_italic_fonts, self.bold_italic_count, fs, fw)
            else
                self.selectOrDerive(&self.bold_italic_fonts, self.bold_italic_count, fs, 3, fw))
        else if (props.use_italic and self.italic_count > 0)
            (if (props.force_linear)
                self.selectStableFromGroup(&self.italic_fonts, self.italic_count, fs, fw)
            else
                self.selectOrDerive(&self.italic_fonts, self.italic_count, fs, 2, fw))
        else
            regular_font;

        const content_fallback = self.resolveContentFallback(content, props, primary, regular_font);
        return .{
            .primary = primary,
            .fallback = content_fallback.font,
            .fallback_is_script = content_fallback.is_script,
        };
    }

    /// resolveContentFallback 的返回：回退字体本身 + 它是不是脚本回退。
    /// 两者必须一起传出去，否则调用方无从分辨「整段换字体」与「补个别字形」。
    const ContentFallback = struct {
        font: ?*Font = null,
        is_script: bool = false,
    };

    /// 内容相关回退（汉字/假名 → CJK 族，谚文 → 韩文族）。
    /// 与 command_encoder.selectCjkFallbackFont 是同一套判定，收口到这里。
    fn resolveContentFallback(
        self: *FontSelector,
        content: []const u8,
        props: TextFontProps,
        primary: *Font,
        regular_font: *Font,
    ) ContentFallback {
        const fs = props.font_size;
        const fw = props.font_weight;
        // stack_mode：脚本回退让位给显式字体栈（见字段注释），只保留
        // 与脚本无关的 italic 直立兜底。
        if (self.stack_mode) {
            if (props.use_italic and primary != regular_font) return .{ .font = regular_font };
            return .{};
        }
        if (script_detect.preferKoreanFallback(content)) {
            if (fw >= 650 and self.korean_bold_count > 0) {
                return .{ .is_script = true, .font = if (props.force_linear)
                    self.selectStableFromGroup(&self.korean_bold_fonts, self.korean_bold_count, fs, fw)
                else
                    self.selectFromGroup(&self.korean_bold_fonts, self.korean_bold_count, fs) };
            }
            if (self.korean_count > 0) {
                return .{ .is_script = true, .font = if (props.force_linear)
                    self.selectStableFromGroup(&self.korean_fonts, self.korean_count, fs, fw)
                else
                    self.selectFromGroup(&self.korean_fonts, self.korean_count, fs) };
            }
        }
        if (script_detect.preferCjkFallback(content)) {
            if (fw >= 650 and self.cjk_bold_count > 0) {
                return .{ .is_script = true, .font = if (props.force_linear)
                    self.selectStableFromGroup(&self.cjk_bold_fonts, self.cjk_bold_count, fs, fw)
                else
                    self.selectFromGroup(&self.cjk_bold_fonts, self.cjk_bold_count, fs) };
            }
            if (self.cjk_count > 0) {
                return .{ .is_script = true, .font = if (props.force_linear)
                    self.selectStableFromGroup(&self.cjk_fonts, self.cjk_count, fs, fw)
                else
                    self.selectFromGroup(&self.cjk_fonts, self.cjk_count, fs) };
            }
        }
        // italic 面缺字形时的直立兜底 —— 逐字形补漏，**不是**整段字体。
        if (props.use_italic and primary != regular_font) return .{ .font = regular_font };
        return .{};
    }

    /// 保留旧签名给「确实拿不到 content」的调用点（GlyphRun shape 管线在
    /// 拿到文本前就要选字体）。内部转发到 resolveFonts，传空 content ——
    /// 也就是**没有**内容相关回退。新代码请优先用 resolveFonts。
    pub fn selectForMeasure(self: *FontSelector, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) *Font {
        return self.resolveFonts("", .{
            .font_size = font_size,
            .font_weight = font_weight,
            .use_italic = use_italic,
            .use_monospace = use_monospace,
        }).primary;
    }

    /// 测量一段文本 —— 与渲染同源选字体（含内容相关 CJK/韩文回退）。
    ///
    /// 回退字体存在时按 CoreText 的 cascade 语义测：把主字体作为 base、
    /// 回退字体作为 fallback 交给同一个 shaper。这里的实现直接用回退字体
    /// 测整段 —— 与 text_renderer 在 cjk_fallback 非空时的行为一致
    /// （见 drawTextWithOptions 的 fallback 参数）。
    pub fn measureTextWidth(self: *FontSelector, text: []const u8, font_size: f32, font_weight: u16, use_italic: bool) f32 {
        if (text.len == 0) return 0;
        return self.measureTextWidthWithProps(text, .{
            .font_size = font_size,
            .font_weight = font_weight,
            .use_italic = use_italic,
        });
    }

    pub fn setDrawnWidthSource(self: *FontSelector, f: ?DrawnWidthFn, ctx: ?*anyopaque) void {
        self.drawn_width_fn = f;
        self.drawn_width_ctx = ctx;
    }

    /// == 为什么优先问渲染器，而不是 CoreText ==
    /// `.fit` 容器的宽度 = 先测一次、再画一次。两次不一致，容器就按 A 收紧、
    /// 字按 B 画，尾巴被裁。而「画成多宽」不是 (文本, 字号) 的纯函数：渲染端
    /// 按 segmentText 逐段 shape（CJK 逐码点、ASCII 成词，跨段没有 kerning），
    /// 再逐 glyph 累加 x_advance * scale。CoreText 的
    /// CTLineGetTypographicBounds measure 的是**整串一次排版**的宽度 ——
    /// 它在排版学上更"对"，但那不是我们要的：我们要的是**和 GPU 实际画出来
    /// 的那一版完全相同**的数。两者对纯 ASCII 常常巧合地接近，于是这类错位
    /// 长期只在长串/斜体/CJK 混排上零星冒头，很难归因。
    ///
    /// 所以这里不再自己算，而是把问题转给渲染器 emit 循环的不 emit 版本。
    pub fn measureTextWidthWithProps(self: *FontSelector, text: []const u8, props: TextFontProps) f32 {
        if (text.len == 0) return 0;
        const font = self.resolveFonts(text, props).shapingFont();
        if (self.drawn_width_fn) |drawn| {
            if (self.drawn_width_ctx) |ctx| {
                if (drawn(ctx, text, font, props)) |w| return w;
            }
        }
        const fixed_advance = script_detect.fixedMonospaceAdvance(text, props.use_monospace, props.monospace_char_width);
        if (fixed_advance > 0) return @as(f32, @floatFromInt(text.len)) * fixed_advance;
        const text_scale = props.font_size / font.pixelSize();
        return font.measureWidth(text) * text_scale;
    }

    /// Monospace 文本测量（等宽字体专用快速路径）
    ///
    /// 快速路径：纯 ASCII 字符串 → len * cached_advance（O(1) 加 O(N) 扫描判 ASCII，
    /// 完全跳过 CoreText FFI）。Non-ASCII 字符串走原始 CoreText 测量。
    pub fn measureMonospaceTextWidth(self: *FontSelector, text: []const u8, font_size: f32, font_weight: u16, use_italic: bool) f32 {
        if (text.len == 0) return 0;
        const font = self.selectMonospaceWeighted(font_size, font_weight, use_italic);
        if (isAllAscii(text)) {
            const advance = self.lookupOrInsertAsciiAdvance(font, font_size, font_weight, use_italic);
            if (advance > 0) {
                return @as(f32, @floatFromInt(text.len)) * advance;
            }
        }
        const text_scale = font_size / font.pixelSize();
        return font.measureWidth(text) * text_scale;
    }

    /// monospace 字体选择（若未注册 monospace 组则回退到常规选择）
    pub fn selectMonospaceWeighted(self: *FontSelector, font_size: f32, font_weight: u16, use_italic: bool) *Font {
        if (use_italic and font_weight >= 650 and self.mono_bold_italic_count > 0) {
            return self.selectOrDerive(&self.mono_bold_italic_fonts, self.mono_bold_italic_count, font_size, 3, font_weight);
        }
        if (use_italic and self.mono_italic_count > 0) {
            return self.selectOrDerive(&self.mono_italic_fonts, self.mono_italic_count, font_size, 2, font_weight);
        }
        if (font_weight >= 650 and self.mono_bold_count > 0) {
            return self.selectOrDerive(&self.mono_bold_fonts, self.mono_bold_count, font_size, 1, font_weight);
        }
        if (self.mono_count > 0) {
            return self.selectOrDerive(&self.mono_fonts, self.mono_count, font_size, 0, font_weight);
        }
        return self.selectWeighted(font_size, font_weight);
    }

    /// 从指定字体组中按 font_size 选择最佳匹配（含 lazy derive）
    pub fn selectFromGroup(self: *FontSelector, group: []const ?*Font, count: u8, font_size: f32) *Font {
        return self.selectOrDerive(group, count, font_size, 0, null);
    }

    // ===== 内部方法 =====

    inline fn weightDelta(font_weight: u16, desired_weight: ?u16) u16 {
        const dw = desired_weight orelse return 0;
        return if (font_weight >= dw) font_weight - dw else dw - font_weight;
    }

    inline fn betterCandidate(weight_diff: u16, size_diff: f32, best_weight_diff: u16, best_size_diff: f32) bool {
        return weight_diff < best_weight_diff or (weight_diff == best_weight_diff and size_diff < best_size_diff);
    }

    inline fn betterStableCandidate(
        candidate_weight_diff: u16,
        candidate_font_px: f32,
        best_weight_diff: u16,
        best_font_px: f32,
        target: f32,
    ) bool {
        if (candidate_weight_diff != best_weight_diff) return candidate_weight_diff < best_weight_diff;

        const candidate_oversample = candidate_font_px >= target;
        const best_oversample = best_font_px >= target;
        if (candidate_oversample != best_oversample) return candidate_oversample;

        const candidate_size_diff = @abs(candidate_font_px - target);
        const best_size_diff = @abs(best_font_px - target);
        if (!std.math.approxEqAbs(f32, candidate_size_diff, best_size_diff, 0.0001)) {
            return candidate_size_diff < best_size_diff;
        }
        return candidate_font_px > best_font_px;
    }

    /// regular 组 + .small/.medium/.large 三个基础槽一起参与最近匹配
    fn selectOrDeriveRegular(self: *FontSelector, font_size: f32, desired_weight: u16) *Font {
        // 预载组里没有这个字重：按字重加载真字形（而不是拿常规体顶替）。
        const want_weight = quantizeWeight(desired_weight);
        if (weightDelta(self.medium.weight, want_weight) >= 100) {
            if (self.loadWeightedCached(font_size, want_weight)) |f| return f;
        }
        const target = font_size;
        var best = self.small;
        var best_size_diff = @abs(self.small.pixelSize() - target);
        var best_weight_diff = weightDelta(self.small.weight, desired_weight);

        const diff_m = @abs(self.medium.pixelSize() - target);
        const weight_diff_m = weightDelta(self.medium.weight, desired_weight);
        if (betterCandidate(weight_diff_m, diff_m, best_weight_diff, best_size_diff)) {
            best = self.medium;
            best_size_diff = diff_m;
            best_weight_diff = weight_diff_m;
        }

        const diff_l = @abs(self.large.pixelSize() - target);
        const weight_diff_l = weightDelta(self.large.weight, desired_weight);
        if (betterCandidate(weight_diff_l, diff_l, best_weight_diff, best_size_diff)) {
            best = self.large;
            best_size_diff = diff_l;
            best_weight_diff = weight_diff_l;
        }

        for (self.extra_fonts[0..self.extra_count]) |maybe_font| {
            if (maybe_font) |font| {
                const size_diff = @abs(font.pixelSize() - target);
                const weight_diff = weightDelta(font.weight, desired_weight);
                if (betterCandidate(weight_diff, size_diff, best_weight_diff, best_size_diff)) {
                    best = font;
                    best_size_diff = size_diff;
                    best_weight_diff = weight_diff;
                }
            }
        }

        // 接近精确匹配直接复用，避免不必要派生。
        if (best_size_diff <= exact_size_epsilon) return best;
        return self.deriveFontCached(best, font_size, 0) orelse best;
    }

    fn selectStableRegular(self: *FontSelector, font_size: f32, desired_weight: u16) *Font {
        const want_weight = quantizeWeight(desired_weight);
        if (weightDelta(self.medium.weight, want_weight) >= 100) {
            // 稳定路径（缩放动画期间）不派生任意字号：按最近的预载字号加载该字重。
            const presets = [_]f32{ self.small.pixelSize(), self.medium.pixelSize(), self.large.pixelSize() };
            var nearest = presets[0];
            for (presets[1..]) |p| {
                if (@abs(p - font_size) < @abs(nearest - font_size)) nearest = p;
            }
            if (self.loadWeightedCached(nearest, want_weight)) |f| return f;
        }
        const target = font_size;
        var best = self.small;
        var best_font_px = self.small.pixelSize();
        var best_weight_diff = weightDelta(self.small.weight, desired_weight);

        const medium_px = self.medium.pixelSize();
        const medium_weight_diff = weightDelta(self.medium.weight, desired_weight);
        if (betterStableCandidate(medium_weight_diff, medium_px, best_weight_diff, best_font_px, target)) {
            best = self.medium;
            best_font_px = medium_px;
            best_weight_diff = medium_weight_diff;
        }

        const large_px = self.large.pixelSize();
        const large_weight_diff = weightDelta(self.large.weight, desired_weight);
        if (betterStableCandidate(large_weight_diff, large_px, best_weight_diff, best_font_px, target)) {
            best = self.large;
            best_font_px = large_px;
            best_weight_diff = large_weight_diff;
        }

        for (self.extra_fonts[0..self.extra_count]) |maybe_font| {
            if (maybe_font) |font| {
                const font_px = font.pixelSize();
                const weight_diff = weightDelta(font.weight, desired_weight);
                if (betterStableCandidate(weight_diff, font_px, best_weight_diff, best_font_px, target)) {
                    best = font;
                    best_font_px = font_px;
                    best_weight_diff = weight_diff;
                }
            }
        }
        return best;
    }

    /// 从任意字体组中找最近匹配，若未命中精确字号则 lazy derive
    fn selectOrDerive(
        self: *FontSelector,
        group: []const ?*Font,
        count: u8,
        font_size: f32,
        group_idx: u4,
        desired_weight: ?u16,
    ) *Font {
        var best: ?*Font = null;
        var best_size_diff: f32 = std.math.inf(f32);
        var best_weight_diff: u16 = std.math.maxInt(u16);
        for (group[0..count]) |maybe_font| {
            if (maybe_font) |font| {
                const size_diff = @abs(font.pixelSize() - font_size);
                const weight_diff = weightDelta(font.weight, desired_weight);
                if (best == null or betterCandidate(weight_diff, size_diff, best_weight_diff, best_size_diff)) {
                    best = font;
                    best_size_diff = size_diff;
                    best_weight_diff = weight_diff;
                }
            }
        }
        const b = best orelse return self.selectWeighted(font_size, desired_weight orelse 400);
        if (best_size_diff <= exact_size_epsilon) return b;
        return self.deriveFontCached(b, font_size, group_idx) orelse b;
    }

    pub fn selectStableFromGroup(
        self: *FontSelector,
        group: []const ?*Font,
        count: u8,
        font_size: f32,
        desired_weight: ?u16,
    ) *Font {
        var best: ?*Font = null;
        var best_font_px: f32 = 0;
        var best_weight_diff: u16 = std.math.maxInt(u16);
        for (group[0..count]) |maybe_font| {
            if (maybe_font) |font| {
                const font_px = font.pixelSize();
                const weight_diff = weightDelta(font.weight, desired_weight);
                if (best == null or betterStableCandidate(weight_diff, font_px, best_weight_diff, best_font_px, font_size)) {
                    best = font;
                    best_font_px = font_px;
                    best_weight_diff = weight_diff;
                }
            }
        }
        return best orelse self.selectWeightedStable(font_size, desired_weight orelse 400);
    }

    pub fn selectWeightedStable(self: *FontSelector, font_size: f32, font_weight: u16) *Font {
        if (font_weight >= 650 and self.bold_count > 0) {
            return self.selectStableFromGroup(&self.bold_fonts, self.bold_count, font_size, font_weight);
        }
        return self.selectStableRegular(font_size, font_weight);
    }

    pub fn selectMonospaceWeightedStable(self: *FontSelector, font_size: f32, font_weight: u16, use_italic: bool) *Font {
        if (use_italic and font_weight >= 650 and self.mono_bold_italic_count > 0) {
            return self.selectStableFromGroup(&self.mono_bold_italic_fonts, self.mono_bold_italic_count, font_size, font_weight);
        }
        if (use_italic and self.mono_italic_count > 0) {
            return self.selectStableFromGroup(&self.mono_italic_fonts, self.mono_italic_count, font_size, font_weight);
        }
        if (font_weight >= 650 and self.mono_bold_count > 0) {
            return self.selectStableFromGroup(&self.mono_bold_fonts, self.mono_bold_count, font_size, font_weight);
        }
        if (self.mono_count > 0) {
            return self.selectStableFromGroup(&self.mono_fonts, self.mono_count, font_size, font_weight);
        }
        return self.selectWeightedStable(font_size, font_weight);
    }

    /// 从缓存中取或派生新字号字体
    fn deriveFontCached(self: *FontSelector, src: *Font, font_size: f32, group_idx: u4) ?*Font {
        if (!self.derived_cache_inited) return null;
        const target_size = @max(font_size, 1.0);
        const size_hundredths: u32 = @intFromFloat(@round(target_size * 100));
        const seed = (@as(u64, @intFromPtr(src)) << 4) | @as(u64, @intCast(group_idx));
        const key = std.hash.Wyhash.hash(seed, std.mem.asBytes(&size_hundredths));
        if (self.derived_cache.get(key)) |cached| return cached;

        const derived = src.derive(target_size) catch return null;
        self.derived_cache.put(key, derived) catch {
            derived.deinit();
            return null;
        };
        return derived;
    }
};
