//! Chrome sync on a real Cx tree: the native pinned header moves over the
//! content without changing layout. Only an open header overlay needs a frame
//! when its native anchor offset changes.
const std = @import("std");
const ui = @import("ui");
const chrome_controller = @import("chrome_controller.zig");

const chrome = @import("chrome_backend.zig").chrome;
const FakeWindow = struct {
    offset: [2]f32 = .{ 0, 0 },
    frame_requested: bool = false,
};
const Backend = struct {
    pub fn takeHeaderFrameRequest(win: *FakeWindow) bool {
        const requested = win.frame_requested;
        win.frame_requested = false;
        return requested;
    }
    pub fn headerBackground(_: *FakeWindow, _: anytype) void {}
    pub fn headerLayout(win: *FakeWindow, _: bool) [2]f32 {
        return win.offset;
    }
    pub fn state(_: *FakeWindow, initial: chrome.State) chrome.State {
        return initial;
    }
    pub fn perform(_: *FakeWindow, _: chrome.Action) !void {
        return error.UnexpectedWindowAction;
    }
};
const FakeRenderer = struct {};
const Fake = struct {
    cx: *ui.Cx,
    win: FakeWindow = .{},
    chrome: chrome_controller.Controller = .{ .initial = .{ .fullscreen = true } },
    renderer: *FakeRenderer,
};

const Tree = struct {
    content: *ui.Node,
    slot: *ui.Node,
    header: *ui.Node,
    body: *ui.Node,
};

// root > content(column) > [slot(fit) > header(38), body(grow)]
fn build(cx: *ui.Cx) !Tree {
    const a = cx.allocator;
    const root = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } }, .{});
    const content = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } }, .{});
    const slot = try ui.box(cx, .{ .width = .{ .grow = .{} } }, .{});
    const header = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 38 } }, .{});
    const body = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } }, .{});
    try slot.appendChild(a, header);
    try content.appendChild(a, slot);
    try content.appendChild(a, body);
    try root.appendChild(a, content);
    cx.root = root;
    cx.content_root = content;
    cx.is_mounted = true;
    cx.window_header_node = header;
    cx.viewport = .{ .width = 400, .height = 300 };
    cx.layout();
    return .{ .content = content, .slot = slot, .header = header, .body = body };
}

fn expectStable(f: *Fake, t: Tree, reveal: f32) !void {
    try expectSyncFrame(f, t, .{ 0, reveal }, false);
}

fn expectSyncFrame(f: *Fake, t: Tree, offset: [2]f32, redraw: bool) !void {
    const root = f.cx.root.?;
    const content_rect = t.content.rectFromWorldOrFallback();
    const body_rect = t.body.rectFromWorldOrFallback();
    const root_rect = root.rectFromWorldOrFallback();
    const header_margin = t.header.style.margin;
    const slot_margin = t.slot.style.margin;
    // Layout has consumed all geometry changes; sync must not dirty it again.
    try std.testing.expect(!root.frame_state.state_bits.dirty.core.layout);
    try std.testing.expect(!root.frame_state.state_bits.dirty.core.subtree_layout);
    f.cx.needs_redraw = false;
    f.win.offset = offset;
    chrome_controller.syncChromeWithBackend(f, Backend);
    try std.testing.expectEqualDeep(offset, f.cx.window_header_offset);
    try std.testing.expectEqual(redraw, f.cx.needs_redraw);
    try std.testing.expectEqualDeep(f.chrome.initial, f.cx.window_chrome_signal.?.peek());
    try std.testing.expect(!root.frame_state.state_bits.dirty.core.layout);
    try std.testing.expect(!root.frame_state.state_bits.dirty.core.subtree_layout);
    try std.testing.expectEqualDeep(root_rect, root.rectFromWorldOrFallback());
    try std.testing.expectEqualDeep(content_rect, t.content.rectFromWorldOrFallback());
    try std.testing.expectEqualDeep(body_rect, t.body.rectFromWorldOrFallback());
    try std.testing.expectEqualDeep(header_margin, t.header.style.margin);
    try std.testing.expectEqualDeep(slot_margin, t.slot.style.margin);
    // Even a later normal layout retains the same content origin and size.
    f.cx.layout();
    try std.testing.expectEqualDeep(content_rect, t.content.rectFromWorldOrFallback());
    try std.testing.expectEqualDeep(body_rect, t.body.rectFromWorldOrFallback());
}

test "pinned header reveal and retraction preserve content geometry without layout or redraw" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const t = try build(cx);
    var renderer: FakeRenderer = .{};
    var f = Fake{ .cx = cx, .renderer = &renderer };
    (try cx.windowChrome()).set(f.chrome.initial);
    try std.testing.expectEqual(@as(f32, 38), t.body.rectFromWorldOrFallback().y);
    for ([_]f32{ 12, 30, 30, 12, 0, 0 }) |offset| try expectStable(&f, t, offset);
}

