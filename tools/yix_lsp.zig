//! .yix and .yss language server (proxy).
//!
//! Each open .yix file is compiled to a virtual Zig doc (same dir, `<file>.yix.zig`,
//! memory-only, didOpen/didChange to a ZLS subprocess). Zig features (hover/completion/
//! goto/refs/highlight/sig) are forwarded to ZLS: request positions are mapped from .yix to
//! the virtual doc via the compiler segment table (compileMapped), results mapped back.
//! Diagnostics = Yix compile + ZLS on the virtual doc (mapped back).
//!
//! Each .yix / .yss pairs with a generated sibling `_<name>.zig` (card.yix -> _card.yix.zig)
//! in the repo; hand-written code imports it. The virtual doc uses the sibling's real path
//! (content = current compile output), so it is in the build graph and `@import("ui")` resolves.
//! On save the sibling is written to disk (importers see it via ZLS disk read); ZLS results
//! on the sibling map back to source.
//!
//! .yss (style recipe) DSL parts (props/tokens/conditions/mixins/variants) completion/hover/
//! goto/outline are answered by the proxy via compiler outline + schema (reflected from ui
//! style types); Zig + `{zig}` values are forwarded to ZLS.
//!
//! Positions are UTF-16 per LSP default. ZLS path: `--zls <path>`, env YIX_ZLS, sibling `zenit-zls`, else PATH `zls`.
//! Design: docs/YIX_EDITOR.md.
const std = @import("std");
const compiler = @import("yix_compiler");
const json = std.json;
const Allocator = std.mem.Allocator;
/// YIX_LSP_DEBUG=1: echo ZLS message digest to stderr
var debug = false;

// JSON-RPC framing (Content-Length)

const Framer = struct {
    file: std.Io.File,
    io: std.Io,
    buf: std.ArrayList(u8) = .empty,

    /// Read one complete message body (owned by gpa); EOF return null.
    fn next(self: *Framer, gpa: Allocator) !?[]u8 {
        while (true) {
            if (std.mem.indexOf(u8, self.buf.items, "\r\n\r\n")) |header_end| {
                const headers = self.buf.items[0..header_end];
                var len: ?usize = null;
                var it = std.mem.splitSequence(u8, headers, "\r\n");
                while (it.next()) |line| {
                    if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                        len = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \t"), 10) catch null;
                    }
                }
                const body_len = len orelse return error.MissingContentLength;
                const total = header_end + 4 + body_len;
                while (self.buf.items.len < total) if (!try self.fill(gpa)) return null;
                const body = try gpa.dupe(u8, self.buf.items[header_end + 4 .. total]);
                const rest = self.buf.items.len - total;
                std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[total..]);
                self.buf.shrinkRetainingCapacity(rest);
                return body;
            }
            if (!try self.fill(gpa)) return null;
        }
    }

    fn fill(self: *Framer, gpa: Allocator) !bool {
        var tmp: [64 * 1024]u8 = undefined;
        const n = self.file.readStreaming(self.io, &.{&tmp}) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        if (n == 0) return false;
        try self.buf.appendSlice(gpa, tmp[0..n]);
        return true;
    }
};

fn sendRaw(io: std.Io, file: std.Io.File, mutex: *std.Io.Mutex, body: []const u8) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    writeFrame(io, file, body);
}

fn writeFrame(io: std.Io, file: std.Io.File, body: []const u8) void {
    var header: [64]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    file.writeStreamingAll(io, h) catch return;
    file.writeStreamingAll(io, body) catch return;
}

// Position conversion (UTF-16 line/column <-> byte offset)

const Pos = struct { line: usize, character: usize };

fn offsetOf(text: []const u8, pos: Pos) usize {
    var line: usize = 0;
    var i: usize = 0;
    while (line < pos.line and i < text.len) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    var units: usize = 0;
    while (i < text.len and text[i] != '\n' and units < pos.character) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        units += if (n == 4) 2 else 1;
        i += @min(n, text.len - i);
    }
    return i;
}

/// 1-indexed line, byte column (Zig error style) -> byte offset
fn byteOffset(text: []const u8, line: usize, column: usize) usize {
    var l: usize = 1;
    var i: usize = 0;
    while (l < line and i < text.len) : (i += 1) {
        if (text[i] == '\n') l += 1;
    }
    return @min(i + (column -| 1), text.len);
}

fn posOf(text: []const u8, offset: usize) Pos {
    var line: usize = 0;
    var line_start: usize = 0;
    const end = @min(offset, text.len);
    for (text[0..end], 0..) |c, i| if (c == '\n') {
        line += 1;
        line_start = i + 1;
    };
    var units: usize = 0;
    var i = line_start;
    while (i < end) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return .{ .line = line, .character = units };
}

// Segment table mapping

const srcToGen = compiler.srcToGen;
const genToSrc = compiler.genToSrc;
const genToSrcNearest = compiler.genToSrcNearest;

// Documents

const Doc = struct {
    uri: []u8,
    virtual_uri: []u8,
    text: []u8,
    /// Monotonic across close/reopen and failed compiles, unlike virtual_version.
    revision: u64 = 0,
    /// Latest successful compile result + source text (compile fail suspends requests, diagnostics
    /// continue)
    mapped: ?compiler.Mapped = null,
    mapped_text: ?[]u8 = null,
    virtual_version: i64 = 0,
    virtual_open: bool = false,
    /// mapped text is "repair string inserted after cursor" (compile fail does temp repair, see
    /// repairAt)
    repair: ?Repair = null,
    yix_diag: ?compiler.Diagnostic = null,
    /// ZLS's latest diagnostic on virtual (already mapped back to .yix JSON snippet)
    zls_diags: []u8 = &.{},

    fn deinit(d: *Doc, gpa: Allocator) void {
        // .yss diagnostics stay with this doc (compiler allocates per caller); check uri before
        // freeing
        if (d.yix_diag) |x| gpa.free(x.message);
        gpa.free(d.uri);
        gpa.free(d.virtual_uri);
        gpa.free(d.text);
        if (d.mapped) |m| m.deinit(gpa);
        if (d.mapped_text) |t| gpa.free(t);
        gpa.free(d.zls_diags);
    }

    /// mapBack only when current text == successful-compile text (repair compile only services that
    /// request)
    fn current(d: *const Doc) ?compiler.Mapped {
        const m = d.mapped orelse return null;
        if (d.repair != null or !std.mem.eql(u8, d.mapped_text.?, d.text)) return null;
        return m;
    }

    /// Current text mapping, allow cursor repair for that text
    fn forRequest(d: *const Doc) ?compiler.Mapped {
        const m = d.mapped orelse return null;
        const t = d.mapped_text.?;
        if (d.repair) |r| {
            if (t.len != d.text.len + r.inserted.len) return null;
            if (!std.mem.eql(u8, t[0..r.cursor], d.text[0..r.cursor])) return null;
            if (!std.mem.eql(u8, t[r.cursor + r.inserted.len ..], d.text[r.cursor..])) return null;
            return m;
        }
        return if (std.mem.eql(u8, t, d.text)) m else null;
    }

    /// Source offset <-> current text offset (repair string after cursor; position after shifts)
    fn toMappedSrc(d: *const Doc, off: usize) usize {
        const r = d.repair orelse return off;
        return if (off > r.cursor) off + r.inserted.len else off;
    }
    fn fromMappedSrc(d: *const Doc, off: usize) usize {
        const r = d.repair orelse return off;
        if (off <= r.cursor) return off;
        if (off < r.cursor + r.inserted.len) return r.cursor;
        return off - r.inserted.len;
    }
};

const Repair = struct { cursor: usize, inserted: []const u8 };

/// During input .yix often incomplete (`style={S.`): after cursor try these closures in order,
/// first
/// compiling used to service this request.
const repairs = [_][]const u8{ "}", ")}", "\"}", "})", "/>", "}/>", "} />", "}}", ")", "\"", ";" };

/// ZLS message queue: read thread push, process thread pop; close on read end
const Inbox = struct {
    io: std.Io,
    gpa: Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: std.ArrayList([]u8) = .empty,
    head: usize = 0,
    closed: bool = false,

    fn push(q: *Inbox, body: []u8) void {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        q.items.append(q.gpa, body) catch {
            std.log.err("yix-lsp: out of memory queueing a ZLS message; dropped", .{});
            q.gpa.free(body);
            return;
        };
        q.cond.signal(q.io);
    }
    fn close(q: *Inbox) void {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        q.closed = true;
        q.cond.signal(q.io);
    }
    fn pop(q: *Inbox) ?[]u8 {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        while (q.head == q.items.items.len and !q.closed) q.cond.waitUncancelable(q.io, &q.mutex);
        if (q.head == q.items.items.len) return null;
        const body = q.items.items[q.head];
        q.head += 1;
        if (q.head == q.items.items.len) {
            q.items.clearRetainingCapacity();
            q.head = 0;
        }
        return body;
    }
    fn deinit(q: *Inbox) void {
        for (q.items.items[q.head..]) |b| q.gpa.free(b);
        q.items.deinit(q.gpa);
    }
};

const Pending = struct {
    /// Request id from editor (JSON text), null = proxy-originated (initialize etc)
    editor_id: ?[]u8,
    method: []const u8,
    doc_uri: ?[]u8,
    revision: u64 = 0,
    virtual_version: i64 = 0,
    /// Prop completion: proxy asks ZLS for component def, parse props for editor
    props_lookup: ?PropsLookup = null,
};

const PropsLookup = struct { prefix: []u8, present: []u8 };

// Template context: tag name / attribute name completion

const TagContext = union(enum) {
    /// Cursor after `<` in tag
    tag_name: []const u8,
    /// Cursor in open-tag prop area: tag name, prop prefix written, tag offset in source,
    /// props written (comma-delim)
    attribute: struct { tag: []const u8, tag_at: usize, prefix: []const u8, present: []const u8 },
};

/// Scan cursor back: inside open tag (not in braces / string) gives context
fn tagContext(a: Allocator, text: []const u8, cursor: usize) !?TagContext {
    var prefix_start = cursor;
    while (prefix_start > 0 and (std.ascii.isAlphanumeric(text[prefix_start - 1]) or text[prefix_start - 1] == '_' or text[prefix_start - 1] == '.')) prefix_start -= 1;
    const prefix = text[prefix_start..cursor];
    if (prefix_start > 0 and text[prefix_start - 1] == '<') return .{ .tag_name = prefix };
    var i = prefix_start;
    var depth: usize = 0;
    var present: std.ArrayList(u8) = .empty;
    while (i > 0) {
        i -= 1;
        const c = text[i];
        switch (c) {
            '}' => depth += 1,
            '{' => {
                if (depth == 0) return null; // Inside braces: Zig fragment
                depth -= 1;
            },
            '"' => if (depth == 0) {
                // Skip attr string value
                while (i > 0) {
                    i -= 1;
                    if (text[i] == '"' and (i == 0 or text[i - 1] != '\\')) break;
                }
            },
            '>' => if (depth == 0) return null,
            '<' => if (depth == 0) {
                var e = i + 1;
                while (e < text.len and (std.ascii.isAlphanumeric(text[e]) or text[e] == '_' or text[e] == '.')) e += 1;
                if (e == i + 1) return null;
                // Prop name before must be whitespace (not writing attr value)
                if (prefix_start == 0 or !std.ascii.isWhitespace(text[prefix_start - 1])) return null;
                return .{ .attribute = .{ .tag = text[i + 1 .. e], .tag_at = i + 1, .prefix = prefix, .present = present.items } };
            },
            '=' => if (depth == 0) {
                // `name=`: record prop written
                var b = i;
                while (b > 0 and (std.ascii.isAlphanumeric(text[b - 1]) or text[b - 1] == '_')) b -= 1;
                try present.appendSlice(a, text[b..i]);
                try present.append(a, ',');
            },
            else => {},
        }
    }
    return null;
}

const host_tags = compiler.host_tags;
fn camel(a: Allocator, snake: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var up = false;
    for (snake) |c| {
        if (c == '_') {
            up = true;
            continue;
        }
        try out.append(a, if (up) std.ascii.toUpper(c) else c);
        up = false;
    }
    return out.items;
}

fn completionItem(a: Allocator, label: []const u8, kind: i64, detail: []const u8, doc: []const u8) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(a, "label", .{ .string = label });
    try o.put(a, "kind", .{ .integer = kind });
    if (detail.len != 0) try o.put(a, "detail", .{ .string = detail });
    if (doc.len != 0) try o.put(a, "documentation", .{ .string = doc });
    return .{ .object = o };
}

