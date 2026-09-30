//! Accessibility Tree — Phase 6 真 a11y 投影
//!
//! 当前 zenit a11y 仅是单点 "notify focus/property change" 的桥；本模块建立
//! 完整的 AccessibilityTree —— 从 ElementTable + InteractionTable 投影出
//! 平台无关的 a11y node 树，供 NSAccessibility / IAccessible / AT-SPI 消费。
//!
//! 设计参照：
//! - macOS NSAccessibility 协议（accessibilityChildren / accessibilityHitTest:）
//! - W3C ARIA 1.2 / WAI-ARIA Authoring Practices
//! - Chrome AXTree / AXNode
//! - SwiftUI AccessibilityElement
//!
//! 历史债避免：
//! - **不**让 a11y 节点持 *Node（用 ElementId 跨帧安全）
//! - **不**每帧重建（reactive：节点 a11y 属性变化只 dirty 该 a11y node）
//! - **不**把 a11y 焦点和键盘焦点混淆（两套 focused 状态独立）

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("../core/element_id.zig");

pub const ElementId = element_id_mod.ElementId;

/// 完整 ARIA 风格角色（覆盖最常用 30+ 个；后续按需扩）
pub const Role = enum(u16) {
    none,
    application,
    /// 按钮（普通 / submit / reset）
    button,
    /// 复选框
    checkbox,
    /// 单选按钮
    radio,
    /// 单选组
    radiogroup,
    /// 滑块
    slider,
    /// 数字输入
    spinbutton,
    /// 进度条
    progressbar,
    /// 链接
    link,
    /// 文本框（单行 input）
    textbox,
    /// 多行文本区
    textarea,
    /// 搜索框
    searchbox,
    /// 下拉
    combobox,
    /// 列表
    listbox,
    listitem,
    /// 树
    tree,
    treeitem,
    /// 表
    grid,
    row,
    cell,
    columnheader,
    rowheader,
    /// 菜单
    menu,
    menubar,
    menuitem,
    menuitemcheckbox,
    menuitemradio,
    /// 对话
    dialog,
    alertdialog,
    /// 提示
    alert,
    status,
    log,
    /// 标签页
    tabs,
    tab,
    tabpanel,
    /// 工具提示
    tooltip,
    /// 容器/分组
    group,
    region,
    /// 文本类
    heading,
    paragraph,
    /// 图像
    image,
    /// 内容容器
    article,
    section,
    /// 导航
    navigation,
    /// 列表（非 listbox 的列表语义）
    list,
    /// 单元格层级关系
    separator,
    /// 表单
    form,
    /// 主区
    main,
    /// 横幅
    banner,
    contentinfo,
    /// 容器（无具体语义）
    generic,
};

/// 节点状态位（ARIA aria-* 属性）
pub const State = packed struct(u32) {
    /// aria-disabled
    disabled: bool = false,
    /// aria-hidden
    hidden: bool = false,
    /// aria-expanded
    expanded: bool = false,
    /// aria-selected
    selected: bool = false,
    /// aria-checked（checkbox/radio）
    checked: bool = false,
    /// aria-checked = mixed（部分选中）
    indeterminate: bool = false,
    /// aria-pressed（toggle button）
    pressed: bool = false,
    /// aria-required
    required: bool = false,
    /// aria-invalid
    invalid: bool = false,
    /// aria-readonly
    readonly: bool = false,
    /// aria-busy（动态加载中）
    busy: bool = false,
    /// aria-modal（dialog 模态）
    modal: bool = false,
    /// 是否当前 a11y 焦点
    focused: bool = false,
    /// 是否可获焦
    focusable: bool = false,
    /// aria-haspopup
    haspopup: bool = false,
    /// aria-multiline
    multiline: bool = false,
    /// aria-multiselectable
    multiselectable: bool = false,
    /// Secure editable controls must expose a secure native subrole while
    /// withholding their value/range contract.
    secure: bool = false,
    /// Distinguishes aria-expanded=false from an element which does not
    /// support expansion at all (notably leaf tree items).
    expanded_present: bool = false,
    _reserved: u13 = 0,
};

/// aria-live 区域级别
pub const LiveRegion = enum(u8) {
    off,
    polite,
    assertive,
};

