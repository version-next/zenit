const std = @import("std");
const c_api = @import("c_api.zig");
const c = c_api.c;
const types = @import("../types.zig");
extern fn zenit_linux_find_font([*:0]const u8, c_int, c_int, [*]u8, usize, *c_int) c_int;
const NativeGlyph = extern struct { glyph_index: u32, cluster: u32, x_advance: f32, y_advance: f32, x_offset: f32, y_offset: f32, font_ref: ?*anyopaque };
const NativeCaret = extern struct { byte_offset: u32, primary_x: f32, secondary_x: f32, has_secondary: u32 };
const NativeMetrics = extern struct { width: f32, ascent: f32, descent: f32, leading: f32, base_rtl: u32 };
extern fn zenit_linux_text_context_create() ?*anyopaque;
extern fn zenit_linux_text_context_destroy(*anyopaque) void;
extern fn zenit_linux_shape(*anyopaque, [*]const u8, usize, [*:0]const u8, c_int, c_int, f32, f32, *?[*]NativeGlyph, *usize) c_int;
extern fn zenit_linux_free_glyphs(?[*]NativeGlyph, usize) void;
extern fn zenit_linux_carets(*anyopaque, [*]const u8, usize, [*:0]const u8, c_int, c_int, f32, f32, [*]const u32, usize, [*]NativeCaret, *NativeMetrics) c_int;
extern fn zenit_linux_font_ref_retain(*anyopaque) void;
extern fn zenit_linux_font_ref_release(*anyopaque) void;
extern fn zenit_linux_font_ref_identity(*anyopaque) u64;
extern fn zenit_linux_font_ref_size(*anyopaque) f32;
extern fn zenit_linux_font_ref_info(*anyopaque, [*]u8, usize, *c_int, *c_int, *c_int) c_int;
extern fn zenit_linux_font_ref_apply_axes(*anyopaque, ?*anyopaque) c_int;
const NativeColorBitmap = extern struct { pixels: ?[*]u8, width: u32, height: u32, bearing_x: i32, bearing_y: i32, advance: i32 };
extern fn zenit_linux_raster_color_glyph(?*anyopaque, [*:0]const u8, c_int, f64, u32, *NativeColorBitmap) c_int;
extern fn zenit_linux_free_color_bitmap(*NativeColorBitmap) void;
pub const ShapeStats = struct { calls: u64 = 0, total_us: u64 = 0, frame_calls: u32 = 0, frame_us: u64 = 0 };
var shape_stats: ShapeStats = .{};
pub fn takeShapeStats() ShapeStats {
    const result = shape_stats;
    shape_stats.frame_calls = 0;
    shape_stats.frame_us = 0;
    return result;
}
fn cssWeight(weight: types.FontWeight) u16 {
    return switch (weight) {
        .thin => 100,
        .light => 300,
        .regular => 400,
        .medium => 500,
        .semibold => 600,
        .bold => 700,
        .heavy => 800,
        .black => 900,
    };
}
fn physicalSize(size: f32, scale: f32) !c.FT_F26Dot6 {
    if (!std.math.isFinite(size) or !std.math.isFinite(scale) or size <= 0 or scale <= 0 or size * scale > 32768) return error.InvalidFontSize;
    return @intFromFloat(@max(1, @round(@as(f64, size) * scale * 64)));
}

pub const GlyphBitmap = types.GlyphBitmap;
pub const ShapedGlyph = types.ShapedGlyph;

pub fn releaseFallbackFontRef(font_ref: *anyopaque) void {
    zenit_linux_font_ref_release(font_ref);
}
pub fn retainFallbackFontRef(font_ref: *anyopaque) void {
    zenit_linux_font_ref_retain(font_ref);
}
pub fn fallbackFontRefIdentityHash(font_ref: *anyopaque) u64 {
    return zenit_linux_font_ref_identity(font_ref);
}
pub fn fallbackFontRefSize(font_ref: *anyopaque) f32 {
    return zenit_linux_font_ref_size(font_ref);
}
pub fn fallbackFontRefDebugName(allocator: std.mem.Allocator, font_ref: *anyopaque) ?[]u8 {
    var path: [4096]u8 = undefined;
    var index: c_int = 0;
    var weight: c_int = 0;
    var italic: c_int = 0;
    if (zenit_linux_font_ref_info(font_ref, &path, path.len, &index, &weight, &italic) != 1) return null;
    const length = std.mem.indexOfScalar(u8, &path, 0) orelse return null;
    return std.fmt.allocPrint(allocator, "{s}#{d} @ {d:.2}px", .{ path[0..length], index, fallbackFontRefSize(font_ref) }) catch null;
}

