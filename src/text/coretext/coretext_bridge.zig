// CoreText C bridge function declarations

pub const CoreTextShapedGlyph = extern struct {
    glyph_index: u32,
    cluster: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
    is_synthetic_italic: u32, // 1 if glyph needs synthetic italic skew at render time
    is_fallback_font: u32, // 1 if glyph uses a fallback font (e.g. CJK)
    fallback_font_ref: ?*anyopaque, // retained CTFontRef of the actual fallback font (NULL if not fallback)
};

pub const CoreTextCaretStop = extern struct {
    byte_offset: u32,
    primary_x: f32,
    secondary_x: f32,
    has_secondary: u32,
};

pub const CoreTextLineMetrics = extern struct {
    width: f32,
    ascent: f32,
    descent: f32,
    leading: f32,
    base_rtl: u32,
};

// Font creation
pub extern fn coretext_create_font_from_path(path: [*:0]const u8, size: f32) ?*anyopaque;
pub extern fn coretext_create_font_from_path_weighted(path: [*:0]const u8, size: f32, weight: c_int, italic: c_int) ?*anyopaque;
pub extern fn coretext_find_font(family: [*:0]const u8, size: f32, weight: c_int, italic: c_int) ?*anyopaque;
pub extern fn coretext_release_font(font: *anyopaque) void;
pub extern fn coretext_retain_font(font: *anyopaque) void;
/// 从已有 CTFont 派生新字号，保留所有 variation axes（weight/italic）
pub extern fn coretext_derive_font(existing_font: *anyopaque, new_size: f32) ?*anyopaque;
pub extern fn coretext_font_copy_debug_name(font: *anyopaque) ?[*:0]u8;
pub extern fn coretext_free_c_string(str: [*:0]u8) void;

// ---------------------------------------------------------------------------
// 字体枚举（字体选择器）
//
// 实测（本机 macOS，272 family / 990 face）：枚举 17.6ms、全量 trait 扫描
// 40.1ms —— 宿主在后台线程扫一次即可，这一层不做缓存。
// ---------------------------------------------------------------------------

/// 与 C 侧 `CoreTextFamilyInfo` 逐字段对齐。改这里必须同步改 bridge.m。
pub const CoreTextFamilyInfo = extern struct {
    /// symbolic class == Symbolic：名字**不能**用字体自身渲染（Wingdings 等）。
    /// ⚠ 不要用「字形覆盖」代替这个判据 —— 实测 Wingdings 对 'A'/'a'
    ///   返回有字形，但画出来是图形。
    is_symbolic: c_int,
    /// 字体是否含有拼出自己名字所需的全部字形。实测 272 个里有 47 个为 0。
    can_render_name: c_int,
    is_variable: c_int,
    /// 该家族的 face 数。0 表示 descriptor 查不到（如 SF Pro），应从列表过滤。
    face_count: c_int,
    /// 见 FamilyClass。
    classification: c_int,
    /// 有没有基本拉丁字形('A''a''g''1')。0 = 用它打英文会得到空白/豆腐。
    has_latin: c_int,
    /// CTFontCopySupportedLanguages()[0]，NUL 结尾。空 = 拿不到。
    lang: [16]u8,
};

pub const FamilyClass = enum(c_int) {
    unknown = 0,
    serif = 1,
    sans = 2,
    script = 3,
    display = 4,
    monospace = 5,
    symbolic = 6,
    _,
};

