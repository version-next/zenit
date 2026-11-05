//! Yix CLI.
//!
//!   yix INPUT OUTPUT.zig      compile single .yix / .yss (build-time translate test
//!                             fixtures, output in cache dir)
//!   yix gen DIR...            write generated twin `_<name>.zig` beside each .yix / .yss
//!                             in DIR (card.yix -> _card.yix.zig, check in)
//!   yix check DIR...          like gen but verify only: missing, stale, or hand-edited
//!                             twins are reported and exit 1
//!   yix map-errors [DIR]      filter: Zig errors in stdin pointing to twins map back to
//!                             .yix / .yss source (`zig build 2>&1 | yix map-errors`;
//!                             DIR is base for relative paths, default cwd)
//!   gen / check accept `--stamp FILE`: write marker file on success (build system caches
//!                             the step, `--watch` monitors sources)
//!
//! Twins are compiler raw output plus one file header (unformatted: editors map
//! locations by the compiler segment table); same input yields same bytes on any machine.
const std = @import("std");
const compiler = @import("yix_compiler");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 3 and (eq(args[1], "gen") or eq(args[1], "check"))) {
        const check = eq(args[1], "check");
        var dirs = args[2..];
        var stamp: ?[]const u8 = null;
        if (dirs.len >= 2 and eq(dirs[0], "--stamp")) {
            stamp = dirs[1];
            dirs = dirs[2..];
        }
        var problems: usize = 0;
        var count: usize = 0;
        for (dirs) |dir| try tree(a, io, dir, check, &problems, &count);
        if (problems != 0) {
            std.debug.print("yix {s}: {d} problem(s){s}\n", .{ args[1], problems, if (check) "; run `zig build gen-yix`" else "" });
            std.process.exit(1);
        }
        // Build steps with an output stamp capture stderr as diagnostics.
        // Keep successful stamped generation quiet; manual progress is stdout.
        if (!check and stamp == null) try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(a, "yix gen: {d} file(s)\n", .{count}));
        if (stamp) |path| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.fmt.allocPrint(a, "{d}\n", .{count}) });
        return;
    }
    if (args.len >= 2 and eq(args[1], "map-errors")) {
        const text = try blk: {
            var stdin = std.Io.File.stdin().readerStreaming(io, &.{});
            break :blk stdin.interface.allocRemaining(a, .limited(256 * 1024 * 1024));
        };
        var dir = try std.Io.Dir.cwd().openDir(io, if (args.len >= 3) args[2] else ".", .{});
        defer dir.close(io);
        var mapper: compiler.errmap.Mapper = .{ .a = a, .dir = dir, .io = io };
        try std.Io.File.stdout().writeStreamingAll(io, try compiler.errmap.rewrite(&mapper, text));
        return;
    }
    if (args.len != 3) {
        std.debug.print("usage: yix INPUT OUTPUT.zig | yix gen DIR... | yix check DIR... | yix map-errors [DIR]\n", .{});
        std.process.exit(64);
    }
    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[1], a, .limited(8 * 1024 * 1024));
    const out = (try compileOrReport(a, io, args[1], source, false)) orelse std.process.exit(1);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = try std.fmt.allocPrint(a, "{s}\n//# yix-map {s}\n", .{ out, args[1] }) });
}

