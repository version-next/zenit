//! yss-schema: reflect .yss schema from ui style types (src/yix/style_schema_generated.zig, checked
//! in).
//!
//! - Properties: fields of `BoxStyle` / `TextStyle`, meta-keys recognized by ui.css typography /
//!   transition (`color` and `text_color` are aliases, consistent with ui.css), token categories
//!   (`ui.styleCategory`, same function used by css lookup), optional names for enum / bool / width
//!   / height, `///` doc comment on field;
//! - Tokens: default design system (src/tokens/default.json) token names and light/dark values for
//!   each category.
//!
//! .yss compiler uses property table to report unknown properties/enum values at source location;
//! yix-lsp uses it for completion and hover.
//! `zig build gen-yss-schema` regenerates; `check-yss-schema` compares only (included in
//! test-headless).
//! Usage: yss-schema gen|check <out.zig> <source files defining BoxStyle / TextStyle>...
const std = @import("std");
const ui = @import("ui");

const out_header =
    \\//! GENERATED FILE, do not edit: `zig build gen-yss-schema` (tools/yss_schema.zig reflects ui.BoxStyle /
    \\//! ui.TextStyle / ui.styleCategory / the default theme). Shared by the .yss compiler and yix-lsp.
    \\
    \\/// One style property (field name is snake_case; .yss spells it with hyphens)
    \\pub const Prop = struct {
    \\    name: []const u8,
    \\    /// Whether box style / text style has this field (includes the color <-> text_color alias)
    \\    box: bool,
    \\    text: bool,
    \\    /// Token category used to look the name up in the token table; "" = takes no token
    \\    category: []const u8,
    \\    type_name: []const u8,
    \\    /// Accepted names (enum values, true / false, grow / fit / fill for width and height)
    \\    values: []const []const u8 = &.{},
    \\    doc: []const u8 = "",
    \\};
    \\pub const Token = struct { name: []const u8, light: []const u8, dark: []const u8 };
    \\/// All tokens of one category in the default design system
    \\pub const Scale = struct { category: []const u8, tokens: []const Token };
    \\
    \\pub fn prop(name: []const u8) ?*const Prop {
    \\    for (&props) |*p| if (eql(p.name, name)) return p;
    \\    return null;
    \\}
    \\
    \\pub fn scale(category: []const u8) ?*const Scale {
    \\    for (&scales) |*s| if (eql(s.category, category)) return s;
    \\    return null;
    \\}
    \\
    \\fn eql(a: []const u8, b: []const u8) bool {
    \\    if (a.len != b.len) return false;
    \\    for (a, b) |x, y| if (x != y) return false;
    \\    return true;
    \\}
    \\
    \\
;

const Entry = struct { name: []const u8, box: bool, text: bool, category: []const u8, type_name: []const u8, values: []const []const u8, doc: []const u8 };

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa_state.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 4 or !(std.mem.eql(u8, args[1], "gen") or std.mem.eql(u8, args[1], "check"))) {
        std.debug.print("usage: yss-schema gen|check <out.zig> <source.zig>...\n", .{});
        std.process.exit(2);
    }
    var sources: std.ArrayList([]const u8) = .empty;
    for (args[3..]) |path| try sources.append(a, try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(16 * 1024 * 1024)));
    // Normalize per zig fmt (generated output must pass format gate)
    const raw = try render(a, sources.items);
    var ast = try std.zig.Ast.parse(a, try a.dupeSentinel(u8, raw, 0), .{});
    if (ast.errors.len != 0) {
        std.debug.print("yss-schema: generated Zig does not parse (generator bug)\n", .{});
        std.process.exit(1);
    }
    const text = try ast.renderAlloc(a);
    if (std.mem.eql(u8, args[1], "gen")) {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = text });
        return;
    }
    const current = std.Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(16 * 1024 * 1024)) catch "";
    if (!std.mem.eql(u8, current, text)) {
        std.debug.print("{s} is stale; run `zig build gen-yss-schema`\n", .{args[2]});
        std.process.exit(1);
    }
}

