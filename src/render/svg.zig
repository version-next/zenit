const std = @import("std");
const svg_safety = @import("svg_safety");
const icon_ir = @import("icon_ir");

pub const RasterizeOptions = struct {
    target_width: ?u32 = null,
    target_height: ?u32 = null,
    /// Supersampling factor per axis (1-4)
    supersample: u8 = 2,
    /// Optional background color; null means transparent background.
    background: ?Color = null,
};

pub const RasterImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *RasterImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const AlphaMask = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *AlphaMask, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn black() Color {
        return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    }
};

const Point = icon_ir.Point;

const Rect = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    fn width(self: Rect) f32 {
        return self.max_x - self.min_x;
    }

    fn height(self: Rect) f32 {
        return self.max_y - self.min_y;
    }

    fn expand(self: *Rect, amount: f32) void {
        self.min_x -= amount;
        self.min_y -= amount;
        self.max_x += amount;
        self.max_y += amount;
    }
};

const FillRule = enum {
    nonzero,
    evenodd,
};

const Paint = union(enum) {
    unset,
    none,
    current_color,
    color: Color,
};

const ElementStyle = struct {
    fill: Paint = .unset,
    stroke: Paint = .unset,
    color: ?Color = null,
    stroke_width: ?f32 = null,
    opacity: ?f32 = null,
    fill_opacity: ?f32 = null,
    stroke_opacity: ?f32 = null,
    fill_rule: ?FillRule = null,
};

const Stroke = struct {
    color: Color,
    width: f32,
};

const Contour = icon_ir.Contour;

const Drawable = struct {
    contours: []const Contour,
    fill: ?Color,
    stroke: ?Stroke,
    fill_rule: FillRule,

    fn deinit(self: *Drawable, allocator: std.mem.Allocator) void {
        for (self.contours) |c| {
            allocator.free(c.points);
        }
        allocator.free(self.contours);
        self.* = undefined;
    }
};

const PreserveAspectAlign = enum {
    x_min_y_min,
    x_mid_y_min,
    x_max_y_min,
    x_min_y_mid,
    x_mid_y_mid,
    x_max_y_mid,
    x_min_y_max,
    x_mid_y_max,
    x_max_y_max,
};

const PreserveAspectMode = enum {
    none,
    meet,
    slice,
};

const PreserveAspectRatio = struct {
    alignment: PreserveAspectAlign = .x_mid_y_mid,
    mode: PreserveAspectMode = .meet,
};

const MAX_RASTER_DIMENSION: u32 = 8192;

const SvgDocument = struct {
    drawables: std.ArrayList(Drawable) = .{},
    view_min_x: f32 = 0,
    view_min_y: f32 = 0,
    view_width: f32 = 0,
    view_height: f32 = 0,
    width_hint: ?f32 = null,
    height_hint: ?f32 = null,
    preserve_aspect_ratio: PreserveAspectRatio = .{},

    fn deinit(self: *SvgDocument, allocator: std.mem.Allocator) void {
        for (self.drawables.items) |*d| d.deinit(allocator);
        self.drawables.deinit(allocator);
    }
};

pub fn rasterize(
    allocator: std.mem.Allocator,
    svg_data: []const u8,
    options: RasterizeOptions,
) !RasterImage {
    var doc = try parseDocument(allocator, svg_data);
    defer doc.deinit(allocator);

    if (doc.drawables.items.len == 0) return error.InvalidSvg;

    const out = determineOutputSize(&doc, options);

    // 防止极端尺寸导致整数溢出或 OOM（最大 8192x8192）
    if (out.width == 0 or out.height == 0) return error.InvalidSvg;
    if (out.width > MAX_RASTER_DIMENSION or out.height > MAX_RASTER_DIMENSION) return error.InvalidSvg;

    const pixel_count = @as(usize, out.width) * @as(usize, out.height) * 4;
    const pixels = try allocator.alloc(u8, pixel_count);

    if (options.background) |bg| {
        var i: usize = 0;
        while (i + 4 <= pixels.len) : (i += 4) {
            pixels[i + 0] = bg.r;
            pixels[i + 1] = bg.g;
            pixels[i + 2] = bg.b;
            pixels[i + 3] = bg.a;
        }
    } else {
        @memset(pixels, 0);
    }

    const ss = std.math.clamp(options.supersample, 1, 4);

    for (doc.drawables.items) |drawable| {
        drawDrawable(
            pixels,
            out.width,
            out.height,
            doc.view_min_x,
            doc.view_min_y,
            doc.view_width,
            doc.view_height,
            doc.preserve_aspect_ratio,
            drawable,
            ss,
        );
    }

    return .{
        .width = out.width,
        .height = out.height,
        .pixels = pixels,
    };
}

pub fn rasterizeIconMask(
    allocator: std.mem.Allocator,
    rep: icon_ir.Rep,
    target_width: u32,
    target_height: u32,
    supersample: u8,
) !AlphaMask {
    if (target_width == 0 or target_height == 0) return error.InvalidSvg;
    if (target_width > MAX_RASTER_DIMENSION or target_height > MAX_RASTER_DIMENSION) return error.InvalidSvg;

    const pixel_count = @as(usize, target_width) * @as(usize, target_height);
    const pixels = try allocator.alloc(u8, pixel_count);
    @memset(pixels, 0);

    const ss = std.math.clamp(supersample, 1, 4);
    for (rep.shapes) |shape| {
        const drawable = drawableFromIconShape(shape);
        drawDrawableMask(
            pixels,
            target_width,
            target_height,
            rep.view_min_x,
            rep.view_min_y,
            rep.view_width,
            rep.view_height,
            .{},
            drawable,
            ss,
        );
    }

    return .{
        .width = target_width,
        .height = target_height,
        .pixels = pixels,
    };
}

/// Parse an SVG document into an `icon_ir.OwnedRep`, the pre-flattened
/// geometry the icon mask rasterizer consumes (`rasterizeIconMask` reads
/// `rep.shapes`, not raw svg bytes). Used by the offline asset generator
/// (`tools/gen_svg_assets.zig`) so generated `reps` flatten béziers exactly
/// the way the runtime rasterizer expects, no drift between gen and render.
///
/// `size` is the logical px the rep is keyed at (icons ship one rep at 24).
/// Caller owns the result; free with `OwnedRep.deinit`.
pub fn parseToOwnedRep(
    allocator: std.mem.Allocator,
    svg_data: []const u8,
    size: u8,
) !icon_ir.OwnedRep {
    var doc = try parseDocument(allocator, svg_data);
    defer doc.deinit(allocator);

    const view_w = if (doc.view_width > 0) doc.view_width else 24;
    const view_h = if (doc.view_height > 0) doc.view_height else 24;

    var shapes = try allocator.alloc(icon_ir.OwnedShape, doc.drawables.items.len);
    errdefer allocator.free(shapes);
    var built: usize = 0;
    errdefer for (shapes[0..built]) |*s| s.deinit(allocator);

    for (doc.drawables.items) |drawable| {
        var contours = try allocator.alloc(icon_ir.OwnedContour, drawable.contours.len);
        errdefer allocator.free(contours);
        var c_built: usize = 0;
        errdefer for (contours[0..c_built]) |*c| c.deinit(allocator);

        for (drawable.contours, 0..) |c, ci| {
            const pts = try allocator.alloc(icon_ir.Point, c.points.len);
            for (c.points, 0..) |p, pi| pts[pi] = .{ .x = p.x, .y = p.y };
            contours[ci] = .{ .points = pts, .closed = c.closed };
            c_built += 1;
        }

        shapes[built] = .{
            .contours = contours,
            .fill = drawable.fill != null,
            .stroke_width = if (drawable.stroke) |s| s.width else 0,
            .fill_rule = switch (drawable.fill_rule) {
                .nonzero => .nonzero,
                .evenodd => .evenodd,
            },
        };
        built += 1;
    }

    return .{
        .size = size,
        .view_min_x = doc.view_min_x,
        .view_min_y = doc.view_min_y,
        .view_width = view_w,
        .view_height = view_h,
        .shapes = shapes,
    };
}

const OutputSize = struct {
    width: u32,
    height: u32,
};

fn determineOutputSize(doc: *SvgDocument, options: RasterizeOptions) OutputSize {
    const source_w = choosePositive(doc.width_hint, doc.view_width, 256);
    const source_h = choosePositive(doc.height_hint, doc.view_height, 256);

    var w = options.target_width orelse 0;
    var h = options.target_height orelse 0;

    if (w == 0 and h == 0) {
        w = roundedOutputDimension(source_w);
        h = roundedOutputDimension(source_h);
    } else if (w == 0) {
        const aspect = if (source_h > 0) source_w / source_h else 1;
        w = roundedOutputDimension(@as(f32, @floatFromInt(h)) * aspect);
    } else if (h == 0) {
        const aspect = if (source_w > 0) source_h / source_w else 1;
        h = roundedOutputDimension(@as(f32, @floatFromInt(w)) * aspect);
    }

    return .{ .width = w, .height = h };
}

fn choosePositive(a: ?f32, b: f32, fallback: f32) f32 {
    if (a) |v| if (v > 0 and std.math.isFinite(v)) return v;
    if (b > 0 and std.math.isFinite(b)) return b;
    return fallback;
}

fn roundedOutputDimension(value: f32) u32 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    const rounded = @round(value);
    if (!std.math.isFinite(rounded) or rounded > @as(f32, @floatFromInt(MAX_RASTER_DIMENSION))) {
        // Preserve an out-of-range sentinel so rasterize rejects the request
        // instead of silently allocating a different size.
        return MAX_RASTER_DIMENSION + 1;
    }
    return @max(1, @as(u32, @intFromFloat(rounded)));
}

