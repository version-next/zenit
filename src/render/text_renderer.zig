/// Metal Text Renderer - GPU-instanced text rendering
///
/// HarfBuzz text shaping, FreeType glyph rasterization
/// GPU-instanced render for high-perf text drawing.
const std = @import("std");
const builtin = @import("builtin");
const idle_storage = @import("idle_storage.zig");
const SlotBuffer = @import("slot_buffer.zig").SlotBuffer;
const gpu = @import("gpu");
const shape_clip_pair = @import("shape_clip_pair.zig");
const text_module = @import("text");
const Font = text_module.Font;
const TextShaper = text_module.TextShaper;
const atlas_mod = @import("glyph_atlas.zig");
const GlyphAtlas = atlas_mod.GlyphAtlas;
const font_stack_mod = @import("font_fallback_stack.zig");
const FontFallbackStack = font_stack_mod.FontFallbackStack;
const text_trace = @import("trace").text_flicker;

/// Text shader source (single source of truth).
const text_shader_source: []const u8 = @import("shader_sources.zig").text;
const MAX_CLIP_POLYGON_POINTS = 32;
const MAX_CLIP_POLYGON_CONTOURS = 8;

const NativeRaster = struct {
    extern fn zenit_dwrite_raster_context_create() ?*anyopaque;
    extern fn zenit_dwrite_raster_context_destroy(?*anyopaque) void;
    extern fn zenit_dwrite_raster_context_refresh(?*anyopaque, ?*anyopaque, u64, *[8]f32) c_int;
};

/// Uniforms struct (must match shader).
const Uniforms = extern struct {
    viewport_size: [2]f32, // Physical pixels.
    scale_factor: f32,
    clip_shape_kind: u32 = 0,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    /// Keeps the polygon arrays on a 16-byte (cbuffer register) boundary after `clip_radii`.
    _clip_pad: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0)),
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 })),
    dwrite_gamma: if (builtin.os.tag == .windows) [4]f32 else [0]f32 = undefined,
    dwrite_settings: if (builtin.os.tag == .windows) [4]f32 else [0]f32 = undefined,
    /// Second shape clip (shape_clip_pair.zig); zero-sized off Metal.
    clip2: shape_clip_pair.Field = shape_clip_pair.none,
};

// Shared clip header ABI (Metal struct / HLSL cbuffer / GLSL std140): per-corner radii sit on their own
// 16-byte register and the polygon arrays start at the next one.
comptime {
    std.debug.assert(@offsetOf(Uniforms, "clip_rect") == 16);
    std.debug.assert(@offsetOf(Uniforms, "clip_radii") == 32);
    std.debug.assert(@offsetOf(Uniforms, "clip_fill_rule") == 48);
    std.debug.assert(@offsetOf(Uniforms, "clip_polygon_end_points") == 64);
    std.debug.assert(@offsetOf(Uniforms, "clip_polygon_points") == 96);
}

comptime {
    if (builtin.os.tag == .windows and (@offsetOf(Uniforms, "dwrite_gamma") != 352 or @offsetOf(Uniforms, "dwrite_settings") != 368 or @sizeOf(Uniforms) != 384))
        @compileError("DirectWrite runtime uniforms do not match text.hlsl cbuffer layout");
}

/// Packed 32-bit glyph metadata for Metal: bits 0..7 page, 8..9 color mode, 10 snap, 11..31 zero.
const MetalGlyphMetadata = extern struct {
    flags: u32 = 0,

    pub fn init(page: u8, color_mode: u2, snap: bool) MetalGlyphMetadata {
        return .{
            .flags = @as(u32, page) | (@as(u32, color_mode) << 8) | (@as(u32, @intFromBool(snap)) << 10),
        };
    }

    pub fn pageIndex(self: MetalGlyphMetadata) u8 {
        return @truncate(self.flags & 0xFF);
    }

    pub fn colorMode(self: MetalGlyphMetadata) u2 {
        return @truncate((self.flags >> 8) & 0x3);
    }

    pub fn snaps(self: MetalGlyphMetadata) bool {
        return (self.flags >> 10) & 1 != 0;
    }
};

/// Legacy float metadata for non-Metal backends; matches original GlyphInstance trailing fields
/// (stride 80) and shader bytes exactly.
const LegacyGlyphMetadata = extern struct {
    page_index: f32 = 0,
    is_color: f32 = 0,
    shader_snap: f32 = 1,

    pub fn init(page: u8, color_mode: u2, snap: bool) LegacyGlyphMetadata {
        return .{
            .page_index = @floatFromInt(page),
            .is_color = @floatFromInt(color_mode),
            .shader_snap = if (snap) 1 else 0,
        };
    }

    pub fn pageIndex(self: LegacyGlyphMetadata) u8 {
        return @intFromFloat(self.page_index);
    }

    pub fn colorMode(self: LegacyGlyphMetadata) u2 {
        return @intFromFloat(self.is_color);
    }

    pub fn snaps(self: LegacyGlyphMetadata) bool {
        return self.shader_snap > 0.5;
    }
};

const GlyphMetadata = if (gpu.backend_kind == .metal) MetalGlyphMetadata else LegacyGlyphMetadata;

// The wire uses a fixed 4096 normalized-UV grid, independent of physical pages.
// Both power-of-two page sizes divide that grid: 2048 texels encode as even
// coordinates. Keep shader decoding and instance layout unchanged.
comptime {
    for (.{ atlas_mod.GlyphAtlas.ATLAS_SIZE, atlas_mod.GlyphAtlas.SMALL_ATLAS_SIZE, atlas_mod.GlyphAtlas.FIRST_PAGE_SIZE }) |size| {
        if (size == 0 or 4096 % size != 0 or (size & (size - 1)) != 0)
            @compileError("atlas page must be a power-of-two divisor of 4096 UV grid");
    }
}
const atlas_size_f: f32 = 4096.0;

/// Metal UV compression: normalized UV multiplied by 4096 stored as u16.
/// These are physical texels only for 4096 pages; 2048 texels map to even values.
const MetalGlyphUV = extern struct {
    texels: [4]u16,

    pub fn init(v: [4]f32) MetalGlyphUV {
        if (builtin.mode == .debug) {
            for (v) |u| {
                std.debug.assert(std.math.isFinite(u));
                std.debug.assert(u >= 0.0 and u <= 1.0);
                const t = u * atlas_size_f;
                // Integer wire grid: every supported physical texel lands exactly on it.
                std.debug.assert(t == @trunc(t));
            }
        }
        return .{ .texels = .{
            @intFromFloat(v[0] * atlas_size_f),
            @intFromFloat(v[1] * atlas_size_f),
            @intFromFloat(v[2] * atlas_size_f),
            @intFromFloat(v[3] * atlas_size_f),
        } };
    }

    pub fn normalized(self: MetalGlyphUV) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.texels[0])) / atlas_size_f,
            @as(f32, @floatFromInt(self.texels[1])) / atlas_size_f,
            @as(f32, @floatFromInt(self.texels[2])) / atlas_size_f,
            @as(f32, @floatFromInt(self.texels[3])) / atlas_size_f,
        };
    }
};

/// Legacy UV: byte-exact identity with the original [4]f32 wire format; arbitrary floats preserved.
const LegacyGlyphUV = extern struct {
    values: [4]f32,

    pub fn init(v: [4]f32) LegacyGlyphUV {
        return .{ .values = v };
    }

    pub fn normalized(self: LegacyGlyphUV) [4]f32 {
        return self.values;
    }
};

/// Backend-selected UV representation.
const GlyphUV = if (gpu.backend_kind == .metal) MetalGlyphUV else LegacyGlyphUV;

/// Glyph instance wire format; Metal uses packed vectors and exact flags.
const GlyphInstance = extern struct {
    position: [2]f32, // Glyph bottom-left position.
    size: [2]f32, // Glyph size.
    uv_rect: GlyphUV, // UV rect (u_min, v_min, u_max, v_max); Metal stores exact 4096-grid texels.
    color: [4]f32, // Color RGBA.
    rect_clip: [4]f32 = .{ 0, 0, -1, -1 }, // x, y, w, h (logical pixels); negative size = disabled.
    skew_x: f32 = 0, // Synthetic italic x offset (logical pixels).
    metadata: GlyphMetadata = GlyphMetadata.init(0, 0, true),
};

/// Starting per-slot instance capacity; slots grow with the frame's glyph count
/// (all flushes of a frame append to one buffer, never wrapping, because
/// deferred command execution would read overwritten ranges).
const MIN_INSTANCE_BYTES = @sizeOf(GlyphInstance) * 1024;
const MAX_UNIFORM_UPDATES = 512;
// D3D12 CBV addresses require 256-byte alignment. Append aligned slots so
// normal shared draws can bind the retained frame buffer without snapshots.
// D3D12 CBV addresses need 256-byte alignment; Metal buffer offsets need 16.
const UNIFORM_STRIDE = std.mem.alignForward(usize, @sizeOf(Uniforms), if (gpu.is_direct3d) 256 else 16);

/// Triple-buffering constant.
const BUFFER_COUNT = 3;

/// Color constant.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const WHITE = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const BLACK = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const RED = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const GREEN = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const BLUE = Color{ .r = 0, .g = 0, .b = 1, .a = 1 };

    pub fn toArray(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }
};

// -- Segment-level Shaping Cache ------
// Inspired by Chrome/Blink word-level cache: split text by shaping equivalence to min segment,
// CJK single char standalone cache (no ligature), ASCII word + tail space one segment.
// Inline storage kill all alloc/free, deterministic memory ~5.5MB.

/// Segment split result.
const Segment = struct {
    start: u32,
    end: u32,
};

/// Max segments on stack (over -> fallback whole-line cache).
const MAX_SEGMENTS = 256;

/// Segment-level cache: max inline glyphs per segment.
///
/// Segments over this cap are re-shaped every frame. Code identifiers/call expressions are
/// usually 12-32 glyphs; a cap of 12 re-shapes them all per frame and burns encode time in
/// CTLineCreateWithAttributedString. 32 covers most code tokens; longer segments take the
/// owned path, and explicit cache_long_segments enters the bounded spill cache.
const MAX_SEGMENT_GLYPHS = 32;

/// Segment-level cache key.
const SegmentCacheKey = struct {
    content_hash: u64, // Wyhash(segment text).
    font_ptr: usize, // Font pointer.
    flags: u8, // bit0: use_italic
};

/// Exact-size shaped slice. The cache adopts the shaper allocation without copying.
const SegmentCacheEntry = struct {
    glyphs: []text_module.ShapedGlyph,
    frame_last_used: u64 = 0,
};

/// Bounded spill cache for long shaped segments. Ownership transfers only on
/// successful insertion; glyph fallback font refs remain owned by that slice.
const LongSegmentCache = struct {
    const max_entries = 64;
    const max_glyphs = 1024;
    const Entry = struct {
        text: []u8,
        glyphs: []text_module.ShapedGlyph,
        frame: u64,
    };
    entries: std.AutoHashMapUnmanaged(SegmentCacheKey, Entry) = .{},

    fn get(self: *LongSegmentCache, key: SegmentCacheKey, text: []const u8, frame: u64) ?[]const text_module.ShapedGlyph {
        const entry = self.entries.getPtr(key) orelse return null;
        if (!std.mem.eql(u8, entry.text, text)) return null;
        entry.frame = frame;
        return entry.glyphs;
    }

    fn release(allocator: std.mem.Allocator, entry: Entry) void {
        TextRenderer.releaseGlyphFallbackFontRefs(entry.glyphs);
        allocator.free(entry.glyphs);
        allocator.free(entry.text);
    }

    fn adopt(self: *LongSegmentCache, allocator: std.mem.Allocator, key: SegmentCacheKey, text: []const u8, glyphs: []text_module.ShapedGlyph, frame: u64) bool {
        if (glyphs.len > max_glyphs or text.len > max_glyphs * 4) return false;
        const owned_text = allocator.dupe(u8, text) catch return false;
        self.entries.ensureUnusedCapacity(allocator, 1) catch {
            allocator.free(owned_text);
            return false;
        };
        if (self.entries.fetchRemove(key)) |old| release(allocator, old.value);
        if (self.entries.count() >= max_entries) {
            var oldest: ?SegmentCacheKey = null;
            var oldest_frame: u64 = std.math.maxInt(u64);
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (oldest == null or entry.value_ptr.frame < oldest_frame) {
                    oldest = entry.key_ptr.*;
                    oldest_frame = entry.value_ptr.frame;
                }
            }
            if (self.entries.fetchRemove(oldest.?)) |old| release(allocator, old.value);
        }
        self.entries.putAssumeCapacity(key, .{ .text = owned_text, .glyphs = glyphs, .frame = frame });
        return true;
    }

    /// Drop entries last used before `frame`.
    fn trimBefore(self: *LongSegmentCache, allocator: std.mem.Allocator, frame: u64) void {
        var stale: [max_entries]SegmentCacheKey = undefined;
        var count: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.frame < frame and count < stale.len) {
                stale[count] = entry.key_ptr.*;
                count += 1;
            }
        }
        for (stale[0..count]) |key| {
            if (self.entries.fetchRemove(key)) |old| release(allocator, old.value);
        }
    }

    fn deinit(self: *LongSegmentCache, allocator: std.mem.Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| release(allocator, entry.*);
        self.entries.deinit(allocator);
        self.* = .{};
    }
};

// Layout measures overlapping prefixes and identical layers before drawing. Cache
// exact results only within one frame; owned text verifies hash collisions and
// avoids retaining caller buffers. Both entry count and text bytes are bounded.
const WidthCache = struct {
    const Key = struct {
        hash: u64,
        font: usize,
        size: u32,
        physical_size: u32,
        scale: u32,
        advance: u32,
        italic: bool,
    };
    const Entry = struct { text: []u8, width: f32 };
    entries: std.AutoHashMapUnmanaged(Key, Entry) = .{},
    bytes: usize = 0,

    fn get(self: *const WidthCache, key: Key, text: []const u8) ?f32 {
        const entry = self.entries.get(key) orelse return null;
        return if (std.mem.eql(u8, entry.text, text)) entry.width else null;
    }

    fn put(self: *WidthCache, allocator: std.mem.Allocator, key: Key, text: []const u8, width: f32) void {
        if (self.entries.count() >= 4096 or text.len > 2 * 1024 * 1024 - self.bytes) return;
        const owned = allocator.dupe(u8, text) catch return;
        const slot = self.entries.getOrPut(allocator, key) catch {
            allocator.free(owned);
            return;
        };
        if (slot.found_existing) {
            self.bytes -= slot.value_ptr.text.len;
            allocator.free(slot.value_ptr.text);
        }
        slot.value_ptr.* = .{ .text = owned, .width = width };
        self.bytes += text.len;
    }

    fn clear(self: *WidthCache, allocator: std.mem.Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| allocator.free(entry.text);
        self.entries.clearRetainingCapacity();
        self.bytes = 0;
    }

    fn deinit(self: *WidthCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.entries.deinit(allocator);
    }
};

/// Max entry count. Entry inline array: 32 glyph x 40B + head ~ 1.3KB, 8K entry ~ 10.6MB
/// deterministic memory (~ 16 screen code working set). MAX_SEGMENT_GLYPHS up to 32 sync drop from
/// 16K,
/// total memory same old config.
const SEGMENT_CACHE_MAX = 8192;

/// CoreText fallback font wrapper cache limit.
/// run-level CTFontRef may not stable pointer, must cap growth.
const FALLBACK_FONT_CACHE_MAX = 256;
var font_debug_budget: u32 = 12;

const FallbackFontCacheEntry = struct {
    font: *Font,
    frame_last_used: u64,
};

/// Primary font coverage check cache key: cmap coverage is (font, codepoint) pure function.
/// Only long-lived fonts (selector slot / derived cache) come as primary. Using the pointer as
/// key is safe here and does not conflict with the lesson that a run-level CTFontRef pointer is
/// unstable for fallback wrappers: those are temporary instances CoreText creates on the fly,
/// whereas these fonts are owned by us.
const PrimaryCovKey = struct { font_ptr: usize, cp: u21 };
const PRIMARY_COVERAGE_CACHE_MAX = 16384;

fn containsEnclosedDigit(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            i += seq_len;
            continue;
        };
        if (cp >= 0x2460 and cp <= 0x2473) return true;
        i += seq_len;
    }
    return false;
}

/// Judge codepoint is CJK ideograph (no ligature, can shape solo).
fn isCJK(cp: u21) bool {
    return (cp >= 0x2E80 and cp <= 0x2EFF) or // CJK Radicals Supplement
        (cp >= 0x2F00 and cp <= 0x2FDF) or // Kangxi Radicals
        (cp >= 0x3000 and cp <= 0x303F) or // CJK Symbols and Punctuation
        (cp >= 0x3040 and cp <= 0x309F) or // Hiragana
        (cp >= 0x30A0 and cp <= 0x30FF) or // Katakana
        (cp >= 0x3100 and cp <= 0x312F) or // Bopomofo
        (cp >= 0x3130 and cp <= 0x318F) or // Hangul Compatibility Jamo
        (cp >= 0x31A0 and cp <= 0x31BF) or // Bopomofo Extended
        (cp >= 0x31F0 and cp <= 0x31FF) or // Katakana Phonetic Extensions
        (cp >= 0x3200 and cp <= 0x32FF) or // Enclosed CJK Letters
        (cp >= 0x3300 and cp <= 0x33FF) or // CJK Compatibility
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Unified Ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs
        (cp >= 0xA000 and cp <= 0xA48F) or // Yi Syllables
        (cp >= 0xA490 and cp <= 0xA4CF) or // Yi Radicals
        (cp >= 0xAC00 and cp <= 0xD7AF) or // Hangul Syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK Compatibility Forms
        (cp >= 0xFF00 and cp <= 0xFFEF) or // Halfwidth and Fullwidth Forms
        (cp >= 0x20000 and cp <= 0x2A6DF) or // CJK Unified Ext B
        (cp >= 0x2A700 and cp <= 0x2B73F) or // CJK Unified Ext C
        (cp >= 0x2B740 and cp <= 0x2B81F) or // CJK Unified Ext D
        (cp >= 0x2B820 and cp <= 0x2CEAF) or // CJK Unified Ext E
        (cp >= 0x2CEB0 and cp <= 0x2EBEF) or // CJK Unified Ext F
        (cp >= 0x2F800 and cp <= 0x2FA1F); // CJK Compatibility Supplement
}

