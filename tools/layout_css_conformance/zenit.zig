//! Window-free oracle. Standalone Nodes use the same fallback storage as layout_engine tests.
const std = @import("std");
const core = @import("core");
const Ext = @typeInfo(@typeInfo(@FieldType(core.Style, "ext")).optional.child).pointer.child;
const Track = @typeInfo(@FieldType(core.GridConfig, "columns")).array.child;
const Grid = struct { columns: []const std.json.Value, rows: []const std.json.Value = &.{}, column_gap: f32 = 0, row_gap: f32 = 0 };
const Style = struct {
    width: core.Sizing = .{ .fit = .{} },
    height: core.Sizing = .{ .fit = .{} },
    direction: core.Direction = .column,
    justify: core.JustifyContent = .start,
    align_items: core.AlignItems = .stretch,
    align_content: core.AlignContent = .normal,
    gap: f32 = 0,
    padding: core.Padding = .{},
    margin: core.Padding = .{},
    flex: f32 = 1,
    flex_shrink: f32 = 1,
    flex_basis: std.json.Value = .{ .string = "auto" },
    flex_wrap: core.FlexWrap = .no_wrap,
    align_self: ?core.AlignItems = null,
    no_cross_stretch: bool = false,
    margin_auto_mask: u8 = 0,
    position: core.Position = .relative,
    inset: core.Inset = .{},
    sticky_insets: @FieldType(Ext, "sticky_insets") = .{},
    min_width: f32 = -1,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = -1,
    max_height: f32 = std.math.inf(f32),
    aspect_ratio: f32 = 0,
    display: core.Display = .flex,
    overflow: @FieldType(core.Style, "overflow") = .visible,
    overflow_hidden: bool = false,
    layout_isolation: bool = false,
    translate_x: f32 = 0,
    translate_y: f32 = 0,
    border: core.Border = .{},
    grid: ?Grid = null,
    grid_placement: ?core.GridPlacement = null,
};
const Text = struct {
    content: []const u8,
    font_size: f32 = 16,
    line_height: f32 = 1.4,
    wrap: core.TextWrap = .none,
    overflow_wrap: @FieldType(core.TextProps, "overflow_wrap") = .normal,
    word_break: @FieldType(core.TextProps, "word_break") = .normal,
    max_lines: u16 = 0,
    text_overflow: @FieldType(core.TextProps, "text_overflow") = .clip,
    fade_right: f32 = 0,
};
const Spec = struct { id: []const u8, style: Style = .{}, text: ?Text = null, children: []const Spec = &.{} };
const EngineDeviations = struct { chromium: ?[]const u8 = null, firefox: ?[]const u8 = null, webkit: ?[]const u8 = null };
const Fixture = struct { known_engine_deviation: EngineDeviations = .{}, note: ?[]const u8 = null, id: []const u8, properties: []const []const u8, must_match: bool = false, width: f32, height: f32, root: Spec };
const Suite = struct { version: u32, fixtures: []const Fixture };
const Rect = struct { id: []const u8, x: f32, y: f32, w: f32, h: f32 };
const Result = struct { id: []const u8, nodes: []const Rect };

fn parseBreadth(comptime T: type, a: std.mem.Allocator, value: std.json.Value) !T {
    if (value == .string) {
        if (std.mem.eql(u8, value.string, "auto")) return .auto;
        return error.InvalidTrack;
    }
    return (try std.json.parseFromValue(T, a, value, .{})).value;
}

fn parseTrack(a: std.mem.Allocator, value: std.json.Value) !Track {
    if (value == .object) if (value.object.get("minmax")) |m| {
        if (value.object.count() != 1 or m != .object) return error.InvalidTrack;
        var out: @FieldType(Track, "minmax") = .{};
        var it = m.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "min")) out.min = try parseBreadth(Track.Minimum, a, entry.value_ptr.*) else if (std.mem.eql(u8, entry.key_ptr.*, "max")) out.max = try parseBreadth(Track.Maximum, a, entry.value_ptr.*) else return error.InvalidTrack;
        }
        return .{ .minmax = out };
    };
    return parseBreadth(Track, a, value);
}

fn make(a: std.mem.Allocator, spec: Spec, serial: *u32) !*core.Node {
    serial.* += 1;
    const node = try core.Node.create(a, serial.*, if (spec.text != null) .text else .box, .{});
    const ext = try a.create(Ext);
    ext.* = .{};
    node.style.ext = ext;
    inline for (@typeInfo(Style).@"struct".field_names) |field| {
        if (comptime std.mem.eql(u8, field, "grid")) {
            if (spec.style.grid) |g| {
                if (g.columns.len == 0 or g.columns.len > 16 or g.rows.len > 16) return error.InvalidGridTracks;
                const config = try a.create(core.GridConfig);
                config.* = .{ .column_count = @intCast(g.columns.len), .row_count = @intCast(g.rows.len), .column_gap = g.column_gap, .row_gap = g.row_gap };
                for (g.columns, 0..) |track, i| config.columns[i] = try parseTrack(a, track);
                for (g.rows, 0..) |track, i| config.rows[i] = try parseTrack(a, track);
                ext.grid = config;
            }
        } else if (comptime std.mem.eql(u8, field, "flex_basis")) {
            ext.flex_basis = switch (spec.style.flex_basis) {
                .integer => |v| @floatFromInt(v),
                .float => |v| @floatCast(v),
                .string => |v| if (std.mem.eql(u8, v, "auto")) core.FlexBasis.auto else if (std.mem.eql(u8, v, "content")) core.FlexBasis.content else return error.InvalidBasis,
                else => return error.InvalidBasis,
            };
        } else if (@hasField(core.Style, field)) {
            @field(node.style, field) = @field(spec.style, field);
        } else {
            @field(ext, field) = @field(spec.style, field);
        }
    }
    if (spec.text) |t| node.setText(.{ .content = t.content, .font_size = t.font_size, .line_height = t.line_height, .wrap = t.wrap, .overflow_wrap = t.overflow_wrap, .word_break = t.word_break, .max_lines = t.max_lines, .text_overflow = t.text_overflow, .fade_right = t.fade_right });
    for (spec.children) |child| try node.appendChild(a, try make(a, child, serial));
    return node;
}