/// 元素级解析结果的处理：畸形元素（error.InvalidSvg）按 SVG 惯例跳过，
/// 但分配失败必须冒泡，吞掉 OOM 会让图标静默少画几笔，看起来像渲染 bug。
fn skipMalformed(result: anyerror!void) error{OutOfMemory}!void {
    result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

fn parseDocument(allocator: std.mem.Allocator, svg_data: []const u8) !SvgDocument {
    var doc = SvgDocument{};
    errdefer doc.deinit(allocator);

    const StyleFrame = struct {
        name: []const u8,
        style: ElementStyle,
    };
    var style_stack = std.ArrayList(StyleFrame){};
    defer style_stack.deinit(allocator);
    try style_stack.append(allocator, .{
        .name = "__root__",
        .style = .{ .color = Color.black() },
    });

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, svg_data, i, '<')) |lt| {
        const gt = findTagEnd(svg_data, lt + 1) orelse break;
        i = gt + 1;

        var tag_content = trimAscii(svg_data[lt + 1 .. gt]);
        if (tag_content.len == 0) continue;
        if (tag_content[0] == '!' or tag_content[0] == '?') continue;

        var is_closing = false;
        if (tag_content[0] == '/') {
            is_closing = true;
            tag_content = trimAscii(tag_content[1..]);
        }

        var is_self_closing = false;
        if (!is_closing and tag_content.len > 0 and tag_content[tag_content.len - 1] == '/') {
            is_self_closing = true;
            tag_content = trimAscii(tag_content[0 .. tag_content.len - 1]);
        }
        if (tag_content.len == 0) continue;

        var name_end: usize = 0;
        while (name_end < tag_content.len and !isSpace(tag_content[name_end])) : (name_end += 1) {}
        if (name_end == 0) continue;

        const tag_name = tag_content[0..name_end];
        const attrs = if (name_end < tag_content.len) tag_content[name_end..] else "";

        if (is_closing) {
            if (style_stack.items.len > 1) {
                const top = style_stack.items[style_stack.items.len - 1];
                if (asciiEqIgnoreCase(top.name, tag_name)) {
                    style_stack.items.len -= 1;
                }
            }
            continue;
        }

        const parent_style = style_stack.items[style_stack.items.len - 1].style;

        if (asciiEqIgnoreCase(tag_name, "svg")) {
            parseSvgRootAttrs(&doc, attrs);
            var scoped = parent_style;
            applyAttrsToStyle(&scoped, attrs);
            if (!is_self_closing) {
                try style_stack.append(allocator, .{
                    .name = tag_name,
                    .style = scoped,
                });
            }
            continue;
        }

        if (asciiEqIgnoreCase(tag_name, "path")) {
            try skipMalformed(parsePathElement(allocator, &doc, attrs, parent_style));
        } else if (asciiEqIgnoreCase(tag_name, "rect")) {
            try skipMalformed(parseRectElement(allocator, &doc, attrs, parent_style));
        } else if (asciiEqIgnoreCase(tag_name, "circle")) {
            try skipMalformed(parseCircleElement(allocator, &doc, attrs, parent_style));
        } else if (asciiEqIgnoreCase(tag_name, "ellipse")) {
            try skipMalformed(parseEllipseElement(allocator, &doc, attrs, parent_style));
        } else if (asciiEqIgnoreCase(tag_name, "line")) {
            try skipMalformed(parseLineElement(allocator, &doc, attrs, parent_style));
        } else if (asciiEqIgnoreCase(tag_name, "polygon")) {
            try skipMalformed(parsePolyElement(allocator, &doc, attrs, true, parent_style));
        } else if (asciiEqIgnoreCase(tag_name, "polyline")) {
            try skipMalformed(parsePolyElement(allocator, &doc, attrs, false, parent_style));
        } else {
            var scoped = parent_style;
            applyAttrsToStyle(&scoped, attrs);
            if (!is_self_closing) {
                try style_stack.append(allocator, .{
                    .name = tag_name,
                    .style = scoped,
                });
            }
        }
    }

    if (doc.view_width <= 0 or doc.view_height <= 0) {
        if (computeDocumentBounds(doc.drawables.items)) |bounds| {
            doc.view_min_x = bounds.min_x;
            doc.view_min_y = bounds.min_y;
            doc.view_width = @max(bounds.width(), 1);
            doc.view_height = @max(bounds.height(), 1);
        } else {
            doc.view_min_x = 0;
            doc.view_min_y = 0;
            doc.view_width = choosePositive(doc.width_hint, 0, 256);
            doc.view_height = choosePositive(doc.height_hint, 0, 256);
        }
    }

    return doc;
}

fn parseSvgRootAttrs(doc: *SvgDocument, attrs: []const u8) void {
    var it = AttrIterator{ .raw = attrs };
    while (it.next()) |attr| {
        if (asciiEqIgnoreCase(attr.name, "width")) {
            doc.width_hint = parseDimension(attr.value);
        } else if (asciiEqIgnoreCase(attr.name, "height")) {
            doc.height_hint = parseDimension(attr.value);
        } else if (asciiEqIgnoreCase(attr.name, "viewBox")) {
            if (parseViewBox(attr.value)) |vb| {
                doc.view_min_x = vb[0];
                doc.view_min_y = vb[1];
                doc.view_width = vb[2];
                doc.view_height = vb[3];
            }
        } else if (asciiEqIgnoreCase(attr.name, "preserveAspectRatio")) {
            if (parsePreserveAspectRatio(attr.value)) |par| {
                doc.preserve_aspect_ratio = par;
            }
        }
    }

    if (doc.view_width <= 0 or doc.view_height <= 0) {
        if (doc.width_hint) |w| {
            if (w > 0) doc.view_width = w;
        }
        if (doc.height_hint) |h| {
            if (h > 0) doc.view_height = h;
        }
    }
}

fn parsePathElement(
    allocator: std.mem.Allocator,
    doc: *SvgDocument,
    attrs: []const u8,
    inherited_style: ElementStyle,
) !void {
    var d_value: ?[]const u8 = null;
    var style = inherited_style;

    var it = AttrIterator{ .raw = attrs };
    while (it.next()) |attr| {
        if (asciiEqIgnoreCase(attr.name, "d")) {
            d_value = attr.value;
        } else {
            applyStyleAttr(&style, attr.name, attr.value);
        }
    }

    const d = d_value orelse return;
    const contours = try parsePathContours(allocator, d);
    try appendDrawableOwned(allocator, &doc.drawables, contours, style, true);
}

fn parseRectElement(
    allocator: std.mem.Allocator,
    doc: *SvgDocument,
    attrs: []const u8,
    inherited_style: ElementStyle,
) !void {
    var x: f32 = 0;
    var y: f32 = 0;
    var w: f32 = 0;
    var h: f32 = 0;
    var style = inherited_style;

    var it = AttrIterator{ .raw = attrs };
    while (it.next()) |attr| {
        if (asciiEqIgnoreCase(attr.name, "x")) x = parseDimension(attr.value) orelse x else if (asciiEqIgnoreCase(attr.name, "y")) y = parseDimension(attr.value) orelse y else if (asciiEqIgnoreCase(attr.name, "width")) w = parseDimension(attr.value) orelse w else if (asciiEqIgnoreCase(attr.name, "height")) h = parseDimension(attr.value) orelse h else applyStyleAttr(&style, attr.name, attr.value);
    }

    if (w <= 0 or h <= 0) return;

    const pts = try allocator.alloc(Point, 4);
    pts[0] = .{ .x = x, .y = y };
    pts[1] = .{ .x = x + w, .y = y };
    pts[2] = .{ .x = x + w, .y = y + h };
    pts[3] = .{ .x = x, .y = y + h };

    // contours 分配失败时 pts 尚未被任何容器接管，必须就地释放。
    const contours = allocator.alloc(Contour, 1) catch |e| {
        allocator.free(pts);
        return e;
    };
    contours[0] = .{ .points = pts, .closed = true };

    try appendDrawableOwned(allocator, &doc.drawables, contours, style, true);
}

fn parseCircleElement(
    allocator: std.mem.Allocator,
    doc: *SvgDocument,
    attrs: []const u8,
    inherited_style: ElementStyle,
) !void {
    var cx: f32 = 0;
    var cy: f32 = 0;
    var r: f32 = 0;
    var style = inherited_style;

    var it = AttrIterator{ .raw = attrs };
    while (it.next()) |attr| {
        if (asciiEqIgnoreCase(attr.name, "cx")) cx = parseDimension(attr.value) orelse cx else if (asciiEqIgnoreCase(attr.name, "cy")) cy = parseDimension(attr.value) orelse cy else if (asciiEqIgnoreCase(attr.name, "r")) r = parseDimension(attr.value) orelse r else applyStyleAttr(&style, attr.name, attr.value);
    }

    if (r <= 0) return;

    const pts = try buildEllipsePoints(allocator, cx, cy, r, r);
    // contours 分配失败时 pts 尚未被任何容器接管，必须就地释放。
    const contours = allocator.alloc(Contour, 1) catch |e| {
        allocator.free(pts);
        return e;
    };
    contours[0] = .{ .points = pts, .closed = true };
    try appendDrawableOwned(allocator, &doc.drawables, contours, style, true);
}

fn parseEllipseElement(
    allocator: std.mem.Allocator,
    doc: *SvgDocument,
    attrs: []const u8,
    inherited_style: ElementStyle,
) !void {
    var cx: f32 = 0;
    var cy: f32 = 0;
    var rx: f32 = 0;
    var ry: f32 = 0;
    var style = inherited_style;

    var it = AttrIterator{ .raw = attrs };
    while (it.next()) |attr| {
        if (asciiEqIgnoreCase(attr.name, "cx")) cx = parseDimension(attr.value) orelse cx else if (asciiEqIgnoreCase(attr.name, "cy")) cy = parseDimension(attr.value) orelse cy else if (asciiEqIgnoreCase(attr.name, "rx")) rx = parseDimension(attr.value) orelse rx else if (asciiEqIgnoreCase(attr.name, "ry")) ry = parseDimension(attr.value) orelse ry else applyStyleAttr(&style, attr.name, attr.value);
    }

    if (rx <= 0 or ry <= 0) return;

    const pts = try buildEllipsePoints(allocator, cx, cy, rx, ry);
    // contours 分配失败时 pts 尚未被任何容器接管，必须就地释放。
    const contours = allocator.alloc(Contour, 1) catch |e| {
        allocator.free(pts);
        return e;
    };
    contours[0] = .{ .points = pts, .closed = true };
    try appendDrawableOwned(allocator, &doc.drawables, contours, style, true);
}

