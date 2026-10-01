/// storybook，集中展示 + e2e 验证所有 zenit 组件
///
/// 布局 master-detail：左侧组件列表（可点行），右侧 content 面板按选中项切换。
/// 点击左行只切换右面板（无长滚动页），e2e 永远只操作当前可见的那一个组件。
///
/// 架构：
///   - 每个组件一条 WIDGETS 注册项：{ key, title, buildFn }
///   - 每个 story 一条可见性 Signal；点击导航后仅激活目标 story
///   - inline for 在 comptime 展开：每项生成导航行 + Show 面板
///   - NavVisuals 保留导航节点，独立更新 hover / selected / breadcrumb 视觉状态
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
const MultiWindowApp = zenit_app.MultiWindowApp;

const Padding = ui.Padding;
const light = ui.theme.light;

const stories = @import("stories.zig");
const S = @import("styles.zig");

var g_storybook_cx: ?*ui.Cx = null;
var g_devtools_close_requested = false;
/// SIGTERM/SIGINT request a graceful quit so `gpa.deinit()` runs and reports
/// leaks. The e2e runner stops the app with SIGTERM; without this the process
/// died before the leak check and every run was leak-blind.
var g_quit_requested = std.atomic.Value(bool).init(false);

fn onTerminateSignal(_: c_int) callconv(.c) void {
    g_quit_requested.store(true, .release);
}

fn installTerminateHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onTerminateSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

fn toggleDevtools(ctx: *anyopaque) void {
    const cx: *ui.Cx = @ptrCast(@alignCast(ctx));
    cx.inspector.enabled = !cx.inspector.enabled;
    if (!cx.inspector.enabled) {
        cx.inspector.pick_mode = false;
        cx.inspector.clearSelection();
    }
    cx.needs_redraw = true;
}

fn requestDevtoolsClose(flag: *bool) void {
    flag.* = true;
}

fn mountDevtools(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    cx.setTheme(&ui.theme.light);
    return ui.devtools.mountPanel(cx, g_storybook_cx orelse return error.StorybookTargetMissing, .{
        .title = "Zenit Storybook DevTools",
        .on_close = ui.Cx.handlerFrom(bool, &g_devtools_close_requested, requestDevtoolsClose),
    });
}

// ── 组件注册表 ──
// 每项：sidebar 标题 + test_id key（nav.<key> / story.<key>）+ story 构建函数。
const WidgetSpec = struct {
    key: []const u8,
    title: []const u8,
    build: *const fn (*ui.Scope, *ui.Cx) anyerror!*ui.Node,
};

