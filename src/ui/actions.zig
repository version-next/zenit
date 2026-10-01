/// Action Dispatch 系统
///
/// 提供 Key Context + Action 绑定:
/// - 节点可设置 key_context 标签 (如 "editor", "modal")
/// - 全局注册 KeyBinding (key + modifiers -> Action)
/// - 键盘事件到达时，沿焦点链查找匹配 context 的 Action 并分发
const std = @import("std");
const events_mod = @import("events.zig");
const KeyCode = events_mod.KeyCode;
const Modifiers = events_mod.Modifiers;
const EventResult = events_mod.EventResult;
const core = @import("core.zig");
const Node = core.Node;

/// Action 定义
pub const Action = struct {
    /// 上下文名 (需要匹配节点的 key_context)
    context: []const u8,
    /// 动作名
    name: []const u8,
};

/// 键绑定
pub const KeyBinding = struct {
    key: KeyCode,
    modifiers: Modifiers,
    action: Action,
};

pub const CommandBinding = struct {
    command_id: u64,
    action: Action,
};

/// Action handler 回调
pub const ActionHandler = *const fn (action: Action, context: ?*anyopaque) EventResult;

/// Action 调度器
pub const ActionDispatcher = struct {
    registry: ?*const core.NodeRegistry = null,

    bindings: [64]?KeyBinding = [_]?KeyBinding{null} ** 64,
    binding_count: u8 = 0,
    command_bindings: [64]?CommandBinding = [_]?CommandBinding{null} ** 64,
    command_binding_count: u8 = 0,

    pub fn setRegistry(self: *ActionDispatcher, registry: *const core.NodeRegistry) void {
        self.registry = registry;
    }

    /// 注册键绑定
    pub fn bind(self: *ActionDispatcher, key: KeyCode, modifiers: Modifiers, action: Action) void {
        if (self.binding_count >= self.bindings.len) return;
        self.bindings[self.binding_count] = .{
            .key = key,
            .modifiers = modifiers,
            .action = action,
        };
        self.binding_count += 1;
    }

    /// 查找匹配的 Action
    pub fn matchKey(self: *const ActionDispatcher, key: KeyCode, modifiers: Modifiers) ?Action {
        for (self.bindings[0..self.binding_count]) |binding_opt| {
            if (binding_opt) |binding| {
                if (binding.key == key and
                    binding.modifiers.shift == modifiers.shift and
                    binding.modifiers.ctrl == modifiers.ctrl and
                    binding.modifiers.alt == modifiers.alt and
                    binding.modifiers.super == modifiers.super)
                {
                    return binding.action;
                }
            }
        }
        return null;
    }

    pub fn bindCommand(self: *ActionDispatcher, command_id: u64, action: Action) void {
        for (self.command_bindings[0..self.command_binding_count]) |*binding_opt| {
            if (binding_opt.*) |*binding| {
                if (binding.command_id == command_id) {
                    binding.action = action;
                    return;
                }
            }
        }
        if (self.command_binding_count >= self.command_bindings.len) return;
        self.command_bindings[self.command_binding_count] = .{ .command_id = command_id, .action = action };
        self.command_binding_count += 1;
    }

    pub fn matchCommand(self: *const ActionDispatcher, command_id: u64) ?Action {
        for (self.command_bindings[0..self.command_binding_count]) |binding_opt| {
            const binding = binding_opt orelse continue;
            if (binding.command_id == command_id) return binding.action;
        }
        return null;
    }

    /// Bubble along the path captured before the first callback. Reparenting or
    /// nested dispatch cannot redirect an in-flight action. Registered identities
    /// are resolved before each callback, so removed nodes are skipped.
    /// Without a registry callers must retain all path nodes/handler contexts
    /// until dispatch returns. The borrowed action strings must also stay alive.
    pub fn dispatchAction(self: *const ActionDispatcher, action: Action, focus_node: *Node) EventResult {
        return self.dispatchActionWithDelivery(action, focus_node).result;
    }

    pub const DispatchReport = struct {
        result: EventResult,
        /// Whether any matching handler ran, independently of consumption.
        delivered: bool,
    };

    pub fn dispatchActionWithDelivery(self: *const ActionDispatcher, action: Action, focus_node: *Node) DispatchReport {
        const Entry = struct { raw: *Node, handle: ?core.NodeHandle };
        const registry = self.registry;
        // Small paths use the stack; deeper trees preserve the API's unlimited
        // depth without imposing a truncation boundary. Allocation failure occurs
        // before any callback, so it cannot partially execute an action.
        var fallback = std.heap.stackFallback(128 * @sizeOf(Entry), if (registry) |r| r.allocator else std.heap.page_allocator);
        const allocator = fallback.get();
        var path: std.ArrayList(Entry) = .empty;
        defer path.deinit(allocator);
        var current: ?*Node = focus_node;
        while (current) |node| : (current = node.parent) {
            path.append(allocator, .{ .raw = node, .handle = if (registry) |r| r.handleFor(node) else null }) catch {
                std.log.warn("Action path allocation failed; consuming input without dispatch", .{});
                return .{ .result = .stop, .delivered = false };
            };
        }
        var delivered = false;
        for (path.items) |entry| {
            const node = if (registry) |r| r.resolve(entry.handle, null) orelse continue else entry.raw;
            if (node.behavior.interaction.key_context) |ctx| {
                if (std.mem.eql(u8, ctx, action.context)) {
                    if (node.behavior.events.on_action) |handler| {
                        delivered = true;
                        const result = handler(action, node.behavior.events.action_context);
                        if (result != .ignored) return .{ .result = result, .delivered = true };
                    }
                }
            }
        }
        return .{ .result = .ignored, .delivered = delivered };
    }
};

