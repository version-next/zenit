//! DevTools "goto source": resolve a node's `component_name` to a source
//! location and open it in an external editor.
//!
//! The name->location table is produced offline by `tools/gen_component_index.zig`
//! (AST scan of `component_name = "..."` assignments); see that file for why the
//! locations are scanned rather than captured with `@src()`.
//!
//! Two tables are consulted: zenit's own (compiled in) and, optionally, one
//! registered by the host app for its components. Paths in both are relative to
//! their respective source roots, which the app supplies at runtime via
//! `configure`, a built binary has no idea where its sources live.
const std = @import("std");
const builtin = @import("builtin");

const framework_index = @import("../component_index_generated.zig");

pub const Entry = framework_index.Entry;

/// A generated index plus the absolute path its entries are relative to.
pub const IndexSource = struct {
    entries: []const Entry,
    /// Absolute path of the source root; entry `file`s are joined onto it.
    root: []const u8,
};

pub const Resolved = struct {
    /// Absolute path on disk.
    file: []const u8,
    line: u32,
    col: u32,
    label: []const u8,
};

/// Editor launch command. `{file}`, `{line}`, `{col}` are substituted.
pub const EditorCommand = []const []const u8;

/// VS Code / Cursor style: `code --goto path:line:col`.
pub const default_editor: EditorCommand = &.{ "code", "--goto", "{file}:{line}:{col}" };

var g_framework_root: ?[]const u8 = null;
var g_app: ?IndexSource = null;
var g_editor: EditorCommand = default_editor;

/// Point the resolver at on-disk sources. Call once at startup from an app that
/// wants goto-source; without it nothing resolves and DevTools shows no button.
///
/// `framework_root` is the absolute path of the zenit checkout (entries are
/// relative to it); pass null if zenit's sources are not available locally.
/// `app` is the host app's generated index, if it has one.
pub fn configure(opts: struct {
    framework_root: ?[]const u8 = null,
    app: ?IndexSource = null,
    editor: ?EditorCommand = null,
}) void {
    g_framework_root = opts.framework_root;
    g_app = opts.app;
    if (opts.editor) |e| g_editor = e;

    // findIn 是二分查找，app 自供索引若未按 name 排序会**静默 miss**
    // （最终 eql 校验保证不会错配，但查不到 = goto 按钮直接不显示，
    // 极难排查）。Debug 构建下把契约断死在 configure 现场。
    if (builtin.mode == .Debug) {
        if (opts.app) |app| {
            var i: usize = 1;
            while (i < app.entries.len) : (i += 1) {
                std.debug.assert(!std.mem.lessThan(u8, app.entries[i].name, app.entries[i - 1].name));
            }
        }
    }
}

/// True if any index is usable, DevTools uses this to decide whether to render
/// the goto affordance at all.
pub fn isConfigured() bool {
    return g_framework_root != null or g_app != null;
}

/// Runtime-address goto-source requires executable debug info. This is a cheap
/// render-time gate; the actual DWARF lookup still happens lazily on click.
pub fn addressResolutionAvailable() bool {
    return !builtin.strip_debug_info;
}

/// Look up `name`, preferring the app's own components over the framework's:
/// when an app names a component the same as a built-in, the app's is what the
/// developer means.
///
/// Returns a location whose `file` is owned by the caller.
pub fn resolve(alloc: std.mem.Allocator, name: []const u8) !?Resolved {
    if (g_app) |app| {
        if (findIn(app.entries, name)) |e| return try join(alloc, app.root, e);
    }
    if (g_framework_root) |root| {
        if (findIn(&framework_index.entries, name)) |e| return try join(alloc, root, e);
    }
    return null;
}

/// Whether `name` resolves, without allocating. Used to decide if the
/// goto affordance is worth rendering at all.
pub fn has(name: []const u8) bool {
    if (g_app) |app| {
        if (findIn(app.entries, name) != null) return true;
    }
    if (g_framework_root != null) {
        if (findIn(&framework_index.entries, name) != null) return true;
    }
    return false;
}

