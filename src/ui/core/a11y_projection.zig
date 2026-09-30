//! a11y 树投影（Node → AccessibilityTree）—— 从 `Cx` 析出。
//!
//! 原本散在 `Cx` 上的六样东西：`mapA11yRoleToTreeRole` / `parseLiveRegion` /
//! `stringHash` 三个纯函数，加 `projectA11yNode` / `syncA11yNodeRecursive` /
//! `firstSubtreeText` 三个投影函数。它们对 `Cx` 的**全部**依赖只有四项：
//!
//!   * `allocator` —— a11y_label_buf 的 put；
//!   * `accessibility_tree` —— upsert / remove 的目标；
//!   * `a11y_label_buf` —— hash→字符串的旁路查找表；
//!   * `focus_manager.current_focus` —— 只读「这个节点是否持焦」一个 bool。
//!
//! 接口因此切在：**投影函数接收显式参数，不接收 `*Cx`**。焦点解析留在 Cx 侧
//! （`FocusProbe` 函数指针注入，同 text_input_session 的 Host 手法）；9 个
//! `cxA11y*` C-ABI 回调、macos_bridge 上下文注册、flushToBridge 也留在
//! `Cx.syncA11yTreeFromInteractions` —— 那是平台适配层，不是投影逻辑。
//! `accessibility_tree` / `a11y_label_buf` 两个字段同样留在 Cx 上（大量组件
//! 测试直接读 `cx.accessibility_tree.get(...)`，动字段是大面积改动）。
//!
//! 拆出来的直接收益：这些规则此前只能靠「建 Cx → mount → layout → render」
//! 整条链路驱动，现在拿一个裸 Node + 一棵 AccessibilityTree 就能断言。
//! 这里历史上出过「十个状态位硬编码 false / value_now 恒 0」的批量事故
//! （见 projectNode 内注释）—— 组件即使正确声明也被原地丢弃。本文件的
//! 逐字段测试就是为钉住那类回归而写。

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const node_mod = @import("node.zig");
const element_id_mod = @import("element_id.zig");
const a11y_tree_mod = @import("../a11y/tree.zig");

const Node = node_mod.Node;
const ElementId = element_id_mod.ElementId;
const A11yProps = types.A11yProps;
const A11yRole = types.A11yRole;

/// hash→字符串旁路表。A11yNode 只存 hash 不存 slice（见 tree.zig 头注释），
/// AT 工具读字符串时经 label_resolver 回这张表查。
pub const LabelBuf = std.AutoHashMapUnmanaged(u64, []const u8);

/// 焦点探针：Cx 实现为「比较 focus_manager.current_focus 指针」。
/// 投影层不需要（也不能）import Cx，于是把它做成注入 —— 与
/// text_input_session.Host、custom_cursor.RasterizeFn 同一手法。
pub const FocusProbe = struct {
    ctx: ?*const anyopaque = null,
    isFocused: *const fn (ctx: ?*const anyopaque, node: *const Node) bool,
};

/// types.A11yRole → a11y_tree.Role 映射。后者更细 (40+ ARIA roles)，
/// 前者是 Node 上的 24-variant subset。无对应时退化 .generic (focusable 容器) 或 .none。
pub fn mapA11yRoleToTreeRole(role: A11yRole, focusable: bool) a11y_tree_mod.Role {
    return switch (role) {
        .none => if (focusable) a11y_tree_mod.Role.generic else a11y_tree_mod.Role.none,
        .button => .button,
        .checkbox => .checkbox,
        .radio => .radio,
        .textbox => .textbox,
        .switch_role => .checkbox, // ARIA switch 在 NSAccessibility 没原生 role；用 checkbox 近似
        .tab => .tab,
        .tablist => .tabs,
        .dialog => .dialog,
        .alert => .alert,
        .menu => .menu,
        .menuitem => .menuitem,
        .listbox => .listbox,
        .option => .listitem,
        .progressbar => .progressbar,
        .slider => .slider,
        .heading => .heading,
        .link => .link,
        .img => .image,
        .list => .list,
        .listitem => .listitem,
        .table => .grid,
        .tooltip => .tooltip,
        // v0.7 §2.5
        .combobox => .combobox,
        .grid => .grid,
        .gridcell => .cell,
        // 2026-07-31 补齐：这批在 a11y/tree.zig 里本就是一比一同名角色。
        .tree => .tree,
        .treeitem => .treeitem,
        .row => .row,
        .columnheader => .columnheader,
        .rowheader => .rowheader,
        .menubar => .menubar,
        .menuitemcheckbox => .menuitemcheckbox,
        .menuitemradio => .menuitemradio,
        .spinbutton => .spinbutton,
        .status => .status,
        .group => .group,
        .navigation => .navigation,
        .separator => .separator,
        .region => .region,
        .article => .article,
        .application => .application,
        .radiogroup => .radiogroup,
        .textarea => .textarea,
        .searchbox => .searchbox,
        .tabpanel => .tabpanel,
        .alertdialog => .alertdialog,
        .log => .log,
        .paragraph => .paragraph,
        .section => .section,
        .form => .form,
        .main => .main,
        .banner => .banner,
        .contentinfo => .contentinfo,
        .generic => .generic,
    };
}

pub fn parseLiveRegion(value: ?[]const u8) a11y_tree_mod.LiveRegion {
    const s = value orelse return .off;
    if (std.mem.eql(u8, s, "polite")) return .polite;
    if (std.mem.eql(u8, s, "assertive")) return .assertive;
    return .off;
}

pub fn stringHash(s: []const u8) u64 {
    if (s.len == 0) return 0;
    return std.hash.Wyhash.hash(0, s);
}