/// Parse Zig source `<name>Props = struct { ... }` fields: (name, type text, doc comment)
fn propsFields(a: Allocator, source: []const u8, props_name: []const u8) !std.ArrayList(json.Value) {
    var items: std.ArrayList(json.Value) = .empty;
    const z = try a.dupeSentinel(u8, source, 0);
    var ast = try std.zig.Ast.parse(a, z, .{});
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    for (ast.rootDecls()) |decl| {
        const var_decl = ast.fullVarDecl(decl) orelse continue;
        const name_tok = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, ast.tokenSlice(name_tok), props_name)) continue;
        const init = var_decl.ast.init_node.unwrap() orelse continue;
        const container = ast.fullContainerDecl(&buf, init) orelse continue;
        for (container.ast.members) |member| {
            const field = ast.fullContainerField(member) orelse continue;
            const fname = ast.tokenSlice(field.ast.main_token);
            const type_node = field.ast.type_expr.unwrap() orelse continue;
            const ty = ast.getNodeSource(type_node);
            // /// comment before field
            var doc: std.ArrayList(u8) = .empty;
            var t = ast.firstToken(member);
            while (t > 0 and ast.tokenTag(t - 1) == .doc_comment) t -= 1;
            while (ast.tokenTag(t) == .doc_comment) : (t += 1) {
                if (doc.items.len != 0) try doc.append(a, '\n');
                try doc.appendSlice(a, std.mem.trimStart(u8, ast.tokenSlice(t)[3..], " "));
            }
            try items.append(a, try completionItem(a, try camel(a, fname), 5, ty, doc.items));
        }
        break;
    }
    return items;
}

