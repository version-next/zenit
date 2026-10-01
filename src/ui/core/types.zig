const std = @import("std");
const events_mod = @import("../events.zig");
const actions_mod = @import("../actions.zig");
const icon_ir = @import("icon_ir");
pub const theme = @import("../theme.zig");

pub const Event = events_mod.Event;
pub const EventResult = events_mod.EventResult;
pub const KeyCode = events_mod.KeyCode;
pub const Modifiers = events_mod.Modifiers;

/// 二维尺寸
pub const Size = struct {
    width: f32,
    height: f32,

    pub const ZERO = Size{ .width = 0, .height = 0 };

    pub fn init(width: f32, height: f32) Size {
        return .{ .width = width, .height = height };
    }
};

/// 计算后的矩形区域
pub const ComputedRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn init(x: f32, y: f32, w: f32, h: f32) ComputedRect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn contains(self: ComputedRect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }
};

pub const Point = struct {
    x: f32,
    y: f32,
};

/// 2D 仿射变换。**全部字段为 f32（含 tx/ty）**。
///
/// 无限画布类应用注意：在 1e6 量级世界坐标 + 深缩放（>1600%）下，f32 尾数
/// 不足以区分相邻世界坐标（先转 f32 再变换会产生近 1px 量化误差，表现为
/// 对象抖动/粘连）。应用必须在自己的 f64 里先减去视口原点、再把
/// 视口局部坐标转 f32 交给 zenit, f64 中先做减法则误差恒为 0。
pub const Transform2D = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub fn identity() Transform2D {
        return .{};
    }

    pub fn translation(tx: f32, ty: f32) Transform2D {
        return .{ .tx = tx, .ty = ty };
    }

    pub fn scale(sx: f32, sy: f32, origin_x: f32, origin_y: f32) Transform2D {
        return Transform2D.translation(origin_x, origin_y)
            .mul(.{ .a = sx, .d = sy })
            .mul(Transform2D.translation(-origin_x, -origin_y));
    }

    pub fn rotation(rad: f32, origin_x: f32, origin_y: f32) Transform2D {
        const cos_r = @cos(rad);
        const sin_r = @sin(rad);
        return Transform2D.translation(origin_x, origin_y)
            .mul(.{
                .a = cos_r,
                .b = sin_r,
                .c = -sin_r,
                .d = cos_r,
            })
            .mul(Transform2D.translation(-origin_x, -origin_y));
    }

    pub fn fromRectWithOrigin(
        x: f32,
        y: f32,
        _: f32,
        _: f32,
        scale_x: f32,
        scale_y: f32,
        origin_x: f32,
        origin_y: f32,
    ) Transform2D {
        return Transform2D.translation(x, y).mul(
            Transform2D.scale(scale_x, scale_y, origin_x, origin_y),
        );
    }

    pub fn applyPoint(self: Transform2D, x: f32, y: f32) Point {
        return .{
            .x = self.a * x + self.c * y + self.tx,
            .y = self.b * x + self.d * y + self.ty,
        };
    }

    pub fn mul(self: Transform2D, other: Transform2D) Transform2D {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .tx = self.a * other.tx + self.c * other.ty + self.tx,
            .ty = self.b * other.tx + self.d * other.ty + self.ty,
        };
    }

    pub fn transformRectAABB(self: Transform2D, rect: ComputedRect) ComputedRect {
        const top_left = self.applyPoint(rect.x, rect.y);
        const top_right = self.applyPoint(rect.x + rect.w, rect.y);
        const bottom_left = self.applyPoint(rect.x, rect.y + rect.h);
        const bottom_right = self.applyPoint(rect.x + rect.w, rect.y + rect.h);
        const min_x = @min(@min(top_left.x, top_right.x), @min(bottom_left.x, bottom_right.x));
        const min_y = @min(@min(top_left.y, top_right.y), @min(bottom_left.y, bottom_right.y));
        const max_x = @max(@max(top_left.x, top_right.x), @max(bottom_left.x, bottom_right.x));
        const max_y = @max(@max(top_left.y, top_right.y), @max(bottom_left.y, bottom_right.y));
        return ComputedRect.init(min_x, min_y, max_x - min_x, max_y - min_y);
    }

    pub fn transformRect(self: Transform2D, rect: ComputedRect) ComputedRect {
        return self.transformRectAABB(rect);
    }

    pub fn invert(self: Transform2D) Transform2D {
        const det = self.a * self.d - self.b * self.c;
        if (@abs(det) < 0.000001) return .{};
        const inv_det = 1.0 / det;
        return .{
            .a = self.d * inv_det,
            .b = -self.b * inv_det,
            .c = -self.c * inv_det,
            .d = self.a * inv_det,
            .tx = (self.c * self.ty - self.d * self.tx) * inv_det,
            .ty = (self.b * self.tx - self.a * self.ty) * inv_det,
        };
    }

    pub fn isAxisAligned(self: Transform2D) bool {
        const epsilon: f32 = 0.0001;
        return (@abs(self.b) <= epsilon and @abs(self.c) <= epsilon) or
            (@abs(self.a) <= epsilon and @abs(self.d) <= epsilon);
    }

    pub fn isIntegerTranslation(self: Transform2D, epsilon: f32) bool {
        return @abs(self.a - 1.0) <= epsilon and
            @abs(self.d - 1.0) <= epsilon and
            @abs(self.b) <= epsilon and
            @abs(self.c) <= epsilon and
            @abs(self.tx - @round(self.tx)) <= epsilon and
            @abs(self.ty - @round(self.ty)) <= epsilon;
    }

    pub fn extractApproxScale(self: Transform2D) f32 {
        const scale_x = self.extractScaleX();
        const scale_y = self.extractScaleY();
        return @max(scale_x, scale_y);
    }

    pub fn extractScaleX(self: Transform2D) f32 {
        return @sqrt(self.a * self.a + self.c * self.c);
    }

    pub fn extractScaleY(self: Transform2D) f32 {
        return @sqrt(self.b * self.b + self.d * self.d);
    }

    pub fn decompose(self: Transform2D) DecomposedTransform2D {
        var a = self.a;
        var b = self.b;
        var c = self.c;
        var d = self.d;

        var scale_x = @sqrt(a * a + b * b);
        if (scale_x <= 0.000001) {
            scale_x = 0;
        }

        var rotate: f32 = 0;
        var skew_x: f32 = 0;
        var scale_y: f32 = 0;

        if (scale_x > 0.000001) {
            rotate = std.math.atan2(b, a);
            a /= scale_x;
            b /= scale_x;

            skew_x = a * c + b * d;
            c -= a * skew_x;
            d -= b * skew_x;

            scale_y = @sqrt(c * c + d * d);
            if (scale_y > 0.000001) {
                c /= scale_y;
                d /= scale_y;
                skew_x /= scale_y;
            } else {
                scale_y = 0;
                skew_x = 0;
            }

            if (a * d - b * c < 0) {
                scale_y = -scale_y;
            }
        } else {
            scale_y = @sqrt(c * c + d * d);
        }

        return .{
            .translate = .{ self.tx, self.ty },
            .scale = .{ scale_x, scale_y },
            .rotate = rotate,
            .skew_x = skew_x,
        };
    }

    pub fn compose(parts: DecomposedTransform2D) Transform2D {
        return parts.compose();
    }

    pub fn blend(from: Transform2D, to: Transform2D, t: f32) Transform2D {
        return DecomposedTransform2D.blend(from.decompose(), to.decompose(), t).compose();
    }
};

pub const DecomposedTransform2D = struct {
    translate: [2]f32 = .{ 0, 0 },
    scale: [2]f32 = .{ 1, 1 },
    rotate: f32 = 0,
    skew_x: f32 = 0,

    pub fn compose(self: DecomposedTransform2D) Transform2D {
        const cos_r = @cos(self.rotate);
        const sin_r = @sin(self.rotate);
        const sx = self.scale[0];
        const sy = self.scale[1];
        const skew_component = self.skew_x * sy;
        return .{
            .a = cos_r * sx,
            .b = sin_r * sx,
            .c = cos_r * skew_component - sin_r * sy,
            .d = sin_r * skew_component + cos_r * sy,
            .tx = self.translate[0],
            .ty = self.translate[1],
        };
    }

    pub fn blend(from: DecomposedTransform2D, to: DecomposedTransform2D, t: f32) DecomposedTransform2D {
        const clamped_t = std.math.clamp(t, 0.0, 1.0);
        return .{
            .translate = .{
                lerp(from.translate[0], to.translate[0], clamped_t),
                lerp(from.translate[1], to.translate[1], clamped_t),
            },
            .scale = .{
                lerp(from.scale[0], to.scale[0], clamped_t),
                lerp(from.scale[1], to.scale[1], clamped_t),
            },
            .rotate = lerpAngle(from.rotate, to.rotate, clamped_t),
            .skew_x = lerp(from.skew_x, to.skew_x, clamped_t),
        };
    }

    fn lerp(from: f32, to: f32, t: f32) f32 {
        return from + (to - from) * t;
    }

    fn lerpAngle(from: f32, to: f32, t: f32) f32 {
        var delta = std.math.mod(f32, to - from, std.math.tau) catch (to - from);
        if (delta > std.math.pi) delta -= std.math.tau;
        if (delta < -std.math.pi) delta += std.math.tau;
        return from + delta * t;
    }
};

pub const TransformOriginValue = union(enum) {
    px: f32,
    percent: f32,

    pub fn resolve(self: TransformOriginValue, axis_extent: f32) f32 {
        return switch (self) {
            .px => |value| value,
            .percent => |value| axis_extent * value,
        };
    }
};

pub const TransformOrigin = struct {
    x: TransformOriginValue = .{ .percent = 0.5 },
    y: TransformOriginValue = .{ .percent = 0.5 },

    pub fn resolve(self: TransformOrigin, width: f32, height: f32) Point {
        return .{
            .x = self.x.resolve(width),
            .y = self.y.resolve(height),
        };
    }

    pub fn centered() TransformOrigin {
        return .{};
    }

    pub fn topLeft() TransformOrigin {
        return .{
            .x = .{ .percent = 0.0 },
            .y = .{ .percent = 0.0 },
        };
    }
};

/// Padding 值
pub const Padding = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub const ZERO = Padding{};

    pub fn all(value: f32) Padding {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    pub fn symmetric(v: f32, h: f32) Padding {
        return .{ .top = v, .right = h, .bottom = v, .left = h };
    }

    pub fn horizontal(self: Padding) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Padding) f32 {
        return self.top + self.bottom;
    }
};

/// Margin 边值。
/// 与 CSS 一样，默认是长度值；`auto` 通过 auto_mask 按边表达。
/// 这个类型用于声明式样式输入和调试显示；Style 内部仍保持紧凑的数值 margin，
/// auto 标记单独存到 StyleExt，避免把高频布局字段做胖。
pub const Margin = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
    auto_mask: u8 = 0,

    pub const ZERO = Margin{};

    const AUTO_TOP: u8 = 1 << 0;
    const AUTO_RIGHT: u8 = 1 << 1;
    const AUTO_BOTTOM: u8 = 1 << 2;
    const AUTO_LEFT: u8 = 1 << 3;

    pub fn all(value: f32) Margin {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    pub fn symmetric(v: f32, h: f32) Margin {
        return .{ .top = v, .right = h, .bottom = v, .left = h };
    }

    pub fn fromPadding(padding: Padding) Margin {
        return .{
            .top = padding.top,
            .right = padding.right,
            .bottom = padding.bottom,
            .left = padding.left,
        };
    }

    pub fn toPadding(self: Margin) Padding {
        return .{
            .top = self.top,
            .right = self.right,
            .bottom = self.bottom,
            .left = self.left,
        };
    }

    pub fn auto() Margin {
        return .{ .auto_mask = AUTO_TOP | AUTO_RIGHT | AUTO_BOTTOM | AUTO_LEFT };
    }

    pub fn autoHorizontal() Margin {
        return .{ .auto_mask = AUTO_LEFT | AUTO_RIGHT };
    }

    pub fn withAutoTop(self: Margin) Margin {
        var out = self;
        out.auto_mask |= AUTO_TOP;
        return out;
    }

    pub fn withAutoRight(self: Margin) Margin {
        var out = self;
        out.auto_mask |= AUTO_RIGHT;
        return out;
    }

    pub fn withAutoLeft(self: Margin) Margin {
        var out = self;
        out.auto_mask |= AUTO_LEFT;
        return out;
    }

    pub fn topIsAuto(self: Margin) bool {
        return (self.auto_mask & AUTO_TOP) != 0;
    }

    pub fn rightIsAuto(self: Margin) bool {
        return (self.auto_mask & AUTO_RIGHT) != 0;
    }

    pub fn bottomIsAuto(self: Margin) bool {
        return (self.auto_mask & AUTO_BOTTOM) != 0;
    }

    pub fn leftIsAuto(self: Margin) bool {
        return (self.auto_mask & AUTO_LEFT) != 0;
    }

    pub fn horizontal(self: Margin) f32 {
        return (if (self.leftIsAuto()) 0 else self.left) +
            (if (self.rightIsAuto()) 0 else self.right);
    }

    pub fn vertical(self: Margin) f32 {
        return (if (self.topIsAuto()) 0 else self.top) +
            (if (self.bottomIsAuto()) 0 else self.bottom);
    }

    pub fn eql(a: Margin, b: Margin) bool {
        return a.top == b.top and a.right == b.right and a.bottom == b.bottom and a.left == b.left and a.auto_mask == b.auto_mask;
    }
};

/// 尺寸定义 - 支持 4 种模式
pub const Sizing = union(enum) {
    /// 固定像素
    px: f32,
    /// 填充可用空间 (flex grow), 可带 min/max
    grow: SizingMinMax,
    /// 适应内容大小, 可带 min/max
    fit: SizingMinMax,
    /// 百分比
    percent: f32,

    pub const SizingMinMax = struct {
        min: f32 = 0,
        max: f32 = std.math.inf(f32),
    };

    /// 固定像素尺寸。支持 decl literal 写法：`.width = .fixed(120)`。
    pub fn fixed(v: f32) Sizing {
        return .{ .px = v };
    }

    /// 填充可用空间（等价 `.{ .grow = .{} }`）。支持 decl literal 写法：`.width = .fill()`。
    pub fn fill() Sizing {
        return .{ .grow = .{} };
    }

    /// 百分比尺寸。支持 decl literal 写法：`.width = .pct(50)`。
    pub fn pct(v: f32) Sizing {
        return .{ .percent = v };
    }
};