// Convert parent-local layout rects to viewport coordinates. Translation is a paint transform,
// included to match getBoundingClientRect; sticky is sampled only at scroll offset zero.
fn collect(a: std.mem.Allocator, node: *core.Node, spec: Spec, x: f32, y: f32, out: *std.ArrayList(Rect)) !void {
    const r = node.rectFromWorldOrFallback();
    const nx = x + r.x + node.style.translate_x;
    const ny = y + r.y + node.style.translate_y;
    try out.append(a, .{ .id = spec.id, .x = nx, .y = ny, .w = r.w, .h = r.h });
    for (node.children.items, spec.children) |child, child_spec| try collect(a, child, child_spec, nx, ny, out);
}

const Fonts = struct {
    fs: *core.FontSystem,
    fonts: std.AutoHashMap(u32, *core.Font),
    path: [:0]const u8,
    fn resolve(ctx: *anyopaque, _: []const u8, size: f32, _: u16, _: bool, _: bool, _: u16) ?*core.Font {
        const self: *Fonts = @ptrCast(@alignCast(ctx));
        const px: u32 = @intFromFloat(size);
        if (self.fonts.get(px)) |font| return font;
        const font = self.fs.loadFont(self.path, px) catch return null;
        self.fonts.put(px, font) catch return null;
        return font;
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedFixtureAndOutputPaths;
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(16 * 1024 * 1024));
    const suite = try std.json.parseFromSlice(Suite, a, input, .{});
    if (suite.value.version != 1) return error.UnsupportedVersion;
    var fs = try core.FontSystem.init(a, init.io);
    defer fs.deinit();
    var fonts = Fonts{ .fs = &fs, .fonts = std.AutoHashMap(u32, *core.Font).init(a), .path = "tools/fixtures/fonts/Lora-Regular.ttf" };
    defer {
        var it = fonts.fonts.valueIterator();
        while (it.next()) |f| f.*.deinit();
        fonts.fonts.deinit();
    }
    // Fail closed: never report a system-font fallback as fixed-font evidence.
    for ([_]u32{ 16, 32 }) |px| try fonts.fonts.put(px, try fs.loadFont(fonts.path, px));
    core.layout_engine.setShapeFontResolver(Fonts.resolve, &fonts);
    defer core.layout_engine.setShapeFontResolver(null, null);
    var cache = core.ShapingCache.init(a, 1024);
    defer cache.deinit();
    var results: std.ArrayList(Result) = .empty;
    for (suite.value.fixtures) |f| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const fa = arena.allocator();
        var serial: u32 = 0;
        const root = try make(fa, f.root, &serial);
        core.layout_engine.layoutNode(root, .{ .width = f.width, .height = f.height }, .{ .frame_allocator = fa, .shaping_cache = &cache, .font_system = &fs });
        var nodes: std.ArrayList(Rect) = .empty;
        try collect(a, root, f.root, 0, 0, &nodes);
        try results.append(a, .{ .id = f.id, .nodes = try nodes.toOwnedSlice(a) });
    }
    const output = try std.json.Stringify.valueAlloc(a, results.items, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = output });
}

test "fixture parser accepts sizing, auto margin and nested nodes" {
    const json = "{\"version\":1,\"fixtures\":[{\"id\":\"parse\",\"properties\":[\"grow\"],\"width\":300,\"height\":100,\"root\":{\"id\":\"root\",\"children\":[{\"id\":\"a\",\"style\":{\"width\":{\"grow\":{\"min\":250}},\"margin_auto_mask\":8}}]}}]}";
    const parsed = try std.json.parseFromSlice(Suite, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f32, 250), parsed.value.fixtures[0].root.children[0].style.width.grow.min);
    try std.testing.expectEqual(@as(u8, 8), parsed.value.fixtures[0].root.children[0].style.margin_auto_mask);
}

test "fixture parser rejects unknown layout properties" {
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Spec, std.testing.allocator, "{\"id\":\"a\",\"style\":{\"widht\":10}}", .{}));
}

test "real engine fixed row, column reverse and percent-padding regression rectangles" {
    const a = std.testing.allocator;
    for ([_]core.Direction{ .row, .column_reverse }) |direction| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const spec = Spec{ .id = "root", .style = .{ .width = .{ .px = 300 }, .height = .{ .px = 100 }, .direction = direction, .gap = 10 }, .children = &.{
            .{ .id = "a", .style = .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } } },
            .{ .id = "b", .style = .{ .width = .{ .px = 60 }, .height = .{ .px = 30 } } },
        } };
        var serial: u32 = 0;
        const root = try make(arena.allocator(), spec, &serial);
        core.layout_engine.layoutNode(root, .{ .width = 300, .height = 100 }, .{ .frame_allocator = arena.allocator() });
        const first = root.children.items[0].rectFromWorldOrFallback();
        const second = root.children.items[1].rectFromWorldOrFallback();
        try std.testing.expectApproxEqAbs(@as(f32, 40), first.w, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 30), second.h, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, if (direction == .row) 50 else 0), second.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, if (direction == .row) 0 else 80), first.y, 0.01);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var serial: u32 = 0;
    const spec = Spec{ .id = "root", .style = .{ .width = .{ .px = 300 }, .height = .{ .px = 100 }, .direction = .row, .padding = .{ .left = 20, .right = 20, .top = 10, .bottom = 10 } }, .children = &.{.{ .id = "a", .style = .{ .width = .{ .percent = 50 }, .height = .{ .percent = 50 } } }} };
    const root = try make(arena.allocator(), spec, &serial);
    core.layout_engine.layoutNode(root, .{ .width = 300, .height = 100 }, .{ .frame_allocator = arena.allocator() });
    const r = root.children.items[0].rectFromWorldOrFallback();
    try std.testing.expectEqual(@as(f32, 130), r.w);
    try std.testing.expectEqual(@as(f32, 40), r.h);
    try std.testing.expectEqual(@as(f32, 20), r.x);
    try std.testing.expectEqual(@as(f32, 10), r.y);
}

