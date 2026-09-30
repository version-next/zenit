const std = @import("std");
const ct = @import("coretext_bridge.zig");
const types = @import("../types.zig");

// 全局 shape profiling
var g_shape_calls: u64 = 0;
var g_shape_total_us: u64 = 0;
var g_shape_frame_calls: u32 = 0;
var g_shape_frame_us: u64 = 0;

pub const ShapeStats = struct { calls: u64, total_us: u64, frame_calls: u32, frame_us: u64 };

pub fn takeShapeStats() ShapeStats {
    const res = ShapeStats{ .calls = g_shape_calls, .total_us = g_shape_total_us, .frame_calls = g_shape_frame_calls, .frame_us = g_shape_frame_us };
    g_shape_frame_calls = 0;
    g_shape_frame_us = 0;
    return res;
}

pub const GlyphBitmap = types.GlyphBitmap;
pub const ShapedGlyph = types.ShapedGlyph;

pub fn releaseFallbackFontRef(font_ref: *anyopaque) void {
    ct.coretext_release_font(font_ref);
}

pub fn retainFallbackFontRef(font_ref: *anyopaque) void {
    ct.coretext_retain_font(font_ref);
}

pub fn fallbackFontRefSize(font_ref: *anyopaque) f32 {
    return ct.coretext_font_get_size(font_ref);
}

/// fallback CTFontRef 的稳定身份（PS 名+size+traits hash）。
/// 指针不稳定，身份稳定 —— 见 coretext_bridge.m 同名函数的注释。
pub fn fallbackFontRefIdentityHash(font_ref: *anyopaque) u64 {
    return ct.coretext_font_identity_hash(font_ref);
}

pub fn fallbackFontRefDebugName(allocator: std.mem.Allocator, font_ref: *anyopaque) ?[]u8 {
    const raw = ct.coretext_font_copy_debug_name(font_ref) orelse return null;
    defer ct.coretext_free_c_string(raw);
    const slice = std.mem.sliceTo(raw, 0);
    return allocator.dupe(u8, slice) catch null;
}

/// Font system using macOS CoreText
pub const FontSystem = struct {
    allocator: std.mem.Allocator,
    /// "system" family 的实际映射目标。zenit_app 解析 fallback_families 后
    /// 写入（如 "Helvetica Neue"）。不设置时 "system" 交给 CoreText descriptor
    /// 兜底——macOS 上会解析成 **Helvetica**，与渲染用字（FontSelector 的
    /// fallback_families 首选）不同：拉丁 kerning 有 ~1% 细差；且两个基字体的
    /// fallback 级联对 🈶 一类带框符号 emoji 会解析到不同字体（PingFang 16px
    /// vs Apple Color Emoji ~21px）——光标/选区与实际字形错位的根源。
    /// slice 需比 FontSystem 活得久（family 字符串常量即可）。
    default_family: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) !FontSystem {
        std.log.info("[FontSystem/CoreText] Initialized", .{});
        return FontSystem{ .allocator = allocator };
    }

    pub fn setDefaultFamily(self: *FontSystem, family: ?[]const u8) void {
        self.default_family = family;
    }

    pub fn deinit(self: *FontSystem) void {
        _ = self;
        std.log.info("[FontSystem/CoreText] Destroyed", .{});
    }

    /// Load a font from a file path
    pub fn loadFont(self: *FontSystem, path: [:0]const u8, size: u32) !*Font {
        const ct_font = ct.coretext_create_font_from_path(path.ptr, @floatFromInt(size)) orelse {
            std.log.err("[FontSystem/CoreText] Failed to load font: {s}", .{path});
            return error.FontLoadFailed;
        };

        const font = try self.allocator.create(Font);
        font.* = .{
            .allocator = self.allocator,
            .ct_font = ct_font,
            .size = size,
            .size_px = @floatFromInt(size),
        };
        return font;
    }

    /// Find a system font by family name
    pub fn findFont(self: *FontSystem, descriptor_in: types.FontDescriptor) !*Font {
        var descriptor = descriptor_in;
        if (self.default_family) |fam| {
            if (std.mem.eql(u8, descriptor.family, "system")) descriptor.family = fam;
        }
        // Convert FontWeight to numeric weight
        const weight: c_int = switch (descriptor.weight) {
            .thin => 100,
            .light => 300,
            .regular => 400,
            .medium => 500,
            .semibold => 600,
            .bold => 700,
            .heavy => 800,
            .black => 900,
        };
        const italic: c_int = if (descriptor.style == .italic) 1 else 0;

        // We need a null-terminated family name
        const family_z = try self.allocator.dupeZ(u8, descriptor.family);
        defer self.allocator.free(family_z);

        const ct_font = ct.coretext_find_font(
            family_z.ptr,
            descriptor.size,
            weight,
            italic,
        ) orelse {
            std.log.err("[FontSystem/CoreText] Failed to find font: {s}", .{descriptor.family});
            return error.FontNotFound;
        };

        const font = try self.allocator.create(Font);
        font.* = .{
            .allocator = self.allocator,
            .ct_font = ct_font,
            .size = @intFromFloat(descriptor.size),
            .size_px = descriptor.size,
            .weight = @intCast(weight),
        };
        return font;
    }
};

