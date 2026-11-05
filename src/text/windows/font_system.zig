//! Windows font backend. DirectWrite supplies system discovery, metrics and
//! grayscale glyph bitmaps. DirectWrite layout runs supply complex-script
//! shaping, visual bidi order, UTF-8 clusters and retained fallback faces.
const std = @import("std");
const types = @import("../types.zig");

pub const GlyphBitmap = types.GlyphBitmap;
pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapeStats = struct { calls: u64 = 0, total_us: u64 = 0, frame_calls: u32 = 0, frame_us: u64 = 0 };
pub fn takeShapeStats() ShapeStats {
    return .{};
}

extern fn zenit_dwrite_find_font(family: [*:0]const u8, locale: [*:0]const u8, size: f32, weight: c_int, italic: c_int) ?*anyopaque;
extern fn zenit_dwrite_load_font(path: [*:0]const u8, locale: [*:0]const u8, size: f32) ?*anyopaque;
extern fn zenit_dwrite_derive_font(font: *anyopaque, size: f32) ?*anyopaque;
extern fn zenit_dwrite_font_family_name(font: *anyopaque, out: [*]u8, capacity: u32) u32;
extern fn zenit_windows_system_ui_family(out: [*]u8, capacity: u32) u32;
extern fn zenit_windows_user_locale(out: [*]u8, capacity: u32) u32;

/// The system UI font family (CSS `system-ui`): Windows' message font, e.g. "Segoe UI", or
/// "Microsoft YaHei UI" on a Chinese system. Null when the system does not report one.
pub fn systemUiFamily(buffer: []u8) ?[:0]const u8 {
    const length = zenit_windows_system_ui_family(buffer.ptr, @intCast(buffer.len));
    if (length == 0 or length >= buffer.len) return null;
    return buffer[0..length :0];
}

/// The user's UI language (BCP-47, e.g. "zh-CN"). Null when the system does not report one.
pub fn userLocale(buffer: []u8) ?[:0]const u8 {
    const length = zenit_windows_user_locale(buffer.ptr, @intCast(buffer.len));
    if (length == 0 or length >= buffer.len) return null;
    return buffer[0..length :0];
}
extern fn zenit_dwrite_font_weight(font: *anyopaque) u32;
extern fn zenit_dwrite_font_italic(font: *anyopaque) c_int;
extern fn zenit_dwrite_release_font(font: *anyopaque) void;
extern fn zenit_dwrite_measure_utf8(font: *anyopaque, text: [*]const u8, length: u32) f32;
extern fn zenit_dwrite_ascent(font: *anyopaque) f32;
extern fn zenit_dwrite_descent(font: *anyopaque) f32;
extern fn zenit_dwrite_leading(font: *anyopaque) f32;
extern fn zenit_dwrite_glyph_index(font: *anyopaque, codepoint: u32) u32;
extern fn zenit_dwrite_font_has_color_glyphs(font: *anyopaque) c_int;
extern fn zenit_dwrite_rasterize_glyph_context(
    context: ?*anyopaque,
    font: *anyopaque,
    glyph_index: u32,
    scale: f32,
    offset_x: f32,
    offset_y: f32,
    cleartype: u32,
    pixels: *?[*]u8,
    width: *u32,
    height: *u32,
    bearing_x: *i32,
    bearing_y: *i32,
    advance: *i32,
    is_color: *u32,
) c_int;
extern fn zenit_dwrite_free_bitmap(pixels: ?[*]u8) void;

const NativeGlyph = extern struct {
    glyph_index: u32,
    cluster: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
    flags: u32,
    fallback: ?*anyopaque,
};
extern fn zenit_dwrite_free_shaped_glyphs(glyphs: ?[*]NativeGlyph) void;
extern fn zenit_dwrite_retain_font(font: *anyopaque) void;
extern fn zenit_dwrite_font_size(font: *anyopaque) f32;
extern fn zenit_dwrite_wrap_fallback_font(source: *anyopaque, locale: [*:0]const u8) ?*anyopaque;
extern fn zenit_dwrite_font_metadata_string(font: *anyopaque, locale: c_int, out: [*]u8, capacity: u32) u32;
extern fn zenit_dwrite_font_identity(font: *anyopaque) u64;
extern fn zenit_dwrite_font_debug_name(font: *anyopaque, out: [*]u8, capacity: u32) u32;