/// BMP codepoints (below U+1F000) can have emoji presentation: followed by VS16 (U+FE0F) they
/// become color emoji (e.g. heart U+2764). They must also enter the emoji branch; otherwise
/// they drop to the "other Unicode per-codepoint solo" branch, base and VS16 are shaped
/// separately, CoreText can't see the combination and falls back to the single-color form with
/// the narrow width (12.742 vs 19.0), offsetting the cursor.
fn isEmojiCapable(cp: u21) bool {
    return (cp >= 0x2190 and cp <= 0x21FF) or // Arrows.
        (cp >= 0x2300 and cp <= 0x23FF) or // Technical symbols (stopwatch / timer / hourglass...).
        (cp >= 0x2460 and cp <= 0x24FF) or // Circled letters & digits.
        (cp >= 0x25A0 and cp <= 0x25FF) or // Geometric shapes.
        (cp >= 0x2600 and cp <= 0x27BF) or // Misc symbols + Dingbats (sun / star / heart / checkmark / sparkles...).
        (cp >= 0x2B00 and cp <= 0x2BFF) or // Misc symbols & arrows.
        (cp >= 0x1F000 and cp <= 0x1FAFF) or // Main emoji region (safety, actually covered by caller >= 0x1F000).
        cp == 0x203C or cp == 0x2049 or // ‼ ⁉
        cp == 0x2122 or cp == 0x2139 or // ™ ℹ
        cp == 0x3030 or cp == 0x303D or
        cp == 0x3297 or cp == 0x3299;
}

/// Keycap emoji sequence at `i`: `[0-9#*]` + optional VS16 (U+FE0F) + COMBINING ENCLOSING KEYCAP
/// (U+20E3), e.g. 3️⃣. Returns its byte length, 0 when `i` does not start one. The base is ASCII,
/// so without this the ASCII run swallows it and the keycap mark lands in a segment of its own:
/// CoreText then draws a text "3" and the bare enclosing mark (an empty frame) instead of the
/// emoji.
fn keycapLen(text: []const u8, i: u32) u32 {
    const b = text[i];
    if (!((b >= '0' and b <= '9') or b == '#' or b == '*')) return 0;
    var j = i + 1;
    if (j + 3 <= text.len and std.mem.eql(u8, text[j .. j + 3], "\u{FE0F}")) j += 3;
    if (j + 3 <= text.len and std.mem.eql(u8, text[j .. j + 3], "\u{20E3}")) return j + 3 - i;
    return 0;
}

/// Judge codepoint is ZWJ / Variation Selector (emoji sequence joiner).
fn isJoiner(cp: u21) bool {
    return cp == 0x200D or // ZWJ
        (cp >= 0xFE00 and cp <= 0xFE0F) or // Variation Selectors
        (cp >= 0xE0100 and cp <= 0xE01EF); // Variation Selectors Supplement
}

/// RTL script codepoint (Arabic / Hebrew & extension), include combiners used in these scripts.
/// RTL **must hand whole segment to CoreText**: 1. bidi (UAX#9) re-order is CTLine-level,
/// per-codepoint shape can't get;
/// 2. Arabic letter connect form (isolated/initial/medial/final) depend left/right neighbor, cut
///    breaks each letter
/// degrade isolated; 3. diacritic (harakat / niqqud) hang on base, cut become solo glyph.
fn isRtlScript(cp: u21) bool {
    return (cp >= 0x0590 and cp <= 0x05FF) or // Hebrew
        (cp >= 0x0600 and cp <= 0x06FF) or // Arabic
        (cp >= 0x0700 and cp <= 0x074F) or // Syriac
        (cp >= 0x0750 and cp <= 0x077F) or // Arabic Supplement
        (cp >= 0x0780 and cp <= 0x07BF) or // Thaana
        (cp >= 0x08A0 and cp <= 0x08FF) or // Arabic Extended-A
        (cp >= 0xFB1D and cp <= 0xFB4F) or // Hebrew Presentation Forms
        (cp >= 0xFB50 and cp <= 0xFDFF) or // Arabic Presentation Forms-A
        (cp >= 0xFE70 and cp <= 0xFEFF); // Arabic Presentation Forms-B
}

// Decode storage without splitting a UTF-16 pair formed across edit seams.
// Keep original byte lengths so cache clusters remain document offsets.
fn storageScalar(text: []const u8, offset: usize) ?struct { cp: u21, len: u32 } {
    const n = std.unicode.utf8ByteSequenceLength(text[offset]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (n > text.len - offset) return null;
    const cp = std.unicode.wtf8Decode(text[offset..][0..n]) catch return .{ .cp = 0xfffd, .len = n };
    if (cp >= 0xd800 and cp <= 0xdbff and text.len - offset >= n + 3) {
        const tail = text[offset + n ..][0..3];
        if (tail[0] == 0xed) {
            const low = std.unicode.wtf8Decode(tail) catch return .{ .cp = cp, .len = n };
            if (low >= 0xdc00 and low <= 0xdfff)
                return .{ .cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00), .len = n + 3 };
        }
    }
    return .{ .cp = cp, .len = n };
}

/// Split text by shaping equivalence to min cache unit.
/// Return segment count (0 = empty text), over MAX_SEGMENTS return MAX_SEGMENTS + 1 overflow.
fn segmentText(text: []const u8, out: *[MAX_SEGMENTS]Segment) u32 {
    if (text.len == 0) return 0;
    var seg_count: u32 = 0;
    var i: u32 = 0;
    const len: u32 = @intCast(text.len);

    while (i < len) {
        if (seg_count >= MAX_SEGMENTS) return MAX_SEGMENTS + 1; // Overflow.

        const byte = text[i];
        const scalar = storageScalar(text, i) orelse break;
        const cp_len = scalar.len;
        const cp = scalar.cp;

        if (isCJK(cp)) {
            // CJK: each codepoint solo segment.
            out[seg_count] = .{ .start = i, .end = i + cp_len };
            seg_count += 1;
            i += cp_len;
        } else if (keycapLen(text, i) > 0) {
            // Keycap emoji: the whole sequence is one segment (see keycapLen).
            const kl = keycapLen(text, i);
            out[seg_count] = .{ .start = i, .end = i + kl };
            seg_count += 1;
            i += kl;
            while (i < len and text[i] == 0x20) i += 1;
            out[seg_count - 1].end = i;
        } else if (byte < 0x80 and byte > 0x20) {
            // ASCII visible char: scan continuous to non-ASCII visible or end, include tail space;
            // a keycap sequence ends the run (it is shaped as emoji, see keycapLen).
            const seg_start = i;
            i += 1;
            while (i < len and text[i] > 0x20 and text[i] < 0x80 and keycapLen(text, i) == 0) {
                i += 1;
            }
            // Consume ASCII space tail (interval to next word own this segment).
            while (i < len and text[i] == 0x20) {
                i += 1;
            }
            out[seg_count] = .{ .start = seg_start, .end = i };
            seg_count += 1;
        } else if (cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F)) {
            // ZWJ / VS at segment start = prior base didn't consume. **Must still segment**: direct
            // i += cp_len drop bytes from
            // all segment, later start/end mismatch original (test "abc heart-filled def" skip
            // whole segment).
            // Pass to shaper, its advance 0, layout unaffect.
            out[seg_count] = .{ .start = i, .end = i + cp_len };
            seg_count += 1;
            i += cp_len;
        } else if (cp >= 0x1F000 or isEmojiCapable(cp)) {
            // Emoji range: scan ZWJ-joined sequence continuous.
            const seg_start = i;
            i += cp_len;
            while (i < len) {
                const next = storageScalar(text, i) orelse break;
                const ncl = next.len;
                const ncp = next.cp;
                // Only **prior codepoint is ZWJ** accept BMP emoji base (like heart ZWJ flame =
                // U+1F525 ZWJ U+2764).
                // Unconditional isEmojiCapable swallow normal symbol (-> / box etc) right after
                // emoji into same segment.
                const prev_was_zwj = i >= 3 and text[i - 3] == 0xE2 and text[i - 2] == 0x80 and text[i - 1] == 0x8D;
                if (isJoiner(ncp) or ncp >= 0x1F000 or (prev_was_zwj and isEmojiCapable(ncp))) {
                    i += ncl;
                } else break;
            }
            out[seg_count] = .{ .start = seg_start, .end = i };
            seg_count += 1;
        } else if (byte == 0x20) {
            // Leading/isolated spaces: generate segment (shaper gives spaces correct advance,
            // cursor_x advances)
            const seg_start = i;
            while (i < len and text[i] == 0x20) {
                i += 1;
            }
            out[seg_count] = .{ .start = seg_start, .end = i };
            seg_count += 1;
        } else if (byte == 0x09 or byte == 0x0A or byte == 0x0D) {
            // Tab/newline: skip (tabs should be expanded to spaces upstream)
            i += 1;
        } else if (isRtlScript(cp)) {
            // RTL: contiguous RTL codepoints go to CoreText **as a whole segment**.
            // Don't segment per codepoint like the branch below: that would destroy bidi
            // reordering,
            // Arabic connective forms and diacritic attachment (see isRtlScript comment).
            // Spaces within the segment are allowed: a space between RTL words belongs to the same
            // bidi
            // run; splitting would cut the sentence into several runs and sum the cursor as LTR.
            const seg_start = i;
            i += cp_len;
            while (i < len) {
                const next = storageScalar(text, i) orelse break;
                const ncl = next.len;
                const ncp = next.cp;
                // Trailing spaces not consumed: left for space branch below, avoid counting
                // RTL segment trailing spaces into RTL run (would offset LTR continuation).
                if (isRtlScript(ncp) or isJoiner(ncp)) {
                    i += ncl;
                } else if (ncp == 0x20) {
                    // Only merge space into current segment if next char is still RTL.
                    var j = i + 1;
                    while (j < len and text[j] == 0x20) j += 1;
                    if (j >= len) break;
                    const following = storageScalar(text, j) orelse break;
                    const fcp = following.cp;
                    if (isRtlScript(fcp)) i = j else break;
                } else break;
            }
            out[seg_count] = .{ .start = seg_start, .end = i };
            seg_count += 1;
        } else {
            // Other Unicode: each codepoint independent
            out[seg_count] = .{ .start = i, .end = i + cp_len };
            seg_count += 1;
            i += cp_len;
        }
    }
    return seg_count;
}

/// Metal Text Renderer - text pipeline module-level cumulative GPU draw count
/// (FrameStats takes per-frame delta)
pub var text_draw_calls: u64 = 0;

/// Module-level cumulative count of uniform slot overflows that spill to the backup buffer.
/// Overflow itself **doesn't drop glyphs** (see TextRenderer.flush comment), but signals
/// "clip switches per frame exceed expectation", the hallmark of a clip flush storm.
/// Constant zero is healthy; steady growth means the clip chain may re-emit per row.
/// Exported so e2e / /perf can assert it, not just scan logs.
pub var text_uniform_overflow_total: u64 = 0;
/// Module-level cumulative: creation count of fallback wrapper Font.
/// Healthy state on order of 'distinct (font,size,traits) combinations' (dozens or less).
/// Steady growth = fallback identity key regression to pointer-based, character loss recurs.
pub var fallback_wrappers_created_total: u64 = 0;

/// A glyph instance's quad as the text vertex shader places it (logical pixels: x0, y0, x1, y1):
/// position..position+size, the synthetic-italic skew on the top edge, padded by one logical pixel
/// for the shader's snap of the position to a physical pixel (at most half of one).
pub fn glyphQuad(g: anytype) [4]f32 {
    const skew = g.skew_x;
    return .{
        g.position[0] + @min(skew, 0) - 1,
        g.position[1] - 1,
        g.position[0] + g.size[0] + @max(skew, 0) + 1,
        g.position[1] + g.size[1] + 1,
    };
}

/// Accumulator of TextRenderer.probeInk: the union of glyphQuad over the instances the draw
/// would emit, and whether any glyph's raster metrics were unknown (not resident in the atlas).
pub const InkProbe = struct {
    lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) },
    hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) },
    missed: bool = false,

    fn add(self: *InkProbe, q: [4]f32) void {
        self.lo = .{ @min(self.lo[0], q[0]), @min(self.lo[1], q[1]) };
        self.hi = .{ @max(self.hi[0], q[2]), @max(self.hi[1], q[3]) };
    }
};