/// 投影一个 Node 到 A11yNode；返回是否真投影 (false 表示 caller 应 remove)。
///
/// 对 Cx 的依赖全部显式化在参数表里（见模块头）：tree / label_buf 由 caller
/// 传入，焦点被压成一个 bool。hidden 是**祖先传播后**的值（含本节点自身的
/// props.hidden），由 syncSubtree 计算。
pub fn projectNode(
    allocator: Allocator,
    tree: *a11y_tree_mod.AccessibilityTree,
    label_buf: *LabelBuf,
    node: *const Node,
    eid: ElementId,
    parent: ElementId,
    sibling_index: u32,
    hidden: bool,
    is_focused: bool,
) bool {
    const a11y_props = node.behavior.interaction.a11y;
    const focusable = node.behavior.interaction.focusable;
    if (a11y_props == null and !focusable) return false;

    const props = a11y_props orelse A11yProps{};
    const role = mapA11yRoleToTreeRole(props.role, focusable);
    if (role == .none and !focusable) return false;

    // label fallback：组件未显式给 label，借子树文本（focus.zig 同款）。
    const label_str = if (props.label) |l| l else firstSubtreeText(node);
    const label_hash = stringHash(label_str);
    if (label_str.len > 0) {
        // 可降级：a11y_label_buf 只是 hash→字符串的旁路查找表，每次
        // syncA11yTreeFromInteractions 都 clearRetainingCapacity 后整体重建。
        // put 失败只让本次 lookupA11yString 返回 null（该条 label 这一轮读不
        // 出来），不影响 a11y 树结构本身，下一次同步即自愈。
        label_buf.put(allocator, label_hash, label_str) catch {};
    }

    const description_str = props.description orelse "";
    const description_hash = stringHash(description_str);
    if (description_str.len > 0) {
        // 同 label：旁路查找表，失败仅本轮读不出，下次同步自愈。
        label_buf.put(allocator, description_hash, description_str) catch {};
    }

    const placeholder_str = props.placeholder orelse "";
    const placeholder_hash = stringHash(placeholder_str);
    if (placeholder_str.len > 0) {
        label_buf.put(allocator, placeholder_hash, placeholder_str) catch {};
    }

    const identifier_str = props.identifier orelse "";
    const identifier_hash = stringHash(identifier_str);
    if (identifier_str.len > 0) {
        label_buf.put(allocator, identifier_hash, identifier_str) catch {};
    }

    const value_str = props.value_text orelse "";
    const value_hash = stringHash(value_str);
    if (value_str.len > 0) {
        // 同 label：旁路查找表，失败仅本轮读不出，下次同步自愈。
        label_buf.put(allocator, value_hash, value_str) catch {};
    }

    const live = parseLiveRegion(props.live);
    const live_text = if (live == .off)
        ""
    else if (props.live_text) |announcement|
        announcement
    else if (props.value_text) |value|
        value
    else if (props.label) |label|
        if (label.len > 0) label else firstSubtreeText(node)
    else
        firstSubtreeText(node);
    const live_text_hash = stringHash(live_text);
    if (live_text.len > 0) {
        label_buf.put(allocator, live_text_hash, live_text) catch {};
    }

    // ⚠ 2026-07-31 前这里把 pressed/required/invalid/readonly/busy/
    // selected/modal/haspopup/multiline/multiselectable 十个位全部
    // 硬编码成 false，value_now/min/max 硬编码成 0。后果是组件即使
    // 正确声明也被原地丢弃 —— ComboBox / DatePicker / SelectHeadless
    // 都设了 has_popup，AT 侧却永远收不到；slider / progressbar 永远
    // 报不出数值。现按 props 如实投影。
    const a11y_state: a11y_tree_mod.State = .{
        .disabled = props.disabled,
        .checked = if (props.checked) |c| c else false,
        .indeterminate = props.indeterminate,
        .expanded = if (props.expanded) |e| e else false,
        .focused = is_focused,
        .focusable = focusable,
        .pressed = props.pressed,
        .required = props.required,
        .invalid = props.invalid,
        .readonly = props.readonly,
        .busy = props.busy,
        .hidden = hidden,
        .selected = props.selected,
        .modal = props.modal,
        .haspopup = props.has_popup != .none,
        .multiline = props.multiline,
        .multiselectable = props.multiselectable,
        .secure = props.secure,
        .expanded_present = props.expanded != null,
    };

    const rect = node.globalRect();
    const has_click_route = node.behavior.events.on_click != null or node.behavior.events.on_event != null;
    const has_step_route = node.behavior.events.on_key_down != null or node.behavior.events.on_event != null;
    const toggle_role = role == .checkbox or role == .radio or
        role == .menuitemcheckbox or role == .menuitemradio;
    const step_role = role == .slider or role == .spinbutton;
    const editable = if (props.editable_text) |editable_props| a11y_tree_mod.EditableText{
        .selection_start = editable_props.selection_start,
        .selection_end = editable_props.selection_end,
        .caret = editable_props.caret,
        .visible_start = editable_props.visible_start,
        .visible_end = editable_props.visible_end,
        .can_set_selection = !props.disabled and !props.readonly,
        .can_set_value = editable_props.set_value != null and !props.disabled and !props.readonly,
    } else null;
    const numeric = props.value_range;

    // active_descendant 投影 — caller 通过
    // node.behavior.interaction.a11y.active_descendant_element_id 设
    // 当前激活的子项 element_id_raw (combobox/listbox/grid 虚拟焦点模式)。
    const active_desc = if (props.active_descendant_element_id == 0xFFFFFFFF)
        ElementId.NULL
    else
        ElementId.fromRaw(props.active_descendant_element_id);

    tree.upsert(.{
        .element = eid,
        .parent = parent,
        .role = role,
        .state = a11y_state,
        .live = live,
        .label_hash = label_hash,
        .description_hash = description_hash,
        .placeholder_hash = placeholder_hash,
        .identifier_hash = identifier_hash,
        .text_hash = value_hash,
        .live_text_hash = live_text_hash,
        .value_now = if (numeric) |value| value.now else props.value_now,
        .value_min = if (numeric) |value| value.min else props.value_min,
        .value_max = if (numeric) |value| value.max else props.value_max,
        .numeric_value_present = numeric != null or props.value_now != 0 or props.value_min != 0 or props.value_max != 0,
        .can_set_numeric_value = if (numeric) |value|
            value.context != null and value.set_value != null and !props.disabled and !props.readonly
        else
            false,
        .sibling_index = sibling_index,
        .active_descendant = active_desc,
        .frame = .{ .x = rect.x, .y = rect.y, .width = rect.w, .height = rect.h },
        .actions = .{
            .press = has_click_route,
            .toggle = toggle_role and has_click_route,
            .increment = step_role and has_step_route,
            .decrement = step_role and has_step_route,
        },
        .editable_text = editable,
        .orientation = @enumFromInt(@intFromEnum(props.orientation)),
        .sort_direction = @enumFromInt(@intFromEnum(props.sort_direction)),
        .level = props.level,
        .row_index = props.row_index,
        .row_span = @max(props.row_span, 1),
        .column_index = props.column_index,
        .column_span = @max(props.column_span, 1),
    }) catch return false;
    return true;
}

