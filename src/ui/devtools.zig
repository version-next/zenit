/// DevTools surface, two complementary tools:
///
///   1. `panel` (this file), full DevTools window: elements / components /
///      performance tabs. Mount in a second native window via
///      `devtools.mountPanel(cx, target_cx, .{ .on_close = close_handler })`.
///
///   2. `overlay` (sub-module), in-window inspector: dashed-rect hover
///      highlight + dimension/component label. Add via
///      `try ui.devtools.overlay.attach(cx, scope, root, .{})`.
///
/// Features:
/// P0: Complete Style property panel / component name / child count / text preview
/// P1: search filter / tab switch (Layout/Style/State/Events) / render dirty mark
/// P2: Signal/Effect viewer / render stats / tree stats / Events panel
///
/// OOM strategy of this file: `catch {}` on all diagnostic paths, intentionally swallowing alloc
/// failure. DevTools is a **tool observing the debugged app** and holds no authoritative app
/// state: every panel line is a fresh snapshot of target_cx each frame (rebuildFlatRows /
/// *BeforeRender / build*Tab). Worst case an alloc failure shows one fewer line / less text / a
/// tree one level unexpanded, self-healing next frame; layout/hit/state/render correctness of the
/// debugged app is unaffected. Panicking or propagating would let opening the debug panel crash
/// the debugged app, which is explicitly unwanted.
///
/// Categories (not repeated per line below):
///   - panel UI build (appendChild / build*Tab): less panel content.
///   - collection buffers (flat_rows / scoped_state_ptrs / signal list append): one fewer entry;
///     all are per-frame temp tables.
///   - text format (writer print / writeAll / writeByte): stack buffer or frame arena, fail =
///     truncated display.
///   - UI pref expand/collapse (explicitly_expanded / collapsed put): a miss loses one line's
///     remembered expand state, pure UX.
///   - Scope resource cleanup (onDestroy): see the explanation at each place.
const std = @import("std");
const dv_fmt = @import("devtools/format.zig");
const core = @import("core.zig");
const box_model = @import("devtools/box_model.zig");
const console_mod = @import("console.zig");
const StyleField = @import("core/types.zig").StyleField;

/// In-window inspector overlay. See `core/devtools_overlay.zig`.
pub const overlay = @import("core/devtools_overlay.zig");
pub const source_link = @import("devtools/source_link.zig");

/// Render reason / event trace storage; data source of the DevTools Render / Trace panels.
///
/// A host app building a custom inspector panel needs it: `setGlobalTraceTarget(store, frame)`
/// starts collecting, `clearGlobalTraceTarget()` stops, then `DebugTraceStore` methods
/// `getRenderForNode` / `getRecentEvents` read back. Public capability, paired with devtools.
pub const trace = core.debug_trace;
const hooks = @import("hooks.zig");
const devtools_styles = @import("devtools/styles.zig");
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
const Signal = core.Signal;

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

const ScrollArea = scroll_area_mod.ScrollArea;
const Scope = reactive.Scope;

