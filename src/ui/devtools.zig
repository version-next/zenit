/// DevTools surface — two complementary tools:
///
///   1. `panel` (this file) — a full DevTools window: elements / components /
///      performance tabs. Mount it in a second native window with
///      `devtools.mountPanel(cx, target_cx, .{ .on_close = close_handler })`.
///
///   2. `overlay` (sub-module) — an in-window inspector: dashed-rect hover
///      highlight + dimension/component label. Add it with one call:
///      `try ui.devtools.overlay.attach(cx, scope, root, .{})`.
///
/// 功能:
/// P0: 完整 Style 属性面板 / 组件名显示 / Children 数量 / 文本预览
/// P1: 搜索过滤 / Tab 切换 (Layout/Style/State/Events) / Render dirty 标记
/// P2: Signal/Effect 查看器 / 渲染统计 / 树统计 / Events 面板
///
/// ─────────────────────────────────────────────────────────────────────
/// 【本文件的 OOM 策略：`catch {}` 一律是诊断路径，故意吞掉分配失败】
///
/// DevTools 是**观察被调试 app 的工具**，它自己不持有 app 的任何权威状态：
/// 面板里的每一行都是每帧从 target_cx 重新采集/重建的（rebuildFlatRows /
/// *BeforeRender / build*Tab）。所以分配失败的后果上限是「这一帧面板少显示
/// 一行 / 少一段文本 / 树少展开一层」，下一帧就自愈；它不会影响被调试 app 的
/// 布局、命中、状态或渲染正确性。
///
/// 反过来，如果这里改成 panic 或往上传播，就等于「打开调试面板会让被调试的
/// app 崩掉」——调试工具压垮它本该观察的对象，是明确不想要的行为。
///
/// 具体分几类，下面各处不再逐行重复：
///   - 面板 UI 构建（appendChild / build*Tab）：少画一块面板内容。
///   - 采集缓冲（flat_rows / scoped_state_ptrs / signal 列表 append）：
///     少列一个条目，均为每帧重建的临时表。
///   - 文本格式化（writer print / writeAll / writeByte）：写进定长栈缓冲或
///     frame arena，失败即截断显示。
///   - 展开/折叠等 UI 偏好（explicitly_expanded / collapsed put）：
///     丢一次记录只是某行没按记忆展开，纯观感。
///   - Scope 资源析构注册（onDestroy）：见各处说明。
/// ─────────────────────────────────────────────────────────────────────
const std = @import("std");
const dv_fmt = @import("devtools/format.zig");
const core = @import("core.zig");
const box_model = @import("devtools/box_model.zig");
const console_mod = @import("console.zig");
const StyleField = @import("core/types.zig").StyleField;

/// In-window inspector overlay. See `core/devtools_overlay.zig`.
pub const overlay = @import("core/devtools_overlay.zig");
pub const source_link = @import("devtools/source_link.zig");

/// 渲染原因 / 事件追踪存储 —— DevTools 的 Render / Trace 面板数据源。
///
/// 宿主应用要自建 inspector 面板时需要它：`setGlobalTraceTarget(store, frame)`
/// 开始采集、`clearGlobalTraceTarget()` 停止，再用 `DebugTraceStore` 上的
/// `getRenderForNode` / `getRecentEvents` 读回。
///
/// 曾经挂在顶层 `ui.debug_trace`。那个位置属于"引擎内部被顺手 pub 出去"，
/// 但**能力本身是公开的** —— 它是 devtools 的配套，所以归到这个命名空间。
pub const trace = core.debug_trace;
const hooks = @import("hooks.zig");
const theme_schema = @import("theme_schema.zig");
const scroll_area_mod = @import("components/scroll_area/mod.zig");
const virtual_list_mod = @import("components/virtual_list/mod.zig");
const widget_state = @import("widget_state.zig");
const reactive = @import("reactive.zig");
const debug_trace = core.debug_trace;
const button_mod = @import("components/button/mod.zig");
const tabs_mod = @import("components/tabs/mod.zig");
const svg_assets = @import("svg_assets.zig");
const system_icons = @import("zenit_system_icons");
const input_mod = @import("components/input/mod.zig");
const Button = button_mod.Button;
const Input = input_mod.Input;
const Tabs = tabs_mod.Tabs;
const TabItem = tabs_mod.TabItem;
const TabsState = tabs_mod.TabsState;

const Cx = core.Cx;
const Node = core.Node;
const Padding = core.Padding;
const Color = core.Color;
const theme = core.theme;
const Sizing = core.Sizing;
const ComputedRect = core.ComputedRect;
const Transform2D = core.Transform2D;
const HandlerRef = core.HandlerRef;
const Event = core.Event;
const EventResult = core.EventResult;

const mountScrollArea = scroll_area_mod.mountScrollArea;
const Scope = reactive.Scope;

/// DevTools 次要信息色（ID/数量等），在 light 模式下比 fg_disabled 更可读
fn devtoolsMuted(t: *const theme.ThemeTokens) Color {
    return theme_schema.window(t).devtools_muted;
}
const DebugStateEntry = widget_state.DebugStateEntry;
const ScopedStateRef = struct {
    ptr: *anyopaque,
    source_node_id: u32,
};
const ScopedStateEntry = struct {
    entry: DebugStateEntry,
    source_node_id: u32,
};
const DEVTOOLS_STATE_ID: u64 = 0xD3F70000;

/// Elements 树行 slot 的 test_id。hoveredTreeRow 靠它从悬停节点向上找到所属行，
/// e2e 也用它定位行，故集中定义避免两处字符串走样。
const tree_row_test_id = "devtools.tree.row";
const perf_chart_sample_count: usize = 64;
/// DevTools 窗口的保活轮询周期。DevTools 观察的是另一个窗口的 Cx，没有任何
/// 跨窗口"target 渲染了 → DevTools 标脏"的推送链路（MultiWindowApp 各窗口
/// 独立 wantsFrame），所以 DevTools 必须**无条件**自轮询——早期版本只在
/// target idle 时才调度下一次 poll，一旦某帧恰逢 target 活跃就不再调度，
/// 保活链永久断裂，面板从此只有鼠标划过时才动一下。
const devtools_keepalive_ns: u64 = 250_000_000;
/// Performance 页的轮询周期（10Hz）：FPS/柱状图是实时监控，250ms 太迟钝；
/// 100ms 只让 DevTools 自己以 10fps 重绘，不构成对 target 的观测扰动。
const perf_keepalive_ns: u64 = 100_000_000;
/// Console 页的 revision 轮询周期，保证新日志在约 100ms 内可见。
const console_keepalive_ns: u64 = 50_000_000;
/// 滚动监控的时间桶宽度：64 桶 × 100ms ≈ 6.4s 可视窗口。
const perf_bucket_ns: u64 = 100_000_000;
/// target.frame_count 超过此时长未推进 ⇒ FPS 行显示 (idle)。
/// idle 停帧是框架的省电行为——面板必须把「没在渲染」和「稳定 60fps」
/// 区分开，否则停帧后 FPS 文本永远冻在最后一次的值上假装健康。
const perf_idle_indicator_ns: u64 = 700_000_000;

fn allocScopeResource(scope: *Scope, comptime T: type) !*T {
    const value = try scope.allocator.create(T);
    errdefer scope.allocator.destroy(value);
    try scope.registerResource(@ptrCast(value), struct {
        fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const typed: *T = @ptrCast(@alignCast(ptr));
            alloc.destroy(typed);
        }
    }.destroy);
    return value;
}

// ========== 面板配置 ==========

pub const PanelOptions = struct {
    on_close: ?HandlerRef = null,
    /// Title shown in the devtools panel header. Defaults to "DevTools";
    /// applications that want their product name (e.g. "Zenit DevTools",
    /// "MyApp Inspector") should pass it here.
    title: []const u8 = "DevTools",
    /// Header 上的明暗切换开关在两套主题间切换。DevTools 窗口自己的主题，
    /// 与被观察的 target 无关；初始主题取 mountPanel 时 cx.tokens 的 scheme。
    light_theme: *const theme.ThemeTokens = &theme.light,
    dark_theme: *const theme.ThemeTokens = &theme.dark,
};

// ========== 视图模式 ==========

const ViewMode = enum {
    elements,
    components,
    console,
    performance,

    fn label(self: ViewMode) []const u8 {
        return switch (self) {
            .elements => "Elements",
            .components => "Components",
            .console => "Console",
            .performance => "Performance",
        };
    }
};

// ========== Tab 枚举 ==========

const DetailsTab = enum(u8) {
    layout = 0,
    style = 1,
    state = 2,
    events = 3,
    render = 4,
    trace = 5,

    fn label(self: DetailsTab) []const u8 {
        return switch (self) {
            .layout => "Layout",
            .style => "Style",
            .state => "State",
            .events => "Events",
            .render => "Render",
            .trace => "Trace",
        };
    }

    fn idStr(self: DetailsTab) []const u8 {
        return switch (self) {
            .layout => "layout",
            .style => "style",
            .state => "state",
            .events => "events",
            .render => "render",
            .trace => "trace",
        };
    }
};

// ========== Style 实时编辑 ==========

const EditableField = enum(u8) {
    gap,
    flex,
    flex_shrink,
    opacity,
    translate_x,
    translate_y,
    border_width,
    border_radius,

    fn label(self: EditableField) []const u8 {
        return switch (self) {
            .gap => "gap",
            .flex => "flex",
            .flex_shrink => "flex_shrink",
            .opacity => "opacity",
            .translate_x => "translate_x",
            .translate_y => "translate_y",
            .border_width => "border.width",
            .border_radius => "border.radius",
        };
    }

    /// 从目标节点读取当前值
    fn readValue(self: EditableField, node: *Node) f32 {
        return switch (self) {
            .gap => node.style.gap,
            .flex => node.style.flex,
            .flex_shrink => node.style.flex_shrink,
            .opacity => node.getOpacity(),
            .translate_x => node.style.translate_x,
            .translate_y => node.style.translate_y,
            .border_width => node.style.border.width,
            .border_radius => node.style.border.radius,
        };
    }

    fn sourceField(self: EditableField) StyleField {
        return switch (self) {
            .gap => .gap,
            .flex => .flex,
            .flex_shrink => .flex_shrink,
            .opacity => .opacity,
            .translate_x => .translate_x,
            .translate_y => .translate_y,
            // DevTool 当前把 border.width/radius 作为 Border 聚合值编辑。
            .border_width, .border_radius => .border,
        };
    }

    /// 将值写入目标节点并触发布局/渲染脏标记
    fn writeValue(self: EditableField, node: *Node, val: f32) void {
        switch (self) {
            .gap => node.style.gap = val,
            .flex => node.style.flex = val,
            .flex_shrink => node.style.flex_shrink = val,
            .opacity => {
                node.setOpacity(val);
                return; // setOpacity 已处理脏标记
            },
            .translate_x => node.style.translate_x = val,
            .translate_y => node.style.translate_y = val,
            .border_width => node.style.border.width = val,
            .border_radius => node.style.border.radius = val,
        }
        node.markLayoutDirty();
        node.markRenderDirty();
    }
};

/// 可编辑属性值行的点击上下文
const EditFieldCtx = struct {
    state: *DevToolsState,
    node_id: u32,
    field: EditableField,
};

/// 编辑提交上下文
const EditCommitCtx = struct {
    state: *DevToolsState,
    node_id: u32,
    field: EditableField,
};

const StyleSourceCtx = struct {
    cx: *Cx,
    origin: core.world.StyleOrigin,
};

fn styleSourceEvent(event: Event, context: ?*anyopaque) EventResult {
    const ctx: *StyleSourceCtx = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    const is_return_address = ctx.origin.kind != .styled;
    const loc = source_link.resolveAddress(ctx.cx.allocator, ctx.origin.address, is_return_address) catch return .stop;
    if (loc) |resolved| {
        defer ctx.cx.allocator.free(resolved.file);
        source_link.open(ctx.cx.allocator, resolved) catch {};
    }
    return .stop;
}

fn appendStyleSourceLink(cx: *Cx, state: *DevToolsState, inspected: *Node, field: ?StyleField, row: *Node) !void {
    if (!source_link.addressResolutionAvailable()) return;
    const origin = inspected.styleOrigin(field) orelse return;
    const details_scope = state.details_scope orelse state.scope.?;
    const ctx = try allocScopeResource(details_scope, StyleSourceCtx);
    ctx.* = .{ .cx = cx, .origin = origin };

    const btn = try cx.createNode(.box, .{
        .padding = .{ .left = 3, .right = 3 },
        .cursor = .pointer,
        .height = .{ .px = 16 },
        .align_items = .center,
        .justify = .center,
    });
    btn.meta.ownership.meta.test_id = "devtools.style.goto_source";
    try btn.appendChild(cx.allocator, try inlineText(cx, "↗", cx.tokens.color.accent, 10));
    btn.behavior.events.event_context = ctx;
    btn.behavior.events.on_event = styleSourceEvent;
    try row.appendChild(cx.allocator, btn);
}

/// 构建可编辑 kvRow — 显示值+点击进入编辑模式
fn editableKvRow(cx: *Cx, state: *DevToolsState, node: *Node, field: EditableField, parent: *Node) !void {
    const t = cx.tokens;
    const details_scope = state.details_scope orelse state.scope.?;
    const val = field.readValue(node);
    const is_editing = state.editing_field != null and
        state.editing_field.? == field and
        state.editing_node_id != null and
        state.editing_node_id.? == node.id;

    if (is_editing) {
        // 编辑模式：显示 Input
        const row = try cx.createNode(.box, .{
            .direction = .row,
            .gap = 8,
            .align_items = .center,
            .height = .{ .px = 22 },
            .width = .{ .grow = .{} },
        });
        try row.appendChild(cx.allocator, try core.text(cx, field.label(), .{
            .font_size = 10,
            .color = t.color.fg_secondary,
        }));

        // 准备初始值文本
        var val_buf: [12]u8 = undefined;
        const val_str = dv_fmt.fmtFloat(&val_buf, val);

        // 分配 commit context（绑定到 details_scope 生命周期）
        const commit_ctx = details_scope.allocator.create(EditCommitCtx) catch return;
        commit_ctx.* = .{
            .state = state,
            .node_id = node.id,
            .field = field,
        };
        details_scope.registerResource(@ptrCast(commit_ctx), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const c: *EditCommitCtx = @ptrCast(@alignCast(ptr));
                alloc.destroy(c);
            }
            // 诊断路径：注册失败只会漏掉这一个 ctx 的析构（scope 销毁时少 free
            // 一个小结构体），不影响面板行为。注意这是**泄漏而非悬垂**：ctx 本身
            // 仍然有效，事件回调照常能用。devtools 面板生命周期内数量有界，
            // 不为它把调试工具变成会 panic 的东西。
        }.destroy) catch {};

        const mounted_input = try Input(.{
            .initial_value = val_str,
            .size = .sm,
            .width = 80,
            .on_change = core.Cx.strHandlerFrom(EditCommitCtx, commit_ctx, editFieldChanged),
        }).mountResult(details_scope, cx);
        mounted_input.input_container.meta.ownership.meta.test_id = switch (field) {
            .gap => "devtools.style.gap.input",
            .flex => "devtools.style.flex.input",
            .flex_shrink => "devtools.style.flex_shrink.input",
            .opacity => "devtools.getOpacity().input",
            .translate_x => "devtools.style.translate_x.input",
            .translate_y => "devtools.style.translate_y.input",
            .border_width => "devtools.style.border_width.input",
            .border_radius => "devtools.style.border_radius.input",
        };
        try row.appendChild(cx.allocator, mounted_input.node);
        try appendStyleSourceLink(cx, state, node, field.sourceField(), row);

        // 自动聚焦真实 input_container，确保后续 text_input 命中输入框本身。
        cx.setFocus(mounted_input.input_container);

        try parent.appendChild(cx.allocator, row);
    } else {
        // 显示模式：值可点击
        const row = try cx.createNode(.box, .{
            .direction = .row,
            .gap = 8,
            .align_items = .center,
            .height = .{ .px = 16 },
        });
        try row.appendChild(cx.allocator, try core.text(cx, field.label(), .{
            .font_size = 10,
            .color = t.color.fg_secondary,
        }));

        // 可点击的值
        var val_buf2: [12]u8 = undefined;
        const val_text = try inlineText(cx, dv_fmt.fmtFloat(&val_buf2, val), t.color.accent, 10);
        val_text.style.cursor = .pointer;
        val_text.meta.ownership.meta.test_id = switch (field) {
            .gap => "devtools.style.gap.value",
            .flex => "devtools.style.flex.value",
            .flex_shrink => "devtools.style.flex_shrink.value",
            .opacity => "devtools.getOpacity().value",
            .translate_x => "devtools.style.translate_x.value",
            .translate_y => "devtools.style.translate_y.value",
            .border_width => "devtools.style.border_width.value",
            .border_radius => "devtools.style.border_radius.value",
        };

        // 点击事件
        const edit_ctx = try details_scope.allocator.create(EditFieldCtx);
        edit_ctx.* = .{ .state = state, .node_id = node.id, .field = field };
        details_scope.adoptResource(@ptrCast(edit_ctx), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const c: *EditFieldCtx = @ptrCast(@alignCast(ptr));
                alloc.destroy(c);
            }
            // 诊断路径：注册失败只会漏掉这一个 ctx 的析构（scope 销毁时少 free
            // 一个小结构体），不影响面板行为。注意这是**泄漏而非悬垂**：ctx 本身
            // 仍然有效，事件回调照常能用。devtools 面板生命周期内数量有界，
            // 不为它把调试工具变成会 panic 的东西。
        }.destroy) catch {};
        val_text.behavior.events.on_event = editFieldClickEvent;
        val_text.behavior.events.event_context = edit_ctx;

        try row.appendChild(cx.allocator, val_text);
        try appendStyleSourceLink(cx, state, node, field.sourceField(), row);
        try parent.appendChild(cx.allocator, row);
    }
}

fn editFieldClickEvent(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    const ctx: *EditFieldCtx = @ptrCast(@alignCast(context.?));
    ctx.state.editing_field = ctx.field;
    ctx.state.editing_node_id = ctx.node_id;
    ctx.state.details_dirty = true;
    if (ctx.state.cx) |c| c.needs_redraw = true;
    return .handled;
}

fn clearEditingState(state: *DevToolsState) void {
    state.editing_field = null;
    state.editing_node_id = null;
}

fn editFieldChanged(ctx: *EditCommitCtx, new_value: []const u8) void {
    const target = ctx.state.liveTarget() orelse return;
    const root = target.root orelse return;
    const node = findNodeById(root, ctx.node_id) orelse return;

    // 解析数值（中间态如 "-"/"1." 解析失败，静默等下一个键）
    const val = std.fmt.parseFloat(f32, new_value) catch return;
    ctx.field.writeValue(node, val);

    // 实时生效但**不**退出编辑：on_change 每个键击都触发，若在这里
    // clearEditingState + details_dirty，第一个键就会拆掉 Input，
    // 多位数值（如 "12"）永远输不进去。退出编辑走选中节点变化
    // （syncTreeSelection）或切换 tab（onDetailsTabChange）。
    target.needs_redraw = true;
}

// ========== 保留模式入口 ==========

/// 保留模式 mount（首帧调用一次）
pub fn mountPanel(cx: *Cx, target: *Cx, opts: PanelOptions) !*Node {
    const t = cx.tokens;
    const state = try getState(cx);
    // 任一步失败：root 由下面的 errdefer 整棵回收，state 里指向它的指针全部清零（不留悬垂）
    errdefer state.clearMountedNodeRefs();
    state.setTarget(target);
    state.cx = cx;
    state.title = opts.title;
    state.panel_opts = opts;
    state.tree_dirty = true;
    state.details_dirty = true;
    state.stats_dirty = true;
    state.last_seen_target_frame_count = target.frame_count;

    // 初始扁平化
    rebuildFlatRows(state, target);

    const root = try core.box(cx, .{
        .direction = .column,
        .background = t.color.bg_primary,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    }, .{});
    errdefer cx.freeNode(root);

    // 内容 scope 挂在 root scope 之下：失败路径上它随 Cx.root_scope 一起回收。
    state.scope = try Scope.init(cx.allocator, state.root_scope.?, cx.owner);
    try buildPanelContent(cx, target, state, root);

    try core.bindScopeToNode(state.root_scope.?, root);

    // root 节点挂 on_before_render 驱动保留模式更新
    root.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
    root.meta.per_frame.hooks.before_render.main = devtoolsBeforeRender;
    root.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
        fn cleanup(ctx_ptr: *anyopaque) void {
            const cleanup_cx: *Cx = @ptrCast(@alignCast(ctx_ptr));
            cleanup_cx.state_store.remove(DEVTOOLS_STATE_ID);
        }
    }.cleanup, @ptrCast(cx));

    return root;
}

/// 在 root 下构建面板全部内容（titlebar 占位 / header / inspect / console / perf），
/// 组件与资源归属 `state.scope`。mountPanel 首次构建与主题切换重建共用。
fn buildPanelContent(cx: *Cx, target: *Cx, state: *DevToolsState, root: *Node) !void {
    const t = cx.tokens;
    // 原来八个子树全部建成游离节点、最后才用 tuple 拼进 root —— 中间任一步失败
    // 前面建好的全漏（sweep：889 个注入点漏 872 个）。改成每个子树建好即 adopt；
    // root 由调用方兜底回收；state 里的节点指针全部在装配成功之后才发布。
    const a = cx.allocator;

    const titlebar_safe_top: f32 = 28;
    _ = try core.adoptChild(cx, a, root, try core.box(cx, .{
        .height = .{ .px = titlebar_safe_top },
        .background = t.color.bg_primary,
    }, .{}));

    _ = try core.adoptChild(cx, a, root, try buildHeader(cx, target, state.panel_opts, state));

    // Inspect shell: search + tree + stats + details
    const inspect_shell = try core.adoptChild(cx, a, root, try core.box(cx, .{
        .direction = .row,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    }, .{}));
    inspect_shell.meta.ownership.meta.test_id = "devtools.inspect.shell";

    const left_panel = try core.adoptChild(cx, a, inspect_shell, try core.box(cx, .{
        .direction = .column,
        .width = .{ .px = state.left_panel_width },
        .height = .{ .grow = .{} },
    }, .{}));
    left_panel.meta.ownership.meta.test_id = "devtools.left.panel";
    const left_panel_ext = try left_panel.style.ensureExtFallible(cx.allocator);
    // 左栏作为整块 chrome/内容壳，需要接住 search/header/tree 交界处的 seam hit。
    left_panel_ext.hit_roles = .{ .pointer = true, .scroll = true, .inspect = false };
    left_panel_ext.hit_behavior = .@"opaque";
    _ = try core.adoptChild(cx, a, left_panel, try buildSearchBar(cx, state));
    _ = try core.adoptChild(cx, a, left_panel, try mountTreeArea(cx, target, state));
    _ = try core.adoptChild(cx, a, left_panel, try mountStatsBar(cx, state, target));

    // Splitter: 垂直分割线
    _ = try core.adoptChild(cx, a, inspect_shell, try mountDevtoolsSplitter(cx, state));

    // 右面板: tab_bar + details content
    _ = try core.adoptChild(cx, a, inspect_shell, try mountDetails(cx, target, state));

    const console_shell = try core.adoptChild(cx, a, root, try mountConsoleShell(cx, target, state));
    console_shell.meta.ownership.meta.test_id = "devtools.console.shell";
    const perf_shell = try core.adoptChild(cx, a, root, try mountPerformanceShell(cx, state));
    perf_shell.meta.ownership.meta.test_id = "devtools.performance.shell";

    // 装配成功之后才发布节点指针（失败时 root 整棵回收，state 里不能留悬垂指针）
    state.left_panel_node = left_panel;
    state.inspect_shell_node = inspect_shell;
    state.perf_shell_node = perf_shell;
    state.console_shell_node = console_shell;
    syncShellVisibility(state);
}