/// 把运行时代码地址解析成源码位置。styled 来源传函数入口地址；inline
/// builder / setStyle 传返回地址，后者减 1 后再查，避免 DWARF 把它归到调用
/// 之后的下一条语句。
///
/// 解析只发生在用户点击 DevTools 的 `↗` 时，不进入渲染/样式写入热路径。
/// Release strip debug info、dSYM 不可用或地址来自外部动态库时返回 null。
pub fn resolveAddress(alloc: std.mem.Allocator, address: usize, is_return_address: bool) !?Resolved {
    if (builtin.strip_debug_info or address == 0) return null;
    const lookup_address = if (is_return_address and address > 0) address - 1 else address;
    const debug_info = std.debug.getSelfDebugInfo() catch return null;
    const module = debug_info.getModuleForAddress(lookup_address) catch return null;
    // SelfDebugInfo/Module 会把 DWARF/object 数据进程级缓存，allocator 也必须
    // 活到进程结束；绝不能传 DevTools Cx allocator（窗口关掉后缓存会悬空）。
    const debug_alloc = std.heap.page_allocator;
    const symbol = module.getSymbolAtAddress(debug_alloc, lookup_address) catch return null;
    const sl = symbol.source_location orelse return null;
    defer debug_alloc.free(sl.file_name);

    const file = try normalizeDebugPath(alloc, sl.file_name);
    return .{
        .file = file,
        .line = std.math.cast(u32, sl.line) orelse std.math.maxInt(u32),
        .col = std.math.cast(u32, sl.column) orelse 1,
        .label = "debug-info",
    };
}

fn normalizeDebugPath(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(raw)) return std.fs.path.resolve(alloc, &.{raw});

    // `zig build` 常把相对源码路径写进 DWARF。先尊重进程 cwd（命令行运行），
    // 再尝试宿主 app 与 zenit 的已配置 source root（Finder 启动时 cwd 往往是 /）。
    if (pathExists(raw)) return std.fs.path.resolve(alloc, &.{raw});
    if (g_app) |app| {
        const candidate = try std.fs.path.join(alloc, &.{ app.root, raw });
        if (pathExists(candidate)) return candidate;
        alloc.free(candidate);
    }
    if (g_framework_root) |root| {
        const candidate = try std.fs.path.join(alloc, &.{ root, raw });
        if (pathExists(candidate)) return candidate;
        alloc.free(candidate);
    }

    // 保留一个可诊断的 fallback；编辑器会相对自身 cwd 处理它。
    return alloc.dupe(u8, raw);
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn join(alloc: std.mem.Allocator, root: []const u8, e: Entry) !Resolved {
    const raw = try std.fs.path.join(alloc, &.{ root, e.file });
    // A build-time root can be relative-ish ("…/app/../zenit/./src"),
    // which works but is what the user sees in their editor's title bar.
    const resolved = std.fs.path.resolve(alloc, &.{raw}) catch return .{
        .file = raw,
        .line = e.line,
        .col = e.col,
        .label = e.label,
    };
    alloc.free(raw);
    return .{
        .file = resolved,
        .line = e.line,
        .col = e.col,
        .label = e.label,
    };
}

/// Binary search over a name-sorted index.
fn findIn(entries: []const Entry, name: []const u8) ?Entry {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.lessThan(u8, entries[mid].name, name)) lo = mid + 1 else hi = mid;
    }
    if (lo < entries.len and std.mem.eql(u8, entries[lo].name, name)) return entries[lo];
    return null;
}

/// Launch the configured editor on `loc`.
///
/// The launcher is *not* waited on: `code --goto` is a Node.js wrapper that
/// takes ~1.1s even when VS Code is already running, and this is called from a
/// click handler on the UI thread. Instead we double-fork, the intermediate
/// child is reaped immediately and the grandchild that execs the editor is
/// re-parented to init, so it neither blocks us nor lingers as a zombie.
pub fn open(alloc: std.mem.Allocator, loc: Resolved) !void {
    // ⚠ fork 纪律：这是个多线程 GUI 进程（CVDisplayLink/render 线程常驻），
    // fork 出的子进程里只允许 async-signal-safe 调用，任何堆分配都可能
    // 死锁在别的线程 fork 瞬间持有的 malloc 锁上，触碰 ObjC/CF 会直接
    // abort（objc_initializeAfterForkError）。所以 argv 的展开、C 字符串
    // 化全部在 fork **之前**完成，孙进程只做 setsid + execvpe。
    var argv = std.ArrayList([]const u8){};
    defer {
        for (argv.items) |a| alloc.free(a);
        argv.deinit(alloc);
    }
    for (g_editor) |part| {
        try argv.append(alloc, try expand(alloc, part, loc));
    }
    if (argv.items.len == 0) return error.EmptyEditorCommand;

    var argv_z_owned = std.ArrayList([:0]const u8){};
    defer {
        for (argv_z_owned.items) |s| alloc.free(s);
        argv_z_owned.deinit(alloc);
    }
    const argv_z = try alloc.allocSentinel(?[*:0]const u8, argv.items.len, null);
    defer alloc.free(argv_z);
    for (argv.items, 0..) |a, i| {
        const z = try alloc.dupeZ(u8, a);
        try argv_z_owned.append(alloc, z);
        argv_z[i] = z.ptr;
    }
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

    // Double-fork：中间子进程立刻退出（下面的 waitpid 即刻返回），
    // exec 编辑器的孙进程被 init 收养，既不阻塞 UI 线程也不留僵尸。
    const pid = try std.posix.fork();
    if (pid == 0) {
        const inner = std.posix.fork() catch std.c._exit(1);
        if (inner == 0) {
            // 脱离 GUI 进程的会话/进程组，编辑器 launcher 的生死与 app 无关。
            _ = std.posix.setsid() catch {};
            std.posix.execvpeZ(argv_z[0].?, argv_z.ptr, envp) catch {};
            std.c._exit(1);
        }
        // _exit 而非 exit：libc exit 会跑 atexit/flush stdio，
        // 在 fork 子进程里同样不是 async-signal-safe。
        std.c._exit(0);
    }
    _ = std.posix.waitpid(pid, 0);
}