fn nativeDebugName(allocator: std.mem.Allocator, ref: *anyopaque) ?[]u8 {
    var buffer: [1200]u8 = undefined;
    const length = zenit_dwrite_font_debug_name(ref, &buffer, buffer.len);
    if (length == 0 or length >= buffer.len) return null;
    return allocator.dupe(u8, buffer[0..length]) catch null;
}

const NativeCaretStop = extern struct {
    byte_offset: u32,
    primary_x: f32,
    secondary_x: f32,
    has_secondary: u32,
};
const NativeLineMetrics = extern struct {
    width: f32,
    ascent: f32,
    descent: f32,
    leading: f32,
    base_rtl: u32,
};

pub fn releaseFallbackFontRef(ref: *anyopaque) void {
    zenit_dwrite_release_font(ref);
}
pub fn retainFallbackFontRef(ref: *anyopaque) void {
    zenit_dwrite_retain_font(ref);
}
pub fn fallbackFontRefSize(ref: *anyopaque) f32 {
    return zenit_dwrite_font_size(ref);
}
pub fn fallbackFontRefIdentityHash(ref: *anyopaque) u64 {
    const size = zenit_dwrite_font_size(ref);
    const face = zenit_dwrite_font_identity(ref);
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&face));
    hash.update(std.mem.asBytes(&size));
    return hash.final();
}
pub fn fallbackFontRefDebugName(allocator: std.mem.Allocator, ref: *anyopaque) ?[]u8 {
    if (nativeDebugName(allocator, ref)) |name| return name;
    return std.fmt.allocPrint(allocator, "DirectWrite fallback {d:.1}px", .{fallbackFontRefSize(ref)}) catch null;
}

/// Explicit source-font spans in UTF-8 bytes. Fonts are borrowed only during
/// init; the resulting snapshot owns native font references and its text.
pub const FontRange = struct {
    font: *Font,
    start: u32,
    length: u32,
    size: f32,
    /// null preserves the source font style; true requests native italic.
    italic: ?bool = null,
};
const NativeFontRange = extern struct { font: *anyopaque, start: u32, length: u32, size: f32, italic_override: i32 };
extern fn zenit_dwrite_create_font_ranges(?[*]const NativeFontRange, u32, u32) ?*anyopaque;
extern fn zenit_dwrite_release_font_ranges(*anyopaque) void;
extern fn zenit_dwrite_measure_utf8_with_ranges(*anyopaque, [*]const u8, u32, ?*anyopaque) f32;
extern fn zenit_dwrite_shape_utf8_with_ranges(*anyopaque, [*]const u8, u32, c_int, *?[*]NativeGlyph, *u32, ?*anyopaque) c_int;
extern fn zenit_dwrite_line_caret_stops_with_ranges(*anyopaque, [*]const u8, u32, [*]const u32, u32, [*]NativeCaretStop, *NativeLineMetrics, ?*anyopaque) c_int;