/// DevTools secondary info color (ID/count), more readable than fg_disabled in light mode
fn devtoolsMuted(t: *const theme.ThemeTokens) Color {
    return devtools_styles.palette(t).muted;
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

/// Elements tree row slot test_id. hoveredTreeRow walks up from hovered node to find row (pointer
/// usually lands on row's text/glyph child), e2e uses it to locate row; centralize to avoid
/// two-place string drift.
const tree_row_test_id = "devtools.tree.row";
const perf_chart_sample_count: usize = 64;
/// DevTools window keepalive poll period. DevTools observes another window's Cx, no cross-window
/// "target rendered -> DevTools redraw" push chain (MultiWindowApp each window independent
/// wantsFrame), so DevTools **must** self-poll unconditionally; early version only when target
/// idle, once target active some frame skips schedule, keepalive chain breaks forever, panel only
/// moves on mouse hover.
const devtools_keepalive_ns: u64 = 250_000_000;
/// Performance page poll period (10Hz): FPS/histograms real-time monitor, 250ms too sluggish; 100ms
/// only self-redraws at 10fps, no target observation disturbance.
const perf_keepalive_ns: u64 = 100_000_000;
/// Console page revision poll period, new logs visible in ~100ms.
const console_keepalive_ns: u64 = 50_000_000;
/// Scroll monitor time bucket width: 64 buckets * 100ms ~= 6.4s visible window.
const perf_bucket_ns: u64 = 100_000_000;
/// target.frame_count no advance over this time => FPS row shows (idle).
/// idle frame-gating is power-save behavior, panel must distinguish "not rendering" from "steady
/// 60fps", else frozen frame leaves FPS text at last value pretending healthy.
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

// ========== Panel config ==========

pub const PanelOptions = struct {
    on_close: ?HandlerRef = null,
    /// Title shown in the devtools panel header. Defaults to "DevTools";
    /// applications that want their product name (e.g. "Zenit DevTools",
    /// "MyApp Inspector") should pass it here.
    title: []const u8 = "DevTools",
    /// Header theme toggle switches between two themes. DevTools window's own theme, independent of
    /// target; initial theme takes cx.tokens scheme at mountPanel.
    light_theme: *const theme.ThemeTokens = &theme.light,
    dark_theme: *const theme.ThemeTokens = &theme.dark,
    /// Space reserved above the panel header for the window's titlebar (the
    /// macOS traffic lights over full-size content). Pass 0 when the host
    /// already draws its own window header above the panel.
    titlebar_safe_top: f32 = 28,
};

// ========== View mode ==========

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

// ========== Tab enum ==========

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

// ========== Style real-time edit ==========

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

    /// Read current value from target node
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
            // DevTool currently treats border.width/radius as Border aggregate edit.
            .border_width, .border_radius => .border,
        };
    }

    /// Write value to target node and trigger layout/render dirty
    fn writeValue(self: EditableField, node: *Node, val: f32) void {
        switch (self) {
            .gap => node.style.gap = val,
            .flex => node.style.flex = val,
            .flex_shrink => node.style.flex_shrink = val,
            .opacity => {
                node.setOpacity(val);
                return; // setOpacity already marked dirty
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

/// Editable property value row click context
const EditFieldCtx = struct {
    state: *DevToolsState,
    node_id: u32,
    field: EditableField,
};

/// Edit commit context
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
    const loc = source_link.resolveAddress(ctx.cx.allocator, ctx.cx.io, ctx.origin.address, is_return_address) catch return .stop;
    if (loc) |resolved| {
        defer ctx.cx.allocator.free(resolved.file);
        source_link.open(ctx.cx.allocator, ctx.cx.io, resolved) catch {};
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
    try btn.appendChild(cx.allocator, try inlineText(cx, "↗", cx.tokens.tokens.color.accent, 10));
    btn.behavior.events.event_context = ctx;
    btn.behavior.events.on_event = styleSourceEvent;
    try row.appendChild(cx.allocator, btn);
}

/// Build editable kvRow, show value + click to edit
fn editableKvRow(cx: *Cx, state: *DevToolsState, node: *Node, field: EditableField, parent: *Node) !void {
    const t = cx.tokens;
    const details_scope = state.details_scope orelse state.scope.?;
    const val = field.readValue(node);
    const is_editing = state.editing_field != null and
        state.editing_field.? == field and
        state.editing_node_id != null and
        state.editing_node_id.? == node.id;

    if (is_editing) {
        // Edit mode: show Input
        const row = try cx.createNode(.box, .{
            .direction = .row,
            .gap = 8,
            .align_items = .center,
            .height = .{ .px = 22 },
            .width = .{ .grow = .{} },
        });
        try row.appendChild(cx.allocator, try core.text(cx, field.label(), .{
            .font_size = 10,
            .color = t.tokens.color.fg_secondary,
        }));

        // Prep initial value text
        var val_buf: [12]u8 = undefined;
        const val_str = dv_fmt.fmtFloat(&val_buf, val);

        // Allocate commit context (bind to details_scope lifetime)
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
            // Diagnostic: register fail leaks this ctx's cleanup (scope teardown misses one small
            // struct), doesn't affect panel.
            // This is **leak not dangling**: ctx valid, event callbacks work. devtools panel
            // lifetime bounded count, not worth panic.
        }.destroy) catch {};

        const mounted_input = try Input(.{
            .value = val_str,
            .size = .sm,
            .width = 80,
            .on_change = cx.on(EditCommitCtx, commit_ctx, editFieldChanged),
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

        // Auto-focus real input_container, ensure following text_input hits input box itself.
        cx.setFocus(mounted_input.input_container);

        try parent.appendChild(cx.allocator, row);
    } else {
        // Display mode: value clickable
        const row = try cx.createNode(.box, .{
            .direction = .row,
            .gap = 8,
            .align_items = .center,
            .height = .{ .px = 16 },
        });
        try row.appendChild(cx.allocator, try core.text(cx, field.label(), .{
            .font_size = 10,
            .color = t.tokens.color.fg_secondary,
        }));

        // Clickable value
        var val_buf2: [12]u8 = undefined;
        const val_text = try inlineText(cx, dv_fmt.fmtFloat(&val_buf2, val), t.tokens.color.accent, 10);
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

        // Click event
        const edit_ctx = try details_scope.allocator.create(EditFieldCtx);
        edit_ctx.* = .{ .state = state, .node_id = node.id, .field = field };
        details_scope.adoptResource(@ptrCast(edit_ctx), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const c: *EditFieldCtx = @ptrCast(@alignCast(ptr));
                alloc.destroy(c);
            }
            // Diagnostic: register fail leaks this ctx's cleanup (scope teardown misses one small
            // struct), doesn't affect panel.
            // This is **leak not dangling**: ctx valid, event callbacks work. devtools panel
            // lifetime bounded count, not worth panic.
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

    // Parse number (intermediate states like "-"/"1." parse fail, silent wait next key)
    const val = std.fmt.parseFloat(f32, new_value) catch return;
    ctx.field.writeValue(node, val);

    // Real-time effect but **don't** exit edit: on_change fires every keystroke; doing
    // clearEditingState + details_dirty here = first key destroys Input, multi-digit (like "12")
    // never enters.
    // Exit via selected node change (syncTreeSelection) or tab switch (onDetailsTabChange).
    target.needs_redraw = true;
}

// ========== Retain mode entry ==========

/// Retain mode mount (call once first frame)
pub fn mountPanel(cx: *Cx, target: *Cx, opts: PanelOptions) !*Node {
    const t = cx.tokens;
    const state = try getState(cx);
    // Any step fail: root freed below via errdefer, state pointers all zero (no dangling)
    errdefer state.clearMountedNodeRefs();
    state.setTarget(target);
    state.cx = cx;
    state.title = opts.title;
    state.panel_opts = opts;
    state.tree_dirty = true;
    state.details_dirty = true;
    state.stats_dirty = true;
    state.last_seen_target_frame_count = target.frame_count;

    // Initial flattening
    rebuildFlatRows(state, target);

    const root = try core.box(cx, .{
        .direction = .column,
        .background = t.tokens.color.bg_primary,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    }, .{});
    errdefer cx.freeNode(root);

    // Content scope hangs under root scope: fail path reclaimed with Cx.root_scope.
    state.scope = try Scope.init(cx.allocator, state.root_scope.?, cx.owner);
    try buildPanelContent(cx, target, state, root);

    try core.bindScopeToNode(state.root_scope.?, root);

    // Root node hooks on_before_render to drive retain mode updates
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

/// Build all panel content under root (titlebar placeholder / header / inspect / console / perf),
/// components and resources own to `state.scope`. mountPanel first build and theme-switch rebuild
/// share.
fn buildPanelContent(cx: *Cx, target: *Cx, state: *DevToolsState, root: *Node) !void {
    const t = cx.tokens;
    // Eight subtrees all built as orphans, last tuple-spliced into root, mid-fail lost prior trees
    // (sweep: 889 injection sites lost 872). Now build tree, adopt immediately; root freed by
    // caller bottom-up; state node pointers publish only after assembly success.
    const a = cx.allocator;

    const titlebar_safe_top = state.panel_opts.titlebar_safe_top;
    if (titlebar_safe_top > 0) _ = try core.adoptChild(cx, a, root, try core.box(cx, .{
        .height = .{ .px = titlebar_safe_top },
        .background = t.tokens.color.bg_primary,
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
    // Left pane as whole chrome/content shell needs catch seam hit where search/header/tree meet.
    left_panel_ext.hit_roles = .{ .pointer = true, .scroll = true, .inspect = false };
    left_panel_ext.hit_behavior = .@"opaque";
    _ = try core.adoptChild(cx, a, left_panel, try buildSearchBar(cx, state));
    _ = try core.adoptChild(cx, a, left_panel, try mountTreeArea(cx, target, state));
    _ = try core.adoptChild(cx, a, left_panel, try mountStatsBar(cx, state, target));

    // Splitter: vertical divider
    _ = try core.adoptChild(cx, a, inspect_shell, try mountDevtoolsSplitter(cx, state));

    // Right panel: tab_bar + details content
    _ = try core.adoptChild(cx, a, inspect_shell, try mountDetails(cx, target, state));

    const console_shell = try core.adoptChild(cx, a, root, try mountConsoleShell(cx, target, state));
    console_shell.meta.ownership.meta.test_id = "devtools.console.shell";
    const perf_shell = try core.adoptChild(cx, a, root, try mountPerformanceShell(cx, state));
    perf_shell.meta.ownership.meta.test_id = "devtools.performance.shell";

    // Publish node pointers only after assembly success (fail: root freed, no dangling state
    // pointers)
    state.left_panel_node = left_panel;
    state.inspect_shell_node = inspect_shell;
    state.perf_shell_node = perf_shell;
    state.console_shell_node = console_shell;
    syncShellVisibility(state);
}

/// Header theme toggle click: just set flag, actual switch next frame in root hook.
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

fn freePanelChildren(cx: *Cx, parent: *Node) void {
    while (parent.children.items.len > 0) {
        const child = parent.children.items[parent.children.items.len - 1];
        parent.removeChildRetained(child);
        cx.freeNode(child);
    }
}

/// Switch DevTools window theme and rebuild panel content.
///
/// Panel most colors baked at build from cx.tokens (raw box/text no theme hook), cx.setTheme alone
/// refreshes components, so full rebuild: routine like detailsBeforeRender, break interaction refs,
/// unwire hook/scope pointers, dispose content scope, then detach/free children sequentially. Must call
/// from root before_render (tick runs root hook pre-recursion, child replace safe).
fn applyThemeToggle(state: *DevToolsState, cx: *Cx, target: *Cx, root: *Node) void {
    const opts = state.panel_opts;
    const next = if (cx.tokens.scheme == .dark) opts.light_theme else opts.dark_theme;

    for (root.children.items) |child| cx.invalidateReferencesTo(child);
    for (root.children.items) |child| {
        hooks.invalidateSubtreeHookState(child);
        core.clearNodeScopes(child);
    }
    // details_scope is content scope's child, disposed together.
    state.details_scope = null;
    if (state.scope) |s| s.dispose();
    state.scope = null;
    state.clearMountedNodeRefs();
    freePanelChildren(cx, root);
    _ = state.arena.reset(.retain_capacity);
    // Edit-state Input already freed with old details, exit edit, avoid post-rebuild focus steal.
    clearEditingState(state);

    cx.setTheme(next);
    root.setBackground(next.tokens.color.bg_primary);

    // Diagnostic: rebuild fail worst case: "this frame panel empty"; root, hook still there, user
    // re-toggle or close/reopen DevTools recovers.
    state.scope = Scope.init(cx.allocator, state.root_scope.?, cx.owner) catch return;
    buildPanelContent(cx, target, state, root) catch {
        state.clearMountedNodeRefs();
        freePanelChildren(cx, root);
    };

    state.tree_dirty = true;
    state.details_dirty = true;
    state.stats_dirty = true;
    state.last_hovered_row = null;
    root.markLayoutDirty();
    root.markRenderDirty();
    root.markInteractionDirty();
}

/// Retain mode main update hook (runs pre-layout each frame)
fn devtoolsBeforeRender(root_node: *Node) void {
    const state: *DevToolsState = @ptrCast(@alignCast(root_node.meta.per_frame.hooks.slots.anim_state orelse return));
    const target = state.liveTarget() orelse return;
    if (state.theme_toggle_pending) {
        state.theme_toggle_pending = false;
        if (state.cx) |dev_cx| applyThemeToggle(state, dev_cx, target, root_node);
    }
    syncShellVisibility(state);
    const cx = state.cx;

    // Unconditional keepalive: DevTools passive observer, target render doesn't push wake (see
    // devtools_keepalive_ns note).
    // scheduleRedrawAfterNs internally merges by soonest deadline, re-schedule harmless;
    // Performance page overrides via perfBeforeRender higher frequency.
    if (cx) |dev_cx| {
        const poll_ns = switch (state.view_mode) {
            .console => console_keepalive_ns,
            .performance => perf_keepalive_ns,
            else => devtools_keepalive_ns,
        };
        dev_cx.scheduleRedrawAfterNs(poll_ns);
    }

    if (state.view_mode == .console) syncConsole(state, target);

    // Detect target window change
    if (target.frame_count != state.last_seen_target_frame_count) {
        state.last_seen_target_frame_count = target.frame_count;
        state.stats_dirty = true;
        if (state.view_mode == .elements or state.view_mode == .components) {
            state.tree_dirty = true;
        }
        // details updates only on Render/Trace tabs each frame (real-time),
        // Layout/Style/State/Events only on selected node change (see syncTreeSelection)
        if (state.active_tab == .render or state.active_tab == .trace) {
            state.details_dirty = true;
        }
    }

    // Selected node change: expand ancestors + mark scroll needed
    if (state.view_mode == .elements or state.view_mode == .components) syncTreeSelection(state, target);

    // Hovered row change marks dirty: row slot content rebuilds on tree_dirty, hover changes render
    // result (goto button at row tail). No dirty = button appears only on next rebuild from other
    // cause, seems "click shows up".
    if (state.view_mode != .performance) {
        if (cx) |dev_cx| {
            const hovered_row = hoveredTreeRow(dev_cx);
            if (hovered_row != state.last_hovered_row) {
                state.last_hovered_row = hovered_row;
                state.tree_dirty = true;
            }
        }
    }

    // force refresh interaction index only when tree area about to rebuild/scroll.
    // Performance view doesn't show tree, marking dirty each frame makes DevTools itself produce
    // meaningless hit rebuild.
    if ((state.view_mode == .elements or state.view_mode == .components) and (state.tree_dirty or state.tree_auto_scroll_pending)) {
        root_node.markInteractionDirty();
    }

    // update tree data + VirtualList
    if (state.tree_dirty) {
        rebuildFlatRows(state, target);
        if (state.vl_state) |vl| {
            virtual_list_mod.updateItemCount(vl, state.flat_rows.items.len);
        }
        // auto-scroll to selected node (execute after rebuildFlatRows)
        applyTreeAutoScroll(state);
        syncViewModeTabs(state);

        state.tree_dirty = false;
        root_node.markRenderDirty();
    }

    // sync pick button active state (icon tint + background)
    if (state.pick_btn_node) |btn| {
        const is_active = target.inspector.pick_mode;
        const tokens = (state.cx orelse return).tokens;
        const pick_bg = if (is_active) tokens.tokens.color.accent else Color.TRANSPARENT;
        btn.setBackground(pick_bg);
        for (btn.children.items) |child| {
            const icon_tint = if (is_active) tokens.tokens.color.button_primary_fg else tokens.tokens.color.fg_secondary;
            _ = child.setTint(icon_tint);
            for (child.children.items) |grandchild| _ = grandchild.setTint(icon_tint);
        }
    }

    // update stats bar
    if (state.stats_dirty) {
        updateStatsBarContent(state, target);
        // in performance mode stats_dirty cleared by perfBeforeRender
        // in non-performance mode clear here
        if (state.view_mode != .performance) {
            state.stats_dirty = false;
        }
    }

    // detail content updated in detailsBeforeRender
}

/// rebuild flattened tree row data (on persistent allocator)
fn rebuildFlatRows(state: *DevToolsState, target: *Cx) void {
    state.flat_rows.clearRetainingCapacity();
    const root = target.root orelse return;
    const filter = if (state.filter_len > 0) state.filter_buf[0..state.filter_len] else "";
    switch (state.view_mode) {
        .elements => flattenTreeElements(state, root, 0, filter),
        .components => flattenTreeComponents(state, root, 0, filter),
        .console => {},
        .performance => {}, // performance mode doesn't need tree rows
    }
}

/// update stats bar text content
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

/// Retain mode: mount inspect tree region (VirtualList)
fn mountTreeArea(cx: *Cx, target: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    _ = target;

    // Outer shell (overflow_hidden prevents VirtualList content spilling into header/search bar)
    const wrapper = try core.box(cx, .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .overflow_hidden = true,
    }, .{});
    errdefer cx.freeNode(wrapper); // wrapper orphan before VL adoption

    // VirtualList (Elements/Components tree)
    const vl = try virtual_list_mod.VirtualList(.{
        .item_count = state.flat_rows.items.len,
        .item_height = tree_row_height,
        .overscan = 8,
        .padding = Padding.symmetric(4, 4),
        .background = t.tokens.color.bg_primary,
    }).mountWithContext(state.scope.?, cx, @ptrCast(state), null, renderTreeRowRetained);

    vl.container.style.height = .{ .grow = .{} };
    vl.container.style.width = .{ .grow = .{} };
    _ = try core.adoptChild(cx, cx.allocator, wrapper, vl.container);
    state.vl_state = vl.state;

    return wrapper;
}

fn mountPerformanceShell(cx: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    // shell first, ScrollArea adopted after build, panel content fills shell.content (fail: shell
    // freed whole)
    const shell = try core.box(cx, .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .px = 0 },
        .background = t.tokens.color.bg_primary,
    }, .{});
    errdefer cx.freeNode(shell);
    var perf_scroll = try ScrollArea(.{
        .padding = Padding.symmetric(8, 10),
        .background = t.tokens.color.bg_primary,
    }).mount(state.scope.?, cx);
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
    source_link.open(source_ctx.cx.allocator, source_ctx.cx.io, .{
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
    // shell -> toolbar first (errdefer catches all), children adopted post-build, state pointer
    // stable then publish.
    const shell = try core.box(cx, .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .px = 0 },
        .background = t.tokens.color.bg_primary,
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
        .background = t.tokens.color.bg_secondary,
        .border = .{
            .width = 0,
            .color = t.tokens.color.border,
            .side_widths = .{ 0, 0, 1, 0 },
        },
    }, .{}));
    toolbar.meta.ownership.meta.test_id = "devtools.console.toolbar";

    const clear_btn = try core.adoptChild(cx, a, toolbar, try Button(.{
        .label = "Clear",
        .variant = .ghost,
        .size = .xs,
        .on_click = Cx.handlerFrom(DevToolsState, state, clearConsolePanel),
        .base_style = .{
            .height = .{ .px = 28 },
            .padding = Padding.symmetric(0, 10),
            .background = t.tokens.color.bg_primary,
            .border = .{ .width = 1, .color = t.tokens.color.border, .radius = 5 },
            .text_color = t.tokens.color.fg_secondary,
            .font_weight = 600,
        },
        .hover_style = .{
            .background = t.tokens.color.accent.withAlpha(18),
            .border_color = t.tokens.color.accent.withAlpha(110),
            .text_color = t.tokens.color.fg_primary,
        },
    }).mount(scope, cx));
    clear_btn.meta.ownership.meta.test_id = "devtools.console.clear";

    const filter_ctx = try allocScopeResource(scope, ConsoleFilterCtx);
    filter_ctx.* = .{ .state = state };
    const filter = try core.adoptChild(cx, a, toolbar, try Input(.{
        .placeholder = "Filter console output",
        .value = state.console_filter_buf[0..state.console_filter_len],
        .size = .sm,
        .width = 320,
        .on_change = cx.on(ConsoleFilterCtx, filter_ctx, consoleFilterChanged),
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
        .background = t.tokens.color.border.withAlpha(170),
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
        .background = t.tokens.color.bg_primary,
        .border = .{ .width = 1, .color = t.tokens.color.border, .radius = 6 },
    }, .{}));

    const levels = [_]struct { level: console_mod.Level, label: []const u8 }{
        .{ .level = .debug, .label = "Debug" },
        .{ .level = .log, .label = "Log" },
        .{ .level = .info, .label = "Info" },
        .{ .level = .warn, .label = "Warn" },
        .{ .level = .err, .label = "Error" },
    };
    var level_enabled: [state.console_level_enabled.len]?*Signal(bool) = @splat(null);
    inline for (levels) |item| {
        const ctx = try allocScopeResource(scope, ConsoleLevelCtx);
        ctx.* = .{ .state = state, .level = item.level };
        // Toggle state is data: button look (background, opacity) derived, toggle only writes
        // signal
        const bit: u8 = @as(u8, 1) << @intCast(@backingInt(item.level));
        const enabled = try scope.createSignal(bool, (state.console_level_mask & bit) != 0);
        const look = try scope.createMemo(core.StyleOverride, .{ .enabled = enabled, .color = consoleLevelColor(t, item.level), .t = t }, struct {
            fn compute(c: anytype) core.StyleOverride {
                const on = c.enabled.get();
                return .{
                    .height = .{ .px = 24 },
                    .padding = Padding.symmetric(0, 7),
                    .border = .{ .radius = 4 },
                    .background = if (on) c.t.tokens.color.accent.withAlpha(22) else Color.TRANSPARENT,
                    .opacity = if (on) 1 else 0.46,
                    .text_color = c.color,
                    .font_size = 10,
                    .font_weight = 600,
                };
            }
        }.compute);
        const button = try core.adoptChild(cx, a, level_group, try Button(.{
            .label = item.label,
            .variant = .ghost,
            .size = .xs,
            .on_click = Cx.handlerFrom(ConsoleLevelCtx, ctx, toggleConsoleLevel),
            .base_style = look,
            .hover_style = .{
                .background = t.tokens.color.fg_primary.withAlpha(12),
            },
        }).mount(scope, cx));
        button.meta.ownership.meta.test_id = "devtools.console.level";
        level_enabled[@backingInt(item.level)] = enabled;
    }

    const vl = try virtual_list_mod.VirtualList(.{
        .item_count = 0,
        .item_height = 30,
        .overscan = 12,
        .padding = Padding.ZERO,
        .background = t.tokens.color.bg_primary,
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
        .background = t.tokens.color.bg_secondary,
        .border = .{
            .width = 0,
            .color = t.tokens.color.border,
            .side_widths = .{ 1, 0, 0, 0 },
        },
    }, .{}));
    const status_text = try core.adoptChild(cx, a, status, try core.text(cx, "0 messages", .{ .font_size = 10, .color = t.tokens.color.fg_secondary }));
    status_text.meta.ownership.meta.test_id = "devtools.console.status";

    // Publish state pointer only after assembly success
    state.console_filter_node = filter;
    state.console_toolbar_node = toolbar;
    for (level_enabled, 0..) |sig, i| state.console_level_enabled[i] = sig;
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
    const bit: u8 = @as(u8, 1) << @intCast(@backingInt(ctx.level));
    ctx.state.console_level_mask ^= bit;
    syncConsoleLevelButtons(ctx.state);
    rebuildConsoleFilter(ctx.state);
    if (ctx.state.cx) |cx| cx.needs_redraw = true;
}

fn consoleLevelColor(t: *const theme.ThemeTokens, level: console_mod.Level) Color {
    return switch (level) {
        .debug => devtoolsMuted(t),
        .log => t.tokens.color.fg_primary,
        .info => t.tokens.color.accent,
        .warn => t.tokens.color.warning,
        .err => t.tokens.color.danger,
    };
}

fn syncConsoleLevelButtons(state: *DevToolsState) void {
    for (state.console_level_enabled, 0..) |maybe, index| {
        const enabled = maybe orelse continue;
        const bit: u8 = @as(u8, 1) << @intCast(index);
        enabled.set((state.console_level_mask & bit) != 0);
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
        const bit: u8 = @as(u8, 1) << @intCast(@backingInt(event.level));
        if ((state.console_level_mask & bit) == 0) continue;
        if (filter.len != 0 and !consoleContainsIgnoreCase(event.message, filter) and !consoleContainsIgnoreCase(event.scope, filter)) continue;
        state.console_filtered_indices.append(state.allocator, index) catch break;
    }
    if (state.console_vl_state) |vl| {
        const old_total = @as(f32, @floatFromInt(vl.item_count)) * vl.props.item_height;
        const old_max_scroll = @max(@as(f32, 0), old_total - vl.scroll_state.viewport_height);
        const was_following_tail = vl.item_count == 0 or
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
        .color = t.tokens.color.border.withAlpha(90),
        .side_widths = .{ 0, 0, 1, 0 },
    };
    slot.setBackground(switch (event.level) {
        .warn => t.tokens.color.warning.withAlpha(12),
        .err => t.tokens.color.danger.withAlpha(14),
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
            .color = t.tokens.color.fg_secondary,
        }) catch return;
        const scope_badge = core.box(cx, .{
            .direction = .row,
            .align_items = .center,
            .height = .{ .px = 18 },
            .padding = Padding.symmetric(1, 5),
            .background = t.tokens.color.bg_secondary,
            .border = .{ .width = 1, .color = t.tokens.color.border.withAlpha(150), .radius = 4 },
        }, .{scope_text}) catch return;
        slot.appendChild(cx.allocator, scope_badge) catch return;
    }
    const message = core.text(cx, event.message, .{ .font_size = 12, .color = t.tokens.color.fg_primary }) catch return;
    message.meta.ownership.meta.test_id = "devtools.console.message";
    message.style.width = .{ .grow = .{} };
    message.style.overflow_hidden = true;
    slot.appendChild(cx.allocator, message) catch return;

    if (event.source) |source| {
        const basename = std.fs.path.basename(source.file);
        var buf: [160]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}:{d}", .{ basename, source.line }) catch basename;
        const source_node = core.text(cx, label, .{ .font_size = 9, .font_weight = 500, .color = t.tokens.color.accent }) catch return;
        slot.appendChild(cx.allocator, source_node) catch return;
    }
}

fn syncShellVisibility(state: *DevToolsState) void {
    const show_perf = state.view_mode == .performance;
    const show_console = state.view_mode == .console;
    const show_inspect = !show_perf and !show_console;
    // Per-hook timing only on performance panel open, normal frames skip double clock read per hook
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

/// Pre-create all Performance panel nodes (call once mount), each adopted post-build (append fail
/// it self-frees), state pointers stable then publish.
fn mountPerformancePanel(cx: *Cx, container: *Node, t: *const theme.ThemeTokens, state: *DevToolsState) !void {
    const allocator = cx.allocator;

    // Title
    _ = try core.adoptChild(cx, allocator, container, try core.text(cx, "Frame Performance", .{
        .font_size = 12,
        .color = t.tokens.color.fg_primary,
        .font_weight = 600,
    }));

    // FPS text
    const fps_node = try core.adoptChild(cx, allocator, container, try core.text(cx, "FPS: 0", .{
        .font_size = 11,
        .color = t.tokens.color.success,
    }));
    fps_node.meta.ownership.meta.test_id = "devtools.perf.fps";
    state.perf_fps_text = fps_node;

    // Histogram container
    const bar_container = try core.adoptChild(cx, allocator, container, try core.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 80 },
        .direction = .row,
        .align_items = .end,
        .gap = 1,
        .background = t.tokens.color.bg_secondary,
        .padding = Padding.all(4),
        .border = .{ .radius = 4 },
    }, .{}));
    bar_container.setMarginTop(8);
    state.perf_bar_container = bar_container;

    // Pre-create bar nodes
    var i: u32 = 0;
    while (i < perf_chart_sample_count) : (i += 1) {
        const bar = try core.adoptChild(cx, allocator, bar_container, try core.box(cx, .{
            .width = .{ .px = 3 },
            .height = .{ .px = 2 },
            .background = t.tokens.color.border,
            .border = .{ .radius = 1 },
        }, .{}));
        state.perf_bars[i] = bar;
    }

    // 16ms target line label
    const target_line = try core.adoptChild(cx, allocator, container, try core.text(cx, "  16.7ms target (60 FPS)", .{
        .font_size = 9,
        .color = devtoolsMuted(t),
    }));
    state.perf_target_text = target_line;

    // 4 timing text rows
    const timing_node = try core.adoptChild(cx, allocator, container, try core.text(cx, "Timing(us): --", .{
        .font_size = 10,
        .color = t.tokens.color.fg_secondary,
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

/// Performance panel on_before_render, incremental update (don't destroy/rebuild nodes)
fn perfBeforeRender(content_node: *Node) void {
    const state: *DevToolsState = @ptrCast(@alignCast(content_node.meta.per_frame.hooks.slots.anim_state orelse return));
    if (state.view_mode != .performance) return;
    if (!state.perf_mounted) return;
    const target = state.liveTarget() orelse return;
    const cx = state.cx orelse return;
    const t = cx.tokens;
    // Unconditional keepalive (10Hz): perf monitoring must continue, don't depend on target
    // rendering.
    // Can't schedule only on target idle, some frame target active breaks chain (history bug).
    cx.scheduleRedrawAfterNs(perf_keepalive_ns);

    // Target idle detect: frame_count no advance => panel shows (idle).
    const now_inst: ?@import("zenit_time").Instant = @import("zenit_time").Instant.now(cx.io) catch null;
    if (target.frame_count != state.perf_seen_frame_count or state.perf_last_frame_change == null) {
        state.perf_seen_frame_count = target.frame_count;
        state.perf_last_frame_change = now_inst;
    }
    const target_idle = blk: {
        const last = state.perf_last_frame_change orelse break :blk false;
        const now = now_inst orelse break :blk false;
        break :blk now.since(last) > perf_idle_indicator_ns;
    };

    // Scroll time bucket advance (wall clock, independent of target output): every 100ms record one
    // bucket "avg FPS in that bucket", no frames = 0. Monitor keeps rolling, doesn't freeze last
    // 64-frame snapshot after idle.
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

    const current_fps = liveCurrentFps(state);

    if (state.perf_fps_text) |n| {
        if (target_idle) {
            _ = updateTextNodeIfChanged(cx.allocator, n, "FPS: idle (rendering minimized)", .{});
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
                t.tokens.color.success
            else if (fps_f >= refresh_hz * 0.5)
                t.tokens.color.warning
            else
                t.tokens.color.danger;
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

    // Update bar height + color, time-bucket scroll graph: head forward = oldest->newest.
    // Empty bucket (idle/unfilled) draws 2px neutral baseline; with frames draws "bucket avg frame
    // time".
    // Bucket average smooths single-frame spikes, threshold relax to 1.1x/1.5x period, avoid 60Hz
    // full-frame 16.7ms~=period jitter mis-paint red.
    const target_ms: f32 = @floatCast(1000.0 / @as(f64, @floatCast(@max(1.0, target.display_refresh_hz))));
    var i: u32 = 0;
    while (i < perf_chart_sample_count) : (i += 1) {
        if (state.perf_bars[i]) |bar| {
            const val = state.perf_live_fps[(state.perf_live_head + @as(usize, i)) % perf_chart_sample_count];
            var bar_h: f32 = 2.0;
            var bar_color = t.tokens.color.border;
            if (val > 0) {
                const frame_ms = 1000.0 / val;
                bar_h = @max(2.0, @min(72.0, (frame_ms / target_ms) * 40.0));
                bar_color = if (frame_ms > target_ms * 1.5)
                    t.tokens.color.danger
                else if (frame_ms > target_ms * 1.1)
                    t.tokens.color.warning
                else
                    t.tokens.color.success;
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

    // Update timing text
    const perf = target.perf;
    if (state.perf_timing_text) |n| {
        // (encode_us/flush_us/wait_us/acquire_us/cpu_us/total_us fields deleted, 0 write)
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

/// VirtualList render callback (retain mode, VirtualList manages slot lifetime)
/// The tree-row slot mouse is over, or null. Walks up from hovered node (pointer usually lands on
/// row text/glyph child).
fn hoveredTreeRow(cx: *Cx) ?*Node {
    var cur: ?*Node = cx.hovered_node;
    var guard: usize = 0;
    while (cur) |n| {
        if (n.meta.ownership.meta.test_id) |tid| {
            if (std.mem.eql(u8, tid, tree_row_test_id)) return n;
        }
        if (guard >= 64) return null; // Guard vs abnormal deep/cycle parent chain
        guard += 1;
        cur = n.parent;
    }
    return null;
}

/// Whether `candidate` is `root` or sits inside it, hovering a row's text or
/// glyph should count as hovering the row.
fn isSelfOrAncestor(root: *Node, candidate: *Node) bool {
    var cur: ?*Node = candidate;
    var guard: usize = 0;
    while (cur) |n| {
        if (n == root) return true;
        if (guard >= 64) return false; // Guard vs abnormal deep/cycle parent chain
        guard += 1;
        cur = n.parent;
    }
    return false;
}

/// Each slot child was create then append, append fail orphaned child; changed all to adoptChild
/// (append fail it self-frees).
fn renderTreeRowRetained(node: *Node, index: usize, cx: *Cx, user_context: ?*anyopaque) void {
    const state: *DevToolsState = @ptrCast(@alignCast(user_context orelse return));
    if (index >= state.flat_rows.items.len) return;
    const entry = state.flat_rows.items[index];
    const target = state.liveTarget() orelse return;

    const t = cx.tokens;
    const s = devtools_styles.palette(t);
    const tree_node = entry.node;

    const is_selected = target.inspector.selected_node_id != null and target.inspector.selected_node_id.? == tree_node.id;
    const is_hovered = target.inspector.hover_node_id != null and target.inspector.hover_node_id.? == tree_node.id;

    const row_bg = if (is_selected) s.row_selected_bg else if (is_hovered) s.row_hover_bg else Color.TRANSPARENT;

    node.style.direction = .row;
    node.style.align_items = .center;
    node.style.gap = 4;
    node.style.padding = .{ .left = 4 + @as(f32, @floatFromInt(entry.depth)) * 12.0, .right = 4, .top = 0, .bottom = 0 };
    node.setBackgroundRaw(row_bg);
    node.style.width = .{ .grow = .{} };
    node.style.cursor = .pointer;
    node.meta.ownership.meta.test_id = tree_row_test_id;
    freePanelChildren(cx, node);

    // Expander
    if (entry.has_children) {
        const symbol = if (entry.collapsed) ">" else "v";
        _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, symbol, .{ .font_size = 9, .color = t.tokens.color.fg_secondary }) catch return) catch return;
    } else {
        _ = core.adoptChild(cx, cx.allocator, node, cx.createNode(.spacer, .{
            .width = .{ .px = 8 },
            .height = .{ .px = 12 },
        }) catch return) catch return;
    }

    // Tag / Component name
    if (state.view_mode == .components) {
        if (tree_node.meta.ownership.meta.component_name) |comp_name| {
            _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, comp_name, .{ .font_size = 11, .color = s.component_label, .font_weight = 600 }) catch return) catch return;
        }
    } else {
        const tag_name = @tagName(tree_node.tag);
        _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, tag_name, .{ .font_size = 11, .color = tagColor(tree_node.tag, t) }) catch return) catch return;
        if (tree_node.meta.ownership.meta.component_name) |comp_name| {
            _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, comp_name, .{ .font_size = 10, .color = s.component_label, .font_weight = 600 }) catch return) catch return;
        }
    }

    // ID
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "#{d}", .{tree_node.id}) catch "";
    _ = core.adoptChild(cx, cx.allocator, node, inlineText(cx, id_str, devtoolsMuted(t), 10) catch return) catch return;

    if (tree_node.frame_state.state_bits.flags.inspect_pick_disabled) {
        _ = core.adoptChild(cx, cx.allocator, node, inlineText(cx, "pick-off", t.tokens.color.warning, 9) catch return) catch return;
    }

    // Child count
    if (entry.has_children) {
        var count_buf: [12]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "({d})", .{tree_node.children.items.len}) catch "";
        _ = core.adoptChild(cx, cx.allocator, node, inlineText(cx, count_str, devtoolsMuted(t), 9) catch return) catch return;
    }

    // Text preview
    if (tree_node.getText()) |tp| {
        if (tp.content.len > 0) {
            const preview = tp.content[0..@min(tp.content.len, 30)];
            var preview_buf: [36]u8 = undefined;
            const preview_str = std.fmt.bufPrint(&preview_buf, "\"{s}\"", .{preview}) catch "";
            _ = core.adoptChild(cx, cx.allocator, node, inlineText(cx, preview_str, s.text_preview, 10) catch return) catch return;
        }
    }

    // Render dirty
    if (tree_node.frame_state.state_bits.dirty.core.render) {
        _ = core.adoptChild(cx, cx.allocator, node, core.text(cx, "*", .{ .font_size = 10, .color = t.tokens.color.warning }) catch return) catch return;
    }

    // Goto-source: show at row tail on hover, click opens external editor at component definition.
    // Only rows with parseable source location show, anon nodes and runtime-named components not
    // indexed; showing unresponsive button worse than hiding.
    // Note use cx.hovered_node (DevTools own window mouse hover), not is_hovered above (reads
    // target.inspector.hover_node_id, set only when mouse hovers **debugged app window** in pick
    // mode, unrelated to "line hover").
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
        // glyph may fail before btn hangs on node, gate defer guards window (break normal exit,
        // errdefer skips)
        var btn_owned = true;
        defer if (btn_owned) cx.freeNode(btn);
        btn.meta.ownership.meta.test_id = "devtools.tree.goto_source";
        _ = core.adoptChild(cx, cx.allocator, btn, inlineText(cx, "↗", s.component_label, 11) catch break :resolve_goto) catch break :resolve_goto;

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

    // Click event, reuse slot node's existing event_context, avoid per-rebuild alloc leak
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
        // toggle RowCtx store into slot node's focus_ring_anim (slot not destroyed, avoid child
        // rebuild leak)
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

/// Retain mode: mount stats row
fn mountStatsBar(cx: *Cx, state: *DevToolsState, target: *Cx) !*Node {
    const t = cx.tokens;
    const bar = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .width = .{ .grow = .{} },
        .height = .{ .px = 22 },
        .padding = Padding.symmetric(2, 8),
        .background = t.tokens.color.bg_tertiary,
        .border = .{ .width = 1, .color = t.tokens.color.border },
    }, .{});

    // Five text nodes adopted post-build, stable then publish into state (fail: bar freed, no
    // dangling state)
    errdefer cx.freeNode(bar);
    const a = cx.allocator;
    const nodes_text = try core.adoptChild(cx, a, bar, try core.text(cx, "Nodes: 0", .{ .font_size = 10, .color = t.tokens.color.fg_secondary }));
    const depth_text = try core.adoptChild(cx, a, bar, try core.text(cx, "Depth: 0", .{ .font_size = 10, .color = t.tokens.color.fg_secondary }));
    const cmds_text = try core.adoptChild(cx, a, bar, try core.text(cx, "Cmds: 0", .{ .font_size = 10, .color = t.tokens.color.fg_secondary }));
    const se_text = try core.adoptChild(cx, a, bar, try core.text(cx, "S:0 E:0", .{ .font_size = 10, .color = t.tokens.color.fg_secondary }));
    const frame_text = try core.adoptChild(cx, a, bar, try core.text(cx, "F:0", .{ .font_size = 10, .color = devtoolsMuted(t) }));
    state.stats_nodes_text = nodes_text;
    state.stats_depth_text = depth_text;
    state.stats_cmds_text = cmds_text;
    state.stats_se_text = se_text;
    state.stats_frame_text = frame_text;

    // Initial update
    updateStatsBarContent(state, target);

    return bar;
}