test "LC3 main-axis contracts use real fixture trees" {
    const parsed = try std.json.parseFromSlice(Suite, std.testing.allocator, @embedFile("fixtures.json"), .{});
    defer parsed.deinit();
    const Case = struct { id: []const u8, sizes: []const f32 };
    for ([_]Case{
        .{ .id = "grow-min", .sizes = &.{ 250, 50 } },
        .{ .id = "grow-max", .sizes = &.{ 50, 250 } },
        .{ .id = "grow-weight-small", .sizes = &.{ 60, 60 } },
        .{ .id = "shrink-min", .sizes = &.{ 80, 20 } },
        .{ .id = "shrink-grow", .sizes = &.{ 50, 50 } },
        .{ .id = "default-min", .sizes = &.{ 100, 100 } },
        .{ .id = "basis-zero", .sizes = &.{ 0, 0 } },
        .{ .id = "basis-grow", .sizes = &.{ 200, 100 } },
        .{ .id = "basis-auto-content", .sizes = &.{100} },
        .{ .id = "basis-content-content", .sizes = &.{40} },
        .{ .id = "auto-margin-grow-max", .sizes = &.{ 50, 40 } },
        .{ .id = "auto-margin-grow-max-row_reverse", .sizes = &.{ 50, 40 } },
        .{ .id = "auto-margin-grow-max-column_reverse", .sizes = &.{ 50, 40 } },
        .{ .id = "grow-min-column", .sizes = &.{ 250, 50 } },
        .{ .id = "grow-min-row_reverse", .sizes = &.{ 250, 50 } },
        .{ .id = "grow-min-column_reverse", .sizes = &.{ 250, 50 } },
    }) |case| {
        var found = false;
        for (parsed.value.fixtures) |f| {
            if (!std.mem.eql(u8, f.id, case.id)) continue;
            found = true;
            try std.testing.expect(f.must_match);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var serial: u32 = 0;
            const root = try make(arena.allocator(), f.root, &serial);
            core.layout_engine.layoutNode(root, .{ .width = f.width, .height = f.height }, .{ .frame_allocator = arena.allocator() });
            for (root.children.items, case.sizes) |child, expected| {
                const rect = child.rectFromWorldOrFallback();
                try std.testing.expectApproxEqAbs(expected, if (root.style.direction.isRow()) rect.w else rect.h, 0.01);
            }
            if (std.mem.startsWith(u8, f.id, "auto-margin-grow-max-")) {
                const r = root.children.items[0].rectFromWorldOrFallback();
                try std.testing.expectApproxEqAbs(@as(f32, 250), if (root.style.direction.isRow()) r.x else r.y, 0.01);
            }
            if (std.mem.eql(u8, f.id, "auto-margin-grow-max"))
                try std.testing.expectApproxEqAbs(@as(f32, 210), root.children.items[0].rectFromWorldOrFallback().x, 0.01);
        }
        try std.testing.expect(found);
    }
}

test "fit parent intrinsic measurement honors explicit zero basis" {
    const parsed = try std.json.parseFromSlice(Suite, std.testing.allocator, @embedFile("fixtures.json"), .{});
    defer parsed.deinit();
    var found = false;
    for (parsed.value.fixtures) |f| {
        if (!std.mem.eql(u8, f.id, "fit-parent-basis-zero")) continue;
        found = true;
        // Engines disagree here (see the fixture note); keep zenit pinned to
        // the Chromium result it was designed against.
        try std.testing.expect(!f.must_match);
        try std.testing.expect(f.note != null);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var serial: u32 = 0;
        const root = try make(arena.allocator(), f.root, &serial);
        core.layout_engine.layoutNode(root, .{ .width = f.width, .height = f.height }, .{ .frame_allocator = arena.allocator() });
        const fit = root.children.items[0];
        try std.testing.expectEqual(@as(f32, 0), fit.rectFromWorldOrFallback().w);
        try std.testing.expectEqual(@as(f32, 0), fit.children.items[0].rectFromWorldOrFallback().w);
    }
    try std.testing.expect(found);
}