/// 布局约束（Measure 阶段传递给子节点）
/// 类似 CSS 的 available size + min/max 约束
pub const LayoutConstraints = struct {
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),
    /// 已知确切宽度（非 null 时子节点应使用此宽度，不做 intrinsic 计算）
    definite_width: ?f32 = null,
    /// 已知确切高度
    definite_height: ?f32 = null,

    /// 创建有确切宽高的约束
    pub fn exact(w: f32, h: f32) LayoutConstraints {
        return .{
            .min_width = w,
            .max_width = w,
            .min_height = h,
            .max_height = h,
            .definite_width = w,
            .definite_height = h,
        };
    }
};

/// Flex 方向
pub const Direction = enum {
    row,
    row_reverse,
    column,
    column_reverse,

    pub fn isRow(self: Direction) bool {
        return self == .row or self == .row_reverse;
    }

    pub fn isReverse(self: Direction) bool {
        return self == .row_reverse or self == .column_reverse;
    }
};

/// 主轴对齐
pub const JustifyContent = enum {
    start,
    end,
    center,
    space_between,
    space_around,
    space_evenly,
};

/// 交叉轴对齐
pub const AlignItems = enum {
    start,
    end,
    center,
    stretch,
    baseline,
};

/// Flex 换行
pub const FlexWrap = enum {
    no_wrap,
    wrap,
    wrap_reverse,
};

pub const Justify = JustifyContent;
pub const Alignment = AlignItems;

/// 颜色（RGBA）
pub const Color = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const TRANSPARENT = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const WHITE = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const BLACK = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn hex(value: u24) Color {
        return .{
            .r = @truncate(value >> 16),
            .g = @truncate(value >> 8),
            .b = @truncate(value),
            .a = 255,
        };
    }

    pub fn lerp(from: Color, to: Color, t: f32) Color {
        const t_clamped = std.math.clamp(t, 0.0, 1.0);
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(from.r)) + (@as(f32, @floatFromInt(to.r)) - @as(f32, @floatFromInt(from.r))) * t_clamped),
            .g = @intFromFloat(@as(f32, @floatFromInt(from.g)) + (@as(f32, @floatFromInt(to.g)) - @as(f32, @floatFromInt(from.g))) * t_clamped),
            .b = @intFromFloat(@as(f32, @floatFromInt(from.b)) + (@as(f32, @floatFromInt(to.b)) - @as(f32, @floatFromInt(from.b))) * t_clamped),
            .a = @intFromFloat(@as(f32, @floatFromInt(from.a)) + (@as(f32, @floatFromInt(to.a)) - @as(f32, @floatFromInt(from.a))) * t_clamped),
        };
    }

    pub fn withAlpha(self: Color, alpha: u8) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

pub const ThemeTokens = theme.ThemeTokens;
pub const ColorScheme = theme.ColorScheme;

/// 渐变延伸模式
/// 控制渐变 t 值超出 [0,1] 范围时的行为（对应 CSS background-repeat / SVG spreadMethod）
pub const GradientExtendMode = enum {
    pad, // 夹制到边界颜色（默认，CSS default）
    repeat, // 循环重复（CSS repeat / SVG repeat）
    reflect, // 镜像反射（CSS reflect / SVG reflect）
};

/// 渐变方向
pub const GradientDirection = enum {
    horizontal,
    vertical,
    diagonal,
    radial,
    conic,
};

/// SVG / CSS 合成混合模式（用于 Opacity Layer 的 blend_mode 参数）
/// 对应 CSS mix-blend-mode / SVG feBlend
pub const BlendMode = enum {
    normal, // 标准 SrcOver（默认）
    multiply, // 相乘变暗
    screen, // 相加变亮
    overlay, // 对比度增强（亮处更亮，暗处更暗）
    darken, // 取较暗值
    lighten, // 取较亮值
    color_dodge, // 亮化（分母为 1-src）
    color_burn, // 暗化（分母为 src）
    hard_light, // 强光（类 Overlay 但以 src 为主导）
    soft_light, // 柔光（低对比度 Overlay）
    difference, // 差值（绝对差）
    exclusion, // 排除（低对比度 Difference）
};

pub const PathFillRule = enum {
    evenodd,
    nonzero,
};

pub const LineJoin = enum {
    miter,
    bevel,
    round,
};

pub const RingArcHitSpec = struct {
    outer_radius: f32 = 0,
    inner_radius: f32 = 0,
    start_angle: f32 = 0,
    end_angle: f32 = std.math.tau,
};

pub const PathVerb = enum(u8) {
    move_to,
    line_to,
    quad_to,
    cubic_to,
    close,
};

pub const QuadraticPathCommand = struct {
    ctrl: Point,
    end: Point,
};

pub const CubicPathCommand = struct {
    ctrl1: Point,
    ctrl2: Point,
    end: Point,
};

pub const PathCommand = union(PathVerb) {
    move_to: Point,
    line_to: Point,
    quad_to: QuadraticPathCommand,
    cubic_to: CubicPathCommand,
    close: void,
};

pub const PathShapeSpec = struct {
    fill_rule: PathFillRule = .evenodd,
};

pub const HitShapeSpec = union(enum) {
    auto,
    none,
    rect,
    rounded_rect: f32,
    circle,
    ellipse,
    ring_arc: RingArcHitSpec,
    path: PathShapeSpec,
    custom,
};

/// 节点**自身绘制形状**（背景/边框走哪种 SDF）。与 `ClipShapeSpec` 不同：
/// 那个是裁剪掩码，只裁内容、裁不动描边；这个换的是填充与描边的距离场本身。
///
/// 默认 `rounded_rect` = 历史行为（圆角由 `corner_radius` 决定）。
/// `ellipse` 内接节点盒（半轴 = w/2, h/2），此时 `corner_radius` 被忽略。
pub const ShapeSpec = enum {
    rounded_rect,
    ellipse,
};

pub const ClipShapeSpec = union(enum) {
    auto,
    none,
    rect,
    rounded_rect: f32,
    ellipse,
    path: PathShapeSpec,
    custom,
};

pub const HitBehavior = enum {
    @"opaque",
    pass_through,
    children_only,
    self_only,
    self_and_children,
};

/// 解析后的命中角色（三个 role 都已定值）。消费端只见这个类型。
pub const HitRoles = packed struct(u3) {
    pointer: bool = false,
    scroll: bool = false,
    inspect: bool = true,

    pub fn any(self: HitRoles) bool {
        return self.pointer or self.scroll or self.inspect;
    }
};

/// `style.hit_roles` 的覆盖类型：**逐 role 三态**，null = 沿用框架推导的默认值。
///
/// 刻意不复用 `HitRoles`：那是个 bool 结构体，写 `.{ .pointer = true }` 会连带把
/// 未提及的 `scroll`/`inspect` 按字段默认值归零，调用方想"加一个 role"，实际
/// 却把另外两个也一并接管了（`inspect` 默认 true，被静默改成 false ⇒ 该节点在
/// devtools 里选不中）。三态让"只覆盖我写的那一个"成为可表达的意图。
pub const HitRolesOverride = struct {
    pointer: ?bool = null,
    scroll: ?bool = null,
    inspect: ?bool = null,

    /// 把覆盖叠加到推导出的默认值上；未指定的 role 原样保留。
    pub fn apply(self: HitRolesOverride, base: HitRoles) HitRoles {
        return .{
            .pointer = self.pointer orelse base.pointer,
            .scroll = self.scroll orelse base.scroll,
            .inspect = self.inspect orelse base.inspect,
        };
    }
};

pub const PathGeometry = struct {
    commands: []const PathCommand = &.{},
    fill_rule: PathFillRule = .evenodd,
    bounds: ComputedRect = ComputedRect.init(0, 0, 0, 0),
    owned: bool = false,
};

pub const HitProxySpec = struct {
    local_rect: ComputedRect = ComputedRect.init(0, 0, 0, 0),
    shape: HitShapeSpec = .auto,
    roles: ?HitRoles = null,
    behavior: ?HitBehavior = null,
};

pub const max_node_hit_proxies: usize = 8;

pub const Border = struct {
    width: f32 = 0,
    color: Color = Color.TRANSPARENT,
    radius: f32 = 0,
    /// 按边宽度覆盖（默认 -1 = 使用 width）
    /// 顺序: top, right, bottom, left
    side_widths: [4]f32 = .{ -1, -1, -1, -1 },

    pub const SIDE_TOP: usize = 0;
    pub const SIDE_RIGHT: usize = 1;
    pub const SIDE_BOTTOM: usize = 2;
    pub const SIDE_LEFT: usize = 3;

    /// 解析为四边宽度（top, right, bottom, left）
    pub fn resolvedWidths(self: Border) [4]f32 {
        const base = @max(@as(f32, 0), self.width);
        return .{
            if (self.side_widths[SIDE_TOP] >= 0) @max(@as(f32, 0), self.side_widths[SIDE_TOP]) else base,
            if (self.side_widths[SIDE_RIGHT] >= 0) @max(@as(f32, 0), self.side_widths[SIDE_RIGHT]) else base,
            if (self.side_widths[SIDE_BOTTOM] >= 0) @max(@as(f32, 0), self.side_widths[SIDE_BOTTOM]) else base,
            if (self.side_widths[SIDE_LEFT] >= 0) @max(@as(f32, 0), self.side_widths[SIDE_LEFT]) else base,
        };
    }

    pub fn clearPerSideWidths(self: *Border) void {
        self.side_widths = .{ -1, -1, -1, -1 };
    }

    pub fn setUniformWidth(self: *Border, width: f32) void {
        self.width = @max(@as(f32, 0), width);
        self.clearPerSideWidths();
    }

    pub fn isUniformWidth(self: Border) bool {
        const w = self.resolvedWidths();
        const eps: f32 = 0.0001;
        return std.math.approxEqAbs(f32, w[SIDE_TOP], w[SIDE_RIGHT], eps) and
            std.math.approxEqAbs(f32, w[SIDE_TOP], w[SIDE_BOTTOM], eps) and
            std.math.approxEqAbs(f32, w[SIDE_TOP], w[SIDE_LEFT], eps);
    }
};

pub const BorderSideColors = struct {
    top: ?Color = null,
    right: ?Color = null,
    bottom: ?Color = null,
    left: ?Color = null,

    pub fn resolved(self: BorderSideColors, base: Color) [4]Color {
        return .{
            self.top orelse base,
            self.right orelse base,
            self.bottom orelse base,
            self.left orelse base,
        };
    }
};

pub const Shadow = struct {
    color: Color = Color.rgba(0, 0, 0, 80),
    blur: f32 = 8,
    offset_x: f32 = 0,
    offset_y: f32 = 4,
    /// CSS box-shadow spread：正值外扩、负值先把阴影矩形收小再模糊（远投影常用）。
    spread: f32 = 0,
};

/// 外阴影层数上限（CSS 多重 box-shadow；列表第一项在最上层）。
pub const max_shadows = 4;

pub const Gradient = struct {
    from: Color,
    to: Color,
    direction: GradientDirection = .vertical,
};

/// 多色渐变色标
pub const GradientStop = struct {
    color: Color,
    position: f32, // [0.0, 1.0]
};

/// 多色渐变（最多 16 个 stop，无 banding）
/// 用静态数组避免动态分配和生命周期管理：stops[0..stop_count] 是有效数据
pub const MultiGradient = struct {
    stops: [16]GradientStop = [_]GradientStop{.{ .color = Color.rgba(0, 0, 0, 0), .position = 0 }} ** 16,
    stop_count: u8 = 0,
    direction: GradientDirection = .vertical,
    /// 径向渐变圆心（占节点宽 / 高的比例，可超出 [0,1]，如 CSS `at 12% -10%`）。
    radial_center: [2]f32 = .{ 0.5, 0.5 },
    /// 径向渐变椭圆半径（占节点宽 / 高的比例，CSS `radial-gradient(120% 100% …)`）。
    /// 默认 0.5 × 0.5 = 内切椭圆（与旧行为一致）。
    radial_radius: [2]f32 = .{ 0.5, 0.5 },

    /// 从 slice 构造（编译期 / 运行期均可，最多取 16 个）
    pub fn fromSlice(src: []const GradientStop, dir: GradientDirection) MultiGradient {
        var mg = MultiGradient{ .direction = dir };
        const n = @min(src.len, 16);
        mg.stop_count = @intCast(n);
        for (0..n) |i| mg.stops[i] = src[i];
        return mg;
    }

    pub fn slice(self: *const MultiGradient) []const GradientStop {
        return self.stops[0..self.stop_count];
    }
};

/// 程序性噪声参数
pub const NoiseParams = struct {
    mode: NoiseMode = .film_grain,
    scale: f32 = 2.0, // 逻辑像素，Value Noise 格点间距
    intensity: f32 = 0.04, // 混合强度 [0..1]
    seed: u8 = 0,
};

/// 噪声模式（对应 sdf_renderer.zig NoiseMode）
pub const NoiseMode = enum(u8) {
    none = 0,
    value = 1,
    film_grain = 2,
};