/// Retain mode: mount details panel (right panel)
fn mountDetails(cx: *Cx, target: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    _ = target;

    // wrapper first, tab_bar / ScrollArea adopted post-build; content pointer stable then publish
    const wrapper = try core.box(cx, .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .border = .{ .width = 1, .color = t.tokens.color.border },
    }, .{});
    errdefer cx.freeNode(wrapper);
    wrapper.meta.ownership.meta.test_id = "devtools.details.panel";
    _ = try core.adoptChild(cx, cx.allocator, wrapper, try buildTabBar(cx, state));
    var content_scroll = try ScrollArea(.{
        .padding = Padding.symmetric(4, 8),
        .background = t.tokens.color.bg_secondary,
    }).mount(state.scope.?, cx);
    _ = try core.adoptChild(cx, cx.allocator, wrapper, content_scroll.container);
    content_scroll.container.style.height = .{ .grow = .{} };
    content_scroll.container.style.width = .{ .grow = .{} };

    // Save content reference for on_before_render local rebuild
    state.details_content = content_scroll.content;
    content_scroll.content.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
    content_scroll.content.meta.per_frame.hooks.before_render.main = detailsBeforeRender;
    return wrapper;
}

/// Details panel on_before_render: detect dirty then local rebuild content
fn detailsBeforeRender(content_node: *Node) void {
    const state: *DevToolsState = @ptrCast(@alignCast(content_node.meta.per_frame.hooks.slots.anim_state orelse return));
    if (state.view_mode == .performance) return;
    if (!state.details_dirty) return;
    state.details_dirty = false;

    const cx = state.cx orelse return;
    const target = state.liveTarget() orelse return;
    const t = cx.tokens;

    // First clear interaction refs, ensure subtree blur/focus callbacks finish while scope live.
    for (content_node.children.items) |child| {
        cx.invalidateReferencesTo(child);
    }

    // Unwire old subtree's scope pointers, then dispose scope.
    // Subsequent freeNode(child) won't retrace freed scope.
    for (content_node.children.items) |child| {
        hooks.invalidateSubtreeHookState(child);
        core.clearNodeScopes(child);
    }
    if (state.details_scope) |ds| ds.dispose();
    state.details_scope = null;

    // Detach through the structural seam before freeing. Index from the live
    // list each time: cleanup may remove/reparent siblings.
    freePanelChildren(cx, content_node);

    // Reclaim frame arena: Trace/State tab event ctx (TracePauseCtx/TraceClickCtx etc.) allocated
    // here, only referenced by freed old subtree.
    // No reset: Trace tab + 60fps target ~1-2KB per rebuild grows, panel running hour = observable
    // leak.
    _ = state.arena.reset(.retain_capacity);

    // Create new scope
    state.details_scope = Scope.init(cx.allocator, state.scope, cx.owner) catch null;

    const selected_id = target.inspector.selected_node_id orelse target.inspector.hover_node_id;

    // Diagnostic: content_node rebuilt each frame from selected node, catch {} fail worst: "this
    // frame details page misses section", next frame self-heals; debugged app unaffected.
    if (state.active_tab == .trace) {
        buildTraceTab(cx, target, state, content_node) catch {};
    } else if (selected_id == null or target.root == null) {
        const no_sel = core.text(cx, "No selection", .{ .font_size = 11, .color = t.tokens.color.fg_secondary }) catch return;
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
            const not_found = core.text(cx, "Node not found", .{ .font_size = 11, .color = t.tokens.color.fg_secondary }) catch return;
            content_node.appendChild(cx.allocator, not_found) catch {};
        }
    }
    content_node.markLayoutDirty();
}