fn parseLineElement(
    allocator: std.mem.Allocator,
    doc: *SvgDocument,
    attrs: []const u8,
    inherited_style: ElementStyle,
) !void {
    var x1: f32 = 0;
    var y1: f32 = 0;
    var x2: f32 = 0;
    var y2: f32 = 0;
    var style = inherited_style;

    var it = AttrIterator{ .raw = attrs };
    while (it.next()) |attr| {
        if (asciiEqIgnoreCase(attr.name, "x1")) x1 = parseDimension(attr.value) orelse x1 else if (asciiEqIgnoreCase(attr.name, "y1")) y1 = parseDimension(attr.value) orelse y1 else if (asciiEqIgnoreCase(attr.name, "x2")) x2 = parseDimension(attr.value) orelse x2 else if (asciiEqIgnoreCase(attr.name, "y2")) y2 = parseDimension(attr.value) orelse y2 else applyStyleAttr(&style, attr.name, attr.value);
    }

    const pts = try allocator.alloc(Point, 2);
    pts[0] = .{ .x = x1, .y = y1 };
    pts[1] = .{ .x = x2, .y = y2 };

    // contours 分配失败时 pts 尚未被任何容器接管，必须就地释放。
    const contours = allocator.alloc(Contour, 1) catch |e| {
        allocator.free(pts);
        return e;
    };
    contours[0] = .{ .points = pts, .closed = false };

    try appendDrawableOwned(allocator, &doc.drawables, contours, style, false);
}

fn parsePolyElement(
    allocator: std.mem.Allocator,
    doc: *SvgDocument,
    attrs: []const u8,
    closed: bool,
    inherited_style: ElementStyle,
) !void {
    var points_raw: ?[]const u8 = null;
    var style = inherited_style;

    var it = AttrIterator{ .raw = attrs };
    while (it.next()) |attr| {
        if (asciiEqIgnoreCase(attr.name, "points")) {
            points_raw = attr.value;
        } else {
            applyStyleAttr(&style, attr.name, attr.value);
        }
    }

    const raw = points_raw orelse return;
    const pts = try parsePointList(allocator, raw);
    if (pts.len < 2) {
        allocator.free(pts);
        return;
    }

    // contours 分配失败时 pts 尚未被任何容器接管，必须就地释放。
    const contours = allocator.alloc(Contour, 1) catch |e| {
        allocator.free(pts);
        return e;
    };
    contours[0] = .{ .points = pts, .closed = closed };

    const default_fill = closed;
    try appendDrawableOwned(allocator, &doc.drawables, contours, style, default_fill);
}

fn appendDrawableOwned(
    allocator: std.mem.Allocator,
    drawables: *std.ArrayList(Drawable),
    contours: []Contour,
    style: ElementStyle,
    default_fill: bool,
) !void {
    var fill_color: ?Color = null;
    const default_paint: Paint = if (default_fill) Paint{ .color = Color.black() } else .none;
    const resolved_fill = resolvePaint(style.fill, default_paint, style.color orelse Color.black());
    if (resolved_fill) |base| {
        fill_color = applyCombinedOpacity(base, style.opacity, style.fill_opacity);
        if (fill_color.?.a == 0) fill_color = null;
    }

    var stroke: ?Stroke = null;
    if (resolvePaint(style.stroke, .none, style.color orelse Color.black())) |base| {
        const width = @max(style.stroke_width orelse 1, 0);
        if (width > 0) {
            const stroked = applyCombinedOpacity(base, style.opacity, style.stroke_opacity);
            if (stroked.a > 0) {
                stroke = .{ .color = stroked, .width = width };
            }
        }
    }

    if (fill_color == null and stroke == null) {
        freeContours(allocator, contours);
        return;
    }

    // 所有权合同：本函数接管 contours，成功时交给 drawables，失败时释放。
    drawables.append(allocator, .{
        .contours = contours,
        .fill = fill_color,
        .stroke = stroke,
        .fill_rule = style.fill_rule orelse .nonzero,
    }) catch |e| {
        freeContours(allocator, contours);
        return e;
    };
}

fn freeContours(allocator: std.mem.Allocator, contours: []const Contour) void {
    for (contours) |c| allocator.free(c.points);
    allocator.free(contours);
}

fn resolvePaint(paint: Paint, fallback: Paint, current_color: Color) ?Color {
    return switch (paint) {
        .unset => switch (fallback) {
            .unset, .none => null,
            .current_color => current_color,
            .color => |c| c,
        },
        .none => null,
        .current_color => current_color,
        .color => |c| c,
    };
}

fn applyCombinedOpacity(color: Color, base_opacity: ?f32, local_opacity: ?f32) Color {
    const mul = std.math.clamp((base_opacity orelse 1.0) * (local_opacity orelse 1.0), 0.0, 1.0);
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = @intFromFloat(@as(f32, @floatFromInt(color.a)) * mul),
    };
}

fn buildEllipsePoints(allocator: std.mem.Allocator, cx: f32, cy: f32, rx: f32, ry: f32) ![]Point {
    const segments: usize = 64;
    const pts = try allocator.alloc(Point, segments);
    for (0..segments) |i| {
        const t = 2.0 * std.math.pi * (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)));
        pts[i] = .{
            .x = cx + rx * @cos(t),
            .y = cy + ry * @sin(t),
        };
    }
    return pts;
}

fn parsePathContours(allocator: std.mem.Allocator, d: []const u8) ![]Contour {
    var contours = std.ArrayList(Contour){};
    errdefer {
        for (contours.items) |c| allocator.free(c.points);
        contours.deinit(allocator);
    }

    var points = std.ArrayList(Point){};
    defer points.deinit(allocator);

    var i: usize = 0;
    var cmd: u8 = 0;
    var current = Point{ .x = 0, .y = 0 };
    var subpath_start = current;
    var last_cubic_ctrl: ?Point = null;
    var last_quad_ctrl: ?Point = null;

    while (true) {
        skipNumberSeparators(d, &i);
        if (i >= d.len) break;

        if (isPathCommand(d[i])) {
            cmd = d[i];
            i += 1;
        } else if (cmd == 0) {
            return error.InvalidSvg;
        }

        switch (cmd) {
            'M', 'm' => {
                var first = true;
                while (nextIsNumber(d, i)) {
                    const x = try parseNumber(d, &i);
                    const y = try parseNumber(d, &i);
                    var p = Point{ .x = x, .y = y };
                    if (cmd == 'm') {
                        p.x += current.x;
                        p.y += current.y;
                    }

                    if (first) {
                        if (points.items.len >= 2) {
                            try appendContourOwned(allocator, &contours, &points, false);
                        } else {
                            points.clearRetainingCapacity();
                        }
                        try points.append(allocator, p);
                        current = p;
                        subpath_start = p;
                        first = false;
                    } else {
                        try ensurePathStarted(allocator, &points, current);
                        try appendPointUnique(allocator, &points, p);
                        current = p;
                    }
                    last_cubic_ctrl = null;
                    last_quad_ctrl = null;
                }
                if (first) return error.InvalidSvg;
                cmd = if (cmd == 'm') 'l' else 'L';
            },
            'L', 'l' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    const x = try parseNumber(d, &i);
                    const y = try parseNumber(d, &i);
                    var p = Point{ .x = x, .y = y };
                    if (cmd == 'l') {
                        p.x += current.x;
                        p.y += current.y;
                    }
                    try ensurePathStarted(allocator, &points, current);
                    try appendPointUnique(allocator, &points, p);
                    current = p;
                    had = true;
                }
                if (!had) return error.InvalidSvg;
                last_cubic_ctrl = null;
                last_quad_ctrl = null;
            },
            'H', 'h' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    const x = try parseNumber(d, &i);
                    var p = current;
                    p.x = if (cmd == 'h') current.x + x else x;
                    try ensurePathStarted(allocator, &points, current);
                    try appendPointUnique(allocator, &points, p);
                    current = p;
                    had = true;
                }
                if (!had) return error.InvalidSvg;
                last_cubic_ctrl = null;
                last_quad_ctrl = null;
            },
            'V', 'v' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    const y = try parseNumber(d, &i);
                    var p = current;
                    p.y = if (cmd == 'v') current.y + y else y;
                    try ensurePathStarted(allocator, &points, current);
                    try appendPointUnique(allocator, &points, p);
                    current = p;
                    had = true;
                }
                if (!had) return error.InvalidSvg;
                last_cubic_ctrl = null;
                last_quad_ctrl = null;
            },
            'C', 'c' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    var c1 = Point{ .x = try parseNumber(d, &i), .y = try parseNumber(d, &i) };
                    var c2 = Point{ .x = try parseNumber(d, &i), .y = try parseNumber(d, &i) };
                    var p = Point{ .x = try parseNumber(d, &i), .y = try parseNumber(d, &i) };
                    if (cmd == 'c') {
                        c1.x += current.x;
                        c1.y += current.y;
                        c2.x += current.x;
                        c2.y += current.y;
                        p.x += current.x;
                        p.y += current.y;
                    }
                    try ensurePathStarted(allocator, &points, current);
                    try appendCubicCurve(allocator, &points, current, c1, c2, p);
                    current = p;
                    last_cubic_ctrl = c2;
                    last_quad_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvg;
            },
            'S', 's' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    var c2 = Point{ .x = try parseNumber(d, &i), .y = try parseNumber(d, &i) };
                    var p = Point{ .x = try parseNumber(d, &i), .y = try parseNumber(d, &i) };
                    if (cmd == 's') {
                        c2.x += current.x;
                        c2.y += current.y;
                        p.x += current.x;
                        p.y += current.y;
                    }
                    const c1 = if (last_cubic_ctrl) |prev|
                        Point{ .x = 2 * current.x - prev.x, .y = 2 * current.y - prev.y }
                    else
                        current;

                    try ensurePathStarted(allocator, &points, current);
                    try appendCubicCurve(allocator, &points, current, c1, c2, p);
                    current = p;
                    last_cubic_ctrl = c2;
                    last_quad_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvg;
            },
            'Q', 'q' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    var c = Point{ .x = try parseNumber(d, &i), .y = try parseNumber(d, &i) };
                    var p = Point{ .x = try parseNumber(d, &i), .y = try parseNumber(d, &i) };
                    if (cmd == 'q') {
                        c.x += current.x;
                        c.y += current.y;
                        p.x += current.x;
                        p.y += current.y;
                    }
                    try ensurePathStarted(allocator, &points, current);
                    try appendQuadraticCurve(allocator, &points, current, c, p);
                    current = p;
                    last_quad_ctrl = c;
                    last_cubic_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvg;
            },
            'T', 't' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    var p = Point{ .x = try parseNumber(d, &i), .y = try parseNumber(d, &i) };
                    if (cmd == 't') {
                        p.x += current.x;
                        p.y += current.y;
                    }
                    const c = if (last_quad_ctrl) |prev|
                        Point{ .x = 2 * current.x - prev.x, .y = 2 * current.y - prev.y }
                    else
                        current;

                    try ensurePathStarted(allocator, &points, current);
                    try appendQuadraticCurve(allocator, &points, current, c, p);
                    current = p;
                    last_quad_ctrl = c;
                    last_cubic_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvg;
            },
            'A', 'a' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    const rx = try parseNumber(d, &i);
                    const ry = try parseNumber(d, &i);
                    const x_axis_rotation = try parseNumber(d, &i);
                    const large_arc = (try parseNumber(d, &i)) != 0;
                    const sweep = (try parseNumber(d, &i)) != 0;
                    var p = Point{ .x = try parseNumber(d, &i), .y = try parseNumber(d, &i) };
                    if (cmd == 'a') {
                        p.x += current.x;
                        p.y += current.y;
                    }
                    try ensurePathStarted(allocator, &points, current);
                    try appendArcCurve(allocator, &points, current, p, rx, ry, x_axis_rotation, large_arc, sweep);
                    current = p;
                    last_quad_ctrl = null;
                    last_cubic_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvg;
            },
            'Z', 'z' => {
                if (points.items.len >= 2) {
                    try appendContourOwned(allocator, &contours, &points, true);
                } else {
                    points.clearRetainingCapacity();
                }
                current = subpath_start;
                last_quad_ctrl = null;
                last_cubic_ctrl = null;
                // close has no operands and therefore cannot be implicitly
                // repeated. Clearing it guarantees malformed trailing input
                // advances or returns instead of appending contours forever.
                cmd = 0;
            },
            else => {
                return error.InvalidSvg;
            },
        }
    }

    if (points.items.len >= 2) {
        try appendContourOwned(allocator, &contours, &points, false);
    }

    return contours.toOwnedSlice(allocator);
}