/// Inset Shadow（内阴影）
pub const InsetShadow = struct {
    color: Color = Color.rgba(0, 0, 0, 80),
    blur: f32 = 8,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

/// Overflow fade 遮罩的边缘选择
pub const FadeEdges = packed struct(u4) {
    top: bool = true,
    bottom: bool = true,
    left: bool = true,
    right: bool = true,
};

/// Overflow 容器溢出时在边缘显示渐变淡出遮罩
/// 在 overflow_hidden 容器的内容之上叠加 gradient rect，
/// 从容器背景色（实色端）到透明（淡出端），视觉效果类似 CSS mask-image
pub const OverflowFade = struct {
    /// 渐变区域大小（px）
    size: f32 = 32,
    /// 实色端颜色，null = 使用容器 background
    color: ?Color = null,
    /// 哪些边启用渐变
    edges: FadeEdges = .{},
};

pub const CornerRadius = union(enum) {
    all: f32,
    each: [4]f32, // TL, TR, BR, BL

    pub fn uniform(r: f32) CornerRadius {
        return .{ .all = r };
    }

    /// 返回统一圆角值（取四角最大值）
    pub fn resolve(self: CornerRadius) f32 {
        return switch (self) {
            .all => |v| v,
            .each => |e| @max(@max(e[0], e[1]), @max(e[2], e[3])),
        };
    }

    /// 返回四角独立圆角值 [TL, TR, BR, BL]
    pub fn resolve4(self: CornerRadius) [4]f32 {
        return switch (self) {
            .all => |v| .{ v, v, v, v },
            .each => |e| e,
        };
    }
};

/// CSS display 的子集。`.none`：节点连同子树不参与布局（不占空间、不计 gap）、
/// 不绘制、不参与命中测试 / 焦点遍历 / 无障碍树；节点与状态保持存活，切回
/// `.flex` 即恢复（与卸载子树不同）。
pub const Display = enum(u1) {
    flex,
    none,
};

pub const Position = enum {
    relative,
    absolute,
    sticky,
};

/// CSS inset 值（top/right/bottom/left）
pub const InsetValue = union(enum) {
    /// 不约束（CSS auto）
    auto,
    /// 绝对像素偏移
    px: f32,
    /// 相对 containing block 百分比
    percent: f32,

    /// 解析为绝对值。auto 返回 null。
    pub fn resolve(self: InsetValue, containing_size: f32) ?f32 {
        return switch (self) {
            .auto => null,
            .px => |v| v,
            .percent => |p| containing_size * p / 100.0,
        };
    }
};

/// CSS inset 配置（类似 top/right/bottom/left）
/// 仅 position != .relative 时生效
pub const Inset = struct {
    top: InsetValue = .auto,
    right: InsetValue = .auto,
    bottom: InsetValue = .auto,
    left: InsetValue = .auto,
};

/// CSS overflow 属性
pub const Overflow = enum {
    /// 内容可溢出（默认）
    visible,
    /// 裁剪溢出内容（无滚动条）
    hidden,
    /// 始终显示滚动条
    scroll,
    /// 仅在溢出时显示滚动条
    auto,

    /// 是否裁剪溢出（hidden/scroll/auto 都裁剪）
    pub fn clips(self: Overflow) bool {
        return self != .visible;
    }

    /// 是否可滚动（scroll/auto）
    pub fn scrollable(self: Overflow) bool {
        return self == .scroll or self == .auto;
    }
};

/// Sticky 定位的 inset 配置（类似 CSS top/left/bottom/right）
/// 只有对应方向的值不为 null 时才在该方向上粘附
pub const StickyInsets = struct {
    top: ?f32 = null,
    left: ?f32 = null,
    bottom: ?f32 = null,
    right: ?f32 = null,
};

pub const Outline = struct {
    color: Color,
    width: f32 = 1.5,
    offset: f32 = 2,
};

/// 鼠标光标形状 (类似 CSS cursor)
/// 通过 node.style.cursor 设置，框架自动在 hover 时应用对应系统光标
pub const CursorShape = enum(u8) {
    /// 继承父节点光标 (默认值，类似 CSS inherit)
    inherit,
    /// 默认箭头光标 (CSS: default)
    default,
    /// 手指指针，表示可点击 (CSS: pointer)
    pointer,
    /// I-beam 文本选择光标 (CSS: text)
    text,
    /// 十字准心 (CSS: crosshair)
    crosshair,
    /// 移动光标 (CSS: move)
    move,
    /// 禁止操作 (CSS: not-allowed)
    not_allowed,
    /// 抓取手势 (CSS: grab)
    grab,
    /// 正在抓取 (CSS: grabbing)
    grabbing,
    /// 水平调整大小 (CSS: ew-resize)
    ew_resize,
    /// 垂直调整大小 (CSS: ns-resize)
    ns_resize,
    /// 左上-右下调整 (CSS: nwse-resize)
    nwse_resize,
    /// 右上-左下调整 (CSS: nesw-resize)
    nesw_resize,
    /// 列调整 (CSS: col-resize)
    col_resize,
    /// 行调整 (CSS: row-resize)
    row_resize,
    /// 等待 (CSS: wait)
    wait,
    /// 后台处理中 (CSS: progress)
    progress,
    /// 帮助 (CSS: help)
    help,
    /// 隐藏光标 (CSS: none)
    none,
    /// 自定义位图光标：内容（位图 + 热点）由 `Cx.setCustomCursor` 激活，
    /// 节点/override 上只写这个形状值；后端不支持位图光标时降级为
    /// `Cx.custom_cursor_fallback`（默认 crosshair）。
    /// 必须追加在枚举尾部：1..18 与 native 层 switch 一一对应。
    custom,
    /// Stop framework cursor writes; a native/platform view owns presentation.
    uncontrolled,
};

/// Grid track 尺寸定义（类似 CSS grid-template-columns/rows 中的值）
pub const GridTrackSize = union(enum) {
    px: f32, // 固定像素
    fr: f32, // 弹性比例（CSS fr 单位）
    auto, // 适应内容
};

/// Grid 容器配置（通过指针挂载到 Style，仅 Grid 容器使用）
pub const GridConfig = struct {
    columns: [MAX_TRACKS]GridTrackSize = undefined,
    column_count: u8 = 0,
    rows: [MAX_TRACKS]GridTrackSize = undefined,
    row_count: u8 = 0,
    column_gap: f32 = 0,
    row_gap: f32 = 0,

    pub const MAX_TRACKS = 16;
};

/// Grid 子节点放置位置
pub const GridPlacement = struct {
    col_start: u8 = 0, // 1-based，0 = auto
    col_span: u8 = 1,
    row_start: u8 = 0, // 1-based，0 = auto
    row_span: u8 = 1,
};

pub const Style = struct {
    // ── 高频内联字段 (~80 bytes) ──
    // background / opacity 字段已删 -> World.paint_state SoA。
    // 读写经 Node.getBackground/setBackgroundRaw（standalone fallback for mock）。
    border: Border = .{},
    padding: Padding = Padding.ZERO,
    direction: Direction = .column,
    justify: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    gap: f32 = 0,
    width: Sizing = .{ .fit = .{} },
    height: Sizing = .{ .fit = .{} },
    flex: f32 = 1,
    flex_shrink: f32 = 1,
    translate_x: f32 = 0,
    translate_y: f32 = 0,
    overflow: Overflow = .visible,
    overflow_hidden: bool = false,
    margin: Padding = Padding.ZERO,
    position: Position = .relative,
    display: Display = .flex,
    cursor: CursorShape = .inherit,
    layout_isolation: bool = false,

    // ── 低频字段（按需分配，大多数节点为 null -> ~0 bytes） ──
    ext: ?*StyleExt = null,

    // ── Accessor 方法（只读，返回 ext 中的值或默认值） ──

    const default_ext = StyleExt{};

    pub inline fn getExt(self: *const Style) *const StyleExt {
        return if (self.ext) |e| e else &default_ext;
    }

    /// 返回第一层外阴影（不存在则 null）
    pub inline fn shadow(self: *const Style) ?Shadow {
        const e = self.getExt();
        return if (e.shadow_count > 0) e.shadows[0] else null;
    }

    /// 返回全部外阴影切片（0~max_shadows 个）
    pub inline fn shadowSlice(self: *const Style) []const Shadow {
        const e = self.getExt();
        return e.shadows[0..e.shadow_count];
    }
    pub inline fn gradient(self: *const Style) ?Gradient {
        return self.getExt().gradient;
    }
    pub inline fn outline(self: *const Style) ?Outline {
        return self.getExt().outline;
    }
    pub inline fn corner_radius(self: *const Style) ?CornerRadius {
        return self.getExt().corner_radius;
    }
    pub inline fn scale_x(self: *const Style) f32 {
        return self.getExt().scale_x;
    }
    pub inline fn scale_y(self: *const Style) f32 {
        return self.getExt().scale_y;
    }
    pub inline fn rotate(self: *const Style) f32 {
        return self.getExt().rotate;
    }
    pub inline fn transform_origin(self: *const Style) TransformOrigin {
        return self.getExt().transform_origin;
    }
    pub inline fn flex_basis(self: *const Style) f32 {
        return self.getExt().flex_basis;
    }
    pub inline fn align_self(self: *const Style) ?AlignItems {
        return self.getExt().align_self;
    }
    pub inline fn no_cross_stretch(self: *const Style) bool {
        return self.getExt().no_cross_stretch;
    }
    pub inline fn inset(self: *const Style) Inset {
        return self.getExt().inset;
    }
    pub inline fn sticky_insets(self: *const Style) StickyInsets {
        return self.getExt().sticky_insets;
    }
    pub inline fn z_index(self: *const Style) i16 {
        return self.getExt().z_index;
    }
    pub inline fn tab_index(self: *const Style) ?i32 {
        return self.getExt().tab_index;
    }
    pub inline fn aspect_ratio(self: *const Style) f32 {
        return self.getExt().aspect_ratio;
    }
    pub inline fn grid(self: *const Style) ?*GridConfig {
        return self.getExt().grid;
    }
    pub inline fn grid_placement(self: *const Style) ?GridPlacement {
        return self.getExt().grid_placement;
    }
    pub inline fn min_width(self: *const Style) f32 {
        return self.getExt().min_width;
    }
    pub inline fn max_width(self: *const Style) f32 {
        return self.getExt().max_width;
    }
    pub inline fn min_height(self: *const Style) f32 {
        return self.getExt().min_height;
    }
    pub inline fn max_height(self: *const Style) f32 {
        return self.getExt().max_height;
    }
    pub inline fn flex_wrap(self: *const Style) FlexWrap {
        return self.getExt().flex_wrap;
    }
    pub inline fn hit_shape(self: *const Style) HitShapeSpec {
        return self.getExt().hit_shape;
    }
    pub inline fn clip_shape(self: *const Style) ClipShapeSpec {
        return self.getExt().clip_shape;
    }

    pub inline fn shape(self: *const Style) ShapeSpec {
        return self.getExt().shape;
    }
    pub inline fn hit_behavior(self: *const Style) ?HitBehavior {
        return self.getExt().hit_behavior;
    }
    pub inline fn hit_roles(self: *const Style) HitRolesOverride {
        return self.getExt().hit_roles;
    }
    /// 获取 glass 参数（null = 无 glass 效果）
    pub inline fn glass_params(self: *const Style) ?GlassParams {
        return self.getExt().glass;
    }
    /// 背景模糊半径（逻辑像素，0 = 无模糊），从 glass 参数解包
    pub inline fn backdrop_blur(self: *const Style) f32 {
        const gp = self.getExt().glass orelse return 0;
        return gp.backdrop_blur;
    }
    pub inline fn multi_gradient(self: *const Style) ?MultiGradient {
        return self.getExt().multi_gradient;
    }
    pub inline fn noise(self: *const Style) ?NoiseParams {
        return self.getExt().noise;
    }
    pub inline fn inset_shadow(self: *const Style) ?InsetShadow {
        return self.getExt().inset_shadow;
    }
    /// 第 2 层起的内阴影（最多 2 层）。
    pub inline fn extraInsetShadows(self: *const Style) []const InsetShadow {
        const e = self.getExt();
        return e.extra_inset_shadows[0..e.extra_inset_count];
    }
    pub inline fn overflow_fade(self: *const Style) ?OverflowFade {
        return self.getExt().overflow_fade;
    }
    pub inline fn border_side_colors(self: *const Style) ?BorderSideColors {
        return self.getExt().border_side_colors;
    }
    pub inline fn keep_rendering_when_transparent(self: *const Style) bool {
        return self.getExt().keep_rendering_when_transparent;
    }
    pub inline fn will_change_transform(self: *const Style) bool {
        return self.getExt().will_change_transform;
    }
    pub inline fn will_change_opacity(self: *const Style) bool {
        return self.getExt().will_change_opacity;
    }
    pub inline fn composited_group(self: *const Style) bool {
        return self.getExt().composited_group;
    }
    pub inline fn blendMode(self: *const Style) BlendMode {
        return self.getExt().blend_mode;
    }
    pub inline fn marginAutoMask(self: *const Style) u8 {
        return self.getExt().margin_auto_mask;
    }
    pub inline fn marginTopIsAuto(self: *const Style) bool {
        return (self.marginAutoMask() & Margin.AUTO_TOP) != 0;
    }
    pub inline fn marginRightIsAuto(self: *const Style) bool {
        return (self.marginAutoMask() & Margin.AUTO_RIGHT) != 0;
    }
    pub inline fn marginBottomIsAuto(self: *const Style) bool {
        return (self.marginAutoMask() & Margin.AUTO_BOTTOM) != 0;
    }
    pub inline fn marginLeftIsAuto(self: *const Style) bool {
        return (self.marginAutoMask() & Margin.AUTO_LEFT) != 0;
    }
    pub inline fn marginHorizontal(self: *const Style) f32 {
        return (if (self.marginLeftIsAuto()) 0 else self.margin.left) +
            (if (self.marginRightIsAuto()) 0 else self.margin.right);
    }
    pub inline fn marginVertical(self: *const Style) f32 {
        return (if (self.marginTopIsAuto()) 0 else self.margin.top) +
            (if (self.marginBottomIsAuto()) 0 else self.margin.bottom);
    }
    pub inline fn marginSpec(self: *const Style) Margin {
        return .{
            .top = self.margin.top,
            .right = self.margin.right,
            .bottom = self.margin.bottom,
            .left = self.margin.left,
            .auto_mask = self.marginAutoMask(),
        };
    }
    pub fn setMarginSpec(self: *Style, allocator: std.mem.Allocator, margin: Margin) void {
        self.margin = margin.toPadding();
        self.ensureExtPanic(allocator).margin_auto_mask = margin.auto_mask;
    }
    pub fn clearAutoMargins(self: *Style) void {
        if (self.ext) |e| e.margin_auto_mask = 0;
    }
    pub fn setMarginTopAutoFallback(self: *Style, auto: bool) void {
        if (self.ext == null and !auto) return;
        if (self.ext) |e| {
            if (auto) e.margin_auto_mask |= Margin.AUTO_TOP else e.margin_auto_mask &= ~Margin.AUTO_TOP;
        }
    }
    pub fn setMarginLeftAutoFallback(self: *Style, auto: bool) void {
        if (self.ext == null and !auto) return;
        if (self.ext) |e| {
            if (auto) e.margin_auto_mask |= Margin.AUTO_LEFT else e.margin_auto_mask &= ~Margin.AUTO_LEFT;
        }
    }

    // ── 可继承文本属性 accessor ──
    pub inline fn text_color(self: *const Style) ?Color {
        return self.getExt().text_color;
    }
    pub inline fn text_font_size(self: *const Style) ?f32 {
        return self.getExt().text_font_size;
    }
    pub inline fn text_font_weight(self: *const Style) ?u16 {
        return self.getExt().text_font_weight;
    }

    pub fn effectiveRadius(self: *const Style) f32 {
        if (self.corner_radius()) |cr| return cr.resolve();
        return self.border.radius;
    }

    /// 返回四角独立圆角值 [TL, TR, BR, BL]
    pub fn effectiveRadii(self: *const Style) [4]f32 {
        if (self.corner_radius()) |cr| return cr.resolve4();
        const r = self.border.radius;
        return .{ r, r, r, r };
    }

    // 编译期大小检查：内联高频字段应 <= 128 bytes
    comptime {
        if (@sizeOf(Style) > 128) @compileError("Style too large");
    }

    /// ⚠️ **已冻结，不要在新代码里用。** 分配失败时 `@panic`，对编辑器来说
    /// abort 是最坏结局（用户数据全丢）。绝大多数调用点所在的函数本身就是 `!T`、
    /// 本来就能传播错误。
    ///
    /// 新代码一律用 `ensureExtFallible` 并把错误传上去。确实"构造上不可能失败"
    /// （容量已预留等）就写 `ensureExtFallible(a) catch unreachable` 并在注释里
    /// 论证，要可 grep、可 review，而不是藏在库函数里。
    ///
    /// 存量调用点受下游项目的 OOM 债务棘轮脚本约束：只减不增。
    /// 归零后本函数删除。改名为 `*Panic` 是为了让存量可 grep、且没人会顺手敲它。
    pub fn ensureExtPanic(self: *Style, allocator: std.mem.Allocator) *StyleExt {
        return self.ensureExtFallible(allocator) catch @panic("OOM: StyleExt");
    }

    pub fn ensureExtFallible(self: *Style, allocator: std.mem.Allocator) !*StyleExt {
        if (self.ext) |e| return e;
        const e = try allocator.create(StyleExt);
        e.* = .{};
        self.ext = e;
        return e;
    }
};

pub const GlassSurface = enum(u8) {
    /// 平面，不额外塑形。适合作为玻璃底面基准。
    flat = 0,
    /// 圆弧凸面，边缘位移更均匀，适合放大镜 / 浮凸镜片。
    convex_circle = 1,
    /// Squircle 凸面，边缘过渡更平，适合系统控件式 liquid glass。
    convex_squircle = 2,
    /// 凹面，中心更容易产生缩退 / zoom-out 的位移趋势。
    concave = 3,
    /// 外圈凸起、中心微凹，适合开关 / 胶囊按钮一类玻璃。
    lip = 4,
};

/// 液态玻璃效果参数（用户侧，Color 类型）
/// 类 CSS linear-gradient 的 blur 渐变：把 backdrop blur 强度当作沿某方向
/// 变化的渐变属性（Apple scroll-edge progressive blur 是它的一个特例）。
///   blur_gradient = .{ .direction = .to_bottom,
///                      .stops = ..., .stop_count = 3 }
/// ≈ linear-gradient(to bottom, blur 0%, blur 30%, none 100%)
pub const BlurGradient = struct {
    pub const BlurGradientDirection = enum(u8) {
        /// 关闭（无渐变，整面均匀 blur）
        none = 0,
        /// t=0 在顶边（CSS `to bottom`：起点在上）
        to_bottom = 1,
        /// t=0 在底边
        to_top = 2,
        /// t=0 在左边
        to_right = 3,
        /// t=0 在右边
        to_left = 4,
    };
    /// 渐变 stop（同 CSS gradient color stop）
    pub const Stop = struct {
        /// 位置：占节点沿渐变轴尺寸的百分比 0~1（需升序）
        pos: f32 = 0.0,
        /// 该位置的 blur 强度 0~1
        strength: f32 = 0.0,
    };

    direction: BlurGradientDirection = .none,
    /// 全局强度乘子 0~1（滚动位置等运行时信号驱动整体淡入淡出）
    strength: f32 = 1.0,
    /// stops：段间 smoothstep 插值；首 stop 前 / 末 stop 后保持端点强度。
    /// 最多取前 4 个；空 slice 退回默认 (0,1)->(1,0) 单段渐出。
    /// 注意生命周期：style 是 retained 的，slice 须指向 comptime 字面量
    /// （`&.{ ... }`）或与节点同寿命的存储，不能指向栈上临时数组。
    stops: []const Stop = &.{},
};

pub const GlassParams = struct {
    /// 背景模糊半径（逻辑像素，0 = 无模糊），同 CSS backdrop-filter: blur(px)：
    /// 连续可调、DPI 无关。量程 [0, 96]，超出 clamp（Kawase 链 6 级封顶，
    /// 96 已接近纯色平均，更大值无视觉意义）。
    backdrop_blur: f32 = 0,
    /// 毛玻璃色调叠加（null = 无色调，仅 blur）
    glass_tint: ?Color = null,
    /// Liquid Glass 强度（0 = 仅 blur，1 = 默认液态玻璃，>1 = 更厚更亮）
    glass_intensity: f32 = 1.0,
    /// 高光不透明度（0.20~0.50，搜索框=0.20，开关=0.50）
    specular_opacity: f32 = 0.35,
    /// 高光颜色饱和度（4~9，搜索框=4，放大镜=9）
    specular_saturation: f32 = 6.0,
    /// 折射强度（0~1，搜索框=0.70，其他=1.00）
    refraction_level: f32 = 1.0,
    /// Backdrop blur 混合（0=纯 sharp，1=纯 blur，开关=0.20，其他=1.0）
    blur_level: f32 = 1.0,
    /// 屏幕空间折射位移感知强度（与 IOR 解耦，0-3，默认 1.0）
    warp_gain: f32 = 1.0,
    /// 中心薄层厚度（逻辑像素，驱动折射 warp 幅度和 Beer-Lambert tint，默认 4.0）
    center_thickness: f32 = 4.0,
    /// 玻璃上表面轮廓，直接影响镜面高光、位移向量场与中心透镜感。
    surface: GlassSurface = .convex_squircle,
    /// 上表面玻璃边沿（bezel）占最小半轴的比例，决定曲面过渡宽度。
    bezel_width: f32 = 0.18,
    /// 玻璃下表面轮廓，默认平面；影响厚度分布与出射折射。
    bottom_surface: GlassSurface = .flat,
    /// 下表面 bevel 宽度比例。默认较窄，常用于平底或浅弧底。
    bottom_bezel_width: f32 = 0.12,
    /// 背景饱和度（CSS backdrop-filter: saturate()，1 = 不变，2.1 = 210%）。
    backdrop_saturation: f32 = 1.0,
    /// 背景亮度（CSS backdrop-filter: brightness()，1 = 不变）。
    backdrop_brightness: f32 = 1.0,
    /// 镜面高光方向（弧度，屏幕空间，0 = 向右，-π/2 = 向上）。
    specular_angle: f32 = -std.math.pi / 3.0,
    /// 额外中心放大倍率（0 = 无放大，1 = 明显透镜）。
    magnification: f32 = 0.0,
    /// 玻璃主体的光学尺度比例，控制位移场覆盖半径。
    scale_ratio: f32 = 1.0,
    /// 边缘 displacement field 强度（0.2~4.0），控制 bezel 附近的背景扭曲。
    edge_field_strength: f32 = 1.0,
    /// 中心 zoom displacement 半径（相对最小半轴，0.1~1.5）。
    center_zoom_radius: f32 = 0.58,
    /// 中心 zoom displacement 衰减指数（越大边界越紧，0.4~6.0）。
    center_zoom_falloff: f32 = 2.2,
    /// 玻璃与底图之间的“悬浮距离”（逻辑像素），会放大折射和模糊感。
    backdrop_distance: f32 = 0.0,
    /// blur 渐变（类 CSS linear-gradient；见 BlurGradient）。
    /// direction=.none 时关闭。
    blur_gradient: BlurGradient = .{},

    /// 转为 GPU 就绪格式（Color->[4]f32）
    pub fn resolve(self: GlassParams) ResolvedGlassParams {
        // blur gradient stops：clamp 到 [0,1] 并强制升序；空 slice -> 默认
        // 双 stop (0,1)->(1,0)（单段渐出）
        const bg = self.blur_gradient;
        var stop_pos: [4]f32 = .{ 0, 1, 1, 1 };
        var stop_str: [4]f32 = .{ 1, 0, 0, 0 };
        var stop_count: u8 = 2;
        if (bg.stops.len > 0) {
            stop_count = @intCast(@min(bg.stops.len, 4));
            var prev: f32 = 0.0;
            for (0..stop_count) |i| {
                const s = bg.stops[i];
                prev = std.math.clamp(std.math.clamp(s.pos, 0.0, 1.0), prev, 1.0);
                stop_pos[i] = prev;
                stop_str[i] = std.math.clamp(s.strength, 0.0, 1.0);
            }
            // 尾部填充为末 stop，shader 循环越界安全
            for (stop_count..4) |i| {
                stop_pos[i] = stop_pos[stop_count - 1];
                stop_str[i] = stop_str[stop_count - 1];
            }
        }
        var specular_angle = self.specular_angle;
        while (specular_angle > std.math.pi) specular_angle -= std.math.tau;
        while (specular_angle <= -std.math.pi) specular_angle += std.math.tau;
        const gt: [4]f32 = if (self.glass_tint) |c|
            .{ @as(f32, @floatFromInt(c.r)) / 255.0, @as(f32, @floatFromInt(c.g)) / 255.0, @as(f32, @floatFromInt(c.b)) / 255.0, @as(f32, @floatFromInt(c.a)) / 255.0 }
        else
            .{ 1, 1, 1, 1 };
        return .{
            .backdrop_blur = std.math.clamp(self.backdrop_blur, 0.0, 96.0),
            .glass_tint = gt,
            .glass_intensity = std.math.clamp(self.glass_intensity, 0.0, 2.0),
            .specular_opacity = std.math.clamp(self.specular_opacity, 0.0, 1.0),
            .specular_saturation = std.math.clamp(self.specular_saturation, 1.0, 12.0),
            .refraction_level = std.math.clamp(self.refraction_level, 0.0, 1.0),
            .blur_level = std.math.clamp(self.blur_level, 0.0, 1.0),
            .warp_gain = std.math.clamp(self.warp_gain, 0.0, 3.0),
            .center_thickness = std.math.clamp(self.center_thickness, 0.0, 20.0),
            .surface = self.surface,
            .bezel_width = std.math.clamp(self.bezel_width, 0.04, 0.45),
            .bottom_surface = self.bottom_surface,
            .bottom_bezel_width = std.math.clamp(self.bottom_bezel_width, 0.04, 0.45),
            .backdrop_saturation = std.math.clamp(self.backdrop_saturation, 0.0, 4.0),
            .backdrop_brightness = std.math.clamp(self.backdrop_brightness, 0.0, 3.0),
            .specular_angle = specular_angle,
            .magnification = std.math.clamp(self.magnification, -1.0, 2.0),
            .scale_ratio = std.math.clamp(self.scale_ratio, 0.35, 1.6),
            .edge_field_strength = std.math.clamp(self.edge_field_strength, 0.2, 4.0),
            .center_zoom_radius = std.math.clamp(self.center_zoom_radius, 0.1, 1.5),
            .center_zoom_falloff = std.math.clamp(self.center_zoom_falloff, 0.4, 6.0),
            .backdrop_distance = std.math.clamp(self.backdrop_distance, 0.0, 40.0),
            .blur_gradient_direction = @intFromEnum(bg.direction),
            .blur_gradient_strength = std.math.clamp(bg.strength, 0.0, 1.0),
            .blur_gradient_stop_pos = stop_pos,
            .blur_gradient_stop_str = stop_str,
            .blur_gradient_stop_count = stop_count,
        };
    }
};

/// 液态玻璃效果参数（GPU 就绪格式，[4]f32 tint）
pub const ResolvedGlassParams = struct {
    backdrop_blur: f32 = 0,
    glass_tint: [4]f32 = .{ 1, 1, 1, 1 },
    glass_intensity: f32 = 1.0,
    specular_opacity: f32 = 0.35,
    specular_saturation: f32 = 6.0,
    refraction_level: f32 = 1.0,
    blur_level: f32 = 1.0,
    warp_gain: f32 = 1.0,
    center_thickness: f32 = 4.0,
    surface: GlassSurface = .convex_squircle,
    bezel_width: f32 = 0.18,
    bottom_surface: GlassSurface = .flat,
    bottom_bezel_width: f32 = 0.12,
    backdrop_saturation: f32 = 1.0,
    backdrop_brightness: f32 = 1.0,
    specular_angle: f32 = -std.math.pi / 3.0,
    magnification: f32 = 0.0,
    scale_ratio: f32 = 1.0,
    edge_field_strength: f32 = 1.0,
    center_zoom_radius: f32 = 0.58,
    center_zoom_falloff: f32 = 2.2,
    backdrop_distance: f32 = 0.0,
    blur_gradient_direction: u8 = 0,
    blur_gradient_strength: f32 = 1.0,
    blur_gradient_stop_pos: [4]f32 = .{ 0, 1, 1, 1 },
    blur_gradient_stop_str: [4]f32 = .{ 1, 0, 0, 0 },
    blur_gradient_stop_count: u8 = 2,
};

/// Style 扩展结构（低频字段，按需分配）
pub const StyleExt = struct {
    /// 外阴影列表（最多 max_shadows 层）。通过 setShadow / setShadows / setShadowList
    /// 设置，不要直接修改字段。
    shadows: [max_shadows]Shadow = [_]Shadow{.{}} ** max_shadows,
    shadow_count: u8 = 0,
    gradient: ?Gradient = null,
    outline: ?Outline = null,
    corner_radius: ?CornerRadius = null,
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    /// 旋转角度（弧度，正值顺时针），origin 由 transform_origin 控制
    rotate: f32 = 0,
    transform_origin: TransformOrigin = .{},
    flex_basis: f32 = 0,
    align_self: ?AlignItems = null,
    /// 只拒绝「继承来的」交叉轴 stretch：align_self 为 null 且父 align_items == .stretch
    /// 时按 .start 排（保持 intrinsic 交叉尺寸）；父显式 .center/.end/.start 照常生效，
    /// 显式 align_self（含 .stretch）仍优先。用于 fit 宽但不该被拉伸的控件（Button）。
    no_cross_stretch: bool = false,
    margin_auto_mask: u8 = 0,
    inset: Inset = .{},
    sticky_insets: StickyInsets = .{},
    /// **只影响同一父节点下兄弟节点的绘制与命中顺序。** 每个节点都是其子节点的
    /// stacking context：z 不跨父节点比较，不影响裁剪，也不影响命中是否受裁剪
    /// （渲染与命中都由祖先 overflow_hidden 链裁剪）。同级顺序见
    /// core/paint_order.zig：regular -> sticky(z<=0) -> positive_z(z>0，按 z 稳定升序)；
    /// 负值按 0 处理。要在视觉上压过表亲，就给共同祖先下相应的那个子节点设 z；
    /// 要画到所有容器外，就挂到 portal（`cx.ensurePopoverPortalRoot()` / OverlayStack）。
    z_index: i16 = 0,
    tab_index: ?i32 = null,
    aspect_ratio: f32 = 0,
    grid: ?*GridConfig = null,
    grid_placement: ?GridPlacement = null,
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),
    flex_wrap: FlexWrap = .no_wrap,
    hit_shape: HitShapeSpec = .auto,
    clip_shape: ClipShapeSpec = .auto,
    /// 节点自身的绘制形状（见 ShapeSpec）。默认圆角矩形。
    shape: ShapeSpec = .rounded_rect,
    hit_behavior: ?HitBehavior = null,
    hit_roles: HitRolesOverride = .{},
    /// 液态玻璃效果参数（null = 无 glass/blur 效果）
    glass: ?GlassParams = null,
    /// 多色渐变（null = 用旧两色 Gradient）
    multi_gradient: ?MultiGradient = null,
    /// 程序性噪声纹理（null = 无噪声）
    noise: ?NoiseParams = null,
    /// Inset Shadow 内阴影（null = 无）。多层时这是第一层（最上层），其余在 extra_inset_shadows。
    inset_shadow: ?InsetShadow = null,
    /// 第 2、3 层内阴影（CSS 多重 inset box-shadow）。经 setInsetShadowList 设置。
    extra_inset_shadows: [2]InsetShadow = [_]InsetShadow{.{}} ** 2,
    extra_inset_count: u8 = 0,
    /// Overflow fade 渐变遮罩配置
    overflow_fade: ?OverflowFade = null,
    /// 四边独立 border 颜色覆盖（null = 使用 border.color）
    border_side_colors: ?BorderSideColors = null,
    /// 即使 opacity=0 也保留在 render/tick traversal 中，供 overlay 等场景预热首帧。
    keep_rendering_when_transparent: bool = false,
    /// 预提示 compositor 提前为 transform 动画准备独立 layer。
    will_change_transform: bool = false,
    /// 预提示 compositor 提前为 opacity 动画准备独立 layer。
    will_change_opacity: bool = false,
    /// 显式请求将当前节点子树提升为 retained composited group surface。
    composited_group: bool = false,
    /// SVG/CSS 混合模式（multiply/screen/…）。非 normal 会强制本节点子树走
    /// offscreen surface（混合需要独立光栅化的 src），并在合成时按 W3C
    /// Compositing L1 公式与背景混合。normal = 默认 SrcOver，无额外开销。
    blend_mode: BlendMode = .normal,

    // ── 可继承文本属性（类似 CSS inherited properties） ──
    // 设置后自动被子孙 text 节点继承（除非子节点自己显式设置）
    /// 继承文本颜色（null = 不设置，由 text node 自己决定）
    text_color: ?Color = null,
    /// 继承字体大小
    text_font_size: ?f32 = null,
    /// 继承字体权重
    text_font_weight: ?u16 = null,

    /// 设置单层外阴影
    pub fn setShadow(self: *StyleExt, s: Shadow) void {
        self.shadows[0] = s;
        self.shadow_count = 1;
    }

    /// 设置两层外阴影（s1 = 近距精锐，s2 = 远距环境光）
    pub fn setShadows(self: *StyleExt, s1: Shadow, s2: Shadow) void {
        self.shadows[0] = s1;
        self.shadows[1] = s2;
        self.shadow_count = 2;
    }

    /// 设置多层外阴影（CSS 顺序：第一项在最上层），超出 max_shadows 的截断。
    pub fn setShadowList(self: *StyleExt, list: []const Shadow) void {
        const n = @min(list.len, max_shadows);
        for (list[0..n], 0..) |s, i| self.shadows[i] = s;
        self.shadow_count = @intCast(n);
    }

    /// 设置多层内阴影（CSS 顺序：第一项在最上层），最多 3 层。
    pub fn setInsetShadowList(self: *StyleExt, list: []const InsetShadow) void {
        self.inset_shadow = if (list.len > 0) list[0] else null;
        const extra = if (list.len > 1) @min(list.len - 1, self.extra_inset_shadows.len) else 0;
        for (0..extra) |i| self.extra_inset_shadows[i] = list[i + 1];
        self.extra_inset_count = @intCast(extra);
    }

    /// 清除所有外阴影
    pub fn clearShadows(self: *StyleExt) void {
        self.shadow_count = 0;
    }
};