test "LC3B cross wrap baseline and negative justify reach real layout paths" {
    const parsed = try std.json.parseFromSlice(Suite, std.testing.allocator, @embedFile("fixtures.json"), .{});
    defer parsed.deinit();
    const Check = struct { id: []const u8, must_match: bool = true, child: usize = 0, x: ?f32 = null, y: ?f32 = null, w: ?f32 = null, h: ?f32 = null };
    for ([_]Check{
        .{ .id = "stretch-grow-max", .h = 20 },
        .{ .id = "lc3b-fit-cross-nested-center", .h = 80 },
        .{ .id = "stretch-fit-ext-max", .h = 25 },
        .{ .id = "no-cross-explicit", .h = 100 },
        .{ .id = "cross-grow-center", .y = 40, .h = 20 },
        .{ .id = "auto-margin-cross", .y = 80 },
        .{ .id = "baseline-box", .y = 40 },
        .{ .id = "wrap-grow", .w = 150 },
        .{ .id = "wrap-shrink", .w = 300 },
        .{ .id = "wrap-align-self", .y = 80, .h = 20 },
        .{ .id = "wrap-explicit-cross", .h = 20 },
        .{ .id = "wrap-257", .child = 256, .y = 256 },
        .{ .id = "lc3b-overflow-row-end", .x = -87 },
        .{ .id = "lc3b-overflow-row-center", .x = -43.5 },
        .{ .id = "lc3b-overflow-row_reverse-space_around", .must_match = false, .x = 50 },
        .{ .id = "lc3b-overflow-row_reverse-space_evenly", .must_match = false, .x = 50 },
        .{ .id = "lc3b-overflow-column_reverse-space_around", .must_match = false, .y = -10 },
        .{ .id = "lc3b-overflow-column_reverse-space_evenly", .must_match = false, .y = -10 },
        .{ .id = "lc3b-line-overflow-wrap_reverse-space_around", .must_match = false, .y = 30 },
        .{ .id = "lc3b-line-overflow-wrap_reverse-space_evenly", .must_match = false, .y = 30 },
        .{ .id = "lc3b-line-overflow-wrap_reverse-space_between", .y = 30 },
    }) |check| {
        var found = false;
        for (parsed.value.fixtures) |f| {
            if (!std.mem.eql(u8, f.id, check.id)) continue;
            found = true;
            try std.testing.expectEqual(check.must_match, f.must_match);
            if (!check.must_match) try std.testing.expect(f.note != null);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var serial: u32 = 0;
            const root = try make(arena.allocator(), f.root, &serial);
            for (0..3) |_| {
                root.frame_state.state_bits.dirty.core.layout = true;
                core.layout_engine.layoutNode(root, .{ .width = f.width, .height = f.height }, .{ .frame_allocator = arena.allocator() });
                const r = root.children.items[check.child].rectFromWorldOrFallback();
                if (std.mem.eql(u8, check.id, "lc3b-fit-cross-nested-center")) try std.testing.expectEqual(@as(f32, 30), root.children.items[0].children.items[0].children.items[0].rectFromWorldOrFallback().y);
                inline for (.{ "x", "y", "w", "h" }) |field| if (@field(check, field)) |expected| try std.testing.expectApproxEqAbs(expected, @field(r, field), 0.01);
            }
        }
        try std.testing.expect(found);
    }
}

test "LC3B incremental descendant change cannot undo cross stretch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var serial: u32 = 0;
    const root = try make(a, .{ .id = "root", .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .direction = .row }, .children = &.{.{ .id = "fit", .style = .{ .width = .{ .px = 40 } }, .children = &.{.{ .id = "leaf", .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } } }} }} }, &serial);
    const fit = root.children.items[0];
    const leaf = fit.children.items[0];
    core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try std.testing.expectEqual(@as(f32, 100), fit.rectFromWorldOrFallback().h);
    leaf.style.height = .{ .px = 40 };
    leaf.frame_state.state_bits.dirty.core.layout = true;
    fit.frame_state.state_bits.dirty.core.layout = false;
    fit.frame_state.state_bits.dirty.core.subtree_layout = true;
    root.frame_state.state_bits.dirty.core.layout = false;
    root.frame_state.state_bits.dirty.core.subtree_layout = true;
    core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try std.testing.expectEqual(@as(f32, 100), fit.rectFromWorldOrFallback().h);
    try std.testing.expectEqual(@as(f32, 40), leaf.rectFromWorldOrFallback().h);
}

test "LC3B descendant reflow updates wrapped line cross positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var serial: u32 = 0;
    const root = try make(a, .{ .id = "root", .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .direction = .row, .flex_wrap = .wrap, .align_content = .start }, .children = &.{
        .{ .id = "fit", .style = .{ .width = .{ .px = 100 } }, .children = &.{.{ .id = "leaf", .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } } }} },
        .{ .id = "next", .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 10 } } },
    } }, &serial);
    const fit = root.children.items[0];
    const leaf = fit.children.items[0];
    core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try std.testing.expectEqual(@as(f32, 20), root.children.items[1].rectFromWorldOrFallback().y);
    leaf.style.height = .{ .px = 40 };
    leaf.frame_state.state_bits.dirty.core.layout = true;
    fit.frame_state.state_bits.dirty.core.subtree_layout = true;
    root.frame_state.state_bits.dirty.core.layout = false;
    root.frame_state.state_bits.dirty.core.subtree_layout = true;
    core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try std.testing.expectEqual(@as(f32, 40), root.children.items[1].rectFromWorldOrFallback().y);
}

test "LC3B wrap mount observes final line geometry and permits reentry once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var serial: u32 = 0;
    const root = try make(a, .{ .id = "root", .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .direction = .row, .flex_wrap = .wrap, .align_content = .center }, .children = &.{
        .{ .id = "first", .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } } },
        .{ .id = "second", .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } } },
    } }, &serial);
    const Probe = struct {
        root: *core.Node,
        node: *core.Node,
        allocator: std.mem.Allocator,
        count: usize = 0,
        x: f32 = -1,
        y: f32 = -1,
        fn mounted(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.count += 1;
            p.x = p.node.rectFromWorldOrFallback().x;
            p.y = p.node.rectFromWorldOrFallback().y;
            core.layout_engine.layoutNode(p.root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = p.allocator });
        }
    };
    var probe = Probe{ .root = root, .node = root.children.items[1], .allocator = a };
    probe.node.meta.ownership.hooks.on_mount = .{ .callback = Probe.mounted, .context = &probe };
    core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(@as(f32, 50), probe.x);
    try std.testing.expectEqual(@as(f32, 40), probe.y);
    root.frame_state.state_bits.dirty.core.layout = true;
    core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
    try std.testing.expectEqual(@as(usize, 1), probe.count);
}

