const std = @import("std");
const a11y_preferences = @import("../a11y/preferences.zig");
const a11y_collection = @import("../a11y/collection.zig");
const events_mod = @import("../events.zig");
const actions_mod = @import("../actions.zig");
const icon_ir = @import("icon_ir");
pub const theme = @import("../theme.zig");

pub const Event = events_mod.Event;
pub const EventResult = events_mod.EventResult;
pub const KeyCode = events_mod.KeyCode;
pub const Modifiers = events_mod.Modifiers;

/// Two-dimensional size.
pub const Size = struct {
    width: f32,
    height: f32,

    pub const ZERO = Size{ .width = 0, .height = 0 };

    pub fn init(width: f32, height: f32) Size {
        return .{ .width = width, .height = height };
    }
};

/// Computed rectangle area.
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

/// 2D affine transform. **All fields f32 (including tx/ty)**.
///
/// Infinite-canvas apps at 1e6 world coords + deep zoom (>1600%) note: f32 mantissa can't
/// distinguish adjacent world coords (convert f32 then transform -> ~1px quantization error,
/// appears as jitter/sticking). Must offset by viewport origin in own f64, convert viewport-local
/// coords to f32, subtract in f64 first -> always zero error.
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

    /// Per-corner radii [TL, TR, BR, BL] of a rect in this transform's source frame, re-indexed
    /// by the corner each lands on in the target frame. Axis-aligned linear parts (scale, mirror,
    /// quarter turns) permute the corners exactly; any other rotation returns the radii unchanged,
    /// where the clip rect itself is already an axis-aligned bounding approximation.
    pub fn orientCornerRadii(self: Transform2D, radii: [4]f32) [4]f32 {
        const extent = @abs(self.a) + @abs(self.b) + @abs(self.c) + @abs(self.d);
        if (!(extent > 0) or !std.math.isFinite(extent)) return radii;
        const eps = extent * 1e-4;
        const diagonal = @abs(self.b) <= eps and @abs(self.c) <= eps;
        const anti_diagonal = @abs(self.a) <= eps and @abs(self.d) <= eps;
        if (!diagonal and !anti_diagonal) return radii;
        const corner_signs = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
        var out = radii;
        for (corner_signs, radii) |s, radius| {
            const left = self.a * s[0] + self.c * s[1] < 0;
            const top = self.b * s[0] + self.d * s[1] < 0;
            const corner: usize = if (top) (if (left) 0 else 1) else (if (left) 3 else 2);
            out[corner] = radius;
        }
        return out;
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

/// Padding value.
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

/// Margin value. Like CSS, default is length; `auto` via auto_mask. Type for declarative style
/// input and debug display; Style keeps compact margin values internally, auto marks separate in
/// StyleExt to avoid bloating hot layout fields.
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

/// Numeric keywords preserve the existing f32 flex_basis API (including explicit zero).
pub const FlexBasis = struct {
    pub const auto: f32 = -1;
    pub const content: f32 = -2;
    /// Reflected by the YSS schema generator; numbers remain accepted separately.
    pub const keywords = [_][]const u8{ "auto", "content" };
};

/// Size definition - 4 modes supported.
pub const Sizing = union(enum) {
    /// Fixed pixels.
    px: f32,
    /// Fill available space (flex grow), optional min/max.
    grow: SizingMinMax,
    /// Fit content size, optional min/max.
    fit: SizingMinMax,
    /// Percentage.
    percent: f32,

    pub const SizingMinMax = struct {
        /// Negative means CSS automatic minimum on a flex main axis; 0 is explicit.
        min: f32 = -1,
        max: f32 = std.math.inf(f32),
    };

    /// Fixed-pixel size. Supports decl literal: `.width = .fixed(120)`.
    pub fn fixed(v: f32) Sizing {
        return .{ .px = v };
    }

    /// Fill available space (equivalent `.{ .grow = .{} }`). Supports decl literal: `.width =
    /// .fill()`.
    pub fn fill() Sizing {
        return .{ .grow = .{} };
    }

    /// Percentage size. Supports decl literal: `.width = .pct(50)`.
    pub fn pct(v: f32) Sizing {
        return .{ .percent = v };
    }
};

/// Layout constraint (passed to children in Measure phase). Like CSS available size + min/max
/// constraints.
pub const LayoutConstraints = struct {
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),
    /// Known exact width (non-null -> child uses this, no intrinsic calc).
    definite_width: ?f32 = null,
    /// Known exact height.
    definite_height: ?f32 = null,

    /// Create constraint with known width and height.
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

/// Flex direction.
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

/// Main-axis alignment.
pub const JustifyContent = enum {
    start,
    end,
    center,
    space_between,
    space_around,
    space_evenly,
};

/// Cross-axis alignment.
pub const AlignItems = enum {
    start,
    end,
    center,
    stretch,
    baseline,
    first_baseline,
};

/// Packing flex lines; normal has the CSS stretch behavior.
pub const AlignContent = enum { normal, start, end, center, stretch, space_between, space_around, space_evenly };

/// Flex wrapping.
pub const FlexWrap = enum {
    no_wrap,
    wrap,
    wrap_reverse,
};

pub const Justify = JustifyContent;
pub const Alignment = AlignItems;

/// Color (RGBA).
pub const Color = @import("zenit_style_values").Color;

pub const ThemeTokens = theme.ThemeTokens;
pub const ColorScheme = theme.ColorScheme;

/// Gradient spread mode. Controls behavior when gradient t outside [0,1] (CSS background-repeat /
/// SVG spreadMethod).
pub const GradientExtendMode = enum {
    pad, // Clamp to edge color (CSS default).
    repeat, // Repeat (CSS repeat / SVG repeat).
    reflect, // Mirror reflection (CSS reflect / SVG reflect).
};

/// Gradient direction.
pub const GradientDirection = enum {
    horizontal,
    vertical,
    diagonal,
    radial,
    conic,
};

/// SVG/CSS composite blend mode (Opacity Layer blend_mode param). Corresponds to CSS mix-blend-mode
/// / SVG feBlend.
pub const BlendMode = enum {
    normal, // Standard SrcOver (default).
    multiply, // Multiply darken.
    screen, // Screen lighten.
    overlay, // Overlay: contrast boost (bright brighter, dark darker).
    darken, // Darken: take darker value.
    lighten, // Lighten: take lighter value.
    color_dodge, // Color dodge: brighten (denominator 1-src).
    color_burn, // Color burn: darken (denominator src).
    hard_light, // Hard light: strong light (like Overlay, src-dominant).
    soft_light, // Soft light: low-contrast Overlay.
    difference, // Difference: absolute difference.
    exclusion, // Exclusion: low-contrast Difference.
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
    /// Per-corner radii [TL, TR, BR, BL] (attached group items: rounded outer, square inner).
    rounded_corners: [4]f32,
    circle,
    ellipse,
    ring_arc: RingArcHitSpec,
    path: PathShapeSpec,
    custom,
};

/// Node **self paint shape** (background/border SDF). Unlike `ClipShapeSpec`: that's clip mask,
/// clips content not stroke; this replaces fill/stroke distance field itself.
///
/// Default `rounded_rect` = historical (corner_radius decides corners). `ellipse` inscribed to node
/// box (half-axes w/2, h/2); corner_radius ignored.
pub const ShapeSpec = enum {
    rounded_rect,
    ellipse,
};

pub const ClipShapeSpec = union(enum) {
    auto,
    none,
    rect,
    rounded_rect: f32,
    /// Per-corner radii [TL, TR, BR, BL] (attached group items: rounded outer, square inner).
    /// `.auto` resolves to this for non-uniform `corner_radius`, matching `HitShapeSpec`.
    rounded_corners: [4]f32,
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

/// Resolved hit role (all three roles finalized). Consumer sees only this type.
pub const HitRoles = packed struct(u4) {
    pointer: bool = false,
    scroll: bool = false,
    inspect: bool = true,
    window_chrome: bool = false,

    pub fn any(self: HitRoles) bool {
        return self.pointer or self.scroll or self.inspect or self.window_chrome;
    }
};

/// `style.hit_roles` override type: **three-state per role**, null = use framework default.
///
/// Deliberate != `HitRoles` (bool struct): `.{ .pointer = true }` resets unmentioned
/// `scroll`/`inspect` to field defaults, caller wants 'add one role' but actually resets the rest
/// (inspect default true -> silent false -> can't select in devtools). Three-state makes 'override
/// just this one' expressible.
pub const HitRolesOverride = struct {
    pointer: ?bool = null,
    scroll: ?bool = null,
    inspect: ?bool = null,

    /// Overlay override onto inferred default; unspecified roles preserved.
    pub fn apply(self: HitRolesOverride, base: HitRoles) HitRoles {
        return .{
            .pointer = self.pointer orelse base.pointer,
            .scroll = self.scroll orelse base.scroll,
            .inspect = self.inspect orelse base.inspect,
            .window_chrome = base.window_chrome,
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
    /// Explicit decorative inset border; maps to an inset shadow/pseudo-element.
    /// Default false: border consumes space inside the border-box.
    overlay: bool = false,
    width: f32 = 0,
    color: Color = Color.TRANSPARENT,
    radius: f32 = 0,
    /// Override by edge width (default -1 = use width). Order: top, right, bottom, left.
    side_widths: [4]f32 = .{ -1, -1, -1, -1 },

    pub const SIDE_TOP: usize = 0;
    pub const SIDE_RIGHT: usize = 1;
    pub const SIDE_BOTTOM: usize = 2;
    pub const SIDE_LEFT: usize = 3;

    /// Resolve to four-edge widths (top, right, bottom, left).
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

pub const Shadow = @import("zenit_style_values").Shadow;

/// Max outer shadow layers (CSS multi box-shadow; first item topmost).
pub const max_shadows = 4;

/// Multi-layer inset shadow type (fixed, for BoxStyle.inset_shadows). `ui.InsetShadowList.of(&.{ a,
/// b })`.
pub const InsetShadowList = struct {
    items: [3]InsetShadow = @as([3]InsetShadow, @splat(.{})),
    len: u8 = 0,

    pub fn of(list: []const InsetShadow) InsetShadowList {
        var out = InsetShadowList{};
        const n = @min(list.len, out.items.len);
        for (list[0..n], 0..) |s, i| out.items[i] = s;
        out.len = @intCast(n);
        return out;
    }
};

/// Multi-layer outer shadow type (fixed, value-storable, for BoxStyle.shadows).
/// `ui.ShadowList.of(&.{ near, far })`.
pub const ShadowList = struct {
    items: [max_shadows]Shadow = @as([max_shadows]Shadow, @splat(.{})),
    len: u8 = 0,

    pub fn of(list: []const Shadow) ShadowList {
        var out = ShadowList{};
        const n = @min(list.len, max_shadows);
        for (list[0..n], 0..) |s, i| out.items[i] = s;
        out.len = @intCast(n);
        return out;
    }
};

pub const Gradient = struct {
    from: Color,
    to: Color,
    direction: GradientDirection = .vertical,
};

/// Multi-color gradient stop.
pub const GradientStop = struct {
    color: Color,
    position: f32, // [0.0, 1.0]
};

/// Multi-color gradient (max 16 stops, no banding). Static array avoids alloc and lifetime mgmt:
/// stops[0..stop_count] is valid.
pub const MultiGradient = struct {
    stops: [16]GradientStop = @as([16]GradientStop, @splat(.{ .color = Color.rgba(0, 0, 0, 0), .position = 0 })),
    stop_count: u8 = 0,
    direction: GradientDirection = .vertical,
    /// Radial gradient center (proportion of node width/height, can exceed [0,1], like CSS `at 12%
    /// -10%`).
    radial_center: [2]f32 = .{ 0.5, 0.5 },
    /// Radial gradient ellipse radius (proportion of node width/height, CSS `radial-gradient(120%
    /// 100% ...)`). Default 0.5 x 0.5 = inscribed ellipse (historic behavior).
    radial_radius: [2]f32 = .{ 0.5, 0.5 },

    /// Construct from slice (compile/runtime both, max 16).
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

/// Procedural noise params.
pub const NoiseParams = struct {
    mode: NoiseMode = .film_grain,
    scale: f32 = 2.0, // Logical pixels, Value Noise grid spacing.
    intensity: f32 = 0.04, // Mix intensity [0..1].
    seed: u8 = 0,
};

/// Noise mode (corresponds sdf_renderer.zig NoiseMode).
pub const NoiseMode = enum(u8) {
    none = 0,
    value = 1,
    film_grain = 2,
};

/// Inset shadow.
pub const InsetShadow = struct {
    color: Color = Color.rgba(0, 0, 0, 80),
    blur: f32 = 8,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

/// Overflow fade mask edge selection.
pub const FadeEdges = packed struct(u4) {
    top: bool = true,
    bottom: bool = true,
    left: bool = true,
    right: bool = true,
};

/// Overflow container gradient-fade mask on edges when content overflows. Stacks gradient rect over
/// overflow_hidden content, base container color (solid end) to transparent (fade end), visual like
/// CSS mask-image.
pub const OverflowFade = struct {
    /// Gradient area size (px).
    size: f32 = 32,
    /// Solid-end color, null = use container background.
    color: ?Color = null,
    /// Which edges enable gradient.
    edges: FadeEdges = .{},
};

pub const CornerRadius = union(enum) {
    all: f32,
    each: [4]f32, // TL, TR, BR, BL

    pub fn uniform(r: f32) CornerRadius {
        return .{ .all = r };
    }

    /// Return unified corner radius (max of four).
    pub fn resolve(self: CornerRadius) f32 {
        return switch (self) {
            .all => |v| v,
            .each => |e| @max(@max(e[0], e[1]), @max(e[2], e[3])),
        };
    }

    /// Return four-corner radii [TL, TR, BR, BL].
    pub fn resolve4(self: CornerRadius) [4]f32 {
        return switch (self) {
            .all => |v| .{ v, v, v, v },
            .each => |e| e,
        };
    }
};

/// CSS display subset. `.none`: node + subtree skip layout (no space, no gap), no paint, no
/// hit/focus/a11y; node/state live; `.flex` restores (unlike unmount).
pub const Display = enum(u1) {
    flex,
    none,
};

pub const Position = enum {
    relative,
    absolute,
    sticky,
    static,
};

/// CSS inset value (top/right/bottom/left).
pub const InsetValue = union(enum) {
    /// Unconstrained (CSS auto).
    auto,
    /// Absolute pixel offset.
    px: f32,
    /// Percentage relative to containing block.
    percent: f32,

    /// Resolve to absolute value. auto -> null.
    pub fn resolve(self: InsetValue, containing_size: f32) ?f32 {
        return switch (self) {
            .auto => null,
            .px => |v| v,
            .percent => |p| containing_size * p / 100.0,
        };
    }
};

/// CSS inset config. Static ignores inset; relative offsets the flow box.
pub const Inset = struct {
    top: InsetValue = .auto,
    right: InsetValue = .auto,
    bottom: InsetValue = .auto,
    left: InsetValue = .auto,
};

/// CSS overflow property.
pub const Overflow = enum {
    /// Content can overflow (default).
    visible,
    /// Clip overflow (no scrollbar).
    hidden,
    /// Always show scrollbar.
    scroll,
    /// Show scrollbar only if overflow.
    auto,

    /// Clips overflow (hidden/scroll/auto all clip).
    pub fn clips(self: Overflow) bool {
        return self != .visible;
    }

    /// Scrollable (scroll/auto).
    pub fn scrollable(self: Overflow) bool {
        return self == .scroll or self == .auto;
    }
};

/// Sticky positioning inset config (top/left/bottom/right like CSS). Sticky on axis only if inset
/// value non-null.
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

/// Mouse cursor shape (CSS cursor-like). Set via node.style.cursor; framework auto-applies on
/// hover.
pub const CursorShape = enum(u8) {
    /// Inherit parent cursor (default, CSS inherit).
    inherit,
    /// Default arrow cursor (CSS: default).
    default,
    /// Pointing finger, indicates clickable (CSS: pointer).
    pointer,
    /// I-beam text cursor (CSS: text).
    text,
    /// Crosshair (CSS: crosshair).
    crosshair,
    /// Move cursor (CSS: move).
    move,
    /// No-operation cursor (CSS: not-allowed).
    not_allowed,
    /// Grab hand (CSS: grab).
    grab,
    /// Grabbing hand (CSS: grabbing).
    grabbing,
    /// Horizontal resize (CSS: ew-resize).
    ew_resize,
    /// Vertical resize (CSS: ns-resize).
    ns_resize,
    /// NW-SE resize (CSS: nwse-resize).
    nwse_resize,
    /// NE-SW resize (CSS: nesw-resize).
    nesw_resize,
    /// Column resize (CSS: col-resize).
    col_resize,
    /// Row resize (CSS: row-resize).
    row_resize,
    /// Wait (CSS: wait).
    wait,
    /// Progress (CSS: progress).
    progress,
    /// Help (CSS: help).
    help,
    /// Hidden cursor (CSS: none).
    none,
    /// Custom bitmap cursor: content (bitmap + hotspot) activated by `Cx.setCustomCursor`;
    /// node/override only write this shape; fallback to `Cx.custom_cursor_fallback` (default
    /// crosshair) if backend doesn't support bitmap. Append at enum end: 1..18 one-to-one with
    /// native switch.
    custom,
    /// Stop framework cursor writes; a native/platform view owns presentation.
    uncontrolled,
};

/// Grid track size definition (like CSS grid-template-columns/rows values).
pub const GridTrackSize = union(enum) {
    px: f32, // Fixed pixels.
    fr: f32, // Flexible ratio (CSS fr unit).
    auto, // minmax(auto, max-content), stretched by normal content alignment.
    minmax: struct { min: Minimum = .auto, max: Maximum = .auto },

    pub const Minimum = union(enum) { px: f32, auto };
    pub const Maximum = union(enum) { px: f32, fr: f32, auto };
};

/// Grid container config (pointer-mounted on Style, Grid containers only).
pub const GridConfig = struct {
    columns: [MAX_TRACKS]GridTrackSize = undefined,
    column_count: u8 = 0,
    rows: [MAX_TRACKS]GridTrackSize = undefined,
    row_count: u8 = 0,
    column_gap: f32 = 0,
    row_gap: f32 = 0,

    pub const MAX_TRACKS = 16;
};

/// Grid child placement position.
pub const GridPlacement = struct {
    col_start: u8 = 0, // 1-based, 0 = auto.
    col_span: u8 = 1,
    row_start: u8 = 0, // 1-based, 0 = auto.
    row_span: u8 = 1,
};

/// Lens warp of a composited subtree (`StyleExt.content_warp`): the composite samples the
/// subtree's surface shifted radially from the rect centre, by `cap` px across the rounded ends
/// and `edge` px across the long edges (positive = toward the centre, the rim magnifies),
/// fading to zero from `fade_start` over `fade_width` px inside the contour. Native iOS tab
/// bar: the lifted selection shows a `_UIPortalView` of the bar content through a
/// displacement map; the portal smears far more at the caps than the backdrop does.
pub const ContentWarp = extern struct {
    cap: f32 = 0,
    edge: f32 = 0,
    fade_start: f32 = 0,
    fade_width: f32 = 1,
};

pub const Style = struct {
    // -- High-freq inline fields (~80 bytes) --
    // background / opacity removed -> World.paint_state SoA.
    // Access via Node.getBackground/setBackgroundRaw (standalone fallback for mock).
    border: Border = .{},
    padding: Padding = Padding.ZERO,
    direction: Direction = .column,
    justify: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    align_content: AlignContent = .normal,
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

    // -- Low-freq fields (allocated on-demand, most nodes null -> ~0 bytes) --
    ext: ?*StyleExt = null,

    // -- Accessor methods (read-only, return ext value or default) --

    const default_ext = StyleExt{};

    pub inline fn getExt(self: *const Style) *const StyleExt {
        return if (self.ext) |e| e else &default_ext;
    }

    /// Return first outer shadow (null if none).
    pub inline fn shadow(self: *const Style) ?Shadow {
        const e = self.getExt();
        return if (e.shadow_count > 0) e.shadows[0] else null;
    }

    /// Return all outer shadow slice (0~max_shadows count).
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
    /// Border-box to content-box insets, shared by layout and text paint.
    pub fn contentInsets(self: *const Style) Padding {
        const b = if (self.border.overlay) [4]f32{ 0, 0, 0, 0 } else self.border.resolvedWidths();
        return .{ .top = self.padding.top + b[0], .right = self.padding.right + b[1], .bottom = self.padding.bottom + b[2], .left = self.padding.left + b[3] };
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
        return @max(0, self.getExt().min_width);
    }
    pub inline fn max_width(self: *const Style) f32 {
        return self.getExt().max_width;
    }
    pub inline fn min_height(self: *const Style) f32 {
        return @max(0, self.getExt().min_height);
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
    /// Get glass params (null = no glass effect).
    pub inline fn glass_params(self: *const Style) ?GlassParams {
        return self.getExt().glass;
    }
    /// Backdrop blur radius (logical pixels, 0 = no blur), unpacked from glass params.
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
    /// Inset shadows layer 2+ (max 2 layers).
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
    pub inline fn contentWarp(self: *const Style) ?ContentWarp {
        return self.getExt().content_warp;
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
    /// Fallible version: OOM returns error (not abort) on constructor paths with error channel.
    pub fn setMarginSpecFallible(self: *Style, allocator: std.mem.Allocator, margin: Margin) !void {
        (try self.ensureExtFallible(allocator)).margin_auto_mask = margin.auto_mask;
        self.margin = margin.toPadding();
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

    // -- Inherited text property accessors --
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

    /// Return four-corner radii [TL, TR, BR, BL].
    pub fn effectiveRadii(self: *const Style) [4]f32 {
        if (self.corner_radius()) |cr| return cr.resolve4();
        const r = self.border.radius;
        return .{ r, r, r, r };
    }

    // Compile-time size check: high-freq inline fields should be <= 128 bytes.
    comptime {
        if (@sizeOf(Style) > 128) @compileError("Style too large");
    }

    /// Warning: **frozen; don't use in new code.** OOM panics (abort is worst for an editor: user
    /// data lost).
    /// New code uses `ensureExtFallible` and propagates errors. If it genuinely cannot fail by
    /// construction (capacity already reserved, etc.), write `ensureExtFallible(a) catch
    /// unreachable` and justify it in a comment, so it is greppable and reviewable instead of
    /// hidden inside a library function.
    /// Existing callsites are bound by the OOM debt ratchet: count may only decrease; deleted at
    /// zero.
    /// Named `*Panic` to be greppable and avoid accidental use.
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
    /// Flat, no extra shaping. Good glass base reference.
    flat = 0,
    /// Arc bulge, smoother edge shift; magnifying glass / convex lens.
    convex_circle = 1,
    /// Squircle bulge, smooth edge transition; system-control liquid glass.
    convex_squircle = 2,
    /// Concave surface; the center tends to displace inward (shrink / zoom-out).
    concave = 3,
    /// Outer ring convex + center slight concave; switch / capsule button glass.
    lip = 4,
    /// Flat body + arc edge; body avoids full-face lens distortion.
    convex_plate = 5,
};

/// Liquid glass effect params (user-side, Color type). CSS-like linear-gradient blur: treat
/// backdrop blur strength as gradient property varying along axis (Apple scroll-edge progressive
/// blur is special case).
///   blur_gradient = .{ .direction = .to_bottom,
///                      .stops = ..., .stop_count = 3 }
/// ≈ linear-gradient(to bottom, blur 0%, blur 30%, none 100%)
pub const BlurGradient = struct {
    pub const BlurGradientDirection = enum(u8) {
        /// Off (no gradient, uniform blur across).
        none = 0,
        /// t=0 at top edge (CSS `to bottom`: start at top).
        to_bottom = 1,
        /// t=0 at bottom edge.
        to_top = 2,
        /// t=0 at left edge.
        to_right = 3,
        /// t=0 at right edge.
        to_left = 4,
    };
    /// Gradient stop (CSS gradient color stop).
    pub const Stop = struct {
        /// Position: % of node size along gradient axis, 0~1 (must be ascending).
        pos: f32 = 0.0,
        /// Blur strength 0~1 at this position.
        strength: f32 = 0.0,
    };

    direction: BlurGradientDirection = .none,
    /// Global strength multiplier 0~1 (scroll position etc runtime signal drives whole fade).
    strength: f32 = 1.0,
    /// stops: smoothstep between segments; before first/after last hold endpoint. Inline max 4
    /// (shader match), first stop_count valid; stop_count=0 -> default (0,1)->(1,0) single
    /// fade-out. Fixed inline not slice: styles are values, can save/compare/encode, no lifetime
    /// constraints.
    stops: [max_stops]Stop = @as([max_stops]Stop, @splat(.{})),
    stop_count: u8 = 0,

    pub const max_stops = 4;

    /// Construct from stops (>4 takes first 4 only).
    pub fn withStops(self: BlurGradient, list: []const Stop) BlurGradient {
        var out = self;
        const n = @min(list.len, max_stops);
        out.stops = @as([max_stops]Stop, @splat(.{}));
        for (list[0..n], 0..) |st, i| out.stops[i] = st;
        out.stop_count = @intCast(n);
        return out;
    }
};

/// GlassGroup member shape (docs/LIQUID_GLASS_DESIGN.md §3 / §7.2): container surface samples
/// background once, composites N shapes. Coords in container surface local logical px.
pub const GlassGroupShape = struct {
    /// Member surface node id: luminance read area key (member finds its reading by it).
    node_id: u32 = std.math.maxInt(u32),
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    radius: f32 = 0,
    /// Shadow (in container glass pass, drawn as union SDF, bridge-continuous): alpha 0..1, blur &
    /// offset (logical px).
    shadow_alpha: f32 = 0,
    shadow_blur: f32 = 0,
    shadow_offset_x: f32 = 0,
    shadow_offset_y: f32 = 0,
    /// Materialize amount (1 = fully formed): shader converges this shape's blur to clear
    /// background.
    level: f32 = 1,
    /// Base coat without tint (neutral veil): {grayscale 0..1, alpha 0..1}. Container bridge + tint
    /// fade-out use it (native: bridge always untinted base glass, tint only inside member shapes).
    base_veil: [2]f32 = .{ 247.0 / 255.0, 0 },
    /// Press feedback offset (see GlassParams.press_offset).
    press_offset: f32 = 0,
    /// glassEffectUnion: same key (!=0) merges members into one shape—their bounding box's
    /// same-type shape (capsule recalc corners by short edge, rounded-rect keeps corners); material
    /// from first member.
    union_key: u32 = 0,
    capsule: bool = false,
    /// Member's own material: lens/coat/rim/tint per-shape; shared items (blur bank etc.) from
    /// member 0.
    material: ResolvedGlassParams = .{},
};

pub const glass_group_max_shapes = 8;

/// Shape table owned by GlassGroup state (stable address, lifetime = container scope); container
/// surface glass params hold pointer only; each member write self-increments version; glass
/// fingerprint (nodeGlassParamsHash) feeds version only, not whole table.
pub const GlassGroupShapes = struct {
    /// Style handle (see style_decl.isStyleHandle): GlassParams.group pointer-only; identity is
    /// address.
    pub const style_handle = true;
    count: u8 = 0,
    version: u32 = 0,
    /// Merge distance (logical px, corresponds GlassEffectContainer(spacing:)); active M3 onward.
    spacing: f32 = 0,
    /// Merge blend radius overall scale (0 = hard union; transitions static = 0).
    blend: f32 = 1,
    /// Transition-period merge radius k/S (max across transitioning members): warp 2·sqrt(1-s),
    /// matched insert 0.75 / remove 0.5.
    motion: f32 = 0,
    /// This frame has member in transition (morph / matched / pulse / materialize): render disables
    /// pixel snap, else slow segments quantize to whole physical pixels, motion steps one by one.
    continuous: bool = false,
    shapes: [glass_group_max_shapes]GlassGroupShape = @as([glass_group_max_shapes]GlassGroupShape, @splat(.{})),
};

pub const GlassParams = struct {
    /// GlassGroup container surface: when non-null, composite N shapes by shape table (see
    /// GlassGroupShapes).
    group: ?*const GlassGroupShapes = null,
    /// Backdrop blur radius (logical pixels, 0 = no blur), like CSS backdrop-filter: blur(px):
    /// continuous adjustable, DPI-independent. Range [0, 96], exceeds -> clamp (6-tier Kawase
    /// chain, 96 near pure-color average, larger meaningless).
    backdrop_blur: f32 = 0,
    /// Frosted glass tint (null = no tint, blur only).
    glass_tint: ?Color = null,
    /// Absorption colors transmitted light; surface blends a readable material
    /// veil before lighting. Native regular glass needs the latter to lift a
    /// dark backdrop in a light appearance, and to support prominent tint.
    tint_mode: enum(u8) { absorption, surface } = .absorption,
    /// With `.absorption`: the share of the tinted (absorption) result; the rest is the surface
    /// veil `base_veil` (`NSGlassEffectView.tintColor` alpha: native output is exactly the untinted
    /// glass mixed toward the fully tinted glass by alpha). 1 = fully tinted.
    tint_amount: f32 = 1.0,
    /// Surface veil for the untinted share of a partial tint (`tint_amount < 1`); null = none.
    base_veil: ?Color = null,
    /// Surface veil as a backdrop-luma transfer curve (sRGB 0-1 output at backdrop gray 16k,
    /// i.e. luma 16k / 255, k = 0..16; the end segments extrapolate)
    /// instead of the affine `glass_tint` blend: out = T(Y) + (e - Y) * (1 - glass_tint.a). An
    /// affine T reproduces the blend exactly; null = the affine blend.
    veil_curve: ?[17]f32 = null,
    /// iOS tab-bar selection lens (single glass; see glass.metal native_glass): [0] > 0 marks
    /// the material, whose displacement is the measured native field (glass.metal tab_lens_field);
    /// [1..8) unused.
    tab_lens: [24]f32 = @as([24]f32, @splat(0)),
    /// Liquid Glass intensity (0 = blur only, 1 = default liquid, >1 = thicker/brighter).
    glass_intensity: f32 = 1.0,
    /// Highlight opacity (0.20~0.50, searchbox=0.20, switch=0.50).
    specular_opacity: f32 = 0.35,
    /// Highlight color saturation (4~9, searchbox=4, magnifier=9).
    specular_saturation: f32 = 6.0,
    /// Refraction strength (0~1, searchbox=0.70, other=1.00).
    refraction_level: f32 = 1.0,
    /// Backdrop blur blend (0=pure sharp, 1=pure blur, switch=0.20, other=1.0).
    blur_level: f32 = 1.0,
    /// Screen-space refraction displacement perception intensity (uncoupled from IOR, 0-3, default
    /// 1.0).
    warp_gain: f32 = 1.0,
    /// Center thin-layer thickness (logical pixels, drives refraction warp magnitude and
    /// Beer-Lambert tint, default 4.0).
    center_thickness: f32 = 4.0,
    /// Glass top-surface profile, directly affects specular highlight, displacement field,
    /// center-lens feel.
    surface: GlassSurface = .convex_squircle,
    /// Top-surface bezel width % of minor axis, decides curvature transition width.
    bezel_width: f32 = 0.18,
    /// Glass bottom-surface profile, default flat; affects thickness distribution and exit
    /// refraction.
    bottom_surface: GlassSurface = .flat,
    /// Bottom-surface bevel width %. Default narrow, flat/shallow-arc bottom.
    bottom_bezel_width: f32 = 0.12,
    /// Background saturation (CSS backdrop-filter: saturate(), 1 = unchanged, 2.1 = 210%).
    backdrop_saturation: f32 = 1.0,
    /// Background brightness (CSS backdrop-filter: brightness(), 1 = unchanged).
    backdrop_brightness: f32 = 1.0,
    /// Specular highlight direction (radians, screen-space, 0 = right, -pi/2 = up).
    specular_angle: f32 = -std.math.pi / 3.0,
    /// Extra center magnification (0 = none, 1 = obvious lens).
    magnification: f32 = 0.0,
    /// Glass body optical scale %, controls displacement field coverage radius.
    scale_ratio: f32 = 1.0,
    /// Edge displacement field intensity (0.2~4.0), controls bezel-area background warp.
    edge_field_strength: f32 = 1.0,
    /// Center zoom displacement radius (relative minor axis, 0.1~1.5).
    center_zoom_radius: f32 = 0.58,
    /// Center zoom displacement falloff exponent (larger -> tighter boundary, 0.4~6.0).
    center_zoom_falloff: f32 = 2.2,
    /// 'Float distance' between glass and backdrop (logical px), magnifies refraction and blur
    /// feel.
    backdrop_distance: f32 = 0.0,
    /// Native Liquid Glass lens geometry (logical px, surface = .convex_plate only): superellipse
    /// bevel width/height + flat base thickness. When bezel=0, use old surface model. Native clear
    /// capsule measured: 19.75 / 27 / 37.5 (see docs/GLASS_NATIVE_FIDELITY.md).
    lens_bezel_px: f32 = 0.0,
    lens_height_px: f32 = 0.0,
    lens_base_px: f32 = 0.0,
    /// Native model: rim blur-mix relative to center (0..1; native clear ~= 0.7).
    lens_edge_blur: f32 = 1.0,
    /// Measured native gamma-space Gaussian kernel. backdrop_blur is main
    /// sigma; signed coarse weight represents compact contrast enhancement.
    native_fine_sigma: f32 = 0.0,
    native_main_grid_mix: f32 = 0,
    /// Native geometry rasterization: static SwiftUI layout snaps all four
    /// physical edges, but an animating (morphing) shape is rasterized at its
    /// continuous position (measured mid-morph edge coverage). GlassBox sets
    /// this while a morph is running.
    native_continuous_geometry: bool = false,
    /// Press feedback: final color sRGB constant offset (system .glass button pressed: light family
    /// -19.8/255, dark family +17.7/255).
    press_offset: f32 = 0,
    /// Popover arrow (single glass): {edge 0 none/1 down/2 up/3 left/4 right, offset along edge
    /// from center, protrusion length, tip radius} (logical px). Node rect includes arrow area;
    /// body is rect minus arrow-side protrusion.
    arrow: [4]f32 = .{ 0, 0, 0, 0 },
    /// Knob lens dual-color rim (see GlassUniforms.knob_rim_*); knob_rim_light[3]=0 disables.
    knob_rim_dark: [4]f32 = .{ 0, 0, 0, 0 },
    knob_rim_light: [4]f32 = .{ 0, 0, 0, 0 },
    /// Accessibility material (resolve per system pref, see GlassUniforms.a11y_params).
    a11y: [4]f32 = .{ 0, 0, 0, 0 },
    /// Capture area no outer expand, blur clamped at edge (backgroundExtensionEffect blur layer).
    capture_clamp: bool = false,
    /// Not affected by accessibility material (reduce transparency / increase contrast): pure blur
    /// layer (backgroundExtensionEffect) not glass material; replace with opaque matte -> covers
    /// whole extension.
    a11y_exempt: bool = false,
    native_coarse_sigma: f32 = 0.0,
    native_fine_weight: f32 = 0.0,
    native_coarse_weight: f32 = 0.0,
    native_fine_slope: f32 = 0.0,
    native_fine_curve: f32 = 0.0,
    native_coarse_slope: f32 = 0.0,
    native_coarse_curve: f32 = 0.0,
    native_rim_offset: f32 = 0.0,
    native_rim_luma: f32 = 0.0,
    native_rim_chroma: f32 = 0.0,
    native_rim_ratio: f32 = 0.0,
    native_chroma_enabled: f32 = 0.0,
    native_chroma_fine: f32 = 0.0,
    native_chroma_coarse: f32 = 0.0,
    native_chroma_fine_slope: f32 = 0.0,
    native_chroma_fine_curve: f32 = 0.0,
    native_chroma_coarse_slope: f32 = 0.0,
    native_chroma_coarse_curve: f32 = 0.0,
    native_tint_mode: f32 = 0.0,
    native_tint_dark: f32 = 0.0,
    native_tint_chroma_base: f32 = 0.0,
    native_tint_chroma_slope: f32 = 0.0,
    /// Blur gradient (CSS linear-gradient-like; see BlurGradient). direction=.none disables.
    blur_gradient: BlurGradient = .{},

    /// Convert to GPU-ready format (Color->[4]f32).
    /// System pref 'reduce transparency' on: glass becomes max-frosted matte: blur maxed,
    /// refraction/warp/
    /// magnify/edge-field zero, highlight dimmed; color blocks and tone remain, content unseeable.
    /// Don't swap to a solid panel: glass content color is designed over the background (white text
    /// on
    /// color); the node's light background would make it white-on-white (GlassBox capsules vanish).
    pub fn resolve(self: GlassParams) ResolvedGlassParams {
        const ic = a11y_preferences.increaseContrast();
        if (!self.a11y_exempt and (a11y_preferences.reduceTransparency() or ic)) {
            // Native measured (native_tint_backdrop.swift with -reduceTransparency /
            // -increaseContrast process params, not system settings): body becomes
            // opaque—Glass.tint shows tint proper (background-independent), untinted is
            // fixed-brightness matte (reduce 242; increase 234 + 14*Y), preserves 16% / 10%
            // background saturation. Reduce keeps material highlight/shadow; increase replaces
            // highlight with ~0.75pt dark stroke. Body color is blurred background (max blur mixes
            // adjacent areas, dilutes saturation/brightness).
            var frosted = self;
            frosted.blur_level = 1.0;
            frosted.refraction_level = 0.0;
            frosted.warp_gain = 0.0;
            frosted.magnification = 0.0;
            frosted.edge_field_strength = 0.2;
            frosted.a11y = if (ic) .{ 2, 234.0 / 255.0, 14.0 / 255.0, 0.10 } else .{ 1, 242.0 / 255.0, 0, 0.16 };
            if (ic) frosted.specular_opacity = 0;
            return frosted.resolveRaw();
        }
        return self.resolveRaw();
    }

    fn resolveRaw(self: GlassParams) ResolvedGlassParams {
        // Blur gradient stops: clamp to [0,1], force ascending; empty slice -> default double-stop
        // (0,1)->(1,0) (single fade-out).
        const bg = self.blur_gradient;
        var stop_pos: [4]f32 = .{ 0, 1, 1, 1 };
        var stop_str: [4]f32 = .{ 1, 0, 0, 0 };
        var stop_count: u8 = 2;
        if (bg.stop_count > 0) {
            stop_count = @min(bg.stop_count, BlurGradient.max_stops);
            var prev: f32 = 0.0;
            for (0..stop_count) |i| {
                const s = bg.stops[i];
                prev = std.math.clamp(std.math.clamp(s.pos, 0.0, 1.0), prev, 1.0);
                stop_pos[i] = prev;
                stop_str[i] = std.math.clamp(s.strength, 0.0, 1.0);
            }
            // Tail-fill to last stop; shader loop overflow-safe.
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
            .{ 1, 1, 1, if (self.tint_mode == .surface) 0 else 1 };
        return .{
            .group = self.group,
            .backdrop_blur = std.math.clamp(self.backdrop_blur, 0.0, 96.0),
            .glass_tint = gt,
            .tint_mode = switch (self.tint_mode) {
                .surface => 1.0,
                .absorption => 1.0 - std.math.clamp(self.tint_amount, 0.0, 1.0),
            },
            .veil_curve = if (self.veil_curve) |c| curve: {
                var out: [20]f32 = @splat(0);
                for (c, 0..) |v, i| out[i] = std.math.clamp(v, 0.0, 1.0);
                out[17] = 1; // enabled
                break :curve out;
            } else @splat(0),
            .base_veil = if (self.base_veil) |c|
                .{ @as(f32, @floatFromInt(c.r)) / 255.0, @as(f32, @floatFromInt(c.g)) / 255.0, @as(f32, @floatFromInt(c.b)) / 255.0, @as(f32, @floatFromInt(c.a)) / 255.0 }
            else
                .{ 0, 0, 0, -1 },
            .tab_lens = self.tab_lens,
            .glass_intensity = std.math.clamp(self.glass_intensity, 0.0, 2.0),
            .specular_opacity = std.math.clamp(self.specular_opacity, 0.0, 1.0),
            .specular_saturation = std.math.clamp(self.specular_saturation, 1.0, 12.0),
            // Negative = shrink lens (knob-hold state, native edge samples outward).
            .refraction_level = std.math.clamp(self.refraction_level, -1.0, 1.0),
            .blur_level = std.math.clamp(self.blur_level, 0.0, 1.0),
            .warp_gain = std.math.clamp(self.warp_gain, 0.0, 3.0),
            .center_thickness = std.math.clamp(self.center_thickness, 0.0, if (self.surface == .convex_plate) @as(f32, 40.0) else 20.0),
            .surface = self.surface,
            .bezel_width = std.math.clamp(self.bezel_width, 0.04, if (self.surface == .convex_plate) @as(f32, 1.0) else 0.45),
            .bottom_surface = self.bottom_surface,
            .bottom_bezel_width = std.math.clamp(self.bottom_bezel_width, 0.04, if (self.bottom_surface == .convex_plate) @as(f32, 1.0) else 0.45),
            .backdrop_saturation = std.math.clamp(self.backdrop_saturation, 0.0, 8.0),
            .backdrop_brightness = std.math.clamp(self.backdrop_brightness, 0.0, 3.0),
            .specular_angle = specular_angle,
            .magnification = std.math.clamp(self.magnification, -1.0, 2.0),
            .scale_ratio = std.math.clamp(self.scale_ratio, 0.35, 1.6),
            .edge_field_strength = std.math.clamp(self.edge_field_strength, 0.2, 4.0),
            .center_zoom_radius = std.math.clamp(self.center_zoom_radius, 0.1, 1.5),
            .center_zoom_falloff = std.math.clamp(self.center_zoom_falloff, 0.4, 6.0),
            .backdrop_distance = std.math.clamp(self.backdrop_distance, 0.0, 40.0),
            .lens_bezel_px = std.math.clamp(self.lens_bezel_px, 0.0, 200.0),
            .lens_height_px = std.math.clamp(self.lens_height_px, 0.0, 200.0),
            .lens_base_px = std.math.clamp(self.lens_base_px, 0.0, 400.0),
            .lens_edge_blur = std.math.clamp(self.lens_edge_blur, 0.0, 1.0),
            .native_fine_sigma = @max(self.native_fine_sigma, 0.0),
            .native_main_grid_mix = std.math.clamp(self.native_main_grid_mix, 0.0, 1.0),
            .native_continuous_geometry = self.native_continuous_geometry,
            .press_offset = self.press_offset,
            .arrow = self.arrow,
            .knob_rim_dark = self.knob_rim_dark,
            .knob_rim_light = self.knob_rim_light,
            .a11y = self.a11y,
            .capture_clamp = self.capture_clamp,
            .native_coarse_sigma = @max(self.native_coarse_sigma, 0.0),
            .native_fine_weight = self.native_fine_weight,
            .native_coarse_weight = self.native_coarse_weight,
            .native_fine_slope = self.native_fine_slope,
            .native_fine_curve = self.native_fine_curve,
            .native_coarse_slope = self.native_coarse_slope,
            .native_coarse_curve = self.native_coarse_curve,
            .native_rim_offset = self.native_rim_offset,
            .native_rim_luma = self.native_rim_luma,
            .native_rim_chroma = self.native_rim_chroma,
            .native_rim_ratio = self.native_rim_ratio,
            .native_chroma_enabled = self.native_chroma_enabled,
            .native_chroma_fine = self.native_chroma_fine,
            .native_chroma_coarse = self.native_chroma_coarse,
            .native_chroma_fine_slope = self.native_chroma_fine_slope,
            .native_chroma_fine_curve = self.native_chroma_fine_curve,
            .native_chroma_coarse_slope = self.native_chroma_coarse_slope,
            .native_chroma_coarse_curve = self.native_chroma_coarse_curve,
            .native_tint_mode = self.native_tint_mode,
            .native_tint_dark = self.native_tint_dark,
            .native_tint_chroma_base = self.native_tint_chroma_base,
            .native_tint_chroma_slope = self.native_tint_chroma_slope,
            .blur_gradient_direction = @backingInt(bg.direction),
            .blur_gradient_strength = std.math.clamp(bg.strength, 0.0, 1.0),
            .blur_gradient_stop_pos = stop_pos,
            .blur_gradient_stop_str = stop_str,
            .blur_gradient_stop_count = stop_count,
        };
    }
};

/// Liquid glass effect params (GPU-ready format, [4]f32 tint).
pub const ResolvedGlassParams = struct {
    /// GlassGroup shape table (container surface only; null = single rect).
    group: ?*const GlassGroupShapes = null,
    backdrop_blur: f32 = 0,
    glass_tint: [4]f32 = .{ 1, 1, 1, 1 },
    /// Surface-veil share: 0 = absorption (Glass.tint), 1 = surface veil; in between = partial
    /// tint (absorption result mixed toward the `base_veil` surface result).
    tint_mode: f32 = 0,
    /// Surface veil of a partial tint (sRGB 0-1); alpha < 0 = none (the veil branch uses
    /// glass_tint).
    base_veil: [4]f32 = .{ 0, 0, 0, -1 },
    /// Veil transfer curve: [0..17) knots (sRGB 0-1), [17] = enabled flag (see GlassParams).
    veil_curve: [20]f32 = @splat(0),
    /// See GlassParams.tab_lens.
    tab_lens: [24]f32 = @as([24]f32, @splat(0)),
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
    lens_bezel_px: f32 = 0.0,
    lens_height_px: f32 = 0.0,
    lens_base_px: f32 = 0.0,
    lens_edge_blur: f32 = 1.0,
    native_fine_sigma: f32 = 0.0,
    native_main_grid_mix: f32 = 0,
    native_continuous_geometry: bool = false,
    /// Press feedback: final color sRGB constant offset (system .glass button pressed: light family
    /// -19.8/255, dark family +17.7/255).
    press_offset: f32 = 0,
    /// Popover arrow (single glass): {edge 0 none/1 down/2 up/3 left/4 right, offset along edge
    /// from center, protrusion length, tip radius} (logical px). Node rect includes arrow area;
    /// body is rect minus arrow-side protrusion.
    arrow: [4]f32 = .{ 0, 0, 0, 0 },
    /// Knob lens dual-color rim (see GlassUniforms.knob_rim_*); knob_rim_light[3]=0 disables.
    knob_rim_dark: [4]f32 = .{ 0, 0, 0, 0 },
    knob_rim_light: [4]f32 = .{ 0, 0, 0, 0 },
    /// Accessibility material (resolve per system pref, see GlassUniforms.a11y_params).
    a11y: [4]f32 = .{ 0, 0, 0, 0 },
    /// Capture area no outer expand, blur clamped at edge (backgroundExtensionEffect blur layer).
    capture_clamp: bool = false,
    native_coarse_sigma: f32 = 0.0,
    native_fine_weight: f32 = 0.0,
    native_coarse_weight: f32 = 0.0,
    native_fine_slope: f32 = 0.0,
    native_fine_curve: f32 = 0.0,
    native_coarse_slope: f32 = 0.0,
    native_coarse_curve: f32 = 0.0,
    native_rim_offset: f32 = 0.0,
    native_rim_luma: f32 = 0.0,
    native_rim_chroma: f32 = 0.0,
    native_rim_ratio: f32 = 0.0,
    native_chroma_enabled: f32 = 0.0,
    native_chroma_fine: f32 = 0.0,
    native_chroma_coarse: f32 = 0.0,
    native_chroma_fine_slope: f32 = 0.0,
    native_chroma_fine_curve: f32 = 0.0,
    native_chroma_coarse_slope: f32 = 0.0,
    native_chroma_coarse_curve: f32 = 0.0,
    native_tint_mode: f32 = 0.0,
    native_tint_dark: f32 = 0.0,
    native_tint_chroma_base: f32 = 0.0,
    native_tint_chroma_slope: f32 = 0.0,
    blur_gradient_direction: u8 = 0,
    blur_gradient_strength: f32 = 1.0,
    blur_gradient_stop_pos: [4]f32 = .{ 0, 1, 1, 1 },
    blur_gradient_stop_str: [4]f32 = .{ 1, 0, 0, 0 },
    blur_gradient_stop_count: u8 = 2,
};

/// Style extension struct (low-freq fields, allocated on-demand).
pub const StyleExt = struct {
    /// Outer shadow list (max max_shadows layers). Set via setShadow / setShadows / setShadowList;
    /// don't modify field directly.
    shadows: [max_shadows]Shadow = @as([max_shadows]Shadow, @splat(.{})),
    shadow_count: u8 = 0,
    gradient: ?Gradient = null,
    outline: ?Outline = null,
    corner_radius: ?CornerRadius = null,
    /// >0 = this node is container shape (SwiftUI
    /// `.containerShape(RoundedRectangle(cornerRadius:))`); descendants ConcentricRectangle /
    /// GlassBox `.concentric` use it for concentric-corner calc (see ui/concentric.zig).
    container_shape_radius: f32 = 0,
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    /// Transient part of translate_x/y (parent-local units) that an enter/exit motion currently
    /// adds, e.g. an overlay's dropdown slide. Not a style property: the transition writes it next
    /// to the translate it animates and zeroes it when the motion ends. A composited surface
    /// anchors its texture's pixel grid to the position without it, so the texture does not
    /// re-raster as the node slides into place.
    motion_offset: [2]f32 = .{ 0, 0 },
    /// Rotation angle (radians, positive = clockwise), origin controlled by transform_origin.
    rotate: f32 = 0,
    transform_origin: TransformOrigin = .{},
    /// CSS flex-basis: nonnegative pixels, FlexBasis.auto or FlexBasis.content.
    flex_basis: f32 = FlexBasis.auto,
    align_self: ?AlignItems = null,
    /// Reject only inherited cross-axis stretch: align_self null && parent align_items == .stretch
    /// -> .start (preserve intrinsic); parent explicit .center/.end/.start still applies; explicit
    /// align_self (including .stretch) takes priority. For controls fit width but not stretch
    /// (Button).
    no_cross_stretch: bool = false,
    margin_auto_mask: u8 = 0,
    inset: Inset = .{},
    sticky_insets: StickyInsets = .{},
    /// **Only affects sibling paint and hit order under same parent.** Each node is its children's
    /// stacking context: z doesn't cross-parent compare, no clipping effect, no hit clipping impact
    /// (render and hit both clipped by ancestor overflow_hidden chain). Sibling order in
    /// core/paint_order.zig: regular -> sticky(z<=0) -> positive_z(z>0, stable ascending by z);
    /// negative treated 0. Visually overlay cousin -> z on common-ancestor child; paint outside all
    /// containers -> portal (`cx.ensurePopoverPortalRoot()` / OverlayStack).
    z_index: i16 = 0,
    tab_index: ?i32 = null,
    aspect_ratio: f32 = 0,
    grid: ?*GridConfig = null,
    grid_placement: ?GridPlacement = null,
    min_width: f32 = -1,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = -1,
    max_height: f32 = std.math.inf(f32),
    flex_wrap: FlexWrap = .no_wrap,
    hit_shape: HitShapeSpec = .auto,
    clip_shape: ClipShapeSpec = .auto,
    /// Hit-testing-only override of the overflow clip (null = clip_shape). AppKit `hitTest:` is
    /// frame-based while a layer mask clips drawing: GlassBox content paints clipped to the glass
    /// shape but receives hits anywhere inside its rectangular bounds.
    hit_clip_shape: ?ClipShapeSpec = null,
    /// Node self paint shape (see ShapeSpec). Default rounded rect.
    shape: ShapeSpec = .rounded_rect,
    hit_behavior: ?HitBehavior = null,
    hit_roles: HitRolesOverride = .{},
    /// Liquid glass effect params (null = no glass/blur effect).
    glass: ?GlassParams = null,
    /// Multi-color gradient (null = use old two-color Gradient).
    multi_gradient: ?MultiGradient = null,
    /// Procedural noise texture (null = no noise).
    noise: ?NoiseParams = null,
    /// Inset shadow (null = none). When multi-layer, this is first (topmost); rest in
    /// extra_inset_shadows.
    inset_shadow: ?InsetShadow = null,
    /// Layers 2-3 inset shadow (CSS multi inset box-shadow). Set via setInsetShadowList.
    extra_inset_shadows: [2]InsetShadow = @as([2]InsetShadow, @splat(.{})),
    extra_inset_count: u8 = 0,
    /// Overflow fade gradient mask config.
    overflow_fade: ?OverflowFade = null,
    /// Per-edge border color override (null = use border.color).
    border_side_colors: ?BorderSideColors = null,
    /// Keep in render/tick traversal even if opacity=0, for overlay first-frame warm-up.
    keep_rendering_when_transparent: bool = false,
    /// Hint compositor pre-stage layer for transform animation.
    will_change_transform: bool = false,
    /// Hint compositor pre-stage layer for opacity animation.
    will_change_opacity: bool = false,
    /// Explicitly request subtree promoted to retained composited group surface.
    composited_group: bool = false,
    /// Lens warp of the promoted subtree surface (see ContentWarp); promotes like composited_group.
    content_warp: ?ContentWarp = null,
    /// SVG/CSS blend mode (multiply/screen/...). Non-normal forces subtree to offscreen surface
    /// (blending needs src raster), composite via W3C Compositing L1 with background. normal =
    /// default SrcOver, zero overhead.
    blend_mode: BlendMode = .normal,

    // -- Inherited text properties (CSS-like) --
    // After set, auto-inherited by text descendants (unless child overrides).
    /// Inherited text color (null = unset, text node decides).
    text_color: ?Color = null,
    /// Inherited font size.
    text_font_size: ?f32 = null,
    /// Inherited font weight.
    text_font_weight: ?u16 = null,

    /// Set single outer shadow.
    pub fn setShadow(self: *StyleExt, s: Shadow) void {
        self.shadows[0] = s;
        self.shadow_count = 1;
    }

    /// Set two outer shadows (s1 = near-precise, s2 = far-ambient).
    pub fn setShadows(self: *StyleExt, s1: Shadow, s2: Shadow) void {
        self.shadows[0] = s1;
        self.shadows[1] = s2;
        self.shadow_count = 2;
    }

    /// Set multi outer shadow (CSS order: first item topmost), truncate if exceeds max_shadows.
    pub fn setShadowList(self: *StyleExt, list: []const Shadow) void {
        const n = @min(list.len, max_shadows);
        for (list[0..n], 0..) |s, i| self.shadows[i] = s;
        self.shadow_count = @intCast(n);
    }

    /// Set multi inset shadow (CSS order: first topmost), max 3 layers.
    pub fn setInsetShadowList(self: *StyleExt, list: []const InsetShadow) void {
        self.inset_shadow = if (list.len > 0) list[0] else null;
        const extra = if (list.len > 1) @min(list.len - 1, self.extra_inset_shadows.len) else 0;
        for (0..extra) |i| self.extra_inset_shadows[i] = list[i + 1];
        self.extra_inset_count = @intCast(extra);
    }

    /// Clear all outer shadows.
    pub fn clearShadows(self: *StyleExt) void {
        self.shadow_count = 0;
    }
};

// ==================== StyleOverride, unified style override ====================

/// Style override struct; all fields default null = 'don't override, use component defaults'.
/// Unified style description (all optional fields).
///
/// For box() node construction, component external style override, multi-layer merge. Internal via
/// applyTo() -> compact Style (stored on Node).
pub const BoxStyle = struct {
    // -- Layout fields --
    width: ?Sizing = null,
    height: ?Sizing = null,
    direction: ?Direction = null,
    justify: ?JustifyContent = null,
    align_items: ?AlignItems = null,
    align_content: ?AlignContent = null,
    gap: ?f32 = null,
    padding: ?Padding = null,
    margin: ?Padding = null,
    /// Complete margin declaration (supports auto). If both margin and margin_spec set, margin_spec
    /// wins.
    margin_spec: ?Margin = null,
    flex: ?f32 = null,
    flex_shrink: ?f32 = null,
    /// Flex wrapping (write StyleExt.flex_wrap).
    flex_wrap: ?FlexWrap = null,
    /// Blend mode (write StyleExt.blend_mode; non-normal -> node uses blend composite layer).
    blend_mode: ?BlendMode = null,
    /// Z-order (write StyleExt.z_index; cross-parent -> use portal, see zindex docs).
    z_index: ?i16 = null,
    /// Absolute/sticky positioning four-edge offset (write StyleExt.inset).
    inset: ?Inset = null,
    /// Linear gradient background (write StyleExt.gradient).
    gradient: ?Gradient = null,
    /// Clip shape (write StyleExt.clip_shape).
    clip_shape: ?ClipShapeSpec = null,
    /// Liquid glass / backdrop blur (write StyleExt.glass).
    glass: ?GlassParams = null,
    /// Multi-segment gradient background (write StyleExt.multi_gradient; overrides gradient).
    multi_gradient: ?MultiGradient = null,
    /// Composite subtree as one group (write StyleExt.composited_group).
    composited_group: ?bool = null,
    /// Lens warp of the subtree surface (write StyleExt.content_warp).
    content_warp: ?ContentWarp = null,
    /// Placement in grid container (write StyleExt.grid_placement).
    grid_placement: ?GridPlacement = null,
    /// Per-corner radius (write StyleExt.corner_radius; when both corner_radius set, this wins).
    corner_radii: ?CornerRadius = null,
    /// Multi inset shadow (CSS order, max 3; write StyleExt.inset_shadow / extra_inset_shadows).
    inset_shadows: ?InsetShadowList = null,
    // -- StyleExt same-name passthrough (type/semantics in StyleExt; write/reset both per
    // ext_passthrough generic) --
    outline: ExtField("outline") = null,
    /// Nonnegative pixels (including 0), or FlexBasis.auto/content; YSS accepts both keywords.
    flex_basis: ExtField("flex_basis") = null,
    align_self: ExtField("align_self") = null,
    no_cross_stretch: ExtField("no_cross_stretch") = null,
    sticky_insets: ExtField("sticky_insets") = null,
    tab_index: ExtField("tab_index") = null,
    aspect_ratio: ExtField("aspect_ratio") = null,
    min_width: ExtField("min_width") = null,
    max_width: ExtField("max_width") = null,
    min_height: ExtField("min_height") = null,
    max_height: ExtField("max_height") = null,
    hit_shape: ExtField("hit_shape") = null,
    shape: ExtField("shape") = null,
    hit_behavior: ExtField("hit_behavior") = null,
    hit_roles: ExtField("hit_roles") = null,
    noise: ExtField("noise") = null,
    inset_shadow: ExtField("inset_shadow") = null,
    overflow_fade: ExtField("overflow_fade") = null,
    keep_rendering_when_transparent: ExtField("keep_rendering_when_transparent") = null,
    will_change_transform: ExtField("will_change_transform") = null,
    will_change_opacity: ExtField("will_change_opacity") = null,
    position: ?Position = null,
    display: ?Display = null,
    overflow: ?Overflow = null,
    overflow_hidden: ?bool = null,
    layout_isolation: ?bool = null,

    // -- Visual fields --
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
    /// Whole border (color + width + radius one-shot).
    border: ?Border = null,
    /// Fine-grained border_color override (color only, unaffected width/radius).
    border_color: ?Color = null,
    /// Fine-grained border_width override (width only, unaffected color/radius).
    border_width: ?f32 = null,
    border_overlay: ?bool = null,
    /// Fine-grained four-edge width override.
    border_top_width: ?f32 = null,
    border_right_width: ?f32 = null,
    border_bottom_width: ?f32 = null,
    border_left_width: ?f32 = null,
    /// Fine-grained four-edge color override.
    border_top_color: ?Color = null,
    border_right_color: ?Color = null,
    border_bottom_color: ?Color = null,
    border_left_color: ?Color = null,

    // -- ext convenience fields --
    corner_radius: ?f32 = null,
    shadow: ?Shadow = null,
    /// Multi outer shadow (CSS order, max max_shadows; when both shadow and shadows set, shadows
    /// wins).
    shadows: ?ShadowList = null,

    // -- Text-related (components often override) --
    text_color: ?Color = null,
    font_size: ?f32 = null,
    font_weight: ?u16 = null,

    /// Icon tint: icon / image node tint (YSS `icon-color`), varies by variant/condition. Not into
    /// Style; view writes to node.
    icon_color: ?Color = null,

    /// Fields with StyleExt same-name, value-passthrough write (applyTo / needsExt / field mask
    /// shared).
    pub const ext_passthrough = [_][]const u8{ "outline", "flex_basis", "align_self", "no_cross_stretch", "sticky_insets", "tab_index", "aspect_ratio", "min_width", "max_width", "min_height", "max_height", "hit_shape", "shape", "hit_behavior", "hit_roles", "noise", "inset_shadow", "overflow_fade", "keep_rendering_when_transparent", "will_change_transform", "will_change_opacity" };

    fn ExtField(comptime name: []const u8) type {
        const T = @FieldType(StyleExt, name);
        return if (@typeInfo(T) == .optional) T else ?T;
    }

    fn anyPassthrough(self: BoxStyle) bool {
        inline for (ext_passthrough) |name| {
            if (@field(self, name) != null) return true;
        }
        return false;
    }

    /// DevTools origin trace: return StyleField bitset actually declared by this BoxStyle. BoxStyle
    /// fine-grained border_* all land StyleField.border; margin_spec lands margin. Pure calc, no
    /// BoxStyle/Node runtime size increase.
    pub fn styleFieldMask(self: BoxStyle) u64 {
        comptime std.debug.assert(@import("zenit_reflection").fields(StyleField).len <= 64);
        var mask: u64 = 0;
        const Add = struct {
            fn field(out: *u64, comptime f: StyleField, present: bool) void {
                if (present) out.* |= @as(u64, 1) << @backingInt(f);
            }
        };

        Add.field(&mask, .width, self.width != null);
        Add.field(&mask, .height, self.height != null);
        Add.field(&mask, .direction, self.direction != null);
        Add.field(&mask, .justify, self.justify != null);
        Add.field(&mask, .align_items, self.align_items != null);
        Add.field(&mask, .align_content, self.align_content != null);
        Add.field(&mask, .gap, self.gap != null);
        Add.field(&mask, .padding, self.padding != null);
        Add.field(&mask, .margin, self.margin != null or self.margin_spec != null);
        Add.field(&mask, .flex, self.flex != null);
        Add.field(&mask, .flex_shrink, self.flex_shrink != null);
        Add.field(&mask, .flex_wrap, self.flex_wrap != null);
        Add.field(&mask, .z_index, self.z_index != null);
        Add.field(&mask, .inset, self.inset != null);
        Add.field(&mask, .gradient, self.gradient != null);
        Add.field(&mask, .clip_shape, self.clip_shape != null);
        Add.field(&mask, .composited_group, self.composited_group != null);
        Add.field(&mask, .content_warp, self.content_warp != null);
        Add.field(&mask, .grid_placement, self.grid_placement != null);
        Add.field(&mask, .corner_radius, self.corner_radii != null);
        inline for (ext_passthrough) |name| {
            if (comptime @hasField(StyleField, name)) Add.field(&mask, @field(StyleField, name), @field(self, name) != null);
        }
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
            self.border_overlay != null or self.border_width != null or self.border_top_width != null or
            self.border_right_width != null or self.border_bottom_width != null or
            self.border_left_width != null or self.border_top_color != null or
            self.border_right_color != null or self.border_bottom_color != null or
            self.border_left_color != null);
        Add.field(&mask, .corner_radius, self.corner_radius != null);
        Add.field(&mask, .shadow, self.shadow != null or self.shadows != null);
        Add.field(&mask, .text_color, self.text_color != null);
        Add.field(&mask, .text_font_size, self.font_size != null);
        Add.field(&mask, .text_font_weight, self.font_weight != null);
        return mask;
    }

    /// Apply non-null BoxStyle fields onto Style. Best effort: ext alloc fail preserves existing
    /// ext fields. Fallible callers must reserve ext first (toStyleFallible / needsExt).
    pub fn applyTo(self: BoxStyle, style: *Style, maybe_allocator: ?std.mem.Allocator) void {
        // All or nothing: if ext fields are requested but the ext block cannot be
        // allocated, apply none of this style (avoids half-applied theme replays).
        if (maybe_allocator) |allocator| {
            if (self.needsExt() and style.ext == null) {
                _ = style.ensureExtFallible(allocator) catch {
                    std.log.warn("ui: style update dropped: no memory for its ext block", .{});
                    return;
                };
            }
        }
        // Layout.
        if (self.width) |v| style.width = v;
        if (self.height) |v| style.height = v;
        if (self.direction) |v| style.direction = v;
        if (self.justify) |v| style.justify = v;
        if (self.align_items) |v| style.align_items = v;
        if (self.align_content) |v| style.align_content = v;
        if (self.gap) |v| style.gap = v;
        if (self.padding) |v| style.padding = v;
        if (self.margin) |v| style.margin = v;
        if (self.margin_spec) |v| {
            if (maybe_allocator) |allocator| {
                // Share ext strategy: toStyleFallible pre-allocates ext, this won't re-alloc.
                style.margin = v.toPadding();
                if (style.ensureExtFallible(allocator)) |e| {
                    e.margin_auto_mask = v.auto_mask;
                } else |_| {}
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
        // Visual. Style.background/opacity removed -> World.paint_state. BoxStyle retains
        // background/opacity fields (public API invariant); builder after Node.create lands these
        // to SoA via node.setBackgroundRaw/setOpacityRaw (see BoxStyle.paintOverride() +
        // builders.applyPaintOverride).
        if (self.cursor) |v| style.cursor = v;
        if (self.translate_x) |v| style.translate_x = v;
        if (self.translate_y) |v| style.translate_y = v;
        // border: whole first, then fine-grained.
        if (self.border) |v| style.border = v;
        if (self.border_color) |v| style.border.color = v;
        if (self.border_width) |v| style.border.setUniformWidth(v);
        if (self.border_overlay) |v| style.border.overlay = v;
        if (self.border_top_width) |v| style.border.side_widths[Border.SIDE_TOP] = @max(@as(f32, 0), v);
        if (self.border_right_width) |v| style.border.side_widths[Border.SIDE_RIGHT] = @max(@as(f32, 0), v);
        if (self.border_bottom_width) |v| style.border.side_widths[Border.SIDE_BOTTOM] = @max(@as(f32, 0), v);
        if (self.border_left_width) |v| style.border.side_widths[Border.SIDE_LEFT] = @max(@as(f32, 0), v);
        // ext fields need allocator.
        if (maybe_allocator) |allocator| {
            if (self.border_top_color != null or
                self.border_right_color != null or
                self.border_bottom_color != null or
                self.border_left_color != null)
            {
                // Pure visual: alloc fail keeps old value graceful, no abort.
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
            if (self.flex_wrap) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.flex_wrap = v;
                } else |_| {}
            }
            if (self.blend_mode) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.blend_mode = v;
                } else |_| {}
            }
            if (self.z_index) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.z_index = v;
                } else |_| {}
            }
            if (self.inset) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.inset = v;
                } else |_| {}
            }
            if (self.gradient) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.gradient = v;
                } else |_| {}
            }
            if (self.clip_shape) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.clip_shape = v;
                } else |_| {}
            }
            if (self.shadows) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.setShadowList(v.items[0..v.len]);
                } else |_| {}
            }
            if (self.glass) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.glass = v;
                } else |_| {}
            }
            if (self.multi_gradient) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.multi_gradient = v;
                } else |_| {}
            }
            if (self.composited_group) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.composited_group = v;
                } else |_| {}
            }
            if (self.content_warp) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.content_warp = v;
                } else |_| {}
            }
            if (self.grid_placement) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.grid_placement = v;
                } else |_| {}
            }
            if (self.corner_radii) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.corner_radius = v;
                } else |_| {}
            }
            if (self.inset_shadows) |v| {
                if (style.ensureExtFallible(allocator)) |e| {
                    e.setInsetShadowList(v.items[0..v.len]);
                } else |_| {}
            }
            inline for (ext_passthrough) |name| {
                if (@field(self, name)) |v| {
                    if (style.ensureExtFallible(allocator)) |e| {
                        @field(e, name) = v;
                    } else |_| {}
                }
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

    /// Convert to a Style (applied on top of the default Style).
    /// Whether applying this style requires writing StyleExt. Paths with an error channel use this
    /// to
    /// allocate the ext first (fallibly); the ext write inside applyTo is best-effort and silently
    /// skipped on OOM.
    /// Whether a declared field requires extended storage; shares needsExt's rules.
    pub fn fieldNeedsExt(comptime name: []const u8) bool {
        var probe: BoxStyle = .{};
        @field(probe, name) = @as(@typeInfo(@FieldType(BoxStyle, name)).optional.child, undefined);
        return probe.needsExt();
    }

    pub fn needsExt(self: BoxStyle) bool {
        return self.margin_spec != null or self.border_top_color != null or
            self.border_right_color != null or self.border_bottom_color != null or
            self.border_left_color != null or self.corner_radius != null or
            self.shadow != null or self.scale_x != null or self.scale_y != null or
            self.rotate != null or self.transform_origin != null or self.flex_wrap != null or self.blend_mode != null or
            self.z_index != null or self.inset != null or self.gradient != null or
            self.clip_shape != null or self.shadows != null or
            self.glass != null or self.multi_gradient != null or self.composited_group != null or self.content_warp != null or
            self.grid_placement != null or self.anyPassthrough() or
            self.corner_radii != null or self.inset_shadows != null or
            self.text_color != null or self.font_size != null or self.font_weight != null;
    }

    pub fn toStyleFallible(self: BoxStyle, allocator: std.mem.Allocator) !Style {
        var style = Style{};
        // Prepare the sole allocation before applyTo can mutate any fields.
        if (self.needsExt()) _ = try style.ensureExtFallible(allocator);
        self.applyTo(&style, allocator);
        return style;
    }

    pub fn toStyle(self: BoxStyle, maybe_allocator: ?std.mem.Allocator) Style {
        var style = Style{};
        self.applyTo(&style, maybe_allocator);
        return style;
    }

    /// background/opacity no longer in Style; builder after Node.create uses this override via
    /// setBackgroundRaw/setOpacityRaw -> World.paint_state.
    pub const PaintOverride = struct { background: ?Color = null, opacity: ?f32 = null };
    pub fn paintOverride(self: BoxStyle) PaintOverride {
        return .{ .background = self.background, .opacity = self.opacity };
    }

    /// Merge two BoxStyle: other values override self.
    pub fn merge(self: BoxStyle, other: BoxStyle) BoxStyle {
        // Compile-time field traversal: hand-written list once missed display (silent loss on
        // merge); new fields won't miss. All optional; other has value -> override.
        var result = self;
        inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
            comptime std.debug.assert(@typeInfo(f.type) == .optional);
            if (@field(other, f.name) != null) @field(result, f.name) = @field(other, f.name);
        }
        // `border` shorthand (width + color): if later sets it, earlier fine-grained border_* void
        // (CSS shorthand reset long-form); else applyTo writes border then fine-grained, earlier
        // border_color can reverse later-layer stroke. Long-form by field prefix (no hand-list:
        // future border_* auto-reset).
        if (other.border != null) inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
            if (comptime std.mem.startsWith(u8, f.name, "border_")) @field(result, f.name) = @field(other, f.name);
        };
        // Single and multiple shadows describe the same stack. A later declaration
        // replaces the entire earlier stack; a multi-shadow declaration wins when
        // both are explicitly supplied in the same layer, as in applyTo().
        if (other.shadows != null) {
            result.shadow = null;
        } else if (other.shadow != null) {
            result.shadows = null;
        }
        return result;
    }

    /// Check all fields null (empty style).
    pub fn isEmpty(self: BoxStyle) bool {
        inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
            if (@field(self, f.name) != null) return false;
        }
        return true;
    }
};