fn appendContourOwned(
    allocator: std.mem.Allocator,
    contours: *std.ArrayList(Contour),
    points: *std.ArrayList(Point),
    closed: bool,
) !void {
    // 先预留槽位再转移点集：toOwnedSlice 之后的 append 若失败，点集已脱离
    // `points` 又没进 `contours`，两边的清理都够不着，泄漏。
    try contours.ensureUnusedCapacity(allocator, 1);
    const owned_points = try points.toOwnedSlice(allocator);
    contours.appendAssumeCapacity(.{
        .points = owned_points,
        .closed = closed,
    });
}

fn ensurePathStarted(allocator: std.mem.Allocator, points: *std.ArrayList(Point), current: Point) !void {
    if (points.items.len == 0) {
        try points.append(allocator, current);
    }
}

fn appendPointUnique(allocator: std.mem.Allocator, points: *std.ArrayList(Point), p: Point) !void {
    if (points.items.len == 0) {
        try points.append(allocator, p);
        return;
    }
    const last = points.items[points.items.len - 1];
    if (@abs(last.x - p.x) <= 0.0001 and @abs(last.y - p.y) <= 0.0001) return;
    try points.append(allocator, p);
}

fn appendCubicCurve(
    allocator: std.mem.Allocator,
    points: *std.ArrayList(Point),
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
) !void {
    const approx = distance(p0, p1) + distance(p1, p2) + distance(p2, p3);
    const segments = boundedSegmentCount(approx / 8, 4, 64);

    for (1..segments + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const it = 1.0 - t;
        const x = it * it * it * p0.x + 3 * it * it * t * p1.x + 3 * it * t * t * p2.x + t * t * t * p3.x;
        const y = it * it * it * p0.y + 3 * it * it * t * p1.y + 3 * it * t * t * p2.y + t * t * t * p3.y;
        try appendPointUnique(allocator, points, .{ .x = x, .y = y });
    }
}

fn appendQuadraticCurve(
    allocator: std.mem.Allocator,
    points: *std.ArrayList(Point),
    p0: Point,
    p1: Point,
    p2: Point,
) !void {
    const approx = distance(p0, p1) + distance(p1, p2);
    const segments = boundedSegmentCount(approx / 8, 4, 48);

    for (1..segments + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const it = 1.0 - t;
        const x = it * it * p0.x + 2 * it * t * p1.x + t * t * p2.x;
        const y = it * it * p0.y + 2 * it * t * p1.y + t * t * p2.y;
        try appendPointUnique(allocator, points, .{ .x = x, .y = y });
    }
}

fn appendArcCurve(
    allocator: std.mem.Allocator,
    points: *std.ArrayList(Point),
    p0: Point,
    p1: Point,
    rx_in: f32,
    ry_in: f32,
    x_axis_rotation: f32,
    large_arc: bool,
    sweep: bool,
) !void {
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);

    if (rx <= 0.0001 or ry <= 0.0001 or (@abs(p0.x - p1.x) <= 0.0001 and @abs(p0.y - p1.y) <= 0.0001)) {
        try appendPointUnique(allocator, points, p1);
        return;
    }

    const phi = x_axis_rotation * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    const dx2 = (p0.x - p1.x) * 0.5;
    const dy2 = (p0.y - p1.y) * 0.5;

    const x1p = cos_phi * dx2 + sin_phi * dy2;
    const y1p = -sin_phi * dx2 + cos_phi * dy2;

    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1.0) {
        const s = @sqrt(lambda);
        rx *= s;
        ry *= s;
    }

    const rx2 = rx * rx;
    const ry2 = ry * ry;
    const x1p2 = x1p * x1p;
    const y1p2 = y1p * y1p;

    const sign: f32 = if (large_arc == sweep) -1.0 else 1.0;
    const denom = rx2 * y1p2 + ry2 * x1p2;
    if (denom <= 0.0000001) {
        try appendPointUnique(allocator, points, p1);
        return;
    }

    const numer = @max(0.0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2);
    const coef = sign * @sqrt(numer / denom);

    const cxp = coef * (rx * y1p / ry);
    const cyp = coef * (-ry * x1p / rx);

    const cx = cos_phi * cxp - sin_phi * cyp + (p0.x + p1.x) * 0.5;
    const cy = sin_phi * cxp + cos_phi * cyp + (p0.y + p1.y) * 0.5;

    const ux = (x1p - cxp) / rx;
    const uy = (y1p - cyp) / ry;
    const vx = (-x1p - cxp) / rx;
    const vy = (-y1p - cyp) / ry;

    const theta1 = angleBetween(1, 0, ux, uy);
    var delta = angleBetween(ux, uy, vx, vy);

    if (!sweep and delta > 0) delta -= 2 * std.math.pi;
    if (sweep and delta < 0) delta += 2 * std.math.pi;

    const segments = boundedSegmentCount(@abs(delta) / (std.math.pi / 8.0), 4, 128);

    for (1..segments + 1) |idx| {
        const t = theta1 + delta * (@as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(segments)));
        const cos_t = @cos(t);
        const sin_t = @sin(t);

        const x = cx + rx * cos_phi * cos_t - ry * sin_phi * sin_t;
        const y = cy + rx * sin_phi * cos_t + ry * cos_phi * sin_t;
        try appendPointUnique(allocator, points, .{ .x = x, .y = y });
    }
}

fn distance(a: Point, b: Point) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

fn boundedSegmentCount(value: f32, min: usize, max: usize) usize {
    return svg_safety.boundedSegmentCount(value, min, max);
}

fn angleBetween(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
    const cross = ux * vy - uy * vx;
    const dot = ux * vx + uy * vy;
    return std.math.atan2(cross, dot);
}

fn rasterPixelCoord(value: f32) ?i32 {
    if (!std.math.isFinite(value)) return null;
    // Only coordinates near the output surface matter. Clamping before the
    // float-to-int conversion also keeps finite-but-extreme SVG geometry safe.
    const limit = @as(f32, @floatFromInt(MAX_RASTER_DIMENSION)) + 2;
    return @intFromFloat(std.math.clamp(value, -2.0, limit));
}

fn rectIsFinite(rect: Rect) bool {
    return std.math.isFinite(rect.min_x) and std.math.isFinite(rect.min_y) and
        std.math.isFinite(rect.max_x) and std.math.isFinite(rect.max_y);
}

