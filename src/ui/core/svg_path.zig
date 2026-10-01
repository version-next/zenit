//! SVG `<path d="...">` parser. Converts the textual command stream into the
//! framework's `PathCommand` IR (move_to / line_to / quad_to / cubic_to /
//! close), with helpers to clone & free `PathGeometry`, compute path bounds,
//! and approximate elliptical arcs as polylines.
//!
//! Extracted from `core/node.zig` to keep that file focused on the Node
//! struct itself. No behavior change.
const std = @import("std");
const svg_safety = @import("svg_safety");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");

const Point = types.Point;
const ComputedRect = types.ComputedRect;
const PathFillRule = types.PathFillRule;
const PathGeometry = types.PathGeometry;
const PathCommand = types.PathCommand;
const QuadraticPathCommand = types.QuadraticPathCommand;
const CubicPathCommand = types.CubicPathCommand;

/// Tight axis-aligned bounding box over a sequence of `PathCommand`s.
/// Considers control points, since they bound the curves' convex hulls.
pub fn computePathBounds(commands: []const PathCommand) ComputedRect {
    var has_point = false;
    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;

    for (commands) |cmd| {
        switch (cmd) {
            .move_to => |pt| updatePathBoundsPoint(&has_point, &min_x, &min_y, &max_x, &max_y, pt),
            .line_to => |pt| updatePathBoundsPoint(&has_point, &min_x, &min_y, &max_x, &max_y, pt),
            .quad_to => |quad| {
                updatePathBoundsPoint(&has_point, &min_x, &min_y, &max_x, &max_y, quad.ctrl);
                updatePathBoundsPoint(&has_point, &min_x, &min_y, &max_x, &max_y, quad.end);
            },
            .cubic_to => |cubic| {
                updatePathBoundsPoint(&has_point, &min_x, &min_y, &max_x, &max_y, cubic.ctrl1);
                updatePathBoundsPoint(&has_point, &min_x, &min_y, &max_x, &max_y, cubic.ctrl2);
                updatePathBoundsPoint(&has_point, &min_x, &min_y, &max_x, &max_y, cubic.end);
            },
            .close => continue,
        }
    }

    if (!has_point) return ComputedRect.init(0, 0, 0, 0);
    return ComputedRect.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn updatePathBoundsPoint(has_point: *bool, min_x: *f32, min_y: *f32, max_x: *f32, max_y: *f32, point: Point) void {
    if (!has_point.*) {
        has_point.* = true;
        min_x.* = point.x;
        min_y.* = point.y;
        max_x.* = point.x;
        max_y.* = point.y;
        return;
    }
    min_x.* = @min(min_x.*, point.x);
    min_y.* = @min(min_y.*, point.y);
    max_x.* = @max(max_x.*, point.x);
    max_y.* = @max(max_y.*, point.y);
}

/// Deep-copy a `PathGeometry` so the clone owns its command buffer.
pub fn clonePathGeometry(allocator: Allocator, geometry: PathGeometry) !PathGeometry {
    const owned_commands = try allocator.dupe(PathCommand, geometry.commands);
    return .{
        .commands = owned_commands,
        .fill_rule = geometry.fill_rule,
        .bounds = geometry.bounds,
        .owned = true,
    };
}

/// Free the command buffer owned by a `PathGeometry` and reset to default.
pub fn freePathGeometry(allocator: Allocator, geometry: *PathGeometry) void {
    if (geometry.owned and geometry.commands.len > 0) {
        allocator.free(geometry.commands);
    }
    geometry.* = .{};
}

/// Parse all `<path d="...">` elements out of an SVG document and return
/// a single concatenated command sequence as a `PathGeometry`.
pub fn createSvgDocumentPathGeometry(allocator: Allocator, svg_data: []const u8, fill_rule: PathFillRule) !PathGeometry {
    const commands = try parseSvgDocumentPathCommands(allocator, svg_data);
    return .{
        .commands = commands,
        .fill_rule = fill_rule,
        .bounds = computePathBounds(commands),
        .owned = true,
    };
}

/// 单个 `d` 属性、以及整份 SVG 文档累计可产出的 PathCommand 条数上限。
///
/// 这两条解析路径是运行时可达的（`ui.createSvgDocumentPathGeometry` /
/// `cx.registerTextureSvgHit`），宿主完全可能把用户粘贴、导入或网络下载来的
/// SVG 喂进来。没有上限时，一串几十 MB 的 `M0 0 L1 1 L2 2 ...` 就能让每个
/// 坐标对变成一条 PathCommand，造成无界内存增长（CWE-400/770 资源耗尽）。
///
/// 取值给真实图标留了几个数量级的余量：复杂的 24×24 描边图标通常在几百条以内，
/// 整页插画级 SVG 也远低于文档上限。命中上限说明输入已经不像是要拿来渲染的图形。
pub const MAX_PATH_COMMANDS_PER_ATTR: usize = 64 * 1024;
pub const MAX_PATH_COMMANDS_PER_DOCUMENT: usize = 256 * 1024;

/// Parse a single `d="..."` attribute value into PathCommands.
pub fn parseSvgPathCommands(allocator: Allocator, d: []const u8) ![]PathCommand {
    var commands = std.ArrayList(PathCommand){};
    errdefer commands.deinit(allocator);

    var i: usize = 0;
    var cmd: u8 = 0;
    var current = Point{ .x = 0, .y = 0 };
    var subpath_start = current;
    var last_cubic_ctrl: ?Point = null;
    var last_quad_ctrl: ?Point = null;

    while (true) {
        // 单条 `d` 的产出上限。放在循环顶部是因为每轮最多再追加常数条命令，
        // 这一个检查点就能兜住下面所有 append 分支。
        if (commands.items.len > MAX_PATH_COMMANDS_PER_ATTR) return error.SvgPathTooComplex;
        skipNumberSeparators(d, &i);
        if (i >= d.len) break;

        if (isSvgPathCommand(d[i])) {
            cmd = d[i];
            i += 1;
        } else if (cmd == 0) {
            return error.InvalidSvgPath;
        }

        switch (cmd) {
            'M', 'm' => {
                var first = true;
                while (nextIsNumber(d, i)) {
                    const x = try parseSvgNumber(d, &i);
                    const y = try parseSvgNumber(d, &i);
                    var p = Point{ .x = x, .y = y };
                    if (cmd == 'm') {
                        p.x += current.x;
                        p.y += current.y;
                    }

                    if (first) {
                        try commands.append(allocator, .{ .move_to = p });
                        current = p;
                        subpath_start = p;
                        first = false;
                    } else {
                        try commands.append(allocator, .{ .line_to = p });
                        current = p;
                    }
                    last_cubic_ctrl = null;
                    last_quad_ctrl = null;
                }
                if (first) return error.InvalidSvgPath;
                cmd = if (cmd == 'm') 'l' else 'L';
            },
            'L', 'l' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    const x = try parseSvgNumber(d, &i);
                    const y = try parseSvgNumber(d, &i);
                    var p = Point{ .x = x, .y = y };
                    if (cmd == 'l') {
                        p.x += current.x;
                        p.y += current.y;
                    }
                    try commands.append(allocator, .{ .line_to = p });
                    current = p;
                    had = true;
                }
                if (!had) return error.InvalidSvgPath;
                last_cubic_ctrl = null;
                last_quad_ctrl = null;
            },
            'H', 'h' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    const x = try parseSvgNumber(d, &i);
                    var p = current;
                    p.x = if (cmd == 'h') current.x + x else x;
                    try commands.append(allocator, .{ .line_to = p });
                    current = p;
                    had = true;
                }
                if (!had) return error.InvalidSvgPath;
                last_cubic_ctrl = null;
                last_quad_ctrl = null;
            },
            'V', 'v' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    const y = try parseSvgNumber(d, &i);
                    var p = current;
                    p.y = if (cmd == 'v') current.y + y else y;
                    try commands.append(allocator, .{ .line_to = p });
                    current = p;
                    had = true;
                }
                if (!had) return error.InvalidSvgPath;
                last_cubic_ctrl = null;
                last_quad_ctrl = null;
            },
            'C', 'c' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    var c1 = Point{ .x = try parseSvgNumber(d, &i), .y = try parseSvgNumber(d, &i) };
                    var c2 = Point{ .x = try parseSvgNumber(d, &i), .y = try parseSvgNumber(d, &i) };
                    var p = Point{ .x = try parseSvgNumber(d, &i), .y = try parseSvgNumber(d, &i) };
                    if (cmd == 'c') {
                        c1.x += current.x;
                        c1.y += current.y;
                        c2.x += current.x;
                        c2.y += current.y;
                        p.x += current.x;
                        p.y += current.y;
                    }
                    try commands.append(allocator, .{ .cubic_to = CubicPathCommand{ .ctrl1 = c1, .ctrl2 = c2, .end = p } });
                    current = p;
                    last_cubic_ctrl = c2;
                    last_quad_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvgPath;
            },
            'S', 's' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    var c2 = Point{ .x = try parseSvgNumber(d, &i), .y = try parseSvgNumber(d, &i) };
                    var p = Point{ .x = try parseSvgNumber(d, &i), .y = try parseSvgNumber(d, &i) };
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
                    try commands.append(allocator, .{ .cubic_to = CubicPathCommand{ .ctrl1 = c1, .ctrl2 = c2, .end = p } });
                    current = p;
                    last_cubic_ctrl = c2;
                    last_quad_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvgPath;
            },
            'Q', 'q' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    var c = Point{ .x = try parseSvgNumber(d, &i), .y = try parseSvgNumber(d, &i) };
                    var p = Point{ .x = try parseSvgNumber(d, &i), .y = try parseSvgNumber(d, &i) };
                    if (cmd == 'q') {
                        c.x += current.x;
                        c.y += current.y;
                        p.x += current.x;
                        p.y += current.y;
                    }
                    try commands.append(allocator, .{ .quad_to = QuadraticPathCommand{ .ctrl = c, .end = p } });
                    current = p;
                    last_quad_ctrl = c;
                    last_cubic_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvgPath;
            },
            'T', 't' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    var p = Point{ .x = try parseSvgNumber(d, &i), .y = try parseSvgNumber(d, &i) };
                    if (cmd == 't') {
                        p.x += current.x;
                        p.y += current.y;
                    }
                    const c = if (last_quad_ctrl) |prev|
                        Point{ .x = 2 * current.x - prev.x, .y = 2 * current.y - prev.y }
                    else
                        current;
                    try commands.append(allocator, .{ .quad_to = QuadraticPathCommand{ .ctrl = c, .end = p } });
                    current = p;
                    last_quad_ctrl = c;
                    last_cubic_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvgPath;
            },
            'A', 'a' => {
                var had = false;
                while (nextIsNumber(d, i)) {
                    const rx = try parseSvgNumber(d, &i);
                    const ry = try parseSvgNumber(d, &i);
                    const rotation = try parseSvgNumber(d, &i);
                    const large_arc = (try parseSvgNumber(d, &i)) != 0;
                    const sweep = (try parseSvgNumber(d, &i)) != 0;
                    var p = Point{ .x = try parseSvgNumber(d, &i), .y = try parseSvgNumber(d, &i) };
                    if (cmd == 'a') {
                        p.x += current.x;
                        p.y += current.y;
                    }
                    try appendArcToCommands(allocator, &commands, current, p, rx, ry, rotation, large_arc, sweep);
                    current = p;
                    last_quad_ctrl = null;
                    last_cubic_ctrl = null;
                    had = true;
                }
                if (!had) return error.InvalidSvgPath;
            },
            'Z', 'z' => {
                try commands.append(allocator, .{ .close = {} });
                current = subpath_start;
                last_quad_ctrl = null;
                last_cubic_ctrl = null;
                // `close` has no operands, so it cannot be implicitly repeated.
                // Clear the command after consuming it: otherwise a trailing
                // number/invalid token re-enters this branch forever without
                // advancing `i`, appending `.close` until OOM.
                cmd = 0;
            },
            else => return error.UnsupportedSvgPathCommand,
        }
    }

    return commands.toOwnedSlice(allocator);
}