/// Backward-compat alias (deprecated, use BoxStyle).
pub const StyleOverride = BoxStyle;

/// Interaction/component state snapshot (from Signal system or component state).
///
/// Interaction state (hovered/pressed/focused) + persistent semantic (selected/expanded/invalid).
/// Mirrors Panda CSS conditions _hover/_active/_focus/_disabled/_checked/_expanded/_invalid subset
/// (only conditions with real component consumers).
pub const InteractionState = struct {
    is_hovered: bool = false,
    is_pressed: bool = false,
    is_focused: bool = false,
    /// Resolved focus visibility: input modality plus an optional explicit policy.
    is_focus_visible: bool = false,
    is_disabled: bool = false,
    /// Persistent selected state. selected and checked merge: same node won't both exist (list
    /// row/tab = selected, checkbox/radio/switch = checked).
    is_selected: bool = false,
    /// Expanded state (accordion item / tree node / dropdown chevron).
    is_expanded: bool = false,
    /// Validation fail state (input / textarea / form field).
    is_invalid: bool = false,
};

// ==================== Style bitfield dirty-mark system ====================

/// Dirty-mark level from Style change.
pub const DirtyLevel = enum {
    /// No mark (cursor, tab_index).
    none,
    /// Render-only dirty (background, border.color, opacity, translate, shadow, gradient, outline,
    /// corner_radius, scale).
    render,
    /// Hit/render dirty (opacity, translate, radius, clip, hit roles, etc).
    interaction,
    /// Layout dirty (padding, margin, direction, justify, align_items, gap, flex, overflow,
    /// position, inset, etc).
    layout,
    /// Sizing dirty (width, height, parent must recalc).
    sizing,

    /// Return higher of two levels.
    pub fn max(a: DirtyLevel, b: DirtyLevel) DirtyLevel {
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }
};