const Server = struct {
    io: std.Io,
    gpa: Allocator,
    mutex: std.Io.Mutex = .init,
    out_mutex: std.Io.Mutex = .init,
    zls_mutex: std.Io.Mutex = .init,
    stdout: std.Io.File,
    zls_in: std.Io.File,
    docs: std.StringHashMapUnmanaged(*Doc) = .empty,
    pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
    /// Parsed design systems (theme.json path -> token table), invalid by file mtime
    themes: std.StringHashMapUnmanaged(*ThemeTable) = .empty,
    next_id: i64 = 1_000_000,
    next_revision: u64 = 1,
    shutting_down: bool = false,
    exit_requested: bool = false,
    /// ZLS output unreadable (process exit or protocol corrupt): later writes silently dropped;
    /// can't block on full pipe.
    zls_dead: std.atomic.Value(bool) = .init(false),
    /// Build on save: Zig type errors (ZLS skips comptime semantic check) mapped to .yix/.yss.
    /// All fields read-write under mutex.
    build: Build = .{},

    const Build = struct {
        /// Workspace root (build runs here, diagnostics relative to it)
        root: ?[]u8 = null,
        /// Build command; null = off
        argv: ?[]const []const u8 = null,
        thread: ?std.Thread = null,
        running: bool = false,
        /// Saved again during build: rerun after this round
        rerun: bool = false,
        child_pid: ?std.process.Child.Id = null,
        /// File URI -> build diagnostic (JSON snippet, comma-delim)
        diags: std.StringHashMapUnmanaged([]u8) = .empty,

        fn deinit(b: *Build, gpa: Allocator) void {
            Server.freeDiagMap(gpa, &b.diags);
            if (b.argv) |argv| {
                for (argv) |x| gpa.free(x);
                gpa.free(argv);
            }
            if (b.root) |r| gpa.free(r);
        }
    };

    fn toEditor(s: *Server, body: []const u8) void {
        sendRaw(s.io, s.stdout, &s.out_mutex, body);
    }
    fn toZls(s: *Server, body: []const u8) void {
        // Disconnect check + write under same lock: shutdown closes ZLS stdin holding lock,
        // won't write to closed (or reused) fd.
        s.zls_mutex.lockUncancelable(s.io);
        defer s.zls_mutex.unlock(s.io);
        if (s.zls_dead.load(.acquire)) return;
        writeFrame(s.io, s.zls_in, body);
    }

    fn docByVirtual(s: *Server, uri: []const u8) ?*Doc {
        var it = s.docs.valueIterator();
        while (it.next()) |d| if (std.mem.eql(u8, d.*.virtual_uri, uri)) return d.*;
        return null;
    }

    // ---------------- Editor -> Proxy ----------------

    fn fromEditor(s: *Server, body: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const msg = try json.parseFromSliceLeaky(json.Value, a, body, .{});
        if (msg != .object) return;
        const method = if (msg.object.get("method")) |m| m.string else {
            // Editor response to proxy-forwarded server request: proxy answered ZLS, ignore
            return;
        };
        const id = msg.object.get("id");
        const params = msg.object.get("params") orelse json.Value{ .null = {} };

        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);

        if (std.mem.eql(u8, method, "initialize")) {
            s.configureBuild(a, params) catch |err| std.log.warn("yix-lsp: build-on-save disabled: {s}", .{@errorName(err)});
            return s.forwardRequest(a, msg, null, "initialize");
        }
        if (std.mem.eql(u8, method, "shutdown")) {
            s.shutting_down = true;
            return s.forwardRequest(a, msg, null, "shutdown");
        }
        if (std.mem.eql(u8, method, "textDocument/didOpen")) return s.didOpen(a, params);
        if (std.mem.eql(u8, method, "textDocument/didChange")) return s.didChange(a, params);
        if (std.mem.eql(u8, method, "textDocument/didClose")) return s.didClose(a, params);
        if (std.mem.eql(u8, method, "textDocument/didSave")) return s.didSave(a, params);
        if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            const req_id = id orelse return;
            const uri = params.object.get("textDocument").?.object.get("uri").?.string;
            const doc = s.docs.get(uri) orelse return s.reply(a, req_id, .{ .null = {} });
            return s.reply(a, req_id, if (isYss(uri)) try yssSymbols(a, doc.text) else .{ .null = {} });
        }
        if (std.mem.eql(u8, method, "exit")) s.exit_requested = true;
        if (isPositional(method)) return s.positional(a, msg, method, params);
        if (id) |_| {
            // Unproxied request: return null, don't let editor hang
            return s.reply(a, id.?, .{ .null = {} });
        }
        // Other notifications (initialized / exit / $/cancelRequest ...): pass to ZLS
        s.toZls(body);
    }

    fn isPositional(method: []const u8) bool {
        const list = [_][]const u8{ "textDocument/hover", "textDocument/completion", "textDocument/definition", "textDocument/declaration", "textDocument/typeDefinition", "textDocument/implementation", "textDocument/references", "textDocument/documentHighlight", "textDocument/signatureHelp" };
        for (list) |m| if (std.mem.eql(u8, m, method)) return true;
        return false;
    }

    fn reply(s: *Server, a: Allocator, id: json.Value, result: json.Value) !void {
        var obj: json.ObjectMap = .empty;
        try obj.put(a, "jsonrpc", .{ .string = "2.0" });
        try obj.put(a, "id", id);
        try obj.put(a, "result", result);
        s.toEditor(try json.Stringify.valueAlloc(a, json.Value{ .object = obj }, .{}));
    }

    fn forwardRequest(s: *Server, a: Allocator, msg: json.Value, doc_uri: ?[]const u8, method: []const u8) !void {
        // No ZLS (missing / fail / disconnect): degrade—proxy answers initialize, other requests
        // return
        // null; don't hang editor.
        if (s.zls_dead.load(.acquire)) {
            const id = msg.object.get("id") orelse return;
            if (std.mem.eql(u8, method, "initialize")) return s.reply(a, id, try degradedInitialize(a));
            return s.reply(a, id, .{ .null = {} });
        }
        var m = msg;
        const our = s.next_id;
        s.next_id += 1;
        const editor_id = if (msg.object.get("id")) |id| try s.gpa.dupe(u8, try json.Stringify.valueAlloc(a, id, .{})) else null;
        try s.pending.put(s.gpa, our, .{
            .editor_id = editor_id,
            .method = method,
            .doc_uri = if (doc_uri) |u| try s.gpa.dupe(u8, u) else null,
            .revision = if (doc_uri) |u| s.docs.get(u).?.revision else 0,
            .virtual_version = if (doc_uri) |u| s.docs.get(u).?.virtual_version else 0,
        });
        try m.object.put(a, "id", .{ .integer = our });
        s.toZls(try json.Stringify.valueAlloc(a, m, .{}));
    }

    fn didOpen(s: *Server, a: Allocator, params: json.Value) !void {
        const td = params.object.get("textDocument").?.object;
        const uri = td.get("uri").?.string;
        const text = td.get("text").?.string;
        const doc = try s.gpa.create(Doc);
        errdefer s.gpa.destroy(doc);
        doc.* = .{ .uri = try s.gpa.dupe(u8, uri), .virtual_uri = &.{}, .text = &.{} };
        errdefer s.gpa.free(doc.uri);
        // .yix / .yss: virtual is disk sibling (not file URI fallback to `<uri>.zig`); else
        // pass-through
        doc.virtual_uri = if (!isYixFamily(uri))
            try s.gpa.dupe(u8, uri)
        else if (try uriToPath(a, uri)) |path|
            try s.gpa.dupe(u8, try pathToUri(a, try compiler.twinPath(a, path)))
        else
            try std.fmt.allocPrint(s.gpa, "{s}.zig", .{uri});
        doc.text = try s.gpa.dupe(u8, text);
        doc.revision = s.next_revision;
        s.next_revision += 1;
        if (s.docs.fetchRemove(uri)) |old| {
            old.value.deinit(s.gpa);
            s.gpa.destroy(old.value);
        }
        try s.docs.put(s.gpa, doc.uri, doc);
        try s.recompile(a, doc);
    }

    fn didChange(s: *Server, a: Allocator, params: json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const doc = s.docs.get(uri) orelse return;
        const changes = params.object.get("contentChanges").?.array.items;
        if (changes.len == 0) return;
        // Full sync only declared: last is whole text
        const text = changes[changes.len - 1].object.get("text").?.string;
        s.gpa.free(doc.text);
        doc.text = try s.gpa.dupe(u8, text);
        doc.revision = s.next_revision;
        s.next_revision += 1;
        // Last build error for save-time text; changed -> unreliable: recompile next save
        if (s.build.diags.fetchRemove(uri)) |kv| {
            s.gpa.free(kv.key);
            s.gpa.free(kv.value);
        }
        try s.recompile(a, doc);
    }

    /// Save: compile pass writes sibling to disk (no change no write; temp then rename,
    /// build always reads complete)
    fn didSave(s: *Server, a: Allocator, params: json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const doc = s.docs.get(uri) orelse return;
        if (!isYixFamily(uri)) return;
        try writeTwin(s.io, a, uri, doc);
        s.scheduleBuild();
    }

    fn writeTwin(io: std.Io, a: Allocator, uri: []const u8, doc: *Doc) !void {
        const path = (try uriToPath(a, uri)) orelse return;
        const m = doc.current() orelse return; // Current text compile fails: don't touch disk sibling
        const twin = try compiler.twinPath(a, path);
        const want = try compiler.twinText(a, std.fs.path.basename(path), m.output);
        if (std.Io.Dir.cwd().readFileAlloc(io, twin, a, .limited(64 * 1024 * 1024))) |have| {
            if (std.mem.eql(u8, have, want)) return;
            // Hand-written file (no generated header): don't overwrite
            if (compiler.twinOutputStart(have) == null) return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            // Can't read (perms, too big...): can't tell hand-written, don't write
            else => return std.log.warn("yix-lsp: reading {s} failed ({s}); not rewriting it", .{ twin, @errorName(err) }),
        }
        writeAtomic(io, twin, want) catch |err| std.log.warn("yix-lsp: writing {s} failed: {s}", .{ twin, @errorName(err) });
    }

    // ---------------- Build on save ----------------

    /// initialize: workspace root + build command. Command from
    /// initializationOptions.buildOnSave (string array, empty = off), else env YIX_BUILD_ON_SAVE
    /// (space-sep; `off` = off), else workspace has build.zig run `zig build`.
    fn configureBuild(s: *Server, a: Allocator, params: json.Value) !void {
        if (params != .object) return;
        const root: ?[]const u8 = blk: {
            if (params.object.get("rootUri")) |u| if (u == .string) break :blk try uriToPath(a, u.string);
            if (params.object.get("rootPath")) |r| if (r == .string) break :blk r.string;
            break :blk null;
        };
        const dir = root orelse return;
        var argv: std.ArrayList([]const u8) = .empty;
        var configured = false;
        if (params.object.get("initializationOptions")) |o| if (o == .object) if (o.object.get("buildOnSave")) |b| if (b == .array) {
            configured = true;
            for (b.array.items) |x| if (x == .string) try argv.append(a, x.string);
        };
        if (!configured) if (@import("zenit_environment").getOwned(a, "YIX_BUILD_ON_SAVE")) |v| {
            configured = true;
            if (!std.mem.eql(u8, std.mem.trim(u8, v, " "), "off")) {
                var it = std.mem.tokenizeScalar(u8, v, ' ');
                while (it.next()) |x| try argv.append(a, x);
            }
        } else |_| {};
        if (!configured) {
            const has_build = blk: {
                var d = std.Io.Dir.cwd().openDir(s.io, dir, .{}) catch break :blk false;
                defer d.close(s.io);
                d.access(s.io, "build.zig", .{}) catch break :blk false;
                break :blk true;
            };
            if (has_build) try argv.appendSlice(a, &.{ "zig", "build" });
        }
        s.build.root = try s.gpa.dupe(u8, dir);
        if (argv.items.len == 0) return;
        const owned = try s.gpa.alloc([]const u8, argv.items.len);
        for (argv.items, 0..) |x, i| owned[i] = try s.gpa.dupe(u8, x);
        s.build.argv = owned;
    }

    /// Call with mutex held. The build runs on a separate thread; if one is already running, only
    /// record that another run is needed once it finishes.
    fn scheduleBuild(s: *Server) void {
        if (s.build.argv == null or s.build.root == null or s.shutting_down) return;
        if (s.build.running) {
            s.build.rerun = true;
            return;
        }
        // Prior thread done (running false), reap then start
        if (s.build.thread) |t| t.join();
        s.build.thread = null;
        s.build.running = true;
        s.build.thread = std.Thread.spawn(.{}, buildLoop, .{s}) catch |err| {
            std.log.warn("yix-lsp: starting the build failed: {s}", .{@errorName(err)});
            s.build.running = false;
            return;
        };
    }

    fn buildLoop(s: *Server) void {
        while (true) {
            const out = s.runBuild() catch |err| blk: {
                std.log.warn("yix-lsp: build-on-save failed to run: {s}", .{@errorName(err)});
                break :blk null;
            };
            s.mutex.lockUncancelable(s.io);
            if (out) |text| {
                // Killed during shutdown, output incomplete: don't publish
                if (!s.shutting_down) s.applyBuild(text) catch |err| std.log.warn("yix-lsp: mapping build errors failed: {s}", .{@errorName(err)});
                s.gpa.free(text);
            }
            if (!s.build.rerun or s.shutting_down) {
                s.build.running = false;
                s.mutex.unlock(s.io);
                return;
            }
            s.build.rerun = false;
            s.mutex.unlock(s.io);
        }
    }

    /// Run one build, return its stderr (Zig errors all here)
    fn runBuild(s: *Server) ![]u8 {
        // argv / root unchanged after initialize; safe to read without lock
        var child: std.process.Child = undefined;
        {
            // Spawn and publish the pid under one lock so shutdown cannot miss a build.
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            if (s.shutting_down) return error.ShuttingDown;
            child = try std.process.spawn(s.io, .{
                .argv = s.build.argv.?,
                .cwd = .{ .path = s.build.root.? },
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .pipe,
            });
            s.build.child_pid = child.id;
        }
        // Unpublish before reaping, while the pid still cannot be reused.
        defer child.kill(s.io);
        defer {
            s.mutex.lockUncancelable(s.io);
            s.build.child_pid = null;
            s.mutex.unlock(s.io);
        }
        defer {
            if (child.stdout) |file| file.close(s.io);
            if (child.stderr) |file| file.close(s.io);
            child.stdout = null;
            child.stderr = null;
        }
        var buffers: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(s.gpa, s.io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        while (reader.fill(4096, .none)) |_| {
            if (reader.reader(0).buffered().len > 64 * 1024 * 1024 or
                reader.reader(1).buffered().len > 64 * 1024 * 1024) return error.StreamTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        try reader.checkAnyError();
        // Pipe EOF does not mean the child has exited. Keep its pid published
        // while waiting, and serialize nonblocking reap with shutdown's kill.
        while (true) {
            s.mutex.lockUncancelable(s.io);
            const pid = child.id.?;
            var status: c_int = undefined;
            const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
            const err = std.posix.errno(result);
            const reaped = result == pid;
            if (reaped or err == .CHILD) {
                // A reaped pid can be reused immediately; clear both identities
                // before releasing the lock that stopBuild uses to signal it.
                s.build.child_pid = null;
                child.id = null;
            }
            s.mutex.unlock(s.io);
            switch (err) {
                .SUCCESS => {},
                .INTR => continue,
                .CHILD => return error.ChildNotWaitable,
                else => return error.WaitFailed,
            }
            if (reaped) break;
            try std.Io.sleep(s.io, .fromMilliseconds(5), .awake);
        }
        return reader.toOwnedSlice(1);
    }

    /// Hold mutex: swap new build diagnostics, publish changed files (new + prior had, now don't)
    fn applyBuild(s: *Server, text: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const root = s.build.root.?;
        var dir = try std.Io.Dir.cwd().openDir(s.io, root, .{});
        defer dir.close(s.io);
        var mapper: compiler.errmap.Mapper = .{ .a = a, .dir = dir, .io = s.io };
        const ds = try compiler.errmap.collect(&mapper, text);
        var fresh: std.StringHashMapUnmanaged(std.ArrayList(u8)) = .empty;
        for (ds) |d| {
            const abs = if (std.fs.path.isAbsolute(d.path)) d.path else try std.fs.path.join(a, &.{ root, d.path });
            const uri = try pathToUri(a, abs);
            const file_text = dir.readFileAlloc(s.io, abs, a, .limited(16 * 1024 * 1024)) catch continue;
            const off = byteOffset(file_text, d.line, d.column);
            const p = posOf(file_text, off);
            const e = posOf(file_text, @min(off + 1, file_text.len));
            const gop = try fresh.getOrPut(a, uri);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            if (gop.value_ptr.items.len != 0) try gop.value_ptr.append(a, ',');
            try gop.value_ptr.appendSlice(a, try std.fmt.allocPrint(a, "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":\"zig build\",\"message\":{f}}}", .{ p.line, p.character, e.line, e.character, @as(u8, if (d.severity == .@"error") 1 else 3), json.fmt(d.message, .{}) }));
        }
        // Files to publish: this time + had prior, don't now (empty)
        var touched: std.ArrayList([]const u8) = .empty;
        var old = s.build.diags.iterator();
        while (old.next()) |kv| if (!fresh.contains(kv.key_ptr.*)) try touched.append(a, try a.dupe(u8, kv.key_ptr.*));
        var fit = fresh.iterator();
        while (fit.next()) |kv| try touched.append(a, kv.key_ptr.*);
        // Build new table complete before swap: OOM keeps old (no half-new-half-old, no free
        // of table-owned keys)
        const next = blk: {
            var m: std.StringHashMapUnmanaged([]u8) = .empty;
            errdefer freeDiagMap(s.gpa, &m);
            var nit = fresh.iterator();
            while (nit.next()) |kv| {
                try m.ensureUnusedCapacity(s.gpa, 1);
                const key = try s.gpa.dupe(u8, kv.key_ptr.*);
                const val = s.gpa.dupe(u8, kv.value_ptr.items) catch |err| {
                    s.gpa.free(key);
                    return err;
                };
                m.putAssumeCapacity(key, val);
            }
            break :blk m;
        };
        freeDiagMap(s.gpa, &s.build.diags);
        s.build.diags = next;
        for (touched.items) |uri| {
            if (s.docs.get(uri)) |doc| {
                try s.publish(a, doc);
            } else {
                const items = s.build.diags.get(uri) orelse "";
                s.toEditor(try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":{f},\"diagnostics\":[{s}]}}}}", .{ json.fmt(uri, .{}), items }));
            }
        }
    }

    fn freeDiagMap(gpa: Allocator, m: *std.StringHashMapUnmanaged([]u8)) void {
        var it = m.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        m.deinit(gpa);
    }

    /// Wrap-up: kill running build, reap thread
    fn stopBuild(s: *Server) void {
        s.mutex.lockUncancelable(s.io);
        s.shutting_down = true;
        if (s.build.child_pid) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        const t = s.build.thread;
        s.build.thread = null;
        s.mutex.unlock(s.io);
        if (t) |th| th.join();
    }

    /// Design-system tokens for this file: up from dir find theme.json (same agreement as
    /// build.zig theme wiring: examples use examples/theme.json), miss/fail use default (schema,
    /// src/tokens/default.json reflected)
    fn scalesFor(s: *Server, a: Allocator, uri: []const u8) ![]const schema.Scale {
        const path = (try uriToPath(a, uri)) orelse return &schema.scales;
        var dir = std.fs.path.dirname(path);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            const candidate = try std.fs.path.join(a, &.{ d, "theme.json" });
            const st = std.Io.Dir.cwd().statFile(s.io, candidate, .{}) catch continue;
            if (s.themes.get(candidate)) |t| {
                if (t.mtime == st.mtime.nanoseconds) return t.scales;
                t.destroy(s.gpa);
                const old = s.themes.fetchRemove(candidate).?;
                s.gpa.free(old.key);
            }
            const t = ThemeTable.load(s.gpa, s.io, candidate, st.mtime.nanoseconds) catch |err| {
                std.log.warn("yix-lsp: {s}: {s}; using the default design system", .{ candidate, @errorName(err) });
                return &schema.scales;
            };
            const key = try s.gpa.dupe(u8, candidate);
            s.themes.put(s.gpa, key, t) catch |err| {
                s.gpa.free(key);
                t.destroy(s.gpa);
                return err;
            };
            return t.scales;
        }
        return &schema.scales;
    }

    /// Result position on sibling (request's doc handled by mapBack): redirect to source
    fn mapTwins(s: *Server, a: Allocator, v: *json.Value) !void {
        switch (v.*) {
            .array => |*arr| for (arr.items) |*x| try s.mapTwins(a, x),
            .object => |*obj| {
                inline for (.{ "uri", "targetUri" }) |key| {
                    if (obj.get(key)) |u| if (u == .string) if (try s.twinSource(a, u.string)) |src| {
                        try obj.put(a, key, .{ .string = src.uri });
                        const ranges = if (comptime std.mem.eql(u8, key, "uri")) &[_][]const u8{"range"} else &[_][]const u8{ "targetRange", "targetSelectionRange" };
                        for (ranges) |rk| if (obj.getPtr(rk)) |r| try mapTwinRange(a, r, src);
                    };
                }
                var it = obj.iterator();
                while (it.next()) |e| if (e.value_ptr.* == .array or e.value_ptr.* == .object) try s.mapTwins(a, e.value_ptr);
            },
            else => {},
        }
    }

    /// Match CLI generation: identity is relative to the workspace/build root,
    /// independent of URI spelling, absolute diagnostic paths, or twin output.
    fn stableSourcePath(s: *Server, a: Allocator, path: []const u8) ![]u8 {
        const owned_base = if (s.build.root == null) try std.Io.Dir.cwd().realPathFileAlloc(s.io, ".", a) else null;
        defer if (owned_base) |base| a.free(base);
        const base = s.build.root orelse owned_base.?;
        const absolute = try std.fs.path.resolve(a, &.{ base, path });
        defer a.free(absolute);
        const relative = try std.fs.path.relativeAlloc(a, base, null, base, absolute);
        if (comptime @import("builtin").os.tag == .windows) for (relative) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        };
        return relative;
    }

    fn twinSource(s: *Server, a: Allocator, uri: []const u8) !?TwinSource {
        const path = (try uriToPath(a, uri)) orelse return null;
        const src_path = (try compiler.sourceOfTwin(a, path)) orelse return null;
        const src_uri = try pathToUri(a, src_path);
        // Source open, virtual sent to ZLS: ZLS has latest sent (no generated header), even if
        // current compile fails. Segment table from compile that made it; source offset remapped
        // current via repair.
        if (s.docs.get(src_uri)) |d| if (d.virtual_open) if (d.mapped) |m|
            return .{ .uri = src_uri, .text = d.text, .generated = m.output, .segments = m.segments, .doc = d };
        // Else ZLS reads disk sibling: header then output
        const disk = std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(64 * 1024 * 1024)) catch return null;
        const head = compiler.twinOutputStart(disk) orelse return null;
        const text = std.Io.Dir.cwd().readFileAlloc(s.io, src_path, a, .limited(64 * 1024 * 1024)) catch return null;
        return switch (try compiler.compileMappedSource(a, try s.stableSourcePath(a, src_path), text)) {
            // Disk coordinates belong to this exact output. A stale twin cannot be
            // mapped with a freshly compiled source's segment table.
            .mapped => |m| if (std.mem.eql(u8, disk, try compiler.twinText(a, src_path, m.output)))
                .{ .uri = src_uri, .text = text, .generated = disk, .segments = m.segments, .head = head }
            else
                null,
            .diagnostic => null,
        };
    }

    fn didClose(s: *Server, a: Allocator, params: json.Value) !void {
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const kv = s.docs.fetchRemove(uri) orelse return;
        const doc = kv.value;
        if (doc.virtual_open) {
            const body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{{\"textDocument\":{{\"uri\":{f}}}}}}}", .{json.fmt(doc.virtual_uri, .{})});
            s.toZls(body);
        }
        doc.deinit(s.gpa);
        s.gpa.destroy(doc);
    }

    /// A request arrived on text that fails to compile: try the repair strings after the cursor;
    /// if one compiles, hand the repaired result to ZLS to serve this request.
    fn repairAt(s: *Server, a: Allocator, doc: *Doc, cursor: usize) !void {
        if (!isYixFamily(doc.uri)) return;
        for (repairs) |ins| {
            const patched = try std.mem.concat(s.gpa, u8, &.{ doc.text[0..cursor], ins, doc.text[cursor..] });
            const result = compileDoc(s, doc.uri, patched) catch |err| {
                s.gpa.free(patched);
                return err;
            };
            switch (result) {
                .diagnostic => |d| {
                    freeDiag(s.gpa, doc.uri, d);
                    s.gpa.free(patched);
                },
                .mapped => |m| {
                    try s.installMapped(a, doc, m, patched);
                    doc.repair = .{ .cursor = cursor, .inserted = ins };
                    return;
                },
            }
        }
    }

    /// Swap compile result (mapped_text takes text_owned), give generated to ZLS
    fn installMapped(s: *Server, a: Allocator, doc: *Doc, m: compiler.Mapped, text_owned: []u8) !void {
        if (doc.mapped) |old| old.deinit(s.gpa);
        if (doc.mapped_text) |t| s.gpa.free(t);
        doc.mapped = m;
        doc.mapped_text = text_owned;
        doc.repair = null;
        doc.virtual_version += 1;
        s.gpa.free(doc.zls_diags);
        doc.zls_diags = &.{};
        const body = if (!doc.virtual_open)
            try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":{f},\"languageId\":\"zig\",\"version\":{d},\"text\":{f}}}}}}}", .{ json.fmt(doc.virtual_uri, .{}), doc.virtual_version, json.fmt(m.output, .{}) })
        else
            try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":{f},\"version\":{d}}},\"contentChanges\":[{{\"text\":{f}}}]}}}}", .{ json.fmt(doc.virtual_uri, .{}), doc.virtual_version, json.fmt(m.output, .{}) });
        doc.virtual_open = true;
        s.toZls(body);
    }

    /// Recompile: success updates virtual (didOpen/didChange to ZLS), fail keeps prior;
    /// publish merged diagnostic.
    fn recompile(s: *Server, a: Allocator, doc: *Doc) !void {
        if (doc.yix_diag) |old| freeDiag(s.gpa, doc.uri, old);
        doc.yix_diag = null;
        if (!isYixFamily(doc.uri)) {
            // .zig: forward as-is (position 1:1)
            const out = try s.gpa.dupe(u8, doc.text);
            errdefer s.gpa.free(out);
            const segments = try s.gpa.alloc(compiler.Segment, 1);
            errdefer s.gpa.free(segments);
            segments[0] = .{ .generated = 0, .generated_len = out.len, .source = 0, .source_len = out.len, .exact = true };
            const text_owned = try s.gpa.dupe(u8, doc.text);
            try s.installMapped(a, doc, .{ .output = out, .segments = segments }, text_owned);
            return s.publish(a, doc);
        }
        switch (try compileDoc(s, doc.uri, doc.text)) {
            .diagnostic => |d| doc.yix_diag = d,
            .mapped => |m| {
                doc.yix_diag = null;
                const text_owned = s.gpa.dupe(u8, doc.text) catch |err| {
                    m.deinit(s.gpa);
                    return err;
                };
                try s.installMapped(a, doc, m, text_owned);
                try s.publish(a, doc);
                return;
            },
        }
        try s.publish(a, doc);
    }

    fn publish(s: *Server, a: Allocator, doc: *Doc) !void {
        var items: std.ArrayList(u8) = .empty;
        if (doc.yix_diag) |d| {
            const p = posOf(doc.text, d.offset);
            const e = posOf(doc.text, @min(d.offset + 1, doc.text.len));
            try items.appendSlice(a, try std.fmt.allocPrint(a, "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":1,\"source\":\"yix\",\"message\":{f}}}", .{ p.line, p.character, e.line, e.character, json.fmt(d.message, .{}) }));
        }
        // Source text changed (compile fail): ZLS diagnostic for old text, don't publish
        if (doc.current() != null and doc.zls_diags.len != 0) {
            if (items.items.len != 0) try items.append(a, ',');
            try items.appendSlice(a, doc.zls_diags);
        }
        if (s.build.diags.get(doc.uri)) |b| if (b.len != 0) {
            if (items.items.len != 0) try items.append(a, ',');
            try items.appendSlice(a, b);
        };
        const body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":{f},\"diagnostics\":[{s}]}}}}", .{ json.fmt(doc.uri, .{}), items.items });
        s.toEditor(body);
    }

    fn positional(s: *Server, a: Allocator, msg: json.Value, method: []const u8, params: json.Value) !void {
        const id = msg.object.get("id") orelse return;
        const uri = params.object.get("textDocument").?.object.get("uri").?.string;
        const doc = s.docs.get(uri) orelse return s.reply(a, id, .{ .null = {} });
        const pos_v = params.object.get("position").?.object;
        const pos: Pos = .{ .line = @intCast(pos_v.get("line").?.integer), .character = @intCast(pos_v.get("character").?.integer) };
        const cursor = offsetOf(doc.text, pos);
        if (isYss(uri)) {
            // DSL proxy answers; Zig + `{zig}` forward to ZLS
            const d = try yssContext(a, doc.text, cursor, try s.scalesFor(a, uri));
            if (d.ctx.kind != .zig) {
                const result: ?json.Value = if (std.mem.eql(u8, method, "textDocument/completion"))
                    try yssCompletion(a, doc.text, d, cursor)
                else if (std.mem.eql(u8, method, "textDocument/hover"))
                    try yssHover(a, doc.text, d)
                else if (std.mem.eql(u8, method, "textDocument/definition") or std.mem.eql(u8, method, "textDocument/declaration"))
                    try yssDefinition(a, uri, doc.text, d)
                else
                    null;
                return s.reply(a, id, result orelse .{ .null = {} });
            }
        } else if (std.mem.endsWith(u8, uri, ".yix") and std.mem.eql(u8, method, "textDocument/completion")) {
            if (try tagContext(a, doc.text, cursor)) |ctx| return s.templateCompletion(a, id, doc, ctx, cursor);
        }
        if (doc.forRequest() == null) try s.repairAt(a, doc, cursor);
        const m = doc.forRequest() orelse return s.reply(a, id, .{ .null = {} });
        // Not in Zig fragment (tag name, plain text...): no smarts, return empty
        const gen = srcToGen(m.segments, doc.toMappedSrc(cursor)) orelse return s.reply(a, id, .{ .null = {} });
        const gp = posOf(m.output, gen);
        var p2 = params;
        var td: json.ObjectMap = .empty;
        try td.put(a, "uri", .{ .string = doc.virtual_uri });
        try p2.object.put(a, "textDocument", .{ .object = td });
        var np: json.ObjectMap = .empty;
        try np.put(a, "line", .{ .integer = @intCast(gp.line) });
        try np.put(a, "character", .{ .integer = @intCast(gp.character) });
        try p2.object.put(a, "position", .{ .object = np });
        var m2 = msg;
        try m2.object.put(a, "params", p2);
        try s.forwardRequest(a, m2, uri, method);
    }

    /// Template position completion: tag (host tags + local components), props (host static;
    /// components via ZLS def lookup + parse props)
    fn templateCompletion(s: *Server, a: Allocator, id: json.Value, doc: *Doc, ctx: TagContext, cursor: usize) !void {
        switch (ctx) {
            .tag_name => {
                var arr = json.Array.init(a);
                for (host_tags) |t| try arr.append(try completionItem(a, t, 10, "host element", ""));
                // Top-level uppercase names (components, imported namespaces)
                var it = std.mem.tokenizeAny(u8, doc.text, " \t\r\n;(");
                var prev: []const u8 = "";
                while (it.next()) |w| {
                    if ((std.mem.eql(u8, prev, "fn") or std.mem.eql(u8, prev, "const")) and w.len != 0 and std.ascii.isUpper(w[0])) try arr.append(try completionItem(a, w, 7, "component", ""));
                    prev = w;
                }
                return s.reply(a, id, .{ .array = arr });
            },
            .attribute => |attr| {
                var is_host = false;
                for (host_tags) |t| is_host = is_host or std.mem.eql(u8, t, attr.tag);
                if (is_host) {
                    // Prop table same as compiler (compiler.hostAttrs), by tag
                    var arr = json.Array.init(a);
                    for (compiler.hostAttrs(attr.tag).?) |hp| if (!presentHas(attr.present, hp.name)) try arr.append(try completionItem(a, hp.name, 5, "", hp.doc));
                    if (std.mem.eql(u8, attr.tag, "icon") or std.mem.eql(u8, attr.tag, "image")) {
                        if (!presentHas(attr.present, "src")) try arr.append(try completionItem(a, compiler.media_src.name, 5, "", compiler.media_src.doc));
                    }
                    if (std.mem.eql(u8, attr.tag, "canvas")) for (compiler.canvas_extra) |hp| if (!presentHas(attr.present, hp.name)) try arr.append(try completionItem(a, hp.name, 5, "", hp.doc));
                    return s.reply(a, id, .{ .array = arr });
                }
                // Component: locate in virtual doc, ask ZLS for def
                if (doc.forRequest() == null) try s.repairAt(a, doc, cursor);
                const m = doc.forRequest() orelse return s.reply(a, id, .{ .null = {} });
                // Namespaced tag (W.Button) query last segment
                const last_dot = std.mem.lastIndexOfScalar(u8, attr.tag, '.');
                const name_at = attr.tag_at + (if (last_dot) |d| d + 1 else 0);
                const gen = srcToGen(m.segments, doc.toMappedSrc(name_at)) orelse return s.reply(a, id, .{ .null = {} });
                const gp = posOf(m.output, gen);
                const our = s.next_id;
                s.next_id += 1;
                const name = attr.tag[if (last_dot) |d| d + 1 else 0..];
                try s.pending.put(s.gpa, our, .{
                    .editor_id = try s.gpa.dupe(u8, try json.Stringify.valueAlloc(a, id, .{})),
                    .method = "props",
                    .doc_uri = try s.gpa.dupe(u8, doc.uri),
                    .revision = doc.revision,
                    .virtual_version = doc.virtual_version,
                    .props_lookup = .{ .prefix = try s.gpa.dupe(u8, name), .present = try s.gpa.dupe(u8, attr.present) },
                });
                const body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/definition\",\"params\":{{\"textDocument\":{{\"uri\":{f}}},\"position\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ our, json.fmt(doc.virtual_uri, .{}), gp.line, gp.character });
                s.toZls(body);
            },
        }
    }

    /// ZLS returned component def: read def file, parse `<name>Props`, props completion to editor
    fn finishPropsLookup(s: *Server, a: Allocator, editor_id: []const u8, lookup: PropsLookup, result: ?json.Value) !void {
        var arr = json.Array.init(a);
        if (result) |r| {
            const loc: ?json.Value = switch (r) {
                .array => |xs| if (xs.items.len != 0) xs.items[0] else null,
                .object => r,
                else => null,
            };
            if (loc) |l| {
                const uri = (l.object.get("uri") orelse l.object.get("targetUri").?).string;
                const source: ?[]const u8 = if (s.docByVirtual(uri)) |d|
                    (if (d.mapped) |mm| mm.output else null)
                else if (std.mem.startsWith(u8, uri, "file://"))
                    std.Io.Dir.cwd().readFileAlloc(s.io, uri["file://".len..], a, .limited(16 * 1024 * 1024)) catch null
                else
                    null;
                if (source) |src| {
                    // Yix components generate `<name>Props`; hand-written by convention
                    // `<name>Props`
                    const props_name = try std.fmt.allocPrint(a, "{s}Props", .{lookup.prefix});
                    const fields = try propsFields(a, src, props_name);
                    for (fields.items) |f| {
                        if (!presentHas(lookup.present, f.object.get("label").?.string)) try arr.append(f);
                    }
                }
            }
        }
        var obj: json.ObjectMap = .empty;
        try obj.put(a, "jsonrpc", .{ .string = "2.0" });
        try obj.put(a, "id", try json.parseFromSliceLeaky(json.Value, a, editor_id, .{}));
        try obj.put(a, "result", .{ .array = arr });
        s.toEditor(try json.Stringify.valueAlloc(a, json.Value{ .object = obj }, .{}));
    }

    /// ZLS disconnected: pending replies all null
    fn abandonPending(s: *Server) void {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var it = s.pending.valueIterator();
        while (it.next()) |p| {
            if (p.editor_id) |e| {
                const id = json.parseFromSliceLeaky(json.Value, a, e, .{}) catch continue;
                if (std.mem.eql(u8, p.method, "props")) {
                    s.reply(a, id, .{ .array = json.Array.init(a) }) catch {};
                } else if (std.mem.eql(u8, p.method, "initialize")) {
                    // ZLS missing before initialize reply (spawn ok, exec fail: path not found,
                    // dispatch fail)
                    s.reply(a, id, degradedInitialize(a) catch .{ .null = {} }) catch {};
                } else s.reply(a, id, .{ .null = {} }) catch {};
                s.gpa.free(e);
            }
            if (p.doc_uri) |u| s.gpa.free(u);
            if (p.props_lookup) |l| {
                s.gpa.free(l.prefix);
                s.gpa.free(l.present);
            }
        }
        s.pending.clearRetainingCapacity();
    }

    // ---------------- ZLS -> Proxy ----------------

    fn fromZls(s: *Server, body: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var msg = try json.parseFromSliceLeaky(json.Value, a, body, .{});
        if (msg != .object) return;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const method = if (msg.object.get("method")) |m| m.string else null;
        const id = msg.object.get("id");
        if (debug) std.debug.print("yix-lsp <- zls: {s}\n", .{body[0..@min(body.len, 300)]});
        if (method) |name| {
            if (id) |req_id| return s.answerZlsRequest(a, req_id, name, msg.object.get("params"));
            if (std.mem.eql(u8, name, "textDocument/publishDiagnostics")) return s.zlsDiagnostics(a, msg.object.get("params").?);
            // window/logMessage, $/progress etc: forward to editor
            if (std.mem.startsWith(u8, name, "window/") or std.mem.startsWith(u8, name, "$/")) s.toEditor(body);
            return;
        }
        // Proxy-forwarded request reply
        const our = switch (id orelse return) {
            .integer => |v| v,
            else => return,
        };
        const kv = s.pending.fetchRemove(our) orelse return;
        const pend = kv.value;
        defer {
            if (pend.editor_id) |e| s.gpa.free(e);
            if (pend.doc_uri) |u| s.gpa.free(u);
        }
        const editor_id = pend.editor_id orelse return;
        if (pend.doc_uri) |uri| {
            const doc = s.docs.get(uri);
            if (doc == null or doc.?.revision != pend.revision or doc.?.virtual_version != pend.virtual_version) {
                if (pend.props_lookup) |lookup| {
                    s.gpa.free(lookup.prefix);
                    s.gpa.free(lookup.present);
                }
                return s.reply(a, try json.parseFromSliceLeaky(json.Value, a, editor_id, .{}), .{ .null = {} });
            }
        }
        if (pend.props_lookup) |lookup| {
            defer {
                s.gpa.free(lookup.prefix);
                s.gpa.free(lookup.present);
            }
            return s.finishPropsLookup(a, editor_id, lookup, msg.object.get("result"));
        }
        try msg.object.put(a, "id", try json.parseFromSliceLeaky(json.Value, a, editor_id, .{}));
        if (std.mem.eql(u8, pend.method, "initialize")) {
            if (msg.object.getPtr("result")) |r| try patchCapabilities(a, r);
        } else if (pend.doc_uri) |uri| {
            if (s.docs.get(uri)) |doc| if (doc.forRequest()) |m| {
                if (msg.object.getPtr("result")) |r| try mapBack(a, r, doc, m, true);
            };
            if (msg.object.getPtr("result")) |r| try s.mapTwins(a, r);
        }
        s.toEditor(try json.Stringify.valueAlloc(a, msg, .{}));
    }

    /// ZLS client request proxy answers: config default values, progress / capability register
    /// auto-confirm
    fn answerZlsRequest(s: *Server, a: Allocator, id: json.Value, method: []const u8, params: ?json.Value) !void {
        var result: json.Value = .{ .null = {} };
        if (std.mem.eql(u8, method, "workspace/configuration")) {
            var arr = json.Array.init(a);
            if (params) |p| if (p.object.get("items")) |items| {
                for (items.array.items) |_| try arr.append(.{ .null = {} });
            };
            result = .{ .array = arr };
        }
        var obj: json.ObjectMap = .empty;
        try obj.put(a, "jsonrpc", .{ .string = "2.0" });
        try obj.put(a, "id", id);
        try obj.put(a, "result", result);
        s.toZls(try json.Stringify.valueAlloc(a, json.Value{ .object = obj }, .{}));
    }

    fn zlsDiagnostics(s: *Server, a: Allocator, params: json.Value) !void {
        const uri = params.object.get("uri").?.string;
        const doc = s.docByVirtual(uri) orelse return;
        // Notifications may be coalesced or repeated: their count is not a
        // document version. Versionless ZLS notifications are best effort.
        if (params.object.get("version")) |version| {
            if (version == .integer and version.integer != doc.virtual_version) return;
        }
        // Repair-compile diagnostic: don't publish
        if (doc.repair != null) return;
        const m = doc.mapped orelse return;
        var out: std.ArrayList(u8) = .empty;
        for (params.object.get("diagnostics").?.array.items) |*d| {
            if (d.object.getPtr("range")) |r| {
                const start = r.object.get("start").?.object;
                const gen = offsetOf(m.output, .{ .line = @intCast(start.get("line").?.integer), .character = @intCast(start.get("character").?.integer) });
                const src = genToSrcNearest(m.segments, gen);
                const sp = posOf(doc.mapped_text.?, src);
                var range: json.ObjectMap = .empty;
                try range.put(a, "start", try posValue(a, sp));
                try range.put(a, "end", try posValue(a, .{ .line = sp.line, .character = sp.character + 1 }));
                r.* = .{ .object = range };
            }
            try d.object.put(a, "source", .{ .string = "zig" });
            if (out.items.len != 0) try out.append(a, ',');
            try out.appendSlice(a, try json.Stringify.valueAlloc(a, d.*, .{}));
        }
        s.gpa.free(doc.zls_diags);
        doc.zls_diags = try s.gpa.dupe(u8, out.items);
        try s.publish(a, doc);
    }
};