/// 递归同步一棵 Node 子树到 a11y 树。
///
/// 维护两条不变量：
///   * a11y parent = element 树上**最近的已投影祖先**（不裁剪层级，
///     button 包 text 时只投 button，text 内容作 label）；
///   * sibling_index 只数**已投影**的兄弟（未投影的纯视觉容器不占位）。
///
/// 节点不再合格（无 a11y props 且不 focusable）时走 remove：remove 失败会
/// 把陈旧条目留在树上，VoiceOver 会继续朗读一个界面上已经不存在的元素，
/// 且下次同步不会再走到这里重试 —— 故 OOM 直接 panic。
pub fn syncSubtree(
    allocator: Allocator,
    tree: *a11y_tree_mod.AccessibilityTree,
    label_buf: *LabelBuf,
    node: *Node,
    parent_a11y_id: ElementId,
    sibling_counter: *u32,
    ancestor_hidden: bool,
    focus: FocusProbe,
) void {
    var next_parent = parent_a11y_id;
    const explicitly_hidden = if (node.behavior.interaction.a11y) |props| props.hidden else false;
    // display:none 子树与 aria-hidden 同样整棵退出无障碍树（节点仍在，只是不呈现）。
    const subtree_hidden = ancestor_hidden or explicitly_hidden or node.style.display == .none;
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid: ElementId = .{
            .index = @as(u24, @intCast(node.element_id_raw & 0x00FF_FFFF)),
            .generation = @as(u8, @intCast((node.element_id_raw >> 24) & 0xFF)),
        };
        if (projectNode(allocator, tree, label_buf, node, eid, parent_a11y_id, sibling_counter.*, subtree_hidden, focus.isFocused(focus.ctx, node))) {
            next_parent = eid;
            sibling_counter.* += 1;
        } else {
            // 正确性路径：节点已不该出现在 a11y 树里（不再 focusable / 无 a11y
            // props）。remove 失败会把陈旧条目留在树上，VoiceOver 会继续朗读一个
            // 界面上已经不存在的元素，且下次同步不会再走到这里重试。
            tree.remove(eid) catch @panic("OOM: a11y tree remove (stale node projection)");
        }
    }
    var child_counter: u32 = 0;
    for (node.children.items) |child| {
        syncSubtree(allocator, tree, label_buf, child, next_parent, &child_counter, subtree_hidden, focus);
    }
}

pub fn firstSubtreeText(node: *const Node) []const u8 {
    if (node.getText()) |t| {
        if (t.content.len > 0) return t.content;
    }
    for (node.children.items) |child| {
        const t = firstSubtreeText(child);
        if (t.len > 0) return t;
    }
    return "";
}

// ── 测试 ───────────────────────────────────────────────────────────────
//
// 全部用 standalone Node（element_id_raw == 0xFFFFFFFF，不挂任何 Cx/World）：
// eid 是 projectNode 的显式参数，与 node.element_id_raw 无关，于是不需要
// 建 Cx、建 element 表、跑 render。content/rect 落进程级 standalone fallback
// 表（page_allocator，GPA leak check 看不见）。
//
// syncSubtree 的用例需要非 INVALID 的 element_id_raw（它靠该字段派生 eid），
// 那里的建树顺序见该节头注释。

const testing = std.testing;

var g_next_node_id: u32 = 0x9000;
var g_handler_ctx: u8 = 0;
var g_numeric_ctx: u8 = 0;
var g_edit_ctx: u8 = 0;

fn makeNode(tag: types.ElementTag) !*Node {
    g_next_node_id += 1;
    const n = try Node.create(testing.allocator, g_next_node_id, tag, .{});
    // 强制 standalone：即使进程里有先前测试遗留的全局 hook，也固定走
    // standalone content/rect 存储；同时清掉可能被复用地址上的陈旧文本。
    n.element_id_raw = 0xFFFFFFFF;
    n.world_id = node_mod.INVALID_WORLD_ID;
    n.world_ref = null;
    n.setText(null);
    return n;
}

fn makeBox() !*Node {
    return makeNode(.box);
}

fn makeText(content: []const u8) !*Node {
    const n = try makeNode(.text);
    var t = types.TextProps{};
    t.content = content;
    t.owned = false;
    n.setText(t);
    return n;
}

/// standalone content 表按 node 指针 key、进程级存活，不清会把陈旧文本
/// 泄给复用同一地址的后续节点 —— 递归清掉再销毁。
fn destroyTree(root: *Node) void {
    clearTextEntries(root);
    root.destroy(testing.allocator);
}

fn clearTextEntries(n: *Node) void {
    if (n.getText() != null) n.setText(null);
    for (n.children.items) |c| clearTextEntries(c);
}

fn makeEid(index: u24) ElementId {
    return .{ .index = index, .generation = 1 };
}

fn noopHandler(_: *anyopaque) void {}

fn handlerRef() types.HandlerRef {
    return .{ .callback = noopHandler, .context = @ptrCast(&g_handler_ctx) };
}

fn noopKeyHandler(_: types.KeyCode, _: types.Modifiers, _: ?*anyopaque) types.EventResult {
    return .handled;
}

fn noopEventHandler(_: types.Event, _: ?*anyopaque) types.EventResult {
    return .handled;
}

fn setNumericValue(_: *anyopaque, _: f32) bool {
    return true;
}

fn setSelection(_: *anyopaque, _: u32, _: u32) bool {
    return true;
}

fn setEditTextValue(_: *anyopaque, _: []const u8) bool {
    return true;
}

/// 指向固定节点的焦点探针：只有那个节点「持焦」。
fn probeSingle(ctx: ?*const anyopaque, n: *const Node) bool {
    const target: *const Node = @ptrCast(@alignCast(ctx orelse return false));
    return target == n;
}

fn probeOf(target: *const Node) FocusProbe {
    return .{ .ctx = @ptrCast(target), .isFocused = probeSingle };
}

// ── 纯函数 ─────────────────────────────────────────────────────────────