// ==================== StyleOverride，统一样式覆盖 ====================

/// 样式覆盖结构，所有字段默认 null，表示"不覆盖，用组件默认值"
/// 统一样式描述（全可选字段）
///
/// 用于 box() 构造节点、组件外部样式覆盖、多层 merge。
/// 内部通过 applyTo() 转换为紧凑的 Style（存储在 Node 上）。
pub const BoxStyle = struct {
    // ── 布局字段 ──
    width: ?Sizing = null,
    height: ?Sizing = null,
    direction: ?Direction = null,
    justify: ?JustifyContent = null,
    align_items: ?AlignItems = null,
    gap: ?f32 = null,
    padding: ?Padding = null,
    margin: ?Padding = null,
    /// 完整 margin 声明（支持 auto）。若与 margin 同时设置，以 margin_spec 为准。
    margin_spec: ?Margin = null,
    flex: ?f32 = null,
    flex_shrink: ?f32 = null,
    position: ?Position = null,
    display: ?Display = null,
    overflow: ?Overflow = null,
    overflow_hidden: ?bool = null,
    layout_isolation: ?bool = null,

    // ── 视觉字段 ──
    background: ?Color = null,
    opacity: ?f32 = null,
    cursor: ?CursorShape = null,
    translate_x: ?f32 = null,
    translate_y: ?f32 = null,
    scale_x: ?f32 = null,
    scale_y: ?f32 = null,
    rotate: ?f32 = null,
    transform_origin: ?TransformOrigin = null,

    // ── Border ──
    /// 整体 border（color + width + radius 一次性设置）
    border: ?Border = null,
    /// 细粒度 border_color 覆盖（仅改颜色，不影响 width/radius）
    border_color: ?Color = null,
    /// 细粒度 border_width 覆盖（仅改宽度，不影响 color/radius）
    border_width: ?f32 = null,
    /// 细粒度四边宽度覆盖
    border_top_width: ?f32 = null,
    border_right_width: ?f32 = null,
    border_bottom_width: ?f32 = null,
    border_left_width: ?f32 = null,
    /// 细粒度四边颜色覆盖
    border_top_color: ?Color = null,
    border_right_color: ?Color = null,
    border_bottom_color: ?Color = null,
    border_left_color: ?Color = null,

    // ── ext 便捷字段 ──
    corner_radius: ?f32 = null,
    shadow: ?Shadow = null,

    // ── 文本相关（组件常需覆盖） ──
    text_color: ?Color = null,
    font_size: ?f32 = null,
    font_weight: ?u16 = null,

    /// DevTools 来源追踪用：返回这个 BoxStyle 实际声明的 StyleField bitset。
    /// BoxStyle 的细粒度 border_* 最终都落到 StyleField.border；margin_spec
    /// 同理落到 margin。保持纯计算，不增加 BoxStyle/Node 的运行时尺寸。
    pub fn styleFieldMask(self: BoxStyle) u64 {
        comptime std.debug.assert(@typeInfo(StyleField).@"enum".fields.len <= 64);
        var mask: u64 = 0;
        const Add = struct {
            fn field(out: *u64, comptime f: StyleField, present: bool) void {
                if (present) out.* |= @as(u64, 1) << @intFromEnum(f);
            }
        };

        Add.field(&mask, .width, self.width != null);
        Add.field(&mask, .height, self.height != null);
        Add.field(&mask, .direction, self.direction != null);
        Add.field(&mask, .justify, self.justify != null);
        Add.field(&mask, .align_items, self.align_items != null);
        Add.field(&mask, .gap, self.gap != null);
        Add.field(&mask, .padding, self.padding != null);
        Add.field(&mask, .margin, self.margin != null or self.margin_spec != null);
        Add.field(&mask, .flex, self.flex != null);
        Add.field(&mask, .flex_shrink, self.flex_shrink != null);
        Add.field(&mask, .position, self.position != null);
        Add.field(&mask, .overflow, self.overflow != null);
        Add.field(&mask, .overflow_hidden, self.overflow_hidden != null);
        Add.field(&mask, .layout_isolation, self.layout_isolation != null);
        Add.field(&mask, .background, self.background != null);
        Add.field(&mask, .opacity, self.opacity != null);
        Add.field(&mask, .cursor, self.cursor != null);
        Add.field(&mask, .translate_x, self.translate_x != null);
        Add.field(&mask, .translate_y, self.translate_y != null);
        Add.field(&mask, .scale_x, self.scale_x != null);
        Add.field(&mask, .scale_y, self.scale_y != null);
        Add.field(&mask, .rotate, self.rotate != null);
        Add.field(&mask, .transform_origin, self.transform_origin != null);
        Add.field(&mask, .border, self.border != null or self.border_color != null or
            self.border_width != null or self.border_top_width != null or
            self.border_right_width != null or self.border_bottom_width != null or
            self.border_left_width != null or self.border_top_color != null or
            self.border_right_color != null or self.border_bottom_color != null or
            self.border_left_color != null);
        Add.field(&mask, .corner_radius, self.corner_radius != null);
        Add.field(&mask, .shadow, self.shadow != null);
        Add.field(&mask, .text_color, self.text_color != null);
        Add.field(&mask, .text_font_size, self.font_size != null);
        Add.field(&mask, .text_font_weight, self.font_weight != null);
        return mask;
    }

    /// 将 BoxStyle 非 null 的字段覆盖到 Style 上
    /// ⚠️ **本函数是 void，内部有三处 ensureExtPanic, OOM 下会 abort 整个进程。**
    /// git_diff sidebar sweep 撞到过（applyMountedComponentStyle -> 这里）。
    /// 没有当场改成 fallible 是因为 applyTo 是 BoxStyle 的公共 API、调用点很广，
    /// 改签名要连带改一大批调用方，属于接口级改动。
    /// **欠账登记在此**：要么把它改成 `!void` 并传播，要么让内部三处降级
    /// （corner_radius / shadow 都是纯视觉属性，分配失败保持原值即可）。
    pub fn applyTo(self: BoxStyle, style: *Style, maybe_allocator: ?std.mem.Allocator) void {
        // 布局
        if (self.width) |v| style.width = v;
        if (self.height) |v| style.height = v;
        if (self.direction) |v| style.direction = v;
        if (self.justify) |v| style.justify = v;
        if (self.align_items) |v| style.align_items = v;
        if (self.gap) |v| style.gap = v;
        if (self.padding) |v| style.padding = v;
        if (self.margin) |v| style.margin = v;
        if (self.margin_spec) |v| {
            if (maybe_allocator) |allocator| {
                style.setMarginSpec(allocator, v);
            } else {
                style.margin = v.toPadding();
            }
        }
        if (self.flex) |v| style.flex = v;
        if (self.flex_shrink) |v| style.flex_shrink = v;
        if (self.position) |v| style.position = v;
        if (self.overflow) |v| style.overflow = v;
        if (self.overflow_hidden) |v| style.overflow_hidden = v;
        if (self.display) |v| style.display = v;
        if (self.layout_isolation) |v| style.layout_isolation = v;
        // 视觉
        // Style.background/opacity 字段已删 -> World.paint_state。
        // BoxStyle 仍保留 background/opacity 字段（公开 API 不变）；这两个值
        // 由 builder 在 Node.create 后经 node.setBackgroundRaw/setOpacityRaw
        // 落到 SoA（见 BoxStyle.paintOverride() + builders.applyPaintOverride）。
        if (self.cursor) |v| style.cursor = v;
        if (self.translate_x) |v| style.translate_x = v;
        if (self.translate_y) |v| style.translate_y = v;
        // border: 整体先，细粒度后
        if (self.border) |v| style.border = v;
        if (self.border_color) |v| style.border.color = v;
        if (self.border_width) |v| style.border.setUniformWidth(v);
        if (self.border_top_width) |v| style.border.side_widths[Border.SIDE_TOP] = @max(@as(f32, 0), v);
        if (self.border_right_width) |v| style.border.side_widths[Border.SIDE_RIGHT] = @max(@as(f32, 0), v);
        if (self.border_bottom_width) |v| style.border.side_widths[Border.SIDE_BOTTOM] = @max(@as(f32, 0), v);
        if (self.border_left_width) |v| style.border.side_widths[Border.SIDE_LEFT] = @max(@as(f32, 0), v);
        // ext 字段需要 allocator
        if (maybe_allocator) |allocator| {
            if (self.border_top_color != null or
                self.border_right_color != null or
                self.border_bottom_color != null or
                self.border_left_color != null)
            {
                // 纯视觉属性：分配失败保持原值降级，不 abort 整个进程。
                if (style.ensureExtFallible(allocator)) |ext| {
                    var side = ext.border_side_colors orelse BorderSideColors{};
                    if (self.border_top_color) |v| side.top = v;
                    if (self.border_right_color) |v| side.right = v;
                    if (self.border_bottom_color) |v| side.bottom = v;
                    if (self.border_left_color) |v| side.left = v;
                    ext.border_side_colors = side;
                } else |_| {}
            }
            if (self.corner_radius) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.corner_radius = .{ .all = v };
                } else |_| {}
            }
            if (self.shadow) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.setShadow(v);
                } else |_| {}
            }
            if (self.scale_x) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.scale_x = v;
                } else |_| {}
            }
            if (self.scale_y) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.scale_y = v;
                } else |_| {}
            }
            if (self.rotate) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.rotate = v;
                } else |_| {}
            }
            if (self.transform_origin) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.transform_origin = v;
                } else |_| {}
            }
            if (self.text_color) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.text_color = v;
                } else |_| {}
            }
            if (self.font_size) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.text_font_size = v;
                } else |_| {}
            }
            if (self.font_weight) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.text_font_weight = v;
                } else |_| {}
            }
        }
    }

    /// 转换为 Style（从默认 Style 开始 apply）
    pub fn toStyleFallible(self: BoxStyle, allocator: std.mem.Allocator) !Style {
        var style = Style{};
        // Prepare the sole allocation before applyTo can mutate any fields.
        if (self.margin_spec != null or self.border_top_color != null or
            self.border_right_color != null or self.border_bottom_color != null or
            self.border_left_color != null or self.corner_radius != null or
            self.shadow != null or self.scale_x != null or self.scale_y != null or
            self.rotate != null or self.transform_origin != null or
            self.text_color != null or self.font_size != null or self.font_weight != null)
        {
            _ = try style.ensureExtFallible(allocator);
        }
        self.applyTo(&style, allocator);
        return style;
    }

    pub fn toStyle(self: BoxStyle, maybe_allocator: ?std.mem.Allocator) Style {
        var style = Style{};
        self.applyTo(&style, maybe_allocator);
        return style;
    }

    /// background/opacity 已不在 Style；builder 在 Node.create
    /// 后用本 override 经 setBackgroundRaw/setOpacityRaw 落到 World.paint_state。
    pub const PaintOverride = struct { background: ?Color = null, opacity: ?f32 = null };
    pub fn paintOverride(self: BoxStyle) PaintOverride {
        return .{ .background = self.background, .opacity = self.opacity };
    }

    /// 两个 BoxStyle 合并：other 有值则覆盖 self
    pub fn merge(self: BoxStyle, other: BoxStyle) BoxStyle {
        var result = self;
        if (other.width != null) result.width = other.width;
        if (other.height != null) result.height = other.height;
        if (other.direction != null) result.direction = other.direction;
        if (other.justify != null) result.justify = other.justify;
        if (other.align_items != null) result.align_items = other.align_items;
        if (other.gap != null) result.gap = other.gap;
        if (other.padding != null) result.padding = other.padding;
        if (other.margin != null) result.margin = other.margin;
        if (other.margin_spec != null) result.margin_spec = other.margin_spec;
        if (other.flex != null) result.flex = other.flex;
        if (other.flex_shrink != null) result.flex_shrink = other.flex_shrink;
        if (other.position != null) result.position = other.position;
        if (other.overflow != null) result.overflow = other.overflow;
        if (other.overflow_hidden != null) result.overflow_hidden = other.overflow_hidden;
        if (other.layout_isolation != null) result.layout_isolation = other.layout_isolation;
        if (other.background != null) result.background = other.background;
        if (other.opacity != null) result.opacity = other.opacity;
        if (other.cursor != null) result.cursor = other.cursor;
        if (other.translate_x != null) result.translate_x = other.translate_x;
        if (other.translate_y != null) result.translate_y = other.translate_y;
        if (other.scale_x != null) result.scale_x = other.scale_x;
        if (other.scale_y != null) result.scale_y = other.scale_y;
        if (other.rotate != null) result.rotate = other.rotate;
        if (other.transform_origin != null) result.transform_origin = other.transform_origin;
        if (other.border != null) result.border = other.border;
        if (other.border_color != null) result.border_color = other.border_color;
        if (other.border_width != null) result.border_width = other.border_width;
        if (other.border_top_width != null) result.border_top_width = other.border_top_width;
        if (other.border_right_width != null) result.border_right_width = other.border_right_width;
        if (other.border_bottom_width != null) result.border_bottom_width = other.border_bottom_width;
        if (other.border_left_width != null) result.border_left_width = other.border_left_width;
        if (other.border_top_color != null) result.border_top_color = other.border_top_color;
        if (other.border_right_color != null) result.border_right_color = other.border_right_color;
        if (other.border_bottom_color != null) result.border_bottom_color = other.border_bottom_color;
        if (other.border_left_color != null) result.border_left_color = other.border_left_color;
        if (other.corner_radius != null) result.corner_radius = other.corner_radius;
        if (other.shadow != null) result.shadow = other.shadow;
        if (other.text_color != null) result.text_color = other.text_color;
        if (other.font_size != null) result.font_size = other.font_size;
        if (other.font_weight != null) result.font_weight = other.font_weight;
        return result;
    }

    /// 检查是否所有字段都是 null（空样式）
    pub fn isEmpty(self: BoxStyle) bool {
        return self.width == null and
            self.height == null and
            self.direction == null and
            self.justify == null and
            self.align_items == null and
            self.gap == null and
            self.padding == null and
            self.margin == null and
            self.margin_spec == null and
            self.flex == null and
            self.flex_shrink == null and
            self.position == null and
            self.overflow == null and
            self.overflow_hidden == null and
            self.layout_isolation == null and
            self.background == null and
            self.opacity == null and
            self.cursor == null and
            self.translate_x == null and
            self.translate_y == null and
            self.scale_x == null and
            self.scale_y == null and
            self.rotate == null and
            self.transform_origin == null and
            self.border == null and
            self.border_color == null and
            self.border_width == null and
            self.border_top_width == null and
            self.border_right_width == null and
            self.border_bottom_width == null and
            self.border_left_width == null and
            self.border_top_color == null and
            self.border_right_color == null and
            self.border_bottom_color == null and
            self.border_left_color == null and
            self.corner_radius == null and
            self.shadow == null and
            self.text_color == null and
            self.font_size == null and
            self.font_weight == null;
    }
};