test "LC3B wrap mount can remove and destroy itself after final placement" {
    const a = std.testing.allocator;
    var serial: u32 = 0;
    const root = try make(a, .{ .id = "root", .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .direction = .row, .flex_wrap = .wrap, .align_content = .center }, .children = &.{
        .{ .id = "first", .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } } },
        .{ .id = "second", .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } } },
    } }, &serial);
    defer root.destroy(a);
    var frame = std.heap.ArenaAllocator.init(a);
    defer frame.deinit();
    const Probe = struct {
        root: *core.Node,
        node: *core.Node,
        allocator: std.mem.Allocator,
        mounts: usize = 0,
        cleanups: usize = 0,
        x: f32 = -1,
        y: f32 = -1,
        fn mount(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.mounts += 1;
            p.x = p.node.rectFromWorldOrFallback().x;
            p.y = p.node.rectFromWorldOrFallback().y;
            p.root.removeChild(p.node);
            p.node.destroy(p.allocator);
        }
        fn cleanup(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.cleanups += 1;
        }
    };
    var probe = Probe{ .root = root, .node = root.children.items[1], .allocator = a };
    probe.node.meta.ownership.hooks.on_mount = .{ .callback = Probe.mount, .context = &probe };
    probe.node.meta.ownership.hooks.on_cleanup = .{ .callback = Probe.cleanup, .context = &probe };
    core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = frame.allocator() });
    try std.testing.expectEqual(@as(usize, 1), probe.mounts);
    try std.testing.expectEqual(@as(usize, 1), probe.cleanups);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(@as(f32, 50), probe.x);
    try std.testing.expectEqual(@as(f32, 40), probe.y);
    root.frame_state.state_bits.dirty.core.layout = true;
    core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = frame.allocator() });
    try std.testing.expectEqual(@as(usize, 1), probe.mounts);
}

test "LC3B wrap publishes deep mount hooks after clean intrinsic probes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var serial: u32 = 0;
    const root = try make(a, .{ .id = "root", .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .direction = .row, .flex_wrap = .wrap, .align_content = .center }, .children = &.{
        .{ .id = "first", .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } } },
        .{ .id = "second", .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } }, .children = &.{
            .{ .id = "middle", .style = .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .children = &.{
                .{ .id = "deep", .style = .{ .width = .{ .px = 5 }, .height = .{ .px = 5 } } },
            } },
        } },
    } }, &serial);
    const Probe = struct {
        node: *core.Node,
        mounts: usize = 0,
        x: f32 = 0,
        y: f32 = 0,
        fn mount(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.mounts += 1;
            var node: ?*core.Node = p.node;
            while (node) |n| : (node = n.parent) {
                const rect = n.rectFromWorldOrFallback();
                p.x += rect.x;
                p.y += rect.y;
            }
        }
    };
    var probe = Probe{ .node = root.children.items[1].children.items[0].children.items[0] };
    probe.node.meta.ownership.hooks.on_mount = .{ .callback = Probe.mount, .context = &probe };
    for (0..2) |_| {
        core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
        try std.testing.expectEqual(@as(usize, 1), probe.mounts);
        try std.testing.expectEqual(@as(f32, 50), probe.x);
        try std.testing.expectEqual(@as(f32, 40), probe.y);
    }
    // Adding a new deep node below already-mounted ancestors must survive
    // deferred probes even when the card's final allocation is unchanged.
    const added = try make(a, .{ .id = "added", .style = .{ .width = .{ .px = 5 }, .height = .{ .px = 5 } } }, &serial);
    try probe.node.parent.?.appendChild(a, added);
    var added_probe = Probe{ .node = added };
    added.meta.ownership.hooks.on_mount = .{ .callback = Probe.mount, .context = &added_probe };
    for (0..2) |_| {
        core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
        try std.testing.expectEqual(@as(usize, 1), added_probe.mounts);
        try std.testing.expectEqual(@as(f32, 50), added_probe.x);
        try std.testing.expectEqual(@as(f32, 45), added_probe.y);
    }
}

test "LC3B baseline groups retain signed distances outside line boxes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]core.FlexWrap{ .no_wrap, .wrap, .wrap_reverse }) |wrap| {
        var serial: u32 = 0;
        const root = try make(a, .{ .id = "root", .style = .{ .width = .{ .px = 100 }, .direction = .row, .flex_wrap = wrap, .align_items = .baseline, .align_content = .start }, .children = &.{
            .{ .id = "a", .style = .{ .width = .{ .px = 50 } }, .text = .{ .content = "A", .font_size = 16, .line_height = 0.5 } },
            .{ .id = "b", .style = .{ .width = .{ .px = 50 } }, .text = .{ .content = "A", .font_size = 32, .line_height = 0.5 } },
        } }, &serial);
        // Explicit out-of-box baselines make this independent of host fonts.
        // Outer sizes 8/16; baselines16/32 => before32 + after(-8) =24.
        for (root.children.items) |child| {
            var text = child.resolveTextProps().?;
            text.baseline_ratio = 2;
            child.setText(text);
        }
        core.layout_engine.layoutNode(root, .{ .width = 100, .height = 100 }, .{ .frame_allocator = a });
        try std.testing.expectEqual(@as(f32, 24), root.rectFromWorldOrFallback().h);
        try std.testing.expectEqual(@as(f32, 16), root.children.items[0].rectFromWorldOrFallback().y);
        try std.testing.expectEqual(@as(f32, 0), root.children.items[1].rectFromWorldOrFallback().y);
    }
}

test "LC3B reversed safe fallback also reaches wrapped main allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]core.JustifyContent{ .space_around, .space_evenly }) |justify| {
        var serial: u32 = 0;
        // A singleton wider than the container forces negative free space in
        // the wrap main-axis path. Zenit keeps its chosen flex-start fallback.
        const root = try make(a, .{ .id = "root", .style = .{ .width = .{ .px = 180 }, .height = .{ .px = 120 }, .direction = .row_reverse, .flex_wrap = .wrap, .justify = justify, .align_content = .start }, .children = &.{
            .{ .id = "a", .style = .{ .width = .{ .px = 260 }, .height = .{ .px = 20 }, .flex_shrink = 0 } },
        } }, &serial);
        core.layout_engine.layoutNode(root, .{ .width = 180, .height = 120 }, .{ .frame_allocator = a });
        try std.testing.expectEqual(@as(f32, -80), root.children.items[0].rectFromWorldOrFallback().x);
    }
}

