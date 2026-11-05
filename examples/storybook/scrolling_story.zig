//! Scroll inputs and nested ownership, using the same ScrollArea as applications.
const std = @import("std");
const ui = @import("ui");
const v = ui.view;
const W = ui.widgets;
const SA = W.scroll_area;

const S = struct {
    fn root(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 620 }, .gap = 14 };
    }
    fn row(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 20, .align_items = .start };
    }
    fn column(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 6 };
    }
    fn title(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 14, .font_weight = 600, .color = t.tokens.color.fg_primary };
    }
    fn status(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 11, .color = t.tokens.color.fg_secondary };
    }
    /// Hoverable rows: with the pointer resting on a list, scrolling moves the highlight to the
    /// row that arrives under it (stationary-pointer hover, core/cx_hover.zig).
    const line = ui.css(.{ .height = 30, .width = .fill, .padding = .{ .x = 10, .y = 4 }, .background = .bg_secondary, ._hover = .{ .background = .bg_active } });
    fn body(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_primary };
    }
};

const Watch = struct {
    cx: *ui.Cx,
    area: SA.ScrollAreaResult,
    dx: f32 = 0,
    dy: f32 = 0,
    phase: ui.events.ScrollPhase = .none,
    momentum: ui.events.MomentumPhase = .none,
    count: usize = 0,
    shown: [256]u8 = undefined,
    shown_len: usize = 0,

    fn capture(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const self: *Watch = @ptrCast(@alignCast(context.?));
        if (event == .scroll) {
            self.dx = event.scroll.dx;
            self.dy = event.scroll.dy;
            self.phase = event.scroll.phase;
            self.momentum = event.scroll.momentum;
            self.count += 1;
            self.cx.needs_redraw = true;
        }
        return .ignored; // Observe without replacing ScrollArea's handler or ownership.
    }
    fn status(node: *ui.Node) void {
        const self: *Watch = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state.?));
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "x={d:.0} y={d:.0}  dx={d:.0} dy={d:.0} · {s}/{s} · #{d}", .{
            self.area.state.scroll_x, self.area.state.scroll_y, self.dx,    self.dy,
            @tagName(self.phase),     @tagName(self.momentum),  self.count,
        }) catch return;
        if (std.mem.eql(u8, self.shown[0..self.shown_len], text)) return;
        node.setTextContent(self.cx.allocator, text) catch return;
        @memcpy(self.shown[0..text.len], text);
        self.shown_len = text.len;
    }
    fn reset(self: *Watch) void {
        SA.setScrollY(self.area.state, self.area.content, 0);
        self.area.state.scroll_x = 0;
        self.area.content.setTranslateX(0);
        self.dx = 0;
        self.dy = 0;
        self.count = 0;
        self.phase = .none;
        self.momentum = .none;
        self.cx.needs_redraw = true;
    }
};

const Panel = struct { root: *ui.Node, area: SA.ScrollAreaResult };
fn panel(scope: *ui.Scope, cx: *ui.Cx, comptime id: []const u8, title: []const u8, width: f32, height: f32, direction: SA.ScrollDirection) !Panel {
    const area = try W.ScrollArea(.{ .width = width, .height = height, .direction = direction, .rubber_band_y = false, .rubber_band_x = false }).mount(scope, cx);
    area.container.meta.ownership.meta.test_id = id;
    area.content.meta.ownership.meta.test_id = id ++ ".content";
    const watch = try scope.createState(Watch, .{ .cx = cx, .area = area });
    const root = try v.render(scope, cx, v.col(.{ .style = S.column }, .{
        v.text(.{ .style = S.title }, title),
        v.attrs(.{ .test_id = id ++ ".reset" }, W.Button(.{ .label = "Reset", .size = .xs, .variant = .secondary, .on_click = ui.on.call(watch, Watch.reset) })),
    }));
    root.behavior.events.on_event_capture = Watch.capture;
    root.behavior.events.capture_context = watch;
    try root.appendChild(cx.allocator, area.container);
    const label = try v.render(scope, cx, v.text(.{ .style = S.status, .test_id = id ++ ".status" }, "Ready"));
    label.meta.per_frame.hooks.slots.anim_state = watch;
    label.addBeforeRenderScoped(Watch.status, .self);
    try root.appendChild(cx.allocator, label);
    return .{ .root = root, .area = area };
}
/// Rows carry `<id>.row.NN` test ids (1-based, as labelled) when `id` is given.
fn rows(scope: *ui.Scope, cx: *ui.Cx, parent: *ui.Node, comptime id: ?[]const u8, comptime prefix: []const u8, comptime count: usize) !void {
    inline for (0..count) |i| {
        const text = std.fmt.comptimePrint(prefix ++ " {d:0>2}  ·  Scroll to explore", .{i + 1});
        const row = v.row(.{ .style = S.line }, v.text(.{ .style = S.body }, text));
        const node = if (id) |prefix_id|
            try v.render(scope, cx, v.attrs(.{ .test_id = std.fmt.comptimePrint("{s}.row.{d:0>2}", .{ prefix_id, i + 1 }) }, row))
        else
            try v.render(scope, cx, row);
        try parent.appendChild(cx.allocator, node);
    }
}
pub fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const root = try v.render(scope, cx, v.col(.{ .style = S.root }, .{}));
    const top = try v.render(scope, cx, v.row(.{ .style = S.row }, .{}));
    try root.appendChild(cx.allocator, top);
    const vertical = try panel(scope, cx, "story.scrolling.vertical", "Vertical · wheel / trackpad", 300, 170, .vertical);
    try rows(scope, cx, vertical.area.content, "story.scrolling.vertical", "Row", 40);
    try top.appendChild(cx.allocator, vertical.root);
    const horizontal = try panel(scope, cx, "story.scrolling.horizontal", "Horizontal · sideways scroll", 300, 170, .horizontal);
    try horizontal.area.content.setStyleInlineFallible(cx.allocator, .{ .width = .{ .px = 1200 } });
    const strip = try ui.box(cx, .{ .width = .{ .px = 1200 }, .height = .{ .px = 160 }, .direction = .row, .gap = 12 }, .{});
    try horizontal.area.content.appendChild(cx.allocator, strip);
    for (0..8) |i| {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "Card {d}", .{i + 1});
        const card = try W.Card(.{ .title = text, .variant = .outlined }).mount(scope, cx);
        try card.setStyleInlineFallible(cx.allocator, .{ .width = .{ .px = 130 }, .height = .{ .px = 140 } });
        try strip.appendChild(cx.allocator, card);
    }
    try top.appendChild(cx.allocator, horizontal.root);
    const outer = try panel(scope, cx, "story.scrolling.outer", "Nested · inner first, then parent at the edge", 620, 190, .vertical);
    const inner = try panel(scope, cx, "story.scrolling.inner", "Inner list", 560, 100, .vertical);
    try rows(scope, cx, inner.area.content, "story.scrolling.inner", "Inner", 20);
    try outer.area.content.appendChild(cx.allocator, inner.root);
    try rows(scope, cx, outer.area.content, null, "Outer", 16);
    try root.appendChild(cx.allocator, outer.root);
    return root;
}
