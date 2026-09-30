const std = @import("std");

/// GlyphBitmap holds rasterized glyph data (platform-agnostic)
pub const GlyphBitmap = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i32,
    /// true = pixels 是 BGRA premultiplied（4 字节/像素，彩色字形）；
    /// false = 单通道覆盖率掩码（1 字节/像素）。
    is_color: bool = false,

    /// 每像素字节数，由 is_color 唯一决定。上传纹理时算 bytes_per_row 用。
    pub fn bytesPerPixel(self: GlyphBitmap) u32 {
        return if (self.is_color) 4 else 1;
    }

    pub fn deinit(self: GlyphBitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Shaped glyph info after text shaping (platform-agnostic)
pub const ShapedGlyph = struct {
    glyph_index: u32,
    cluster: u32, // UTF-8 byte offset
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
    is_synthetic_italic: bool = false, // true if glyph needs synthetic italic skew at render time
    is_fallback_font: bool = false, // true if glyph uses a fallback font (e.g. CJK)
    /// CoreText 实际选用的 fallback 字体 CTFontRef（retained）。
    /// 渲染时用此字体光栅化，而非固定的 CJK fallback。
    fallback_font_ref: ?*anyopaque = null,
};

/// Backend-neutral line caret extraction record. One record corresponds to one
/// framework-provided grapheme boundary; `secondary_x` is meaningful only at a
/// bidi boundary where the same logical position has two visual carets.
pub const LineCaretStop = struct {
    byte_offset: u32,
    primary_x: f32,
    secondary_x: f32,
    has_secondary: bool,
};

pub const LineMetrics = struct {
    width: f32,
    ascent: f32,
    descent: f32,
    leading: f32,
    base_rtl: bool,
};

/// Font descriptor for system font discovery
pub const FontDescriptor = struct {
    family: []const u8,
    size: f32,
    weight: FontWeight = .regular,
    style: FontStyle = .normal,
};

pub const FontWeight = enum {
    thin,
    light,
    regular,
    medium,
    semibold,
    bold,
    heavy,
    black,
};

pub const FontStyle = enum {
    normal,
    italic,
};