const WIDGETS = [_]WidgetSpec{
    .{ .key = "button", .title = "Button", .build = stories.buildButton },
    .{ .key = "checkbox", .title = "Checkbox", .build = stories.buildCheckbox },
    .{ .key = "switch", .title = "Switch", .build = stories.buildSwitch },
    .{ .key = "radio", .title = "Radio", .build = stories.buildRadio },
    .{ .key = "slider", .title = "Slider", .build = stories.buildSlider },
    .{ .key = "input", .title = "Input", .build = stories.buildInput },
    .{ .key = "textarea", .title = "Textarea", .build = stories.buildTextarea },
    .{ .key = "select", .title = "Select", .build = stories.buildSelect },
    .{ .key = "combobox", .title = "ComboBox", .build = stories.buildComboBox },
    .{ .key = "badge", .title = "Badge", .build = stories.buildBadge },
    .{ .key = "tag", .title = "Tag", .build = stories.buildTag },
    .{ .key = "chip", .title = "Chip", .build = stories.buildChip },
    .{ .key = "card", .title = "Card", .build = stories.buildCard },
    .{ .key = "glassbox", .title = "GlassBox", .build = stories.buildGlassBox },
    .{ .key = "glasslab", .title = "GlassLab", .build = stories.buildGlassLab },
    .{ .key = "glassedge", .title = "GlassEdge", .build = stories.buildGlassEdge },
    .{ .key = "glassislands", .title = "GlassIslands", .build = stories.buildGlassIslands },
    .{ .key = "glassmotion", .title = "GlassMotion", .build = stories.buildGlassMotion },
    .{ .key = "glasschrome", .title = "GlassChrome", .build = stories.buildGlassChrome },
    .{ .key = "canvasevents", .title = "CanvasEvents", .build = stories.buildCanvasEvents },
    .{ .key = "drag", .title = "Drag", .build = stories.buildDrag },
    .{ .key = "multiclick", .title = "Gestures", .build = stories.buildMultiClick },
    .{ .key = "animctl", .title = "AnimControls", .build = stories.buildAnimCtl },
    .{ .key = "divider", .title = "Divider", .build = stories.buildDivider },
    .{ .key = "stack", .title = "Stack", .build = stories.buildStack },
    .{ .key = "layoutbox", .title = "Layout / Box Model", .build = stories.buildLayoutBoxModel },
    .{ .key = "alert", .title = "Alert", .build = stories.buildAlert },
    .{ .key = "notification", .title = "Notification", .build = stories.buildNotification },
    .{ .key = "progress", .title = "Progress", .build = stories.buildProgress },
    .{ .key = "spinner", .title = "Spinner", .build = stories.buildSpinner },
    .{ .key = "skeleton", .title = "Skeleton", .build = stories.buildSkeleton },
    .{ .key = "timeline", .title = "Timeline", .build = stories.buildTimeline },
    .{ .key = "breadcrumb", .title = "Breadcrumb", .build = stories.buildBreadcrumb },
    .{ .key = "steps", .title = "Steps", .build = stories.buildSteps },
    .{ .key = "rate", .title = "Rate", .build = stories.buildRate },
    .{ .key = "tabs", .title = "Tabs", .build = stories.buildTabs },
    .{ .key = "accordion", .title = "Accordion", .build = stories.buildAccordion },
    .{ .key = "tree", .title = "Tree", .build = stories.buildTree },
    .{ .key = "table", .title = "Table", .build = stories.buildTable },
    .{ .key = "datatable", .title = "DataTable", .build = stories.buildDataTable },
    .{ .key = "stepper", .title = "NumberStepper", .build = stories.buildNumberStepper },
    .{ .key = "tags", .title = "TagsInput", .build = stories.buildTagsInput },
    .{ .key = "upload", .title = "FileUpload", .build = stories.buildFileUpload },
    .{ .key = "menu", .title = "Menu", .build = stories.buildMenu },
    .{ .key = "dropdown", .title = "DropdownMenu", .build = stories.buildDropdownMenu },
    .{ .key = "tooltip", .title = "Tooltip", .build = stories.buildTooltip },
    .{ .key = "popover", .title = "Popover", .build = stories.buildPopover },
    .{ .key = "modal", .title = "Modal", .build = stories.buildModal },
    .{ .key = "zindex", .title = "ZIndex", .build = stories.buildZIndex },
    .{ .key = "sheet", .title = "Sheet", .build = stories.buildSheet },
    .{ .key = "calendar", .title = "Calendar", .build = stories.buildCalendar },
    .{ .key = "datepicker", .title = "DatePicker", .build = stories.buildDatePicker },
    .{ .key = "daterange", .title = "DateRangePicker", .build = stories.buildDateRangePicker },
    .{ .key = "markdown", .title = "Markdown", .build = stories.buildMarkdown },
    .{ .key = "virtuallist", .title = "VirtualList", .build = stories.buildVirtualList },
    .{ .key = "virtuallistdynamic", .title = "VirtualList (Dynamic)", .build = stories.buildVirtualListDynamic },
    .{ .key = "scrollarea", .title = "ScrollArea", .build = stories.buildScrollArea },
    .{ .key = "grid", .title = "Grid", .build = stories.buildGrid },
    .{ .key = "form", .title = "Form", .build = stories.buildForm },
    .{ .key = "formcompose", .title = "Form Composition", .build = @import("form_composition.zig").build },
    .{ .key = "wall", .title = "Component Wall", .build = @import("component_wall.zig").build },
    .{ .key = "cleanup", .title = "CleanupHooks", .build = stories.buildCleanup },
    .{ .key = "icons", .title = "Icons", .build = stories.buildIconGallery },
    .{ .key = "vectorpath", .title = "VectorPath", .build = stories.buildVectorPath },
    .{ .key = "blend", .title = "BlendModes", .build = stories.buildBlend },
    .{ .key = "emoji", .title = "Emoji", .build = stories.buildEmoji },
    .{ .key = "rtl", .title = "RTL", .build = stories.buildRtl },
    .{ .key = "wordnav", .title = "WordNav", .build = stories.buildWordNav },
    .{ .key = "heavytext", .title = "HeavyText", .build = stories.buildHeavyText },
    .{ .key = "textanimjitter", .title = "TextAnimJitter", .build = stories.buildTextAnimJitter },
    .{ .key = "secsvg", .title = "Security / SVG", .build = stories.buildSecuritySvg },
    .{ .key = "secopacity", .title = "Security / Opacity", .build = stories.buildSecurityOpacity },
    .{ .key = "sectext", .title = "Security / Text", .build = stories.buildSecurityText },
    .{ .key = "interactionlifecycle", .title = "Interaction Lifecycle", .build = stories.buildInteractionLifecycle },
    .{ .key = "teardownstress", .title = "Lifecycle Stress", .build = stories.buildTeardownStress },
};

