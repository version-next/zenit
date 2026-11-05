/// FileUpload: file select area.
///
/// Data: `files: Model([]const []const u8)` (full paths). `*Signal` must be created via
/// `scope.createList([]const u8, ...)` (path bytes copied by signal).
/// File rows rebuild with `files`; Browse / drag / delete only propose a new path list.
///
/// File dialog:
///   - without `on_browse`, 'Browse...' uses native NSOpenPanel
///     (`cx.openFilePanel`, system_sdk `file_dialog` capability; no-op when headless/no SDK).
///     runModal blocks the frame loop synchronously.
///   - `on_browse` takes priority (host invokes dialog/custom source); host fills via
///     `result.add(path)` (same proposal pipeline), or writes its own files signal.
/// Drag-drop: hint zone is the drop target; files dragged from Finder are added one by one;
/// hover highlights border/background. Intra-window drag (reorder) not supported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const bind_mod = @import("../../bind.zig");
const button_mod = @import("../button/mod.zig");
const styles = @import("styles.zig");
const icons = @import("zenit_system_icons");

pub const FileUploadProps = struct {
    width: f32 = 360,
    /// Max files to retain (exceeding adds discarded)
    max_files: usize = 8,
    /// Hint text (also a11y description for entire group)
    hint: Source([]const u8) = .{ .value = "Click Browse to add files" },
    /// Selected file full paths
    files: Model([]const []const u8) = .{ .local = &.{} },
    /// Called after user adds / removes and lands (landed value). Same list as split parent sees,
    /// valid only during this sync call (elements may point to event buffer); to keep, write to
    /// owned signal or copy on-site
    on_change: ?Handler([]const []const u8) = null,
    /// Custom Browse (host fills via `result.add(path)`); null = native NSOpenPanel
    on_browse: ?Handler(void) = null,
};

/// Create FileUpload: `W.FileUpload(.{ .files = picked, .max_files = 4 }).mount(scope, cx)`
pub fn FileUpload(props: anytype) FileUploadBuilder {
    return .{ .props = reactive.props.coerce(FileUploadProps, props) };
}

pub const FileUploadBuilder = struct {
    props: FileUploadProps,

    pub fn mount(self: FileUploadBuilder, scope: *Scope, cx: *Cx) !FileUploadResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        return mountImpl(self.props, scope, cx);
    }
};