/// Windows owned font-selection snapshot. Move this value; do not copy it.
/// Native consumers may borrow `native` until deinit, or retain it explicitly.
pub const FontRanges = struct {
    allocator: std.mem.Allocator,
    native: *anyopaque,
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8, ranges: []const FontRange) !FontRanges {
        // The native limit is 1M UTF-16 units, whose UTF-8 representation cannot
        // exceed 4M bytes. Bound temporary allocations before decoding input.
        if (content.len > 4 * 1048576) return error.TextTooLong;
        if (ranges.len > 65536) return error.TooManyFontRanges;
        const view = std.unicode.Utf8View.init(content) catch return error.InvalidUtf8;
        const specs = try allocator.alloc(NativeFontRange, ranges.len);
        defer allocator.free(specs);
        var utf16_length: u32 = 0;
        var byte: u32 = 0;
        var iter = view.iterator();
        var previous_end: u32 = 0;
        for (ranges, specs) |range, *spec| {
            if (!std.math.isFinite(range.size) or range.size <= 0 or range.length == 0 or
                range.start < previous_end or range.start > content.len or range.length > content.len - range.start)
                return error.InvalidFontRange;
            const end = range.start + range.length;
            try advanceTo(&iter, &byte, &utf16_length, range.start);
            const start = utf16_length;
            try advanceTo(&iter, &byte, &utf16_length, end);
            spec.* = .{ .font = range.font.native, .start = start, .length = utf16_length - start, .size = range.size, .italic_override = if (range.italic) |italic| (if (italic) @as(i32, 1) else 0) else -1 };
            previous_end = end;
        }
        try advanceTo(&iter, &byte, &utf16_length, @intCast(content.len));
        if (utf16_length > 1048576) return error.TextTooLong;
        const owned = try allocator.dupe(u8, content);
        errdefer allocator.free(owned);
        const native = zenit_dwrite_create_font_ranges(specs.ptr, @intCast(specs.len), utf16_length) orelse return error.FontRangesCreationFailed;
        return .{ .allocator = allocator, .native = native, .content = owned };
    }
    // One scan and O(range count) temporary memory; no per-byte offset table.
    fn advanceTo(iter: *std.unicode.Utf8Iterator, byte: *u32, wide: *u32, target: u32) !void {
        while (byte.* < target) {
            const slice = iter.nextCodepointSlice() orelse return error.InvalidFontRangeBoundary;
            const cp = std.unicode.utf8Decode(slice) catch unreachable;
            byte.* += @intCast(slice.len);
            wide.* += if (cp > 0xffff) @as(u32, 2) else 1;
        }
        if (byte.* != target) return error.InvalidFontRangeBoundary;
    }
    pub fn deinit(self: *FontRanges) void {
        zenit_dwrite_release_font_ranges(self.native);
        self.allocator.free(self.content);
        self.* = undefined;
    }
    pub fn validateText(self: *const FontRanges, content: []const u8) !void {
        if (!std.mem.eql(u8, self.content, content)) return error.FontRangeTextMismatch;
    }
};