/// Orientation exposed by controls whose interaction model has a primary axis.
/// `undefined` means the role's native default should be used.
pub const Orientation = enum(u8) {
    undefined,
    horizontal,
    vertical,
};

pub const SortDirection = enum(u8) {
    none,
    ascending,
    descending,
    other,
};

/// Window content coordinates, in logical points with a top-left origin.
/// Platform bridges are responsible for projecting this into screen space.
pub const Frame = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn isUsable(self: Frame) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y) and
            std.math.isFinite(self.width) and std.math.isFinite(self.height) and
            self.width >= 0 and self.height >= 0;
    }
};

/// Actions which the current retained node can actually route.  These are not
/// inferred merely from the role: a slider without a live key/event handler
/// must not advertise increment/decrement to assistive technology.
pub const Actions = packed struct(u8) {
    press: bool = false,
    toggle: bool = false,
    increment: bool = false,
    decrement: bool = false,
    _reserved: u4 = 0,
};

/// Read/write text contract. Offsets are UTF-8 byte offsets, matching Zenit's
/// canonical editing model; native bridges convert them to platform units.
pub const EditableText = struct {
    selection_start: u32 = 0,
    selection_end: u32 = 0,
    caret: u32 = 0,
    visible_start: u32 = 0,
    visible_end: u32 = std.math.maxInt(u32),
    can_set_selection: bool = false,
    can_set_value: bool = false,
};

/// 单个 a11y 节点
pub const A11yNode = struct {
    /// 投影自哪个 element
    element: ElementId,
    /// 父 a11y 节点（不一定与 ElementTable 父相同：a11y tree 可裁剪）
    parent: ElementId = ElementId.NULL,
    role: Role = .none,
    state: State = .{},
    live: LiveRegion = .off,
    /// 标签 hash（实际字符串由 caller 通过 label_resolver 取，避免在此层持有 []const u8）
    label_hash: u64 = 0,
    /// 描述（aria-describedby 引用结果）hash
    description_hash: u64 = 0,
    /// Placeholder and stable application identifier are independent from the
    /// accessible name; VoiceOver uses both through dedicated AX attributes.
    placeholder_hash: u64 = 0,
    identifier_hash: u64 = 0,
    /// 数值（slider/progress/spinbutton）
    value_now: f32 = 0,
    value_min: f32 = 0,
    value_max: f32 = 0,
    numeric_value_present: bool = false,
    /// Whether the source node published a callable numeric setter. Native
    /// selector gating must be node-specific rather than inferred from the
    /// window-wide interaction router.
    can_set_numeric_value: bool = false,
    /// Current AXValue text.
    text_hash: u64 = 0,
    /// Announcement payload is independent from AXValue. Alerts and status
    /// regions commonly derive this from their label or subtree text while
    /// exposing no value attribute.
    live_text_hash: u64 = 0,
    /// 在父中的索引（用于 NSAccessibility children 顺序）
    sibling_index: u32 = 0,
    /// aria-activedescendant — 给 combobox/listbox 这种容器
    /// 自身保持 focus，但通过 active_descendant 告诉 AT 当前哪个 child 是活动项。
    /// ElementId.NULL = 无 active descendant (default)
    active_descendant: ElementId = ElementId.NULL,
    /// Current layout-space geometry and callable behavior capabilities.
    frame: Frame = .{},
    actions: Actions = .{},
    /// null means the node does not publish the complete editable-text
    /// contract. Platform bridges must then fail closed even for textbox roles.
    editable_text: ?EditableText = null,
    orientation: Orientation = .undefined,
    sort_direction: SortDirection = .none,
    /// ARIA heading/tree/table metadata. Levels are 1-based; zero means
    /// unspecified. Row/column indices are zero-based for AppKit NSRange.
    level: u16 = 0,
    row_index: u32 = 0,
    row_span: u32 = 1,
    column_index: u32 = 0,
    column_span: u32 = 1,
};

pub fn announcementHash(node: A11yNode) u64 {
    return if (node.live_text_hash != 0) node.live_text_hash else node.text_hash;
}

