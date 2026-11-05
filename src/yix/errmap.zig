//! Zig compile error -> .yix / .yss source position.
//! `zig build` and editor on-save get errors pointing to generated twin (_card.yix.zig:124:17)
//! or library receiving props (props.zig:33:37: error: ButtonProps: unknown prop ...; twin frame
//! in call stack). Remap both to source:
//! - Position in twin: use source recompile segment table to map generated offset to source offset;
//! - Position elsewhere, twin frame in stack: report same error at first twin frame's source
//!   position
//!   (with original position in message).
//! Twin outdated (doesn't match current source compile): still map, note in message.
const std = @import("std");
const compiler = @import("compiler.zig");
const Allocator = std.mem.Allocator;

pub const Severity = enum { @"error", note };

pub const Diag = struct {
    /// Source file path (same relative / absolute form as in error).
    path: []const u8,
    line: usize,
    column: usize,
    severity: Severity,
    message: []const u8,
};

pub const Loc = struct { path: []const u8, line: usize, column: usize, stale: bool };

/// Error location part: `PATH:LINE:COL`.
const Where = struct { path: []const u8, line: usize, column: usize };

/// Is twin file (_x.yix.zig / _x.yss.zig).
pub fn isTwinPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (base.len < 2 or base[0] != '_') return false;
    return std.mem.endsWith(u8, base, ".yix.zig") or std.mem.endsWith(u8, base, ".yss.zig");
}

/// Map twin line/col to source. Cached by twin path (read file + recompile source once).
pub const Mapper = struct {
    a: Allocator,
    /// Base dir for relative paths (build root).
    dir: std.Io.Dir,
    io: std.Io,
    cache: std.StringHashMapUnmanaged(?Entry) = .empty,

    const Entry = struct {
        source_path: []const u8,
        source: []const u8,
        twin: []const u8,
        output_start: usize,
        segments: []const compiler.Segment,
        stale: bool,
    };

    fn entry(m: *Mapper, twin_path: []const u8) !?Entry {
        if (m.cache.get(twin_path)) |e| return e;
        const e = m.load(twin_path) catch null;
        try m.cache.put(m.a, try m.a.dupe(u8, twin_path), e);
        return e;
    }

    fn load(m: *Mapper, twin_path: []const u8) !?Entry {
        const source_path = (try compiler.sourceOfTwin(m.a, twin_path)) orelse return null;
        const twin = try m.dir.readFileAlloc(m.io, twin_path, m.a, .limited(64 * 1024 * 1024));
        const start = compiler.twinOutputStart(twin) orelse return null;
        const source = try m.dir.readFileAlloc(m.io, source_path, m.a, .limited(16 * 1024 * 1024));
        // Generation stores checkout-relative descriptor paths, independent of whether
        // Zig printed a relative path or an absolute path in this diagnostic.
        const base = try m.dir.realPathFileAlloc(m.io, ".", m.a);
        const absolute = try std.fs.path.resolve(m.a, &.{ base, source_path });
        const stable_path = try std.fs.path.relativeAlloc(m.a, base, null, base, absolute);
        if (comptime @import("builtin").os.tag == .windows) for (stable_path) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        };
        // Legacy off-tree translations remain supported alongside preview twins.
        const preview_twin = std.mem.indexOf(u8, twin, "ui.previewCss(") != null or std.mem.indexOf(u8, twin, "ui.previewCva(") != null;
        const r = if (!preview_twin and std.mem.endsWith(u8, source_path, ".yss"))
            try compiler.style.compileMapped(m.a, source)
        else
            try compiler.compileMappedSource(m.a, stable_path, source);
        switch (r) {
            .diagnostic => return null, // Source file now doesn't compile: no segment table available.
            .mapped => |mp| {
                const want = try compiler.twinText(m.a, std.fs.path.basename(source_path), mp.output);
                return .{ .source_path = source_path, .source = source, .twin = twin, .output_start = start, .segments = mp.segments, .stale = !std.mem.eql(u8, want, twin) };
            },
        }
    }

    /// Twin line/col (1-based) -> source line/col; null if not twin or can't map.
    pub fn locate(m: *Mapper, twin_path: []const u8, line: usize, column: usize) !?Loc {
        if (!isTwinPath(twin_path)) return null;
        const e = (try m.entry(twin_path)) orelse return null;
        const off = offsetOf(e.twin, line, column) orelse return null;
        if (off < e.output_start) return null;
        const src = compiler.genToSrcNearest(e.segments, off - e.output_start);
        const lc = compiler.lineColumn(e.source, src);
        return .{ .path = e.source_path, .line = lc.line, .column = lc.column, .stale = e.stale };
    }
};

