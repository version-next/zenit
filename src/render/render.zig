const std = @import("std");
pub const PaintFingerprint = @import("command_encoder/paint_fingerprint.zig");
pub const visual_quality = @import("visual_quality.zig");
pub const shader_sources = @import("shader_sources.zig");
pub const tab_lens_field = @import("tab_lens_field.zig");
/// Glass shader uniform ABI (backdrop_blur.zig), for backend contract direct use not hand-copied
/// layout.
pub const GlassUniforms = @import("backdrop_blur.zig").GlassUniforms;
/// Per-frame glass cost counters (read and reset by the app renderer).
pub const backdrop_blur = @import("backdrop_blur.zig");
pub const corner_radii = @import("zenit_corner_radii");
pub const offscreen_texture = @import("offscreen_texture.zig");
pub const glass_reuse = @import("glass_reuse.zig");
pub const opacity_layer = @import("opacity_layer.zig");
pub const cpu_flat = @import("cpu_flat.zig");
pub const text_ink = @import("text_ink.zig");
pub const recording_submission = @import("recording_submission.zig");

// Text rendering (from text abstraction layer)
const text = @import("text");
pub const FontManager = text.FontSystem;
pub const Font = text.Font;
pub const TextShaper = text.TextShaper;
pub const GlyphBitmap = text.GlyphBitmap;
pub const ShapedGlyph = text.ShapedGlyph;

// GPU glyph atlas and text renderer (Metal-based)
pub const GlyphAtlas = @import("glyph_atlas.zig").GlyphAtlas;
const text_renderer = @import("text_renderer.zig");
pub const TextRenderer = text_renderer.TextRenderer;
pub const Color = text_renderer.Color;

// SDF renderer (primary, real SDF shadow/hollow stroke).
const sdf_renderer = @import("sdf_renderer.zig");
pub const SdfRenderer = sdf_renderer.SdfRenderer;
pub const SDFInstance = sdf_renderer.SDFInstance;

// Image renderer (texture image rendering).
const image_renderer = @import("image_renderer.zig");
pub const ImageRenderer = image_renderer.ImageRenderer;
pub const ImageTextureStore = image_renderer.ImageTextureStore;
pub const ImageInstance = image_renderer.ImageInstance;
pub const TextureId = image_renderer.TextureId;

// Icon renderer (UI icon mask pipeline)
const icon_renderer = @import("icon_renderer.zig");
pub const IconRenderer = icon_renderer.IconRenderer;
/// Icon pipeline module-level cumulative GPU draw count (FrameStats takes per-frame delta).
pub fn iconDrawCallsTotal() u64 {
    return icon_renderer.icon_draw_calls;
}
pub fn sdfDrawCallsTotal() u64 {
    return sdf_renderer.sdf_draw_calls;
}
pub fn textDrawCallsTotal() u64 {
    return text_renderer.text_draw_calls;
}
/// Text uniform slot overflow cumulative count. Healthy state always 0; sustained growth = clip
/// switches per frame far exceed expectation (clip flush storm), investigate clip chain not
/// increase limit.
pub fn textUniformOverflowTotal() u64 {
    return text_renderer.text_uniform_overflow_total;
}
/// Image pipeline module-level cumulative count (FrameStats takes per-frame delta).
pub fn imageDrawCallsTotal() u64 {
    return image_renderer.image_draw_calls;
}
pub fn imageInstancesTotal() u64 {
    return image_renderer.image_instances_drawn;
}
pub fn imageTextureBindsTotal() u64 {
    return image_renderer.image_texture_binds;
}
pub const TextureMemoryStats = image_renderer.TextureMemoryStats;
pub const IconInstance = icon_renderer.IconInstance;

// DisplayItem encoder (UI -> GPU unified encoder).
const command_encoder_mod = @import("command_encoder.zig");
pub const RenderCommandEncoder = command_encoder_mod.RenderCommandEncoder;
pub const FrameDamage = @import("frame_damage.zig").FrameDamage;
pub const frame_damage = @import("frame_damage.zig");
pub const RetainedPlan = @import("command_encoder/retained_plan.zig").Plan;
pub const OffscreenTexturePool = @import("offscreen_texture.zig").OffscreenTexturePool;
pub const OffscreenMaintenanceRetry = @import("offscreen_maintenance_retry.zig").MaintenanceRetry;
/// Cross-frame persistent path/blur/glass GPU resource cache (held by AppRenderer).
pub const PersistentGpuCache = @import("command_encoder.zig").PersistentGpuCache;
pub const FontSelector = command_encoder_mod.FontSelector;
pub const TextFontProps = command_encoder_mod.TextFontProps;
/// CSS font-family style explicit font fallback stack: app-declared ordered family stack + per-OS
/// system fallback, before shaping check codepoint in stack to select font explicitly, CoreText
/// cascade only final fallback.
pub const font_fallback_stack = @import("font_fallback_stack.zig");
pub const FontFallbackStack = font_fallback_stack.FontFallbackStack;
/// Process-level font family registry (id -> family name + face cache). For family axis, see
/// font_registry.zig file header on 'why id not string'.
pub const font_registry = @import("font_registry.zig");
pub const FontRegistry = font_registry.FontRegistry;
pub const FamilyId = font_registry.FamilyId;
pub const colorToFloat4 = command_encoder_mod.colorToFloat4;

// Path rendering (vector path fill/stroke).
const path_tessellator_mod = @import("path_tessellator.zig");
pub const PathTessellator = path_tessellator_mod.PathTessellator;
pub const TPoint = path_tessellator_mod.TPoint;
pub const Contour = path_tessellator_mod.Contour;

const path_renderer_mod = @import("path_renderer.zig");
pub const PathRenderer = path_renderer_mod.PathRenderer;

// command_encoder tests extracted to separate file (occupied 679 lines in original). Must
// explicitly import to be collected by test runner, refAllDecls only recurses modules referenced in
// this file, missing this line silently loses 16 tests.
test {
    _ = @import("recording_submission.zig");
    _ = @import("command_encoder_test.zig");
    _ = @import("zenit_corner_radii");
    _ = @import("texture_upload_validation_test.zig");
    _ = @import("frame_damage.zig");
    _ = @import("slot_buffer.zig");
    _ = @import("tab_lens_field.zig");
    // RTL shaping contract test: must run real CoreText (this test target linked bridge).
    _ = @import("rtl_shaping_test.zig");
    // Same: font_registry tests must also be explicitly imported, pub const reference will not
    // cause its tests to be collected.
    _ = @import("font_registry.zig");
    // Explicit font fallback stack: pure logic test + real macOS font coverage test.
    _ = @import("font_fallback_stack.zig");
    _ = @import("cpu_flat.zig");
    std.testing.refAllDecls(@This());
}

pub const drawable_extent_contract = @import("drawable_extent_contract.zig");

pub const text_render_policy = @import("text_render_policy.zig");