// ========== Panel header ==========

fn buildHeader(cx: *Cx, target: *Cx, opts: PanelOptions, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    const a = cx.allocator;
    const scope = state.scope.?;
    // header first, errdefer catches all; children adopted post-build (append fail self-frees).
    var header = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .width = .{ .grow = .{} },
        .height = .{ .px = 32 },
        .padding = Padding.symmetric(4, 10),
        .background = t.tokens.color.bg_secondary,
        .border = .{ .width = 1, .color = t.tokens.color.border },
    }, .{});
    errdefer cx.freeNode(header);
    header.meta.ownership.meta.test_id = "devtools.header.shell";
    const header_ext = try header.style.ensureExtFallible(cx.allocator);
    // Header fixed chrome, shouldn't pass scroll to tree/details ScrollArea below.
    header_ext.hit_roles = .{ .pointer = true, .scroll = true, .inspect = false };
    header_ext.hit_behavior = .@"opaque";

    // Left: pick button + title + view switch
    const left = try core.adoptChild(cx, a, header, try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 8,
    }, .{}));
    left.meta.ownership.meta.test_id = "devtools.header.left";

    // "Pick" button -> Button component + SVG icon
    {
        const is_pick_active = target.inspector.pick_mode;

        const pick_ctx = try allocScopeResource(scope, PickModeCtx);
        pick_ctx.* = .{ .state = state };

        const pick_btn = try core.adoptChild(cx, a, left, try Button(.{
            .icon_only = true,
            .icon_asset = svg_assets.common.scan,
            .variant = @as(button_mod.ButtonVariant, if (is_pick_active) .primary else .ghost),
            .size = .xs,
            .icon_size = 14,
            .on_event = pickModeEvent,
            .event_context = pick_ctx,
        }).mount(scope, cx));
        state.pick_btn_node = pick_btn;
    }

    _ = try core.adoptChild(cx, a, left, try core.text(cx, state.title, .{
        .font_size = 12,
        .color = t.tokens.color.fg_primary,
        .font_weight = 600,
    }));

    // View switch -> underline Tabs
    const mode_items = [_]TabItem{
        .{ .id = "elements", .label = "Elements" },
        .{ .id = "components", .label = "Components" },
        .{ .id = "console", .label = "Console" },
        .{ .id = "performance", .label = "Performance" },
    };
    const mode_tabs = try core.adoptChild(cx, a, left, try Tabs(.{
        .items = &mode_items,
        // Active page by signal: programmatic switch (syncViewModeTabs) just set
        .active = blk: {
            const sig = try scope.createSignal(?[]const u8, viewModeId(state.view_mode));
            state.view_mode_tab = sig;
            break :blk sig;
        },
        .variant = .underline,
        .size = .xs,
        .on_change = cx.on(DevToolsState, state, applyViewModeById),
    }).mount(scope, cx));
    mode_tabs.meta.ownership.meta.test_id = "devtools.view-mode.tabs";
    state.view_mode_tabs_node = mode_tabs;

    // Right: theme toggle + close
    const right = try core.adoptChild(cx, a, header, try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 4,
    }, .{}));
    right.meta.ownership.meta.test_id = "devtools.header.right";

    // Theme toggle: show icon for "clicking will switch to" side (dark mode shows sun)
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

    // Close button -> Button component
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
        // Show placeholder even without on_close handler
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

