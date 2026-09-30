/// FileUpload — 文件选择区（B5）
///
/// 文件对话框：
///   - `on_browse` 未提供时，"Browse…" 默认走原生 NSOpenPanel
///     （`cx.openFilePanel`，system_sdk `file_dialog` capability；headless/无
///     SDK 环境下静默 no-op）。注意 runModal 同步阻塞帧循环。
///   - `on_browse` 提供时优先（宿主自行调起对话框/自定义来源，用
///     `state.addFile(path)` 程序化回填）——e2e/storybook 走此路径。
///   - 文件列表行 + × 移除
/// 拖放：提示区即 drop target —— 从 Finder 拖文件进来会逐条 addFile，
/// 悬停期间换边框/底色高亮。窗口内元素互拖（reorder）仍不支持。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Padding = core.Padding;
const Color = core.Color;
const theme = core.theme;
const Scope = @import("../../reactive.zig").Scope;
const button_mod = @import("../button/mod.zig");
const styles = @import("styles.zig");
const DeferredEntry = @import("../../reactive/deferred_disposal.zig").Entry;

pub const FileUploadProps = struct {
    width: f32 = 360,
    max_files: usize = 8,
    hint: []const u8 = "Click Browse to add files",
    /// Browse 按钮回调（宿主调起对话框后用 state.addFile 回填）。
    /// null = 默认原生 NSOpenPanel（cx.openFilePanel）。
    on_browse: ?core.HandlerRef = null,
    /// 文件列表变化回调
    on_change: ?core.HandlerRef = null,
};

const FileEntry = struct {
    path: []u8,
    row_node: *Node,
    /// false = 已移除但 path 仍归 state（仅延迟释放分配失败时的降级路径：槽不复用，
    /// path 在 scope cleanup 释放）。正常移除把槽置 null 供复用。
    active: bool = true,
};

const RemoveCtx = struct {
    state: *FileUploadState,
    slot: usize,
};

/// 移除后释放 path：行节点的 TextProps / a11y label 仍借用这段字节，而 freeNode 在
/// reactive / tick 深度里只是排队 —— 必须排进与 freeNode 同一条延迟队列，节点在前、path 在后。
const DeferredBytes = struct {
    entry: DeferredEntry = .{},
    alloc: Allocator,
    bytes: []u8,

    fn dispose(ptr: *anyopaque) void {
        const d: *DeferredBytes = @ptrCast(@alignCast(ptr));
        d.alloc.free(d.bytes);
        d.alloc.destroy(d);
    }

    /// 紧跟在对应的 freeNode 之后调用。分配失败返回 false（调用方保留所有权）。
    fn freeAfterNode(cx: *Cx, alloc: Allocator, bytes: []u8) bool {
        const d = alloc.create(DeferredBytes) catch return false;
        d.* = .{ .alloc = alloc, .bytes = bytes };
        cx.deferDisposalLikeFreeNode(&d.entry, @ptrCast(d), dispose);
        return true;
    }
};

pub const FileUploadState = struct {
    alloc: Allocator,
    cx: *Cx,
    files: [32]?FileEntry = [_]?FileEntry{null} ** 32,
    remove_ctxs: [32]RemoveCtx = undefined,
    count: usize = 0,
    max_files: usize,
    list: *Node,
    /// 提示区 = drop target，悬停时改边框/底色
    drop_zone: *Node,
    drop_hover: bool = false,
    on_change: ?core.HandlerRef = null,

    pub fn fileCount(self: *const FileUploadState) usize {
        return self.count;
    }

    /// 拖放悬停高亮：换 drop_zone 的边框/底色。
    pub fn setDropHover(self: *FileUploadState, active: bool) void {
        if (self.drop_hover == active) return;
        self.drop_hover = active;
        const colors = styles.dropZoneColors(active, self.cx.tokens);
        self.drop_zone.setBackground(colors.bg);
        self.drop_zone.setBorderColor(colors.border);
    }

    /// 程序化添加文件（拷贝 path）。超上限 no-op。
    pub fn addFile(self: *FileUploadState, path: []const u8) !void {
        if (path.len == 0 or self.count >= self.max_files) return;
        const slot = blk: {
            for (&self.files, 0..) |*s, i| {
                if (s.* == null) break :blk i;
            }
            return;
        };
        const t = self.cx.tokens;
        const copy = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(copy);

        // 文件名（basename）展示，完整路径悬浮可加 tooltip（后续）
        const base = std.fs.path.basename(copy);

        const row = try box(self.cx, styles.fileRowStyle(t), .{});
        row.behavior.interaction.a11y = .{ .role = .listitem, .label = base };
        const name_node = try box(self.cx, .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} } }, .{});
        var name_txt = styles.fileNameTextStyle(t);
        name_txt.content = base;
        name_node.setText(name_txt);
        try row.appendChild(self.alloc, name_node);

        const close = try box(self.cx, styles.removeBtnStyle(t), .{});
        close.style.cursor = .pointer;
        // 子树文本是字面量 "x"，靠 fallback 会被读成字母 x。给出文件名让
        // AT 用户知道自己要移除的是哪一个。
        close.behavior.interaction.a11y = .{ .role = .button, .label = "Remove file" };
        const x_node = try box(self.cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{});
        var x_txt = styles.removeGlyphTextStyle(t);
        x_txt.content = "x";
        x_node.setText(x_txt);
        try close.appendChild(self.alloc, x_node);
        self.remove_ctxs[slot] = .{ .state = self, .slot = slot };
        close.behavior.events.on_click = .{ .callback = onRemoveClick, .context = @ptrCast(&self.remove_ctxs[slot]) };
        try row.appendChild(self.alloc, close);

        try self.list.appendChild(self.alloc, row);
        self.files[slot] = .{ .path = copy, .row_node = row };
        self.count += 1;
        self.list.markLayoutDirty();
        if (self.on_change) |h| h.invoke();
    }

    pub fn removeSlot(self: *FileUploadState, slot: usize) void {
        if (self.files[slot]) |*e| {
            if (!e.active) return;
            self.list.removeChild(e.row_node);
            self.cx.freeNode(e.row_node);
            if (DeferredBytes.freeAfterNode(self.cx, self.alloc, e.path)) {
                self.files[slot] = null; // 槽可复用（此前永不复用，32 次 add 后静默丢文件）
            } else {
                e.active = false;
            }
            if (self.count > 0) self.count -= 1;
            self.list.markLayoutDirty();
            if (self.on_change) |h| h.invoke();
        }
    }
};

