const builtin = @import("builtin");

// Platform-agnostic types
pub const GlyphBitmap = @import("types.zig").GlyphBitmap;
pub const ShapedGlyph = @import("types.zig").ShapedGlyph;
pub const LineCaretStop = @import("types.zig").LineCaretStop;
pub const LineMetrics = @import("types.zig").LineMetrics;
pub const FontDescriptor = @import("types.zig").FontDescriptor;
pub const FontWeight = @import("types.zig").FontWeight;
pub const FontStyle = @import("types.zig").FontStyle;

// 系统字体目录（字体选择器的数据层）。只做枚举与元数据，
// 不负责把字体接到渲染管线，family 轴在管线里还不存在。
pub const font_catalog = @import("font_catalog.zig");
pub const FontCatalog = font_catalog.FontCatalog;

// Backend selection: CoreText on macOS, FreeType elsewhere
pub const Backend = if (builtin.target.os.tag == .macos)
    @import("coretext/font_system.zig")
else
    @import("freetype/font_system.zig");

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
