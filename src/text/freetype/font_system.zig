const std = @import("std");
const c_api = @import("c_api.zig");
const c = c_api.c;
const types = @import("../types.zig");

pub const GlyphBitmap = types.GlyphBitmap;
pub const ShapedGlyph = types.ShapedGlyph;

pub fn releaseFallbackFontRef(font_ref: *anyopaque) void {
    _ = font_ref;
}

pub fn retainFallbackFontRef(font_ref: *anyopaque) void {
    _ = font_ref;
}

pub fn fallbackFontRefIdentityHash(font_ref: *anyopaque) u64 {
    // FreeType 后端的 fallback ref 是稳定指针，直接用指针值作身份。
    return @intFromPtr(font_ref);
}

pub fn fallbackFontRefSize(font_ref: *anyopaque) f32 {
    _ = font_ref;
    return 0;
}

pub fn fallbackFontRefDebugName(allocator: std.mem.Allocator, font_ref: *anyopaque) ?[]u8 {
    _ = allocator;
    _ = font_ref;
    return null;
}

/// Font manager, responsible for initializing FreeType library
pub const FontSystem = struct {
    allocator: std.mem.Allocator,
    ft_library: c.FT_Library,

    pub fn init(allocator: std.mem.Allocator) !FontSystem {
        var ft_lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_lib) != 0) {
            return error.FreeTypeInitFailed;
        }

        std.log.info("[FontSystem/FreeType] Initialized", .{});

        return FontSystem{
            .allocator = allocator,
            .ft_library = ft_lib,
        };
    }

    pub fn deinit(self: *FontSystem) void {
        _ = c.FT_Done_FreeType(self.ft_library);
        std.log.info("[FontSystem/FreeType] Destroyed", .{});
    }

    /// 与 CoreText 后端 API 对齐（"system" family 映射）。FreeType 后端
    /// 按路径加载字体、无 "system" 语义，no-op 即正确。
    pub fn setDefaultFamily(self: *FontSystem, family: ?[]const u8) void {
        _ = self;
        _ = family;
    }

    /// Load a font from a file path
    pub fn loadFont(self: *FontSystem, path: [:0]const u8, size: u32) !*Font {
        const font = try self.allocator.create(Font);
        errdefer self.allocator.destroy(font);

        // Load font file
        if (c.FT_New_Face(self.ft_library, path.ptr, 0, &font.ft_face) != 0) {
            std.log.err("[FontSystem/FreeType] Failed to load font: {s}", .{path});
            return error.FontLoadFailed;
        }
        errdefer _ = c.FT_Done_Face(font.ft_face);

        // Set pixel size
        if (c.FT_Set_Pixel_Sizes(font.ft_face, 0, size) != 0) {
            std.log.err("[FontSystem/FreeType] Failed to set font size: {d}", .{size});
            return error.SetSizeFailed;
        }

        // Create HarfBuzz font
        font.hb_font = c.hb_ft_font_create(font.ft_face, null);
        if (font.hb_font == null) {
            std.log.err("[FontSystem/FreeType] Failed to create HarfBuzz font", .{});
            return error.HarfBuzzFontCreationFailed;
        }

        font.allocator = self.allocator;
        font.size = size;
        font.size_px = @floatFromInt(size);

        std.log.info("[FontSystem/FreeType] Loaded font: {s} @ {d}px", .{ path, size });

        return font;
    }

    /// Find a system font by family name (FreeType backend: not supported, use loadFont)
    pub fn findFont(self: *FontSystem, descriptor: types.FontDescriptor) !*Font {
        _ = self;
        _ = descriptor;
        return error.FontDiscoveryNotSupported;
    }
};

// Legacy alias for compatibility
pub const FontManager = FontSystem;