// ========== Search bar ==========

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

    // shell first, Input adopted post-build (fail: shell freed whole)
    const shell = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .padding = Padding.symmetric(6, 8),
        .background = t.tokens.color.bg_secondary,
        .overflow_hidden = true,
    }, .{});
    errdefer cx.freeNode(shell);
    const mounted_input = try Input(.{
        .placeholder = "Filter (tag, #id)...",
        .value = state.filter_buf[0..state.filter_len],
        .size = .sm,
        .leading_icon_asset = svg_assets.common.search,
        .on_change = cx.on(FilterChangeCtx, filter_ctx, filterInputChanged),
    }).mountResult(scope, cx);
    const input_node = try core.adoptChild(cx, cx.allocator, shell, mounted_input.node);
    input_node.style.width = .{ .grow = .{} };
    input_node.meta.ownership.meta.test_id = "devtools.search.input";
    mounted_input.input_container.meta.ownership.meta.test_id = "devtools.search.input.control";
    shell.meta.ownership.meta.test_id = "devtools.search.shell";
    shell.setInteractionDelegate(mounted_input.input_container);
    const shell_ext = try shell.style.ensureExtFallible(cx.allocator);
    // Search region also fixed chrome; Input padding avoids hugging header/tree boundary seam.
    shell_ext.hit_roles = .{ .pointer = true, .scroll = true, .inspect = false };
    shell_ext.hit_behavior = .@"opaque";
    return shell;
}

/// Quick estimate subtree node count (upper-clamped, avoid deep recursion)
fn countSubtreeNodes(node: *Node, limit: u32) u32 {
    var count: u32 = 1;
    for (node.children.items) |child| {
        count += countSubtreeNodes(child, limit);
        if (count >= limit) return limit;
    }
    return count;
}

/// Collapse subtree by default if child count exceeds this threshold (unless user manually expand)
const auto_collapse_threshold: usize = 500;
/// Tree max render rows limit, prevent hang
const max_visible_rows: u32 = 2000;
const tree_row_height: f32 = 20;
const tree_reveal_margin_top: f32 = 8;
const tree_reveal_margin_bottom: f32 = 12;

// ========== Flat tree entries (VirtualList data source) ==========

const FlatTreeEntry = struct {
    node: *Node,
    depth: u32,
    has_children: bool,
    collapsed: bool,
};