/// Header 明暗开关的点击：只置位，真正的切换在下一帧 root hook 里做。
fn themeToggleEvent(event: Event, context: ?*anyopaque) EventResult {
    const state: *DevToolsState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    state.theme_toggle_pending = true;
    if (state.cx) |c| c.needs_redraw = true;
    return .handled;
}

/// 切换 DevTools 窗口的明暗主题并整棵重建面板内容。
///
/// 面板的大部分颜色在构建时从 cx.tokens 写死（raw box/text 没有主题 hook），
/// 单靠 Cx.setTheme 只能刷新组件，所以直接重建：套路同 detailsBeforeRender
/// ——先断交互引用、摘 hook/scope 指针，再 dispose 内容 scope，最后逐个 pop
/// 释放旧子树。必须在 root 的 before_render 里调用（tick 在递归子节点之前
/// 执行 root hook，替换 children 是安全的）。
fn applyThemeToggle(state: *DevToolsState, cx: *Cx, target: *Cx, root: *Node) void {
    const opts = state.panel_opts;
    const next = if (cx.tokens.scheme == .dark) opts.light_theme else opts.dark_theme;

    for (root.children.items) |child| cx.invalidateReferencesTo(child);
    for (root.children.items) |child| {
        hooks.invalidateSubtreeHookState(child);
        core.clearNodeScopes(child);
    }
    // details_scope 是内容 scope 的子 scope，随之一起 dispose。
    state.details_scope = null;
    if (state.scope) |s| s.dispose();
    state.scope = null;
    state.clearMountedNodeRefs();
    while (root.children.pop()) |child| {
        child.parent = null;
        cx.freeNode(child);
    }
    _ = state.arena.reset(.retain_capacity);
    // 编辑态的 Input 已随旧 details 释放，退出编辑，避免重建后抢焦点。
    clearEditingState(state);

    cx.setTheme(next);
    root.setBackground(next.color.bg_primary);

    // 诊断路径：重建失败上限是「面板这一帧是空的」；root 仍在、hook 仍在，
    // 用户再点一次开关（或关掉重开 DevTools 窗口）即可恢复。
    state.scope = Scope.init(cx.allocator, state.root_scope.?, cx.owner) catch return;
    buildPanelContent(cx, target, state, root) catch {
        state.clearMountedNodeRefs();
        while (root.children.pop()) |child| {
            child.parent = null;
            cx.freeNode(child);
        }
    };

    state.tree_dirty = true;
    state.details_dirty = true;
    state.stats_dirty = true;
    state.last_hovered_row = null;
    root.markLayoutDirty();
    root.markRenderDirty();
    root.markInteractionDirty();
}

/// 保留模式主更新钩子（每帧在布局前调用）
fn devtoolsBeforeRender(root_node: *Node) void {
    const state: *DevToolsState = @ptrCast(@alignCast(root_node.meta.per_frame.hooks.slots.anim_state orelse return));
    const target = state.liveTarget() orelse return;
    if (state.theme_toggle_pending) {
        state.theme_toggle_pending = false;
        if (state.cx) |dev_cx| applyThemeToggle(state, dev_cx, target, root_node);
    }
    syncShellVisibility(state);
    const cx = state.cx;

    // 无条件保活：DevTools 是被动观察者，target 的渲染不会推送唤醒它
    // （见 devtools_keepalive_ns 的说明）。scheduleRedrawAfterNs 内部按
    // 最近截止时间合并，重复调度无害；Performance 页由 perfBeforeRender
    // 以更高频率覆盖。
    if (cx) |dev_cx| {
        const poll_ns = switch (state.view_mode) {
            .console => console_keepalive_ns,
            .performance => perf_keepalive_ns,
            else => devtools_keepalive_ns,
        };
        dev_cx.scheduleRedrawAfterNs(poll_ns);
    }

    if (state.view_mode == .console) syncConsole(state, target);

    // 检测 target 窗口变化
    if (target.frame_count != state.last_seen_target_frame_count) {
        state.last_seen_target_frame_count = target.frame_count;
        state.stats_dirty = true;
        if (state.view_mode == .elements or state.view_mode == .components) {
            state.tree_dirty = true;
        }
        // details 只在 Render/Trace tab 时每帧更新（实时数据），
        // Layout/Style/State/Events tab 只在选中节点变化时更新（见 syncTreeSelection）
        if (state.active_tab == .render or state.active_tab == .trace) {
            state.details_dirty = true;
        }
    }

    // 选中节点变化时：展开祖先 + 标记需要滚动
    if (state.view_mode == .elements or state.view_mode == .components) syncTreeSelection(state, target);

    // 悬停行变化时补标脏：行 slot 的内容只在 tree_dirty 时重建，而 hover 会改变
    // 行的渲染结果（行尾的 goto 按钮）。不标脏的话按钮要等下一次因别的原因重建
    // 树时才出现——表现为「点一下才出来」。
    if (state.view_mode != .performance) {
        if (cx) |dev_cx| {
            const hovered_row = hoveredTreeRow(dev_cx);
            if (hovered_row != state.last_hovered_row) {
                state.last_hovered_row = hovered_row;
                state.tree_dirty = true;
            }
        }
    }

    // 只有树区域将要重建/滚动时才强制刷新 interaction index。
    // Performance 视图不显示树，继续每帧标脏会让 DevTools 自己产生无意义的 hit rebuild。
    if ((state.view_mode == .elements or state.view_mode == .components) and (state.tree_dirty or state.tree_auto_scroll_pending)) {
        root_node.markInteractionDirty();
    }

    // 更新树数据 + VirtualList
    if (state.tree_dirty) {
        rebuildFlatRows(state, target);
        if (state.vl_state) |vl| {
            virtual_list_mod.updateItemCount(vl, state.flat_rows.items.len);
        }
        // 自动滚动到选中节点（在 rebuildFlatRows 之后执行）
        applyTreeAutoScroll(state);
        syncViewModeTabs(state);

        state.tree_dirty = false;
        root_node.markRenderDirty();
    }

    // 同步 pick 按钮激活态（icon tint + background）
    if (state.pick_btn_node) |btn| {
        const is_active = target.inspector.pick_mode;
        const tokens = (state.cx orelse return).tokens;
        const pick_bg = if (is_active) tokens.color.accent else Color.TRANSPARENT;
        btn.setBackground(pick_bg);
        for (btn.children.items) |child| {
            const icon_tint = if (is_active) tokens.color.button_primary_fg else tokens.color.fg_secondary;
            _ = child.setTint(icon_tint);
            for (child.children.items) |grandchild| _ = grandchild.setTint(icon_tint);
        }
    }

    // 更新统计栏
    if (state.stats_dirty) {
        updateStatsBarContent(state, target);
        // Performance 模式下 stats_dirty 由 perfBeforeRender 清除
        // 非 Performance 模式下在此清除
        if (state.view_mode != .performance) {
            state.stats_dirty = false;
        }
    }

    // 详情内容在 detailsBeforeRender 中更新
}

/// 重建扁平化树行数据（持久化分配器上）
fn rebuildFlatRows(state: *DevToolsState, target: *Cx) void {
    state.flat_rows.clearRetainingCapacity();
    const root = target.root orelse return;
    const filter = if (state.filter_len > 0) state.filter_buf[0..state.filter_len] else "";
    switch (state.view_mode) {
        .elements => flattenTreeElements(state, root, 0, filter),
        .components => flattenTreeComponents(state, root, 0, filter),
        .console => {},
        .performance => {}, // performance 模式不需要树行
    }
}

/// 更新统计栏文本内容
fn updateStatsBarContent(state: *DevToolsState, target: *Cx) void {
    var stats = TreeStats{};
    if (target.root) |r| collectTreeStats(r, 0, &stats);
    const render_cmd_count = target.display_list.items.items.len;
    const signal_count = target.owner.signals.items.len;
    const effect_count = target.owner.effects.items.len;

    if (state.stats_nodes_text) |n| updateTextNode(state.allocator, n, "Nodes: {d}", .{stats.total_nodes});
    if (state.stats_depth_text) |n| updateTextNode(state.allocator, n, "Depth: {d}", .{stats.max_depth});
    if (state.stats_cmds_text) |n| updateTextNode(state.allocator, n, "Cmds: {d}", .{render_cmd_count});
    if (state.stats_se_text) |n| updateTextNode(state.allocator, n, "S:{d} E:{d}", .{ signal_count, effect_count });
    if (state.stats_frame_text) |n| updateTextNode(state.allocator, n, "F:{d}", .{target.frame_count});
}

fn updateTextNodeIfChanged(allocator: std.mem.Allocator, node: *Node, comptime fmt: []const u8, args: anytype) bool {
    if (node.getText()) |old| {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return false;
        if (std.mem.eql(u8, old.content, s)) return false;
        var tp = old;
        // Node.setText owns replacement of the old content and frees an old
        // owned allocation when the pointer changes. Do not pre-free here.
        setTextContent(allocator, &tp, s) catch return false;
        node.setText(tp);
        node.markLayoutDirty();
        return true;
    }
    return false;
}

fn updateTextNode(allocator: std.mem.Allocator, node: *Node, comptime fmt: []const u8, args: anytype) void {
    _ = updateTextNodeIfChanged(allocator, node, fmt, args);
}

fn replaceTextContent(allocator: std.mem.Allocator, t: *core.TextProps, src: []const u8) !void {
    if (t.owned and t.content.len > 0) {
        allocator.free(t.content);
    }
    try setTextContent(allocator, t, src);
}

/// 保留模式：mount inspect 树区域（VirtualList）
fn mountTreeArea(cx: *Cx, target: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    _ = target;

    // 外层容器（overflow_hidden 防止 VirtualList 内容溢出到 header/search bar 区域）
    const wrapper = try core.box(cx, .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .overflow_hidden = true,
    }, .{});
    errdefer cx.freeNode(wrapper); // VL 挂上之前 wrapper 游离

    // VirtualList（Elements/Components 树）
    const vl = try virtual_list_mod.VirtualList(.{
        .item_count = state.flat_rows.items.len,
        .item_height = tree_row_height,
        .overscan = 8,
        .padding = Padding.symmetric(4, 4),
        .background = t.color.bg_primary,
    }).mountWithContext(state.scope.?, cx, @ptrCast(state), null, renderTreeRowRetained);

    vl.container.style.height = .{ .grow = .{} };
    vl.container.style.width = .{ .grow = .{} };
    _ = try core.adoptChild(cx, cx.allocator, wrapper, vl.container);
    state.vl_state = vl.state;

    return wrapper;
}

fn mountPerformanceShell(cx: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    // shell 先建、ScrollArea 建好即 adopt，面板内容再往 content 里填（失败时 shell 整棵回收）
    const shell = try core.box(cx, .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .px = 0 },
        .background = t.color.bg_primary,
    }, .{});
    errdefer cx.freeNode(shell);
    var perf_scroll = try mountScrollArea(.{
        .padding = Padding.symmetric(8, 10),
        .background = t.color.bg_primary,
    }, state.scope.?, cx);
    _ = try core.adoptChild(cx, cx.allocator, shell, perf_scroll.container);
    perf_scroll.container.style.width = .{ .grow = .{} };
    perf_scroll.container.style.height = .{ .grow = .{} };
    perf_scroll.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
    perf_scroll.content.meta.per_frame.hooks.before_render.main = perfBeforeRender;
    try mountPerformancePanel(cx, perf_scroll.content, t, state);
    return shell;
}

const ConsoleFilterCtx = struct { state: *DevToolsState };
const ConsoleLevelCtx = struct { state: *DevToolsState, level: console_mod.Level };
const ConsoleSourceCtx = struct {
    cx: *Cx,
    source: ?console_mod.SourceLocation = null,
};

fn consoleSourceEvent(event: Event, context: ?*anyopaque) EventResult {
    const source_ctx: *ConsoleSourceCtx = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    const source = source_ctx.source orelse return .ignored;
    source_link.open(source_ctx.cx.allocator, .{
        .file = source.file,
        .line = source.line,
        .col = source.column,
        .label = "console",
    }) catch {};
    return .stop;
}

fn mountConsoleShell(cx: *Cx, target: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    const scope = state.scope.?;
    const a = cx.allocator;
    // shell → toolbar 先建（errdefer 兜底整棵），子节点建好即 adopt，state 指针挂稳后发布。
    const shell = try core.box(cx, .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .px = 0 },
        .background = t.color.bg_primary,
    }, .{});
    errdefer cx.freeNode(shell);
    const toolbar = try core.adoptChild(cx, a, shell, try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .width = .{ .grow = .{} },
        .height = .{ .px = 44 },
        .flex_shrink = 0,
        .padding = Padding.symmetric(6, 10),
        .background = t.color.bg_secondary,
        .border = .{
            .width = 0,
            .color = t.color.border,
            .side_widths = .{ 0, 0, 1, 0 },
        },
    }, .{}));
    toolbar.meta.ownership.meta.test_id = "devtools.console.toolbar";

    const clear_btn = try core.adoptChild(cx, a, toolbar, try Button(.{
        .label = "Clear",
        .variant = .ghost,
        .size = .xs,
        .on_click = Cx.handlerFrom(DevToolsState, state, clearConsolePanel),
        .style = .{
            .height = .{ .px = 28 },
            .padding = Padding.symmetric(0, 10),
            .background = t.color.bg_primary,
            .border = .{ .width = 1, .color = t.color.border, .radius = 5 },
            .text_color = t.color.fg_secondary,
            .font_weight = 600,
        },
        .hover_style = .{
            .background = t.color.accent.withAlpha(18),
            .border_color = t.color.accent.withAlpha(110),
            .text_color = t.color.fg_primary,
        },
    }).mount(scope, cx));
    clear_btn.meta.ownership.meta.test_id = "devtools.console.clear";

    const filter_ctx = try allocScopeResource(scope, ConsoleFilterCtx);
    filter_ctx.* = .{ .state = state };
    const filter = try core.adoptChild(cx, a, toolbar, try Input(.{
        .placeholder = "Filter console output",
        .initial_value = state.console_filter_buf[0..state.console_filter_len],
        .size = .sm,
        .width = 320,
        .on_change = Cx.strHandlerFrom(ConsoleFilterCtx, filter_ctx, consoleFilterChanged),
    }).mount(scope, cx));
    filter.meta.ownership.meta.test_id = "devtools.console.filter";
    // The filter is the flexible part of the toolbar. Its configured width is
    // only the preferred standalone size; inside DevTools it must consume all
    // space left between Clear and the fixed-width level controls.
    filter.style.width = .{ .grow = .{ .min = 120 } };
    filter.style.flex_shrink = 1;

    _ = try core.adoptChild(cx, a, toolbar, try core.box(cx, .{
        .width = .{ .px = 1 },
        .height = .{ .px = 20 },
        .background = t.color.border.withAlpha(170),
        .margin = Padding.symmetric(0, 2),
    }, .{}));

    _ = try core.adoptChild(cx, a, toolbar, try core.text(cx, "Levels", .{
        .font_size = 10,
        .font_weight = 600,
        .color = devtoolsMuted(t),
    }));

    const level_group = try core.adoptChild(cx, a, toolbar, try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 1,
        .padding = Padding.all(2),
        .background = t.color.bg_primary,
        .border = .{ .width = 1, .color = t.color.border, .radius = 6 },
    }, .{}));

    const levels = [_]struct { level: console_mod.Level, label: []const u8 }{
        .{ .level = .debug, .label = "Debug" },
        .{ .level = .log, .label = "Log" },
        .{ .level = .info, .label = "Info" },
        .{ .level = .warn, .label = "Warn" },
        .{ .level = .err, .label = "Error" },
    };
    var level_buttons: [state.console_level_buttons.len]?*Node = .{null} ** state.console_level_buttons.len;
    inline for (levels) |item| {
        const ctx = try allocScopeResource(scope, ConsoleLevelCtx);
        ctx.* = .{ .state = state, .level = item.level };
        const button = try core.adoptChild(cx, a, level_group, try Button(.{
            .label = item.label,
            .variant = .ghost,
            .size = .xs,
            .on_click = Cx.handlerFrom(ConsoleLevelCtx, ctx, toggleConsoleLevel),
            .style = .{
                .height = .{ .px = 24 },
                .padding = Padding.symmetric(0, 7),
                .border = .{ .radius = 4 },
                .text_color = consoleLevelColor(t, item.level),
                .font_size = 10,
                .font_weight = 600,
            },
            .hover_style = .{
                .background = t.color.fg_primary.withAlpha(12),
            },
        }).mount(scope, cx));
        button.meta.ownership.meta.test_id = "devtools.console.level";
        level_buttons[@intFromEnum(item.level)] = button;
    }

    const vl = try virtual_list_mod.VirtualList(.{
        .item_count = 0,
        .item_height = 30,
        .overscan = 12,
        .padding = Padding.ZERO,
        .background = t.color.bg_primary,
    }).mountWithContext(scope, cx, @ptrCast(state), null, renderConsoleRow);
    _ = try core.adoptChild(cx, a, shell, vl.container);
    vl.container.style.width = .{ .grow = .{} };
    vl.container.style.height = .{ .grow = .{} };
    vl.container.meta.ownership.meta.test_id = "devtools.console.list";

    const status = try core.adoptChild(cx, a, shell, try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .width = .{ .grow = .{} },
        .height = .{ .px = 22 },
        .padding = Padding.symmetric(2, 8),
        .background = t.color.bg_secondary,
        .border = .{
            .width = 0,
            .color = t.color.border,
            .side_widths = .{ 1, 0, 0, 0 },
        },
    }, .{}));
    const status_text = try core.adoptChild(cx, a, status, try core.text(cx, "0 messages", .{ .font_size = 10, .color = t.color.fg_secondary }));
    status_text.meta.ownership.meta.test_id = "devtools.console.status";

    // 整棵装配成功之后才发布 state 指针
    state.console_filter_node = filter;
    state.console_toolbar_node = toolbar;
    for (level_buttons, 0..) |btn, i| state.console_level_buttons[i] = btn;
    syncConsoleLevelButtons(state);
    state.console_vl_state = vl.state;
    state.console_status_text = status_text;
    _ = target;
    return shell;
}

fn clearConsolePanel(state: *DevToolsState) void {
    const target = state.liveTarget() orelse return;
    target.console().clear();
    clearConsoleMirror(state);
    state.console_cursor = 0;
    state.console_clear_generation +%= 1;
    rebuildConsoleFilter(state);
    if (state.cx) |cx| cx.needs_redraw = true;
}

fn consoleFilterChanged(ctx: *ConsoleFilterCtx, value: []const u8) void {
    const len = @min(value.len, ctx.state.console_filter_buf.len);
    @memcpy(ctx.state.console_filter_buf[0..len], value[0..len]);
    ctx.state.console_filter_len = @intCast(len);
    rebuildConsoleFilter(ctx.state);
    if (ctx.state.cx) |cx| cx.needs_redraw = true;
}

fn toggleConsoleLevel(ctx: *ConsoleLevelCtx) void {
    const bit: u8 = @as(u8, 1) << @intCast(@intFromEnum(ctx.level));
    ctx.state.console_level_mask ^= bit;
    syncConsoleLevelButtons(ctx.state);
    rebuildConsoleFilter(ctx.state);
    if (ctx.state.cx) |cx| cx.needs_redraw = true;
}

fn consoleLevelColor(t: *const theme.ThemeTokens, level: console_mod.Level) Color {
    return switch (level) {
        .debug => devtoolsMuted(t),
        .log => t.color.fg_primary,
        .info => t.color.accent,
        .warn => t.color.warning,
        .err => t.color.danger,
    };
}

fn syncConsoleLevelButtons(state: *DevToolsState) void {
    const cx = state.cx orelse return;
    for (&state.console_level_buttons, 0..) |*maybe_button, index| {
        const button = maybe_button.* orelse continue;
        const bit: u8 = @as(u8, 1) << @intCast(index);
        const enabled = (state.console_level_mask & bit) != 0;
        button_mod.setBackgroundOverride(button, if (enabled) cx.tokens.color.accent.withAlpha(22) else Color.TRANSPARENT);
        button.setOpacity(if (enabled) 1 else 0.46);
    }
}

fn syncConsole(state: *DevToolsState, target: *Cx) void {
    const console = target.console();
    const revision = console.revision();
    if (revision == state.console_revision) return;
    var evicted_total: u64 = 0;
    var dropped_total: u64 = 0;
    while (true) {
        var snapshot = console.snapshotSince(state.allocator, state.console_cursor, 1024) catch return;
        defer state.allocator.free(snapshot.events);
        if (snapshot.clear_generation != state.console_clear_generation or snapshot.gap) {
            clearConsoleMirror(state);
            state.console_clear_generation = snapshot.clear_generation;
        }

        var moved: usize = 0;
        for (snapshot.events) |event| {
            state.console_events.append(state.allocator, event) catch break;
            moved += 1;
            state.console_cursor = event.seq;
        }
        // Events not moved into the mirror are still owned by the snapshot.
        for (snapshot.events[moved..]) |*event| event.deinit(state.allocator);
        if (moved != snapshot.events.len) return;

        // Mirror the target's eviction boundary so opening DevTools never
        // creates an unbounded second log store.
        if (snapshot.oldest_seq != 0) {
            var remove_count: usize = 0;
            while (remove_count < state.console_events.items.len and state.console_events.items[remove_count].seq < snapshot.oldest_seq) : (remove_count += 1) {
                state.console_events.items[remove_count].deinit(state.allocator);
            }
            if (remove_count > 0) {
                const remain = state.console_events.items.len - remove_count;
                std.mem.copyForwards(console_mod.Event, state.console_events.items[0..remain], state.console_events.items[remove_count..]);
                state.console_events.items.len = remain;
            }
        }
        evicted_total = snapshot.evicted_total;
        dropped_total = snapshot.dropped_oom + snapshot.dropped_oversize;
        if (!snapshot.has_more) break;
    }
    // Only acknowledge a revision after every page was mirrored. A transient
    // allocation failure therefore retries on the next DevTools poll.
    state.console_revision = revision;
    rebuildConsoleFilter(state);
    updateConsoleStatus(state, evicted_total, dropped_total);
}

fn clearConsoleMirror(state: *DevToolsState) void {
    for (state.console_events.items) |*event| event.deinit(state.allocator);
    state.console_events.clearRetainingCapacity();
    state.console_filtered_indices.clearRetainingCapacity();
}

