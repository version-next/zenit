const std = @import("std");
const ui = @import("../core.zig");
const helpers = @import("../components/window_chrome/mod.zig");
const chrome = @import("system_sdk").window_chrome;

fn init() !*ui.Cx {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    cx.setViewport(300, 180);
    (try cx.windowChrome()).set(.{ .effective_mode = .custom, .controls_owner = .framework });
    return cx;
}

test "window header slot rejects duplicates and reveal leases release with their scope" {
    const cx = try init();
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    try std.testing.expectError(error.MissingWindowHeader, cx.acquireWindowHeaderReveal(scope));
    const header = try helpers.WindowHeader(.{}, .{"Header"}).mount(scope, cx);
    try std.testing.expect(cx.window_header_node == header);
    try std.testing.expectError(error.DuplicateWindowHeader, helpers.WindowHeader(.{}, .{"Duplicate"}).mount(scope, cx));
    const lease_scope = try scope.childScope();
    const first = try cx.acquireWindowHeaderReveal(lease_scope);
    _ = try cx.acquireWindowHeaderReveal(lease_scope);
    try std.testing.expectEqual(@as(u32, 2), cx.window_header_reveal_leases);
    first.release();
    first.release();
    try std.testing.expectEqual(@as(u32, 1), cx.window_header_reveal_leases);
    lease_scope.dispose();
    try std.testing.expectEqual(@as(u32, 0), cx.window_header_reveal_leases);
    cx.destroyDetached(header);
    try std.testing.expect(cx.window_header_node == null);
    const replacement = try helpers.WindowHeader(.{}, .{"Replacement"}).mount(scope, cx);
    try std.testing.expect(cx.window_header_node == replacement);
    cx.destroyDetached(replacement);
}

test "window chrome published hit scene respects interactive children, overlays, visibility and transforms" {
    const cx = try init();
    defer cx.deinit();
    const child = try ui.box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } }, .{});
    const root = try ui.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 180 } }, .{child});
    root.behavior.interaction.window_region = .drag;
    cx.root = root;
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.drag, cx.windowRegionAt(10, 10));
    child.behavior.interaction.focusable = true;
    child.markInteractionDirty();
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.client, cx.windowRegionAt(10, 10));
    child.behavior.interaction.focusable = false;
    child.behavior.interaction.window_region = .client;
    child.markInteractionDirty();
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.client, cx.windowRegionAt(10, 10));
    child.setDisplay(.none);
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.drag, cx.windowRegionAt(10, 10));
    child.setDisplay(.flex);
    child.setStyle(null, .translate_x, @as(f32, 100));
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.drag, cx.windowRegionAt(10, 10));
    try std.testing.expectEqual(chrome.Region.client, cx.windowRegionAt(110, 10));
    child.setStyle(null, .opacity, @as(f32, 0));
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.drag, cx.windowRegionAt(110, 10));
    cx.tick_depth += 1;
    try std.testing.expectEqual(chrome.Region.client, cx.windowRegionAt(200, 10));
    cx.tick_depth -= 1;
    cx.detachChild(root, child);
    cx.freeNode(child);
    try std.testing.expectEqual(chrome.Region.drag, cx.windowRegionAt(110, 10));
}

test "window chrome helpers release subscriptions when their subtree is removed" {
    const cx = try init();
    defer cx.deinit();
    const state = try cx.windowChrome();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 180 } }, .{});
    cx.root = root;
    for (0..8) |_| {
        const header = try helpers.WindowHeader(.{}, .{helpers.DragRegion(.{}, .{"Title"})}).mount(scope, cx);
        try root.appendChild(cx.allocator, header);
        cx.publishWindowRegions();
        cx.detachChild(root, header);
        cx.freeNode(header);
        var next = state.peek();
        next.maximized = !next.maximized;
        state.set(next);
        const controls = try helpers.WindowControls(.{}).mount(scope, cx);
        try root.appendChild(cx.allocator, controls);
        cx.detachChild(root, controls);
        cx.freeNode(controls);
        next = state.peek();
        next.fullscreen = !next.fullscreen;
        state.set(next);
    }
}