/// Font represents a loaded font at a specific size
pub const Font = struct {
    allocator: std.mem.Allocator,
    ft_face: c.FT_Face,
    hb_font: ?*c.hb_font_t,
    size: u32,
    size_px: f32,

    pub fn pixelSize(self: *const Font) f32 {
        return if (self.size_px > 0) self.size_px else @as(f32, @floatFromInt(self.size));
    }

    pub fn debugName(self: *const Font, allocator: std.mem.Allocator) ?[]u8 {
        return std.fmt.allocPrint(allocator, "FreeType font @ {d:.2}px", .{self.pixelSize()}) catch null;
    }

    pub fn deinit(self: *Font) void {
        if (self.hb_font) |hb| {
            c.hb_font_destroy(hb);
        }
        _ = c.FT_Done_Face(self.ft_face);
        self.allocator.destroy(self);
    }

    /// Get font metrics (pixel units)
    pub fn getAscent(self: *Font) f32 {
        const metrics = self.ft_face.*.size.*.metrics;
        return @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
    }

    pub fn getDescent(self: *Font) f32 {
        const metrics = self.ft_face.*.size.*.metrics;
        return @as(f32, @floatFromInt(-metrics.descender)) / 64.0;
    }

    pub fn getLeading(self: *Font) f32 {
        const metrics = self.ft_face.*.size.*.metrics;
        const height = @as(f32, @floatFromInt(metrics.height)) / 64.0;
        const ascent = @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
        const descent = @as(f32, @floatFromInt(-metrics.descender)) / 64.0;
        return height - (ascent + descent);
    }

    /// FreeType 后端只走 FT_PIXEL_MODE_GRAY（见 rasterizeGlyph 的 pixel_mode 断言），
    /// 没有彩色字形路径 —— 恒为 false，与 CoreText 后端 API 对齐。
    pub fn hasColorGlyphs(self: *const Font) bool {
        _ = self;
        return false;
    }

    /// Rasterize a single glyph
    pub fn rasterizeGlyph(self: *Font, glyph_index: u32) !GlyphBitmap {
        // Load and render glyph
        if (c.FT_Load_Glyph(self.ft_face, glyph_index, c.FT_LOAD_RENDER) != 0) {
            std.log.err("[Font/FreeType] Failed to load glyph: {d}", .{glyph_index});
            return error.GlyphLoadFailed;
        }

        const glyph = self.ft_face.*.glyph;
        const bitmap = glyph.*.bitmap;

        // Ensure grayscale bitmap
        if (bitmap.pixel_mode != c.FT_PIXEL_MODE_GRAY) {
            std.log.err("[Font/FreeType] Unsupported pixel mode: {d}", .{bitmap.pixel_mode});
            return error.UnsupportedPixelMode;
        }

        const width = bitmap.width;
        const height = bitmap.rows;
        const pitch = @as(usize, @intCast(@abs(bitmap.pitch)));

        // Allocate pixel data
        var pixels = try self.allocator.alloc(u8, width * height);
        errdefer self.allocator.free(pixels);

        // FreeType bitmap may have padding, copy row by row
        if (height > 0 and width > 0) {
            for (0..height) |row| {
                const src_offset = row * pitch;
                const dst_offset = row * width;
                @memcpy(
                    pixels[dst_offset..][0..width],
                    bitmap.buffer[src_offset..][0..width],
                );
            }
        }

        return GlyphBitmap{
            .pixels = pixels,
            .width = width,
            .height = height,
            .bearing_x = glyph.*.bitmap_left,
            .bearing_y = glyph.*.bitmap_top,
            .advance = @intCast(glyph.*.advance.x >> 6), // 26.6 fixed point to integer
        };
    }
};

/// Text Shaper using HarfBuzz
pub const TextShaper = struct {
    allocator: std.mem.Allocator,
    hb_buffer: ?*c.hb_buffer_t,

    pub fn init(allocator: std.mem.Allocator) !TextShaper {
        const buffer = c.hb_buffer_create();
        if (buffer == null) {
            return error.HarfBuzzBufferCreationFailed;
        }

        std.log.info("[TextShaper/HarfBuzz] Initialized", .{});

        return TextShaper{
            .allocator = allocator,
            .hb_buffer = buffer,
        };
    }

    pub fn deinit(self: *TextShaper) void {
        if (self.hb_buffer) |buf| {
            c.hb_buffer_destroy(buf);
        }
        std.log.info("[TextShaper/HarfBuzz] Destroyed", .{});
    }

    /// Shape text, returning glyph sequence
    pub fn shapeWithOptions(
        self: *TextShaper,
        text: []const u8,
        font: *Font,
        _: bool, // use_italic (not supported on FreeType backend)
    ) ![]ShapedGlyph {
        return self.shape(text, font);
    }

    pub fn shape(
        self: *TextShaper,
        text: []const u8,
        font: *Font,
    ) ![]ShapedGlyph {
        const buffer = self.hb_buffer.?;

        // Clear buffer
        c.hb_buffer_clear_contents(buffer);

        // Add UTF-8 text
        c.hb_buffer_add_utf8(
            buffer,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );

        // Set direction, script, and language
        c.hb_buffer_set_direction(buffer, c.HB_DIRECTION_LTR);
        c.hb_buffer_set_script(buffer, c.HB_SCRIPT_LATIN);
        c.hb_buffer_set_language(buffer, c.hb_language_from_string("en", -1));

        // Perform shaping
        c.hb_shape(font.hb_font, buffer, null, 0);

        // Get results
        var glyph_count: c_uint = undefined;
        const glyph_infos = c.hb_buffer_get_glyph_infos(buffer, &glyph_count);
        const glyph_positions = c.hb_buffer_get_glyph_positions(buffer, &glyph_count);

        if (glyph_count == 0) {
            return &[_]ShapedGlyph{};
        }

        // Convert to Zig struct
        const result = try self.allocator.alloc(ShapedGlyph, glyph_count);
        for (0..glyph_count) |i| {
            result[i] = ShapedGlyph{
                .glyph_index = glyph_infos[i].codepoint,
                .cluster = glyph_infos[i].cluster,
                .x_advance = @as(f32, @floatFromInt(glyph_positions[i].x_advance)) / 64.0,
                .y_advance = @as(f32, @floatFromInt(glyph_positions[i].y_advance)) / 64.0,
                .x_offset = @as(f32, @floatFromInt(glyph_positions[i].x_offset)) / 64.0,
                .y_offset = @as(f32, @floatFromInt(glyph_positions[i].y_offset)) / 64.0,
            };
        }

        return result;
    }
};