pub extern fn coretext_family_count() c_int;
/// 写入 out_names[0..max)，返回实际条数。每条都要 coretext_free_c_string。
pub extern fn coretext_copy_family_names(out_names: [*]?[*:0]u8, max: c_int) c_int;
/// 0 = 成功，-1 = 家族名建不出字体。
pub extern fn coretext_family_info(family: [*:0]const u8, out: *CoreTextFamilyInfo) c_int;
/// 写入 out_styles[0..max)，返回实际条数。每条都要 coretext_free_c_string。
pub extern fn coretext_family_styles(family: [*:0]const u8, out_styles: [*]?[*:0]u8, max: c_int) c_int;
/// 该家族**实际存在**的字重档位（CSS 100~900，升序去重）。返回写入数。
/// ⚠ 字重下拉必须用它生成：CoreText 对拿不到的字重静默降级、不报错
///   （实测 Zapfino 要 Bold 会安静地给 Regular），挂固定 100~900 列表
///   会让用户选了没反应且无任何信号。可变字体按 wght 轴区间铺档位。
pub extern fn coretext_family_weights(family: [*:0]const u8, out_weights: [*]c_int, max: c_int) c_int;
/// 样例串的最终兜底：从字体自身 character set 取前 max_cp 个可渲染码点。
/// 用于 lang 为空且非符号的字体（实测 Noto Sans Batak / Tagalog 两个）。
pub extern fn coretext_family_sample_codepoints(family: [*:0]const u8, out_cps: [*]u32, max_cp: c_int) c_int;
/// 1 = 家族名完全匹配；0 = 不存在或被 CoreText 静默替换成了别的字体。
/// ⚠ 解析用户存盘的字体名时**必须**先过这一关：coretext_find_font 对不存在的
///   家族不会失败，它会安静地给你一个替身。
pub extern fn coretext_family_exists(family: [*:0]const u8) c_int;

// Font metrics
pub extern fn coretext_font_get_ascent(font: *anyopaque) f32;
pub extern fn coretext_font_get_descent(font: *anyopaque) f32;
pub extern fn coretext_font_get_leading(font: *anyopaque) f32;
pub extern fn coretext_font_get_units_per_em(font: *anyopaque) c_uint;
pub extern fn coretext_font_get_size(font: *anyopaque) f32;
pub extern fn coretext_font_identity_hash(font: *anyopaque) u64;
pub extern fn coretext_font_get_glyph_index(font: *anyopaque, codepoint: c_uint) c_uint;

// Glyph rasterization
pub extern fn coretext_rasterize_glyph(
    font: *anyopaque,
    glyph_index: c_uint,
    scale_factor: f32,
    out_pixels: *?[*]u8,
    out_width: *c_uint,
    out_height: *c_uint,
    out_bearing_x: *c_int,
    out_bearing_y: *c_int,
    out_advance: *c_int,
    out_is_color: *c_int,
) c_int;

/// 字体是否含彩色字形表（sbix / COLR / CBDT，或 ColorGlyphs symbolic trait）。
pub extern fn coretext_font_has_color_glyphs(font: *anyopaque) c_int;

// R6: Glyph rasterization with subpixel offset
pub extern fn coretext_rasterize_glyph_subpixel(
    font: *anyopaque,
    glyph_index: c_uint,
    scale_factor: f32,
    subpixel_offset_x: f32,
    subpixel_offset_y: f32,
    out_pixels: *?[*]u8,
    out_width: *c_uint,
    out_height: *c_uint,
    out_bearing_x: *c_int,
    out_bearing_y: *c_int,
    out_advance: *c_int,
    out_is_color: *c_int,
) c_int;

pub extern fn coretext_free_bitmap(pixels: ?[*]u8) void;

// Text shaping
pub extern fn coretext_shape_text(
    font: *anyopaque,
    text: [*]const u8,
    text_len: c_uint,
    out_glyphs: *?[*]CoreTextShapedGlyph,
    out_count: *c_uint,
    synthetic_italic: c_int,
) c_int;

pub extern fn coretext_free_shaped_glyphs(glyphs: ?[*]CoreTextShapedGlyph) void;

/// Extract CoreText-authoritative caret geometry at caller-supplied UTF-8
/// grapheme boundaries. The output preserves primary/secondary positions at
/// bidi boundaries; the Zig side expands and sorts them into visual order.
pub extern fn coretext_line_caret_stops(
    font: *anyopaque,
    text: [*]const u8,
    text_len: c_uint,
    boundaries: [*]const u32,
    boundary_count: c_uint,
    out_stops: [*]CoreTextCaretStop,
    out_metrics: *CoreTextLineMetrics,
) c_int;

// Text measurement with existing font
pub extern fn coretext_measure_text_width_with_font(font: *anyopaque, text: [*]const u8, len: c_int) f32;