/// 向后兼容别名（已废弃，请使用 BoxStyle）
pub const StyleOverride = BoxStyle;

/// 交互/组件状态快照（从 Signal 系统或组件状态读取）
///
/// 交互态（hovered/pressed/focused）+ 持久语义态（selected/expanded/invalid）。
/// 对标 Panda CSS conditions 的 _hover/_active/_focus/_disabled/_checked/
/// _expanded/_invalid 子集，只收录组件库有真实消费者的条件位。
pub const InteractionState = struct {
    is_hovered: bool = false,
    is_pressed: bool = false,
    is_focused: bool = false,
    is_disabled: bool = false,
    /// 持久选中态。selected 与 checked 合一：同一节点上二者不会共存
    /// （列表行/标签页用 selected 语义，checkbox/radio/switch 用 checked 语义）。
    is_selected: bool = false,
    /// 展开态（accordion item / tree 节点 / 下拉 chevron）。
    is_expanded: bool = false,
    /// 校验失败态（input / textarea / form field）。
    is_invalid: bool = false,
};

// ==================== Style 位域脏标记系统 ====================

/// Style 修改触发的脏标记级别
pub const DirtyLevel = enum {
    /// 无标脏（cursor, tab_index）
    none,
    /// 仅渲染脏（background, border.color, opacity, translate, shadow, gradient, outline, corner_radius, scale）
    render,
    /// 命中/渲染脏（opacity, translate, radius, clip, hit roles 等）
    interaction,
    /// 布局脏（padding, margin, direction, justify, align_items, gap, flex, overflow, position, inset 等）
    layout,
    /// 尺寸脏（width, height，需要父容器重算）
    sizing,

    /// 返回两个级别中更高的
    pub fn max(a: DirtyLevel, b: DirtyLevel) DirtyLevel {
        return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
    }
};

