//! Offline generator: AST-scan Zig source trees for component_name assignments
//! and emit a sorted `component_name -> source location` table for DevTools'
//! "goto source" button (Elements tree row hover → open the component's
//! definition in an editor).
//!
//! Why an AST scan instead of `@src()` instrumentation: Zig has no call-site
//! default arguments (`fn f(src: SourceLocation = @src())` is a parse error),
//! and `@src()` inside an `inline fn` yields the *callee's* own location, not
//! the caller's. Capturing the definition site would therefore mean hand-writing
//! `@src()` at every node-construction site (600+ across zenit + consumers) and
//! maintaining that forever. Scanning the source is zero-touch and covers every
//! string-literal assignment. Names built at runtime (e.g.
//! `component_name = pickName(kind)`) are inherently unresolvable statically and
//! are skipped — DevTools just shows no button for those.
//!
//! The matched pattern is structural, not textual: an `.assign` node whose LHS
//! is a `.field_access` named `component_name` and whose RHS is a
//! `.string_literal`. Commented-out code and matching text inside strings do not
//! produce false positives.
//!
//! Build & run:
//!   zig build gen-component-index      (see build.zig `gen-component-index` step)
//!
//! Args: <output_file> <root>[:<label>] [<root>[:<label>] ...]
//!   output_file — path to write generated Zig
//!   root        — directory to scan recursively for *.zig
//!   label       — optional prefix recorded with each hit, so a consumer app can
//!                 tell "this component is defined in the framework" from "this
//!                 one is mine". Defaults to the root's basename.
const std = @import("std");

const Entry = struct {
    name: []const u8,
    /// Path as recorded in the generated table (see `path_prefix`).
    file: []const u8,
    line: u32,
    col: u32,
    label: []const u8,
};

/// Recursively AST-scan `root` for `<expr>.component_name = "<literal>"`.
fn scanRoot(
    alloc: std.mem.Allocator,
    root: []const u8,
    label: []const u8,
    path_prefix: []const u8,
    out: *std.ArrayList(Entry),
    stats: *Stats,
) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        std.debug.print("WARN: open {s}: {s} — skipped\n", .{ root, @errorName(err) });
        return;
    };
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const src = entry.dir.readFileAllocOptions(
            alloc,
            entry.basename,
            MAX_FILE_BYTES,
            null,
            .of(u8),
            0,
        ) catch |err| {
            std.debug.print("WARN: read {s}: {s} — skipped\n", .{ entry.path, @errorName(err) });
            stats.skipped += 1;
            continue;
        };
        defer alloc.free(src);

        stats.files += 1;

        // Path recorded in the table: prefix + path relative to the scan root,
        // so the running app can resolve it without knowing the build layout.
        const rel = try std.fs.path.join(alloc, &.{ path_prefix, entry.path });
        try scanFile(alloc, src, rel, label, out, stats);
    }
}

const MAX_FILE_BYTES = 1 << 24;

const Stats = struct {
    files: usize = 0,
    skipped: usize = 0,
    parse_errors: usize = 0,
    dynamic: usize = 0,
};