/// Style settable field name enum.
pub const StyleField = enum {
    // Sizing level.
    width,
    height,
    // Layout level.
    padding,
    margin,
    direction,
    justify,
    align_items,
    align_content,
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
    // Render level.
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
    content_warp,
    // Render level (inherited text property).
    text_color,
    text_font_size,
    text_font_weight,
    // None level.
    cursor,
    tab_index,
    layout_isolation,
};

/// Compile-time: determine Style field's dirty-mark level.
pub fn styleDirtyLevel(comptime field: StyleField) DirtyLevel {
    return switch (field) {
        .width, .height => .sizing,
        .border, .padding, .margin, .direction, .justify, .align_items, .align_content, .gap, .flex, .flex_shrink, .flex_basis, .flex_wrap, .overflow, .position, .aspect_ratio, .grid, .grid_placement, .min_width, .max_width, .min_height, .max_height, .align_self, .no_cross_stretch, .sticky_insets, .inset => .layout,
        .opacity, .translate_x, .translate_y, .scale_x, .scale_y, .rotate, .transform_origin, .corner_radius, .overflow_hidden, .z_index, .hit_shape, .clip_shape, .hit_behavior, .hit_roles, .will_change_transform, .will_change_opacity, .composited_group, .content_warp => .interaction,
        .background, .shadow, .gradient, .outline, .overflow_fade, .text_color, .text_font_size, .text_font_weight => .render,
        .tab_index, .layout_isolation => .none,
        .cursor => .interaction,
    };
}