const NavSection = struct {
    start_key: []const u8,
    label: []const u8,
};

/// Sections are anchored by stable story keys instead of numeric offsets, so
/// inserting a component inside a group cannot silently misclassify every
/// section after it.
const NAV_SECTIONS = [_]NavSection{
    .{ .start_key = "button", .label = "CONTROLS" },
    .{ .start_key = "badge", .label = "DATA DISPLAY" },
    .{ .start_key = "glassbox", .label = "MATERIALS & MOTION" },
    .{ .start_key = "divider", .label = "LAYOUT" },
    .{ .start_key = "alert", .label = "FEEDBACK" },
    .{ .start_key = "timeline", .label = "NAVIGATION" },
    .{ .start_key = "table", .label = "DATA & FORMS" },
    .{ .start_key = "menu", .label = "OVERLAYS" },
    .{ .start_key = "calendar", .label = "DATE & CONTENT" },
    .{ .start_key = "virtuallist", .label = "PATTERNS" },
    .{ .start_key = "icons", .label = "GRAPHICS & TEXT" },
    .{ .start_key = "secsvg", .label = "SECURITY REGRESSIONS" },
};

const COMPONENT_COUNT_LABEL = std.fmt.comptimePrint("{d} COMPONENTS", .{WIDGETS.len});
const STORY_COUNT_LABEL = std.fmt.comptimePrint("{d} STORIES", .{WIDGETS.len});

// 每个面板一个可见性 Signal(bool)。点某行 -> 该行 signal 设 true、其余设 false。
// Show 接受 *Signal(bool)（不接受 Memo），故用一组 signal 而非单个 active 索引。
const VisSignals = [WIDGETS.len]*ui.Signal(bool);

/// Sidebar visuals are kept separately from visibility signals: the signals
/// mount/unmount stories, while these retained nodes provide immediate hover,
/// selected, and breadcrumb feedback without rebuilding the navigation tree.
const NavVisuals = struct {
    rows: [WIDGETS.len]*ui.Node,
    indicators: [WIDGETS.len]*ui.Node,
    labels: [WIDGETS.len]*ui.Node,
    active: usize,
    current_section: *ui.Node,
    current_title: *ui.Node,
    allocator: std.mem.Allocator,
};

// 每个 sidebar 行携带的点击上下文：选中本行 = 把全组 signal 置成「仅本行 true」。
const RowCtx = struct {
    vis: *const VisSignals,
    visuals: *NavVisuals,
    index: u32,
};

const NAV_ENTRY_COUNT = WIDGETS.len + NAV_SECTIONS.len;