fn scanFile(
    alloc: std.mem.Allocator,
    src: [:0]const u8,
    rel_path: []const u8,
    label: []const u8,
    out: *std.ArrayList(Entry),
    stats: *Stats,
) !void {
    var ast = std.zig.Ast.parse(alloc, src, .zig) catch |err| {
        std.debug.print("WARN: parse {s}: {s} — skipped\n", .{ rel_path, @errorName(err) });
        stats.parse_errors += 1;
        return;
    };
    defer ast.deinit(alloc);

    // A file that does not parse cleanly may still be walkable, but its node
    // data is unreliable — treat it as a hard skip so we never emit bad lines.
    if (ast.errors.len > 0) {
        stats.parse_errors += 1;
        return;
    }

    const tags = ast.nodes.items(.tag);
    const datas = ast.nodes.items(.data);
    const main_tokens = ast.nodes.items(.main_token);

    for (tags, 0..) |tag, i| {
        if (tag != .assign) continue;
        const pair = datas[i].node_and_node;

        const lhs = @intFromEnum(pair[0]);
        if (tags[lhs] != .field_access) continue;
        // `.field_access` stores the field-name token as the token half.
        const field_tok = datas[lhs].node_and_token[1];
        if (!std.mem.eql(u8, ast.tokenSlice(field_tok), "component_name")) continue;

        const rhs = @intFromEnum(pair[1]);
        if (tags[rhs] != .string_literal) {
            // Runtime-computed name — nothing to point an editor at.
            stats.dynamic += 1;
            continue;
        }

        const raw = ast.tokenSlice(main_tokens[rhs]);
        // Decode escapes so the table holds the same bytes the UI compares
        // against at runtime.
        var name_buf = std.Io.Writer.Allocating.init(alloc);
        errdefer name_buf.deinit();
        switch (try std.zig.string_literal.parseWrite(&name_buf.writer, raw)) {
            .success => {},
            .failure => {
                name_buf.deinit();
                continue;
            },
        }
        const name = try name_buf.toOwnedSlice();

        // Point at the assignment target, which is the line a developer wants
        // to land on.
        const loc = ast.tokenLocation(0, main_tokens[lhs]);
        try out.append(alloc, .{
            .name = name,
            .file = try alloc.dupe(u8, rel_path),
            .line = @intCast(loc.line + 1),
            .col = @intCast(loc.column + 1),
            .label = label,
        });
    }
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    // Primary key: name (binary-searched at runtime). Ties broken by location so
    // regeneration is byte-stable and duplicate names keep a deterministic order.
    return switch (std.mem.order(u8, a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => switch (std.mem.order(u8, a.file, b.file)) {
            .lt => true,
            .gt => false,
            .eq => a.line < b.line,
        },
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Entry names/paths live until the file is written; an arena frees them in
    // one shot instead of tracking each string's lifetime.
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 3) {
        std.debug.print(
            "usage: gen_component_index <output_file> <root>[:<label>[:<path_prefix>]] ...\n",
            .{},
        );
        return error.BadArgs;
    }

    const output_path = args[1];

    var entries = std.ArrayList(Entry){};
    defer entries.deinit(alloc);

    var stats: Stats = .{};

    // --entry-from=<module>: reuse that module's Entry type instead of
    // declaring a local one (see the emit site for why this matters).
    var entry_from: ?[]const u8 = null;
    var roots = std.ArrayList([]const u8){};
    defer roots.deinit(alloc);
    for (args[2..]) |a| {
        if (std.mem.startsWith(u8, a, "--entry-from=")) {
            entry_from = a["--entry-from=".len..];
        } else {
            try roots.append(alloc, a);
        }
    }

    for (roots.items) |spec| {
        // spec = root[:label[:path_prefix]]
        var it = std.mem.splitScalar(u8, spec, ':');
        const root = it.next().?;
        const label = it.next() orelse std.fs.path.basename(root);
        const path_prefix = it.next() orelse root;
        try scanRoot(alloc, root, label, path_prefix, &entries, &stats);
    }

    std.mem.sort(Entry, entries.items, {}, lessThan);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\// This file is auto-generated by tools/gen_component_index.zig. Do not edit manually.
        \\// Regenerate with: zig build gen-component-index
        \\//
        \\// Maps a node's `component_name` to where that name is assigned in source,
        \\// so DevTools can open the component's definition in an editor.
        \\
        \\const std = @import("std");
        \\
    );

    // A consumer app's index must use the *framework's* Entry type, not a
    // structurally identical copy — Zig types are nominal, so a local redeclare
    // would not coerce when handed to source_link.configure().
    if (entry_from) |mod| {
        try w.print(
            \\
            \\pub const Entry = @import("{f}").devtools.source_link.Entry;
            \\
        , .{std.zig.fmtString(mod)});
    } else {
        try w.writeAll(
            \\
            \\pub const Entry = struct {
            \\    name: []const u8,
            \\    file: []const u8,
            \\    line: u32,
            \\    col: u32,
            \\    /// Which source tree this came from (e.g. "zenit", "app").
            \\    label: []const u8,
            \\};
            \\
        );
    }

    try w.writeAll(
        \\
        \\/// Sorted by `name`, so `lookup` can binary-search. Duplicate names are
        \\/// possible (several components share a short name); `lookup` returns the
        \\/// first and `lookupAll` returns the full run.
        \\pub const entries = [_]Entry{
        \\
    );

    for (entries.items) |e| {
        try w.print("    .{{ .name = \"{f}\", .file = \"{f}\", .line = {d}, .col = {d}, .label = \"{f}\" }},\n", .{
            std.zig.fmtString(e.name),
            std.zig.fmtString(e.file),
            e.line,
            e.col,
            std.zig.fmtString(e.label),
        });
    }

    try w.writeAll(
        \\};
        \\
        \\/// First entry whose name matches, or null. O(log n).
        \\pub fn lookup(name: []const u8) ?Entry {
        \\    const run = lookupAll(name);
        \\    return if (run.len == 0) null else run[0];
        \\}
        \\
        \\/// Every entry matching `name` (contiguous, since `entries` is sorted).
        \\pub fn lookupAll(name: []const u8) []const Entry {
        \\    var lo: usize = 0;
        \\    var hi: usize = entries.len;
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        if (std.mem.lessThan(u8, entries[mid].name, name)) lo = mid + 1 else hi = mid;
        \\    }
        \\    var end = lo;
        \\    while (end < entries.len and std.mem.eql(u8, entries[end].name, name)) end += 1;
        \\    return entries[lo..end];
        \\}
        \\
    );

    const out_bytes = aw.written();
    if (std.fs.path.dirname(output_path)) |d| {
        std.fs.cwd().makePath(d) catch {};
    }
    try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = out_bytes });

    std.debug.print(
        "gen_component_index: {d} entries from {d} files -> {s}" ++
            " ({d} dynamic names skipped, {d} parse-skipped, {d} unreadable)\n",
        .{ entries.items.len, stats.files, output_path, stats.dynamic, stats.parse_errors, stats.skipped },
    );
}