/// Compile-time: determine dirty-mark level by field name string (for setStyles).
pub fn styleDirtyLevelByName(comptime name: []const u8) DirtyLevel {
    const field = std.meta.stringToEnum(StyleField, name) orelse @compileError("Unknown Style field: " ++ name);
    return styleDirtyLevel(field);
}

/// Compile-time: is ext field (low-freq, stored in StyleExt).
pub fn isExtField(comptime field: StyleField) bool {
    return switch (field) {
        .shadow, .gradient, .outline, .corner_radius, .scale_x, .scale_y, .rotate, .transform_origin, .flex_basis, .align_self, .no_cross_stretch, .inset, .sticky_insets, .z_index, .tab_index, .aspect_ratio, .grid, .grid_placement, .min_width, .max_width, .min_height, .max_height, .flex_wrap, .hit_shape, .clip_shape, .hit_behavior, .hit_roles, .overflow_fade, .will_change_transform, .will_change_opacity, .composited_group, .text_color, .text_font_size, .text_font_weight => true,
        else => false,
    };
}

/// Compile-time: get Style field type.
pub fn StyleFieldType(comptime field: StyleField) type {
    // background/opacity no longer in Style (-> World.paint_state); keep StyleField enum + setStyle
    // API, type explicit here.
    if (comptime field == .background) return Color;
    if (comptime field == .opacity) return f32;
    if (comptime isExtField(field)) {
        return @TypeOf(@field(@as(StyleExt, .{}), @tagName(field)));
    }
    return @TypeOf(@field(@as(Style, .{}), @tagName(field)));
}