pub const FontSystem = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    default_family: ?[]const u8 = null,
    default_locale: [:0]const u8 = "en-us",

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !FontSystem {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *FontSystem) void {
        _ = self;
    }

    pub fn setDefaultFamily(self: *FontSystem, family: ?[]const u8) void {
        self.default_family = family;
    }

    pub fn setDefaultLocale(self: *FontSystem, locale: [:0]const u8) void {
        self.default_locale = locale;
    }

    pub fn loadFont(self: *FontSystem, path: [:0]const u8, size: u32) !*Font {
        const native = zenit_dwrite_load_font(path.ptr, self.default_locale.ptr, @floatFromInt(size)) orelse return error.FontLoadFailed;
        errdefer zenit_dwrite_release_font(native);
        var family_buffer: [4096]u8 = undefined;
        const length = zenit_dwrite_font_family_name(native, &family_buffer, family_buffer.len);
        if (length == 0) return error.FontFamilyNameFailed;
        const family = try self.allocator.dupeSentinel(u8, family_buffer[0..length], 0);
        errdefer self.allocator.free(family);
        const locale = try self.allocator.dupeSentinel(u8, self.default_locale, 0);
        errdefer self.allocator.free(locale);
        const font = try self.allocator.create(Font);
        font.* = .{
            .allocator = self.allocator,
            .native = native,
            .family = family,
            .locale = locale,
            .size_px = @floatFromInt(size),
            .weight = @intCast(zenit_dwrite_font_weight(native)),
            .italic = zenit_dwrite_font_italic(native) != 0,
        };
        return font;
    }

    pub fn findFont(self: *FontSystem, descriptor: types.FontDescriptor) !*Font {
        var system_ui: [256]u8 = undefined;
        const family = if (self.default_family != null and std.mem.eql(u8, descriptor.family, "system"))
            self.default_family.?
        else if (std.mem.eql(u8, descriptor.family, "system-ui"))
            systemUiFamily(&system_ui) orelse return error.FontNotFound
        else
            descriptor.family;
        const owned_family = try self.allocator.dupeSentinel(u8, family, 0);
        errdefer self.allocator.free(owned_family);
        const owned_locale = try self.allocator.dupeSentinel(u8, self.default_locale, 0);
        errdefer self.allocator.free(owned_locale);
        const weight: u16 = switch (descriptor.weight) {
            .thin => 100,
            .light => 300,
            .regular => 400,
            .medium => 500,
            .semibold => 600,
            .bold => 700,
            .heavy => 800,
            .black => 900,
        };
        const native = zenit_dwrite_find_font(owned_family.ptr, owned_locale.ptr, descriptor.size, weight, if (descriptor.style == .italic) 1 else 0) orelse return error.FontNotFound;
        errdefer zenit_dwrite_release_font(native);
        const font = try self.allocator.create(Font);
        font.* = .{
            .allocator = self.allocator,
            .native = native,
            .family = owned_family,
            .locale = owned_locale,
            .size_px = descriptor.size,
            .weight = weight,
            .italic = descriptor.style == .italic,
        };
        return font;
    }
};

pub const FontManager = FontSystem;