fn drawDrawable(
    pixels: []u8,
    out_w: u32,
    out_h: u32,
    view_min_x: f32,
    view_min_y: f32,
    view_w: f32,
    view_h: f32,
    preserve_aspect_ratio: PreserveAspectRatio,
    drawable: Drawable,
    supersample: u8,
) void {
    const bounds = drawableBounds(drawable) orelse return;
    if (!rectIsFinite(bounds) or
        !std.math.isFinite(view_min_x) or !std.math.isFinite(view_min_y) or
        !std.math.isFinite(view_w) or !std.math.isFinite(view_h) or
        view_w <= 0 or view_h <= 0)
    {
        return;
    }

    const out_wf = @as(f32, @floatFromInt(out_w));
    const out_hf = @as(f32, @floatFromInt(out_h));

    var scale_x = out_wf / view_w;
    var scale_y = out_hf / view_h;
    var offset_x: f32 = 0;
    var offset_y: f32 = 0;
    var clip_min_x: f32 = 0;
    var clip_min_y: f32 = 0;
    var clip_max_x: f32 = out_wf;
    var clip_max_y: f32 = out_hf;

    switch (preserve_aspect_ratio.mode) {
        .none => {},
        .meet, .slice => |mode| {
            const sx = out_wf / view_w;
            const sy = out_hf / view_h;
            const uniform = if (mode == .meet) @min(sx, sy) else @max(sx, sy);
            scale_x = uniform;
            scale_y = uniform;

            const content_w = view_w * uniform;
            const content_h = view_h * uniform;
            offset_x = alignOffsetX(preserve_aspect_ratio.alignment, out_wf - content_w);
            offset_y = alignOffsetY(preserve_aspect_ratio.alignment, out_hf - content_h);

            if (mode == .meet) {
                clip_min_x = offset_x;
                clip_min_y = offset_y;
                clip_max_x = offset_x + content_w;
                clip_max_y = offset_y + content_h;
            }
        },
    }

    if (!std.math.isFinite(scale_x) or !std.math.isFinite(scale_y) or
        !std.math.isFinite(offset_x) or !std.math.isFinite(offset_y) or
        !std.math.isFinite(clip_min_x) or !std.math.isFinite(clip_min_y) or
        !std.math.isFinite(clip_max_x) or !std.math.isFinite(clip_max_y))
    {
        return;
    }

    var min_px = (rasterPixelCoord(@floor((bounds.min_x - view_min_x) * scale_x + offset_x)) orelse return) - 1;
    var max_px = (rasterPixelCoord(@ceil((bounds.max_x - view_min_x) * scale_x + offset_x)) orelse return) + 1;
    var min_py = (rasterPixelCoord(@floor((bounds.min_y - view_min_y) * scale_y + offset_y)) orelse return) - 1;
    var max_py = (rasterPixelCoord(@ceil((bounds.max_y - view_min_y) * scale_y + offset_y)) orelse return) + 1;

    if (preserve_aspect_ratio.mode == .meet) {
        min_px = @max(min_px, rasterPixelCoord(@floor(clip_min_x)) orelse return);
        min_py = @max(min_py, rasterPixelCoord(@floor(clip_min_y)) orelse return);
        max_px = @min(max_px, (rasterPixelCoord(@ceil(clip_max_x)) orelse return) - 1);
        max_py = @min(max_py, (rasterPixelCoord(@ceil(clip_max_y)) orelse return) - 1);
    }

    if (max_px < 0 or max_py < 0 or min_px >= @as(i32, @intCast(out_w)) or min_py >= @as(i32, @intCast(out_h))) return;

    min_px = std.math.clamp(min_px, 0, @as(i32, @intCast(out_w)) - 1);
    min_py = std.math.clamp(min_py, 0, @as(i32, @intCast(out_h)) - 1);
    max_px = std.math.clamp(max_px, 0, @as(i32, @intCast(out_w)) - 1);
    max_py = std.math.clamp(max_py, 0, @as(i32, @intCast(out_h)) - 1);

    const ss = @as(u32, supersample);
    const total_samples = ss * ss;
    const ssf = @as(f32, @floatFromInt(supersample));

    var py: i32 = min_py;
    while (py <= max_py) : (py += 1) {
        var px: i32 = min_px;
        while (px <= max_px) : (px += 1) {
            var fill_hits: u32 = 0;
            var stroke_hits: u32 = 0;

            var sy: u32 = 0;
            while (sy < ss) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < ss) : (sx += 1) {
                    const sample_x = @as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sx)) + 0.5) / ssf;
                    const sample_y = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / ssf;

                    if (sample_x < clip_min_x or sample_x >= clip_max_x or sample_y < clip_min_y or sample_y >= clip_max_y) continue;

                    const vx = view_min_x + (sample_x - offset_x) / scale_x;
                    const vy = view_min_y + (sample_y - offset_y) / scale_y;

                    if (drawable.fill != null and pointInDrawable(drawable, vx, vy)) fill_hits += 1;
                    if (drawable.stroke) |stroke| {
                        if (pointOnStroke(drawable, vx, vy, stroke.width)) stroke_hits += 1;
                    }
                }
            }

            const idx = (@as(usize, @intCast(py)) * @as(usize, out_w) + @as(usize, @intCast(px))) * 4;
            if (idx + 4 > pixels.len) continue; // 边界保护

            if (drawable.fill) |fill_color| {
                if (fill_hits > 0) {
                    const coverage = @as(f32, @floatFromInt(fill_hits)) / @as(f32, @floatFromInt(total_samples));
                    blendPixel(pixels[idx .. idx + 4], fill_color, coverage);
                }
            }

            if (drawable.stroke) |stroke| {
                if (stroke_hits > 0) {
                    const coverage = @as(f32, @floatFromInt(stroke_hits)) / @as(f32, @floatFromInt(total_samples));
                    blendPixel(pixels[idx .. idx + 4], stroke.color, coverage);
                }
            }
        }
    }
}

fn drawableFromIconShape(shape: icon_ir.Shape) Drawable {
    return .{
        .contours = shape.contours,
        .fill = if (shape.fill) .{ .r = 255, .g = 255, .b = 255, .a = 255 } else null,
        .stroke = if (shape.stroke_width > 0)
            .{
                .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
                .width = shape.stroke_width,
            }
        else
            null,
        .fill_rule = switch (shape.fill_rule) {
            .nonzero => .nonzero,
            .evenodd => .evenodd,
        },
    };
}

fn drawDrawableMask(
    pixels: []u8,
    out_w: u32,
    out_h: u32,
    view_min_x: f32,
    view_min_y: f32,
    view_w: f32,
    view_h: f32,
    preserve_aspect_ratio: PreserveAspectRatio,
    drawable: Drawable,
    supersample: u8,
) void {
    const bounds = drawableBounds(drawable) orelse return;
    if (!rectIsFinite(bounds) or
        !std.math.isFinite(view_min_x) or !std.math.isFinite(view_min_y) or
        !std.math.isFinite(view_w) or !std.math.isFinite(view_h) or
        view_w <= 0 or view_h <= 0)
    {
        return;
    }

    const out_wf = @as(f32, @floatFromInt(out_w));
    const out_hf = @as(f32, @floatFromInt(out_h));

    var scale_x = out_wf / view_w;
    var scale_y = out_hf / view_h;
    var offset_x: f32 = 0;
    var offset_y: f32 = 0;
    var clip_min_x: f32 = 0;
    var clip_min_y: f32 = 0;
    var clip_max_x: f32 = out_wf;
    var clip_max_y: f32 = out_hf;

    switch (preserve_aspect_ratio.mode) {
        .none => {},
        .meet, .slice => |mode| {
            const sx = out_wf / view_w;
            const sy = out_hf / view_h;
            const uniform = if (mode == .meet) @min(sx, sy) else @max(sx, sy);
            scale_x = uniform;
            scale_y = uniform;

            const content_w = view_w * uniform;
            const content_h = view_h * uniform;
            offset_x = alignOffsetX(preserve_aspect_ratio.alignment, out_wf - content_w);
            offset_y = alignOffsetY(preserve_aspect_ratio.alignment, out_hf - content_h);

            if (mode == .meet) {
                clip_min_x = offset_x;
                clip_min_y = offset_y;
                clip_max_x = offset_x + content_w;
                clip_max_y = offset_y + content_h;
            }
        },
    }

    if (!std.math.isFinite(scale_x) or !std.math.isFinite(scale_y) or
        !std.math.isFinite(offset_x) or !std.math.isFinite(offset_y) or
        !std.math.isFinite(clip_min_x) or !std.math.isFinite(clip_min_y) or
        !std.math.isFinite(clip_max_x) or !std.math.isFinite(clip_max_y))
    {
        return;
    }

    var min_px = (rasterPixelCoord(@floor((bounds.min_x - view_min_x) * scale_x + offset_x)) orelse return) - 1;
    var max_px = (rasterPixelCoord(@ceil((bounds.max_x - view_min_x) * scale_x + offset_x)) orelse return) + 1;
    var min_py = (rasterPixelCoord(@floor((bounds.min_y - view_min_y) * scale_y + offset_y)) orelse return) - 1;
    var max_py = (rasterPixelCoord(@ceil((bounds.max_y - view_min_y) * scale_y + offset_y)) orelse return) + 1;

    if (preserve_aspect_ratio.mode == .meet) {
        min_px = @max(min_px, rasterPixelCoord(@floor(clip_min_x)) orelse return);
        min_py = @max(min_py, rasterPixelCoord(@floor(clip_min_y)) orelse return);
        max_px = @min(max_px, (rasterPixelCoord(@ceil(clip_max_x)) orelse return) - 1);
        max_py = @min(max_py, (rasterPixelCoord(@ceil(clip_max_y)) orelse return) - 1);
    }

    if (max_px < 0 or max_py < 0 or min_px >= @as(i32, @intCast(out_w)) or min_py >= @as(i32, @intCast(out_h))) return;

    min_px = std.math.clamp(min_px, 0, @as(i32, @intCast(out_w)) - 1);
    min_py = std.math.clamp(min_py, 0, @as(i32, @intCast(out_h)) - 1);
    max_px = std.math.clamp(max_px, 0, @as(i32, @intCast(out_w)) - 1);
    max_py = std.math.clamp(max_py, 0, @as(i32, @intCast(out_h)) - 1);

    const ss = @as(u32, supersample);
    const total_samples = ss * ss;
    const ssf = @as(f32, @floatFromInt(supersample));

    var py: i32 = min_py;
    while (py <= max_py) : (py += 1) {
        var px: i32 = min_px;
        while (px <= max_px) : (px += 1) {
            var fill_hits: u32 = 0;
            var stroke_hits: u32 = 0;

            var sy: u32 = 0;
            while (sy < ss) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < ss) : (sx += 1) {
                    const sample_x = @as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sx)) + 0.5) / ssf;
                    const sample_y = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / ssf;

                    if (sample_x < clip_min_x or sample_x >= clip_max_x or sample_y < clip_min_y or sample_y >= clip_max_y) continue;

                    const vx = view_min_x + (sample_x - offset_x) / scale_x;
                    const vy = view_min_y + (sample_y - offset_y) / scale_y;

                    if (drawable.fill != null and pointInDrawable(drawable, vx, vy)) fill_hits += 1;
                    if (drawable.stroke) |stroke| {
                        if (pointOnStroke(drawable, vx, vy, stroke.width)) stroke_hits += 1;
                    }
                }
            }

            const idx = @as(usize, @intCast(py)) * @as(usize, out_w) + @as(usize, @intCast(px));
            if (idx >= pixels.len) continue;

            var max_coverage: f32 = @as(f32, @floatFromInt(fill_hits)) / @as(f32, @floatFromInt(total_samples));
            if (stroke_hits > 0) {
                const stroke_coverage = @as(f32, @floatFromInt(stroke_hits)) / @as(f32, @floatFromInt(total_samples));
                max_coverage = @max(max_coverage, stroke_coverage);
            }
            blendAlpha(&pixels[idx], max_coverage);
        }
    }
}