// ==================== Declarative Transition ====================

/// Easing function (uses full set from animation/easing.zig).
pub const Easing = @import("../animation/easing.zig").Easing;

/// Transition config.
pub const TransitionSpec = struct {
    duration_ms: f32 = 150,
    easing: Easing = .ease_out_quad,
};

/// Transitionable property.
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
    /// Text color (TextProps.color); 'all' excludes it, explicit 'color' required.
    text_color = 11,
};

/// Single transition slot runtime state.
pub const TransitionSlot = struct {
    prop: TransitionProp,
    spec: TransitionSpec = .{},
    // Color transition (background, border_color).
    from_color: Color = Color.TRANSPARENT,
    to_color: Color = Color.TRANSPARENT,
    // Scalar transition (opacity, translate_x/y, scale_x/y).
    from_value: f32 = 0,
    to_value: f32 = 0,
    /// Animation start absolute timestamp (ms). progress = (now_ms - start_time_ms) / duration_ms,
    /// zero cumulative error.
    start_time_ms: f64 = 0,
    active: bool = false,
    /// Completion callback (node exit-anim destroy, etc).
    on_complete: ?*const fn (*anyopaque) void = null,
    on_complete_ctx: ?*anyopaque = null,
};

/// Transition slot set (max 12 properties transitioning).
pub const TransitionSlots = struct {
    slots: [12]TransitionSlot = @as([12]TransitionSlot, @splat(.{ .prop = .background })),
    count: u4 = 0,
    any_active: bool = false,

    /// Find existing slot or alloc new.
    pub fn getOrCreate(self: *TransitionSlots, prop: TransitionProp) ?*TransitionSlot {
        // Find existing.
        for (self.slots[0..self.count]) |*slot| {
            if (slot.prop == prop) return slot;
        }
        // Alloc new.
        if (self.count < 12) {
            const slot = &self.slots[self.count];
            slot.* = .{ .prop = prop };
            self.count += 1;
            return slot;
        }
        return null;
    }

    /// Find existing slot.
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

    // -- 2026-07-31: a11y gap found when components declared. a11y/tree.zig Role has these, but
    // component A11yRole missing entries, so Tree/DataTable/Steps couldn't declare self (degrade to
    // button/list, AT loses structure). --
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
    /// Scroll area (AXScrollArea). Undeclared ScrollArea auto-inferred by projection.
    scroll_area,
};