/// Prop written (comma-delim snake/camel) has this camelCase
fn presentHas(present: []const u8, camel_name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, present, ',');
    while (it.next()) |p| {
        var i: usize = 0;
        var j: usize = 0;
        // Ignore underscores, case-insensitive compare (label_text == labelText)
        while (i < p.len and j < camel_name.len) {
            if (p[i] == '_') {
                i += 1;
                continue;
            }
            if (std.ascii.toLower(p[i]) != std.ascii.toLower(camel_name[j])) break;
            i += 1;
            j += 1;
        }
        if (i == p.len and j == camel_name.len) return true;
    }
    return false;
}

/// No ZLS: proxy answers initialize (full sync + template completion; Yix diagnostic normal)
fn degradedInitialize(a: Allocator) !json.Value {
    var caps: json.ObjectMap = .empty;
    try caps.put(a, "textDocumentSync", try syncOptions(a));
    try caps.put(a, "completionProvider", .{ .object = .empty });
    // .yss DSL smarts don't need ZLS
    try caps.put(a, "hoverProvider", .{ .bool = true });
    try caps.put(a, "definitionProvider", .{ .bool = true });
    try caps.put(a, "documentSymbolProvider", .{ .bool = true });
    var result: json.ObjectMap = .empty;
    try result.put(a, "capabilities", .{ .object = caps });
    var info: json.ObjectMap = .empty;
    try info.put(a, "name", .{ .string = "yix-lsp (no ZLS)" });
    try result.put(a, "serverInfo", .{ .object = info });
    return .{ .object = result };
}