pub const Font = struct {
    allocator: std.mem.Allocator,
    native: *anyopaque,
    family: [:0]u8,
    locale: [:0]u8,
    size_px: f32,
    weight: u16,
    italic: bool,
    scale_factor: f32 = 1,
    /// Platform font smoothing (macOS only; DirectWrite has none to turn off): written by the text
    /// renderer, ignored here and kept out of the glyph atlas key (honors_smoothing).
    smooth_fonts: bool = true,
    cleartype: bool = false,
    pub const honors_smoothing = false;
    pub const layout_selects_faces = true;

    /// Independently own a shaped run's native fallback face and metadata.
    pub fn fromFallbackRef(allocator: std.mem.Allocator, ref: *anyopaque, prototype: *const Font) !*Font {
        const size = fallbackFontRefSize(ref);
        if (!std.math.isFinite(size) or size <= 0) return error.InvalidFallbackFontSize;
        const native = zenit_dwrite_wrap_fallback_font(ref, prototype.locale.ptr) orelse return error.FallbackFontWrapFailed;
        errdefer zenit_dwrite_release_font(native);
        var buffer: [4096]u8 = undefined;
        const family_len = zenit_dwrite_font_metadata_string(native, 0, &buffer, buffer.len);
        if (family_len == 0) return error.MissingFallbackFontFamily;
        const family = try allocator.dupeSentinel(u8, buffer[0 .. family_len - 1], 0);
        errdefer allocator.free(family);
        const locale_len = zenit_dwrite_font_metadata_string(native, 1, &buffer, buffer.len);
        if (locale_len == 0) return error.MissingFallbackFontLocale;
        const locale = try allocator.dupeSentinel(u8, buffer[0 .. locale_len - 1], 0);
        errdefer allocator.free(locale);
        const font = try allocator.create(Font);
        font.* = .{ .allocator = allocator, .native = native, .family = family, .locale = locale, .size_px = size, .weight = @intCast(zenit_dwrite_font_weight(native)), .italic = zenit_dwrite_font_italic(native) != 0, .scale_factor = prototype.scale_factor };
        return font;
    }

    pub fn deinit(self: *Font) void {
        zenit_dwrite_release_font(self.native);
        self.allocator.free(self.family);
        self.allocator.free(self.locale);
        self.allocator.destroy(self);
    }

    pub fn derive(self: *const Font, new_size: f32) !*Font {
        const size = @max(new_size, 1);
        const native = zenit_dwrite_derive_font(self.native, size) orelse return error.FontDeriveFailed;
        errdefer zenit_dwrite_release_font(native);
        const family = try self.allocator.dupeSentinel(u8, self.family, 0);
        errdefer self.allocator.free(family);
        const locale = try self.allocator.dupeSentinel(u8, self.locale, 0);
        errdefer self.allocator.free(locale);
        const derived = try self.allocator.create(Font);
        derived.* = .{ .allocator = self.allocator, .native = native, .family = family, .locale = locale, .size_px = size, .weight = self.weight, .italic = self.italic, .scale_factor = self.scale_factor };
        return derived;
    }

    pub fn setScaleFactor(self: *Font, scale: f32) void {
        self.scale_factor = if (scale > 0) scale else 1;
    }
    pub fn pixelSize(self: *const Font) f32 {
        return self.size_px;
    }
    pub fn debugName(self: *const Font, allocator: std.mem.Allocator) ?[]u8 {
        if (nativeDebugName(allocator, self.native)) |name| return name;
        return std.fmt.allocPrint(allocator, "DirectWrite {s} {d:.1}px", .{ self.family, self.size_px }) catch null;
    }
    pub fn getAscent(self: *Font) f32 {
        return zenit_dwrite_ascent(self.native);
    }
    pub fn getDescent(self: *Font) f32 {
        return zenit_dwrite_descent(self.native);
    }
    pub fn getLeading(self: *Font) f32 {
        return zenit_dwrite_leading(self.native);
    }
    pub fn glyphIndexForCodepoint(self: *const Font, codepoint: u32) u32 {
        return zenit_dwrite_glyph_index(self.native, codepoint);
    }
    pub fn hasColorGlyphs(self: *const Font) bool {
        return zenit_dwrite_font_has_color_glyphs(self.native) != 0;
    }

    pub fn measureWidth(self: *const Font, text: []const u8) f32 {
        if (text.len == 0 or text.len > std.math.maxInt(u32)) return 0;
        return zenit_dwrite_measure_utf8(self.native, text.ptr, @intCast(text.len));
    }

    /// The caller and painter can share this exact selection snapshot.
    pub fn measureWidthWithRanges(self: *const Font, content: []const u8, ranges: *const FontRanges) !f32 {
        try ranges.validateText(content);
        return zenit_dwrite_measure_utf8_with_ranges(self.native, content.ptr, @intCast(content.len), ranges.native);
    }

    pub fn rasterizeGlyph(self: *Font, glyph_index: u32) !GlyphBitmap {
        return self.rasterizeGlyphSubpixel(glyph_index, 0, 0);
    }

    pub fn rasterizeGlyphSubpixel(self: *Font, glyph_index: u32, offset_x: f32, offset_y: f32) !GlyphBitmap {
        return self.rasterizeGlyphWithContext(glyph_index, offset_x, offset_y, null);
    }

    pub fn rasterizeGlyphWithContext(self: *Font, glyph_index: u32, offset_x: f32, offset_y: f32, context: ?*anyopaque) !GlyphBitmap {
        var raw: ?[*]u8 = null;
        var width: u32 = 0;
        var height: u32 = 0;
        var bearing_x: i32 = 0;
        var bearing_y: i32 = 0;
        var advance: i32 = 0;
        var is_color: u32 = 0;
        const status = zenit_dwrite_rasterize_glyph_context(context, self.native, glyph_index, self.scale_factor, offset_x, offset_y, @intFromBool(self.cleartype), &raw, &width, &height, &bearing_x, &bearing_y, &advance, &is_color);
        if (status == 2) return error.GlyphTooLarge;
        if (status != 0) return error.GlyphRasterizationFailed;
        defer zenit_dwrite_free_bitmap(raw);
        const pixels = try self.allocator.alloc(u8, @as(usize, width) * height * @as(usize, if (is_color != 0) 4 else 1));
        if (raw) |source| @memcpy(pixels, source[0..pixels.len]);
        return .{ .pixels = pixels, .width = width, .height = height, .bearing_x = bearing_x, .bearing_y = bearing_y, .advance = advance, .is_color = is_color == 1, .is_cleartype = is_color == 2 };
    }

    pub fn lineCaretStops(self: *const Font, text: []const u8, boundaries: []const u32, out: []types.LineCaretStop) !types.LineMetrics {
        return self.lineCaretStopsWithRanges(text, boundaries, out, null);
    }

    pub fn lineCaretStopsWithRanges(self: *const Font, text: []const u8, boundaries: []const u32, out: []types.LineCaretStop, ranges: ?*const FontRanges) !types.LineMetrics {
        if (ranges) |snapshot| try snapshot.validateText(text);
        if (boundaries.len == 0 or out.len < boundaries.len) return error.InvalidCaretBuffer;
        if (text.len > std.math.maxInt(u32) or boundaries.len > std.math.maxInt(u32)) return error.TextTooLong;
        const native = try self.allocator.alloc(NativeCaretStop, boundaries.len);
        defer self.allocator.free(native);
        var metrics: NativeLineMetrics = undefined;
        if (zenit_dwrite_line_caret_stops_with_ranges(self.native, text.ptr, @intCast(text.len), boundaries.ptr, @intCast(boundaries.len), native.ptr, &metrics, if (ranges) |r| r.native else null) != 0)
            return error.TextCaretExtractionFailed;
        for (native, out[0..boundaries.len]) |source, *destination| {
            destination.* = .{ .byte_offset = source.byte_offset, .primary_x = source.primary_x, .secondary_x = source.secondary_x, .has_secondary = source.has_secondary != 0 };
        }
        return .{ .width = metrics.width, .ascent = metrics.ascent, .descent = metrics.descent, .leading = metrics.leading, .base_rtl = metrics.base_rtl != 0 };
    }
};

