// Shared C API imports for FreeType and HarfBuzz
// This ensures all modules use the same C types

pub const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});
