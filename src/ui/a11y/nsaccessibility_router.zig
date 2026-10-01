//! NSAccessibility Router, Phase 6 a11y_tree -> 平台 bridge 路由
//!
//! 把 AccessibilityTree 的 dirty 队列转换为平台 bridge 调用：
//! - role/state/value 变化 -> bridge.notifyPropertyChange
//! - focus 变化 -> bridge.notifyFocusChange
//! - live region announce -> bridge.announceText
//! - structure 变化 -> bridge.notifyChildrenChanged（重新拉 children）
//!
//! ObjC 端已实装（不是 stub）：native/macos/window_bridge.m 的
//! ZenitA11yElement 实现了完整 NSAccessibility 协议，roles/subroles、
//! value/min/max、focus 读写、hit test、table 协议（rows/columns/cells/
//! header）、AXTextArea 全套（selectedTextRange / frameForRange /
//! rangeForLine / insertionPointLineNumber），含 UTF-8↔UTF-16 偏移换算。
//! 本 router 与 a11y_macos_bridge 已接进生产（src/ui/core.zig / ui.zig）。
//! 仍缺：attributed run（bold/link/拼写）播报、AXCustomRotor、
//! press/increment/decrement 之外的自定义 action，以及真 VoiceOver 验收
//! （尚未进行）。

const std = @import("std");
const testing = std.testing;
const tree_mod = @import("tree.zig");
const element_id_mod = @import("../core/element_id.zig");

pub const ElementId = element_id_mod.ElementId;
pub const A11yNode = tree_mod.A11yNode;
pub const A11yDirtyFlag = tree_mod.A11yDirtyFlag;
pub const AccessibilityTree = tree_mod.AccessibilityTree;

/// Router 接收 dirty 通知，调适当的 platform bridge。
/// platform bridge 是 trait 风格 vtable，便于不同平台实现 + 单测桩。
pub const PlatformBridge = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        notify_property: *const fn (ctx: *anyopaque, id: ElementId, node: A11yNode, flag: A11yDirtyFlag) void,
        /// `node == null` means focus left the retained Zenit tree. Platforms
        /// should move accessibility focus back to the host/window, not retain
        /// a stale virtual element.
        notify_focus: *const fn (ctx: *anyopaque, id: ElementId, node: ?A11yNode) void,
        notify_children_changed: *const fn (ctx: *anyopaque, id: ElementId) void,
        announce: *const fn (ctx: *anyopaque, id: ElementId, text_hash: u64, live: tree_mod.LiveRegion) void,
        /// aria-activedescendant 变化 -> 平台投 AXSelectedChildren
        /// (NSAccessibility) 或 IA2_STATE_ACTIVE (Windows IA2)。可选: null -> 跳过。
        notify_active_descendant: ?*const fn (ctx: *anyopaque, container: ElementId, active: ElementId) void = null,
    };

    pub fn notifyProperty(self: PlatformBridge, id: ElementId, node: A11yNode, flag: A11yDirtyFlag) void {
        self.vtable.notify_property(self.ctx, id, node, flag);
    }
    pub fn notifyFocus(self: PlatformBridge, id: ElementId, node: ?A11yNode) void {
        self.vtable.notify_focus(self.ctx, id, node);
    }
    pub fn notifyChildrenChanged(self: PlatformBridge, id: ElementId) void {
        self.vtable.notify_children_changed(self.ctx, id);
    }
    pub fn announce(self: PlatformBridge, id: ElementId, text_hash: u64, live: tree_mod.LiveRegion) void {
        self.vtable.announce(self.ctx, id, text_hash, live);
    }
    pub fn notifyActiveDescendant(self: PlatformBridge, container: ElementId, active: ElementId) void {
        if (self.vtable.notify_active_descendant) |cb| cb(self.ctx, container, active);
    }
};

/// 从 a11y tree 把 dirty 队列推到平台。
pub fn flushToBridge(
    tree: *AccessibilityTree,
    bridge: PlatformBridge,
) void {
    const Ctx = struct {
        tree: *AccessibilityTree,
        bridge: PlatformBridge,
        focus_changed: bool = false,
    };
    var ctx = Ctx{ .tree = tree, .bridge = bridge };
    tree.drainDirty(&ctx, &dispatch);
    // Coalesce old-focus/new-focus records into one notification for the final
    // retained state. Hash-map iteration order must never decide AX focus.
    if (ctx.focus_changed) {
        const focused = tree.focused;
        ctx.bridge.notifyFocus(focused, tree.get(focused));
    }
}

