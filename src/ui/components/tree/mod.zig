/// Tree Component
///
/// 树形控件，用于文件浏览器、目录结构等
///
/// 特性:
/// - 可展开/折叠
/// - 缩进显示层级
/// - 键盘导航 (ArrowRight 展开, ArrowLeft 折叠, ArrowUp/Down 上下)
/// - 可选择
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const KeyCode = events.KeyCode;
const Modifiers = events.Modifiers;
const svg_assets = @import("../../svg_assets.zig");
const selection_mod = @import("../selection.zig");
pub const SelectionMode = selection_mod.SelectionMode;

/// 树节点数据
pub const TreeNodeData = struct {
    id: []const u8,
    label_text: []const u8,
    children: []const TreeNodeData = &.{},
    disabled: bool = false,
};

/// Tree 属性
pub const TreeProps = struct {
    nodes: []const TreeNodeData = &.{},
    indent: f32 = 20,
    selectable: bool = true,
    /// 选中回调。用 `cx.strHandlerFrom(State, ptr, method)` 构造即可在回调里
    /// 拿到**被选中节点的 id**（此前是无 payload 的 HandlerRef，而 FlatNode
    /// 是私有的，应用根本无从知道选中了谁）。注册成无参 handler 也仍会被调用。
    on_select: ?core.HandlerRef = null,
    on_expand: ?core.HandlerRef = null,
    expand_icon_asset: ?svg_assets.Asset = null,
    /// 选择模式。默认 .single = 与加入多选之前的行为一致（非破坏性新增）。
    /// .multi 下 Cmd/Ctrl 点选切换、Shift 点选连续区间（按 flat_index）。
    selection_mode: selection_mod.SelectionMode = .single,
};

// ── 样式层在 styles.zig ──
const styles = @import("styles.zig");
const treeContainerStyle = styles.treeContainerStyle;
const treeRowStyle = styles.treeRowStyle;
const treeSelectionBg = styles.treeSelectionBg;
const treeIndicatorBoxStyle = styles.treeIndicatorBoxStyle;
const treeExpandIconStyle = styles.treeExpandIconStyle;
const treeIndicatorTextStyle = styles.treeIndicatorTextStyle;
const treeLabelBoxStyle = styles.treeLabelBoxStyle;
const treeLabelTextStyle = styles.treeLabelTextStyle;