fn rebuildConsoleFilter(state: *DevToolsState) void {
    state.console_filtered_indices.clearRetainingCapacity();
    const filter = state.console_filter_buf[0..state.console_filter_len];
    for (state.console_events.items, 0..) |event, index| {
        const bit: u8 = @as(u8, 1) << @intCast(@intFromEnum(event.level));
        if ((state.console_level_mask & bit) == 0) continue;
        if (filter.len != 0 and !consoleContainsIgnoreCase(event.message, filter) and !consoleContainsIgnoreCase(event.scope, filter)) continue;
        state.console_filtered_indices.append(state.allocator, index) catch break;
    }
    if (state.console_vl_state) |vl| {
        const old_total = @as(f32, @floatFromInt(vl.props.item_count)) * vl.props.item_height;
        const old_max_scroll = @max(@as(f32, 0), old_total - vl.scroll_state.viewport_height);
        const was_following_tail = vl.props.item_count == 0 or
            vl.scroll_state.scroll_y >= old_max_scroll - vl.props.item_height * 1.5;
        virtual_list_mod.updateItemCount(vl, state.console_filtered_indices.items.len);
        // Match browser consoles: follow new output only while the user is at
        // the tail. Scrolling upward creates an implicit scroll lock.
        if (was_following_tail and state.console_filtered_indices.items.len > 0) {
            virtual_list_mod.scrollToIndex(vl, state.console_filtered_indices.items.len - 1);
        }
    }
}

fn consoleContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var equal = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

fn updateConsoleStatus(state: *DevToolsState, evicted: u64, dropped: u64) void {
    const node = state.console_status_text orelse return;
    updateTextNode(state.allocator, node, "{d} shown / {d} captured  |  evicted {d}  dropped {d}", .{
        state.console_filtered_indices.items.len,
        state.console_events.items.len,
        evicted,
        dropped,
    });
}

fn renderConsoleRow(slot: *Node, filtered_index: usize, cx: *Cx, user_context: ?*anyopaque) void {
    const state: *DevToolsState = @ptrCast(@alignCast(user_context orelse return));
    if (filtered_index >= state.console_filtered_indices.items.len) return;
    const event_index = state.console_filtered_indices.items[filtered_index];
    if (event_index >= state.console_events.items.len) return;
    const event = &state.console_events.items[event_index];
    const t = cx.tokens;

    // VirtualList reuses a bounded pool of row nodes. Allocate one handler
    // context per pool slot and update its source on every rebind, avoiding a
    // per-frame allocation leak while making source-bearing rows clickable.
    const source_ctx: *ConsoleSourceCtx = if (slot.behavior.events.event_context) |ptr|
        @ptrCast(@alignCast(ptr))
    else blk: {
        const ctx = allocScopeResource(state.scope orelse return, ConsoleSourceCtx) catch return;
        slot.behavior.events.event_context = ctx;
        slot.behavior.events.on_event = consoleSourceEvent;
        break :blk ctx;
    };
    source_ctx.* = .{ .cx = cx, .source = event.source };
    slot.setCursor(if (event.source != null) .pointer else .default);

    slot.meta.ownership.meta.test_id = "devtools.console.row";
    slot.style.direction = .row;
    slot.style.align_items = .center;
    slot.style.width = .{ .grow = .{} };
    slot.style.gap = 7;
    slot.style.padding = .{
        .top = 3,
        .right = 10,
        .bottom = 3,
        .left = 10 + @as(f32, @floatFromInt(event.group_depth)) * 14,
    };
    slot.style.border = .{
        .width = 0,
        .color = t.color.border.withAlpha(90),
        .side_widths = .{ 0, 0, 1, 0 },
    };
    slot.setBackground(switch (event.level) {
        .warn => t.color.warning.withAlpha(12),
        .err => t.color.danger.withAlpha(14),
        else => Color.TRANSPARENT,
    });
    const level_color = consoleLevelColor(t, event.level);
    const level_dot = core.box(cx, .{
        .width = .{ .px = 6 },
        .height = .{ .px = 6 },
        .flex_shrink = 0,
        .background = level_color,
        .border = .{ .radius = 3 },
    }, .{}) catch return;
    slot.appendChild(cx.allocator, level_dot) catch return;

    const level = core.text(cx, event.level.label(), .{
        .font_size = 9,
        .font_weight = 600,
        .color = level_color,
    }) catch return;
    level.style.width = .{ .px = 34 };
    slot.appendChild(cx.allocator, level) catch return;

    if (event.scope.len > 0) {
        const scope_text = core.text(cx, event.scope, .{
            .font_size = 9,
            .font_weight = 600,
            .color = t.color.fg_secondary,
        }) catch return;
        const scope_badge = core.box(cx, .{
            .direction = .row,
            .align_items = .center,
            .height = .{ .px = 18 },
            .padding = Padding.symmetric(1, 5),
            .background = t.color.bg_secondary,
            .border = .{ .width = 1, .color = t.color.border.withAlpha(150), .radius = 4 },
        }, .{scope_text}) catch return;
        slot.appendChild(cx.allocator, scope_badge) catch return;
    }
    const message = core.text(cx, event.message, .{ .font_size = 12, .color = t.color.fg_primary }) catch return;
    message.meta.ownership.meta.test_id = "devtools.console.message";
    message.style.width = .{ .grow = .{} };
    message.style.overflow_hidden = true;
    slot.appendChild(cx.allocator, message) catch return;

    if (event.source) |source| {
        const basename = std.fs.path.basename(source.file);
        var buf: [160]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}:{d}", .{ basename, source.line }) catch basename;
        const source_node = core.text(cx, label, .{ .font_size = 9, .font_weight = 500, .color = t.color.accent }) catch return;
        slot.appendChild(cx.allocator, source_node) catch return;
    }
}

fn syncShellVisibility(state: *DevToolsState) void {
    const show_perf = state.view_mode == .performance;
    const show_console = state.view_mode == .console;
    const show_inspect = !show_perf and !show_console;
    // per-hook 计时只在 performance 面板打开时启用，普通帧免掉每 hook 两次时钟读取
    @import("core/render_engine/tick.zig").g_profile_hooks = show_perf;
    if (state.inspect_shell_node) |node| {
        if (!show_inspect) {
            if (!isZeroHeight(node)) {
                node.style.height = .{ .px = 0 };
                node.markSizingDirty();
            }
            node.setHitTestVisible(false);
            node.setOpacity(0);
        } else {
            if (!isGrowHeight(node)) {
                node.style.height = .{ .grow = .{} };
                node.markSizingDirty();
            }
            node.setHitTestVisible(true);
            node.setOpacity(1);
        }
    }
    if (state.console_shell_node) |node| {
        setShellVisible(node, show_console);
    }
    if (state.perf_shell_node) |node| {
        setShellVisible(node, show_perf);
    }
}

fn setShellVisible(node: *Node, visible: bool) void {
    if (visible) {
        if (!isGrowHeight(node)) {
            node.style.height = .{ .grow = .{} };
            node.markSizingDirty();
        }
        node.setHitTestVisible(true);
        node.setOpacity(1);
    } else {
        if (!isZeroHeight(node)) {
            node.style.height = .{ .px = 0 };
            node.markSizingDirty();
        }
        node.setHitTestVisible(false);
        node.setOpacity(0);
    }
}

fn isGrowHeight(node: *Node) bool {
    return switch (node.style.height) {
        .grow => true,
        else => false,
    };
}

fn isZeroHeight(node: *Node) bool {
    return switch (node.style.height) {
        .px => |v| @abs(v) <= 0.01,
        else => false,
    };
}

/// 预创建 Performance 面板所有节点（mount 时调用一次）
/// 每个节点建好即 adopt 进 container（append 失败它自己收尸），state 指针挂稳后再发布。
fn mountPerformancePanel(cx: *Cx, container: *Node, t: *const theme.ThemeTokens, state: *DevToolsState) !void {
    const allocator = cx.allocator;

    // 标题
    _ = try core.adoptChild(cx, allocator, container, try core.text(cx, "Frame Performance", .{
        .font_size = 12,
        .color = t.color.fg_primary,
        .font_weight = 600,
    }));

    // FPS 文本
    const fps_node = try core.adoptChild(cx, allocator, container, try core.text(cx, "FPS: 0", .{
        .font_size = 11,
        .color = t.color.success,
    }));
    fps_node.meta.ownership.meta.test_id = "devtools.perf.fps";
    state.perf_fps_text = fps_node;

    // 柱状图容器
    const bar_container = try core.adoptChild(cx, allocator, container, try core.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 80 },
        .direction = .row,
        .align_items = .end,
        .gap = 1,
        .background = t.color.bg_secondary,
        .padding = Padding.all(4),
        .border = .{ .radius = 4 },
    }, .{}));
    bar_container.setMarginTop(8);
    state.perf_bar_container = bar_container;

    // 预创建 bar 节点
    var i: u32 = 0;
    while (i < perf_chart_sample_count) : (i += 1) {
        const bar = try core.adoptChild(cx, allocator, bar_container, try core.box(cx, .{
            .width = .{ .px = 3 },
            .height = .{ .px = 2 },
            .background = t.color.border,
            .border = .{ .radius = 1 },
        }, .{}));
        state.perf_bars[i] = bar;
    }

    // 16ms 目标线标注
    const target_line = try core.adoptChild(cx, allocator, container, try core.text(cx, "  16.7ms target (60 FPS)", .{
        .font_size = 9,
        .color = devtoolsMuted(t),
    }));
    state.perf_target_text = target_line;

    // 4 行 timing 文本
    const timing_node = try core.adoptChild(cx, allocator, container, try core.text(cx, "Timing(us): --", .{
        .font_size = 10,
        .color = t.color.fg_secondary,
    }));
    timing_node.meta.ownership.meta.test_id = "devtools.perf.timing";
    timing_node.setMarginTop(8);
    state.perf_timing_text = timing_node;

    const summary_text = try core.adoptChild(cx, allocator, container, try core.text(cx, "Summary: --", .{
        .font_size = 10,
        .color = devtoolsMuted(t),
    }));
    summary_text.meta.ownership.meta.test_id = "devtools.perf.summary";
    state.perf_summary_text = summary_text;

    const interaction_text = try core.adoptChild(cx, allocator, container, try core.text(cx, "Interaction: --", .{
        .font_size = 10,
        .color = devtoolsMuted(t),
    }));
    interaction_text.meta.ownership.meta.test_id = "devtools.perf.interaction";
    state.perf_interaction_text = interaction_text;

    const cache_text = try core.adoptChild(cx, allocator, container, try core.text(cx, "Cache/Rebuild: --", .{
        .font_size = 10,
        .color = devtoolsMuted(t),
    }));
    cache_text.meta.ownership.meta.test_id = "devtools.perf.cache";
    state.perf_cache_text = cache_text;

    state.perf_mounted = true;
}

/// Performance 面板的 on_before_render — 增量更新（不销毁/重建节点）
fn perfBeforeRender(content_node: *Node) void {
    const state: *DevToolsState = @ptrCast(@alignCast(content_node.meta.per_frame.hooks.slots.anim_state orelse return));
    if (state.view_mode != .performance) return;
    if (!state.perf_mounted) return;
    const target = state.liveTarget() orelse return;
    const cx = state.cx orelse return;
    const t = cx.tokens;
    // 无条件保活（10Hz）：性能监控必须持续走，不依赖 target 是否在渲染。
    // 不能只在 target idle 时调度——那样某帧恰逢 target 活跃就断链（历史 bug）。
    cx.scheduleRedrawAfterNs(perf_keepalive_ns);

    // target 停帧检测：frame_count 长时间未推进 ⇒ 面板进入 idle 显示。
    const now_inst: ?std.time.Instant = std.time.Instant.now() catch null;
    if (target.frame_count != state.perf_seen_frame_count or state.perf_last_frame_change == null) {
        state.perf_seen_frame_count = target.frame_count;
        state.perf_last_frame_change = now_inst;
    }
    const target_idle = blk: {
        const last = state.perf_last_frame_change orelse break :blk false;
        const now = now_inst orelse break :blk false;
        break :blk now.since(last) > perf_idle_indicator_ns;
    };

    // 滚动时间桶推进（墙钟驱动，与 target 是否出帧无关）：
    // 每满 100ms 记一桶「桶内平均 FPS」，无帧 = 0。监控因此持续向前滚，
    // 而不是停帧后把最后 64 个渲染帧的快照冻在屏上。
    if (now_inst) |now| {
        if (state.perf_bucket_start) |bucket_start| {
            const dt_ns = now.since(bucket_start);
            if (dt_ns >= perf_bucket_ns) {
                const frames = target.frame_count -% state.perf_bucket_frames;
                const fps_val: f32 = if (frames == 0)
                    0.0
                else
                    @as(f32, @floatFromInt(frames)) * 1.0e9 / @as(f32, @floatFromInt(dt_ns));
                state.perf_live_fps[state.perf_live_head] = fps_val;
                state.perf_live_head = (state.perf_live_head + 1) % perf_chart_sample_count;
                state.perf_bucket_start = now;
                state.perf_bucket_frames = target.frame_count;
            }
        } else {
            state.perf_bucket_start = now;
            state.perf_bucket_frames = target.frame_count;
        }
    }

    // 当前 FPS：最近 ~1s（10 桶）已填充桶的平均。target idle 时自然掉到 0。
    const current_fps: u32 = blk: {
        var sum: f32 = 0;
        var n_buckets: usize = 0;
        var back: usize = 0;
        while (back < 10) : (back += 1) {
            const idx = (state.perf_live_head + perf_chart_sample_count - 1 - back) % perf_chart_sample_count;
            const val = state.perf_live_fps[idx];
            if (val < 0) continue;
            sum += val;
            n_buckets += 1;
        }
        if (n_buckets == 0) break :blk 0;
        break :blk @intFromFloat(@min(@as(f32, 999), @round(sum / @as(f32, @floatFromInt(n_buckets)))));
    };

    if (state.perf_fps_text) |n| {
        if (target_idle) {
            _ = updateTextNodeIfChanged(cx.allocator, n, "FPS: 0 — idle (not rendering)", .{});
        } else if (current_fps > 0) {
            _ = updateTextNodeIfChanged(cx.allocator, n, "FPS: {d} (last 1s) | frame avg {d:.1}ms", .{
                current_fps,
                1000.0 / @as(f32, @floatFromInt(current_fps)),
            });
        } else {
            _ = updateTextNodeIfChanged(cx.allocator, n, "FPS: 0", .{});
        }
        if (n.getText()) |old| {
            const refresh_hz = @max(1.0, target.display_refresh_hz);
            const fps_f: f32 = @floatFromInt(current_fps);
            const next_color = if (target_idle)
                devtoolsMuted(t)
            else if (fps_f >= refresh_hz * 0.9)
                t.color.success
            else if (fps_f >= refresh_hz * 0.5)
                t.color.warning
            else
                t.color.danger;
            if (!Color.eql(old.color, next_color)) {
                var tp = old;
                tp.color = next_color;
                n.setText(tp);
                n.markRenderDirty();
            }
        }
    }

    if (state.perf_target_text) |n| {
        const target_refresh_hz = @max(1.0, target.display_refresh_hz);
        const target_ms = 1000.0 / target_refresh_hz;
        _ = updateTextNodeIfChanged(cx.allocator, n, "  {d:.1}ms target ({d:.0} FPS)", .{
            target_ms,
            target_refresh_hz,
        });
    }

    // 更新 bar 的 height + color —— 时间桶滚动图：head 起往后读 = 最旧→最新。
    // 空桶（idle/未填充）画 2px 中性底线；有帧的桶画「桶平均帧时间」。
    // 桶平均会抹平单帧尖刺，阈值放宽到 1.1×/1.5× 目标周期，避免 60Hz 满帧
    // 时 16.7ms≈周期本身的抖动被误画成红柱。
    const target_ms: f32 = @floatCast(1000.0 / @as(f64, @floatCast(@max(1.0, target.display_refresh_hz))));
    var i: u32 = 0;
    while (i < perf_chart_sample_count) : (i += 1) {
        if (state.perf_bars[i]) |bar| {
            const val = state.perf_live_fps[(state.perf_live_head + @as(usize, i)) % perf_chart_sample_count];
            var bar_h: f32 = 2.0;
            var bar_color = t.color.border;
            if (val > 0) {
                const frame_ms = 1000.0 / val;
                bar_h = @max(2.0, @min(72.0, (frame_ms / target_ms) * 40.0));
                bar_color = if (frame_ms > target_ms * 1.5)
                    t.color.danger
                else if (frame_ms > target_ms * 1.1)
                    t.color.warning
                else
                    t.color.success;
            }
            const old_h = switch (bar.style.height) {
                .px => |v| v,
                else => 0,
            };
            if (@abs(old_h - bar_h) > 0.01) {
                bar.style.height = .{ .px = bar_h };
                bar.markSizingDirty();
            }
            bar.setBackground(bar_color);
        }
    }

    // 更新 timing 文本
    const perf = target.perf;
    if (state.perf_timing_text) |n| {
        // (encode_us/flush_us/wait_us/acquire_us/cpu_us/total_us 字段已删 — 0 write)
        _ = updateTextNodeIfChanged(cx.allocator, n, "Timing(us): layout {d} | render {d}", .{
            perf.layout_us, perf.render_us,
        });
    }
    if (state.perf_summary_text) |n| {
        _ = updateTextNodeIfChanged(cx.allocator, n, "Summary: hit {d} | registry {d} | mouse-hit {d} | redraw {d} | cache {d}/{d} | focus {d} | interaction {d}/{d}", .{
            perf.hit_test_count,
            perf.registry_resolve_count,
            perf.mouse_move_hit_test_count,
            perf.continuous_redraw_frames,
            perf.render_cache_hit,
            perf.render_cache_miss,
            perf.focus_rebuild_count,
            perf.interaction_full_rebuild_count,
            perf.interaction_partial_rebuild_count,
        });
    }
    if (state.perf_interaction_text) |n| {
        _ = updateTextNodeIfChanged(cx.allocator, n, "Interaction: hit {d} | registry {d} | mouse-hit {d} | redraw streak {d}", .{
            perf.hit_test_count,            perf.registry_resolve_count,
            perf.mouse_move_hit_test_count, perf.continuous_redraw_frames,
        });
    }
    if (state.perf_cache_text) |n| {
        _ = updateTextNodeIfChanged(cx.allocator, n, "Cache/Rebuild: cache hit/miss {d}/{d} | focus rebuild {d} | interaction full/partial {d}/{d}", .{
            perf.render_cache_hit,               perf.render_cache_miss,                 perf.focus_rebuild_count,
            perf.interaction_full_rebuild_count, perf.interaction_partial_rebuild_count,
        });
    }

    state.stats_dirty = false;
}

/// VirtualList 渲染回调（保留模式 — VirtualList 管理 slot 生命周期）
/// The tree-row slot the mouse is currently over, or null. Walks up from the
/// hovered node because the pointer usually lands on a row's text/glyph child.
fn hoveredTreeRow(cx: *Cx) ?*Node {
    var cur: ?*Node = cx.hovered_node;
    var guard: usize = 0;
    while (cur) |n| {
        if (n.meta.ownership.meta.test_id) |tid| {
            if (std.mem.eql(u8, tid, tree_row_test_id)) return n;
        }
        if (guard >= 64) return null; // 防御异常深/成环的父链
        guard += 1;
        cur = n.parent;
    }
    return null;
}

/// Whether `candidate` is `root` or sits inside it — hovering a row's text or
/// glyph should count as hovering the row.
fn isSelfOrAncestor(root: *Node, candidate: *Node) bool {
    var cur: ?*Node = candidate;
    var guard: usize = 0;
    while (cur) |n| {
        if (n == root) return true;
        if (guard >= 64) return false; // 防御异常深/成环的父链
        guard += 1;
        cur = n.parent;
    }
    return false;
}