fn dispatch(ctx_ptr: *anyopaque, id: ElementId, flag: A11yDirtyFlag) void {
    const Ctx = struct {
        tree: *AccessibilityTree,
        bridge: PlatformBridge,
        focus_changed: bool = false,
    };
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));

    if (flag.structure_changed) {
        if (ctx.tree.structureChange(id)) |change| {
            if (change.had_old and !change.old_hidden) {
                ctx.bridge.notifyChildrenChanged(change.old_parent);
            }
            if (change.has_new and !change.new_hidden and
                (!change.had_old or change.old_hidden or !change.old_parent.eql(change.new_parent)))
            {
                ctx.bridge.notifyChildrenChanged(change.new_parent);
            }
            // A same-parent reorder is already covered by the old-parent
            // notification above; do not post the identical layout change
            // twice.
        }
    }
    const node = ctx.tree.get(id);
    if (node != null and (flag.role_changed or flag.state_changed or flag.label_changed or
        flag.value_changed or flag.geometry_changed or flag.selection_changed))
    {
        ctx.bridge.notifyProperty(id, node.?, flag);
    }
    if (flag.focus_changed) {
        ctx.focus_changed = true;
    }
    if (flag.live_announce and node != null) {
        ctx.bridge.announce(id, tree_mod.announcementHash(node.?), node.?.live);
    }
    if (flag.active_descendant_changed and node != null) {
        ctx.bridge.notifyActiveDescendant(id, node.?.active_descendant);
    }
}

// ============================================================================
// Tests
// ============================================================================

const TestBridge = struct {
    property_calls: std.ArrayListUnmanaged(ElementId) = .{},
    focus_calls: std.ArrayListUnmanaged(ElementId) = .{},
    children_calls: std.ArrayListUnmanaged(ElementId) = .{},
    announce_calls: std.ArrayListUnmanaged(u64) = .{},
    active_desc_calls: std.ArrayListUnmanaged(struct { container: ElementId, active: ElementId }) = .{},
    allocator: std.mem.Allocator,

    fn vtable() *const PlatformBridge.VTable {
        const Static = struct {
            const v = PlatformBridge.VTable{
                .notify_property = TestBridge.notifyProperty,
                .notify_focus = TestBridge.notifyFocus,
                .notify_children_changed = TestBridge.notifyChildrenChanged,
                .announce = TestBridge.announce,
                .notify_active_descendant = TestBridge.notifyActiveDescendant,
            };
        };
        return &Static.v;
    }

    fn bridge(self: *TestBridge) PlatformBridge {
        return .{ .ctx = self, .vtable = vtable() };
    }

    fn notifyProperty(ctx: *anyopaque, id: ElementId, node: A11yNode, flag: A11yDirtyFlag) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.property_calls.append(self.allocator, id) catch {};
        _ = node;
        _ = flag;
    }
    fn notifyFocus(ctx: *anyopaque, id: ElementId, node: ?A11yNode) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.focus_calls.append(self.allocator, id) catch {};
        _ = node;
    }
    fn notifyChildrenChanged(ctx: *anyopaque, id: ElementId) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.children_calls.append(self.allocator, id) catch {};
    }
    fn announce(ctx: *anyopaque, id: ElementId, text_hash: u64, live: tree_mod.LiveRegion) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.announce_calls.append(self.allocator, text_hash) catch {};
        _ = id;
        _ = live;
    }
    fn notifyActiveDescendant(ctx: *anyopaque, container: ElementId, active: ElementId) void {
        const self: *TestBridge = @ptrCast(@alignCast(ctx));
        self.active_desc_calls.append(self.allocator, .{ .container = container, .active = active }) catch {};
    }

    fn deinit(self: *TestBridge) void {
        self.property_calls.deinit(self.allocator);
        self.focus_calls.deinit(self.allocator);
        self.children_calls.deinit(self.allocator);
        self.announce_calls.deinit(self.allocator);
        self.active_desc_calls.deinit(self.allocator);
    }
};

test "router: structure_changed triggers notifyChildrenChanged on parent" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const parent: ElementId = .{ .index = 0, .generation = 0 };
    const child: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{ .element = parent, .role = .group });
    try tree.upsert(.{ .element = child, .parent = parent, .role = .button });

    flushToBridge(&tree, bridge.bridge());

    try testing.expect(bridge.children_calls.items.len >= 1);
}

test "router: state_changed → notifyProperty" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try tree.upsert(.{ .element = id, .role = .checkbox });
    flushToBridge(&tree, bridge.bridge());
    bridge.property_calls.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .checkbox, .state = .{ .checked = true } });
    flushToBridge(&tree, bridge.bridge());

    try testing.expectEqual(@as(usize, 1), bridge.property_calls.items.len);
}

test "router: focus_changed + focused=true → notifyFocus" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try tree.upsert(.{ .element = id, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    bridge.focus_calls.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .button, .state = .{ .focused = true, .focusable = true } });
    flushToBridge(&tree, bridge.bridge());

    try testing.expectEqual(@as(usize, 1), bridge.focus_calls.items.len);
}

