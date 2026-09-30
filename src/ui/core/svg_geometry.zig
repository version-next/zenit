//! Pure (Cx-free) SVG / icon geometry helpers used by node builders.
//!
//! Splits cleanly out of `core.zig`:
//!   - `parseSvgIntrinsicSize` / `findSvgAttributeValue` / `parseSvgLength` /
//!     `parseSvgViewBox` — extract width/height from `<svg>` markup.
//!   - `resolveSvgRasterSize` — final pixel size for SVG rasterization, taking
//!     window scale + oversample into account. (Caller passes scale directly,
//!     not a `*Cx`, so this stays a pure helper.)
//!   - `createIconPathGeometry` / `computePathGeometryBounds` — convert an
//!     `icon_ir.Rep` into a `PathGeometry` for hit-testing.
//!   - `hashSvgTexture` — stable cache-key hash for an SVG's bytes.
//!
//! Extracted from `core.zig` to keep that file focused on the `Cx` runtime.
//! No behavior change.
const std = @import("std");
const Allocator = std.mem.Allocator;

const icon_ir = @import("icon_ir");
const types = @import("types.zig");
const svg_assets_mod = @import("../svg_assets.zig");

const Sizing = types.Sizing;
const Style = types.Style;
const ComputedRect = types.ComputedRect;
const PathFillRule = types.PathFillRule;
const PathGeometry = types.PathGeometry;
const PathCommand = types.PathCommand;

pub fn hashSvgTexture(svg_data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, svg_data);
}

/// Build a hit-testable `PathGeometry` from an icon IR representation.
/// Each contour becomes a `move_to` + n `line_to`s; closed contours add a
/// `close`. The resulting commands are owned by the caller (`.owned = true`).
pub fn createIconPathGeometry(allocator: Allocator, rep: icon_ir.Rep) !PathGeometry {
    var commands = std.ArrayList(PathCommand){};
    errdefer commands.deinit(allocator);

    var fill_rule: PathFillRule = .nonzero;
    for (rep.shapes) |shape| {
        if (shape.fill_rule == .evenodd) fill_rule = .evenodd;
        for (shape.contours) |contour| {
            if (contour.points.len == 0) continue;
            try commands.append(allocator, .{ .move_to = .{
                .x = contour.points[0].x,
                .y = contour.points[0].y,
            } });
            for (contour.points[1..]) |point| {
                try commands.append(allocator, .{ .line_to = .{
                    .x = point.x,
                    .y = point.y,
                } });
            }
            if (contour.closed) {
                try commands.append(allocator, .{ .close = {} });
            }
        }
    }

    const owned_commands = try commands.toOwnedSlice(allocator);
    return .{
        .commands = owned_commands,
        .fill_rule = fill_rule,
        .bounds = if (owned_commands.len > 0) computePathGeometryBounds(owned_commands) else ComputedRect.init(0, 0, 0, 0),
        .owned = true,
    };
}