pub const FileUploadResult = struct {
    wrapper: *Node,
    /// Files list signal (`ui.split` when null)
    files: ?*Signal([]const []const u8),
    /// Hint zone (drop target)
    drop_zone: *Node,
    browse_button: *Node,
    rt: *FileUploadRuntime,

    /// Programmatically add one file (custom Browse fill): same proposal pipeline as drag
    pub fn add(self: FileUploadResult, path: []const u8) void {
        self.rt.addPaths(&.{path});
    }
    /// `ui.view` entry (see src/ui/view_parts.zig).
    pub fn viewParts(self: FileUploadResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

/// Runtime (scope-owned). View = f(files): rows rebuild via `ui.rebuildOn` when files changes.
pub const FileUploadRuntime = struct {
    cx: *Cx,
    files: reactive.Bound([]const []const u8),
    on_change: ?Handler([]const []const u8),
    max_files: usize,
    list: *Node,
    /// Hint zone = drop target, hover changes border/background
    drop_zone: *Node,
    drop_hover: bool = false,

    pub fn fileCount(self: *const FileUploadRuntime) usize {
        return self.files.peek().len;
    }

    /// Drag-drop hover highlight: swap drop_zone border/background.
    pub fn setDropHover(self: *FileUploadRuntime, active: bool) void {
        if (self.drop_hover == active) return;
        self.drop_hover = active;
        const colors = styles.dropZoneColors(active, self.cx.tokens);
        self.drop_zone.setBackground(colors.bg);
        self.drop_zone.setBorderColor(colors.border);
    }

    /// Propose current list + paths (skip empty paths, discard over max_files)
    pub fn addPaths(self: *FileUploadRuntime, paths: []const []const u8) void {
        const cur = self.files.peek();
        var n_new: usize = 0;
        for (paths) |p| {
            if (p.len > 0) n_new += 1;
        }
        if (n_new == 0 or cur.len >= self.max_files) return;
        const total = @min(cur.len + n_new, self.max_files);
        const buf = self.cx.allocator.alloc([]const u8, total) catch |err| {
            std.log.err("[FileUpload] add failed: {}", .{err});
            return;
        };
        defer self.cx.allocator.free(buf);
        @memcpy(buf[0..cur.len], cur);
        var n = cur.len;
        for (paths) |p| {
            if (p.len == 0) continue;
            if (n >= total) break;
            buf[n] = p;
            n += 1;
        }
        self.propose(buf[0..n]);
    }

    /// Propose removing file at index
    pub fn removeAt(self: *FileUploadRuntime, index: usize) void {
        const cur = self.files.peek();
        if (index >= cur.len) return;
        const buf = self.cx.allocator.alloc([]const u8, cur.len - 1) catch |err| {
            std.log.err("[FileUpload] remove failed: {}", .{err});
            return;
        };
        defer self.cx.allocator.free(buf);
        @memcpy(buf[0..index], cur[0..index]);
        @memcpy(buf[index..], cur[index + 1 ..]);
        self.propose(buf);
    }

    fn propose(self: *FileUploadRuntime, v: []const []const u8) void {
        const on_change = self.on_change;
        const landed = self.files.commit(v) orelse return;
        if (on_change) |h| h.call(landed);
    }

    // ---- File rows (ui.rebuildOn) ----

    fn filesKey(files: []const []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&files.len));
        for (files) |f| {
            h.update(std.mem.asBytes(&f.len));
            h.update(f);
        }
        return h.final();
    }

    const RemoveCtx = struct {
        rt: *FileUploadRuntime,
        index: usize,

        fn fire(ptr: *anyopaque) void {
            const c: *RemoveCtx = @ptrCast(@alignCast(ptr));
            c.rt.removeAt(c.index);
        }
    };

    const Ctxs = struct {
        items: []RemoveCtx = &.{},

        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const c: *Ctxs = @ptrCast(@alignCast(ptr));
            alloc.free(c.items);
            alloc.destroy(c);
        }
    };

    fn buildRows(self: *FileUploadRuntime, child: *Scope, list: *Node, files: []const []const u8) !void {
        const cx = self.cx;
        const ctxs = try child.allocator.create(Ctxs);
        ctxs.* = .{};
        try child.adoptResource(@ptrCast(ctxs), Ctxs.destroy);
        ctxs.items = try child.allocator.alloc(RemoveCtx, files.len);
        for (ctxs.items, 0..) |*c, i| c.* = .{ .rt = self, .index = i };
        try view.mount(child, cx, list, view.items(ctxs.items, files, rowElement));
    }

    fn rowElement(ctxs: []RemoveCtx, path: []const u8, i: usize) view.ComponentOf(buildRow) {
        return view.component(buildRow, RowArgs{ .path = path, .remove = &ctxs[i] });
    }

    const RowArgs = struct { path: []const u8, remove: *RemoveCtx };

    fn buildRow(args: RowArgs, scope: *Scope, cx: *Cx) !*Node {
        const t = cx.tokens;
        var name_node: *Node = undefined;
        const row = try view.render(scope, cx, view.box(.{ .style = styles.fileRowStyle(t) }, .{
            view.icon(.{ .style = styles.fileIconStyle, .tint = t.tokens.color.fg_primary }, @import("zenit_icons").file),
            // Filename (basename) fills line remainder (pushes x to line end); text copied into
            // node itself (not borrowed from signal double-buffer)
            view.capture(&name_node, view.attrs(.{ .style = core.BoxStyle{ .width = .{ .grow = .{} } } }, view.text(.{ .style = styles.fileNameTextStyle(t) }, std.fs.path.basename(args.path)))),
            view.box(.{
                .style = .{ styles.removeBtnStyle(t), core.BoxStyle{ .cursor = .pointer } },
                // Subtree text is literal 'x', fallback reads as letter x.
                .a11y = core.A11yProps{ .role = .button, .label = "Remove file" },
                .on_click = core.Cx.simpleHandler(RemoveCtx.fire, args.remove),
            }, view.icon(.{ .style = styles.removeIconStyle, .tint = t.tokens.color.fg_secondary }, icons.close)),
        }));
        // Row a11y name points to node's own text copy
        row.behavior.interaction.a11y = .{ .role = .listitem, .label = name_node.getText().?.content };
        return row;
    }
};