/// Tree dirty flags（reactive consumer：哪些 a11y node 本帧需重投影）
pub const A11yDirtyFlag = packed struct(u16) {
    role_changed: bool = false,
    state_changed: bool = false,
    label_changed: bool = false,
    value_changed: bool = false,
    /// live region 内容变 → 需要 announce
    live_announce: bool = false,
    /// 焦点变化 → 需要平台通知
    focus_changed: bool = false,
    structure_changed: bool = false,
    /// active_descendant 变化 → 需要 NSAccessibility
    /// AXSelectedChildren 重投
    active_descendant_changed: bool = false,
    /// Geometry is a first-class AX attribute and must invalidate cached
    /// positions even when no semantic property changed.
    geometry_changed: bool = false,
    /// Text selection changes use a distinct AppKit notification from value
    /// changes. Keeping the bit separate prevents noisy full-value announces.
    selection_changed: bool = false,
    _reserved: u6 = 0,
};

/// Structural dirty state must survive node removal. A dirty map containing
/// flags alone cannot recover the former parent once `nodes[index]` is null,
/// which used to make removal notifications disappear in the router.
pub const StructureChange = struct {
    had_old: bool = false,
    old_parent: ElementId = ElementId.NULL,
    old_hidden: bool = false,
    has_new: bool = false,
    new_parent: ElementId = ElementId.NULL,
    new_hidden: bool = false,
};