test "LC3B reverse fallback geometry stays flex-start during engine disagreement" {
    const parsed = try std.json.parseFromSlice(Suite, std.testing.allocator, @embedFile("fixtures.json"), .{});
    defer parsed.deinit();
    const Contract = struct { id: []const u8, rects: []const Rect };
    const contracts = [_]Contract{
        .{ .id = "lc3b-overflow-row_reverse-space_around", .rects = &.{ .{ .id = "root", .x = 0, .y = 0, .w = 180, .h = 120 }, .{ .id = "a", .x = 50, .y = 0, .w = 130, .h = 20 }, .{ .id = "b", .x = -87, .y = 0, .w = 130, .h = 20 } } },
        .{ .id = "lc3b-overflow-row_reverse-space_evenly", .rects = &.{ .{ .id = "root", .x = 0, .y = 0, .w = 180, .h = 120 }, .{ .id = "a", .x = 50, .y = 0, .w = 130, .h = 20 }, .{ .id = "b", .x = -87, .y = 0, .w = 130, .h = 20 } } },
        .{ .id = "lc3b-overflow-column_reverse-space_around", .rects = &.{ .{ .id = "root", .x = 0, .y = 0, .w = 180, .h = 120 }, .{ .id = "a", .x = 0, .y = -10, .w = 20, .h = 130 }, .{ .id = "b", .x = 0, .y = -147, .w = 20, .h = 130 } } },
        .{ .id = "lc3b-overflow-column_reverse-space_evenly", .rects = &.{ .{ .id = "root", .x = 0, .y = 0, .w = 180, .h = 120 }, .{ .id = "a", .x = 0, .y = -10, .w = 20, .h = 130 }, .{ .id = "b", .x = 0, .y = -147, .w = 20, .h = 130 } } },
        .{ .id = "lc3b-line-overflow-wrap_reverse-space_around", .rects = &.{ .{ .id = "root", .x = 0, .y = 0, .w = 180, .h = 120 }, .{ .id = "0", .x = 0, .y = 30, .w = 120, .h = 90 }, .{ .id = "1", .x = 0, .y = -60, .w = 120, .h = 90 } } },
        .{ .id = "lc3b-line-overflow-wrap_reverse-space_evenly", .rects = &.{ .{ .id = "root", .x = 0, .y = 0, .w = 180, .h = 120 }, .{ .id = "0", .x = 0, .y = 30, .w = 120, .h = 90 }, .{ .id = "1", .x = 0, .y = -60, .w = 120, .h = 90 } } },
    };
    var count: usize = 0;
    for (parsed.value.fixtures) |f| {
        var expected: ?[]const Rect = null;
        for (contracts) |contract| {
            if (std.mem.eql(u8, f.id, contract.id)) expected = contract.rects;
        }
        const rects = expected orelse continue;
        count += 1;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var serial: u32 = 0;
        const root = try make(a, f.root, &serial);
        core.layout_engine.layoutNode(root, .{ .width = f.width, .height = f.height }, .{ .frame_allocator = a });
        var actual: std.ArrayList(Rect) = .empty;
        try collect(a, root, f.root, 0, 0, &actual);
        try std.testing.expectEqual(rects.len, actual.items.len);
        for (rects, actual.items) |want, got| {
            try std.testing.expectEqualStrings(want.id, got.id);
            inline for (.{ "x", "y", "w", "h" }) |field| try std.testing.expectApproxEqAbs(@field(want, field), @field(got, field), 0.01);
        }
    }
    try std.testing.expectEqual(@as(usize, 6), count);
}

test "LC3B wrap OOM defers self-destroying mount until successful recovery" {
    const a = std.testing.allocator;
    var serial: u32 = 0;
    const root = try make(a, .{ .id = "root", .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 330 }, .direction = .row, .flex_wrap = .wrap, .align_content = .start } }, &serial);
    defer root.destroy(a);
    for (0..33) |_| {
        const child = try make(a, .{ .id = "child", .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 10 } } }, &serial);
        try root.appendChild(a, child);
    }
    const Probe = struct {
        root: *core.Node,
        node: *core.Node,
        allocator: std.mem.Allocator,
        mounts: usize = 0,
        cleanups: usize = 0,
        y: f32 = -1,
        fn mount(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.mounts += 1;
            p.y = p.node.rectFromWorldOrFallback().y;
            p.root.removeChild(p.node);
            p.node.destroy(p.allocator);
        }
        fn cleanup(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.cleanups += 1;
        }
    };
    var probe = Probe{ .root = root, .node = root.children.items[32], .allocator = a };
    probe.node.meta.ownership.hooks.on_mount = .{ .callback = Probe.mount, .context = &probe };
    probe.node.meta.ownership.hooks.on_cleanup = .{ .callback = Probe.cleanup, .context = &probe };
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    core.layout_engine.layoutNode(root, .{ .width = 20, .height = 330 }, .{ .frame_allocator = failing.allocator() });
    try std.testing.expectEqual(@as(usize, 0), probe.mounts);
    try std.testing.expectEqual(@as(usize, 0), probe.cleanups);
    try std.testing.expectEqual(@as(f32, 20), probe.node.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 10), probe.node.rectFromWorldOrFallback().h);
    var frame = std.heap.ArenaAllocator.init(a);
    defer frame.deinit();
    core.layout_engine.layoutNode(root, .{ .width = 20, .height = 330 }, .{ .frame_allocator = frame.allocator() });
    try std.testing.expectEqual(@as(usize, 1), probe.mounts);
    try std.testing.expectEqual(@as(usize, 1), probe.cleanups);
    try std.testing.expectEqual(@as(f32, 320), probe.y);
    try std.testing.expectEqual(@as(usize, 32), root.children.items.len);
    core.layout_engine.layoutNode(root, .{ .width = 20, .height = 330 }, .{ .frame_allocator = frame.allocator() });
    try std.testing.expectEqual(@as(usize, 1), probe.mounts);
    try std.testing.expectEqual(@as(usize, 1), probe.cleanups);
}