fn onRemoveClick(ctx: *anyopaque) void {
    const c: *RemoveCtx = @ptrCast(@alignCast(ctx));
    c.state.removeSlot(c.slot);
}

/// 默认 Browse：原生打开文件面板 → addFile 回填。
/// 无 SDK / 不支持 / 取消 / 出错时 no-op。
fn onNativeBrowse(ctx: *anyopaque) void {
    const state: *FileUploadState = @ptrCast(@alignCast(ctx));
    var path_buf: [1024]u8 = undefined;
    const path = core.platform_services.openFilePanel(state.cx.system_sdk, &path_buf) orelse return;
    // 用户已经在原生面板里明确选了文件：失败静默 no-op 会让文件凭空不出现，
    // 与「取消选择」无法区分（取消走上面的 orelse return）。回调无法传播 → panic。
    state.addFile(path) catch @panic("OOM: FileUpload 无法添加原生面板选中的文件");
}

/// 从 Finder 拖入：paths 是换行分隔的路径列表，逐条 addFile。
/// 超 max_files 的部分由 addFile 自身 no-op 吃掉。
fn onDropFiles(self: *FileUploadState, paths: []const u8) void {
    self.setDropHover(false);
    if (paths.len == 0) return;
    var it = std.mem.splitScalar(u8, paths, '\n');
    while (it.next()) |p| {
        const trimmed = std.mem.trim(u8, p, " \t\r");
        if (trimmed.len == 0) continue;
        // 超 max_files 是 addFile 内部的 `return`（非 error），不受这里影响；
        // 能到这里的只有分配失败，吞掉会让拖入的文件静默消失。
        self.addFile(trimmed) catch @panic("OOM: FileUpload 无法添加拖入的文件");
    }
}

fn onDropEnter(self: *FileUploadState) void {
    self.setDropHover(true);
}

fn onDropLeave(self: *FileUploadState) void {
    self.setDropHover(false);
}

pub const FileUploadMount = struct {
    wrapper: *Node,
    state: *FileUploadState,
};