pub const AccessibilityTree = struct {
    allocator: std.mem.Allocator,
    /// dense by ElementId.index
    nodes: std.ArrayListUnmanaged(?A11yNode),
    /// Dense projection mark parallel to `nodes`. A render projection is a
    /// replacement snapshot; entries not observed in the current epoch must
    /// be removed instead of leaking into later screens.
    seen_epochs: std.ArrayListUnmanaged(u64),
    projection_epoch: u64 = 0,
    projection_active: bool = false,
    /// 待平台通知的 dirty 队列（element id → flags）
    dirty: std.AutoHashMapUnmanaged(u32, A11yDirtyFlag),
    /// Parent snapshots for structural changes, keyed by the generational raw
    /// handle just like `dirty`.
    structure_changes: std.AutoHashMapUnmanaged(u32, StructureChange),
    /// 当前 a11y focused element
    focused: ElementId = ElementId.NULL,

    pub fn init(allocator: std.mem.Allocator) AccessibilityTree {
        return .{
            .allocator = allocator,
            .nodes = .{},
            .seen_epochs = .{},
            .dirty = .{},
            .structure_changes = .{},
        };
    }

    pub fn deinit(self: *AccessibilityTree) void {
        self.nodes.deinit(self.allocator);
        self.seen_epochs.deinit(self.allocator);
        self.dirty.deinit(self.allocator);
        self.structure_changes.deinit(self.allocator);
        self.* = undefined;
    }

    /// 投影/更新一个 a11y node。
    /// dirty flag 自动累积；caller 在帧末调 drainDirty 把变化推到平台。
    pub fn upsert(self: *AccessibilityTree, incoming: A11yNode) !void {
        var node = incoming;
        if (node.state.hidden or node.state.disabled) {
            node.state.focused = false;
        }
        const idx = node.element.index;
        while (self.nodes.items.len <= idx) {
            try self.nodes.append(self.allocator, null);
        }
        while (self.seen_epochs.items.len <= idx) {
            try self.seen_epochs.append(self.allocator, 0);
        }
        if (self.projection_active) self.seen_epochs.items[idx] = self.projection_epoch;
        const old = self.nodes.items[idx];
        var flag: A11yDirtyFlag = .{};
        if (old == null or !old.?.element.eql(node.element)) {
            flag.structure_changed = true;
            flag.focus_changed = node.state.focused;
            flag.live_announce = !node.state.hidden and node.live != .off and announcementHash(node) != 0;
            if (old) |stale| {
                try self.recordStructureChange(stale.element, .{
                    .had_old = true,
                    .old_parent = stale.parent,
                    .old_hidden = stale.state.hidden,
                });
                try self.markDirty(stale.element, .{ .structure_changed = true });
                if (self.focused.eql(stale.element)) {
                    self.focused = ElementId.NULL;
                    try self.markDirty(stale.element, .{ .focus_changed = true });
                }
            }
            try self.recordStructureChange(node.element, .{
                .has_new = true,
                .new_parent = node.parent,
                .new_hidden = node.state.hidden,
            });
        } else {
            const o = old.?;
            if (o.role != node.role) flag.role_changed = true;
            const o_state: u32 = @bitCast(o.state);
            const n_state: u32 = @bitCast(node.state);
            const focused_mask: u32 = @as(u32, 1) << 12;
            if ((o_state & ~focused_mask) != (n_state & ~focused_mask)) flag.state_changed = true;
            if (o.label_hash != node.label_hash or
                o.description_hash != node.description_hash or
                o.placeholder_hash != node.placeholder_hash) flag.label_changed = true;
            if (o.value_now != node.value_now or o.value_min != node.value_min or
                o.value_max != node.value_max or
                o.numeric_value_present != node.numeric_value_present or
                o.text_hash != node.text_hash) flag.value_changed = true;
            if ((o.editable_text == null) != (node.editable_text == null) or
                o.can_set_numeric_value != node.can_set_numeric_value or
                !std.meta.eql(o.actions, node.actions)) flag.state_changed = true;
            if (o.editable_text != null and node.editable_text != null and
                (o.editable_text.?.selection_start != node.editable_text.?.selection_start or
                    o.editable_text.?.selection_end != node.editable_text.?.selection_end or
                    o.editable_text.?.caret != node.editable_text.?.caret))
            {
                flag.selection_changed = true;
            }
            if (o.editable_text != null and node.editable_text != null) {
                const old_editable = o.editable_text.?;
                const new_editable = node.editable_text.?;
                if (old_editable.can_set_selection != new_editable.can_set_selection or
                    old_editable.can_set_value != new_editable.can_set_value) flag.state_changed = true;
                if (old_editable.visible_start != new_editable.visible_start or
                    old_editable.visible_end != new_editable.visible_end) flag.geometry_changed = true;
            }
            if ((announcementHash(o) != announcementHash(node) or o.live != node.live) and
                !node.state.hidden and node.live != .off and announcementHash(node) != 0) flag.live_announce = true;
            if (o.state.focused != node.state.focused) flag.focus_changed = true;
            if (!o.active_descendant.eql(node.active_descendant)) flag.active_descendant_changed = true;
            if (!std.meta.eql(o.frame, node.frame)) flag.geometry_changed = true;
            if (!o.parent.eql(node.parent) or o.sibling_index != node.sibling_index or
                o.state.hidden != node.state.hidden)
            {
                flag.structure_changed = true;
                try self.recordStructureChange(node.element, .{
                    .had_old = true,
                    .old_parent = o.parent,
                    .old_hidden = o.state.hidden,
                    .has_new = true,
                    .new_parent = node.parent,
                    .new_hidden = node.state.hidden,
                });
            }
            if (o.identifier_hash != node.identifier_hash or
                o.orientation != node.orientation or
                o.sort_direction != node.sort_direction or
                o.level != node.level or o.row_index != node.row_index or
                o.row_span != node.row_span or o.column_index != node.column_index or
                o.column_span != node.column_span)
            {
                flag.state_changed = true;
            }
        }
        self.nodes.items[idx] = node;
        if (@as(u16, @bitCast(flag)) != 0) {
            try self.markDirty(node.element, flag);
        }
        if (node.state.focused) {
            if (!self.focused.isNull() and !self.focused.eql(node.element)) {
                const previous = self.focused;
                if (previous.index < self.nodes.items.len) {
                    if (self.nodes.items[previous.index]) |*previous_node| {
                        if (previous_node.element.eql(previous) and previous_node.state.focused) {
                            previous_node.state.focused = false;
                            try self.markDirty(previous, .{ .focus_changed = true });
                        }
                    }
                }
            }
            self.focused = node.element;
        } else if (self.focused.eql(node.element)) {
            self.focused = ElementId.NULL;
        }
    }

    /// Begin a full retained-tree projection. Pair with `finishProjection`.
    pub fn beginProjection(self: *AccessibilityTree) void {
        std.debug.assert(!self.projection_active);
        self.projection_epoch +%= 1;
        if (self.projection_epoch == 0) {
            @memset(self.seen_epochs.items, 0);
            self.projection_epoch = 1;
        }
        self.projection_active = true;
    }

    /// Remove every entry which was not upserted since `beginProjection`.
    /// This preserves node-level diffs while making screen/root replacement
    /// semantics exact.
    pub fn finishProjection(self: *AccessibilityTree) !void {
        if (!self.projection_active) return;
        const epoch = self.projection_epoch;
        for (self.nodes.items, 0..) |maybe, idx| {
            const node = maybe orelse continue;
            const seen = idx < self.seen_epochs.items.len and self.seen_epochs.items[idx] == epoch;
            if (!seen) try self.remove(node.element);
        }
        self.projection_active = false;
    }

    pub fn remove(self: *AccessibilityTree, id: ElementId) !void {
        if (id.isNull() or id.index >= self.nodes.items.len) return;
        const existing = self.nodes.items[id.index] orelse return;
        // A stale generation must not remove the live element which reused the
        // same dense index.
        if (!existing.element.eql(id)) return;
        self.nodes.items[id.index] = null;
        try self.recordStructureChange(id, .{
            .had_old = true,
            .old_parent = existing.parent,
            .old_hidden = existing.state.hidden,
        });
        try self.markDirty(id, .{ .structure_changed = true });
        if (self.focused.eql(id)) {
            self.focused = ElementId.NULL;
            try self.markDirty(id, .{ .focus_changed = true });
        }
    }

    pub fn get(self: *const AccessibilityTree, id: ElementId) ?A11yNode {
        if (id.isNull() or id.index >= self.nodes.items.len) return null;
        const node = self.nodes.items[id.index] orelse return null;
        if (!node.element.eql(id)) return null;
        return node;
    }

    pub fn count(self: *const AccessibilityTree) usize {
        var n: usize = 0;
        for (self.nodes.items) |maybe| {
            if (maybe != null) n += 1;
        }
        return n;
    }

    pub fn markDirty(self: *AccessibilityTree, id: ElementId, flag: A11yDirtyFlag) !void {
        if (id.isNull()) return;
        const gop = try self.dirty.getOrPut(self.allocator, id.raw());
        if (!gop.found_existing) {
            gop.value_ptr.* = flag;
        } else {
            const a: u16 = @bitCast(gop.value_ptr.*);
            const b: u16 = @bitCast(flag);
            gop.value_ptr.* = @bitCast(a | b);
        }
    }

    fn recordStructureChange(self: *AccessibilityTree, id: ElementId, change: StructureChange) !void {
        if (id.isNull()) return;
        const gop = try self.structure_changes.getOrPut(self.allocator, id.raw());
        if (!gop.found_existing) {
            gop.value_ptr.* = change;
            return;
        }
        // Preserve the earliest old location and the latest new location when
        // a node is moved repeatedly before frame-end.
        if (!gop.value_ptr.had_old and change.had_old) {
            gop.value_ptr.had_old = true;
            gop.value_ptr.old_parent = change.old_parent;
            gop.value_ptr.old_hidden = change.old_hidden;
        }
        if (change.has_new) {
            gop.value_ptr.has_new = true;
            gop.value_ptr.new_parent = change.new_parent;
            gop.value_ptr.new_hidden = change.new_hidden;
        } else if (change.had_old) {
            gop.value_ptr.has_new = false;
        }
    }

    pub fn structureChange(self: *const AccessibilityTree, id: ElementId) ?StructureChange {
        return self.structure_changes.get(id.raw());
    }

    /// 平台 bridge 在帧末调用：消费 dirty 队列。
    /// callback 可以在每个 entry 调用平台 API（NSAccessibilityPostNotification 等）。
    pub fn drainDirty(
        self: *AccessibilityTree,
        ctx: *anyopaque,
        cb: *const fn (ctx: *anyopaque, id: ElementId, flag: A11yDirtyFlag) void,
    ) void {
        var iter = self.dirty.iterator();
        while (iter.next()) |entry| {
            const id = ElementId.fromRaw(entry.key_ptr.*);
            cb(ctx, id, entry.value_ptr.*);
        }
        self.dirty.clearRetainingCapacity();
        self.structure_changes.clearRetainingCapacity();
    }

    /// 返回 element 的 a11y children（按 sibling_index 排序）。
    /// 简化实现：扫描所有节点找 parent 匹配；O(n)。后续按需加索引。
    pub fn children(
        self: *const AccessibilityTree,
        parent: ElementId,
        out: *std.ArrayListUnmanaged(ElementId),
        allocator: std.mem.Allocator,
    ) !void {
        for (self.nodes.items) |maybe| {
            if (maybe) |n| {
                if (n.parent.eql(parent) and !n.state.hidden) {
                    try out.append(allocator, n.element);
                }
            }
        }
        // Keep this helper's documented order identical to the native pull
        // bridge. Stable raw-handle tie-breaking makes malformed duplicate
        // sibling indices deterministic instead of dense-slot dependent.
        var i: usize = 1;
        while (i < out.items.len) : (i += 1) {
            var j = i;
            while (j > 0) : (j -= 1) {
                const left = self.get(out.items[j - 1]) orelse break;
                const right = self.get(out.items[j]) orelse break;
                const right_before = right.sibling_index < left.sibling_index or
                    (right.sibling_index == left.sibling_index and right.element.raw() < left.element.raw());
                if (!right_before) break;
                std.mem.swap(ElementId, &out.items[j - 1], &out.items[j]);
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AccessibilityTree: upsert / get / count" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id1: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{
        .element = id1,
        .role = .button,
        .state = .{ .focusable = true },
        .label_hash = 0x12345,
    });

    const got = tree.get(id1).?;
    try testing.expectEqual(Role.button, got.role);
    try testing.expectEqual(@as(u64, 0x12345), got.label_hash);
    try testing.expectEqual(@as(usize, 1), tree.count());
}

test "AccessibilityTree: upsert detects changes and marks dirty" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{ .element = id, .role = .button });

    // 第一次插入 → structure_changed
    try testing.expect(tree.dirty.get(id.raw()).?.structure_changed);

    // 清队列
    tree.dirty.clearRetainingCapacity();

    // 修改 role → role_changed dirty
    try tree.upsert(.{ .element = id, .role = .checkbox });
    try testing.expect(tree.dirty.get(id.raw()).?.role_changed);
}