fn expand(alloc: std.mem.Allocator, template: []const u8, loc: Resolved) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    var rest = template;
    while (rest.len > 0) {
        const open_i = std.mem.indexOfScalar(u8, rest, '{') orelse {
            try out.writer.writeAll(rest);
            break;
        };
        try out.writer.writeAll(rest[0..open_i]);
        const close_i = std.mem.indexOfScalarPos(u8, rest, open_i, '}') orelse {
            try out.writer.writeAll(rest[open_i..]);
            break;
        };
        const key = rest[open_i + 1 .. close_i];
        if (std.mem.eql(u8, key, "file")) {
            try out.writer.writeAll(loc.file);
        } else if (std.mem.eql(u8, key, "line")) {
            try out.writer.print("{d}", .{loc.line});
        } else if (std.mem.eql(u8, key, "col")) {
            try out.writer.print("{d}", .{loc.col});
        } else {
            // Unknown placeholder: emit verbatim so a literal brace survives.
            try out.writer.writeAll(rest[open_i .. close_i + 1]);
        }
        rest = rest[close_i + 1 ..];
    }
    return out.toOwnedSlice();
}

test "expand substitutes placeholders" {
    const loc: Resolved = .{ .file = "/a/b.zig", .line = 42, .col = 7, .label = "app" };
    const got = try expand(std.testing.allocator, "{file}:{line}:{col}", loc);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/a/b.zig:42:7", got);
}

test "expand leaves unknown placeholders alone" {
    const loc: Resolved = .{ .file = "/a/b.zig", .line = 1, .col = 1, .label = "app" };
    const got = try expand(std.testing.allocator, "x{nope}y{line}", loc);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("x{nope}y1", got);
}

noinline fn sourceAddressProbe() void {}

test "resolveAddress symbolizes a styled function entry" {
    if (!addressResolutionAvailable()) return;
    const loc = try resolveAddress(std.testing.allocator, @intFromPtr(&sourceAddressProbe), false);
    const resolved = loc orelse return error.MissingDebugInfo;
    defer std.testing.allocator.free(resolved.file);
    try std.testing.expectEqualStrings("source_link.zig", std.fs.path.basename(resolved.file));
    try std.testing.expect(resolved.line > 0);
}

test "findIn locates entries and rejects misses" {
    const entries = [_]Entry{
        .{ .name = "Alpha", .file = "a.zig", .line = 1, .col = 1, .label = "t" },
        .{ .name = "Beta", .file = "b.zig", .line = 2, .col = 1, .label = "t" },
        .{ .name = "Gamma", .file = "c.zig", .line = 3, .col = 1, .label = "t" },
    };
    try std.testing.expectEqual(@as(u32, 2), findIn(&entries, "Beta").?.line);
    try std.testing.expectEqual(@as(u32, 1), findIn(&entries, "Alpha").?.line);
    try std.testing.expectEqual(@as(u32, 3), findIn(&entries, "Gamma").?.line);
    try std.testing.expect(findIn(&entries, "Delta") == null);
    try std.testing.expect(findIn(&entries, "Zzz") == null);
    try std.testing.expect(findIn(&.{}, "Alpha") == null);
}

test "framework index is sorted so binary search is valid" {
    for (framework_index.entries[1..], 0..) |e, i| {
        try std.testing.expect(!std.mem.lessThan(u8, e.name, framework_index.entries[i].name));
    }
}
