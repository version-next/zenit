//! command_encoder/pixel_domain.zig，逻辑像素 -> 物理像素域的安全转换
//!
//! 2026-08-05 随 backdrop_capture.zig 同批析出。这三个原语此前直接住在
//! command_encoder.zig，而 backdrop 采样区域解析（backdrop_capture.zig）也要
//! 用同一份 2^24 钳制，两个消费方（encoder 的 viewport/scissor 路径与
//! backdrop 采样）共享同一个语义，不能各留一份拷贝。于是搬进这个零依赖的
//! 小模块，母文件和 backdrop_capture 都**从这里** import：析出模块不反向
//! import 母文件，否则母文件里的同名 decl 会变成 ambiguous reference。
//!
//! 为什么上限是 2^24：f32 在 2^24 之内才能逐整数精确表示，再往上相邻整数
//! 开始被吞，@intFromFloat 的结果不再可预测。所有要变成纹理坐标 / scissor
//! / viewport 尺寸的量都必须先过这里。

const std = @import("std");

/// 物理像素坐标的安全上限（2^24 = 16_777_216）。
pub const max_safe_pixel_coordinate: f32 = 16_777_216;

/// 浮点坐标 -> u32：负值/零折成 0；NaN/Inf/超过安全上限返回 null。
///
/// 用于 src/dst 像素矩形。调用方拿到 null 应放弃本次捕获/裁剪，绝不能把
/// 越界值截断后继续用，截断会把采样窗口整体挪到别处。
pub fn finitePixelCoordinate(value: f32) ?u32 {
    if (!std.math.isFinite(value)) return null;
    if (value <= 0) return 0;
    if (value > max_safe_pixel_coordinate) return null;
    return @intFromFloat(value);
}

/// 逻辑尺寸 × scale 的物理像素 extent：ceil 取整、非法输入归零、
/// 结果钳到 max_safe_pixel_coordinate（viewport/scissor 宽高用）。
pub fn physicalPixelExtent(logical: f32, scale: f32) u32 {
    if (!std.math.isFinite(logical) or !std.math.isFinite(scale) or logical <= 0 or scale <= 0) return 0;
    const pixels = @ceil(logical * scale);
    if (!std.math.isFinite(pixels) or pixels <= 0) return 0;
    return @intFromFloat(@min(pixels, max_safe_pixel_coordinate));
}

// ── 测试 ───────────────────────────────────────────────────────────────
// 这两个原语在母文件内联期间没有直接覆盖（只被 backdrop region 的端到端
// 测试间接经过）。钳制边界一旦松动：viewport 会拿到越界尺寸，
// backdrop 采样窗口会整体挪位，都在这里钉住。

test "finitePixelCoordinate: 负值/零折成 0，超安全上限返回 null" {
    try std.testing.expectEqual(@as(?u32, 0), finitePixelCoordinate(-1.5));
    try std.testing.expectEqual(@as(?u32, 0), finitePixelCoordinate(0));
    try std.testing.expectEqual(@as(?u32, 7), finitePixelCoordinate(7.9));
    // 注意不能用 max+1 做越界样本：f32 在 2^24 之上间距已是 2，
    // 16_777_216 + 1 会被舍回 16_777_216 本身（仍然合法）。用 2^25。
    try std.testing.expectEqual(@as(?u32, null), finitePixelCoordinate(33_554_432));
    try std.testing.expectEqual(@as(?u32, null), finitePixelCoordinate(std.math.nan(f32)));
    try std.testing.expectEqual(@as(?u32, null), finitePixelCoordinate(std.math.inf(f32)));
    // 恰好等于上限：f32 在 2^24 内可精确表示，仍合法。
    const at_limit = finitePixelCoordinate(max_safe_pixel_coordinate);
    try std.testing.expectEqual(@as(?u32, 16_777_216), at_limit);
}

test "physicalPixelExtent: ceil 取整且钳到安全上限，非法输入归零" {
    try std.testing.expectEqual(@as(u32, 1), physicalPixelExtent(0.1, 1));
    try std.testing.expectEqual(@as(u32, 2), physicalPixelExtent(1.0, 2)); // 1.0*2=2
    try std.testing.expectEqual(@as(u32, 0), physicalPixelExtent(-5, 2));
    try std.testing.expectEqual(@as(u32, 0), physicalPixelExtent(10, 0));
    try std.testing.expectEqual(@as(u32, 0), physicalPixelExtent(std.math.nan(f32), 1));
    // 巨大逻辑尺寸 -> ceil 后钳到 16_777_216 而不是溢出/崩溃。
    try std.testing.expectEqual(@as(u32, 16_777_216), physicalPixelExtent(1e9, 1e9));
}