/// aria-haspopup value set, ARIA 1.2 spec.
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
    /// Whether an IME session is composing, including overlay-only preedit
    /// which has no marked projection in the committed text. Read-only query.
    /// Escape must reach this client before dismissing an enclosing overlay.
    is_composing: ?*const fn (context: *anyopaque) bool = null,
    set_selection: ?*const fn (context: *anyopaque, start_utf8: u32, end_utf8: u32) bool = null,
    frame_for_range: ?*const fn (context: *anyopaque, start_utf8: u32, end_utf8: u32, out: *A11yRect) bool = null,
    range_at_point: ?*const fn (context: *anyopaque, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool = null,
    secure: bool = false,
};

pub const A11yValueRange = struct {
    small_change: ?f32 = null,
    large_change: ?f32 = null,
    now: f32,
    min: f32,
    max: f32,
    context: ?*anyopaque = null,
    set_value: ?*const fn (context: *anyopaque, value: f32) bool = null,
    /// Logical increment (+1) / decrement (-1) for the native AX actions. Null routes them as
    /// synthetic right/left key_down on the node instead, which is wrong for a control whose
    /// arrow keys belong to an embedded text field (NumberStepper).
    step: ?*const fn (context: *anyopaque, direction: i8) bool = null,
};

pub const A11yProps = struct {
    pub const ItemSelectionOperation = enum { replace, add, remove };
    pub const ItemSelection = struct {
        context: *anyopaque,
        set: *const fn (*anyopaque, ItemSelectionOperation) bool,
    };
    pub const TextScrollRequest = struct { start: u32, end: u32, align_top: bool, text_hash: u64, caret: usize, anchor: ?usize };
    pub const TextGeometrySegment = struct { start: u32, end: u32, rect: A11yRect };
    /// Visual row region, including its logical newline if present. An empty
    /// trailing row has start == end. Spans are ordered without overlap.
    /// This is visibility data, not glyph ink.
    pub const TextRowGeometry = struct { start: u32, end: u32, rect: A11yRect };
    /// Actual visual caret line in layout-world coordinates, before transforms.
    /// UTF-8 offsets may repeat at bidi boundaries and soft wraps; preserve them.
    pub const TextCaretGeometry = struct { offset: u32, rect: A11yRect, downstream: bool };
    /// Transformed and clipped caret line; endpoints retain top-to-bottom order.
    pub const TextCaretSegment = struct { offset: u32, first: Point, last: Point, downstream: bool };
    /// Exact caret for point mapping. A visible neighboring glyph can retain
    /// this candidate even when its own vertical line lies outside the clip.
    pub const TextCaretCandidate = struct {
        offset: u32,
        first: Point,
        last: Point,
        downstream: bool,
        visible: ?struct { first: Point, last: Point } = null,
    };
    pub const max_text_geometry_segments = 65536;
    pub const EditableText = struct {
        context: *anyopaque,
        selection_start: u32,
        selection_end: u32,
        caret: u32,
        /// Plain semantic text with one attribute run and no embedded objects.
        uniform_format: bool = false,
        /// Visible UTF-8 byte range. Non-scrolling controls use 0..text.len.
        visible_start: u32 = 0,
        visible_end: u32 = std.math.maxInt(u32),
        /// Receives UTF-8 byte offsets. Implementations must clamp to valid
        /// grapheme boundaries and return false without mutating on failure.
        set_selection: *const fn (context: *anyopaque, start_utf8: u32, end_utf8: u32) bool,
        set_value: ?*const fn (context: *anyopaque, value: []const u8) bool = null,
        scroll_into_view: ?*const fn (context: *anyopaque, start_utf8: u32, end_utf8: u32, align_top: bool) bool = null,
        /// Owner-thread query of current display-line boundaries, including
        /// 0 and text length. Caller owns the returned UTF-8 offset array.
        line_boundaries: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]u32 = null,
        /// Owner-thread shaped visual pieces with canonical UTF-8 spans and
        /// layout-world logical rectangles (globalRect coordinates, before
        /// scale/rotation). Cx applies the owner's render transform and clips
        /// before native publication. Caller owns the array; no widget pointers
        /// may be retained by platform accessibility readers.
        geometry_segments: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]TextGeometrySegment = null,
        /// Caller-owned shaped caret stops, including empty rows and affinity.
        /// Width is zero; Cx must transform/clip the vertical segment, not an AABB.
        caret_geometry: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]TextCaretGeometry = null,
        /// Caller-owned current row spans and actual inner-width regions in
        /// layout-world coordinates. Pending/interpolated wrapping is unavailable.
        row_geometry: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]TextRowGeometry = null,
        frame_for_range: ?*const fn (context: *anyopaque, start_utf8: u32, end_utf8: u32, out: *A11yRect) bool = null,
        range_at_point: ?*const fn (context: *anyopaque, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool = null,
    };

    expansion: ?struct { context: *anyopaque, set: *const fn (*anyopaque, bool) bool } = null,
    item_selection: ?ItemSelection = null,
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
    /// aria-haspopup: this control opens popover when activated (menu/dialog/etc).
    has_popup: HasPopup = .none,

    // -- 2026-07-31: fields below never existed in A11yProps; Cx.projectA11yNode **hard-coded to
    // false**, so components couldn't declare. Now wired.
    /// aria-selected (listbox option / tab / grid row selected).
    selected: bool = false,
    /// aria-pressed (toggle button pressed).
    pressed: bool = false,
    /// aria-required (form required).
    required: bool = false,
    /// aria-invalid (validation fail).
    invalid: bool = false,
    /// aria-readonly (read-only, distinct from disabled).
    readonly: bool = false,
    /// aria-busy (loading).
    busy: bool = false,
    /// aria-modal (modal dialog).
    modal: bool = false,
    /// aria-multiline (multiline text).
    multiline: bool = false,
    /// aria-multiselectable (container supports multi-select).
    multiselectable: bool = false,
    /// Password/secret input. Native bridges expose a secure text subrole and
    /// must not publish value, selection, or range content.
    secure: bool = false,
    /// aria-indeterminate (tri-state checkbox intermediate).
    indeterminate: bool = false,

    /// aria-valuenow / valuemin / valuemax (slider / progressbar / spinbutton). All zero = 'not
    /// provided'; platform gets zero.
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
    /// Collection logical total count (aria-setsize / aria-rowcount). 0 = unset; platform counts
    /// visible children. Virtual lists must declare: tree has visible dozens, undeclared ->
    /// VoiceOver says 'list, 12 items' not actual 100000.
    set_size: u32 = 0,
    /// Item position in collection, 1-based (aria-posinset). 0 = unset; platform counts visible
    /// siblings. Virtual list rows must declare index, else row 5000 reads as row 3.
    pos_in_set: u32 = 0,
    /// aria-activedescendant: when container focused, tell AT active child via this element_id_raw.
    /// 0xFFFFFFFF = none. For combobox / listbox / grid 'virtual focus' controls.
    active_descendant_element_id: u32 = 0xFFFFFFFF,
    /// Semantic collection (docs/A11Y_ARCHITECTURE.md §12): this node as table exposes all data
    /// rows to AT, decoupled from render virtualization. See a11y/collection.zig for provider
    /// lifetime contract.
    collection: ?a11y_collection.Provider = null,
    /// This node collection row content container, currently item N: node itself not projected,
    /// subtree hangs under that item's cell. Only on direct children of `collection` node.
    collection_item: ?u32 = null,
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
    /// Control flow anchor (Show / Match / For / view DSL boundary). Always display:none, no
    /// layout/gap/hit/a11y; marks dynamic region position in parent, sibling add/remove keeps
    /// content at insertion (Solid marker-comment equivalent).
    anchor,
};