/// Tree 内部状态
pub const TreeState = struct {
    expanded: [MAX_NODES]bool = [_]bool{false} ** MAX_NODES,
    selected_flat_index: ?usize = null,
    flat_nodes: [MAX_NODES]FlatNode = undefined,
    flat_node_rows: [MAX_NODES]?*Node = [_]?*Node{null} ** MAX_NODES,
    container: *Node,
    flat_count: usize = 0,
    on_select: ?core.HandlerRef,
    /// 选中行背景色 — mount 时从 treeSelectionBg 样式函数 resolve 得到
    selection_bg: Color,

    /// 多选位图。MAX_NODES 固定 128，所以内联即可，无需分配。
    selection_mode: selection_mod.SelectionMode = .single,
    selected_bits: [MAX_NODES / 64]u64 = [_]u64{0} ** (MAX_NODES / 64),
    selected_count: usize = 0,
    /// Shift 区间锚点
    selection_anchor: ?usize = null,

    const MAX_NODES = 128;

    const FlatNode = struct {
        data: *const TreeNodeData,
        depth: u16,
        flat_index: usize,
        has_children: bool,
    };

    /// 展开/折叠
    pub fn toggleExpand(self: *TreeState, flat_index: usize) void {
        if (flat_index >= self.flat_count) return;
        if (!self.flat_nodes[flat_index].has_children) return;
        self.expanded[flat_index] = !self.expanded[flat_index];

        // aria-expanded 必须跟着走，否则 AT 用户展开一个目录后仍被告知它是折叠的。
        if (self.flat_node_rows[flat_index]) |row| {
            if (row.behavior.interaction.a11y) |*a| a.expanded = self.expanded[flat_index];
        }

        // 更新子节点可见性
        self.updateVisibility();
    }

    /// 某个 flat_index 是否被选中
    pub fn isSelected(self: *const TreeState, flat_index: usize) bool {
        if (flat_index >= self.flat_count) return false;
        return (self.selected_bits[flat_index / 64] & (@as(u64, 1) << @intCast(flat_index % 64))) != 0;
    }

    fn setSelectedBit(self: *TreeState, flat_index: usize, on: bool) void {
        if (flat_index >= TreeState.MAX_NODES) return;
        const w = flat_index / 64;
        const mask = @as(u64, 1) << @intCast(flat_index % 64);
        const was = (self.selected_bits[w] & mask) != 0;
        if (on == was) return;
        if (on) {
            self.selected_bits[w] |= mask;
            self.selected_count += 1;
        } else {
            self.selected_bits[w] &= ~mask;
            self.selected_count -= 1;
        }
    }

    fn clearSelection(self: *TreeState) void {
        @memset(&self.selected_bits, 0);
        self.selected_count = 0;
    }

    /// 把选择态刷到行底色
    fn applySelectionStyles(self: *TreeState) void {
        var i: usize = 0;
        while (i < self.flat_count) : (i += 1) {
            const row = self.flat_node_rows[i] orelse continue;
            const sel = self.isSelected(i);
            row.setBackgroundRaw(if (sel)
                self.selection_bg
            else
                Color.TRANSPARENT);
            // 高亮是纯视觉的；aria-selected 才是 AT 唯一的选中依据。
            // 放在这个全行遍历里（而不是只改"旧/新选中"两行）——
            // 多选模式下一次操作可能改变任意多行的选中态。
            if (row.behavior.interaction.a11y) |*a| a.selected = sel;
            row.markRenderDirty();
        }
        if (self.container.behavior.interaction.a11y) |*a| {
            a.active_descendant_element_id = if (self.selected_flat_index) |selected|
                if (selected < self.flat_count and self.flat_node_rows[selected] != null)
                    self.flat_node_rows[selected].?.element_id_raw
                else
                    0xFFFFFFFF
            else
                0xFFFFFFFF;
        }
        self.container.markRenderDirty();
    }

    /// 把选中节点的 id 写进 out，返回个数
    pub fn selectedIds(self: *const TreeState, out: [][]const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.flat_count and n < out.len) : (i += 1) {
            if (self.isSelected(i)) {
                out[n] = self.flat_nodes[i].data.id;
                n += 1;
            }
        }
        return n;
    }

    /// 当前（主）选中节点的 id —— 回调里最常用的东西
    pub fn selectedId(self: *const TreeState) ?[]const u8 {
        const i = self.selected_flat_index orelse return null;
        if (i >= self.flat_count) return null;
        return self.flat_nodes[i].data.id;
    }

    /// 选中（无修饰键；语义与加入多选前一致）
    pub fn selectNode(self: *TreeState, flat_index: usize) void {
        self.selectNodeWithIntent(flat_index, .{});
    }

    /// 带修饰键意图的选中。
    /// single 模式忽略修饰键；multi 下 toggle=Cmd/Ctrl、range=Shift。
    pub fn selectNodeWithIntent(
        self: *TreeState,
        flat_index: usize,
        intent: selection_mod.ClickIntent,
    ) void {
        if (flat_index >= self.flat_count) return;

        if (self.selection_mode == .multi and intent.range) {
            const a = self.selection_anchor orelse flat_index;
            const lo = @min(a, flat_index);
            const hi = @max(a, flat_index);
            self.clearSelection();
            var i = lo;
            while (i <= hi) : (i += 1) self.setSelectedBit(i, true);
            if (self.selection_anchor == null) self.selection_anchor = flat_index;
        } else if (self.selection_mode == .multi and intent.toggle) {
            self.setSelectedBit(flat_index, !self.isSelected(flat_index));
            self.selection_anchor = flat_index;
        } else {
            self.clearSelection();
            self.setSelectedBit(flat_index, true);
            self.selection_anchor = flat_index;
        }

        self.selected_flat_index = flat_index;
        self.applySelectionStyles();

        // 并轨后的回调协议：带上被选中节点的 id，应用终于知道选中了谁。
        // 注册成无参 handler 时 invokeWithStr 会退化为无参调用，不丢事件。
        if (self.on_select) |handler| {
            handler.invokeWithStr(self.flat_nodes[flat_index].data.id);
        }
    }

    fn updateVisibility(self: *TreeState) void {
        // 根据 expanded 状态隐藏/显示行
        var i: usize = 0;
        while (i < self.flat_count) : (i += 1) {
            const row = self.flat_node_rows[i] orelse continue;
            const visible = self.isVisible(i);
            if (visible) {
                row.style.height = .{ .px = 28 };
            } else {
                row.style.height = .{ .px = 0 };
                row.style.overflow_hidden = true;
            }
            if (row.behavior.interaction.a11y) |*a| a.hidden = !visible;
            row.markLayoutDirty();
            row.markRenderDirty();
        }
    }

    fn isVisible(self: *TreeState, flat_index: usize) bool {
        if (flat_index == 0) return true; // 根层总可见
        const node = self.flat_nodes[flat_index];
        if (node.depth == 0) return true;

        // 检查所有祖先是否展开
        var check: usize = flat_index;
        while (check > 0) {
            check -= 1;
            if (self.flat_nodes[check].depth < node.depth) {
                // 找到父节点
                if (!self.expanded[check]) return false;
                if (self.flat_nodes[check].depth == 0) return true;
                // 继续向上检查
                const parent_depth = self.flat_nodes[check].depth;
                _ = parent_depth;
                return self.isVisible(check);
            }
        }
        return true;
    }
};