fn render(a: std.mem.Allocator, sources: []const []const u8) ![]u8 {
    const box_docs = try fieldDocs(a, sources, "BoxStyle");
    const text_docs = try fieldDocs(a, sources, "TextStyle");
    var entries: std.ArrayList(Entry) = .empty;
    try collect(a, &entries, ui.BoxStyle, true, box_docs);
    try collect(a, &entries, ui.TextStyle, false, text_docs);
    // Meta-keys recognized by ui.css outside struct fields (css.zig: applyTextSpec expands
    // typography; isMetaKey recognizes transition)
    try entries.append(a, .{ .name = "typography", .box = false, .text = true, .category = @tagName(ui.StyleCategory.typography), .type_name = "TypographyPatch", .values = &.{}, .doc = "排版 token：一次给出字号、字重、行高（设计系统的 typography 类别）；同时写的单项属性覆盖它" });
    try entries.append(a, .{ .name = "transition", .box = true, .text = false, .category = "", .type_name = "ui.transition", .values = &.{}, .doc = "属性过渡：整段原文是过渡描述，如 `background 150ms ease-out, opacity 100ms`" });
    // Alias: color on box is text_color, text_color on text is color (ui.css boxName / textName)
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.name, "color")) e.box = true;
        if (std.mem.eql(u8, e.name, "text_color")) e.text = true;
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);

    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(out_header);
    try w.writeAll("pub const props = [_]Prop{\n");
    for (entries.items) |e| {
        try w.print("    .{{ .name = \"{s}\", .box = {}, .text = {}, .category = \"{s}\", .type_name = \"{s}\"", .{ e.name, e.box, e.text, e.category, e.type_name });
        if (e.values.len != 0) {
            try w.writeAll(", .values = &.{");
            for (e.values, 0..) |v, i| try w.print("{s}\"{s}\"", .{ if (i == 0) " " else ", ", v });
            try w.writeAll(" }");
        }
        if (e.doc.len != 0) try w.print(", .doc = {s}", .{try literal(a, e.doc)});
        try w.writeAll(" },\n");
    }
    try w.writeAll("};\n\npub const scales = [_]Scale{\n");
    const light = ui.theme.light.tokens;
    const dark = ui.theme.dark.tokens;
    inline for (@import("zenit_reflection").fields(@TypeOf(light))) |cat| {
        try w.print("    .{{ .category = \"{s}\", .tokens = &.{{\n", .{cat.name});
        const L = @field(light, cat.name);
        const D = @field(dark, cat.name);
        inline for (@import("zenit_reflection").fields(@TypeOf(L))) |t| {
            try w.print("        .{{ .name = \"{s}\", .light = {s}, .dark = {s} }},\n", .{ t.name, try literal(a, try valueText(a, @field(L, t.name))), try literal(a, try valueText(a, @field(D, t.name))) });
        }
        try w.writeAll("    } },\n");
    }
    try w.writeAll("};\n");
    return out.toOwnedSlice();
}