fn blendAlpha(dst_alpha: *u8, coverage: f32) void {
    const src_a = std.math.clamp(coverage, 0.0, 1.0);
    if (src_a <= 0.000001) return;
    const dst_a = @as(f32, @floatFromInt(dst_alpha.*)) / 255.0;
    const out_a = src_a + dst_a * (1.0 - src_a);
    dst_alpha.* = @intFromFloat(std.math.clamp(out_a * 255.0, 0.0, 255.0));
}

fn drawableBounds(drawable: Drawable) ?Rect {
    var first = true;
    var rect = Rect{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 };

    for (drawable.contours) |contour| {
        for (contour.points) |p| {
            if (first) {
                rect = .{ .min_x = p.x, .min_y = p.y, .max_x = p.x, .max_y = p.y };
                first = false;
            } else {
                rect.min_x = @min(rect.min_x, p.x);
                rect.min_y = @min(rect.min_y, p.y);
                rect.max_x = @max(rect.max_x, p.x);
                rect.max_y = @max(rect.max_y, p.y);
            }
        }
    }

    if (first) return null;

    if (drawable.stroke) |stroke| {
        rect.expand(stroke.width * 0.5 + 1.0);
    }

    return rect;
}

fn computeDocumentBounds(drawables: []const Drawable) ?Rect {
    var first = true;
    var out: Rect = undefined;
    for (drawables) |d| {
        if (drawableBounds(d)) |r| {
            if (first) {
                out = r;
                first = false;
            } else {
                out.min_x = @min(out.min_x, r.min_x);
                out.min_y = @min(out.min_y, r.min_y);
                out.max_x = @max(out.max_x, r.max_x);
                out.max_y = @max(out.max_y, r.max_y);
            }
        }
    }
    return if (first) null else out;
}

fn pointInDrawable(drawable: Drawable, x: f32, y: f32) bool {
    return switch (drawable.fill_rule) {
        .evenodd => pointInDrawableEvenOdd(drawable, x, y),
        .nonzero => pointInDrawableNonZero(drawable, x, y),
    };
}

fn pointInDrawableEvenOdd(drawable: Drawable, x: f32, y: f32) bool {
    var inside = false;
    for (drawable.contours) |contour| {
        if (contour.points.len < 3) continue;
        if (pointInContourEvenOdd(contour, x, y)) inside = !inside;
    }
    return inside;
}

fn pointInContourEvenOdd(contour: Contour, x: f32, y: f32) bool {
    var inside = false;
    var i: usize = 0;
    const n = contour.points.len;
    while (i < n) : (i += 1) {
        const a = contour.points[i];
        const b = contour.points[(i + 1) % n];

        const intersects = ((a.y > y) != (b.y > y)) and
            (x < (b.x - a.x) * (y - a.y) / (b.y - a.y + 0.0000001) + a.x);
        if (intersects) inside = !inside;
    }
    return inside;
}

fn pointInDrawableNonZero(drawable: Drawable, x: f32, y: f32) bool {
    var winding: i32 = 0;
    for (drawable.contours) |contour| {
        if (contour.points.len < 3) continue;
        winding += contourWinding(contour, x, y);
    }
    return winding != 0;
}

fn contourWinding(contour: Contour, x: f32, y: f32) i32 {
    var winding: i32 = 0;
    var i: usize = 0;
    const n = contour.points.len;
    while (i < n) : (i += 1) {
        const a = contour.points[i];
        const b = contour.points[(i + 1) % n];

        if (a.y <= y) {
            if (b.y > y and isLeft(a, b, x, y) > 0) winding += 1;
        } else {
            if (b.y <= y and isLeft(a, b, x, y) < 0) winding -= 1;
        }
    }
    return winding;
}

fn isLeft(a: Point, b: Point, x: f32, y: f32) f32 {
    return (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y);
}

fn pointOnStroke(drawable: Drawable, x: f32, y: f32, width: f32) bool {
    const half = width * 0.5;
    const limit_sq = half * half;

    for (drawable.contours) |contour| {
        if (contour.points.len < 2) continue;

        const segment_count = if (contour.closed) contour.points.len else contour.points.len - 1;
        var i: usize = 0;
        while (i < segment_count) : (i += 1) {
            const a = contour.points[i];
            const b = contour.points[(i + 1) % contour.points.len];
            if (pointSegmentDistanceSq(x, y, a, b) <= limit_sq) return true;
        }
    }

    return false;
}

fn pointSegmentDistanceSq(px: f32, py: f32, a: Point, b: Point) f32 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const wx = px - a.x;
    const wy = py - a.y;

    const vv = vx * vx + vy * vy;
    if (vv <= 0.0000001) {
        const dx = px - a.x;
        const dy = py - a.y;
        return dx * dx + dy * dy;
    }

    var t = (wx * vx + wy * vy) / vv;
    t = std.math.clamp(t, 0.0, 1.0);

    const proj_x = a.x + t * vx;
    const proj_y = a.y + t * vy;
    const dx = px - proj_x;
    const dy = py - proj_y;
    return dx * dx + dy * dy;
}

fn blendPixel(dst_rgba: []u8, src: Color, coverage: f32) void {
    const src_a = (@as(f32, @floatFromInt(src.a)) / 255.0) * std.math.clamp(coverage, 0.0, 1.0);
    if (src_a <= 0.000001) return;

    const dst_a = @as(f32, @floatFromInt(dst_rgba[3])) / 255.0;
    const out_a = src_a + dst_a * (1.0 - src_a);

    const src_r = @as(f32, @floatFromInt(src.r)) / 255.0;
    const src_g = @as(f32, @floatFromInt(src.g)) / 255.0;
    const src_b = @as(f32, @floatFromInt(src.b)) / 255.0;

    const dst_r = @as(f32, @floatFromInt(dst_rgba[0])) / 255.0;
    const dst_g = @as(f32, @floatFromInt(dst_rgba[1])) / 255.0;
    const dst_b = @as(f32, @floatFromInt(dst_rgba[2])) / 255.0;

    var out_r: f32 = 0;
    var out_g: f32 = 0;
    var out_b: f32 = 0;

    if (out_a > 0.000001) {
        out_r = (src_r * src_a + dst_r * dst_a * (1.0 - src_a)) / out_a;
        out_g = (src_g * src_a + dst_g * dst_a * (1.0 - src_a)) / out_a;
        out_b = (src_b * src_a + dst_b * dst_a * (1.0 - src_a)) / out_a;
    }

    dst_rgba[0] = @intFromFloat(std.math.clamp(out_r * 255.0, 0.0, 255.0));
    dst_rgba[1] = @intFromFloat(std.math.clamp(out_g * 255.0, 0.0, 255.0));
    dst_rgba[2] = @intFromFloat(std.math.clamp(out_b * 255.0, 0.0, 255.0));
    dst_rgba[3] = @intFromFloat(std.math.clamp(out_a * 255.0, 0.0, 255.0));
}

fn applyAttrsToStyle(style: *ElementStyle, attrs: []const u8) void {
    var it = AttrIterator{ .raw = attrs };
    while (it.next()) |attr| {
        applyStyleAttr(style, attr.name, attr.value);
    }
}

fn applyStyleAttr(style: *ElementStyle, key: []const u8, value: []const u8) void {
    if (asciiEqIgnoreCase(key, "style")) {
        parseStyleDecls(style, value);
        return;
    }

    applyStyleDecl(style, key, value);
}

fn parseStyleDecls(style: *ElementStyle, raw: []const u8) void {
    var it = std.mem.splitScalar(u8, raw, ';');
    while (it.next()) |pair| {
        const p = trimAscii(pair);
        if (p.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, p, ':') orelse continue;
        const key = trimAscii(p[0..sep]);
        const value = trimAscii(p[sep + 1 ..]);
        applyStyleDecl(style, key, value);
    }
}

fn applyStyleDecl(style: *ElementStyle, key: []const u8, value: []const u8) void {
    if (asciiEqIgnoreCase(key, "fill")) {
        style.fill = parsePaint(value);
    } else if (asciiEqIgnoreCase(key, "stroke")) {
        style.stroke = parsePaint(value);
    } else if (asciiEqIgnoreCase(key, "color")) {
        style.color = parseColor(value) orelse style.color;
    } else if (asciiEqIgnoreCase(key, "stroke-width")) {
        style.stroke_width = parseDimension(value) orelse style.stroke_width;
    } else if (asciiEqIgnoreCase(key, "opacity")) {
        style.opacity = parseOpacity(value) orelse style.opacity;
    } else if (asciiEqIgnoreCase(key, "fill-opacity")) {
        style.fill_opacity = parseOpacity(value) orelse style.fill_opacity;
    } else if (asciiEqIgnoreCase(key, "stroke-opacity")) {
        style.stroke_opacity = parseOpacity(value) orelse style.stroke_opacity;
    } else if (asciiEqIgnoreCase(key, "fill-rule")) {
        const v = trimAscii(value);
        if (asciiEqIgnoreCase(v, "evenodd")) style.fill_rule = .evenodd else if (asciiEqIgnoreCase(v, "nonzero")) style.fill_rule = .nonzero;
    }
}

fn parsePaint(value: []const u8) Paint {
    const v = trimAscii(value);
    if (v.len == 0) return .unset;
    if (asciiEqIgnoreCase(v, "none")) return .none;
    if (asciiEqIgnoreCase(v, "currentColor")) return .current_color;
    if (parseColor(v)) |c| return .{ .color = c };
    return .unset;
}