test "pinned header sync preserves app margins across strip changes and unmount" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const t = try build(cx);
    var renderer: FakeRenderer = .{};
    var f = Fake{ .cx = cx, .renderer = &renderer };
    (try cx.windowChrome()).set(f.chrome.initial);
    try expectStable(&f, t, 30);
    const extra = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 } }, .{});
    try t.slot.appendChild(cx.allocator, extra);
    cx.layout();
    try expectStable(&f, t, 30);
    try expectStable(&f, t, 0);
    var margin = t.slot.style.margin;
    margin.bottom = 5;
    t.slot.setStyle(null, .margin, margin);
    cx.layout();
    try expectStable(&f, t, 30);
    try expectStable(&f, t, 0);
    const body_rect = t.body.rectFromWorldOrFallback();
    cx.window_header_node = null;
    for ([_]f32{ 30, 0 }) |offset| {
        cx.needs_redraw = false;
        f.win.offset = .{ 0, offset };
        chrome_controller.syncChromeWithBackend(&f, Backend);
        try std.testing.expectEqual(@as(f32, 5), t.slot.style.margin.bottom);
        try std.testing.expectEqualDeep(body_rect, t.body.rectFromWorldOrFallback());
        try std.testing.expect(!cx.needs_redraw);
        try std.testing.expect(!cx.root.?.frame_state.state_bits.dirty.core.subtree_layout);
    }
}

fn pushOverlay(cx: *ui.Cx, trigger: *ui.Node) !void {
    _ = try cx.overlay_stack.push(.{
        .kind = .non_modal,
        .trigger_node = trigger,
        .enter_transition = .none,
        .exit_transition = .none,
        .focus = .{ .auto_focus = false, .restore = false },
    });
}

test "an open header overlay requests a frame on offset change without content layout" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const t = try build(cx);
    // Ownership includes a trigger nested inside the header.
    const trigger = try ui.box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    try t.header.appendChild(cx.allocator, trigger);
    cx.layout();
    try pushOverlay(cx, trigger);
    var renderer: FakeRenderer = .{};
    var f = Fake{ .cx = cx, .renderer = &renderer };
    (try cx.windowChrome()).set(f.chrome.initial);
    try expectSyncFrame(&f, t, .{ 0, 30.25 }, true);
    try expectSyncFrame(&f, t, .{ 2.5, 30.25 }, true);
    try expectSyncFrame(&f, t, .{ 0, 0 }, true);
}

test "body overlays and suspended or exiting header overlays do not request offset frames" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const t = try build(cx);
    try pushOverlay(cx, t.body);
    const header_handle = try cx.overlay_stack.push(.{
        .kind = .non_modal,
        .trigger_node = t.header,
        .enter_transition = .none,
        .exit_transition = .none,
        .focus = .{ .auto_focus = false, .restore = false },
    });
    const header_layer = cx.overlay_stack.findLayer(header_handle).?;
    header_layer.suspended = true;
    var renderer: FakeRenderer = .{};
    var f = Fake{ .cx = cx, .renderer = &renderer };
    (try cx.windowChrome()).set(f.chrome.initial);
    try expectSyncFrame(&f, t, .{ 0, 30.25 }, false);
    header_layer.suspended = false;
    header_layer.state = .exiting;
    try expectSyncFrame(&f, t, .{ 0, 0 }, false);
}

test "a header overlay whose trigger was freed is not dereferenced and no longer owns the header" {
    // The overlay outlives its trigger (a tooltip on a row the user just deleted): chrome sync
    // must resolve the trigger through the stack's generation-checked handle, never the raw
    // cached pointer.
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const t = try build(cx);
    const trigger = try ui.box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    try t.header.appendChild(cx.allocator, trigger);
    cx.layout();
    try pushOverlay(cx, trigger);
    t.header.removeChild(trigger);
    cx.freeNode(trigger);
    cx.layout();
    var renderer: FakeRenderer = .{};
    var f = Fake{ .cx = cx, .renderer = &renderer };
    (try cx.windowChrome()).set(f.chrome.initial);
    // No live header overlay: an offset change needs no frame.
    try expectSyncFrame(&f, t, .{ 0, 30.25 }, false);
}

test "an open header overlay does not request a frame when offset is unchanged" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const t = try build(cx);
    try pushOverlay(cx, t.header);
    var renderer: FakeRenderer = .{};
    var f = Fake{ .cx = cx, .renderer = &renderer };
    (try cx.windowChrome()).set(f.chrome.initial);
    try expectSyncFrame(&f, t, .{ 0, 0 }, false);
    try expectSyncFrame(&f, t, .{ 0, 30.25 }, true);
    try expectSyncFrame(&f, t, .{ 0, 30.25 }, false);
    try expectSyncFrame(&f, t, .{ 0, 30.25 }, false);
}

// Native prewarm requests repaint a clean/idle tree once, without reflowing it.
test "native header prewarm requests one frame without an open overlay" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const tree = try build(cx);
    var renderer: FakeRenderer = .{};
    var f = Fake{ .cx = cx, .renderer = &renderer };
    (try cx.windowChrome()).set(f.chrome.initial);
    f.win.frame_requested = true;
    try expectSyncFrame(&f, tree, .{ 0, 0 }, true);
    try std.testing.expect(!f.win.frame_requested);
    try expectSyncFrame(&f, tree, .{ 0, 0 }, false);
}