/// Fields a style type marks as machinery (`pub const internal_fields`) are not properties.
fn isInternal(comptime S: type, comptime name: []const u8) bool {
    if (!@hasDecl(S, "internal_fields")) return false;
    for (S.internal_fields) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn collect(a: std.mem.Allocator, entries: *std.ArrayList(Entry), comptime S: type, comptime is_box: bool, docs: std.StringHashMapUnmanaged([]const u8)) !void {
    inline for (@import("zenit_reflection").fields(S)) |f| {
        if (comptime isInternal(S, f.name)) continue;
        const T = unwrap(f.type);
        const existing = for (entries.items) |*e| {
            if (std.mem.eql(u8, e.name, f.name)) break e;
        } else null;
        if (existing) |e| {
            if (is_box) e.box = true else e.text = true;
            if (e.doc.len == 0) e.doc = docs.get(f.name) orelse "";
        } else try entries.append(a, .{
            .name = f.name,
            .box = is_box,
            .text = !is_box,
            .category = switch (ui.styleCategory(f.name)) {
                .none => "",
                else => |c| @tagName(c),
            },
            .type_name = shortName(@typeName(T)),
            .values = if (comptime std.mem.eql(u8, f.name, "flex_basis")) &ui.FlexBasis.keywords else comptime valuesOf(T),
            .doc = docs.get(f.name) orelse "",
        });
    }
}

/// Zig string literal (preserve UTF-8 source, escape only quotes / backslash / newline)
fn literal(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (text) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
    return out.items;
}

fn unwrap(comptime T: type) type {
    return if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
}

fn shortName(name: []const u8) []const u8 {
    // Drop namespace prefix (ui.core.types.Direction -> Direction), dots in generic parameters
    // ignored
    const head = if (std.mem.indexOfScalar(u8, name, '(')) |p| name[0..p] else name;
    return if (std.mem.lastIndexOfScalar(u8, head, '.')) |d| name[d + 1 ..] else name;
}

fn valuesOf(comptime T: type) []const []const u8 {
    if (T == ui.Sizing) return &.{ "grow", "fit", "fill" };
    if (T == bool) return &.{ "true", "false" };
    if (@typeInfo(T) != .@"enum") return &.{};
    comptime var out: []const []const u8 = &.{};
    inline for (comptime @import("zenit_reflection").fields(T)) |f| out = out ++ [_][]const u8{f.name};
    return out;
}

/// Display text for token values: color `#rrggbb[aa]`, numbers as-is, struct recurse by field (skip
/// empty)
fn valueText(a: std.mem.Allocator, v: anytype) ![]const u8 {
    const T = @TypeOf(v);
    if (T == ui.Color) {
        if (v.a == 255) return std.fmt.allocPrint(a, "#{x:0>2}{x:0>2}{x:0>2}", .{ v.r, v.g, v.b });
        return std.fmt.allocPrint(a, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ v.r, v.g, v.b, v.a });
    }
    switch (@typeInfo(T)) {
        .int, .float => return std.fmt.allocPrint(a, "{d}", .{v}),
        .optional => return if (v) |x| valueText(a, x) else "",
        .@"struct" => {
            var out: std.Io.Writer.Allocating = .init(a);
            errdefer out.deinit();
            inline for (@import("zenit_reflection").fields(T)) |f| {
                const s = try valueText(a, @field(v, f.name));
                if (s.len != 0) {
                    if (out.writer.buffered().len != 0) try out.writer.writeByte(' ');
                    try out.writer.print("{s}={s}", .{ f.name, s });
                }
            }
            return out.toOwnedSlice();
        },
        else => return "",
    }
}

/// `pub const <container> = struct { ... }` (any source file) `///` comments before each field
/// (multi-line joined by newline)
fn fieldDocs(a: std.mem.Allocator, sources: []const []const u8, container_name: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (sources) |source| {
        try docsIn(a, source, container_name, &map);
        if (map.count() != 0) return map;
    }
    return error.ContainerNotFound;
}

fn docsIn(a: std.mem.Allocator, source: []const u8, container_name: []const u8, map: *std.StringHashMapUnmanaged([]const u8)) !void {
    const z = try a.dupeSentinel(u8, source, 0);
    var ast = try std.zig.Ast.parse(a, z, .{});
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    for (ast.rootDecls()) |decl| {
        const var_decl = ast.fullVarDecl(decl) orelse continue;
        if (!std.mem.eql(u8, ast.tokenSlice(var_decl.ast.mut_token + 1), container_name)) continue;
        const init = var_decl.ast.init_node.unwrap() orelse continue;
        const container = ast.fullContainerDecl(&buf, init) orelse continue;
        for (container.ast.members) |member| {
            const field = ast.fullContainerField(member) orelse continue;
            var doc: std.ArrayList(u8) = .empty;
            var t = ast.firstToken(member);
            while (t > 0 and ast.tokenTag(t - 1) == .doc_comment) t -= 1;
            while (ast.tokenTag(t) == .doc_comment) : (t += 1) {
                if (doc.items.len != 0) try doc.append(a, '\n');
                try doc.appendSlice(a, std.mem.trim(u8, ast.tokenSlice(t)[3..], " "));
            }
            if (doc.items.len != 0) try map.put(a, ast.tokenSlice(field.ast.main_token), doc.items);
        }
        break;
    }
}