// ========== 测试 ==========

test "ActionDispatcher: matchKey" {
    var ad = ActionDispatcher{};

    ad.bind(.s, .{ .super = true }, .{ .context = "editor", .name = "save" });
    ad.bind(.z, .{ .super = true }, .{ .context = "editor", .name = "undo" });
    ad.bind(.escape, .{}, .{ .context = "modal", .name = "close" });

    // Match Cmd+S
    const save = ad.matchKey(.s, .{ .super = true });
    try std.testing.expect(save != null);
    try std.testing.expect(std.mem.eql(u8, save.?.name, "save"));
    try std.testing.expect(std.mem.eql(u8, save.?.context, "editor"));

    // Match Escape
    const close = ad.matchKey(.escape, .{});
    try std.testing.expect(close != null);
    try std.testing.expect(std.mem.eql(u8, close.?.name, "close"));

    // No match for unbound key
    const none = ad.matchKey(.a, .{});
    try std.testing.expectEqual(@as(?Action, null), none);

    // No match for wrong modifiers
    const no_match = ad.matchKey(.s, .{});
    try std.testing.expectEqual(@as(?Action, null), no_match);
}

test "ActionDispatcher: native menu command uses the same Action" {
    var ad = ActionDispatcher{};
    ad.bindCommand(42, .{ .context = "editor", .name = "save" });
    const action = ad.matchCommand(42).?;
    try std.testing.expectEqualStrings("editor", action.context);
    try std.testing.expectEqualStrings("save", action.name);
    try std.testing.expectEqual(@as(?Action, null), ad.matchCommand(99));
}

test "Action: bubbles along focus chain" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    ctx.root = root;

    var action_received = false;

    // editor container with key_context
    const editor = try core.box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    editor.behavior.interaction.key_context = "editor";
    editor.behavior.events.on_action = struct {
        fn handler(action: Action, context: ?*anyopaque) EventResult {
            if (std.mem.eql(u8, action.name, "save")) {
                const ptr: *bool = @ptrCast(@alignCast(context.?));
                ptr.* = true;
                return .handled;
            }
            return .ignored;
        }
    }.handler;
    editor.behavior.events.action_context = &action_received;
    try root.appendChild(std.testing.allocator, editor);

    // focusable child inside editor
    const input_node = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 30 } }, .{});
    input_node.setFocusable(true);
    try editor.appendChild(std.testing.allocator, input_node);

    var ad = ActionDispatcher{};
    ad.bind(.s, .{ .super = true }, .{ .context = "editor", .name = "save" });

    // Simulate: Cmd+S while input is focused
    const action = ad.matchKey(.s, .{ .super = true });
    try std.testing.expect(action != null);

    const result = ad.dispatchAction(action.?, input_node);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expect(action_received);
}

test "ActionDispatcher: destruction skips removed ancestors and preserves surviving path" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const parent = try core.box(cx, .{}, .{});
    const leaf = try core.box(cx, .{}, .{});
    try root.appendChild(cx.allocator, parent);
    try parent.appendChild(cx.allocator, leaf);
    const State = struct {
        cx: *core.Cx,
        parent: *Node,
        received: usize = 0,
        fn remove(_: Action, raw: ?*anyopaque) EventResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.cx.detachChild(self.parent.parent.?, self.parent);
            self.cx.freeNode(self.parent);
            return .ignored;
        }
        fn rootHandler(_: Action, raw: ?*anyopaque) EventResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.received += 1;
            return .handled;
        }
    };
    var state = State{ .cx = cx, .parent = parent };
    leaf.behavior.interaction.key_context = "test";
    leaf.behavior.events.on_action = State.remove;
    leaf.behavior.events.action_context = &state;
    root.behavior.interaction.key_context = "test";
    root.behavior.events.on_action = State.rootHandler;
    root.behavior.events.action_context = &state;
    cx.layout();
    var dispatcher = ActionDispatcher{};
    dispatcher.setRegistry(&cx.node_registry);
    const result = dispatcher.dispatchAction(.{ .context = "test", .name = "remove" }, leaf);
    try std.testing.expectEqual(EventResult.handled, result);
    try std.testing.expectEqual(@as(usize, 1), state.received);
}

