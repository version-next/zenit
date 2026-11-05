//! One layout, two host slots: caption controls and application-menu entry.
const std = @import("std");
const ui = @import("ui");
const app = @import("zenit_app");
const v = ui.view;
const W = ui.widgets;
const S = @import("styles.zig");
const M = @import("model.zig");
const Chrome = app.window_chrome;
pub const Props = struct {
    state: *ui.Signal(Chrome.State),
    preview: bool = false,
    radius: f32 = 0,
    menu_bar: *ui.Signal(bool),
    menu_open: *ui.Signal(bool),
    file_open: ?*ui.Signal(bool) = null,
    on_command: ui.Handler([]const u8),
    /// Current project / branch shown in the leading chips; both chips open a menu
    /// whose selection is reported through `on_command` as `project:<name>` and
    /// `branch:<name>` (plus `project-open`, `project-new`, `branch-new`, `branch-sync`).
    project: ?*ui.Signal([]const u8) = null,
    branch: ?*ui.Signal([]const u8) = null,
    test_id: []const u8 = "window.header",
    drag_id: []const u8 = "window.drag",
    control_ids: [3][]const u8 = .{ "window.controls.minimize", "window.controls.maximize", "window.controls.close" },
};
const Context = struct {
    props: Props,
    cx: *ui.Cx,
    fn caption(c: *Context, action: Chrome.Action) void {
        if (!c.props.preview) {
            c.cx.performWindowAction(action) catch {};
            return;
        }
        var state = c.props.state.peek();
        switch (action) {
            .close => state.active = false,
            .minimize => state.active = false,
            .toggle_maximize => state.maximized = !state.maximized,
            .maximize => |value| state.maximized = value,
            .fullscreen => |value| state.fullscreen = value,
        }
        c.props.state.set(state);
    }
    fn command(c: *Context, id: []const u8) void {
        c.props.menu_bar.set(false);
        c.props.on_command.call(id);
    }
    fn project(c: *Context) void {
        c.command("project");
    }
    fn branch(c: *Context) void {
        c.command("branch");
    }
};
fn iconButton(icon: ui.SvgAsset, label: []const u8, handler: ui.Handler(void)) @TypeOf(W.Button(.{})) {
    return W.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = icon, .icon_size = @as(f32, 15), .icon_tint = S.icon_tint, .a11y_label = label, .on_click = handler, .base_style = S.icon_button });
}
pub fn mount(p: Props, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const c = try scope.createState(Context, .{ .props = p, .cx = cx });
    const s = p.state.peek();
    const is_mac = s.appearance == .macos;
    const branch_text = try scope.createMemo(bool, p.state, struct {
        fn read(state: *ui.Signal(Chrome.State)) bool {
            return state.get().width >= 720;
        }
    }.read);
    const full_actions = try scope.createMemo(bool, p.state, struct {
        fn read(state: *ui.Signal(Chrome.State)) bool {
            return state.get().width >= 600;
        }
    }.read);
    const project_width = try scope.createMemo(f32, p.state, struct {
        fn read(state: *ui.Signal(Chrome.State)) f32 {
            const value = state.get();
            const mac = value.appearance == .macos;
            const captions = if (value.controls_owner == .native) @as(f32, 0) else M.captionWidth(value.button_layout, value.appearance);
            const reserve = if (mac) @as(f32, 90) else @as(f32, 42);
            const branch = if (value.width >= 720) @as(f32, 59) else @as(f32, 12);
            const actions = if (value.width >= 600) @as(f32, 108) else @as(f32, 28);
            return @max(24, @min(146, value.width - reserve - captions - branch - actions - 16 - 28 - 160));
        }
    }.read);
    const file_open = p.file_open orelse try scope.createSignal(bool, false);
    // Every item array here carries platform-dependent strings, so it is built at
    // runtime. Menu clones its items at mount and `v.show` re-mounts the menu bar
    // and chips whenever it toggles, so the arrays must outlive this function:
    // the scope owns them (a stack array here is read after return and crashes).
    const recent_items = try scope.createState([2]W.MenuItem, .{ .{ .id = "recent-design", .label = "window-adaptation.md" }, .{ .id = "recent-readme", .label = "README.md" } });
    const file_items = try scope.createState([12]W.MenuItem, .{
        .{ .id = "new", .label = "新建文件", .shortcut = if (is_mac) "⌘N" else "Ctrl+N" },
        .{ .id = "new-window", .label = "新建窗口", .shortcut = if (is_mac) "⇧⌘N" else "Ctrl+Shift+N" },
        .{ .id = "open", .label = "打开…", .shortcut = if (is_mac) "⌘O" else "Ctrl+O" },
        .{ .id = "recent", .label = "打开最近", .children = recent_items },
        .{ .kind = .separator },
        .{ .id = "save", .label = "保存", .shortcut = if (is_mac) "⌘S" else "Ctrl+S" },
        .{ .id = "save-as", .label = "另存为…", .shortcut = if (is_mac) "⇧⌘S" else "Ctrl+Shift+S" },
        .{ .id = "export", .label = "导出…", .shortcut = if (is_mac) "⇧⌘E" else "Ctrl+Shift+E" },
        .{ .kind = .separator },
        .{ .id = "settings", .label = "偏好设置…", .shortcut = if (is_mac) "⌘," else "Ctrl+," },
        .{ .id = "close", .label = "关闭窗口", .shortcut = if (is_mac) "⌘W" else "Ctrl+W" },
        .{ .id = "quit", .label = "退出", .shortcut = if (is_mac) "⌘Q" else "Ctrl+Q" },
    });
    const edit_items = try scope.createState([3]W.MenuItem, .{ .{ .id = "undo", .label = "撤销", .shortcut = if (is_mac) "⌘Z" else "Ctrl+Z" }, .{ .id = "copy", .label = "复制", .shortcut = if (is_mac) "⌘C" else "Ctrl+C" }, .{ .id = "paste", .label = "粘贴", .shortcut = if (is_mac) "⌘V" else "Ctrl+V" } });
    const view_items = try scope.createState([2]W.MenuItem, .{ .{ .id = "fullscreen", .label = "全屏", .shortcut = "F11" }, .{ .id = "reveal", .label = if (is_mac) "在 Finder 中显示" else if (s.appearance == .windows) "在资源管理器中显示" else "在文件管理器中显示" } });
    const insert_items = try scope.createState([2]W.MenuItem, .{ .{ .id = "insert-heading", .label = "标题" }, .{ .id = "insert-code", .label = "代码块" } });
    const format_items = try scope.createState([2]W.MenuItem, .{ .{ .id = "format-bold", .label = "加粗" }, .{ .id = "format-italic", .label = "斜体" } });
    const window_items = try scope.createState([2]W.MenuItem, .{ .{ .id = "minimize", .label = "最小化" }, .{ .id = "maximize", .label = "最大化 / 还原" } });
    const help_items = try scope.createState([1]W.MenuItem, .{.{ .id = "about", .label = "关于 markdown-editor" }});
    const menu_items = try scope.createState([7]W.MenuItem, .{
        .{ .id = "file", .label = "文件", .children = file_items },
        .{ .id = "edit", .label = "编辑", .children = edit_items },
        .{ .id = "view", .label = "视图", .children = view_items },
        .{ .id = "insert", .label = "插入", .children = insert_items },
        .{ .id = "format", .label = "格式", .children = format_items },
        .{ .id = "window", .label = "窗口", .children = window_items },
        .{ .id = "help", .label = "帮助", .children = help_items },
    });
    // Leading chips: project switcher and branch switcher. The demo has no real
    // workspace, so selections only rename the chips and report a status line.
    const project_name = p.project orelse try scope.createText("markdown-editor", .{});
    const branch_name = p.branch orelse try scope.createText("main", .{});
    // Menu items with platform-dependent values are runtime arrays. `v.show`
    // re-mounts the chips whenever the menu bar toggles, and Menu clones its
    // items at mount, so they must outlive this function: the scope owns them.
    const project_items = try scope.createState([6]W.MenuItem, .{
        .{ .id = "project:markdown-editor", .label = "markdown-editor" },
        .{ .id = "project:zenit-docs", .label = "zenit-docs" },
        .{ .id = "project:video-catch", .label = "video-catch" },
        .{ .kind = .separator },
        .{ .id = "project-open", .label = "打开项目…", .icon_asset = ui.icons.folder_open, .shortcut = if (is_mac) "⌘O" else "Ctrl+O" },
        .{ .id = "project-new", .label = "新建项目…", .icon_asset = ui.icons.plus },
    });
    const branch_items = try scope.createState([6]W.MenuItem, .{
        .{ .id = "branch:main", .label = "main" },
        .{ .id = "branch:feat/window-header", .label = "feat/window-header" },
        .{ .id = "branch:release/0.13", .label = "release/0.13" },
        .{ .kind = .separator },
        .{ .id = "branch-new", .label = "新建分支…", .icon_asset = ui.icons.plus },
        .{ .id = "branch-sync", .label = "拉取 / 推送" },
    });
    const menu = if (!is_mac) try v.render(scope, cx, v.with(W.Menu(.{ .items = menu_items, .open = p.menu_open, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{v.attrs(.{ .test_id = "window.menu" }, W.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.menu, .icon_size = @as(f32, 15), .icon_tint = S.icon_tint, .a11y_label = "应用菜单", .base_style = S.icon_button }))})) else null;
    const left = if (!is_mac) try W.WindowControls(.{ .state = p.state, .side = .left, .fullscreen_controls = true, .native_regions = !p.preview, .on_action = cx.on(Context, c, Context.caption) }).mount(scope, cx) else null;
    const right = if (!is_mac) try W.WindowControls(.{ .state = p.state, .side = .right, .fullscreen_controls = true, .native_regions = !p.preview, .on_action = cx.on(Context, c, Context.caption) }).mount(scope, cx) else null;
    for ([_]?*ui.Node{ left, right }) |root| if (root) |node| {
        for (node.children.items) |button| {
            if (button.meta.ownership.meta.test_id) |id| {
                if (std.mem.eql(u8, id, "window.controls.minimize")) button.meta.ownership.meta.test_id = p.control_ids[0];
                if (std.mem.eql(u8, id, "window.controls.maximize")) button.meta.ownership.meta.test_id = p.control_ids[1];
                if (std.mem.eql(u8, id, "window.controls.close")) button.meta.ownership.meta.test_id = p.control_ids[2];
            }
        }
    };
    // macOS always owns traffic lights. Previews reserve their slot without drawing replicas.
    const traffic = if (is_mac and p.preview) try v.render(scope, cx, v.box(.{ .style = .{ .width = 70, .height = 38 }, .hit_test = false }, .{})) else null;
    const children = .{
        v.row(.{ .style = S.leading }, .{
            traffic, left, menu,
            v.show(ui.not(p.menu_bar), .{v.row(.{ .style = S.project_group }, .{
                v.with(W.Menu(.{ .items = project_items, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{v.row(.{ .test_id = "window.project", .window_region = .client, .style = v.styleBy(project_width, S.projectSized) }, .{
                    v.box(.{ .style = S.badge }, .{v.text(.{ .style = S.badge_text }, "M")}),
                    v.text(.{ .style = S.project_text }, project_name),
                    v.icon(.{ .style = .{ .width = 11, .height = 11 }, .tint = S.icon_tint }, ui.icons.chevron_down),
                })}),
                v.with(W.Menu(.{ .items = branch_items, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{v.row(.{ .test_id = "window.branch", .window_region = .client, .style = S.branch }, .{ v.icon(.{ .style = .{ .width = 12, .height = 12 }, .tint = S.icon_tint }, ui.icons.git_branch), v.show(branch_text, .{ v.text(.{ .style = S.muted_text }, branch_name), v.icon(.{ .style = .{ .width = 11, .height = 11 }, .tint = S.icon_tint }, ui.icons.chevron_down) }) })}),
            })}),
            v.show(p.menu_bar, .{v.row(.{ .style = S.menu_bar }, .{
                v.with(W.Menu(.{ .items = file_items, .open = file_open, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{W.Button(.{ .label = "文件(F)", .variant = .ghost, .size = .sm })}),
                v.with(W.Menu(.{ .items = menu_items[1].children, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{W.Button(.{ .label = "编辑(E)", .variant = .ghost, .size = .sm })}),
                v.with(W.Menu(.{ .items = menu_items[2].children, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{W.Button(.{ .label = "视图(V)", .variant = .ghost, .size = .sm })}),
                v.with(W.Menu(.{ .items = menu_items[3].children, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{W.Button(.{ .label = "插入(I)", .variant = .ghost, .size = .sm })}),
                v.with(W.Menu(.{ .items = menu_items[4].children, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{W.Button(.{ .label = "格式(O)", .variant = .ghost, .size = .sm })}),
                v.with(W.Menu(.{ .items = menu_items[5].children, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{W.Button(.{ .label = "窗口(W)", .variant = .ghost, .size = .sm })}),
                v.with(W.Menu(.{ .items = menu_items[6].children, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{W.Button(.{ .label = "帮助(H)", .variant = .ghost, .size = .sm })}),
            })}),
        }),
        v.box(.{ .test_id = p.drag_id, .window_region = if (s.effective_mode == .custom and !p.preview) Chrome.Region.drag else Chrome.Region.client, .style = S.drag }, .{}),
        v.row(.{ .style = S.trailing }, .{
            v.row(.{ .style = S.actions }, .{
                v.show(full_actions, .{ v.with(W.Tooltip(.{ .text = "分享" }), .{}).trigger(.{iconButton(ui.icons.share, "分享", ui.on.call(c, Context.project))}), v.with(W.Tooltip(.{ .text = "历史" }), .{}).trigger(.{iconButton(ui.icons.history, "历史", ui.on.call(c, Context.branch))}) }),
                v.with(W.Menu(.{ .items = &[_]W.MenuItem{ .{ .id = "share", .label = "分享" }, .{ .id = "history", .label = "历史" }, .{ .id = "fullscreen", .label = "全屏 / 退出全屏" } }, .on_select = cx.on(Context, c, Context.command) }), .{}).trigger(.{v.attrs(.{ .test_id = "window.more" }, W.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.ellipsis, .icon_size = @as(f32, 15), .icon_tint = ui.arb.hex(0xe8652e), .a11y_label = "更多操作", .base_style = S.icon_button }))}),
                v.show(full_actions, .{v.with(W.Tooltip(.{ .text = if (is_mac) "搜索 ⌘P" else "搜索 (Ctrl+P)" }), .{}).trigger(.{iconButton(ui.icons.search, "搜索", ui.on.call(c, Context.project))})}),
            }),
            right,
        }),
    };
    const root = if (p.preview) try v.render(scope, cx, v.row(.{ .test_id = p.test_id, .style = S.header }, children)) else try W.WindowHeader(.{ .test_id = p.test_id, .style = S.header }, children).mount(scope, cx);
    if (p.preview and p.radius > 0) root.setStyleInlineFallible(cx.allocator, .{ .corner_radii = .{ .each = .{ p.radius, p.radius, 0, 0 } }, .overflow_hidden = true }) catch |err| {
        cx.freeNode(root);
        return err;
    };
    return root;
}