pub const TextRenderer = struct {
    pub const FontRangeRequest = struct {
        text: []const u8,
        font_size: f32,
        font_weight: u16,
        font_family: u16,
        use_italic: bool,
        use_monospace: bool,
        use_symbols: bool,
    };
    pub const FontRangesProvider = *const fn (*anyopaque, FontRangeRequest, *Font, std.mem.Allocator) anyerror!?*text_module.FontRanges;
    /// Shared shaping-equivalence segmentation for platform layout adapters.
    pub const SegmentSpan = Segment;
    pub const segment_capacity = MAX_SEGMENTS;
    pub const CpuMemoryStats = struct {
        segment_entries: usize,
        segment_capacity: usize,
        segment_entry_bytes: usize,
        segment_slot_bytes: usize,
        segment_live_glyph_bytes: usize,
        segment_hits: u64,
        segment_misses: u64,
        instance_capacity_bytes: usize,
        width_cache_text_bytes: usize,
    };
    /// Hash slots exclude allocation header/alignment; not a resident metric.
    pub fn cpuMemoryStats(self: *const TextRenderer) CpuMemoryStats {
        var glyph_bytes: usize = 0;
        var it = self.segment_cache.valueIterator();
        while (it.next()) |entry| glyph_bytes += @as(usize, entry.glyphs.len) * @sizeOf(text_module.ShapedGlyph);
        return .{
            .segment_entries = self.segment_cache.count(),
            .segment_capacity = self.segment_cache.capacity(),
            .segment_entry_bytes = @sizeOf(SegmentCacheEntry),
            .segment_slot_bytes = self.segment_cache.capacity() * (@sizeOf(SegmentCacheEntry) + @sizeOf(SegmentCacheKey) + 1),
            .segment_live_glyph_bytes = glyph_bytes,
            .segment_hits = self.segment_cache_hits,
            .segment_misses = self.segment_cache_misses,
            .instance_capacity_bytes = (self.instances_nearest.capacity + self.instances_linear.capacity) * @sizeOf(GlyphInstance),
            .width_cache_text_bytes = self.width_cache.bytes,
        };
    }
    pub fn splitSegments(content: []const u8, out: *[segment_capacity]SegmentSpan) u32 {
        return segmentText(content, out);
    }

    allocator: std.mem.Allocator,
    device: *gpu.Backend.Device,
    pipeline: gpu.Backend.RenderPipeline,
    /// Triple-buffered uniform buffers, must rotate per-frame like instance buffers.
    /// Previously single buffer with uniform_write_offset reset each frame: with three in flight,
    /// frame N+1 would overwrite N-frame viewport/clip/scale not yet consumed, manifesting
    /// as flicker/wrong clipping.
    uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer,
    uniform_write_offset: usize = 0,
    /// Per-frame uniform slot overflow count (diagnostic)
    uniform_overflow_count: u64 = 0,

    /// Overflow uniform buffer (one per frame per slot, grows and is retained).
    /// Slot exhaustion must not fail the batch: a flush failure doesn't clear instances, the next
    /// batch overflows again, and the frame renders nothing from then on (symptom: large text
    /// vanishes with gaps and flickers while node tree/layout rects stay correct).
    /// Out of slots -> grow on demand in a per-slot buffer retained across frames
    /// (see SlotBuffer). Slots rotate with current_buffer, so in-flight data is
    /// not overwritten.
    uniform_overflow: SlotBuffer(BUFFER_COUNT) = .init("Zenit.Text.OverflowUniforms", UNIFORM_STRIDE * 64),
    /// Overflow uniform slots consumed in this frame
    uniform_overflow_used: usize = 0,
    /// Peak flush count this frame (diagnostic, exported to /perf)
    uniform_peak_slots: usize = 0,
    /// Triple-buffered instance storage, sized by demand.
    instance_buffers: SlotBuffer(BUFFER_COUNT) = .init("Zenit.Text.InstanceBuffer", MIN_INSTANCE_BYTES),
    current_buffer: usize = 0,

    // Fonts and atlases
    atlas: GlyphAtlas,

    /// Explicit font fallback stack (app-injected; null = maintain pure CoreText cascade).
    /// See font_fallback_stack.zig header comment.
    fallback_stack: ?*FontFallbackStack = null,
    font_ranges_provider: ?FontRangesProvider = null,
    font_ranges_context: ?*anyopaque = null,
    /// Borrowed only during a single encoder draw; never enters segment caches.
    active_font_ranges: ?*const text_module.FontRanges = null,
    /// Borrowed only during a single encoder draw: the instance the drawn font's own glyphs
    /// rasterize from (FontSelector `ResolvedFonts.raster`, animated raster). Shaping, and so
    /// every advance and pen position, stays with the drawn font.
    raster_font: ?*Font = null,

    /// (primary font, codepoint) -> is covered. selectSegmentFont hot-path cache:
    /// hit -> each non-ASCII segment pays hash lookup once, no CoreText FFI again.
    primary_coverage_cache: std.AutoHashMap(PrimaryCovKey, bool),

    /// Prewarm mode: shape + rasterize glyphs into the atlas only, **no instance output**.
    /// Early-frame prewarm uploads missing glyphs to the atlas before the GPU critical path;
    /// running full encodeText would build all instances only to discard them
    /// (shrinkRetainingCapacity), encoding text almost twice. With this flag emitGlyphInstance
    /// returns the advance after atlas insertion, skipping all instance construction and append.
    glyph_only: bool = false,
    /// Ink probe (probeInk): emitGlyphInstance records each instance's quad here instead of
    /// appending it, and reads the atlas without inserting.
    ink_probe: ?*InkProbe = null,
    prewarm_layered: bool = false,
    prewarm_scales: [9]f32 = @splat(0),
    prewarm_scale_count: usize = 0,

    /// Text signature of the last fully-run prewarm command stream + atlas GC generation.
    /// Prewarm's only output is "missing glyphs enter the atlas". If this frame's text matches the
    /// previous one byte-for-byte and no atlas page was evicted in between, the required glyphs
    /// **must** already be resident and the whole prewarm is pure spinning (often inserts=0 while
    /// costing more than encode). Signature match + gc_gen match -> skip. Either differs (text
    /// changed / page evicted) -> full prewarm.
    prewarm_signature: u64 = 0,
    prewarm_signature_valid: bool = false,
    /// Prewarm passes that ran (signature changed) rather than skipped, for perf traces.
    prewarm_full_passes: u64 = 0,
    /// Text items (prewarmItemKey) the last completed prewarm pass covered, and the set this pass
    /// fills: an item seen by the last pass has its glyphs resident unless the atlas collected
    /// pages since (gc generation), so only new items are prewarmed.
    prewarm_known: std.AutoHashMapUnmanaged(u64, void) = .empty,
    prewarm_seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    prewarm_gc_generation: u32 = 0,
    shaper: TextShaper,

    // Segment-level shaping cache, word/CJK-single-char granularity, inline-stored no-alloc
    segment_cache: std.AutoHashMap(SegmentCacheKey, SegmentCacheEntry),
    segment_cache_hits: u64 = 0,
    segment_cache_misses: u64 = 0,
    width_cache: WidthCache = .{},
    cache_long_segments: bool = false,
    long_segment_cache: LongSegmentCache = .{},
    // Full-line fallback cache, used when segment overflows.
    // CoreText actual fallback CTFontRef -> borrowed Font wrapper.
    // Per-run CTFontRef may materialize fresh each shape, capacity control required.
    fallback_font_cache: std.AutoHashMap(u64, FallbackFontCacheEntry),
    current_frame: u64 = 0,
    /// GC collected atlas pages this frame -> upper layers must invalidate render cache
    atlas_gc_happened: bool = false,

    // Current frame's instance data
    instances_nearest: std.ArrayList(GlyphInstance),
    instances_linear: std.ArrayList(GlyphInstance),
    /// Advances whenever the pending instances are dropped (flush, new frame): a holder of
    /// facts about "the pending glyphs" (the encoder's ink set) knows they are stale.
    pending_generation: u64 = 0,
    viewport_width: f32,
    viewport_height: f32,
    scale_factor: f32,
    clip_rect: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    clip_shape_kind: u32 = 0,
    clip2: shape_clip_pair.Uniform = .{},
    clip_fill_rule: u32 = 0,
    clip_point_count: u32 = 0,
    clip_contour_count: u32 = 0,
    clip_polygon_end_points: [MAX_CLIP_POLYGON_CONTOURS]u32 = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0)),
    clip_polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32 = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 })),
    current_rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    /// Current clip region's horizontal range (logical pixels), skip off-viewport glyphs
    clip_x_min: f32 = 0,
    clip_x_max: f32 = std.math.inf(f32),
    /// Current pass target's **logical-pixel** width (beginFrame/setViewport width param).
    /// setRectClip(null) must restore clip_x_min/max to whole target width, cannot use
    /// viewport_width which is physical pixels post-scale.
    viewport_logical_width: f32 = 0,
    /// Right-fade mask window (logical pixels, same space as draw x; CSS mask-image minimal
    /// text-only): glyph left edge in [fade_x0, fade_x1] -> alpha linearly drops to 0, past
    /// fade_x1 fully transparent. inf/inf = off. Set per text command and reset by
    /// command_encoder (same mode as clip_x_*)
    /// Font smoothing for the glyphs being emitted (set per text command by the encoder from
    /// TextFontFlag.no_smoothing, reset after it)
    smooth_fonts: bool = true,
    cleartype_enabled: bool = false,
    raster_context: ?*anyopaque = null,
    dwrite_params: [8]f32 = @splat(0),
    cleartype_allowed: bool = false,
    lcd_glyph_count: usize = 0,
    gray_glyph_count: usize = 0,
    run_lcd_rejected: bool = false,
    lcd_backdrop: ?*const @import("text_render_policy.zig").Backdrop = null,
    fade_x0: f32 = std.math.inf(f32),
    fade_x1: f32 = std.math.inf(f32),
    instance_high_water_mark: usize = 0,
    /// Flush offset: after mid-flush, append writes avoid GPU async overwrite
    buffer_write_offset: usize = 0,

    /// Initialize Text Renderer
    pub fn init(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !TextRenderer {
        var raster_context: ?*anyopaque = null;
        var params: [8]f32 = @splat(0);
        if (comptime builtin.os.tag == .windows) {
            raster_context = NativeRaster.zenit_dwrite_raster_context_create() orelse return error.TextRenderingParamsFailed;
            errdefer NativeRaster.zenit_dwrite_raster_context_destroy(raster_context);
            if (NativeRaster.zenit_dwrite_raster_context_refresh(raster_context, null, 0, &params) < 0) return error.TextRenderingParamsFailed;
        }
        errdefer if (comptime builtin.os.tag == .windows) NativeRaster.zenit_dwrite_raster_context_destroy(raster_context);
        const lcd_enabled = params[7] != 0 and !@import("zenit_environment").flag("ZENIT_TEXT_BASELINE_GRAYSCALE");
        const source = text_shader_source;
        var shader = try gpu.Backend.ShaderModule.initFromSource(device, source);
        defer shader.deinit();

        // Get function
        var vertex_func = try shader.getFunction("text_vertex_main");
        defer vertex_func.deinit();
        var fragment_func = try shader.getFunction("text_fragment_main");
        defer fragment_func.deinit();

        // Create pipeline. After this line, every fallible step must have errdefer covering
        // created resources; GPU objects GPA won't detect, leaks are MTLBuffer/PSO/CoreText.
        // Note: errdefer in for loop body loses scope with iteration (dead code, used to be
        // that way); counter must go outside loop.
        var pipeline_desc = gpu.Backend.RenderPipelineDescriptor{
            .vertex_function = &vertex_func,
            .fragment_function = &fragment_func,
            .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
            .blend_state = .{
                .source_rgb = .one,
                .destination_rgb = .one_minus_src_alpha,
                .rgb_operation = .add,
                .source_alpha = .one,
                .destination_alpha = .one_minus_src_alpha,
                .alpha_operation = .add,
            },
        };
        if (comptime gpu.is_direct3d) pipeline_desc.dual_source_blending = true;
        var pipeline = try gpu.Backend.createRenderPipeline(device, pipeline_desc);
        errdefer pipeline.deinit();

        // Create uniform buffer
        var uniform_buffers: [BUFFER_COUNT]gpu.Backend.Buffer = undefined;
        var uniform_created: usize = 0;
        errdefer for (uniform_buffers[0..uniform_created]) |*ub| ub.destroy();
        for (&uniform_buffers) |*ubuf| {
            ubuf.* = try device.createBuffer(allocator, .{
                .label = "Zenit.Text.Uniforms",
                .size = UNIFORM_STRIDE * MAX_UNIFORM_UPDATES,
                .usage = .{ .vertex = true, .map_write = true },
            });
            uniform_created += 1;
        }

        // Create glyph atlas
        var atlas = try GlyphAtlas.init(allocator, device);
        errdefer atlas.deinit();
        atlas.raster_context = raster_context;

        // Create text shaper
        const shaper = try TextShaper.init(allocator);

        if (comptime builtin.os.tag == .windows) std.debug.print("TEXT_RASTER_PIPELINE glyph-coverage phase_bins=4 dynamic-monitor-params\n", .{});
        std.log.info("[TextRenderer] Initialized", .{});

        return TextRenderer{
            .allocator = allocator,
            .device = device,
            .cleartype_enabled = lcd_enabled,
            .raster_context = raster_context,
            .dwrite_params = params,
            .pipeline = pipeline,
            .uniform_buffers = uniform_buffers,
            .atlas = atlas,
            .shaper = shaper,
            .segment_cache = std.AutoHashMap(SegmentCacheKey, SegmentCacheEntry).init(allocator),
            .fallback_font_cache = std.AutoHashMap(u64, FallbackFontCacheEntry).init(allocator),
            .primary_coverage_cache = std.AutoHashMap(PrimaryCovKey, bool).init(allocator),
            .instances_nearest = .empty,
            .instances_linear = .empty,
            .viewport_width = 800,
            .viewport_height = 600,
            .scale_factor = 1.0,
        };
    }

    /// Destroy
    /// Per-slot scratch storage is rewritten every frame; see idle_storage.
    pub fn setScratchVolatile(self: *TextRenderer, make_volatile: bool) void {
        idle_storage.setBuffersVolatile(&self.uniform_buffers, make_volatile);
        self.uniform_overflow.setVolatile(make_volatile);
        self.instance_buffers.setVolatile(make_volatile);
    }

    /// Drop demand-sized scratch so the next frame regrows it to what it
    /// draws. Only while no submitted frame is executing.
    pub fn releaseScratch(self: *TextRenderer) void {
        self.instance_buffers.release();
        self.uniform_overflow.release();
    }

    /// Idle: keep only the shaped segments the latest frame drew (what is on
    /// screen). Everything else a scroll or an edit shaped since is reshaped
    /// on demand; held across windows it adds up (5 editors after a 300k-line
    /// scroll each: ~16 MiB of shaped glyphs).
    pub fn trimIdleCaches(self: *TextRenderer) void {
        const keep_after = self.current_frame -| 1;
        var stale: std.ArrayList(SegmentCacheKey) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.segment_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.frame_last_used < keep_after) stale.append(self.allocator, entry.key_ptr.*) catch break;
        }
        for (stale.items) |key| {
            if (self.segment_cache.fetchRemove(key)) |kv| releaseSegmentEntry(self.allocator, kv.value);
        }
        self.long_segment_cache.trimBefore(self.allocator, keep_after);
    }

    pub fn deinit(self: *TextRenderer) void {
        self.prewarm_known.deinit(self.allocator);
        self.prewarm_seen.deinit(self.allocator);
        var seg_iter = self.segment_cache.iterator();
        while (seg_iter.next()) |entry| {
            releaseSegmentEntry(self.allocator, entry.value_ptr.*);
        }
        self.segment_cache.deinit();
        self.long_segment_cache.deinit(self.allocator);
        self.width_cache.deinit(self.allocator);
        var fallback_font_iter = self.fallback_font_cache.iterator();
        while (fallback_font_iter.next()) |entry| {
            entry.value_ptr.font.deinit();
        }
        self.fallback_font_cache.deinit();
        self.primary_coverage_cache.deinit();
        self.instances_nearest.deinit(self.allocator);
        self.instances_linear.deinit(self.allocator);
        self.shaper.deinit();
        self.atlas.deinit();
        if (comptime builtin.os.tag == .windows) NativeRaster.zenit_dwrite_raster_context_destroy(self.raster_context);
        self.instance_buffers.deinit(self.allocator);
        for (&self.uniform_buffers) |*ubuf| ubuf.destroy();
        self.uniform_overflow.deinit(self.allocator);
        self.pipeline.deinit();
        std.log.info("[TextRenderer] Destroyed", .{});
    }

    pub fn updateWindowTextParameters(self: *TextRenderer, window: ?*anyopaque) !bool {
        if (comptime builtin.os.tag != .windows) return false;
        const changed = NativeRaster.zenit_dwrite_raster_context_refresh(self.raster_context, window, 0, &self.dwrite_params);
        if (changed < 0) return error.TextRenderingParamsFailed;
        self.cleartype_enabled = self.dwrite_params[7] != 0 and !@import("zenit_environment").flag("ZENIT_TEXT_BASELINE_GRAYSCALE");
        if (changed != 0) {
            self.atlas.invalidateRaster();
            self.prewarm_signature_valid = false;
        }
        return changed != 0;
    }

    /// Start a GPU frame. width/height: logical pixels; scale: DPI scale factor (Retina=2.0)
    pub fn beginFrame(self: *TextRenderer, width: f32, height: f32, scale: f32) void {
        self.beginFrameFor(width, height, scale, true);
    }

    /// `gpu_frame` false: a CPU patch encode (cpu_flat), which reads only the
    /// CPU-side batches: the triple-buffered GPU slots keep rotating with GPU
    /// frames alone, so a slot an in-flight frame reads is never reused.
    /// Only GPU frames advance `current_frame`: idle trim keeps the segments the
    /// latest GPU frame drew, which a patch drawing one line must not age out.
    pub fn beginFrameFor(self: *TextRenderer, width: f32, height: f32, scale: f32, gpu_frame: bool) void {
        self.instances_nearest.clearRetainingCapacity();
        self.instances_linear.clearRetainingCapacity();
        self.pending_generation +%= 1;
        self.buffer_write_offset = 0;
        if (gpu_frame) {
            self.current_buffer = (self.current_buffer + 1) % BUFFER_COUNT;
            self.instance_buffers.beginSlot(self.current_buffer);
            self.uniform_overflow.beginSlot(self.current_buffer);
        }
        self.uniform_write_offset = 0;
        self.uniform_overflow_used = 0;
        self.uniform_peak_slots = 0;
        self.width_cache.clear(self.allocator);
        if (gpu_frame) self.current_frame += 1;
        // DPI changed (drag window across screens) -> glyph raster size and subpixel
        // bin key change; prewarm skip baseline invalidated.
        if (self.scale_factor != scale) self.prewarm_signature_valid = false;
        // viewport_size passes physical pixels to shader
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
        self.clip_rect = .{ 0, 0, 0, 0 };
        self.clip_radii = .{ 0, 0, 0, 0 };
        self.clip_shape_kind = 0;
        self.clip2 = .{};
        self.clip_fill_rule = 0;
        self.clip_point_count = 0;
        self.clip_contour_count = 0;
        self.clip_polygon_end_points = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0));
        self.clip_polygon_points = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 }));
        self.current_rect_clip = .{ 0, 0, -1, -1 };
        // Reset clip to full viewport (logical pixels)
        self.viewport_logical_width = width;
        self.clip_x_min = 0;
        self.clip_x_max = width;

        // Sync frame number to atlas (used for page-level last_used_frame GC judgment)
        self.atlas.current_frame = self.current_frame;
        self.atlas.resetFrameStats();
        self.lcd_glyph_count = 0;
        self.gray_glyph_count = 0;
        // Periodic age-based GC (self-throttled internally + budget gate, not every-frame scan).
        // Previously atlas only evicted when page count hit MAX_PAGES (=512 MiB);
        // EVICT_THRESHOLD was dead code (review report P1).
        self.atlas.maybeCollect();

        // Atlas page-level GC moved to window_render.zig render() before execution,
        // ensuring GC-collected pages can invalidate render cache same frame, avoiding
        // stale texture references
        self.atlas_gc_happened = false;

        // Segment cache cleanup: lower frequency + longer retention window, reduce jitter.
        // GPU frames only: CPU patch frames hold current_frame, and one held on a
        // multiple of 900 would rerun this scan on every patch.
        if (gpu_frame and self.current_frame % 900 == 0) {
            self.evictStaleSegments();
            self.evictStaleFallbackFonts();
            // After fallback font release, atlas GlyphKey.font_ptr may be reused by next Font at
            // same address. prewarm skip baseline cannot cross this point; force next frame rerun.
            self.prewarm_signature_valid = false;
        }
    }

    /// Update viewport size only (used when offscreen composite render pass switches).
    /// Don't reset buffer/instances/rotation, frame-internal state stays continuous
    pub fn setViewport(self: *TextRenderer, width: f32, height: f32, scale: f32) void {
        self.viewport_width = width * scale;
        self.viewport_height = height * scale;
        self.scale_factor = scale;
        self.viewport_logical_width = width;
        self.clip_x_min = 0;
        self.clip_x_max = width;
    }

    /// Second shape clip intersected with the primary one (shape_clip_pair.zig).
    pub fn setPartnerClip(self: *TextRenderer, clip: shape_clip_pair.Uniform) void {
        self.clip2 = clip;
    }

    pub fn setClipMask(self: *TextRenderer, shape_kind: u32, rect: ?[4]f32, radii: [4]f32, fill_rule: u32, point_count: u32, contour_count: u32, contour_end_points: [MAX_CLIP_POLYGON_CONTOURS]u8, polygon_points: [MAX_CLIP_POLYGON_POINTS][2]f32) void {
        if (rect) |mask_rect| {
            self.clip_rect = mask_rect;
            self.clip_radii = radii;
            self.clip_shape_kind = shape_kind;
            self.clip_fill_rule = fill_rule;
            self.clip_point_count = point_count;
            self.clip_contour_count = contour_count;
            for (0..MAX_CLIP_POLYGON_CONTOURS) |i| self.clip_polygon_end_points[i] = contour_end_points[i];
            self.clip_polygon_points = polygon_points;
        } else {
            self.clip_rect = .{ 0, 0, 0, 0 };
            self.clip_radii = .{ 0, 0, 0, 0 };
            self.clip_shape_kind = 0;
            self.clip2 = .{};
            self.clip_fill_rule = 0;
            self.clip_point_count = 0;
            self.clip_contour_count = 0;
            self.clip_polygon_end_points = @as([MAX_CLIP_POLYGON_CONTOURS]u32, @splat(0));
            self.clip_polygon_points = @as([MAX_CLIP_POLYGON_POINTS][2]f32, @splat(.{ 0, 0 }));
        }
    }

    /// Besides recording the per-instance rect_clip, also merge its x range into
    /// clip_x_min/x_max; the draw path emit loop uses this pair to skip left / truncate right.
    /// If it were only set to full window width at beginFrame, long lines within a rect clip
    /// (split-view code column, h-scroll window) would emit to the window right edge, each
    /// invisible glyph paying one atlas lookup + instance append before the GPU discards it by
    /// per-instance rect_clip. Early CPU truncation doesn't change the visible result: the shader
    /// can't draw outside the rect anyway (negative bearing fray is tolerated, same as the
    /// window-right truncate). Rect and cursor_x are logical pixels in target coords (offscreen
    /// pass also layer-local; encoder's syncRectClipState re-pushes after a pass switch).
    pub fn setRectClip(self: *TextRenderer, rect: ?[4]f32) void {
        self.current_rect_clip = rect orelse .{ 0, 0, -1, -1 };
        if (rect) |r| {
            self.clip_x_min = @max(0, r[0]);
            self.clip_x_max = @min(self.viewport_logical_width, r[0] + r[2]);
        } else {
            self.clip_x_min = 0;
            self.clip_x_max = self.viewport_logical_width;
        }
    }

    /// Clean up segment-cache entries unused over 1800 frames (approx 30 sec @60fps)
    fn evictStaleSegments(self: *TextRenderer) void {
        const evict_threshold = 1800;
        var keys_buf: [128]SegmentCacheKey = undefined;
        var remove_count: usize = 0;

        var iter = self.segment_cache.iterator();
        while (iter.next()) |entry| {
            if (self.current_frame - entry.value_ptr.frame_last_used > evict_threshold) {
                if (remove_count < keys_buf.len) {
                    keys_buf[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }
        for (keys_buf[0..remove_count]) |key| {
            if (self.segment_cache.fetchRemove(key)) |kv| {
                releaseSegmentEntry(self.allocator, kv.value);
            }
        }
    }

    fn destroyFallbackFontEntry(self: *TextRenderer, entry: FallbackFontCacheEntry) void {
        // Atlas keyed by Font heap address; after wrapper release address gets reused by next
        // wrapper, must remove entry first or new font hits old font's bitmap (wrong glyph).
        self.atlas.forgetFont(@intFromPtr(entry.font));
        entry.font.deinit();
    }

    fn evictStaleFallbackFonts(self: *TextRenderer) void {
        const evict_threshold = 1800;
        var keys_buf: [64]u64 = undefined;
        var remove_count: usize = 0;

        var iter = self.fallback_font_cache.iterator();
        while (iter.next()) |entry| {
            if (self.current_frame - entry.value_ptr.frame_last_used > evict_threshold) {
                if (remove_count < keys_buf.len) {
                    keys_buf[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }

        for (keys_buf[0..remove_count]) |key| {
            if (self.fallback_font_cache.fetchRemove(key)) |kv| {
                self.destroyFallbackFontEntry(kv.value);
            }
        }
    }

    /// When segment cache full: evict first delete >300-frame-unused; if still full, clear half
    fn evictSegmentCacheOnFull(self: *TextRenderer) void {
        // Pass 1: delete entries unused >300 frames
        const threshold = 300;
        var keys_buf: [256]SegmentCacheKey = undefined;
        var remove_count: usize = 0;

        var iter = self.segment_cache.iterator();
        while (iter.next()) |entry| {
            if (self.current_frame - entry.value_ptr.frame_last_used > threshold) {
                if (remove_count < keys_buf.len) {
                    keys_buf[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }
        for (keys_buf[0..remove_count]) |key| {
            if (self.segment_cache.fetchRemove(key)) |kv| {
                releaseSegmentEntry(self.allocator, kv.value);
            }
        }

        // If still full, brutally clear half
        if (self.segment_cache.count() >= SEGMENT_CACHE_MAX) {
            var iter2 = self.segment_cache.iterator();
            var half = self.segment_cache.count() / 2;
            var keys2: [256]SegmentCacheKey = undefined;
            var c2: usize = 0;
            while (half > 0) {
                if (iter2.next()) |entry| {
                    if (c2 < keys2.len) {
                        keys2[c2] = entry.key_ptr.*;
                        c2 += 1;
                        half -= 1;
                    }
                    if (c2 == keys2.len) {
                        for (keys2[0..c2]) |k| {
                            if (self.segment_cache.fetchRemove(k)) |kv| {
                                releaseSegmentEntry(self.allocator, kv.value);
                            }
                        }
                        c2 = 0;
                    }
                } else break;
            }
            for (keys2[0..c2]) |k| {
                if (self.segment_cache.fetchRemove(k)) |kv| {
                    releaseSegmentEntry(self.allocator, kv.value);
                }
            }
        }
    }

    fn evictFallbackFontsOnFull(self: *TextRenderer) void {
        var keys_buf: [64]u64 = undefined;
        var remove_count: usize = 0;
        const threshold = 300;

        var iter = self.fallback_font_cache.iterator();
        while (iter.next()) |entry| {
            if (self.current_frame - entry.value_ptr.frame_last_used > threshold) {
                if (remove_count < keys_buf.len) {
                    keys_buf[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }

        for (keys_buf[0..remove_count]) |key| {
            if (self.fallback_font_cache.fetchRemove(key)) |kv| {
                self.destroyFallbackFontEntry(kv.value);
            }
        }

        if (self.fallback_font_cache.count() >= FALLBACK_FONT_CACHE_MAX) {
            var iter2 = self.fallback_font_cache.iterator();
            var half = self.fallback_font_cache.count() / 2;
            var keys2: [64]u64 = undefined;
            var c2: usize = 0;
            while (half > 0) {
                if (iter2.next()) |entry| {
                    if (c2 < keys2.len) {
                        keys2[c2] = entry.key_ptr.*;
                        c2 += 1;
                        half -= 1;
                    }
                    if (c2 == keys2.len) {
                        for (keys2[0..c2]) |k| {
                            if (self.fallback_font_cache.fetchRemove(k)) |kv| {
                                self.destroyFallbackFontEntry(kv.value);
                            }
                        }
                        c2 = 0;
                    }
                } else break;
            }
            for (keys2[0..c2]) |k| {
                if (self.fallback_font_cache.fetchRemove(k)) |kv| {
                    self.destroyFallbackFontEntry(kv.value);
                }
            }
        }
    }

    /// Draw text
    fn getOrCreateGlyphFallbackFont(self: *TextRenderer, fallback_font_ref: *anyopaque, prototype: *Font) !*Font {
        if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .windows and builtin.target.os.tag != .linux) {
            return error.UnsupportedNativeFallbackFontRef;
        } else {
            // Key must be the font **identity** (PS name + size + traits), not the CTFontRef
            // pointer:
            // CoreText's per-run fallback ref isn't a stable instance. A pointer key causes:
            //   1. wrapper total miss every frame (scrolling a CJK doc creates hundreds of
            //      thousands of
            //      wrappers, thrashing the 256-entry cache);
            //   2. the wrapper heap addr enters GlyphKey.font_ptr -> the same glyph is recorded as
            //      countless "new fonts" in the glyph atlas -> 32 pages exhausted -> AtlasFull ->
            //      later CJK glyphs silently dropped (char-by-char vanishing with position gaps;
            //      ASCII
            //      unaffected because the primary font ptr is stable). When the allocator reuses
            //      addresses, keys alias and point at the wrong font.
            const key = text_module.fallbackFontRefIdentityHash(fallback_font_ref);
            if (self.fallback_font_cache.getPtr(key)) |cached| {
                cached.frame_last_used = self.current_frame;
                if (comptime builtin.target.os.tag == .linux) cached.font.setScaleFactor(prototype.scale_factor) else cached.font.scale_factor = prototype.scale_factor;
                return cached.font;
            }

            if (self.fallback_font_cache.count() >= FALLBACK_FONT_CACHE_MAX) {
                self.evictFallbackFontsOnFull();
            }

            fallback_wrappers_created_total += 1;
            const ct_size = text_module.fallbackFontRefSize(fallback_font_ref);
            const requested_size = if (std.math.isFinite(ct_size) and ct_size > 0) ct_size else prototype.pixelSize();
            const size_px: f32 = if (std.math.isFinite(requested_size)) std.math.clamp(requested_size, 1, 4096) else 1;
            const fallback_font = if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .linux)
                try Font.fromFallbackRef(self.allocator, fallback_font_ref, prototype)
            else blk: {
                const owned = try self.allocator.create(Font);
                // Font wrapper independently retains CTFontRef, independent of segment cache
                // reference lifetime. Segment cache evict releases its own retain, doesn't affect
                // this.
                text_module.retainFallbackFontRef(fallback_font_ref);
                owned.* = .{
                    .allocator = self.allocator,
                    .ct_font = fallback_font_ref,
                    .io = prototype.io,
                    .size = @intFromFloat(@round(size_px)),
                    .size_px = size_px,
                    .weight = prototype.weight,
                    .scale_factor = prototype.scale_factor,
                };
                break :blk owned;
            };
            // Font.deinit both releases that retain and destroys wrapper heap block itself
            // (see font_system.zig Font.deinit); calling destroy again here is double-free.
            errdefer fallback_font.deinit();
            try self.fallback_font_cache.put(key, .{
                .font = fallback_font,
                .frame_last_used = self.current_frame,
            });
            return fallback_font;
        }
    }

    /// Hook to app's explicit font fallback stack. Pass null to disconnect
    /// (revert to pure cascade). Stack must outlive this renderer (held by app).
    pub fn setFallbackStack(self: *TextRenderer, stack: ?*FontFallbackStack) void {
        if (self.fallback_stack == stack) return;
        self.fallback_stack = stack;
        self.primary_coverage_cache.clearRetainingCapacity();
        // Font selection changed -> prewarm 'glyphs from last frame must be resident' baseline
        // invalidated.
        self.prewarm_signature_valid = false;
    }

    fn primaryCoversCodepoint(self: *TextRenderer, font: *Font, cp: u21) bool {
        const key = PrimaryCovKey{ .font_ptr = @intFromPtr(font), .cp = cp };
        if (self.primary_coverage_cache.get(key)) |covered| return covered;
        const covered = font.glyphIndexForCodepoint(cp) != 0;
        if (self.primary_coverage_cache.count() >= PRIMARY_COVERAGE_CACHE_MAX) {
            self.primary_coverage_cache.clearRetainingCapacity();
        }
        self.primary_coverage_cache.put(key, covered) catch {};
        return covered;
    }

    /// Explicit font selection **before** shaping (CSS font-family semantics): segment-start
    /// codepoint -> if primary covers it use primary (implicit stack head), else ask the fallback
    /// stack for the first font covering it and shape directly; the selection is certain and the
    /// CTFont is owned by us (pointer stable), skipping CoreText cascade overhead. If neither
    /// answers, keep primary and let the run cascade do the final fallback (emoji, rare symbols).
    /// Only the segment-start codepoint is checked: segmentText already splits CJK per codepoint;
    /// mixed-script segments (RTL/emoji sequences) should use one font.
    /// ASCII segments (first byte < 0x80) short-circuit: the ASCII hot path costs nothing.
    /// WARNING: draw (shapeAndEmitSegment*) and measure (measureTextWidthAsDrawn) must both go
    /// through here; if only one does, "measured and drawn width differ" recurs.
    fn selectSegmentFont(self: *TextRenderer, seg_text: []const u8, font: *Font, requested_size: f32) *Font {
        const stack = self.fallback_stack orelse return font;
        if (seg_text.len == 0 or seg_text[0] < 0x80) return font;
        const scalar = storageScalar(seg_text, 0) orelse return font;
        const cp = if (scalar.cp >= 0xd800 and scalar.cp <= 0xdfff) 0xfffd else scalar.cp;
        if (self.primaryCoversCodepoint(font, cp)) return font;
        if (stack.selectForCodepoint(cp, requested_size, font.weight)) |stack_font| {
            // Same scale-following as fallback wrapper: stack fonts are shared instances;
            // raster size must track current draw context DPI.
            stack_font.scale_factor = font.scale_factor;
            return stack_font;
        }
        return font;
    }

    /// EmitParams adapted above selectSegmentFont: the stack font and primary font may be
    /// different pixelSize instances, so shaping advance/offset scale must be recalculated per
    /// segment font. Existing backends keep whole-pixel fallback caching; Windows
    /// preserves the actual phase so a selected CJK face matches native scan conversion.
    fn emitParamsForSegmentFont(p: EmitParams, seg_font: *Font) EmitParams {
        var seg_p = p;
        seg_p.font = seg_font;
        seg_p.fallback_font = seg_font;
        seg_p.raster_font = null;
        const seg_px = seg_font.pixelSize();
        if (p.requested_size > 0 and seg_px > 0) {
            seg_p.layout_scale = p.requested_size / seg_px;
        }
        seg_p.use_subpixel = if (builtin.os.tag == .windows) p.use_subpixel else false;
        return seg_p;
    }

    fn selectRenderFontForGlyph(self: *TextRenderer, glyph: text_module.ShapedGlyph, p: EmitParams) !*Font {
        if (p.resolved_font) |font| return font;
        if (glyph.is_fallback_font) {
            if (glyph.fallback_font_ref) |fallback_font_ref| {
                return self.getOrCreateGlyphFallbackFont(fallback_font_ref, p.font);
            }
            if (p.fallback_font) |fallback_font| {
                return fallback_font;
            }
        }
        if (glyph.is_synthetic_italic and p.fallback_font != null) {
            return p.fallback_font.?;
        }
        return p.raster_font orelse p.font;
    }

    fn releaseGlyphFallbackFontRefs(glyphs: []const text_module.ShapedGlyph) void {
        for (glyphs) |glyph| {
            if (glyph.fallback_font_ref) |fallback_font_ref| {
                text_module.releaseFallbackFontRef(fallback_font_ref);
            }
        }
    }

    fn logEnclosedDigitFontDebug(
        self: *TextRenderer,
        seg_text: []const u8,
        font: *Font,
        use_italic: bool,
        fallback_hint: ?*Font,
        glyphs: []const text_module.ShapedGlyph,
        source: []const u8,
    ) void {
        if (font_debug_budget == 0 or !containsEnclosedDigit(seg_text)) return;
        font_debug_budget -= 1;

        const base_name_owned = font.debugName(self.allocator);
        defer if (base_name_owned) |name| self.allocator.free(name);
        const fallback_hint_owned = if (fallback_hint) |f| f.debugName(self.allocator) else null;
        defer if (fallback_hint_owned) |name| self.allocator.free(name);

        const base_name = base_name_owned orelse "<base-font-name-unavailable>";
        const hint_name = fallback_hint_owned orelse "<no-fallback-hint>";

        std.log.warn("[FontDebug] seg=\"{s}\" source={s} base={s} hint={s} italic={} glyphs={d}", .{
            seg_text,
            source,
            base_name,
            hint_name,
            use_italic,
            glyphs.len,
        });

        for (glyphs, 0..) |glyph, idx| {
            const run_name_owned = if (glyph.fallback_font_ref) |font_ref|
                text_module.fallbackFontRefDebugName(self.allocator, font_ref)
            else
                null;
            defer if (run_name_owned) |name| self.allocator.free(name);

            const run_name = run_name_owned orelse if (glyph.is_fallback_font) hint_name else base_name;
            std.log.warn("[FontDebug] seg=\"{s}\" glyph#{d} cluster={d} gid={d} adv={d:.2} fallback={} synth_italic={} run={s}", .{
                seg_text,
                idx,
                glyph.cluster,
                glyph.glyph_index,
                glyph.x_advance,
                glyph.is_fallback_font,
                glyph.is_synthetic_italic,
                run_name,
            });
        }
    }

    /// Glyph emit params pack (avoid function parameter explosion)
    const EmitParams = struct {
        requested_size: f32,
        /// Shaping space scale (used for x_advance / x_offset / y_offset)
        layout_scale: f32,
        scale: f32,
        use_subpixel: bool,
        snap_to_device_pixels: bool,
        /// Does vertex shader snap position to physical pixels (written to
        /// GlyphInstance.metadata.snaps()).
        /// Must match snap_to_device_pixels origin: CPU snap + shader snap is idempotent;
        /// CPU no-snap + shader snap is direct_animated jitter cause (both sides contract
        /// in text_blob.TextRasterPolicy).
        shader_snap: bool,
        synthetic_skew: f32,
        font: *Font,
        fallback_font: ?*Font,
        instance_list: *std.ArrayList(GlyphInstance),
        fixed_advance: f32 = 0,
        explicit_range_raster: bool = false,
        resolved_font: ?*Font = null,
        /// Raster instance for glyphs of `font` itself (TextRenderer.raster_font).
        raster_font: ?*Font = null,
    };

    /// Take glyphs[i] cluster_span = next_cluster - cur_cluster, last glyph uses
    /// segment end byte offset. fixed_advance mode uses this span to advance ligature
    /// glyph N cells, keep byte_col -> pixel_x identity.
    fn clusterSpanAt(glyphs: []const text_module.ShapedGlyph, idx: usize, segment_end_byte: u32) u32 {
        const cur = glyphs[idx].cluster;
        const next = if (idx + 1 < glyphs.len) glyphs[idx + 1].cluster else segment_end_byte;
        return if (next > cur) next - cur else 1;
    }

    /// `cluster_span` is the source byte count this glyph covers (`next_cluster - glyph.cluster`).
    /// In fixed_advance mode, a ligature glyph with cluster_span > 1 needs N x cell advance to
    /// keep the byte_col -> pixel_x = byte_col x cell_width identity.
    /// Physical-pixel left edge of a subpixel-binned glyph bitmap. The rasterizer
    /// bakes the pen's fractional bin into the bitmap and measures bearing from the
    /// integer origin (CoreText and DirectWrite alike), so only the pen's integer
    /// pixel may move it. Rounding pen + bearing adds the fraction a second time:
    /// every glyph whose pen fraction >= 0.5 lands one device pixel right,
    /// which reads as random letter gaps at 100% scale.
    fn subpixelGlyphLeftPx(pen: atlas_mod.SubpixelPen, bearing_px: f32) f32 {
        return pen.pixel + bearing_px;
    }

    fn glyphAdvance(glyph: text_module.ShapedGlyph, cluster_span: u32, p: EmitParams) f32 {
        const advance = glyph.x_advance * p.layout_scale;
        if (p.fixed_advance > 0 and !glyph.is_fallback_font) {
            const cells: f32 = @floatFromInt(@max(cluster_span, 1));
            return p.fixed_advance * cells;
        }
        return advance;
    }

    /// Caveat: fixed_advance mode cannot forcibly clamp glyph_x >= cell_x.
    /// JetBrains Mono calt overhang (e.g. `less_slash.liga` xMin=-470) relies on the glyph
    /// extending left of the cell origin to form the `</` visual ligature; a forced clamp pushes
    /// the alt glyph back into the cell and overlaps the right neighbor. Let the font own its
    /// bearing and decide position.
    fn clampFixedAdvanceGlyphX(x: f32, cell_x: f32, glyph: text_module.ShapedGlyph, p: EmitParams) f32 {
        _ = cell_x;
        _ = glyph;
        _ = p;
        return x;
    }

    /// Convert single ShapedGlyph to GlyphInstance and append to instance list;
    /// return cursor_x delta (glyph.x_advance * text_scale)
    fn prewarmGlyphVariants(self: *TextRenderer, font: *Font, glyph: u32, phase: ?u32) void {
        if (comptime builtin.os.tag != .windows) return;
        if (!self.glyph_only) return;
        const saved_scale = font.scale_factor;
        const saved_lcd = font.cleartype;
        defer {
            font.setScaleFactor(saved_scale);
            font.cleartype = saved_lcd;
        }
        const scale_count = if (self.prewarm_scale_count > 0) self.prewarm_scale_count else 1;
        scales: for (0..scale_count) |i| {
            const scale = if (self.prewarm_scale_count > 0) self.prewarm_scales[i] else saved_scale;
            if (self.prewarm_scale_count > 0) for (0..i) |prior| {
                if (self.prewarm_scales[prior] == scale) continue :scales;
            };
            font.setScaleFactor(scale);
            const mode_count: usize = if (!self.prewarm_layered and phase != null and self.cleartype_enabled) 2 else 1;
            for (0..mode_count) |mode| {
                font.cleartype = if (mode == 0) saved_lcd else !saved_lcd;
                if (phase) |bin| {
                    if (self.prewarm_layered) {
                        font.cleartype = false;
                        for (0..atlas_mod.SUBPIXEL_BINS) |x| _ = self.atlas.getOrInsertSubpixel(font, glyph, atlas_mod.packSubpixelBin(@intCast(x), 0)) catch {};
                    } else _ = self.atlas.getOrInsertSubpixel(font, glyph, bin) catch {};
                } else _ = self.atlas.getOrInsert(font, glyph) catch {};
            }
        }
    }

    /// Every emitted glyph instance goes through here: appended for drawing, or, under an ink
    /// probe, only its quad recorded.
    inline fn pushInstance(self: *TextRenderer, list: *std.ArrayList(GlyphInstance), instance: GlyphInstance) !void {
        if (self.ink_probe) |probe| return probe.add(glyphQuad(&instance));
        try list.append(self.allocator, instance);
    }

    /// Ink of a text draw without drawing it: the union of glyphQuad over every glyph instance
    /// drawTextWithOptions (spans == null) or drawTextWithSpans would emit for these arguments at
    /// render scale `scale`, as (x0, y0, x1, y1) in the same logical space as x/y. It runs the
    /// draw's own segmentation, shaping (segment cache), font selection and placement code; only
    /// the atlas is read without inserting and the instances are not stored. The horizontal clip
    /// (clip_x_min/max), which only drops glyphs, is ignored.
    ///
    /// Null when a glyph's raster metrics are unknown (not resident in the atlas: the draw would
    /// rasterize it), on shaping failure, and where the draw is not one deterministic function of
    /// these arguments (Windows: ClearType backdrop decisions and provider font ranges). Text
    /// without ink returns a zero-size rect at (x, y).
    pub fn probeInk(
        self: *TextRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        font: *Font,
        requested_size: f32,
        use_italic: bool,
        fallback_font: ?*Font,
        force_linear: bool,
        shader_snap: bool,
        fixed_advance: f32,
        spans: ?[]const ColorSpan,
        scale: f32,
        smooth_fonts: bool,
    ) ?[4]f32 {
        if (comptime builtin.os.tag == .windows) return null;
        if (self.active_font_ranges != null or self.ink_probe != null or !(scale > 0)) return null;
        var probe: InkProbe = .{};
        const saved = .{ self.scale_factor, self.clip_x_min, self.clip_x_max, self.smooth_fonts, self.glyph_only };
        self.ink_probe = &probe;
        self.scale_factor = scale;
        self.clip_x_min = -std.math.inf(f32);
        self.clip_x_max = std.math.inf(f32);
        self.smooth_fonts = smooth_fonts;
        self.glyph_only = false;
        defer {
            self.ink_probe = null;
            self.scale_factor, self.clip_x_min, self.clip_x_max, self.smooth_fonts, self.glyph_only = saved;
        }
        const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
        if (spans) |s| {
            self.drawTextWithSpansInternal(text, x, y, font, black, requested_size, use_italic, fallback_font, force_linear, shader_snap, fixed_advance, s) catch return null;
        } else {
            self.drawTextWithOptionsInternal(text, x, y, font, black, requested_size, use_italic, fallback_font, force_linear, shader_snap, fixed_advance) catch return null;
        }
        if (probe.missed) return null;
        if (probe.lo[0] > probe.hi[0]) return .{ x, y, x, y };
        return .{ probe.lo[0], probe.lo[1], probe.hi[0], probe.hi[1] };
    }

    fn emitGlyphInstance(
        self: *TextRenderer,
        glyph: text_module.ShapedGlyph,
        cluster_span: u32,
        cursor_x: f32,
        cursor_y: f32,
        raw_glyph_color: Color,
        p: EmitParams,
    ) !f32 {
        // Right-fade mask: per-glyph modulate alpha by left edge position
        // (see fade_x0/x1 comment). All draw paths (including spans per-glyph coloring)
        // converge here, single-point effect.
        var glyph_color = raw_glyph_color;
        if (cursor_x >= self.fade_x0) {
            const span_w = self.fade_x1 - self.fade_x0;
            const keep: f32 = if (span_w > 0)
                std.math.clamp((self.fade_x1 - cursor_x) / span_w, 0, 1)
            else
                0;
            glyph_color.a *= keep;
        }
        const render_font = try self.selectRenderFontForGlyph(glyph, p);
        // Rasterize at the current target's scale, not the window's: inside a magnified surface
        // (an upscaled layer draws at parent scale x its magnification) a glyph rasterized for
        // the window would be stretched (blurry). scale_factor only drives rasterization; the
        // atlas keys glyphs by it.
        if (p.scale > 0 and render_font.scale_factor != p.scale) render_font.setScaleFactor(p.scale);
        // and with the command's font smoothing (TextProps.font_smoothing; atlas-keyed)
        render_font.smooth_fonts = self.smooth_fonts;
        if (comptime builtin.os.tag == .windows) render_font.cleartype = self.cleartype_enabled and self.cleartype_allowed and p.use_subpixel and !glyph.is_synthetic_italic and glyph_color.a == 1;
        const layout_scale = p.layout_scale;
        const render_font_px = render_font.pixelSize();
        // bitmap_scale applies to bearing/bitmap size; layout_scale continues for
        // shaping offset and advance.
        const bitmap_scale: f32 = if (p.requested_size > 0 and render_font_px > 0)
            p.requested_size / render_font_px
        else
            layout_scale;

        if (comptime builtin.os.tag == .windows) {
            if (bitmap_scale != 1) render_font.cleartype = false;
            if (self.cleartype_enabled and self.cleartype_allowed and !render_font.cleartype and !render_font.hasColorGlyphs()) self.run_lcd_rejected = true;
        }
        const cur_instance_list = if (glyph.is_synthetic_italic)
            &self.instances_linear
        else
            p.instance_list;

        const layout_selects_faces = comptime @hasDecl(Font, "layout_selects_faces") and Font.layout_selects_faces;
        if (p.use_subpixel and !glyph.is_synthetic_italic and (!glyph.is_fallback_font or p.explicit_range_raster or layout_selects_faces)) {
            const phys_x = (cursor_x + glyph.x_offset * layout_scale) * p.scale;
            const pen = atlas_mod.subpixelPen(phys_x);
            const bin_packed = atlas_mod.packSubpixelBin(pen.bin, 0);

            var region = if (self.ink_probe) |probe| self.atlas.peekSubpixel(render_font, glyph.glyph_index, bin_packed) orelse {
                probe.missed = true;
                return glyphAdvance(glyph, cluster_span, p);
            } else self.atlas.getOrInsertSubpixel(render_font, glyph.glyph_index, bin_packed) catch {
                return glyphAdvance(glyph, cluster_span, p);
            };
            if (self.ink_probe == null) self.prewarmGlyphVariants(render_font, glyph.glyph_index, bin_packed);
            if (comptime builtin.os.tag == .windows) {
                if (!self.glyph_only and self.ink_probe == null and region.is_cleartype) {
                    const left = clampFixedAdvanceGlyphX(subpixelGlyphLeftPx(pen, @as(f32, @floatFromInt(region.bearing_x))) / p.scale, cursor_x, glyph, p);
                    const top = cursor_y + glyph.y_offset * layout_scale - @as(f32, @floatFromInt(region.bearing_y)) / p.scale;
                    const x = if (p.shader_snap or p.snap_to_device_pixels) @round(left * p.scale) / p.scale else left;
                    const y = if (p.shader_snap or p.snap_to_device_pixels) @round(top * p.scale) / p.scale else top;
                    const rect: [4]f32 = .{ @max(0, x), @max(0, y), @min(self.viewport_width / p.scale, x + @as(f32, @floatFromInt(region.width)) / p.scale), @min(self.viewport_height / p.scale, y + @as(f32, @floatFromInt(region.height)) / p.scale) };
                    const supported = if (self.lcd_backdrop) |backdrop| backdrop.contains(rect) else false;
                    if (!supported) {
                        self.run_lcd_rejected = true;
                        render_font.cleartype = false;
                        region = self.atlas.getOrInsertSubpixel(render_font, glyph.glyph_index, bin_packed) catch return glyphAdvance(glyph, cluster_span, p);
                    }
                }
            }

            if (region.width == 0 or region.height == 0) {
                return glyphAdvance(glyph, cluster_span, p);
            }
            // prewarm: glyph already in atlas, no instance needed (see glyph_only comment).
            if (self.glyph_only) return glyphAdvance(glyph, cluster_span, p);

            const sp_bearing_y: f32 = @as(f32, @floatFromInt(region.bearing_y)) / render_font.scale_factor;
            // The bitmap already carries the pen's fractional bin; place it from
            // the pen's integer pixel only (see subpixelGlyphLeftPx).
            const bearing_px = @as(f32, @floatFromInt(region.bearing_x)) * (p.scale / render_font.scale_factor) * bitmap_scale;
            const raw_final_x = subpixelGlyphLeftPx(pen, bearing_px) / p.scale;
            const final_x = clampFixedAdvanceGlyphX(raw_final_x, cursor_x, glyph, p);
            const final_y = cursor_y + glyph.y_offset * layout_scale - sp_bearing_y * bitmap_scale;
            const snap_x = if (p.snap_to_device_pixels) @round(final_x * p.scale) / p.scale else final_x;
            const snap_y = if (p.snap_to_device_pixels) @round(final_y * p.scale) / p.scale else final_y;

            const region_w: f32 = @floatFromInt(region.width);
            const region_h: f32 = @floatFromInt(region.height);
            try self.pushInstance(p.instance_list, .{
                .position = .{ snap_x, snap_y },
                .size = .{
                    (region_w / render_font.scale_factor) * bitmap_scale,
                    (region_h / render_font.scale_factor) * bitmap_scale,
                },
                .uv_rect = GlyphUV.init(.{
                    region.uv_min[0],
                    region.uv_min[1],
                    region.uv_max[0],
                    region.uv_max[1],
                }),
                .color = glyph_color.toArray(),
                .rect_clip = self.current_rect_clip,
                .metadata = GlyphMetadata.init(region.page_index, if (region.is_color) 1 else if (region.is_cleartype) 2 else 0, p.shader_snap),
            });
        } else {
            const region = if (self.ink_probe) |probe| self.atlas.peek(render_font, glyph.glyph_index) orelse {
                probe.missed = true;
                return glyphAdvance(glyph, cluster_span, p);
            } else try self.atlas.getOrInsert(render_font, glyph.glyph_index);
            if (self.ink_probe == null) self.prewarmGlyphVariants(render_font, glyph.glyph_index, null);
            if (region.width == 0 or region.height == 0) {
                return glyphAdvance(glyph, cluster_span, p);
            }
            // prewarm: same; just glyph in atlas is enough.
            if (self.glyph_only) return glyphAdvance(glyph, cluster_span, p);

            const bearing_x: f32 = @as(f32, @floatFromInt(region.bearing_x)) / render_font.scale_factor;
            const bearing_y: f32 = @as(f32, @floatFromInt(region.bearing_y)) / render_font.scale_factor;
            const raw_glyph_x = cursor_x + glyph.x_offset * layout_scale + bearing_x * bitmap_scale;
            const glyph_x = clampFixedAdvanceGlyphX(raw_glyph_x, cursor_x, glyph, p);
            const glyph_y = cursor_y + glyph.y_offset * layout_scale - bearing_y * bitmap_scale;
            const snap_x = if (p.snap_to_device_pixels) @round(glyph_x * p.scale) / p.scale else glyph_x;
            const snap_y = if (p.snap_to_device_pixels) @round(glyph_y * p.scale) / p.scale else glyph_y;

            const region_w: f32 = @floatFromInt(region.width);
            const region_h: f32 = @floatFromInt(region.height);
            try self.pushInstance(cur_instance_list, .{
                .position = .{ snap_x, snap_y },
                .size = .{
                    (region_w / render_font.scale_factor) * bitmap_scale,
                    (region_h / render_font.scale_factor) * bitmap_scale,
                },
                .uv_rect = GlyphUV.init(.{
                    region.uv_min[0],
                    region.uv_min[1],
                    region.uv_max[0],
                    region.uv_max[1],
                }),
                .color = glyph_color.toArray(),
                .rect_clip = self.current_rect_clip,
                .skew_x = if (glyph.is_synthetic_italic) p.synthetic_skew else 0,
                .metadata = GlyphMetadata.init(region.page_index, if (region.is_color) 1 else if (region.is_cleartype) 2 else 0, p.shader_snap),
            });
        }

        return glyphAdvance(glyph, cluster_span, p);
    }

    /// lookupOrShapeSegment return: glyphs either borrowed from cache or caller-owned.
    /// owned=true caller must `releaseGlyphFallbackFontRefs` + `free`;
    /// owned=false memory and its fallback_font_ref retains belong to cache,
    /// released by evict/deinit, caller only borrows for this draw.
    const SegmentGlyphs = struct {
        glyphs: []const text_module.ShapedGlyph,
        owned: bool,
    };

    /// Segment cache lookup/insert. Miss -> shape once: if it fits the cache, cache it (borrow),
    /// else (too long / put failed) **hand the caller ownership including glyphs**; never
    /// discard and retry. Shaping an oversized segment, discovering the over-limit, freeing it and
    /// returning null makes the caller shape again, so the longest code segments
    /// (identifiers/call expressions) pay CTLine creation twice per frame per line. The discard
    /// path must also release fallback_font_ref, else long segments with fallback glyphs leak a
    /// CTFontRef.
    fn lookupOrShapeSegment(
        self: *TextRenderer,
        seg_text: []const u8,
        font: *Font,
        use_italic: bool,
    ) !SegmentGlyphs {
        const italic_flag: u8 = if (use_italic) 1 else 0;
        const cache_key = SegmentCacheKey{
            .content_hash = std.hash.Wyhash.hash(@as(u64, italic_flag), seg_text),
            .font_ptr = @intFromPtr(font),
            .flags = italic_flag,
        };

        if (self.segment_cache.getPtr(cache_key)) |entry| {
            self.segment_cache_hits += 1;
            entry.frame_last_used = self.current_frame;
            return .{ .glyphs = entry.glyphs, .owned = false };
        }

        if (self.cache_long_segments) {
            if (self.long_segment_cache.get(cache_key, seg_text, self.current_frame)) |glyphs|
                return .{ .glyphs = glyphs, .owned = false };
        }

        // cache miss, shape this segment
        self.segment_cache_misses += 1;
        const shaped = try self.shaper.shapeWithOptions(seg_text, font, use_italic);

        // When inline capacity exceeded, try bounded long-segment cache; failure still hands
        // caller ownership.
        if (shaped.len > MAX_SEGMENT_GLYPHS) {
            const cached = self.cache_long_segments and self.long_segment_cache.adopt(self.allocator, cache_key, seg_text, shaped, self.current_frame);
            return .{ .glyphs = shaped, .owned = !cached };
        }

        const cached = self.adoptShortSegment(cache_key, shaped);
        return .{ .glyphs = shaped, .owned = !cached };
    }

    fn releaseSegmentEntry(allocator: std.mem.Allocator, entry: SegmentCacheEntry) void {
        releaseGlyphFallbackFontRefs(entry.glyphs);
        allocator.free(entry.glyphs);
    }

    /// Failure leaves incoming ownership with the caller and existing entries intact.
    /// Reserve metadata before eviction; committing the adopted slice cannot fail.
    fn adoptShortSegment(self: *TextRenderer, key: SegmentCacheKey, glyphs: []text_module.ShapedGlyph) bool {
        self.segment_cache.ensureUnusedCapacity(1) catch return false;
        if (self.segment_cache.fetchRemove(key)) |old| releaseSegmentEntry(self.allocator, old.value);
        if (self.segment_cache.count() >= SEGMENT_CACHE_MAX) self.evictSegmentCacheOnFull();
        self.segment_cache.putAssumeCapacity(key, .{ .glyphs = glyphs, .frame_last_used = self.current_frame });
        return true;
    }

    /// How wide a text segment ACTUALLY draws: uses the same segmentation, shaper and
    /// glyphAdvance formula as the drawTextWithOptions emit loop, just doesn't emit.
    ///
    /// Layout must use this instead of remeasuring: .fit width is "measure once, draw once"; two
    /// different answers = container shrinks per A, text draws per B, tail gets clipped. Drawn
    /// width is not a pure function of "text + font size", it depends on:
    ///   1. Which *Font shapes it (italic/mono/symbols/script fallback each pick their own)
    ///   2. Segmentation: draw segments per segmentText (CJK per codepoint, ASCII by word);
    ///      whole-string shaping produces cross-segment kerning/ligatures absent from per-segment
    ///      sums
    ///   3. fixed_advance (monospace grid) pushes ligatures by grid
    /// A re-implemented measure function must duplicate all three and they evolve independently,
    /// so divergence is inevitable. Hence no second algorithm, only this same one WITHOUT emit.
    ///
    /// Parameters mirror drawTextWithOptions one-to-one; pass the values the render-time call uses.
    pub fn measureTextWidthAsDrawn(
        self: *TextRenderer,
        text: []const u8,
        font: *Font,
        requested_size: f32,
        use_italic: bool,
        fixed_advance: f32,
    ) !f32 {
        if (text.len == 0) return 0;
        const font_physical_size = font.pixelSize();
        const width_key: WidthCache.Key = .{
            .hash = std.hash.Wyhash.hash(0, text),
            .font = @intFromPtr(font),
            .size = @bitCast(requested_size),
            .physical_size = @bitCast(font_physical_size),
            .scale = @bitCast(self.scale_factor),
            .advance = @bitCast(fixed_advance),
            .italic = use_italic,
        };
        if (self.width_cache.get(width_key, text)) |width| return width;
        const text_scale: f32 = if (requested_size > 0 and font_physical_size > 0)
            requested_size / font_physical_size
        else
            1.0;

        var total: f32 = 0;
        var seg_buf: [MAX_SEGMENTS]Segment = undefined;
        var text_pos: u32 = 0;
        while (text_pos < text.len) {
            const remaining = text[text_pos..];
            const seg_count = segmentText(remaining, &seg_buf);
            const effective_count = @min(seg_count, MAX_SEGMENTS);
            for (seg_buf[0..effective_count]) |seg| {
                const seg_text = remaining[seg.start..seg.end];
                const seg_end_byte: u32 = @intCast(seg_text.len);
                // Explicit font stack: **same** selectSegmentFont as draw emit loop.
                // Single-path buy-in = measured and drawn use different font, .fit container
                // clips tail, old bug recurs.
                const seg_font = self.selectSegmentFont(seg_text, font, requested_size);
                const seg_px = seg_font.pixelSize();
                const seg_scale: f32 = if (requested_size > 0 and seg_px > 0)
                    requested_size / seg_px
                else
                    text_scale;
                const shaped = try self.lookupOrShapeSegment(seg_text, seg_font, use_italic);
                defer if (shaped.owned) {
                    releaseGlyphFallbackFontRefs(shaped.glyphs);
                    self.allocator.free(shaped.glyphs);
                };
                for (shaped.glyphs, 0..) |g, i| {
                    const span = clusterSpanAt(shaped.glyphs, i, seg_end_byte);
                    // glyphAdvance only uses layout_scale / fixed_advance, other emit fields
                    // unrelated
                    // to width, pass zero.
                    total += glyphAdvance(g, span, .{
                        .requested_size = requested_size,
                        .layout_scale = seg_scale,
                        .scale = self.scale_factor,
                        .use_subpixel = false,
                        .snap_to_device_pixels = false,
                        .shader_snap = false,
                        .synthetic_skew = 0,
                        .font = font,
                        .fallback_font = null,
                        .instance_list = &self.instances_nearest,
                        .fixed_advance = fixed_advance,
                    });
                }
            }
            if (effective_count > 0) {
                text_pos += seg_buf[effective_count - 1].end;
            } else break;
            if (seg_count <= MAX_SEGMENTS) break;
        }
        self.width_cache.put(self.allocator, width_key, text, total);
        return total;
    }

    fn runHasLCD(self: *const TextRenderer, nearest_start: usize, linear_start: usize) bool {
        for ([_][]const GlyphInstance{ self.instances_nearest.items[nearest_start..], self.instances_linear.items[linear_start..] }) |instances|
            for (instances) |instance| if (instance.metadata.colorMode() == 2) return true;
        return false;
    }

    pub fn drawTextWithOptions(
        self: *TextRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        font: *Font,
        color: Color,
        requested_size: f32,
        use_italic: bool,
        fallback_font: ?*Font,
        force_linear: bool,
        shader_snap: bool,
        fixed_advance: f32,
    ) !void {
        if (comptime builtin.os.tag != .windows) return self.drawTextWithOptionsInternal(text, x, y, font, color, requested_size, use_italic, fallback_font, force_linear, shader_snap, fixed_advance);
        const nearest_start = self.instances_nearest.items.len;
        const linear_start = self.instances_linear.items.len;
        const allowed = self.cleartype_allowed;
        self.run_lcd_rejected = false;
        try self.drawTextWithOptionsInternal(text, x, y, font, color, requested_size, use_italic, fallback_font, force_linear, shader_snap, fixed_advance);
        if (allowed and self.run_lcd_rejected and !self.glyph_only and self.runHasLCD(nearest_start, linear_start)) {
            // A text command is one AA decision, including spans and fallback faces.
            self.instances_nearest.items.len = nearest_start;
            self.instances_linear.items.len = linear_start;
            self.cleartype_allowed = false;
            defer self.cleartype_allowed = allowed;
            try self.drawTextWithOptionsInternal(text, x, y, font, color, requested_size, use_italic, fallback_font, force_linear, shader_snap, fixed_advance);
        }
    }

    fn drawTextWithOptionsInternal(
        self: *TextRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        font: *Font,
        color: Color,
        requested_size: f32,
        use_italic: bool,
        fallback_font: ?*Font,
        force_linear: bool,
        shader_snap: bool,
        fixed_advance: f32,
    ) !void {
        if (comptime builtin.os.tag == .windows) {
            if (@import("zenit_environment").flag("ZENIT_TEXT_DIAGNOSTICS") and !self.glyph_only) {
                const record = try std.json.Stringify.valueAlloc(self.allocator, .{ .text = text, .x = x, .baseline = y, .size = requested_size, .weight = font.weight, .color = color.toArray(), .scale = self.scale_factor, .cleartype = self.cleartype_enabled and self.cleartype_allowed and !force_linear, .force_linear = force_linear }, .{});
                defer self.allocator.free(record);
                std.debug.print("TEXT_DRAW {s}\n", .{record});
            }
        }
        const instances_before = self.instances_nearest.items.len + self.instances_linear.items.len;

        // Calculate scale factor: UI requested size / font physical size
        const font_physical_size = font.pixelSize();
        const text_scale: f32 = if (requested_size > 0 and font_physical_size > 0)
            requested_size / font_physical_size
        else
            1.0;
        const use_nearest = !force_linear and @abs(text_scale - 1.0) <= 0.01;
        // Static cached Windows text keeps raster phase; the surface still composites
        // linearly. Animated glyphs retain continuous placement without phase bins.
        const use_subpixel = (use_nearest or (builtin.os.tag == .windows and shader_snap)) and self.scale_factor > 0;
        const scale = self.scale_factor;
        const synthetic_skew: f32 = requested_size * 0.75 * 0.2126;
        const instance_list = if (use_nearest) &self.instances_nearest else &self.instances_linear;

        const emit_params = EmitParams{
            .requested_size = requested_size,
            .layout_scale = text_scale,
            .scale = scale,
            .use_subpixel = use_subpixel,
            .snap_to_device_pixels = !force_linear,
            .shader_snap = shader_snap,
            .synthetic_skew = synthetic_skew,
            .font = font,
            .fallback_font = fallback_font,
            .instance_list = instance_list,
            .fixed_advance = fixed_advance,
            .raster_font = self.raster_font,
        };

        if (try self.emitFontRanges(text, x, y, color, use_italic, emit_params, &.{})) return;

        // Horizontal viewport clip boundary (logical pixels)
        const clip_left = self.clip_x_min;
        const clip_right = self.clip_x_max;

        // Segment split + per-segment render (unified path, auto-continue on overflow)
        var cursor_x = x;
        var seg_buf: [MAX_SEGMENTS]Segment = undefined;
        var text_pos: u32 = 0; // byte offset processed so far

        while (text_pos < text.len) {
            if (cursor_x > clip_right) break;

            // Segment-split remaining text
            const remaining = text[text_pos..];
            const seg_count = segmentText(remaining, &seg_buf);
            const effective_count = @min(seg_count, MAX_SEGMENTS);

            for (seg_buf[0..effective_count]) |seg| {
                if (cursor_x > clip_right) break;

                const seg_text = remaining[seg.start..seg.end];
                cursor_x = try self.shapeAndEmitSegment(seg_text, cursor_x, y, color, clip_left, text_scale, font, use_italic, emit_params);
            }

            // Update processed offset
            if (effective_count > 0) {
                text_pos += seg_buf[effective_count - 1].end;
            } else {
                break; // Cannot segment (empty text), exit
            }

            // Didn't overflow -> fully processed all text
            if (seg_count <= MAX_SEGMENTS) break;
        }

        const instances_after = self.instances_nearest.items.len + self.instances_linear.items.len;
        if (self.ink_probe == null and text.len > 0 and instances_after == instances_before) {
            text_trace.log(
                self.current_frame,
                "draw-text-no-instances hash=0x{x} len={d} x={d:.1} y={d:.1} size={d:.1} linear={} clip=[{d:.1},{d:.1}]",
                .{
                    std.hash.Wyhash.hash(0, text),
                    text.len,
                    x,
                    y,
                    requested_size,
                    force_linear,
                    clip_left,
                    clip_right,
                },
            );
        }
    }

    fn emitFontRanges(self: *TextRenderer, content: []const u8, x: f32, y: f32, color: Color, italic: bool, params: EmitParams, spans: []const ColorSpan) !bool {
        if (comptime builtin.os.tag != .windows) return false;
        const ranges = self.active_font_ranges orelse return false;
        const glyphs = try self.shaper.shapeWithRanges(content, params.font, italic, ranges);
        defer self.allocator.free(glyphs);
        defer releaseGlyphFallbackFontRefs(glyphs);
        var cursor = x;
        for (glyphs, 0..) |glyph, index| {
            var p = params;
            // A provider-selected face is intentional, not an automatic fallback.
            // Keep the same fractional-origin raster policy as direct selection.
            p.explicit_range_raster = true;
            // Explicit range sizes affect raster dimensions as well as advance.
            // Preserve shaping scale; do not normalize every run to base size.
            if (glyph.fallback_font_ref) |ref| p.requested_size = text_module.fallbackFontRefSize(ref) * params.layout_scale;
            var glyph_color = color;
            // Visual-order glyphs may have descending clusters (RTL).
            for (spans) |span| {
                if (span.start <= glyph.cluster and glyph.cluster < span.end) {
                    glyph_color = span.color;
                    break;
                }
            }
            cursor += try self.emitGlyphInstance(glyph, clusterSpanAt(glyphs, index, @intCast(content.len)), cursor, y, glyph_color, p);
        }
        return true;
    }

    /// Helper: shape and emit single text segment (no spans), return updated cursor_x.
    /// Supports left-boundary skip (shape but don't emit) and segment cache.
    fn shapeAndEmitSegment(
        self: *TextRenderer,
        seg_text: []const u8,
        cursor_x_in: f32,
        y: f32,
        color: Color,
        clip_left: f32,
        _: f32,
        font: *Font,
        use_italic: bool,
        p: EmitParams,
    ) !f32 {
        var cursor_x = cursor_x_in;

        const seg_end_byte: u32 = @intCast(seg_text.len);
        // Explicit font stack: per-segment-start codepoint font selection before shaping
        // (see selectSegmentFont).
        const seg_font = self.selectSegmentFont(seg_text, font, p.requested_size);
        const seg_p = if (seg_font != font) emitParamsForSegmentFont(p, seg_font) else p;
        const seg = try self.lookupOrShapeSegment(seg_text, seg_font, use_italic);
        defer if (seg.owned) {
            releaseGlyphFallbackFontRefs(seg.glyphs);
            self.allocator.free(seg.glyphs);
        };
        const glyphs = seg.glyphs;
        self.logEnclosedDigitFontDebug(seg_text, seg_font, use_italic, seg_p.fallback_font, glyphs, if (seg.owned) "fresh-shape" else "segment-cache");
        if (cursor_x < clip_left) {
            var adv: f32 = 0;
            for (glyphs, 0..) |g, i| adv += glyphAdvance(g, clusterSpanAt(glyphs, i, seg_end_byte), seg_p);
            if (cursor_x + adv < clip_left) return cursor_x + adv;
        }
        var previous_ref: ?*anyopaque = null;
        var previous_font: ?*Font = null;
        for (glyphs, 0..) |g, i| {
            const span = clusterSpanAt(glyphs, i, seg_end_byte);
            var glyph_params = seg_p;
            // Consecutive glyphs in one shaped run share an owned native ref.
            // Resolve its font once within this call; never cache borrowed ref
            // pointers across calls, where allocator reuse could alias fonts.
            if (g.is_fallback_font and g.fallback_font_ref != null) {
                if (previous_ref != g.fallback_font_ref) {
                    previous_font = try self.selectRenderFontForGlyph(g, seg_p);
                    previous_ref = g.fallback_font_ref;
                }
                glyph_params.resolved_font = previous_font;
            }
            cursor_x += try self.emitGlyphInstance(g, span, cursor_x, y, color, glyph_params);
        }
        return cursor_x;
    }

    /// Text color span for drawTextWithSpans per-glyph coloring
    pub const ColorSpan = struct {
        start: u32, // byte offset within content
        end: u32,
        color: Color,
    };

    /// Shape full line once + per-glyph color by span (segment-cache version)
    pub fn drawTextWithSpans(
        self: *TextRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        font: *Font,
        base_color: Color,
        requested_size: f32,
        use_italic: bool,
        fallback_font: ?*Font,
        force_linear: bool,
        shader_snap: bool,
        fixed_advance: f32,
        spans: []const ColorSpan,
    ) !void {
        if (comptime builtin.os.tag != .windows) return self.drawTextWithSpansInternal(text, x, y, font, base_color, requested_size, use_italic, fallback_font, force_linear, shader_snap, fixed_advance, spans);
        const nearest_start = self.instances_nearest.items.len;
        const linear_start = self.instances_linear.items.len;
        const allowed = self.cleartype_allowed;
        self.run_lcd_rejected = false;
        try self.drawTextWithSpansInternal(text, x, y, font, base_color, requested_size, use_italic, fallback_font, force_linear, shader_snap, fixed_advance, spans);
        if (allowed and self.run_lcd_rejected and !self.glyph_only and self.runHasLCD(nearest_start, linear_start)) {
            // A text command is one AA decision, including spans and fallback faces.
            self.instances_nearest.items.len = nearest_start;
            self.instances_linear.items.len = linear_start;
            self.cleartype_allowed = false;
            defer self.cleartype_allowed = allowed;
            try self.drawTextWithSpansInternal(text, x, y, font, base_color, requested_size, use_italic, fallback_font, force_linear, shader_snap, fixed_advance, spans);
        }
    }

    fn drawTextWithSpansInternal(
        self: *TextRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        font: *Font,
        base_color: Color,
        requested_size: f32,
        use_italic: bool,
        fallback_font: ?*Font,
        force_linear: bool,
        shader_snap: bool,
        fixed_advance: f32,
        spans: []const ColorSpan,
    ) !void {
        const font_physical_size = font.pixelSize();
        const text_scale: f32 = if (requested_size > 0 and font_physical_size > 0)
            requested_size / font_physical_size
        else
            1.0;
        const use_nearest = !force_linear and @abs(text_scale - 1.0) <= 0.01;
        // Static cached Windows text keeps raster phase; the surface still composites
        // linearly. Animated glyphs retain continuous placement without phase bins.
        const use_subpixel = (use_nearest or (builtin.os.tag == .windows and shader_snap)) and self.scale_factor > 0;
        const scale = self.scale_factor;
        const synthetic_skew: f32 = requested_size * 0.75 * 0.2126;
        const instance_list = if (use_nearest) &self.instances_nearest else &self.instances_linear;

        const emit_params = EmitParams{
            .requested_size = requested_size,
            .layout_scale = text_scale,
            .scale = scale,
            .use_subpixel = use_subpixel,
            .snap_to_device_pixels = !force_linear,
            .shader_snap = shader_snap,
            .synthetic_skew = synthetic_skew,
            .font = font,
            .fallback_font = fallback_font,
            .instance_list = instance_list,
            .fixed_advance = fixed_advance,
            .raster_font = self.raster_font,
        };

        if (try self.emitFontRanges(text, x, y, base_color, use_italic, emit_params, spans)) return;

        // Horizontal viewport clip boundary (logical pixels)
        const clip_left = self.clip_x_min;
        const clip_right = self.clip_x_max;

        // Segment split + per-segment render (unified path, auto-continue on overflow)
        var cursor_x = x;
        var span_idx: usize = 0;
        var seg_buf: [MAX_SEGMENTS]Segment = undefined;
        var text_pos: u32 = 0;

        while (text_pos < text.len) {
            if (cursor_x > clip_right) break;

            const remaining = text[text_pos..];
            const seg_count = segmentText(remaining, &seg_buf);
            const effective_count = @min(seg_count, MAX_SEGMENTS);

            for (seg_buf[0..effective_count]) |seg| {
                if (cursor_x > clip_right) break;

                const seg_text = remaining[seg.start..seg.end];
                // Global byte offset = text_pos + offset within segment (for span matching)
                const global_start = text_pos + seg.start;
                const global_end = text_pos + seg.end;
                cursor_x = try self.shapeAndEmitSegmentWithSpans(seg_text, global_start, cursor_x, y, base_color, clip_left, text_scale, font, use_italic, emit_params, spans, &span_idx, global_end);
            }

            if (effective_count > 0) {
                text_pos += seg_buf[effective_count - 1].end;
            } else {
                break;
            }

            if (seg_count <= MAX_SEGMENTS) break;
        }
    }

    /// Helper: shape and emit single span-bearing segment, return updated cursor_x.
    fn shapeAndEmitSegmentWithSpans(
        self: *TextRenderer,
        seg_text: []const u8,
        global_byte_start: u32,
        cursor_x_in: f32,
        y: f32,
        base_color: Color,
        clip_left: f32,
        _: f32,
        font: *Font,
        use_italic: bool,
        p: EmitParams,
        spans: []const ColorSpan,
        span_idx: *usize,
        global_byte_end: u32,
    ) !f32 {
        var cursor_x = cursor_x_in;

        // Explicit font stack: same shaping-before-selection as shapeAndEmitSegment.
        const seg_font = self.selectSegmentFont(seg_text, font, p.requested_size);
        const seg_p = if (seg_font != font) emitParamsForSegmentFont(p, seg_font) else p;
        // Shape: cache-borrowed or this-time-owned, owned -> this function releases.
        const seg = try self.lookupOrShapeSegment(seg_text, seg_font, use_italic);
        defer if (seg.owned) {
            releaseGlyphFallbackFontRefs(seg.glyphs);
            self.allocator.free(seg.glyphs);
        };
        const glyphs = seg.glyphs;
        self.logEnclosedDigitFontDebug(seg_text, seg_font, use_italic, seg_p.fallback_font, glyphs, if (seg.owned) "fresh-shape-spans" else "segment-cache-spans");

        const seg_end_byte: u32 = @intCast(seg_text.len);
        // Left-boundary clip: entire segment left of viewport -> skip emit
        if (cursor_x < clip_left) {
            var adv: f32 = 0;
            for (glyphs, 0..) |g, i| adv += glyphAdvance(g, clusterSpanAt(glyphs, i, seg_end_byte), seg_p);
            if (cursor_x + adv < clip_left) {
                while (span_idx.* < spans.len and spans[span_idx.*].end <= global_byte_end) span_idx.* += 1;
                return cursor_x + adv;
            }
        }

        // Emit with per-glyph span coloring
        for (glyphs, 0..) |glyph, i| {
            const global_cluster = glyph.cluster + global_byte_start;
            var glyph_color = base_color;
            while (span_idx.* < spans.len and spans[span_idx.*].end <= global_cluster) span_idx.* += 1;
            if (span_idx.* < spans.len and spans[span_idx.*].start <= global_cluster and global_cluster < spans[span_idx.*].end) {
                glyph_color = spans[span_idx.*].color;
            }
            const span = clusterSpanAt(glyphs, i, seg_end_byte);
            cursor_x += try self.emitGlyphInstance(glyph, span, cursor_x, y, glyph_color, seg_p);
        }
        return cursor_x;
    }

    /// Mid-flush: draw accumulated glyph instances and clear buffer.
    /// Ensures text draws per correct clip region before scissor rect change.
    /// Multi-Page: per page_index bucket, each bucket switches texture then draws
    pub fn flush(self: *TextRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        const nearest_count = self.instances_nearest.items.len;
        const linear_count = self.instances_linear.items.len;
        if (nearest_count == 0 and linear_count == 0) return;
        if (comptime builtin.os.tag == .windows) {
            for ([_][]const GlyphInstance{ self.instances_nearest.items, self.instances_linear.items }) |instances| {
                for (instances) |instance| {
                    if (instance.metadata.colorMode() == 2) self.lcd_glyph_count += 1;
                    if (instance.metadata.colorMode() == 0) self.gray_glyph_count += 1;
                }
            }
        }

        // Update uniform buffer.
        //
        // Overflow **cannot** clamp to the last slot: that aliases the batch and subsequent draws
        // to
        // soon-overwritten memory (silent wrong draw). It also **cannot** drop the batch: a flush
        // failure doesn't reach clearRetainingCapacity below, instances stay, the next batch
        // overflows
        // again with stale instances, and the frame renders **nothing** from that point.
        //
        // Correct: keep drawing. Out of slots -> switch to a grow-on-demand cross-frame retained
        // overflow buffer.
        const uniform_buffer, const uniform_byte_offset = blk: {
            if (self.uniform_write_offset < MAX_UNIFORM_UPDATES) {
                const slot = self.uniform_write_offset;
                self.uniform_write_offset += 1;
                break :blk .{ &self.uniform_buffers[self.current_buffer], slot * UNIFORM_STRIDE };
            }
            self.uniform_overflow_count += 1;
            text_uniform_overflow_total += 1;
            const slot = self.uniform_overflow_used;
            const buf = try self.ensureUniformOverflowCapacity(slot + 1);
            self.uniform_overflow_used += 1;
            break :blk .{ buf, slot * UNIFORM_STRIDE };
        };
        const peak = self.uniform_write_offset + self.uniform_overflow_used;
        if (peak > self.uniform_peak_slots) self.uniform_peak_slots = peak;
        const uniforms = Uniforms{
            .viewport_size = .{ self.viewport_width, self.viewport_height },
            .scale_factor = self.scale_factor,
            .clip_shape_kind = self.clip_shape_kind,
            .clip2 = shape_clip_pair.field(self.clip2),
            .clip_rect = self.clip_rect,
            .clip_radii = self.clip_radii,
            .clip_fill_rule = self.clip_fill_rule,
            .clip_point_count = self.clip_point_count,
            .clip_contour_count = self.clip_contour_count,
            .clip_polygon_end_points = self.clip_polygon_end_points,
            .clip_polygon_points = self.clip_polygon_points,
            .dwrite_gamma = if (builtin.os.tag == .windows) self.dwrite_params[0..4].* else .{},
            .dwrite_settings = if (builtin.os.tag == .windows) self.dwrite_params[4..8].* else .{},
        };
        const uniform_data = try uniform_buffer.getMappedRange(uniform_byte_offset, @sizeOf(Uniforms));
        @memcpy(uniform_data, std.mem.asBytes(&uniforms));

        // Set pipeline
        render_pass.setPipeline(&self.pipeline);

        // Text fragment shader also reads buffer(0) clip/uniform. Binding only vertex buffer
        // leaves fragment stage with stale or undefined state; offscreen/clip switch scenes
        // show first-frame text clipped wrong.
        // One uniform slot, not the rest of the ring: Direct3D snapshots the bound
        // range per draw (constant buffers over 4 KiB are copied into a new buffer).
        gpu.setVertexBufferRange(render_pass, 0, uniform_buffer, @intCast(uniform_byte_offset), UNIFORM_STRIDE);
        gpu.setFragmentBufferRange(render_pass, 0, uniform_buffer, @intCast(uniform_byte_offset), UNIFORM_STRIDE);

        // Nearest pass (1:1 scale), per page_index bucket
        if (nearest_count > 0) {
            if (self.atlas.getSamplerNearest()) |sampler| {
                render_pass.setFragmentSampler(0, sampler);
            }
            try self.flushInstanceList(&self.instances_nearest, render_pass);
        }

        // Linear pass (non-1:1 scale), per page_index bucket
        if (linear_count > 0) {
            if (self.atlas.getSamplerLinear()) |sampler| {
                render_pass.setFragmentSampler(0, sampler);
            }
            try self.flushInstanceList(&self.instances_linear, render_pass);
        }

        // Clear instance buffer, continue collecting subsequent text
        self.instances_nearest.clearRetainingCapacity();
        self.instances_linear.clearRetainingCapacity();
        self.pending_generation +%= 1;
    }

    /// Ensure this frame's slot overflow uniform buffer can hold at least `slots` Uniforms.
    fn ensureUniformOverflowCapacity(self: *TextRenderer, slots: usize) !*gpu.Backend.Buffer {
        return (try self.uniform_overflow.ensure(self.allocator, self.device, self.current_buffer, slots * UNIFORM_STRIDE)).buffer;
    }

    /// Per page_index bucket flush one instance list. Iterate instances, find contiguous
    /// same page_index spans, each span switches texture then draws
    fn flushInstanceList(self: *TextRenderer, list: *std.ArrayList(GlyphInstance), render_pass: *gpu.Backend.RenderPass) !void {
        const items = list.items;
        const total = items.len;
        if (total == 0) return;
        self.instance_high_water_mark = @max(self.instance_high_water_mark, total);

        var batch_start: usize = 0;
        while (batch_start < total) {
            const cur_page: u8 = items[batch_start].metadata.pageIndex();
            var batch_end = batch_start + 1;
            while (batch_end < total and items[batch_end].metadata.pageIndex() == cur_page) {
                batch_end += 1;
            }

            // Bind this page's texture.
            // Batches are bucketed by page_index and one page_index determines one page's format,
            // so
            // format within a batch is consistent: grayscale page binds texture(0), color page
            // binds
            // texture(1), mapping to the shader's two binding points.
            // Both slots must always bind a **valid** texture: sampling an unbound texture is
            // undefined
            // behavior in Metal, and although only one fragment shader branch produces output, the
            // compiler may speculatively sample the other. So the other slot uses page 0
            // (guaranteed by
            // init, grayscale page) as a pure placeholder that doesn't affect output.
            const texture = self.atlas.getPageTexture(cur_page) orelse {
                // A stale page index must never draw with the previous batch's binding. The atlas
                // normally pins pages used in this frame; skipping is the fail-closed fallback if
                // that invariant ever regresses.
                //
                // Warning: skip = glyphs **in this page bucket don't draw at all** (same-batch
                // characters
                // vanish, with position gaps). By design this path never hits; if it does it must
                // shout,
                // else it is another silent character-loss point visible only in screenshots.
                std.log.warn("[TextRenderer] stale atlas page index {d} (pages: {d}); dropping batch segment of {d} glyphs", .{ cur_page, self.atlas.getPageCount(), batch_end - batch_start });
                batch_start = batch_end;
                continue;
            };
            const is_color_page = (self.atlas.getPageFormat(cur_page) orelse .gray) == .color;
            const fallback = self.atlas.getPageTexture(0) orelse texture;
            if (is_color_page) {
                render_pass.setFragmentTextureBinding(0, fallback);
                render_pass.setFragmentTextureBinding(1, texture);
            } else {
                render_pass.setFragmentTextureBinding(0, texture);
                render_pass.setFragmentTextureBinding(1, fallback);
            }

            // Write instance buffer and draw. Note: Metal command buffer deferred execution,
            // can't wrap-overwrite in same frame, else prior draw call's referenced offset
            // already overwritten at commit
            const batch = batch_end - batch_start;
            const instance_size = @sizeOf(GlyphInstance) * batch;
            const byte_offset = self.buffer_write_offset * @sizeOf(GlyphInstance);
            const slot = try self.instance_buffers.ensure(self.allocator, self.device, self.current_buffer, byte_offset + instance_size);
            const instance_data = try slot.buffer.getMappedRange(byte_offset, instance_size);
            @memcpy(instance_data, std.mem.sliceAsBytes(items[batch_start..batch_end]));
            gpu.setVertexBufferRange(render_pass, 1, slot.buffer, @intCast(byte_offset), @intCast(instance_size));
            gpu.setFragmentBufferRange(render_pass, 1, slot.buffer, @intCast(byte_offset), @intCast(instance_size));
            self.buffer_write_offset += batch;
            if (comptime gpu.backend_kind == .metal) {
                render_pass.drawTriangleStrip(4, @intCast(batch), 0, 0);
            } else {
                render_pass.draw(6, @intCast(batch), 0, 0);
            }
            text_draw_calls += 1;

            batch_start = batch_end;
        }
    }

    /// End frame and render
    pub fn endFrame(self: *TextRenderer, render_pass: *gpu.Backend.RenderPass) !void {
        try self.flush(render_pass);
        if (self.atlas.frame_insert_count > 0 or self.atlas_gc_happened) {
            text_trace.log(
                self.current_frame,
                "text-frame-summary inserts={d} gc={} atlas_pages={d} atlas_cache={d} nearest={d} linear={d}",
                .{
                    self.atlas.frame_insert_count,
                    self.atlas_gc_happened,
                    self.atlas.page_count,
                    self.atlas.getCacheSize(),
                    self.instances_nearest.items.len,
                    self.instances_linear.items.len,
                },
            );
        }
    }

    /// Get atlas cache size
    pub fn getAtlasCacheSize(self: *TextRenderer) usize {
        return self.atlas.getCacheSize();
    }

    pub fn getPendingInstanceCount(self: *TextRenderer) usize {
        return self.instances_nearest.items.len + self.instances_linear.items.len;
    }
};

// -- segmentText: RTL whole-segment unit test --
//
// RTL must go to CoreText as a whole segment, else bidi reorder / Arabic connect forms /
// diacritic attachment break. Pins segment boundaries here to prevent chunking RTL for
// cache granularity.
const seg_testing = std.testing;

fn segCountOf(text: []const u8, out: *[MAX_SEGMENTS]Segment) u32 {
    return segmentText(text, out);
}

test "segmentText: 纯阿拉伯语整串为单段（连写形态依赖左右邻居）" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{645}\u{631}\u{62D}\u{628}\u{627}";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 1), n);
    try seg_testing.expectEqual(@as(u32, 0), buf[0].start);
    try seg_testing.expectEqual(@as(u32, s.len), buf[0].end);
}

test "segmentText: 纯希伯来语整串为单段" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{5E9}\u{5DC}\u{5D5}\u{5DD}";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 1), n);
    try seg_testing.expectEqual(@as(u32, s.len), buf[0].end);
}

test "segmentText: RTL 词间空格并入同一段（同一 bidi run 不可拆）" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{5E9}\u{5DC} \u{5D5}\u{5DD}";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 1), n);
    try seg_testing.expectEqual(@as(u32, s.len), buf[0].end);
}

test "segmentText: RTL 尾随空格不并入 RTL 段" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{5E9}\u{5DC}  ";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 2), n);
    // First segment only RTL letters (2 chars x 2 bytes)
    try seg_testing.expectEqual(@as(u32, 4), buf[0].end);
}

test "segmentText: 混排 latin+arabic+latin 切成三段且 RTL 段完整" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "ab\u{645}\u{631}\u{62D}cd";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 3), n);
    try seg_testing.expectEqual(@as(u32, 0), buf[0].start);
    try seg_testing.expectEqual(@as(u32, 2), buf[0].end); // "ab"
    try seg_testing.expectEqual(@as(u32, 2), buf[1].start);
    try seg_testing.expectEqual(@as(u32, 8), buf[1].end); // 3 Arabic letters x 2 bytes
    try seg_testing.expectEqual(@as(u32, 8), buf[2].start);
    try seg_testing.expectEqual(@as(u32, 10), buf[2].end); // "cd"
}

test "segmentText: LTR 未退化 —— ASCII 仍按词分段" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const n = segCountOf("hello world", &buf);
    try seg_testing.expectEqual(@as(u32, 2), n);
    try seg_testing.expectEqual(@as(u32, 6), buf[0].end); // 'hello ' with trailing space
}

test "segmentText: CJK 未退化 —— 仍每码点独立" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const n = segCountOf("\u{4F60}\u{597D}", &buf);
    try seg_testing.expectEqual(@as(u32, 2), n);
}