test "mapA11yRoleToTreeRole: 非同名映射逐一钉住" {
    // 这些是两侧名字不同的映射，逐一断言（防止有人"顺手"改掉近似策略）
    try testing.expectEqual(a11y_tree_mod.Role.none, mapA11yRoleToTreeRole(.none, false));
    try testing.expectEqual(a11y_tree_mod.Role.checkbox, mapA11yRoleToTreeRole(.switch_role, false));
    try testing.expectEqual(a11y_tree_mod.Role.tabs, mapA11yRoleToTreeRole(.tablist, false));
    try testing.expectEqual(a11y_tree_mod.Role.listitem, mapA11yRoleToTreeRole(.option, false));
    try testing.expectEqual(a11y_tree_mod.Role.grid, mapA11yRoleToTreeRole(.table, false));
    try testing.expectEqual(a11y_tree_mod.Role.cell, mapA11yRoleToTreeRole(.gridcell, false));
    try testing.expectEqual(a11y_tree_mod.Role.image, mapA11yRoleToTreeRole(.img, false));

    // 同名映射抽查（全量见下一条 comptime 用例）
    try testing.expectEqual(a11y_tree_mod.Role.button, mapA11yRoleToTreeRole(.button, false));
    try testing.expectEqual(a11y_tree_mod.Role.combobox, mapA11yRoleToTreeRole(.combobox, false));
    try testing.expectEqual(a11y_tree_mod.Role.alertdialog, mapA11yRoleToTreeRole(.alertdialog, false));
    try testing.expectEqual(a11y_tree_mod.Role.generic, mapA11yRoleToTreeRole(.generic, false));
}

test "mapA11yRoleToTreeRole: 除 .none 外每个角色都落到非 .none（新增角色不得静默退化）" {
    inline for (@typeInfo(A11yRole).@"enum".fields) |field| {
        if (!std.mem.eql(u8, field.name, "none")) {
            const role: A11yRole = @field(A11yRole, field.name);
            try testing.expect(mapA11yRoleToTreeRole(role, false) != .none);
        }
    }
}

test "mapA11yRoleToTreeRole: focusable 只影响 .none（.generic 容器化），不影响具体角色" {
    try testing.expectEqual(a11y_tree_mod.Role.none, mapA11yRoleToTreeRole(.none, false));
    try testing.expectEqual(a11y_tree_mod.Role.generic, mapA11yRoleToTreeRole(.none, true));
    // focusable=true 不会把 button 改写成别的角色
    try testing.expectEqual(a11y_tree_mod.Role.button, mapA11yRoleToTreeRole(.button, true));
    try testing.expectEqual(a11y_tree_mod.Role.checkbox, mapA11yRoleToTreeRole(.switch_role, true));
}

test "parseLiveRegion: null/合法值/非法值" {
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion(null));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.polite, parseLiveRegion("polite"));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.assertive, parseLiveRegion("assertive"));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion("off"));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion(""));
    // 大小写敏感：ARIA 属性值由组件作者写字面量，不在这里做归一化
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion("POLITE"));
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, parseLiveRegion("rude"));
}

test "stringHash: 空串哨兵 0、确定性、可区分" {
    try testing.expectEqual(@as(u64, 0), stringHash(""));
    try testing.expectEqual(stringHash("Submit"), stringHash("Submit"));
    try testing.expect(stringHash("a") != stringHash("b"));
    try testing.expect(stringHash(" OK") != stringHash("OK"));
}

// ── projectNode：资格判定 / 角色 / 焦点 ────────────────────────────────

test "projectNode: 无 a11y props 且不可聚焦 → false（caller 应 remove）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    try testing.expect(!projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    try testing.expectEqual(@as(usize, 0), tree.count());
}

test "projectNode: role=.none 且不可聚焦 → false；role=.none 可聚焦 → .generic 容器" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{ .role = .none };
    try testing.expect(!projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));

    const f = try makeBox();
    defer destroyTree(f);
    f.behavior.interaction.a11y = .{ .role = .none };
    f.behavior.interaction.focusable = true;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, f, makeEid(2), .NULL, 0, false, false));
    const a = tree.get(makeEid(2)).?;
    try testing.expectEqual(a11y_tree_mod.Role.generic, a.role);
    try testing.expect(a.state.focusable);
}

test "projectNode: 无 props 但 focusable → .generic（VoiceOver 仍可 tab 到）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.focusable = true;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 3, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expectEqual(a11y_tree_mod.Role.generic, a.role);
    try testing.expect(a.state.focusable);
    try testing.expectEqual(@as(u32, 3), a.sibling_index);
}

test "projectNode: is_focused 直通 state.focused（未隐藏/未禁用节点）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{ .role = .button, .label = "F" };
    n.behavior.interaction.focusable = true;

    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, true));
    try testing.expect(tree.get(makeEid(1)).?.state.focused);

    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(2), .NULL, 0, false, false));
    try testing.expect(!tree.get(makeEid(2)).?.state.focused);
}

// ── projectNode：label / live 文本解析 ─────────────────────────────────