pub const OverflowWrap = enum { normal, break_word, anywhere };
pub const WordBreak = enum { normal, break_all, keep_all };

pub const TextWrap = enum {
    none,
    word,
    char,
    newline_only, // Line break on \n only, no width wrapping (code fence).
    // Internal effective modes also support CSS overflow-wrap/word-break.
    word_break, // overflow-wrap:break-word (emergency breaks do not affect min-content).
    break_all, // word-break:break-all.
    keep_all, // word-break:keep-all.
};

/// Text horizontal alignment within node content width (per visual line, CSS text-align-like).
/// Moves draw position only, doesn't affect measure/wrap; host self-computes cursor/hit via
/// `text_layout.alignLineOffset` for same offset.
pub const TextAlign = enum(u8) {
    start,
    center,
    end,
};

/// Text overflow handling (single-line text wrap=.none only). CSS text-overflow-like, pure visual,
/// no layout impact.
pub const TextOverflow = enum {
    clip, // Default: GPU scissor hard-truncate.
    ellipsis, // Ellipsis tail: "building-a-modern-edi..."
    ellipsis_smart, // Smart ellipsis (keep suffix): "building-a-m...editor.md"
};

/// Rich Text Span: text node can hold multiple TextSpan, each with style override. Null = inherit
/// TextProps base style. Underline style.
pub const UnderlineStyle = enum {
    solid,
    dotted,
    dashed,
    wavy,
};

pub const TextSpan = struct {
    start: u32, // byte offset in content
    end: u32,
    color: ?Color = null, // null = inherit TextProps.color
    font_weight: ?u16 = null, // null = inherit TextProps.font_weight
    use_italic_font: bool = false,
    use_monospace_font: bool = false, // inline code uses monospace font
    strikethrough: bool = false,
    bg_color: ?Color = null, // inline code background
    /// Inline box horizontal padding participates in layout/wrapping/hit,
    /// not just visual background extension.
    inline_box_padding_left: f32 = 0,
    inline_box_padding_right: f32 = 0,
    /// Inline box vertical inset affects only background rendering,
    /// not horizontal layout.
    inline_box_inset_top: f32 = 0,
    inline_box_inset_bottom: f32 = 0,
    inline_box_corner_radius: f32 = 0,
    underline: bool = false,
    underline_color: ?Color = null, // null = inherit from span/text color
    underline_style: UnderlineStyle = .solid,
    /// Underline vertical offset (px, positive downward) from its default top edge, 2px above the
    /// bottom of the line box (`line_height`), not the baseline: a host that wants the underline
    /// at a fixed distance below the baseline in a tall line box passes a negative offset.
    underline_offset: f32 = 0,
    /// Underline thickness (px). <= 0 uses style default:
    ///   solid/dashed/dotted -> 1 / 1 / 1.5 (dotted: round dots of this diameter, one apart)
    ///   wavy -> WavyParams.forFontSize(font_size).thickness (1 at code sizes)
    underline_thickness: f32 = 0,
};

/// TextProps.font_family: the platform UI font (macOS: SF Pro with its size's optical size and
/// tracking, what native controls' labels use). Mirrors render's FontSelector.system_ui_family.
pub const font_family_system_ui: u16 = 0xFFFF;