pub fn mountFileUpload(props: FileUploadProps, scope: *Scope, cx: *Cx) !FileUploadMount {
    const my_scope = try scope.childScope();
    const allocator = cx.allocator;
    const t = cx.tokens;

    const state = try my_scope.allocator.create(FileUploadState);
    // sweep：adoptResource 失败当场跑 cleanup、之后任何一步失败也会经 scope 级联跑到它，
    // 而 cleanup 会遍历 files 释放 path —— state 此刻还没初始化（0xaa），必须先把 files 清空。
    state.files = [_]?FileEntry{null} ** 32;
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            const s: *FileUploadState = @ptrCast(@alignCast(ptr));
            for (&s.files) |*maybe| {
                if (maybe.*) |e| {
                    alloc.free(e.path);
                    maybe.* = null;
                }
            }
            alloc.destroy(s);
        }
    }.cleanup);

    const wrapper = try box(cx, styles.wrapperStyle(props.width), .{});
    wrapper.meta.ownership.meta.component_name = "FileUpload";
    // sweep：wrapper 守到 return（连带 dispose 绑上的 my_scope）；子节点建好即 adopt
    errdefer cx.freeNode(wrapper);
    try core.bindScopeToNode(my_scope, wrapper);
    // role=group + label：把"提示文字 + Browse 按钮 + 已选文件列表"绑成一个
    // 有名字的整体。否则 AT 用户 tab 到 Browse 按钮时，完全不知道它属于
    // 哪个上传控件，也听不到 hint 里写的格式/大小限制。
    wrapper.behavior.interaction.a11y = .{
        .role = .group,
        .label = "File upload",
        .description = props.hint,
    };

    // 提示区 + Browse 按钮
    const drop_zone = try core.adoptChild(cx, allocator, wrapper, try box(cx, styles.dropZoneStyle(t), .{}));
    const hint_node = try core.adoptChild(cx, allocator, drop_zone, try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{}));
    var hint_txt = styles.hintTextStyle(t);
    hint_txt.content = props.hint;
    hint_node.setText(hint_txt);

    const browse_btn = try button_mod.Button(.{
        .label = "Browse…",
        .variant = .secondary,
        .size = .sm,
        .on_click = props.on_browse orelse core.HandlerRef{ .callback = onNativeBrowse, .context = @ptrCast(state) },
    }).mount(my_scope, cx);
    _ = try core.adoptChild(cx, allocator, drop_zone, browse_btn);

    // 文件列表
    const list = try core.adoptChild(cx, allocator, wrapper, try box(cx, styles.listStyle(t), .{}));
    // 已选文件是一份列表，role=list 让 AT 播报"共 N 项"。
    list.behavior.interaction.a11y = .{ .role = .list, .label = "Selected files" };

    state.* = .{
        .alloc = my_scope.allocator,
        .cx = cx,
        .max_files = props.max_files,
        .list = list,
        .drop_zone = drop_zone,
        .on_change = props.on_change,
    };

    // 从 Finder 拖文件进提示区即添加（点击 Browse 之外的第二条入口）。
    // 必须在 state.* 初始化之后挂：handler 捕获的是 state 指针。
    drop_zone.behavior.events.on_drag_enter =
        core.Cx.handlerFrom(FileUploadState, state, onDropEnter);
    drop_zone.behavior.events.on_drag_leave =
        core.Cx.handlerFrom(FileUploadState, state, onDropLeave);
    drop_zone.behavior.events.on_drop =
        core.Cx.strHandlerFrom(FileUploadState, state, onDropFiles);

    return .{ .wrapper = wrapper, .state = state };
}

// ============================================================================

test "FileUpload: addFile/removeSlot + max_files" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const fu = try mountFileUpload(.{ .max_files = 2 }, scope, cx);
    try root.appendChild(testing.allocator, fu.wrapper);

    try fu.state.addFile("/tmp/a.txt");
    try fu.state.addFile("/tmp/b.txt");
    try fu.state.addFile("/tmp/c.txt"); // 超上限 no-op
    try testing.expectEqual(@as(usize, 2), fu.state.fileCount());

    fu.state.removeSlot(0);
    try testing.expectEqual(@as(usize, 1), fu.state.fileCount());
    fu.state.removeSlot(0); // 重复移除 no-op
    try testing.expectEqual(@as(usize, 1), fu.state.fileCount());
}

test "FileUpload: 移除后槽位复用，增删超过 32 次仍能添加" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const fu = try mountFileUpload(.{}, scope, cx);
    try root.appendChild(testing.allocator, fu.wrapper);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try fu.state.addFile("/tmp/a.txt");
        try testing.expectEqual(@as(usize, 1), fu.state.fileCount());
        fu.state.removeSlot(0);
        try testing.expectEqual(@as(usize, 0), fu.state.fileCount());
    }
}

test "FileUpload: 拖入多行路径逐条添加 + 悬停高亮复位" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const fu = try mountFileUpload(.{ .max_files = 2 }, scope, cx);
    try root.appendChild(testing.allocator, fu.wrapper);

    // drop_zone 必须真的是 drop target（挂了 handler）
    try testing.expect(fu.state.drop_zone.behavior.events.on_drop != null);

    fu.state.setDropHover(true);
    try testing.expect(fu.state.drop_hover);

    // 换行分隔 + 空行 + 超上限一并验证
    fu.state.drop_zone.behavior.events.on_drop.?.invokeWithStr("/tmp/a.txt\n\n/tmp/b.txt\n/tmp/c.txt");
    try testing.expectEqual(@as(usize, 2), fu.state.fileCount());
    // drop 后高亮必须复位，否则拖完一直亮着
    try testing.expect(!fu.state.drop_hover);
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "file_upload: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("file_upload", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try mountFileUpload(.{ .max_files = 2 }, scope, cx)).wrapper;
        }
    }.m);
}