fn posValue(a: Allocator, p: Pos) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(a, "line", .{ .integer = @intCast(p.line) });
    try o.put(a, "character", .{ .integer = @intCast(p.character) });
    return .{ .object = o };
}

/// Only declare proxy-mapped capability; text sync full (whole each time, total recompile).
fn patchCapabilities(a: Allocator, result: *json.Value) !void {
    const caps = (result.object.getPtr("capabilities") orelse return).*;
    var out: json.ObjectMap = .empty;
    try out.put(a, "textDocumentSync", try syncOptions(a));
    const keep = [_][]const u8{ "hoverProvider", "completionProvider", "definitionProvider", "declarationProvider", "typeDefinitionProvider", "implementationProvider", "referencesProvider", "documentHighlightProvider", "signatureHelpProvider" };
    for (keep) |k| if (caps.object.get(k)) |v| try out.put(a, k, v);
    // .yss DSL by proxy, regardless ZLS declaration
    if (!out.contains("hoverProvider")) try out.put(a, "hoverProvider", .{ .bool = true });
    if (!out.contains("definitionProvider")) try out.put(a, "definitionProvider", .{ .bool = true });
    if (!out.contains("completionProvider")) try out.put(a, "completionProvider", .{ .object = .empty });
    try out.put(a, "documentSymbolProvider", .{ .bool = true });
    try result.object.put(a, "capabilities", .{ .object = out });
    var info: json.ObjectMap = .empty;
    try info.put(a, "name", .{ .string = "yix-lsp" });
    try result.object.put(a, "serverInfo", .{ .object = info });
}

/// Map result position on virtual to .yix. `in_doc`: current layer range for request doc
/// (hover / completion / highlight).
fn mapBack(a: Allocator, v: *json.Value, doc: *Doc, m: compiler.Mapped, in_doc: bool) !void {
    switch (v.*) {
        .array => |*arr| for (arr.items) |*x| try mapBack(a, x, doc, m, in_doc),
        .object => |*obj| {
            var here = in_doc;
            inline for (.{ "uri", "targetUri" }) |key| {
                if (obj.get(key)) |u| if (u == .string) {
                    here = std.mem.eql(u8, u.string, doc.virtual_uri);
                    if (here) try obj.put(a, key, .{ .string = doc.uri });
                };
            }
            var it = obj.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                const is_range = std.mem.eql(u8, k, "range") or std.mem.eql(u8, k, "targetRange") or std.mem.eql(u8, k, "targetSelectionRange") or
                    std.mem.eql(u8, k, "insert") or std.mem.eql(u8, k, "replace");
                // originSelectionRange always in request doc
                if (std.mem.eql(u8, k, "originSelectionRange")) {
                    try mapRange(a, e.value_ptr, doc, m);
                } else if (is_range and here) {
                    try mapRange(a, e.value_ptr, doc, m);
                } else if (!is_range) try mapBack(a, e.value_ptr, doc, m, here);
            }
        },
        else => {},
    }
}