/// 行内每个子节点原来都是「create 再 append」两步、append 失败 child 漏（mountPanel sweep 抓到）；
/// 全部改 adoptChild（append 失败它自己收尸）。
fn renderTreeRowRetained(node: *Node, index: usize, cx: *Cx, user_context: ?*anyopaque) void {
    const state: *DevToolsState = @ptrCast(@alignCast(user_context orelse return));
    if (index >= state.flat_rows.items.len) return;
    const entry = state.flat_rows.items[index];
    const target = state.liveTarget() orelse return;

    const t = cx.tokens;
    const s = theme_schema.window(t);
    const tree_node = entry.node;

    const is_selected = target.inspector.selected_node_id != null and target.inspector.selected_node_id.? == tree_node.id;
    const is_hovered = target.inspector.hover_node_id != null and target.inspector.hover_node_id.? == tree_node.id;

    const row_bg = if (is_selected) s.devtools_row_selected_bg else if (is_hovered) s.devtools_row_hover_bg else Color.TRANSPARENT;

    node.style.direction = .row;
    node.style.align_items = .center;
    node.style.gap = 4;
    node.style.padding = .{ .left = 4 + @as(f32, @floatFromInt(entry.depth)) * 12.0, .right = 4, .top = 0, .bottom = 0 };
    node.setBackgroundRaw(row_bg);
    node.style.width = .{ .grow = .{} };
    node.style.cursor = .pointer;
    node.meta.ownership.meta.test_id = tree_row_test_id;
    node.children.items.len = 0;

    // Expander
    if (entry.has_children) {
        const symbol = if (entry.collapsed) ">" else "v";
        _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, symbol, .{ .font_size = 9, .color = t.color.fg_secondary }) catch return) catch return;
    } else {
        _ = core.adoptChild(cx, cx.allocator, node, cx.createNode(.spacer, .{
            .width = .{ .px = 8 },
            .height = .{ .px = 12 },
        }) catch return) catch return;
    }

    // Tag / Component 名
    if (state.view_mode == .components) {
        if (tree_node.meta.ownership.meta.component_name) |comp_name| {
            _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, comp_name, .{ .font_size = 11, .color = s.devtools_component_label, .font_weight = 600 }) catch return) catch return;
        }
    } else {
        const tag_name = @tagName(tree_node.tag);
        _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, tag_name, .{ .font_size = 11, .color = tagColor(tree_node.tag, t) }) catch return) catch return;
        if (tree_node.meta.ownership.meta.component_name) |comp_name| {
            _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, comp_name, .{ .font_size = 10, .color = s.devtools_component_label, .font_weight = 600 }) catch return) catch return;
        }
    }

    // ID
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "#{d}", .{tree_node.id}) catch "";
    _ = core.adoptChild(cx, cx.allocator, node, inlineText(cx, id_str, devtoolsMuted(t), 10) catch return) catch return;

    if (tree_node.frame_state.state_bits.flags.inspect_pick_disabled) {
        _ = core.adoptChild(cx, cx.allocator, node, inlineText(cx, "pick-off", t.color.warning, 9) catch return) catch return;
    }

    // Children 数量
    if (entry.has_children) {
        var count_buf: [12]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "({d})", .{tree_node.children.items.len}) catch "";
        _ = core.adoptChild(cx, cx.allocator, node, inlineText(cx, count_str, devtoolsMuted(t), 9) catch return) catch return;
    }

    // 文本预览
    if (tree_node.getText()) |tp| {
        if (tp.content.len > 0) {
            const preview = tp.content[0..@min(tp.content.len, 30)];
            var preview_buf: [36]u8 = undefined;
            const preview_str = std.fmt.bufPrint(&preview_buf, "\"{s}\"", .{preview}) catch "";
            _ = core.adoptChild(cx, cx.allocator, node, inlineText(cx, preview_str, s.devtools_text_preview, 10) catch return) catch return;
        }
    }

    // Render dirty
    if (tree_node.frame_state.state_bits.dirty.core.render) {
        _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, "*", .{ .font_size = 10, .color = t.color.warning }) catch return) catch return;
    }

    // Goto-source：hover 时在行尾显示，点击用外部编辑器打开该组件的定义处。
    // 只有能解析出源码位置的行才显示——匿名节点和运行期拼名字的组件不在索引里，
    // 与其显示一个点了没反应的按钮，不如不显示。
    // 注意用 cx.hovered_node（DevTools 自己这个窗口的鼠标悬停），而不是上面的
    // is_hovered —— 后者读的是 target.inspector.hover_node_id，那是 pick 模式下
    // 鼠标悬停在**被检查的 app 窗口**上时才会被设置的，跟"鼠标停在这一行"无关。
    const row_hovered = if (cx.hovered_node) |h| isSelfOrAncestor(node, h) else false;
    const goto_name: ?[]const u8 = if (row_hovered and source_link.isConfigured())
        tree_node.meta.ownership.meta.component_name
    else
        null;
    if (goto_name) |name| resolve_goto: {
        if (!source_link.has(name)) break :resolve_goto;

        _ = core.adoptChild(cx, cx.allocator, node, cx.createNode(.spacer, .{ .width = .{ .grow = .{} } }) catch break :resolve_goto) catch break :resolve_goto;

        const btn = cx.createNode(.box, .{
            .padding = .{ .left = 4, .right = 4, .top = 0, .bottom = 0 },
            .cursor = .pointer,
        }) catch break :resolve_goto;
        // btn 挂到 node 之前 glyph 还可能失败 —— 门控 defer 守窗口（break 走的是正常退出，errdefer 不触发）
        var btn_owned = true;
        defer if (btn_owned) cx.freeNode(btn);
        btn.meta.ownership.meta.test_id = "devtools.tree.goto_source";
        _ = core.adoptChild(cx, cx.allocator, btn, inlineText(cx, "↗", s.devtools_component_label, 11) catch break :resolve_goto) catch break :resolve_goto;

        state.goto_ctx = .{
            .state = state,
            .node_id = tree_node.id,
            .action = .goto_source,
            .component_name = name,
        };
        btn.behavior.events.event_context = &state.goto_ctx;
        btn.behavior.events.on_event = rowEvent;
        btn_owned = false;
        _ = core.adoptChild(cx, cx.allocator, node, btn) catch break :resolve_goto;
    }

    // 点击事件 — 复用 slot 节点已有的 event_context，避免每次重新分配泄漏
    if (node.behavior.events.event_context) |old_ptr| {
        const old: *RowCtx = @ptrCast(@alignCast(old_ptr));
        old.* = .{ .state = state, .node_id = tree_node.id, .action = .select };
    } else {
        const scope = state.scope orelse return;
        const row_ctx = allocScopeResource(scope, RowCtx) catch return;
        row_ctx.* = .{ .state = state, .node_id = tree_node.id, .action = .select };
        node.behavior.events.event_context = row_ctx;
    }
    node.behavior.events.on_event = rowEvent;

    if (entry.has_children and node.children.items.len > 0) {
        const expander_node = node.children.items[0];
        // toggle RowCtx 存到 slot 节点的 focus_ring_anim 上（slot 不被销毁，避免子节点重建时泄漏）
        if (node.meta.per_frame.hooks.slots.focus_ring_anim) |old_ptr| {
            const old: *RowCtx = @ptrCast(@alignCast(old_ptr));
            old.* = .{ .state = state, .node_id = tree_node.id, .action = .toggle, .is_currently_collapsed = entry.collapsed };
            expander_node.behavior.events.event_context = old_ptr;
        } else {
            const scope = state.scope orelse return;
            const toggle_ctx = allocScopeResource(scope, RowCtx) catch return;
            toggle_ctx.* = .{ .state = state, .node_id = tree_node.id, .action = .toggle, .is_currently_collapsed = entry.collapsed };
            node.meta.per_frame.hooks.slots.focus_ring_anim = toggle_ctx;
            expander_node.behavior.events.event_context = toggle_ctx;
        }
        expander_node.behavior.events.on_event = rowEvent;
    }
}

/// 保留模式：mount 统计栏
fn mountStatsBar(cx: *Cx, state: *DevToolsState, target: *Cx) !*Node {
    const t = cx.tokens;
    const bar = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .width = .{ .grow = .{} },
        .height = .{ .px = 22 },
        .padding = Padding.symmetric(2, 8),
        .background = t.color.bg_tertiary,
        .border = .{ .width = 1, .color = t.color.border },
    }, .{});

    // 五个文字节点建好即 adopt，挂稳后才发布进 state（失败时 bar 整棵回收，state 不留悬垂）
    errdefer cx.freeNode(bar);
    const a = cx.allocator;
    const nodes_text = try core.adoptChild(cx, a, bar, try core.text(cx, "Nodes: 0", .{ .font_size = 10, .color = t.color.fg_secondary }));
    const depth_text = try core.adoptChild(cx, a, bar, try core.text(cx, "Depth: 0", .{ .font_size = 10, .color = t.color.fg_secondary }));
    const cmds_text = try core.adoptChild(cx, a, bar, try core.text(cx, "Cmds: 0", .{ .font_size = 10, .color = t.color.fg_secondary }));
    const se_text = try core.adoptChild(cx, a, bar, try core.text(cx, "S:0 E:0", .{ .font_size = 10, .color = t.color.fg_secondary }));
    const frame_text = try core.adoptChild(cx, a, bar, try core.text(cx, "F:0", .{ .font_size = 10, .color = devtoolsMuted(t) }));
    state.stats_nodes_text = nodes_text;
    state.stats_depth_text = depth_text;
    state.stats_cmds_text = cmds_text;
    state.stats_se_text = se_text;
    state.stats_frame_text = frame_text;

    // 初始更新
    updateStatsBarContent(state, target);

    return bar;
}

/// 保留模式：mount 详情面板（右侧面板）
fn mountDetails(cx: *Cx, target: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    _ = target;

    // wrapper 先建，tab_bar / ScrollArea 建好即 adopt；content 指针挂稳后再发布
    const wrapper = try core.box(cx, .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .border = .{ .width = 1, .color = t.color.border },
    }, .{});
    errdefer cx.freeNode(wrapper);
    wrapper.meta.ownership.meta.test_id = "devtools.details.panel";
    _ = try core.adoptChild(cx, cx.allocator, wrapper, try buildTabBar(cx, state));
    var content_scroll = try mountScrollArea(.{
        .padding = Padding.symmetric(4, 8),
        .background = t.color.bg_secondary,
    }, state.scope.?, cx);
    _ = try core.adoptChild(cx, cx.allocator, wrapper, content_scroll.container);
    content_scroll.container.style.height = .{ .grow = .{} };
    content_scroll.container.style.width = .{ .grow = .{} };

    // 保存 content 引用，用于 on_before_render 局部重建
    state.details_content = content_scroll.content;
    content_scroll.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
    content_scroll.content.meta.per_frame.hooks.before_render.main = detailsBeforeRender;
    return wrapper;
}

/// 详情面板 on_before_render：检测脏标记后局部重建内容
fn detailsBeforeRender(content_node: *Node) void {
    const state: *DevToolsState = @ptrCast(@alignCast(content_node.meta.per_frame.hooks.slots.anim_state orelse return));
    if (state.view_mode == .performance) return;
    if (!state.details_dirty) return;
    state.details_dirty = false;

    const cx = state.cx orelse return;
    const target = state.liveTarget() orelse return;
    const t = cx.tokens;

    // 先清理交互引用，确保 subtree 内的 blur/focus 回调在 scope 资源仍有效时完成。
    for (content_node.children.items) |child| {
        cx.invalidateReferencesTo(child);
    }

    // 断开旧 subtree 上的 scope 指针，再 dispose scope。
    // 这样后续 freeNode(child) 不会再次触碰已释放的 scope。
    for (content_node.children.items) |child| {
        hooks.invalidateSubtreeHookState(child);
        core.clearNodeScopes(child);
    }
    if (state.details_scope) |ds| ds.dispose();
    state.details_scope = null;

    // 最后释放旧子节点。
    //
    // 逐个 pop 而不是 `for (children.items) |child| freeNode(child)`：tick 期间
    // 的 freeNode 会走 removeChildIncremental → children.orderedRemove(i)，即
    // 边遍历边改动正在遍历的数组，后续迭代会跳过元素并最终读到已失效的槽位
    // （表现为 invalidateHandlesInSubtree 递归时解引用 0xaaaa… 毒值 segfault）。
    // 先摘链再交给 freeNode，父子链已断，removeChildIncremental 便是 no-op。
    while (content_node.children.pop()) |child| {
        child.parent = null;
        cx.freeNode(child);
    }

    // 回收 frame arena：Trace/State tab 的事件 ctx（TracePauseCtx/
    // TraceClickCtx 等）都从这里分配、且只被刚释放的旧子树引用。
    // 不 reset 的话 Trace tab + 60fps target 下每次重建 ~1-2KB 只增不减，
    // 面板开一小时就是可观的泄漏。
    _ = state.arena.reset(.retain_capacity);

    // 创建新 scope
    state.details_scope = Scope.init(cx.allocator, state.scope, cx.owner) catch null;

    const selected_id = target.inspector.selected_node_id orelse target.inspector.hover_node_id;

    // 诊断路径：content_node 每帧从被选中节点重新构建，这里的 catch {} 失败
    // 上限是「本帧详情页少显示一段内容」，下一帧重建即自愈；被调试 app 不受影响。
    if (state.active_tab == .trace) {
        buildTraceTab(cx, target, state, content_node) catch {};
    } else if (selected_id == null or target.root == null) {
        const no_sel = core.text(cx, "No selection", .{ .font_size = 11, .color = t.color.fg_secondary }) catch return;
        content_node.appendChild(cx.allocator, no_sel) catch {};
    } else {
        const root = target.root.?;
        const node = findNodeById(root, selected_id.?);
        if (node) |n| {
            switch (state.active_tab) {
                .layout => buildLayoutTab(cx, state, n, content_node) catch {},
                .style => buildStyleTab(cx, state, n, content_node) catch {},
                .state => buildStateTab(cx, target, state, n, content_node) catch {},
                .events => buildEventsTab(cx, target, n, content_node) catch {},
                .render => buildRenderTab(cx, target, n, content_node) catch {},
                .trace => unreachable,
            }
        } else {
            const not_found = core.text(cx, "Node not found", .{ .font_size = 11, .color = t.color.fg_secondary }) catch return;
            content_node.appendChild(cx.allocator, not_found) catch {};
        }
    }
    content_node.markLayoutDirty();
}

// ========== 面板头部 ==========

fn buildHeader(cx: *Cx, target: *Cx, opts: PanelOptions, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    const a = cx.allocator;
    const scope = state.scope.?;
    // header 先建、errdefer 兜底整棵；子树建好即 adopt（append 失败它自己收尸）。
    var header = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .width = .{ .grow = .{} },
        .height = .{ .px = 32 },
        .padding = Padding.symmetric(4, 10),
        .background = t.color.bg_secondary,
        .border = .{ .width = 1, .color = t.color.border },
    }, .{});
    errdefer cx.freeNode(header);
    header.meta.ownership.meta.test_id = "devtools.header.shell";
    const header_ext = try header.style.ensureExtFallible(cx.allocator);
    // Header 是固定 chrome，不应把滚动漏给下方 tree/details ScrollArea。
    header_ext.hit_roles = .{ .pointer = true, .scroll = true, .inspect = false };
    header_ext.hit_behavior = .@"opaque";

    // 左侧: 选择元素按钮 + 标题 + 视图切换
    const left = try core.adoptChild(cx, a, header, try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 8,
    }, .{}));
    left.meta.ownership.meta.test_id = "devtools.header.left";

    // "选择元素"按钮 → Button 组件 + SVG icon
    {
        const is_pick_active = target.inspector.pick_mode;

        const pick_ctx = try allocScopeResource(scope, PickModeCtx);
        pick_ctx.* = .{ .state = state };

        const pick_btn = try core.adoptChild(cx, a, left, try Button(.{
            .icon_only = true,
            .icon_asset = svg_assets.common.scan,
            .variant = if (is_pick_active) .primary else .ghost,
            .size = .xs,
            .icon_size = 14,
            .on_event = pickModeEvent,
            .event_context = pick_ctx,
        }).mount(scope, cx));
        state.pick_btn_node = pick_btn;
    }

    _ = try core.adoptChild(cx, a, left, try core.text(cx, state.title, .{
        .font_size = 12,
        .color = t.color.fg_primary,
        .font_weight = 600,
    }));

    // 视图切换 → underline Tabs
    const mode_items = [_]TabItem{
        .{ .id = "elements", .label_text = "Elements" },
        .{ .id = "components", .label_text = "Components" },
        .{ .id = "console", .label_text = "Console" },
        .{ .id = "performance", .label_text = "Performance" },
    };
    const mode_tabs = try core.adoptChild(cx, a, left, try Tabs(.{
        .items = &mode_items,
        .default_active_id = viewModeId(state.view_mode),
        .variant = .underline,
        .size = .xs,
        // 并轨后：strHandlerFrom 把 context 与回调捆在一起，payload 即 tab id。
        .on_change = core.Cx.strHandlerFrom(DevToolsState, state, applyViewModeById),
    }).mount(scope, cx));
    mode_tabs.meta.ownership.meta.test_id = "devtools.view-mode.tabs";
    state.view_mode_tabs_node = mode_tabs;
    state.view_mode_tabs_state = tabsStateFromNode(mode_tabs);

    // 右侧: 明暗切换 + 关闭
    const right = try core.adoptChild(cx, a, header, try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 4,
    }, .{}));
    right.meta.ownership.meta.test_id = "devtools.header.right";

    // 明暗切换：显示「点了会切到」的那一侧图标（暗色下显示太阳）
    {
        const theme_btn = try core.adoptChild(cx, a, right, try Button(.{
            .icon_only = true,
            .icon_asset = if (t.scheme == .dark) system_icons.sun else system_icons.moon,
            .variant = .ghost,
            .size = .xs,
            .icon_size = 14,
            .on_event = themeToggleEvent,
            .event_context = state,
        }).mount(scope, cx));
        theme_btn.meta.ownership.meta.test_id = "devtools.theme.toggle";
    }

    // 关闭按钮 → Button 组件
    if (opts.on_close) |h| {
        const close_ctx = try allocScopeResource(scope, CloseCtx);
        close_ctx.* = .{ .handler = h };

        const close_btn = try core.adoptChild(cx, a, right, try Button(.{
            .icon_only = true,
            .icon_asset = svg_assets.common.x_close,
            .variant = .ghost,
            .size = .xs,
            .icon_size = 12,
            .on_event = closeEvent,
            .event_context = close_ctx,
        }).mount(scope, cx));
        close_btn.meta.ownership.meta.test_id = "devtools.close";
    } else {
        // 即使没有 on_close handler 也显示一个占位
        const close_btn = try core.adoptChild(cx, a, right, try Button(.{
            .icon_only = true,
            .icon_asset = svg_assets.common.x_close,
            .variant = .ghost,
            .size = .xs,
            .icon_size = 12,
        }).mount(scope, cx));
        close_btn.meta.ownership.meta.test_id = "devtools.close";
    }

    return header;
}

// ========== 搜索栏 ==========

fn buildSearchBar(cx: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    const scope = state.scope.?;

    const filter_ctx = try scope.allocator.create(FilterChangeCtx);
    filter_ctx.* = .{ .state = state };
    scope.adoptResource(@ptrCast(filter_ctx), struct {
        fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const c: *FilterChangeCtx = @ptrCast(@alignCast(ptr));
            alloc.destroy(c);
        }
    }.destroy) catch {};

    // shell 先建、Input 建好即 adopt（失败时 shell 整棵回收）
    const shell = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .padding = Padding.symmetric(6, 8),
        .background = t.color.bg_secondary,
        .overflow_hidden = true,
    }, .{});
    errdefer cx.freeNode(shell);
    const mounted_input = try Input(.{
        .placeholder = "Filter (tag, #id)...",
        .initial_value = state.filter_buf[0..state.filter_len],
        .size = .sm,
        .leading_icon_asset = svg_assets.common.search,
        .on_change = core.Cx.strHandlerFrom(FilterChangeCtx, filter_ctx, filterInputChanged),
    }).mountResult(scope, cx);
    const input_node = try core.adoptChild(cx, cx.allocator, shell, mounted_input.node);
    input_node.style.width = .{ .grow = .{} };
    input_node.meta.ownership.meta.test_id = "devtools.search.input";
    mounted_input.input_container.meta.ownership.meta.test_id = "devtools.search.input.control";
    shell.meta.ownership.meta.test_id = "devtools.search.shell";
    shell.setInteractionDelegate(mounted_input.input_container);
    const shell_ext = try shell.style.ensureExtFallible(cx.allocator);
    // Search 区也是固定 chrome；并且给 input 留出内边距，避免它贴在上下分界线上和 header/tree 抢命中。
    shell_ext.hit_roles = .{ .pointer = true, .scroll = true, .inspect = false };
    shell_ext.hit_behavior = .@"opaque";
    return shell;
}

/// 子树节点总数的快速估算（有上限截断，避免深递归）
fn countSubtreeNodes(node: *Node, limit: u32) u32 {
    var count: u32 = 1;
    for (node.children.items) |child| {
        count += countSubtreeNodes(child, limit);
        if (count >= limit) return limit;
    }
    return count;
}

/// 子节点数量超过此阈值时，DevTools 默认折叠（除非用户手动展开）
const auto_collapse_threshold: usize = 500;
/// 树区域最大渲染行数上限，防止卡死
const max_visible_rows: u32 = 2000;
const tree_row_height: f32 = 20;
const tree_reveal_margin_top: f32 = 8;
const tree_reveal_margin_bottom: f32 = 12;

// ========== 扁平化树条目（VirtualList 数据源） ==========

const FlatTreeEntry = struct {
    node: *Node,
    depth: u32,
    has_children: bool,
    collapsed: bool,
};

/// 将 UI 树递归扁平化为索引数组（Elements 视图）
fn flattenTreeElements(state: *DevToolsState, node: *Node, depth: u32, filter: []const u8) void {
    if (state.flat_rows.items.len >= max_visible_rows) return;

    if (!node.frame_state.state_bits.flags.inspectable) {
        for (node.children.items) |child| {
            flattenTreeElements(state, child, depth, filter);
            if (state.flat_rows.items.len >= max_visible_rows) return;
        }
        return;
    }

    // 过滤检查
    if (filter.len > 0) {
        if (!nodeMatchesFilter(node, filter)) {
            var any_child_match = false;
            for (node.children.items) |child| {
                if (subtreeMatchesFilter(child, filter, 0)) {
                    any_child_match = true;
                    break;
                }
            }
            if (!any_child_match) return;
        }
    }

    const has_children = node.children.items.len > 0;
    const subtree_size: u32 = if (!has_children)
        1
    else if (node.children.items.len >= auto_collapse_threshold)
        auto_collapse_threshold + 1
    else
        countSubtreeNodes(node, auto_collapse_threshold + 1);
    const auto_collapsed = has_children and subtree_size >= auto_collapse_threshold and !state.isExplicitlyExpanded(node.id);
    // 有过滤串时不做折叠：能走到这里的节点要么自己匹配、要么子树里有匹配，
    // 折叠会把用户正在搜的那一行藏起来，搜索就等于失效了。
    const collapsed = if (filter.len > 0) false else (state.isCollapsed(node.id) or auto_collapsed);

    // 诊断路径：flat_rows 是元素树面板的显示行缓冲，每次 rebuildFlatRows 都
    // clear 后整体重建。append 失败 = 这一帧树里少一行，下次重建自愈。
    _ = state.flat_rows.append(state.allocator, FlatTreeEntry{
        .node = node,
        .depth = depth,
        .has_children = has_children,
        .collapsed = collapsed,
    }) catch {};

    if (has_children and !collapsed) {
        for (node.children.items) |child| {
            flattenTreeElements(state, child, depth + 1, filter);
            if (state.flat_rows.items.len >= max_visible_rows) return;
        }
    }
}

/// 将 UI 树递归扁平化（Components 视图）
fn flattenTreeComponents(state: *DevToolsState, node: *Node, depth: u32, filter: []const u8) void {
    if (state.flat_rows.items.len >= max_visible_rows) return;

    if (!node.frame_state.state_bits.flags.inspectable) {
        for (node.children.items) |child| {
            flattenTreeComponents(state, child, depth, filter);
            if (state.flat_rows.items.len >= max_visible_rows) return;
        }
        return;
    }

    const is_component = node.meta.ownership.meta.component_name != null;
    if (is_component) {
        if (filter.len > 0) {
            if (!componentMatchesFilter(node, filter) and !subtreeHasMatchingComponent(node, filter)) return;
        }
        const has_component_kids = hasComponentChildren(node);
        const collapsed = state.isCollapsed(node.id);

        // 诊断路径：同 flattenTreeElements —— 每帧重建的显示行缓冲。
        _ = state.flat_rows.append(state.allocator, FlatTreeEntry{
            .node = node,
            .depth = depth,
            .has_children = has_component_kids,
            .collapsed = collapsed,
        }) catch {};

        if (has_component_kids and !collapsed) {
            flattenComponentChildren(state, node, depth + 1, filter);
        }
    } else {
        for (node.children.items) |child| {
            flattenTreeComponents(state, child, depth, filter);
            if (state.flat_rows.items.len >= max_visible_rows) return;
        }
    }
}

fn flattenComponentChildren(state: *DevToolsState, node: *Node, depth: u32, filter: []const u8) void {
    for (node.children.items) |child| {
        if (state.flat_rows.items.len >= max_visible_rows) return;
        if (child.meta.ownership.meta.component_name != null) {
            flattenTreeComponents(state, child, depth, filter);
        } else {
            flattenComponentChildren(state, child, depth, filter);
        }
    }
}

/// 检查节点子树中是否有任何组件子节点
fn hasComponentChildren(node: *Node) bool {
    for (node.children.items) |child| {
        if (child.meta.ownership.meta.component_name != null) return true;
        if (hasComponentChildren(child)) return true;
    }
    return false;
}

/// 查找节点子树中第一个文本内容
fn findFirstText(node: *Node) ?[]const u8 {
    if (node.getText()) |t| {
        if (t.content.len > 0) return t.content;
    }
    for (node.children.items) |child| {
        if (findFirstText(child)) |txt| return txt;
    }
    return null;
}