/// 创建 Tree
pub fn Tree(props: TreeProps) TreeBuilder {
    return TreeBuilder{ .props = props };
}

/// TreeBuilder.mount 的返回结果
pub const TreeResult = struct { wrapper: *Node, state: *TreeState };

pub const TreeBuilder = struct {
    props: TreeProps,

    pub fn nodes(self: TreeBuilder, n: []const TreeNodeData) TreeBuilder {
        var new = self;
        new.props.nodes = n;
        return new;
    }

    pub fn indent(self: TreeBuilder, i: f32) TreeBuilder {
        var new = self;
        new.props.indent = i;
        return new;
    }

    pub fn onSelect(self: TreeBuilder, handler_ref: core.HandlerRef) TreeBuilder {
        var new = self;
        new.props.on_select = handler_ref;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: TreeBuilder, scope: *Scope, cx: *Cx) !TreeResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const container = try box(cx, treeContainerStyle(t), .{});
        // sweep：container 守卫一直武装到 return；每行及行内子节点建好即 adopt
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Tree";
        try core.bindScopeToNode(my_scope, container);
        container.setFocusable(true);
        // 容器是 role=tree：AT 靠它把下面的行当成层级结构而不是一堆散行。
        container.behavior.interaction.a11y = .{
            .role = .tree,
            .multiselectable = p.selection_mode == .multi,
        };

        // State
        const state = try allocator.create(TreeState);
        state.* = .{
            .on_select = p.on_select,
            .selection_bg = treeSelectionBg(t),
            .selection_mode = p.selection_mode,
            .container = container,
        };
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const s: *TreeState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.cleanup);

        // 扁平化树节点
        for (p.nodes) |*node_data| {
            try flattenNode(state, node_data, 0);
        }

        // 渲染行
        for (state.flat_nodes[0..state.flat_count], 0..) |flat, i| {
            const indent_px = @as(f32, @floatFromInt(flat.depth)) * p.indent;

            const row = try core.adoptChild(cx, allocator, container, try box(cx, treeRowStyle(t), .{}));
            row.style.cursor = .pointer;
            // 每行 role=treeitem。expanded 只对有子节点的行有意义——叶子节点
            // 留 null，否则 AT 会把"可展开但已折叠"的假信息读给用户。
            row.behavior.interaction.a11y = .{
                .role = .treeitem,
                .label = flat.data.label_text,
                .disabled = flat.data.disabled,
                .expanded = if (flat.has_children) state.expanded[i] else null,
                .selected = (state.selected_flat_index == i),
                .hidden = flat.depth > 0,
                .level = flat.depth + 1,
                .row_index = @intCast(i),
            };

            // 缩进
            if (indent_px > 0) {
                _ = try core.adoptChild(cx, allocator, row, try box(cx, .{
                    .width = .{ .px = indent_px },
                    .height = .{ .px = 1 },
                }, .{}));
            }

            // 展开指示器
            if (flat.has_children and p.expand_icon_asset != null) {
                const ind_box = try core.adoptChild(cx, allocator, row, try box(cx, treeIndicatorBoxStyle(t), .{}));
                _ = try core.adoptChild(cx, allocator, ind_box, try core.iconTint(cx, p.expand_icon_asset.?, t.color.fg_secondary, treeExpandIconStyle(t)));
            } else {
                const indicator_text: []const u8 = if (flat.has_children) ">" else " ";
                const ind_wrapper = try core.adoptChild(cx, allocator, row, try box(cx, treeIndicatorBoxStyle(t), .{}));
                const indicator = try core.adoptChild(cx, allocator, ind_wrapper, try core.text(cx, indicator_text, .{}));
                if (indicator.getText()) |old| {
                    const ind_style = treeIndicatorTextStyle(t);
                    var txt = old;
                    txt.color = ind_style.color;
                    txt.font_size = ind_style.font_size;
                    indicator.setText(txt);
                }
            }

            // 标签
            const label = try core.adoptChild(cx, allocator, row, try box(cx, treeLabelBoxStyle(t), .{}));
            var label_txt = treeLabelTextStyle(flat.data.disabled, t);
            label_txt.content = flat.data.label_text;
            label.setText(label_txt);

            // 交互
            if (!flat.data.disabled) {
                const click_ctx = try allocator.create(TreeClickContext);
                click_ctx.* = .{ .state = state, .flat_index = i };
                try my_scope.adoptResource(@ptrCast(click_ctx), struct {
                    fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                        const c: *TreeClickContext = @ptrCast(@alignCast(ptr));
                        alloc.destroy(c);
                    }
                }.cleanup);
                row.behavior.events.on_event = treeItemEventHandler;
                row.behavior.events.event_context = @ptrCast(click_ctx);
            }

            state.flat_node_rows[i] = row;

            // 初始可见性: 只有 depth=0 可见
            if (flat.depth > 0) {
                row.style.height = .{ .px = 0 };
                row.style.overflow_hidden = true;
            }
        }

        // 键盘导航
        container.behavior.events.on_key_down = treeKeyHandler;
        container.behavior.events.key_context = @ptrCast(state);

        return .{ .wrapper = container, .state = state };
    }
};