/// Default Browse: native open file panel -> propose add.
/// No SDK / unsupported / cancel: no-op.
fn onNativeBrowse(ptr: *anyopaque) void {
    const rt: *FileUploadRuntime = @ptrCast(@alignCast(ptr));
    var path_buf: [1024]u8 = undefined;
    const path = core.platform_services.openFilePanel(rt.cx.system_sdk, &path_buf) orelse return;
    rt.addPaths(&.{path});
}

/// Drag from Finder: paths are newline-delimited list, propose all at once (empty lines skipped in
/// addPaths)
fn onDropFiles(rt: *FileUploadRuntime, paths: []const u8) void {
    rt.setDropHover(false);
    const a = rt.cx.allocator;
    const list = a.alloc([]const u8, std.mem.count(u8, paths, "\n") + 1) catch |err| {
        std.log.err("[FileUpload] drop failed: {}", .{err});
        return;
    };
    defer a.free(list);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, paths, '\n');
    while (it.next()) |p| : (n += 1) list[n] = std.mem.trim(u8, p, " \t\r");
    rt.addPaths(list[0..n]);
}

fn onDropEnter(rt: *FileUploadRuntime) void {
    rt.setDropHover(true);
}

fn onDropLeave(rt: *FileUploadRuntime) void {
    rt.setDropHover(false);
}

fn mountImpl(props: FileUploadProps, scope: *Scope, cx: *Cx) !FileUploadResult {
    const my_scope = try scope.childScope();
    var scope_bound = false;
    errdefer if (!scope_bound) my_scope.dispose();
    const t = cx.tokens;
    reactive.checkBorrow(my_scope, props.hint);

    // Structure: hint zone (hint text + Browse button) + selected files list
    const Parts = struct { drop_zone: *Node = undefined, hint: *Node = undefined, list: *Node = undefined };
    var parts: Parts = .{};
    const wrapper = try view.render(my_scope, cx, view.box(.{
        .style = styles.wrapperStyle(props.width, t),
        // role=group + label: binds 'hint text + Browse button + file list' as single named unit,
        // so AT users tabbing to Browse know which upload control, hear hint.
        .a11y = .{ .role = .group, .label = "File upload" },
    }, .{
        view.capture(&parts.drop_zone, view.box(.{ .style = styles.dropZoneStyle(t) }, view.capture(&parts.hint, view.text(.{ .style = styles.hintTextStyle(t) }, props.hint.peek())))),
        // Selected files are a list, role=list tells AT 'N items total'.
        view.capture(&parts.list, view.box(.{ .style = styles.listStyle(t), .a11y = .{ .role = .list, .label = "Selected files" } }, {})),
    }));
    wrapper.meta.ownership.meta.component_name = "FileUpload";
    // sweep: wrapper guards to return (carries dispose of bound my_scope)
    errdefer cx.freeNode(wrapper);
    try core.bindScopeToNode(my_scope, wrapper);
    scope_bound = true;

    const files = try reactive.resolveListModel([]const u8, my_scope, props.files);
    const rt = try my_scope.allocator.create(FileUploadRuntime);
    try my_scope.adoptResource(@ptrCast(rt), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            alloc.destroy(@as(*FileUploadRuntime, @ptrCast(@alignCast(ptr))));
        }
    }.destroy);

    const drop_zone = parts.drop_zone;
    const hint_node = parts.hint;
    const list = parts.list;
    // Initial value synced into view.text; changes tracked by binding.
    // Hint text also a11y description for group (points to node's own copy)
    try bind_mod.bindTextA11y(cx, my_scope, props.hint, hint_node, wrapper, .description);

    rt.* = .{
        .cx = cx,
        .files = files,
        .on_change = props.on_change,
        .max_files = props.max_files,
        .list = list,
        .drop_zone = drop_zone,
    };
    wrapper.addDebugState(@ptrCast(rt));

    const browse_btn = button_mod.Button(.{
        .label = "Choose file…",
        .variant = .secondary,
        .size = .sm,
        .on_click = props.on_browse orelse core.Cx.simpleHandler(onNativeBrowse, rt),
    });
    const browse_node = try browse_btn.mount(my_scope, cx);
    // FileUploadResult exposes a snapshot browse_button pointer.
    view.pinComponentRoot(browse_node);
    _ = try core.adoptChild(cx, cx.allocator, drop_zone, browse_node);

    // Drag files into hint zone to add (second entry besides Browse button)
    drop_zone.behavior.events.on_drag_enter = core.Cx.handlerFrom(FileUploadRuntime, rt, onDropEnter);
    drop_zone.behavior.events.on_drag_leave = core.Cx.handlerFrom(FileUploadRuntime, rt, onDropLeave);
    drop_zone.behavior.events.on_drop = core.Cx.strHandlerFrom(FileUploadRuntime, rt, onDropFiles);

    // files is Model: rebuildOn rebuilds with it (local also signal, must have effect)
    try bind_mod.rebuildOn(cx, my_scope, files.read, list, rt, FileUploadRuntime.filesKey, FileUploadRuntime.buildRows);

    return .{ .wrapper = wrapper, .files = files.asSignal(), .drop_zone = drop_zone, .browse_button = browse_node, .rt = rt };
}