fn skipNumberSeparators(s: []const u8, index: *usize) void {
    svg_safety.skipNumberSeparators(s, index);
}

fn isSvgPathCommand(c: u8) bool {
    return switch (c) {
        'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z' => true,
        else => false,
    };
}

fn nextIsNumber(s: []const u8, index: usize) bool {
    return svg_safety.nextIsNumber(s, index);
}

fn parseSvgNumber(s: []const u8, index: *usize) !f32 {
    return svg_safety.parseFiniteNumber(s, index) orelse error.InvalidSvgPath;
}

/// Parse all `<path d="...">` elements in an SVG document into a single
/// concatenated PathCommand slice.
pub fn parseSvgDocumentPathCommands(allocator: Allocator, svg_data: []const u8) ![]PathCommand {
    var all = std.ArrayList(PathCommand){};
    errdefer all.deinit(allocator);

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, svg_data, cursor, "<path")) |tag_start| {
        const tag_end = std.mem.indexOfScalarPos(u8, svg_data, tag_start, '>') orelse break;
        const tag = svg_data[tag_start..tag_end];
        const d_attr = findSvgAttribute(tag, "d") orelse {
            cursor = tag_end + 1;
            continue;
        };

        const commands = try parseSvgPathCommands(allocator, d_attr);
        defer allocator.free(commands);
        // 整份文档的累计上限：单条 `d` 合规不代表几千个 <path> 拼起来也合规。
        if (all.items.len + commands.len > MAX_PATH_COMMANDS_PER_DOCUMENT) {
            return error.SvgPathTooComplex;
        }
        try all.appendSlice(allocator, commands);
        cursor = tag_end + 1;
    }

    if (all.items.len == 0) return error.MissingSvgPathData;
    return all.toOwnedSlice(allocator);
}