test "ActionDispatcher: nested dispatch and reparenting preserve outer path" {
    for ([_]bool{ true, false }) |registered| {
        const cx = try core.Cx.init(std.testing.allocator);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const left = try core.box(cx, .{}, .{});
        const right = try core.box(cx, .{}, .{});
        const leaf = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, left);
        try root.appendChild(cx.allocator, right);
        try left.appendChild(cx.allocator, leaf);
        var dispatcher = ActionDispatcher{};
        const State = struct {
            cx: *core.Cx,
            dispatcher: *ActionDispatcher,
            leaf: *Node,
            right: *Node,
            left_count: usize = 0,
            right_count: usize = 0,
            nested_count: usize = 0,
            fn move(action: Action, raw: ?*anyopaque) EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                if (std.mem.eql(u8, action.name, "outer")) {
                    self.cx.detachChild(self.leaf.parent.?, self.leaf);
                    self.right.appendChild(self.cx.allocator, self.leaf) catch unreachable;
                    _ = self.dispatcher.dispatchAction(.{ .context = "test", .name = "inner" }, self.right);
                }
                return .ignored;
            }
            fn onLeft(_: Action, raw: ?*anyopaque) EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.left_count += 1;
                return .handled;
            }
            fn onRight(action: Action, raw: ?*anyopaque) EventResult {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                if (std.mem.eql(u8, action.name, "outer")) self.right_count += 1 else self.nested_count += 1;
                return .handled;
            }
        };
        var state = State{ .cx = cx, .dispatcher = &dispatcher, .leaf = leaf, .right = right };
        for ([_]*Node{ left, right, leaf }) |node| {
            node.behavior.interaction.key_context = "test";
            node.behavior.events.action_context = &state;
        }
        leaf.behavior.events.on_action = State.move;
        left.behavior.events.on_action = State.onLeft;
        right.behavior.events.on_action = State.onRight;
        cx.layout();
        if (registered) dispatcher.setRegistry(&cx.node_registry);
        try std.testing.expectEqual(EventResult.handled, dispatcher.dispatchAction(.{ .context = "test", .name = "outer" }, leaf));
        try std.testing.expectEqual(@as(usize, 1), state.nested_count);
        try std.testing.expectEqual(@as(usize, 0), state.right_count);
        try std.testing.expectEqual(@as(usize, 1), state.left_count);
    }
}

test "ActionDispatcher: deep paths allocate before callbacks and OOM consumes input" {
    const cx = try core.Cx.init(std.testing.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    var leaf = root;
    for (0..200) |_| {
        const child = try core.box(cx, .{}, .{});
        try leaf.appendChild(cx.allocator, child);
        leaf = child;
    }
    var called: usize = 0;
    const Callback = struct {
        fn handle(_: Action, raw: ?*anyopaque) EventResult {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
            return .ignored;
        }
    };
    for ([_]*Node{ root, leaf }) |node| {
        node.behavior.interaction.key_context = "test";
        node.behavior.events.on_action = Callback.handle;
        node.behavior.events.action_context = &called;
    }
    try cx.node_registry.rebuild(root);
    var dispatcher = ActionDispatcher{};
    dispatcher.setRegistry(&cx.node_registry);
    try std.testing.expectEqual(EventResult.ignored, dispatcher.dispatchAction(.{ .context = "test", .name = "deep" }, leaf));
    try std.testing.expectEqual(@as(usize, 2), called);
    called = 0;
    const original_allocator = cx.node_registry.allocator;
    var fail = std.testing.FailingAllocator.init(original_allocator, .{ .fail_index = 0 });
    cx.node_registry.allocator = fail.allocator();
    defer cx.node_registry.allocator = original_allocator;
    try std.testing.expectEqual(EventResult.stop, dispatcher.dispatchAction(.{ .context = "test", .name = "deep" }, leaf));
    try std.testing.expectEqual(@as(usize, 0), called);
}

test "ActionDispatcher: command fallback depends on delivery not consumption" {
    for ([_]bool{ true, false }) |in_focus_path| {
        const cx = try core.Cx.init(std.testing.allocator);
        defer cx.deinit();
        const root = try core.box(cx, .{}, .{});
        cx.root = root;
        const focus = try core.box(cx, .{}, .{});
        try root.appendChild(cx.allocator, focus);
        focus.setFocusable(true);
        const recipient = if (in_focus_path) focus else try core.box(cx, .{}, .{});
        if (!in_focus_path) try root.appendChild(cx.allocator, recipient);
        var received: usize = 0;
        recipient.behavior.interaction.key_context = "test";
        recipient.behavior.events.action_context = &received;
        recipient.behavior.events.on_action = struct {
            fn handle(_: Action, raw: ?*anyopaque) EventResult {
                const count: *usize = @ptrCast(@alignCast(raw.?));
                count.* += 1;
                return .ignored;
            }
        }.handle;
        cx.layout();
        cx.setFocus(focus);
        cx.bindCommandAction(42, .{ .context = "test", .name = "command" });
        cx.handleCommand(42);
        try std.testing.expectEqual(@as(usize, 1), received);
    }
}