/// Recursively flatten UI tree to index array (Elements view)
fn flattenTreeElements(state: *DevToolsState, node: *Node, depth: u32, filter: []const u8) void {
    if (state.flat_rows.items.len >= max_visible_rows) return;

    if (!node.frame_state.state_bits.flags.inspectable) {
        for (node.children.items) |child| {
            flattenTreeElements(state, child, depth, filter);
            if (state.flat_rows.items.len >= max_visible_rows) return;
        }
        return;
    }

    // Filter check
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
    // No collapse when filter: reaching here = self match or descendant match, collapse hides
    // searched line, search fails.
    const collapsed = if (filter.len > 0) false else (state.isCollapsed(node.id) or auto_collapsed);

    // Diagnostic: flat_rows is elements tree panel display buffer, clear then full rebuild each
    // rebuildFlatRows. append fail = tree misses line this frame, next rebuild heals.
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

/// Recursively flatten UI tree (Components view)
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

        // Diagnostic: like flattenTreeElements, per-frame rebuild display buffer.
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

/// Check subtree has any component children
fn hasComponentChildren(node: *Node) bool {
    for (node.children.items) |child| {
        if (child.meta.ownership.meta.component_name != null) return true;
        if (hasComponentChildren(child)) return true;
    }
    return false;
}

/// Find first text content in node subtree
fn findFirstText(node: *Node) ?[]const u8 {
    if (node.getText()) |t| {
        if (t.content.len > 0) return t.content;
    }
    for (node.children.items) |child| {
        if (findFirstText(child)) |txt| return txt;
    }
    return null;
}

/// Components view filter match
fn componentMatchesFilter(node: *Node, filter: []const u8) bool {
    if (filter.len == 0) return true;

    // #id filter
    if (filter[0] == '#') {
        if (filter.len > 1) {
            const id_num = std.fmt.parseInt(u32, filter[1..], 10) catch return false;
            return node.id == id_num;
        }
        return false;
    }

    // component_name match
    if (node.meta.ownership.meta.component_name) |name| {
        if (containsIgnoreCase(name, filter)) return true;
    }

    // Text content match
    const txt = findFirstText(node);
    if (txt) |t| {
        if (containsIgnoreCase(t, filter)) return true;
    }

    return false;
}

/// Subtree has filter-matching component
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
        // Dark mode brighter value, light mode darker for white bg readability
        .box => if (is_dark) Color.hex(0x5a9fd4) else Color.hex(0x2E6FA0),
        .text => if (is_dark) Color.hex(0x7a9a70) else Color.hex(0x4A6F40),
        .image => if (is_dark) Color.hex(0x5aa0a0) else Color.hex(0x3A7575),
        .button => if (is_dark) Color.hex(0xc0a060) else Color.hex(0x8A7030),
        .input => if (is_dark) Color.hex(0xb080c0) else Color.hex(0x7A5090),
        .scroll => if (is_dark) Color.hex(0x80b0c0) else Color.hex(0x507888),
        .list => if (is_dark) Color.hex(0xa0a0c0) else Color.hex(0x606088),
        .spacer, .anchor => if (is_dark) Color.hex(0x505050) else Color.hex(0xAAAAAA),
        .custom => if (is_dark) Color.hex(0xd08050) else Color.hex(0x9A5530),
    };
}

// ========== Details panel ==========

fn buildTabBar(cx: *Cx, state: *DevToolsState) !*Node {
    const t = cx.tokens;
    const tab_items = [_]TabItem{
        .{ .id = "layout", .label = "Layout" },
        .{ .id = "style", .label = "Style" },
        .{ .id = "state", .label = "State" },
        .{ .id = "events", .label = "Events" },
        .{ .id = "render", .label = "Render" },
        .{ .id = "trace", .label = "Trace" },
    };
    // shell first, Tabs adopted post-build, prev Tabs first + shell box fail orphaned tabs in tuple
    // (sweep last 3 sites). stable then publish.
    const shell = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .width = .{ .grow = .{} },
        .background = t.tokens.color.bg_secondary,
        .overflow_hidden = true,
    }, .{});
    errdefer cx.freeNode(shell);
    const tabs = try core.adoptChild(cx, cx.allocator, shell, try Tabs(.{
        .items = &tab_items,
        .active = blk: {
            const sig = try state.scope.?.createSignal(?[]const u8, state.active_tab.idStr());
            state.details_tab = sig;
            break :blk sig;
        },
        .variant = .underline,
        .size = .xs,
        .on_change = cx.on(DevToolsState, state, onDetailsTabChange),
    }).mount(state.scope.?, cx));
    tabs.style.width = .{ .grow = .{} };
    tabs.style.height = .{ .fit = .{} };
    // Programmatic tab switch (setActiveTab) needs sync underline to component (see
    // syncDetailsTabs), view-mode tabs have matching sync, round it out here.
    state.details_tabs_node = tabs;
    shell.meta.ownership.meta.test_id = "devtools.details.tabs";
    const shell_ext = try shell.style.ensureExtFallible(cx.allocator);
    // Details tabs top-bar doesn't pass scroll to details scroll area below.
    shell_ext.hit_roles = .{ .pointer = true, .scroll = true, .inspect = false };
    shell_ext.hit_behavior = .@"opaque";
    return shell;
}

// ========== Layout Tab ==========

fn buildLayoutTab(cx: *Cx, state: *DevToolsState, node: *Node, parent: *Node) !void {
    const rect = computeRenderRect(node);

    // Section: Basic info
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

    // Box Model visualization
    try box_model.build(cx, node, parent);

    // Section: Position / Size
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

    // Section: Flexbox (numeric properties clickable edit)
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

    // Transform (editable)
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
        .color = cx.tokens.tokens.color.fg_secondary,
    }));

    const btn = try Button(.{
        .label = if (node.frame_state.state_bits.flags.inspect_pick_disabled) "Allow pick" else "Exclude from pick",
        .variant = @as(button_mod.ButtonVariant, if (node.frame_state.state_bits.flags.inspect_pick_disabled) .secondary else .ghost),
        .size = .xs,
        .on_event = inspectPickToggleEvent,
        .event_context = ctx,
        .base_style = .{ .border = .{ .width = 1, .color = cx.tokens.tokens.color.border, .radius = 3 } },
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

    // Opacity (editable)
    try editableKvRow(cx, state, node, .opacity, parent);

    // Border (editable numbers)
    try parent.appendChild(cx.allocator, try sectionTitle(cx, "Border"));
    try editableKvRow(cx, state, node, .border_width, parent);
    try parent.appendChild(cx.allocator, try styleColorRow(cx, state, node, .border, "color", node.style.border.color));
    try editableKvRow(cx, state, node, .border_radius, parent);

    // Corner Radius (advanced)
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
    // Diagnostic: both are frame arena temp collection tables, only display State panel rows. lose
    // one = show one fewer state entry, no debugged app impact.
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

    // Title + copy
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
        .color = t.tokens.color.accent,
        .font_weight = 600,
    });
    title_node.meta.ownership.meta.test_id = "devtools.state.subject";
    try state_head.appendChild(cx.allocator, title_node);

    var all_buf: [12288]u8 = undefined;
    var all_writer = std.Io.Writer.fixed(&all_buf);
    const all_w = &all_writer;

    // Diagnostic: all_w is 12KB **fixed stack buffer** writer, catch {} swallows NoSpaceLeft not
    // OOM. Too long "copy all state" text truncates display, exactly wanted fallback (not crash
    // panel). Print/writeAll below same.
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
        .base_style = .{ .border = .{ .width = 1, .color = t.tokens.color.accent, .radius = 3 } },
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
    const s = devtools_styles.palette(t);
    const row = try cx.createNode(.box, .{
        .direction = .row,
        .gap = 8,
        .align_items = .center,
        .height = .{ .px = 18 },
    });
    try row.appendChild(cx.allocator, try core.text(cx, name, .{
        .font_size = 10,
        .color = s.event_name,
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
            .layout_triggered, .sizing_triggered => t.tokens.color.warning,
            .explicit, .mount => t.tokens.color.accent,
            .transition_tick => devtoolsMuted(t),
            else => t.tokens.color.fg_primary,
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

    // Top bar: Pause/Resume + Clear buttons
    const toolbar = try core.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .height = .{ .px = 22 },
        .padding = Padding.symmetric(2, 4),
    }, .{});

    const store = target.inspector.trace_store;

    // Pause/Resume button -> Button component
    {
        const is_paused = if (store) |s| s.paused else false;
        const pause_ctx = try state.frameAlloc().create(TracePauseCtx);
        pause_ctx.* = .{ .state = state };
        const details_scope = state.details_scope orelse state.scope.?;
        const pause_btn = try Button(.{
            .label = if (is_paused) "Resume" else "Pause",
            .variant = @as(button_mod.ButtonVariant, if (is_paused) .secondary else .ghost),
            .size = .xs,
            .on_event = tracePauseEvent,
            .event_context = pause_ctx,
        }).mount(details_scope, cx);
        try toolbar.appendChild(cx.allocator, pause_btn);
    }

    // Clear button -> Button component
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

    // Event list
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

        // phase color: capture=gray, target=blue, bubble=green
        const phase_color = switch (rec.phase) {
            .capture => devtoolsMuted(t),
            .target => t.tokens.color.accent,
            .bubble => t.tokens.color.success,
        };

        // result color correct: stop=red
        const line_color = if (rec.result == .stop) t.tokens.color.danger else phase_color;

        // Highlight selected-node related rows
        const is_related = selected_id != null and
            (rec.target_node_id == selected_id.? or rec.handler_node_id == selected_id.?);

        const row = try core.box(cx, .{
            .direction = .row,
            .align_items = .center,
            .height = .{ .px = 16 },
            .padding = Padding.symmetric(0, 4),
            .background = if (is_related) t.tokens.color.bg_hover else Color.TRANSPARENT,
        }, .{
            try core.text(cx, line, .{ .font_size = 10, .color = line_color }),
        });
        // row post-build frameAlloc().create may still fail, gate errdefer guards window, adopt
        // hooks.
        var row_owned = true;
        errdefer if (row_owned) cx.freeNode(row);

        // Click jump to handler node
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

/// Trace toolbar button click in DevTools window, doesn't advance target frame_count, but Trace
/// content rebuilds only on target frame (not here explicit dirty), Pause text won't flip, Clear
/// leaves list residue, waits target chance frame.
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

// ========== UI helper functions ==========

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
            .color = t.tokens.color.accent,
            .font_weight = 600,
        }),
    });
}