// ============================================================================

const testing = std.testing;

fn rowNames(r: FileUploadResult, out: [][]const u8) [][]const u8 {
    for (r.rt.list.children.items, 0..) |row, i| out[i] = row.children.items[1].getText().?.content;
    return out[0..r.rt.list.children.items.len];
}

test "FileUpload: 添加 / 移除只提议；行跟随 files；max_files 截断" {
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Spy = struct {
        n: usize = 0,
        fn f(self: *@This(), _: []const []const u8) void {
            self.n += 1;
        }
    };
    var spy = Spy{};
    const fu = try FileUpload(.{ .max_files = 2, .on_change = cx.on(Spy, &spy, Spy.f) }).mount(scope, cx);
    defer cx.freeNode(fu.wrapper);

    var tmp = "/tmp/a.txt".*;
    fu.add(&tmp);
    tmp[5] = 'Z'; // Caller's temp buffer change has no effect
    fu.add("/tmp/b.txt");
    fu.add("/tmp/c.txt"); // Over limit: no-op
    try testing.expectEqual(@as(usize, 2), fu.rt.fileCount());
    try testing.expectEqualStrings("/tmp/a.txt", fu.files.?.peek()[0]);
    var names: [8][]const u8 = undefined;
    const shown = rowNames(fu, &names);
    try testing.expectEqual(@as(usize, 2), shown.len);
    try testing.expectEqualStrings("a.txt", shown[0]);
    try testing.expectEqualStrings("b.txt", shown[1]);
    try testing.expectEqual(@as(usize, 2), spy.n);

    // Click × on first row
    const close = fu.rt.list.children.items[0].children.items[2];
    close.behavior.events.on_click.?.invoke();
    try testing.expectEqual(@as(usize, 1), fu.rt.fileCount());
    try testing.expectEqualStrings("b.txt", rowNames(fu, &names)[0]);
    try testing.expectEqual(@as(usize, 3), spy.n);
}

test "FileUpload: 增删超过 32 次仍能添加（行随数据重建，不再有固定槽位）" {
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const fu = try FileUpload(.{}).mount(scope, cx);
    defer cx.freeNode(fu.wrapper);
    for (0..40) |_| {
        fu.add("/tmp/a.txt");
        try testing.expectEqual(@as(usize, 1), fu.rt.list.children.items.len);
        fu.rt.removeAt(0);
        try testing.expectEqual(@as(usize, 0), fu.rt.list.children.items.len);
    }
}