const MAX_TREE_DEPTH = 64;

fn flattenNode(state: *TreeState, data: *const TreeNodeData, depth: u16) !void {
    if (state.flat_count >= TreeState.MAX_NODES) return;
    if (depth >= MAX_TREE_DEPTH) return; // 防止极深树导致栈溢出
    const idx = state.flat_count;
    state.flat_nodes[idx] = .{
        .data = data,
        .depth = depth,
        .flat_index = idx,
        .has_children = data.children.len > 0,
    };
    state.flat_count += 1;

    for (data.children) |*child| {
        try flattenNode(state, child, depth + 1);
    }
}

// ========== 内部辅助 ==========

const TreeClickContext = struct {
    state: *TreeState,
    flat_index: usize,
};

fn treeItemEventHandler(event: Event, context: ?*anyopaque) EventResult {
    switch (event) {
        .click => |c| {
            if (context) |ctx| {
                const tc: *TreeClickContext = @ptrCast(@alignCast(ctx));
                const flat = tc.state.flat_nodes[tc.flat_index];
                if (flat.has_children) {
                    tc.state.toggleExpand(tc.flat_index);
                }
                tc.state.selectNodeWithIntent(tc.flat_index, .{
                    // macOS 用 Cmd，其它平台用 Ctrl —— 两个都认
                    .toggle = c.modifiers.super or c.modifiers.ctrl,
                    .range = c.modifiers.shift,
                });
                return .stop;
            }
        },
        else => {},
    }
    return .ignored;
}