test "AccessibilityTree: projection removes nodes absent from the next root" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const old_only: ElementId = .{ .index = 1, .generation = 0 };
    const retained: ElementId = .{ .index = 2, .generation = 0 };
    tree.beginProjection();
    try tree.upsert(.{ .element = old_only, .role = .button });
    try tree.upsert(.{ .element = retained, .role = .checkbox });
    try tree.finishProjection();
    tree.dirty.clearRetainingCapacity();

    tree.beginProjection();
    try tree.upsert(.{ .element = retained, .role = .checkbox });
    try tree.finishProjection();

    try testing.expect(tree.get(old_only) == null);
    try testing.expect(tree.get(retained) != null);
    try testing.expect(tree.dirty.get(old_only.raw()).?.structure_changed);
}

test "AccessibilityTree: state change tracked" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{ .element = id, .role = .checkbox, .state = .{} });
    tree.dirty.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .checkbox, .state = .{ .checked = true } });
    try testing.expect(tree.dirty.get(id.raw()).?.state_changed);
}

test "AccessibilityTree: live region announce on text change" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{ .element = id, .role = .status, .live = .polite, .text_hash = 100 });
    tree.dirty.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .status, .live = .polite, .text_hash = 200 });
    try testing.expect(tree.dirty.get(id.raw()).?.live_announce);
}