/// 委托 svg_geometry 的实现，它有本函数曾缺失的"前一字符必须是空白或 <"
/// 校验。旧的等价实现只查匹配后是否为 `=`，`<path id="foo" d="M0 0">`
/// 会把 `id` 里的 `d` 当属性名，返回 "foo" 使整个节点构建失败。
fn findSvgAttribute(tag: []const u8, name: []const u8) ?[]const u8 {
    return @import("svg_geometry.zig").findSvgAttributeValue(tag, name);
}

/// Approximate an SVG elliptical arc as a polyline. Used for path
/// commands `A`/`a`. The output appends `line_to` segments to `commands`.
fn appendArcToCommands(
    allocator: Allocator,
    commands: *std.ArrayList(PathCommand),
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
        try commands.append(allocator, .{ .line_to = p1 });
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
        try commands.append(allocator, .{ .line_to = p1 });
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

    const theta1 = std.math.atan2(uy, ux);
    var delta = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);

    if (!sweep and delta > 0) delta -= 2 * std.math.pi;
    if (sweep and delta < 0) delta += 2 * std.math.pi;

    const segments = svg_safety.boundedSegmentCount(@abs(delta) / (std.math.pi / 8.0), 4, 128);

    for (1..segments + 1) |idx| {
        const t = theta1 + delta * (@as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(segments)));
        const cos_t = @cos(t);
        const sin_t = @sin(t);
        const point = Point{
            .x = cx + rx * cos_phi * cos_t - ry * sin_phi * sin_t,
            .y = cy + rx * sin_phi * cos_t + ry * cos_phi * sin_t,
        };
        try commands.append(allocator, .{ .line_to = point });
    }
}