fn treeKeyHandler(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    const state: *TreeState = @ptrCast(@alignCast(context.?));

    const sel = state.selected_flat_index orelse 0;

    switch (key) {
        .down => {
            // 移动到下一个可见且可用的节点；尚未选中时从第 0 行开始（此前 0+1 跳过首行）
            var next = if (state.selected_flat_index) |s| s + 1 else 0;
            while (next < state.flat_count) : (next += 1) {
                if (state.isVisible(next) and !state.flat_nodes[next].data.disabled) {
                    state.selectNode(next);
                    break;
                }
            }
            return .stop;
        },
        .up => {
            if (sel > 0) {
                var prev = sel - 1;
                while (true) {
                    if (state.isVisible(prev) and !state.flat_nodes[prev].data.disabled) {
                        state.selectNode(prev);
                        break;
                    }
                    if (prev == 0) break;
                    prev -= 1;
                }
            }
            return .stop;
        },
        .right => {
            // 展开
            if (sel < state.flat_count and state.flat_nodes[sel].has_children) {
                if (!state.expanded[sel]) {
                    state.toggleExpand(sel);
                }
            }
            return .stop;
        },
        .left => {
            // 折叠
            if (sel < state.flat_count and state.flat_nodes[sel].has_children) {
                if (state.expanded[sel]) {
                    state.toggleExpand(sel);
                }
            }
            return .stop;
        },
        else => return .ignored,
    }
}

// ========== 测试 ==========

const test_tree = [_]TreeNodeData{
    .{
        .id = "src",
        .label_text = "src",
        .children = &[_]TreeNodeData{
            .{ .id = "main.zig", .label_text = "main.zig" },
            .{
                .id = "ui",
                .label_text = "ui",
                .children = &[_]TreeNodeData{
                    .{ .id = "core.zig", .label_text = "core.zig" },
                },
            },
        },
    },
    .{ .id = "README", .label_text = "README.md" },
};

test "Tree: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tree(.{
        .nodes = &test_tree,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 5 flat nodes: src, main.zig, ui, core.zig, README
    try std.testing.expectEqual(@as(usize, 5), result.state.flat_count);
}

test "Tree: initial visibility" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tree(.{
        .nodes = &test_tree,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // depth=0 可见 (src, README), depth>0 隐藏
    const src_row = result.state.flat_node_rows[0].?;
    try std.testing.expectEqual(@as(f32, 28), src_row.style.height.px);

    const main_row = result.state.flat_node_rows[1].?;
    try std.testing.expectEqual(@as(f32, 0), main_row.style.height.px);
}

test "Tree: expand/collapse" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tree(.{
        .nodes = &test_tree,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 展开 src (index 0)
    result.state.toggleExpand(0);
    try std.testing.expect(result.state.expanded[0]);

    // main.zig (index 1) 应该可见
    const main_row = result.state.flat_node_rows[1].?;
    try std.testing.expectEqual(@as(f32, 28), main_row.style.height.px);

    // 折叠 src
    result.state.toggleExpand(0);
    try std.testing.expect(!result.state.expanded[0]);
}

test "Tree: select node" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Tree(.{
        .nodes = &test_tree,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    result.state.selectNode(0);
    try std.testing.expectEqual(@as(?usize, 0), result.state.selected_flat_index);
}

test "Tree: 无选中时 Down 选第 0 行；方向键跳过 disabled 节点" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const nodes = [_]TreeNodeData{
        .{ .id = "a", .label_text = "A" },
        .{ .id = "b", .label_text = "B", .disabled = true },
        .{ .id = "c", .label_text = "C" },
    };
    const result = try Tree(.{ .nodes = &nodes }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expect(result.state.selected_flat_index == null);
    _ = treeKeyHandler(.down, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(?usize, 0), result.state.selected_flat_index);
    _ = treeKeyHandler(.down, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(?usize, 2), result.state.selected_flat_index);
    _ = treeKeyHandler(.up, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(?usize, 0), result.state.selected_flat_index);
}

// ── on_select payload + 多选 ────────────────────────────────

/// 记录回调收到的 node id —— 这正是此前拿不到的东西
const SelectSpy = struct {
    last: [64]u8 = [_]u8{0} ** 64,
    last_len: usize = 0,
    calls: usize = 0,

    fn onSelect(self: *SelectSpy, id: []const u8) void {
        const n = @min(id.len, self.last.len);
        @memcpy(self.last[0..n], id[0..n]);
        self.last_len = n;
        self.calls += 1;
    }

    fn lastId(self: *const SelectSpy) []const u8 {
        return self.last[0..self.last_len];
    }
};

fn mountTreeForTest(
    ctx: *Cx,
    scope: *Scope,
    mode: SelectionMode,
    handler: ?core.HandlerRef,
) !TreeResult {
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const result = try Tree(.{
        .nodes = &test_tree,
        .selection_mode = mode,
        .on_select = handler,
    }).mount(scope, ctx);
    try root.appendChild(ctx.allocator, result.wrapper);
    return result;
}

test "Tree: on_select 回调带上被选中节点的 id（此前完全拿不到是谁）" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    var spy = SelectSpy{};
    const result = try mountTreeForTest(
        ctx,
        scope,
        .single,
        core.Cx.strHandlerFrom(SelectSpy, &spy, SelectSpy.onSelect),
    );

    // flat 顺序：src(0) main.zig(1) ui(2) core.zig(3) README(4)
    result.state.selectNode(4);
    try std.testing.expectEqual(@as(usize, 1), spy.calls);
    try std.testing.expectEqualStrings("README", spy.lastId());
    try std.testing.expectEqualStrings("README", result.state.selectedId().?);

    result.state.selectNode(3);
    try std.testing.expectEqual(@as(usize, 2), spy.calls);
    try std.testing.expectEqualStrings("core.zig", spy.lastId());
}

test "Tree: 无参 handler 仍被调用（invokeWithStr 退化，不丢事件）" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const Counter = struct {
        n: usize = 0,
        fn bump(c: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(c));
            self.n += 1;
        }
    };
    var counter = Counter{};
    const result = try mountTreeForTest(ctx, scope, .single, .{
        .callback = Counter.bump,
        .context = @ptrCast(&counter),
    });

    result.state.selectNode(0);
    result.state.selectNode(4);
    try std.testing.expectEqual(@as(usize, 2), counter.n);
}