test "AccessibilityTree: a populated live region announces when inserted or enabled" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const inserted: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{ .element = inserted, .role = .alert, .live = .assertive, .text_hash = 123 });
    try testing.expect(tree.dirty.get(inserted.raw()).?.live_announce);

    const enabled: ElementId = .{ .index = 2, .generation = 0 };
    try tree.upsert(.{ .element = enabled, .role = .status, .text_hash = 456 });
    tree.dirty.clearRetainingCapacity();
    try tree.upsert(.{ .element = enabled, .role = .status, .live = .polite, .text_hash = 456 });
    try testing.expect(tree.dirty.get(enabled.raw()).?.live_announce);
}

test "AccessibilityTree: active_descendant diff sets flag" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const container: ElementId = .{ .index = 0, .generation = 0 };
    const opt_a: ElementId = .{ .index = 1, .generation = 0 };
    const opt_b: ElementId = .{ .index = 2, .generation = 0 };

    try tree.upsert(.{ .element = container, .role = .combobox });
    // 第一次进入 dirty 已 drain（这里直接清掉再做 diff）
    tree.dirty.clearRetainingCapacity();

    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_a });
    {
        const flag = tree.dirty.get(container.index).?;
        try testing.expect(flag.active_descendant_changed);
    }
    tree.dirty.clearRetainingCapacity();

    // 写入相同值 → 不应再 dirty
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_a });
    try testing.expect(tree.dirty.get(container.index) == null);

    // 切到 B → 重新 dirty
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_b });
    {
        const flag = tree.dirty.get(container.index).?;
        try testing.expect(flag.active_descendant_changed);
    }
}

