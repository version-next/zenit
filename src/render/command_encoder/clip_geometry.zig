//! Clip 几何代数 —— 与 encoder 状态零耦合的纯函数簇。
//!
//! 从 command_encoder.zig 析出（2026-08-05）。这一簇回答的是同一个问题域：
//! **两个 clip 形状等价吗 / 两个矩形的交是什么 / 外部 duck-typed 多边形怎么
//! 归一成 encoder 的定长 ClipPolygon**。全部只吃值、只返回值，不触 self、
//! 不分配、无副作用 —— 与 encoder 的 clip 栈状态（clip_depth /
//! logical_clip_stack / effective_rect_clip_stack）刻意分离：
//! 栈的**推进/回退**留在 encoder（有状态），栈元素之间的**比较与归一**在这里。
//!
//! 等价比较统一用 approxEqAbs(1e-4)：clip 坐标经过 world→local 投影与 DPI
//! 缩放，位精确比较会把"同一个 clip"判成不同，导致每帧无谓重建 clip mask。
//!
//! command_encoder.zig 保留同名 re-export（含 pub 的 intersectClipRects），
//! 公共 API 与既有调用点、单测全部不变。

const std = @import("std");

/// 这几个类型仍由 command_encoder.zig 拥有（是它的公共 API 面），
/// 这里按结构约定接收 —— 传入 comptime 类型参数会让签名比搬运本身更复杂，
/// 故用 anytype + 显式返回类型保持调用点零改动。
pub fn clipPolygonEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a.point_count != b.point_count or a.contour_count != b.contour_count or a.fill_rule != b.fill_rule) return false;
    const max_contours = a.contour_end_points.len;
    const max_points = a.points.len;
    const contour_count = @min(@as(usize, a.contour_count), max_contours);
    for (0..contour_count) |i| {
        if (a.contour_end_points[i] != b.contour_end_points[i]) return false;
    }
    const count = @min(@as(usize, a.point_count), max_points);
    for (0..count) |i| {
        if (!std.math.approxEqAbs(f32, a.points[i][0], b.points[i][0], 0.0001) or
            !std.math.approxEqAbs(f32, a.points[i][1], b.points[i][1], 0.0001))
        {
            return false;
        }
    }
    return true;
}

/// 圆角 clip 状态等价。null == null 视为等价（都表示"无圆角 clip"）。
pub fn roundedClipEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const lhs = a.?;
    const rhs = b.?;
    return std.math.approxEqAbs(f32, lhs.x, rhs.x, 0.0001) and
        std.math.approxEqAbs(f32, lhs.y, rhs.y, 0.0001) and
        std.math.approxEqAbs(f32, lhs.w, rhs.w, 0.0001) and
        std.math.approxEqAbs(f32, lhs.h, rhs.h, 0.0001) and
        std.math.approxEqAbs(f32, lhs.radius, rhs.radius, 0.0001) and
        lhs.shape_kind == rhs.shape_kind and
        clipPolygonEqual(lhs.polygon, rhs.polygon);
}

/// 两个 [x, y, w, h] 矩形求交。不相交时返回零面积矩形（保留左上角，
/// 让调用方的 scissor 设置仍是合法输入而非负宽高）。
pub fn intersectClipRects(a: [4]f32, b: [4]f32) [4]f32 {
    const x1 = @max(a[0], b[0]);
    const y1 = @max(a[1], b[1]);
    const x2 = @min(a[0] + a[2], b[0] + b[2]);
    const y2 = @min(a[1] + a[3], b[1] + b[3]);
    if (x2 <= x1 or y2 <= y1) return .{ x1, y1, 0, 0 };
    return .{ x1, y1, x2 - x1, y2 - y1 };
}

/// duck-typed 外部多边形 → encoder 定长 ClipPolygon。
///
/// `Out` 是 command_encoder.ClipPolygon；`coerceFillRule` 把来源侧的
/// fill_rule 枚举转成 encoder 侧同序枚举。缺字段的来源类型退化为空多边形，
/// 超出定长容量的点/轮廓按上限钳掉（encoder 的 clip 多边形是定长数组）。
pub fn coerceClipPolygon(
    comptime Out: type,
    polygon: anytype,
    comptime coerceFillRule: anytype,
) Out {
    var out = Out.empty();
    if (!@hasField(@TypeOf(polygon), "point_count") or !@hasField(@TypeOf(polygon), "points")) {
        return out;
    }
    const max_points = out.points.len;
    const max_contours = out.contour_end_points.len;
    const count = @min(@as(usize, polygon.point_count), max_points);
    out.point_count = @intCast(count);
    if (@hasField(@TypeOf(polygon), "fill_rule")) {
        out.fill_rule = coerceFillRule(polygon.fill_rule);
    }
    if (@hasField(@TypeOf(polygon), "contour_count") and @hasField(@TypeOf(polygon), "contour_end_points")) {
        const contour_count = @min(@as(usize, polygon.contour_count), max_contours);
        out.contour_count = @intCast(contour_count);
        for (0..contour_count) |i| {
            out.contour_end_points[i] = @min(polygon.contour_end_points[i], out.point_count);
        }
    } else if (count > 0) {
        out.contour_count = 1;
        out.contour_end_points[0] = out.point_count;
    }
    for (0..count) |i| {
        out.points[i] = polygon.points[i];
    }
    return out;
}