/// Tight axis-aligned bounding box over a sequence of PathCommands. Differs
/// from `svg_path.computePathBounds` in that quad/cubic curves treat all
/// control points as part of the box (sufficient for hit-testing).
pub fn computePathGeometryBounds(commands: []const PathCommand) ComputedRect {
    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    var first = true;

    for (commands) |cmd| {
        switch (cmd) {
            .move_to => |pt| {
                if (first) {
                    min_x = pt.x;
                    min_y = pt.y;
                    max_x = pt.x;
                    max_y = pt.y;
                    first = false;
                } else {
                    min_x = @min(min_x, pt.x);
                    min_y = @min(min_y, pt.y);
                    max_x = @max(max_x, pt.x);
                    max_y = @max(max_y, pt.y);
                }
            },
            .line_to => |pt| {
                if (first) {
                    min_x = pt.x;
                    min_y = pt.y;
                    max_x = pt.x;
                    max_y = pt.y;
                    first = false;
                } else {
                    min_x = @min(min_x, pt.x);
                    min_y = @min(min_y, pt.y);
                    max_x = @max(max_x, pt.x);
                    max_y = @max(max_y, pt.y);
                }
            },
            .quad_to => |quad| {
                if (first) {
                    min_x = quad.end.x;
                    min_y = quad.end.y;
                    max_x = quad.end.x;
                    max_y = quad.end.y;
                    first = false;
                }
                min_x = @min(min_x, @min(quad.ctrl.x, quad.end.x));
                min_y = @min(min_y, @min(quad.ctrl.y, quad.end.y));
                max_x = @max(max_x, @max(quad.ctrl.x, quad.end.x));
                max_y = @max(max_y, @max(quad.ctrl.y, quad.end.y));
            },
            .cubic_to => |cubic| {
                if (first) {
                    min_x = cubic.end.x;
                    min_y = cubic.end.y;
                    max_x = cubic.end.x;
                    max_y = cubic.end.y;
                    first = false;
                }
                min_x = @min(min_x, @min(cubic.ctrl1.x, @min(cubic.ctrl2.x, cubic.end.x)));
                min_y = @min(min_y, @min(cubic.ctrl1.y, @min(cubic.ctrl2.y, cubic.end.y)));
                max_x = @max(max_x, @max(cubic.ctrl1.x, @max(cubic.ctrl2.x, cubic.end.x)));
                max_y = @max(max_y, @max(cubic.ctrl1.y, @max(cubic.ctrl2.y, cubic.end.y)));
            },
            .close => {},
        }
    }

    if (first) return ComputedRect.init(0, 0, 0, 0);
    return ComputedRect.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

/// Final raster size in physical pixels for an SVG, taking into account:
///   - intrinsic size from `<svg width=... height=... viewBox=...>`,
///   - the style's explicit width/height (if any),
///   - the window's logical-to-physical scale (passed in),
///   - 2× oversampling for small UI icons.
pub fn resolveSvgRasterSize(window_scale: f32, svg_data: []const u8, style: Style) [2]u32 {
    const intrinsic = parseSvgIntrinsicSize(svg_data);
    const fallback_width = intrinsic.width orelse intrinsic.height orelse 24;
    const fallback_height = intrinsic.height orelse intrinsic.width orelse 24;
    const aspect_ratio = if (intrinsic.width != null and intrinsic.height != null and intrinsic.width.? > 0 and intrinsic.height.? > 0)
        intrinsic.width.? / intrinsic.height.?
    else
        null;

    var width = resolveSizingPx(style.width);
    var height = resolveSizingPx(style.height);

    if (width == null and height == null) {
        width = fallback_width;
        height = fallback_height;
    } else if (width != null and height == null) {
        if (aspect_ratio) |ratio| {
            height = width.? / ratio;
        } else {
            height = intrinsic.height orelse width.?;
        }
    } else if (width == null and height != null) {
        if (aspect_ratio) |ratio| {
            width = height.? * ratio;
        } else {
            width = intrinsic.width orelse height.?;
        }
    }

    const target_w = width orelse fallback_width;
    const target_h = height orelse fallback_height;
    const scale = if (window_scale > 0) window_scale else 1.0;
    const physical_w = target_w * scale;
    const physical_h = target_h * scale;
    const oversample = svgOversampleFactor(physical_w, physical_h);

    return .{
        clampSvgRasterDimension(physical_w * oversample),
        clampSvgRasterDimension(physical_h * oversample),
    };
}

pub fn resolveIconLogicalSize(asset: svg_assets_mod.Asset, style: Style) f32 {
    return resolveSizingPx(style.width) orelse
        resolveSizingPx(style.height) orelse
        @as(f32, @floatFromInt(asset.default_width));
}

fn svgOversampleFactor(width: f32, height: f32) f32 {
    const max_dim = @max(width, height);
    // Small UI SVGs rendered at logical-pixel size on Retina look fuzzy after
    // upscaling to physical pixels. 2× oversampling for icons avoids threading
    // window scale all the way into core.
    if (max_dim <= 64) return 2.0;
    return 1.0;
}

fn resolveSizingPx(sizing: Sizing) ?f32 {
    return switch (sizing) {
        .px => |value| if (value > 0) value else null,
        else => null,
    };
}

fn clampSvgRasterDimension(value: f32) u32 {
    const finite = if (std.math.isFinite(value)) value else 24;
    const rounded = @round(finite);
    const clamped = std.math.clamp(rounded, 1.0, 4096.0);
    return @intFromFloat(clamped);
}

pub const SvgIntrinsicSize = struct {
    width: ?f32 = null,
    height: ?f32 = null,
};

pub fn parseSvgIntrinsicSize(svg_data: []const u8) SvgIntrinsicSize {
    const svg_start = std.mem.indexOf(u8, svg_data, "<svg") orelse return .{};
    const tag_end = std.mem.indexOfScalarPos(u8, svg_data, svg_start, '>') orelse return .{};
    const tag = svg_data[svg_start..tag_end];

    var width = parseSvgLength(findSvgAttributeValue(tag, "width"));
    var height = parseSvgLength(findSvgAttributeValue(tag, "height"));
    if (width == null or height == null) {
        if (findSvgAttributeValue(tag, "viewBox")) |view_box| {
            const parsed = parseSvgViewBox(view_box);
            if (width == null) width = parsed.width;
            if (height == null) height = parsed.height;
        }
    }
    return .{ .width = width, .height = height };
}

pub fn findSvgAttributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < tag.len) : (index += 1) {
        const pos = std.mem.indexOfPos(u8, tag, index, name) orelse return null;
        if (pos > 0) {
            const before = tag[pos - 1];
            if (!std.ascii.isWhitespace(before) and before != '<') {
                index = pos + name.len;
                continue;
            }
        }

        const after = pos + name.len;
        if (after >= tag.len or tag[after] != '=') {
            index = after;
            continue;
        }
        if (after + 1 >= tag.len) return null;
        const quote = tag[after + 1];
        if (quote != '"' and quote != '\'') {
            index = after + 1;
            continue;
        }
        const value_start = after + 2;
        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
        return tag[value_start..value_end];
    }
    return null;
}

pub fn parseSvgLength(value: ?[]const u8) ?f32 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] == '%') return null;

    var end: usize = 0;
    while (end < trimmed.len) : (end += 1) {
        const c = trimmed[end];
        if (!(std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.' or c == 'e' or c == 'E')) break;
    }
    if (end == 0) return null;
    return std.fmt.parseFloat(f32, trimmed[0..end]) catch null;
}

pub fn parseSvgViewBox(view_box: []const u8) SvgIntrinsicSize {
    var parts = std.mem.tokenizeAny(u8, view_box, " ,\t\r\n");
    _ = parts.next() orelse return .{};
    _ = parts.next() orelse return .{};
    const width_text = parts.next() orelse return .{};
    const height_text = parts.next() orelse return .{};
    const width = std.fmt.parseFloat(f32, width_text) catch return .{};
    const height = std.fmt.parseFloat(f32, height_text) catch return .{};
    return .{
        .width = if (width > 0) width else null,
        .height = if (height > 0) height else null,
    };
}
