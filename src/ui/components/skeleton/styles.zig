/// Skeleton，样式层
///
/// 变体外观与 shimmer 插值端点颜色；动画逻辑（tick/正弦插值）在 mod.zig。
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const ConditionalStyle = core.ConditionalStyle;
const mod = @import("mod.zig");

/// SkeletonVariant.style 的实现体（枚举本体是公共 API，留在 mod.zig）
pub fn variantStyle(v: mod.SkeletonVariant, t: *const theme.ThemeTokens) ConditionalStyle {
    return .{
        .base = .{
            .background = Color.lerp(t.color.bg_primary, t.color.bg_tertiary, 0.5),
            .corner_radius = switch (v) {
                .text => 4,
                .circular => 999,
                .rectangular => 8,
            },
        },
    };
}

pub fn skeletonRadius(v: mod.SkeletonVariant, width: f32, t: *const theme.ThemeTokens) f32 {
    return switch (v) {
        .text => 4,
        .circular => width / 2,
        .rectangular => t.radius.md,
    };
}

/// shimmer 基色（静态背景同源）
pub fn skeletonBaseColor(t: *const theme.ThemeTokens) Color {
    return Color.lerp(t.color.fg_disabled, t.color.bg_primary, 0.7);
}

/// shimmer 高亮端点
pub fn skeletonHighlightColor(t: *const theme.ThemeTokens) Color {
    return Color.lerp(t.color.fg_disabled, t.color.bg_primary, 0.85);
}