// -- segmentText: byte coverage completeness + VS16 emoji presentation --
//
// Both bug classes are silent: dropped bytes don't error, later segment start/end just
// misalign from the original; a stripped VS16 doesn't error, the heart just reverts to
// single-color with the narrow glyph width (12.742 vs 19.0), showing as caret offset.

/// All segments must **exactly** stitch back to original: no holes, no overlap,
/// total length equal.
fn expectFullCoverage(text: []const u8) !void {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const n = segCountOf(text, &buf);
    var prev_end: u32 = 0;
    var covered: usize = 0;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        try seg_testing.expectEqual(prev_end, buf[k].start); // No holes/overlap
        covered += buf[k].end - buf[k].start;
        prev_end = buf[k].end;
    }
    try seg_testing.expectEqual(text.len, covered);
    if (n > 0) try seg_testing.expectEqual(@as(u32, @intCast(text.len)), prev_end);
}

test "segmentText: keycap sequence is one segment, split from the ASCII run around it" {
    var segs: [MAX_SEGMENTS]Segment = undefined;
    const s = "ab3\u{FE0F}\u{20E3} #\u{20E3}x";
    const n = segmentText(s, &segs);
    try std.testing.expectEqual(@as(u32, 4), n);
    try std.testing.expectEqualStrings("ab", s[segs[0].start..segs[0].end]);
    try std.testing.expectEqualStrings("3\u{FE0F}\u{20E3} ", s[segs[1].start..segs[1].end]);
    try std.testing.expectEqualStrings("#\u{20E3}", s[segs[2].start..segs[2].end]);
    try std.testing.expectEqualStrings("x", s[segs[3].start..segs[3].end]);
    // a plain digit is not a keycap
    try std.testing.expectEqual(@as(u32, 1), segmentText("a3b", &segs));
    try expectFullCoverage("ab3\u{FE0F}\u{20E3} #\u{20E3}x");
}