/// 侧边栏搜索：按标题 / key 做不区分大小写的子串过滤。
/// 用框架原生 display:none 隐藏不匹配的行与空分组标题，节点始终在树上，
/// 不重排 children、不需要在销毁时恢复。
const NavFilter = struct {
    allocator: std.mem.Allocator,
    /// 规范顺序的全部导航条目（分组标题 + 行）。
    entries: [NAV_ENTRY_COUNT]*ui.Node = undefined,
    /// 条目对应的 WIDGETS 下标；分组标题为 null。
    widget_of: [NAV_ENTRY_COUNT]?usize = undefined,
    len: usize = 0,
    /// 列表末尾的无匹配提示（默认 display:none）。
    empty_hint: *ui.Node,

    fn push(self: *NavFilter, node: *ui.Node, widget: ?usize) void {
        self.entries[self.len] = node;
        self.widget_of[self.len] = widget;
        self.len += 1;
    }

    fn matches(widget: WidgetSpec, query: []const u8) bool {
        if (query.len == 0) return true;
        return std.ascii.indexOfIgnoreCase(widget.title, query) != null or
            std.ascii.indexOfIgnoreCase(widget.key, query) != null;
    }

    fn onQuery(self: *NavFilter, raw: []const u8) void {
        self.apply(std.mem.trim(u8, raw, " \t"));
    }

    fn apply(self: *NavFilter, query: []const u8) void {
        var any = false;
        var header: ?*ui.Node = null;
        var header_has_match = false;
        for (self.entries[0..self.len], self.widget_of[0..self.len]) |node, widget| {
            const index = widget orelse {
                if (header) |h| h.setDisplay(if (header_has_match) .flex else .none);
                header = node;
                header_has_match = false;
                continue;
            };
            const show = matches(WIDGETS[index], query);
            node.setDisplay(if (show) .flex else .none);
            header_has_match = header_has_match or show;
            any = any or show;
        }
        if (header) |h| h.setDisplay(if (header_has_match) .flex else .none);
        self.empty_hint.setDisplay(if (any) .none else .flex);
    }
};

fn sectionForIndex(index: usize) []const u8 {
    var cursor = @min(index + 1, WIDGETS.len);
    while (cursor > 0) {
        cursor -= 1;
        for (NAV_SECTIONS) |section| {
            if (std.mem.eql(u8, WIDGETS[cursor].key, section.start_key)) return section.label;
        }
    }
    unreachable;
}

fn isSectionStart(comptime index: usize) bool {
    for (NAV_SECTIONS) |section| {
        if (std.mem.eql(u8, WIDGETS[index].key, section.start_key)) return true;
    }
    return false;
}

fn updateTextStyle(node: *ui.Node, active: bool) void {
    if (node.getText()) |old| {
        var next = old;
        next.color = if (active) light.color.fg_primary else light.color.fg_secondary;
        next.font_weight = if (active) 600 else 400;
        node.setText(next);
        node.markLayoutDirty();
    }
}

fn updateNavigation(visuals: *NavVisuals, active_index: usize) void {
    visuals.active = active_index;
    for (visuals.rows, visuals.indicators, visuals.labels, 0..) |row, indicator, label, i| {
        const active = i == active_index;
        row.setBackground(if (active) light.color.accent_subtle else ui.Color.TRANSPARENT);
        indicator.setBackground(if (active) light.color.accent else ui.Color.TRANSPARENT);
        updateTextStyle(label, active);
    }

    visuals.current_section.setTextContent(visuals.allocator, sectionForIndex(active_index)) catch {};
    visuals.current_title.setTextContent(visuals.allocator, WIDGETS[active_index].title) catch {};
    visuals.current_section.markLayoutDirty();
    visuals.current_title.markLayoutDirty();
}

fn rowClick(ctx: *anyopaque) void {
    const rc: *RowCtx = @ptrCast(@alignCast(ctx));
    for (rc.vis.*, 0..) |sig, i| {
        sig.set(i == rc.index);
    }
    updateNavigation(rc.visuals, rc.index);
}

fn rowHover(ctx: *anyopaque) void {
    const rc: *RowCtx = @ptrCast(@alignCast(ctx));
    if (rc.visuals.active != rc.index) {
        rc.visuals.rows[rc.index].setBackground(light.color.bg_hover);
    }
}