test "projectNode: label 回退到子树文本，显式 label 优先" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const btn = try makeBox();
    defer destroyTree(btn);
    btn.behavior.interaction.a11y = .{ .role = .button };
    const label_text = try makeText("Submit");
    try btn.appendChild(testing.allocator, label_text);

    try testing.expect(projectNode(testing.allocator, &tree, &labels, btn, makeEid(1), .NULL, 0, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expectEqual(stringHash("Submit"), a.label_hash);
    try testing.expectEqualStrings("Submit", labels.get(a.label_hash).?);

    // 显式 label 赢过子树文本
    const btn2 = try makeBox();
    defer destroyTree(btn2);
    btn2.behavior.interaction.a11y = .{ .role = .button, .label = "OK" };
    const inner = try makeText("ignored");
    try btn2.appendChild(testing.allocator, inner);
    try testing.expect(projectNode(testing.allocator, &tree, &labels, btn2, makeEid(2), .NULL, 0, false, false));
    try testing.expectEqual(stringHash("OK"), tree.get(makeEid(2)).?.label_hash);
}

test "firstSubtreeText: 自身文本优先；跳过空子节点；深度优先取第一个非空" {
    const root = try makeBox();
    defer destroyTree(root);
    const empty_a = try makeBox();
    const deep = try makeText("deep");
    const sibling_b = try makeText("B");
    try empty_a.appendChild(testing.allocator, deep);
    try root.appendChild(testing.allocator, empty_a);
    try root.appendChild(testing.allocator, sibling_b);
    try testing.expectEqualStrings("deep", firstSubtreeText(root));

    const own = try makeText("own");
    defer destroyTree(own);
    const child = try makeText("child");
    try own.appendChild(testing.allocator, child);
    try testing.expectEqualStrings("own", firstSubtreeText(own));

    const bare = try makeBox();
    defer bare.destroy(testing.allocator);
    try testing.expectEqualStrings("", firstSubtreeText(bare));
}

test "projectNode: live 文本解析优先级 live_text > value_text > label > 子树文本" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // live = off → 不解析任何播报文本
    const off = try makeBox();
    defer destroyTree(off);
    off.behavior.interaction.a11y = .{ .role = .status, .live_text = "不应被采用" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, off, makeEid(1), .NULL, 0, false, false));
    const a_off = tree.get(makeEid(1)).?;
    try testing.expectEqual(a11y_tree_mod.LiveRegion.off, a_off.live);
    try testing.expectEqual(@as(u64, 0), a_off.live_text_hash);

    // live_text 显式给 → 直接用
    const explicit = try makeBox();
    defer destroyTree(explicit);
    explicit.behavior.interaction.a11y = .{
        .role = .alert,
        .live = "assertive",
        .live_text = "Disk full",
        .value_text = "v",
        .label = "l",
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, explicit, makeEid(2), .NULL, 0, false, false));
    const a_exp = tree.get(makeEid(2)).?;
    try testing.expectEqual(a11y_tree_mod.LiveRegion.assertive, a_exp.live);
    try testing.expectEqual(stringHash("Disk full"), a_exp.live_text_hash);
    try testing.expectEqualStrings("Disk full", labels.get(a_exp.live_text_hash).?);

    // 无 live_text → value_text
    const by_value = try makeBox();
    defer destroyTree(by_value);
    by_value.behavior.interaction.a11y = .{ .role = .status, .live = "polite", .value_text = "3 files" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, by_value, makeEid(3), .NULL, 0, false, false));
    try testing.expectEqual(stringHash("3 files"), tree.get(makeEid(3)).?.live_text_hash);

    // 无 live_text/value_text → 非空 label；label 为空串则继续退到子树文本
    const by_label = try makeBox();
    defer destroyTree(by_label);
    by_label.behavior.interaction.a11y = .{ .role = .status, .live = "polite", .label = "Saved" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, by_label, makeEid(4), .NULL, 0, false, false));
    try testing.expectEqual(stringHash("Saved"), tree.get(makeEid(4)).?.live_text_hash);

    const empty_label = try makeBox();
    defer destroyTree(empty_label);
    empty_label.behavior.interaction.a11y = .{ .role = .status, .live = "polite", .label = "" };
    const t = try makeText("from subtree");
    try empty_label.appendChild(testing.allocator, t);
    try testing.expect(projectNode(testing.allocator, &tree, &labels, empty_label, makeEid(5), .NULL, 0, false, false));
    try testing.expectEqual(stringHash("from subtree"), tree.get(makeEid(5)).?.live_text_hash);
}

test "projectNode: description/placeholder/identifier/value_text 各自入旁路表" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{
        .role = .textbox,
        .label = "Email",
        .description = "工作邮箱",
        .placeholder = "name@example.com",
        .identifier = "login-email",
        .value_text = "a@b.c",
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expectEqualStrings("工作邮箱", labels.get(a.description_hash).?);
    try testing.expectEqualStrings("name@example.com", labels.get(a.placeholder_hash).?);
    try testing.expectEqualStrings("login-email", labels.get(a.identifier_hash).?);
    try testing.expectEqualStrings("a@b.c", labels.get(a.text_hash).?);
    // 空 description 的 hash 是 0，且不应写入任何空串条目
    try testing.expect(labels.get(0) == null);
}

// ── projectNode：状态位逐字段（历史事故点，逐个钉死） ──────────────────

test "projectNode: 状态位逐字段投影（2026-07-31 前曾整批硬编码 false）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{
        .role = .checkbox,
        .label = "All",
        .disabled = true,
        .checked = true,
        .indeterminate = true,
        .expanded = true,
        .selected = true,
        .pressed = true,
        .required = true,
        .invalid = true,
        .readonly = true,
        .busy = true,
        .modal = true,
        .has_popup = .menu,
        .multiline = true,
        .multiselectable = true,
        .secure = true,
    };

    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, true, false));
    const a = tree.get(makeEid(1)).?;
    // 十个曾被硬编码成 false 的位
    try testing.expect(a.state.selected);
    try testing.expect(a.state.pressed);
    try testing.expect(a.state.required);
    try testing.expect(a.state.invalid);
    try testing.expect(a.state.readonly);
    try testing.expect(a.state.busy);
    try testing.expect(a.state.modal);
    try testing.expect(a.state.haspopup);
    try testing.expect(a.state.multiline);
    try testing.expect(a.state.multiselectable);
    // 一直存在的位
    try testing.expect(a.state.disabled);
    try testing.expect(a.state.checked);
    try testing.expect(a.state.indeterminate);
    try testing.expect(a.state.expanded);
    try testing.expect(a.state.expanded_present);
    try testing.expect(a.state.secure);
    try testing.expect(a.state.hidden); // hidden 参数（祖先传播后）直通
    // focused 不在此断言：upsert 对 disabled/hidden 节点强制清零（tree 侧策略），
    // 直通行为由上面的 "is_focused 直通" 用例单独钉。
}

test "projectNode: 默认 props 下除 focusable/hidden 外所有状态位为 false" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{ .role = .button, .label = "B" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expect(!a.state.disabled);
    try testing.expect(!a.state.checked);
    try testing.expect(!a.state.indeterminate);
    try testing.expect(!a.state.expanded);
    try testing.expect(!a.state.expanded_present);
    try testing.expect(!a.state.selected);
    try testing.expect(!a.state.pressed);
    try testing.expect(!a.state.required);
    try testing.expect(!a.state.invalid);
    try testing.expect(!a.state.readonly);
    try testing.expect(!a.state.busy);
    try testing.expect(!a.state.modal);
    try testing.expect(!a.state.haspopup);
    try testing.expect(!a.state.multiline);
    try testing.expect(!a.state.multiselectable);
    try testing.expect(!a.state.secure);
    try testing.expect(!a.state.hidden);
    try testing.expect(!a.state.focused);
    try testing.expect(!a.state.focusable);
}