test "segmentText: VS16 与基字同段（❤+FE0F 不可拆，否则退回单色窄字形）" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    const s = "\u{2764}\u{FE0F}";
    const n = segCountOf(s, &buf);
    try seg_testing.expectEqual(@as(u32, 1), n);
    try seg_testing.expectEqual(@as(u32, 0), buf[0].start);
    try seg_testing.expectEqual(@as(u32, 6), buf[0].end); // 3(❤) + 3(VS16)
}

test "segmentText: 字节覆盖完整 —— VS16 序列不得吞字节" {
    try expectFullCoverage("\u{2764}\u{FE0F}");
    try expectFullCoverage("abc\u{2764}\u{FE0F}def");
    try expectFullCoverage("a\u{FE0F}b"); // Isolated VS16 must segment too
    try expectFullCoverage("abc\u{1F62D}def\u{9876}\u{8D77}\u{2764}\u{FE0F}\u{2705}\u{2728}");
}

test "segmentText: 字节覆盖完整 —— 实测丢字文档的原文行（下游编辑器滚动丢字回归）" {
    // These lines were observed to lose their middle or tail when a downstream editor rendered a
    // canvas-engine research document.
    try expectFullCoverage("Figma 说自己是 tile-based，但没说怎么做。我们要不要跟？");
    try expectFullCoverage("代价是：一套持久 tile 池 + 失效逻辑 + 额外显存。");
    try expectFullCoverage("**但 300 draw call 在 Apple Silicon 上依然是很小的负载**（量级参考：");
    try expectFullCoverage("超过则应先做**按纹理排序**（把同纹理对象排到一起，在 z 序允许时合并），");
    try expectFullCoverage("\"连续同纹理的 instance 合成一次 draw\"（`image_renderer.zig:640`）。");
}