fn rowLeave(ctx: *anyopaque) void {
    const rc: *RowCtx = @ptrCast(@alignCast(ctx));
    if (rc.visuals.active != rc.index) {
        rc.visuals.rows[rc.index].setBackground(ui.Color.TRANSPARENT);
    }
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    // 62 inline story builders plus key-anchored section lookup exceed Zig's
    // conservative default comptime branch budget during monomorphization.
    comptime {
        @setEvalBranchQuota(20_000);
    }
    const allocator = cx.allocator;

    // 框架默认 theme 是 dark（cx.tokens=&theme.dark）。storybook 全程用 light
    // 配色，故显式切到 light，让组件自绘背景（Table/Calendar 等用 cx.tokens）
    // 与本文件硬编码的 light.* 文本色一致，避免暗底暗字看不见。
    cx.setTheme(&ui.theme.light);

    // 可见性 signal 组（堆分配以获稳定指针，供 RowCtx 引用）。
    const vis = try allocator.create(VisSignals);
    try scope.registerResource(@ptrCast(vis), struct {
        fn destroy(ptr: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*VisSignals, @ptrCast(@alignCast(ptr))));
        }
    }.destroy);
    inline for (0..WIDGETS.len) |i| {
        vis[i] = try scope.createSignal(bool, i == 0); // 默认选中第一个
    }

    // 根：row 容器（左 sidebar + 右 workspace）
    const root = try ui.boxStyled(cx, S.root, .{});

    // ── 左 sidebar ──
    const sidebar = try ui.boxStyled(cx, S.sidebar, .{});
    sidebar.meta.ownership.meta.test_id = "sidebar";
    try root.appendChild(allocator, sidebar);

    const brand = try ui.boxStyled(cx, S.brand, .{});
    const logo = try ui.boxStyled(cx, S.logoMark, .{});
    try logo.appendChild(allocator, try ui.textStyled(cx, S.logoLetter, "Z"));
    try brand.appendChild(allocator, logo);
    const brand_copy = try ui.boxStyled(cx, S.brandCopy, .{});
    try brand_copy.appendChild(allocator, try ui.textStyled(cx, S.brandName, "Zenit UI"));
    try brand_copy.appendChild(allocator, try ui.textStyled(cx, S.brandLabel, "COMPONENT STUDIO"));
    try brand.appendChild(allocator, brand_copy);
    try sidebar.appendChild(allocator, brand);

    const search_wrap = try ui.boxStyled(cx, S.searchWrap, .{});
    const search_field = try ui.boxStyled(cx, S.searchField, .{});
    try search_field.appendChild(allocator, try ui.iconTintStyled(cx, ui.system_icons.search, light.color.fg_tertiary, .{
        .width = .{ .px = 14 },
        .height = .{ .px = 14 },
    }));
    const search = try ui.widgets.Input(.{
        .placeholder = "Browse component library",
        .placeholder_color = light.color.fg_tertiary,
        .size = .sm,
        .embedded = true,
    }).mountResult(scope, cx);
    stripEmbeddedInputChrome(search);
    search.input_container.meta.ownership.meta.test_id = "storybook.search";
    try search_field.appendChild(allocator, search.node);
    try search_wrap.appendChild(allocator, search_field);
    try sidebar.appendChild(allocator, search_wrap);

    const library_meta = try ui.boxStyled(cx, S.libraryMeta, .{});
    try library_meta.appendChild(allocator, try ui.textStyled(cx, S.libraryLabel, "LIBRARY"));
    try library_meta.appendChild(allocator, try ui.textStyled(cx, S.libraryCount, COMPONENT_COUNT_LABEL));
    try sidebar.appendChild(allocator, library_meta);

    // nav 列表放进 ScrollArea：组件数超过窗口高度时可滚动（鼠标滚轮/触控板）。
    // width/height 留空 -> 容器默认 grow，吃掉 "Components" header 下方剩余高度。
    // e2e 的 clickTestId 走 test harness scroll-into-view（命令执行前把目标滚进视口），
    // 故滚出视口的行依旧可点，见 src/test_harness/command_executor.zig。
    const nav_scroll = try ui.widgets.mountScrollArea(.{
        .direction = .vertical,
        .padding = .{ .top = 0, .right = 10, .bottom = 12, .left = 10 },
    }, scope, cx);
    try sidebar.appendChild(allocator, nav_scroll.container);
    const nav_list = nav_scroll.content;

    const nav_filter = try allocator.create(NavFilter);
    nav_filter.* = .{
        .allocator = allocator,
        .empty_hint = try ui.textStyled(cx, S.navEmptyHint, "No matching components"),
    };
    nav_filter.empty_hint.setDisplay(.none);
    try scope.registerResource(@ptrCast(nav_filter), struct {
        fn destroy(ptr: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*NavFilter, @ptrCast(@alignCast(ptr))));
        }
    }.destroy);
    search.state.on_change = ui.Cx.strHandlerFrom(NavFilter, nav_filter, NavFilter.onQuery);

    const footer = try ui.boxStyled(cx, S.sidebarFooter, .{});
    try footer.appendChild(allocator, try ui.boxStyled(cx, S.onlineDot, .{}));
    try footer.appendChild(allocator, try ui.textStyled(cx, S.sidebarFooterText, "All systems ready"));
    const footer_spacer = try ui.spacer(cx);
    footer_spacer.style.flex = 1;
    try footer.appendChild(allocator, footer_spacer);
    try footer.appendChild(allocator, try ui.textStyled(cx, S.sidebarVersion, "v0.1.0-alpha"));
    try sidebar.appendChild(allocator, footer);

    // ── 右 workspace ──
    const workspace = try ui.boxStyled(cx, S.workspace, .{});
    try root.appendChild(allocator, workspace);

    const toolbar = try ui.boxStyled(cx, S.toolbar, .{});
    const breadcrumb = try ui.boxStyled(cx, S.breadcrumb, .{});
    try breadcrumb.appendChild(allocator, try ui.textStyled(cx, S.breadcrumbRoot, "LIBRARY"));
    try breadcrumb.appendChild(allocator, try ui.textStyled(cx, S.breadcrumbRoot, "/"));
    const current_section = try ui.textStyled(cx, S.breadcrumbSection, sectionForIndex(0));
    try breadcrumb.appendChild(allocator, current_section);
    try breadcrumb.appendChild(allocator, try ui.textStyled(cx, S.breadcrumbRoot, "/"));
    const current_title = try ui.textStyled(cx, S.breadcrumbCurrent, WIDGETS[0].title);
    try breadcrumb.appendChild(allocator, current_title);
    try toolbar.appendChild(allocator, breadcrumb);

    const toolbar_actions = try ui.boxStyled(cx, S.toolbarActions, .{});
    const devtools_pill = try ui.boxStyled(cx, S.toolbarPill, .{});
    devtools_pill.style.cursor = .pointer;
    devtools_pill.meta.ownership.meta.test_id = "storybook.devtools";
    devtools_pill.behavior.events.on_click = ui.Cx.simpleHandler(toggleDevtools, @ptrCast(cx));
    try devtools_pill.appendChild(allocator, try ui.textStyled(cx, S.toolbarPillText, "DEVTOOLS  ⌥⌘I"));
    try toolbar_actions.appendChild(allocator, devtools_pill);
    const version_pill = try ui.boxStyled(cx, S.toolbarPill, .{});
    try version_pill.appendChild(allocator, try ui.textStyled(cx, S.toolbarPillText, "ZENIT v0.1.0-alpha"));
    try toolbar_actions.appendChild(allocator, version_pill);
    const stories_pill = try ui.boxStyled(cx, S.toolbarPill, .{});
    try stories_pill.appendChild(allocator, try ui.boxStyled(cx, S.onlineDot, .{}));
    try stories_pill.appendChild(allocator, try ui.textStyled(cx, S.toolbarPillText, STORY_COUNT_LABEL));
    try toolbar_actions.appendChild(allocator, stories_pill);
    try toolbar.appendChild(allocator, toolbar_actions);
    try workspace.appendChild(allocator, toolbar);

    // ── 右 content 面板 ──
    // 包进垂直 ScrollArea：story 内容超过窗口高度时可滚动（鼠标滚轮/触控板）。
    // container 为 grow 视口（overflow_hidden），content 为承载各面板的内层列。
    // padding 放在 ScrollArea 上，使内容随滚动一起移动（含上下留白）。
    const content_scroll = try ui.widgets.mountScrollArea(.{
        .direction = .vertical,
        .padding = Padding.all(32),
        .background = light.color.bg_base,
    }, scope, cx);
    try workspace.appendChild(allocator, content_scroll.container);

    // 内层内容列：承载 Show 面板。test_id="content" 保留供 e2e 定位。
    const content = content_scroll.content;
    content.style.gap = 24;
    content.meta.ownership.meta.test_id = "content";

    const visuals = try allocator.create(NavVisuals);
    visuals.* = .{
        .rows = undefined,
        .indicators = undefined,
        .labels = undefined,
        .active = 0,
        .current_section = current_section,
        .current_title = current_title,
        .allocator = allocator,
    };
    try scope.registerResource(@ptrCast(visuals), struct {
        fn destroy(ptr: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*NavVisuals, @ptrCast(@alignCast(ptr))));
        }
    }.destroy);

    // ── inline for：每个组件生成导航行 + Show 面板 ──
    inline for (WIDGETS, 0..) |spec, i| {
        if (comptime isSectionStart(i)) {
            const section = try ui.boxStyled(cx, S.navSection, .{});
            try section.appendChild(allocator, try ui.textStyled(cx, S.navSectionText, sectionForIndex(i)));
            try nav_list.appendChild(allocator, section);
            nav_filter.push(section, null);
        }

        // 导航行
        const row = try ui.boxStyled(cx, S.navRow(i == 0), .{});
        row.meta.ownership.meta.test_id = "nav." ++ spec.key;
        const indicator = try ui.boxStyled(cx, S.navIndicator(i == 0), .{});
        const label = try ui.textStyled(cx, S.navLabel(i == 0), spec.title);
        try row.appendChild(allocator, indicator);
        try row.appendChild(allocator, label);
        visuals.rows[i] = row;
        visuals.indicators[i] = indicator;
        visuals.labels[i] = label;
        // 点击 -> 仅本行 signal true
        const rc = try allocator.create(RowCtx);
        rc.* = .{ .vis = vis, .visuals = visuals, .index = @intCast(i) };
        try scope.registerResource(@ptrCast(rc), struct {
            fn destroy(ptr: *anyopaque, a: std.mem.Allocator) void {
                a.destroy(@as(*RowCtx, @ptrCast(@alignCast(ptr))));
            }
        }.destroy);
        row.behavior.events.on_click = ui.Cx.simpleHandler(rowClick, rc);
        row.behavior.events.on_hover = ui.Cx.simpleHandler(rowHover, rc);
        row.behavior.events.on_leave = ui.Cx.simpleHandler(rowLeave, rc);
        try nav_list.appendChild(allocator, row);
        nav_filter.push(row, i);

        // 面板：Show 直接吃本组件的可见性 signal（spec.build 是 comptime 已知）
        try ui.Show(scope, content, vis[i], cx, makePanelBuilder(spec, sectionForIndex(i)));
    }

    try nav_list.appendChild(allocator, nav_filter.empty_hint);

    return root;
}