fn offsetOf(text: []const u8, line: usize, column: usize) ?usize {
    var l: usize = 1;
    var i: usize = 0;
    while (l < line) : (i += 1) {
        if (i >= text.len) return null;
        if (text[i] == '\n') l += 1;
    }
    const off = i + (column -| 1);
    return if (off <= text.len) off else null;
}

/// `PATH:LINE:COL` followed immediately by `: ` (error head) or line end (call stack).
fn parseWhere(s: []const u8) ?struct { where: Where, rest: []const u8 } {
    // Find leftmost `:number:number` followed by `:` or line end.
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, ':')) |c1| : (i = c1 + 1) {
        const l_end = digitsEnd(s, c1 + 1) orelse continue;
        if (l_end >= s.len or s[l_end] != ':') continue;
        const c_end = digitsEnd(s, l_end + 1) orelse continue;
        if (c_end != s.len and s[c_end] != ':') continue;
        if (c1 == 0) return null;
        const line = std.fmt.parseInt(usize, s[c1 + 1 .. l_end], 10) catch return null;
        const column = std.fmt.parseInt(usize, s[l_end + 1 .. c_end], 10) catch return null;
        return .{ .where = .{ .path = s[0..c1], .line = line, .column = column }, .rest = s[c_end..] };
    }
    return null;
}

fn digitsEnd(s: []const u8, from: usize) ?usize {
    var j = from;
    while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    return if (j > from) j else null;
}

const Header = struct { where: Where, severity: Severity, message: []const u8 };

/// `PATH:L:C: error: msg` / `PATH:L:C: note: msg` (no indent at line start).
fn parseHeader(line: []const u8) ?Header {
    if (line.len == 0 or line[0] == ' ') return null;
    const p = parseWhere(line) orelse return null;
    inline for (.{ .{ ": error: ", Severity.@"error" }, .{ ": note: ", Severity.note } }) |k| {
        if (std.mem.startsWith(u8, p.rest, k[0])) return .{ .where = p.where, .severity = k[1], .message = p.rest[k[0].len..] };
    }
    return null;
}

/// Call-stack line: `    name: PATH:L:C`.
const Reference = struct { name: []const u8, where: Where };
fn parseReference(line: []const u8) ?Reference {
    if (line.len == 0 or line[0] != ' ') return null;
    const t = std.mem.trimStart(u8, line, " ");
    const sep = std.mem.indexOf(u8, t, ": ") orelse return null;
    const p = parseWhere(t[sep + 2 ..]) orelse return null;
    if (p.rest.len != 0) return null;
    return .{ .name = t[0..sep], .where = p.where };
}

fn staleNote(stale: bool) []const u8 {
    return if (stale) " (the generated file is out of date; run `zig build gen-yix`)" else "";
}

/// Call block for error not in twin: scan full block then pick source position--prefer
/// component-body frame (`__yix_ComponentName`; template here; call site with prop typo /
/// type mismatch), else first twin frame (wrapper func `Name__anon_...` is boilerplate).
const Pending = struct {
    header: Header,
    first: ?Loc = null,
    body: ?Loc = null,
    fn note(p: *Pending, m: *Mapper, r: Reference) !bool {
        const loc = (try m.locate(r.where.path, r.where.line, r.where.column)) orelse return false;
        if (p.first == null) p.first = loc;
        if (p.body == null and std.mem.startsWith(u8, r.name, "__yix_")) p.body = loc;
        return true;
    }
    fn pick(p: Pending) ?Loc {
        return p.body orelse p.first;
    }
};