fn parseOpacity(value: []const u8) ?f32 {
    const v = trimAscii(value);
    if (v.len == 0) return null;
    if (std.mem.indexOfScalar(u8, v, '%') != null) {
        const pct = parseUnitFloat(v) orelse return null;
        return std.math.clamp(pct / 100.0, 0.0, 1.0);
    }
    return std.math.clamp(parseUnitFloat(v) orelse return null, 0.0, 1.0);
}

fn parseColor(value: []const u8) ?Color {
    const v = trimAscii(value);
    if (v.len == 0) return null;

    if (v[0] == '#') {
        return parseHexColor(v[1..]);
    }

    if (startsWithIgnoreCase(v, "rgb(")) {
        return parseRgbFunc(v, false);
    }
    if (startsWithIgnoreCase(v, "rgba(")) {
        return parseRgbFunc(v, true);
    }

    if (asciiEqIgnoreCase(v, "black")) return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    if (asciiEqIgnoreCase(v, "white")) return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    if (asciiEqIgnoreCase(v, "red")) return .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    if (asciiEqIgnoreCase(v, "green")) return .{ .r = 0, .g = 128, .b = 0, .a = 255 };
    if (asciiEqIgnoreCase(v, "blue")) return .{ .r = 0, .g = 0, .b = 255, .a = 255 };

    return null;
}

fn parseHexColor(hex: []const u8) ?Color {
    if (hex.len == 3 or hex.len == 4) {
        const r = parseHexNibble(hex[0]) orelse return null;
        const g = parseHexNibble(hex[1]) orelse return null;
        const b = parseHexNibble(hex[2]) orelse return null;
        const a: u8 = if (hex.len == 4) blk: {
            const v = parseHexNibble(hex[3]) orelse return null;
            break :blk v * 17;
        } else 255;

        return .{ .r = r * 17, .g = g * 17, .b = b * 17, .a = a };
    }

    if (hex.len == 6 or hex.len == 8) {
        const r = parseHexByte(hex[0..2]) orelse return null;
        const g = parseHexByte(hex[2..4]) orelse return null;
        const b = parseHexByte(hex[4..6]) orelse return null;
        const a: u8 = if (hex.len == 8) parseHexByte(hex[6..8]) orelse return null else 255;
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    return null;
}

fn parseHexNibble(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn parseHexByte(two: []const u8) ?u8 {
    if (two.len != 2) return null;
    const hi = parseHexNibble(two[0]) orelse return null;
    const lo = parseHexNibble(two[1]) orelse return null;
    return hi * 16 + lo;
}

fn parseRgbFunc(value: []const u8, has_alpha: bool) ?Color {
    const start = std.mem.indexOfScalar(u8, value, '(') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, value, ')') orelse return null;
    if (end <= start) return null;

    const inner = value[start + 1 .. end];
    var i: usize = 0;

    const r = parseColorComponent(inner, &i) orelse return null;
    const g = parseColorComponent(inner, &i) orelse return null;
    const b = parseColorComponent(inner, &i) orelse return null;

    var a: u8 = 255;
    if (has_alpha) {
        const alpha_f = parseAlphaComponent(inner, &i) orelse return null;
        a = @intFromFloat(std.math.clamp(alpha_f * 255.0, 0.0, 255.0));
    }

    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn parseColorComponent(s: []const u8, index: *usize) ?u8 {
    const token = nextCsvToken(s, index) orelse return null;
    if (std.mem.indexOfScalar(u8, token, '%') != null) {
        const pct = parseUnitFloat(token) orelse return null;
        return @intFromFloat(std.math.clamp(pct, 0, 100) / 100.0 * 255.0);
    }
    const val = parseUnitFloat(token) orelse return null;
    return @intFromFloat(std.math.clamp(val, 0, 255));
}

fn parseAlphaComponent(s: []const u8, index: *usize) ?f32 {
    const token = nextCsvToken(s, index) orelse return null;
    if (std.mem.indexOfScalar(u8, token, '%') != null) {
        const pct = parseUnitFloat(token) orelse return null;
        return std.math.clamp(pct / 100.0, 0.0, 1.0);
    }
    return std.math.clamp(parseUnitFloat(token) orelse return null, 0.0, 1.0);
}

fn nextCsvToken(s: []const u8, index: *usize) ?[]const u8 {
    while (index.* < s.len and (isSpace(s[index.*]) or s[index.*] == ',')) : (index.* += 1) {}
    if (index.* >= s.len) return null;

    const start = index.*;
    while (index.* < s.len and s[index.*] != ',') : (index.* += 1) {}
    const token = trimAscii(s[start..index.*]);
    if (index.* < s.len and s[index.*] == ',') index.* += 1;
    return token;
}

fn parsePointList(allocator: std.mem.Allocator, raw: []const u8) ![]Point {
    var points = std.ArrayList(Point){};
    errdefer points.deinit(allocator);

    var i: usize = 0;
    while (nextIsNumber(raw, i)) {
        const x = try parseNumber(raw, &i);
        const y = try parseNumber(raw, &i);
        try points.append(allocator, .{ .x = x, .y = y });
    }

    return points.toOwnedSlice(allocator);
}

fn parseViewBox(value: []const u8) ?[4]f32 {
    var i: usize = 0;
    var out: [4]f32 = undefined;
    var idx: usize = 0;

    while (idx < 4 and nextIsNumber(value, i)) : (idx += 1) {
        out[idx] = parseNumber(value, &i) catch return null;
    }

    if (idx != 4) return null;
    if (out[2] <= 0 or out[3] <= 0) return null;
    return out;
}

fn parsePreserveAspectRatio(value: []const u8) ?PreserveAspectRatio {
    const raw = trimAscii(value);
    if (raw.len == 0) return null;

    var result = PreserveAspectRatio{};
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");

    const first = it.next() orelse return null;
    if (asciiEqIgnoreCase(first, "none")) {
        result.mode = .none;
        result.alignment = .x_min_y_min;
    } else {
        result.alignment = parsePreserveAspectAlign(first) orelse return null;
    }

    if (it.next()) |second| {
        if (asciiEqIgnoreCase(second, "meet")) {
            result.mode = .meet;
        } else if (asciiEqIgnoreCase(second, "slice")) {
            result.mode = .slice;
        } else {
            return null;
        }
    }

    return result;
}

fn parsePreserveAspectAlign(value: []const u8) ?PreserveAspectAlign {
    if (asciiEqIgnoreCase(value, "xMinYMin")) return .x_min_y_min;
    if (asciiEqIgnoreCase(value, "xMidYMin")) return .x_mid_y_min;
    if (asciiEqIgnoreCase(value, "xMaxYMin")) return .x_max_y_min;
    if (asciiEqIgnoreCase(value, "xMinYMid")) return .x_min_y_mid;
    if (asciiEqIgnoreCase(value, "xMidYMid")) return .x_mid_y_mid;
    if (asciiEqIgnoreCase(value, "xMaxYMid")) return .x_max_y_mid;
    if (asciiEqIgnoreCase(value, "xMinYMax")) return .x_min_y_max;
    if (asciiEqIgnoreCase(value, "xMidYMax")) return .x_mid_y_max;
    if (asciiEqIgnoreCase(value, "xMaxYMax")) return .x_max_y_max;
    return null;
}

fn alignOffsetX(alignment: PreserveAspectAlign, spare: f32) f32 {
    return switch (alignment) {
        .x_min_y_min, .x_min_y_mid, .x_min_y_max => 0,
        .x_mid_y_min, .x_mid_y_mid, .x_mid_y_max => spare * 0.5,
        .x_max_y_min, .x_max_y_mid, .x_max_y_max => spare,
    };
}

fn alignOffsetY(alignment: PreserveAspectAlign, spare: f32) f32 {
    return switch (alignment) {
        .x_min_y_min, .x_mid_y_min, .x_max_y_min => 0,
        .x_min_y_mid, .x_mid_y_mid, .x_max_y_mid => spare * 0.5,
        .x_min_y_max, .x_mid_y_max, .x_max_y_max => spare,
    };
}

fn parseDimension(value: []const u8) ?f32 {
    return parseUnitFloat(value);
}

/// 解析带单位的 CSS 属性值（`width="10px"`）：解析前导数字，忽略尾部单位。
///
/// ⚠ 这是 `svg_safety.parseFiniteNumber` 的**近似重复**，但**不能**直接合并：
/// 两者对分隔符的语义不同，parseFiniteNumber 服务 path data（`M 10,20`），
/// 会先 skipNumberSeparators 吃掉前导逗号/空白；而 CSS 属性值里前导逗号是
/// 非法的，必须拒绝（`width=",10"` 不是 10）。
///
/// 数值解析核心（符号/小数点/指数/isFinite 拒绝）实测与 parseFiniteNumber
/// **完全一致**：排除分隔符字符后 20 万轮随机输入零差异（2026-09-22）。
/// 改动任何一边的数值逻辑时，另一边必须同步，下面的测试锁住这条等价性。
fn parseUnitFloat(value: []const u8) ?f32 {
    const v = trimAscii(value);
    if (v.len == 0) return null;

    var i: usize = 0;
    if (v[i] == '+' or v[i] == '-') i += 1;

    var has_digit = false;
    while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) has_digit = true;
    if (i < v.len and v[i] == '.') {
        i += 1;
        while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) has_digit = true;
    }

    if (!has_digit) return null;

    if (i < v.len and (v[i] == 'e' or v[i] == 'E')) {
        i += 1;
        if (i < v.len and (v[i] == '+' or v[i] == '-')) i += 1;
        var exp_has_digit = false;
        while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) exp_has_digit = true;
        if (!exp_has_digit) return null;
    }

    const parsed = std.fmt.parseFloat(f32, v[0..i]) catch return null;
    return if (std.math.isFinite(parsed)) parsed else null;
}

fn parseNumber(s: []const u8, index: *usize) !f32 {
    return svg_safety.parseFiniteNumber(s, index) orelse error.InvalidSvg;
}

fn nextIsNumber(s: []const u8, index: usize) bool {
    return svg_safety.nextIsNumber(s, index);
}

fn skipNumberSeparators(s: []const u8, index: *usize) void {
    svg_safety.skipNumberSeparators(s, index);
}

fn isPathCommand(c: u8) bool {
    return switch (c) {
        'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z' => true,
        else => false,
    };
}