/// Components 视图的过滤匹配
fn componentMatchesFilter(node: *Node, filter: []const u8) bool {
    if (filter.len == 0) return true;

    // #id 过滤
    if (filter[0] == '#') {
        if (filter.len > 1) {
            const id_num = std.fmt.parseInt(u32, filter[1..], 10) catch return false;
            return node.id == id_num;
        }
        return false;
    }

    // component_name 匹配
    if (node.meta.ownership.meta.component_name) |name| {
        if (containsIgnoreCase(name, filter)) return true;
    }

    // 文本内容匹配
    const txt = findFirstText(node);
    if (txt) |t| {
        if (containsIgnoreCase(t, filter)) return true;
    }

    return false;
}

/// 子树中是否有匹配过滤条件的组件
fn subtreeHasMatchingComponent(node: *Node, filter: []const u8) bool {
    for (node.children.items) |child| {
        if (child.meta.ownership.meta.component_name != null and componentMatchesFilter(child, filter)) return true;
        if (subtreeHasMatchingComponent(child, filter)) return true;
    }
    return false;
}

fn tagColor(tag: core.ElementTag, t: *const theme.ThemeTokens) Color {
    const is_dark = t.scheme == .dark;
    return switch (tag) {
        // dark 模式用较亮色值，light 模式用较暗色值以确保在白色背景上可读
        .box => if (is_dark) Color.hex(0x5a9fd4) else Color.hex(0x2E6FA0),
        .text => if (is_dark) Color.hex(0x7a9a70) else Color.hex(0x4A6F40),
        .image => if (is_dark) Color.hex(0x5aa0a0) else Color.hex(0x3A7575),
        .button => if (is_dark) Color.hex(0xc0a060) else Color.hex(0x8A7030),
        .input => if (is_dark) Color.hex(0xb080c0) else Color.hex(0x7A5090),
        .scroll => if (is_dark) Color.hex(0x80b0c0) else Color.hex(0x507888),
        .list => if (is_dark) Color.hex(0xa0a0c0) else Color.hex(0x606088),
        .spacer => if (is_dark) Color.hex(0x505050) else Color.hex(0xAAAAAA),
        .custom => if (is_dark) Color.hex(0xd08050) else Color.hex(0x9A5530),
    };
}

// ========== Details 面板 ==========

fn buildTabBar(cx: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    const tab_items = [_]TabItem{
        .{ .id = "layout", .label_text = "Layout" },
        .{ .id = "style", .label_text = "Style" },
        .{ .id = "state", .label_text = "State" },
        .{ .id = "events", .label_text = "Events" },
        .{ .id = "render", .label_text = "Render" },
        .{ .id = "trace", .label_text = "Trace" },
    };
    // shell 先建、Tabs 建好即 adopt —— 原来 Tabs 先建、shell 的 box 自身分配失败时
    // tuple 里的 tabs 无人释放（mountPanel sweep 最后 3 个注入点）。指针挂稳后才发布。
    const shell = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .width = .{ .grow = .{} },
        .background = t.color.bg_secondary,
        .overflow_hidden = true,
    }, .{});
    errdefer cx.freeNode(shell);
    const tabs = try core.adoptChild(cx, cx.allocator, shell, try Tabs(.{
        .items = &tab_items,
        .default_active_id = state.active_tab.idStr(),
        .variant = .underline,
        .size = .xs,
        .on_change = core.Cx.strHandlerFrom(DevToolsState, state, onDetailsTabChange),
    }).mount(state.scope.?, cx));
    tabs.style.width = .{ .grow = .{} };
    tabs.style.height = .{ .fit = .{} };
    // 程序化换 tab（setActiveTab）时要能把下划线同步回组件（见
    // syncDetailsTabs）——view-mode tabs 有同款 sync 路径，这里补齐。
    state.details_tabs_node = tabs;
    state.details_tabs_state = tabsStateFromNode(tabs);
    shell.meta.ownership.meta.test_id = "devtools.details.tabs";
    const shell_ext = try shell.style.ensureExtFallible(cx.allocator);
    // Details tabs 顶栏不应把滚动漏给下方详情滚动区。
    shell_ext.hit_roles = .{ .pointer = true, .scroll = true, .inspect = false };
    shell_ext.hit_behavior = .@"opaque";
    return shell;
}

// ========== Layout Tab ==========

fn buildLayoutTab(cx: *Cx, state: *DevToolsState, node: *Node, parent: *Node) !void {
    const rect = computeRenderRect(node);

    // Section: 基本信息
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Element"));
    try parent.appendChild(cx.allocator, try kvRow(cx, "tag", @tagName(node.tag)));
    try parent.appendChild(cx.allocator, try kvRowInt(cx, "id", @intCast(node.id)));
    try parent.appendChild(cx.allocator, try kvRow(cx, "pick_excluded", if (node.frame_state.state_bits.flags.inspect_pick_disabled) "true" else "false"));
    try appendInspectPickToggle(cx, state, node, parent);

    if (node.getText()) |t| {
        if (t.content.len > 0) {
            const preview = t.content[0..@min(t.content.len, 60)];
            try parent.appendChild(cx.allocator, try kvRow(cx, "text", preview));
        }
    }

    // Box Model 可视化
    try box_model.build(cx, node, parent);

    // Section: 位置/尺寸
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Computed Rect"));
    // Render diagnostics as floats instead of converting untrusted layout data
    // to i64. NaN/Inf and very large transforms must never trap devtools.
    try parent.appendChild(cx.allocator, try kvRowFloat(cx, "x", rect.x));
    try parent.appendChild(cx.allocator, try kvRowFloat(cx, "y", rect.y));
    try parent.appendChild(cx.allocator, try kvRowFloat(cx, "w", rect.w));
    try parent.appendChild(cx.allocator, try kvRowFloat(cx, "h", rect.h));

    // Section: Sizing
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Sizing"));
    var w_buf: [20]u8 = undefined;
    var h_buf: [20]u8 = undefined;
    try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .width, "width", dv_fmt.formatSizing(&w_buf, node.style.width)));
    try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .height, "height", dv_fmt.formatSizing(&h_buf, node.style.height)));

    // Section: Flexbox（数值属性可点击编辑）
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Flexbox"));
    try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .direction, "direction", @tagName(node.style.direction)));
    try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .justify, "justify", @tagName(node.style.justify)));
    try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .align_items, "align_items", @tagName(node.style.align_items)));
    try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .flex_wrap, "flex_wrap", @tagName(node.style.flex_wrap())));

    try editableKvRow(cx, state, node, .gap, parent);
    try editableKvRow(cx, state, node, .flex, parent);
    try editableKvRow(cx, state, node, .flex_shrink, parent);

    if (node.style.align_self()) |as_val| {
        try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .align_self, "align_self", @tagName(as_val)));
    }

    // Padding & Margin
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Spacing"));
    var pad_buf: [48]u8 = undefined;
    var margin_buf: [64]u8 = undefined;
    try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .padding, "padding", dv_fmt.fmtPadding(&pad_buf, node.style.padding)));
    try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .margin, "margin", dv_fmt.fmtMargin(&margin_buf, node.style.marginSpec())));

    // Position
    if (node.style.position != .relative or node.style.z_index() != 0) {
        try parent.appendChild(cx.allocator, try sectionTitle(cx, "Position"));
        try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .position, "position", @tagName(node.style.position)));
        try parent.appendChild(cx.allocator, try styleKvRowInt(cx, state, node, .z_index, "z_index", node.style.z_index()));
    }

    // Transform（可编辑）
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Transform"));
    try editableKvRow(cx, state, node, .translate_x, parent);
    try editableKvRow(cx, state, node, .translate_y, parent);

    // Children
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Children"));
    try parent.appendChild(cx.allocator, try kvRowInt(cx, "count", @intCast(node.children.items.len)));

    // Flags
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Flags"));
    try parent.appendChild(cx.allocator, try kvRow(cx, "layout_dirty", if (node.frame_state.state_bits.dirty.core.layout) "true" else "false"));
    try parent.appendChild(cx.allocator, try kvRow(cx, "render_dirty", if (node.frame_state.state_bits.dirty.core.render) "true" else "false"));
    try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .overflow_hidden, "overflow_hidden", if (node.style.overflow_hidden) "true" else "false"));
}

const InspectPickToggleCtx = struct {
    state: *DevToolsState,
    node_id: u32,
};

fn appendInspectPickToggle(cx: *Cx, state: *DevToolsState, node: *Node, parent: *Node) !void {
    const details_scope = state.details_scope orelse state.scope.?;
    _ = state.liveTarget() orelse return;
    const ctx = try allocScopeResource(details_scope, InspectPickToggleCtx);
    ctx.* = .{
        .state = state,
        .node_id = node.id,
    };

    const row = try cx.createNode(.box, .{
        .direction = .row,
        .gap = 8,
        .align_items = .center,
        .height = .{ .px = 24 },
    });
    try row.appendChild(cx.allocator, try core.text(cx, "mouse_pick", .{
        .font_size = 10,
        .color = cx.tokens.color.fg_secondary,
    }));

    const btn = try Button(.{
        .label = if (node.frame_state.state_bits.flags.inspect_pick_disabled) "Allow pick" else "Exclude from pick",
        .variant = if (node.frame_state.state_bits.flags.inspect_pick_disabled) .secondary else .ghost,
        .size = .xs,
        .on_event = inspectPickToggleEvent,
        .event_context = ctx,
        .style = .{ .border = .{ .width = 1, .color = cx.tokens.color.border, .radius = 3 } },
    }).mount(details_scope, cx);
    try row.appendChild(cx.allocator, btn);
    try parent.appendChild(cx.allocator, row);
}

fn inspectPickToggleEvent(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    const ctx: *InspectPickToggleCtx = @ptrCast(@alignCast(context.?));
    const target = ctx.state.liveTarget() orelse return .handled;
    const root = target.root orelse return .handled;
    const node = findNodeById(root, ctx.node_id) orelse return .handled;
    node.setInspectPickDisabled(!node.frame_state.state_bits.flags.inspect_pick_disabled);
    if (target.inspector.hover_node_id == node.id and node.frame_state.state_bits.flags.inspect_pick_disabled) {
        target.inspector.hover_node_id = null;
    }
    target.needs_redraw = true;
    ctx.state.details_dirty = true;
    ctx.state.tree_dirty = true;
    if (ctx.state.cx) |c| c.needs_redraw = true;
    return .handled;
}

// ========== Style Tab ==========

fn buildStyleTab(cx: *Cx, state: *DevToolsState, node: *Node, parent: *Node) !void {
    // Background
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Background"));
    try parent.appendChild(cx.allocator, try styleColorRow(cx, state, node, .background, "color", node.getBackground()));

    // Opacity（可编辑）
    try editableKvRow(cx, state, node, .opacity, parent);

    // Border（可编辑数值）
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Border"));
    try editableKvRow(cx, state, node, .border_width, parent);
    try parent.appendChild(cx.allocator, try styleColorRow(cx, state, node, .border, "color", node.style.border.color));
    try editableKvRow(cx, state, node, .border_radius, parent);

    // Corner Radius (高级)
    if (node.style.corner_radius()) |cr| {
        switch (cr) {
            .all => |v| {
                var cr_buf: [12]u8 = undefined;
                try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .corner_radius, "corner_radius", dv_fmt.fmtFloat(&cr_buf, v)));
            },
            .each => |vals| {
                var cr_buf: [48]u8 = undefined;
                const s = std.fmt.bufPrint(&cr_buf, "{d:.0} {d:.0} {d:.0} {d:.0}", .{
                    vals[0], vals[1], vals[2], vals[3],
                }) catch "";
                try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .corner_radius, "corner_radius", s));
            },
        }
    }

    // Shadow
    if (node.style.shadow()) |shadow| {
        try parent.appendChild(cx.allocator, try sectionTitle(cx, "Shadow"));
        try parent.appendChild(cx.allocator, try styleColorRow(cx, state, node, .shadow, "color", shadow.color));
        var blur_buf: [12]u8 = undefined;
        try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .shadow, "blur", dv_fmt.fmtFloat(&blur_buf, shadow.blur)));
        var sox_buf: [12]u8 = undefined;
        var soy_buf: [12]u8 = undefined;
        try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .shadow, "offset_x", dv_fmt.fmtFloat(&sox_buf, shadow.offset_x)));
        try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .shadow, "offset_y", dv_fmt.fmtFloat(&soy_buf, shadow.offset_y)));
    }

    // Gradient
    if (node.style.gradient()) |grad| {
        try parent.appendChild(cx.allocator, try sectionTitle(cx, "Gradient"));
        try parent.appendChild(cx.allocator, try styleColorRow(cx, state, node, .gradient, "from", grad.from));
        try parent.appendChild(cx.allocator, try styleColorRow(cx, state, node, .gradient, "to", grad.to));
        try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .gradient, "direction", @tagName(grad.direction)));
    }

    // Text Style
    if (node.getText()) |t| {
        try parent.appendChild(cx.allocator, try sectionTitle(cx, "Text"));
        try parent.appendChild(cx.allocator, try styleColorRow(cx, state, node, .text_color, "color", t.color));
        var fs_buf: [12]u8 = undefined;
        try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, .text_font_size, "font_size", dv_fmt.fmtFloat(&fs_buf, t.font_size)));
        try parent.appendChild(cx.allocator, try styleKvRowInt(cx, state, node, .text_font_weight, "font_weight", @intCast(t.font_weight)));
        var lh_buf: [12]u8 = undefined;
        try parent.appendChild(cx.allocator, try styleKvRow(cx, state, node, null, "line_height", dv_fmt.fmtFloat(&lh_buf, t.line_height)));
        try parent.appendChild(cx.allocator, try kvRow(cx, "selectable", if (t.selectable) "true" else "false"));
    }
}

// ========== State Tab ==========

fn buildStateTab(cx: *Cx, target: *Cx, state: *DevToolsState, node: *Node, parent: *Node) !void {
    const t = cx.tokens;
    const details_scope = state.details_scope orelse state.scope.?;
    const component_root = findOwningComponent(node);
    const component_name = component_root.meta.ownership.meta.component_name orelse @tagName(component_root.tag);
    const subject_name = node.meta.ownership.meta.component_name orelse @tagName(node.tag);

    var scoped_state_refs = std.ArrayList(ScopedStateRef).empty;
    defer scoped_state_refs.deinit(state.frameAlloc());
    var scoped_signals = std.ArrayList(core.DebugSignalRef).empty;
    defer scoped_signals.deinit(state.frameAlloc());
    collectNodeDebugRefs(node, &scoped_state_refs, &scoped_signals, state.frameAlloc());

    var scoped_state_ptrs = std.ArrayList(*anyopaque).empty;
    defer scoped_state_ptrs.deinit(state.frameAlloc());
    var source_by_ptr = std.AutoHashMap(usize, u32).init(state.frameAlloc());
    defer source_by_ptr.deinit();
    // 诊断路径：这两个都是 frame arena 上的临时采集表，只用于本帧列出 State
    // 面板的行。丢一条 = 少显示一个 state 条目，不影响被调试 app。
    for (scoped_state_refs.items) |r| {
        _ = scoped_state_ptrs.append(state.frameAlloc(), r.ptr) catch {};
        _ = source_by_ptr.put(@intFromPtr(r.ptr), r.source_node_id) catch {};
    }

    const entries = target.state_store.debugEntriesByPtrs(state.frameAlloc(), scoped_state_ptrs.items);

    var scoped_entries = std.ArrayList(ScopedStateEntry).empty;
    defer scoped_entries.deinit(state.frameAlloc());
    for (entries) |e| {
        const source_node_id = source_by_ptr.get(@intFromPtr(e.ptr)) orelse continue;
        _ = scoped_entries.append(state.frameAlloc(), .{
            .entry = e,
            .source_node_id = source_node_id,
        }) catch {};
    }

    // 标题 + 复制
    const state_head = try cx.createNode(.box, .{
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .width = .{ .grow = .{} },
        .height = .{ .px = 22 },
    });

    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s} #{d}", .{ subject_name, node.id }) catch "Node";
    const title_text = scopeOwnedText(details_scope, title);
    const title_node = try core.text(cx, title_text, .{
        .font_size = 10,
        .color = t.color.accent,
        .font_weight = 600,
    });
    title_node.meta.ownership.meta.test_id = "devtools.state.subject";
    try state_head.appendChild(cx.allocator, title_node);

    var all_buf: [12288]u8 = undefined;
    var all_writer = std.Io.Writer.fixed(&all_buf);
    const all_w = &all_writer;

    // 诊断路径：all_w 是 12KB **定长栈缓冲**上的 writer，这里的 catch {} 吞的是
    // NoSpaceLeft 而非 OOM。超长时"复制全部 state"的文本被截断显示，
    // 这正是想要的降级（而不是让面板炸掉）。下面同组 print/writeAll 同理。
    _ = all_w.print("node={s}#{d}\n", .{ subject_name, node.id }) catch {};
    _ = all_w.print("owning_component={s}#{d}\n", .{ component_name, component_root.id }) catch {};
    if (scoped_signals.items.len > 0) {
        _ = all_w.writeAll("\n[signals]\n") catch {};
        for (scoped_signals.items) |sig| {
            _ = all_w.print("{s}={s}\n", .{ sig.label, signalValueText(sig) }) catch {};
        }
    }
    if (scoped_entries.items.len > 0) {
        _ = all_w.writeAll("\n[state]\n") catch {};
        for (scoped_entries.items) |e| {
            _ = all_w.print("id=0x{x}\nsource_node={d}\ntype={s}\nvalue:\n{s}\n---\n", .{
                e.entry.id,
                e.source_node_id,
                e.entry.type_name,
                e.entry.valueSlice(),
            }) catch {};
        }
    }
    const all_copy_text = scopeOwnedText(details_scope, all_writer.buffered());

    const copy_all_ctx = scopeAllocCopyStateCtx(details_scope, cx, all_copy_text) orelse
        scopeAllocCopyStateCtx(details_scope, cx, "");
    const copy_all_ctx_ptr = copy_all_ctx orelse return;
    const copy_all_btn = try Button(.{
        .label = "COPY ALL",
        .variant = .ghost,
        .size = .xs,
        .style = .{ .border = .{ .width = 1, .color = t.color.accent, .radius = 3 } },
    }).mount(details_scope, cx);
    copy_all_btn.behavior.events.on_click = core.Cx.simpleHandler(copyStateClick, @ptrCast(copy_all_ctx_ptr));
    try state_head.appendChild(cx.allocator, copy_all_btn);

    try parent.appendChild(cx.allocator, state_head);

    var meta_buf: [160]u8 = undefined;
    const meta_text = std.fmt.bufPrint(&meta_buf, "node#{d} local signals: {d}  local state: {d}", .{
        node.id,
        scoped_signals.items.len,
        scoped_entries.items.len,
    }) catch "";
    const meta_node = try inlineText(cx, scopeOwnedText(details_scope, meta_text), devtoolsMuted(t), 10);
    meta_node.meta.ownership.meta.test_id = "devtools.state.meta";
    try parent.appendChild(cx.allocator, meta_node);

    if (component_root != node) {
        var owner_buf: [96]u8 = undefined;
        const owner_text = std.fmt.bufPrint(&owner_buf, "owning component: {s} #{d}", .{ component_name, component_root.id }) catch "";
        const owner_node = try inlineText(cx, scopeOwnedText(details_scope, owner_text), devtoolsMuted(t), 10);
        owner_node.meta.ownership.meta.test_id = "devtools.state.owner";
        try parent.appendChild(cx.allocator, owner_node);
    }

    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Signals"));
    if (scoped_signals.items.len == 0) {
        const empty_signals = try core.text(cx, "No local signals", .{
            .font_size = 10,
            .color = devtoolsMuted(t),
        });
        empty_signals.meta.ownership.meta.test_id = "devtools.state.signals.empty";
        try parent.appendChild(cx.allocator, empty_signals);
    } else {
        for (scoped_signals.items) |sig| {
            try parent.appendChild(cx.allocator, try kvRow(cx, sig.label, signalValueText(sig)));
        }
    }

    try parent.appendChild(cx.allocator, try sectionTitle(cx, "State"));
    if (scoped_entries.items.len == 0) {
        const empty_state = try core.text(cx, "No local state", .{
            .font_size = 10,
            .color = devtoolsMuted(t),
        });
        empty_state.meta.ownership.meta.test_id = "devtools.state.entries.empty";
        try parent.appendChild(cx.allocator, empty_state);
    } else {
        for (scoped_entries.items) |e| {
            try parent.appendChild(cx.allocator, try stateRow(cx, state, e));
        }
    }
}

// ========== Events Tab ==========

fn buildEventsTab(cx: *Cx, target: *Cx, node: *Node, parent: *Node) !void {
    const t = cx.tokens;
    _ = target;

    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Event Handlers"));

    var has_any = false;

    if (node.behavior.events.on_click != null) {
        try parent.appendChild(cx.allocator, try eventRow(cx, "on_click", "HandlerRef"));
        has_any = true;
    }
    if (node.behavior.events.on_hover != null) {
        try parent.appendChild(cx.allocator, try eventRow(cx, "on_hover", "HandlerRef"));
        has_any = true;
    }
    if (node.behavior.events.on_leave != null) {
        try parent.appendChild(cx.allocator, try eventRow(cx, "on_leave", "HandlerRef"));
        has_any = true;
    }
    if (node.behavior.events.on_focus != null) {
        try parent.appendChild(cx.allocator, try eventRow(cx, "on_focus", "HandlerRef"));
        has_any = true;
    }
    if (node.behavior.events.on_blur != null) {
        try parent.appendChild(cx.allocator, try eventRow(cx, "on_blur", "HandlerRef"));
        has_any = true;
    }
    if (node.behavior.events.on_event != null) {
        try parent.appendChild(cx.allocator, try eventRow(cx, "on_event", "GenericEventCallback"));
        has_any = true;
    }

    if (!has_any) {
        try parent.appendChild(cx.allocator, try core.text(cx, "No event handlers", .{
            .font_size = 10,
            .color = devtoolsMuted(t),
        }));
    }

    // Lifecycle
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Lifecycle"));

    if (node.meta.ownership.hooks.on_mount != null) {
        try parent.appendChild(cx.allocator, try eventRow(cx, "on_mount", "HandlerRef"));
    }
    if (node.meta.ownership.hooks.on_cleanup != null) {
        try parent.appendChild(cx.allocator, try eventRow(cx, "on_cleanup", "HandlerRef"));
    }
    if (node.meta.per_frame.hooks.before_render.main != null) {
        try parent.appendChild(cx.allocator, try eventRow(cx, "on_before_render", "fn(*Node)"));
    }

    const mounted_text = if (node.frame_state.state_bits.flags.is_mounted) "true" else "false";
    try parent.appendChild(cx.allocator, try kvRow(cx, "is_mounted", mounted_text));
}

fn eventRow(cx: *Cx, name: []const u8, type_info: []const u8) !*Node {
    const t = cx.tokens;
    const s = theme_schema.window(t);
    const row = try cx.createNode(.box, .{
        .direction = .row,
        .gap = 8,
        .align_items = .center,
        .height = .{ .px = 18 },
    });
    try row.appendChild(cx.allocator, try core.text(cx, name, .{
        .font_size = 10,
        .color = s.devtools_event_name,
    }));
    try row.appendChild(cx.allocator, try inlineText(cx, type_info, devtoolsMuted(t), 10));
    return row;
}