test "segmentText: emoji 后的普通符号不被吞进 emoji 段" {
    var buf: [MAX_SEGMENTS]Segment = undefined;
    // Fire emoji followed by arrow -> (U+2192, in isEmojiCapable range but not
    // ZWJ-connected)
    const n = segCountOf("\u{1F525}\u{2192}", &buf);
    try seg_testing.expectEqual(@as(u32, 2), n);
}

test "long segment cache bounds ownership and rejects hash collisions" {
    const allocator = std.testing.allocator;
    var cache: LongSegmentCache = .{};
    defer cache.deinit(allocator);
    for (0..LongSegmentCache.max_entries + 8) |i| {
        const key = SegmentCacheKey{ .content_hash = i, .font_ptr = 1, .flags = 0 };
        const glyphs = try allocator.alloc(text_module.ShapedGlyph, 103);
        @memset(glyphs, std.mem.zeroes(text_module.ShapedGlyph));
        glyphs[0].glyph_index = @intCast(i);
        try std.testing.expect(cache.adopt(allocator, key, "long segment", glyphs, i));
        try std.testing.expect(cache.entries.count() <= LongSegmentCache.max_entries);
        try std.testing.expectEqual(@as(u32, @intCast(i)), cache.get(key, "long segment", i).?[0].glyph_index);
        try std.testing.expect(cache.get(key, "different content", i) == null);
    }
    const first = SegmentCacheKey{ .content_hash = 0, .font_ptr = 1, .flags = 0 };
    try std.testing.expect(cache.get(first, "long segment", 100) == null);
    const live = SegmentCacheKey{ .content_hash = 8, .font_ptr = 1, .flags = 0 };
    try std.testing.expect(cache.get(live, "long segment", 100) != null);
    const replacement = try allocator.alloc(text_module.ShapedGlyph, 40);
    @memset(replacement, std.mem.zeroes(text_module.ShapedGlyph));
    try std.testing.expect(cache.adopt(allocator, first, "replacement", replacement, 101));
    try std.testing.expect(cache.get(live, "long segment", 102) != null);
    const huge = try allocator.alloc(text_module.ShapedGlyph, LongSegmentCache.max_glyphs + 1);
    defer allocator.free(huge);
    try std.testing.expect(!cache.adopt(allocator, first, "too large", huge, 103));
    try std.testing.expect(cache.get(first, "replacement", 104) != null);
}