// Legacy alias for compatibility
pub const FontManager = FontSystem;

/// Font represents a loaded font at a specific size (CoreText backend)
pub const Font = struct {
    allocator: std.mem.Allocator,
    ct_font: *anyopaque,
    size: u32,
    size_px: f32,
    weight: u16 = 400,
    scale_factor: f32 = 1.0,

    pub fn setScaleFactor(self: *Font, scale: f32) void {
        self.scale_factor = scale;
    }

    pub fn debugName(self: *const Font, allocator: std.mem.Allocator) ?[]u8 {
        const raw = ct.coretext_font_copy_debug_name(self.ct_font) orelse return null;
        defer ct.coretext_free_c_string(raw);
        const slice = std.mem.sliceTo(raw, 0);
        return allocator.dupe(u8, slice) catch null;
    }

    /// 派生同字体族（相同 variation axes）的新字号 Font
    /// 用于 lazy font loading：base_font_size 变化时按需创建精确字号
    pub fn derive(self: *const Font, new_size: f32) !*Font {
        const clamped_size = @max(new_size, 1.0);
        const ct_font = ct.coretext_derive_font(self.ct_font, clamped_size) orelse {
            return error.FontLoadFailed;
        };
        const font = try self.allocator.create(Font);
        font.* = .{
            .allocator = self.allocator,
            .ct_font = ct_font,
            .size = @max(@as(u32, 1), @as(u32, @intFromFloat(@round(clamped_size)))),
            .size_px = clamped_size,
            .weight = self.weight,
            .scale_factor = self.scale_factor,
        };
        return font;
    }

    pub fn pixelSize(self: *const Font) f32 {
        return if (self.size_px > 0) self.size_px else @as(f32, @floatFromInt(self.size));
    }

    pub fn deinit(self: *Font) void {
        ct.coretext_release_font(self.ct_font);
        self.allocator.destroy(self);
    }

    /// Rasterize a single glyph
    pub fn rasterizeGlyph(self: *Font, glyph_index: u32) !GlyphBitmap {
        var c_pixels: ?[*]u8 = null;
        var c_width: c_uint = 0;
        var c_height: c_uint = 0;
        var c_bearing_x: c_int = 0;
        var c_bearing_y: c_int = 0;
        var c_advance: c_int = 0;
        var c_is_color: c_int = 0;

        const result = ct.coretext_rasterize_glyph(
            self.ct_font,
            @intCast(glyph_index),
            self.scale_factor,
            &c_pixels,
            &c_width,
            &c_height,
            &c_bearing_x,
            &c_bearing_y,
            &c_advance,
            &c_is_color,
        );

        if (result != 0) {
            return error.GlyphRasterizationFailed;
        }

        const width: u32 = @intCast(c_width);
        const height: u32 = @intCast(c_height);
        const is_color = c_is_color != 0;

        // Empty glyph (e.g., space)
        if (width == 0 or height == 0 or c_pixels == null) {
            return GlyphBitmap{
                .pixels = &[_]u8{},
                .width = 0,
                .height = 0,
                .bearing_x = @intCast(c_bearing_x),
                .bearing_y = @intCast(c_bearing_y),
                .advance = @intCast(c_advance),
                .is_color = is_color,
            };
        }

        // Copy pixels to Zig-managed memory（彩色是 BGRA，4 字节/像素）
        // alloc 失败也必须归还 C 侧位图——GPA 看不见 C 分配，这是生产后端的
        // OOM 净泄漏路径
        errdefer ct.coretext_free_bitmap(c_pixels);
        const pixel_count = width * height * (if (is_color) @as(u32, 4) else 1);
        const pixels = try self.allocator.alloc(u8, pixel_count);
        @memcpy(pixels, c_pixels.?[0..pixel_count]);

        // Free C-allocated bitmap
        ct.coretext_free_bitmap(c_pixels);

        return GlyphBitmap{
            .pixels = pixels,
            .width = width,
            .height = height,
            .bearing_x = @intCast(c_bearing_x),
            .bearing_y = @intCast(c_bearing_y),
            .advance = @intCast(c_advance),
            .is_color = is_color,
        };
    }

    /// 码点 → 字形索引（该字体内）。0 = 该字体不含此码点。
    pub fn glyphIndexForCodepoint(self: *const Font, codepoint: u32) u32 {
        return ct.coretext_font_get_glyph_index(self.ct_font, @intCast(codepoint));
    }

    /// 该字体是否含彩色字形表（sbix/COLR/CBDT）。
    /// 用于在光栅化前就决定走哪条 atlas 路径（灰度页 vs BGRA 页）。
    pub fn hasColorGlyphs(self: *const Font) bool {
        return ct.coretext_font_has_color_glyphs(self.ct_font) != 0;
    }

    /// R6: Rasterize glyph with subpixel offset for sharper rendering
    /// subpixel_offset_x/y: 物理像素内的亚像素偏移 [0.0, 1.0)
    pub fn rasterizeGlyphSubpixel(self: *Font, glyph_index: u32, subpixel_offset_x: f32, subpixel_offset_y: f32) !GlyphBitmap {
        var c_pixels: ?[*]u8 = null;
        var c_width: c_uint = 0;
        var c_height: c_uint = 0;
        var c_bearing_x: c_int = 0;
        var c_bearing_y: c_int = 0;
        var c_advance: c_int = 0;
        var c_is_color: c_int = 0;

        const result = ct.coretext_rasterize_glyph_subpixel(
            self.ct_font,
            @intCast(glyph_index),
            self.scale_factor,
            subpixel_offset_x,
            subpixel_offset_y,
            &c_pixels,
            &c_width,
            &c_height,
            &c_bearing_x,
            &c_bearing_y,
            &c_advance,
            &c_is_color,
        );

        if (result != 0) {
            return error.GlyphRasterizationFailed;
        }

        const width: u32 = @intCast(c_width);
        const height: u32 = @intCast(c_height);
        const is_color = c_is_color != 0;

        if (width == 0 or height == 0 or c_pixels == null) {
            return GlyphBitmap{
                .pixels = &[_]u8{},
                .width = 0,
                .height = 0,
                .bearing_x = @intCast(c_bearing_x),
                .bearing_y = @intCast(c_bearing_y),
                .advance = @intCast(c_advance),
                .is_color = is_color,
            };
        }

        // 同 rasterizeGlyph：alloc 失败也要归还 C 侧位图
        errdefer ct.coretext_free_bitmap(c_pixels);
        const pixel_count = width * height * (if (is_color) @as(u32, 4) else 1);
        const pixels = try self.allocator.alloc(u8, pixel_count);
        @memcpy(pixels, c_pixels.?[0..pixel_count]);
        ct.coretext_free_bitmap(c_pixels);

        return GlyphBitmap{
            .pixels = pixels,
            .width = width,
            .height = height,
            .bearing_x = @intCast(c_bearing_x),
            .bearing_y = @intCast(c_bearing_y),
            .advance = @intCast(c_advance),
            .is_color = is_color,
        };
    }

    /// Get font metrics
    pub fn getAscent(self: *Font) f32 {
        return ct.coretext_font_get_ascent(self.ct_font);
    }

    pub fn getDescent(self: *Font) f32 {
        return ct.coretext_font_get_descent(self.ct_font);
    }

    pub fn getLeading(self: *Font) f32 {
        return ct.coretext_font_get_leading(self.ct_font);
    }

    /// Extract visual caret geometry from the same CoreText line construction
    /// used by shaping/measurement. `boundaries` must contain UTF-8 grapheme
    /// boundaries and `out` must have the same length.
    pub fn lineCaretStops(
        self: *const Font,
        text: []const u8,
        boundaries: []const u32,
        out: []types.LineCaretStop,
    ) !types.LineMetrics {
        if (boundaries.len == 0 or out.len < boundaries.len) return error.InvalidCaretBuffer;
        const native = try self.allocator.alloc(ct.CoreTextCaretStop, boundaries.len);
        defer self.allocator.free(native);
        var metrics: ct.CoreTextLineMetrics = undefined;
        if (ct.coretext_line_caret_stops(
            self.ct_font,
            text.ptr,
            @intCast(text.len),
            boundaries.ptr,
            @intCast(boundaries.len),
            native.ptr,
            &metrics,
        ) != 0) return error.TextCaretExtractionFailed;
        for (native, 0..) |stop, i| {
            out[i] = .{
                .byte_offset = stop.byte_offset,
                .primary_x = stop.primary_x,
                .secondary_x = stop.secondary_x,
                .has_secondary = stop.has_secondary != 0,
            };
        }
        return .{
            .width = metrics.width,
            .ascent = metrics.ascent,
            .descent = metrics.descent,
            .leading = metrics.leading,
            .base_rtl = metrics.base_rtl != 0,
        };
    }

    /// 使用该 Font 的 CTFontRef 测量文本宽度（与渲染完全一致）
    pub fn measureWidth(self: *const Font, text: []const u8) f32 {
        if (text.len == 0) return 0;
        return ct.coretext_measure_text_width_with_font(self.ct_font, text.ptr, @intCast(text.len));
    }
};