fn mapRange(a: Allocator, r: *json.Value, doc: *Doc, m: compiler.Mapped) !void {
    if (r.* != .object) return;
    const s = r.object.get("start") orelse return;
    const e = r.object.get("end") orelse return;
    const gs = offsetOf(m.output, .{ .line = @intCast(s.object.get("line").?.integer), .character = @intCast(s.object.get("character").?.integer) });
    const ge = offsetOf(m.output, .{ .line = @intCast(e.object.get("line").?.integer), .character = @intCast(e.object.get("character").?.integer) });
    const ss = doc.fromMappedSrc(genToSrcNearest(m.segments, gs));
    // Range end: mappable + not before start, else shrink to start
    const se = if (genToSrc(m.segments, ge)) |x| (if (doc.fromMappedSrc(x) >= ss) doc.fromMappedSrc(x) else ss) else ss;
    var out: json.ObjectMap = .empty;
    try out.put(a, "start", try posValue(a, posOf(doc.text, ss)));
    try out.put(a, "end", try posValue(a, posOf(doc.text, se)));
    r.* = .{ .object = out };
}

// Entry point

fn findZls(io: std.Io, gpa: Allocator, args: []const []const u8) ![]const u8 {
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 1) if (std.mem.eql(u8, args[i], "--zls")) return gpa.dupe(u8, args[i + 1]);
    if (@import("zenit_environment").getOwned(gpa, "YIX_ZLS")) |p| return p else |_| {}
    if (std.process.executablePathAlloc(io, gpa)) |exe| {
        defer gpa.free(exe);
        const name = if (@import("builtin").os.tag == .windows) "zenit-zls.exe" else "zenit-zls";
        const sibling = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(exe).?, name });
        if (std.Io.Dir.cwd().access(io, sibling, .{ .execute = true })) |_| return sibling else |_| gpa.free(sibling);
    } else |_| {}
    return gpa.dupe(u8, "zls");
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const zls_path = try findZls(init.io, gpa, args);
    if (@import("zenit_environment").getOwned(gpa, "YIX_LSP_DEBUG")) |v| {
        gpa.free(v);
        debug = true;
    } else |_| {}
    defer gpa.free(zls_path);

    // Write to closed pipe (ZLS or editor exited) gets EPIPE, not SIGPIPE kill
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);

    var child = std.process.spawn(init.io, .{ .argv = &.{zls_path}, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit }) catch |err| {
        std.log.err("yix-lsp: starting ZLS ({s}) failed: {}; running without Zig intelligence", .{ zls_path, err });
        return runWithoutZls(gpa, init.io);
    };
    var server: Server = .{ .io = init.io, .gpa = gpa, .stdout = std.Io.File.stdout(), .zls_in = child.stdin.? };
    defer {
        var it = server.docs.valueIterator();
        while (it.next()) |d| {
            d.*.deinit(gpa);
            gpa.destroy(d.*);
        }
        server.docs.deinit(gpa);
        var themes = server.themes.iterator();
        while (themes.next()) |t| {
            gpa.free(t.key_ptr.*);
            t.value_ptr.*.destroy(gpa);
        }
        server.themes.deinit(gpa);
        var pit = server.pending.valueIterator();
        while (pit.next()) |p| {
            if (p.editor_id) |e| gpa.free(e);
            if (p.doc_uri) |u| gpa.free(u);
            if (p.props_lookup) |l| {
                gpa.free(l.prefix);
                gpa.free(l.present);
            }
        }
        server.pending.deinit(gpa);
        server.build.deinit(gpa);
    }

    // ZLS output read by read thread always draining (frame only, queue, never take server lock),
    // process thread holds lock on service. Else: editor thread holds lock write to ZLS then big
    // message pipe-blocked, ZLS write diagnostic also blocked, read thread waits lock—three
    // deadlock.
    var inbox: Inbox = .{ .io = init.io, .gpa = gpa };
    defer inbox.deinit();
    const zls_reader = try std.Thread.spawn(.{}, struct {
        fn run(q: *Inbox, out: std.Io.File, srv: *Server, pid: std.process.Child.Id) void {
            var framer: Framer = .{ .io = q.io, .file = out };
            defer framer.buf.deinit(q.gpa);
            while (true) {
                const body = framer.next(q.gpa) catch |err| {
                    // Protocol corrupt: no one draining ZLS output, stalls write, reads stuck—
                    // mark disconnect (later writes silent) + kill, avoid lock-holding write block
                    // forever.
                    std.log.err("yix-lsp: reading from ZLS failed: {}; ZLS disabled for this session", .{err});
                    srv.zls_dead.store(true, .release);
                    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
                    break;
                } orelse break;
                q.push(body);
            }
            srv.zls_dead.store(true, .release);
            q.close();
        }
    }.run, .{ &inbox, child.stdout.?, &server, child.id.? });
    const zls_worker = try std.Thread.spawn(.{}, struct {
        fn run(srv: *Server, q: *Inbox) void {
            while (q.pop()) |body| {
                defer srv.gpa.free(body);
                srv.fromZls(body) catch |err| std.log.err("yix-lsp: zls message: {}", .{err});
            }
            srv.abandonPending();
        }
    }.run, .{ &server, &inbox });

    var framer: Framer = .{ .io = init.io, .file = std.Io.File.stdin() };
    defer framer.buf.deinit(gpa);
    while (true) {
        const body = framer.next(gpa) catch |err| {
            std.log.err("yix-lsp: reading from the editor failed: {}", .{err});
            break;
        } orelse break;
        defer gpa.free(body);
        server.fromEditor(body) catch |err| std.log.err("yix-lsp: editor message: {}", .{err});
        if (server.exit_requested) break;
    }
    server.stopBuild();
    // Wrap-up: close ZLS input let exit; watchdog 3s wait fail kills to guarantee join unblocks
    server.zls_mutex.lockUncancelable(server.io);
    child.stdin.?.close(init.io);
    child.stdin = null;
    server.zls_dead.store(true, .release);
    server.zls_mutex.unlock(server.io);
    var exited: std.atomic.Value(bool) = .init(false);
    const watchdog = std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, done: *std.atomic.Value(bool), pid: std.process.Child.Id) void {
            var waited: usize = 0;
            while (waited < 30 and !done.load(.acquire)) : (waited += 1) std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
            if (!done.load(.acquire)) std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        }
    }.run, .{ init.io, &exited, child.id.? }) catch null;
    // Without a watchdog thread, terminate now so neither reader nor worker can hang.
    if (watchdog == null) std.posix.kill(child.id.?, std.posix.SIG.KILL) catch {};
    zls_reader.join();
    zls_worker.join();
    // EOF does not imply process exit: ZLS may close stdout while remaining alive.
    // Signal before canceling the watchdog and before reaping. The unreaped pid
    // cannot be reused; join the watchdog before wait to preserve that guarantee.
    std.posix.kill(child.id.?, std.posix.SIG.KILL) catch {};
    exited.store(true, .release);
    if (watchdog) |w| w.join();
    _ = child.wait(init.io) catch {};
}

/// No ZLS: only Yix diagnostic + template completion
fn runWithoutZls(gpa: Allocator, io: std.Io) !void {
    var server: Server = .{ .io = io, .gpa = gpa, .stdout = std.Io.File.stdout(), .zls_in = undefined };
    server.zls_dead.store(true, .release);
    defer {
        var it = server.docs.valueIterator();
        while (it.next()) |d| {
            d.*.deinit(gpa);
            gpa.destroy(d.*);
        }
        server.docs.deinit(gpa);
        var themes = server.themes.iterator();
        while (themes.next()) |t| {
            gpa.free(t.key_ptr.*);
            t.value_ptr.*.destroy(gpa);
        }
        server.themes.deinit(gpa);
        server.pending.deinit(gpa);
        server.build.deinit(gpa);
    }
    var framer: Framer = .{ .io = io, .file = std.Io.File.stdin() };
    defer framer.buf.deinit(gpa);
    while (true) {
        const body = framer.next(gpa) catch break orelse break;
        defer gpa.free(body);
        server.fromEditor(body) catch |err| std.log.err("yix-lsp: editor message: {}", .{err});
        if (server.exit_requested) break;
    }
    server.stopBuild();
}

// Tests: position conversion and segment table mapping

test "UTF-16 positions round-trip through byte offsets" {
    const text = "ab\n中文😀x\nend";
    const p = posOf(text, std.mem.indexOf(u8, text, "x").?);
    try std.testing.expectEqual(@as(usize, 1), p.line);
    try std.testing.expectEqual(@as(usize, 4), p.character); // Chinese = 2, emoji = 2 (surrogate pair)
    try std.testing.expectEqual(std.mem.indexOf(u8, text, "x").?, offsetOf(text, p));
    try std.testing.expectEqual(std.mem.indexOf(u8, text, "end").?, offsetOf(text, .{ .line = 2, .character = 0 }));
}

test "segment mapping prefers the smallest enclosing segment and falls back for synthetic code" {
    const segs = [_]compiler.Segment{
        .{ .generated = 0, .generated_len = 20, .source = 100, .source_len = 20, .exact = true },
        .{ .generated = 5, .generated_len = 3, .source = 105, .source_len = 3, .exact = true },
        .{ .generated = 30, .generated_len = 10, .source = 200, .source_len = 0, .exact = false },
    };
    try std.testing.expectEqual(@as(?usize, 6), srcToGen(&segs, 106));
    try std.testing.expectEqual(@as(?usize, 15), srcToGen(&segs, 115));
    try std.testing.expectEqual(@as(?usize, 30), srcToGen(&segs, 200));
    try std.testing.expectEqual(@as(?usize, 200), genToSrc(&segs, 35));
    try std.testing.expectEqual(@as(usize, 120), genToSrcNearest(&segs, 25));
}

// Twin files: position mapping and write-back

fn isYixFamily(uri: []const u8) bool {
    return std.mem.endsWith(u8, uri, ".yix") or std.mem.endsWith(u8, uri, ".yss");
}

/// Full sync + save notify (save converts file to dist)
fn syncOptions(a: Allocator) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(a, "openClose", .{ .bool = true });
    try o.put(a, "change", .{ .integer = 1 });
    var save: json.ObjectMap = .empty;
    try save.put(a, "includeText", .{ .bool = false });
    try o.put(a, "save", .{ .object = save });
    return .{ .object = o };
}

/// Parse one theme.json to token table shape same as schema (category -> name + light/dark value).
/// Only flat names (nested group token not directly referenceable from .yss).
const ThemeTable = struct {
    arena: std.heap.ArenaAllocator,
    mtime: i128,
    scales: []const schema.Scale,

    fn load(gpa: Allocator, io: std.Io, path: []const u8, mtime: i128) !*ThemeTable {
        const t = try gpa.create(ThemeTable);
        t.* = .{ .arena = .init(gpa), .mtime = mtime, .scales = &.{} };
        errdefer t.destroy(gpa);
        const a = t.arena.allocator();
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
        var doc = try token_resolver.parse(gpa, source);
        defer doc.deinit();
        if (doc.diagnostic != null) return error.InvalidTheme;
        const light = modeIndex(doc.modes, "light") orelse return error.InvalidTheme;
        const dark = modeIndex(doc.modes, "dark") orelse light;
        var scales: std.ArrayList(schema.Scale) = .empty;
        for (std.enums.values(token_model.Category)) |cat| {
            var tokens: std.ArrayList(schema.Token) = .empty;
            const prefix = @tagName(cat);
            for (doc.tokens, 0..) |tok, i| {
                if (tok.category != cat or tok.path.len <= prefix.len + 1) continue;
                const name = tok.path[prefix.len + 1 ..];
                if (std.mem.indexOfScalar(u8, name, '.') != null) continue;
                try tokens.append(a, .{ .name = try a.dupe(u8, name), .light = try valueText(a, doc.modes[light].values[i]), .dark = try valueText(a, doc.modes[dark].values[i]) });
            }
            try scales.append(a, .{ .category = prefix, .tokens = tokens.items });
        }
        t.scales = scales.items;
        return t;
    }

    fn destroy(t: *ThemeTable, gpa: Allocator) void {
        t.arena.deinit();
        gpa.destroy(t);
    }

    fn modeIndex(modes: []const token_model.Mode, name: []const u8) ?usize {
        for (modes, 0..) |m, i| if (std.mem.eql(u8, m.name, name)) return i;
        return null;
    }

    /// Display same as schema generator: color `#rrggbb[aa]`, number as-is, struct per-field (skip
    /// null)
    fn valueText(a: Allocator, v: token_model.Value) ![]const u8 {
        return switch (v) {
            .number => |n| std.fmt.allocPrint(a, "{d}", .{n}),
            .weight => |w| std.fmt.allocPrint(a, "{d}", .{w}),
            .color => |c| colorText(a, c),
            .shadow => |sh| std.fmt.allocPrint(a, "color={s} blur={d} offset_x={d} offset_y={d} spread={d}", .{ try colorText(a, sh.color), sh.blur, sh.offset_x, sh.offset_y, sh.spread }),
            .typography => |ty| blk: {
                var out: std.ArrayList(u8) = .empty;
                if (ty.font_size) |x| try compiler.style.list_writer.init(a, &out).print("font_size={d}", .{x});
                if (ty.font_weight) |x| try compiler.style.list_writer.init(a, &out).print("{s}font_weight={d}", .{ if (out.items.len == 0) "" else " ", x });
                if (ty.line_height) |x| try compiler.style.list_writer.init(a, &out).print("{s}line_height={d}", .{ if (out.items.len == 0) "" else " ", x });
                break :blk out.items;
            },
        };
    }

    fn colorText(a: Allocator, c: token_model.values.Color) ![]const u8 {
        if (c.a == 255) return std.fmt.allocPrint(a, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
        return std.fmt.allocPrint(a, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a });
    }
};