test "projectNode: checked/expanded 的可选三态（null → false；expanded_present 只看是否声明）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // checked = null / expanded = null：不声明 ⇒ false，且 expanded_present = false
    const undeclared = try makeBox();
    defer destroyTree(undeclared);
    undeclared.behavior.interaction.a11y = .{ .role = .checkbox, .label = "u" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, undeclared, makeEid(1), .NULL, 0, false, false));
    const a1 = tree.get(makeEid(1)).?;
    try testing.expect(!a1.state.checked);
    try testing.expect(!a1.state.expanded);
    try testing.expect(!a1.state.expanded_present);

    // checked = false（显式未选中）/ expanded = false（显式折叠）：
    // 值仍为 false，但「支持展开」这个事实必须能表达 —— expanded_present = true。
    // 这正是叶 treeitem 与不支持展开元素的分界（tree.zig State 注释）。
    const declared_false = try makeBox();
    defer destroyTree(declared_false);
    declared_false.behavior.interaction.a11y = .{
        .role = .treeitem,
        .label = "d",
        .checked = false,
        .expanded = false,
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, declared_false, makeEid(2), .NULL, 0, false, false));
    const a2 = tree.get(makeEid(2)).?;
    try testing.expect(!a2.state.checked);
    try testing.expect(!a2.state.expanded);
    try testing.expect(a2.state.expanded_present);

    // expanded = true
    const declared_true = try makeBox();
    defer destroyTree(declared_true);
    declared_true.behavior.interaction.a11y = .{ .role = .treeitem, .label = "t", .expanded = true };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, declared_true, makeEid(3), .NULL, 0, false, false));
    const a3 = tree.get(makeEid(3)).?;
    try testing.expect(a3.state.expanded);
    try testing.expect(a3.state.expanded_present);
}

// ── projectNode：数值 / actions / editable / 元数据 ────────────────────

test "projectNode: value_range 优先于 legacy value_now/min/max；present 与 setter 门控" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // legacy 三字段原样透传，且任一非 0 即 present
    const legacy = try makeBox();
    defer destroyTree(legacy);
    legacy.behavior.interaction.a11y = .{
        .role = .slider,
        .label = "L",
        .value_now = 42,
        .value_min = 0,
        .value_max = 100,
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, legacy, makeEid(1), .NULL, 0, false, false));
    const a1 = tree.get(makeEid(1)).?;
    try testing.expectEqual(@as(f32, 42), a1.value_now);
    try testing.expectEqual(@as(f32, 0), a1.value_min);
    try testing.expectEqual(@as(f32, 100), a1.value_max);
    try testing.expect(a1.numeric_value_present);
    try testing.expect(!a1.can_set_numeric_value);

    // value_range 覆盖 legacy 字段
    const ranged = try makeBox();
    defer destroyTree(ranged);
    ranged.behavior.interaction.a11y = .{
        .role = .slider,
        .label = "R",
        .value_now = 9,
        .value_range = .{ .now = 7, .min = 0, .max = 10 },
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, ranged, makeEid(2), .NULL, 0, false, false));
    const a2 = tree.get(makeEid(2)).?;
    try testing.expectEqual(@as(f32, 7), a2.value_now);
    try testing.expectEqual(@as(f32, 0), a2.value_min);
    try testing.expectEqual(@as(f32, 10), a2.value_max);
    try testing.expect(a2.numeric_value_present);
    try testing.expect(!a2.can_set_numeric_value); // 无 context/set_value

    // 全零 + 无 range ⇒ 不 present（合法的全零区间 vs 未发布值）
    const none = try makeBox();
    defer destroyTree(none);
    none.behavior.interaction.a11y = .{ .role = .progressbar, .label = "N" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, none, makeEid(3), .NULL, 0, false, false));
    try testing.expect(!tree.get(makeEid(3)).?.numeric_value_present);

    // setter + context + 未禁用/只读 → can_set_numeric_value
    const settable = try makeBox();
    defer destroyTree(settable);
    settable.behavior.interaction.a11y = .{
        .role = .slider,
        .label = "S",
        .value_range = .{
            .now = 1,
            .min = 0,
            .max = 2,
            .context = @ptrCast(&g_numeric_ctx),
            .set_value = setNumericValue,
        },
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, settable, makeEid(4), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(4)).?.can_set_numeric_value);

    // disabled 或 readonly 关掉 setter 通道
    var disabled_props = settable.behavior.interaction.a11y.?;
    disabled_props.disabled = true;
    settable.behavior.interaction.a11y = disabled_props;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, settable, makeEid(5), .NULL, 0, false, false));
    try testing.expect(!tree.get(makeEid(5)).?.can_set_numeric_value);
}

test "projectNode: actions 只按「角色 × 实际可路由的回调」宣告" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    // button + on_click → press；button 不是 toggle 角色 → toggle 关
    const btn = try makeBox();
    defer destroyTree(btn);
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "B" };
    btn.behavior.events.on_click = handlerRef();
    try testing.expect(projectNode(testing.allocator, &tree, &labels, btn, makeEid(1), .NULL, 0, false, false));
    const a1 = tree.get(makeEid(1)).?;
    try testing.expect(a1.actions.press);
    try testing.expect(!a1.actions.toggle);
    try testing.expect(!a1.actions.increment);

    // 无任何事件路由的 button：不得向 AT 宣告 press
    const dead = try makeBox();
    defer destroyTree(dead);
    dead.behavior.interaction.a11y = .{ .role = .button, .label = "D" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, dead, makeEid(2), .NULL, 0, false, false));
    try testing.expect(!tree.get(makeEid(2)).?.actions.press);

    // checkbox + on_click → toggle；radio/menuitemcheckbox/menuitemradio 同类
    const cb = try makeBox();
    defer destroyTree(cb);
    cb.behavior.interaction.a11y = .{ .role = .checkbox, .label = "C" };
    cb.behavior.events.on_click = handlerRef();
    try testing.expect(projectNode(testing.allocator, &tree, &labels, cb, makeEid(3), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(3)).?.actions.toggle);

    // slider + on_key_down → increment/decrement
    const slider = try makeBox();
    defer destroyTree(slider);
    slider.behavior.interaction.a11y = .{ .role = .slider, .label = "S" };
    slider.behavior.events.on_key_down = noopKeyHandler;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, slider, makeEid(4), .NULL, 0, false, false));
    const a4 = tree.get(makeEid(4)).?;
    try testing.expect(a4.actions.increment);
    try testing.expect(a4.actions.decrement);

    // slider 无键路由：不得宣告 increment（AT 会发出无人接的命令）
    const passive = try makeBox();
    defer destroyTree(passive);
    passive.behavior.interaction.a11y = .{ .role = .slider, .label = "P" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, passive, makeEid(5), .NULL, 0, false, false));
    const a5 = tree.get(makeEid(5)).?;
    try testing.expect(!a5.actions.increment);
    try testing.expect(!a5.actions.decrement);

    // spinbutton 同为 step 角色
    const spin = try makeBox();
    defer destroyTree(spin);
    spin.behavior.interaction.a11y = .{ .role = .spinbutton, .label = "N" };
    spin.behavior.events.on_event = noopEventHandler;
    try testing.expect(projectNode(testing.allocator, &tree, &labels, spin, makeEid(6), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(6)).?.actions.increment);
}