test "router: removed children and roots invalidate their former containers" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const root: ElementId = .{ .index = 0, .generation = 0 };
    const child: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{ .element = root, .role = .group });
    try tree.upsert(.{ .element = child, .parent = root, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    bridge.children_calls.clearRetainingCapacity();

    try tree.remove(child);
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.children_calls.items.len);
    try testing.expect(bridge.children_calls.items[0].eql(root));

    bridge.children_calls.clearRetainingCapacity();
    try tree.remove(root);
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.children_calls.items.len);
    try testing.expect(bridge.children_calls.items[0].isNull());
}

test "router: reparent and reorder invalidate every affected container" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const a: ElementId = .{ .index = 0, .generation = 0 };
    const b: ElementId = .{ .index = 1, .generation = 0 };
    const child: ElementId = .{ .index = 2, .generation = 0 };
    try tree.upsert(.{ .element = a, .role = .group });
    try tree.upsert(.{ .element = b, .role = .group });
    try tree.upsert(.{ .element = child, .parent = a, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    bridge.children_calls.clearRetainingCapacity();

    try tree.upsert(.{ .element = child, .parent = b, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 2), bridge.children_calls.items.len);
    var saw_a = false;
    var saw_b = false;
    for (bridge.children_calls.items) |id| {
        saw_a = saw_a or id.eql(a);
        saw_b = saw_b or id.eql(b);
    }
    try testing.expect(saw_a and saw_b);

    bridge.children_calls.clearRetainingCapacity();
    try tree.upsert(.{ .element = child, .parent = b, .role = .button, .sibling_index = 7 });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.children_calls.items.len);
    try testing.expect(bridge.children_calls.items[0].eql(b));
}

test "router: focus changes coalesce to final element and clear on removal" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const a: ElementId = .{ .index = 0, .generation = 0 };
    const b: ElementId = .{ .index = 1, .generation = 0 };
    try tree.upsert(.{ .element = a, .role = .button, .state = .{ .focused = true, .focusable = true } });
    try tree.upsert(.{ .element = b, .role = .button });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.focus_calls.items.len);
    try testing.expect(bridge.focus_calls.items[0].eql(a));

    bridge.focus_calls.clearRetainingCapacity();
    try tree.upsert(.{ .element = b, .role = .button, .state = .{ .focused = true, .focusable = true } });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.focus_calls.items.len);
    try testing.expect(bridge.focus_calls.items[0].eql(b));

    bridge.focus_calls.clearRetainingCapacity();
    try tree.remove(b);
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.focus_calls.items.len);
    try testing.expect(bridge.focus_calls.items[0].isNull());
}

test "router: live_announce on text_hash change in live region" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const id: ElementId = .{ .index = 0, .generation = 0 };
    try tree.upsert(.{ .element = id, .role = .status, .live = .polite, .text_hash = 100 });
    flushToBridge(&tree, bridge.bridge());
    bridge.announce_calls.clearRetainingCapacity();

    try tree.upsert(.{ .element = id, .role = .status, .live = .polite, .text_hash = 200 });
    flushToBridge(&tree, bridge.bridge());

    try testing.expectEqual(@as(usize, 1), bridge.announce_calls.items.len);
    try testing.expectEqual(@as(u64, 200), bridge.announce_calls.items[0]);
}

test "router: active_descendant change → notifyActiveDescendant" {
    var tree = AccessibilityTree.init(testing.allocator);
    defer tree.deinit();
    var bridge = TestBridge{ .allocator = testing.allocator };
    defer bridge.deinit();

    const container: ElementId = .{ .index = 0, .generation = 0 };
    const opt_a: ElementId = .{ .index = 1, .generation = 0 };
    const opt_b: ElementId = .{ .index = 2, .generation = 0 };

    try tree.upsert(.{ .element = container, .role = .combobox });
    flushToBridge(&tree, bridge.bridge());
    bridge.active_desc_calls.clearRetainingCapacity();

    // 容器声明 active_descendant=A
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_a });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.active_desc_calls.items.len);
    try testing.expect(bridge.active_desc_calls.items[0].container.eql(container));
    try testing.expect(bridge.active_desc_calls.items[0].active.eql(opt_a));

    // 切到 B
    bridge.active_desc_calls.clearRetainingCapacity();
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_b });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 1), bridge.active_desc_calls.items.len);
    try testing.expect(bridge.active_desc_calls.items[0].active.eql(opt_b));

    // 不变 -> 不投递
    bridge.active_desc_calls.clearRetainingCapacity();
    try tree.upsert(.{ .element = container, .role = .combobox, .active_descendant = opt_b });
    flushToBridge(&tree, bridge.bridge());
    try testing.expectEqual(@as(usize, 0), bridge.active_desc_calls.items.len);
}