/// Sibling-corresponding source: segment table + source text; `head` = generated starts in
/// `generated` (disk sibling has one-line header). `doc`: source open, segment table's source
/// offset vs. latest compile text (may have cursor repair), need fromMappedSrc to get current.
const TwinSource = struct { uri: []const u8, text: []const u8, generated: []const u8, segments: []const compiler.Segment, head: usize = 0, doc: ?*Doc = null };

fn mapTwinRange(a: Allocator, r: *json.Value, src: TwinSource) !void {
    if (r.* != .object) return;
    const conv = struct {
        fn f(g: TwinSource, p: ?json.Value) ?usize {
            const pv = p orelse return null;
            if (pv != .object) return null;
            const line = pv.object.get("line") orelse return null;
            const ch = pv.object.get("character") orelse return null;
            if (line != .integer or ch != .integer or line.integer < 0 or ch.integer < 0) return null;
            const off = offsetOf(g.generated, .{ .line = @intCast(line.integer), .character = @intCast(ch.integer) });
            const src_off = genToSrcNearest(g.segments, off -| g.head);
            return if (g.doc) |d| d.fromMappedSrc(src_off) else src_off;
        }
    }.f;
    const st = conv(src, r.object.get("start")) orelse return;
    const en = @max(st, conv(src, r.object.get("end")) orelse st);
    r.* = try rangeValue(a, src.text, st, en);
}

/// Write temp same-dir then rename to target
fn writeAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{});
    defer af.deinit(io);
    var writer = af.file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
    try af.replace(io);
}

// .yss: native intelligence for DSL (completion / hover / goto / outline), data from style compiler
// outline and schema

const style = compiler.style;
const token_resolver = @import("token_resolver");
const token_model = @import("token_model");
const schema = style.schema;

fn isYss(uri: []const u8) bool {
    return std.mem.endsWith(u8, uri, ".yss");
}

/// `.yss` uses style compiler; else Yix (diagnostics owned by gpa)
fn compileDoc(s: *Server, uri: []const u8, text: []const u8) !compiler.MappedResult {
    if (isYss(uri)) return style.compileMapped(s.gpa, text);
    const path = (try uriToPath(s.gpa, uri)) orelse return compiler.compileMapped(s.gpa, text);
    defer s.gpa.free(path);
    const stable = try s.stableSourcePath(s.gpa, path);
    defer s.gpa.free(stable);
    return compiler.compileMappedWithPath(s.gpa, stable, text);
}

fn freeDiag(gpa: Allocator, uri: []const u8, d: compiler.Diagnostic) void {
    _ = uri;
    gpa.free(d.message);
}

fn snakeOf(a: Allocator, name: []const u8) ![]const u8 {
    const out = try a.dupe(u8, name);
    for (out) |*ch| if (ch.* == '-') {
        ch.* = '_';
    };
    return out;
}

const condition_docs = [_]struct { name: []const u8, doc: []const u8 }{
    .{ .name = "hover", .doc = "指针悬停在节点上（普通盒子上有状态来源）" },
    .{ .name = "active", .doc = "在节点上按下、指针仍在节点内（普通盒子上有状态来源）" },
    .{ .name = "focus", .doc = "获得焦点（由组件按自身状态应用）" },
    .{ .name = "selected", .doc = "选中（由组件按自身状态应用）" },
    .{ .name = "expanded", .doc = "展开（由组件按自身状态应用）" },
    .{ .name = "invalid", .doc = "校验不通过（由组件按自身状态应用）" },
    .{ .name = "disabled", .doc = "禁用（由组件按自身状态应用）" },
};

const section_docs = [_]struct { name: []const u8, doc: []const u8 }{
    .{ .name = "base", .doc = "`base { … }`：始终应用的样式" },
    .{ .name = "variant", .doc = "`variant dim = 默认 { opt { … } … }`：一个变体维度；不写默认取第一个选项" },
    .{ .name = "flag", .doc = "`flag dim { … }` / `flag dim;` / `flag dim = true { … }`：布尔维度，块是开着时的样式" },
    .{ .name = "when", .doc = "`when a & !b & c = x & d in (y, z) { … }`：复合规则，`in` 展开成多条" },
};

/// `.yss` shorthand (override field meaning)
fn shorthandDoc(field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "padding") or std.mem.eql(u8, field, "margin")) return "简写：1 / 2（竖 横）/ 4（上 右 下 左）个值，每个是间距 token 或数字";
    if (std.mem.eql(u8, field, "border")) return ".yss 简写：`border: 宽 [颜色]` → `border_width` + `border_color`";
    if (std.mem.eql(u8, field, "transition")) return "整段原文是过渡描述：`background 150ms ease-out, opacity 100ms`";
    return null;
}

fn scaleIn(scales: []const schema.Scale, category: []const u8) ?*const schema.Scale {
    for (scales) |*sc| if (std.mem.eql(u8, sc.category, category)) return sc;
    return null;
}

fn tokenOf(scales: []const schema.Scale, category: []const u8, name: []const u8) ?schema.Token {
    const sc = scaleIn(scales, category) orelse return null;
    for (sc.tokens) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

fn markdown(a: Allocator, text: []const u8) !json.Value {
    var contents: json.ObjectMap = .empty;
    try contents.put(a, "kind", .{ .string = "markdown" });
    try contents.put(a, "value", .{ .string = text });
    var o: json.ObjectMap = .empty;
    try o.put(a, "contents", .{ .object = contents });
    return .{ .object = o };
}

fn rangeValue(a: Allocator, text: []const u8, from: usize, to: usize) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(a, "start", try posValue(a, posOf(text, from)));
    try o.put(a, "end", try posValue(a, posOf(text, to)));
    return .{ .object = o };
}

fn location(a: Allocator, uri: []const u8, text: []const u8, from: usize, to: usize) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(a, "uri", .{ .string = uri });
    try o.put(a, "range", try rangeValue(a, text, from, to));
    return .{ .object = o };
}

/// Completion list: each via textEdit replace whole hyphenated word at cursor (editor default
/// word boundary breaks at `-`)
const Completions = struct {
    a: Allocator,
    text: []const u8,
    from: usize,
    to: usize,
    items: json.Array,

    fn add(c: *Completions, label: []const u8, kind: i64, detail: []const u8, doc: []const u8, insert: ?[]const u8) !void {
        var item = (try completionItem(c.a, label, kind, detail, doc)).object;
        var edit: json.ObjectMap = .empty;
        try edit.put(c.a, "range", try rangeValue(c.a, c.text, c.from, c.to));
        try edit.put(c.a, "newText", .{ .string = insert orelse label });
        try item.put(c.a, "textEdit", .{ .object = edit });
        try item.put(c.a, "filterText", .{ .string = label });
        try c.items.append(.{ .object = item });
    }
};

fn propDetail(a: Allocator, p: *const schema.Prop) ![]const u8 {
    const on = if (p.box and p.text) "box · text" else if (p.box) "box" else "text";
    if (p.category.len != 0) return std.fmt.allocPrint(a, "{s} · {s} token · {s}", .{ p.type_name, p.category, on });
    return std.fmt.allocPrint(a, "{s} · {s}", .{ p.type_name, on });
}

fn propDoc(a: Allocator, p: *const schema.Prop) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (shorthandDoc(p.name)) |sd| {
        try out.appendSlice(a, sd);
        try out.appendSlice(a, "\n\n");
    }
    try out.appendSlice(a, p.doc);
    if (p.values.len != 0) {
        if (out.items.len != 0) try out.appendSlice(a, "\n\n");
        try out.appendSlice(a, "可选：");
        for (p.values, 0..) |v, i| try compiler.style.list_writer.init(a, &out).print("{s}`{s}`", .{ if (i == 0) "" else " ", try style.kebab(a, v) });
    }
    return out.items;
}

/// One .yss request context: outline, cursor position semantic, this file's design-system tokens
const YssDoc = struct { symbols: []style.Symbol, ctx: style.Context, scales: []const schema.Scale };

fn yssContext(a: Allocator, text: []const u8, cursor: usize, scales: []const schema.Scale) !YssDoc {
    const symbols = try style.outline(a, text);
    return .{ .symbols = symbols, .ctx = style.contextAt(text, symbols, cursor), .scales = scales };
}

fn yssCompletion(a: Allocator, text: []const u8, d: YssDoc, cursor: usize) !?json.Value {
    const ctx = d.ctx;
    const sym: ?*const style.Symbol = if (ctx.symbol) |i| &d.symbols[i] else null;
    var c: Completions = .{ .a = a, .text = text, .from = ctx.word_at, .to = @max(cursor, ctx.word_end), .items = json.Array.init(a) };
    switch (ctx.kind) {
        .zig => return null,
        .none, .decl_name => {},
        .section => for (section_docs) |sd| try c.add(sd.name, 14, "", sd.doc, null),
        .condition => for (condition_docs) |cd| try c.add(cd.name, 14, "condition", cd.doc, null),
        .property, .mixin_name, .slot_name => {
            if (ctx.level != .slots) {
                for (&schema.props) |*p| try c.add(try style.kebab(a, p.name), 10, try propDetail(a, p), try propDoc(a, p), try std.fmt.allocPrint(a, "{s}: ", .{try style.kebab(a, p.name)}));
            }
            if (ctx.level != .flat) if (sym) |s| for (s.slots) |sl| try c.add(sl.name, 5, "slot", "", null);
            for (d.symbols) |s| if (s.kind == .mixin and s.name.len != 0) {
                const sig = try mixinSignature(a, &s);
                try c.add(s.name, 3, sig, s.doc, try std.fmt.allocPrint(a, "{s}(", .{s.name}));
            };
        },
        .value => {
            const p: ?*const schema.Prop = if (ctx.prop.len != 0) schema.prop(try snakeOf(a, ctx.prop)) else null;
            const category: []const u8 = if (p) |pp| pp.category else "color";
            if (scaleIn(d.scales, category)) |sc| for (sc.tokens) |t| {
                const is_color = std.mem.eql(u8, category, "color");
                try c.add(try style.kebab(a, t.name), if (is_color) 16 else 21, try std.fmt.allocPrint(a, "{s} token", .{category}), if (is_color) t.light else try std.fmt.allocPrint(a, "light {s} · dark {s}", .{ t.light, t.dark }), null);
            };
            if (p) |pp| for (pp.values) |v| try c.add(try style.kebab(a, v), 20, pp.type_name, "", null);
            if (std.mem.eql(u8, category, "color")) {
                try c.add("transparent", 21, "Color", "完全透明", null);
                try c.add("mix", 3, "mix(a, b, weight)", "颜色混合：从 a 向 b 走 weight（0..1）", "mix(");
                try c.add("rgba", 3, "rgba(r, g, b, a)", "通道 0..255，alpha 0..1（同 CSS）", "rgba(");
                try c.add("rgb", 3, "rgb(r, g, b)", "通道 0..255", "rgb(");
            }
            if (sym) |s| if (s.kind == .mixin) for (s.params) |pr| try c.add(pr.name, 6, "mixin parameter", "", null);
        },
        .when_dim => if (sym) |s| for (s.dims) |dm| try c.add(dm.name, 5, if (dm.flag) "flag" else "variant", "", null),
        .when_option => if (sym) |s| if (s.dim(ctx.dim)) |dm| for (dm.options) |o| try c.add(o.name, 20, dm.name, "", null),
    }
    return .{ .array = c.items };
}

fn mixinSignature(a: Allocator, s: *const style.Symbol) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try compiler.style.list_writer.init(a, &out).print("mixin {s}(", .{s.name});
    for (s.params, 0..) |p, i| try compiler.style.list_writer.init(a, &out).print("{s}{s}", .{ if (i == 0) "" else ", ", p.name });
    try out.append(a, ')');
    return out.items;
}