test "projectNode: editable_text 选区透传，can_set_* 受 disabled/readonly 门控" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const editableProps = types.A11yProps.EditableText{
        .context = @ptrCast(&g_edit_ctx),
        .selection_start = 2,
        .selection_end = 5,
        .caret = 4,
        .visible_start = 1,
        .visible_end = 9,
        .set_selection = setSelection,
    };

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{ .role = .textbox, .label = "T", .editable_text = editableProps };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    const e1 = tree.get(makeEid(1)).?.editable_text.?;
    try testing.expectEqual(@as(u32, 2), e1.selection_start);
    try testing.expectEqual(@as(u32, 5), e1.selection_end);
    try testing.expectEqual(@as(u32, 4), e1.caret);
    try testing.expectEqual(@as(u32, 1), e1.visible_start);
    try testing.expectEqual(@as(u32, 9), e1.visible_end);
    try testing.expect(e1.can_set_selection); // 未 disabled/readonly
    try testing.expect(!e1.can_set_value); // 未发布 set_value

    // 发布 set_value → can_set_value
    const n2 = try makeBox();
    defer destroyTree(n2);
    var with_setter = editableProps;
    with_setter.set_value = setEditTextValue;
    n2.behavior.interaction.a11y = .{ .role = .textbox, .label = "T2", .editable_text = with_setter };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n2, makeEid(2), .NULL, 0, false, false));
    const e2 = tree.get(makeEid(2)).?.editable_text.?;
    try testing.expect(e2.can_set_value);
    try testing.expect(e2.can_set_selection);

    // disabled / readonly 关掉两个通道
    const n3 = try makeBox();
    defer destroyTree(n3);
    var disabled = editableProps;
    disabled.set_value = setEditTextValue;
    n3.behavior.interaction.a11y = .{
        .role = .textbox,
        .label = "T3",
        .editable_text = disabled,
        .disabled = true,
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n3, makeEid(3), .NULL, 0, false, false));
    const e3 = tree.get(makeEid(3)).?.editable_text.?;
    try testing.expect(!e3.can_set_selection);
    try testing.expect(!e3.can_set_value);

    const n4 = try makeBox();
    defer destroyTree(n4);
    n4.behavior.interaction.a11y = .{
        .role = .textbox,
        .label = "T4",
        .editable_text = editableProps,
        .readonly = true,
    };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n4, makeEid(4), .NULL, 0, false, false));
    try testing.expect(!tree.get(makeEid(4)).?.editable_text.?.can_set_selection);

    // 未发布 editable_text（只有 textbox 角色）→ null，平台桥必须 fail closed
    const n5 = try makeBox();
    defer destroyTree(n5);
    n5.behavior.interaction.a11y = .{ .role = .textbox, .label = "T5" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n5, makeEid(5), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(5)).?.editable_text == null);
}

test "projectNode: active_descendant / 表格元数据 / orientation / frame" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const n = try makeBox();
    defer destroyTree(n);
    n.behavior.interaction.a11y = .{
        .role = .gridcell,
        .label = "cell",
        .active_descendant_element_id = 0x00000A05,
        .orientation = .horizontal,
        .sort_direction = .ascending,
        .level = 3,
        .row_index = 2,
        .row_span = 0, // 0 必须被夹到 1
        .column_index = 4,
        .column_span = 0,
    };
    n.setLayoutRect(.{ .x = 10, .y = 20, .w = 30, .h = 40 });
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n, makeEid(1), .NULL, 0, false, false));
    const a = tree.get(makeEid(1)).?;
    try testing.expect(a.active_descendant.eql(ElementId.fromRaw(0x00000A05)));
    try testing.expectEqual(a11y_tree_mod.Orientation.horizontal, a.orientation);
    try testing.expectEqual(a11y_tree_mod.SortDirection.ascending, a.sort_direction);
    try testing.expectEqual(@as(u16, 3), a.level);
    try testing.expectEqual(@as(u32, 2), a.row_index);
    try testing.expectEqual(@as(u32, 1), a.row_span);
    try testing.expectEqual(@as(u32, 4), a.column_index);
    try testing.expectEqual(@as(u32, 1), a.column_span);
    // globalRect：x/y 沿祖先链累加自身 rect（无父 ⇒ 就是自身 rect）
    try testing.expectEqual(@as(f32, 10), a.frame.x);
    try testing.expectEqual(@as(f32, 20), a.frame.y);
    try testing.expectEqual(@as(f32, 30), a.frame.width);
    try testing.expectEqual(@as(f32, 40), a.frame.height);

    // 嵌套一层：child 的 frame x/y = 祖先累加 + 自身（globalRect 语义）。
    // child 挂在 parent 下，销毁只走 parent 一份（递归）。
    const parent = try makeBox();
    defer destroyTree(parent);
    parent.setLayoutRect(.{ .x = 10, .y = 20, .w = 100, .h = 50 });
    const child = try makeBox();
    child.setLayoutRect(.{ .x = 5, .y = 6, .w = 7, .h = 8 });
    child.behavior.interaction.a11y = .{ .role = .button, .label = "c" };
    try parent.appendChild(testing.allocator, child);
    try testing.expect(projectNode(testing.allocator, &tree, &labels, child, makeEid(3), .NULL, 0, false, false));
    const nested = tree.get(makeEid(3)).?;
    try testing.expectEqual(@as(f32, 15), nested.frame.x);
    try testing.expectEqual(@as(f32, 26), nested.frame.y);
    try testing.expectEqual(@as(f32, 7), nested.frame.width);
    try testing.expectEqual(@as(f32, 8), nested.frame.height);

    // 0xFFFFFFFF 哨兵 → NULL（无 active descendant）
    const n2 = try makeBox();
    defer destroyTree(n2);
    n2.behavior.interaction.a11y = .{ .role = .combobox, .label = "cb" };
    try testing.expect(projectNode(testing.allocator, &tree, &labels, n2, makeEid(2), .NULL, 0, false, false));
    try testing.expect(tree.get(makeEid(2)).?.active_descendant.isNull());
}

// ── syncSubtree：层级 / 顺序 / hidden 传播 / 陈旧清扫 ─────────────────
//
// 这些用例需要 node.element_id_raw 非 INVALID（syncSubtree 靠它派生 eid）。
// 顺序刻意是：**先在全部 standalone（INVALID）状态下建好父子树，再统一赋
// element_id_raw**。appendChild / markLayoutDirty 在 INVALID 时对进程级全局
// 回调一律早退，于是这些测试不依赖「此刻 g_active_world 指向谁」。