/// Style 可设置的字段名枚举
pub const StyleField = enum {
    // sizing 级别
    width,
    height,
    // layout 级别
    padding,
    margin,
    direction,
    justify,
    align_items,
    gap,
    flex,
    flex_shrink,
    flex_basis,
    flex_wrap,
    overflow,
    overflow_hidden,
    position,
    aspect_ratio,
    grid,
    grid_placement,
    min_width,
    max_width,
    min_height,
    max_height,
    align_self,
    no_cross_stretch,
    sticky_insets,
    inset,
    z_index,
    // render 级别
    background,
    border,
    opacity,
    translate_x,
    translate_y,
    scale_x,
    scale_y,
    rotate,
    transform_origin,
    shadow,
    gradient,
    outline,
    corner_radius,
    hit_shape,
    clip_shape,
    hit_behavior,
    hit_roles,
    overflow_fade,
    will_change_transform,
    will_change_opacity,
    composited_group,
    // render 级别（可继承文本属性）
    text_color,
    text_font_size,
    text_font_weight,
    // none 级别
    cursor,
    tab_index,
    layout_isolation,
};

/// 编译时确定 Style 字段对应的脏标记级别
pub fn styleDirtyLevel(comptime field: StyleField) DirtyLevel {
    return switch (field) {
        .width, .height => .sizing,
        .padding, .margin, .direction, .justify, .align_items, .gap, .flex, .flex_shrink, .flex_basis, .flex_wrap, .overflow, .position, .aspect_ratio, .grid, .grid_placement, .min_width, .max_width, .min_height, .max_height, .align_self, .no_cross_stretch, .sticky_insets, .inset => .layout,
        .border, .opacity, .translate_x, .translate_y, .scale_x, .scale_y, .rotate, .transform_origin, .corner_radius, .overflow_hidden, .z_index, .hit_shape, .clip_shape, .hit_behavior, .hit_roles, .will_change_transform, .will_change_opacity, .composited_group => .interaction,
        .background, .shadow, .gradient, .outline, .overflow_fade, .text_color, .text_font_size, .text_font_weight => .render,
        .tab_index, .layout_isolation => .none,
        .cursor => .interaction,
    };
}

/// 编译时根据字段名字符串确定脏标记级别（供 setStyles 使用）
pub fn styleDirtyLevelByName(comptime name: []const u8) DirtyLevel {
    const field = std.meta.stringToEnum(StyleField, name) orelse @compileError("Unknown Style field: " ++ name);
    return styleDirtyLevel(field);
}

/// 编译时判断是否是 ext 字段（低频，存储在 StyleExt 中）
pub fn isExtField(comptime field: StyleField) bool {
    return switch (field) {
        .shadow, .gradient, .outline, .corner_radius, .scale_x, .scale_y, .rotate, .transform_origin, .flex_basis, .align_self, .no_cross_stretch, .inset, .sticky_insets, .z_index, .tab_index, .aspect_ratio, .grid, .grid_placement, .min_width, .max_width, .min_height, .max_height, .flex_wrap, .hit_shape, .clip_shape, .hit_behavior, .hit_roles, .overflow_fade, .will_change_transform, .will_change_opacity, .composited_group, .text_color, .text_font_size, .text_font_weight => true,
        else => false,
    };
}

/// 编译时获取 Style 字段的类型
pub fn StyleFieldType(comptime field: StyleField) type {
    // background/opacity 已不在 Style（-> World.paint_state）；
    // 保留 StyleField 枚举 + setStyle API，类型在此显式给出。
    if (comptime field == .background) return Color;
    if (comptime field == .opacity) return f32;
    if (comptime isExtField(field)) {
        return @TypeOf(@field(@as(StyleExt, .{}), @tagName(field)));
    }
    return @TypeOf(@field(@as(Style, .{}), @tagName(field)));
}

// ==================== 声明式 Transition ====================

/// 缓动函数（统一使用 animation/easing.zig 的完整集合）
pub const Easing = @import("../animation/easing.zig").Easing;

/// 过渡配置
pub const TransitionSpec = struct {
    duration_ms: f32 = 150,
    easing: Easing = .ease_out_quad,
};

/// 可过渡的属性
pub const TransitionProp = enum(u5) {
    background = 0,
    opacity = 1,
    border_color = 2,
    translate_x = 3,
    translate_y = 4,
    scale_x = 5,
    scale_y = 6,
    rotate = 7,
    corner_radius = 8,
    border_width = 9,
    width = 10,
};

/// 单个过渡槽的运行时状态
pub const TransitionSlot = struct {
    prop: TransitionProp,
    spec: TransitionSpec = .{},
    // 颜色过渡（background, border_color）
    from_color: Color = Color.TRANSPARENT,
    to_color: Color = Color.TRANSPARENT,
    // 标量过渡（opacity, translate_x/y, scale_x/y）
    from_value: f32 = 0,
    to_value: f32 = 0,
    /// 动画开始的绝对时间戳（ms）。progress = (now_ms - start_time_ms) / duration_ms，
    /// 零累积误差。
    start_time_ms: f64 = 0,
    active: bool = false,
    /// 过渡完成时的回调（用于退出动画后销毁节点等）
    on_complete: ?*const fn (*anyopaque) void = null,
    on_complete_ctx: ?*anyopaque = null,
};

/// 过渡槽集合（最多 12 个属性同时过渡）
pub const TransitionSlots = struct {
    slots: [12]TransitionSlot = [_]TransitionSlot{.{ .prop = .background }} ** 12,
    count: u4 = 0,
    any_active: bool = false,

    /// 查找已有 slot 或分配新 slot
    pub fn getOrCreate(self: *TransitionSlots, prop: TransitionProp) ?*TransitionSlot {
        // 查找已有
        for (self.slots[0..self.count]) |*slot| {
            if (slot.prop == prop) return slot;
        }
        // 分配新的
        if (self.count < 12) {
            const slot = &self.slots[self.count];
            slot.* = .{ .prop = prop };
            self.count += 1;
            return slot;
        }
        return null;
    }

    /// 查找已有 slot
    pub fn find(self: *TransitionSlots, prop: TransitionProp) ?*TransitionSlot {
        for (self.slots[0..self.count]) |*slot| {
            if (slot.prop == prop) return slot;
        }
        return null;
    }
};