/// 搜索框自己画 shell（边框 / 背景 / 图标），嵌入的 Input 只保留可编辑文本面
/// （与 Select 的 searchable 模式同一做法）。
fn stripEmbeddedInputChrome(result: anytype) void {
    const a = result.state.allocator;
    result.node.style.width = .{ .grow = .{ .min = 0 } };
    result.node.style.flex_shrink = 1;
    result.node.style.gap = 0;
    result.node.style.ensureExtPanic(a).min_width = 0;
    if (result.node.children.items.len > 0) {
        const field_shell = result.node.children.items[0];
        field_shell.style.width = .{ .grow = .{ .min = 0 } };
        field_shell.style.flex_shrink = 1;
        field_shell.style.ensureExtPanic(a).min_width = 0;
        field_shell.style.border.width = 0;
    }
    result.input_container.style.width = .{ .grow = .{ .min = 0 } };
    result.input_container.style.flex_shrink = 1;
    result.input_container.style.ensureExtPanic(a).min_width = 0;
    result.input_container.style.height = .{ .fit = .{} };
    result.input_container.style.padding = Padding.ZERO;
    result.input_container.style.border.width = 0;
    result.input_container.setBackgroundRaw(ui.Color.TRANSPARENT);
    result.state.padding_h = 0;
}