test "LC3C border positioning aspect and grid contracts reach real fixture trees" {
    const parsed = try std.json.parseFromSlice(Suite, std.testing.allocator, @embedFile("fixtures.json"), .{});
    defer parsed.deinit();
    const Case = struct { id: []const u8, path: []const usize = &.{0}, rect: [4]f32 };
    for ([_]Case{
        .{ .id = "lc3c-glm-absolute-static-flex", .path = &.{0}, .rect = .{ 22, 18, 40, 20 } },
        .{ .id = "lc3c-glm-absolute-static-flex", .path = &.{1}, .rect = .{ 5, 5, 40, 20 } },
        // Grid: static position is the padding edge (CSS Grid 1 §9.1); Chromium/Firefox/WebKit agree.
        .{ .id = "lc3c-glm-absolute-static-grid", .path = &.{0}, .rect = .{ 5, 5, 40, 20 } },
        .{ .id = "lc3c-glm-absolute-static-grid", .path = &.{1}, .rect = .{ 5, 5, 40, 20 } },
        .{ .id = "lc3c-glm-grid-span-fr-min", .path = &.{1}, .rect = .{ 0, 40, 100, 20 } },
        .{ .id = "lc3c-glm-grid-span-fr-min", .path = &.{2}, .rect = .{ 100, 40, 200, 20 } },
        .{ .id = "lc3c-glm-grid-row-locked-hole", .path = &.{1}, .rect = .{ 40, 0, 40, 10 } },
        .{ .id = "lc3c-glm-grid-row-locked-hole", .path = &.{2}, .rect = .{ 80, 0, 10, 10 } },
        .{ .id = "lc3c-glm-grid-row-locked-first-hole", .path = &.{1}, .rect = .{ 0, 0, 10, 10 } },
        .{ .id = "lc3c-glm-aspect-percent-definite", .path = &.{0}, .rect = .{ 0, 0, 80, 100 } },
        .{ .id = "lc3c-glm-aspect-percent-indefinite", .path = &.{0}, .rect = .{ 0, 0, 80, 40 } },
        .{ .id = "lc3c-glm-aspect-percent-grid", .path = &.{0}, .rect = .{ 0, 0, 120, 60 } },
        .{ .id = "lc3c-absolute-floor-ratio", .rect = .{ 292, 92, 8, 8 } },
        .{ .id = "lc3c-absolute-floor-ratio", .path = &.{1}, .rect = .{ 5, 5, 100, 50 } },
        .{ .id = "lc3c-aspect-column-wrap", .rect = .{ 0, 0, 80, 40 } },
        .{ .id = "lc3c-aspect-column-wrap_reverse", .rect = .{ 220, 0, 80, 40 } },
        .{ .id = "lc3c-aspect-min-wins", .rect = .{ 0, 0, 100, 60 } },
        .{ .id = "lc3c-aspect-nested-min", .rect = .{ 0, 0, 80, 40 } },
        .{ .id = "lc3c-grid-partial-fr", .path = &.{1}, .rect = .{ 75, 0, 75, 40 } },
        .{ .id = "lc3c-grid-row-locked-sparse", .path = &.{1}, .rect = .{ 40, 0, 10, 10 } },
        .{ .id = "lc3c-grid-row-locked-sparse", .path = &.{2}, .rect = .{ 60, 0, 10, 10 } },
        .{ .id = "lc3c-aspect-root", .path = &.{}, .rect = .{ 0, 0, 100, 50 } },
        .{ .id = "lc3c-initial-containing-block", .rect = .{ 275, 85, 20, 10 } },
        .{ .id = "lc3c-grid-align-center", .rect = .{ 100, 40, 20, 10 } },
        .{ .id = "lc3c-grid-align-center", .path = &.{1}, .rect = .{ 150, 40, 20, 10 } },
        .{ .id = "lc3c-grid-align-end", .rect = .{ 200, 40, 20, 10 } },
        .{ .id = "lc3c-grid-align-space_between", .path = &.{1}, .rect = .{ 250, 40, 20, 10 } },
        .{ .id = "lc3c-absolute-static-transform", .path = &.{ 0, 0 }, .rect = .{ 71, 41, 20, 10 } },
        .{ .id = "lc3c-absolute-static-contain", .path = &.{ 0, 0 }, .rect = .{ 71, 41, 20, 10 } },
        .{ .id = "border-flow", .path = &.{ 0, 0 }, .rect = .{ 15, 15, 40, 20 } },
        .{ .id = "absolute-border", .rect = .{ 250, 70, 40, 20 } },
        .{ .id = "relative-inset", .rect = .{ 30, 0, 40, 20 } },
        .{ .id = "aspect-height", .rect = .{ 0, 0, 80, 40 } },
        .{ .id = "aspect-minmax", .rect = .{ 0, 0, 100, 20 } },
        .{ .id = "aspect-percent", .rect = .{ 0, 0, 100, 80 } },
        .{ .id = "lc3c-border-fit", .rect = .{ 0, 0, 35, 19 } },
        .{ .id = "lc3c-border-floor", .rect = .{ 0, 0, 10, 9 } },
        .{ .id = "lc3c-border-overlay", .path = &.{ 0, 0 }, .rect = .{ 5, 5, 40, 20 } },
        .{ .id = "lc3c-border-percent", .rect = .{ 15, 15, 135, 35 } },
        .{ .id = "lc3c-absolute-percent", .rect = .{ 38, 18, 140, 40 } },
        .{ .id = "lc3c-absolute-static-ancestor", .path = &.{ 0, 0 }, .rect = .{ 225, 45, 20, 10 } },
        .{ .id = "lc3c-relative-physical", .rect = .{ 15, 10, 40, 20 } },
        .{ .id = "lc3c-relative-physical", .path = &.{1}, .rect = .{ 35, -4, 40, 20 } },
        .{ .id = "lc3c-aspect-no_wrap", .rect = .{ 0, 0, 100, 50 } },
        .{ .id = "lc3c-aspect-wrap", .rect = .{ 0, 0, 100, 50 } },
        .{ .id = "lc3c-aspect-wrap_reverse", .rect = .{ 0, 50, 100, 50 } },
        .{ .id = "lc3c-aspect-border", .rect = .{ 0, 0, 100, 50 } },
        .{ .id = "lc3c-aspect-auto-min", .rect = .{ 0, 0, 80, 40 } },
        .{ .id = "lc3c-aspect-zero-min", .rect = .{ 0, 0, 50, 40 } },
        .{ .id = "grid-intrinsic-fr", .path = &.{1}, .rect = .{ 200, 0, 0, 20 } },
        .{ .id = "grid-minmax", .rect = .{ 0, 0, 200, 20 } },
        .{ .id = "grid-implicit-rows", .path = &.{1}, .rect = .{ 0, 33.33333, 100, 30 } },
        .{ .id = "grid-implicit-columns", .rect = .{ 50, 0, 40, 20 } },
        .{ .id = "grid-row-limit", .path = &.{64}, .rect = .{ 0, 64, 100, 1 } },
        .{ .id = "lc3c-grid-content-align-margin", .rect = .{ 5, 18, 20, 10 } },
        .{ .id = "lc3c-grid-minmax-default", .rect = .{ 0, 0, 0, 40 } },
        .{ .id = "lc3c-grid-minmax-default", .path = &.{1}, .rect = .{ 0, 0, 300, 40 } },
        .{ .id = "lc3c-grid-minmax-fr", .path = &.{1}, .rect = .{ 150, 0, 150, 40 } },
        .{ .id = "lc3c-grid-minmax-cap", .path = &.{1}, .rect = .{ 80, 0, 220, 40 } },
        .{ .id = "lc3c-grid-partial-placement", .rect = .{ 0, 25, 50, 30 } },
        .{ .id = "lc3c-grid-partial-placement", .path = &.{1}, .rect = .{ 60, 0, 60, 20 } },
        .{ .id = "lc3c-grid-partial-placement", .path = &.{2}, .rect = .{ 60, 25, 60, 30 } },
        .{ .id = "lc3c-grid-auto-span", .path = &.{1}, .rect = .{ 0, 45, 0, 30 } },
    }) |case| {
        var found = false;
        for (parsed.value.fixtures) |f| {
            if (!std.mem.eql(u8, f.id, case.id)) continue;
            found = true;
            try std.testing.expect(f.must_match);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var serial: u32 = 0;
            const root = try make(arena.allocator(), f.root, &serial);
            core.layout_engine.layoutNode(root, .{ .width = f.width, .height = f.height }, .{ .frame_allocator = arena.allocator() });
            var n = root;
            for (case.path) |i| n = n.children.items[i];
            const r = n.rectFromWorldOrFallback();
            for ([_]f32{ r.x, r.y, r.w, r.h }, case.rect) |actual, expected| {
                if (@abs(actual - expected) > 0.01) std.debug.print("LC3C {s}: {any} expected {any}\n", .{ case.id, r, case.rect });
                try std.testing.expectApproxEqAbs(expected, actual, 0.01);
            }
        }
        try std.testing.expect(found);
    }
}

