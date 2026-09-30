//! Core dispatch contract fixture. These deliberately use raw event targets:
//! replacing a widget's private handlers would test an unsupported widget API.
const std = @import("std");
const ui = @import("ui");

const State = struct {
    cx: *ui.Cx,
    status: *ui.Node,
    click_target: ?*ui.Node = null,
    focus_target: ?*ui.Node = null,
    destination: *ui.Node,
    removed: usize = 0,
    followups: usize = 0,
    blurs: usize = 0,
    path_clicks: usize = 0,
    oom: bool = false,
    shown: [256]u8 = undefined,
    shown_len: usize = 0,

    fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
        allocator.destroy(@as(*State, @ptrCast(@alignCast(raw))));
    }
    fn removeClick(self: *State) void {
        const node = self.click_target orelse return;
        self.click_target = null;
        self.cx.detachChild(node.parent.?, node);
        self.cx.freeNode(node);
        self.removed += 1;
    }
    fn followup(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *State = @ptrCast(@alignCast(raw.?));
        if (event == .click) self.followups += 1;
        return .ignored;
    }
    fn blur(self: *State) void {
        self.blurs += 1;
        // Bound a broken implementation so the test reports recursion precisely.
        if (self.blurs < 5) self.cx.focus_manager.setFocus(self.destination);
    }
    fn redirect(self: *State) void {
        self.cx.focus_manager.setFocus(self.destination);
    }
    fn removeFocus(self: *State) void {
        const node = self.focus_target orelse return;
        self.focus_target = null;
        self.cx.detachChild(node.parent.?, node);
        self.cx.freeNode(node);
    }
    fn pathClick(self: *State) void {
        self.path_clicks += 1;
    }
    fn tick(node: *ui.Node) void {
        const self: *State = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state.?));
        const actual = self.cx.focus_manager.getFocused();
        const focus_name: []const u8 = if (actual) |n| n.meta.ownership.meta.test_id orelse "other" else "none";
        var buf: [256]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, "removed={d} followups={d} blurs={d} path={d} oom={} cache={} focus={s}", .{
            self.removed,                   self.followups, self.blurs, self.path_clicks, self.oom,
            self.cx.focused_node == actual, focus_name,
        }) catch unreachable;
        if (!std.mem.eql(u8, self.shown[0..self.shown_len], value)) {
            self.status.setTextContent(self.cx.allocator, value) catch return;
            @memcpy(self.shown[0..value.len], value);
            self.shown_len = value.len;
        }
    }
};

fn target(cx: *ui.Cx, parent: *ui.Node, title: []const u8, id: []const u8) !*ui.Node {
    const text = try ui.text(cx, title, .{ .font_size = 13, .color = ui.theme.light.color.fg_primary });
    text.setHitTestVisible(false);
    const node = try ui.box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 38 },
        .background = ui.theme.light.color.bg_secondary,
        .padding = ui.Padding.all(8),
    }, .{text});
    node.meta.ownership.meta.test_id = id;
    node.setFocusable(true);
    try parent.appendChild(cx.allocator, node);
    return node;
}

pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const root = try ui.box(cx, .{ .direction = .column, .gap = 8 }, .{});
    const status = try ui.text(cx, "Waiting for frame", .{ .font_size = 12, .color = ui.theme.light.color.fg_primary });
    status.meta.ownership.meta.test_id = "lifecycle.status";
    const destination = try target(cx, root, "Settled focus destination", "lifecycle.destination");
    const state = try scope.allocator.create(State);
    state.* = .{ .cx = cx, .status = status, .destination = destination };
    try scope.adoptResource(state, State.destroy);
    const dying = try target(cx, root, "Click removes this target", "lifecycle.click-remove");
    state.click_target = dying;
    dying.behavior.events.on_click = ui.Cx.handlerFrom(State, state, State.removeClick);
    dying.behavior.events.on_event = State.followup;
    dying.behavior.events.event_context = state;
    const blur_source = try target(cx, root, "Focus me, then click attempted destination", "lifecycle.blur-source");
    blur_source.behavior.events.on_blur = ui.Cx.handlerFrom(State, state, State.blur);
    _ = try target(cx, root, "Attempted focus destination", "lifecycle.attempted");
    const redirect = try target(cx, root, "Focus redirects to settled destination", "lifecycle.redirect");
    redirect.behavior.events.on_focus = ui.Cx.handlerFrom(State, state, State.redirect);
    const removed = try target(cx, root, "Focus removes this target", "lifecycle.focus-remove");
    state.focus_target = removed;
    removed.behavior.events.on_focus = ui.Cx.handlerFrom(State, state, State.removeFocus);
    const path = try target(cx, root, "Path hit area: left 80 px only", "lifecycle.path");
    (try path.style.ensureExtFallible(cx.allocator)).hit_shape = .{ .path = .{} };
    try path.setSvgPathHitGeometry(cx.allocator, "M0 0 H80 V38 H0 Z", .nonzero);
    var failing = std.testing.FailingAllocator.init(cx.allocator, .{ .fail_index = 0 });
    path.setPathHitGeometry(failing.allocator(), path.getLayoutOutput().vector.fill.path.?.commands, .evenodd) catch |err| {
        state.oom = err == error.OutOfMemory;
    };
    path.behavior.events.on_click = ui.Cx.handlerFrom(State, state, State.pathClick);
    try root.appendChild(cx.allocator, status);
    root.meta.per_frame.hooks.slots.anim_state = state;
    root.addBeforeRender(State.tick);
    return root;
}
