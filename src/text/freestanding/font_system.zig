//! Freestanding layout uses injected text measurement hooks. Native fonts,
//! shaping and rasterization are unavailable; attempted use fails explicitly.
const std = @import("std");
const types = @import("../types.zig");
pub const ShapeStats = struct { calls: u64 = 0, total_us: u64 = 0, frame_calls: u32 = 0, frame_us: u64 = 0 };
pub fn takeShapeStats() ShapeStats {
    @panic("freestanding shaping is unsupported");
}
pub fn releaseFallbackFontRef(_: *anyopaque) void {
    @panic("freestanding font references are unsupported");
}
pub fn retainFallbackFontRef(_: *anyopaque) void {
    @panic("freestanding font references are unsupported");
}
pub fn fallbackFontRefSize(_: *anyopaque) f32 {
    @panic("freestanding font references are unsupported");
}
pub fn fallbackFontRefIdentityHash(_: *anyopaque) u64 {
    @panic("freestanding font references are unsupported");
}
pub fn fallbackFontRefDebugName(_: std.mem.Allocator, _: *anyopaque) ?[]u8 {
    @panic("freestanding font references are unsupported");
}
pub const FontSystem = struct {
    pub fn init(_: std.mem.Allocator, _: std.Io) !FontSystem {
        return error.Unsupported;
    }
    pub fn deinit(_: *FontSystem) void {
        @panic("freestanding font systems are unsupported");
    }
    pub fn findFont(_: *FontSystem, _: types.FontDescriptor) !*Font {
        return error.Unsupported;
    }
};
pub const FontManager = FontSystem;
pub const Font = struct {
    pub fn deinit(_: *Font) void {
        @panic("freestanding fonts are unsupported");
    }
    pub fn pixelSize(_: *const Font) f32 {
        @panic("freestanding fonts are unsupported");
    }
};
pub const TextShaper = struct {
    pub fn init(_: std.mem.Allocator) !TextShaper {
        return error.Unsupported;
    }
    pub fn deinit(_: *TextShaper) void {
        @panic("freestanding shaping is unsupported");
    }
    pub fn shapeWithOptions(_: *TextShaper, _: []const u8, _: *Font, _: bool) ![]types.ShapedGlyph {
        return error.Unsupported;
    }
    pub fn shape(_: *TextShaper, _: []const u8, _: *Font) ![]types.ShapedGlyph {
        return error.Unsupported;
    }
};
