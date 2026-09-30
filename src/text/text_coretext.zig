// Text module variant that uses CoreText backend
// Used for testing CoreText independently

// Platform-agnostic types
pub const GlyphBitmap = @import("types.zig").GlyphBitmap;
pub const ShapedGlyph = @import("types.zig").ShapedGlyph;
pub const FontDescriptor = @import("types.zig").FontDescriptor;
pub const FontWeight = @import("types.zig").FontWeight;
pub const FontStyle = @import("types.zig").FontStyle;

// CoreText backend
pub const Backend = @import("coretext/font_system.zig");

// Re-export backend types
pub const FontSystem = Backend.FontSystem;
pub const FontManager = Backend.FontManager;
pub const Font = Backend.Font;
pub const TextShaper = Backend.TextShaper;
pub const releaseFallbackFontRef = Backend.releaseFallbackFontRef;
pub const retainFallbackFontRef = Backend.retainFallbackFontRef;
pub const fallbackFontRefSize = Backend.fallbackFontRefSize;