pub const TextShaper = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) !TextShaper {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *TextShaper) void {
        _ = self;
    }
    pub fn shape(self: *TextShaper, text: []const u8, font: *Font) ![]ShapedGlyph {
        return self.shapeWithOptions(text, font, false);
    }
    pub fn shapeWithOptions(self: *TextShaper, text: []const u8, font: *Font, use_italic: bool) ![]ShapedGlyph {
        return self.shapeWithRanges(text, font, use_italic, null);
    }

    pub fn shapeWithRanges(self: *TextShaper, text: []const u8, font: *Font, use_italic: bool, ranges: ?*const FontRanges) ![]ShapedGlyph {
        if (ranges) |snapshot| try snapshot.validateText(text);
        if (text.len > std.math.maxInt(u32)) return error.TextTooLong;
        var native: ?[*]NativeGlyph = null;
        var count: u32 = 0;
        if (zenit_dwrite_shape_utf8_with_ranges(font.native, text.ptr, @intCast(text.len), if (use_italic) 1 else 0, &native, &count, if (ranges) |r| r.native else null) != 0) return error.TextShapingFailed;
        defer zenit_dwrite_free_shaped_glyphs(native);
        errdefer if (native) |items| {
            for (items[0..count]) |glyph| if (glyph.fallback) |ref| releaseFallbackFontRef(ref);
        };
        const glyphs = try self.allocator.alloc(ShapedGlyph, count);
        if (native) |items| for (items[0..count], glyphs) |source, *destination| {
            destination.* = .{
                .glyph_index = source.glyph_index,
                .cluster = source.cluster,
                .x_advance = source.x_advance,
                .y_advance = source.y_advance,
                .x_offset = source.x_offset,
                .y_offset = source.y_offset,
                .is_fallback_font = source.flags & 1 != 0,
                .fallback_font_ref = source.fallback,
            };
        };
        return glyphs;
    }
};