// ========== Render Tab (Why Did This Render) ==========

const RenderAnimationSubjectInfo = struct {
    node: *Node,
    source: []const u8,
};

const RenderFinalDrawInfo = struct {
    source: []const u8,
    effect_kind: []const u8,
    requires_offscreen: bool,
    has_plan_layer: bool,
    draw_opacity: f32,
    draw_bounds: ComputedRect,
    use_draw_transform: bool,
    rotate: f32,
    draw_transform: Transform2D,
};

fn resolveRenderAnimationSubject(target: *Cx, node: *Node) RenderAnimationSubjectInfo {
    if (target.overlay_stack.findLayerForNode(node)) |layer| {
        if (layer.content_node) |content| {
            return .{ .node = content, .source = "overlay_content" };
        }
    }
    return .{ .node = node, .source = "node" };
}

fn resolveRenderFinalDraw(target: *Cx, subject: *Node) ?RenderFinalDrawInfo {
    const runtime = target.scene_runtime.get(subject.id) orelse return null;
    if (runtime.effect_id == core.SceneRuntimeInvalidId or runtime.effect_id >= target.property_tree.effects.items.len) {
        return null;
    }

    const effect = target.property_tree.effects.items[runtime.effect_id];
    const effect_state = target.layer_tree.planQueryEffect(runtime.effect_id);
    const has_surface_transform =
        (@abs(subject.style.rotate()) > 0.0001) or
        (@abs(subject.style.scale_x() - 1.0) > 0.0001) or
        (@abs(subject.style.scale_y() - 1.0) > 0.0001);
    const draw_bounds = if (has_surface_transform)
        runtime.world_bounds
    else
        (effect_state.begin_bounds orelse runtime.world_bounds);
    const draw_opacity = if (effect.kind == .opacity or effect.kind == .composited_group)
        (if (effect_state.draw_opacity) |opacity| opacity else effect.opacity)
    else
        1.0;
    const draw_transform = if (runtime.transform_id < target.property_tree.transforms.items.len)
        target.property_tree.transforms.items[runtime.transform_id].world
    else
        Transform2D.identity();

    return .{
        .source = if (has_surface_transform) "custom_surface_transform" else "plan_bridge",
        .effect_kind = @tagName(effect.kind),
        .requires_offscreen = effect.requires_offscreen,
        .has_plan_layer = effect_state.has_plan_layer,
        .draw_opacity = draw_opacity,
        .draw_bounds = draw_bounds,
        .use_draw_transform = has_surface_transform,
        .rotate = if (has_surface_transform) subject.style.rotate() else 0,
        .draw_transform = if (has_surface_transform) draw_transform else Transform2D.identity(),
    };
}

fn kvRowBool(cx: *Cx, label: []const u8, value: bool) !*Node {
    return kvRow(cx, label, if (value) "true" else "false");
}

fn kvRowFloat(cx: *Cx, label: []const u8, value: f32) !*Node {
    var buf: [12]u8 = undefined;
    return kvRow(cx, label, dv_fmt.fmtFloat(&buf, value));
}

fn kvRowRect(cx: *Cx, label: []const u8, rect: ComputedRect) !*Node {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.1}, {d:.1}, {d:.1}, {d:.1}", .{ rect.x, rect.y, rect.w, rect.h }) catch "";
    return kvRow(cx, label, text);
}

fn buildRenderTab(cx: *Cx, target: *Cx, node: *Node, parent: *Node) !void {
    const t = cx.tokens;
    const subject = resolveRenderAnimationSubject(target, node);
    const final_draw = resolveRenderFinalDraw(target, subject.node);

    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Render Reasons"));

    const store = target.inspector.trace_store orelse {
        try parent.appendChild(cx.allocator, try core.text(cx, "No trace store. Interact with the target window.", .{
            .font_size = 10,
            .color = devtoolsMuted(t),
        }));
        return;
    };

    var records: [50]debug_trace.RenderReasonRecord = undefined;
    const count = store.getRenderForNode(node.id, &records);

    if (count == 0) {
        try parent.appendChild(cx.allocator, try core.text(cx, "No render reasons recorded. Interact with the target window.", .{
            .font_size = 10,
            .color = devtoolsMuted(t),
        }));
        return;
    }

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const rec = records[i];
        var buf: [80]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[F#{d}] {s} | {s}", .{
            rec.frame,
            @tagName(rec.reason),
            rec.getSource(),
        }) catch "";

        const reason_color = switch (rec.reason) {
            .layout_triggered, .sizing_triggered => t.color.warning,
            .explicit, .mount => t.color.accent,
            .transition_tick => devtoolsMuted(t),
            else => t.color.fg_primary,
        };

        try parent.appendChild(cx.allocator, try core.text(cx, line, .{
            .font_size = 10,
            .color = reason_color,
        }));
    }

    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Animation Subject"));
    try parent.appendChild(cx.allocator, try kvRow(cx, "source", subject.source));
    try parent.appendChild(cx.allocator, try kvRowInt(cx, "node_id", @intCast(subject.node.id)));
    try parent.appendChild(cx.allocator, try kvRow(cx, "tag", @tagName(subject.node.tag)));
    if (subject.node.meta.ownership.meta.component_name) |cn| {
        try parent.appendChild(cx.allocator, try kvRow(cx, "component", cn));
    }
    if (subject.node.meta.ownership.meta.test_id) |tid| {
        try parent.appendChild(cx.allocator, try kvRow(cx, "test_id", tid));
    }
    try parent.appendChild(cx.allocator, try kvRowFloat(cx, "style.opacity", subject.node.getOpacity()));
    try parent.appendChild(cx.allocator, try kvRowFloat(cx, "style.translate_x", subject.node.style.translate_x));
    try parent.appendChild(cx.allocator, try kvRowFloat(cx, "style.translate_y", subject.node.style.translate_y));
    try parent.appendChild(cx.allocator, try kvRowFloat(cx, "style.scale_x", subject.node.style.scale_x()));
    try parent.appendChild(cx.allocator, try kvRowFloat(cx, "style.scale_y", subject.node.style.scale_y()));

    if (target.scene_runtime.get(subject.node.id)) |runtime| {
        try parent.appendChild(cx.allocator, try kvRowBool(cx, "runtime.composite_anim", runtime.has_active_composite_animation));
        try parent.appendChild(cx.allocator, try kvRowBool(cx, "runtime.transform_anim", runtime.has_active_transform_animation));
        try parent.appendChild(cx.allocator, try kvRowBool(cx, "runtime.opacity_anim", runtime.has_active_opacity_animation));
        try parent.appendChild(cx.allocator, try kvRowRect(cx, "runtime.world_bounds", runtime.world_bounds));
    }
    if (target.scene_runtime.get(subject.node.id)) |runtime| {
        if (runtime.transform_id < target.property_tree.transforms.items.len) {
            const transform = target.property_tree.transforms.items[runtime.transform_id].world.decompose();
            try parent.appendChild(cx.allocator, try kvRowFloat(cx, "world.translate_x", transform.translate[0]));
            try parent.appendChild(cx.allocator, try kvRowFloat(cx, "world.translate_y", transform.translate[1]));
            try parent.appendChild(cx.allocator, try kvRowFloat(cx, "world.scale_x", transform.scale[0]));
            try parent.appendChild(cx.allocator, try kvRowFloat(cx, "world.scale_y", transform.scale[1]));
            try parent.appendChild(cx.allocator, try kvRowFloat(cx, "world.rotate", transform.rotate));
        }
    }

    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Final Draw"));
    if (final_draw) |fd| {
        try parent.appendChild(cx.allocator, try kvRow(cx, "source", fd.source));
        try parent.appendChild(cx.allocator, try kvRow(cx, "effect_kind", fd.effect_kind));
        try parent.appendChild(cx.allocator, try kvRowBool(cx, "requires_offscreen", fd.requires_offscreen));
        try parent.appendChild(cx.allocator, try kvRowBool(cx, "has_plan_layer", fd.has_plan_layer));
        try parent.appendChild(cx.allocator, try kvRowFloat(cx, "draw_opacity", fd.draw_opacity));
        try parent.appendChild(cx.allocator, try kvRowRect(cx, "draw_bounds", fd.draw_bounds));
        try parent.appendChild(cx.allocator, try kvRowBool(cx, "use_draw_transform", fd.use_draw_transform));
        try parent.appendChild(cx.allocator, try kvRowFloat(cx, "rotate", fd.rotate));
        const parts = fd.draw_transform.decompose();
        try parent.appendChild(cx.allocator, try kvRowFloat(cx, "draw.translate_x", parts.translate[0]));
        try parent.appendChild(cx.allocator, try kvRowFloat(cx, "draw.translate_y", parts.translate[1]));
        try parent.appendChild(cx.allocator, try kvRowFloat(cx, "draw.scale_x", parts.scale[0]));
        try parent.appendChild(cx.allocator, try kvRowFloat(cx, "draw.scale_y", parts.scale[1]));
        try parent.appendChild(cx.allocator, try kvRowFloat(cx, "draw.rotate", parts.rotate));
        try parent.appendChild(cx.allocator, try kvRowFloat(cx, "draw.skew_x", parts.skew_x));
    } else {
        try parent.appendChild(cx.allocator, try core.text(cx, "No active final draw surface state for this node.", .{
            .font_size = 10,
            .color = devtoolsMuted(t),
        }));
    }
}

// ========== Trace Tab (Event Trace Timeline) ==========

fn buildTraceTab(cx: *Cx, target: *Cx, state: *DevToolsState, parent: *Node) !void {
    const t = cx.tokens;

    // 顶栏: Pause/Resume + Clear 按钮
    const toolbar = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .height = .{ .px = 22 },
        .padding = Padding.symmetric(2, 4),
    }, .{});

    const store = target.inspector.trace_store;

    // Pause/Resume 按钮 → Button 组件
    {
        const is_paused = if (store) |s| s.paused else false;
        const pause_ctx = try state.frameAlloc().create(TracePauseCtx);
        pause_ctx.* = .{ .state = state };
        const details_scope = state.details_scope orelse state.scope.?;
        const pause_btn = try Button(.{
            .label = if (is_paused) "Resume" else "Pause",
            .variant = if (is_paused) .secondary else .ghost,
            .size = .xs,
            .on_event = tracePauseEvent,
            .event_context = pause_ctx,
        }).mount(details_scope, cx);
        try toolbar.appendChild(cx.allocator, pause_btn);
    }

    // Clear 按钮 → Button 组件
    {
        const clear_ctx = try state.frameAlloc().create(TraceClearCtx);
        clear_ctx.* = .{ .state = state };
        const details_scope = state.details_scope orelse state.scope.?;
        const clear_btn = try Button(.{
            .label = "Clear",
            .variant = .ghost,
            .size = .xs,
            .on_event = traceClearEvent,
            .event_context = clear_ctx,
        }).mount(details_scope, cx);
        try toolbar.appendChild(cx.allocator, clear_btn);
    }

    try parent.appendChild(cx.allocator, toolbar);

    // 事件列表
    if (store == null) {
        try parent.appendChild(cx.allocator, try core.text(cx, "No trace store active.", .{
            .font_size = 10,
            .color = devtoolsMuted(t),
        }));
        return;
    }

    var events_buf: [100]debug_trace.EventTraceRecord = undefined;
    const count = store.?.getRecentEvents(&events_buf);

    if (count == 0) {
        try parent.appendChild(cx.allocator, try core.text(cx, "No events recorded. Interact with the target window.", .{
            .font_size = 10,
            .color = devtoolsMuted(t),
        }));
        return;
    }

    const selected_id = target.inspector.selected_node_id;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const rec = events_buf[i];
        var buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[F#{d}] {s} {s} #{d} {s}", .{
            rec.frame,
            @tagName(rec.event_kind),
            @tagName(rec.phase),
            rec.handler_node_id,
            @tagName(rec.result),
        }) catch "";

        // phase 颜色：capture=灰, target=蓝, bubble=绿
        const phase_color = switch (rec.phase) {
            .capture => devtoolsMuted(t),
            .target => t.color.accent,
            .bubble => t.color.success,
        };

        // result 颜色修正：stop=红
        const line_color = if (rec.result == .stop) t.color.danger else phase_color;

        // 高亮选中节点相关行
        const is_related = selected_id != null and
            (rec.target_node_id == selected_id.? or rec.handler_node_id == selected_id.?);

        const row = try core.box(cx, .{
            .direction = .row,
            .align_items = .center,
            .height = .{ .px = 16 },
            .padding = Padding.symmetric(0, 4),
            .background = if (is_related) t.color.bg_hover else Color.TRANSPARENT,
        }, .{
            try core.text(cx, line, .{ .font_size = 10, .color = line_color }),
        });
        // row 建好之后 frameAlloc().create 还可能失败 —— 门控 errdefer 守窗口，adopt 挂接。
        var row_owned = true;
        errdefer if (row_owned) cx.freeNode(row);

        // 点击跳转到 handler 节点
        const trace_click_ctx = try state.frameAlloc().create(TraceClickCtx);
        trace_click_ctx.* = .{ .state = state, .node_id = rec.handler_node_id };
        row.behavior.events.on_event = traceClickEvent;
        row.behavior.events.event_context = trace_click_ctx;

        row_owned = false;
        _ = try core.adoptChild(cx, cx.allocator, parent, row);
    }
}

const TracePauseCtx = struct {
    state: *DevToolsState,
};

/// Trace 工具栏按钮点击发生在 DevTools 窗口，不推进 target 的 frame_count，
/// 而 Trace 内容默认只在 target 出帧时重建 —— 不在这里显式标脏的话，
/// Pause 按钮文字不翻转、Clear 后列表残留，要等 target 恰好渲染才更新。
fn markTraceDetailsDirty(state: *DevToolsState) void {
    state.details_dirty = true;
    if (state.cx) |c| c.needs_redraw = true;
}

fn tracePauseEvent(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    const ctx: *TracePauseCtx = @ptrCast(@alignCast(context.?));
    if (ctx.state.liveTarget()) |target| if (target.inspector.trace_store) |store| {
        store.paused = !store.paused;
    };
    markTraceDetailsDirty(ctx.state);
    return .handled;
}

const TraceClearCtx = struct {
    state: *DevToolsState,
};

fn traceClearEvent(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    const ctx: *TraceClearCtx = @ptrCast(@alignCast(context.?));
    if (ctx.state.liveTarget()) |target| if (target.inspector.trace_store) |store| {
        store.clear();
    };
    markTraceDetailsDirty(ctx.state);
    return .handled;
}

const TraceClickCtx = struct {
    state: *DevToolsState,
    node_id: u32,
};

fn traceClickEvent(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    const ctx: *TraceClickCtx = @ptrCast(@alignCast(context.?));
    const target = ctx.state.liveTarget() orelse return .handled;
    target.inspector.selected_node_id = ctx.node_id;
    target.inspector.enabled = true;
    target.needs_redraw = true;
    return .handled;
}

// ========== UI 辅助函数 ==========

fn sectionTitle(cx: *Cx, title: []const u8) !*Node {
    const t = cx.tokens;
    return core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .height = .{ .px = 20 },
        .padding = Padding{ .top = 6, .bottom = 2, .left = 0, .right = 0 },
    }, .{
        try core.text(cx, title, .{
            .font_size = 10,
            .color = t.color.accent,
            .font_weight = 600,
        }),
    });
}

fn stateRow(cx: *Cx, state: *DevToolsState, scoped: ScopedStateEntry) !*Node {
    const t = cx.tokens;
    const s = theme_schema.window(t);
    const details_scope = state.details_scope orelse state.scope.?;
    var row = try cx.createNode(.box, .{
        .direction = .column,
        .gap = 2,
        .height = .{ .fit = .{} },
        .padding = Padding{ .top = 4, .bottom = 4, .left = 6, .right = 6 },
        .width = .{ .grow = .{} },
        .border = .{ .radius = 4, .width = 1, .color = t.color.border },
    });
    cx.linkNodeToWorld(row);
    row.setBackgroundRaw(s.devtools_state_card_bg);

    // ID + 类型名在同一行
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "0x{x}", .{scoped.entry.id}) catch "0x0";
    const owned_id_str = scopeOwnedText(details_scope, id_str);
    const instance_id: u32 = @truncate(scoped.entry.id);
    var inst_buf: [20]u8 = undefined;
    const inst_str = std.fmt.bufPrint(&inst_buf, "#{d}", .{instance_id}) catch "#0";
    const owned_inst_str = scopeOwnedText(details_scope, inst_str);
    var source_buf: [24]u8 = undefined;
    const source_str = std.fmt.bufPrint(&source_buf, "node#{d}", .{scoped.source_node_id}) catch "node#0";
    const owned_source_str = scopeOwnedText(details_scope, source_str);

    const head_row = try cx.createNode(.box, .{
        .direction = .row,
        .gap = 4,
        .height = .{ .fit = .{} },
        .align_items = .center,
        .width = .{ .grow = .{} },
    });
    try head_row.appendChild(cx.allocator, try core.text(cx, scoped.entry.type_name, .{
        .font_size = 10,
        .color = t.color.fg_primary,
    }));
    try head_row.appendChild(cx.allocator, try inlineText(cx, owned_id_str, devtoolsMuted(t), 9));
    try head_row.appendChild(cx.allocator, try inlineText(cx, owned_inst_str, devtoolsMuted(t), 9));
    try head_row.appendChild(cx.allocator, try inlineText(cx, owned_source_str, devtoolsMuted(t), 9));

    var pretty_buf: [1024]u8 = undefined;
    const pretty = prettyStateValueInto(&pretty_buf, scoped.entry.valueSlice());
    var copy_buf: [1536]u8 = undefined;
    const copy_payload = std.fmt.bufPrint(&copy_buf, "id={s}\ninstance={d}\nsource_node={d}\ntype={s}\nvalue:\n{s}", .{
        id_str,
        instance_id,
        scoped.source_node_id,
        scoped.entry.type_name,
        pretty,
    }) catch pretty;
    const copy_text = scopeOwnedText(details_scope, copy_payload);
    const copy_ctx = scopeAllocCopyStateCtx(details_scope, cx, copy_text) orelse
        scopeAllocCopyStateCtx(details_scope, cx, "");
    const copy_ctx_ptr = copy_ctx orelse return row;
    const copy_btn = try Button(.{
        .label = "COPY",
        .variant = .ghost,
        .size = .xs,
        .style = .{ .border = .{ .width = 1, .color = t.color.accent, .radius = 3 } },
    }).mount(details_scope, cx);
    copy_btn.behavior.events.on_click = core.Cx.simpleHandler(copyStateClick, @ptrCast(copy_ctx_ptr));
    try head_row.appendChild(cx.allocator, copy_btn);

    try row.appendChild(cx.allocator, head_row);

    const wrap_cols: usize = 82;
    var it = std.mem.splitScalar(u8, pretty, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var start: usize = 0;
        while (start < trimmed.len) {
            const end = @min(start + wrap_cols, trimmed.len);
            const seg = trimmed[start..end];
            try row.appendChild(cx.allocator, try core.text(cx, scopeOwnedText(details_scope, seg), .{
                .font_size = 10,
                .color = t.color.fg_secondary,
            }));
            start = end;
        }
    }

    return row;
}

fn findOwningComponent(node: *Node) *Node {
    var cur: ?*Node = node;
    while (cur) |n| : (cur = n.parent) {
        if (n.meta.ownership.meta.component_name != null) return n;
    }
    return node;
}

fn collectNodeDebugRefs(node: *Node, state_refs: *std.ArrayList(ScopedStateRef), signal_refs: *std.ArrayList(core.DebugSignalRef), alloc: std.mem.Allocator) void {
    for (node.meta.ownership.debug_slots.state_ptrs[0..node.meta.ownership.debug_slots.state_count]) |slot| {
        if (slot) |ptr| appendUniqueStateRef(state_refs, alloc, ptr, node.id);
    }
    for (node.meta.ownership.debug_slots.signals[0..node.meta.ownership.debug_slots.signal_count]) |slot| {
        if (slot) |sig| appendUniqueSignal(signal_refs, alloc, sig);
    }
}

/// 诊断路径：本函数与 appendUniqueSignal 都往 frame arena 的去重采集表里加一条，
/// 供 State 面板列出。append 失败 = 少列一个 state/signal，不影响被调试 app。
fn appendUniqueStateRef(list: *std.ArrayList(ScopedStateRef), alloc: std.mem.Allocator, ptr: *anyopaque, source_node_id: u32) void {
    for (list.items) |e| {
        if (e.ptr == ptr) return;
    }
    _ = list.append(alloc, .{
        .ptr = ptr,
        .source_node_id = source_node_id,
    }) catch {};
}

fn appendUniqueSignal(list: *std.ArrayList(core.DebugSignalRef), alloc: std.mem.Allocator, sig: core.DebugSignalRef) void {
    for (list.items) |e| {
        if (e.ptr == sig.ptr) return;
    }
    _ = list.append(alloc, sig) catch {};
}

fn signalValueText(sig: core.DebugSignalRef) []const u8 {
    if (sig.kind == .bool) {
        const s: *reactive.Signal(bool) = @ptrCast(@alignCast(sig.ptr));
        return if (s.peek()) "true" else "false";
    }
    return "<opaque>";
}

/// 诊断路径：把 state 的原始值排版成带缩进的多行文本，写进调用方给的**定长**
/// 缓冲 `out`。函数内所有 `catch {}` 吞的都是 NoSpaceLeft：缓冲写满即停止，
/// 返回已写部分 —— 面板显示一段被截断的值，正是期望的降级行为。
fn prettyStateValueInto(out: []u8, raw: []const u8) []const u8 {
    if (raw.len == 0) return raw;
    if (out.len == 0) return out[0..0];
    var writer = std.Io.Writer.fixed(out);
    const w = &writer;

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const ch = raw[i];
        if (in_string) {
            _ = w.writeByte(ch) catch {};
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }

        switch (ch) {
            '"' => {
                in_string = true;
                _ = w.writeByte(ch) catch {};
            },
            '{', '[' => {
                _ = w.writeByte(ch) catch {};
                depth += 1;
                _ = w.writeByte('\n') catch {};
                writeIndent(w, depth);
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
                _ = w.writeByte('\n') catch {};
                writeIndent(w, depth);
                _ = w.writeByte(ch) catch {};
            },
            ',' => {
                _ = w.writeAll(",\n") catch {};
                writeIndent(w, depth);
            },
            '=' => {
                _ = w.writeAll(": ") catch {};
            },
            else => {
                _ = w.writeByte(ch) catch {};
            },
        }
    }

    return writer.buffered();
}

/// 诊断路径：只给 prettyStateValueInto 写缩进空格，写的是定长缓冲，
/// 吞的是 NoSpaceLeft —— 缓冲满了就不再缩进，显示截断即可。
fn writeIndent(writer: anytype, depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        _ = writer.writeAll("  ") catch {};
    }
}

const CopyStateCtx = struct {
    cx: *Cx,
    text: []const u8,
};

const OwnedScopeText = struct {
    buf: []u8,
};