test "findSvgAttribute: 前置属性名含子串 d 时不误匹配" {
    // 回归：<path id="foo" d="M0 0"> 曾匹配 id 里的 d 返回 "foo"，
    // parseSvgPathCommands("foo") 失败中止整个节点构建
    const tag = "path id=\"foo\" d=\"M0 0 L10 10\"";
    const d = findSvgAttribute(tag, "d");
    try std.testing.expect(d != null);
    try std.testing.expectEqualStrings("M0 0 L10 10", d.?);
}

test "parseSvgPathCommands rejects operands after close instead of looping" {
    try std.testing.expectError(
        error.InvalidSvgPath,
        parseSvgPathCommands(std.testing.allocator, "M0 0 Z 5"),
    );

    const commands = try parseSvgPathCommands(std.testing.allocator, "M0 0 Z M1 1");
    defer std.testing.allocator.free(commands);
    try std.testing.expectEqual(@as(usize, 3), commands.len);
}

test "parseSvgPathCommands rejects non-finite coordinates" {
    try std.testing.expectError(
        error.InvalidSvgPath,
        parseSvgPathCommands(std.testing.allocator, "M1e999 0"),
    );
}

test "parseSvgPathCommands 对超量命令的 d 属性设上限" {
    const alloc = std.testing.allocator;

    // 每个 "L1 1" 产出一条 line_to，堆到超过单属性上限
    var d = std.ArrayList(u8){};
    defer d.deinit(alloc);
    try d.appendSlice(alloc, "M0 0");
    for (0..MAX_PATH_COMMANDS_PER_ATTR + 16) |_| {
        try d.appendSlice(alloc, "L1 1");
    }

    try std.testing.expectError(
        error.SvgPathTooComplex,
        parseSvgPathCommands(alloc, d.items),
    );
}

test "parseSvgDocumentPathCommands 对累计命令数设上限" {
    const alloc = std.testing.allocator;

    // 单条 d 各自合规，但 <path> 数量堆上去后累计超文档上限
    const per_path = 4096;
    var one_d = std.ArrayList(u8){};
    defer one_d.deinit(alloc);
    try one_d.appendSlice(alloc, "M0 0");
    for (0..per_path) |_| try one_d.appendSlice(alloc, "L1 1");

    var doc = std.ArrayList(u8){};
    defer doc.deinit(alloc);
    try doc.appendSlice(alloc, "<svg>");
    for (0..(MAX_PATH_COMMANDS_PER_DOCUMENT / per_path) + 2) |_| {
        try doc.appendSlice(alloc, "<path d=\"");
        try doc.appendSlice(alloc, one_d.items);
        try doc.appendSlice(alloc, "\"/>");
    }
    try doc.appendSlice(alloc, "</svg>");

    try std.testing.expectError(
        error.SvgPathTooComplex,
        parseSvgDocumentPathCommands(alloc, doc.items),
    );
}

test "上限不影响正常图标尺度的 path" {
    const alloc = std.testing.allocator;
    // 典型 24x24 描边图标量级，远低于上限
    const cmds = try parseSvgDocumentPathCommands(
        alloc,
        "<svg><path d=\"M3 12h18M12 3v18\"/><path d=\"M5 5L19 19\"/></svg>",
    );
    defer alloc.free(cmds);
    try std.testing.expect(cmds.len > 0);
    try std.testing.expect(cmds.len < MAX_PATH_COMMANDS_PER_DOCUMENT);
}