test "long segment cache allocation failures leave glyph ownership with caller" {
    const allocator = std.testing.allocator;
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var cache: LongSegmentCache = .{};
        defer cache.deinit(failing.allocator());
        const glyphs = try allocator.alloc(text_module.ShapedGlyph, 103);
        defer allocator.free(glyphs);
        @memset(glyphs, std.mem.zeroes(text_module.ShapedGlyph));
        const key = SegmentCacheKey{ .content_hash = 1, .font_ptr = 1, .flags = 0 };
        try std.testing.expect(!cache.adopt(failing.allocator(), key, "text", glyphs, 0));
        try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
        glyphs[0].glyph_index = 42;
        try std.testing.expectEqual(@as(u32, 42), glyphs[0].glyph_index);
    }
}

test "long segment cache preserves real shaped glyphs including fallback fonts" {
    // SKIP-REASON: needs real CoreText font system (findFont/shape), absent non-macOS
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fs = try text_module.FontSystem.init(allocator, @import("std").testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Menlo", .size = 14 });
    defer font.deinit();
    var shaper = try TextShaper.init(allocator);
    defer shaper.deinit();
    var cache: LongSegmentCache = .{};
    defer cache.deinit(allocator);
    const sample = (@as([("A").len * (80)]u8, @bitCast(@as([80][("A").len]u8, @splat(("A").*)))) ++ "") ++ "中文🙂";
    const shaped = try shaper.shapeWithOptions(sample, font, false);
    var caller_owned = true;
    defer if (caller_owned) {
        TextRenderer.releaseGlyphFallbackFontRefs(shaped);
        allocator.free(shaped);
    };
    const key = SegmentCacheKey{ .content_hash = 1, .font_ptr = @intFromPtr(font), .flags = 0 };
    caller_owned = !cache.adopt(allocator, key, sample, shaped, 1);
    try std.testing.expect(!caller_owned);
    const cached = cache.get(key, sample, 2).?;
    try std.testing.expect(cached.ptr == shaped.ptr);
    const reference = try shaper.shapeWithOptions(sample, font, false);
    defer {
        TextRenderer.releaseGlyphFallbackFontRefs(reference);
        allocator.free(reference);
    }
    try std.testing.expectEqual(reference.len, cached.len);
    var fallback_refs: usize = 0;
    for (reference, cached) |expected, actual| {
        inline for (.{ "glyph_index", "cluster", "x_advance", "y_advance", "x_offset", "y_offset", "is_synthetic_italic", "is_fallback_font" }) |field| {
            try std.testing.expectEqual(@field(expected, field), @field(actual, field));
        }
        if (actual.fallback_font_ref != null) fallback_refs += 1;
    }
    try std.testing.expect(fallback_refs > 0);
}

/// Assemble fallback wrapper path-only fields (allocator / fallback_font_cache /
/// current_frame / atlas.cache), rest GPU resources stay undefined, tested function
/// untouches them.
fn fallbackOnlyRendererForTest(allocator: std.mem.Allocator) TextRenderer {
    var tr: TextRenderer = undefined;
    tr.allocator = allocator;
    tr.current_frame = 0;
    tr.fallback_font_cache = std.AutoHashMap(u64, FallbackFontCacheEntry).init(allocator);
    tr.atlas.cache = @TypeOf(tr.atlas.cache).init(std.testing.allocator);
    return tr;
}

test "fallback wrapper: cache put OOM 时 errdefer 不 double free" {
    // SKIP-REASON: needs real CTFontRef as fallback ref
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fs = try text_module.FontSystem.init(allocator, @import("std").testing.io);
    defer fs.deinit();
    const proto = try fs.findFont(.{ .family = "Helvetica", .size = 14 });
    defer proto.deinit();

    // fail_index 0 = create(Font) succeeds, 1 = fallback_font_cache.put resizes fails.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var tr = fallbackOnlyRendererForTest(failing.allocator());
    defer tr.atlas.cache.deinit();
    defer tr.fallback_font_cache.deinit();
    try std.testing.expectError(error.OutOfMemory, tr.getOrCreateGlyphFallbackFont(proto.ct_font, proto));
    // Created wrapper destroyed exactly once (testing allocator errors on
    // double-free / leak).
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
}

test "fallback wrapper 驱逐时摘除其 atlas 条目（地址复用不命中旧位图）" {
    // SKIP-REASON: needs real CTFontRef as fallback ref
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fs = try text_module.FontSystem.init(allocator, @import("std").testing.io);
    defer fs.deinit();
    const proto = try fs.findFont(.{ .family = "Helvetica", .size = 14 });
    defer proto.deinit();

    var tr = fallbackOnlyRendererForTest(allocator);
    defer tr.atlas.cache.deinit();
    defer {
        var it = tr.fallback_font_cache.iterator();
        while (it.next()) |e| e.value_ptr.font.deinit();
        tr.fallback_font_cache.deinit();
    }
    const wrapper = try tr.getOrCreateGlyphFallbackFont(proto.ct_font, proto);
    const region = atlas_mod.AtlasRegion{
        .uv_min = .{ 0, 0 },
        .uv_max = .{ 1, 1 },
        .bearing_x = 0,
        .bearing_y = 0,
        .advance = 0,
        .width = 1,
        .height = 1,
        .page_index = 0,
    };
    const Key = @FieldType(@TypeOf(tr.atlas.cache).KV, "key");
    const wrapper_key = Key{ .font_ptr = @intFromPtr(wrapper), .glyph_index = 42 };
    const other_key = Key{ .font_ptr = @intFromPtr(proto), .glyph_index = 42 };
    try tr.atlas.cache.put(wrapper_key, region);
    try tr.atlas.cache.put(other_key, region);

    // Take real eviction path: evictStaleFallbackFonts destroys wrapper once over-aged.
    tr.current_frame = 100_000;
    tr.evictStaleFallbackFonts();
    try std.testing.expectEqual(@as(u32, 0), tr.fallback_font_cache.count());
    try std.testing.expect(tr.atlas.cache.get(wrapper_key) == null);
    try std.testing.expect(tr.atlas.cache.get(other_key) != null);
}

test "CoreText 桥：开头 UTF-8 BOM 不打乱 cluster 映射与 caret stops" {
    // SKIP-REASON: real CoreText bridge (initWithBytes eats BOM is Foundation)
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fs = try text_module.FontSystem.init(allocator, @import("std").testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 14 });
    defer font.deinit();
    const sample = "\u{FEFF}ab"; // EF BB BF 61 62

    var shaper = try TextShaper.init(allocator);
    defer shaper.deinit();
    const shaped = try shaper.shapeWithOptions(sample, font, false);
    defer {
        TextRenderer.releaseGlyphFallbackFontRefs(shaped);
        allocator.free(shaped);
    }
    // 'a' at byte 3, 'b' at byte 4 (BOM itself may or may not have glyph).
    try std.testing.expect(shaped.len >= 2);
    try std.testing.expectEqual(@as(u32, 3), shaped[shaped.len - 2].cluster);
    try std.testing.expectEqual(@as(u32, 4), shaped[shaped.len - 1].cluster);
    for (shaped) |g| try std.testing.expect(g.cluster < sample.len);

    const boundaries = [_]u32{ 0, 3, 4, 5 };
    var stops: [boundaries.len]text_module.LineCaretStop = undefined;
    _ = try font.lineCaretStops(sample, &boundaries, &stops);
    try std.testing.expectEqual(@as(u32, 3), stops[1].byte_offset);
    // 'a' and 'b' each have positive width: caret advances monotonic.
    try std.testing.expect(stops[2].primary_x > stops[1].primary_x);
    try std.testing.expect(stops[3].primary_x > stops[2].primary_x);
}