pub const A11yRole = enum {
    none,
    button,
    checkbox,
    radio,
    textbox,
    switch_role,
    tab,
    tablist,
    dialog,
    alert,
    menu,
    menuitem,
    listbox,
    option,
    progressbar,
    slider,
    heading,
    link,
    img,
    list,
    listitem,
    table,
    tooltip,
    // v0.7 §2.5
    combobox,
    grid,
    gridcell,

    // ── 2026-07-31：补组件 a11y 声明时发现的缺口。a11y/tree.zig 的 Role
    // 早就有这些角色，但组件侧的 A11yRole 没有对应项，于是 Tree/DataTable/
    // Steps 之类根本无法声明自己的语义（只能退化成 button/list，AT 侧就
    // 失去了层级/表格/进度的结构信息）。
    tree,
    treeitem,
    row,
    columnheader,
    rowheader,
    menubar,
    menuitemcheckbox,
    menuitemradio,
    spinbutton,
    status,
    group,
    navigation,
    separator,
    region,
    article,
    application,
    radiogroup,
    textarea,
    searchbox,
    tabpanel,
    alertdialog,
    log,
    paragraph,
    section,
    form,
    main,
    banner,
    contentinfo,
    generic,
};

/// aria-haspopup 值集，ARIA 1.2 spec
pub const HasPopup = enum {
    none,
    menu,
    listbox,
    tree,
    grid,
    dialog,
};

pub const A11yOrientation = enum { undefined, horizontal, vertical };
pub const A11ySortDirection = enum { none, ascending, descending, other };

/// Window-content geometry in logical points with a top-left origin.
pub const A11yRect = struct { x: f32, y: f32, width: f32, height: f32 };

/// Live text-model contract used by platform input methods.
///
/// This deliberately does not reuse `A11yProps.EditableText`: accessibility
/// is a retained, frame-synchronised projection, while NSTextInputClient is a
/// synchronous protocol and may query the document again from inside the same
/// native key event.  Every callback therefore reads the editor's current
/// model directly. Offsets are UTF-8 bytes; platform bridges own conversion to
/// their native units (UTF-16 on AppKit).
pub const TextInputSelection = struct {
    start: u32,
    end: u32,
    caret: u32,
};

pub const TextInputClient = struct {
    context: *anyopaque,
    text_len: *const fn (context: *anyopaque) usize,
    /// Copy exactly `min(out.len, text_len() - start_utf8)` bytes beginning at
    /// `start_utf8` and return the number copied. Implementations must not
    /// mutate the model. The exact-fill rule lets platform bridges stream
    /// Unicode conversion and answer synchronous native range queries without
    /// allocating a complete-document snapshot.
    copy_text: *const fn (context: *anyopaque, start_utf8: usize, out: []u8) usize,
    selection: *const fn (context: *anyopaque) TextInputSelection,
    /// Optional committed-to-model marked projection in copy_text coordinates.
    /// Return false when there is no in-document preedit (overlay-only clients
    /// leave this null). Queried after the preedit handler has returned.
    /// Native sync requires the projected bytes to match its current candidate;
    /// transformed text conservatively keeps the existing native cache.
    marked_range: ?*const fn (context: *anyopaque, start_utf8: *u32, end_utf8: *u32) bool = null,
    set_selection: ?*const fn (context: *anyopaque, start_utf8: u32, end_utf8: u32) bool = null,
    frame_for_range: ?*const fn (context: *anyopaque, start_utf8: u32, end_utf8: u32, out: *A11yRect) bool = null,
    range_at_point: ?*const fn (context: *anyopaque, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool = null,
    secure: bool = false,
};

pub const A11yValueRange = struct {
    now: f32,
    min: f32,
    max: f32,
    context: ?*anyopaque = null,
    set_value: ?*const fn (context: *anyopaque, value: f32) bool = null,
};

pub const A11yProps = struct {
    pub const EditableText = struct {
        context: *anyopaque,
        selection_start: u32,
        selection_end: u32,
        caret: u32,
        /// Visible UTF-8 byte range. Non-scrolling controls use 0..text.len.
        visible_start: u32 = 0,
        visible_end: u32 = std.math.maxInt(u32),
        /// Receives UTF-8 byte offsets. Implementations must clamp to valid
        /// grapheme boundaries and return false without mutating on failure.
        set_selection: *const fn (context: *anyopaque, start_utf8: u32, end_utf8: u32) bool,
        set_value: ?*const fn (context: *anyopaque, value: []const u8) bool = null,
        frame_for_range: ?*const fn (context: *anyopaque, start_utf8: u32, end_utf8: u32, out: *A11yRect) bool = null,
        range_at_point: ?*const fn (context: *anyopaque, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool = null,
    };

    role: A11yRole = .none,
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    identifier: ?[]const u8 = null,
    checked: ?bool = null,
    disabled: bool = false,
    expanded: ?bool = null,
    value_text: ?[]const u8 = null,
    live: ?[]const u8 = null,
    /// Spoken payload for a live-region update. This is intentionally
    /// independent from value_text so status/alert content is not exposed as
    /// an unrelated AXValue.
    live_text: ?[]const u8 = null,
    hidden: bool = false,
    /// aria-haspopup，表明此控件激活时会打开浮层（菜单/对话框等）
    has_popup: HasPopup = .none,

    // ── 2026-07-31：以下字段此前在 A11yProps 里根本不存在，
    // Cx.projectA11yNode 把对应的 a11y State 位**硬编码成 false**，
    // 于是组件即使想声明也无从声明。补齐后投影层一并接通。
    /// aria-selected（listbox option / tab / grid row 的选中态）
    selected: bool = false,
    /// aria-pressed（toggle button 按下态）
    pressed: bool = false,
    /// aria-required（表单必填）
    required: bool = false,
    /// aria-invalid（校验失败）
    invalid: bool = false,
    /// aria-readonly（只读，区别于 disabled）
    readonly: bool = false,
    /// aria-busy（加载中）
    busy: bool = false,
    /// aria-modal（模态对话框）
    modal: bool = false,
    /// aria-multiline（多行文本域）
    multiline: bool = false,
    /// aria-multiselectable（容器支持多选）
    multiselectable: bool = false,
    /// Password/secret input. Native bridges expose a secure text subrole and
    /// must not publish value, selection, or range content.
    secure: bool = false,
    /// aria-indeterminate（三态 checkbox 的中间态）
    indeterminate: bool = false,

    /// aria-valuenow / valuemin / valuemax（slider / progressbar / spinbutton）。
    /// 三者同时为 0 视为"未提供数值"，投影层原样传 0。
    value_now: f32 = 0,
    value_min: f32 = 0,
    value_max: f32 = 0,
    /// Typed contract distinguishes a legitimate all-zero range from an
    /// unpublished value. Legacy fields above remain source-compatible.
    value_range: ?A11yValueRange = null,
    orientation: A11yOrientation = .undefined,
    sort_direction: A11ySortDirection = .none,
    /// Heading/disclosure level is one-based; zero means unspecified.
    level: u16 = 0,
    row_index: u32 = 0,
    row_span: u32 = 1,
    column_index: u32 = 0,
    column_span: u32 = 1,
    /// aria-activedescendant，容器自身 focus 时，
    /// 通过此 element_id_raw 告诉 AT 当前激活的子项。0xFFFFFFFF = 无。
    /// 适用 combobox / listbox / grid 等"虚拟焦点"模式控件。
    active_descendant_element_id: u32 = 0xFFFFFFFF,
    /// Explicit editable-text bridge. A textbox role alone is deliberately
    /// insufficient: null keeps native editable protocols fail-closed.
    editable_text: ?EditableText = null,
};

pub const ElementTag = enum {
    box,
    text,
    image,
    button,
    input,
    scroll,
    list,
    spacer,
    custom,
};

pub const TextWrap = enum {
    none,
    word,
    char,
    newline_only, // 只在 \n 断行，不做宽度折行（用于 code fence）
};

/// 文本在 node 内容宽内的水平对齐（逐视觉行，类 CSS text-align）。
/// 只移动绘制位置，不影响测量 / 折行；宿主自己算光标与命中时用
/// `text_layout.alignLineOffset` 取同一个偏移。
pub const TextAlign = enum(u8) {
    start,
    center,
    end,
};

/// 文本溢出处理方式（仅对单行文本 wrap=.none 生效）
/// 类似 CSS text-overflow，纯视觉优化，不影响布局
pub const TextOverflow = enum {
    clip, // 默认：GPU scissor 硬截断
    ellipsis, // 末尾省略: "building-a-modern-edi…"
    ellipsis_smart, // 智能省略（保留后缀）: "building-a-m…editor.md"
};

/// 文本内子段样式（Rich Text Span）
/// 一个 text node 可包含多个 TextSpan，每段有独立的样式覆盖。
/// null 值表示继承 TextProps 的基础样式。
/// 下划线样式
pub const UnderlineStyle = enum {
    solid,
    dotted,
    dashed,
    wavy,
};

pub const TextSpan = struct {
    start: u32, // content 中的字节偏移
    end: u32,
    color: ?Color = null, // null = 继承 TextProps.color
    font_weight: ?u16 = null, // null = 继承 TextProps.font_weight
    use_italic_font: bool = false,
    use_monospace_font: bool = false, // inline code 用等宽字体
    strikethrough: bool = false,
    bg_color: ?Color = null, // inline code 背景
    /// Inline box 水平 padding，会参与布局/折行/命中，而不只是视觉背景扩展。
    inline_box_padding_left: f32 = 0,
    inline_box_padding_right: f32 = 0,
    /// Inline box 垂直 inset，仅影响背景盒子的绘制，不参与水平布局。
    inline_box_inset_top: f32 = 0,
    inline_box_inset_bottom: f32 = 0,
    inline_box_corner_radius: f32 = 0,
    underline: bool = false,
    underline_color: ?Color = null, // null = 继承 span/text color
    underline_style: UnderlineStyle = .solid,
    /// 下划线相对基线的额外垂直偏移（像素，正值向下）。
    /// 0 = 默认贴在 line 底部上方 2px；波浪线 diagnostic 常用 +1~+2 下沉到 descender 下方。
    underline_offset: f32 = 0,
    /// 下划线粗细（像素）。<= 0 表示 style 对应的默认值：
    ///   solid/dashed/dotted -> 1 / 1 / 1.5
    ///   wavy                -> max(1.0, font_size * 0.12) 由渲染器决定
    underline_thickness: f32 = 0,
};

pub const TextProps = struct {
    content: []const u8 = "",
    color: Color = theme.dark.color.fg_primary,
    font_size: f32 = 14,
    font_weight: u16 = 400,
    /// 字体族 id(render.FontRegistry 的进程内 id)。0 = 用默认族。
    /// ⚠ 存 id 不存族名:text_run 每帧重建,塞 slice 会引入悬垂
    ///   (见 render/font_registry.zig 文件头)。
    font_family: u16 = 0,
    line_height: f32 = 1.4,
    selectable: bool = true,
    wrap: TextWrap = .none,
    max_lines: u16 = 0,
    /// 基线位置比例 (0.0-1.0)，相对于行高
    /// 默认 0.75 适用于大多数拉丁字体；CJK 字体可能需要 0.8
    /// 设为 0 表示使用默认值 0.75
    baseline_ratio: f32 = 0,
    inline_buf: [16]u8 = undefined,
    inline_len: u8 = 0,
    /// 使用符号字体渲染（FontSelector.symbols_font）
    /// 用于 list marker 等需要特殊 Unicode 字符的场景
    use_symbols_font: bool = false,
    /// 使用等宽字体渲染（FontSelector monospace 组）
    use_monospace_font: bool = false,
    /// 使用斜体字体渲染
    use_italic_font: bool = false,
    /// 删除线
    strikethrough: bool = false,
    /// 等宽字体字符宽度（> 0 时启用快速路径：整行一次塑形 + utf8DisplayWidth 计算 span 背景位置）
    monospace_char_width: f32 = 0,
    /// content 是否由框架 allocator 分配（节点销毁 / setText 换内容时由框架释放）。
    /// 坑：`getText -> 改 content 指向应用自己的 buffer -> setText` 时 owned 会跟着
    /// 拷过来仍为 true，节点销毁会 free 应用的 buffer（Invalid free）,
    /// 指向应用 buffer 时必须显式置 `owned = false`，或直接用 `node.setTextContent`。
    owned: bool = false,

    /// 文本溢出处理（仅 wrap=.none 单行文本生效）
    text_overflow: TextOverflow = .clip,

    /// 逐视觉行水平对齐。节点宽由布局决定（`.fit` 宽时行宽 = 节点宽，看不出差别），
    /// 所以居中折行要配 `.grow` / 固定宽。
    text_align: TextAlign = .start,

    /// 右端淡出遮罩宽（px，0 = 关闭；仅 wrap=.none 单行、无 spans 时生效）。
    /// 在可用宽（node 内容宽）的最后 fade_right px 内，glyph alpha 按位置
    /// 线性降到 0，类 CSS mask-image 的文本专用最小实现。与 .clip 搭配
    /// 使用可得到"名字淡出而不是被硬切/省略号"的收尾（浮层控件盖在文字上
    /// 的场景不再需要任何底色板，透明/玻璃背景上天然正确）。
    fade_right: f32 = 0,

    /// Rich text spans（按字节偏移划分的子段样式）
    /// 空 = 单一样式
    spans: []const TextSpan = &.{},
    /// false 时，spans 只影响 paint，不参与文本布局/shape cache。
    spans_affect_layout: bool = true,
    /// spans 数组是否由 allocator 分配（需要在节点销毁时释放）
    spans_owned: bool = false,

    /// 设置内联文本内容（≤ inline_buf.len = 16 字节，零分配）。
    ///
    /// **不截断**：超长返回 error.InlineContentTooLong。曾经静默截到 16 字节,
    /// 调用方传入的 placeholder / 月份标签 / 格式化数字悄悄被砍掉一截。长度不受控的
    /// 内容用 `setContent(allocator, src)`（放得下走 inline，否则 dupe 成 owned）。
    /// 注意：调用后如果 TextProps 被值传递或复制，必须调用 fixupAfterMove
    pub fn setInlineContent(self: *TextProps, src: []const u8) error{InlineContentTooLong}!void {
        if (src.len > self.inline_buf.len) return error.InlineContentTooLong;
        const len: u8 = @intCast(src.len);
        @memcpy(self.inline_buf[0..len], src[0..len]);
        self.inline_len = len;
        self.content = self.inline_buf[0..len];
        // content 已改指自身 inline_buf，不再是堆内存：必须撤掉 owned。
        // 否则 `getText -> setInlineContent -> setText` 换掉一段 owned 堆文本时，
        // 新条目带着 owned=true 指向 inline_buf，节点销毁时 free 它 = Invalid free。
        // 旧堆内存由 ContentTable.setText 按指针守卫释放。
        self.owned = false;
    }

    /// 设置文本内容的唯一通用入口：放得下 inline 就零分配，否则用 `allocator`
    /// dupe 成 owned（节点销毁 / 换文本时由 ContentTable 用 Cx allocator 释放，
    /// 所以 `allocator` 必须是 Cx.allocator）。
    pub fn setContent(self: *TextProps, allocator: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error!void {
        self.setInlineContent(src) catch {
            self.content = try allocator.dupe(u8, src);
            self.inline_len = 0;
            self.owned = true;
        };
    }

    /// 在结构体被 move/copy 后修复 content 指针
    /// 当 inline_len > 0 时，content 可能指向旧地址的 inline_buf，需要重新定位到当前地址
    pub fn fixupAfterMove(self: *TextProps) void {
        if (self.inline_len > 0) {
            self.content = self.inline_buf[0..self.inline_len];
        }
    }
};

pub const ImageProps = struct {
    texture_id: u32,
    tint: Color = Color.WHITE,
};

pub const IconProps = struct {
    icon_id: u16,
    rep: icon_ir.Rep,
    tint: Color = Color.WHITE,
};

/// 事件回调引用，组件回调的统一形态。
///
/// ## 为什么有 payload 变体（2026-07-31）
///
/// 此前组件回调分两轨且**不可互换**：
///   - `?HandlerRef`，无参，只通知"发生了"
///   - `?*const fn (T, *anyopaque) void`，带值，告诉你"变成了什么"
///
/// docs/API_STABILITY.md 曾声称"已统一为 HandlerRef、Input 是特例"，实测
/// 是 16 vs 17 的对半分裂。而且**直接把带值那组迁到无参 HandlerRef 会静默
/// 丢掉 payload**，调用方照常编译，值没了，是最难查的一类回归。
///
/// 所以先给 HandlerRef 加上可选的 payload 通道，再让两轨并轨：
///   - `.callback` 仍是无参签名，54 处既有 `.invoke()` 调用点零改动；
///   - `.payload_callback` 是可选的带值签名，由 `invokeWith*` 触发。
///
/// payload 只支持 bool / []const u8 两种，实测全仓 17 个带值回调的载荷
/// 就这两类（bool: checkbox/switch/accordion；[]const u8: input/textarea/
/// tabs/radio）。不做泛型是刻意的：HandlerRef 存在 Node 里，泛型会让
/// EventHandlers 变成 comptime 类型参数，污染整棵树的类型。
///
/// ⚠ 组件作者：**同时设置两者时 payload 版本优先**。只设 callback 的
/// 老代码行为不变。
pub const HandlerRef = struct {
    callback: *const fn (*anyopaque) void,
    context: *anyopaque,
    /// 可选的带值回调。非 null 时 invokeWithBool/Str 走这条，否则退化为无参。
    payload_callback: ?PayloadCallback = null,

    pub const PayloadCallback = union(enum) {
        boolean: *const fn (bool, *anyopaque) void,
        string: *const fn ([]const u8, *anyopaque) void,
        drop: *const fn (DropPayload, *anyopaque) void,
    };

    /// drop 回调的完整 payload：换行分隔的 paths + 落点坐标（window 坐标系，
    /// 与 DragEvent.x/y 同源）。按落点摆放文件（画布拖入）需要坐标,
    /// 只给 paths 时宿主只能退回全局 .drag 事件自己记位置（下游回归）。
    pub const DropPayload = struct {
        /// 换行分隔的文件路径 / URL 列表；仅回调执行期间有效，需留存自行 dupe。
        /// 平台拖入时内容由外部进程控制，必须按不可信输入处理。
        paths: []const u8,
        x: f32,
        y: f32,
        /// 0=none, 1=newline-separated file/URL list, 2=text, 3=internal.
        payload_kind: u8 = 0,
        /// true 表示后端因容量上限拒绝了整个 payload，`paths` 为空。
        payload_truncated: bool = false,
        payload_is_untrusted: bool = true,
    };

    pub fn invoke(self: HandlerRef) void {
        self.callback(self.context);
    }

    /// 带 bool 值触发。handler 若注册的是无参版本，退化为无参调用
    /// （不丢事件，只是拿不到值），这样组件可以无条件调 invokeWithBool，
    /// 不必关心调用方注册了哪种。
    pub fn invokeWithBool(self: HandlerRef, value: bool) void {
        if (self.payload_callback) |pc| switch (pc) {
            .boolean => |f| return f(value, self.context),
            .drop => {},
            .string => {},
        };
        self.callback(self.context);
    }

    /// 带字符串值触发。语义同 invokeWithBool。
    /// ⚠ slice 生命周期：只保证**回调执行期间**有效（通常指向组件内部
    /// buffer）。需要留存请自行 dupe。
    pub fn invokeWithStr(self: HandlerRef, value: []const u8) void {
        if (self.payload_callback) |pc| switch (pc) {
            .string => |f| return f(value, self.context),
            .drop => |f| return f(.{ .paths = value, .x = 0, .y = 0 }, self.context),
            .boolean => {},
        };
        self.callback(self.context);
    }

    /// 带完整 drop payload（paths + 落点坐标）触发。注册的是 string 版本时
    /// 退化为仅 paths；无参版本退化为无参，同 invokeWithBool 的降级合同。
    pub fn invokeWithDrop(self: HandlerRef, payload: DropPayload) void {
        if (self.payload_callback) |pc| switch (pc) {
            .drop => |f| return f(payload, self.context),
            .string => |f| return f(payload.paths, self.context),
            .boolean => {},
        };
        self.callback(self.context);
    }
};

pub const GenericEventCallback = *const fn (event: Event, context: ?*anyopaque) EventResult;
pub const EventCallback = *const fn (ctx: *anyopaque) void;
pub const KeyEventCallback = *const fn (KeyCode, Modifiers, ?*anyopaque) EventResult;
pub const ScrollEventCallback = *const fn (events_mod.ScrollEvent, ?*anyopaque) EventResult;

pub const ScrollDirectionHint = enum(u8) {
    vertical,
    horizontal,
    both,
};

pub const EventHandlers = struct {
    on_click: ?HandlerRef = null,
    on_hover: ?HandlerRef = null,
    on_leave: ?HandlerRef = null,
    on_focus: ?HandlerRef = null,
    on_blur: ?HandlerRef = null,
    on_event: ?GenericEventCallback = null,
    /// Phase 6: capture 阶段事件处理器（root -> target 路径下行调用）。
    /// 默认 null = 该节点不参与 capture phase 派发，零开销跳过。
    /// 用于：focus trap、scroll lock、手势仲裁等需要在祖先拦截的场景。
    on_event_capture: ?GenericEventCallback = null,
    event_context: ?*anyopaque = null,
    /// 滚轮事件专用处理器（与 on_key_down 对称）。
    /// on_event 返回 ignored 或不存在时 fallthrough 到这里；context 用 event_context。
    on_scroll: ?ScrollEventCallback = null,
    scroll_direction_hint: ?ScrollDirectionHint = null,
    on_key_down: ?KeyEventCallback = null,
    on_key_up: ?KeyEventCallback = null,
    key_context: ?*anyopaque = null,
    on_action: ?actions_mod.ActionHandler = null,
    action_context: ?*anyopaque = null,

    /// 拖放：文件拖入本节点边界（drag.entered）。用于悬停高亮等反馈。
    /// 非 null 即把本节点标记为 drop target（参与 pointer 命中）。
    on_drag_enter: ?HandlerRef = null,
    /// 拖放：文件拖离本节点边界（drag.exited）。
    on_drag_leave: ?HandlerRef = null,
    /// 拖放：文件在本节点上放下（drag.dropped）。
    /// 用 `Cx.strHandlerFrom` 注册可拿到换行分隔的路径列表；
    /// ⚠ slice 只在回调执行期间有效，需留存请自行 dupe。
    on_drop: ?HandlerRef = null,
};

pub const DebugSignalKind = enum {
    bool,
    @"opaque",
};

pub const DebugSignalRef = struct {
    ptr: *anyopaque,
    label: []const u8,
    kind: DebugSignalKind,
};

test "Transform2D.transformRect uses four-corner AABB for rotation" {
    const t = Transform2D.rotation(std.math.pi / 4.0, 50, 25);
    const rect = t.transformRect(ComputedRect.init(0, 0, 100, 50));

    try std.testing.expect(rect.w > 100);
    try std.testing.expect(rect.h > 50);
}

test "Transform2D invert round-trips transformed points" {
    const t = Transform2D.translation(40, -12)
        .mul(Transform2D.scale(1.5, 0.75, 10, 20))
        .mul(Transform2D.rotation(0.3, 10, 20));
    const inv = t.invert();
    const p = t.applyPoint(18, 42);
    const round_trip = inv.applyPoint(p.x, p.y);

    try std.testing.expectApproxEqAbs(@as(f32, 18), round_trip.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 42), round_trip.y, 0.001);
}

test "TransformOrigin resolves percent and px values" {
    const centered = TransformOrigin.centered().resolve(200, 80);
    try std.testing.expectApproxEqAbs(@as(f32, 100), centered.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), centered.y, 0.001);

    const custom = (TransformOrigin{
        .x = .{ .px = 12 },
        .y = .{ .percent = 0.25 },
    }).resolve(200, 80);
    try std.testing.expectApproxEqAbs(@as(f32, 12), custom.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), custom.y, 0.001);
}