// 为某个 spec 生成 comptime panel builder：包一层标题 + 调 spec.build。
fn makePanelBuilder(comptime spec: WidgetSpec, comptime section_name: []const u8) fn (*ui.Scope, *ui.Cx) anyerror!*ui.Node {
    return struct {
        fn build(s: *ui.Scope, c: *ui.Cx) anyerror!*ui.Node {
            const panel = try ui.boxStyled(c, S.panel, .{});
            panel.meta.ownership.meta.test_id = "story." ++ spec.key;

            const header = try ui.boxStyled(c, S.panelHeader, .{});
            try header.appendChild(c.allocator, try ui.textStyled(c, S.sectionEyebrow, section_name ++ "  /  COMPONENT"));

            const title_row = try ui.boxStyled(c, S.titleRow, .{});
            try title_row.appendChild(c.allocator, try ui.textStyled(c, S.panelTitle, spec.title));
            const stable = try ui.boxStyled(c, S.stablePill, .{});
            try stable.appendChild(c.allocator, try ui.boxStyled(c, S.onlineDot, .{}));
            try stable.appendChild(c.allocator, try ui.textStyled(c, S.stableText, "READY"));
            try title_row.appendChild(c.allocator, stable);
            try header.appendChild(c.allocator, title_row);
            try header.appendChild(c.allocator, try ui.textStyled(c, S.description, spec.title ++ " states, variants, and interaction patterns in the Zenit design system."));
            try panel.appendChild(c.allocator, header);

            const preview = try ui.boxStyled(c, S.previewCard, .{});
            const preview_toolbar = try ui.boxStyled(c, S.previewToolbar, .{});
            const preview_status = try ui.boxStyled(c, S.previewStatus, .{});
            try preview_status.appendChild(c.allocator, try ui.boxStyled(c, S.onlineDot, .{}));
            try preview_status.appendChild(c.allocator, try ui.textStyled(c, S.previewLabel, "Live preview"));
            try preview_toolbar.appendChild(c.allocator, preview_status);
            const theme_pill = try ui.boxStyled(c, S.themePill, .{});
            try theme_pill.appendChild(c.allocator, try ui.textStyled(c, S.themePillText, "LIGHT THEME"));
            try preview_toolbar.appendChild(c.allocator, theme_pill);
            try preview.appendChild(c.allocator, preview_toolbar);

            const preview_body = try ui.boxStyled(c, S.previewBody, .{});
            const body = try spec.build(s, c);
            try preview_body.appendChild(c.allocator, body);
            try preview.appendChild(c.allocator, preview_body);
            try panel.appendChild(c.allocator, preview);
            return panel;
        }
    }.build;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 16 });
    defer application.deinit();

    const storybook = try application.createWindowWith(.{
        .window = .{ .width = 1100, .height = 1000, .title = "zenit Storybook" },
        .idle_skip_frames = true,
    }, mountUI);
    const storybook_window_id = storybook.windowId();
    g_storybook_cx = storybook.cx;
    defer g_storybook_cx = null;

    installTerminateHandlers();

    var devtools_window_id: ?u64 = null;
    while (try application.tick()) {
        if (g_quit_requested.load(.acquire)) {
            application.quit();
            break;
        }
        const target = application.window(storybook_window_id) orelse {
            application.quit();
            break;
        };

        // Native close and the panel close button both converge here. The
        // target inspector bit is the single source of truth for Cmd+Opt+I,
        // the toolbar button, and the DevTools window lifecycle.
        if (devtools_window_id) |id| {
            if (application.window(id) == null) {
                devtools_window_id = null;
                target.cx.inspector.enabled = false;
                target.rebindTestHarness();
                // DevTools was the last laid-out Cx. Reset text_layout's
                // process bridge to the surviving Storybook font context
                // before a test RPC can render/query the target directly.
                target.cx.layout();
            }
        }
        if (g_devtools_close_requested) {
            g_devtools_close_requested = false;
            target.cx.inspector.enabled = false;
        }

        if (target.cx.inspector.enabled) {
            if (devtools_window_id == null) {
                const devtools = try application.createWindowWith(.{
                    .window = .{ .width = 980, .height = 720, .title = "Zenit Storybook DevTools" },
                    .idle_skip_frames = true,
                }, mountDevtools);
                devtools_window_id = devtools.windowId();
            }
        } else if (devtools_window_id) |id| {
            _ = application.closeWindow(id);
            devtools_window_id = null;
            target.rebindTestHarness();
            target.cx.layout();
        }
    }
}