fn tree(a: std.mem.Allocator, io: std.Io, root: []const u8, check: bool, problems: *usize, count: *usize) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    var twins: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isSource(entry.basename)) {
            try paths.append(a, try std.fs.path.join(a, &.{ root, entry.path }));
        } else if (try compiler.sourceOfTwin(a, entry.basename) != null) {
            try twins.append(a, try std.fs.path.join(a, &.{ root, entry.path }));
        }
    }
    // Traversal order depends on filesystem; sorting stabilizes diagnostics and counts.
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    std.mem.sort([]const u8, twins.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (twins.items) |twin| {
        const source_path = (try compiler.sourceOfTwin(a, twin)).?;
        std.Io.Dir.cwd().access(io, source_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const have = try std.Io.Dir.cwd().readFileAlloc(io, twin, a, .limited(16 * 1024 * 1024));
                if (compiler.twinOutputStart(have) != null) {
                    std.debug.print("orphan: {s} (source {s} is missing; remove the generated file or restore its source)\n", .{ twin, source_path });
                    problems.* += 1;
                }
            },
            else => return err,
        };
    }
    for (paths.items) |input| {
        count.* += 1;
        const twin = try compiler.twinPath(a, input);
        const source = try std.Io.Dir.cwd().readFileAlloc(io, input, a, .limited(8 * 1024 * 1024));
        const out = (try compileOrReport(a, io, input, source, true)) orelse {
            problems.* += 1;
            continue;
        };
        const want = try compiler.twinText(a, input, out);
        const have = std.Io.Dir.cwd().readFileAlloc(io, twin, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        // Hand-written file with same name (no generated header): don't overwrite
        if (have) |h| if (compiler.twinOutputStart(h) == null) {
            std.debug.print("{s}: exists and is not a generated file; rename it (the twin of {s} goes there)\n", .{ twin, input });
            problems.* += 1;
            continue;
        };
        if (have != null and std.mem.eql(u8, have.?, want)) continue;
        if (check) {
            std.debug.print("stale: {s}\n", .{twin});
            problems.* += 1;
        } else try writeAtomic(io, twin, want);
    }
}

/// Write temp file with random name in same dir then rename in place: multiple zig
/// builds (or yix-lsp saves) writing same twin concurrently, readers always see
/// complete file
fn writeAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    var writer = af.file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
    try af.replace(io);
}

fn isSource(name: []const u8) bool {
    for (compiler.source_exts) |ext| if (std.mem.endsWith(u8, name, ext)) return true;
    return false;
}

/// Compile; on error print `path:line:col: error: ...` and return null
fn compileOrReport(a: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, sibling: bool) !?[]const u8 {
    // The single-file translator allows output in another directory. Its source is not
    // available to a basename @embedFile there; retain its established plain output.
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const absolute = try std.fs.path.resolve(a, &.{ cwd, path });
    const stable_path = try std.fs.path.relativeAlloc(a, cwd, null, cwd, absolute);
    if (comptime @import("builtin").os.tag == .windows) for (stable_path) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    };
    const result = if (!sibling and std.mem.endsWith(u8, path, ".yss"))
        try compiler.style.compile(a, source)
    else
        try compiler.compileSource(a, stable_path, source);
    return switch (result) {
        .output => |o| o,
        .diagnostic => |d| {
            const lc = compiler.lineColumn(source, d.offset);
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, lc.line, lc.column, d.message });
            return null;
        },
    };
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

test "双胞胎命名：_ + 源文件名 + .zig，可反查源文件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src/ui/card/_card.yix.zig", try compiler.twinPath(a, "src/ui/card/card.yix"));
    try std.testing.expectEqualStrings("_styles.yss.zig", try compiler.twinPath(a, "styles.yss"));
    try std.testing.expectEqualStrings("src/ui/card/card.yix", (try compiler.sourceOfTwin(a, "src/ui/card/_card.yix.zig")).?);
    try std.testing.expect(try compiler.sourceOfTwin(a, "src/ui/card/mod.zig") == null);
    try std.testing.expect(try compiler.sourceOfTwin(a, "src/ui/_private.zig") == null);
    const text = try compiler.twinText(a, "src/ui/card/card.yix", "pub const x = 1;");
    try std.testing.expectEqualStrings("pub const x = 1;", text[compiler.twinOutputStart(text).? .. compiler.twinOutputStart(text).? + "pub const x = 1;".len]);
}

test "generation gates reject orphan generated twins but preserve handwritten files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "styles.yss", .data = "const ui = @import(\"ui\"); style old { gap: 4; }" });
    var problems: usize = 0;
    var count: usize = 0;
    try tree(a, io, root, false, &problems, &count);
    try std.testing.expectEqual(@as(usize, 0), problems);
    try tmp.dir.deleteFile(io, "styles.yss");
    try tmp.dir.writeFile(io, .{ .sub_path = "_hand.yix.zig", .data = "pub const hand = true;" });
    for ([_]bool{ true, false }) |check| {
        problems = 0;
        count = 0;
        try tree(a, io, root, check, &problems, &count);
        try std.testing.expectEqual(@as(usize, 1), problems);
        try tmp.dir.access(io, "_styles.yss.zig", .{});
        try tmp.dir.access(io, "_hand.yix.zig", .{});
    }
}