fn scopeOwnedText(scope: *Scope, text: []const u8) []const u8 {
    if (text.len == 0) return text;
    const dup = scope.allocator.dupe(u8, text) catch return text;
    const holder = scope.allocator.create(OwnedScopeText) catch {
        scope.allocator.free(dup);
        return text;
    };
    holder.* = .{ .buf = dup };
    scope.registerResource(@ptrCast(holder), struct {
        fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const owned: *OwnedScopeText = @ptrCast(@alignCast(ptr));
            alloc.free(owned.buf);
            alloc.destroy(owned);
        }
    }.destroy) catch {
        scope.allocator.free(dup);
        scope.allocator.destroy(holder);
        return text;
    };
    return holder.buf;
}

fn scopeAllocCopyStateCtx(scope: *Scope, cx: *Cx, text: []const u8) ?*CopyStateCtx {
    const ctx = scope.allocator.create(CopyStateCtx) catch return null;
    ctx.* = .{
        .cx = cx,
        .text = text,
    };
    scope.registerResource(@ptrCast(ctx), struct {
        fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const c: *CopyStateCtx = @ptrCast(@alignCast(ptr));
            alloc.destroy(c);
        }
    }.destroy) catch {
        scope.allocator.destroy(ctx);
        return null;
    };
    return ctx;
}

fn copyStateClick(ctx_ptr: *anyopaque) void {
    const ctx: *CopyStateCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.text.len == 0) return;
    _ = core.platform_services.clipboardSetText(ctx.cx.system_sdk, ctx.text);
}

fn colorRow(cx: *Cx, label: []const u8, color: Color) !*Node {
    const t = cx.tokens;
    const row = try cx.createNode(.box, .{
        .direction = .row,
        .gap = 6,
        .align_items = .center,
        .height = .{ .px = 18 },
    });

    // 标签
    try row.appendChild(cx.allocator, try core.text(cx, label, .{
        .font_size = 10,
        .color = t.color.fg_secondary,
    }));

    // 色块预览
    const swatch = try cx.createNode(.box, .{
        .width = .{ .px = 12 },
        .height = .{ .px = 12 },
        .border = .{ .radius = 2, .width = 1, .color = t.color.border },
    });
    cx.linkNodeToWorld(swatch);
    swatch.setBackgroundRaw(color);
    try row.appendChild(cx.allocator, swatch);

    // RGBA 值
    var color_buf: [32]u8 = undefined;
    const color_str = if (color.a == 255)
        std.fmt.bufPrint(&color_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b }) catch ""
    else
        std.fmt.bufPrint(&color_buf, "rgba({d},{d},{d},{d})", .{ color.r, color.g, color.b, color.a }) catch "";
    try row.appendChild(cx.allocator, try inlineText(cx, color_str, t.color.fg_primary, 10));

    return row;
}

fn styleColorRow(cx: *Cx, state: *DevToolsState, inspected: *Node, field: ?StyleField, label: []const u8, color: Color) !*Node {
    const row = try colorRow(cx, label, color);
    try appendStyleSourceLink(cx, state, inspected, field, row);
    return row;
}

fn kvRow(cx: *Cx, label: []const u8, value: []const u8) !*Node {
    const t = cx.tokens;
    const row = try cx.createNode(.box, .{
        .direction = .row,
        .gap = 8,
        .align_items = .center,
        .height = .{ .px = 16 },
    });
    try row.appendChild(cx.allocator, try core.text(cx, label, .{
        .font_size = 10,
        .color = t.color.fg_secondary,
    }));
    try row.appendChild(cx.allocator, try inlineText(cx, value, t.color.fg_primary, 10));
    return row;
}

fn styleKvRow(cx: *Cx, state: *DevToolsState, inspected: *Node, field: ?StyleField, label: []const u8, value: []const u8) !*Node {
    const row = try kvRow(cx, label, value);
    try appendStyleSourceLink(cx, state, inspected, field, row);
    return row;
}

fn kvRowInt(cx: *Cx, label: []const u8, value: i64) !*Node {
    var buf: [16]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
    return kvRow(cx, label, str);
}

fn styleKvRowInt(cx: *Cx, state: *DevToolsState, inspected: *Node, field: ?StyleField, label: []const u8, value: i64) !*Node {
    var buf: [16]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
    return styleKvRow(cx, state, inspected, field, label, str);
}

fn inlineText(cx: *Cx, text_content: []const u8, color: Color, size: f32) !*Node {
    const node = try core.text(cx, "", .{
        .font_size = size,
        .color = color,
    });
    if (node.getText()) |old| {
        var t = old;
        try setTextContent(cx.allocator, &t, text_content);
        node.setText(t);
    }
    return node;
}

fn setTextContent(allocator: std.mem.Allocator, t: *core.TextProps, src: []const u8) !void {
    try t.setContent(allocator, src);
}

// ========== 搜索/过滤 ==========

fn nodeMatchesFilter(node: *Node, filter: []const u8) bool {
    if (filter.len == 0) return true;

    // #id 过滤
    if (filter[0] == '#') {
        if (filter.len > 1) {
            const id_num = std.fmt.parseInt(u32, filter[1..], 10) catch return false;
            return node.id == id_num;
        }
        return false;
    }

    // tag 名匹配
    const tag_name = @tagName(node.tag);
    if (containsIgnoreCase(tag_name, filter)) return true;

    // component_name 匹配
    if (node.meta.ownership.meta.component_name) |name| {
        if (containsIgnoreCase(name, filter)) return true;
    }

    // 文本内容匹配
    if (node.getText()) |t| {
        if (t.content.len > 0 and containsIgnoreCase(t.content, filter)) return true;
    }

    return false;
}