fn yssHover(a: Allocator, text: []const u8, d: YssDoc) !?json.Value {
    const ctx = d.ctx;
    const word = ctx.word(text);
    if (word.len == 0) return null;
    const sym: ?*const style.Symbol = if (ctx.symbol) |i| &d.symbols[i] else null;
    const body: ?[]const u8 = switch (ctx.kind) {
        .zig, .none => null,
        .section => for (section_docs) |sd| {
            if (std.mem.eql(u8, sd.name, word)) break sd.doc;
        } else null,
        .condition => for (condition_docs) |cd| {
            if (std.mem.eql(u8, cd.name, word)) break try std.fmt.allocPrint(a, "**:{s}**\n\n{s}", .{ word, cd.doc });
        } else null,
        .property => blk: {
            const field = try snakeOf(a, word);
            if (std.mem.eql(u8, field, "transition")) break :blk try std.fmt.allocPrint(a, "**transition**\n\n{s}", .{shorthandDoc("transition").?});
            const p = schema.prop(field) orelse break :blk null;
            break :blk try std.fmt.allocPrint(a, "**{s}** · `{s}`\n\n{s}", .{ word, try propDetail(a, p), try propDoc(a, p) });
        },
        .mixin_name => blk: {
            for (d.symbols) |*s| if (s.kind == .mixin and std.mem.eql(u8, s.name, word)) break :blk try std.fmt.allocPrint(a, "```\n{s}\n```\n{s}", .{ try mixinSignature(a, s), s.doc });
            break :blk null;
        },
        .slot_name => if (sym) |s| try std.fmt.allocPrint(a, "slot **{s}** of `{s}`", .{ word, s.name }) else null,
        .value => blk: {
            const name = try snakeOf(a, word);
            const p: ?*const schema.Prop = if (ctx.prop.len != 0) schema.prop(try snakeOf(a, ctx.prop)) else null;
            const category: []const u8 = if (p) |pp| pp.category else "color";
            // Same parse as ui.css: name priority, then `-` to `_`
            if (tokenOf(d.scales, category, word) orelse tokenOf(d.scales, category, name)) |t| break :blk try std.fmt.allocPrint(a, "**{s}** · {s} token\n\nlight `{s}` · dark `{s}`", .{ word, category, t.light, t.dark });
            if (p) |pp| for (pp.values) |v| if (std.mem.eql(u8, v, name)) break :blk try std.fmt.allocPrint(a, "**{s}** · `{s}`", .{ word, pp.type_name });
            if (std.mem.eql(u8, word, "transparent")) break :blk "**transparent** · 完全透明";
            if (std.mem.eql(u8, word, "mix")) break :blk "**mix(a, b, weight)** · 颜色混合：从 a 向 b 走 weight（0..1），换主题跟随";
            if (std.mem.eql(u8, word, "rgba")) break :blk "**rgba(r, g, b, a)** · 通道 0..255，alpha 0..1（同 CSS）";
            if (std.mem.eql(u8, word, "rgb")) break :blk "**rgb(r, g, b)** · 通道 0..255";
            if (sym) |s| if (s.kind == .mixin) for (s.params) |pr| if (std.mem.eql(u8, pr.name, word)) break :blk try std.fmt.allocPrint(a, "parameter **{s}** of `{s}`", .{ word, try mixinSignature(a, s) });
            break :blk null;
        },
        .when_dim => if (sym) |s| (if (s.dim(word)) |dm| try dimSummary(a, dm) else null) else null,
        .when_option => if (sym) |s| (if (s.dim(ctx.dim)) |dm| try std.fmt.allocPrint(a, "option **{s}** of `{s}`", .{ word, dm.name }) else null) else null,
        .decl_name => if (sym) |s| try symbolSummary(a, s) else null,
    };
    return if (body) |b| try markdown(a, b) else null;
}

fn dimSummary(a: Allocator, dm: *const style.DimInfo) ![]const u8 {
    if (dm.flag) return std.fmt.allocPrint(a, "flag **{s}**: bool", .{dm.name});
    var out: std.ArrayList(u8) = .empty;
    try compiler.style.list_writer.init(a, &out).print("variant **{s}**:", .{dm.name});
    for (dm.options, 0..) |o, i| try compiler.style.list_writer.init(a, &out).print("{s} `{s}`", .{ if (i == 0) "" else " |", o.name });
    return out.items;
}

fn symbolSummary(a: Allocator, s: *const style.Symbol) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = compiler.style.list_writer.init(a, &out);
    switch (s.kind) {
        .style => try w.print("style **{s}** → `ui.css`", .{s.name}),
        .mixin => try w.print("```\n{s}\n```", .{try mixinSignature(a, s)}),
        .recipe => {
            try w.print("recipe **{s}** → `ui.{s}`", .{ s.name, if (s.slots.len != 0) "sva" else "cva" });
            if (s.slots.len != 0) {
                try out.appendSlice(a, "\n\nslots:");
                for (s.slots) |sl| try w.print(" `{s}`", .{sl.name});
            }
            for (s.dims) |*dm| try w.print("\n\n{s}", .{try dimSummary(a, dm)});
        },
    }
    if (s.doc.len != 0) try w.print("\n\n{s}", .{s.doc});
    return out.items;
}

fn yssDefinition(a: Allocator, uri: []const u8, text: []const u8, d: YssDoc) !?json.Value {
    const ctx = d.ctx;
    const word = ctx.word(text);
    if (word.len == 0) return null;
    const sym: ?*const style.Symbol = if (ctx.symbol) |i| &d.symbols[i] else null;
    const target: ?usize = switch (ctx.kind) {
        .mixin_name => for (d.symbols) |s| {
            if (s.kind == .mixin and std.mem.eql(u8, s.name, word)) break s.name_at;
        } else null,
        .slot_name => if (sym) |s| for (s.slots) |sl| {
            if (std.mem.eql(u8, sl.name, word)) break sl.at;
        } else null else null,
        .when_dim => if (sym) |s| (if (s.dim(word)) |dm| dm.at else null) else null,
        .when_option => if (sym) |s| (if (s.dim(ctx.dim)) |dm| for (dm.options) |o| {
            if (std.mem.eql(u8, o.name, word)) break o.at;
        } else null else null) else null,
        .value => if (sym) |s| (if (s.kind == .mixin) for (s.params) |pr| {
            if (std.mem.eql(u8, pr.name, word)) break pr.at;
        } else null else null) else null,
        else => null,
    };
    const at = target orelse return null;
    return try location(a, uri, text, at, at + word.len);
}

fn yssSymbols(a: Allocator, text: []const u8) !json.Value {
    const symbols = try style.outline(a, text);
    var arr = json.Array.init(a);
    for (symbols) |*s| {
        if (s.name.len == 0) continue;
        var children = json.Array.init(a);
        for (s.dims) |dm| {
            var opts = json.Array.init(a);
            for (dm.options) |o| try opts.append(try docSymbol(a, text, o.name, 22, o.at, o.at + o.name.len, o.at, o.name.len, json.Array.init(a)));
            try children.append(try docSymbol(a, text, dm.name, if (dm.flag) 17 else 10, dm.at, dm.at + dm.name.len, dm.at, dm.name.len, opts));
        }
        for (s.slots) |sl| try children.append(try docSymbol(a, text, sl.name, 8, sl.at, sl.at + sl.name.len, sl.at, sl.name.len, json.Array.init(a)));
        const kind: i64 = switch (s.kind) {
            .recipe => 5,
            .style => 14,
            .mixin => 12,
        };
        try arr.append(try docSymbol(a, text, s.name, kind, s.start, @min(s.end + 1, text.len), s.name_at, s.name.len, children));
    }
    return .{ .array = arr };
}

fn docSymbol(a: Allocator, text: []const u8, name: []const u8, kind: i64, from: usize, to: usize, sel: usize, sel_len: usize, children: json.Array) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(a, "name", .{ .string = name });
    try o.put(a, "kind", .{ .integer = kind });
    try o.put(a, "range", try rangeValue(a, text, from, to));
    try o.put(a, "selectionRange", try rangeValue(a, text, sel, sel + sel_len));
    if (children.items.len != 0) try o.put(a, "children", .{ .array = children });
    return .{ .object = o };
}

/// `file://` URI -> local path (decode percent); not file URI null
fn uriToPath(a: Allocator, uri: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    const raw = try a.dupe(u8, uri["file://".len..]);
    return std.Uri.percentDecodeInPlace(raw);
}

/// Local path -> `file://` URI (with editor: keep `/` + RFC 3986 unreserved, else percent-encode)
fn pathToUri(a: Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '.' or ch == '_' or ch == '~') {
            try out.append(a, ch);
        } else try compiler.style.list_writer.init(a, &out).print("%{X:0>2}", .{ch});
    }
    return out.items;
}

test "file URIs round-trip with spaces and non-ASCII paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "/tmp/a b/组件/styles.yss";
    const uri = try pathToUri(a, path);
    try std.testing.expect(std.mem.indexOfScalar(u8, uri, ' ') == null);
    try std.testing.expectEqualStrings(path, (try uriToPath(a, uri)).?);
    try std.testing.expect(try uriToPath(a, "untitled:x") == null);
}

test "build-on-save concurrently drains both child output pipes" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "/bin/sh", "-c", "i=0; while [ \"$i\" -lt 5000 ]; do printf '0123456789abcdef'; printf 'fedcba9876543210' >&2; i=$((i+1)); done" };
    var server: Server = .{
        .io = std.testing.io,
        .gpa = a,
        .stdout = undefined,
        .zls_in = undefined,
        .build = .{ .argv = &argv, .root = @constCast(".") },
    };
    const output = try server.runBuild();
    defer a.free(output);
    try std.testing.expectEqual(@as(usize, 80_000), output.len);
    try std.testing.expect(std.mem.startsWith(u8, output, "fedcba9876543210"));
    try std.testing.expectEqual(@as(?std.process.Child.Id, null), server.build.child_pid);
}

test "stopBuild terminates and joins a live build process" {
    const argv = [_][]const u8{ "/bin/sh", "-c", "exec sleep 60" };
    var server: Server = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .stdout = undefined,
        .zls_in = undefined,
        .build = .{ .argv = &argv, .root = @constCast(".") },
    };
    server.mutex.lockUncancelable(server.io);
    server.scheduleBuild();
    server.mutex.unlock(server.io);
    defer server.stopBuild();
    var live = false;
    for (0..200) |_| {
        server.mutex.lockUncancelable(server.io);
        live = server.build.child_pid != null;
        server.mutex.unlock(server.io);
        if (live) break;
        try std.Io.sleep(server.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(live);
    server.stopBuild();
    try std.testing.expectEqual(@as(?std.process.Child.Id, null), server.build.child_pid);
    try std.testing.expect(server.build.thread == null);
    try std.testing.expect(!server.build.running);
}

test "framer treats streaming EOF as clean disconnect" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    const file = try tmp.dir.openFile(io, "empty", .{});
    defer file.close(io);
    var framer: Framer = .{ .io = io, .file = file };
    defer framer.buf.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?[]u8, null), try framer.next(std.testing.allocator));
}

test "stopBuild retains a live child after both output pipes close" {
    const argv = [_][]const u8{ "/bin/sh", "-c", "sleep 0.1; exec 1>&- 2>&-; exec sleep 2" };
    var server: Server = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .stdout = undefined,
        .zls_in = undefined,
        .build = .{ .argv = &argv, .root = @constCast(".") },
    };
    server.mutex.lockUncancelable(server.io);
    server.scheduleBuild();
    server.mutex.unlock(server.io);
    defer server.stopBuild();
    // The child has closed both pipes but must remain registered until reaped.
    try std.Io.sleep(server.io, .fromMilliseconds(300), .awake);
    server.mutex.lockUncancelable(server.io);
    const still_registered = server.build.child_pid != null;
    server.mutex.unlock(server.io);
    try std.testing.expect(still_registered);
    const start = std.Io.Clock.awake.now(server.io);
    server.stopBuild();
    const elapsed = start.durationTo(std.Io.Clock.awake.now(server.io));
    try std.testing.expect(elapsed.toMilliseconds() < 1000);
    try std.testing.expect(server.build.thread == null);
    try std.testing.expectEqual(@as(?std.process.Child.Id, null), server.build.child_pid);
}