test "syncSubtree: parent 是最近已投影祖先，sibling_index 只数已投影节点" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const root = try makeBox();
    defer destroyTree(root);

    // 未投影的纯视觉容器（无 a11y、不可聚焦）
    const plain = try makeBox();

    const first = try makeBox();
    first.behavior.interaction.a11y = .{ .role = .button, .label = "one" };

    const second = try makeBox();
    second.behavior.interaction.a11y = .{ .role = .button, .label = "two" };

    // first 的子树里再套一层未投影容器 + 一个合格节点
    const wrapper = try makeBox();
    const inner = try makeBox();
    inner.behavior.interaction.a11y = .{ .role = .button, .label = "inner" };

    try wrapper.appendChild(testing.allocator, inner);
    try first.appendChild(testing.allocator, wrapper);
    try root.appendChild(testing.allocator, plain);
    try root.appendChild(testing.allocator, first);
    try root.appendChild(testing.allocator, second);

    // 树建完再赋 element id（见本节头注释）
    root.element_id_raw = 0x00000001;
    plain.element_id_raw = 0x00000002;
    first.element_id_raw = 0x00000003;
    second.element_id_raw = 0x00000004;
    wrapper.element_id_raw = 0x00000005;
    inner.element_id_raw = 0x00000006;
    root.behavior.interaction.a11y = .{ .role = .group, .label = "root" };

    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, .{ .isFocused = neverFocused });

    try testing.expectEqual(@as(usize, 4), tree.count()); // root/one/two/inner
    const root_eid = ElementId.fromRaw(0x00000001);
    const one_eid = ElementId.fromRaw(0x00000003);
    const two_eid = ElementId.fromRaw(0x00000004);
    const inner_eid = ElementId.fromRaw(0x00000006);

    try testing.expect(tree.get(ElementId.fromRaw(0x00000002)) == null); // 未投影
    try testing.expect(tree.get(one_eid).?.parent.eql(root_eid));
    try testing.expect(tree.get(two_eid).?.parent.eql(root_eid));
    // plain 不占位：one 是 0，two 是 1
    try testing.expectEqual(@as(u32, 0), tree.get(one_eid).?.sibling_index);
    try testing.expectEqual(@as(u32, 1), tree.get(two_eid).?.sibling_index);
    try testing.expectEqual(@as(u32, 0), tree.get(root_eid).?.sibling_index);
    // wrapper 未投影 → inner 的 a11y parent 是 first，且在自己的兄弟序里从 0 起
    try testing.expect(tree.get(inner_eid).?.parent.eql(one_eid));
    try testing.expectEqual(@as(u32, 0), tree.get(inner_eid).?.sibling_index);
}

test "syncSubtree: 祖先 hidden 传播给整个子树（即使后代自身未声明）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const root = try makeBox();
    defer destroyTree(root);

    const child = try makeBox();
    child.behavior.interaction.a11y = .{ .role = .button, .label = "B" }; // 自身未声明 hidden

    const grandchild = try makeBox();
    grandchild.behavior.interaction.a11y = .{ .role = .button, .label = "C" };

    try child.appendChild(testing.allocator, grandchild);
    try root.appendChild(testing.allocator, child);

    root.element_id_raw = 0x00000011;
    child.element_id_raw = 0x00000012;
    grandchild.element_id_raw = 0x00000013;

    root.behavior.interaction.a11y = .{ .role = .group, .label = "G", .hidden = true };
    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, .{ .isFocused = neverFocused });

    try testing.expect(tree.get(ElementId.fromRaw(0x00000011)).?.state.hidden);
    try testing.expect(tree.get(ElementId.fromRaw(0x00000012)).?.state.hidden);
    try testing.expect(tree.get(ElementId.fromRaw(0x00000013)).?.state.hidden);

    // 对照：同一棵树去掉祖先 hidden，后代不再隐藏
    var tree2 = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree2.deinit();
    var labels2: LabelBuf = .{};
    defer labels2.deinit(testing.allocator);
    var counter2: u32 = 0;
    root.behavior.interaction.a11y = .{ .role = .group, .label = "G" };
    syncSubtree(testing.allocator, &tree2, &labels2, root, .NULL, &counter2, false, .{ .isFocused = neverFocused });
    try testing.expect(!tree2.get(ElementId.fromRaw(0x00000012)).?.state.hidden);
    try testing.expect(!tree2.get(ElementId.fromRaw(0x00000013)).?.state.hidden);
}

test "syncSubtree: 不再合格的节点被 remove（陈旧条目不能留给 VoiceOver）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const root = try makeBox();
    defer destroyTree(root);
    root.behavior.interaction.a11y = .{ .role = .button, .label = "B" };
    root.element_id_raw = 0x00000021;

    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, .{ .isFocused = neverFocused });
    try testing.expectEqual(@as(usize, 1), tree.count());

    // 节点失去 a11y props 与 focusable → 下一次同步必须把它摘掉
    root.behavior.interaction.a11y = null;
    root.behavior.interaction.focusable = false;
    var counter2: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter2, false, .{ .isFocused = neverFocused });
    try testing.expectEqual(@as(usize, 0), tree.count());
    try testing.expect(tree.get(ElementId.fromRaw(0x00000021)) == null);
}

test "syncSubtree: FocusProbe 决定 state.focused（Cx 侧只注入一次比较）" {
    var tree = a11y_tree_mod.AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var labels: LabelBuf = .{};
    defer labels.deinit(testing.allocator);

    const root = try makeBox();
    defer destroyTree(root);

    const a = try makeBox();
    a.behavior.interaction.a11y = .{ .role = .button, .label = "A" };

    const b = try makeBox();
    b.behavior.interaction.a11y = .{ .role = .button, .label = "B" };

    try root.appendChild(testing.allocator, a);
    try root.appendChild(testing.allocator, b);

    root.element_id_raw = 0x00000031;
    a.element_id_raw = 0x00000032;
    b.element_id_raw = 0x00000033;
    root.behavior.interaction.a11y = .{ .role = .group, .label = "G" };

    var counter: u32 = 0;
    syncSubtree(testing.allocator, &tree, &labels, root, .NULL, &counter, false, probeOf(a));

    try testing.expect(tree.get(ElementId.fromRaw(0x00000032)).?.state.focused);
    try testing.expect(!tree.get(ElementId.fromRaw(0x00000033)).?.state.focused);
}

fn neverFocused(_: ?*const anyopaque, _: *const Node) bool {
    return false;
}