fn isReferenceBlockLine(line: []const u8) bool {
    if (parseReference(line) != null) return true;
    if (std.mem.eql(u8, line, "referenced by:")) return true;
    const t = std.mem.trim(u8, line, " ");
    return std.mem.indexOf(u8, t, "reference(s) hidden") != null;
}

/// Parse Zig error segment; get diagnostics landing on .yix / .yss source files.
pub fn collect(m: *Mapper, text: []const u8) ![]Diag {
    var out: std.ArrayList(Diag) = .empty;
    var pending: ?Pending = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (true) {
        const raw = it.next();
        const line = if (raw) |r| std.mem.trimEnd(u8, r, "\r") else "";
        if (pending) |*p| {
            if (raw != null and isReferenceBlockLine(line)) {
                if (parseReference(line)) |r| _ = try p.note(m, r);
                continue;
            }
            // Following note in twin (comptime-eval 'called at comptime here', e.g. token typo in
            // .yss):
            // it's this error's source position.
            if (raw != null) if (parseHeader(line)) |h| if (h.severity == .note) {
                if (try m.locate(h.where.path, h.where.line, h.where.column)) |loc| {
                    if (p.body == null) p.body = loc;
                    continue;
                }
            };
            // Call block end (or code excerpt between error head and block): settle only if block
            // appeared.
            if (p.first != null or (raw == null or parseHeader(line) != null)) {
                if (p.pick()) |loc| try out.append(m.a, .{
                    .path = loc.path,
                    .line = loc.line,
                    .column = loc.column,
                    .severity = .@"error",
                    .message = try std.fmt.allocPrint(m.a, "{s} (reported at {s}:{d}:{d}){s}", .{ p.header.message, p.header.where.path, p.header.where.line, p.header.where.column, staleNote(loc.stale) }),
                });
                pending = null;
            }
        }
        if (raw == null) break;
        if (parseHeader(line)) |h| {
            if (try m.locate(h.where.path, h.where.line, h.where.column)) |loc| {
                try out.append(m.a, .{ .path = loc.path, .line = loc.line, .column = loc.column, .severity = h.severity, .message = try std.fmt.allocPrint(m.a, "{s}{s}", .{ h.message, staleNote(loc.stale) }) });
            } else if (h.severity == .@"error") pending = .{ .header = h };
        }
    }
    return out.items;
}

/// CLI filter: swap twin position to source in error head (original in line end); error with
/// position elsewhere, append note line of source position after call block. Rest as-is.
pub fn rewrite(m: *Mapper, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending: ?Pending = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (true) {
        const raw = it.next();
        const line = if (raw) |r| std.mem.trimEnd(u8, r, "\r") else "";
        if (pending) |*p| {
            const twin_note: ?Loc = if (raw != null) if (parseHeader(line)) |h| if (h.severity == .note) try m.locate(h.where.path, h.where.line, h.where.column) else null else null else null;
            if (raw != null and isReferenceBlockLine(line)) {
                if (parseReference(line)) |r| _ = try p.note(m, r);
            } else if (twin_note) |loc| {
                // See collect: note in twin is this error's source position (normal map and
                // output).
                if (p.body == null) p.body = loc;
            } else if (p.first != null or (raw == null or parseHeader(line) != null)) {
                if (p.pick()) |loc| try out.appendSlice(m.a, try std.fmt.allocPrint(m.a, "\n{s}:{d}:{d}: note: Yix source of the error above ({s}){s}", .{ loc.path, loc.line, loc.column, p.header.message, staleNote(loc.stale) }));
                pending = null;
            }
        }
        if (raw == null) break;
        if (!first) try out.append(m.a, '\n');
        first = false;
        if (parseHeader(line)) |h| {
            if (try m.locate(h.where.path, h.where.line, h.where.column)) |loc| {
                try out.appendSlice(m.a, try std.fmt.allocPrint(m.a, "{s}:{d}:{d}: {s}: {s} [generated: {s}:{d}:{d}]{s}", .{ loc.path, loc.line, loc.column, @tagName(h.severity), h.message, h.where.path, h.where.line, h.where.column, staleNote(loc.stale) }));
                continue;
            }
            if (h.severity == .@"error") pending = .{ .header = h };
        }
        try out.appendSlice(m.a, raw.?);
    }
    return out.items;
}