test "AccessibilityTree: focused tracked" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const id: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{ .element = id, .role = .button, .state = .{ .focused = true, .focusable = true } });
    try testing.expect(tree.focused.eql(id));
    try testing.expect(tree.dirty.get(id.raw()).?.focus_changed);
}

test "AccessibilityTree: generation replacement cannot retain a stale focus handle" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const old: ElementId = .{ .index = 3, .generation = 1 };
    const replacement: ElementId = .{ .index = 3, .generation = 2 };
    try tree.upsert(.{ .element = old, .role = .button, .state = .{ .focused = true, .focusable = true } });
    tree.dirty.clearRetainingCapacity();
    tree.structure_changes.clearRetainingCapacity();

    try tree.upsert(.{ .element = replacement, .role = .button });
    try testing.expect(tree.focused.isNull());
    try testing.expect(tree.dirty.get(old.raw()).?.focus_changed);
    try testing.expect(tree.get(old) == null);
    try testing.expect(tree.get(replacement) != null);
}

test "AccessibilityTree: removal retains former parent until dirty drain" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const parent: ElementId = .{ .index = 1, .generation = 0 };
    const child: ElementId = .{ .index = 2, .generation = 0 };
    try tree.upsert(.{ .element = parent, .role = .group });
    try tree.upsert(.{ .element = child, .parent = parent, .role = .button });
    tree.dirty.clearRetainingCapacity();
    tree.structure_changes.clearRetainingCapacity();

    try tree.remove(child);
    try testing.expect(tree.get(child) == null);
    const change = tree.structureChange(child).?;
    try testing.expect(change.had_old);
    try testing.expect(change.old_parent.eql(parent));
    try testing.expect(!change.has_new);
}

test "AccessibilityTree: drainDirty visits all entries" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    try tree.upsert(.{ .element = .{ .index = 1, .generation = 0 }, .role = .button });
    try tree.upsert(.{ .element = .{ .index = 2, .generation = 0 }, .role = .checkbox });

    const Counter = struct {
        n: u32 = 0,
        fn cb(ctx: *anyopaque, id: ElementId, flag: A11yDirtyFlag) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.n += 1;
            _ = id;
            _ = flag;
        }
    };
    var counter = Counter{};
    tree.drainDirty(&counter, &Counter.cb);
    try testing.expectEqual(@as(u32, 2), counter.n);
    try testing.expectEqual(@as(u32, 0), tree.dirty.count());
}

test "AccessibilityTree: children lookup" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();

    const root: ElementId = .{ .index = 0, .generation = 0 };
    const c1: ElementId = .{ .index = 1, .generation = 0 };
    const c2: ElementId = .{ .index = 2, .generation = 0 };

    try tree.upsert(.{ .element = root, .role = .group });
    try tree.upsert(.{ .element = c1, .parent = root, .role = .button, .sibling_index = 9 });
    try tree.upsert(.{ .element = c2, .parent = root, .role = .button, .sibling_index = 1 });

    var out: std.ArrayListUnmanaged(ElementId) = .{};
    defer out.deinit(testing.allocator);
    try tree.children(root, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(out.items[0].eql(c2));
    try testing.expect(out.items[1].eql(c1));
}

test "State / A11yDirtyFlag are properly sized" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(State));
    try testing.expectEqual(@as(usize, 2), @sizeOf(A11yDirtyFlag));
}