fn stateRow(cx: *Cx, state: *DevToolsState, scoped: ScopedStateEntry) !*Node {
    const t = cx.tokens;
    const s = devtools_styles.palette(t);
    const details_scope = state.details_scope orelse state.scope.?;
    var row = try cx.createNode(.box, .{
        .direction = .column,
        .gap = 2,
        .height = .{ .fit = .{} },
        .padding = Padding{ .top = 4, .bottom = 4, .left = 6, .right = 6 },
        .width = .{ .grow = .{} },
        .border = .{ .radius = 4, .width = 1, .color = t.tokens.color.border },
    });
    cx.linkNodeToWorld(row);
    row.setBackgroundRaw(s.state_card_bg);

    // ID + type name same line
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
        .color = t.tokens.color.fg_primary,
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
        .base_style = .{ .border = .{ .width = 1, .color = t.tokens.color.accent, .radius = 3 } },
    }).mount(details_scope, cx);
    copy_btn.behavior.events.on_click = core.Cx.simpleHandler(copyStateClick, @ptrCast(copy_ctx_ptr));
    try head_row.appendChild(cx.allocator, copy_btn);

    try row.appendChild(cx.allocator, head_row);

    const wrap_cols: usize = 82;
    var it = std.mem.splitScalar(u8, pretty, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var start: usize = 0;
        while (start < trimmed.len) {
            const end = @min(start + wrap_cols, trimmed.len);
            const seg = trimmed[start..end];
            try row.appendChild(cx.allocator, try core.text(cx, scopeOwnedText(details_scope, seg), .{
                .font_size = 10,
                .color = t.tokens.color.fg_secondary,
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

/// Diagnostic: this function + appendUniqueSignal both append frame arena dedup collection for
/// State panel list. fail = show one fewer state/signal, no debugged app impact.
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

/// Diagnostic: pretty-print state raw value into multi-line indented text, write into caller
/// **fixed** buffer `out`.
/// All catch {} inside swallow NoSpaceLeft: buffer full stop, return written part, panel shows
/// truncated value, exactly wanted fallback.
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

/// Diagnostic: only write indent spaces for prettyStateValueInto, fixed buffer writer, swallow
/// NoSpaceLeft, buffer full skip indent, show truncated OK.
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

    // Label
    try row.appendChild(cx.allocator, try core.text(cx, label, .{
        .font_size = 10,
        .color = t.tokens.color.fg_secondary,
    }));

    // Color swatch preview
    const swatch = try cx.createNode(.box, .{
        .width = .{ .px = 12 },
        .height = .{ .px = 12 },
        .border = .{ .radius = 2, .width = 1, .color = t.tokens.color.border },
    });
    cx.linkNodeToWorld(swatch);
    swatch.setBackgroundRaw(color);
    try row.appendChild(cx.allocator, swatch);

    // RGBA value
    var color_buf: [32]u8 = undefined;
    const color_str = if (color.a == 255)
        std.fmt.bufPrint(&color_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b }) catch ""
    else
        std.fmt.bufPrint(&color_buf, "rgba({d},{d},{d},{d})", .{ color.r, color.g, color.b, color.a }) catch "";
    try row.appendChild(cx.allocator, try inlineText(cx, color_str, t.tokens.color.fg_primary, 10));

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
        .color = t.tokens.color.fg_secondary,
    }));
    try row.appendChild(cx.allocator, try inlineText(cx, value, t.tokens.color.fg_primary, 10));
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

// ========== Search / filter ==========

fn nodeMatchesFilter(node: *Node, filter: []const u8) bool {
    if (filter.len == 0) return true;

    // #id filter
    if (filter[0] == '#') {
        if (filter.len > 1) {
            const id_num = std.fmt.parseInt(u32, filter[1..], 10) catch return false;
            return node.id == id_num;
        }
        return false;
    }

    // tag name match
    const tag_name = @tagName(node.tag);
    if (containsIgnoreCase(tag_name, filter)) return true;

    // component_name match
    if (node.meta.ownership.meta.component_name) |name| {
        if (containsIgnoreCase(name, filter)) return true;
    }

    // text content match
    if (node.getText()) |t| {
        if (t.content.len > 0 and containsIgnoreCase(t.content, filter)) return true;
    }

    return false;
}

fn subtreeMatchesFilter(node: *Node, filter: []const u8, depth: u32) bool {
    // Limit search depth, avoid deep recursion in large subtree
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

// ========== Tree stats ==========

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

// ========== Node selection sync (retain mode) ==========

/// Retain mode: detect selected_node_id change, expand ancestors mark tree_dirty + scroll pending
fn syncTreeSelection(state: *DevToolsState, target: *Cx) void {
    const selected = target.inspector.selected_node_id;
    if (state.last_target_selected_id == selected) return;
    state.last_target_selected_id = selected;
    clearEditingState(state);

    if (state.view_mode == .performance) return;

    state.tree_auto_scroll_pending = false;
    state.tree_auto_scroll_id = null;

    const selected_id = selected orelse return;

    // Expand ancestor chain (ensure selected visible in flat_rows)
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

/// Retain mode: after rebuildFlatRows, find target row scroll VirtualList
fn applyTreeAutoScroll(state: *DevToolsState) void {
    if (!state.tree_auto_scroll_pending) return;
    const target_id = state.tree_auto_scroll_id orelse {
        state.tree_auto_scroll_pending = false;
        return;
    };

    // Find target node row index in flat_rows
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

/// Diagnostic: mark selected node ancestors "expand" so visible in tree.
/// put fail = one level didn't auto-expand, user manual click works, pure UX.
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

// ========== Behavior / state ==========

// ========== Splitter vertical divider ==========

const SPLITTER_HIT_WIDTH: f32 = 6;
const SPLITTER_GUIDE_THICKNESS: f32 = 2;
const SPLITTER_GUIDE_FADE_LEN: f32 = 20;
const MIN_LEFT_PANEL: f32 = 200;
const MAX_LEFT_PANEL: f32 = 600;

fn mountDevtoolsSplitter(cx: *Cx, state: *DevToolsState) !*Node {
    const allocator = cx.allocator;
    const t = cx.tokens;
    const guide_color = t.tokens.color.accent;
    const guide_transparent = Color.rgba(guide_color.r, guide_color.g, guide_color.b, 0);

    // Hotzone
    const splitter = try core.box(cx, .{
        .width = .{ .px = SPLITTER_HIT_WIDTH },
        .height = .{ .grow = .{} },
        .align_items = .center,
        .justify = .center,
        .cursor = .ew_resize,
    }, .{});
    splitter.style.cursor = .ew_resize;
    // Until child nodes are built, splitter must be guarded; state pointer published only after
    // assembly completes
    errdefer cx.freeNode(splitter);

    // Visual line (top gradient + solid line + bottom gradient) with guarded adoption:
    // each child adopted into line immediately after creation; line mounted to splitter before
    // state is published.
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

    // Bind event handlers
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
                // Policy: DevTools must not kill the debugged app.
                // Dragging splitter without ew_resize cursor is visual regression only.
                // splitter_dragging state unaffected.
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
                // the inspector over, the button simply appears to do nothing.
                source_link.open(alloc, cx.io, l) catch {};
            }
            return .stop;
        },
    }
}

fn onDetailsTabChange(state: *DevToolsState, tab_id: []const u8) void {
    const tab: ?DetailsTab = inline for (@import("zenit_reflection").fields(DetailsTab)) |f| {
        if (std.mem.eql(u8, tab_id, f.name)) break @fromBackingInt(@intCast(f.value));
    } else null;
    if (tab) |t| {
        state.active_tab = t;
        // Exit Style tab edit mode: one of two edit exit points (other is selection change).
        clearEditingState(state);
        state.details_dirty = true;
        syncDetailsTabs(state);
        if (state.cx) |c| c.needs_redraw = true;
    }
}

/// Sync state.active_tab back to details Tabs component (underline position).
/// User clicks update component (no-op); programmatic setActiveTab depends on this.
fn syncDetailsTabs(state: *DevToolsState) void {
    if (state.details_tab) |sig| sig.set(state.active_tab.idStr());
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
        // Pick mode requires enabled to render overlay and handle hover/click
        target.inspector.enabled = true;
    } else {
        target.inspector.hover_node_id = null;
        // Highlight drawn in target window; force target redraw to clear last hover highlight on
        // pick exit.
        target.needs_redraw = true;
    }
    return .handled;
}

