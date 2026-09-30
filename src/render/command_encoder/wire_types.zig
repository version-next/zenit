//! Conversion from UI display-list wire values to renderer enums.

const sdf = @import("../sdf_renderer.zig");

pub fn gradientDirection(direction: u8) sdf.GradientDir {
    return switch (direction) {
        0 => .horizontal,
        1 => .vertical,
        2 => .diagonal,
        3 => .radial,
        4 => .conic,
        else => .vertical,
    };
}

/// text_run.raster_policy 过线值（与 ui 侧 text_blob.TextRasterPolicy 对应）。
pub const TextRasterMode = enum(u8) {
    /// 静态文本：nearest + subpixel 变体 + CPU/shader 双侧像素吸附（幂等组合）
    static_crisp = 0,
    /// 动画中直绘：CPU 与 shader 都保持连续浮点坐标。任一侧 round 都会让
    /// 相邻 glyph 在不同帧跨越取整阈值，产生字距/基线跳动（抖动根因）。
    direct_animated = 1,
    /// 文本已光栅进 retained surface：坐标是稳定 owner-local，吸附安全。
    surface_cached = 2,
};

pub const TextRasterControls = struct {
    /// linear 采样 + 禁 subpixel 变体 + 字体稳定选择 + CPU 不吸附
    force_linear: bool,
    /// vertex shader 是否把 glyph position round 到物理像素
    shader_snap: bool,
};

/// 唯一的 policy → 绘制控制推导点。exhaustive switch：新增模式必须显式决策，
/// 禁止回退成 `policy != 0` 的布尔折叠。
pub fn textRasterControls(policy_byte: u8) TextRasterControls {
    const mode: TextRasterMode = switch (policy_byte) {
        0 => .static_crisp,
        1 => .direct_animated,
        2 => .surface_cached,
        // 未知过线值走最保守的静态路径（不糊、不动）
        else => .static_crisp,
    };
    return switch (mode) {
        .static_crisp => .{ .force_linear = false, .shader_snap = true },
        .direct_animated => .{ .force_linear = true, .shader_snap = false },
        // P0 保持 surface 内现状（linear、CPU 不吸附）；shader 吸附与旧行为一致。
        // P2 计划升级为 surface 内 static_crisp 光栅化。
        .surface_cached => .{ .force_linear = true, .shader_snap = true },
    };
}

pub fn gradientExtendMode(mode: u8) sdf.GradientExtendMode {
    return switch (mode) {
        0 => .pad,
        1 => .repeat,
        2 => .reflect,
        else => .pad,
    };
}