pub const TextProps = struct {
    /// The text's own style declared `color` / `font_size` / `font_weight` (CSS inheritance): an
    /// ancestor's text_color / text_font_size / text_font_weight only fills a property the text
    /// did not declare; a declared one always wins. Resolved for layout and paint alike by
    /// Node.resolveTextProps (node_inherit.zig).
    color_set: bool = false,
    font_size_set: bool = false,
    font_weight_set: bool = false,
    content: []const u8 = "",
    color: Color = theme.dark.tokens.color.fg_primary,
    font_size: f32 = 14,
    font_weight: u16 = 400,
    /// Font family id (process-local from render.FontRegistry). 0 = default.
    /// WARNING: store id not name; text_run rebuilds each frame, slice
    /// introduces dangling reference (see render/font_registry.zig header).
    font_family: u16 = 0,
    line_height: f32 = 1.4,
    selectable: bool = true,
    wrap: TextWrap = .none,
    overflow_wrap: OverflowWrap = .normal,
    word_break: WordBreak = .normal,

    max_lines: u16 = 0,
    /// Baseline position fraction (0.0-1.0) relative to line height.
    /// 0 uses the resolved face metrics and half-leading, shared by layout and paint.
    /// Without a host font resolver the fallback is 0.75.
    baseline_ratio: f32 = 0,
    inline_buf: [16]u8 = undefined,
    inline_len: u8 = 0,
    /// Use symbol font rendering (FontSelector.symbols_font) for list
    /// markers and special Unicode characters.
    use_symbols_font: bool = false,
    /// Use monospace font rendering (FontSelector monospace group)
    use_monospace_font: bool = false,
    /// Use italic font rendering
    use_italic_font: bool = false,
    /// Platform font smoothing (macOS stem darkening) when rasterizing glyphs. Off for content
    /// that reproduces iOS, which draws glyphs unsmoothed (macOS smoothing put 23-46 % more ink
    /// on the iOS tab bar labels). Rendering only: layout is unchanged.
    font_smoothing: bool = true,
    /// Strikethrough
    strikethrough: bool = false,
    /// Monospace char width (>0 enables fast path: single shape pass +
    /// utf8DisplayWidth for span background position)
    monospace_char_width: f32 = 0,
    /// Whether content allocated by framework allocator (freed on
    /// node destroy/setText). Pitfall: getText -> point to app buffer ->
    /// setText keeps owned=true, destroy frees app buffer (invalid free).
    /// Set owned=false explicitly or use node.setTextContent.
    owned: bool = false,

    /// text overflow handling (wrap=.none single-line only)
    text_overflow: TextOverflow = .clip,

    /// Per-visual-line horizontal alignment. Node width from layout
    /// (fit width makes line=node width, indistinguishable), so center
    /// wrapping needs .grow or fixed width.
    text_align: TextAlign = .start,

    /// Right-edge fade mask width (px, 0=off; wrap=.none no spans).
    /// Within last fade_right px of available width, glyph alpha drops
    /// linearly to 0, like CSS mask-image for text. Combine with .clip
    /// for name-fades-not-cut appearance (overlay floats need no backdrop,
    /// transparent/glass naturally correct).
    fade_right: f32 = 0,

    /// Rich text spans (subsegments by byte offset with independent
    /// styles). Empty = single style
    spans: []const TextSpan = &.{},
    /// When false, spans affect paint only, not text layout/shape cache.
    spans_affect_layout: bool = true,
    /// Whether spans array allocated by allocator (freed on destroy)
    spans_owned: bool = false,

    /// Set inline text content (<= inline_buf.len = 16 bytes, zero-alloc).
    /// Does NOT truncate: oversized returns error.InlineContentTooLong.
    /// Use setContent(allocator, src) for variable-length. After call,
    /// if TextProps value-passed/copied, must call fixupAfterMove.
    pub fn setInlineContent(self: *TextProps, src: []const u8) error{InlineContentTooLong}!void {
        if (src.len > self.inline_buf.len) return error.InlineContentTooLong;
        const len: u8 = @intCast(src.len);
        @memcpy(self.inline_buf[0..len], src[0..len]);
        self.inline_len = len;
        self.content = self.inline_buf[0..len];
        // Content now points to own inline_buf, not heap: must remove
        // owned. Else getText -> setInlineContent -> setText with owned heap
        // text creates entry with owned=true -> inline_buf, destroy frees it
        // (invalid free). Old heap freed by ContentTable.setText.
        self.owned = false;
    }

    /// Universal text content entry: fits inline = zero-alloc, else dup
    /// owned via allocator (freed on destroy/setText by ContentTable using
    /// Cx allocator, so allocator must be Cx.allocator).
    pub fn setContent(self: *TextProps, allocator: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error!void {
        self.setInlineContent(src) catch {
            self.content = try allocator.dupe(u8, src);
            self.inline_len = 0;
            self.owned = true;
        };
    }

    /// Fix content pointer after struct move/copy. When inline_len > 0,
    /// content may point to old inline_buf address, needs relocation.
    pub fn fixupAfterMove(self: *TextProps) void {
        if (self.inline_len > 0) {
            self.content = self.inline_buf[0..self.inline_len];
        }
    }
    pub fn layoutWrap(self: TextProps) TextWrap {
        if (self.wrap == .none or self.wrap == .newline_only) return self.wrap;
        return switch (self.word_break) {
            .break_all => .break_all,
            .keep_all => .keep_all,
            .normal => switch (self.overflow_wrap) {
                .anywhere => .char,
                .break_word => .word_break,
                .normal => self.wrap,
            },
        };
    }
};

/// How an icon / image is tinted: a fixed color, or the current color (`current_color`: the nearest
/// ancestor text color, CSS currentColor, resolved at paint; `color` paints when no ancestor
/// declares one). The whole mode is one value: restoring a tint restores both.
pub const TintMode = struct {
    color: Color,
    current_color: bool = false,

    pub fn fixed(c: Color) TintMode {
        return .{ .color = c };
    }

    pub fn currentColor(fallback: Color) TintMode {
        return .{ .color = fallback, .current_color = true };
    }
};

pub const ImageProps = struct {
    texture_id: u32,
    tint: Color = Color.WHITE,
    /// Tint with the nearest text color up the ancestors (CSS currentColor), resolved at paint;
    /// `tint` is the fallback when no ancestor declares one. See IconProps.
    tint_current_color: bool = false,

    /// Tint painted for this image (currentColor resolved).
    pub fn paintTint(self: ImageProps, inherited: ?Color) Color {
        return if (self.tint_current_color) inherited orelse self.tint else self.tint;
    }
};

pub const IconProps = struct {
    icon_id: u16,
    rep: icon_ir.Rep,
    tint: Color = Color.WHITE,
    /// Tint with the nearest text color up the ancestors (CSS currentColor), resolved at paint;
    /// `tint` is the fallback when no ancestor declares one. A glyph inside a control follows the
    /// control's foreground through its states without its own state wiring.
    tint_current_color: bool = false,

    /// Tint painted for this icon on `node` (currentColor resolved).
    pub fn paintTint(self: IconProps, inherited: ?Color) Color {
        return if (self.tint_current_color) inherited orelse self.tint else self.tint;
    }
};

/// Event callback reference, unified form for component callbacks.
///
/// ## Why payload variants
///
/// Callbacks come in two incompatible tracks:
///   - ?HandlerRef: no-arg, notify only
///   - ?*const fn (T, *anyopaque) void: value-passing
///
/// Migrating the value track to no-arg silently loses the payload (the caller compiles, the value
/// is gone). So HandlerRef has an optional payload channel:
///   - .callback: no-arg
///   - .payload_callback: optional value (triggered by invokeWith*)
///
/// Payload supports bool / []const u8 only (all repo value callbacks use just these: bool for
/// checkbox/switch/accordion; []const u8 for input/textarea/tabs/radio). No generics:
/// HandlerRef lives in Node, and generics would pollute the tree type.
///
/// WARNING Component authors: the payload version takes priority when both are set.
pub const HandlerRef = struct {
    /// Event callback type marker (Yix distinguishes events from data
    /// by receiver param type, see ui.view.isEventProp)
    pub const zenit_handler = true;
    callback: *const fn (*anyopaque) void,
    context: *anyopaque,
    /// Optional value callback. Non-null invokes invokeWithBool/Str via
    /// this, else degrades to no-arg.
    payload_callback: ?PayloadCallback = null,

    pub const PayloadCallback = union(enum) {
        boolean: *const fn (bool, *anyopaque) void,
        string: *const fn ([]const u8, *anyopaque) void,
        drop: *const fn (DropPayload, *anyopaque) void,
    };

    /// Drop callback complete payload: newline-separated paths + hit
    /// point (window coords, DragEvent.x/y source). File placement needs
    /// coords; paths-only falls back to global .drag self-recording.
    pub const DropPayload = struct {
        /// Newline-separated file path/URL list; valid only during callback
        /// execution, must dup to retain. Platform drag externally controlled,
        /// treat as untrusted input.
        paths: []const u8,
        x: f32,
        y: f32,
        /// 0=none, 1=newline-separated file/URL list, 2=text, 3=internal.
        payload_kind: u8 = 0,
        /// True means backend rejected entire payload for capacity, paths
        /// empty.
        payload_truncated: bool = false,
        payload_is_untrusted: bool = true,
    };

    pub fn invoke(self: HandlerRef) void {
        self.callback(self.context);
    }

    /// Invoke with bool value. No-arg handler degrades to no-arg call
    /// (event not lost, value unavailable), so components unconditionally
    /// call invokeWithBool regardless of registration.
    pub fn invokeWithBool(self: HandlerRef, value: bool) void {
        if (self.payload_callback) |pc| switch (pc) {
            .boolean => |f| return f(value, self.context),
            .drop => {},
            .string => {},
        };
        self.callback(self.context);
    }

    /// Invoke with string value. Semantics match invokeWithBool. WARNING:
    /// slice lifetime valid ONLY during callback execution (usually
    /// component buffer). Must dup to retain.
    pub fn invokeWithStr(self: HandlerRef, value: []const u8) void {
        if (self.payload_callback) |pc| switch (pc) {
            .string => |f| return f(value, self.context),
            .drop => |f| return f(.{ .paths = value, .x = 0, .y = 0 }, self.context),
            .boolean => {},
        };
        self.callback(self.context);
    }

    /// Invoke with complete drop payload (paths + coords). String
    /// registration degrades to paths-only; no-arg degrades to no-arg.
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
    /// Phase 6: capture-phase event handler (root -> target downward).
    /// Default null = skip capture, zero-cost. For: focus trap, scroll
    /// lock, gesture arbitration needing ancestor interception.
    on_event_capture: ?GenericEventCallback = null,
    event_context: ?*anyopaque = null,
    /// Capture handler's own context (null uses event_context). Component
    /// root's on_event/event_context belongs to component; template
    /// onKeyDown/onPointer*/onScroll in capture slot with own context.
    capture_context: ?*anyopaque = null,
    /// Dedicated scroll event handler (symmetric with on_key_down).
    /// Fallthrough if on_event returns ignored or missing; context uses
    /// event_context.
    on_scroll: ?ScrollEventCallback = null,
    scroll_direction_hint: ?ScrollDirectionHint = null,
    on_key_down: ?KeyEventCallback = null,
    on_key_up: ?KeyEventCallback = null,
    key_context: ?*anyopaque = null,
    on_action: ?actions_mod.ActionHandler = null,
    action_context: ?*anyopaque = null,

    /// Drag: file entered this node boundary (drag.entered). Hover
    /// highlight feedback. Non-null marks as drop target (pointer hit).
    on_drag_enter: ?HandlerRef = null,
    /// Drag: file exited this node boundary (drag.exited).
    on_drag_leave: ?HandlerRef = null,
    /// Drag: file dropped on this node (drag.dropped). Register via
    /// Cx.strHandlerFrom for newline-separated paths. WARNING: slice
    /// valid only during callback, must dup to retain.
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

test "Transform2D.orientCornerRadii re-indexes corners for flips and quarter turns only" {
    const radii = [4]f32{ 1, 2, 3, 4 }; // TL, TR, BR, BL
    const expectEq = std.testing.expectEqual;
    try expectEq(radii, Transform2D.translation(30, -7).mul(Transform2D.scale(2, 0.5, 0, 0)).orientCornerRadii(radii));
    // Horizontal mirror: TL <-> TR, BL <-> BR.
    try expectEq([4]f32{ 2, 1, 4, 3 }, Transform2D.scale(-1, 1, 50, 20).orientCornerRadii(radii));
    // Vertical mirror: TL <-> BL, TR <-> BR.
    try expectEq([4]f32{ 4, 3, 2, 1 }, Transform2D.scale(1, -1, 50, 20).orientCornerRadii(radii));
    // Half turn: TL <-> BR, TR <-> BL.
    try expectEq([4]f32{ 3, 4, 1, 2 }, Transform2D.rotation(std.math.pi, 50, 20).orientCornerRadii(radii));
    // Quarter turn clockwise (y down): TL lands top-right, TR bottom-right, ...
    try expectEq([4]f32{ 4, 1, 2, 3 }, Transform2D.rotation(std.math.pi / 2.0, 0, 0).orientCornerRadii(radii));
    try expectEq([4]f32{ 2, 3, 4, 1 }, Transform2D.rotation(-std.math.pi / 2.0, 0, 0).orientCornerRadii(radii));
    // Oblique rotation (AABB-approximated clip) and degenerate maps keep the source order.
    try expectEq(radii, Transform2D.rotation(0.3, 0, 0).orientCornerRadii(radii));
    try expectEq(radii, (Transform2D{ .a = 0, .d = 0 }).orientCornerRadii(radii));
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

test "BoxStyle.applyTo is all or nothing when its ext block cannot be had (acceptance)" {
    // Theme replay re-applies a resolved BoxStyle through applyTo in a void callback. If the
    // node has no ext block yet and none can be allocated, the replay must leave the style as it
    // was, not land the plain fields and drop the ext ones (a half-applied theme).
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var style: Style = .{};
    style.gap = 2;
    style.padding = Padding.all(1);
    const next: BoxStyle = .{
        .gap = 7,
        .padding = Padding.all(9),
        .corner_radius = 8,
        .z_index = 3,
    };
    next.applyTo(&style, failing.allocator());
    try std.testing.expect(style.ext == null);
    try std.testing.expectEqual(@as(f32, 2), style.gap);
    try std.testing.expectEqual(@as(f32, 1), style.padding.top);

    // With memory, every field lands, plain and ext alike.
    next.applyTo(&style, std.testing.allocator);
    defer if (style.ext) |ext| std.testing.allocator.destroy(ext);
    try std.testing.expectEqual(@as(f32, 7), style.gap);
    try std.testing.expectEqual(@as(f32, 9), style.padding.top);
    try std.testing.expectEqual(@as(i16, 3), style.ext.?.z_index);
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

test "BoxStyle.merge / isEmpty 覆盖全部字段（曾漏 display）" {
    const merged = (BoxStyle{ .gap = 4 }).merge(.{ .display = .none, .gap = 8 });
    try std.testing.expectEqual(@as(?Display, .none), merged.display);
    try std.testing.expectEqual(@as(?f32, 8), merged.gap);
    try std.testing.expect(!(BoxStyle{ .display = .none }).isEmpty());
    try std.testing.expect((BoxStyle{}).isEmpty());

    // Per-field set carries through merge, isEmpty sees all. donor must
    // fill every field: BoxStyle new field without follow-up red-flags
    // donor assertion.
    const donor = BoxStyle{
        .width = .{ .px = 1 },
        .height = .{ .px = 1 },
        .direction = .row,
        .justify = .center,
        .align_items = .center,
        .align_content = .center,
        .gap = 1,
        .padding = Padding.all(1),
        .margin = Padding.all(1),
        .margin_spec = .{},
        .flex = 1,
        .flex_shrink = 1,
        .flex_wrap = .wrap,
        .blend_mode = .multiply,
        .z_index = 1,
        .inset = .{},
        .gradient = .{ .from = Color.WHITE, .to = Color.WHITE },
        .clip_shape = .auto,
        .shadows = ShadowList.of(&.{.{}}),
        .glass = .{},
        .multi_gradient = MultiGradient.fromSlice(&.{}, .diagonal),
        .composited_group = true,
        .content_warp = .{ .cap = 6, .edge = 2, .fade_start = 4, .fade_width = 14 },
        .grid_placement = .{},
        .corner_radii = .{ .each = .{ 1, 2, 3, 4 } },
        .inset_shadows = InsetShadowList.of(&.{.{}}),
        .outline = .{ .color = Color.WHITE },
        .flex_basis = 1,
        .align_self = .center,
        .no_cross_stretch = true,
        .sticky_insets = .{},
        .tab_index = 1,
        .aspect_ratio = 1,
        .min_width = 1,
        .max_width = 1,
        .min_height = 1,
        .max_height = 1,
        .hit_shape = .rect,
        .shape = .ellipse,
        .hit_behavior = .pass_through,
        .hit_roles = .{},
        .noise = .{},
        .inset_shadow = .{},
        .overflow_fade = .{},
        .keep_rendering_when_transparent = true,
        .will_change_transform = true,
        .will_change_opacity = true,
        .position = .absolute,
        .display = .none,
        .overflow = .hidden,
        .overflow_hidden = true,
        .layout_isolation = true,
        .background = Color.WHITE,
        .opacity = 0.5,
        .cursor = .pointer,
        .translate_x = 1,
        .translate_y = 1,
        .scale_x = 1,
        .scale_y = 1,
        .rotate = 1,
        .transform_origin = .{},
        .border = .{},
        .border_color = Color.WHITE,
        .border_width = 1,
        .border_overlay = true,
        .border_top_width = 1,
        .border_right_width = 1,
        .border_bottom_width = 1,
        .border_left_width = 1,
        .border_top_color = Color.WHITE,
        .border_right_color = Color.WHITE,
        .border_bottom_color = Color.WHITE,
        .border_left_color = Color.WHITE,
        .corner_radius = 1,
        .shadow = .{},
        .text_color = Color.WHITE,
        .font_size = 1,
        .font_weight = 1,
        .icon_color = Color.WHITE,
    };
    inline for (@import("zenit_reflection").fields(BoxStyle)) |f| {
        try std.testing.expect(@field(donor, f.name) != null);
        var one: BoxStyle = .{};
        @field(one, f.name) = @field(donor, f.name);
        try std.testing.expect(@field((BoxStyle{}).merge(one), f.name) != null);
        try std.testing.expect(!one.isEmpty());
    }
}

test "BoxStyle styleFieldMask reports only declared aggregate fields" {
    const mask = (BoxStyle{
        .padding = Padding.all(8),
        .background = Color.BLACK,
        .border_left_width = 2,
    }).styleFieldMask();
    const has = struct {
        fn field(bits: u64, f: StyleField) bool {
            return (bits & (@as(u64, 1) << @backingInt(f))) != 0;
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
    // On failure, don't modify existing content
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

test "GlassParams.resolve: reduce transparency / increase contrast pick the measured opaque materials" {
    const saved = a11y_preferences.current();
    defer a11y_preferences.set(saved);
    const base = GlassParams{ .backdrop_blur = 20, .specular_opacity = 0.6 };
    a11y_preferences.set(.{});
    try std.testing.expectEqual(@as(f32, 0), base.resolve().a11y[0]);
    a11y_preferences.set(.{ .reduce_transparency = true });
    const rt = base.resolve();
    try std.testing.expectEqual(@as(f32, 1), rt.a11y[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 242.0 / 255.0), rt.a11y[1], 1e-6);
    try std.testing.expectEqual(@as(f32, 20), rt.backdrop_blur); // regular blur (max blur would dilute background chroma)
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), rt.specular_opacity, 1e-6); // preserve material specular
    a11y_preferences.set(.{ .increase_contrast = true, .reduce_transparency = true });
    const ic = base.resolve();
    try std.testing.expectEqual(@as(f32, 2), ic.a11y[0]); // high contrast mode (stroke)
    try std.testing.expectEqual(@as(f32, 0), ic.specular_opacity);
    // pure blur layer exemption
    var blur_only = base;
    blur_only.a11y_exempt = true;
    try std.testing.expectEqual(@as(f32, 0), blur_only.resolve().a11y[0]);
}

test "BoxStyle.merge：后层的 border 简写重置前层的细粒度 border_*（CSS 语义）；后层的细粒度字段照常叠在前层简写上" {
    const lower: BoxStyle = .{ .border_color = Color.hex(0xff0000), .border_width = 1 };
    const upper: BoxStyle = .{ .border = .{ .width = 0, .color = Color.hex(0x00ff00) } };
    const m = lower.merge(upper);
    try std.testing.expect(m.border_color == null and m.border_width == null);
    try std.testing.expectEqual(@as(f32, 0), m.border.?.width);
    const m2 = upper.merge(.{ .border_color = Color.hex(0x0000ff) });
    try std.testing.expect(m2.border != null);
    try std.testing.expect(m2.border_color.?.eql(Color.hex(0x0000ff)));
}

test "Color.lerp from transparent fades the target hue in (no dark flash)" {
    // Ghost Button hover: TRANSPARENT -> opaque bg-hover. Straight per-channel lerp passes
    // through dark translucent gray; premultiplied lerp keeps the target RGB throughout.
    const hover = Color.hex(0xF0F0F0);
    var i: u32 = 1;
    while (i < 10) : (i += 1) {
        const c = Color.lerp(Color.TRANSPARENT, hover, @as(f32, @floatFromInt(i)) / 10.0);
        try std.testing.expectEqual(hover.withAlpha(c.a), c);
    }
    try std.testing.expectEqual(hover, Color.lerp(Color.TRANSPARENT, hover, 1.0));
    try std.testing.expectEqual(Color.TRANSPARENT, Color.lerp(Color.TRANSPARENT, hover, 0.0));
    // Reverse direction (hover out) likewise keeps the source hue.
    const out = Color.lerp(hover, Color.TRANSPARENT, 0.5);
    try std.testing.expectEqual(hover.withAlpha(out.a), out);
    // Equal alphas: unchanged straight lerp.
    try std.testing.expectEqual(Color.rgb(127, 127, 127), Color.lerp(Color.BLACK, Color.WHITE, 0.5));
}