/// Text Shaper using CoreText
pub const TextShaper = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TextShaper {
        std.log.info("[TextShaper/CoreText] Initialized", .{});
        return TextShaper{ .allocator = allocator };
    }

    pub fn deinit(self: *TextShaper) void {
        _ = self;
        std.log.info("[TextShaper/CoreText] Destroyed", .{});
    }

    /// Shape text, returning glyph sequence
    pub fn shape(
        self: *TextShaper,
        text: []const u8,
        font: *Font,
    ) ![]ShapedGlyph {
        return self.shapeWithOptions(text, font, false);
    }

    pub fn shapeWithOptions(
        self: *TextShaper,
        text: []const u8,
        font: *Font,
        use_italic: bool,
    ) ![]ShapedGlyph {
        var c_glyphs: ?[*]ct.CoreTextShapedGlyph = null;
        var c_count: c_uint = 0;

        var timer = std.time.Timer.start() catch undefined;
        defer {
            const elapsed = timer.read() / 1000;
            g_shape_calls += 1;
            g_shape_total_us += elapsed;
            g_shape_frame_calls += 1;
            g_shape_frame_us += elapsed;
        }
        const result = ct.coretext_shape_text(
            font.ct_font,
            text.ptr,
            @intCast(text.len),
            &c_glyphs,
            &c_count,
            if (use_italic) @as(c_int, 1) else @as(c_int, 0),
        );

        if (result != 0) {
            return error.TextShapingFailed;
        }

        const glyph_count: usize = @intCast(c_count);

        if (glyph_count == 0) {
            return &[_]ShapedGlyph{};
        }

        // Convert to Zig structs。
        // alloc 失败时：桥为每个 fallback_font_ref 做的 +1 retain 尚未转交
        // （free_shaped_glyphs 刻意不 release 它们），必须逐个归还再释放数组，
        // 否则 CTFont 引用与 C 数组双双失联。
        errdefer {
            for (c_glyphs.?[0..glyph_count]) |cg| {
                if (cg.fallback_font_ref) |ref| ct.coretext_release_font(ref);
            }
            ct.coretext_free_shaped_glyphs(c_glyphs);
        }
        const glyphs = try self.allocator.alloc(ShapedGlyph, glyph_count);
        const c_glyph_slice = c_glyphs.?[0..glyph_count];
        for (c_glyph_slice, 0..) |cg, i| {
            glyphs[i] = .{
                .glyph_index = cg.glyph_index,
                .cluster = cg.cluster,
                .x_advance = cg.x_advance,
                .y_advance = cg.y_advance,
                .x_offset = cg.x_offset,
                .y_offset = cg.y_offset,
                .is_synthetic_italic = cg.is_synthetic_italic != 0,
                .is_fallback_font = cg.is_fallback_font != 0,
                .fallback_font_ref = cg.fallback_font_ref,
            };
        }

        // Free C-allocated glyphs (does not release fallback_font_ref — ownership transferred above)
        ct.coretext_free_shaped_glyphs(c_glyphs);

        return glyphs;
    }
};