/// Font manager, responsible for initializing FreeType library
pub const FontSystem = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ft_library: c.FT_Library,
    layout_context: *anyopaque,
    default_family: ?[:0]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !FontSystem {
        var ft_lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_lib) != 0) {
            return error.FreeTypeInitFailed;
        }

        errdefer _ = c.FT_Done_FreeType(ft_lib);
        const layout_context = zenit_linux_text_context_create() orelse return error.TextLayoutInitFailed;
        std.log.info("[FontSystem/FreeType] Initialized", .{});

        return FontSystem{
            .allocator = allocator,
            .io = io,
            .ft_library = ft_lib,
            .layout_context = layout_context,
        };
    }

    pub fn deinit(self: *FontSystem) void {
        if (self.default_family) |family| self.allocator.free(family);
        zenit_linux_text_context_destroy(self.layout_context);
        _ = c.FT_Done_FreeType(self.ft_library);
        std.log.info("[FontSystem/FreeType] Destroyed", .{});
    }

    pub fn setDefaultFamily(self: *FontSystem, family: ?[]const u8) void {
        const next = if (family) |name| self.allocator.dupeSentinel(u8, name, 0) catch return else null;
        if (self.default_family) |old| self.allocator.free(old);
        self.default_family = next;
    }

    pub fn loadFont(self: *FontSystem, path: [:0]const u8, size: u32) !*Font {
        return loadFace(self.allocator, self.ft_library, self.layout_context, path, 0, @floatFromInt(size), 400, false, 1);
    }

    pub fn findFont(self: *FontSystem, descriptor: types.FontDescriptor) !*Font {
        _ = try physicalSize(descriptor.size, 1);
        if (std.mem.indexOfScalar(u8, descriptor.family, 0) != null) return error.InvalidFontFamily;
        const family = if (descriptor.family.len == 0 or std.mem.eql(u8, descriptor.family, "system"))
            self.default_family orelse "sans-serif"
        else
            descriptor.family;
        const terminated = try self.allocator.dupeSentinel(u8, family, 0);
        defer self.allocator.free(terminated);
        var path: [4096]u8 = undefined;
        var index: c_int = 0;
        const weight = cssWeight(descriptor.weight);
        const italic = descriptor.style == .italic;
        if (zenit_linux_find_font(terminated.ptr, weight, @intFromBool(italic), &path, path.len, &index) != 1) {
            // "system-ui" is a fontconfig generic alias on current desktops; older configurations
            // only know sans-serif, which is the desktop's UI face there.
            if (!std.mem.eql(u8, family, "system-ui") or zenit_linux_find_font("sans-serif", weight, @intFromBool(italic), &path, path.len, &index) != 1) return error.FontLoadFailed;
        }
        const length = std.mem.indexOfScalar(u8, &path, 0) orelse return error.InvalidFontPath;
        return loadFace(self.allocator, self.ft_library, self.layout_context, path[0..length :0], index, descriptor.size, weight, italic, 1);
    }
};

// Legacy alias for compatibility
pub const FontManager = FontSystem;

fn loadFace(allocator: std.mem.Allocator, library: c.FT_Library, layout_context: *anyopaque, path: [:0]const u8, index: c_long, size: f32, weight: u16, italic: bool, scale: f32) !*Font {
    const physical = try physicalSize(size, scale);
    const owned_path = try allocator.dupeSentinel(u8, path, 0);
    errdefer allocator.free(owned_path);
    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(library, owned_path.ptr, index, &face) != 0) return error.FontLoadFailed;
    errdefer _ = c.FT_Done_Face(face);
    if (c.FT_Set_Char_Size(face, 0, physical, 72, 72) != 0) return error.SetSizeFailed;
    const hb = c.hb_ft_font_create(face, null) orelse return error.HarfBuzzFontCreationFailed;
    errdefer c.hb_font_destroy(hb);
    const font = try allocator.create(Font);
    font.* = .{ .allocator = allocator, .ft_library = library, .layout_context = layout_context, .ft_face = face, .hb_font = hb, .path = owned_path, .face_index = index, .size = @intFromFloat(@max(1, @round(size))), .size_px = size, .scale_factor = scale, .weight = weight, .italic = italic };
    return font;
}