const Attr = struct {
    name: []const u8,
    value: []const u8,
};

const AttrIterator = struct {
    raw: []const u8,
    index: usize = 0,

    fn next(self: *AttrIterator) ?Attr {
        while (self.index < self.raw.len and isSpace(self.raw[self.index])) : (self.index += 1) {}
        if (self.index >= self.raw.len) return null;

        const name_start = self.index;
        while (self.index < self.raw.len) : (self.index += 1) {
            const c = self.raw[self.index];
            if (isSpace(c) or c == '=') break;
        }
        const name = self.raw[name_start..self.index];

        while (self.index < self.raw.len and isSpace(self.raw[self.index])) : (self.index += 1) {}

        var value: []const u8 = "";
        if (self.index < self.raw.len and self.raw[self.index] == '=') {
            self.index += 1;
            while (self.index < self.raw.len and isSpace(self.raw[self.index])) : (self.index += 1) {}

            if (self.index < self.raw.len and (self.raw[self.index] == '"' or self.raw[self.index] == '\'')) {
                const quote = self.raw[self.index];
                self.index += 1;
                const start = self.index;
                while (self.index < self.raw.len and self.raw[self.index] != quote) : (self.index += 1) {}
                value = self.raw[start..@min(self.index, self.raw.len)];
                if (self.index < self.raw.len) self.index += 1;
            } else {
                const start = self.index;
                while (self.index < self.raw.len and !isSpace(self.raw[self.index])) : (self.index += 1) {}
                value = self.raw[start..self.index];
            }
        }

        return .{ .name = trimAscii(name), .value = trimAscii(value) };
    }
};

fn findTagEnd(s: []const u8, from: usize) ?usize {
    var i = from;
    var quote: ?u8 = null;

    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }

        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }

        if (c == '>') return i;
    }

    return null;
}

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

test "svg rasterize simple rect" {
    const allocator = std.testing.allocator;
    const svg =
        \\<svg viewBox="0 0 100 100">
        \\  <rect x="10" y="10" width="80" height="80" fill="#ff0000"/>
        \\</svg>
    ;

    var image = try rasterize(allocator, svg, .{ .target_width = 64, .target_height = 64, .supersample = 2 });
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 64), image.width);
    try std.testing.expectEqual(@as(u32, 64), image.height);

    const center = ((32 * image.width) + 32) * 4;
    try std.testing.expect(image.pixels[center + 0] > 200);
    try std.testing.expect(image.pixels[center + 3] > 200);
}

test "svg rasterize path" {
    const allocator = std.testing.allocator;
    const svg =
        \\<svg viewBox="0 0 24 24">
        \\  <path d="M3 3 L21 3 L21 21 L3 21 Z" fill="#00ff00"/>
        \\</svg>
    ;

    var image = try rasterize(allocator, svg, .{ .target_width = 48, .target_height = 48 });
    defer image.deinit(allocator);

    const center = ((24 * image.width) + 24) * 4;
    try std.testing.expect(image.pixels[center + 1] > 180);
    try std.testing.expect(image.pixels[center + 3] > 180);
}

test "svg path close rejects trailing operands instead of looping" {
    try std.testing.expectError(
        error.InvalidSvg,
        parsePathContours(std.testing.allocator, "M0 0 Z 5"),
    );
}

test "svg inherits stroke from root svg" {
    const allocator = std.testing.allocator;
    const svg =
        \\<svg viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2">
        \\  <path d="M4 12 L20 12"></path>
        \\</svg>
    ;

    var image = try rasterize(allocator, svg, .{ .target_width = 48, .target_height = 48 });
    defer image.deinit(allocator);

    const center = ((24 * image.width) + 24) * 4;
    try std.testing.expect(image.pixels[center + 3] > 0);
}

test "svg currentColor resolves from inherited color" {
    const allocator = std.testing.allocator;
    const svg =
        \\<svg viewBox="0 0 24 24" color="#ff0000">
        \\  <path d="M3 3 L21 3 L21 21 L3 21 Z" fill="currentColor"></path>
        \\</svg>
    ;

    var image = try rasterize(allocator, svg, .{ .target_width = 48, .target_height = 48 });
    defer image.deinit(allocator);

    const center = ((24 * image.width) + 24) * 4;
    try std.testing.expect(image.pixels[center + 0] > 200);
    try std.testing.expect(image.pixels[center + 1] < 30);
    try std.testing.expect(image.pixels[center + 2] < 30);
    try std.testing.expect(image.pixels[center + 3] > 200);
}

test "svg default preserveAspectRatio keeps aspect ratio" {
    const allocator = std.testing.allocator;
    const svg =
        \\<svg viewBox="0 0 100 50">
        \\  <rect x="0" y="0" width="100" height="50" fill="#ff0000"/>
        \\</svg>
    ;

    var image = try rasterize(allocator, svg, .{ .target_width = 100, .target_height = 100, .supersample = 1 });
    defer image.deinit(allocator);

    const top = ((5 * image.width) + 50) * 4;
    const middle = ((50 * image.width) + 50) * 4;
    try std.testing.expect(image.pixels[top + 3] == 0);
    try std.testing.expect(image.pixels[middle + 3] > 200);
}

test "svg opacity percentage parses correctly" {
    const allocator = std.testing.allocator;
    const svg =
        \\<svg viewBox="0 0 10 10">
        \\  <rect x="0" y="0" width="10" height="10" fill="#ff0000" opacity="50%"/>
        \\</svg>
    ;

    var image = try rasterize(allocator, svg, .{ .target_width = 10, .target_height = 10, .supersample = 1 });
    defer image.deinit(allocator);

    const center = ((5 * image.width) + 5) * 4;
    try std.testing.expect(image.pixels[center + 3] >= 120 and image.pixels[center + 3] <= 135);
}

test "svg rasterization bounds extreme dimensions and curve geometry" {
    const allocator = std.testing.allocator;
    const oversized =
        \\<svg width="1e30" height="1e30">
        \\  <rect x="0" y="0" width="1" height="1" fill="#fff"/>
        \\</svg>
    ;
    try std.testing.expectError(error.InvalidSvg, rasterize(allocator, oversized, .{}));

    const huge_curve =
        \\<svg viewBox="0 0 1e30 1e30">
        \\  <path d="M0 0 C1e30 0 0 1e30 1e30 1e30" fill="none" stroke="#fff"/>
        \\</svg>
    ;
    var image = try rasterize(allocator, huge_curve, .{ .target_width = 8, .target_height = 8 });
    defer image.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
}

test "parseUnitFloat 与 svg_safety.parseFiniteNumber 的数值核心必须保持一致" {
    // 两份实现逐字节重复（见 parseUnitFloat 的文档注释：分隔符语义不同，
    // 不能合并）。这个测试锁住「除分隔符外行为一致」，让任何一边的数值
    // 逻辑改动都会在另一边暴露出来，安全修复最怕的就是悄悄分叉。
    //
    // 用例不含逗号/空白：那是两者**有意**分歧的地方。
    const cases = [_][]const u8{
        "0",   "1",   "-1",   "+1",   "1.5",   "-1.5",  ".5",   "-.5",
        "1e3", "1E3", "1e+3", "1e-3", "-1e-3", "1.5e2", "10px", "2.5em",
        "50%", "3pt", "e5",   "E",    "+",     "-",     ".",    "+.",
        "-.",  "1e",  "1e+",  "1e-",  "..",    "--1",   "++1",
        "1e999999", "-1e999999", // 溢出 ⇒ 两边都必须靠 isFinite 拒绝
        "",         "px",
        "abc",
    };

    for (cases) |c| {
        const via_unit = parseUnitFloat(c);
        var i: usize = 0;
        const via_safety = svg_safety.parseFiniteNumber(c, &i);

        try std.testing.expectEqual(via_unit == null, via_safety == null);
        if (via_unit) |a| {
            const b = via_safety.?;
            try std.testing.expectEqual(a, b);
            // 两边都只放行有限值
            try std.testing.expect(std.math.isFinite(a));
        }
    }
}

test "parseUnitFloat 拒绝前导分隔符（与 path data 的有意分歧）" {
    // CSS 属性值里前导逗号非法：`width=",10"` 不是 10。
    // 而 path data 的 parseFiniteNumber 会吃掉它，这是两者唯一的分歧点，
    // 显式锁住，免得日后有人"统一"时把它抹平。
    try std.testing.expectEqual(@as(?f32, null), parseUnitFloat(",10"));

    var i: usize = 0;
    try std.testing.expectEqual(@as(?f32, 10), svg_safety.parseFiniteNumber(",10", &i));
}

test "svg 解析在任意一次分配失败时不泄漏（checkAllAllocationFailures）" {
    // 回归：rect/circle/ellipse 先分配 points 再分配 contours，后者失败时
    // points 泄漏；appendDrawableOwned 的 drawables.append 失败时 contours
    // 泄漏；appendContourOwned toOwnedSlice 之后 append 失败时点集泄漏。
    const svg =
        \\<svg viewBox="0 0 24 24" stroke="#000" stroke-width="2">
        \\  <g fill="#123456">
        \\    <rect x="1" y="1" width="10" height="10"/>
        \\    <circle cx="12" cy="12" r="5"/>
        \\    <ellipse cx="6" cy="18" rx="4" ry="2"/>
        \\  </g>
        \\  <line x1="0" y1="0" x2="24" y2="24"/>
        \\  <polyline points="1,1 5,5 9,1 13,5" fill="none"/>
        \\  <polygon points="2,20 6,22 4,23"/>
        \\  <path d="M3 3 L21 3 L21 21 Z M5 5 C6 6 7 7 8 5 Q9 9 10 5 L12 12 Z L14 14"/>
        \\</svg>
    ;
    const Wrap = struct {
        fn raster(allocator: std.mem.Allocator, data: []const u8) !void {
            var image = try rasterize(allocator, data, .{ .target_width = 24, .target_height = 24 });
            image.deinit(allocator);
        }
        fn rep(allocator: std.mem.Allocator, data: []const u8) !void {
            var owned = try parseToOwnedRep(allocator, data, 24);
            owned.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Wrap.raster, .{svg});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Wrap.rep, .{svg});
}
