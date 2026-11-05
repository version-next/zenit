const builtin = @import("builtin");

// Platform-agnostic types
pub const GlyphBitmap = @import("types.zig").GlyphBitmap;
pub const ShapedGlyph = @import("types.zig").ShapedGlyph;
pub const LineCaretStop = @import("types.zig").LineCaretStop;
pub const LineMetrics = @import("types.zig").LineMetrics;
pub const FontDescriptor = @import("types.zig").FontDescriptor;
pub const FontWeight = @import("types.zig").FontWeight;
pub const FontStyle = @import("types.zig").FontStyle;

// System font directory (data layer for font picker). Only enumerate and metadata,
// doesn't connect fonts to render pipeline, family axis doesn't exist in pipeline yet.
pub const font_catalog = @import("font_catalog.zig");
pub const FontCatalog = font_catalog.FontCatalog;

// Native font backends, plus an injected-measurement-only freestanding closure.
pub const Backend = switch (builtin.target.os.tag) {
    .macos => @import("coretext/font_system.zig"),
    .freestanding => @import("freestanding/font_system.zig"),
    .windows => @import("windows/font_system.zig"),
    else => @import("freetype/font_system.zig"),
};

// Re-export backend types
pub const FontSystem = Backend.FontSystem;
pub const FontManager = Backend.FontManager;
pub const Font = Backend.Font;
pub const TextShaper = Backend.TextShaper;
pub const takeShapeStats = Backend.takeShapeStats;
pub const releaseFallbackFontRef = Backend.releaseFallbackFontRef;
pub const retainFallbackFontRef = Backend.retainFallbackFontRef;
pub const fallbackFontRefSize = Backend.fallbackFontRefSize;
pub const fallbackFontRefIdentityHash = Backend.fallbackFontRefIdentityHash;
pub const fallbackFontRefDebugName = Backend.fallbackFontRefDebugName;

// Explicit snapshots currently have a native implementation on Windows only.
// Opaque types keep cross-platform hook declarations possible without exposing
// unsupported constructors on other backends.
pub const FontRange = if (@hasDecl(Backend, "FontRange")) Backend.FontRange else opaque {};
pub const FontRanges = if (@hasDecl(Backend, "FontRanges")) Backend.FontRanges else opaque {};