test "window chrome clip and topmost client overlays block inherited drag" {
    const cx = try init();
    defer cx.deinit();
    const drag = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 } }, .{});
    drag.behavior.interaction.window_region = .drag;
    const clip = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 }, .overflow_hidden = true, .flex_shrink = 0 }, .{drag});
    drag.style.flex_shrink = 0;
    const root = try ui.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 180 } }, .{clip});
    cx.root = root;
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.drag, cx.windowRegionAt(10, 10));
    try std.testing.expectEqual(chrome.Region.client, cx.windowRegionAt(10, 60));
    const portal = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 300 }, .height = .{ .px = 180 } }, .{});
    portal.setStyle(cx.allocator, .z_index, @as(i32, 100));
    portal.setStyle(cx.allocator, .hit_behavior, ui.HitBehavior.children_only);
    try root.appendChild(cx.allocator, portal);
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.drag, cx.windowRegionAt(10, 10));
    const overlay = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    overlay.behavior.interaction.window_region = .client;
    overlay.setStyle(cx.allocator, .z_index, @as(i32, 5));
    try portal.appendChild(cx.allocator, overlay);
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.client, cx.windowRegionAt(10, 10));
    overlay.behavior.interaction.window_region = .inherit;
    overlay.setStyle(cx.allocator, .hit_behavior, ui.HitBehavior.pass_through);
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.drag, cx.windowRegionAt(10, 10));
    cx.detachChild(portal, overlay);
    cx.freeNode(overlay);
    cx.publishWindowRegions();
    try std.testing.expectEqual(chrome.Region.drag, cx.windowRegionAt(10, 10));
}

// Reference-checked OOM sweep (components/oom_sweep.zig): the header's inset and the controls'
// order / spacing / button looks are bound to the chrome state; their first application is part
// of the mount, so a mount that reports success must carry them completely.
test "window header + controls: mount 成功即外观完整，任意分配点失败不假成功（sweep）" {
    const sw = @import("../components/oom_sweep.zig");
    try sw.sweepMountVerified("window_chrome(header+controls)", struct {
        fn m(scope: *ui.Scope, cx: *ui.Cx) anyerror!?*ui.Node {
            // published before anything observes it (a set() would notify through the graph)
            cx.window_chrome_signal = try ui.Signal(chrome.State).create(cx.owner, .{ .effective_mode = .custom, .controls_owner = .native, .controls_geometry_known = false, .width = 72 });
            const header = try helpers.WindowHeader(.{ .style = .{ .padding = ui.Padding.all(4) } }, .{"Title"}).mount(scope, cx);
            errdefer cx.destroyDetached(header);
            const controls = try helpers.WindowControls(.{}).mount(scope, cx);
            header.appendChild(cx.allocator, controls) catch |err| {
                cx.destroyDetached(controls);
                return err;
            };
            return header;
        }
    }.m, struct {
        fn check(root: *ui.Node) anyerror!void {
            // unknown native geometry: the header reserves the whole width on the left
            try std.testing.expectEqual(@as(f32, 72), root.style.padding.left);
            try std.testing.expectEqual(chrome.Region.drag, root.behavior.interaction.window_region);
            const controls = root.children.items[root.children.items.len - 1];
            try std.testing.expectEqual(@as(usize, 3), controls.children.items.len);
            try std.testing.expect(controls.style.gap > 0);
        }
    }.check);
}

fn themedHeaderLayout(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 38 }, .direction = .row, .align_items = .center, .padding = .{ .right = 10 } };
}

fn expectHeaderInsetSurvivesTheme(comptime style: anytype, owner: chrome.ControlsOwner) !void {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 180);
    var state: chrome.State = .{ .effective_mode = .custom, .controls_owner = owner, .width = 300, .height = 180 };
    if (owner == .native) {
        state.native_controls[0] = .{ .x = 160, .y = 0, .w = 140, .h = 32 };
        state.native_controls_count = 1;
    }
    (try cx.windowChrome()).set(state);
    const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    const header = try helpers.WindowHeader(.{ .style = style }, .{helpers.ClientRegion(.{ .style = .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } } }, .{})}).mount(scope, cx);
    // The root owns the header; cx.deinit frees the tree.
    const root = try ui.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 180 } }, .{});
    cx.root = root;
    try root.appendChild(cx.allocator, header);
    cx.layout();
    const before = header.style.padding;
    const controls_before = header.children.items[header.children.items.len - 1].globalRect();
    cx.setTheme(&ui.theme.light);
    cx.layout();
    try std.testing.expectEqual(before, header.style.padding);
    try std.testing.expectEqual(controls_before, header.children.items[header.children.items.len - 1].globalRect());
    cx.setTheme(&ui.theme.dark);
    cx.layout();
    try std.testing.expectEqual(before, header.style.padding);
}

const static_header_layout: ui.BoxStyle = .{ .width = .fill(), .height = .{ .px = 38 }, .padding = .{ .right = 10 } };

test "window header keeps its control inset across a theme switch" {
    const static_style = static_header_layout;
    try expectHeaderInsetSurvivesTheme(static_style, .native);
    try expectHeaderInsetSurvivesTheme(themedHeaderLayout, .native);
    try expectHeaderInsetSurvivesTheme(static_style, .framework);
    try expectHeaderInsetSurvivesTheme(themedHeaderLayout, .framework);
}