/// Owns a face and source path; FontSystem's library must outlive its fonts.
pub const Font = struct {
    allocator: std.mem.Allocator,
    ft_library: c.FT_Library,
    layout_context: *anyopaque,
    ft_face: c.FT_Face,
    hb_font: ?*c.hb_font_t,
    path: [:0]u8,
    face_index: c_long,
    size: u32,
    size_px: f32,
    scale_factor: f32 = 1,
    weight: u16 = 400,
    italic: bool = false,
    /// Platform font smoothing means macOS stem darkening (antialiasing stays on there).
    /// FreeType applies none, so there is nothing to turn off: written by the text renderer,
    /// ignored here and kept out of the glyph atlas key (honors_smoothing). It must never
    /// select monochrome rasterization.
    smooth_fonts: bool = true,
    pub const honors_smoothing = false;
    /// Pango itemizes every run and names its face (`fallback_font_ref` on every glyph,
    /// Latin included): that face is the layout's choice, not an automatic fallback, so it
    /// keeps fractional pen positioning like the primary face (per-glyph integer snapping
    /// made small labels unevenly spaced).
    pub const layout_selects_faces = true;

    fn fontFamily(self: *const Font) [*:0]const u8 {
        return if (self.ft_face.*.family_name != null) @ptrCast(self.ft_face.*.family_name) else "sans-serif";
    }
    pub fn fromFallbackRef(allocator: std.mem.Allocator, ref: *anyopaque, prototype: *const Font) !*Font {
        var path: [4096]u8 = undefined;
        var index: c_int = 0;
        var weight: c_int = 0;
        var italic: c_int = 0;
        if (zenit_linux_font_ref_info(ref, &path, path.len, &index, &weight, &italic) != 1) return error.InvalidFallbackFontRef;
        const length = std.mem.indexOfScalar(u8, &path, 0) orelse return error.InvalidFontPath;
        const font = try loadFace(allocator, prototype.ft_library, prototype.layout_context, path[0..length :0], index, fallbackFontRefSize(ref), @intCast(weight), italic != 0, prototype.scale_factor);
        errdefer font.deinit();
        if (zenit_linux_font_ref_apply_axes(ref, font.ft_face) != 1) return error.FontVariationFailed;
        c.hb_ft_font_changed(font.hb_font);
        font.smooth_fonts = prototype.smooth_fonts;
        return font;
    }
    pub fn lineCaretStops(self: *const Font, content: []const u8, boundaries: []const u32, out: []types.LineCaretStop) !types.LineMetrics {
        if (boundaries.len == 0 or out.len < boundaries.len) return error.InvalidCaretBuffer;
        const native = try self.allocator.alloc(NativeCaret, boundaries.len);
        defer self.allocator.free(native);
        var metrics: NativeMetrics = undefined;
        if (zenit_linux_carets(self.layout_context, content.ptr, content.len, self.fontFamily(), self.weight, @intFromBool(self.italic), self.size_px, self.scale_factor, boundaries.ptr, boundaries.len, native.ptr, &metrics) != 1) return error.TextCaretExtractionFailed;
        for (native, out[0..boundaries.len]) |source, *destination| destination.* = .{ .byte_offset = source.byte_offset, .primary_x = source.primary_x, .secondary_x = source.secondary_x, .has_secondary = source.has_secondary != 0 };
        return .{ .width = metrics.width, .ascent = metrics.ascent, .descent = metrics.descent, .leading = metrics.leading, .base_rtl = metrics.base_rtl != 0 };
    }
    pub fn pixelSize(self: *const Font) f32 {
        return self.size_px;
    }
    pub fn setScaleFactor(self: *Font, scale: f32) void {
        const physical = physicalSize(self.size_px, scale) catch return;
        if (scale == self.scale_factor) return;
        if (c.FT_Set_Char_Size(self.ft_face, 0, physical, 72, 72) != 0) {
            const previous = physicalSize(self.size_px, self.scale_factor) catch unreachable;
            _ = c.FT_Set_Char_Size(self.ft_face, 0, previous, 72, 72);
            c.hb_ft_font_changed(self.hb_font);
            return;
        }
        self.scale_factor = scale;
        c.hb_ft_font_changed(self.hb_font);
    }
    pub fn derive(self: *const Font, new_size: f32) !*Font {
        const derived = try loadFace(self.allocator, self.ft_library, self.layout_context, self.path, self.face_index, new_size, self.weight, self.italic, self.scale_factor);
        derived.smooth_fonts = self.smooth_fonts;
        return derived;
    }
    pub fn glyphIndexForCodepoint(self: *const Font, codepoint: u32) u32 {
        return c.FT_Get_Char_Index(self.ft_face, codepoint);
    }
    pub fn measureWidth(self: *const Font, content: []const u8) f32 {
        var shaper = TextShaper.init(self.allocator) catch return 0;
        defer shaper.deinit();
        const glyphs = shaper.shape(content, @constCast(self)) catch return 0;
        defer {
            for (glyphs) |glyph| if (glyph.fallback_font_ref) |ref| releaseFallbackFontRef(ref);
            self.allocator.free(glyphs);
        }
        var width: f32 = 0;
        for (glyphs) |glyph| width += glyph.x_advance;
        return @abs(width);
    }
    pub fn debugName(self: *const Font, allocator: std.mem.Allocator) ?[]u8 {
        const family = if (self.ft_face.*.family_name != null) std.mem.span(self.ft_face.*.family_name) else "FreeType";
        return std.fmt.allocPrint(allocator, "{s} @ {d:.2}px", .{ family, self.pixelSize() }) catch null;
    }
    pub fn deinit(self: *Font) void {
        if (self.hb_font) |hb| c.hb_font_destroy(hb);
        _ = c.FT_Done_Face(self.ft_face);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
    pub fn getAscent(self: *const Font) f32 {
        return @as(f32, @floatFromInt(self.ft_face.*.size.*.metrics.ascender)) / (64 * self.scale_factor);
    }
    pub fn getDescent(self: *const Font) f32 {
        return @as(f32, @floatFromInt(-self.ft_face.*.size.*.metrics.descender)) / (64 * self.scale_factor);
    }
    pub fn getLeading(self: *const Font) f32 {
        return @as(f32, @floatFromInt(self.ft_face.*.size.*.metrics.height)) / (64 * self.scale_factor) - self.getAscent() - self.getDescent();
    }
    pub fn hasColorGlyphs(self: *const Font) bool {
        return self.ft_face.*.face_flags & c.FT_FACE_FLAG_COLOR != 0;
    }
    pub fn rasterizeGlyphSubpixel(self: *Font, glyph_index: u32, offset_x: f32, offset_y: f32) !GlyphBitmap {
        if (!std.math.isFinite(offset_x) or !std.math.isFinite(offset_y) or @abs(offset_x) > 1 or @abs(offset_y) > 1) return error.InvalidGlyphOffset;
        var delta: c.FT_Vector = .{ .x = @intFromFloat(@round(offset_x * 64)), .y = @intFromFloat(@round(-offset_y * 64)) };
        c.FT_Set_Transform(self.ft_face, null, &delta);
        defer c.FT_Set_Transform(self.ft_face, null, null);
        return self.rasterizeGlyph(glyph_index);
    }

    /// Rasterize a single glyph
    pub fn rasterizeGlyph(self: *Font, glyph_index: u32) !GlyphBitmap {
        var color: NativeColorBitmap = undefined;
        const color_result = zenit_linux_raster_color_glyph(self.ft_face, self.path.ptr, @intCast(self.face_index), @as(f64, self.size_px) * self.scale_factor, glyph_index, &color);
        defer zenit_linux_free_color_bitmap(&color);
        if (color_result < 0) return error.ColorGlyphRenderFailed;
        if (color_result == 1) {
            const length = try std.math.mul(usize, try std.math.mul(usize, color.width, color.height), 4);
            const source = color.pixels orelse return error.InvalidGlyphBitmap;
            return .{ .pixels = try self.allocator.dupe(u8, source[0..length]), .width = color.width, .height = color.height, .bearing_x = color.bearing_x, .bearing_y = color.bearing_y, .advance = color.advance, .is_color = true };
        }
        // Load and render glyph
        const load_flags: c.FT_Int32 = @intCast(c.FT_LOAD_RENDER | c.FT_LOAD_COLOR);
        if (c.FT_Load_Glyph(self.ft_face, glyph_index, load_flags) != 0) {
            std.log.err("[Font/FreeType] Failed to load glyph: {d}", .{glyph_index});
            return error.GlyphLoadFailed;
        }

        const glyph = self.ft_face.*.glyph;
        const bitmap = glyph.*.bitmap;

        // Ensure grayscale bitmap
        if (bitmap.width != 0 and bitmap.rows != 0 and bitmap.pixel_mode != c.FT_PIXEL_MODE_GRAY and bitmap.pixel_mode != c.FT_PIXEL_MODE_BGRA and bitmap.pixel_mode != c.FT_PIXEL_MODE_MONO) {
            std.log.err("[Font/FreeType] Unsupported pixel mode: {d}", .{bitmap.pixel_mode});
            return error.UnsupportedPixelMode;
        }

        const width = bitmap.width;
        const height = bitmap.rows;
        const pitch: usize = @intCast(@abs(@as(i64, bitmap.pitch)));
        const is_color = bitmap.pixel_mode == c.FT_PIXEL_MODE_BGRA;
        const row_bytes = try std.math.mul(usize, width, if (is_color) 4 else 1);
        const source_row_bytes = if (bitmap.pixel_mode == c.FT_PIXEL_MODE_MONO) (@as(usize, width) + 7) / 8 else row_bytes;
        if (height > 0 and width > 0 and (bitmap.buffer == null or pitch < source_row_bytes)) return error.InvalidGlyphBitmap;

        // Allocate pixel data
        var pixels = try self.allocator.alloc(u8, try std.math.mul(usize, row_bytes, height));
        errdefer self.allocator.free(pixels);

        // FreeType bitmap may have padding, copy row by row
        if (height > 0 and width > 0) {
            for (0..height) |row| {
                // The signed pitch is the offset from the top row to the next
                // row, including for upward-flow bitmaps (FreeType FT_Bitmap).
                const src_address: usize = @intCast(@as(i128, @intFromPtr(bitmap.buffer)) + @as(i128, bitmap.pitch) * row);
                const source: [*]const u8 = @ptrFromInt(src_address);
                const dst_offset = row * row_bytes;
                if (bitmap.pixel_mode == c.FT_PIXEL_MODE_MONO) {
                    for (0..width) |col| pixels[dst_offset + col] = if (source[col / 8] & (@as(u8, 0x80) >> @as(u3, @intCast(col % 8))) != 0) 255 else 0;
                } else {
                    @memcpy(pixels[dst_offset..][0..row_bytes], source[0..row_bytes]);
                }
            }
        }

        return GlyphBitmap{
            .pixels = pixels,
            .width = width,
            .height = height,
            .bearing_x = glyph.*.bitmap_left,
            .bearing_y = glyph.*.bitmap_top,
            .is_color = is_color,
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
        use_italic: bool,
    ) ![]ShapedGlyph {
        const result = try self.shape(text, font);
        if (use_italic and font.ft_face.*.style_flags & c.FT_STYLE_FLAG_ITALIC == 0)
            for (result) |*glyph| {
                glyph.is_synthetic_italic = true;
            };
        return result;
    }

    pub fn shape(
        self: *TextShaper,
        text: []const u8,
        font: *Font,
    ) ![]ShapedGlyph {
        if (text.len > std.math.maxInt(c_int)) return error.TextTooLong;
        if (text.len == 0) return try self.allocator.alloc(ShapedGlyph, 0);
        shape_stats.calls += 1;
        shape_stats.frame_calls += 1;
        var native: ?[*]NativeGlyph = null;
        var count: usize = 0;
        if (zenit_linux_shape(font.layout_context, text.ptr, text.len, font.fontFamily(), font.weight, @intFromBool(font.italic), font.size_px, font.scale_factor, &native, &count) != 1) return error.TextShapingFailed;
        defer zenit_linux_free_glyphs(native, count);
        const result = try self.allocator.alloc(ShapedGlyph, count);
        if (native) |items| for (items[0..count], result) |source, *destination| {
            if (source.font_ref) |ref| retainFallbackFontRef(ref);
            destination.* = .{
                .glyph_index = source.glyph_index,
                .cluster = source.cluster,
                .x_advance = source.x_advance,
                .y_advance = source.y_advance,
                .x_offset = source.x_offset,
                .y_offset = source.y_offset,
                .is_fallback_font = source.font_ref != null,
                .fallback_font_ref = source.font_ref,
            };
        };

        return result;
    }
};