fn applyViewModeById(state: *DevToolsState, mode_id: []const u8) void {
    const mode: ?ViewMode = inline for (@import("zenit_reflection").fields(ViewMode)) |f| {
        if (std.mem.eql(u8, mode_id, f.name)) break @fromBackingInt(@intCast(f.value));
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

fn syncViewModeTabs(state: *DevToolsState) void {
    if (state.view_mode_tab) |sig| sig.set(viewModeId(state.view_mode));
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

// ========== DevTools persistent state ==========

const DevToolsState = struct {
    initialized: bool = false,
    allocator: std.mem.Allocator = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    collapsed: std.AutoHashMap(u32, bool) = undefined,
    /// User-expanded nodes (large subtrees collapsed by default, recorded here when expanded)
    explicitly_expanded: std.AutoHashMap(u32, bool) = undefined,
    /// Panel content scope: owns all components/resources under root.
    /// Disposed when theme toggles for full rebuild; root node (Cx.root) and hooks unchanged.
    scope: ?*Scope = null,
    /// Cx.root_scope (see ensureInit). Root node bound to it.
    root_scope: ?*Scope = null,
    /// Title shown in panel header, supplied by PanelOptions. Borrowed.
    title: []const u8 = "DevTools",
    /// Original mountPanel options; reused when header rebuilt on theme change.
    panel_opts: PanelOptions = .{},
    /// Header theme toggle clicked; devtoolsBeforeRender switches theme and rebuilds panel at safe
    /// point.
    theme_toggle_pending: bool = false,

    // View mode
    view_mode: ViewMode = .elements,

    // Tab
    active_tab: DetailsTab = .layout,

    // Style real-time edit state
    editing_field: ?EditableField = null,
    editing_node_id: ?u32 = null,

    // Left/right split: left panel width + splitter drag state
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

    /// Goto-source button click context. Single hover row per panel; reused instance to avoid
    /// accumulation.
    goto_ctx: RowCtx = undefined,

    // VirtualList data source: flattened tree rows (persistent allocator)
    flat_rows: std.ArrayList(FlatTreeEntry) = .empty,

    // === Retained-mode fields ===
    target_cx: ?*Cx = null,
    target_lifetime: ?*Cx.LifetimeToken = null,
    cx: ?*Cx = null,
    last_seen_target_frame_count: u64 = 0,
    /// Previous frame mouse hover tree row slot. Row content rebuilt only when tree_dirty; hover
    /// changes render (goto button).
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
    /// Per-log-level toggle states of the Console filter buttons (button appearance is derived from
    /// them); released with the scope on panel rebuild.
    console_level_enabled: [5]?*Signal(bool) = @splat(null),
    // Performance panel retained node reference
    perf_fps_text: ?*Node = null,
    perf_bar_container: ?*Node = null,
    perf_bars: [perf_chart_sample_count]?*Node = @splat(null),
    perf_target_text: ?*Node = null,
    perf_timing_text: ?*Node = null,
    perf_summary_text: ?*Node = null,
    perf_interaction_text: ?*Node = null,
    perf_cache_text: ?*Node = null,
    perf_mounted: bool = false,
    /// Frame count seen in perfBeforeRender (idle detection only; distinct from
    /// last_seen_target_frame_count for time-since-change detection).
    perf_seen_frame_count: u64 = 0,
    perf_last_frame_change: ?@import("zenit_time").Instant = null,
    /// Time buckets for scroll monitoring (100ms/bucket, 64 buckets ~= 6.4s window).
    /// Advances by wall clock while target idles; values: <0 = unfilled, 0 = idle, >0 = avg FPS.
    perf_live_fps: [perf_chart_sample_count]f32 = @splat(-1.0),
    /// Next bucket to write (ring cursor; render reads forward = oldest->newest)
    perf_live_head: usize = 0,
    perf_bucket_start: ?@import("zenit_time").Instant = null,
    perf_bucket_frames: u64 = 0,
    // Componentized Header reference
    pick_btn_node: ?*Node = null,
    view_mode_tabs_node: ?*Node = null,
    /// View-mode Tabs active page signal (set for programmatic switch)
    view_mode_tab: ?*Signal(?[]const u8) = null,
    // Details tab bar reference (programmatic setActiveTab syncs underline)
    details_tabs_node: ?*Node = null,
    details_tab: ?*Signal(?[]const u8) = null,
    // Details area component scope (dispose + rebuild each time)
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

    /// when mountPanel fails entire root tree recycled, but nodes/child states pointers written
    /// during child mount
    /// (vl_state / details_content / perf_* / console_* / stats_* / splitter_*) dangle,
    /// same Cx re-mountPanel or event handler (event_context = state) reading them is UAF.
    /// clear all failure paths (cross-review P1/P2). scope / target / cx don't belong to this
    /// batch, preserve.
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
        self.console_level_enabled = @splat(null);
        self.perf_fps_text = null;
        self.perf_bar_container = null;
        self.perf_bars = @splat(null);
        self.perf_target_text = null;
        self.perf_timing_text = null;
        self.perf_summary_text = null;
        self.perf_interaction_text = null;
        self.perf_cache_text = null;
        self.perf_mounted = false;
        self.pick_btn_node = null;
        self.view_mode_tabs_node = null;
        self.view_mode_tab = null;
        self.details_tabs_node = null;
        self.details_tab = null;
    }

    pub fn deinit(self: *DevToolsState) void {
        if (!self.initialized) return;
        // Note: do not dispose scope/details_scope here.
        // DevTools scope registered as Cx.root_scope; Cx.deinit unmounts and disposes before
        // freeing nodes.
        // This clears only DevToolsState containers, not scopes.
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

    /// Whether user manually expanded
    fn isExplicitlyExpanded(self: *DevToolsState, id: u32) bool {
        return self.explicitly_expanded.get(id) != null;
    }

    /// is_currently_collapsed: whether node displays as collapsed in UI (includes auto-collapse).
    /// Collapse/expand are display preference only. Put failure = this click not recorded; next
    /// frame follows default; no correctness impact.
    fn toggle(self: *DevToolsState, id: u32, is_currently_collapsed: bool) void {
        if (is_currently_collapsed) {
            // Current collapsed -> expand
            _ = self.collapsed.remove(id);
            _ = self.explicitly_expanded.put(id, true) catch {};
        } else {
            // Current expanded -> collapse
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
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const state = try getState(cx);
    try std.testing.expect(state.scope != null);
    try std.testing.expect(cx.root_scope != null);
    try std.testing.expect(state.scope.? == cx.root_scope.?);
}

test "DevTools stops observing a target Cx that has been destroyed" {
    var target = try Cx.init(std.testing.allocator, std.testing.io);
    target.root = try core.box(target, .{}, .{});

    var dev = try Cx.init(std.testing.allocator, std.testing.io);
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
    var target = try Cx.init(std.testing.allocator, std.testing.io);
    defer target.deinit();
    target.root = try core.box(target, .{}, .{});

    var dev = try Cx.init(std.testing.allocator, std.testing.io);
    defer dev.deinit();
    dev.setTheme(&theme.light);
    const panel = try mountPanel(dev, target, .{});
    dev.root = panel;

    const state = try getState(dev);
    const old_header = state.pick_btn_node.?;
    const child_count = panel.children.items.len;
    try std.testing.expect(state.scope.? != state.root_scope.?);

    // Toggle only sets flag; do not mutate tree in event callback.
    try std.testing.expectEqual(EventResult.handled, themeToggleEvent(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left } }, state));
    try std.testing.expect(dev.tokens == &theme.light);

    devtoolsBeforeRender(panel);
    try std.testing.expect(dev.tokens == &theme.dark);
    try std.testing.expect(!state.theme_toggle_pending);
    try std.testing.expectEqual(child_count, panel.children.items.len);
    try std.testing.expect(state.pick_btn_node != null and state.pick_btn_node.? != old_header);
    try std.testing.expectEqual(theme.dark.tokens.color.bg_primary, panel.getBackground());

    state.theme_toggle_pending = true;
    devtoolsBeforeRender(panel);
    try std.testing.expect(dev.tokens == &theme.light);
    try std.testing.expectEqual(child_count, panel.children.items.len);
}

// Kept beside the private rebuild hooks so the regression reaches the real
// event, details and partial-panel failure paths rather than a synthetic tree.
test "renderer host DevTools theme details rows and failed panel rebuilds" {
    const a = std.testing.allocator;
    var host: @import("core/recording_host.zig").RecordingHost = undefined;
    host.init(a);
    defer host.deinit();
    const target = try Cx.init(a, std.testing.io);
    defer target.deinit();
    target.root = try core.box(target, .{}, .{});

    var failing = std.testing.FailingAllocator.init(a, .{});
    const dev = try Cx.init(failing.allocator(), std.testing.io);
    defer dev.deinit();
    const panel = try mountPanel(dev, target, .{});
    dev.root = panel;
    const state = try getState(dev);
    try host.expectForest(&.{ target.root.?, panel });

    target.inspector.selected_node_id = target.root.?.id;
    for (0..2) |_| {
        state.details_dirty = true;
        detailsBeforeRender(state.details_content.?);
        try host.expectForest(&.{ target.root.?, panel });
    }
    // Reuse a virtual tree row that already owns children.
    const row = try core.box(dev, .{}, .{});
    for (0..2) |_| {
        renderTreeRowRetained(row, 0, dev, state);
        try host.expectForest(&.{ target.root.?, panel, row });
    }
    dev.freeNode(row);

    _ = themeToggleEvent(.{ .mouse_down = .{ .x = 0, .y = 0, .button = .left } }, state);
    devtoolsBeforeRender(panel);
    try host.expectForest(&.{ target.root.?, panel });

    // Offset zero fails the new scope; later offsets fail after panel assembly
    // has started. Recovery also exercises repeated owner subtree replacement.
    var partial_failures: usize = 0;
    for ([_]usize{ 0, 8, 32 }) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        state.theme_toggle_pending = true;
        devtoolsBeforeRender(panel);
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try std.testing.expect(induced);
        try std.testing.expectEqual(@as(usize, 0), panel.children.items.len);
        if (state.scope != null) partial_failures += 1;
        try host.expectForest(&.{ target.root.?, panel });
        state.theme_toggle_pending = true;
        devtoolsBeforeRender(panel);
        try std.testing.expect(panel.children.items.len > 0);
        try host.expectForest(&.{ target.root.?, panel });
    }
    try std.testing.expect(partial_failures > 0);
}

test "DevTools titlebar_safe_top = 0 drops the titlebar spacer for hosts with their own header" {
    var target = try Cx.init(std.testing.allocator, std.testing.io);
    defer target.deinit();
    target.root = try core.box(target, .{}, .{});

    var with_spacer = try Cx.init(std.testing.allocator, std.testing.io);
    defer with_spacer.deinit();
    const a = try mountPanel(with_spacer, target, .{});
    with_spacer.root = a;

    var without = try Cx.init(std.testing.allocator, std.testing.io);
    defer without.deinit();
    const b = try mountPanel(without, target, .{ .titlebar_safe_top = 0 });
    without.root = b;

    try std.testing.expectEqual(a.children.items.len - 1, b.children.items.len);
    try std.testing.expectEqual(@as(f32, 28), a.children.items[0].style.height.px);
    try std.testing.expect(b.children.items[0].style.height != .px or b.children.items[0].style.height.px != 28);
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
    var target = try Cx.init(std.testing.allocator, std.testing.io);
    defer target.deinit();
    const inspected = try core.box(target, .{ .background = Color.BLACK }, .{});
    target.root = inspected;

    var dev = try Cx.init(std.testing.allocator, std.testing.io);
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

    // Gap not declared in this BoxStyle; cannot use background base.
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
    var target = try Cx.init(std.testing.allocator, std.testing.io);
    defer target.deinit();
    target.console().configure(.{ .terminal_level = null, .max_entries = 2_000 });
    target.root = try core.box(target, .{ .width = .{ .px = 320 }, .height = .{ .px = 200 } }, .{});

    // More than one mirror page proves that a quiet target cannot strand the
    // second page after DevTools acknowledges the first revision.
    for (0..1_500) |i| target.console().debug("history-{d}", .{i});
    target.console().writeAt(.err, @src(), "needle-error", .{});

    var dev = try Cx.init(std.testing.allocator, std.testing.io);
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

/// Current FPS: average of last ~1s (10 buckets) filled buckets. Buckets advance by wall clock;
/// target idle drops to 0.
fn liveCurrentFps(state: *const DevToolsState) u32 {
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
    if (n_buckets == 0) return 0;
    return @intFromFloat(@min(@as(f32, 999), @round(sum / @as(f32, @floatFromInt(n_buckets)))));
}

/// Performance panel scroll monitor current FPS (same source as panel FPS row). Real window probe
/// asserts "scroll advances after frame pause; FPS drops to 0".
pub fn perfCurrentFps(cx: *Cx) ?u32 {
    const state = getState(cx) catch return null;
    return liveCurrentFps(state);
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

// Full DevTools panel mount allocation-point OOM sweep (per-case GPA check leak; induced > 0
// prevents empty-spin).
// mountPanel needs target Cx; MountFn(scope, cx) form insufficient; custom here.
test "mountPanel 在任意分配点失败时不泄漏" {
    const t = std.testing;
    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const target = try Cx.init(t.allocator, std.testing.io);
        defer target.deinit();
        target.root = try core.box(target, .{}, .{});
        const dev = try Cx.init(counting.allocator(), std.testing.io);
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
        var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
        {
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const target = try Cx.init(t.allocator, std.testing.io);
            defer target.deinit();
            target.root = try core.box(target, .{}, .{});
            const dev = Cx.init(failing.allocator(), std.testing.io) catch {
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
                // State cannot hold dangling pointers to freed nodes after failure.
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
    // Empty-spin guard by ratio not absolute minimum (same meter as oom_sweep.zig): induced > 0
    // threshold lower than measured by three orders of magnitude; cannot block mount early-return
    // collapse.
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

/// Stable-address requested allocation ledger for opt-in subsystem diagnostics.
pub const CountingAllocator = @import("core/counting_allocator.zig").CountingAllocator;

pub const intrinsicCacheMemoryStats = @import("core/layout_engine.zig").intrinsicCacheMemoryStats;