fn subtreeMatchesFilter(node: *Node, filter: []const u8, depth: u32) bool {
    // 限制搜索深度，避免在大子树中深递归
    const max_filter_depth = 512;
    if (depth >= max_filter_depth) return false;
    if (nodeMatchesFilter(node, filter)) return true;
    for (node.children.items) |child| {
        if (subtreeMatchesFilter(child, filter, depth + 1)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const end = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ========== 树统计 ==========

const TreeStats = struct {
    total_nodes: u32 = 0,
    max_depth: u32 = 0,
    text_nodes: u32 = 0,
    box_nodes: u32 = 0,
};

fn collectTreeStats(node: *Node, depth: u32, stats: *TreeStats) void {
    const max_depth_limit = 512;
    const max_stats_nodes = 200_000;
    if (depth > max_depth_limit) return;
    if (stats.total_nodes >= max_stats_nodes) return;
    stats.total_nodes += 1;
    if (depth > stats.max_depth) stats.max_depth = depth;
    switch (node.tag) {
        .text => stats.text_nodes += 1,
        .box => stats.box_nodes += 1,
        else => {},
    }
    for (node.children.items) |child| {
        collectTreeStats(child, depth + 1, stats);
        if (stats.total_nodes >= max_stats_nodes) return;
    }
}

// ========== 节点选中同步（保留模式） ==========

/// 保留模式：检测 selected_node_id 变化，展开祖先并标记 tree_dirty + 待滚动
fn syncTreeSelection(state: *DevToolsState, target: *Cx) void {
    const selected = target.inspector.selected_node_id;
    if (state.last_target_selected_id == selected) return;
    state.last_target_selected_id = selected;
    clearEditingState(state);

    if (state.view_mode == .performance) return;

    state.tree_auto_scroll_pending = false;
    state.tree_auto_scroll_id = null;

    const selected_id = selected orelse return;

    // 展开祖先链（确保选中节点在 flat_rows 中可见）
    if (target.root) |root| {
        if (findNodeById(root, selected_id)) |node| {
            revealInspectableAncestors(state, node);
        }
    }

    state.tree_auto_scroll_pending = true;
    state.tree_auto_scroll_id = selected_id;
    state.tree_dirty = true;
    state.details_dirty = true;
}

/// 保留模式：在 rebuildFlatRows 之后，查找目标行并滚动 VirtualList
fn applyTreeAutoScroll(state: *DevToolsState) void {
    if (!state.tree_auto_scroll_pending) return;
    const target_id = state.tree_auto_scroll_id orelse {
        state.tree_auto_scroll_pending = false;
        return;
    };

    // 在 flat_rows 中查找目标节点的行索引
    for (state.flat_rows.items, 0..) |entry, idx| {
        if (entry.node.id == target_id) {
            if (state.vl_state) |vl| {
                virtual_list_mod.ensureVisible(vl, idx);
            }
            break;
        }
    }

    state.tree_auto_scroll_pending = false;
    state.tree_auto_scroll_id = null;
}

/// 诊断路径：把被选中节点的祖先链标成"展开"，好让它在树里可见。
/// put 失败 = 某一层没自动展开，用户手点一下即可，纯 UI 观感。
fn revealInspectableAncestors(state: *DevToolsState, node: *Node) void {
    var cur = node.parent;
    while (cur) |n| : (cur = n.parent) {
        if (!n.frame_state.state_bits.flags.inspectable) continue;
        _ = state.collapsed.remove(n.id);
        _ = state.explicitly_expanded.put(n.id, true) catch {};
    }
}

fn computeRenderRect(node: *Node) ComputedRect {
    return node.globalRect();
}

fn findNodeById(node: *Node, id: u32) ?*Node {
    if (node.id == id) return node;
    for (node.children.items) |child| {
        if (findNodeById(child, id)) |hit| return hit;
    }
    return null;
}

// ========== 行为/状态 ==========

// ========== Splitter 垂直分割线 ==========

const SPLITTER_HIT_WIDTH: f32 = 6;
const SPLITTER_GUIDE_THICKNESS: f32 = 2;
const SPLITTER_GUIDE_FADE_LEN: f32 = 20;
const MIN_LEFT_PANEL: f32 = 200;
const MAX_LEFT_PANEL: f32 = 600;

fn mountDevtoolsSplitter(cx: *Cx, state: *DevToolsState) !*Node {
    const allocator = cx.allocator;
    const t = cx.tokens;
    const guide_color = t.color.accent;
    const guide_transparent = Color.rgba(guide_color.r, guide_color.g, guide_color.b, 0);

    // 热区
    const splitter = try core.box(cx, .{
        .width = .{ .px = SPLITTER_HIT_WIDTH },
        .height = .{ .grow = .{} },
        .align_items = .center,
        .justify = .center,
        .cursor = .ew_resize,
    }, .{});
    splitter.style.cursor = .ew_resize;
    // line 及其子节点还没建好，splitter 自身也要守；state 指针在整棵装配成功后才发布
    errdefer cx.freeNode(splitter);

    // 视觉线 (上渐变 + 实线 + 下渐变)
    // 原来四个节点全部建完、`state.splitter_line_node = line` 先发布，最后才逐个 append ——
    // 中间任一步失败四个节点全漏，state 里还留着指向游离节点的指针。改成每个子节点建好即 adopt
    // 进 line、line 挂稳 splitter 之后才发布；line 自身用门控 errdefer 守到 adopt 前。
    const line = try core.box(cx, .{
        .width = .{ .px = SPLITTER_GUIDE_THICKNESS },
        .height = .{ .grow = .{} },
        .direction = .column,
        .opacity = 0.4,
    }, .{});
    var line_owned = true;
    errdefer if (line_owned) cx.freeNode(line);
    const top_fade = try core.adoptChild(cx, allocator, line, try core.box(cx, .{
        .width = .{ .px = SPLITTER_GUIDE_THICKNESS },
        .height = .{ .px = SPLITTER_GUIDE_FADE_LEN },
    }, .{}));
    (try top_fade.style.ensureExtFallible(allocator)).gradient = core.Gradient{
        .from = guide_transparent,
        .to = guide_color,
        .direction = .vertical,
    };
    _ = try core.adoptChild(cx, allocator, line, try core.box(cx, .{
        .width = .{ .px = SPLITTER_GUIDE_THICKNESS },
        .height = .{ .grow = .{} },
        .background = guide_color,
    }, .{}));
    const bottom_fade = try core.adoptChild(cx, allocator, line, try core.box(cx, .{
        .width = .{ .px = SPLITTER_GUIDE_THICKNESS },
        .height = .{ .px = SPLITTER_GUIDE_FADE_LEN },
    }, .{}));
    (try bottom_fade.style.ensureExtFallible(allocator)).gradient = core.Gradient{
        .from = guide_color,
        .to = guide_transparent,
        .direction = .vertical,
    };
    line_owned = false;
    _ = try core.adoptChild(cx, allocator, splitter, line);
    state.splitter_node = splitter;
    state.splitter_line_node = line;

    // 绑定事件
    splitter.behavior.events.on_event = devtoolsSplitterEvent;
    splitter.behavior.events.event_context = @ptrCast(state);

    return splitter;
}

fn devtoolsSplitterEvent(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    const state: *DevToolsState = @ptrCast(@alignCast(context.?));
    const cx = state.cx orelse return .ignored;

    switch (event) {
        .mouse_down => |e| {
            state.splitter_dragging = true;
            state.splitter_drag_start_x = e.x;
            state.splitter_drag_start_w = state.left_panel_width;
            if (state.splitter_node) |sn| {
                sn.on_capture_lost = struct {
                    fn lost(node: *Node) void {
                        const s: *DevToolsState = @ptrCast(@alignCast(node.behavior.events.event_context.?));
                        s.splitter_dragging = false;
                    }
                }.lost;
                cx.setPointerCapture(sn);
                // 本文件头部的策略：DevTools 不该杀掉被调试的 app。
                // 拖 splitter 拿不到 ew_resize 光标是纯观感降级，
                // splitter_dragging 状态不受影响。
                _ = cx.acquireCursor(sn, .ew_resize) catch {};
            }
            updateSplitterVisual(state, true);
            return .stop;
        },
        .mouse_move => |e| {
            if (state.splitter_dragging) {
                const delta = e.x - state.splitter_drag_start_x;
                const new_w = std.math.clamp(state.splitter_drag_start_w + delta, MIN_LEFT_PANEL, MAX_LEFT_PANEL);
                state.left_panel_width = new_w;
                if (state.left_panel_node) |lp| {
                    lp.style.width = .{ .px = new_w };
                    lp.markSizingDirty();
                }
                return .stop;
            }
            return .ignored;
        },
        .mouse_up => {
            if (state.splitter_dragging) {
                state.splitter_dragging = false;
                cx.releasePointerCapture();
                cx.refreshCursor();
                updateSplitterVisual(state, false);
                return .stop;
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

fn updateSplitterVisual(state: *DevToolsState, active: bool) void {
    const line = state.splitter_line_node orelse return;
    const opacity: f32 = if (active) 1.0 else 0.4;
    if (@abs(line.getOpacity() - opacity) <= 0.001) return;
    line.setOpacity(opacity);
    for (line.children.items) |seg| {
        seg.setOpacity(opacity);
    }
    if (state.cx) |c| c.needs_redraw = true;
}

const RowAction = enum { select, toggle, goto_source };

const RowCtx = struct {
    state: *DevToolsState,
    node_id: u32,
    action: RowAction,
    is_currently_collapsed: bool = false,
    /// For .goto_source: the component_name to look up. Points into the target
    /// tree's node meta, which outlives the click.
    component_name: ?[]const u8 = null,
};

fn rowEvent(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    const ctx: *RowCtx = @ptrCast(@alignCast(context.?));
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    switch (ctx.action) {
        .select => {
            const target = ctx.state.liveTarget() orelse return .handled;
            target.inspector.selected_node_id = ctx.node_id;
            target.inspector.enabled = true;
            target.needs_redraw = true;
            ctx.state.details_dirty = true;
            ctx.state.last_target_selected_id = null;
            ctx.state.tree_dirty = true;
            if (ctx.state.cx) |c| c.needs_redraw = true;
            return .handled;
        },
        .toggle => {
            ctx.state.toggle(ctx.node_id, ctx.is_currently_collapsed);
            ctx.state.tree_dirty = true;
            if (ctx.state.cx) |c| c.needs_redraw = true;
            return .stop;
        },
        .goto_source => {
            // component_name is borrowed from the target tree; validate the
            // target token before reading it.
            _ = ctx.state.liveTarget() orelse return .stop;
            const name = ctx.component_name orelse return .stop;
            const cx = ctx.state.cx orelse return .stop;
            const alloc = cx.allocator;
            const loc = source_link.resolve(alloc, name) catch return .stop;
            if (loc) |l| {
                defer alloc.free(l.file);
                // A failed launch (no editor on PATH) is not worth disrupting
                // the inspector over — the button simply appears to do nothing.
                source_link.open(alloc, l) catch {};
            }
            return .stop;
        },
    }
}

fn onDetailsTabChange(state: *DevToolsState, tab_id: []const u8) void {
    const tab: ?DetailsTab = inline for (std.meta.fields(DetailsTab)) |f| {
        if (std.mem.eql(u8, tab_id, f.name)) break @enumFromInt(f.value);
    } else null;
    if (tab) |t| {
        state.active_tab = t;
        // 离开 Style tab 的编辑态：编辑退出点之一（另一个是选中节点变化）。
        clearEditingState(state);
        state.details_dirty = true;
        syncDetailsTabs(state);
        if (state.cx) |c| c.needs_redraw = true;
    }
}

/// 把 state.active_tab 同步回 details Tabs 组件（下划线位置）。
/// 用户点击 tab 时组件自身已更新（no-op）；程序化 setActiveTab 时靠这里。
fn syncDetailsTabs(state: *DevToolsState) void {
    const tabs_state = state.details_tabs_state orelse return;
    const target_index: usize = @intFromEnum(state.active_tab);
    if (tabs_state.active_index == target_index) return;
    tabs_state.active_index = target_index;
    if (state.details_tabs_node) |tabs_node| {
        if (tabs_node.children.items.len > 0) {
            const tab_row = tabs_node.children.items[0];
            if (tab_row.meta.per_frame.hooks.before_render.main) |before_render| {
                before_render(tab_row);
            }
        }
        tabs_node.markRenderDirty();
    }
}

const PickModeCtx = struct {
    state: *DevToolsState,
};

fn pickModeEvent(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    const ctx: *PickModeCtx = @ptrCast(@alignCast(context.?));
    const target = ctx.state.liveTarget() orelse return .handled;
    // toggle pick mode
    target.inspector.pick_mode = !target.inspector.pick_mode;
    if (target.inspector.pick_mode) {
        // pick 模式需要 enabled 才能渲染 overlay 和处理 hover/click
        target.inspector.enabled = true;
    } else {
        target.inspector.hover_node_id = null;
        // 高亮画在 target 窗口里，必须让 target 重绘一帧来消掉 ——
        // 否则退出 pick 后最后的 hover 高亮冻结在 target 上。
        target.needs_redraw = true;
    }
    return .handled;
}

fn applyViewModeById(state: *DevToolsState, mode_id: []const u8) void {
    const mode: ?ViewMode = inline for (std.meta.fields(ViewMode)) |f| {
        if (std.mem.eql(u8, mode_id, f.name)) break @enumFromInt(f.value);
    } else null;
    if (mode) |m| {
        applyViewMode(state, m);
    }
}

fn applyViewMode(state: *DevToolsState, mode: ViewMode) void {
    if (state.view_mode == mode) return;
    state.view_mode = mode;
    state.tree_dirty = true;
    state.details_dirty = true;
    state.stats_dirty = true;
    if (state.cx) |c| c.needs_redraw = true;
}

fn viewModeId(mode: ViewMode) []const u8 {
    return switch (mode) {
        .elements => "elements",
        .components => "components",
        .console => "console",
        .performance => "performance",
    };
}

fn tabsStateFromNode(node: *Node) ?*TabsState {
    for (node.meta.ownership.debug_slots.state_ptrs[0..node.meta.ownership.debug_slots.state_count]) |slot| {
        if (slot) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
    }
    return null;
}

fn viewModeIndex(mode: ViewMode) usize {
    return switch (mode) {
        .elements => 0,
        .components => 1,
        .console => 2,
        .performance => 3,
    };
}

fn syncViewModeTabs(state: *DevToolsState) void {
    const tabs_state = state.view_mode_tabs_state orelse return;
    const target_index = viewModeIndex(state.view_mode);
    if (tabs_state.active_index == target_index) return;
    tabs_state.active_index = target_index;
    if (state.view_mode_tabs_node) |tabs_node| {
        if (tabs_node.children.items.len > 0) {
            const tab_row = tabs_node.children.items[0];
            if (tab_row.meta.per_frame.hooks.before_render.main) |before_render| {
                before_render(tab_row);
            }
        }
        tabs_node.markRenderDirty();
    }
}

const FilterChangeCtx = struct {
    state: *DevToolsState,
};

fn filterInputChanged(ctx: *FilterChangeCtx, new_value: []const u8) void {
    const len = @min(new_value.len, ctx.state.filter_buf.len);
    @memcpy(ctx.state.filter_buf[0..len], new_value[0..len]);
    ctx.state.filter_len = @intCast(len);
    ctx.state.tree_dirty = true;
    if (ctx.state.cx) |c| c.needs_redraw = true;
}

const CloseCtx = struct {
    handler: HandlerRef,
};

fn closeEvent(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    switch (event) {
        .mouse_down => {},
        else => return .ignored,
    }
    const ctx: *CloseCtx = @ptrCast(@alignCast(context.?));
    ctx.handler.invoke();
    return .stop;
}

// ========== DevTools 持久状态 ==========

const DevToolsState = struct {
    initialized: bool = false,
    allocator: std.mem.Allocator = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    collapsed: std.AutoHashMap(u32, bool) = undefined,
    /// 用户手动展开的节点（大子树默认折叠，展开后记录在此）
    explicitly_expanded: std.AutoHashMap(u32, bool) = undefined,
    /// 面板内容 scope：root 下所有组件/资源的归属。它是 `root_scope` 的子
    /// scope——切换明暗主题时整棵内容重建，dispose 这一个就能回收旧内容的全部
    /// 组件状态，而 root 节点本身（host 持有的 cx.root）与其 hook 保持不动。
    scope: ?*Scope = null,
    /// Cx.root_scope（见 ensureInit）。root 节点绑定在它上面。
    root_scope: ?*Scope = null,
    /// Title shown in panel header, supplied by PanelOptions. Borrowed.
    title: []const u8 = "DevTools",
    /// mountPanel 的原始选项，主题切换重建 header 时复用（on_close 等）。
    panel_opts: PanelOptions = .{},
    /// Header 明暗开关点击后置位；下一帧 devtoolsBeforeRender 在安全点
    /// 切主题并重建面板内容（不能在事件回调里拆掉正在分发事件的按钮）。
    theme_toggle_pending: bool = false,

    // View mode
    view_mode: ViewMode = .elements,

    // Tab
    active_tab: DetailsTab = .layout,

    // Style 实时编辑状态
    editing_field: ?EditableField = null,
    editing_node_id: ?u32 = null,

    // 左右分割: 左面板宽度 + splitter 拖拽状态
    left_panel_width: f32 = 350,
    splitter_dragging: bool = false,
    splitter_drag_start_x: f32 = 0,
    splitter_drag_start_w: f32 = 0,
    left_panel_node: ?*Node = null,
    splitter_node: ?*Node = null,
    splitter_line_node: ?*Node = null,

    // Search filter
    filter_buf: [64]u8 = undefined,
    filter_len: u8 = 0,
    last_target_selected_id: ?u32 = null,
    tree_auto_scroll_pending: bool = false,
    tree_auto_scroll_id: ?u32 = null,

    /// goto-source 按钮的点击上下文。只有一行能处于 hover 态，故整个面板复用
    /// 这一个实例——每帧新分配会在面板生命周期内累积（scope 资源直到 unmount
    /// 才释放）。
    goto_ctx: RowCtx = undefined,

    // VirtualList 数据源：扁平化的树行（持久化分配器上）
    flat_rows: std.ArrayList(FlatTreeEntry) = .empty,

    // === 保留模式字段 ===
    target_cx: ?*Cx = null,
    target_lifetime: ?*Cx.LifetimeToken = null,
    cx: ?*Cx = null,
    last_seen_target_frame_count: u64 = 0,
    /// 上一帧鼠标悬停所在的树行 slot。行内容只在 tree_dirty 时重建，而 hover
    /// 会改变行的渲染结果（goto 按钮），故需要在悬停行变化时补标脏。
    last_hovered_row: ?*Node = null,
    tree_dirty: bool = true,
    details_dirty: bool = true,
    stats_dirty: bool = true,
    vl_state: ?*virtual_list_mod.VirtualListState = null,
    details_content: ?*Node = null,
    stats_nodes_text: ?*Node = null,
    stats_depth_text: ?*Node = null,
    stats_cmds_text: ?*Node = null,
    stats_se_text: ?*Node = null,
    stats_frame_text: ?*Node = null,
    inspect_shell_node: ?*Node = null,
    console_shell_node: ?*Node = null,
    perf_shell_node: ?*Node = null,
    // Console panel mirror. Events are deep copies, so target ring eviction is
    // safe while DevTools renders a frame.
    console_events: std.ArrayList(console_mod.Event) = .empty,
    console_filtered_indices: std.ArrayList(usize) = .empty,
    console_cursor: u64 = 0,
    console_revision: u64 = 0,
    console_clear_generation: u64 = 0,
    console_filter_buf: [128]u8 = undefined,
    console_filter_len: u8 = 0,
    console_level_mask: u8 = 0x1f,
    console_vl_state: ?*virtual_list_mod.VirtualListState = null,
    console_status_text: ?*Node = null,
    console_toolbar_node: ?*Node = null,
    console_filter_node: ?*Node = null,
    console_level_buttons: [5]?*Node = .{null} ** 5,
    // Performance 面板保留节点引用
    perf_fps_text: ?*Node = null,
    perf_bar_container: ?*Node = null,
    perf_bars: [perf_chart_sample_count]?*Node = .{null} ** perf_chart_sample_count,
    perf_target_text: ?*Node = null,
    perf_timing_text: ?*Node = null,
    perf_summary_text: ?*Node = null,
    perf_interaction_text: ?*Node = null,
    perf_cache_text: ?*Node = null,
    perf_mounted: bool = false,
    /// perfBeforeRender 上次看到的 target.frame_count（idle 检测专用，与
    /// last_seen_target_frame_count 分开——后者在 devtoolsBeforeRender 里
    /// 每帧被消费，无法用来测"多久没变"）。
    perf_seen_frame_count: u64 = 0,
    perf_last_frame_change: ?std.time.Instant = null,
    /// 滚动时间桶（每桶 100ms，共 64 桶 ≈ 6.4s 窗口）。监控按墙钟持续
    /// 向前滚——target 停帧时滚出 idle 空档，而不是把"最近 64 个渲染帧"
    /// 的快照冻在屏上（Chrome FPS meter 语义）。
    /// 值：<0 = 桶未填充；0 = 桶内无渲染帧（idle）；>0 = 桶内平均 FPS。
    perf_live_fps: [perf_chart_sample_count]f32 = @splat(-1.0),
    /// 下一个要写入的桶（环形游标；渲染时从这里往后读 = 最旧→最新）。
    perf_live_head: usize = 0,
    perf_bucket_start: ?std.time.Instant = null,
    perf_bucket_frames: u64 = 0,
    // 组件化 Header 引用
    pick_btn_node: ?*Node = null,
    view_mode_tabs_node: ?*Node = null,
    view_mode_tabs_state: ?*TabsState = null,
    // Details tab bar 引用（程序化 setActiveTab 时同步下划线）
    details_tabs_node: ?*Node = null,
    details_tabs_state: ?*TabsState = null,
    // 详情区域组件 Scope（每次重建时 dispose + 重建）
    details_scope: ?*Scope = null,

    fn ensureInit(self: *DevToolsState, cx: *Cx) !void {
        if (self.initialized) return;
        self.allocator = cx.allocator;
        self.arena = std.heap.ArenaAllocator.init(cx.allocator);
        self.collapsed = std.AutoHashMap(u32, bool).init(cx.allocator);
        self.explicitly_expanded = std.AutoHashMap(u32, bool).init(cx.allocator);

        // This scope owns the entire retained DevTools component tree. It must
        // also be the Cx root scope so Cx.deinit()/unmount() can reach and
        // dispose it before freeing the nodes. Keeping an independent parentless
        // scope here leaked every child component when the DevTools window
        // closed (Button/Input/VirtualList/Tabs/ScrollArea were all descendants
        // of this one unreachable root).
        if (cx.root_scope) |root_scope| {
            self.scope = root_scope;
        } else {
            const root_scope = try Scope.init(cx.allocator, null, cx.owner);
            cx.root_scope = root_scope;
            self.scope = root_scope;
        }
        self.root_scope = self.scope;
        self.initialized = true;
    }

    /// mountPanel 失败时 root 整棵回收，而子 mount 中途写进来的节点 / 子状态指针
    ///（vl_state / details_content / perf_* / console_* / stats_* / splitter_*）会悬垂——
    /// 同一 Cx 再次 mountPanel、或事件 handler（event_context = state）读到它们就是 UAF。
    /// 失败路径统一清零（交叉审查 P1/P2）。scope / target / cx 不属于这批，保留。
    pub fn clearMountedNodeRefs(self: *DevToolsState) void {
        self.left_panel_node = null;
        self.splitter_node = null;
        self.splitter_line_node = null;
        self.last_hovered_row = null;
        self.vl_state = null;
        self.details_content = null;
        self.stats_nodes_text = null;
        self.stats_depth_text = null;
        self.stats_cmds_text = null;
        self.stats_se_text = null;
        self.stats_frame_text = null;
        self.inspect_shell_node = null;
        self.console_shell_node = null;
        self.perf_shell_node = null;
        self.console_vl_state = null;
        self.console_status_text = null;
        self.console_toolbar_node = null;
        self.console_filter_node = null;
        self.console_level_buttons = .{null} ** self.console_level_buttons.len;
        self.perf_fps_text = null;
        self.perf_bar_container = null;
        self.perf_bars = .{null} ** perf_chart_sample_count;
        self.perf_target_text = null;
        self.perf_timing_text = null;
        self.perf_summary_text = null;
        self.perf_interaction_text = null;
        self.perf_cache_text = null;
        self.perf_mounted = false;
        self.pick_btn_node = null;
        self.view_mode_tabs_node = null;
        self.view_mode_tabs_state = null;
        self.details_tabs_node = null;
        self.details_tabs_state = null;
    }

    pub fn deinit(self: *DevToolsState) void {
        if (!self.initialized) return;
        // 注意: 不要在这里 dispose scope/details_scope。
        // DevTools scope 已登记为 Cx.root_scope，Cx.deinit/unmount 会在释放
        // 节点树之前 dispose 整棵 scope。deinit 也可能在 Cx.freeNode
        // 递归中通过 on_cleanup → StateStore.remove 调用，所以这里只清理
        // DevToolsState 自身所有的容器，不重复触碰 scope。
        self.details_scope = null;
        self.arena.deinit();
        self.collapsed.deinit();
        self.explicitly_expanded.deinit();
        self.flat_rows.deinit(self.allocator);
        for (self.console_events.items) |*event| event.deinit(self.allocator);
        self.console_events.deinit(self.allocator);
        self.console_filtered_indices.deinit(self.allocator);
        self.clearTarget();
        self.initialized = false;
    }

    fn setTarget(self: *DevToolsState, target: *Cx) void {
        // Retain before releasing the previous marker so re-binding the same Cx
        // cannot transiently drop its token to zero.
        const next_lifetime = target.retainLifetimeToken();
        if (self.target_lifetime) |previous| previous.release();
        self.target_cx = target;
        self.target_lifetime = next_lifetime;
    }

    fn clearTarget(self: *DevToolsState) void {
        if (self.target_lifetime) |token| token.release();
        self.target_lifetime = null;
        self.target_cx = null;
    }

    fn liveTarget(self: *const DevToolsState) ?*Cx {
        const token = self.target_lifetime orelse return null;
        if (!token.isAlive()) return null;
        return self.target_cx;
    }

    fn frameAlloc(self: *DevToolsState) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn isCollapsed(self: *DevToolsState, id: u32) bool {
        return self.collapsed.get(id) != null;
    }

    /// 是否被用户手动展开过
    fn isExplicitlyExpanded(self: *DevToolsState, id: u32) bool {
        return self.explicitly_expanded.get(id) != null;
    }

    /// is_currently_collapsed: 当前节点是否在 UI 上显示为折叠状态（含自动折叠）
    ///
    /// 诊断路径：展开/折叠只是树面板的显示偏好。put 失败 = 这次点击没记住状态
    /// （下一帧仍按默认折叠规则显示），用户再点一次即可，无正确性影响。
    fn toggle(self: *DevToolsState, id: u32, is_currently_collapsed: bool) void {
        if (is_currently_collapsed) {
            // 当前折叠 → 展开
            _ = self.collapsed.remove(id);
            _ = self.explicitly_expanded.put(id, true) catch {};
        } else {
            // 当前展开 → 折叠
            _ = self.explicitly_expanded.remove(id);
            _ = self.collapsed.put(id, true) catch {};
        }
    }
};

fn getState(cx: *Cx) !*DevToolsState {
    const state_ptr = try cx.state(DevToolsState, DEVTOOLS_STATE_ID, DevToolsState{});
    try state_ptr.ensureInit(cx);
    return state_ptr;
}

test "DevTools root scope is owned by its Cx" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const state = try getState(cx);
    try std.testing.expect(state.scope != null);
    try std.testing.expect(cx.root_scope != null);
    try std.testing.expect(state.scope.? == cx.root_scope.?);
}

test "DevTools stops observing a target Cx that has been destroyed" {
    var target = try Cx.init(std.testing.allocator);
    target.root = try core.box(target, .{}, .{});

    var dev = try Cx.init(std.testing.allocator);
    defer dev.deinit();
    const panel = try mountPanel(dev, target, .{});
    dev.root = panel;

    target.deinit();

    // The retained liveness token is safe to read after `target` itself is
    // gone. Per-frame hooks and event helpers must stop at that boundary.
    devtoolsBeforeRender(panel);
    const state = try getState(dev);
    try std.testing.expect(state.liveTarget() == null);
    try std.testing.expect(!refreshConsole(dev));
}

test "DevTools header theme toggle flips scheme and rebuilds panel content" {
    var target = try Cx.init(std.testing.allocator);
    defer target.deinit();
    target.root = try core.box(target, .{}, .{});

    var dev = try Cx.init(std.testing.allocator);
    defer dev.deinit();
    dev.setTheme(&theme.light);
    const panel = try mountPanel(dev, target, .{});
    dev.root = panel;

    const state = try getState(dev);
    const old_header = state.pick_btn_node.?;
    const child_count = panel.children.items.len;
    try std.testing.expect(state.scope.? != state.root_scope.?);

    // 点击开关只置位，不在事件回调里拆树。
    try std.testing.expectEqual(EventResult.handled, themeToggleEvent(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left } }, state));
    try std.testing.expect(dev.tokens == &theme.light);

    devtoolsBeforeRender(panel);
    try std.testing.expect(dev.tokens == &theme.dark);
    try std.testing.expect(!state.theme_toggle_pending);
    try std.testing.expectEqual(child_count, panel.children.items.len);
    try std.testing.expect(state.pick_btn_node != null and state.pick_btn_node.? != old_header);
    try std.testing.expectEqual(theme.dark.color.bg_primary, panel.getBackground());

    state.theme_toggle_pending = true;
    devtoolsBeforeRender(panel);
    try std.testing.expect(dev.tokens == &theme.light);
    try std.testing.expectEqual(child_count, panel.children.items.len);
}

test "DevTools float formatting accepts non-finite and extreme rect values" {
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("nan", dv_fmt.fmtFloat(&buf, std.math.nan(f32)));
    try std.testing.expectEqualStrings("inf", dv_fmt.fmtFloat(&buf, std.math.inf(f32)));
    try std.testing.expectEqualStrings("-inf", dv_fmt.fmtFloat(&buf, -std.math.inf(f32)));

    const extreme = dv_fmt.fmtFloat(&buf, 1.0e30);
    try std.testing.expect(extreme.len > 0);
    try std.testing.expect(!std.mem.eql(u8, extreme, "0"));
}

test "setTextContent keeps full long text via owned storage" {
    var t = core.TextProps{};
    defer if (t.owned and t.content.len > 0) std.testing.allocator.free(t.content);

    const s = "1234567890abcdefg"; // 17 bytes
    try setTextContent(std.testing.allocator, &t, s);
    try std.testing.expect(t.owned);
    try std.testing.expectEqualStrings(s, t.content);
}

test "setTextContent keeps short text inline" {
    var t = core.TextProps{};
    const s = "short";
    try setTextContent(std.testing.allocator, &t, s);
    try std.testing.expect(!t.owned);
    try std.testing.expectEqualStrings(s, t.content);
}

fn testFindByTestId(node: *Node, test_id: []const u8) ?*Node {
    if (node.meta.ownership.meta.test_id) |own| {
        if (std.mem.eql(u8, own, test_id)) return node;
    }
    for (node.children.items) |child| {
        if (testFindByTestId(child, test_id)) |found| return found;
    }
    return null;
}

test "Style tab adds goto-source only for properties with tracked origins" {
    var target = try Cx.init(std.testing.allocator);
    defer target.deinit();
    const inspected = try core.box(target, .{ .background = Color.BLACK }, .{});
    target.root = inspected;

    var dev = try Cx.init(std.testing.allocator);
    defer dev.deinit();
    const state = try getState(dev);
    state.setTarget(target);
    const panel = try core.box(dev, .{}, .{});
    dev.root = panel;

    try buildStyleTab(dev, state, inspected, panel);
    const source_btn = testFindByTestId(panel, "devtools.style.goto_source") orelse
        return error.StyleSourceButtonMissing;
    try std.testing.expect(source_btn.behavior.events.on_event != null);
    try std.testing.expect(source_btn.behavior.events.event_context != null);

    // gap 没在这个 BoxStyle 中声明，不能用 background 的 base 来源冒充。
    try std.testing.expect(inspected.styleOrigin(.gap) == null);
}

test "replaceTextContent upgrades long text to owned storage" {
    var t = core.TextProps{};
    defer if (t.owned and t.content.len > 0) std.testing.allocator.free(t.content);

    try setTextContent(std.testing.allocator, &t, "short");
    try replaceTextContent(std.testing.allocator, &t, "Timing(us): layout 1 | render 2 | encode 3 | flush 4 | total 5");

    try std.testing.expect(t.owned);
    try std.testing.expectEqualStrings("Timing(us): layout 1 | render 2 | encode 3 | flush 4 | total 5", t.content);
}

test "DevTools Console mirrors pre-mount history, pagination, filtering and clear" {
    var target = try Cx.init(std.testing.allocator);
    defer target.deinit();
    target.console().configure(.{ .terminal_level = null, .max_entries = 2_000 });
    target.root = try core.box(target, .{ .width = .{ .px = 320 }, .height = .{ .px = 200 } }, .{});

    // More than one mirror page proves that a quiet target cannot strand the
    // second page after DevTools acknowledges the first revision.
    for (0..1_500) |i| target.console().debug("history-{d}", .{i});
    target.console().writeAt(.err, @src(), "needle-error", .{});

    var dev = try Cx.init(std.testing.allocator);
    defer dev.deinit();
    const panel = try mountPanel(dev, target, .{});
    dev.root = panel;
    dev.setViewport(1_000, 700);
    try std.testing.expect(setViewMode(dev, "console"));
    try std.testing.expect(refreshConsole(dev));
    const console_state = try getState(dev);
    try std.testing.expect(switch (console_state.console_toolbar_node.?.style.width) {
        .grow => true,
        else => false,
    });
    try std.testing.expect(switch (console_state.console_filter_node.?.style.width) {
        .grow => true,
        else => false,
    });
    try std.testing.expectEqual(@as(usize, 1_501), consoleVisibleEventCount(dev));
    try std.testing.expect(consoleContainsText(dev, "history-1499"));
    try std.testing.expect(consoleContainsText(dev, "needle-error"));

    try std.testing.expect(setConsoleFilter(dev, "needle"));
    try std.testing.expectEqual(@as(usize, 1), consoleVisibleEventCount(dev));
    try std.testing.expect(setConsoleFilter(dev, ""));

    target.console().clear();
    try std.testing.expect(refreshConsole(dev));
    try std.testing.expectEqual(@as(usize, 0), consoleVisibleEventCount(dev));
    target.console().writeAt(.warn, @src(), "after-clear", .{});
    try std.testing.expect(refreshConsole(dev));
    try std.testing.expectEqual(@as(usize, 1), consoleVisibleEventCount(dev));
    try std.testing.expect(consoleContainsText(dev, "after-clear"));

    const source_slot = try core.box(dev, .{}, .{});
    defer dev.freeNode(source_slot);
    renderConsoleRow(source_slot, 0, dev, @ptrCast(try getState(dev)));
    try std.testing.expect(source_slot.behavior.events.event_context != null);
    try std.testing.expect(source_slot.behavior.events.on_event != null);
    try std.testing.expectEqual(core.CursorShape.pointer, source_slot.style.cursor);

    // Render the mounted Console tree once so the test covers the retained UI
    // hooks and virtualized row path in addition to the public mirror API.
    _ = dev.render();
}

// Make sure tests in `overlay` (and any other nested imports) get discovered
// when this file is reached via `ui.devtools`.
test {
    std.testing.refAllDecls(@This());
}

pub fn wantsTraceCapture(cx: *Cx) bool {
    const state = getState(cx) catch return false;
    return state.active_tab == .render or state.active_tab == .trace;
}

pub fn syncTargetCx(cx: *Cx, target: *Cx) void {
    const state = getState(cx) catch return;
    state.setTarget(target);
}

pub fn setActiveTab(cx: *Cx, tab_id: []const u8) bool {
    const state = getState(cx) catch return false;
    onDetailsTabChange(state, tab_id);
    return std.mem.eql(u8, state.active_tab.idStr(), tab_id);
}

pub fn setViewMode(cx: *Cx, mode_id: []const u8) bool {
    const state = getState(cx) catch return false;
    applyViewModeById(state, mode_id);
    return std.mem.eql(u8, viewModeId(state.view_mode), mode_id);
}

/// Set the Elements-tree filter programmatically (same effect as typing in the
/// filter box). Matching rows are revealed regardless of collapse state, which
/// makes it the reliable way for a test to reach a deeply nested component.
pub fn setTreeFilter(cx: *Cx, filter: []const u8) bool {
    const state = getState(cx) catch return false;
    const len = @min(filter.len, state.filter_buf.len);
    @memcpy(state.filter_buf[0..len], filter[0..len]);
    state.filter_len = @intCast(len);
    state.tree_dirty = true;
    if (state.cx) |c| c.needs_redraw = true;
    return true;
}

/// Programmatic Console controls used by real-window probes and E2E fixtures.
pub fn refreshConsole(cx: *Cx) bool {
    const state = getState(cx) catch return false;
    const target = state.liveTarget() orelse return false;
    syncConsole(state, target);
    return true;
}

pub fn consoleVisibleEventCount(cx: *Cx) usize {
    const state = getState(cx) catch return 0;
    return state.console_filtered_indices.items.len;
}

pub fn consoleContainsText(cx: *Cx, text: []const u8) bool {
    const state = getState(cx) catch return false;
    for (state.console_filtered_indices.items) |index| {
        if (index < state.console_events.items.len and consoleContainsIgnoreCase(state.console_events.items[index].message, text)) return true;
    }
    return false;
}

pub fn setConsoleFilter(cx: *Cx, filter: []const u8) bool {
    const state = getState(cx) catch return false;
    const len = @min(filter.len, state.console_filter_buf.len);
    @memcpy(state.console_filter_buf[0..len], filter[0..len]);
    state.console_filter_len = @intCast(len);
    rebuildConsoleFilter(state);
    cx.needs_redraw = true;
    return true;
}

// DevTools 面板整条 mount 的逐分配点 OOM sweep（与 components/oom_sweep 同口径：
// per-case GPA 判 leak、induced>0 防空转）。mountPanel 需要一个 target Cx，helper 的
// MountFn(scope, cx) 形态放不下，这里手写一份。
test "mountPanel 在任意分配点失败时不泄漏" {
    const t = std.testing;
    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const target = try Cx.init(t.allocator);
        defer target.deinit();
        target.root = try core.box(target, .{}, .{});
        const dev = try Cx.init(counting.allocator());
        defer dev.deinit();
        const before = counting.alloc_index;
        dev.root = try mountPanel(dev, target, .{});
        break :blk counting.alloc_index - before;
    };
    try t.expect(total_allocs > 0);

    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;
    for (0..total_allocs) |failure_index| {
        var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        {
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const target = try Cx.init(t.allocator);
            defer target.deinit();
            target.root = try core.box(target, .{}, .{});
            const dev = Cx.init(failing.allocator()) catch {
                _ = gpa.deinit();
                continue;
            };
            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = mountPanel(dev, target, .{});
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |panel| {
                dev.root = panel;
            } else |_| {
                induced += 1;
                // 失败后 state 里不能留指向已回收节点的指针（交叉审查 P1/P2）
                const st = getState(dev) catch unreachable;
                try t.expect(st.splitter_node == null);
                try t.expect(st.splitter_line_node == null);
                try t.expect(st.vl_state == null);
                try t.expect(st.details_content == null);
                try t.expect(st.perf_fps_text == null);
                try t.expect(st.console_status_text == null);
                try t.expect(st.stats_nodes_text == null);
                try t.expect(st.view_mode_tabs_node == null);
                try t.expect(st.details_tabs_node == null);
            }
            dev.deinit();
        }
        if (gpa.deinit() == .leak) {
            leaked += 1;
            if (first_leak == null) first_leak = failure_index;
        }
    }
    // 空转防护按比例而非绝对下限（口径同 oom_sweep.zig）：induced > 0 的门槛
    // 比实测值低三个数量级，挡不住「mount 提前 return 导致分配点坍塌」。
    const min_induced = total_allocs / 2;
    if (induced < min_induced) {
        std.debug.print(
            "\n[{s}] sweep 覆盖坍塌: induced={d} / total_allocs={d}（要求 >= {d}）\n",
            .{ "devtools.mountPanel", induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) std.debug.print("\n[devtools.mountPanel] LEAK at {d}/{d} failure points; induced={d}; first={?d}\n", .{ leaked, total_allocs, induced, first_leak });
    try t.expectEqual(@as(usize, 0), leaked);
}