test "subpixel glyph placement counts the pen fraction once" {
    // A glyph rasterized into bin b has its origin at subpixelOffset(b) inside the
    // bitmap, whose left edge sits at bearing from the integer origin. A pen on the pixel
    // grid uses the unshifted (hinted) raster.
    const bearing_px: f32 = -1;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const pen_px = 100.0 + @as(f32, @floatFromInt(i)) / 64.0;
        const pen = atlas_mod.subpixelPen(pen_px);
        const left = TextRenderer.subpixelGlyphLeftPx(pen, bearing_px);
        try std.testing.expectEqual(@floor(left), left);
        const drawn_origin = left - bearing_px + atlas_mod.subpixelOffset(pen.bin);
        try std.testing.expect(@abs(drawn_origin - pen_px) <= 0.5 / @as(f32, @floatFromInt(atlas_mod.SUBPIXEL_BINS)) + 1e-4);
    }
    // On the grid (and within 1/8 px of it, either side) the raster is unshifted.
    for ([_]f32{ 100.0, 100.1, 99.9 }) |pen_px| {
        const pen = atlas_mod.subpixelPen(pen_px);
        try std.testing.expectEqual(@as(u4, 0), pen.bin);
        try std.testing.expectEqual(@as(f32, 100), pen.pixel);
    }
    try std.testing.expectEqual(@as(f32, 0), atlas_mod.subpixelOffset(0));
}

test "frame width cache owns text, rejects collisions and clears results" {
    var cache: WidthCache = .{};
    defer cache.deinit(std.testing.allocator);
    const key: WidthCache.Key = .{ .hash = 1, .font = 2, .size = 3, .physical_size = 4, .scale = 5, .advance = 6, .italic = false };
    var text = [_]u8{ 'a', 'b' };
    cache.put(std.testing.allocator, key, &text, 12.5);
    text[0] = 'x';
    try std.testing.expectEqual(@as(?f32, 12.5), cache.get(key, "ab"));
    try std.testing.expectEqual(@as(?f32, null), cache.get(key, &text));
    cache.put(std.testing.allocator, key, &text, 13);
    try std.testing.expectEqual(@as(?f32, null), cache.get(key, "ab"));
    try std.testing.expectEqual(@as(usize, 2), cache.bytes);
    cache.clear(std.testing.allocator);
    try std.testing.expectEqual(@as(?f32, null), cache.get(key, &text));
    const oversized = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024 + 1);
    defer std.testing.allocator.free(oversized);
    cache.put(std.testing.allocator, key, oversized, 99);
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
}

test "segmentText: WTF8 pairs and joined emoji keep original storage spans" {
    const pair = "\xed\xa0\xbd\xed\xb8\x80";
    var segments: [MAX_SEGMENTS]Segment = undefined;
    for ([_][]const u8{ pair, pair ++ "\u{200d}" ++ pair, pair ++ "\u{fe0f}" }) |emoji| {
        try std.testing.expectEqual(@as(u32, 1), segmentText(emoji, &segments));
        try std.testing.expectEqual(@as(u32, 0), segments[0].start);
        try std.testing.expectEqual(@as(u32, @intCast(emoji.len)), segments[0].end);
    }
    const mixed = "A" ++ pair ++ "Z";
    try std.testing.expectEqual(@as(u32, 3), segmentText(mixed, &segments));
    try std.testing.expectEqual(@as(u32, 1), segments[1].start);
    try std.testing.expectEqual(@as(u32, 7), segments[1].end);
    try std.testing.expectEqual(@as(u32, 3), segmentText("A\xed\xa0\x80Z", &segments));
    try std.testing.expectEqual(@as(u32, 4), segments[1].end);
}

fn checkShortSegmentAdoptionOom(allocator: std.mem.Allocator) !void {
    var tr: TextRenderer = undefined;
    tr.allocator = allocator;
    tr.segment_cache = std.AutoHashMap(SegmentCacheKey, SegmentCacheEntry).init(allocator);
    tr.current_frame = 1;
    defer {
        var it = tr.segment_cache.valueIterator();
        while (it.next()) |entry| TextRenderer.releaseSegmentEntry(allocator, entry.*);
        tr.segment_cache.deinit();
    }
    const glyphs = try allocator.alloc(text_module.ShapedGlyph, 3);
    var adopted = false;
    defer if (!adopted) allocator.free(glyphs);
    @memset(glyphs, .{ .glyph_index = 1, .cluster = 0, .x_advance = 4, .y_advance = 0, .x_offset = 0, .y_offset = 0 });
    const key = SegmentCacheKey{ .content_hash = 1, .font_ptr = 0, .flags = 0 };
    adopted = tr.adoptShortSegment(key, glyphs);
    if (!adopted) return error.OutOfMemory;
    try std.testing.expectEqual(@intFromPtr(glyphs.ptr), @intFromPtr(tr.segment_cache.get(key).?.glyphs.ptr));
}

test "short segment cache adoption exhaustively rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkShortSegmentAdoptionOom, .{});
}

test "short segment cache retains exact payload and frees stale and full entries" {
    const allocator = std.testing.allocator;
    var tr: TextRenderer = undefined;
    tr.allocator = allocator;
    tr.segment_cache = std.AutoHashMap(SegmentCacheKey, SegmentCacheEntry).init(allocator);
    tr.current_frame = 1;
    defer {
        var it = tr.segment_cache.valueIterator();
        while (it.next()) |entry| TextRenderer.releaseSegmentEntry(allocator, entry.*);
        tr.segment_cache.deinit();
    }
    var first: ?[*]text_module.ShapedGlyph = null;
    for (0..SEGMENT_CACHE_MAX + 1) |i| {
        const glyphs = try allocator.alloc(text_module.ShapedGlyph, 2);
        @memset(glyphs, .{ .glyph_index = 1, .cluster = 0, .x_advance = 4, .y_advance = 0, .x_offset = 0, .y_offset = 0 });
        if (!tr.adoptShortSegment(.{ .content_hash = i, .font_ptr = 0, .flags = 0 }, glyphs)) {
            allocator.free(glyphs);
            return error.OutOfMemory;
        }
        if (i == 0) first = glyphs.ptr;
        if (i == 200) try std.testing.expectEqual(@intFromPtr(first.?), @intFromPtr(tr.segment_cache.get(.{ .content_hash = 0, .font_ptr = 0, .flags = 0 }).?.glyphs.ptr));
    }
    try std.testing.expect(tr.segment_cache.count() < SEGMENT_CACHE_MAX);
    try std.testing.expect(@sizeOf(SegmentCacheEntry) < 64);
    tr.current_frame = 2000;
    const count = tr.segment_cache.count();
    tr.evictStaleSegments();
    try std.testing.expectEqual(count - 128, tr.segment_cache.count());
}

test "glyph metadata preserves Metal and legacy backend wire contracts" {
    const t = std.testing;
    try t.expectEqual(@as(usize, if (gpu.backend_kind == .metal) 64 else 80), @sizeOf(GlyphInstance));
    try t.expectEqual(@as(usize, if (gpu.backend_kind == .metal) 60 else 68), @offsetOf(GlyphInstance, "metadata"));
    const Meta = @FieldType(GlyphInstance, "metadata");
    const default = GlyphInstance{ .position = .{ 0, 0 }, .size = .{ 1, 1 }, .uv_rect = @FieldType(GlyphInstance, "uv_rect").init(.{ 0, 0, 1, 1 }), .color = .{ 1, 1, 1, 1 } };
    try t.expectEqual(@as(u8, 0), default.metadata.pageIndex());
    try t.expectEqual(@as(u2, 0), default.metadata.colorMode());
    try t.expect(default.metadata.snaps());
    if (comptime gpu.backend_kind != .metal) {
        try t.expectEqual(@as(usize, 0), @offsetOf(Meta, "page_index"));
        try t.expectEqual(@as(usize, 4), @offsetOf(Meta, "is_color"));
        try t.expectEqual(@as(usize, 8), @offsetOf(Meta, "shader_snap"));
    }
    for (0..256) |page| for (0..3) |mode| for ([_]bool{ false, true }) |snap| {
        const m = Meta.init(@intCast(page), @intCast(mode), snap);
        try t.expectEqual(@as(u8, @intCast(page)), m.pageIndex());
        try t.expectEqual(@as(u2, @intCast(mode)), m.colorMode());
        try t.expectEqual(snap, m.snaps());
        if (comptime gpu.backend_kind == .metal) try t.expectEqual(@as(u32, @intCast(page)) | (@as(u32, @intCast(mode)) << 8) | (@as(u32, @intFromBool(snap)) << 10), m.flags) else {
            try t.expectEqual(@as(f32, @floatFromInt(page)), m.page_index);
            try t.expectEqual(@as(f32, @floatFromInt(mode)), m.is_color);
            try t.expectEqual(@as(f32, if (snap) 1 else 0), m.shader_snap);
        }
    };
}

test "glyph UV wire round trips every 4096 atlas texel boundary exactly" {
    const UV = @FieldType(GlyphInstance, "uv_rect");
    try std.testing.expectEqual(@as(usize, if (gpu.backend_kind == .metal) 8 else 16), @sizeOf(UV));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(GlyphInstance, "uv_rect"));
    try std.testing.expectEqual(@as(usize, if (gpu.backend_kind == .metal) 24 else 32), @offsetOf(GlyphInstance, "color"));
    try std.testing.expectEqual(@as(usize, if (gpu.backend_kind == .metal) 40 else 48), @offsetOf(GlyphInstance, "rect_clip"));
    try std.testing.expectEqual(@as(usize, if (gpu.backend_kind == .metal) 56 else 64), @offsetOf(GlyphInstance, "skew_x"));
    for (0..4097) |i| {
        const expected: [4]f32 = .{ @as(f32, @floatFromInt(i)) / 4096, @as(f32, @floatFromInt(4096 - i)) / 4096, @as(f32, @floatFromInt((i * 17) % 4097)) / 4096, 1 };
        const uv = UV.init(expected);
        const decoded = uv.normalized();
        for (expected, decoded) |x, y| try std.testing.expectEqual(@as(u32, @bitCast(x)), @as(u32, @bitCast(y)));
        if (comptime gpu.backend_kind == .metal) {
            const bytes = std.mem.asBytes(&uv);
            for (0..4) |j| try std.testing.expectEqual(@as(u16, @intFromFloat(expected[j] * 4096)), std.mem.readInt(u16, bytes[j * 2 ..][0..2], .little));
        } else try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&uv));
    }
    if (comptime gpu.backend_kind != .metal) {
        const arbitrary: [4]f32 = .{ 0.1, 0.2, 0.7, 0.9 };
        const uv = UV.init(arbitrary);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&arbitrary), std.mem.asBytes(&uv));
    }
}

test "2048 atlas physical boundaries preserve fixed 4096 UV wire exactly" {
    for (0..2049) |i| {
        const u: f32 = @as(f32, @floatFromInt(i)) / 2048;
        const encoded_uv = MetalGlyphUV.init(.{ u, 0, u, 1 });
        try std.testing.expectEqual(@as(u16, @intCast(i * 2)), encoded_uv.texels[0]);
        try std.testing.expectEqual(u, encoded_uv.normalized()[0]);
    }
}

test "idle trim keeps only the segments the latest frame drew" {
    const allocator = std.testing.allocator;
    var tr: TextRenderer = undefined;
    tr.allocator = allocator;
    tr.segment_cache = std.AutoHashMap(SegmentCacheKey, SegmentCacheEntry).init(allocator);
    tr.long_segment_cache = .{};
    defer {
        var it = tr.segment_cache.valueIterator();
        while (it.next()) |entry| TextRenderer.releaseSegmentEntry(allocator, entry.*);
        tr.segment_cache.deinit();
        tr.long_segment_cache.deinit(allocator);
    }
    const shaped = struct {
        fn make(a: std.mem.Allocator) ![]text_module.ShapedGlyph {
            const glyphs = try a.alloc(text_module.ShapedGlyph, 2);
            @memset(glyphs, .{ .glyph_index = 1, .cluster = 0, .x_advance = 4, .y_advance = 0, .x_offset = 0, .y_offset = 0 });
            return glyphs;
        }
    };
    // Shaped long ago (scrolled past), and on the latest frame (on screen).
    tr.current_frame = 1;
    try std.testing.expect(tr.adoptShortSegment(.{ .content_hash = 1, .font_ptr = 0, .flags = 0 }, try shaped.make(allocator)));
    try std.testing.expect(tr.long_segment_cache.adopt(allocator, .{ .content_hash = 3, .font_ptr = 0, .flags = 0 }, "old long line", try shaped.make(allocator), 1));
    tr.current_frame = 40;
    try std.testing.expect(tr.adoptShortSegment(.{ .content_hash = 2, .font_ptr = 0, .flags = 0 }, try shaped.make(allocator)));
    try std.testing.expect(tr.long_segment_cache.adopt(allocator, .{ .content_hash = 4, .font_ptr = 0, .flags = 0 }, "visible long line", try shaped.make(allocator), 40));
    tr.trimIdleCaches();
    try std.testing.expect(tr.segment_cache.get(.{ .content_hash = 1, .font_ptr = 0, .flags = 0 }) == null);
    try std.testing.expect(tr.segment_cache.get(.{ .content_hash = 2, .font_ptr = 0, .flags = 0 }) != null);
    try std.testing.expectEqual(@as(u32, 1), tr.long_segment_cache.entries.count());
    try std.testing.expect(tr.long_segment_cache.get(.{ .content_hash = 4, .font_ptr = 0, .flags = 0 }, "visible long line", 40) != null);
}