test "LC3C overflow wrap controls automatic minimum and emergency line breaks" {
    const parsed = try std.json.parseFromSlice(Suite, std.testing.allocator, @embedFile("fixtures.json"), .{});
    defer parsed.deinit();
    var count: usize = 0;
    for (parsed.value.fixtures) |f| {
        const emergency_explicit_zero = std.mem.eql(u8, f.id, "lc3c-text-emergency-break-word");
        if (!std.mem.startsWith(u8, f.id, "lc3c-word-") and !emergency_explicit_zero) continue;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var serial: u32 = 0;
        const root = try make(arena.allocator(), f.root, &serial);
        core.layout_engine.layoutNode(root, .{ .width = f.width, .height = f.height }, .{ .frame_allocator = arena.allocator() });
        const child = root.children.items[0];
        const r = child.rectFromWorldOrFallback();
        const emergency_min = std.mem.endsWith(u8, f.id, "anywhere") or std.mem.endsWith(u8, f.id, "break_all");
        if (emergency_min or emergency_explicit_zero) {
            try std.testing.expectApproxEqAbs(@as(f32, 40), r.w, 0.01);
            try std.testing.expect(child.layoutTextLayout().?.line_count > 1);
        } else {
            try std.testing.expect(r.w > 40);
            try std.testing.expectEqual(@as(u32, 1), @as(u32, child.layoutTextLayout().?.line_count));
        }
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), count);
}

test "LC3C farther containing block resize invalidates static ancestor caches" {
    const parsed = try std.json.parseFromSlice(Suite, std.testing.allocator, @embedFile("fixtures.json"), .{});
    defer parsed.deinit();
    var found = false;
    for (parsed.value.fixtures) |f| {
        if (!std.mem.eql(u8, f.id, "lc3c-absolute-static-ancestor")) continue;
        found = true;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var serial: u32 = 0;
        const root = try make(arena.allocator(), f.root, &serial);
        for ([_]f32{ 300, 400, 300 }) |width| {
            root.style.width = .{ .px = width };
            root.frame_state.state_bits.dirty.core.layout = true;
            core.layout_engine.layoutNode(root, .{ .width = width, .height = 100 }, .{ .frame_allocator = arena.allocator() });
            const r = root.children.items[0].children.items[0].rectFromWorldOrFallback();
            try std.testing.expectApproxEqAbs(width - 75, r.x, 0.01);
        }
    }
    try std.testing.expect(found);
}

test "LC3C track parser keeps auto and minmax breadths distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auto = try std.json.parseFromSlice(std.json.Value, a, "\"auto\"", .{});
    try std.testing.expect(try parseTrack(a, auto.value) == .auto);
    const mm = try std.json.parseFromSlice(std.json.Value, a, "{\"minmax\":{\"min\":\"auto\",\"max\":{\"fr\":1}}}", .{});
    const track = try parseTrack(a, mm.value);
    try std.testing.expect(track.minmax.min == .auto);
    try std.testing.expectEqual(@as(f32, 1), track.minmax.max.fr);
}