test "FileUpload: 拖入多行路径一次添加 + 悬停高亮复位" {
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const fu = try FileUpload(.{ .max_files = 2 }).mount(scope, cx);
    defer cx.freeNode(fu.wrapper);

    // drop_zone really is drop target (has handler)
    try testing.expect(fu.drop_zone.behavior.events.on_drop != null);
    fu.rt.setDropHover(true);
    try testing.expect(fu.rt.drop_hover);
    // Newline separator + empty lines + over limit all verified
    fu.drop_zone.behavior.events.on_drop.?.invokeWithStr("/tmp/a.txt\n\n/tmp/b.txt\n/tmp/c.txt");
    try testing.expectEqual(@as(usize, 2), fu.rt.fileCount());
    // After drop, highlight must reset, else keeps showing after drag
    try testing.expect(!fu.rt.drop_hover);
}

test "FileUpload: 一次拖入超过 64 个路径不丢（max_files 足够时全部添加）" {
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const fu = try FileUpload(.{ .max_files = 100 }).mount(scope, cx);
    defer cx.freeNode(fu.wrapper);
    var buf: [100 * 16]u8 = undefined;
    var w: usize = 0;
    for (0..80) |i| {
        const line = try std.fmt.bufPrint(buf[w..], "/tmp/f{d}.txt\n", .{i});
        w += line.len;
    }
    fu.drop_zone.behavior.events.on_drop.?.invokeWithStr(buf[0..w]);
    try testing.expectEqual(@as(usize, 80), fu.rt.fileCount());
}

test "FileUpload: 外部写入 files 刷新行；ui.split 拒绝时不动；非 createList 的 signal 被拒" {
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const files = try scope.createList([]const u8, &.{"/x/one.png"});
    const fu = try FileUpload(.{ .files = files }).mount(scope, cx);
    defer cx.freeNode(fu.wrapper);
    var names: [8][]const u8 = undefined;
    try testing.expectEqualStrings("one.png", rowNames(fu, &names)[0]);
    files.set(&.{ "/y/two.png", "/y/three.png" });
    try testing.expectEqual(@as(usize, 2), rowNames(fu, &names).len);
    try testing.expectEqualStrings("three.png", rowNames(fu, &names)[1]);

    const Parent = struct {
        sig: *Signal([]const []const u8),
        fn write(_: *@This(), _: []const []const u8) void {}
    };
    var parent = Parent{ .sig = try scope.createList([]const u8, &.{}) };
    const fu2 = try FileUpload(.{ .files = reactive.split(parent.sig, cx.on(Parent, &parent, Parent.write)) }).mount(scope, cx);
    defer cx.freeNode(fu2.wrapper);
    try testing.expect(fu2.files == null);
    fu2.add("/tmp/a.txt");
    try testing.expectEqual(@as(usize, 0), fu2.rt.list.children.items.len);

    const borrowed = try scope.createSignal([]const []const u8, &.{});
    try testing.expectError(error.ListModelNotOwned, FileUpload(.{ .files = borrowed }).mount(scope, cx));
}

test "FileUpload: 动态提示文字同步到整组的无障碍描述" {
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();
    const hint = try scope.createText("PNG only", .{});
    const fu = try FileUpload(.{ .hint = hint }).mount(scope, cx);
    defer cx.freeNode(fu.wrapper);
    try testing.expectEqualStrings("PNG only", fu.wrapper.behavior.interaction.a11y.?.description.?);
    hint.set("PNG or JPEG, up to 5 MB");
    try testing.expectEqualStrings("PNG or JPEG, up to 5 MB", fu.wrapper.behavior.interaction.a11y.?.description.?);
}

// styles.zig test collection, this line required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// Per-alloc OOM sweep, see src/ui/components/oom_sweep.zig
test "file_upload: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("file_upload", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const files = try scope.createList([]const u8, &.{ "/tmp/a.txt", "/tmp/b.txt" });
            return (try FileUpload(.{ .max_files = 2, .files = files }).mount(scope, cx)).wrapper;
        }
    }.m);
}