test "Tree: single 模式选中新行取消旧行（默认，行为不变）" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountTreeForTest(ctx, scope, .single, null);
    const st = result.state;

    st.selectNode(0);
    // single 下 Cmd 也不会累加
    st.selectNodeWithIntent(4, .{ .toggle = true });
    try std.testing.expectEqual(@as(usize, 1), st.selected_count);
    try std.testing.expect(st.isSelected(4));
    try std.testing.expect(!st.isSelected(0));
    // 底色也跟着走
    try std.testing.expect(st.flat_node_rows[4].?.getBackground().eql(ctx.tokens.color.list_selection_bg));
    try std.testing.expect(st.flat_node_rows[0].?.getBackground().eql(Color.TRANSPARENT));
}

test "Tree: multi 多选 —— Cmd 切换 / Shift 区间 / selectedIds" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try mountTreeForTest(ctx, scope, .multi, null);
    const st = result.state;

    st.selectNode(0); // src
    st.selectNodeWithIntent(4, .{ .toggle = true }); // + README
    try std.testing.expectEqual(@as(usize, 2), st.selected_count);
    try std.testing.expect(st.isSelected(0) and st.isSelected(4));

    var ids: [8][]const u8 = undefined;
    const n = st.selectedIds(&ids);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("src", ids[0]);
    try std.testing.expectEqualStrings("README", ids[1]);

    // Cmd 再点 4 → 取消
    st.selectNodeWithIntent(4, .{ .toggle = true });
    try std.testing.expectEqual(@as(usize, 1), st.selected_count);
    try std.testing.expect(!st.isSelected(4));

    // Shift 区间：锚点是 4（上一次 toggle 落点）→ 重划 1..4
    st.selectNode(1);
    st.selectNodeWithIntent(4, .{ .range = true });
    try std.testing.expectEqual(@as(usize, 4), st.selected_count);
    for (1..5) |i| try std.testing.expect(st.isSelected(i));
    try std.testing.expect(!st.isSelected(0));

    // 无修饰点击清空其余
    st.selectNode(2);
    try std.testing.expectEqual(@as(usize, 1), st.selected_count);
    try std.testing.expect(st.isSelected(2));
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "tree: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tree", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const nodes = [_]TreeNodeData{ .{ .id = "a", .label_text = "A", .children = &.{ .{ .id = "a1", .label_text = "A1" }, .{ .id = "a2", .label_text = "A2", .disabled = true } } }, .{ .id = "b", .label_text = "B" } };
            const r = try Tree(.{ .nodes = &nodes }).mount(scope, cx);
            return r.wrapper;
        }
    }.m);
}