test "BoxStyle applies transform fields into StyleExt" {
    const style = (BoxStyle{
        .scale_x = 1.2,
        .scale_y = 0.8,
        .rotate = 0.4,
        .transform_origin = .{
            .x = .{ .px = 12 },
            .y = .{ .percent = 0.25 },
        },
    }).toStyle(std.testing.allocator);
    defer if (style.ext) |ext| std.testing.allocator.destroy(ext);

    try std.testing.expectApproxEqAbs(@as(f32, 1.2), style.scale_x(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), style.scale_y(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), style.rotate(), 0.001);
    const origin = style.transform_origin().resolve(200, 80);
    try std.testing.expectApproxEqAbs(@as(f32, 12), origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), origin.y, 0.001);
}

test "BoxStyle styleFieldMask reports only declared aggregate fields" {
    const mask = (BoxStyle{
        .padding = Padding.all(8),
        .background = Color.BLACK,
        .border_left_width = 2,
    }).styleFieldMask();
    const has = struct {
        fn field(bits: u64, f: StyleField) bool {
            return (bits & (@as(u64, 1) << @intFromEnum(f))) != 0;
        }
    }.field;

    try std.testing.expect(has(mask, .padding));
    try std.testing.expect(has(mask, .background));
    try std.testing.expect(has(mask, .border));
    try std.testing.expect(!has(mask, .gap));
    try std.testing.expect(!has(mask, .shadow));
}

test "Transform2D extractScale axes survive rotation" {
    const t = Transform2D.scale(1.5, 0.75, 10, 20)
        .mul(Transform2D.rotation(0.3, 10, 20));

    try std.testing.expectApproxEqAbs(@as(f32, 1.5), t.extractScaleX(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), t.extractScaleY(), 0.001);
}

test "Transform2D decompose and compose round-trip affine state" {
    const source = (DecomposedTransform2D{
        .translate = .{ 40, -12 },
        .scale = .{ 1.5, 0.75 },
        .rotate = 0.3,
        .skew_x = 0.2,
    }).compose();
    const round_trip = source.decompose().compose();

    try std.testing.expectApproxEqAbs(source.a, round_trip.a, 0.001);
    try std.testing.expectApproxEqAbs(source.b, round_trip.b, 0.001);
    try std.testing.expectApproxEqAbs(source.c, round_trip.c, 0.001);
    try std.testing.expectApproxEqAbs(source.d, round_trip.d, 0.001);
    try std.testing.expectApproxEqAbs(source.tx, round_trip.tx, 0.001);
    try std.testing.expectApproxEqAbs(source.ty, round_trip.ty, 0.001);
}

test "Transform2D blend uses shortest rotation path" {
    const from = (DecomposedTransform2D{
        .rotate = std.math.pi - 0.1,
    }).compose();
    const to = (DecomposedTransform2D{
        .rotate = -std.math.pi + 0.1,
    }).compose();
    const blended = Transform2D.blend(from, to, 0.5).decompose();

    try std.testing.expect(@abs(blended.rotate) > std.math.pi - 0.2);
}

test "TextProps.setInlineContent 撤掉 owned（content 已改指 inline_buf）" {
    const heap = try std.testing.allocator.dupe(u8, "a heap owned text longer than sixteen");
    defer std.testing.allocator.free(heap);
    var t: TextProps = .{ .content = heap, .owned = true };
    try t.setInlineContent("short");
    try std.testing.expect(!t.owned);
    try std.testing.expectEqualStrings("short", t.content);
}

test "TextProps.setInlineContent 超长报错而非静默截断" {
    var t: TextProps = .{};
    try t.setInlineContent("exactly 16 bytes");
    try std.testing.expectEqualStrings("exactly 16 bytes", t.content);
    try std.testing.expectError(error.InlineContentTooLong, t.setInlineContent("seventeen bytes!!"));
    // 失败时不改动已有内容
    try std.testing.expectEqualStrings("exactly 16 bytes", t.content);
}

test "TextProps.setContent：短文本走 inline 零分配，长文本完整 dupe 成 owned" {
    const alloc = std.testing.allocator;
    var t: TextProps = .{};
    try t.setContent(alloc, "short");
    try std.testing.expect(!t.owned);
    try std.testing.expectEqualStrings("short", t.content);

    const long = "A very long placeholder that must not be truncated";
    try t.setContent(alloc, long);
    defer if (t.owned) alloc.free(t.content);
    try std.testing.expect(t.owned);
    try std.testing.expectEqualStrings(long, t.content);
}
