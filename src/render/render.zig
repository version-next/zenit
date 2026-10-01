const std = @import("std");

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

// SDF renderer (primary，真正 SDF 阴影/空心边框)
const sdf_renderer = @import("sdf_renderer.zig");
pub const SdfRenderer = sdf_renderer.SdfRenderer;
pub const SDFInstance = sdf_renderer.SDFInstance;

// Image renderer (纹理图片渲染)
const image_renderer = @import("image_renderer.zig");
pub const ImageRenderer = image_renderer.ImageRenderer;
pub const ImageTextureStore = image_renderer.ImageTextureStore;
pub const ImageInstance = image_renderer.ImageInstance;
pub const TextureId = image_renderer.TextureId;

// Icon renderer (UI icon mask pipeline)
const icon_renderer = @import("icon_renderer.zig");
pub const IconRenderer = icon_renderer.IconRenderer;
/// icon 管线模块级累计 GPU draw 数（FrameStats 取每帧增量用）
pub fn iconDrawCallsTotal() u64 {
    return icon_renderer.icon_draw_calls;
}
pub fn sdfDrawCallsTotal() u64 {
    return sdf_renderer.sdf_draw_calls;
}
pub fn textDrawCallsTotal() u64 {
    return text_renderer.text_draw_calls;
}
/// text uniform 槽位溢出累计次数。健康态恒为 0；持续增长 = 一帧内 clip
/// 切换次数远超预期（clip flush 风暴），需要去查 clip 链而不是调大上限。
pub fn textUniformOverflowTotal() u64 {
    return text_renderer.text_uniform_overflow_total;
}
/// image 管线模块级累计计数（FrameStats 取每帧增量用）
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

// DisplayItem encoder (UI -> GPU 统一编码器)
const command_encoder_mod = @import("command_encoder.zig");
pub const RenderCommandEncoder = command_encoder_mod.RenderCommandEncoder;
pub const OffscreenTexturePool = @import("offscreen_texture.zig").OffscreenTexturePool;
/// 跨帧持久的 path/blur/glass GPU 资源缓存（由 AppRenderer 持有）。
pub const PersistentGpuCache = @import("command_encoder.zig").PersistentGpuCache;
pub const FontSelector = command_encoder_mod.FontSelector;
pub const TextFontProps = command_encoder_mod.TextFontProps;
/// CSS font-family 式的显式字体回退栈：应用声明有序族栈 + per-OS 系统兜底，
/// shaping 前按码点在栈内显式选字体，CoreText 级联只作最后兜底。
pub const font_fallback_stack = @import("font_fallback_stack.zig");
pub const FontFallbackStack = font_fallback_stack.FontFallbackStack;
/// 进程级字体族注册表(id ↔ 族名 + face 缓存)。给 family 轴用,
/// 见 font_registry.zig 文件头对「为什么是 id 不是字符串」的说明。
pub const font_registry = @import("font_registry.zig");
pub const FontRegistry = font_registry.FontRegistry;
pub const FamilyId = font_registry.FamilyId;
pub const colorToFloat4 = command_encoder_mod.colorToFloat4;

// Path rendering (矢量路径 fill/stroke)
const path_tessellator_mod = @import("path_tessellator.zig");
pub const PathTessellator = path_tessellator_mod.PathTessellator;
pub const TPoint = path_tessellator_mod.TPoint;
pub const Contour = path_tessellator_mod.Contour;

const path_renderer_mod = @import("path_renderer.zig");
pub const PathRenderer = path_renderer_mod.PathRenderer;

// command_encoder 的单测已析出到独立文件（原文件里占 679 行）。
// 必须显式 import 才会被 test runner 收集，refAllDecls 只递归到
// 本文件引用过的模块，漏了这行等于静默失去 16 个测试。
test {
    _ = @import("command_encoder_test.zig");
    // RTL shaping 合同测试：必须跑真实 CoreText（本 test target 链了桥）。
    _ = @import("rtl_shaping_test.zig");
    // 同上：font_registry 的测试也必须显式 import，
    // pub const 引用**不会**让它的 test 被收集。
    _ = @import("font_registry.zig");
    // 显式字体回退栈：纯逻辑测试 + macOS 真实字体覆盖测试。
    _ = @import("font_fallback_stack.zig");
    std.testing.refAllDecls(@This());
}
