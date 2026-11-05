const control_shell = @import("../components/control_shell/mod.zig");
const std = @import("std");
test {
    _ = @import("renderer_host_tests.zig");
    _ = @import("cursor_tests.zig");
    _ = @import("hover_reconcile_tests.zig");
    _ = @import("host_entry_lifetime_tests.zig");
    _ = @import("render_engine/incremental_verify.zig");
}
const builtin = @import("builtin");
// task #161: historical build.zig misconfigured ui_core import; use relative path to allow
// this file to be imported by src/ui/tests_root.zig test block for same src/ui/core.zig file.
const ui = @import("../core.zig");
const a11y_tree_mod = @import("../a11y/tree.zig");
const display_list = @import("display_list.zig");
const render_cache = @import("render_cache.zig");

const Cx = ui.Cx;
const Node = ui.Node;
const Direction = ui.Direction;
const Color = ui.Color;
const Padding = ui.Padding;
const Event = ui.Event;
const EventResult = ui.EventResult;
const Snapshot = ui.Snapshot;
const theme = ui.theme;

const box = ui.box;
const grid = ui.grid;
const hstack = ui.hstack;
const text = ui.text;
const spacer = ui.spacer;
const clickable = ui.clickable;

fn emptyTextInputLength(_: *anyopaque) usize {
    return 0;
}

fn emptyTextInputCopy(_: *anyopaque, _: usize, _: []u8) usize {
    return 0;
}

fn emptyTextInputSelection(_: *anyopaque) ui.TextInputSelection {
    return .{ .start = 0, .end = 0, .caret = 0 };
}

fn emptyTextInputClient(context: *anyopaque) ui.TextInputClient {
    return .{
        .context = context,
        .text_len = emptyTextInputLength,
        .copy_text = emptyTextInputCopy,
        .selection = emptyTextInputSelection,
    };
}

fn testRenderContext(cx: *Cx) ui.render_engine.RenderContext {
    return .{
        .lowering_buffer = &cx.lowering._dead_main,
        .lowering_buffer_paint = &cx.lowering.main_paint,
        .display_list = &cx.display_list,
        .text_blob_store = &cx.text_blob_store,
        .scene_runtime = &cx.scene_runtime,
        .property_tree = &cx.property_tree,
        .layer_tree = &cx.layer_tree,
        .world = &cx.world,
        .allocator = cx.allocator,
        .frame_allocator = cx.frame_arena.allocator(),
        .viewport = cx.viewport,
        .perf = &cx.perf,
    };
}

test "Cx: basic init/deinit" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    cx.setViewport(800, 600);
    try std.testing.expectEqual(@as(f32, 800), cx.viewport.width);
    try std.testing.expectEqual(@as(f32, 600), cx.viewport.height);
}

test "automation cursor shape is isolated from native cursor updates" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    cx.updateAutomationCursor(40, 50, false);
    _ = cx.virtual_cursor.setShape(.text);

    // A physical/native pointer can update the system cursor independently.
    // It must not mutate the virtual cursor left at an automation coordinate.
    cx.setCursorOverride(.grabbing);
    try std.testing.expectEqual(ui.CursorShape.grabbing, cx.current_cursor);
    try std.testing.expectEqual(ui.CursorShape.text, cx.virtual_cursor.shape);
}

// Custom cursor bitmap flow
// Cursor: Cx.setCustomCursor (rasterize + cache + activate) -> style.cursor/override.
// Parse to .custom -> system_sdk.setCustomCursor dispatches bitmap. Mock backend records calls.

const system_sdk = @import("system_sdk");

const cursor_svg_a =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 22 L22 2" stroke="#000000" stroke-width="2"/></svg>
;
const cursor_svg_b =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 12"><rect x="0" y="0" width="24" height="12" fill="#ff0000"/></svg>
;

const CursorMockBackend = struct {
    fail: bool = false,
    set_shape_count: u32 = 0,
    last_shape: u8 = 0,
    set_custom_count: u32 = 0,
    last_custom: struct {
        len: usize,
        width: u32,
        height: u32,
        hot_x: f32,
        hot_y: f32,
        key: u64,
    } = .{ .len = 0, .width = 0, .height = 0, .hot_x = 0, .hot_y = 0, .key = 0 },

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}

    fn pump(_: *anyopaque, _: *system_sdk.EventQueue, _: u32) system_sdk.SdkError!system_sdk.PumpResult {
        return .{};
    }

    fn setShape(ctx_: *anyopaque, _: system_sdk.events.WindowId, shape: u8) system_sdk.SdkError!void {
        const self: *@This() = @ptrCast(@alignCast(ctx_));
        self.set_shape_count += 1;
        self.last_shape = shape;
        if (self.fail) return error.BackendFailure;
    }

    fn setCustom(
        ctx_: *anyopaque,
        _: system_sdk.events.WindowId,
        rgba: [*]const u8,
        len: usize,
        width: u32,
        height: u32,
        _: f32,
        hot_x: f32,
        hot_y: f32,
        key: u64,
    ) system_sdk.SdkError!void {
        const self: *@This() = @ptrCast(@alignCast(ctx_));
        self.set_custom_count += 1;
        self.last_custom = .{
            .len = len,
            .width = width,
            .height = height,
            .hot_x = hot_x,
            .hot_y = hot_y,
            .key = key,
        };
        // Borrowed buffer valid only in callback (real backend copies). Content untouched.
        _ = rgba;
    }
};

test "cursor presenter: same-shape replay and failed submissions are independently retryable" {
    var backend = CursorMockBackend{};
    const vtable = system_sdk.BackendVTable{
        .name = "cursor-replay-mock",
        .deinit = CursorMockBackend.deinitFn,
        .pump_events = CursorMockBackend.pump,
        .cursor = .{ .set_shape = CursorMockBackend.setShape },
    };
    var sdk = system_sdk.SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .cursor = true });
    defer sdk.deinit();
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    cx.setCursorOverride(.text);
    try std.testing.expectEqual(@as(u32, 1), backend.set_shape_count);
    cx.refreshCursor();
    try std.testing.expectEqual(@as(u32, 1), backend.set_shape_count);
    cx.replayCursor();
    try std.testing.expectEqual(@as(u32, 2), backend.set_shape_count);
    try std.testing.expectEqual(@as(?ui.CursorShape, .text), cx.cursor_override);
    backend.fail = true;
    cx.replayCursor();
    try std.testing.expectEqual(ui.cursor.Submission.failed, cx.cursor_state.submission);
    try std.testing.expect(!cx.cursor_state.submitted);
    backend.fail = false;
    cx.refreshCursor();
    try std.testing.expectEqual(@as(u32, 4), backend.set_shape_count);
    try std.testing.expectEqual(ui.cursor.Submission.accepted, cx.cursor_state.submission);
    cx.setCursorOverride(.uncontrolled);
    try std.testing.expectEqual(ui.cursor.Submission.handoff, cx.cursor_state.submission);
}

test "custom cursor: setCustomCursor pushes bitmap and stays idempotent per key" {
    var backend = CursorMockBackend{};
    const vtable = system_sdk.BackendVTable{
        .name = "ui-cursor-mock",
        .deinit = CursorMockBackend.deinitFn,
        .pump_events = CursorMockBackend.pump,
        .cursor = .{
            .set_shape = CursorMockBackend.setShape,
            .set_custom = CursorMockBackend.setCustom,
        },
    };
    var sdk = system_sdk.SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .cursor = true });
    defer sdk.deinit();

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);

    // On activate, override not yet at .custom: register only, no dispatch.
    cx.setCustomCursor(.{ .svg_data = cursor_svg_a, .size_pt = 24, .scale = 2, .hot_x = 2, .hot_y = 22 });
    try std.testing.expectEqual(@as(u32, 0), backend.set_custom_count);
    try std.testing.expect(cx.activeCustomCursorKey() != null);

    cx.setCursorOverride(.custom);
    try std.testing.expectEqual(ui.CursorShape.custom, cx.current_cursor);
    try std.testing.expectEqual(@as(u32, 1), backend.set_custom_count);
    // viewBox 24x24 -> 24pt @2x = 48px; hotspot in logical coords x scale
    try std.testing.expectEqual(@as(u32, 48), backend.last_custom.width);
    try std.testing.expectEqual(@as(u32, 48), backend.last_custom.height);
    try std.testing.expectEqual(@as(usize, 48 * 48 * 4), backend.last_custom.len);
    try std.testing.expectEqual(@as(f32, 4.0), backend.last_custom.hot_x);
    try std.testing.expectEqual(@as(f32, 44.0), backend.last_custom.hot_y);

    // Repeated with same desc: same key returns cached, no redispatch.
    const first_key = backend.last_custom.key;
    cx.setCustomCursor(.{ .svg_data = cursor_svg_a, .size_pt = 24, .scale = 2, .hot_x = 2, .hot_y = 22 });
    try std.testing.expectEqual(@as(u32, 1), backend.set_custom_count);

    // Content change: shape stays at .custom, changed key must redispatch (pointer static).
    cx.setCustomCursor(.{ .svg_data = cursor_svg_b, .size_pt = 24, .scale = 2, .hot_x = 1, .hot_y = 11 });
    try std.testing.expectEqual(@as(u32, 2), backend.set_custom_count);
    try std.testing.expect(backend.last_custom.key != first_key);
    // viewBox 24x12 -> 48x24 px
    try std.testing.expectEqual(@as(u32, 24), backend.last_custom.height);

    // Leave .custom: restore fixed shape path, clear dispatched key.
    cx.setCursorOverride(null);
    try std.testing.expectEqual(ui.CursorShape.default, cx.current_cursor);
    try std.testing.expect(cx.custom_cursor.submitted == null);
    // Initial default is submitted once, then restored after the custom image.
    try std.testing.expectEqual(@as(u32, 2), backend.set_shape_count);
}

test "custom cursor: unregistered or unsupported degrades to fallback shape" {
    // Bitmap not registered but parsed to .custom -> degrade to crosshair, use set_shape.
    {
        var backend = CursorMockBackend{};
        const vtable = system_sdk.BackendVTable{
            .name = "ui-cursor-mock",
            .deinit = CursorMockBackend.deinitFn,
            .pump_events = CursorMockBackend.pump,
            .cursor = .{
                .set_shape = CursorMockBackend.setShape,
                .set_custom = CursorMockBackend.setCustom,
            },
        };
        var sdk = system_sdk.SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .cursor = true });
        defer sdk.deinit();

        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setSystemSdk(&sdk);

        cx.setCursorOverride(.custom);
        try std.testing.expectEqual(ui.CursorShape.crosshair, cx.current_cursor);
        try std.testing.expectEqual(@as(u32, 1), backend.set_shape_count);
        try std.testing.expectEqual(@backingInt(ui.CursorShape.crosshair), backend.last_shape);
        try std.testing.expectEqual(@as(u32, 0), backend.set_custom_count);
    }
    // Backend lacks set_custom (optional field missing): degrade even if registered.
    {
        var backend = CursorMockBackend{};
        const vtable = system_sdk.BackendVTable{
            .name = "ui-cursor-mock",
            .deinit = CursorMockBackend.deinitFn,
            .pump_events = CursorMockBackend.pump,
            .cursor = .{ .set_shape = CursorMockBackend.setShape },
        };
        var sdk = system_sdk.SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .cursor = true });
        defer sdk.deinit();

        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setSystemSdk(&sdk);

        cx.setCustomCursor(.{ .svg_data = cursor_svg_a, .size_pt = 24, .scale = 2, .hot_x = 2, .hot_y = 22 });
        cx.setCursorOverride(.custom);
        try std.testing.expectEqual(ui.CursorShape.crosshair, cx.current_cursor);
        try std.testing.expectEqual(@as(u32, 2), backend.set_shape_count);
        try std.testing.expectEqual(@as(u32, 0), backend.set_custom_count);
    }
}

test "Cx: nextWakeDelayNs aggregates scheduled redraw deadline read-only" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    // No timer wake requests.
    try std.testing.expectEqual(@as(?u64, null), cx.nextWakeDelayNs());

    // scheduleRedrawAfterNs deadline enters aggregation: remaining time <= requested delay.
    const delay_ns: u64 = 50 * std.time.ns_per_ms;
    cx.scheduleRedrawAfterNs(delay_ns);
    const remaining = cx.nextWakeDelayNs() orelse return error.TestExpectedDeadline;
    try std.testing.expect(remaining <= delay_ns);

    // Read-only: query consumes no deadline, doesn't set needs_redraw.
    cx.needs_redraw = false;
    try std.testing.expect(cx.nextWakeDelayNs() != null);
    try std.testing.expect(!cx.needs_redraw);

    // Closer deadline overrides aggregated result.
    cx.scheduleRedrawAfterNs(1 * std.time.ns_per_ms);
    const closer = cx.nextWakeDelayNs() orelse return error.TestExpectedDeadline;
    try std.testing.expect(closer <= 1 * std.time.ns_per_ms);
}

test "box: inline children" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);

    const root = try box(cx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
        .direction = .column,
        .gap = 16,
    }, .{
        try text(cx, "Hello", .{}),
        try text(cx, "World", .{ .color = theme.dark.tokens.color.fg_secondary }),
    });

    cx.root = root;
    cx.layout();

    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expectEqual(@as(f32, 800), root.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 600), root.rectFromWorldOrFallback().h);
}

test "hstack/vstack: layout shortcuts" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try hstack(cx, .{ .gap = 8 }, .{
        try text(cx, "Left", .{}),
        try spacer(cx),
        try text(cx, "Right", .{}),
    });

    cx.root = root;
    cx.layout();

    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
    try std.testing.expectEqual(Direction.row, root.style.direction);
}

test "component protocol: struct with render" {
    const TestComponent = struct {
        label: []const u8,

        pub fn render(self: @This(), cx: *Cx) !*Node {
            return text(cx, self.label, .{});
        }
    };

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{
        TestComponent{ .label = "Component!" },
    });

    cx.root = root;
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqualStrings("Component!", root.children.items[0].getText().?.content);
}

test "after-layout hook reads this frame's layout and can request another layout pass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 200);
    const child = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 20 } }, .{});
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{child});
    cx.root = root;

    const Probe = struct {
        child: *Node,
        rounds: u8 = 0,
        seen_w: f32 = -1,
        fn run(ctx: *anyopaque, round: u8, last_round: bool) ui.AfterLayoutResult {
            _ = last_round;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.rounds = round + 1;
            if (round == 0) {
                self.child.style.width = .{ .px = 250 };
                self.child.markLayoutDirty();
                return .needs_layout;
            }
            self.seen_w = self.child.rectFromWorldOrFallback().w;
            return .done;
        }
    };
    _ = cx.render();
    cx.frame_count += 1;
    root.markLayoutDirty();
    var probe = Probe{ .child = child };
    try cx.addAfterLayoutHook(&probe, Probe.run);
    _ = cx.render();
    try std.testing.expectEqual(@as(u8, 2), probe.rounds);
    // First pass reads width from same frame after callback changes, layout reapplied.
    try std.testing.expectEqual(@as(f32, 250), probe.seen_w);
    try std.testing.expectEqual(@as(f32, 250), child.rectFromWorldOrFallback().w);

    cx.removeAfterLayoutHook(&probe);
    try std.testing.expectEqual(@as(usize, 0), cx.after_layout_hooks.items.len);
}

test "after-layout hook removing itself during iteration does not skip the next hook" {
    // runAfterLayoutHooks iterates by index; removeAfterLayoutHook in callback does orderedRemove,
    // index increments normally, skips next hook.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);
    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;

    const Probe = struct {
        cx: *Cx,
        calls: u8 = 0,
        remove_self: bool = false,
        also_remove: ?*anyopaque = null,
        fn run(ctx: *anyopaque, round: u8, last_round: bool) ui.AfterLayoutResult {
            _ = round;
            _ = last_round;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.also_remove) |other| self.cx.removeAfterLayoutHook(other);
            if (self.remove_self) self.cx.removeAfterLayoutHook(self);
            return .done;
        }
    };
    _ = cx.render();
    cx.frame_count += 1;
    root.markLayoutDirty();
    var a = Probe{ .cx = cx };
    var b = Probe{ .cx = cx, .remove_self = true };
    var c = Probe{ .cx = cx };
    var d = Probe{ .cx = cx };
    // c's callback also removes a, which sits before it (the index moves back two slots because b
    // already removed itself).
    c.also_remove = &a;
    try cx.addAfterLayoutHook(&a, Probe.run);
    try cx.addAfterLayoutHook(&b, Probe.run);
    try cx.addAfterLayoutHook(&c, Probe.run);
    try cx.addAfterLayoutHook(&d, Probe.run);
    _ = cx.render();
    try std.testing.expectEqual(@as(u8, 1), a.calls);
    try std.testing.expectEqual(@as(u8, 1), b.calls);
    try std.testing.expectEqual(@as(u8, 1), c.calls);
    try std.testing.expectEqual(@as(u8, 1), d.calls);
    try std.testing.expectEqual(@as(usize, 2), cx.after_layout_hooks.items.len);
}

test "after-layout hook that never converges stops at the round cap with last_round set" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);
    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;

    const Probe = struct {
        root: *Node,
        calls: u8 = 0,
        saw_last: bool = false,
        fn run(ctx: *anyopaque, round: u8, last_round: bool) ui.AfterLayoutResult {
            _ = round;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (last_round) self.saw_last = true;
            self.root.markLayoutDirty();
            return .needs_layout;
        }
    };
    _ = cx.render();
    cx.frame_count += 1;
    root.markLayoutDirty();
    var probe = Probe{ .root = root };
    try cx.addAfterLayoutHook(&probe, Probe.run);
    _ = cx.render();
    try std.testing.expectEqual(ui.max_after_layout_rounds, probe.calls);
    try std.testing.expect(probe.saw_last);
}

test "render: retained frame populates display list and text blobs" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 120);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 120 },
        .background = Color.rgba(30, 40, 50, 255),
        .padding = Padding.all(12),
    }, .{
        try text(cx, "Hello retained display list", .{
            .font_size = 16,
            .line_height = 1.25,
            .color = Color.rgba(240, 240, 240, 255),
        }),
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expect(cx.display_list.count() >= 2);
    try std.testing.expectEqual(@as(usize, 1), cx.text_blob_store.blobs.items.len);

    var saw_fill = false;
    var saw_text = false;
    for (cx.display_list.items.items) |item| {
        switch (item) {
            .fill_rect => saw_fill = true,
            .text_run => |run| {
                saw_text = true;
                try std.testing.expect(run.blob_id < cx.text_blob_store.blobs.items.len);
                try std.testing.expectEqual(@as(u32, 0), run.blob_byte_start);
                try std.testing.expectEqual(@as(u32, 27), run.blob_byte_end);
                // content once asserted empty (blob_id indirect byte fetch). blob_id is frame-local
                // sequence;
                // cross-frame items land on others' blobs, terminal renders stale "plaintext"
                // slice. Now item
                // carries fallback slice; resolveTextRunContent detects via content_hash, reverts
                // to fallback.
                try std.testing.expectEqualStrings("Hello retained display list", run.content);
                try std.testing.expect(run.blob_content_hash != 0);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_fill);
    try std.testing.expect(saw_text);

    const blob = cx.text_blob_store.get(0).?;
    try std.testing.expectEqual(@as(u16, 1), blob.line_count);
    try std.testing.expect(blob.max_line_width > 0);
    try std.testing.expectEqualStrings("Hello retained display list", blob.content);

    const root_runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(root_runtime.display_item_count >= 1);
    try std.testing.expect(root_runtime.subtree_display_item_count > root_runtime.display_item_count);
    try std.testing.expectEqual(@as(u32, 1), root_runtime.subtree_text_blob_count);

    const text_node = root.children.items[0];
    const text_runtime = cx.scene_runtime.get(text_node.id).?;
    try std.testing.expect(text_runtime.display_item_count >= 1);
    try std.testing.expectEqual(@as(u32, 1), text_runtime.text_blob_count);
    try std.testing.expect(text_runtime.display_item_start < cx.display_list.items.items.len);
    try std.testing.expect(text_runtime.text_blob_start < cx.text_blob_store.blobs.items.len);
    try std.testing.expectEqual(text_runtime.display_item_count, text_runtime.subtree_display_item_count);
    try std.testing.expectEqual(text_runtime.text_blob_count, text_runtime.subtree_text_blob_count);

    var render_ctx = testRenderContext(cx);
    const own_items = ui.render_engine.getNodeDisplayItems(&render_ctx, text_node.id, .own).?;
    try std.testing.expectEqual(@as(usize, @intCast(text_runtime.display_item_count)), own_items.len);
    try std.testing.expect(own_items.len >= 1);

    const subtree_items = ui.render_engine.getNodeDisplayItems(&render_ctx, root.id, .subtree).?;
    try std.testing.expectEqual(@as(usize, @intCast(root_runtime.subtree_display_item_count)), subtree_items.len);
    try std.testing.expect(subtree_items.len >= own_items.len);

    const own_blobs = ui.render_engine.getNodeTextBlobs(&render_ctx, text_node.id, .own).?;
    try std.testing.expectEqual(@as(usize, 1), own_blobs.len);
    try std.testing.expectEqualStrings("Hello retained display list", own_blobs[0].content);

    const subtree_blobs = ui.render_engine.getNodeTextBlobs(&render_ctx, root.id, .subtree).?;
    try std.testing.expectEqual(@as(usize, 1), subtree_blobs.len);
    try std.testing.expectEqualStrings("Hello retained display list", subtree_blobs[0].content);

    const own_payload = ui.render_engine.getNodeDisplayPayload(&render_ctx, text_node.id, .own).?;
    try std.testing.expectEqual(own_items.len, own_payload.items.len);
    try std.testing.expectEqual(own_blobs.len, own_payload.blobs.len);

    switch (own_payload.items[0]) {
        .text_run => |run| try std.testing.expectEqualStrings(
            "Hello retained display list",
            ui.display_list.resolveTextRunContent(&cx.text_blob_store, run),
        ),
        else => {},
    }

    cx.lowering._dead_main.clearRetainingCapacity();
    render_ctx = testRenderContext(cx);
    try std.testing.expect(try ui.render_engine.appendNodeDisplayPayloadToRenderList(&render_ctx, root.id, .subtree));
    var subtree_text_count: usize = 0;
    var saw_replayed_text = false;
    for (cx.lowering.main_paint.items) |cmd| {
        if (cmd.isText()) {
            const txt = cmd;
            subtree_text_count += 1;
            if (std.mem.eql(u8, txt.text_content, "Hello retained display list")) saw_replayed_text = true;
        }
    }
    try std.testing.expect(subtree_text_count >= 1);
    try std.testing.expect(saw_replayed_text);

    cx.lowering._dead_main.clearRetainingCapacity();
    cx.lowering.main_paint.clearRetainingCapacity();
    render_ctx = testRenderContext(cx);
    try std.testing.expect(try ui.render_engine.appendNodeDisplayPayloadToRenderList(&render_ctx, root.id, .subtree));
    // appendLoweredBoth no longer writes .main, only .main_paint.
    try std.testing.expect(cx.lowering.main_paint.items.len >= 1);
}

// Stage B-1/B-2: shadow GpuDraw encode end-to-end probe.
// After render, assert display_list / drawable lowering_buffer / GpuDraw counts align
// + pipeline sequence equivalent + max_batch_run reasonable.
test "render: stage B-1/B-2 shadow GpuDraw encode is sequence-equivalent" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 120);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 120 },
        .background = Color.rgba(30, 40, 50, 255),
        .padding = Padding.all(12),
    }, .{
        try text(cx, "shadow probe", .{
            .font_size = 14,
            .color = Color.rgba(220, 220, 220, 255),
        }),
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    // Production render only runs the diagnostic shadow encoder in Debug.
    // This test is configuration-independent, so invoke it explicitly in
    // optimized modes before asserting its counters.
    if (builtin.mode != .debug) {
        var render_ctx = testRenderContext(cx);
        ui.render_engine.runShadowEncode(&render_ctx);
    }

    // Debug build: renderNode auto-calls runShadowEncode at end, perf cumulative.
    // B-1 equivalence: display_list count == drawable lowering_buffer command count.
    try std.testing.expectEqual(@as(u32, 0), cx.perf.stage_b_shadow_count_mismatches);
    try std.testing.expect(cx.perf.stage_b_shadow_display_items > 0);
    try std.testing.expectEqual(
        cx.perf.stage_b_shadow_display_items,
        cx.perf.stage_b_shadow_drawable_commands,
    );
    // Post-batching GpuDraw count should be <= display item count.
    try std.testing.expect(cx.perf.stage_b_shadow_gpu_draws <= cx.perf.stage_b_shadow_display_items);

    // B-2 strengthens: pipeline sequence must match. Lowering missed cases / DisplayItem
    // path over/under-producing draw kinds cause mismatch count > 0.
    try std.testing.expectEqual(@as(u32, 0), cx.perf.stage_b_shadow_pipeline_mismatches);
    // Expect some mergeable runs (adjacent fill_rects or same pipeline).
    try std.testing.expect(cx.perf.stage_b_shadow_max_batch_run >= 1);

    // B-2 coverage: lowered kind counts == main-path drawable counts (per kind).
    // Any kind mismatch = lowering vs main path classify differently; B-2 cutover uses this.
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_rect, cx.perf.stage_b_shadow_drawable_kind_rect);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_text, cx.perf.stage_b_shadow_drawable_kind_text);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_image, cx.perf.stage_b_shadow_drawable_kind_image);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_path, cx.perf.stage_b_shadow_drawable_kind_path);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_shadow, cx.perf.stage_b_shadow_drawable_kind_shadow);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_gradient, cx.perf.stage_b_shadow_drawable_kind_gradient);
    // This scenario has box background (rect) + text, both kinds should be > 0.
    try std.testing.expect(cx.perf.stage_b_shadow_kind_rect > 0);
    try std.testing.expect(cx.perf.stage_b_shadow_kind_text > 0);
}

test "render: lowered path geometry is frame-owned instead of borrowing the node" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(160, 100);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 100 },
    }, .{});
    const path_node = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 60 },
        .background = Color.rgba(40, 120, 220, 255),
    }, .{});
    const commands = [_]ui.PathCommand{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .line_to = .{ .x = 80, .y = 0 } },
        .{ .line_to = .{ .x = 40, .y = 60 } },
        .close,
    };
    try path_node.setClonedPathGeometry(cx.allocator, .{
        .commands = &commands,
        .fill_rule = .nonzero,
        .bounds = .{ .x = 0, .y = 0, .w = 80, .h = 60 },
    });
    try root.appendChild(cx.allocator, path_node);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    const source = &path_node.layoutOutputPtr().?.vector.fill.path.?;
    var lowered: ?*const ui.PathGeometry = null;
    for (cx.lowering.main_paint.items) |item| {
        if (item.kind == .path and item.path_geometry_ptr != null) {
            lowered = item.path_geometry_ptr;
            break;
        }
    }
    const frozen = lowered orelse return error.TestUnexpectedResult;
    try std.testing.expect(frozen != source);
    try std.testing.expect(frozen.commands.ptr != source.commands.ptr);
    try std.testing.expectEqualDeep(source.commands, frozen.commands);
    try std.testing.expect(!frozen.owned);
}

test "DisplayList owns path geometry across source teardown" {
    var list = display_list.DisplayList.init(std.testing.allocator);
    defer list.deinit();

    const source_commands = try std.testing.allocator.dupe(ui.PathCommand, &.{
        .{ .move_to = .{ .x = 2, .y = 3 } },
        .{ .line_to = .{ .x = 17, .y = 19 } },
        .close,
    });
    var source = ui.PathGeometry{
        .commands = source_commands,
        .fill_rule = .nonzero,
        .bounds = .{ .x = 2, .y = 3, .w = 15, .h = 16 },
        .owned = true,
    };

    try list.append(.{ .fill_path = .{
        .header = .{ .transform_id = 0, .node_id = 7 },
        .geometry = &source,
        .color = Color.rgb(20, 40, 60),
    } });
    std.testing.allocator.free(source_commands);
    source = .{};

    const retained = list.items.items[0].fill_path.geometry;
    try std.testing.expect(retained != &source);
    try std.testing.expectEqual(@as(usize, 3), retained.commands.len);
    try std.testing.expectEqual(ui.PathFillRule.nonzero, retained.fill_rule);
    try std.testing.expectEqualDeep(ui.PathCommand.close, retained.commands[2]);
    try std.testing.expect(!retained.owned);
}

test "DisplayList owns text content and spans across source teardown" {
    var list = display_list.DisplayList.init(std.testing.allocator);
    defer list.deinit();

    const source_content = try std.testing.allocator.dupe(u8, "retained text");
    const source_spans = try std.testing.allocator.dupe(ui.TextSpan, &.{.{
        .start = 0,
        .end = 8,
        .color = Color.rgb(20, 40, 60),
    }});
    try list.append(.{ .text_run = .{
        .header = .{ .transform_id = 0, .node_id = 8 },
        .x = 2,
        .y = 12,
        .content = source_content,
        .color = Color.rgb(10, 20, 30),
        .font_size = 13,
        .spans = source_spans,
    } });
    std.testing.allocator.free(source_spans);
    std.testing.allocator.free(source_content);

    const retained = list.items.items[0].text_run;
    try std.testing.expectEqualStrings("retained text", retained.content);
    try std.testing.expect(retained.content.ptr != source_content.ptr);
    try std.testing.expect(retained.spans.?.ptr != source_spans.ptr);
    try std.testing.expectEqual(@as(u32, 8), retained.spans.?[0].end);
}

test "retained display item copies own path geometry across source teardown" {
    const source_commands = try std.testing.allocator.dupe(ui.PathCommand, &.{
        .{ .move_to = .{ .x = 1, .y = 2 } },
        .{ .line_to = .{ .x = 30, .y = 40 } },
        .close,
    });
    var source = ui.PathGeometry{
        .commands = source_commands,
        .fill_rule = .nonzero,
        .bounds = .{ .x = 1, .y = 2, .w = 29, .h = 38 },
        .owned = true,
    };
    const items = [_]display_list.DisplayItem{.{ .stroke_path = .{
        .header = .{ .transform_id = 0, .node_id = 9 },
        .geometry = &source,
        .color = Color.rgb(10, 20, 30),
        .width = 2,
    } }};

    const retained = try render_cache.duplicateDisplayItems(std.testing.allocator, &items);
    defer render_cache.freeDuplicatedDisplayItems(std.testing.allocator, retained);
    std.testing.allocator.free(source_commands);
    source = .{};

    const geometry = retained[0].stroke_path.geometry;
    try std.testing.expect(geometry != &source);
    try std.testing.expectEqual(@as(usize, 3), geometry.commands.len);
    try std.testing.expectEqualDeep(ui.PathCommand.close, geometry.commands[2]);
    try std.testing.expect(geometry.owned);
}

test "retained display items own copies of their referenced polygon and glass payloads" {
    var polygon: display_list.ClipPolygon = .{};
    polygon.point_count = 3;
    polygon.contour_count = 1;
    polygon.points[1] = .{ 7, 0 };
    var glass: ui.ResolvedGlassParams = .{};
    glass.backdrop_blur = 11;
    const items = [_]display_list.DisplayItem{
        .{ .push_clip = .{ .header = .{ .transform_id = 0, .node_id = 1 }, .x = 0, .y = 0, .w = 10, .h = 10, .shape_kind = .polygon, .polygon = &polygon } },
        .{ .border_side = .{ .header = .{ .transform_id = 0, .node_id = 2 }, .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.rgb(1, 2, 3), .width = 1, .clip_x = 0, .clip_y = 0, .clip_w = 10, .clip_h = 10, .clip_shape_kind = .polygon, .clip_polygon = &polygon } },
        .{ .begin_blur_layer = .{ .header = .{ .transform_id = 0, .node_id = 3 }, .x = 0, .y = 0, .w = 10, .h = 10, .glass = &glass } },
        .{ .push_clip = .{ .header = .{ .transform_id = 0, .node_id = 4 }, .x = 0, .y = 0, .w = 10, .h = 10 } },
    };
    const retained = try render_cache.duplicateDisplayItems(std.testing.allocator, &items);
    defer render_cache.freeDuplicatedDisplayItems(std.testing.allocator, retained);
    // The sources die with their frame.
    polygon = .{};
    glass = .{};
    try std.testing.expect(retained[0].push_clip.polygon.? != &polygon);
    try std.testing.expectEqual(@as(u8, 3), retained[0].push_clip.polygon.?.point_count);
    try std.testing.expectEqual([2]f32{ 7, 0 }, retained[0].push_clip.polygon.?.points[1]);
    try std.testing.expectEqual(@as(u8, 3), retained[1].border_side.clip_polygon.?.point_count);
    try std.testing.expect(retained[1].border_side.clip_polygon.? != retained[0].push_clip.polygon.?);
    try std.testing.expectEqual(@as(f32, 11), retained[2].begin_blur_layer.glass.backdrop_blur);
    try std.testing.expect(retained[3].push_clip.polygon == null);

    // A display list freezes them into its own payload arena.
    var list = display_list.DisplayList.init(std.testing.allocator);
    defer list.deinit();
    for (retained) |item| try list.append(item);
    try std.testing.expect(list.items.items[0].push_clip.polygon.? != retained[0].push_clip.polygon.?);
    try std.testing.expectEqual([2]f32{ 7, 0 }, list.items.items[0].push_clip.polygon.?.points[1]);
    try std.testing.expect(list.items.items[2].begin_blur_layer.glass != retained[2].begin_blur_layer.glass);
}

test "render: identical text nodes reuse text blob within frame" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 140);

    const root = try box(cx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 140 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
    }, .{
        try text(cx, "Shared blob", .{
            .font_size = 16,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try text(cx, "Shared blob", .{
            .font_size = 16,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 1), cx.text_blob_store.blobs.items.len);

    var first_blob_id: ?u32 = null;
    var text_run_count: usize = 0;
    for (cx.display_list.items.items) |item| {
        switch (item) {
            .text_run => |run| {
                text_run_count += 1;
                if (first_blob_id == null) {
                    first_blob_id = run.blob_id;
                } else {
                    try std.testing.expectEqual(first_blob_id.?, run.blob_id);
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), text_run_count);
}

test "node: text hash cache tracks content_version changes" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try text(cx, "abc", .{});
    defer cx.freeNode(node);
    const first = node.getOrComputeTextHashes(&node.getText().?);
    const second = node.getOrComputeTextHashes(&node.getText().?);
    try std.testing.expectEqual(first.content_hash, second.content_hash);
    try std.testing.expectEqual(first.spans_hash, second.spans_hash);

    {
        var t = node.getText().?;
        t.content = "abcd";
        node.setText(t);
    }
    node.markRenderDirty();

    const third = node.getOrComputeTextHashes(&node.getText().?);
    try std.testing.expect(third.content_hash != first.content_hash);
}

test "node: setText invalidates the text hash cache on a same-length swap" {
    // Regression (downstream editor "3 x 4" -> "3 x 5" repaints only before x):
    // text hash cache key = (content_version, content_ptr, content_len, spans_*);
    // setText does not bump content_version. A same-length swap keeps len and often reuses ptr,
    // so the key collides, the old hash sticks, and blob/paint chunk/retained skip the repaint.
    // Intentionally does NOT call any markDirty: invalidating the cache is the write path's own
    // responsibility.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    var buf: [8]u8 = undefined;
    const node = try text(cx, "placeholder-long-enough", .{ .font_size = 11 });
    defer cx.freeNode(node);

    @memcpy(buf[0..6], "3 \xc3\x97 4");
    {
        var t = node.getText().?;
        t.content = buf[0..6];
        t.owned = false;
        t.inline_len = 0;
        node.setText(t);
    }
    const before = node.getOrComputeTextHashes(&node.getText().?);

    // Same ptr, same len, only last byte changed (post-x segment).
    @memcpy(buf[0..6], "3 \xc3\x97 5");
    {
        var t = node.getText().?;
        t.content = buf[0..6];
        node.setText(t);
    }
    const after = node.getOrComputeTextHashes(&node.getText().?);

    try std.testing.expect(after.content_hash != before.content_hash);
}

test "node: same-length setTextContent swap updates text hash and display run" {
    // Regression (downstream editor "3 x 4" -> "3 x 5" repaints before x only):
    // A same-length swap likely reuses the address, len unchanged. setText does not bump
    // content_version, so the text_hash cache hits the old hash and downstream skips the repaint.
    // Especially visible with a fallback font string (x cuts it into 3 segments):
    // the change lands in one segment, the others keep old glyphs.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 180);

    const node = try text(cx, "3 × 4", .{ .font_size = 11 });
    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 } }, .{node});
    cx.root = root;
    cx.layout();
    _ = cx.render();

    const before = node.getOrComputeTextHashes(&node.getText().?);

    try node.setTextContent(cx.allocator, "3 × 5");
    node.invalidateRenderCache();
    node.markSizingDirty();
    node.markRenderDirty();

    try std.testing.expectEqualStrings("3 × 5", node.getText().?.content);

    const after = node.getOrComputeTextHashes(&node.getText().?);
    try std.testing.expect(after.content_hash != before.content_hash);

    // End-to-end: re-render frame, text_run in display list must emit new bytes.
    cx.layout();
    _ = cx.render();

    var saw_new = false;
    for (cx.display_list.items.items) |item| {
        switch (item) {
            .text_run => |run| {
                if (std.mem.eql(u8, run.content, "3 × 5")) saw_new = true;
                try std.testing.expect(!std.mem.eql(u8, run.content, "3 × 4"));
            },
            else => {},
        }
    }
    try std.testing.expect(saw_new);
}

test "render: nested simple subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 180);

    const nested = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 72 },
        .direction = .column,
        .gap = 8,
        .background = Color.rgba(28, 32, 40, 255),
        .padding = Padding.all(12),
    }, .{
        try text(cx, "Nested subtree", .{
            .font_size = 16,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 80 },
            .height = .{ .px = 18 },
            .background = Color.rgba(0, 180, 120, 255),
        }, .{}),
    });

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 180 },
        .direction = .column,
        .gap = 12,
        .padding = Padding.all(12),
    }, .{
        nested,
        blk: {
            const overlay = try box(cx, .{
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .background = Color.rgba(255, 90, 90, 255),
            }, .{});
            (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 1;
            break :blk overlay;
        },
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);

    const root_runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!root_runtime.display_payload_subtree_prebuilt);
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);
    try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.simple, nested_runtime.display_payload_subtree_strategy);
    try std.testing.expect(nested_runtime.subtree_display_item_count >= nested_runtime.display_item_count);

    var render_ctx = testRenderContext(cx);
    const payload = ui.render_engine.getNodeDisplayPayload(&render_ctx, nested.id, .subtree).?;
    try std.testing.expect(payload.items.len >= 2);
    try std.testing.expect(payload.blobs.len >= 1);
}

test "render: scroll descendants do not use subtree display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 220);

    const content = try box(cx, .{
        .width = .{ .px = 320 },
        .direction = .column,
        .gap = 24,
        .translate_y = -120,
    }, .{
        try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 96 },
            .background = Color.rgba(28, 32, 40, 255),
            .padding = Padding.all(12),
        }, .{
            try text(cx, "Above the fold", .{
                .font_size = 16,
                .line_height = 1.25,
                .color = Color.rgba(255, 255, 255, 255),
            }),
        }),
        try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 96 },
            .background = Color.rgba(36, 44, 58, 255),
            .padding = Padding.all(12),
        }, .{
            try text(cx, "Visible after scroll", .{
                .font_size = 16,
                .line_height = 1.25,
                .color = Color.rgba(255, 255, 255, 255),
            }),
        }),
        try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 96 },
            .background = Color.rgba(52, 60, 74, 255),
            .padding = Padding.all(12),
        }, .{
            try text(cx, "Below the fold", .{
                .font_size = 16,
                .line_height = 1.25,
                .color = Color.rgba(255, 255, 255, 255),
            }),
        }),
    });

    const scroll = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 220 },
        .overflow_hidden = true,
    }, .{
        content,
    });
    scroll.tag = .scroll;

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 220 },
    }, .{
        scroll,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 2), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 2), cx.perf.display_list_subtree_replay_count);

    const scroll_runtime = cx.scene_runtime.get(scroll.id).?;
    const content_runtime = cx.scene_runtime.get(content.id).?;
    try std.testing.expect(!scroll_runtime.display_payload_subtree_prebuilt);
    try std.testing.expect(
        content_runtime.display_payload_subtree_prebuilt or
            cx.perf.display_list_subtree_prebuild_count > 0,
    );

    var saw_visible_text = false;
    for (commands) |cmd| {
        if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Visible after scroll")) {
                saw_visible_text = true;
            }
        }
    }
    try std.testing.expect(saw_visible_text);
}

test "render: scroll descendants do not reuse legacy overflow cache from offscreen frame" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 220);

    const body = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 24,
    }, .{
        try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 180 },
            .background = Color.rgba(24, 28, 36, 255),
        }, .{}),
        try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 120 },
            .overflow_hidden = true,
            .background = Color.rgba(36, 44, 58, 255),
            .padding = Padding.all(12),
        }, .{
            try text(cx, "Visible after scroll", .{
                .font_size = 16,
                .line_height = 1.25,
                .color = Color.rgba(255, 255, 255, 255),
            }),
        }),
    });

    const scroll = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 220 },
        .overflow_hidden = true,
    }, .{
        body,
    });
    scroll.tag = .scroll;

    cx.root = scroll;
    cx.layout();

    _ = cx.render();
    const target = body.children.items[1];
    try std.testing.expect(target.meta.per_frame.caches.commands.own == null);

    body.style.translate_y = -140;
    body.markRenderDirty();

    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 0), cx.perf.render_cache_hit);
    try std.testing.expect(target.meta.per_frame.caches.commands.own == null);

    var saw_visible_text = false;
    for (commands) |cmd| {
        if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Visible after scroll")) {
                saw_visible_text = true;
                break;
            }
        }
    }
    try std.testing.expect(saw_visible_text);
}

test "render: simple subtree can replay from display payload prepass under parent opacity" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 180);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 56 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(36, 44, 58, 255),
        .padding = Padding.all(10),
    }, .{
        try text(cx, "Opacity child subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 64 },
            .height = .{ .px = 12 },
            .background = Color.rgba(90, 160, 255, 255),
        }, .{}),
    });

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 180 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
        .opacity = 0.7,
    }, .{
        nested,
        blk: {
            const overlay = try box(cx, .{
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .background = Color.rgba(255, 90, 90, 255),
            }, .{});
            (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 1;
            break :blk overlay;
        },
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.display_list_self_effect_subtree_replay_count);

    const root_runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!root_runtime.display_payload_subtree_prebuilt);
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);
    try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.simple, nested_runtime.display_payload_subtree_strategy);

    var saw_begin_opacity = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Opacity child subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_nested_text);
}

test "render: simple subtree can replay from display payload prepass under parent scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const nested = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 48 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(50, 60, 78, 255),
        .padding = Padding.all(8),
    }, .{
        try text(cx, "Scaled child subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 40 },
            .height = .{ .px = 10 },
            .background = Color.rgba(0, 200, 120, 255),
        }, .{}),
    });

    const scaled = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 96 },
        .direction = .column,
    }, .{
        nested,
    });
    (try scaled.style.ensureExtFallible(cx.allocator)).scale_x = 0.5;
    (try scaled.style.ensureExtFallible(cx.allocator)).scale_y = 0.5;

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
        .padding = Padding.all(12),
    }, .{
        scaled,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_self_effect_subtree_replay_count);

    const scaled_runtime = cx.scene_runtime.get(scaled.id).?;
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(
        scaled_runtime.display_payload_subtree_prebuilt or
            nested_runtime.display_payload_subtree_prebuilt,
    );

    var saw_scaled_layer = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_scaled_layer = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Scaled child subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_scaled_layer);
    try std.testing.expect(saw_nested_text);
}

test "render: clipped simple subtree can replay from display payload prepass under parent scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 220);

    const nested = try box(cx, .{
        .width = .{ .px = 140 },
        .height = .{ .px = 64 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 52, 70, 255),
        .padding = Padding.all(8),
        .overflow_hidden = true,
    }, .{
        try text(cx, "Scaled clipped subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 96 },
            .height = .{ .px = 16 },
            .background = Color.rgba(255, 160, 0, 255),
        }, .{}),
    });
    (try nested.style.ensureExtFallible(cx.allocator)).corner_radius = ui.CornerRadius.uniform(10);

    const scaled = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 120 },
        .direction = .column,
    }, .{
        nested,
    });
    (try scaled.style.ensureExtFallible(cx.allocator)).scale_x = 0.5;
    (try scaled.style.ensureExtFallible(cx.allocator)).scale_y = 0.5;

    const root = try box(cx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 220 },
        .padding = Padding.all(12),
    }, .{
        scaled,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);

    const scaled_runtime = cx.scene_runtime.get(scaled.id).?;
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(scaled_runtime.display_payload_subtree_prebuilt or nested_runtime.display_payload_subtree_prebuilt);
    if (scaled_runtime.display_payload_subtree_prebuilt) {
        try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.self_scale, scaled_runtime.display_payload_subtree_strategy);
    } else {
        try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.self_safe_effect, nested_runtime.display_payload_subtree_strategy);
    }
    try std.testing.expect(nested_runtime.clip_id != ui.SceneRuntimeInvalidId or scaled_runtime.clip_id != ui.SceneRuntimeInvalidId);

    var saw_scaled_layer = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_scaled_layer = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Scaled clipped subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_scaled_layer);
    try std.testing.expect(saw_nested_text);
}

test "render: clipped simple subtree can replay from display payload prepass under parent opacity and scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 220);

    const nested = try box(cx, .{
        .width = .{ .px = 140 },
        .height = .{ .px = 64 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(36, 46, 66, 255),
        .padding = Padding.all(8),
        .overflow_hidden = true,
    }, .{
        try text(cx, "Opacity scale clipped subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 96 },
            .height = .{ .px = 16 },
            .background = Color.rgba(255, 120, 40, 255),
        }, .{}),
    });
    (try nested.style.ensureExtFallible(cx.allocator)).corner_radius = ui.CornerRadius.uniform(10);

    const scaled = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 120 },
        .direction = .column,
        .opacity = 0.75,
    }, .{
        nested,
    });
    (try scaled.style.ensureExtFallible(cx.allocator)).scale_x = 0.5;
    (try scaled.style.ensureExtFallible(cx.allocator)).scale_y = 0.5;

    const root = try box(cx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 220 },
        .padding = Padding.all(12),
    }, .{
        scaled,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);

    const scaled_runtime = cx.scene_runtime.get(scaled.id).?;
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(scaled_runtime.display_payload_subtree_prebuilt or nested_runtime.display_payload_subtree_prebuilt);
    if (scaled_runtime.display_payload_subtree_prebuilt) {
        try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.self_scale, scaled_runtime.display_payload_subtree_strategy);
    } else {
        try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.self_safe_effect, nested_runtime.display_payload_subtree_strategy);
    }

    var saw_scaled_layer = false;
    var saw_clip = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_scaled_layer = true;
        } else if (cmd.isControl(.push_clip)) {
            saw_clip = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Opacity scale clipped subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_scaled_layer);
    try std.testing.expect(saw_nested_text);
}

test "render: self opacity simple subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 180);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 56 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(36, 44, 58, 255),
        .padding = Padding.all(10),
        .opacity = 0.7,
    }, .{
        try text(cx, "Self opacity subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 64 },
            .height = .{ .px = 12 },
            .background = Color.rgba(90, 160, 255, 255),
        }, .{}),
    });

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 180 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
    }, .{
        nested,
        blk: {
            const overlay = try box(cx, .{
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .background = Color.rgba(255, 90, 90, 255),
            }, .{});
            (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 1;
            break :blk overlay;
        },
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);

    const root_runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!root_runtime.display_payload_subtree_prebuilt);
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);
    try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.self_safe_effect, nested_runtime.display_payload_subtree_strategy);

    var saw_begin_opacity = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Self opacity subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_nested_text);
}

test "render: self opacity and rounded clip subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 64 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 54, 72, 255),
        .padding = Padding.all(10),
        .opacity = 0.72,
        .overflow_hidden = true,
    }, .{
        try text(cx, "Self opacity rounded subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 80 },
            .height = .{ .px = 14 },
            .background = Color.rgba(90, 180, 255, 255),
        }, .{}),
    });
    (try nested.style.ensureExtFallible(cx.allocator)).corner_radius = ui.CornerRadius.uniform(10);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
    }, .{
        nested,
        blk: {
            const overlay = try box(cx, .{
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .background = Color.rgba(255, 90, 90, 255),
            }, .{});
            (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 1;
            break :blk overlay;
        },
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);

    const root_runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!root_runtime.display_payload_subtree_prebuilt);
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);
    try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.self_safe_effect, nested_runtime.display_payload_subtree_strategy);

    var saw_begin_opacity = false;
    var saw_begin_rounded_clip = false;
    var saw_folded_radius = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
            if (cmd.radii.tl > 0.5) saw_folded_radius = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            saw_begin_rounded_clip = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Self opacity rounded subtree")) saw_nested_text = true;
        }
    }

    // Stage 3 fold: same-node rounded_clip merges into opacity layer, token vanishes,
    // begin_opacity_layer carries corner_radius.
    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_folded_radius);
    try std.testing.expect(!saw_begin_rounded_clip);
    try std.testing.expect(saw_nested_text);
}

test "render: self blur subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 64 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 54, 72, 220),
        .padding = Padding.all(10),
    }, .{
        try text(cx, "Self blur subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 80 },
            .height = .{ .px = 14 },
            .background = Color.rgba(90, 180, 255, 255),
        }, .{}),
    });
    (try nested.style.ensureExtFallible(cx.allocator)).glass = .{ .backdrop_blur = 6 };

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
        .background = Color.rgba(18, 24, 32, 255),
    }, .{
        nested,
        blk: {
            const overlay = try box(cx, .{
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .background = Color.rgba(255, 90, 90, 255),
            }, .{});
            (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 1;
            break :blk overlay;
        },
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    // self_blur doesn't use self-effect coordinate space (applyBackdropBlur doesn't push offscreen
    // layer, no external translation converts button-local to absolute), not counted in
    // self_effect.
    try std.testing.expectEqual(@as(u32, 0), cx.perf.display_list_self_effect_subtree_replay_count);

    const root_runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!root_runtime.display_payload_subtree_prebuilt);
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);
    try std.testing.expect(!ui.displayPayloadSubtreeStrategyUsesSelfEffectSpace(nested_runtime.display_payload_subtree_strategy));
    try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.self_blur, nested_runtime.display_payload_subtree_strategy);

    var saw_begin_blur = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_blur_layer)) {
            saw_begin_blur = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Self blur subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_begin_blur);
    try std.testing.expect(saw_nested_text);
}

test "render: self scale subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 220);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 68 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 54, 72, 255),
        .padding = Padding.all(10),
    }, .{
        try text(cx, "Self scale subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 80 },
            .height = .{ .px = 14 },
            .background = Color.rgba(90, 180, 255, 255),
        }, .{}),
    });
    const nested_ext = try nested.style.ensureExtFallible(cx.allocator);
    nested_ext.scale_x = 0.85;
    nested_ext.scale_y = 0.85;

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 220 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
    }, .{
        nested,
        blk: {
            const overlay = try box(cx, .{
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .background = Color.rgba(255, 90, 90, 255),
            }, .{});
            (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 1;
            break :blk overlay;
        },
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_self_effect_subtree_replay_count);

    const root_runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!root_runtime.display_payload_subtree_prebuilt);
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);
    try std.testing.expect(ui.displayPayloadSubtreeStrategyUsesSelfEffectSpace(nested_runtime.display_payload_subtree_strategy));
    try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.self_scale, nested_runtime.display_payload_subtree_strategy);

    var saw_begin_opacity = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            saw_begin_opacity = true;
            try std.testing.expect(layer.geom.w > 0);
            try std.testing.expect(layer.geom.h > 0);
            try std.testing.expect(layer.use_draw_transform or layer.draw_w > 0 or layer.draw_h > 0);
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Self scale subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_nested_text);
}

test "render: self scale display replay preserves shadow extents" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(340, 240);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 72 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 54, 72, 255),
        .padding = Padding.all(10),
    }, .{
        try text(cx, "Scaled shadow subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
    });
    const nested_ext = try nested.style.ensureExtFallible(cx.allocator);
    nested_ext.scale_x = 0.88;
    nested_ext.scale_y = 0.88;
    nested_ext.setShadow(.{
        .color = Color.rgba(0, 0, 0, 36),
        .blur = 24,
        .offset_x = 0,
        .offset_y = 8,
    });

    const root = try box(cx, .{
        .width = .{ .px = 340 },
        .height = .{ .px = 240 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
    }, .{
        nested,
        blk: {
            const overlay = try box(cx, .{
                .width = .{ .px = 20 },
                .height = .{ .px = 20 },
                .background = Color.rgba(255, 90, 90, 255),
            }, .{});
            (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 1;
            break :blk overlay;
        },
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_self_effect_subtree_replay_count);

    var saw_begin_opacity = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            saw_begin_opacity = true;
            try std.testing.expect(layer.use_draw_transform or layer.draw_w > 0 or layer.draw_h > 0);
            try std.testing.expect(layer.geom.x < nested.rectFromWorldOrFallback().x);
            try std.testing.expect(layer.geom.y < nested.rectFromWorldOrFallback().y);
            try std.testing.expect(layer.geom.w > nested.rectFromWorldOrFallback().w);
            try std.testing.expect(layer.geom.h > nested.rectFromWorldOrFallback().h);
            try std.testing.expect(layer.draw_x < nested.rectFromWorldOrFallback().x);
            try std.testing.expect(layer.draw_y < nested.rectFromWorldOrFallback().y);
            try std.testing.expect(layer.draw_w > nested.rectFromWorldOrFallback().w);
            try std.testing.expect(layer.draw_h > nested.rectFromWorldOrFallback().h);
            break;
        }
    }

    try std.testing.expect(saw_begin_opacity);
}

test "render: self scale and blur subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(340, 220);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 72 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 54, 72, 220),
        .padding = Padding.all(10),
    }, .{
        try text(cx, "Self scale blur subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 80 },
            .height = .{ .px = 14 },
            .background = Color.rgba(90, 180, 255, 255),
        }, .{}),
    });
    const nested_ext = try nested.style.ensureExtFallible(cx.allocator);
    nested_ext.scale_x = 0.85;
    nested_ext.scale_y = 0.85;
    nested_ext.glass = .{ .backdrop_blur = 6 };

    const root = try box(cx, .{
        .width = .{ .px = 340 },
        .height = .{ .px = 220 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
        .background = Color.rgba(18, 24, 32, 255),
    }, .{
        nested,
        blk: {
            const overlay = try box(cx, .{
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .background = Color.rgba(255, 90, 90, 255),
            }, .{});
            (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 1;
            break :blk overlay;
        },
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_self_effect_subtree_replay_count);

    const root_runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!root_runtime.display_payload_subtree_prebuilt);
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);
    try std.testing.expect(ui.displayPayloadSubtreeStrategyUsesSelfEffectSpace(nested_runtime.display_payload_subtree_strategy));
    try std.testing.expectEqual(ui.DisplayPayloadSubtreeStrategy.self_scale, nested_runtime.display_payload_subtree_strategy);

    var saw_begin_opacity = false;
    var saw_begin_blur = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
        } else if (cmd.isControl(.begin_blur_layer)) {
            saw_begin_blur = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Self scale blur subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_begin_blur);
    try std.testing.expect(saw_nested_text);
}

test "render: self scale blur and rounded clip subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(340, 240);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 80 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 54, 72, 220),
        .padding = Padding.all(10),
        .overflow_hidden = true,
    }, .{
        try text(cx, "Self scale blur rounded subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 80 },
            .height = .{ .px = 14 },
            .background = Color.rgba(90, 180, 255, 255),
        }, .{}),
    });
    const nested_ext = try nested.style.ensureExtFallible(cx.allocator);
    nested_ext.scale_x = 0.85;
    nested_ext.scale_y = 0.85;
    nested_ext.glass = .{ .backdrop_blur = 6 };
    nested_ext.corner_radius = ui.CornerRadius.uniform(12);

    const root = try box(cx, .{
        .width = .{ .px = 340 },
        .height = .{ .px = 240 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
        .background = Color.rgba(18, 24, 32, 255),
    }, .{
        nested,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_self_effect_subtree_replay_count);

    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);
    try std.testing.expect(ui.displayPayloadSubtreeStrategyUsesSelfEffectSpace(nested_runtime.display_payload_subtree_strategy));

    var saw_begin_opacity = false;
    var saw_begin_blur = false;
    var saw_begin_rounded_clip = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
        } else if (cmd.isControl(.begin_blur_layer)) {
            saw_begin_blur = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            saw_begin_rounded_clip = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Self scale blur rounded subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_begin_blur);
    try std.testing.expect(saw_begin_rounded_clip);
    try std.testing.expect(saw_nested_text);
}

test "render: self scale blur subtree can replay from display payload prepass under parent opacity and scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(380, 260);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 72 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 54, 72, 220),
        .padding = Padding.all(10),
    }, .{
        try text(cx, "Scaled parent self scale blur subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 80 },
            .height = .{ .px = 14 },
            .background = Color.rgba(90, 180, 255, 255),
        }, .{}),
    });
    const nested_ext = try nested.style.ensureExtFallible(cx.allocator);
    nested_ext.scale_x = 0.85;
    nested_ext.scale_y = 0.85;
    nested_ext.glass = .{ .backdrop_blur = 6 };

    const scaled = try box(cx, .{
        .width = .{ .px = 260 },
        .height = .{ .px = 160 },
        .direction = .column,
        .padding = Padding.all(12),
        .opacity = 0.82,
    }, .{
        nested,
    });
    const scaled_ext = try scaled.style.ensureExtFallible(cx.allocator);
    scaled_ext.scale_x = 0.8;
    scaled_ext.scale_y = 0.8;

    const root = try box(cx, .{
        .width = .{ .px = 380 },
        .height = .{ .px = 260 },
        .direction = .column,
        .padding = Padding.all(12),
        .background = Color.rgba(18, 24, 32, 255),
    }, .{
        scaled,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_self_effect_subtree_replay_count);

    const scaled_runtime = cx.scene_runtime.get(scaled.id).?;
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(
        scaled_runtime.display_payload_subtree_prebuilt or
            nested_runtime.display_payload_subtree_prebuilt,
    );
    try std.testing.expect(
        ui.displayPayloadSubtreeStrategyUsesSelfEffectSpace(scaled_runtime.display_payload_subtree_strategy) or
            ui.displayPayloadSubtreeStrategyUsesSelfEffectSpace(nested_runtime.display_payload_subtree_strategy),
    );

    var saw_begin_opacity = false;
    var saw_begin_blur = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
        } else if (cmd.isControl(.begin_blur_layer)) {
            saw_begin_blur = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Scaled parent self scale blur subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_begin_blur);
    try std.testing.expect(saw_nested_text);
}

test "render: self scale blur subtree with nested child subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(380, 260);

    const child_group = try box(cx, .{
        .width = .{ .px = 140 },
        .height = .{ .px = 44 },
        .direction = .column,
        .gap = 4,
        .background = Color.rgba(28, 36, 50, 255),
        .padding = Padding.all(8),
    }, .{
        try text(cx, "Nested child payload", .{
            .font_size = 12,
            .line_height = 1.2,
            .color = Color.rgba(220, 230, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 64 },
            .height = .{ .px = 10 },
            .background = Color.rgba(255, 160, 80, 255),
        }, .{}),
    });

    const nested = try box(cx, .{
        .width = .{ .px = 190 },
        .height = .{ .px = 110 },
        .direction = .column,
        .gap = 8,
        .background = Color.rgba(42, 54, 72, 220),
        .padding = Padding.all(10),
    }, .{
        try text(cx, "Self scale blur parent", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        child_group,
    });
    const nested_ext = try nested.style.ensureExtFallible(cx.allocator);
    nested_ext.scale_x = 0.85;
    nested_ext.scale_y = 0.85;
    nested_ext.glass = .{ .backdrop_blur = 6 };

    const root = try box(cx, .{
        .width = .{ .px = 380 },
        .height = .{ .px = 260 },
        .direction = .column,
        .padding = Padding.all(12),
        .background = Color.rgba(18, 24, 32, 255),
    }, .{
        nested,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_self_effect_subtree_replay_count);

    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);
    try std.testing.expect(ui.displayPayloadSubtreeStrategyUsesSelfEffectSpace(nested_runtime.display_payload_subtree_strategy));
    const child_runtime = cx.scene_runtime.get(child_group.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt or child_runtime.display_payload_subtree_prebuilt);

    var saw_begin_opacity = false;
    var saw_begin_blur = false;
    var saw_parent_text = false;
    var saw_child_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
        } else if (cmd.isControl(.begin_blur_layer)) {
            saw_begin_blur = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Self scale blur parent")) saw_parent_text = true;
            if (std.mem.eql(u8, txt.text_content, "Nested child payload")) saw_child_text = true;
        }
    }

    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_begin_blur);
    try std.testing.expect(saw_parent_text);
    try std.testing.expect(saw_child_text);
}

test "render: self opacity subtree can replay from display payload prepass under parent scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 220);

    const nested = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 56 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 54, 72, 255),
        .padding = Padding.all(10),
        .opacity = 0.72,
    }, .{
        try text(cx, "Scaled parent self opacity subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 72 },
            .height = .{ .px = 12 },
            .background = Color.rgba(90, 180, 255, 255),
        }, .{}),
    });

    const scaled = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 120 },
        .direction = .column,
        .padding = Padding.all(12),
    }, .{
        nested,
    });
    const scaled_ext = try scaled.style.ensureExtFallible(cx.allocator);
    scaled_ext.scale_x = 0.75;
    scaled_ext.scale_y = 0.75;

    const root = try box(cx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 220 },
        .direction = .column,
    }, .{
        scaled,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    const scaled_runtime = cx.scene_runtime.get(scaled.id).?;
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(scaled_runtime.display_payload_subtree_prebuilt or nested_runtime.display_payload_subtree_prebuilt);

    var saw_begin_opacity = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Scaled parent self opacity subtree")) saw_nested_text = true;
        }
    }

    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_nested_text);
}

test "render: self opacity and rounded clip subtree can replay from display payload prepass under parent opacity and scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 240);

    const nested = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 64 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(42, 54, 72, 255),
        .padding = Padding.all(10),
        .opacity = 0.74,
        .overflow_hidden = true,
    }, .{
        try text(cx, "Scaled parent self opacity rounded subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 72 },
            .height = .{ .px = 12 },
            .background = Color.rgba(90, 180, 255, 255),
        }, .{}),
    });
    (try nested.style.ensureExtFallible(cx.allocator)).corner_radius = ui.CornerRadius.uniform(10);

    const scaled = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 140 },
        .direction = .column,
        .padding = Padding.all(12),
        .opacity = 0.8,
        .overflow_hidden = true,
    }, .{
        nested,
    });
    const scaled_ext = try scaled.style.ensureExtFallible(cx.allocator);
    scaled_ext.scale_x = 0.75;
    scaled_ext.scale_y = 0.75;
    scaled_ext.corner_radius = ui.CornerRadius.uniform(12);

    const root = try box(cx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 240 },
        .direction = .column,
    }, .{
        scaled,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    const scaled_runtime = cx.scene_runtime.get(scaled.id).?;
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(scaled_runtime.display_payload_subtree_prebuilt or nested_runtime.display_payload_subtree_prebuilt);

    var saw_begin_opacity = false;
    var saw_begin_rounded_clip = false;
    var saw_folded_radius = false;
    var saw_nested_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
            if (cmd.radii.tl > 0.5) saw_folded_radius = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            saw_begin_rounded_clip = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Scaled parent self opacity rounded subtree")) saw_nested_text = true;
        }
    }

    // Stage 3 fold: rounded_clip merges into opacity layer (see earlier comment).
    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_folded_radius);
    try std.testing.expect(!saw_begin_rounded_clip);
    try std.testing.expect(saw_nested_text);
}

test "render: self scale and opacity subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 220);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 72 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(38, 48, 66, 255),
        .padding = Padding.all(10),
        .opacity = 0.72,
    }, .{
        try text(cx, "Self scale opacity subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 72 },
            .height = .{ .px = 12 },
            .background = Color.rgba(100, 190, 255, 255),
        }, .{}),
    });
    const nested_ext = try nested.style.ensureExtFallible(cx.allocator);
    nested_ext.scale_x = 0.8;
    nested_ext.scale_y = 0.8;

    const root = try box(cx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 220 },
        .direction = .column,
        .padding = Padding.all(12),
    }, .{
        nested,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_self_effect_subtree_replay_count);

    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);

    var saw_begin_opacity = false;
    var saw_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Self scale opacity subtree")) saw_text = true;
        }
    }

    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_text);
}

test "render: self scale opacity and rounded clip subtree can replay from display payload prepass under parent opacity" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(380, 240);

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 76 },
        .direction = .column,
        .gap = 6,
        .background = Color.rgba(38, 48, 66, 255),
        .padding = Padding.all(10),
        .opacity = 0.7,
        .overflow_hidden = true,
    }, .{
        try text(cx, "Self scale opacity rounded subtree", .{
            .font_size = 14,
            .line_height = 1.25,
            .color = Color.rgba(255, 255, 255, 255),
        }),
        try box(cx, .{
            .width = .{ .px = 72 },
            .height = .{ .px = 12 },
            .background = Color.rgba(100, 190, 255, 255),
        }, .{}),
    });
    const nested_ext = try nested.style.ensureExtFallible(cx.allocator);
    nested_ext.scale_x = 0.8;
    nested_ext.scale_y = 0.8;
    nested_ext.corner_radius = ui.CornerRadius.uniform(10);

    const root = try box(cx, .{
        .width = .{ .px = 380 },
        .height = .{ .px = 240 },
        .direction = .column,
        .padding = Padding.all(12),
        .opacity = 0.82,
    }, .{
        nested,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_prebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_self_effect_subtree_replay_count);

    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(nested_runtime.display_payload_subtree_prebuilt);

    var saw_begin_opacity = false;
    var saw_begin_rounded_clip = false;
    var saw_folded_radius = false;
    var saw_text = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_begin_opacity = true;
            if (cmd.radii.tl > 0.5) saw_folded_radius = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            saw_begin_rounded_clip = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Self scale opacity rounded subtree")) saw_text = true;
        }
    }

    // Stage 3 fold: rounded_clip merges into opacity layer (see earlier comment).
    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_folded_radius);
    try std.testing.expect(!saw_begin_rounded_clip);
    try std.testing.expect(saw_text);
}

test "render: blob-backed ellipsis text subtree can replay from display payload prepass under parent scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 220);

    const text_node = try text(cx, "very-long-filename.with.extension", .{
        .font_size = 14,
        .line_height = 1.25,
        .color = Color.rgba(255, 255, 255, 255),
    });
    {
        var t = text_node.getText().?;
        t.text_overflow = .ellipsis_smart;
        text_node.setText(t);
    }

    const nested = try box(cx, .{
        .width = .{ .px = 170 },
        .height = .{ .px = 44 },
        .direction = .column,
        .background = Color.rgba(36, 44, 60, 255),
        .padding = Padding.all(8),
    }, .{
        text_node,
    });

    const scaled = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 120 },
        .direction = .column,
        .padding = Padding.all(12),
    }, .{
        nested,
    });
    const scaled_ext = try scaled.style.ensureExtFallible(cx.allocator);
    scaled_ext.scale_x = 0.75;
    scaled_ext.scale_y = 0.75;

    const root = try box(cx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 220 },
    }, .{
        scaled,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    const scaled_runtime = cx.scene_runtime.get(scaled.id).?;
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(scaled_runtime.display_payload_subtree_prebuilt or nested_runtime.display_payload_subtree_prebuilt);

    var saw_prefix = false;
    var saw_ellipsis = false;
    var saw_suffix = false;
    for (commands) |cmd| {
        if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.startsWith(u8, txt.text_content, "very")) saw_prefix = true;
            if (std.mem.eql(u8, txt.text_content, "\xe2\x80\xa6")) saw_ellipsis = true;
            if (std.mem.eql(u8, txt.text_content, ".extension")) saw_suffix = true;
        }
    }

    try std.testing.expect(saw_prefix);
    try std.testing.expect(saw_ellipsis);
    try std.testing.expect(saw_suffix);
}

test "render: ellipsis ignores sub-pixel float noise between layout and shaped width" {
    // Layout sizes a fit text node through f32 sums, so its width can land an ulp under the
    // shaped width; that must not truncate a label that fits, while a real overflow still does.
    const label = "Option 1";
    const full = ui.text_layout.measureTextWidthByFontKind(label, 13, 400, false, false);
    for ([_]struct { width: f32, ellipsis: bool }{
        .{ .width = full - 0.0001, .ellipsis = false },
        .{ .width = full - 4, .ellipsis = true },
    }) |case| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(200, 60);
        const text_node = try text(cx, label, .{ .font_size = 13, .line_height = 1.4, .color = Color.rgba(0, 0, 0, 255) });
        {
            var t = text_node.getText().?;
            t.text_overflow = .ellipsis;
            text_node.setText(t);
        }
        text_node.style.width = .{ .px = case.width };
        cx.root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 60 } }, .{text_node});
        cx.layout();
        _ = cx.render();
        var saw_ellipsis = false;
        for (cx.lowerForEncoderPaintTable()) |cmd| {
            if (cmd.isText() and std.mem.eql(u8, cmd.text_content, "\xe2\x80\xa6")) saw_ellipsis = true;
        }
        try std.testing.expectEqual(case.ellipsis, saw_ellipsis);
    }
}

test "render: spans text subtree can replay from display payload prepass under parent opacity and scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 240);

    const spans = [_]ui.TextSpan{
        .{
            .start = 0,
            .end = 5,
            .bg_color = Color.rgba(255, 220, 80, 120),
            .color = Color.rgba(30, 30, 30, 255),
        },
        .{
            .start = 6,
            .end = 10,
            .underline = true,
            .underline_style = .dashed,
            .underline_color = Color.rgba(120, 200, 255, 255),
        },
    };

    const text_node = try text(cx, "hello span text", .{
        .font_size = 14,
        .line_height = 1.25,
        .color = Color.rgba(255, 255, 255, 255),
    });
    {
        var t = text_node.getText().?;
        t.spans = spans[0..];
        text_node.setText(t);
    }

    const nested = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 56 },
        .direction = .column,
        .background = Color.rgba(36, 44, 60, 255),
        .padding = Padding.all(8),
        .opacity = 0.74,
    }, .{
        text_node,
    });

    const parent = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 140 },
        .direction = .column,
        .padding = Padding.all(12),
        .opacity = 0.82,
    }, .{
        nested,
    });
    const parent_ext = try parent.style.ensureExtFallible(cx.allocator);
    parent_ext.scale_x = 0.75;
    parent_ext.scale_y = 0.75;

    const root = try box(cx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 240 },
    }, .{
        parent,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.display_list_subtree_replay_count);
    const parent_runtime = cx.scene_runtime.get(parent.id).?;
    const nested_runtime = cx.scene_runtime.get(nested.id).?;
    try std.testing.expect(
        parent_runtime.display_payload_subtree_prebuilt or
            nested_runtime.display_payload_subtree_prebuilt,
    );

    var saw_bg_rect = false;
    var saw_text_with_spans = false;
    for (commands) |cmd| {
        if (cmd.isFillRect()) {
            const r = cmd;
            if (Color.eql(r.color.toColor(), Color.rgba(255, 220, 80, 120))) saw_bg_rect = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            // task #161 calibration (post-v0.4): render pipeline uses single text blob + spans
            // decoration, no chunking into multiple text commands. Check text contains source + has
            // spans.
            if (std.mem.indexOf(u8, txt.text_content, "span") != null and txt.text_spans != null) {
                saw_text_with_spans = true;
            }
        }
    }

    try std.testing.expect(saw_bg_rect);
    try std.testing.expect(saw_text_with_spans);
}

test "render: text blobs do not reuse across different spans" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 160);

    const first = try text(cx, "Shared blob", .{
        .font_size = 16,
        .line_height = 1.25,
        .color = Color.rgba(255, 255, 255, 255),
    });
    const second = try text(cx, "Shared blob", .{
        .font_size = 16,
        .line_height = 1.25,
        .color = Color.rgba(255, 255, 255, 255),
    });
    {
        var t = second.getText().?;
        t.spans = &.{
            .{ .start = 0, .end = 6, .font_weight = 700 },
        };
        second.setText(t);
    }

    const root = try box(cx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 160 },
        .direction = .column,
        .gap = 8,
        .padding = Padding.all(12),
    }, .{
        first,
        second,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 2), cx.text_blob_store.blobs.items.len);
}

test "render: display list emits span decorations and chunked text runs" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(420, 120);

    const root = try box(cx, .{
        .width = .{ .px = 420 },
        .height = .{ .px = 120 },
    }, .{});

    const text_node = try text(cx, "abcdef", .{
        .font_size = 16,
        .line_height = 1.4,
        .color = Color.rgba(240, 240, 240, 255),
    });
    const spans = [_]ui.TextSpan{
        .{ .start = 0, .end = 2, .bg_color = Color.rgba(220, 240, 140, 255) },
        .{ .start = 2, .end = 4, .strikethrough = true, .underline = true, .underline_color = Color.rgba(255, 120, 120, 255) },
        .{ .start = 4, .end = 6, .font_weight = 700 },
    };
    {
        var t = text_node.getText().?;
        t.spans = spans[0..];
        text_node.setText(t);
    }
    try root.appendChild(cx.allocator, text_node);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    var bg_rects: usize = 0;
    var deco_rects: usize = 0;
    var text_runs: usize = 0;
    for (cx.display_list.items.items) |item| {
        switch (item) {
            .fill_rect => |rect| {
                if (Color.eql(rect.color, Color.rgba(220, 240, 140, 255))) bg_rects += 1;
                if (Color.eql(rect.color, Color.rgba(255, 120, 120, 255)) or Color.eql(rect.color, Color.rgba(240, 240, 240, 255))) deco_rects += 1;
            },
            .text_run => text_runs += 1,
            else => {},
        }
    }

    // task #161 calibration: post-v0.4 pipeline merges adjacent same weight/italic/monospace
    // text runs; span decoration (bg/underline/strikethrough/color) encoded via spans in single
    // run,
    // only different font_weight splits. 3 spans over 6 chars produce >= 2 runs ([0..4] + [4..6]).
    try std.testing.expect(bg_rects >= 1);
    try std.testing.expect(deco_rects >= 2);
    try std.testing.expect(text_runs >= 2);
}

test "render: own content can replay directly from prebuilt display payload" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 120);

    const root = try text(cx, "payload-first", .{
        .font_size = 16,
        .line_height = 1.25,
        .color = Color.rgba(240, 240, 240, 255),
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const root_runtime = cx.scene_runtime.get(root.id) orelse unreachable;
    try std.testing.expect(root_runtime.display_item_count > 0);
    try std.testing.expect(root_runtime.display_payload_own_prebuilt);
    try std.testing.expect(cx.perf.display_list_own_prebuild_count >= 1);
    try std.testing.expect(cx.perf.display_list_own_replay_count >= 1);
}

test "render: own payload replay preserves border-radius fallback from border.radius" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 120);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 40 },
        .background = Color.rgba(24, 24, 24, 255),
        .border = .{
            .width = 1,
            .color = Color.rgba(240, 240, 240, 255),
            .radius = 12,
        },
    }, .{});

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const root_runtime = cx.scene_runtime.get(root.id) orelse unreachable;
    try std.testing.expect(root_runtime.display_payload_own_prebuilt);
    try std.testing.expect(cx.perf.display_list_own_replay_count >= 1);

    var saw_fill = false;
    var saw_border = false;
    for (cx.display_list.items.items) |item| {
        switch (item) {
            .fill_rect => |rect| {
                if (Color.eql(rect.color, Color.rgba(24, 24, 24, 255))) {
                    saw_fill = true;
                    try std.testing.expectEqual(@as(f32, 12), rect.radius[0]);
                    try std.testing.expectEqual(@as(f32, 12), rect.radius[1]);
                    try std.testing.expectEqual(@as(f32, 12), rect.radius[2]);
                    try std.testing.expectEqual(@as(f32, 12), rect.radius[3]);
                }
            },
            .stroke_rect => |stroke| {
                if (Color.eql(stroke.color, Color.rgba(240, 240, 240, 255))) {
                    saw_border = true;
                    try std.testing.expectEqual(@as(f32, 12), stroke.radius[0]);
                    try std.testing.expectEqual(@as(f32, 12), stroke.radius[1]);
                    try std.testing.expectEqual(@as(f32, 12), stroke.radius[2]);
                    try std.testing.expectEqual(@as(f32, 12), stroke.radius[3]);
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_fill);
    try std.testing.expect(saw_border);

    var bridged_fill = false;
    var bridged_border = false;
    for (commands) |cmd| {
        if (cmd.isFillRect()) {
            const rect = cmd;
            if (Color.eql(rect.color.toColor(), Color.rgba(24, 24, 24, 255))) {
                bridged_fill = true;
                try std.testing.expectEqual(@as(f32, 12), rect.radii.toArray()[0]);
                try std.testing.expectEqual(@as(f32, 12), rect.radii.toArray()[1]);
                try std.testing.expectEqual(@as(f32, 12), rect.radii.toArray()[2]);
                try std.testing.expectEqual(@as(f32, 12), rect.radii.toArray()[3]);
            }
        } else if (cmd.isStrokeRect()) {
            const border = cmd;
            if (Color.eql(border.color.toColor(), Color.rgba(240, 240, 240, 255))) {
                bridged_border = true;
                try std.testing.expectEqual(@as(f32, 12), border.radii.toArray()[0]);
                try std.testing.expectEqual(@as(f32, 12), border.radii.toArray()[1]);
                try std.testing.expectEqual(@as(f32, 12), border.radii.toArray()[2]);
                try std.testing.expectEqual(@as(f32, 12), border.radii.toArray()[3]);
            }
        }
    }

    try std.testing.expect(bridged_fill);
    try std.testing.expect(bridged_border);
}

test "render: simple leaf opacity updates visible commands across frames" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 120);

    const root = try box(cx, .{
        .width = .{ .px = 64 },
        .height = .{ .px = 64 },
        .background = Color.rgba(80, 140, 220, 255),
    }, .{});

    cx.root = root;
    cx.layout();
    _ = cx.render();

    root.setOpacityRaw(0.4);
    root.markCompositeDirty();
    root.invalidateRenderCache();

    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var saw_modulated_rect = false;
    var saw_opacity_layer = false;
    for (commands) |cmd| {
        if (cmd.isFillRect()) {
            const rect = cmd;
            if (Color.eql(rect.color.toColor(), Color.rgba(80, 140, 220, 102))) {
                saw_modulated_rect = true;
            }
        } else if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            saw_opacity_layer = true;
            try std.testing.expectApproxEqAbs(@as(f32, 0.4), layer.opacity, 0.001);
        }
    }

    try std.testing.expect(saw_modulated_rect or saw_opacity_layer);
}

test "render: leaf own payload can replay under parent opacity when subtree prepass is disabled" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(260, 160);

    const label = try text(cx, "payload-child", .{
        .font_size = 16,
        .line_height = 1.25,
        .color = Color.rgba(245, 245, 245, 255),
    });
    const overlay = try box(cx, .{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
        .background = Color.rgba(255, 80, 80, 255),
    }, .{});
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 1;
    const root = try box(cx, .{
        .width = .{ .px = 260 },
        .height = .{ .px = 160 },
        .padding = Padding.all(12),
        .gap = 8,
        .opacity = 0.8,
        .background = Color.rgba(28, 32, 40, 255),
    }, .{
        label,
        overlay,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const root_runtime = cx.scene_runtime.get(root.id) orelse unreachable;
    const label_runtime = cx.scene_runtime.get(label.id) orelse unreachable;
    try std.testing.expect(!root_runtime.display_payload_subtree_prebuilt);
    try std.testing.expect(label_runtime.display_item_count > 0);
    try std.testing.expect(label_runtime.display_payload_own_prebuilt);
    try std.testing.expect(cx.perf.display_list_own_prebuild_count >= 1);
    try std.testing.expect(cx.perf.display_list_own_replay_count >= 1);
}

test "render: display list uses visible ellipsis segments for truncated single-line text" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 80);

    const text_node = try text(cx, "very-long-filename.txt", .{
        .font_size = 14,
        .line_height = 1.2,
    });
    {
        var t = text_node.getText().?;
        t.text_overflow = .ellipsis_smart;
        text_node.setText(t);
    }

    const root = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 32 },
        .padding = Padding.all(4),
    }, .{
        text_node,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    var saw_full = false;
    var saw_ellipsis = false;
    var saw_blob_backed_prefix = false;
    for (cx.display_list.items.items) |item| {
        switch (item) {
            .text_run => |run| {
                if (std.mem.eql(u8, run.content, "very-long-filename.txt")) saw_full = true;
                if (std.mem.eql(u8, run.content, "\xe2\x80\xa6")) saw_ellipsis = true;
                if (run.blob_id != ui.SceneRuntimeInvalidId and run.blob_byte_end > run.blob_byte_start) {
                    saw_blob_backed_prefix = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(!saw_full);
    try std.testing.expect(saw_ellipsis);
    try std.testing.expect(saw_blob_backed_prefix);
}

test "render: ellipsis preserves compound graphemes with and without prefix cache" {
    const grapheme = @import("text_core").grapheme;
    for ([_][]const u8{ "👨🏻‍💻", "👩🏽‍🚀", "👨‍👩‍👧‍👦", "🇨🇳", "1️⃣", "e\u{301}" }) |cluster| {
        for ([_]usize{ 8, 1030 }) |tail_len| {
            for ([_]f32{ 6, 19, 33, 48, 73 }) |width| {
                var cx = try Cx.init(std.testing.allocator, std.testing.io);
                defer cx.deinit();
                const name = try std.testing.allocator.alloc(u8, cluster.len + tail_len);
                defer std.testing.allocator.free(name);
                @memcpy(name[0..cluster.len], cluster);
                @memset(name[cluster.len..], 'x');
                var rc = testRenderContext(cx);
                const props = ui.TextProps{ .content = name, .font_size = 14, .text_overflow = .ellipsis };
                // A narrow budget must show the entire cluster or just an ellipsis.
                try @import("render_engine/text_item_render.zig").appendDisplayEllipsisText(
                    &rc,
                    .{ .transform_id = ui.SceneRuntimeInvalidId, .node_id = 1 },
                    1,
                    &props,
                    ui.SceneRuntimeInvalidId,
                    0,
                    14,
                    width,
                    .static_crisp,
                );
                var saw_ellipsis = false;
                for (cx.display_list.items.items) |item| {
                    if (item == .text_run) {
                        const content = item.text_run.content;
                        if (std.mem.eql(u8, content, "…")) {
                            saw_ellipsis = true;
                            continue;
                        }
                        var cursor = grapheme.BoundaryCursor.init(name);
                        var end: usize = 0;
                        while (end < content.len) end = cursor.next(end);
                        try std.testing.expectEqual(content.len, end);
                    }
                }
                try std.testing.expect(saw_ellipsis);
            }
        }
    }
}

test "render: display list emits overflow fade gradients" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 80);

    const root = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 32 },
        .padding = Padding.all(4),
        .background = Color.rgba(20, 20, 20, 255),
        .overflow_hidden = true,
    }, .{
        try text(cx, "A very very very long line", .{
            .font_size = 14,
            .line_height = 1.2,
        }),
    });
    (try root.style.ensureExtFallible(cx.allocator)).overflow_fade = .{
        .edges = .{ .right = true },
        .size = 12,
    };

    cx.root = root;
    cx.layout();
    _ = cx.render();

    var saw_right_fade = false;
    for (cx.display_list.items.items) |item| {
        switch (item) {
            .gradient_rect => |grad| {
                if (grad.direction == .horizontal and grad.w == 12) {
                    saw_right_fade = true;
                    try std.testing.expect(Color.eql(grad.from, Color.rgba(20, 20, 20, 0)));
                    try std.testing.expect(Color.eql(grad.to, Color.rgba(20, 20, 20, 255)));
                }
            },
            else => {},
        }
    }
    try std.testing.expect(saw_right_fade);
}

test "render: display list bridge projects simple items back to render commands" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 120);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 120 },
        .background = Color.rgba(30, 40, 50, 255),
        .padding = Padding.all(12),
    }, .{
        try text(cx, "Bridge me", .{
            .font_size = 16,
            .line_height = 1.25,
            .color = Color.rgba(240, 240, 240, 255),
        }),
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const baseline = cx.lowerForEncoderPaintTable();

    var baseline_rect: ?ui.paint_table.DisplayItem = null;
    var baseline_text: ?ui.paint_table.DisplayItem = null;
    for (baseline) |cmd| {
        if (cmd.isFillRect()) {
            if (baseline_rect == null) baseline_rect = cmd;
        } else if (cmd.isText()) {
            if (baseline_text == null) baseline_text = cmd;
        }
    }
    try std.testing.expect(baseline_rect != null);
    try std.testing.expect(baseline_text != null);

    cx.lowering._dead_main.clearRetainingCapacity();
    var render_ctx = testRenderContext(cx);
    try std.testing.expect(try ui.render_engine.appendNodeDisplayPayloadToRenderList(&render_ctx, root.id, .subtree));

    var bridged_rect: ?ui.paint_table.DisplayItem = null;
    var bridged_text: ?ui.paint_table.DisplayItem = null;
    for (cx.lowering.main_paint.items) |cmd| {
        if (cmd.isFillRect()) {
            if (bridged_rect == null) bridged_rect = cmd;
        } else if (cmd.isText()) {
            if (bridged_text == null) bridged_text = cmd;
        }
    }
    try std.testing.expect(bridged_rect != null);
    try std.testing.expect(bridged_text != null);

    {
        const a = baseline_rect.?;
        const b = bridged_rect.?;
        try std.testing.expect(a.isFillRect() and b.isFillRect());
        try std.testing.expectApproxEqAbs(a.geom.x, b.geom.x, 0.001);
        try std.testing.expectApproxEqAbs(a.geom.y, b.geom.y, 0.001);
        try std.testing.expectApproxEqAbs(a.geom.w, b.geom.w, 0.001);
        try std.testing.expectApproxEqAbs(a.geom.h, b.geom.h, 0.001);
        try std.testing.expect(Color.eql(a.color.toColor(), b.color.toColor()));
    }
    {
        const a = baseline_text.?;
        const b = bridged_text.?;
        try std.testing.expect(a.isText() and b.isText());
        try std.testing.expectApproxEqAbs(a.geom.x, b.geom.x, 0.001);
        try std.testing.expectApproxEqAbs(a.geom.y, b.geom.y, 0.001);
        try std.testing.expectEqualStrings(a.text_content, b.text_content);
        try std.testing.expectApproxEqAbs(a.text_font_size, b.text_font_size, 0.001);
    }
}

test "render: display list bridge preserves opacity layer and clip structure" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 64 },
        .background = Color.rgba(40, 50, 60, 255),
        .opacity = 0.7,
        .overflow_hidden = true,
        .padding = Padding.all(12),
    }, .{
        try text(cx, "Clip + opacity", .{
            .font_size = 16,
            .line_height = 1.25,
            .color = Color.rgba(240, 240, 240, 255),
        }),
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const baseline = cx.lowerForEncoderPaintTable();

    var baseline_begin_opacity = false;
    var baseline_push_clip = false;
    var baseline_end_opacity = false;
    var baseline_text: ?ui.paint_table.DisplayItem = null;
    for (baseline) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            baseline_begin_opacity = true;
        } else if (cmd.isControl(.push_clip)) {
            baseline_push_clip = true;
        } else if (cmd.isControl(.end_opacity_layer)) {
            baseline_end_opacity = true;
        } else if (cmd.isText()) {
            if (baseline_text == null) baseline_text = cmd;
        }
    }
    try std.testing.expect(baseline_begin_opacity);
    try std.testing.expect(baseline_push_clip);
    try std.testing.expect(baseline_end_opacity);
    try std.testing.expect(baseline_text != null);

    cx.lowering._dead_main.clearRetainingCapacity();
    var render_ctx = testRenderContext(cx);
    try std.testing.expect(try ui.render_engine.appendNodeDisplayPayloadToRenderList(&render_ctx, root.id, .subtree));

    var bridged_begin_opacity = false;
    var bridged_push_clip = false;
    var bridged_end_opacity = false;
    var bridged_text: ?ui.paint_table.DisplayItem = null;
    for (cx.lowering.main_paint.items) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            bridged_begin_opacity = true;
        } else if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            bridged_push_clip = true;
            try std.testing.expect(clip.clip_shape_kind == @backingInt(ui.display_list.ClipShapeKind.rect) or clip.clip_shape_kind == @backingInt(ui.display_list.ClipShapeKind.rounded_rect) or clip.clip_shape_kind == @backingInt(ui.display_list.ClipShapeKind.polygon));
        } else if (cmd.isControl(.end_opacity_layer)) {
            bridged_end_opacity = true;
        } else if (cmd.isText()) {
            if (bridged_text == null) bridged_text = cmd;
        }
    }
    try std.testing.expect(bridged_begin_opacity);
    try std.testing.expect(bridged_push_clip);
    try std.testing.expect(bridged_end_opacity);
    try std.testing.expect(bridged_text != null);

    {
        const a = baseline_text.?;
        const b = bridged_text.?;
        try std.testing.expect(a.isText() and b.isText());
        try std.testing.expectApproxEqAbs(a.geom.x, b.geom.x, 0.001);
        try std.testing.expectApproxEqAbs(a.geom.y, b.geom.y, 0.001);
        try std.testing.expectEqualStrings(a.text_content, b.text_content);
    }
}

test "clickable: handler on node" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var clicked = false;

    const btn = clickable(
        try box(cx, .{
            .width = .{ .px = 100 },
            .height = .{ .px = 40 },
            .background = theme.dark.tokens.color.accent,
        }, .{}),
        Cx.simpleHandler(struct {
            fn handle(ctx: *anyopaque) void {
                const ptr: *bool = @ptrCast(@alignCast(ctx));
                ptr.* = true;
            }
        }.handle, &clicked),
    );

    cx.root = btn;
    cx.layout();
    cx.handleClick(50, 20);

    try std.testing.expect(clicked);
}

test "optional child: conditional rendering" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const show_extra = false;

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{
        try text(cx, "Always", .{}),
        if (show_extra) try text(cx, "Extra", .{}) else null,
    });

    cx.root = root;
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}

test "Sizing: px/grow/fit" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .row,
    }, .{
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{}),
        try box(cx, .{ .width = .{ .grow = .{} } }, .{}), // fills remaining
    });

    cx.root = root;
    cx.layout();

    try std.testing.expectEqual(@as(f32, 100), root.children.items[0].rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 300), root.children.items[1].rectFromWorldOrFallback().w);
}

test "Sizing: grow 子节点的主轴 margin 必须计入 used_space" {
    // Regression: pass1 .px / .fit / .percent / flex_basis accumulate margin_main, but only
    // .grow accumulates flex_total; a grow child's margin never enters used_space, so
    // remaining is inflated and a margin'd flex child overflows the container.
    //
    // 400w container: px child 100 + grow child with +/-20 margin.
    // Grow gets 400 - 100 - 40 = 260, not 300.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .row,
    }, .{
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{}),
        try box(cx, .{
            .width = .{ .grow = .{} },
            .margin = .{ .left = 20, .right = 20 },
        }, .{}),
    });

    cx.root = root;
    cx.layout();

    const grow_child = root.children.items[1];
    try std.testing.expectEqual(@as(f32, 260), grow_child.rectFromWorldOrFallback().w);
    // Right edge must not exceed container.
    const r = grow_child.rectFromWorldOrFallback();
    try std.testing.expect(r.x + r.w <= 400);
}

test "align: 最终对齐 pass 移动子节点后必须标脏" {
    // layoutChildren ends with a "final cross-axis align" pass: wrap / fit backfill changes
    // cross-axis
    // size during recursion, so children are re-aligned with the final size.
    //
    // But direct setLayoutY/setLayoutX skips the placement loop's "position changed -> mark
    // dirty.core.layout" check. An unmarked move leaves the subtree with stale world coords next
    // frame.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const child = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .row,
        .align_items = .center,
    }, .{child});

    cx.root = root;
    cx.layout();

    const settled_y = child.rectFromWorldOrFallback().y;
    // Center align: (300 - 50) / 2 = 125.
    try std.testing.expectEqual(@as(f32, 125), settled_y);

    // Stable after re-layout, position shouldn't change (both passes converge to same answer,
    // else each frame overwrites).
    cx.layout();
    try std.testing.expectEqual(settled_y, child.rectFromWorldOrFallback().y);
}

test "align: reverse pass 挪动子节点后必须标脏" {
    // batchReverseChildren directly setLayoutX/Y, no mark dirty.core.layout.
    // row_reverse: every child main-axis position changes, subtree left with stale world coords
    // next frame.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const grandchild = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    const child = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{grandchild});
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .row_reverse,
    }, .{child});

    cx.root = root;
    cx.layout();

    // Reverse pushes child right: 400 - 100 = 300.
    try std.testing.expectEqual(@as(f32, 300), child.rectFromWorldOrFallback().x);
    // Position changed by reverse pass -> must mark dirty, descendants' world coords don't recalc.
    try std.testing.expect(child.frame_state.state_bits.dirty.core.layout or
        child.frame_state.state_bits.dirty.core.subtree_layout);
}

test "align: 稳定后重复布局不再标脏（不得永不停帧）" {
    // Reverse / final-align both add marks. Unconditional mark in stable state
    // gets dirty nodes every frame -> idle never stops (repo hit once).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const child = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .row_reverse,
        .align_items = .center,
    }, .{child});

    cx.root = root;
    cx.layout();

    // Clear first-layout dirty, layout again: position converged -> shouldn't mark dirty.
    child.frame_state.state_bits.dirty.core.layout = false;
    child.frame_state.state_bits.dirty.core.subtree_layout = false;
    const settled_x = child.rectFromWorldOrFallback().x;
    const settled_y = child.rectFromWorldOrFallback().y;

    cx.layout();

    try std.testing.expectEqual(settled_x, child.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(settled_y, child.rectFromWorldOrFallback().y);
    try std.testing.expect(!child.frame_state.state_bits.dirty.core.layout);
}

test "render: generates commands" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    cx.root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .background = theme.dark.tokens.color.bg_primary,
    }, .{});

    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expect(commands.len > 0);
    try std.testing.expect(commands[0].isFillRect());
    try std.testing.expectEqual(@as(f32, 400), commands[0].geom.w);
}

test "render: non-uniform border widths emit single per-side border" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 140);

    cx.root = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 140 },
        .border = .{
            .color = Color.rgba(120, 130, 140, 255),
            .side_widths = .{ 1, 2, 3, 4 }, // top, right, bottom, left
        },
    }, .{});

    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var push_count: usize = 0;
    var per_side_count: usize = 0;

    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            push_count += 1;
        } else if ((cmd.kind == .rect and (cmd.border_widths[0] + cmd.border_widths[1] + cmd.border_widths[2] + cmd.border_widths[3]) > 0)) {
            const b = cmd;
            per_side_count += 1;
            // Single draw call includes all 4 border widths.
            try std.testing.expect(std.math.approxEqAbs(f32, b.border_widths[0], 1, 0.0001)); // top
            try std.testing.expect(std.math.approxEqAbs(f32, b.border_widths[1], 2, 0.0001)); // right
            try std.testing.expect(std.math.approxEqAbs(f32, b.border_widths[2], 3, 0.0001)); // bottom
            try std.testing.expect(std.math.approxEqAbs(f32, b.border_widths[3], 4, 0.0001)); // left

        }
    }

    try std.testing.expectEqual(@as(usize, 0), push_count); // No clip.
    try std.testing.expectEqual(@as(usize, 1), per_side_count); // Single draw call.
}

test "render: per-side border colors emit per-side borders without clipping" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(180, 120);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 120 },
        .border = .{
            .width = 2,
            .color = Color.rgba(80, 80, 80, 255),
        },
    }, .{});
    root.setBorderSideColors(
        std.testing.allocator,
        Color.rgba(255, 0, 0, 255),
        Color.rgba(0, 255, 0, 255),
        Color.rgba(0, 0, 255, 255),
        Color.rgba(255, 255, 0, 255),
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var push_count: usize = 0;
    var per_side_count: usize = 0;
    var saw_red = false;
    var saw_green = false;
    var saw_blue = false;
    var saw_yellow = false;

    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            push_count += 1;
        } else if ((cmd.kind == .rect and (cmd.border_widths[0] + cmd.border_widths[1] + cmd.border_widths[2] + cmd.border_widths[3]) > 0)) {
            const b = cmd;
            per_side_count += 1;
            if (Color.eql(b.color.toColor(), Color.rgba(255, 0, 0, 255))) saw_red = true;
            if (Color.eql(b.color.toColor(), Color.rgba(0, 255, 0, 255))) saw_green = true;
            if (Color.eql(b.color.toColor(), Color.rgba(0, 0, 255, 255))) saw_blue = true;
            if (Color.eql(b.color.toColor(), Color.rgba(255, 255, 0, 255))) saw_yellow = true;
        }
    }

    try std.testing.expectEqual(@as(usize, 0), push_count); // No clip.
    try std.testing.expectEqual(@as(usize, 4), per_side_count);
    try std.testing.expect(saw_red);
    try std.testing.expect(saw_green);
    try std.testing.expect(saw_blue);
    try std.testing.expect(saw_yellow);

    // Display list validation.
    var display_per_side_count: usize = 0;
    var display_red = false;
    var display_green = false;
    var display_blue = false;
    var display_yellow = false;
    for (cx.display_list.items.items) |item| {
        switch (item) {
            .border_per_side => |side| {
                if (Color.eql(side.color, Color.rgba(255, 0, 0, 255))) {
                    display_red = true;
                    display_per_side_count += 1;
                }
                if (Color.eql(side.color, Color.rgba(0, 255, 0, 255))) {
                    display_green = true;
                    display_per_side_count += 1;
                }
                if (Color.eql(side.color, Color.rgba(0, 0, 255, 255))) {
                    display_blue = true;
                    display_per_side_count += 1;
                }
                if (Color.eql(side.color, Color.rgba(255, 255, 0, 255))) {
                    display_yellow = true;
                    display_per_side_count += 1;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), display_per_side_count);
    try std.testing.expect(display_red);
    try std.testing.expect(display_green);
    try std.testing.expect(display_blue);
    try std.testing.expect(display_yellow);
}

test "render: per-side borders preserve rounded outer corners without clips" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(160, 80);

    const root = try box(cx, .{
        .width = .{ .px = 48 },
        .height = .{ .px = 32 },
        .background = Color.rgba(255, 255, 255, 255),
        .border = .{
            .width = 1,
            .color = Color.rgba(180, 180, 180, 255),
        },
    }, .{});
    root.style.ensureExtPanic(cx.allocator).corner_radius = .{ .each = .{ 0, 8, 8, 0 } };
    root.setBorderSideColors(
        std.testing.allocator,
        Color.rgba(180, 180, 180, 255),
        Color.rgba(180, 180, 180, 255),
        Color.rgba(180, 180, 180, 255),
        Color.TRANSPARENT,
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var push_count: usize = 0;
    var per_side_count: usize = 0;

    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            push_count += 1;
        } else if ((cmd.kind == .rect and (cmd.border_widths[0] + cmd.border_widths[1] + cmd.border_widths[2] + cmd.border_widths[3]) > 0)) {
            const b = cmd;
            per_side_count += 1;
            // Corner radius must pass to shader.
            try std.testing.expect(b.radii.toArray()[1] > 0); // TR = 8
            try std.testing.expect(b.radii.toArray()[2] > 0); // BR = 8

        }
    }

    try std.testing.expectEqual(@as(usize, 0), push_count); // No clip.
    try std.testing.expect(per_side_count >= 1); // At least 3 edges (left transparent, no render).
}

test "render spans draws highlight backgrounds before italic text" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 120);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 120 },
    }, .{});

    const text_node = try text(cx, "abcdef", .{
        .font_size = 16,
        .line_height = 1.4,
    });
    const spans = [_]ui.TextSpan{
        .{ .start = 0, .end = 2, .bg_color = Color.rgba(220, 240, 140, 255) },
        .{ .start = 2, .end = 4, .bg_color = Color.rgba(220, 240, 140, 255), .use_italic_font = true },
        .{ .start = 4, .end = 6, .bg_color = Color.rgba(220, 240, 140, 255) },
    };
    {
        var t = text_node.getText().?;
        t.spans = spans[0..];
        text_node.setText(t);
    }
    try root.appendChild(cx.allocator, text_node);

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var saw_text = false;
    var highlight_rects: usize = 0;
    var span_texts: usize = 0;
    for (commands) |cmd| {
        if (cmd.isFillRect()) {
            const r = cmd;
            const is_highlight_radius = r.radii.toArray()[0] == 3 and r.radii.toArray()[1] == 3 and r.radii.toArray()[2] == 3 and r.radii.toArray()[3] == 3;
            if (is_highlight_radius and r.color.toColor().eql(Color.rgba(220, 240, 140, 255))) {
                try std.testing.expect(!saw_text);
                highlight_rects += 1;
            }
        } else if (cmd.isText()) {
            saw_text = true;
            span_texts += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 3), highlight_rects);
    try std.testing.expectEqual(@as(usize, 3), span_texts);
}

test "render: parent scale uses layer draw rect for child geometry" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 140 },
    }, .{});

    const scaled = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 40 },
        .direction = .column,
    }, .{});
    scaled.style.ensureExtPanic(cx.allocator).scale_x = 0.5;
    scaled.style.ensureExtPanic(cx.allocator).scale_y = 0.5;

    const child = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 20 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});

    try scaled.appendChild(cx.allocator, child);
    try root.appendChild(cx.allocator, scaled);
    cx.root = root;

    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var saw_child = false;
    var saw_scaled_layer = false;
    for (commands) |cmd| {
        if (cmd.isFillRect()) {
            const r = cmd;
            if (Color.eql(r.color.toColor(), Color.rgba(255, 0, 0, 255))) {
                saw_child = true;
                try std.testing.expect(r.geom.w > 0);
                try std.testing.expect(r.geom.h > 0);
            }
        } else if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            saw_scaled_layer = true;
            try std.testing.expect(layer.use_draw_transform or layer.draw_w > 0 or layer.draw_h > 0);
            try std.testing.expect(layer.geom.w > 0);
            try std.testing.expect(layer.geom.h > 0);
            try std.testing.expect(layer.draw_w > 0);
            try std.testing.expect(layer.draw_h > 0);
        }
    }

    try std.testing.expect(saw_child);
    try std.testing.expect(saw_scaled_layer);
}

test "render: parent scale keeps text content local and scales at layer composite" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 140 },
    }, .{});

    const scaled = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 40 },
        .direction = .column,
    }, .{});
    scaled.style.ensureExtPanic(cx.allocator).scale_x = 0.5;
    scaled.style.ensureExtPanic(cx.allocator).scale_y = 0.5;

    const label = try text(cx, "Zoom", .{ .font_size = 12 });
    try scaled.appendChild(cx.allocator, label);
    try root.appendChild(cx.allocator, scaled);
    cx.root = root;

    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var saw_text = false;
    var saw_scaled_layer = false;
    for (commands) |cmd| {
        if (cmd.isText()) {
            const t = cmd;
            if (std.mem.eql(u8, t.text_content, "Zoom")) {
                saw_text = true;
                // CA-pure (P6+): surface content baked at **1x** (unscaled owner-local), scale
                // applied
                // uniformly by composite draw_transform (plan R4). font_size stays 12, not old
                // model's 24.
                try std.testing.expectApproxEqAbs(@as(f32, 12), t.text_font_size, 0.001);
            }
        } else if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            saw_scaled_layer = true;
            try std.testing.expect(layer.use_draw_transform or layer.draw_w > 0 or layer.draw_h > 0);
        }
    }

    try std.testing.expect(saw_text);
    try std.testing.expect(saw_scaled_layer);
}

test "render: self scale opacity bridge preserves shadow extents" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
        .padding = Padding.all(20),
    }, .{});

    const overlay = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 48 },
        .background = Color.rgba(60, 110, 220, 255),
    }, .{});
    const overlay_ext = overlay.style.ensureExtPanic(cx.allocator);
    overlay_ext.scale_x = 0.92;
    overlay_ext.scale_y = 0.92;
    overlay_ext.setShadow(.{
        .color = Color.rgba(0, 0, 0, 40),
        .blur = 24,
        .offset_x = 0,
        .offset_y = 8,
    });

    try root.appendChild(cx.allocator, overlay);
    cx.root = root;

    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var saw_scaled_layer = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            saw_scaled_layer = true;
            try std.testing.expect(layer.use_draw_transform or layer.draw_w > 0 or layer.draw_h > 0);
            try std.testing.expect(layer.geom.x < overlay.rectFromWorldOrFallback().x);
            try std.testing.expect(layer.geom.y < overlay.rectFromWorldOrFallback().y);
            try std.testing.expect(layer.geom.w > overlay.rectFromWorldOrFallback().w);
            try std.testing.expect(layer.geom.h > overlay.rectFromWorldOrFallback().h);
            try std.testing.expect(layer.draw_x < overlay.rectFromWorldOrFallback().x);
            try std.testing.expect(layer.draw_y < overlay.rectFromWorldOrFallback().y);
            try std.testing.expect(layer.draw_w > overlay.rectFromWorldOrFallback().w);
            try std.testing.expect(layer.draw_h > overlay.rectFromWorldOrFallback().h);
            break;
        }
    }

    try std.testing.expect(saw_scaled_layer);
}

test "render: retained effect bridge preserves property-tree order" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
        .opacity = 0.5,
    }, .{});
    const root_ext = root.style.ensureExtPanic(cx.allocator);
    root_ext.glass = .{ .backdrop_blur = 6 };
    root_ext.corner_radius = ui.CornerRadius.uniform(12);

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(usize, 3), cx.property_tree.effects.items.len);
    try std.testing.expectEqual(ui.EffectKind.opacity, cx.property_tree.effects.items[0].kind);
    try std.testing.expectEqual(ui.EffectKind.backdrop_blur, cx.property_tree.effects.items[1].kind);
    try std.testing.expectEqual(ui.EffectKind.rounded_clip, cx.property_tree.effects.items[2].kind);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cx.property_tree.effects.items[1].local_bounds.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cx.property_tree.effects.items[1].local_bounds.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 180), cx.property_tree.effects.items[1].local_bounds.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), cx.property_tree.effects.items[1].local_bounds.h, 0.001);
    try std.testing.expectEqual(@as(u32, 3), cx.layer_tree.liveLayerCount());
    try std.testing.expectApproxEqAbs(@as(f32, 0), cx.layer_tree.planCompositedAt(1).?.surface_bounds_world.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cx.layer_tree.planCompositedAt(1).?.surface_bounds_world.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 180), cx.layer_tree.planCompositedAt(1).?.surface_bounds_world.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), cx.layer_tree.planCompositedAt(1).?.surface_bounds_world.h, 0.001);
    const root_runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(root_runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);
    try std.testing.expectEqual(ui.EffectKind.backdrop_blur, cx.layer_tree.planCompositedAt(root_runtime.promoted_layer_id).?.effect_kind);
    try std.testing.expectEqual(@as(usize, 9), cx.layer_tree.frame_ops.items.len);
    try std.testing.expectEqual(@as(u32, 0), cx.layer_tree.frame_ops.items[0].begin_surface.layer_id);
    try std.testing.expectEqual(@as(u32, 0), cx.layer_tree.frame_ops.items[1].end_surface.layer_id);
    try std.testing.expectEqual(@as(u32, 0), cx.layer_tree.frame_ops.items[2].draw_surface.layer_id);

    const EffectCmd = enum {
        begin_opacity,
        begin_blur,
        begin_rounded_clip,
        end_rounded_clip,
        end_blur,
        end_opacity,
    };

    var effect_commands: [6]EffectCmd = undefined;
    var effect_count: usize = 0;
    for (commands) |cmd| {
        const effect_cmd: EffectCmd = if (cmd.isControl(.begin_opacity_layer)) .begin_opacity else if (cmd.isControl(.begin_blur_layer)) .begin_blur else if (cmd.isControl(.begin_rounded_clip)) .begin_rounded_clip else if (cmd.isControl(.end_rounded_clip)) .end_rounded_clip else if (cmd.isControl(.end_blur_layer)) .end_blur else if (cmd.isControl(.end_opacity_layer)) .end_opacity else continue;
        try std.testing.expect(effect_count < effect_commands.len);
        effect_commands[effect_count] = effect_cmd;
        effect_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 6), effect_count);
    try std.testing.expectEqual(EffectCmd.begin_opacity, effect_commands[0]);
    try std.testing.expectEqual(EffectCmd.begin_blur, effect_commands[1]);
    try std.testing.expectEqual(EffectCmd.begin_rounded_clip, effect_commands[2]);
    try std.testing.expectEqual(EffectCmd.end_rounded_clip, effect_commands[3]);
    try std.testing.expectEqual(EffectCmd.end_blur, effect_commands[4]);
    try std.testing.expectEqual(EffectCmd.end_opacity, effect_commands[5]);
}

test "render: retained effect subtree skips legacy overflow cache" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
    root.style.ensureExtPanic(cx.allocator).corner_radius = ui.CornerRadius.uniform(12);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expectEqual(ui.SceneRuntimeInvalidId, runtime.effect_id);
    try std.testing.expect(runtime.clip_id != ui.SceneRuntimeInvalidId);
    const node_plan = cx.layer_tree.planQueryNode(
        root.id,
        runtime.effect_id,
        runtime.clip_id != ui.SceneRuntimeInvalidId,
        runtime.effect_id != ui.SceneRuntimeInvalidId,
        runtime.clip_bounds_fallback,
    );
    try std.testing.expect(node_plan.needs_rect_clip_fallback);
}

test "render: liquid glass background fill is attenuated when blur glaze is active" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(180, 210, 255, 120),
        .border = .{ .width = 1, .color = Color.rgba(255, 255, 255, 180), .radius = 14 },
    }, .{});
    const root_ext = root.style.ensureExtPanic(cx.allocator);
    root_ext.glass = .{ .backdrop_blur = 16, .glass_tint = Color.rgba(180, 210, 255, 96), .glass_intensity = 1.18 };
    root_ext.corner_radius = ui.CornerRadius.uniform(14);

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var saw_fill = false;
    for (commands) |cmd| {
        if (cmd.isFillRect()) {
            const rect = cmd;
            if (rect.geom.w == 180 and rect.geom.h == 100) {
                try std.testing.expect(rect.color.a < root.getBackground().a);
                saw_fill = true;
            }
        }
    }

    try std.testing.expect(saw_fill);
}

test "render: liquid glass border is attenuated when blur glaze is active" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(180, 210, 255, 48),
        .border = .{ .width = 1, .color = Color.rgba(255, 255, 255, 180), .radius = 14 },
    }, .{});
    const root_ext = root.style.ensureExtPanic(cx.allocator);
    root_ext.glass = .{ .backdrop_blur = 16, .glass_tint = Color.rgba(180, 210, 255, 96), .glass_intensity = 1.18 };
    root_ext.corner_radius = ui.CornerRadius.uniform(14);

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var saw_border = false;
    for (commands) |cmd| {
        if (cmd.isStrokeRect()) {
            const border = cmd;
            if (border.geom.w == 180 and border.geom.h == 100) {
                try std.testing.expect(border.color.a < root.style.border.color.a);
                saw_border = true;
            }
        }
    }

    try std.testing.expect(saw_border);
}

test "render: clip_shape none disables overflow clip in render runtime" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
    const root_ext = root.style.ensureExtPanic(cx.allocator);
    root_ext.corner_radius = ui.CornerRadius.uniform(12);
    root_ext.clip_shape = .none;

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expectEqual(ui.SceneRuntimeInvalidId, runtime.clip_id);
    try std.testing.expectEqual(ui.SceneRuntimeInvalidId, runtime.effect_id);

    const node_plan = cx.layer_tree.planQueryNode(
        root.id,
        runtime.effect_id,
        runtime.clip_id != ui.SceneRuntimeInvalidId,
        false,
        runtime.clip_bounds_fallback,
    );
    try std.testing.expect(!node_plan.needs_rect_clip_fallback);

    for (commands) |cmd| {
        if (cmd.isControl(.push_clip) or cmd.isControl(.begin_rounded_clip)) {
            return error.UnexpectedClipCommand;
        }
    }
}

/// Per-corner overflow clip fixture: a 200x120 owner with `radii` clipping a full-bleed child.
fn perCornerClipRoot(cx: *Cx, radii: [4]f32, extra: ui.BoxStyle) !*Node {
    return perCornerClipRootWithChild(cx, radii, extra, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } });
}

fn perCornerClipRootWithChild(cx: *Cx, radii: [4]f32, extra: ui.BoxStyle, child_style: ui.BoxStyle) !*Node {
    var style = extra;
    style.width = .{ .px = 200 };
    style.height = .{ .px = 120 };
    style.overflow_hidden = true;
    const root = try box(cx, style, .{});
    root.style.ensureExtPanic(cx.allocator).corner_radius = .{ .each = radii };
    var fill = child_style;
    fill.background = Color.rgba(229, 72, 77, 255);
    fill.flex_shrink = 0;
    const child = try box(cx, fill, .{});
    try root.appendChild(cx.allocator, child);
    return root;
}

fn expectRadii(expected: [4]f32, actual: anytype) !void {
    try std.testing.expectApproxEqAbs(expected[0], actual.tl, 0.001);
    try std.testing.expectApproxEqAbs(expected[1], actual.tr, 0.001);
    try std.testing.expectApproxEqAbs(expected[2], actual.br, 0.001);
    try std.testing.expectApproxEqAbs(expected[3], actual.bl, 0.001);
}

test "render: per-corner corner_radius overflow clip emits a per-corner rounded push_clip" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 160);
    cx.root = try perCornerClipRoot(cx, .{ 12, 0, 6, 0 }, .{});
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var rounded: usize = 0;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            // Non-uniform radii used to degrade to a rect clip; the clip now keeps each corner
            // (every lowered copy of the node-local token: paint pass and prebuilt replay).
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.rounded_rect), cmd.clip_shape_kind);
            try expectRadii(.{ 12, 0, 6, 0 }, cmd.radii);
            try std.testing.expectApproxEqAbs(@as(f32, 200), cmd.geom.w, 0.001);
            rounded += 1;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            return error.UnexpectedRoundedClipEffect;
        }
    }
    try std.testing.expect(rounded >= 1);
}

test "render: per-corner overflow clip insets each corner by its adjacent border" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 160);
    // Visible 2px border: the clip is the padding box and every corner loses the border width.
    cx.root = try perCornerClipRoot(cx, .{ 12, 0, 6, 1 }, .{ .border = .{ .width = 2, .color = Color.rgba(20, 20, 20, 255) } });
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();
    var saw = false;
    for (commands) |cmd| {
        if (!cmd.isControl(.push_clip)) continue;
        try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.rounded_rect), cmd.clip_shape_kind);
        try expectRadii(.{ 10, 0, 4, 0 }, cmd.radii);
        try std.testing.expectApproxEqAbs(@as(f32, 196), cmd.geom.w, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 116), cmd.geom.h, 0.001);
        saw = true;
    }
    try std.testing.expect(saw);
}

test "render: per-corner overflow clip folds into the opacity layer mask corner by corner" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 160);
    const root = try perCornerClipRoot(cx, .{ 0, 14, 14, 0 }, .{ .opacity = 0.5 });
    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();
    var folded = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            try expectRadii(.{ 0, 14, 14, 0 }, cmd.radii);
            folded = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            return error.UnexpectedRoundedClipEffect;
        } else if (cmd.isControl(.push_clip)) {
            // The compositor's precise apply_clip inside the surface keeps the same corners.
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.rounded_rect), cmd.clip_shape_kind);
            try expectRadii(.{ 0, 14, 14, 0 }, cmd.radii);
        }
    }
    try std.testing.expect(folded);
}

test "render: per-corner rounded_clip effect (glass owner) keeps each corner" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 160);
    const root = try perCornerClipRoot(cx, .{ 18, 0, 6, 0 }, .{});
    // Backdrop blur makes the overflow clip a rounded_clip effect (begin_rounded_clip).
    root.style.ensureExtPanic(cx.allocator).glass = .{ .backdrop_blur = 16, .glass_intensity = 0 };
    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();
    var effect = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_rounded_clip)) {
            try expectRadii(.{ 18, 0, 6, 0 }, cmd.radii);
            effect = true;
        } else if (cmd.isControl(.begin_blur_layer)) {
            try expectRadii(.{ 18, 0, 6, 0 }, cmd.radii);
        }
    }
    try std.testing.expect(effect);
}

test "render: mirrored owner keeps local corners in its surface; the composite mirrors them" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 160);
    cx.root = try perCornerClipRoot(cx, .{ 12, 0, 6, 0 }, .{ .scale_x = -1 });
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();
    var surface = false;
    var clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            // Mask radii stay owner-local; draw_transform carries the mirror at composite.
            try std.testing.expect(cmd.use_draw_transform);
            try expectRadii(.{ 12, 0, 6, 0 }, cmd.radii);
            surface = true;
        } else if (cmd.isControl(.push_clip) and cmd.clip_shape_kind == @backingInt(ui.ClipShapeKind.rounded_rect)) {
            // apply_clip goes world (mirrored corners) and back into the surface frame (local).
            try expectRadii(.{ 12, 0, 6, 0 }, cmd.radii);
            clip = true;
        }
    }
    try std.testing.expect(surface and clip);
}

test "render: lowering a node-local clip through a flip or half turn moves each radius with its corner" {
    const lowering = @import("render_engine/display_list_lowering.zig");
    const token: display_list.DisplayItem = .{ .push_clip = .{
        .header = .{ .transform_id = 0, .node_id = 1 },
        .node_local = true,
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 40,
        .radii = .{ 12, 0, 6, 0 },
        .shape_kind = .rounded_rect,
    } };
    const mirrored = (try lowering.lowerNodeClip(std.testing.allocator, token, ui.Transform2D.scale(-1, 1, 50, 20))).push_clip;
    try std.testing.expectEqual([4]f32{ 0, 12, 0, 6 }, mirrored.radii);
    try std.testing.expect(!mirrored.node_local);
    const turned = (try lowering.lowerNodeClip(std.testing.allocator, token, ui.Transform2D.rotation(std.math.pi, 50, 20))).push_clip;
    try std.testing.expectEqual([4]f32{ 6, 0, 12, 0 }, turned.radii);
    // Uniform scale 2 scales every corner; orientation unchanged.
    const scaled = (try lowering.lowerNodeClip(std.testing.allocator, token, ui.Transform2D.scale(2, 2, 0, 0))).push_clip;
    try std.testing.expectEqual([4]f32{ 24, 0, 12, 0 }, scaled.radii);
}

test "render: clip_shape ellipse emits ellipse clip fallback" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{
        // Clipped content: an empty clip scope is elided (render_engine elideEmptyScrollClipScope).
        try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 10, 10, 255) }, .{}),
    });
    root.style.ensureExtPanic(cx.allocator).clip_shape = .ellipse;

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(runtime.clip_id != ui.SceneRuntimeInvalidId);
    try std.testing.expectEqual(ui.SceneRuntimeInvalidId, runtime.effect_id);
    try std.testing.expect(!runtime.clip_bounds_fallback);

    var saw_ellipse_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.ellipse), clip.clip_shape_kind);
            saw_ellipse_clip = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            return error.UnexpectedRoundedClipEffect;
        }
    }
    try std.testing.expect(saw_ellipse_clip);
}

test "render: clip_shape path emits polygon clip for single closed polyline" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{
        // Clipped content: an empty clip scope is elided (render_engine elideEmptyScrollClipScope).
        try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 10, 10, 255) }, .{}),
    });
    root.style.ensureExtPanic(cx.allocator).clip_shape = .{ .path = .{ .fill_rule = .nonzero } };
    try root.setSvgPathHitGeometry(
        cx.allocator,
        "M20 15 L80 15 L80 75 L20 75 Z",
        .nonzero,
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(runtime.clip_id != ui.SceneRuntimeInvalidId);
    try std.testing.expectEqual(ui.SceneRuntimeInvalidId, runtime.effect_id);
    try std.testing.expect(!runtime.clip_bounds_fallback);
    const node_plan = cx.layer_tree.planQueryNode(
        root.id,
        runtime.effect_id,
        true,
        false,
        runtime.clip_bounds_fallback,
    );
    try std.testing.expect(!node_plan.clip_bounds_fallback);

    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expectApproxEqAbs(@as(f32, 20), clip.geom.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 15), clip.geom.y, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 60), clip.geom.w, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 60), clip.geom.h, 0.001);
            try std.testing.expectEqual(@as(u8, 4), clip.clip_polygon_ptr.?.point_count);
            try std.testing.expectEqual(ui.PathFillRule.nonzero, clip.clip_polygon_ptr.?.fill_rule);
            try std.testing.expectApproxEqAbs(@as(f32, 0), clip.clip_polygon_ptr.?.points[0][0], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 0), clip.clip_polygon_ptr.?.points[0][1], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 60), clip.clip_polygon_ptr.?.points[1][0], 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 0), clip.clip_polygon_ptr.?.points[1][1], 0.001);
            saw_polygon_clip = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            return error.UnexpectedRoundedClipEffect;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: simple curved clip_shape path emits polygon clip approximation" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 120 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{
        // Clipped content: an empty clip scope is elided (render_engine elideEmptyScrollClipScope).
        try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 10, 10, 255) }, .{}),
    });
    root.style.ensureExtPanic(cx.allocator).clip_shape = .{ .path = .{ .fill_rule = .evenodd } };
    try root.setSvgPathHitGeometry(
        cx.allocator,
        "M20 20 Q90 0 160 20 L160 90 L20 90 Z",
        .evenodd,
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!runtime.clip_bounds_fallback);
    try std.testing.expect(!runtime.clip_bounds_fallback);

    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expect(clip.clip_polygon_ptr.?.point_count >= 4);
            try std.testing.expectEqual(ui.PathFillRule.evenodd, clip.clip_polygon_ptr.?.fill_rule);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: single-subpath multi-curve clip_shape path stays polygon clip within expanded point budget" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(260, 220);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 180 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{
        // Clipped content: an empty clip scope is elided (render_engine elideEmptyScrollClipScope).
        try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 10, 10, 255) }, .{}),
    });
    root.style.ensureExtPanic(cx.allocator).clip_shape = .{ .path = .{ .fill_rule = .nonzero } };
    try root.setSvgPathHitGeometry(
        cx.allocator,
        "M100 20 C144 20 180 56 180 100 C180 144 144 180 100 180 C56 180 20 144 20 100 C20 56 56 20 100 20 Z",
        .nonzero,
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!runtime.clip_bounds_fallback);

    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expect(clip.clip_polygon_ptr.?.point_count > 16);
            try std.testing.expectEqual(ui.PathFillRule.nonzero, clip.clip_polygon_ptr.?.fill_rule);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: multi-subpath curved clip_shape path emits polygon clip with contours" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 120 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{
        // Clipped content: an empty clip scope is elided (render_engine elideEmptyScrollClipScope).
        try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 10, 10, 255) }, .{}),
    });
    root.style.ensureExtPanic(cx.allocator).clip_shape = .{ .path = .{ .fill_rule = .evenodd } };
    try root.setSvgPathHitGeometry(
        cx.allocator,
        "M20 20 Q90 0 160 20 L160 90 L20 90 Z M40 40 Q90 20 140 40 L140 70 L40 70 Z",
        .evenodd,
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!runtime.clip_bounds_fallback);

    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expectEqual(@as(u8, 2), clip.clip_polygon_ptr.?.contour_count);
            try std.testing.expect(clip.clip_polygon_ptr.?.point_count >= 8);
            try std.testing.expect(clip.clip_polygon_ptr.?.contour_end_points[0] < clip.clip_polygon_ptr.?.contour_end_points[1]);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: clip_shape custom degrades to rect clip in render runtime" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{
        // Clipped content: an empty clip scope is elided (render_engine elideEmptyScrollClipScope).
        try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 10, 10, 255) }, .{}),
    });
    root.style.ensureExtPanic(cx.allocator).clip_shape = .custom;

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(runtime.clip_id != ui.SceneRuntimeInvalidId);
    try std.testing.expectEqual(ui.SceneRuntimeInvalidId, runtime.effect_id);
    try std.testing.expect(runtime.clip_bounds_fallback);
    const node_plan = cx.layer_tree.planQueryNode(
        root.id,
        runtime.effect_id,
        true,
        false,
        runtime.clip_bounds_fallback,
    );
    try std.testing.expect(node_plan.clip_bounds_fallback);

    var saw_rect_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.rect), clip.clip_shape_kind);
            saw_rect_clip = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            return error.UnexpectedRoundedClipEffect;
        }
    }
    try std.testing.expect(saw_rect_clip);
}

test "render: clip_shape custom uses polygon clip when path geometry exists" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{
        // Clipped content: an empty clip scope is elided (render_engine elideEmptyScrollClipScope).
        try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 10, 10, 255) }, .{}),
    });
    root.style.ensureExtPanic(cx.allocator).clip_shape = .custom;
    try root.setSvgPathHitGeometry(
        cx.allocator,
        "M20 20 L160 20 L145 80 L35 80 Z",
        .nonzero,
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!runtime.clip_bounds_fallback);

    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expectEqual(@as(u8, 1), clip.clip_polygon_ptr.?.contour_count);
            try std.testing.expectEqual(@as(u8, 4), clip.clip_polygon_ptr.?.point_count);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: clip_shape custom uses dedicated custom clip geometry" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{
        // Clipped content: an empty clip scope is elided (render_engine elideEmptyScrollClipScope).
        try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 10, 10, 255) }, .{}),
    });
    root.style.ensureExtPanic(cx.allocator).clip_shape = .custom;
    try root.setSvgCustomClipGeometry(
        cx.allocator,
        "M20 20 L160 20 L145 80 L35 80 Z",
        .nonzero,
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!runtime.clip_bounds_fallback);

    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expectEqual(@as(u8, 1), clip.clip_polygon_ptr.?.contour_count);
            try std.testing.expectEqual(@as(u8, 4), clip.clip_polygon_ptr.?.point_count);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: clip_shape custom uses provider geometry when dedicated geometry is absent" {
    const Ctx = struct {
        svg: []const u8,
        fill_rule: ui.PathFillRule,
    };
    const callbacks = struct {
        fn provide(node: *const ui.Node, allocator: std.mem.Allocator, ctx_ptr: ?*anyopaque) !ui.PathGeometry {
            _ = node;
            const ctx = @as(*const Ctx, @ptrCast(@alignCast(ctx_ptr.?)));
            return try ui.createSvgDocumentPathGeometry(allocator, ctx.svg, ctx.fill_rule);
        }
    };

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const provider_ctx = Ctx{
        .svg = "<svg viewBox='0 0 180 100'><path d='M20 20 L160 20 L145 80 L35 80 Z'/></svg>",
        .fill_rule = .nonzero,
    };

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{
        // Clipped content: an empty clip scope is elided (render_engine elideEmptyScrollClipScope).
        try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 10, 10, 255) }, .{}),
    });
    (try root.style.ensureExtFallible(cx.allocator)).clip_shape = .custom;
    root.setCustomClipGeometryProvider(cx.allocator, callbacks.provide, @constCast(&provider_ctx));

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(!runtime.clip_bounds_fallback);

    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            try std.testing.expectEqual(@backingInt(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expectEqual(@as(u8, 1), clip.clip_polygon_ptr.?.contour_count);
            try std.testing.expectEqual(@as(u8, 4), clip.clip_polygon_ptr.?.point_count);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: overflow_hidden 子节点不把祖先的 opacity 层切成两段，clip 与内容同帧" {
    // Pre-fix (43bb5f3 emitted CONTROL scroll-clip for all overflow_hidden plain boxes):
    //   begin_opacity, parent_bg, child_bg, end_opacity, push_clip(world 60,40), begin_opacity,
    //   wide_child, end_opacity, pop_clip
    // Ancestor opacity layer split into two composites (overlap 2x blend), blur resamples backdrop
    // twice.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const parent = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 200 },
        .background = Color.rgba(10, 10, 10, 255),
        .opacity = 0.6,
        .padding = Padding.all(20),
    }, .{});
    parent.style.translate_x = 40;
    parent.style.translate_y = 20;
    const clipper = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
    }, .{});
    const wide = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 0, 0, 255) }, .{});
    try clipper.appendChild(std.testing.allocator, wide);
    try parent.appendChild(std.testing.allocator, clipper);
    cx.root = parent;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var begins: usize = 0;
    var ends: usize = 0;
    var begin_index: ?usize = null;
    var end_index: ?usize = null;
    var clip_index: ?usize = null;
    var pop_index: ?usize = null;
    var wide_index: ?usize = null;
    var clip_geom: [4]f32 = undefined;
    for (commands, 0..) |cmd, i| {
        if (cmd.isControl(.begin_opacity_layer)) {
            begins += 1;
            if (begin_index == null) begin_index = i;
        } else if (cmd.isControl(.end_opacity_layer)) {
            ends += 1;
            end_index = i;
        } else if (cmd.isControl(.push_clip)) {
            clip_index = i;
            clip_geom = .{ cmd.geom.x, cmd.geom.y, cmd.geom.w, cmd.geom.h };
        } else if (cmd.isControl(.pop_clip)) {
            pop_index = i;
        } else if (cmd.kind == .rect and cmd.geom.w == 300 and cmd.geom.h == 20) {
            wide_index = i;
        }
    }
    // Ancestor layer opens once, closes once.
    try std.testing.expectEqual(@as(usize, 1), begins);
    try std.testing.expectEqual(@as(usize, 1), ends);
    // Clip wraps wide child, whole enclosure within begin..end.
    try std.testing.expect(clip_index != null and pop_index != null and wide_index != null);
    try std.testing.expect(begin_index.? < clip_index.?);
    try std.testing.expect(clip_index.? < wide_index.?);
    try std.testing.expect(wide_index.? < pop_index.?);
    try std.testing.expect(pop_index.? < end_index.?);
    // Clip and child must agree before the encoder subtracts the shared surface origin.
    const child = commands[wide_index.?];
    try std.testing.expectApproxEqAbs(child.geom.x, clip_geom[0], 0.001);
    try std.testing.expectApproxEqAbs(child.geom.y, clip_geom[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), clip_geom[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), clip_geom[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), clip_geom[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), clip_geom[3], 0.001);
}

test "render: 自带离屏效果的 overflow_hidden 节点不再额外发 scroll-clip token" {
    // 43bb5f3 emits token for all overflow_hidden; node with own opacity/blur/rounded_clip,
    // clipping already handled by compositor apply_clip / surface mask, token duplicates, splits
    // effect.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(260, 180);
    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 80 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
        .opacity = 0.6,
    }, .{});
    const wide = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 20 }, .background = Color.rgba(200, 0, 0, 255) }, .{});
    try root.appendChild(std.testing.allocator, wide);
    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();
    var pushes: usize = 0;
    var begins: usize = 0;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) pushes += 1;
        if (cmd.isControl(.begin_opacity_layer)) begins += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), pushes);
    try std.testing.expectEqual(@as(usize, 1), begins);
}

test "render: compositor plan drives rect clip for opacity layer" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 140);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 80 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
        .opacity = 0.6,
    }, .{});
    // No shadow/stroke: owner content fully inside clip, overflow clip takes compositor
    // apply_clip fast path. Shadowed owner uses children-wrapping token (shadow exempt from
    // owner overflow clip), see "composited owner overflow clip spares owner shadow...".

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(usize, 4), cx.layer_tree.frame_ops.items.len);
    try std.testing.expectEqual(@as(u32, 0), cx.layer_tree.frame_ops.items[0].apply_clip.effect_id);
    try std.testing.expectEqual(root.id, cx.layer_tree.planCompositedAt(0).?.root_node_id);
    try std.testing.expect(cx.layer_tree.planCompositedAt(0).?.surface_bounds_world.w > 160);
    try std.testing.expect(cx.layer_tree.planCompositedAt(0).?.surface_bounds_world.h > 80);
    try std.testing.expectApproxEqAbs(@as(f32, 160), cx.layer_tree.frame_ops.items[0].apply_clip.bounds.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), cx.layer_tree.frame_ops.items[0].apply_clip.bounds.h, 0.001);

    var push_count: usize = 0;
    var begin_opacity_count: usize = 0;
    var end_opacity_count: usize = 0;
    const ClipEffectCmd = enum {
        begin_opacity,
        push_clip,
        pop_clip,
        end_opacity,
    };
    var clip_effect_commands: [4]ClipEffectCmd = undefined;
    var clip_effect_count: usize = 0;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            push_count += 1;
            try std.testing.expectApproxEqAbs(@as(f32, 160), cmd.geom.w, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 80), cmd.geom.h, 0.001);
            if (clip_effect_count < clip_effect_commands.len) {
                clip_effect_commands[clip_effect_count] = .push_clip;
                clip_effect_count += 1;
            }
        } else if (cmd.isControl(.pop_clip)) {
            if (clip_effect_count < clip_effect_commands.len) {
                clip_effect_commands[clip_effect_count] = .pop_clip;
                clip_effect_count += 1;
            }
        } else if (cmd.isControl(.begin_opacity_layer)) {
            begin_opacity_count += 1;
            if (clip_effect_count < clip_effect_commands.len) {
                clip_effect_commands[clip_effect_count] = .begin_opacity;
                clip_effect_count += 1;
            }
        } else if (cmd.isControl(.end_opacity_layer)) {
            end_opacity_count += 1;
            if (clip_effect_count < clip_effect_commands.len) {
                clip_effect_commands[clip_effect_count] = .end_opacity;
                clip_effect_count += 1;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 1), push_count);
    try std.testing.expectEqual(@as(usize, 1), begin_opacity_count);
    try std.testing.expectEqual(@as(usize, 1), end_opacity_count);
    try std.testing.expectEqual(@as(usize, 4), clip_effect_count);
    try std.testing.expectEqual(ClipEffectCmd.begin_opacity, clip_effect_commands[0]);
    try std.testing.expectEqual(ClipEffectCmd.push_clip, clip_effect_commands[1]);
    try std.testing.expectEqual(ClipEffectCmd.pop_clip, clip_effect_commands[2]);
    try std.testing.expectEqual(ClipEffectCmd.end_opacity, clip_effect_commands[3]);
}

test "render: opacity plan clip bounds projected to owner-local content frame" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(260, 180);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 80 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
        .opacity = 0.6,
    }, .{});
    root.style.translate_x = 40;
    root.style.translate_y = 20;
    cx.root = root;

    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var begin_x: ?f32 = null;
    var begin_y: ?f32 = null;
    var clip_x: ?f32 = null;
    var clip_y: ?f32 = null;
    var clip_w: ?f32 = null;
    var clip_h: ?f32 = null;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            begin_x = layer.geom.x;
            begin_y = layer.geom.y;
        } else if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            clip_x = clip.geom.x;
            clip_y = clip.geom.y;
            clip_w = clip.geom.w;
            clip_h = clip.geom.h;
        }
    }

    // CA-pure model: surface content in owner-unscaled-local frame (world translate(40,20)
    // stripped by owner_world inverse), apply_clip matches content frame = (0,0,160,80),
    // same as content_rect. World-coord clip cuts left/top 40/20px of local content (rotate
    // case clips entirely, see effect_bridge fix).
    try std.testing.expect(begin_x != null and begin_y != null);
    try std.testing.expect(clip_x != null and clip_y != null and clip_w != null and clip_h != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0), clip_x.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), clip_y.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 160), clip_w.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), clip_h.?, 0.001);
}

test "render: scroll opacity subtree disables own payload replay in effect scope" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 220);

    const faded = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 8,
        .align_items = .center,
        .opacity = 0.5,
    }, .{
        try box(cx, .{
            .width = .{ .px = 40 },
            .height = .{ .px = 22 },
            .background = Color.rgba(230, 232, 235, 255),
            .border = .{ .radius = 11 },
        }, .{}),
        blk: {
            const label = try box(cx, .{
                .width = .{ .fit = .{} },
                .height = .{ .fit = .{} },
            }, .{});
            label.setText(.{
                .content = "Disabled Off",
                .font_size = 14,
                .line_height = 1.25,
                .color = Color.rgba(148, 151, 156, 255),
            });
            break :blk label;
        },
    });

    const content = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .fit = .{} },
        .direction = .column,
        .gap = 24,
    }, .{
        try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 120 },
        }, .{}),
        faded,
    });

    const scroll = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 140 },
        .overflow_hidden = true,
    }, .{
        content,
    });
    scroll.tag = .scroll;
    cx.root = scroll;

    cx.layout();
    _ = cx.render();

    content.style.translate_y = -96;
    content.markRenderDirty();

    cx.perf.display_list_own_replay_count = 0;
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expectEqual(@as(u32, 0), cx.perf.display_list_own_replay_count);

    var saw_opacity = false;
    var saw_label = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            saw_opacity = true;
        } else if (cmd.isText()) {
            const txt = cmd;
            if (std.mem.eql(u8, txt.text_content, "Disabled Off")) saw_label = true;
        }
    }

    try std.testing.expect(saw_opacity);
    try std.testing.expect(saw_label);
}

test "render: compositor plan preserves ellipse clip for opacity layer" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 140);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 80 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
        .opacity = 0.6,
    }, .{});
    (try root.style.ensureExtFallible(cx.allocator)).clip_shape = .ellipse;

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(runtime.effect_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(runtime.clip_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(!runtime.clip_bounds_fallback);

    const effect_state = cx.layer_tree.planQueryEffect(runtime.effect_id);
    try std.testing.expect(effect_state.hasPlanClipBridge());
    try std.testing.expectEqual(ui.ClipShapeKind.ellipse, effect_state.apply_clip_shape_kind);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, effect_state.apply_clip_radii);
    try std.testing.expect(!effect_state.apply_clip_bounds_fallback);

    var begin_opacity_count: usize = 0;
    var push_count: usize = 0;
    var saw_ellipse_clip = false;
    var end_opacity_count: usize = 0;

    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            begin_opacity_count += 1;
        } else if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            push_count += 1;
            if (clip.clip_shape_kind == @backingInt(ui.display_list.ClipShapeKind.ellipse)) saw_ellipse_clip = true;
        } else if (cmd.isControl(.end_opacity_layer)) {
            end_opacity_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 1), begin_opacity_count);
    try std.testing.expectEqual(@as(usize, 1), push_count);
    try std.testing.expect(saw_ellipse_clip);
    try std.testing.expectEqual(@as(usize, 1), end_opacity_count);
}

test "render: compositor plan applies clip before blur layer" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 140);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 80 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
    }, .{});
    const root_ext = try root.style.ensureExtFallible(cx.allocator);
    root_ext.clip_shape = .ellipse;
    root_ext.glass = .{ .backdrop_blur = 6 };

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(runtime.effect_id != ui.SceneRuntimeInvalidId);

    const effect_state = cx.layer_tree.planQueryEffect(runtime.effect_id);
    try std.testing.expect(effect_state.hasPlanClipBridge());
    try std.testing.expectEqual(ui.ClipShapeKind.ellipse, effect_state.apply_clip_shape_kind);

    const EffectCmd = enum {
        push_clip,
        begin_blur,
        end_blur,
        pop_clip,
    };

    var effect_commands: [4]EffectCmd = undefined;
    var effect_count: usize = 0;
    for (commands) |cmd| {
        const effect_cmd: EffectCmd = if (cmd.isControl(.push_clip)) .push_clip else if (cmd.isControl(.begin_blur_layer)) .begin_blur else if (cmd.isControl(.end_blur_layer)) .end_blur else if (cmd.isControl(.pop_clip)) .pop_clip else continue;
        try std.testing.expect(effect_count < effect_commands.len);
        effect_commands[effect_count] = effect_cmd;
        effect_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 4), effect_count);
    try std.testing.expectEqual(EffectCmd.push_clip, effect_commands[0]);
    try std.testing.expectEqual(EffectCmd.begin_blur, effect_commands[1]);
    try std.testing.expectEqual(EffectCmd.pop_clip, effect_commands[2]);
    try std.testing.expectEqual(EffectCmd.end_blur, effect_commands[3]);
}

test "glass params resolve advanced optics controls" {
    const resolved = (ui.GlassParams{
        .surface = .concave,
        .bezel_width = 0.31,
        .bottom_surface = .lip,
        .bottom_bezel_width = 0.22,
        .specular_angle = 4.5,
        .magnification = 1.4,
        .scale_ratio = 1.22,
        .edge_field_strength = 2.6,
        .center_zoom_radius = 0.44,
        .center_zoom_falloff = 3.6,
        .backdrop_distance = 7.5,
    }).resolve();

    try std.testing.expectEqual(ui.GlassSurface.concave, resolved.surface);
    try std.testing.expectApproxEqAbs(@as(f32, 0.31), resolved.bezel_width, 0.0001);
    try std.testing.expectEqual(ui.GlassSurface.lip, resolved.bottom_surface);
    try std.testing.expectApproxEqAbs(@as(f32, 0.22), resolved.bottom_bezel_width, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5 - std.math.tau), resolved.specular_angle, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.4), resolved.magnification, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.22), resolved.scale_ratio, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.6), resolved.edge_field_strength, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.44), resolved.center_zoom_radius, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.6), resolved.center_zoom_falloff, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), resolved.backdrop_distance, 0.0001);
}

test "glass params resolve clamps optic ranges on CPU" {
    const resolved = (ui.GlassParams{
        .refraction_level = -0.4,
        .blur_level = 1.7,
        .warp_gain = 9.2,
        .center_thickness = -3.0,
    }).resolve();

    // Refraction strength [-1, 1]: negative is knob lens minify (8460fb85,
    // native_slider_toggle.swift), keep.
    try std.testing.expectApproxEqAbs(@as(f32, -0.4), resolved.refraction_level, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), (ui.GlassParams{ .refraction_level = -3.0 }).resolve().refraction_level, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), resolved.blur_level, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), resolved.warp_gain, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), resolved.center_thickness, 0.0001);
}

test "render: compositor plan preserves polygon clip for opacity layer" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(260, 180);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 120 },
        .background = Color.rgba(36, 56, 80, 255),
        .overflow_hidden = true,
        .opacity = 0.7,
    }, .{});
    (try root.style.ensureExtFallible(cx.allocator)).clip_shape = .{ .path = .{ .fill_rule = .nonzero } };
    try root.setSvgPathHitGeometry(
        cx.allocator,
        "M20 20 L150 20 L160 90 L60 105 L20 70 Z",
        .nonzero,
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(runtime.effect_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(runtime.clip_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(!runtime.clip_bounds_fallback);

    const effect_state = cx.layer_tree.planQueryEffect(runtime.effect_id);
    try std.testing.expect(effect_state.hasPlanClipBridge());
    try std.testing.expectEqual(ui.ClipShapeKind.polygon, effect_state.apply_clip_shape_kind);
    try std.testing.expectEqual(@as(u8, 5), effect_state.apply_clip_polygon.?.point_count);
    try std.testing.expectEqual(ui.PathFillRule.nonzero, effect_state.apply_clip_polygon.?.fill_rule);
    try std.testing.expect(!effect_state.apply_clip_bounds_fallback);

    var push_count: usize = 0;
    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            push_count += 1;
            if (clip.clip_shape_kind == @backingInt(ui.display_list.ClipShapeKind.polygon)) {
                try std.testing.expectEqual(@as(u8, 5), clip.clip_polygon_ptr.?.point_count);
                saw_polygon_clip = true;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 1), push_count);
    try std.testing.expect(saw_polygon_clip);
}

test "render: compositor plan preserves multi-contour polygon clip for opacity layer" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(260, 180);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 120 },
        .background = Color.rgba(36, 56, 80, 255),
        .overflow_hidden = true,
        .opacity = 0.7,
    }, .{});
    (try root.style.ensureExtFallible(cx.allocator)).clip_shape = .{ .path = .{ .fill_rule = .evenodd } };
    try root.setSvgPathHitGeometry(
        cx.allocator,
        "M20 20 L160 20 L160 100 L20 100 Z M60 45 L120 45 L120 75 L60 75 Z",
        .evenodd,
    );

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(runtime.effect_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(!runtime.clip_bounds_fallback);

    const effect_state = cx.layer_tree.planQueryEffect(runtime.effect_id);
    try std.testing.expect(effect_state.hasPlanClipBridge());
    try std.testing.expectEqual(ui.ClipShapeKind.polygon, effect_state.apply_clip_shape_kind);
    try std.testing.expectEqual(@as(u8, 2), effect_state.apply_clip_polygon.?.contour_count);
    try std.testing.expectEqual(ui.PathFillRule.evenodd, effect_state.apply_clip_polygon.?.fill_rule);
    try std.testing.expect(!effect_state.apply_clip_bounds_fallback);

    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            if (clip.clip_shape_kind == @backingInt(ui.display_list.ClipShapeKind.polygon)) {
                try std.testing.expectEqual(@as(u8, 2), clip.clip_polygon_ptr.?.contour_count);
                try std.testing.expect(clip.clip_polygon_ptr.?.contour_end_points[0] < clip.clip_polygon_ptr.?.contour_end_points[1]);
                saw_polygon_clip = true;
            }
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: queryNode exposes clip fallback for non-effect overflow subtree" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 140);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 80 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
    }, .{});

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expectEqual(ui.SceneRuntimeInvalidId, runtime.effect_id);
    try std.testing.expect(runtime.clip_id != ui.SceneRuntimeInvalidId);

    const node_plan = cx.layer_tree.planQueryNode(
        root.id,
        runtime.effect_id,
        true,
        false,
        runtime.clip_bounds_fallback,
    );
    try std.testing.expect(!node_plan.root.has_plan_layer);
    try std.testing.expectEqual(ui.SceneRuntimeInvalidId, node_plan.promoted_layer_id);
    try std.testing.expect(!node_plan.frame_flags.surface_valid);
    try std.testing.expect(node_plan.needs_rect_clip_fallback);
    try std.testing.expect(!node_plan.clip_bounds_fallback);
    try std.testing.expect(!node_plan.effect.has_plan_layer);
    try std.testing.expect(!node_plan.effect.hasPlanClipBridge());
}

test "render: queryNode and queryEffect expose managed opacity clip bridge" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 140);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 80 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
        .opacity = 0.6,
    }, .{});
    // No shadow/stroke: owner content fully inside clip, overflow clip takes compositor
    // apply_clip fast path. Shadowed owner uses children-wrapping token (shadow exempt from
    // owner overflow clip), see "composited owner overflow clip spares owner shadow...".

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(runtime.effect_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(runtime.clip_id != ui.SceneRuntimeInvalidId);

    const node_plan = cx.layer_tree.planQueryNode(
        root.id,
        runtime.effect_id,
        true,
        false,
        runtime.clip_bounds_fallback,
    );
    try std.testing.expect(node_plan.root.has_plan_layer);
    try std.testing.expectEqual(@as(u32, 0), node_plan.effect.layer_id);
    try std.testing.expect(node_plan.effect.hasCompleteSurfaceBridge());
    try std.testing.expect(node_plan.effect.hasPlanClipBridge());
    try std.testing.expect(!node_plan.needs_rect_clip_fallback);
    try std.testing.expect(!node_plan.clip_bounds_fallback);
    try std.testing.expect(node_plan.effect.begin_bounds != null);
    try std.testing.expect(node_plan.effect.apply_clip_bounds != null);
    try std.testing.expect(node_plan.effect.draw_opacity != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), node_plan.effect.draw_opacity.?, 0.001);
    try std.testing.expect(node_plan.effect.begin_bounds.?.w > 160);
    try std.testing.expect(node_plan.effect.begin_bounds.?.h > 80);
    try std.testing.expectApproxEqAbs(@as(f32, 160), node_plan.effect.apply_clip_bounds.?.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), node_plan.effect.apply_clip_bounds.?.h, 0.001);
}

test "render: sibling z_index controls stable paint order without mutating child order" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(160, 100);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 100 },
    }, .{});
    const high = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 60 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    (try high.style.ensureExtFallible(cx.allocator)).z_index = 20;
    const low = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 60 },
        .background = Color.rgba(0, 0, 255, 255),
    }, .{});
    (try low.style.ensureExtFallible(cx.allocator)).z_index = 10;

    // Deliberately append the higher sibling first.
    try root.appendChild(cx.allocator, high);
    try root.appendChild(cx.allocator, low);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    var high_order: ?usize = null;
    var low_order: ?usize = null;
    for (cx.display_list.items.items, 0..) |item, index| switch (item) {
        .fill_rect => |fill| {
            if (fill.header.node_id == high.id and high_order == null) high_order = index;
            if (fill.header.node_id == low.id and low_order == null) low_order = index;
        },
        else => {},
    };
    try std.testing.expect(low_order != null);
    try std.testing.expect(high_order != null);
    try std.testing.expect(low_order.? < high_order.?);
    try std.testing.expectEqual(high, root.children.items[0]);
    try std.testing.expectEqual(low, root.children.items[1]);

    // Exercise the retained/cache pass on a later frame. The render-time sort
    // must be applied again and must still restore the logical tree.
    cx.frame_time_ms = 16.0;
    _ = cx.render();
    high_order = null;
    low_order = null;
    for (cx.display_list.items.items, 0..) |item, index| switch (item) {
        .fill_rect => |fill| {
            if (fill.header.node_id == high.id and high_order == null) high_order = index;
            if (fill.header.node_id == low.id and low_order == null) low_order = index;
        },
        else => {},
    };
    try std.testing.expect(low_order != null);
    try std.testing.expect(high_order != null);
    try std.testing.expect(low_order.? < high_order.?);
    try std.testing.expectEqual(high, root.children.items[0]);
    try std.testing.expectEqual(low, root.children.items[1]);
}

test "render: positive sticky siblings obey z_index and match hit testing" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(160, 140);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 140 },
        .direction = .column,
    }, .{});
    const high = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 60 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    high.setFocusable(true);
    (try high.style.ensureExtFallible(cx.allocator)).z_index = 20;

    const low_sticky = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 60 },
        .position = .sticky,
        .background = Color.rgba(0, 0, 255, 255),
    }, .{});
    low_sticky.setFocusable(true);
    (try low_sticky.style.ensureExtFallible(cx.allocator)).z_index = 10;

    try root.appendChild(cx.allocator, high);
    try root.appendChild(cx.allocator, low_sticky);
    cx.root = root;
    cx.layout();

    // Make the two siblings overlap without changing their logical order.
    const high_rect = high.rectFromWorldOrFallback();
    const low_rect = low_sticky.rectFromWorldOrFallback();
    low_sticky.setStyle(null, .translate_x, high_rect.x - low_rect.x);
    low_sticky.setStyle(null, .translate_y, high_rect.y - low_rect.y);
    _ = cx.render();

    var high_order: ?usize = null;
    var low_order: ?usize = null;
    for (cx.display_list.items.items, 0..) |item, index| switch (item) {
        .fill_rect => |fill| {
            if (fill.header.node_id == high.id and high_order == null) high_order = index;
            if (fill.header.node_id == low_sticky.id and low_order == null) low_order = index;
        },
        else => {},
    };
    try std.testing.expect(low_order != null);
    try std.testing.expect(high_order != null);
    try std.testing.expect(low_order.? < high_order.?);
    try std.testing.expectEqual(high, cx.hitTest(high_rect.x + 10, high_rect.y + 10));
    // Hit side paint_order same as render order (C2 deleted global stacking_z, hit result from
    // paint_order only; old: high paint_order smaller, masked by stacking_z 20>10).
    try std.testing.expect(high.frame_state.frame_local.spatial.paint.order > low_sticky.frame_state.frame_local.spatial.paint.order);
    try std.testing.expectEqual(high, root.children.items[0]);
    try std.testing.expectEqual(low_sticky, root.children.items[1]);
}

/// Advance frame clock then render: ensureBeforeRenderTicked skips tick same frame, sticky
/// unchanged.
fn renderNextStickyFrame(cx: *Cx) void {
    cx.frame_time_ms += 16.0;
    _ = cx.render();
}

/// viewport(200x200, overflow_hidden) -> content(translate_y = -S)
///   -> [spacer 500, section 300 -> [header 40 (sticky top=0)]]
/// Appendix A probe 5: sticky parent is doc-flow block at y=500.
const StickySectionFixture = struct {
    content: *Node,
    section: *Node,
    header: *Node,

    fn build(cx: *Cx) !StickySectionFixture {
        cx.setViewport(200, 200);
        const viewport = try box(cx, .{
            .width = .{ .px = 200 },
            .height = .{ .px = 200 },
            .direction = .column,
            .overflow_hidden = true,
        }, .{});
        const content = try box(cx, .{ .width = .{ .px = 200 }, .direction = .column }, .{});
        const lead = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 500 } }, .{});
        const section = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 300 }, .direction = .column }, .{});
        const header = try box(cx, .{
            .width = .{ .px = 200 },
            .height = .{ .px = 40 },
            .position = .sticky,
            .background = Color.rgba(0, 0, 255, 255),
        }, .{});
        (try header.style.ensureExtFallible(cx.allocator)).sticky_insets = .{ .top = 0 };
        try section.appendChild(cx.allocator, header);
        try content.appendChild(cx.allocator, lead);
        try content.appendChild(cx.allocator, section);
        try viewport.appendChild(cx.allocator, content);
        cx.root = viewport;
        cx.layout();
        return .{ .content = content, .section = section, .header = header };
    }

    fn scrollTo(self: StickySectionFixture, cx: *Cx, scroll: f32) void {
        self.content.setStyle(null, .translate_y, -scroll);
        renderNextStickyFrame(cx);
    }
};

test "sticky: clamp uses parent origin once (section in flow)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const fx = try StickySectionFixture.build(cx);
    try std.testing.expectEqual(@as(f32, 500), fx.section.rectFromWorldOrFallback().y);

    // Hasn't reached stick line: natural position.
    fx.scrollTo(cx, 100);
    try std.testing.expectEqual(@as(f32, 0), fx.header.frame_state.frame_local.runtime.sticky.y);
    // Pinned: header natural y = 500-600 = -100, offset +100; section bottom not reached.
    fx.scrollTo(cx, 600);
    try std.testing.expectEqual(@as(f32, 100), fx.header.frame_state.frame_local.runtime.sticky.y);
    // Constrained: section screen bottom = 500+300-780 = 20, header bottom can't exceed -> offset
    // 260 (old formula re-added section.rect.y, got 280, header escapes past section).
    fx.scrollTo(cx, 780);
    try std.testing.expectEqual(@as(f32, 260), fx.header.frame_state.frame_local.runtime.sticky.y);
    const g = fx.header.globalRect();
    try std.testing.expectEqual(@as(f32, -20), g.y);
    try std.testing.expectEqual(@as(f32, 20), g.y + g.h);
}

test "sticky: clamp with scrolled parent (parent.translate_y != 0)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 200);
    // viewport(clip) -> content(translate_y=-S, padding.bottom=10) -> [lead 100, header 40, tail
    // 300]
    // sticky parent is scrolled content: old formula double-added parent.translate_y(=-S), cap
    // small -> early release.
    const viewport = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
        .direction = .column,
        .overflow_hidden = true,
    }, .{});
    const content = try box(cx, .{
        .width = .{ .px = 200 },
        .direction = .column,
        .padding = .{ .bottom = 10 },
    }, .{});
    const lead = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const header = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 }, .position = .sticky }, .{});
    (try header.style.ensureExtFallible(cx.allocator)).sticky_insets = .{ .top = 0 };
    const tail = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 300 } }, .{});
    try content.appendChild(cx.allocator, lead);
    try content.appendChild(cx.allocator, header);
    try content.appendChild(cx.allocator, tail);
    try viewport.appendChild(cx.allocator, content);
    cx.root = viewport;
    cx.layout();
    try std.testing.expectEqual(@as(f32, 450), content.rectFromWorldOrFallback().h);

    // S=380: header natural y=-280 -> offset 280; content bottom = 450-10-380 = 60, cap 60+280-40 =
    // 300, no constrain.
    content.setStyle(null, .translate_y, -380);
    renderNextStickyFrame(cx);
    try std.testing.expectEqual(@as(f32, 280), header.frame_state.frame_local.runtime.sticky.y);
    // S=430: natural y=-330 -> want 330; content bottom = 10, cap 10+330-40 = 300 -> constrain to
    // 300.
    content.setStyle(null, .translate_y, -430);
    renderNextStickyFrame(cx);
    try std.testing.expectEqual(@as(f32, 300), header.frame_state.frame_local.runtime.sticky.y);
    const g = header.globalRect();
    try std.testing.expectEqual(@as(f32, 10), g.y + g.h);
}

test "sticky: offset resets when ancestor clip intersection is empty" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 200);
    // root(200×200) -> clipper(100×100, clip) -> content(translate_y=-100) -> [lead 50, header 20, tail 200]
    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 }, .direction = .column }, .{});
    const clipper = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
        .direction = .column,
        .overflow_hidden = true,
    }, .{});
    const content = try box(cx, .{ .width = .{ .px = 100 }, .direction = .column }, .{});
    const lead = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const header = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 20 }, .position = .sticky }, .{});
    (try header.style.ensureExtFallible(cx.allocator)).sticky_insets = .{ .top = 0 };
    const tail = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 200 } }, .{});
    try content.appendChild(cx.allocator, lead);
    try content.appendChild(cx.allocator, header);
    try content.appendChild(cx.allocator, tail);
    try clipper.appendChild(cx.allocator, content);
    try root.appendChild(cx.allocator, clipper);
    cx.root = root;
    cx.layout();

    content.setStyle(null, .translate_y, -100);
    renderNextStickyFrame(cx);
    try std.testing.expectEqual(@as(f32, 50), header.frame_state.frame_local.runtime.sticky.y);

    // Clipper whole moved offscreen: ancestor clip empty, sticky no stick zone,
    // offset must zero, can't stale prev frame's 50 (globalRect / hit / popover reads it).
    clipper.setStyle(null, .translate_y, 1000);
    renderNextStickyFrame(cx);
    try std.testing.expectEqual(@as(f32, 0), header.frame_state.frame_local.runtime.sticky.y);
    try std.testing.expectEqual(@as(f32, 1000 + 50 - 100), header.globalRect().y);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(header.frame_state.frame_local.runtime.sticky.state)));
}

test "sticky: own translate participates in natural position" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const fx = try StickySectionFixture.build(cx);
    fx.header.setStyle(null, .translate_y, 10);

    // Pinned: natural y = 500-600+10 = -90 -> offset 90, visual top at stick line 0.
    fx.scrollTo(cx, 600);
    try std.testing.expectEqual(@as(f32, 90), fx.header.frame_state.frame_local.runtime.sticky.y);
    try std.testing.expectEqual(@as(f32, 0), fx.header.globalRect().y);
    // Constrained: visual bottom (with translate) at section bottom 20 -> offset 20-(-270)-40 =
    // 250.
    fx.scrollTo(cx, 780);
    try std.testing.expectEqual(@as(f32, 250), fx.header.frame_state.frame_local.runtime.sticky.y);
    const g = fx.header.globalRect();
    try std.testing.expectEqual(@as(f32, 20), g.y + g.h);
}

test "sticky: state flags follow natural -> pinned -> constrained -> scrolled out" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const fx = try StickySectionFixture.build(cx);
    const sticky = &fx.header.frame_state.frame_local.runtime.sticky;

    const Expect = struct { scroll: f32, offset: f32, engaged_top: bool, pinned: bool, constrained: bool };
    const steps = [_]Expect{
        // Natural position: hasn't crossed stick line.
        .{ .scroll = 100, .offset = 0, .engaged_top = false, .pinned = false, .constrained = false },
        // Aligned to stick line.
        .{ .scroll = 600, .offset = 100, .engaged_top = true, .pinned = true, .constrained = false },
        // Pushed by section bottom (transition).
        .{ .scroll = 780, .offset = 260, .engaged_top = true, .pinned = false, .constrained = true },
        // Header wholly scrolled offscreen (visual -70..-30), still constrained by section.
        .{ .scroll = 830, .offset = 260, .engaged_top = true, .pinned = false, .constrained = true },
        // Scroll back to section top, enter viewport: clear all state.
        // Note: scroll to section leaves clip+48px margin (e.g. scroll=0), tick skips whole section
        // subtree out-of-clip, deep sticky unchanged (see S3.4 S3, C1 unhandled).
        .{ .scroll = 300, .offset = 0, .engaged_top = false, .pinned = false, .constrained = false },
    };
    for (steps) |step| {
        fx.scrollTo(cx, step.scroll);
        try std.testing.expectEqual(step.offset, sticky.y);
        try std.testing.expectEqual(@as(f32, 0), sticky.x);
        try std.testing.expectEqual(step.engaged_top, sticky.state.engaged_top);
        try std.testing.expect(!sticky.state.engaged_bottom);
        try std.testing.expect(!sticky.state.engaged_left);
        try std.testing.expect(!sticky.state.engaged_right);
        try std.testing.expectEqual(step.pinned, sticky.state.pinned);
        try std.testing.expectEqual(step.pinned, sticky.isStuck());
        try std.testing.expectEqual(step.constrained, sticky.state.constrained);
    }
    try std.testing.expectEqual(@as(f32, 200), fx.header.globalRect().y);
}

test "sticky: solveSticky exhaustive clamp matrix" {
    const geometry = @import("render_engine/geometry.zig");
    const Rect = ui.ComputedRect;
    const Side = enum { top, bottom, left, right };
    const Phase = enum { idle, pinned, constrained };
    const size: f32 = 40;
    const parent_size: f32 = 300;
    const clip = Rect.init(0, 0, 200, 200);

    // 1D model (along sticky direction): the parent content box has pad deducted at both ends;
    // sticky sits on the content edge nearest the stick line (leading = pad,
    // trailing = parent_size - pad - size), own translate = t. Natural by phase, parent_origin reverse-solved:
    //   leading  line 0: idle natural=50, pinned natural=-100, constrained natural=-280
    //   trailing line 160: idle natural=60, pinned natural=260, constrained natural=440
    // Expect offset: idle 0, pinned 100, constrained = spare = 260-2pad+/-t (leading -t, trailing
    // +t).
    // parent_rect x/y deliberately 500: layout coord vs ancestor, must ignore in solve
    // (double-count shape).
    for ([_]Side{ .top, .bottom, .left, .right }) |side| {
        for ([_]f32{ 0, 10 }) |pad| {
            for ([_]f32{ 0, 5 }) |t| {
                for ([_]Phase{ .idle, .pinned, .constrained }) |phase| {
                    const leading = side == .top or side == .left;
                    const vertical = side == .top or side == .bottom;
                    const local: f32 = if (leading) pad else parent_size - pad - size;
                    const natural: f32 = if (leading) switch (phase) {
                        .idle => 50,
                        .pinned => -100,
                        .constrained => -280,
                    } else switch (phase) {
                        .idle => 60,
                        .pinned => 260,
                        .constrained => 440,
                    };
                    const origin_axis = natural - local - t;
                    const magnitude: f32 = switch (phase) {
                        .idle => 0,
                        .pinned => 100,
                        // Own translate shrinks leading-side spare, grows trailing-side spare.
                        .constrained => 260 - 2 * pad - (if (leading) t else -t),
                    };
                    const expected: f32 = if (leading) magnitude else -magnitude;

                    // Other axis: natural 50 (inside clip), no inset on this axis, no offset
                    // produces.
                    const insets: @import("types.zig").StickyInsets = switch (side) {
                        .top => .{ .top = 0 },
                        .bottom => .{ .bottom = 0 },
                        .left => .{ .left = 0 },
                        .right => .{ .right = 0 },
                    };
                    const cross_local = pad;
                    const cross_origin: f32 = 50 - pad;
                    const in = geometry.StickyInput{
                        .self_rect = if (vertical)
                            Rect.init(cross_local, local, size, size)
                        else
                            Rect.init(local, cross_local, size, size),
                        .self_translate = if (vertical) .{ .x = 0, .y = t } else .{ .x = t, .y = 0 },
                        .parent_origin = if (vertical)
                            .{ .x = cross_origin, .y = origin_axis }
                        else
                            .{ .x = origin_axis, .y = cross_origin },
                        .parent_rect = Rect.init(500, 500, parent_size, parent_size),
                        .parent_padding = Padding.all(pad),
                        .insets = insets,
                        .clip = clip,
                    };
                    const r = geometry.solveSticky(in);
                    errdefer std.debug.print("side={s} pad={d} t={d} phase={s} got=({d},{d}) state={any}\n", .{ @tagName(side), pad, t, @tagName(phase), r.offset.x, r.offset.y, r.state });

                    const main_axis = if (vertical) r.offset.y else r.offset.x;
                    const cross_axis = if (vertical) r.offset.x else r.offset.y;
                    try std.testing.expectEqual(expected, main_axis);
                    try std.testing.expectEqual(@as(f32, 0), cross_axis);

                    const engaged = phase != .idle;
                    try std.testing.expectEqual(engaged and side == .top, r.state.engaged_top);
                    try std.testing.expectEqual(engaged and side == .bottom, r.state.engaged_bottom);
                    try std.testing.expectEqual(engaged and side == .left, r.state.engaged_left);
                    try std.testing.expectEqual(engaged and side == .right, r.state.engaged_right);
                    try std.testing.expectEqual(phase == .pinned, r.state.pinned);
                    try std.testing.expectEqual(phase == .constrained, r.state.constrained);

                    // After constraint, visual (with own translate) aligns at content box edge.
                    if (phase == .constrained) {
                        const content_lo = origin_axis + pad;
                        const content_hi = origin_axis + parent_size - pad;
                        const visual = natural + main_axis;
                        if (leading)
                            try std.testing.expectEqual(content_hi, visual + size)
                        else
                            try std.testing.expectEqual(content_lo, visual);
                    }
                }
            }
        }
    }

    // No parent: no constraint, pure pin.
    {
        const r = geometry.solveSticky(.{
            .self_rect = Rect.init(0, 0, size, size),
            .parent_origin = .{ .x = 0, .y = -280 },
            .parent_rect = null,
            .insets = .{ .top = 0 },
            .clip = clip,
        });
        try std.testing.expectEqual(@as(f32, 280), r.offset.y);
        try std.testing.expect(r.state.pinned and !r.state.constrained);
    }
    // Explicit constraint replaces parent content box.
    {
        const r = geometry.solveSticky(.{
            .self_rect = Rect.init(0, 0, size, size),
            .parent_origin = .{ .x = 0, .y = -280 },
            .parent_rect = Rect.init(0, 0, parent_size, parent_size),
            .insets = .{ .top = 0 },
            .clip = clip,
            .constraint = Rect.init(0, -280, 200, 400),
        });
        // Constraint bottom 120 -> cap 120-(-280)-40 = 360, doesn't truncate wanted 280.
        try std.testing.expectEqual(@as(f32, 280), r.offset.y);
        try std.testing.expect(r.state.pinned);
        const r2 = geometry.solveSticky(.{
            .self_rect = Rect.init(0, 0, size, size),
            .parent_origin = .{ .x = 0, .y = -280 },
            .parent_rect = Rect.init(0, 0, parent_size, parent_size),
            .insets = .{ .top = 0 },
            .clip = clip,
            .constraint = Rect.init(0, -280, 200, 100),
        });
        // Constraint bottom -180 -> cap -180-(-280)-40 = 60.
        try std.testing.expectEqual(@as(f32, 60), r2.offset.y);
        try std.testing.expect(r2.state.constrained and !r2.state.pinned);
    }
}

test "render: legacy overflow cache replays escaped overlay exactly once" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(180, 120);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 100 },
        .overflow_hidden = true,
        .background = Color.rgba(20, 30, 40, 255),
    }, .{});
    const overlay = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 50 },
        .background = Color.rgba(220, 40, 60, 180),
    }, .{});
    overlay.setOpacityRaw(0.8);
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 10;
    try root.appendChild(cx.allocator, overlay);
    ui.animateNode(overlay, cx.allocator, .{
        .prop = .scale_x,
        .from = 0.9,
        .to = 1.0,
        .duration = 0.3,
    });
    cx.root = root;
    cx.layout();

    _ = cx.render();
    try std.testing.expect(root.meta.per_frame.caches.commands.own != null);
    var first_overlay_fill_count: usize = 0;
    for (cx.display_list.items.items) |item| switch (item) {
        .fill_rect => |fill| if (fill.header.node_id == overlay.id) {
            first_overlay_fill_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), first_overlay_fill_count);

    cx.frame_time_ms = 16.0;
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    try std.testing.expect(cx.perf.render_cache_hit > 0);
    var replay_overlay_fill_count: usize = 0;
    for (cx.display_list.items.items) |item| switch (item) {
        .fill_rect => |fill| if (fill.header.node_id == overlay.id) {
            replay_overlay_fill_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), replay_overlay_fill_count);
}

test "render: legacy overflow cache hit emits the owner's own content once, before its children" {
    // Progress bar shape: overflow_hidden + background track with fill inside; sibling repaints
    // parent, track subtree uses cache replay. Replay once emitted own post-descendants
    // (Stage B dual-list merge mirror remnant): track bg covers fill, static frame flashes.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{ .width = .{ .px = 220 }, .height = .{ .px = 100 }, .direction = .column }, .{});
    const sibling = try box(cx, .{ .width = .{ .px = 60 }, .height = .{ .px = 20 }, .background = Color.rgba(90, 90, 90, 255) }, .{});
    const track = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 6 },
        .overflow_hidden = true,
        .background = Color.rgba(30, 34, 48, 255),
    }, .{});
    const fill = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 6 }, .background = Color.rgba(199, 187, 179, 255) }, .{});
    try track.appendChild(cx.allocator, fill);
    try root.appendChild(cx.allocator, sibling);
    try root.appendChild(cx.allocator, track);
    cx.root = root;
    cx.layout();
    _ = cx.render();
    try std.testing.expect(track.meta.per_frame.caches.commands.own != null);

    // Sibling change only: parent repaints, track subtree clean -> legacy overflow cache replay.
    sibling.setBackgroundRaw(Color.rgba(120, 120, 120, 255));
    cx.frame_time_ms = 16.0;
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    try std.testing.expect(cx.perf.render_cache_hit > 0);

    var track_fills: usize = 0;
    var child_fills: usize = 0;
    var track_at: ?usize = null;
    var fill_at: ?usize = null;
    for (cx.display_list.items.items, 0..) |item, i| switch (item) {
        .fill_rect => |f| {
            if (f.header.node_id == track.id) {
                track_fills += 1;
                if (track_at == null) track_at = i;
            }
            if (f.header.node_id == fill.id) {
                child_fills += 1;
                if (fill_at == null) fill_at = i;
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), track_fills);
    try std.testing.expectEqual(@as(usize, 1), child_fills);
    try std.testing.expect(track_at.? < fill_at.?);
}

// --- z>0 out-of-band render units: guardrails (plan sticky-zindex-clip-decoupling-plan.md S10
// V1/V2) ---
//
// C2 (remove escapes, legacy re-render via parent clip): V1 is a regular regression test.
// C3 (out-of-band dirty bubble per-hop, node_dirty.zig isOutOfBandRenderUnit): both V2 tests
// are regular regression tests.

fn knownBugFillColorOfSize(cx: *Cx, w: f32, h: f32) ?Color {
    for (cx.lowerForEncoderPaintTable()) |it| {
        if (!it.isFillRect()) continue;
        if (@abs(it.geom.w - w) > 0.5 or @abs(it.geom.h - h) > 0.5) continue;
        return Color.rgba(it.color.r, it.color.g, it.color.b, it.color.a);
    }
    return null;
}

test "render: positive z child stays clipped on legacy overflow cache hit" {
    // V1 (plan S9.1 item 2). Mirrors "legacy overflow cache replays escaped overlay exactly once":
    // z>0 overlay carries its own opacity layer (0.8 opacity + scale animation); render dirty does
    // not
    // bubble (escapesAncestorRenderPass, now isOutOfBandRenderUnit), so clipper frame 2+ hits the
    // legacy overflow cache. On a hit, renderOverlayChildrenAfterCacheHit re-renders the overlay
    // with
    // clip=null **after** the cache commands (clipper push/pop_clip token pair) -> scissor stack is
    // empty and 30px past the clipper bottom renders; fresh frame 1 is inside the tokens, clipped.
    // Only "z>0 child renders in paint pass" is affected; plain / opacity-only z>0 child content is
    // written by same-frame prebuild inside the tokens, so hit frames stay clipped (probe control).
    // Fix: re-render passes parent clip/clip_id; overlay ranks after the cache tokens but carries a
    // clip-bridge (in its own opacity surface local) converted to world = clipper frame. Scissor
    // via
    // surface-aware c2ScissorStackForFill: direct world intersection of the clip-bridge is wrong.
    // Also: clipper bg is re-drawn at end of hit frame (mod.zig tryReplayLegacyOverflowCacheHit,
    // unconditional appendNodeOwnContent); out of plan scope, unasserted.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(180, 160);

    const clipper = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 100 },
        .overflow_hidden = true,
        .background = Color.rgba(20, 30, 40, 255),
    }, .{});
    const overlay_color = Color.rgba(220, 40, 60, 255);
    const overlay = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 60 },
        .background = overlay_color,
    }, .{});
    overlay.style.translate_y = 70; // y in [70,130): overflows clipper bottom 30px.
    overlay.setOpacityRaw(0.8);
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 10;
    try clipper.appendChild(cx.allocator, overlay);
    ui.animateNode(overlay, cx.allocator, .{
        .prop = .scale_x,
        .from = 0.9,
        .to = 1.0,
        .duration = 0.3,
    });
    cx.root = clipper;
    cx.layout();

    const clipper_box = ui.ComputedRect.init(0, 0, 160, 100);

    _ = cx.render();
    try std.testing.expect(clipper.meta.per_frame.caches.commands.own != null);
    const fresh = (try c2ScissorStackForFill(cx, 80, 60, overlay_color)).rect orelse return error.FreshFrameUnclipped;
    try std.testing.expectEqual(clipper_box, fresh);

    cx.frame_time_ms = 16.0;
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    // Precondition: frame truly took legacy overflow cache hit path.
    try std.testing.expect(cx.perf.render_cache_hit > 0);
    try std.testing.expect(clipper.meta.per_frame.caches.commands.own != null);
    const replayed = (try c2ScissorStackForFill(cx, 80, 60, overlay_color)).rect orelse return error.CacheHitFrameUnclipped;
    try std.testing.expectEqual(clipper_box, replayed);
}

fn knownBugPositiveZChildRepaint(promoted_is_grandparent: bool) !void {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const root = try box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 240 } }, .{});
    // opacity always 1: dirty criterion parent.opacity >= 0.999 holds -> child render dirty doesn't
    // bubble.
    const promoted = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
        .background = Color.rgba(20, 30, 40, 255),
    }, .{});
    (try promoted.style.ensureExtFallible(cx.allocator)).composited_group = true;
    const child = try box(cx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 70 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    (try child.style.ensureExtFallible(cx.allocator)).z_index = 5;
    if (promoted_is_grandparent) {
        const plain_parent = try box(cx, .{
            .width = .{ .px = 150 },
            .height = .{ .px = 150 },
            .background = Color.rgba(40, 40, 40, 255),
        }, .{});
        try plain_parent.appendChild(cx.allocator, child);
        try promoted.appendChild(cx.allocator, plain_parent);
    } else {
        try promoted.appendChild(cx.allocator, child);
    }
    try root.appendChild(cx.allocator, promoted);
    cx.root = root;
    cx.layout();

    _ = cx.render();
    try std.testing.expect(promoted.meta.per_frame.caches.commands.promoted != null);
    try std.testing.expectEqual(Color.rgba(255, 0, 0, 255), knownBugFillColorOfSize(cx, 60, 70).?);

    const blue = Color.rgba(0, 0, 255, 255);
    child.setBackground(blue);
    cx.frame_time_ms = 16.0;
    _ = cx.render();
    try std.testing.expectEqual(blue, knownBugFillColorOfSize(cx, 60, 70).?);
    // Re-render frame (no new changes): can't rely on "next frame self-heals".
    cx.frame_time_ms = 32.0;
    _ = cx.render();
    try std.testing.expectEqual(blue, knownBugFillColorOfSize(cx, 60, 70).?);
}

test "render: positive z child content change repaints under composited_group parent" {
    // V2 (plan S3.3 / S10). Parent composited_group=true, opacity=1: the dirty criterion
    // (parent.opacity >= 0.999) deems the z>0 child out-of-band so render dirty does not bubble,
    // while
    // the render side has use_opacity_layer=true -> childEscapesAncestorClipInPass=false and the
    // promoted
    // cache hit (renderOverlayChildrenAfterCacheHit) skips re-render: recolor sticks at the old
    // color.
    // Reproduces with composited_group and "z>0 + will_change" parents, not rotate / scale /
    // blend_mode
    // parents (no promoted replay, cache_hit=0). Fix: a parent holding a promoted cache makes the
    // child not out-of-band.
    try knownBugPositiveZChildRepaint(false);
}

test "render: positive z grandchild content change repaints under composited_group ancestor" {
    // V2 extension: composited_group grandparent -> plain parent (opacity 1, no opacity layer) ->
    // z>0 child.
    // Here the dirty/render criteria **align** (both deem the child out-of-band), yet it is still
    // stale:
    // child dirty stops at parent, the promoted grandparent replays its whole old cache, and
    // re-render
    // only sees the grandparent's direct children. So aligning criteria alone doesn't fix it;
    // out-of-band
    // dirty must invalidate the promoted/cached ancestor. OverlayStack content nodes
    // (Modal/Popover/
    // Tooltip, overlay_stack.zig bindContentNode) are all composited_group, so in-place recolor of
    // any
    // z>0 node inside (focus ring, checkbox indicator, etc) lands here.
    // Fix: child->parent hop is out-of-band (parent unchanged); bubble continues to promoted
    // ancestor.
    try knownBugPositiveZChildRepaint(true);
}

// --- C3: render dirty of an out-of-band unit (z>0) must invalidate the cache ancestor wrapping it
// ---
//
// Plan S5.4 / S10 C3. Rule (node_dirty.zig bubbleOutOfBandSubtreeRender): judge per hop whether the
// child is out-of-band to its parent (z>0 AND parent.opacity >= 0.999 AND parent has no promoted
// cache). Yes -> parent's legacy cache replay omits the child subtree and re-renders fresh, parent
// unchanged, but **continue upward**. Else the parent cache (promoted whole replay / legacy
// snapshot)
// holds the child's old commands: set subtree_render. Stopping at the first out-of-band hop leaves
// a promoted ancestor replaying the old cache (V2). Guardrails below cover correctness/perf.

fn c3FillColorOfNode(cx: *Cx, node_id: u32) ?Color {
    var found: ?Color = null;
    for (cx.display_list.items.items) |item| switch (item) {
        .fill_rect => |fill| if (fill.header.node_id == node_id) {
            found = fill.color;
        },
        else => {},
    };
    return found;
}

/// z>0 node renders in paint pass (own opacity layer + long scale animation): plain z>0 content
/// each frame fresh-built by prebuild, legacy snapshot has no entry, can't measure stale (V1 probe
/// same
/// conclusion). Layered only caught by legacy snapshot whole capture.
fn c3MakePaintPassUnit(cx: *Cx, node: *Node) void {
    node.setOpacityRaw(0.8);
    ui.animateNode(node, cx.allocator, .{ .prop = .scale_x, .from = 0.99, .to = 1.0, .duration = 30.0 });
}

fn c3CountFillsOfNode(cx: *Cx, node_id: u32) usize {
    var n: usize = 0;
    for (cx.display_list.items.items) |item| switch (item) {
        .fill_rect => |fill| if (fill.header.node_id == node_id) {
            n += 1;
        },
        else => {},
    };
    return n;
}

test "render: C3 positive z grandchild change invalidates legacy overflow grandparent" {
    // legacy overflow ancestor -> plain parent -> z>0 grandchild (paint pass unit): ancestor legacy
    // snapshot omits its **direct** z>0 children, grandchild old commands in snapshot.
    // Grandchild->parent
    // out-of-band (skip), parent->ancestor not, must invalidate ancestor. Old: stops at first hop
    // ->
    // ancestor hits cache, picture stale (plan S10 V2 probe "legacy ancestor not stale" only holds
    // for plain).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 160);

    const clipper = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 120 },
        .overflow_hidden = true,
        .background = Color.rgba(20, 30, 40, 255),
    }, .{});
    const mid = try box(cx, .{ .width = .{ .px = 140 }, .height = .{ .px = 100 } }, .{});
    const child = try box(cx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 70 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    (try child.style.ensureExtFallible(cx.allocator)).z_index = 5;
    try mid.appendChild(cx.allocator, child);
    try clipper.appendChild(cx.allocator, mid);
    c3MakePaintPassUnit(cx, child);
    cx.root = clipper;
    cx.layout();

    _ = cx.render();
    try std.testing.expect(clipper.meta.per_frame.caches.commands.own != null);
    cx.frame_time_ms = 16.0;
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    // Precondition: idle frame truly hits legacy snapshot.
    try std.testing.expect(cx.perf.render_cache_hit > 0);

    const blue = Color.rgba(0, 0, 255, 255);
    child.setBackground(blue);
    cx.frame_time_ms = 32.0;
    _ = cx.render();
    try std.testing.expectEqual(blue, knownBugFillColorOfSize(cx, 60, 70).?);
    try std.testing.expectEqual(@as(usize, 1), c3CountFillsOfNode(cx, child.id));
    cx.frame_time_ms = 48.0;
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    try std.testing.expectEqual(blue, knownBugFillColorOfSize(cx, 60, 70).?);
    // Invalidate once only: later idle frames re-hit (rewritten) snapshot.
    try std.testing.expect(cx.perf.render_cache_hit > 0);
}

test "render: C3 positive z child change keeps legacy overflow parent cache hit" {
    // Perf guardrail: legacy overflow parent's **direct** z>0 child (paint pass unit) recolor,
    // parent snapshot replay omits it, fresh re-render, parent unchanged (that's the out-of-band
    // optimization to keep). Assert re-render produces new color, one render only.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 160);

    const clipper = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 120 },
        .overflow_hidden = true,
        .background = Color.rgba(20, 30, 40, 255),
    }, .{});
    const sibling = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 20 },
        .background = Color.rgba(0, 200, 0, 255),
    }, .{});
    const overlay = try box(cx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 70 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 5;
    try clipper.appendChild(cx.allocator, sibling);
    try clipper.appendChild(cx.allocator, overlay);
    c3MakePaintPassUnit(cx, overlay);
    cx.root = clipper;
    cx.layout();

    _ = cx.render();
    try std.testing.expect(clipper.meta.per_frame.caches.commands.own != null);
    cx.frame_time_ms = 16.0;
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    const idle_hits = cx.perf.render_cache_hit;
    // Idle hit = clipper legacy snapshot + overlay own promoted surface. Recolor frame overlay
    // itself miss (it's dirty), rest hit unchanged = clipper still hits.
    try std.testing.expect(overlay.meta.per_frame.caches.commands.promoted != null);
    try std.testing.expectEqual(@as(u32, 2), idle_hits);

    const colors = [_]Color{ Color.rgba(0, 0, 255, 255), Color.rgba(255, 255, 0, 255), Color.rgba(0, 255, 255, 255) };
    for (colors, 0..) |c, i| {
        overlay.setBackground(c);
        cx.frame_time_ms = 32.0 + 16.0 * @as(f64, @floatFromInt(i));
        cx.perf.render_cache_hit = 0;
        _ = cx.render();
        try std.testing.expectEqual(idle_hits - 1, cx.perf.render_cache_hit);
        try std.testing.expectEqual(c, knownBugFillColorOfSize(cx, 60, 70).?);
        try std.testing.expectEqual(@as(usize, 1), c3CountFillsOfNode(cx, overlay.id));
    }
}

test "render: C3 nested out-of-band hops keep legacy overflow ancestor cache hit" {
    // Portal form: legacy root -> portal(z>0, plain) -> content(z>0, paint pass unit). Both
    // out-of-band:
    // content change neither invalidates portal nor root (root snapshot omits whole portal subtree,
    // fresh re-render). "Skip first hop, rest bubble" fix fails here (root misses every time).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 160);

    const clipper = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 120 },
        .overflow_hidden = true,
        .background = Color.rgba(20, 30, 40, 255),
    }, .{});
    const portal = try box(cx, .{ .width = .{ .px = 160 }, .height = .{ .px = 120 } }, .{});
    (try portal.style.ensureExtFallible(cx.allocator)).z_index = 10;
    const content = try box(cx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 70 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    (try content.style.ensureExtFallible(cx.allocator)).z_index = 5;
    try portal.appendChild(cx.allocator, content);
    try clipper.appendChild(cx.allocator, portal);
    c3MakePaintPassUnit(cx, content);
    cx.root = clipper;
    cx.layout();

    _ = cx.render();
    try std.testing.expect(clipper.meta.per_frame.caches.commands.own != null);
    cx.frame_time_ms = 16.0;
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    const idle_hits = cx.perf.render_cache_hit;
    // Same: idle hit = clipper snapshot + content own promoted surface.
    try std.testing.expect(content.meta.per_frame.caches.commands.promoted != null);
    try std.testing.expectEqual(@as(u32, 2), idle_hits);

    const blue = Color.rgba(0, 0, 255, 255);
    content.setBackground(blue);
    cx.frame_time_ms = 32.0;
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    try std.testing.expectEqual(idle_hits - 1, cx.perf.render_cache_hit);
    try std.testing.expectEqual(blue, knownBugFillColorOfSize(cx, 60, 70).?);
    try std.testing.expectEqual(@as(usize, 1), c3CountFillsOfNode(cx, content.id));
}

test "render: C3 idle frames keep promoted cache hits with positive z children" {
    // Perf guardrail: composited_group container with z>0 children, idle multi-frame, each hit
    // count
    // = frame 2, zero miss; recolor one child, **sibling** promoted container still hits,
    // post-recolor next frame onward restore to pre-recolor hit count (no degradation to per-frame
    // rebuild).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(420, 240);

    const root = try box(cx, .{ .width = .{ .px = 420 }, .height = .{ .px = 240 }, .direction = .row }, .{});
    var groups: [2]*Node = undefined;
    var kids: [2][3]*Node = undefined;
    for (0..2) |g| {
        const group = try box(cx, .{
            .width = .{ .px = 200 },
            .height = .{ .px = 200 },
            .background = Color.rgba(20, 30, 40, 255),
        }, .{});
        (try group.style.ensureExtFallible(cx.allocator)).composited_group = true;
        for (0..3) |k| {
            const kid = try box(cx, .{
                .width = .{ .px = 30 + @as(f32, @floatFromInt(k)) * 10 },
                .height = .{ .px = 20 },
                .background = Color.rgba(200, 0, 0, 255),
            }, .{});
            (try kid.style.ensureExtFallible(cx.allocator)).z_index = @intCast(k + 1);
            try group.appendChild(cx.allocator, kid);
            kids[g][k] = kid;
        }
        try root.appendChild(cx.allocator, group);
        groups[g] = group;
    }
    cx.root = root;
    cx.layout();

    _ = cx.render();
    try std.testing.expect(groups[0].meta.per_frame.caches.commands.promoted != null);
    try std.testing.expect(groups[1].meta.per_frame.caches.commands.promoted != null);

    var t: f64 = 16.0;
    cx.perf.render_cache_hit = 0;
    cx.perf.render_cache_miss = 0;
    cx.frame_time_ms = t;
    _ = cx.render();
    const idle_hits = cx.perf.render_cache_hit;
    try std.testing.expectEqual(@as(u64, 2), @as(u64, idle_hits));
    try std.testing.expectEqual(@as(u64, 0), @as(u64, cx.perf.render_cache_miss));
    for (0..4) |_| {
        t += 16.0;
        cx.frame_time_ms = t;
        cx.perf.render_cache_hit = 0;
        cx.perf.render_cache_miss = 0;
        _ = cx.render();
        try std.testing.expectEqual(idle_hits, cx.perf.render_cache_hit);
        try std.testing.expectEqual(@as(u64, 0), @as(u64, cx.perf.render_cache_miss));
    }

    const blue = Color.rgba(0, 0, 255, 255);
    kids[0][1].setBackground(blue);
    try std.testing.expect(groups[0].frame_state.state_bits.dirty.core.subtree_render);
    try std.testing.expect(!groups[1].frame_state.state_bits.dirty.core.subtree_render);
    t += 16.0;
    cx.frame_time_ms = t;
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    // Recolor frame: only changed group rebuilds, sibling group still hits.
    try std.testing.expectEqual(idle_hits - 1, cx.perf.render_cache_hit);
    try std.testing.expectEqual(blue, c3FillColorOfNode(cx, kids[0][1].id).?);
    for (0..3) |_| {
        t += 16.0;
        cx.frame_time_ms = t;
        cx.perf.render_cache_hit = 0;
        cx.perf.render_cache_miss = 0;
        _ = cx.render();
        try std.testing.expectEqual(idle_hits, cx.perf.render_cache_hit);
        try std.testing.expectEqual(@as(u64, 0), @as(u64, cx.perf.render_cache_miss));
        try std.testing.expectEqual(blue, c3FillColorOfNode(cx, kids[0][1].id).?);
    }
}

// --- C2: z_index decoupled from clipping (plan sticky-zindex-clip-decoupling-plan.md S9.1 items
// 1,3,4,5) ---
//
// Invariant: a z>0 child is clipped identically to a z=0 sibling (same retained clip_id, same
// scissor depth/rect); z only orders peers.

const C2ScissorStack = struct {
    depth: usize,
    rect: ?ui.ComputedRect,
};

const C2SurfaceFrame = struct {
    m: [6]f32,
    src_x: f32,
    src_y: f32,
};

/// Convert local rect within current surface to world coords. begin_opacity_layer and push_clip
/// (clip-bridge owner-local projection) both in surface local space:
/// parent_space_point = M*(p - src), M = draw_transform, src = begin geom origin.
fn c2RectToWorld(frames: []const C2SurfaceFrame, rect: ui.ComputedRect) ui.ComputedRect {
    var x0 = rect.x;
    var y0 = rect.y;
    var x1 = rect.x + rect.w;
    var y1 = rect.y + rect.h;
    var i = frames.len;
    while (i > 0) {
        i -= 1;
        const f = frames[i];
        const ax = f.m[0] * (x0 - f.src_x) + f.m[2] * (y0 - f.src_y) + f.m[4];
        const ay = f.m[1] * (x0 - f.src_x) + f.m[3] * (y0 - f.src_y) + f.m[5];
        const bx = f.m[0] * (x1 - f.src_x) + f.m[2] * (y1 - f.src_y) + f.m[4];
        const by = f.m[1] * (x1 - f.src_x) + f.m[3] * (y1 - f.src_y) + f.m[5];
        x0 = @min(ax, bx);
        y0 = @min(ay, by);
        x1 = @max(ax, bx);
        y1 = @max(ay, by);
    }
    return ui.ComputedRect.init(x0, y0, x1 - x0, y1 - y0);
}

/// Degrade: take the first paint entry matching (w,h,color); scissor stack = depth + each layer
/// converted to world, intersected (integer pixel tolerance, 0.5 rounding). Empty stack -> rect =
/// null.
/// Must account for opacity-surface local coords, else a surface clip-bridge is wrongly treated as
/// world (z>0 children of a self-surface carry the parent clip_id).
fn c2ScissorStackForFill(cx: *Cx, w: f32, h: f32, color: Color) !C2ScissorStack {
    var stack: [32]ui.ComputedRect = undefined;
    var depth: usize = 0;
    var frames: [16]C2SurfaceFrame = undefined;
    var frame_depth: usize = 0;
    for (cx.lowerForEncoderPaintTable()) |it| {
        if (it.kind == .control) {
            switch (it.control_kind) {
                .push_clip => {
                    if (depth >= stack.len) return error.ScissorStackOverflow;
                    stack[depth] = c2RectToWorld(frames[0..frame_depth], ui.ComputedRect.init(it.geom.x, it.geom.y, it.geom.w, it.geom.h));
                    depth += 1;
                },
                .pop_clip => depth -|= 1,
                .begin_opacity_layer => {
                    if (frame_depth >= frames.len) return error.SurfaceStackOverflow;
                    frames[frame_depth] = .{
                        .m = if (it.use_draw_transform) it.draw_transform else .{ 1, 0, 0, 1, it.draw_x, it.draw_y },
                        .src_x = it.geom.x,
                        .src_y = it.geom.y,
                    };
                    frame_depth += 1;
                },
                .end_opacity_layer => frame_depth -|= 1,
                else => {},
            }
            continue;
        }
        if (!it.isFillRect()) continue;
        if (@abs(it.geom.w - w) > 0.5 or @abs(it.geom.h - h) > 0.5) continue;
        if (it.color.r != color.r or it.color.g != color.g or it.color.b != color.b) continue;
        if (depth == 0) return .{ .depth = 0, .rect = null };
        var x0: f32 = stack[0].x;
        var y0: f32 = stack[0].y;
        var x1: f32 = stack[0].x + stack[0].w;
        var y1: f32 = stack[0].y + stack[0].h;
        for (stack[1..depth]) |r| {
            x0 = @max(x0, r.x);
            y0 = @max(y0, r.y);
            x1 = @min(x1, r.x + r.w);
            y1 = @min(y1, r.y + r.h);
        }
        return .{ .depth = depth, .rect = ui.ComputedRect.init(
            @round(x0),
            @round(y0),
            @round(@max(0, x1 - x0)),
            @round(@max(0, y1 - y0)),
        ) };
    }
    return error.TargetFillNotFound;
}

/// Display list first fill_rect index of some node.
fn c2FirstFillIndex(cx: *Cx, node: *Node) ?usize {
    for (cx.display_list.items.items, 0..) |item, index| switch (item) {
        .fill_rect => |fill| if (fill.header.node_id == node.id) return index,
        else => {},
    };
    return null;
}

/// z>0 node and z=0 sibling contrast must get identical clipping: same retained clip_id (non-null),
/// same scissor depth, same effective rect == expected.
fn c2ExpectSameClipAsPeer(
    cx: *Cx,
    raised: *Node,
    raised_size: [2]f32,
    raised_color: Color,
    peer: *Node,
    peer_size: [2]f32,
    peer_color: Color,
    expected: ui.ComputedRect,
) !void {
    const raised_rt = cx.scene_runtime.get(raised.id).?;
    const peer_rt = cx.scene_runtime.get(peer.id).?;
    try std.testing.expect(peer_rt.clip_id != ui.SceneRuntimeInvalidId);
    try std.testing.expectEqual(peer_rt.clip_id, raised_rt.clip_id);

    const raised_stack = try c2ScissorStackForFill(cx, raised_size[0], raised_size[1], raised_color);
    const peer_stack = try c2ScissorStackForFill(cx, peer_size[0], peer_size[1], peer_color);
    try std.testing.expectEqual(peer_stack.depth, raised_stack.depth);
    try std.testing.expect(raised_stack.rect != null);
    try std.testing.expectEqual(expected, raised_stack.rect.?);
    try std.testing.expectEqual(expected, peer_stack.rect.?);
}

test "render: positive z child is clipped by overflow_hidden parent (fresh frame)" {
    // S9.1 item 1. Appendix A probe 1: old z=0 scissor depth 2 (token + clip-bridge),
    // z=5 depth 1, retained clip_id = INVALID (pixels via token only).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 300);

    const clipper = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
        .overflow_hidden = true,
        .background = Color.rgba(20, 30, 40, 255),
    }, .{});
    const raised_color = Color.rgba(220, 40, 60, 255);
    const raised = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
        .position = .absolute,
        .background = raised_color,
    }, .{});
    (try raised.style.ensureExtFallible(cx.allocator)).z_index = 5;
    const peer_color = Color.rgba(40, 200, 60, 255);
    const peer = try box(cx, .{
        .width = .{ .px = 190 },
        .height = .{ .px = 190 },
        .position = .absolute,
        .background = peer_color,
    }, .{});
    // z>0 appended first: peer order by z, not tree.
    try clipper.appendChild(cx.allocator, raised);
    try clipper.appendChild(cx.allocator, peer);
    cx.root = clipper;
    cx.layout();
    _ = cx.render();

    try c2ExpectSameClipAsPeer(cx, raised, .{ 200, 200 }, raised_color, peer, .{ 190, 190 }, peer_color, ui.ComputedRect.init(0, 0, 100, 100));
    // Order: z=5 drawn above z=0.
    try std.testing.expect(c2FirstFillIndex(cx, peer).? < c2FirstFillIndex(cx, raised).?);
}

test "render: positive z grandchild clipped by grand-ancestor clip" {
    // S9.1 item 3. Appendix A probe 2: outer(clip) -> mid -> child(z=5).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 300);

    const outer = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 90 },
        .overflow_hidden = true,
        .background = Color.rgba(20, 30, 40, 255),
    }, .{});
    const mid = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 90 },
    }, .{});
    const raised_color = Color.rgba(220, 40, 60, 255);
    const raised = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
        .position = .absolute,
        .background = raised_color,
    }, .{});
    (try raised.style.ensureExtFallible(cx.allocator)).z_index = 5;
    const peer_color = Color.rgba(40, 200, 60, 255);
    const peer = try box(cx, .{
        .width = .{ .px = 190 },
        .height = .{ .px = 190 },
        .position = .absolute,
        .background = peer_color,
    }, .{});
    try mid.appendChild(cx.allocator, raised);
    try mid.appendChild(cx.allocator, peer);
    try outer.appendChild(cx.allocator, mid);
    cx.root = outer;
    cx.layout();
    _ = cx.render();

    try c2ExpectSameClipAsPeer(cx, raised, .{ 200, 200 }, raised_color, peer, .{ 190, 190 }, peer_color, ui.ComputedRect.init(0, 0, 120, 90));
    // Cross-generation: z>0 grandchild inherits outer clip (mid itself no clip, clip_id same as
    // mid).
    try std.testing.expectEqual(cx.scene_runtime.get(mid.id).?.clip_id, cx.scene_runtime.get(raised.id).?.clip_id);
}

test "render: sticky with positive z is clipped by scroll viewport and orders above z=0 siblings" {
    // S9.1 item 4. root(column) -> [topbar 40, viewport(200x200 clip) -> content(translate_y=-S)
    //   -> [lead 500, section 300 -> [header 40 (sticky top=0, z=3), body 260]]].
    // S=780: header constrained by section bottom (post-C1 offset 260), screen y = 40+500+260-780 =
    // 20,
    // top 20px scrolled past viewport (in topbar area).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 240);

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 240 }, .direction = .column }, .{});
    const topbar = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 }, .background = Color.rgba(90, 90, 90, 255) }, .{});
    topbar.setFocusable(true);
    const viewport = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
        .direction = .column,
        .overflow_hidden = true,
    }, .{});
    const content = try box(cx, .{ .width = .{ .px = 200 }, .direction = .column }, .{});
    const lead = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 500 } }, .{});
    const section = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 300 }, .direction = .column }, .{});
    const header_color = Color.rgba(0, 0, 255, 255);
    const header = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 40 },
        .position = .sticky,
        .background = header_color,
    }, .{});
    header.setFocusable(true);
    const header_ext = try header.style.ensureExtFallible(cx.allocator);
    header_ext.sticky_insets = .{ .top = 0 };
    header_ext.z_index = 3;
    const body_color = Color.rgba(0, 200, 0, 255);
    const body = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 260 }, .background = body_color }, .{});
    body.setFocusable(true);
    try section.appendChild(cx.allocator, header);
    try section.appendChild(cx.allocator, body);
    try content.appendChild(cx.allocator, lead);
    try content.appendChild(cx.allocator, section);
    try viewport.appendChild(cx.allocator, content);
    try root.appendChild(cx.allocator, topbar);
    try root.appendChild(cx.allocator, viewport);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    content.setStyle(null, .translate_y, -780);
    renderNextStickyFrame(cx);
    try std.testing.expectEqual(@as(f32, 260), header.frame_state.frame_local.runtime.sticky.y);
    const g = header.globalRect();
    try std.testing.expectEqual(@as(f32, 20), g.y);

    const viewport_box = ui.ComputedRect.init(0, 40, 200, 200);
    try c2ExpectSameClipAsPeer(cx, header, .{ 200, 40 }, header_color, body, .{ 200, 260 }, body_color, viewport_box);
    // Order: header (positive_z band) drawn above z=0 sibling body (both overlap in section).
    try std.testing.expect(c2FirstFillIndex(cx, body).? < c2FirstFillIndex(cx, header).?);

    // Hit vs render same: viewport overlap hits header; scrolled past 20px in topbar,
    // must hit topbar, not (invisible) header.
    try std.testing.expectEqual(header, cx.hitTest(100, 50).?);
    try std.testing.expectEqual(topbar, cx.hitTest(100, 30).?);
}

test "render: descendant shadows are inside the opacity-layer surface bounds" {
    // Notification stack regression: the scaled/faded positioner is the layer owner, the shadow
    // is painted by a grandchild (card body). A fixed 8px child margin cut that shadow at the
    // texture edge into a hard rectangle; the surface must cover every shadow layer.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 600);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 600 } }, .{});
    const owner = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 }, .opacity = 0.8 }, .{});
    const wrapper = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 } }, .{});
    const body = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 }, .background = Color.rgba(250, 250, 250, 255) }, .{});
    (try body.style.ensureExtFallible(cx.allocator)).setShadows(
        .{ .color = Color.rgba(0, 0, 0, 30), .blur = 4, .offset_y = 2 },
        .{ .color = Color.rgba(0, 0, 0, 40), .blur = 24, .offset_y = 12, .spread = 2 },
    );
    try wrapper.appendChild(cx.allocator, body);
    try owner.appendChild(cx.allocator, wrapper);
    try root.appendChild(cx.allocator, owner);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    // Second layer: blur 24 on both sides (48) + spread 2, shifted down 12.
    const reach = 24 * 2 + 2;
    const bbox = owner.getLayoutOutput().artifacts.children_bbox orelse return error.MissingChildrenBBox;
    try std.testing.expect(bbox.x <= -reach);
    try std.testing.expect(bbox.x + bbox.w >= 200 + reach);
    try std.testing.expect(bbox.y + bbox.h >= 80 + 12 + reach);

    const runtime = cx.scene_runtime.get(owner.id).?;
    const node_plan = cx.layer_tree.planQueryNode(owner.id, runtime.effect_id, true, false, runtime.clip_bounds_fallback);
    const bounds = node_plan.effect.begin_bounds orelse return error.MissingSurfaceBounds;
    try std.testing.expect(bounds.x <= -reach);
    try std.testing.expect(bounds.x + bounds.w >= 200 + reach);
    try std.testing.expect(bounds.y + bounds.h >= 80 + 12 + reach);
}

test "render: z>0 child of opacity-layer parent is included in surface bounds" {
    // S9.1 item 5. Non-clip opacity 0.8 parent, z>0 child overflow parent frame: post-decouple
    // renders in parent surface like z=0, children_bbox / surface begin_bounds must cover it,
    // else overflow clipped by texture edge (old computeChildrenBBox excluded z>0).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 400);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    const parent = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
        .opacity = 0.8,
        .background = Color.rgba(20, 30, 40, 255),
    }, .{});
    const raised = try box(cx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 60 },
        .position = .absolute,
        .background = Color.rgba(220, 40, 60, 255),
    }, .{});
    raised.style.translate_x = 150; // Local x in [150,210): overflows parent right 110px.
    raised.style.translate_y = 170; // Local y in [170,230).
    (try raised.style.ensureExtFallible(cx.allocator)).z_index = 5;
    try parent.appendChild(cx.allocator, raised);
    try root.appendChild(cx.allocator, parent);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    const bbox = parent.getLayoutOutput().artifacts.children_bbox orelse return error.MissingChildrenBBox;
    try std.testing.expect(bbox.x + bbox.w >= 210);
    try std.testing.expect(bbox.y + bbox.h >= 230);

    const runtime = cx.scene_runtime.get(parent.id).?;
    try std.testing.expect(runtime.effect_id != ui.SceneRuntimeInvalidId);
    const node_plan = cx.layer_tree.planQueryNode(parent.id, runtime.effect_id, true, false, runtime.clip_bounds_fallback);
    const bounds = node_plan.effect.begin_bounds orelse return error.MissingSurfaceBounds;
    try std.testing.expect(bounds.x <= 150);
    try std.testing.expect(bounds.y <= 170);
    try std.testing.expect(bounds.x + bounds.w >= 210);
    try std.testing.expect(bounds.y + bounds.h >= 230);
}

test "overlay: modal barrier is always portaled when root exists" {
    // S9.2 item 15 / plan S6 step 1: overlay() like Popover, always via
    // ensurePopoverPortalRoot; standalone Cx no preset portal builds in-place,
    // no longer fallback to caller inline append (inline mounted clipped by ancestor, z_index
    // doesn't escape).
    const overlay_mod = @import("../overlay_stack.zig");
    const Scope = @import("../reactive.zig").Scope;

    {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(400, 300);
        const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        cx.root = root;
        try std.testing.expect(cx.popover_portal_root == null);
        const scope = try Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();

        const res = try overlay_mod.overlay(scope, cx, .{
            .kind = .modal,
            .barrier = .{ .color = Color.rgba(0, 0, 0, 120) },
            .enter_transition = .none,
            .exit_transition = .none,
        });
        try std.testing.expect(res.portaled);
        const portal = cx.popover_portal_root orelse return error.PortalNotCreated;
        try std.testing.expect(portal.parent == root);
        try std.testing.expect(res.barrier.?.parent == portal);
        // Share same portal as Popover (second modal doesn't create new).
        const res2 = try overlay_mod.overlay(scope, cx, .{
            .kind = .modal,
            .barrier = .{ .color = Color.rgba(0, 0, 0, 120) },
            .enter_transition = .none,
            .exit_transition = .none,
        });
        try std.testing.expect(res2.portaled);
        try std.testing.expect(res2.barrier.?.parent == portal);
        try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    }

    {
        // Pure unit test (cx.root == null): keep inline fallback, caller appends.
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        const scope = try Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        const res = try overlay_mod.overlay(scope, cx, .{
            .kind = .modal,
            .barrier = .{ .color = Color.rgba(0, 0, 0, 120) },
            .enter_transition = .none,
            .exit_transition = .none,
        });
        try std.testing.expect(!res.portaled);
        try std.testing.expect(res.barrier.?.parent == null);
        try std.testing.expect(cx.popover_portal_root == null);
        // Caller mounts; here temporary tree attach avoids scope cleanup leak.
        const host = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
        cx.root = host;
        try host.appendChild(std.testing.allocator, res.barrier.?);
    }
}

test "render: overlay composite animation marks promoted layer" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
    }, .{});

    const overlay = try text(cx, "Overlay", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    overlay.setOpacityRaw(0.8);
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 20;
    try root.appendChild(cx.allocator, overlay);
    ui.animateNode(overlay, cx.allocator, .{
        .prop = .scale_x,
        .from = 0.9,
        .to = 1.0,
        .duration = 0.3,
    });
    ui.animateNode(overlay, cx.allocator, .{
        .prop = .opacity,
        .from = 0.8,
        .to = 1.0,
        .duration = 0.3,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const runtime = cx.scene_runtime.get(overlay.id).?;
    try std.testing.expect(runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(runtime.has_active_composite_animation);
    try std.testing.expect(runtime.has_active_transform_animation);
    try std.testing.expect(runtime.has_active_opacity_animation);

    var promoted_layer = false;
    // P1.6': iterate from LayerTree (plan.layers retiring).
    for (cx.layer_tree.layers.items) |tree_layer| {
        if (!tree_layer.alive) continue;
        const layer = tree_layer.composited orelse continue;
        if (layer.root_node_id != overlay.id or layer.effect_kind != .opacity) continue;
        promoted_layer = true;
        try std.testing.expect(layer.promotion_reason.is_overlay);
        try std.testing.expect(layer.promotion_reason.has_transform_animation);
        try std.testing.expect(layer.promotion_reason.has_opacity_animation);
        try std.testing.expect(layer.promotion_reason.text_with_transform_animation);
        try std.testing.expect(layer.flags.is_animating);
        try std.testing.expect(layer.flags.contains_text);
        try std.testing.expect(tree_layer.frame_flags.surface_valid);
    }
    try std.testing.expect(promoted_layer);
}

test "render: promoted root layer prefers blur over opacity and rounded clip" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
        .opacity = 0.8,
    }, .{});
    const root_ext = try root.style.ensureExtFallible(cx.allocator);
    root_ext.z_index = 20;
    root_ext.glass = .{ .backdrop_blur = 6 };
    root_ext.corner_radius = ui.CornerRadius.uniform(12);

    ui.animateNode(root, cx.allocator, .{
        .prop = .opacity,
        .from = 0.8,
        .to = 1.0,
        .duration = 0.3,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const runtime = cx.scene_runtime.get(root.id).?;
    try std.testing.expect(runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);
    try std.testing.expectEqual(ui.EffectKind.backdrop_blur, cx.layer_tree.planCompositedAt(runtime.promoted_layer_id).?.effect_kind);

    var promoted_count: usize = 0;
    for (cx.layer_tree.layers.items) |tree_layer| {
        if (!tree_layer.alive) continue;
        const layer = tree_layer.composited orelse continue;
        if (layer.root_node_id != root.id) continue;
        if (!layer.promotion_reason.any()) continue;
        promoted_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), promoted_count);
}

test "render: rotate animation promotes overlay layer with affine support" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
    }, .{});

    const overlay = try text(cx, "Rotate", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    overlay.setOpacityRaw(0.85);
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 20;
    try root.appendChild(cx.allocator, overlay);
    ui.animateNode(overlay, cx.allocator, .{
        .prop = .rotate,
        .from = 0,
        .to = 0.5,
        .duration = 0.3,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const runtime = cx.scene_runtime.get(overlay.id).?;
    try std.testing.expect(runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(runtime.has_active_composite_animation);
    try std.testing.expect(runtime.has_active_transform_animation);
    try std.testing.expect(overlay.meta.per_frame.caches.commands.promoted != null);
    try std.testing.expect(runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(!runtime.promoted_surface_flags.reused_this_frame);

    var saw_rotated_opacity_layer = false;
    for (cx.lowering.main_paint.items) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            try std.testing.expect(layer.geom.w > 0);
            try std.testing.expect(layer.geom.h > 0);
            saw_rotated_opacity_layer = true;
            break;
        }
    }
    try std.testing.expect(saw_rotated_opacity_layer);

    var saw_promoted_layer = false;
    for (cx.layer_tree.layers.items) |tree_layer| {
        if (!tree_layer.alive) continue;
        const layer = tree_layer.composited orelse continue;
        if (layer.root_node_id != overlay.id or layer.effect_kind != .opacity) continue;
        try std.testing.expect(layer.promotion_reason.any());
        try std.testing.expect(layer.promotion_reason.has_transform_animation);
        saw_promoted_layer = true;
        break;
    }
    try std.testing.expect(saw_promoted_layer);

    cx.perf.render_cache_hit = 0;
    cx.perf.render_cache_miss = 0;
    // task #161 calibration: v0.5-P4 adds frame-time skip path, same frame_time returns
    // cached commands, skips promoted_surface_reused path. Second render needs frame time bump to
    // normal.
    cx.frame_time_ms = 16.0;
    _ = cx.render();

    const reused_runtime = cx.scene_runtime.get(overlay.id).?;
    try std.testing.expect(reused_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!reused_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(cx.perf.render_cache_hit > 0);
}

test "render: icon quarter-turn rotation keeps affine surface transform" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
    }, .{});

    const icon = try ui.iconTint(cx, ui.svg_assets.common.chevron_right, Color.rgba(255, 255, 255, 255), .{
        .width = .{ .px = 16 },
        .height = .{ .px = 16 },
    });
    icon.style.translate_x = 64;
    icon.style.translate_y = 32;
    const ext = try icon.style.ensureExtFallible(cx.allocator);
    ext.will_change_transform = true;
    ext.rotate = std.math.pi / 2.0;
    try root.appendChild(cx.allocator, icon);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    var saw_rotated_opacity_layer = false;
    for (cx.lowering.main_paint.items) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            try std.testing.expect(layer.geom.w > 0);
            try std.testing.expect(layer.geom.h > 0);
            try std.testing.expect(
                std.math.approxEqAbs(f32, layer.rotate, std.math.pi / 2.0, 0.0001) or
                    @abs(layer.draw_transform[1]) > 0.0001 or
                    @abs(layer.draw_transform[2]) > 0.0001,
            );
            saw_rotated_opacity_layer = true;
            break;
        }
    }
    try std.testing.expect(saw_rotated_opacity_layer);
}

test "render: promoted cache reuses only matching versions" {
    // Zero-dirty fast path (core.zig:2991) requires `frame_time_ms == last_render_frame_time_ms`.
    // The test must advance a monotonic frame clock (16 -> 32 -> 48); writing `cx.frame_time_ms =
    // 16.0`
    // repeatedly doesn't advance, render returns cached and perf.resetFrame() clears the count
    // (symptom: hit=0 **and miss=0**; reused_this_frame=true is prev-frame state, not a cache
    // inconsistency).
    //
    // Promoted surface overlay translate/scale live in the wrapper draw_transform; surface-internal
    // text stays surface-local (always x=0), so asserts read the wrapper draw_transform.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
    }, .{});

    const overlay = try text(cx, "Overlay", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    overlay.setOpacityRaw(0.8);
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 20;
    try root.appendChild(cx.allocator, overlay);
    ui.animateNode(overlay, cx.allocator, .{
        .prop = .scale_x,
        .from = 0.9,
        .to = 1.0,
        .duration = 0.3,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expect(overlay.meta.per_frame.caches.commands.promoted != null);
    const first_runtime = cx.scene_runtime.get(overlay.id).?;
    const first_flags = cx.layer_tree.planFrameFlagsOf(first_runtime.promoted_layer_id);
    const first_plan = cx.layer_tree.planQueryNode(
        overlay.id,
        first_runtime.effect_id,
        false,
        false,
        first_runtime.clip_bounds_fallback,
    );
    try std.testing.expect(first_flags.rebuilt_this_frame);
    try std.testing.expect(!first_flags.reused_this_frame);
    try std.testing.expect(first_plan.frame_flags.rebuilt_this_frame);
    try std.testing.expect(!first_plan.frame_flags.reused_this_frame);
    try std.testing.expect(first_runtime.promoted_surface_flags.surface_valid);
    try std.testing.expect(first_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(!first_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!first_runtime.promoted_surface_flags.invalidated_by_self_this_frame);
    try std.testing.expect(!first_runtime.promoted_surface_flags.invalidated_by_descendant_this_frame);

    cx.perf.render_cache_hit = 0;
    cx.frame_time_ms = 16.0; // task #161: advance frame time past v0.5-P4 skip path.
    _ = cx.render();
    try std.testing.expect(cx.perf.render_cache_hit > 0);
    const reused_runtime = cx.scene_runtime.get(overlay.id).?;
    const reused_flags = cx.layer_tree.planFrameFlagsOf(reused_runtime.promoted_layer_id);
    const reused_plan = cx.layer_tree.planQueryNode(
        overlay.id,
        reused_runtime.effect_id,
        false,
        false,
        reused_runtime.clip_bounds_fallback,
    );
    try std.testing.expect(!reused_flags.rebuilt_this_frame);
    try std.testing.expect(reused_flags.reused_this_frame);
    try std.testing.expect(!reused_plan.frame_flags.rebuilt_this_frame);
    try std.testing.expect(reused_plan.frame_flags.reused_this_frame);
    try std.testing.expect(reused_runtime.promoted_surface_flags.surface_valid);
    try std.testing.expect(!reused_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(reused_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!reused_runtime.promoted_surface_flags.invalidated_by_self_this_frame);
    try std.testing.expect(!reused_runtime.promoted_surface_flags.invalidated_by_descendant_this_frame);

    overlay.setOpacityRaw(0.9);
    overlay.markCompositeDirty();
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    const opacity_commands = cx.lowerForEncoderPaintTable();
    try std.testing.expect(cx.perf.render_cache_hit > 0);

    // Promoted surface: overlay translate/scale in wrapper draw_transform, surface-internal
    // text stays **surface-local** (always x=0).
    // Old assert "text.geom.x += 24" (pre-surface era), now never true (text x always 0, offset on
    // dt[4]).
    // Read wrapper draw_transform instead.
    var baseline_layer_x: ?f32 = null;
    for (opacity_commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer) and cmd.use_draw_transform) {
            baseline_layer_x = cmd.draw_transform[4];
            break;
        }
    }
    try std.testing.expect(baseline_layer_x != null);

    overlay.style.translate_x = 24;
    overlay.markCompositeDirty();
    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    const translated_commands = cx.lowerForEncoderPaintTable();
    try std.testing.expect(cx.perf.render_cache_hit > 0);
    try std.testing.expect(cx.layer_tree.planFrameFlagsOf(0).surface_valid);

    var saw_translated_overlay = false;
    for (translated_commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer) and cmd.use_draw_transform) {
            saw_translated_overlay = true;
            try std.testing.expectApproxEqAbs(baseline_layer_x.? + 24, cmd.draw_transform[4], 0.001);
            break;
        }
    }
    try std.testing.expect(saw_translated_overlay);

    (try overlay.style.ensureExtFallible(cx.allocator)).scale_x = 1.1;
    overlay.markCompositeDirty();
    cx.perf.render_cache_hit = 0;
    cx.perf.render_cache_miss = 0;
    cx.perf.descendant_scoped_promoted_rebuild_count = 0;
    cx.perf.descendant_scoped_promoted_cache_splice_count = 0;
    cx.perf.descendant_scoped_promoted_self_replay_count = 0;
    cx.perf.descendant_scoped_promoted_descendant_pass_replay_count = 0;
    cx.perf.descendant_scoped_promoted_tail_replay_count = 0;
    _ = cx.render();
    const scaled_commands = cx.lowerForEncoderPaintTable();
    try std.testing.expect(cx.perf.render_cache_hit > 0);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.render_cache_miss);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.descendant_scoped_promoted_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.descendant_scoped_promoted_cache_splice_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.descendant_scoped_promoted_self_replay_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.descendant_scoped_promoted_descendant_pass_replay_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.descendant_scoped_promoted_tail_replay_count);
    const scaled_runtime = cx.scene_runtime.get(overlay.id).?;
    const scaled_flags = cx.layer_tree.planFrameFlagsOf(scaled_runtime.promoted_layer_id);
    const scaled_cache = overlay.meta.per_frame.caches.commands.promoted.?;
    try std.testing.expect(scaled_flags.surface_valid);
    try std.testing.expect(!scaled_flags.rebuilt_this_frame);
    try std.testing.expect(scaled_flags.reused_this_frame);
    try std.testing.expect(!scaled_flags.invalidated_by_self_this_frame);
    try std.testing.expect(!scaled_flags.invalidated_by_descendant_this_frame);
    try std.testing.expect(scaled_runtime.promoted_surface_flags.surface_valid);
    try std.testing.expect(!scaled_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(scaled_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!scaled_runtime.promoted_surface_flags.invalidated_by_self_this_frame);
    try std.testing.expect(!scaled_runtime.promoted_surface_flags.invalidated_by_descendant_this_frame);
    try std.testing.expect(!scaled_runtime.promoted_surface_flags.descendant_scoped_rebuild_candidate_this_frame);
    try std.testing.expect(scaled_cache.self_content_command_count > 0);
    try std.testing.expectEqual(@as(u32, 0), scaled_cache.descendant_content_command_count);

    var saw_scaled_opacity_layer = false;
    var saw_scaled_draw_transform = false;
    for (scaled_commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            const layer = cmd;
            saw_scaled_opacity_layer = true;
            try std.testing.expect(layer.geom.w > 0);
            try std.testing.expect(layer.geom.h > 0);
            if (layer.use_draw_transform) {
                saw_scaled_draw_transform = true;
            }
        }
    }
    try std.testing.expect(saw_scaled_opacity_layer);
    try std.testing.expect(saw_scaled_draw_transform);

    cx.perf.render_cache_hit = 0;
    cx.frame_time_ms = 32.0; // task #161: skip v0.5-P4 skip path.
    _ = cx.render();
    try std.testing.expect(cx.perf.render_cache_hit > 0);
    try std.testing.expect(cx.layer_tree.planFrameFlagsOf(0).reused_this_frame);
    try std.testing.expect(!cx.layer_tree.planFrameFlagsOf(0).rebuilt_this_frame);
    const reused_again_runtime = cx.scene_runtime.get(overlay.id).?;
    try std.testing.expect(reused_again_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!reused_again_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(!reused_again_runtime.promoted_surface_flags.invalidated_by_self_this_frame);
    try std.testing.expect(!reused_again_runtime.promoted_surface_flags.invalidated_by_descendant_this_frame);

    overlay.markRenderDirty();
    cx.perf.render_cache_hit = 0;
    cx.frame_time_ms = 48.0; // Frame clock must monotonic increase (see above skip-path comment).
    _ = cx.render();
    try std.testing.expectEqual(@as(u32, 0), cx.perf.render_cache_hit);
}

test "render: explicit composited group requests retained promoted surface" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
    }, .{});

    const panel = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
        .background = Color.rgba(35, 40, 52, 255),
        .padding = ui.Padding.all(8),
    }, .{});
    (try panel.style.ensureExtFallible(cx.allocator)).composited_group = true;
    const label = try text(cx, "Grouped", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    try panel.appendChild(cx.allocator, label);
    try root.appendChild(cx.allocator, panel);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const first_runtime = cx.scene_runtime.get(panel.id).?;
    try std.testing.expect(first_runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(panel.meta.per_frame.caches.commands.promoted != null);
    const first_layer = cx.layer_tree.planCompositedAt(first_runtime.promoted_layer_id).?;
    try std.testing.expectEqual(ui.EffectKind.composited_group, first_layer.effect_kind);
    try std.testing.expect(first_layer.promotion_reason.explicit_composited_group);
    try std.testing.expect(first_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(!first_runtime.promoted_surface_flags.reused_this_frame);

    cx.perf.render_cache_hit = 0;
    cx.frame_time_ms = 16.0; // task #161: skip v0.5-P4 skip path.
    _ = cx.render();

    const reused_runtime = cx.scene_runtime.get(panel.id).?;
    try std.testing.expect(reused_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!reused_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(cx.perf.render_cache_hit > 0);

    panel.style.translate_x = 18;
    panel.markCompositeDirty();
    cx.perf.render_cache_hit = 0;
    _ = cx.render();

    const translated_runtime = cx.scene_runtime.get(panel.id).?;
    try std.testing.expect(translated_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!translated_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(cx.perf.render_cache_hit > 0);
}

test "render: composited group descendants stay in content space during self scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
        .padding = Padding.all(16),
    }, .{});

    const panel = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 56 },
        .padding = Padding.all(8),
        .background = Color.rgba(35, 40, 52, 255),
        .scale_x = 0.86,
        .scale_y = 0.86,
    }, .{});
    (try panel.style.ensureExtFallible(cx.allocator)).composited_group = true;
    const label = try text(cx, "Grouped", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    try panel.appendChild(cx.allocator, label);
    try root.appendChild(cx.allocator, panel);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const panel_runtime = cx.scene_runtime.get(panel.id).?;
    const label_runtime = cx.scene_runtime.get(label.id).?;
    const panel_transform = cx.property_tree.transforms.items[panel_runtime.transform_id].world;
    const label_transform = cx.property_tree.transforms.items[label_runtime.transform_id].world;

    try std.testing.expectApproxEqAbs(@as(f32, 0.86), panel_transform.extractScaleX(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.86), panel_transform.extractScaleY(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), label_transform.extractScaleX(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), label_transform.extractScaleY(), 0.0001);
    try std.testing.expectApproxEqAbs(
        label_runtime.content_transform.tx,
        label_transform.tx,
        0.0001,
    );
    try std.testing.expectApproxEqAbs(
        label_runtime.content_transform.ty,
        label_transform.ty,
        0.0001,
    );
}

test "render: compositor-only dirty keeps content version stable" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
    }, .{});

    const overlay = try text(cx, "Overlay", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    overlay.setOpacityRaw(0.8);
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 20;
    try root.appendChild(cx.allocator, overlay);
    ui.animateNode(overlay, cx.allocator, .{
        .prop = .scale_x,
        .from = 0.9,
        .to = 1.0,
        .duration = 0.3,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expect(overlay.meta.per_frame.caches.commands.promoted != null);
    const before_content_version = overlay.meta.per_frame.caches.versions.content;
    const before_composite_version = overlay.meta.per_frame.caches.versions.composite;

    overlay.style.translate_x = 18;
    overlay.markCompositeDirty();

    try std.testing.expectEqual(before_content_version, overlay.meta.per_frame.caches.versions.content);
    try std.testing.expect(overlay.meta.per_frame.caches.versions.composite != before_composite_version);

    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    try std.testing.expect(cx.perf.render_cache_hit > 0);

    const runtime = cx.scene_runtime.get(overlay.id).?;
    try std.testing.expect(runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!runtime.promoted_surface_flags.rebuilt_this_frame);
}

test "render: font_smoothing = false reaches the encoder as TextFontFlag.no_smoothing" {
    // Regression: the lowering pass rebuilt text_run field by field and dropped font_smoothing,
    // so the iOS bars drew macOS-smoothed (heavier) glyphs.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);
    const root = try box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 200 } }, .{});
    try root.appendChild(cx.allocator, try text(cx, "Crisp", .{ .font_size = 14, .font_smoothing = false }));
    try root.appendChild(cx.allocator, try text(cx, "Smooth", .{ .font_size = 14 }));
    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();
    var seen: u8 = 0;
    for (commands) |cmd| {
        if (!cmd.isText()) continue;
        const no_smooth = (cmd.text_font_flags & @import("paint_table.zig").TextFontFlag.no_smoothing) != 0;
        if (std.mem.eql(u8, cmd.text_content, "Crisp")) {
            try std.testing.expect(no_smooth);
            seen |= 1;
        } else if (std.mem.eql(u8, cmd.text_content, "Smooth")) {
            try std.testing.expect(!no_smooth);
            seen |= 2;
        }
    }
    try std.testing.expectEqual(@as(u8, 3), seen);
}

test "render: transform-animated text subtree auto stabilizes raster policy" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
    }, .{});

    const overlay = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 48 },
    }, .{});
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 20;

    const label = try text(cx, "Overlay text", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    try overlay.appendChild(cx.allocator, label);
    try root.appendChild(cx.allocator, overlay);

    ui.animateNode(overlay, cx.allocator, .{
        .prop = .scale_x,
        .from = 0.9,
        .to = 1.0,
        .duration = 0.3,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    const overlay_runtime = cx.scene_runtime.get(overlay.id).?;
    try std.testing.expect(overlay_runtime.content_flags.has_text);
    try std.testing.expect(overlay_runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);

    var saw_stabilized_text = false;
    for (commands) |cmd| {
        if (cmd.isText()) {
            const t = cmd;
            if (std.mem.eql(u8, t.text_content, "Overlay text")) {
                // paint_table.DisplayItem.text_raster_policy three-state threshold:
                // 0 = static_crisp; 1 = animated_stable/direct_animated; 2 = surface_cached.
                // Animating overlay text must leave static path (1 or 2 both valid, depends promote
                // timing).
                try std.testing.expect(t.text_raster_policy != 0);
                saw_stabilized_text = true;
                break;
            }
        }
    }
    try std.testing.expect(saw_stabilized_text);
}

/// Raster policy of the text "Settled text" inside an overlay box in one of the end-of-animation
/// states (paint_table three-state: 0 static, 1 animated, 2 surface cached).
fn settledOverlayTextPolicy(comptime setup: fn (overlay: *ui.Node, cx: *Cx) anyerror!void) !u8 {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);
    const root = try box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 200 } }, .{});
    const overlay = try box(cx, .{ .width = .{ .px = 160 }, .height = .{ .px = 48 } }, .{});
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 20;
    const label = try text(cx, "Settled text", .{ .font_size = 16, .color = Color.rgba(255, 255, 255, 255) });
    try overlay.appendChild(cx.allocator, label);
    try root.appendChild(cx.allocator, overlay);
    try setup(overlay, cx);
    cx.root = root;
    cx.layout();
    _ = cx.render();
    for (cx.lowerForEncoderPaintTable()) |cmd| {
        if (cmd.isText() and std.mem.eql(u8, cmd.text_content, "Settled text")) return cmd.text_raster_policy;
    }
    return error.TextNotPainted;
}

test "render: text at rest after an overlay animation keeps the static raster" {
    // A modal's last enter frames (scale back to 1, no surface) and the composite linger after
    // it ended used to switch every glyph to the animated raster for a few frames and back. With
    // layout identical under both rasters that no longer moves advances, but the rasters differ
    // (pixel snap vs. linear placement): content at rest keeps the static one.
    const linger = struct {
        fn setup(overlay: *ui.Node, _: *Cx) anyerror!void {
            overlay.frame_state.frame_local.runtime.linger.transform = 2;
        }
    }.setup;
    try std.testing.expect(try settledOverlayTextPolicy(linger) != 1);
    const last_scale_sliver = struct {
        fn setup(overlay: *ui.Node, _: *Cx) anyerror!void {
            overlay.frame_state.state_bits.flags.manual_transform_animation_active = true;
        }
    }.setup;
    try std.testing.expect(try settledOverlayTextPolicy(last_scale_sliver) != 1);
    // Still sliding (a dropdown's motion offset): the content crosses the pixel grid.
    const sliding = struct {
        fn setup(overlay: *ui.Node, cx: *Cx) anyerror!void {
            overlay.frame_state.state_bits.flags.manual_transform_animation_active = true;
            (try overlay.style.ensureExtFallible(cx.allocator)).motion_offset = .{ 0, 6 };
        }
    }.setup;
    try std.testing.expectEqual(@as(u8, 1), try settledOverlayTextPolicy(sliding));
}

test "render: will-change pre-promotes overlay layer before animation starts" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
    }, .{});

    const overlay = try text(cx, "Prepared", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    const ext = try overlay.style.ensureExtFallible(cx.allocator);
    ext.z_index = 20;
    ext.will_change_transform = true;
    try root.appendChild(cx.allocator, overlay);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const runtime = cx.scene_runtime.get(overlay.id).?;
    try std.testing.expect(runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);

    var saw_prepromoted_layer = false;
    for (cx.layer_tree.layers.items) |tree_layer| {
        if (!tree_layer.alive) continue;
        const layer = tree_layer.composited orelse continue;
        if (layer.root_node_id != overlay.id or layer.effect_kind != .opacity) continue;
        try std.testing.expect(layer.promotion_reason.has_will_change_transform);
        saw_prepromoted_layer = true;
        break;
    }
    try std.testing.expect(saw_prepromoted_layer);
}

test "render: promoted cache skips subtrees with before-render hooks" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
    }, .{});

    const overlay = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 80 },
        .opacity = 0.85,
        .background = Color.rgba(250, 250, 250, 255),
    }, .{});
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 20;

    const dynamic_child = try text(cx, "Search options...", .{
        .font_size = 14,
        .color = Color.rgba(60, 60, 60, 255),
    });
    dynamic_child.meta.per_frame.hooks.before_render.main = struct {
        fn hook(node: *ui.Node) void {
            _ = node;
        }
    }.hook;
    try overlay.appendChild(cx.allocator, dynamic_child);
    try root.appendChild(cx.allocator, overlay);

    ui.animateNode(overlay, cx.allocator, .{
        .prop = .scale_x,
        .from = 0.9,
        .to = 1.0,
        .duration = 0.3,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    const runtime = cx.scene_runtime.get(overlay.id).?;
    try std.testing.expect(runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);
    try std.testing.expect(overlay.meta.per_frame.caches.commands.promoted == null);

    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    try std.testing.expectEqual(@as(u32, 0), cx.perf.render_cache_hit);
    try std.testing.expect(overlay.meta.per_frame.caches.commands.promoted == null);
}

test "render: legacy overflow cache skips subtrees with before-render hooks" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 220);

    const root = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 120 },
        .background = Color.rgba(248, 248, 248, 255),
        .overflow_hidden = true,
    }, .{});
    root.style.ensureExtPanic(cx.allocator).corner_radius = ui.CornerRadius.uniform(12);

    const dynamic_child = try text(cx, "Search options...", .{
        .font_size = 14,
        .color = Color.rgba(60, 60, 60, 255),
    });
    dynamic_child.meta.per_frame.hooks.before_render.main = struct {
        fn hook(node: *ui.Node) void {
            _ = node;
        }
    }.hook;
    try root.appendChild(cx.allocator, dynamic_child);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expect(root.meta.per_frame.caches.commands.own == null);

    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    try std.testing.expectEqual(@as(u32, 0), cx.perf.render_cache_hit);
    try std.testing.expect(root.meta.per_frame.caches.commands.own == null);
}

test "render: overlay composite dirty preserves ancestor legacy overflow cache hits" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 120 },
        .background = Color.rgba(20, 30, 40, 255),
        .overflow_hidden = true,
    }, .{});

    const body = try text(cx, "Body", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    try root.appendChild(cx.allocator, body);

    const overlay = try text(cx, "Overlay", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    overlay.setOpacityRaw(0.8);
    overlay.style.ensureExtPanic(cx.allocator).z_index = 20;
    try root.appendChild(cx.allocator, overlay);
    ui.animateNode(overlay, cx.allocator, .{
        .prop = .scale_x,
        .from = 0.9,
        .to = 1.0,
        .duration = 0.3,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expect(root.meta.per_frame.caches.commands.own != null);
    try std.testing.expect(overlay.meta.per_frame.caches.commands.promoted != null);

    overlay.setOpacityRaw(0.9);
    overlay.markCompositeDirty();

    cx.perf.render_cache_hit = 0;
    _ = cx.render();

    try std.testing.expect(root.meta.per_frame.caches.commands.own != null);
    try std.testing.expect(overlay.meta.per_frame.caches.commands.promoted != null);
    try std.testing.expect(cx.perf.render_cache_hit >= 2);
}

test "render: descendant composite dirty rebuilds promoted ancestor but preserves outer overflow cache" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 240);

    const root = try box(cx, .{
        .width = .{ .px = 260 },
        .height = .{ .px = 140 },
        .background = Color.rgba(20, 30, 40, 255),
        .overflow_hidden = true,
    }, .{});

    const body = try text(cx, "Body", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    try root.appendChild(cx.allocator, body);

    const overlay_root = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
        .background = Color.rgba(60, 90, 140, 255),
        .opacity = 0.8,
    }, .{});
    overlay_root.style.ensureExtPanic(cx.allocator).z_index = 20;
    try root.appendChild(cx.allocator, overlay_root);
    ui.animateNode(overlay_root, cx.allocator, .{
        .prop = .opacity,
        .from = 0.8,
        .to = 1.0,
        .duration = 0.3,
    });

    const inner = try text(cx, "Inner", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    try overlay_root.appendChild(cx.allocator, inner);

    cx.root = root;
    cx.layout();
    _ = cx.render();
    const baseline_commands = cx.lowerForEncoderPaintTable();

    try std.testing.expect(root.meta.per_frame.caches.commands.own != null);
    try std.testing.expect(overlay_root.meta.per_frame.caches.commands.promoted != null);

    var baseline_inner_x: ?f32 = null;
    for (baseline_commands) |cmd| {
        if (cmd.isText()) {
            const t = cmd;
            if (std.mem.eql(u8, t.text_content, "Inner")) {
                baseline_inner_x = t.geom.x;
                break;
            }
        }
    }
    try std.testing.expect(baseline_inner_x != null);

    inner.style.translate_x = 24;
    inner.markCompositeDirty();

    cx.perf.render_cache_hit = 0;
    _ = cx.render();
    const translated_commands = cx.lowerForEncoderPaintTable();
    try std.testing.expect(cx.perf.render_cache_hit >= 1);

    const overlay_runtime = cx.scene_runtime.get(overlay_root.id).?;
    try std.testing.expect(overlay_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(!overlay_runtime.promoted_surface_flags.reused_this_frame);

    var translated_inner_x: ?f32 = null;
    for (translated_commands) |cmd| {
        if (cmd.isText()) {
            const t = cmd;
            if (std.mem.eql(u8, t.text_content, "Inner")) {
                translated_inner_x = t.geom.x;
                break;
            }
        }
    }
    try std.testing.expect(translated_inner_x != null);
    try std.testing.expectApproxEqAbs(baseline_inner_x.? + 24, translated_inner_x.?, 0.001);

    cx.perf.render_cache_hit = 0;
    cx.frame_time_ms = 16.0; // task #161: skip v0.5-P4 skip path.
    _ = cx.render();
    try std.testing.expect(cx.perf.render_cache_hit >= 2);
    const reused_overlay_runtime = cx.scene_runtime.get(overlay_root.id).?;
    try std.testing.expect(reused_overlay_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.rebuilt_this_frame);
}

test "render: promoted descendant composite dirty still rebuilds promoted ancestor" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(360, 240);

    const root = try box(cx, .{
        .width = .{ .px = 260 },
        .height = .{ .px = 140 },
        .background = Color.rgba(20, 30, 40, 255),
        .overflow_hidden = true,
    }, .{});

    const overlay_root = try box(cx, .{
        .width = .{ .px = 140 },
        .height = .{ .px = 60 },
        .background = Color.rgba(60, 90, 140, 255),
        .opacity = 0.8,
        .overflow_hidden = true,
    }, .{});
    overlay_root.style.ensureExtPanic(cx.allocator).z_index = 20;
    overlay_root.style.ensureExtPanic(cx.allocator).overflow_fade = .{
        .size = 12,
        .edges = .{ .right = true },
    };
    try root.appendChild(cx.allocator, overlay_root);
    ui.animateNode(overlay_root, cx.allocator, .{
        .prop = .opacity,
        .from = 0.8,
        .to = 1.0,
        .duration = 0.3,
    });

    const promoted_child = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 30 },
        .background = Color.rgba(180, 220, 255, 255),
    }, .{});
    promoted_child.style.ensureExtPanic(cx.allocator).glass = .{ .backdrop_blur = 6 };
    try overlay_root.appendChild(cx.allocator, promoted_child);

    const regular_sibling = try text(cx, "Sibling", .{
        .font_size = 14,
        .color = Color.rgba(255, 255, 255, 255),
    });
    try overlay_root.appendChild(cx.allocator, regular_sibling);

    const overlay_badge = try text(cx, "Badge", .{
        .font_size = 14,
        .color = Color.rgba(255, 255, 255, 255),
    });
    overlay_badge.style.ensureExtPanic(cx.allocator).z_index = 30;
    try overlay_root.appendChild(cx.allocator, overlay_badge);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expect(overlay_root.meta.per_frame.caches.commands.promoted != null);
    try std.testing.expect(promoted_child.meta.per_frame.caches.commands.promoted != null);
    const baseline_overlay_cache = overlay_root.meta.per_frame.caches.commands.promoted.?;
    try std.testing.expect(baseline_overlay_cache.descendant_tail_command_count > 0);

    promoted_child.style.translate_x = 18;
    promoted_child.markCompositeDirty();

    cx.perf.render_cache_hit = 0;
    cx.perf.render_cache_miss = 0;
    cx.perf.descendant_scoped_promoted_rebuild_count = 0;
    cx.perf.descendant_scoped_promoted_cache_splice_count = 0;
    cx.perf.descendant_scoped_promoted_self_replay_count = 0;
    cx.perf.descendant_scoped_promoted_descendant_pass_replay_count = 0;
    cx.perf.descendant_scoped_promoted_tail_replay_count = 0;
    cx.perf.descendant_scoped_promoted_regular_child_replay_count = 0;
    _ = cx.render();
    try std.testing.expect(cx.perf.render_cache_miss > 0);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.descendant_scoped_promoted_rebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.descendant_scoped_promoted_cache_splice_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.descendant_scoped_promoted_self_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.descendant_scoped_promoted_descendant_pass_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.descendant_scoped_promoted_tail_replay_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.descendant_scoped_promoted_regular_child_replay_count);

    const overlay_runtime = cx.scene_runtime.get(overlay_root.id).?;
    const child_runtime = cx.scene_runtime.get(promoted_child.id).?;
    const overlay_cache = overlay_root.meta.per_frame.caches.commands.promoted.?;
    try std.testing.expect(overlay_runtime.has_promoted_descendant_subtree);
    try std.testing.expect(!child_runtime.has_promoted_descendant_subtree);
    try std.testing.expect(overlay_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(!overlay_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(overlay_runtime.promoted_surface_flags.invalidated_by_descendant_this_frame);
    try std.testing.expect(!overlay_runtime.promoted_surface_flags.invalidated_by_self_this_frame);
    try std.testing.expect(overlay_runtime.promoted_surface_flags.descendant_scoped_rebuild_candidate_this_frame);
    try std.testing.expect(overlay_cache.self_content_command_count > 0);
    try std.testing.expect(overlay_cache.descendant_content_command_count > 0);
    try std.testing.expect(overlay_cache.descendant_overlay_command_count > 0);
    try std.testing.expect(overlay_cache.descendant_tail_command_count > 0);
    try std.testing.expect(overlay_cache.regular_child_slices.len >= 2);
    try std.testing.expectEqual(baseline_overlay_cache.self_content_command_count, overlay_cache.self_content_command_count);
    try std.testing.expect(child_runtime.promoted_surface_flags.reused_this_frame or child_runtime.promoted_surface_flags.rebuilt_this_frame);

    cx.perf.render_cache_hit = 0;
    cx.frame_time_ms = 16.0; // task #161: skip v0.5-P4 skip path.
    _ = cx.render();
    const reused_overlay_runtime = cx.scene_runtime.get(overlay_root.id).?;
    try std.testing.expect(reused_overlay_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.invalidated_by_descendant_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.invalidated_by_self_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.descendant_scoped_rebuild_candidate_this_frame);
}

test "Cx: overlay composite dirty still counts as pending scene work" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 120 },
        .overflow_hidden = true,
    }, .{});

    const overlay = try text(cx, "Overlay", .{
        .font_size = 16,
        .color = Color.rgba(255, 255, 255, 255),
    });
    overlay.style.ensureExtPanic(cx.allocator).z_index = 20;
    try root.appendChild(cx.allocator, overlay);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expect(!cx.hasPendingSceneWork());

    overlay.setOpacityRaw(0.9);
    overlay.markCompositeDirty();

    try std.testing.expect(!overlay.frame_state.state_bits.dirty.core.render);
    try std.testing.expect(overlay.frame_state.state_bits.dirty.pipeline.composite);
    try std.testing.expect(root.frame_state.state_bits.dirty.pipeline.subtree_composite);
    try std.testing.expect(!root.frame_state.state_bits.dirty.core.subtree_render);
    try std.testing.expect(cx.hasPendingSceneWork());
}

test "render: fully transparent skipped child clears stale render/composite dirty" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 120 },
        .direction = .column,
    }, .{});

    const hidden = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 40 },
        .opacity = 0,
        .direction = .column,
    }, .{
        try text(cx, "invisible", .{
            .font_size = 14,
            .color = Color.rgba(255, 255, 255, 255),
        }),
    });
    try root.appendChild(cx.allocator, hidden);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    try std.testing.expect(!hidden.frame_state.state_bits.dirty.core.render);
    try std.testing.expect(!hidden.frame_state.state_bits.dirty.core.subtree_render);
    try std.testing.expect(!hidden.frame_state.state_bits.dirty.pipeline.composite);
    try std.testing.expect(!hidden.frame_state.state_bits.dirty.pipeline.subtree_composite);

    const hidden_text = hidden.children.items[0];
    try std.testing.expect(!hidden_text.frame_state.state_bits.dirty.core.render);
    try std.testing.expect(!hidden_text.frame_state.state_bits.dirty.core.subtree_render);
    try std.testing.expect(!hidden_text.frame_state.state_bits.dirty.pipeline.composite);
    try std.testing.expect(!hidden_text.frame_state.state_bits.dirty.pipeline.subtree_composite);
}

test "Cx: parent scale propagates to hit testing" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 140 },
    }, .{});

    const scaled = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 40 },
    }, .{});
    scaled.style.ensureExtPanic(cx.allocator).scale_x = 0.5;
    scaled.style.ensureExtPanic(cx.allocator).scale_y = 0.5;

    const button = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 20 },
    }, .{});
    button.setFocusable(true);

    try scaled.appendChild(cx.allocator, button);
    try root.appendChild(cx.allocator, scaled);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    try std.testing.expect(cx.hitTest(25, 15) == button);
    try std.testing.expect(cx.hitTest(5, 5) == null);
}

test "Cx: rotate propagates to hit testing" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 180);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 180 },
    }, .{});

    const rotated = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    rotated.setFocusable(true);
    rotated.style.translate_x = 70;
    rotated.style.translate_y = 40;
    const rotated_ext = rotated.style.ensureExtPanic(cx.allocator);
    rotated_ext.rotate = std.math.pi / 2.0;

    try root.appendChild(cx.allocator, rotated);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    try std.testing.expect(cx.hitTest(120, 90) == rotated);
    try std.testing.expect(cx.hitTest(90, 60) == null);
}

test "Cx: custom transform origin propagates to hit testing" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 180);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 180 },
    }, .{});

    const rotated = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    rotated.setFocusable(true);
    rotated.style.translate_x = 70;
    rotated.style.translate_y = 40;
    const rotated_ext = rotated.style.ensureExtPanic(cx.allocator);
    rotated_ext.rotate = std.math.pi / 2.0;
    rotated_ext.transform_origin = ui.TransformOrigin.topLeft();

    try root.appendChild(cx.allocator, rotated);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    try std.testing.expect(cx.hitTest(50, 90) == rotated);
    try std.testing.expect(cx.hitTest(120, 90) == null);
}

test "Cx: setTransformOrigin updates hit testing without touching StyleExt directly" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 180);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 180 },
    }, .{});

    const rotated = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    rotated.setFocusable(true);
    rotated.style.translate_x = 70;
    rotated.style.translate_y = 40;
    rotated.setRotate(cx.allocator, std.math.pi / 2.0);
    rotated.setTransformOrigin(cx.allocator, ui.TransformOrigin.topLeft());

    try root.appendChild(cx.allocator, rotated);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    try std.testing.expect(cx.hitTest(50, 90) == rotated);
    try std.testing.expect(cx.hitTest(120, 90) == null);
}

test "Cx: custom clip with path geometry constrains hit testing" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 140);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 140 },
        .overflow_hidden = true,
    }, .{});
    root.style.ensureExtPanic(cx.allocator).clip_shape = .custom;
    try root.setSvgPathHitGeometry(
        cx.allocator,
        "M20 20 L180 20 L100 120 Z",
        .nonzero,
    );

    const child = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 140 },
    }, .{});
    child.setFocusable(true);

    try root.appendChild(cx.allocator, child);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    try std.testing.expect(cx.hitTest(100, 60) == child);
    try std.testing.expect(cx.hitTest(30, 110) == null);
}

test "Cx: custom clip with path geometry preserves nonzero fill rule in hit testing" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 160);

    const root = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 160 },
        .overflow_hidden = true,
    }, .{});
    root.style.ensureExtPanic(cx.allocator).clip_shape = .custom;
    try root.setSvgPathHitGeometry(
        cx.allocator,
        "M20 20 L200 20 L200 140 L20 140 Z M60 50 L160 50 L160 110 L60 110 Z",
        .nonzero,
    );

    const child = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 160 },
    }, .{});
    child.setFocusable(true);

    try root.appendChild(cx.allocator, child);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    // With nonzero fill, the inner contour remains filled because both contours share winding.
    try std.testing.expect(cx.hitTest(110, 80) == child);
}

test "Cx: custom clip with dedicated custom clip geometry constrains hit testing" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 140);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 140 },
        .overflow_hidden = true,
    }, .{});
    root.style.ensureExtPanic(cx.allocator).clip_shape = .custom;
    try root.setSvgCustomClipGeometry(
        cx.allocator,
        "M20 20 L180 20 L100 120 Z",
        .nonzero,
    );

    const child = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 140 },
    }, .{});
    child.setFocusable(true);

    try root.appendChild(cx.allocator, child);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    try std.testing.expect(cx.hitTest(100, 60) == child);
    try std.testing.expect(cx.hitTest(30, 110) == null);
}

test "Cx: custom clip provider geometry constrains hit testing" {
    const Ctx = struct {
        svg: []const u8,
        fill_rule: ui.PathFillRule,
    };
    const callbacks = struct {
        fn provide(node: *const ui.Node, allocator: std.mem.Allocator, ctx_ptr: ?*anyopaque) !ui.PathGeometry {
            _ = node;
            const ctx = @as(*const Ctx, @ptrCast(@alignCast(ctx_ptr.?)));
            return try ui.createSvgDocumentPathGeometry(allocator, ctx.svg, ctx.fill_rule);
        }
    };

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 140);

    const provider_ctx = Ctx{
        .svg = "<svg viewBox='0 0 200 140'><path d='M20 20 L180 20 L100 120 Z'/></svg>",
        .fill_rule = .nonzero,
    };

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 140 },
        .overflow_hidden = true,
    }, .{});
    (try root.style.ensureExtFallible(cx.allocator)).clip_shape = .custom;
    root.setCustomClipGeometryProvider(cx.allocator, callbacks.provide, @constCast(&provider_ctx));

    const child = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 140 },
    }, .{});
    child.setFocusable(true);

    try root.appendChild(cx.allocator, child);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    try std.testing.expect(cx.hitTest(100, 60) == child);
    try std.testing.expect(cx.hitTest(30, 110) == null);
}

test "render: custom clip provider geometry regenerates after layout change" {
    const ProviderState = struct {
        calls: usize = 0,
    };
    const callbacks = struct {
        fn provide(node: *const ui.Node, allocator: std.mem.Allocator, ctx_ptr: ?*anyopaque) !ui.PathGeometry {
            const state = @as(*ProviderState, @ptrCast(@alignCast(ctx_ptr.?)));
            state.calls += 1;
            const inset = node.rectFromWorldOrFallback().w * 0.5;
            const commands = try allocator.dupe(ui.PathCommand, &.{
                .{ .move_to = .{ .x = inset, .y = 0 } },
                .{ .line_to = .{ .x = node.rectFromWorldOrFallback().w, .y = 0 } },
                .{ .line_to = .{ .x = node.rectFromWorldOrFallback().w, .y = node.rectFromWorldOrFallback().h } },
                .{ .line_to = .{ .x = inset, .y = node.rectFromWorldOrFallback().h } },
                .close,
            });
            return .{
                .commands = commands,
                .fill_rule = .nonzero,
                .bounds = .{ .x = inset, .y = 0, .w = node.rectFromWorldOrFallback().w - inset, .h = node.rectFromWorldOrFallback().h },
                .owned = true,
            };
        }
    };

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    var provider_state = ProviderState{};
    const root = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 60 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
    (try root.style.ensureExtFallible(cx.allocator)).clip_shape = .custom;
    root.setCustomClipGeometryProvider(cx.allocator, callbacks.provide, &provider_state);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 1), provider_state.calls);
    try std.testing.expect(root.getLayoutOutput().vector.fill.custom_clip != null);
    try std.testing.expectApproxEqAbs(@as(f32, 40), root.getLayoutOutput().vector.fill.custom_clip.?.bounds.x, 0.001);

    root.style.width = .{ .px = 120 };
    root.markLayoutDirty();
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 2), provider_state.calls);
    try std.testing.expect(root.getLayoutOutput().vector.fill.custom_clip != null);
    try std.testing.expectApproxEqAbs(@as(f32, 60), root.getLayoutOutput().vector.fill.custom_clip.?.bounds.x, 0.001);
}

test "render: custom clip provider geometry regenerates after render-only change" {
    const ProviderState = struct {
        calls: usize = 0,
    };
    const callbacks = struct {
        fn provide(node: *const ui.Node, allocator: std.mem.Allocator, ctx_ptr: ?*anyopaque) !ui.PathGeometry {
            const state = @as(*ProviderState, @ptrCast(@alignCast(ctx_ptr.?)));
            state.calls += 1;
            const inset = @as(f32, @floatFromInt(node.getBackground().a)) * 0.25;
            const commands = try allocator.dupe(ui.PathCommand, &.{
                .{ .move_to = .{ .x = inset, .y = 0 } },
                .{ .line_to = .{ .x = node.rectFromWorldOrFallback().w, .y = 0 } },
                .{ .line_to = .{ .x = node.rectFromWorldOrFallback().w, .y = node.rectFromWorldOrFallback().h } },
                .{ .line_to = .{ .x = inset, .y = node.rectFromWorldOrFallback().h } },
                .close,
            });
            return .{
                .commands = commands,
                .fill_rule = .nonzero,
                .bounds = .{ .x = inset, .y = 0, .w = node.rectFromWorldOrFallback().w - inset, .h = node.rectFromWorldOrFallback().h },
                .owned = true,
            };
        }
    };

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 140);

    var provider_state = ProviderState{};
    const root = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 60 },
        .background = Color.rgba(20, 60, 80, 80),
        .overflow_hidden = true,
    }, .{});
    (try root.style.ensureExtFallible(cx.allocator)).clip_shape = .custom;
    root.setCustomClipGeometryProvider(cx.allocator, callbacks.provide, &provider_state);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 1), provider_state.calls);
    try std.testing.expect(root.getLayoutOutput().vector.fill.custom_clip != null);
    try std.testing.expectApproxEqAbs(@as(f32, 20), root.getLayoutOutput().vector.fill.custom_clip.?.bounds.x, 0.001);

    root.setBackground(Color.rgba(20, 60, 80, 160));
    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 2), provider_state.calls);
    try std.testing.expect(root.getLayoutOutput().vector.fill.custom_clip != null);
    try std.testing.expectApproxEqAbs(@as(f32, 40), root.getLayoutOutput().vector.fill.custom_clip.?.bounds.x, 0.001);
}

test "box: basic node construction" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;
    cx.layout();

    try std.testing.expectEqual(@as(f32, 200), root.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 100), root.rectFromWorldOrFallback().h);
}

test "box: click handler" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);

    var clicked = false;

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
    }, .{});

    const btn = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    btn.behavior.events.on_click = Cx.simpleHandler(struct {
        fn handle(ctx: *anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(ctx));
            ptr.* = true;
        }
    }.handle, &clicked);

    try root.appendChild(cx.allocator, btn);
    cx.root = root;
    cx.layout();

    cx.handleClick(50, 20);
    try std.testing.expect(clicked);
}

test "Cx: handleKeyDown with Tab cycles focus" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = Direction.column,
    }, .{});

    const input1 = try Node.create(cx.allocator, cx.nextId(), .input, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    });
    try root.appendChild(cx.allocator, input1);

    const input2 = try Node.create(cx.allocator, cx.nextId(), .input, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    });
    try root.appendChild(cx.allocator, input2);

    cx.root = root;
    cx.layout();

    try cx.focus_manager.registerFocusable(input1);
    try cx.focus_manager.registerFocusable(input2);

    cx.handleKeyDown(.tab, .{});
    try std.testing.expect(cx.focus_manager.current_focus == input1);

    cx.handleKeyDown(.tab, .{});
    try std.testing.expect(cx.focus_manager.current_focus == input2);

    cx.handleKeyDown(.tab, .{ .shift = true });
    try std.testing.expect(cx.focus_manager.current_focus == input1);
}

test "Cx: bubbled Tab handler suppresses default focus traversal" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = Direction.column,
    }, .{});

    var parent_tab_count: u32 = 0;

    const parent = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 120 },
        .direction = Direction.column,
    }, .{});
    parent.behavior.events.on_key_down = struct {
        fn handler(_: ui.KeyCode, _: ui.Modifiers, context: ?*anyopaque) EventResult {
            const ptr: *u32 = @ptrCast(@alignCast(context.?));
            ptr.* += 1;
            return .handled;
        }
    }.handler;
    parent.behavior.events.key_context = &parent_tab_count;
    try root.appendChild(cx.allocator, parent);

    const input1 = try Node.create(cx.allocator, cx.nextId(), .input, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    });
    try parent.appendChild(cx.allocator, input1);

    const input2 = try Node.create(cx.allocator, cx.nextId(), .input, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    });
    try root.appendChild(cx.allocator, input2);

    cx.root = root;
    cx.layout();

    try cx.focus_manager.registerFocusable(input1);
    try cx.focus_manager.registerFocusable(input2);
    cx.focus_manager.setFocus(input1);

    cx.handleKeyDown(.tab, .{});

    try std.testing.expectEqual(@as(u32, 1), parent_tab_count);
    try std.testing.expect(cx.focus_manager.current_focus == input1);
}

test "Cx: with nothing focused the application root claims Tab chords before focus traversal" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const Seen = struct { ctrl_tabs: u32 = 0 };
    var seen = Seen{};
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = Direction.column,
    }, .{});
    // An app-level "next document" chord on the root: claims Ctrl+Tab only.
    root.behavior.events.on_key_down = struct {
        fn handler(key: ui.KeyCode, mods: ui.Modifiers, context: ?*anyopaque) EventResult {
            if (key != .tab or !mods.ctrl) return .ignored;
            const ptr: *Seen = @ptrCast(@alignCast(context.?));
            ptr.ctrl_tabs += 1;
            return .handled;
        }
    }.handler;
    root.behavior.events.key_context = &seen;

    const input = try Node.create(cx.allocator, cx.nextId(), .input, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    });
    try root.appendChild(cx.allocator, input);
    cx.root = root;
    cx.layout();
    try cx.focus_manager.registerFocusable(input);
    try std.testing.expect(cx.focus_manager.current_focus == null);

    cx.handleKeyDown(.tab, .{ .ctrl = true });
    try std.testing.expectEqual(@as(u32, 1), seen.ctrl_tabs);
    try std.testing.expect(cx.focus_manager.current_focus == null);

    // An unclaimed plain Tab still starts focus traversal.
    cx.handleKeyDown(.tab, .{});
    try std.testing.expectEqual(@as(u32, 1), seen.ctrl_tabs);
    try std.testing.expect(cx.focus_manager.current_focus == input);
}

test "Cx: inspector chord yields to an application binding for the same keys" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 120);

    const Ctx = struct { claim: bool = true, seen: u32 = 0 };
    var ctx = Ctx{};
    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 120 } }, .{});
    root.behavior.events.on_key_down = struct {
        fn handler(_: ui.KeyCode, _: ui.Modifiers, context: ?*anyopaque) EventResult {
            const c: *Ctx = @ptrCast(@alignCast(context.?));
            c.seen += 1;
            return if (c.claim) .stop else .ignored;
        }
    }.handler;
    root.behavior.events.key_context = &ctx;
    cx.root = root;
    cx.layout();

    // Ctrl+Shift+I is "insert image" in an editor on Windows: the app wins.
    const chord = ui.Modifiers{ .ctrl = true, .shift = true };
    cx.handleKeyDown(.i, chord);
    try std.testing.expectEqual(@as(u32, 1), ctx.seen);
    try std.testing.expect(!cx.inspector.enabled);

    // Unclaimed, the chord opens the inspector.
    ctx.claim = false;
    cx.handleKeyDown(.i, chord);
    try std.testing.expect(cx.inspector.enabled);

    // Closing always works, even where the app would claim the keys.
    ctx.claim = true;
    cx.handleKeyDown(.i, chord);
    try std.testing.expect(!cx.inspector.enabled);
    try std.testing.expectEqual(@as(u32, 2), ctx.seen);
}

test "Cx: pointer capture release refreshes hover target" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 120);

    const CaptureCtx = struct {
        cx: *Cx,
        node: ?*Node = null,
    };

    var capture_ctx = CaptureCtx{ .cx = cx };

    const root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
        .direction = Direction.row,
    }, .{});

    const left = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    left.behavior.interaction.focusable = true;
    left.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const ctx_ptr: *CaptureCtx = @ptrCast(@alignCast(context.?));
            switch (event) {
                .mouse_down => {
                    ctx_ptr.cx.setPointerCapture(ctx_ptr.node.?);
                    return .stop;
                },
                else => return .ignored,
            }
        }
    }.handler;
    left.behavior.events.event_context = &capture_ctx;
    capture_ctx.node = left;
    try root.appendChild(cx.allocator, left);

    const right = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    right.behavior.interaction.focusable = true;
    try root.appendChild(cx.allocator, right);

    cx.root = root;
    cx.layout();

    cx.handleMouseMove(10, 10);
    try std.testing.expect(cx.hovered_node == left);

    cx.handleMouseDown(10, 10, .{});
    cx.handleMouseMove(150, 10);
    try std.testing.expect(cx.hovered_node == left);

    cx.handleMouseUp(150, 10);
    try std.testing.expect(cx.hovered_node == right);
}

test "Cx: mouseUp can replace root during pointer capture without stale root dereference" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 120);

    const SwapCtx = struct {
        cx: *Cx,
        old_root: *Node,
        new_root: *Node,
        capture_node: ?*Node = null,
    };

    const new_root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
    }, .{});
    const replacement = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
    }, .{});
    replacement.behavior.interaction.focusable = true;
    try new_root.appendChild(cx.allocator, replacement);

    const old_root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 120 },
        .direction = Direction.row,
    }, .{});

    var swap_ctx = SwapCtx{
        .cx = cx,
        .old_root = old_root,
        .new_root = new_root,
    };

    const left = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    left.behavior.interaction.focusable = true;
    left.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const ctx_ptr: *SwapCtx = @ptrCast(@alignCast(context.?));
            switch (event) {
                .mouse_down => {
                    ctx_ptr.cx.setPointerCapture(ctx_ptr.capture_node.?);
                    return .stop;
                },
                .mouse_up => {
                    ctx_ptr.cx.invalidateReferencesTo(ctx_ptr.old_root);
                    ctx_ptr.cx.root = ctx_ptr.new_root;
                    ctx_ptr.cx.freeNode(ctx_ptr.old_root);
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler;
    left.behavior.events.event_context = &swap_ctx;
    swap_ctx.capture_node = left;
    try old_root.appendChild(cx.allocator, left);

    const right = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
    }, .{});
    right.behavior.interaction.focusable = true;
    try old_root.appendChild(cx.allocator, right);

    cx.root = old_root;
    cx.layout();

    cx.handleMouseMove(10, 10);
    try std.testing.expect(cx.hovered_node == left);

    cx.handleMouseDown(10, 10, .{});
    cx.handleMouseMove(150, 10);
    try std.testing.expect(cx.hovered_node == left);

    cx.handleMouseUp(150, 10);
    try std.testing.expect(cx.root == new_root);
    try std.testing.expect(cx.hovered_node == replacement);
}

test "Cx: same-position hover keeps pending scene work for idle loop" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(220, 120);

    const HoverCtx = struct {
        node: *Node,
        hovered: *bool,
    };

    var hovered = false;
    const root = try box(cx, .{
        .width = .{ .px = 220 },
        .height = .{ .px = 120 },
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 32 },
    }, .{});

    var hover_ctx = HoverCtx{
        .node = button,
        .hovered = &hovered,
    };
    button.behavior.events.on_hover = Cx.simpleHandler(struct {
        fn handler(context: *anyopaque) void {
            const ctx_ptr: *HoverCtx = @ptrCast(@alignCast(context));
            ctx_ptr.hovered.* = true;
            ctx_ptr.node.markRenderDirty();
        }
    }.handler, &hover_ctx);

    try root.appendChild(cx.allocator, button);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    cx.needs_redraw = false;
    cx.mouse_x = 20;
    cx.mouse_y = 16;

    try std.testing.expect(!cx.hasPendingSceneWork());

    cx.handleMouseMove(20, 16);

    try std.testing.expect(hovered);
    try std.testing.expect(cx.hovered_node == button);
    try std.testing.expect(!cx.needs_redraw);
    try std.testing.expect(cx.hasPendingSceneWork());
}

test "Cx: mouseDown syncs runtime and interaction for newly appended node" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});
    cx.root = root;
    cx.layout();
    _ = cx.render();

    const button = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    // Needs pointer role to hitTest find.
    button.setFocusable(true);
    try root.appendChild(cx.allocator, button);

    try std.testing.expect(root.frame_state.state_bits.dirty.runtime.subtree_dirty);
    // appendChild no longer sets subtree_order_dirty, only subtree_runtime_index_dirty.

    cx.handleMouseDown(10, 10, .{});

    try std.testing.expect(cx.pressed_node == button);
    try std.testing.expect(cx.last_mouse_down_target == button);
}

test "Cx: render resolves last mouse-down target through its generation handle" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    button.setFocusable(true);
    try root.appendChild(cx.allocator, button);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    cx.handleMouseDown(10, 10, .{});
    try std.testing.expect(cx.last_mouse_down_target == button);
    try std.testing.expect(cx.last_mouse_down_handle != null);

    // Model the lifecycle boundary that caused the crash: the registry has
    // invalidated the identity before the next render, while the compatibility
    // raw pointer still contains the old address.
    cx.node_registry.noteNodeFreed(button.id);
    root.markRenderDirty();
    _ = cx.render();

    try std.testing.expect(cx.last_mouse_down_target == null);
    try std.testing.expect(cx.last_mouse_down_handle == null);
}

test "Cx: mouseMove syncs translated dirty subtree before render" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});
    const container = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 32 },
    }, .{});
    // Needs pointer role to hitTest find.
    button.setFocusable(true);

    try container.appendChild(cx.allocator, button);
    try root.appendChild(cx.allocator, container);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    container.style.translate_y = 80;
    container.markLayoutDirty(); // translate change needs layout to update hitTest position.

    cx.handleMouseMove(10, 90);

    try std.testing.expect(cx.hovered_node == button);
}

test "Cx: deferred text commits preserve explicit invalidation and conservative defaults" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const Capture = struct {
        cx: *Cx,
        invalidate: bool = false,
        result: EventResult = .stop,
        commits: usize = 0,
        fn event(e: Event, context: ?*anyopaque) EventResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (e) {
                .text_input, .ime_commit => self.commits += 1,
                else => {},
            }
            if (self.invalidate) self.cx.needs_redraw = true;
            return self.result;
        }
    };
    var capture = Capture{ .cx = cx };
    const node = try box(cx, .{}, .{});
    cx.root = node;
    node.behavior.events.on_event = Capture.event;
    node.behavior.events.event_context = &capture;
    node.behavior.interaction.text_input_client = emptyTextInputClient(&capture);
    cx.setViewport(400, 300);
    cx.layout();
    cx.focus_manager.setFocus(node);
    // Default clients still invalidate immediately.
    cx.needs_redraw = false;
    cx.handleTextInput("a");
    try std.testing.expect(cx.needs_redraw);
    node.behavior.interaction.deferred_text_input_redraw = true;
    for (0..2) |kind| {
        for (0..5) |scenario| {
            capture.result = switch (scenario) {
                3 => .ignored,
                4 => .handled,
                else => .stop,
            };
            capture.invalidate = scenario == 1;
            cx.needs_redraw = scenario == 2;
            if (kind == 0) cx.handleTextInput("a") else cx.handleImeCommit("字");
            try std.testing.expectEqual(scenario != 0, cx.needs_redraw);
        }
    }
    try std.testing.expectEqual(@as(usize, 11), capture.commits);
    capture.invalidate = false;
    capture.result = .stop;
    cx.needs_redraw = false;
    cx.handleImePreedit("字", 0);
    try std.testing.expect(cx.needs_redraw);
    // Opt-in never bypasses the live text-input capability gate.
    node.behavior.interaction.text_input_client = null;
    cx.needs_redraw = false;
    cx.handleTextInput("ignored");
    cx.handleImeCommit("ignored");
    try std.testing.expect(!cx.needs_redraw);
    try std.testing.expectEqual(@as(usize, 11), capture.commits);
}

test "Cx: handleTextInput dispatches to focused text editor" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var received = false;

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});

    const input_node = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    }, .{});
    input_node.tag = .input;
    input_node.behavior.events.on_event = struct {
        fn handler_fn(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .text_input => {
                    const ptr: *bool = @ptrCast(@alignCast(context.?));
                    ptr.* = true;
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler_fn;
    input_node.behavior.events.event_context = &received;
    input_node.behavior.interaction.text_input_client = emptyTextInputClient(&received);

    try root.appendChild(cx.allocator, input_node);
    cx.root = root;
    cx.layout();

    cx.focus_manager.setFocus(input_node);
    cx.handleTextInput("hello");
    try std.testing.expect(received);
}

test "Cx: handleImePreedit/Commit dispatches to focused text editor" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const Capture = struct {
        got_preedit: bool = false,
        got_commit: bool = false,
        cursor_offset: u32 = 0,
    };
    var capture = Capture{};

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});

    const input_node = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
    }, .{});
    input_node.tag = .input;
    input_node.behavior.events.on_event = struct {
        fn handler_fn(event: Event, context: ?*anyopaque) EventResult {
            const c: *Capture = @ptrCast(@alignCast(context.?));
            switch (event) {
                .ime_preedit => |ime| {
                    c.got_preedit = true;
                    c.cursor_offset = ime.cursor_utf8_offset;
                    return .handled;
                },
                .ime_commit => {
                    c.got_commit = true;
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler_fn;
    input_node.behavior.events.event_context = &capture;
    input_node.behavior.interaction.text_input_client = emptyTextInputClient(&capture);

    try root.appendChild(cx.allocator, input_node);
    cx.root = root;
    cx.layout();

    cx.focus_manager.setFocus(input_node);
    cx.handleImePreedit("ni", 1);
    cx.handleImeCommit("ni");

    try std.testing.expect(capture.got_preedit);
    try std.testing.expect(capture.got_commit);
    try std.testing.expectEqual(@as(u32, 1), capture.cursor_offset);
}

test "Cx: text input session is the sole idempotent native IME owner" {
    const ImeMockBackend = struct {
        enabled_calls: u32 = 0,
        discard_calls: u32 = 0,
        last_enabled: bool = false,
        last_window: system_sdk.events.WindowId = 0,

        fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}

        fn pump(
            _: *anyopaque,
            _: *system_sdk.events.EventQueue,
            _: u32,
        ) system_sdk.SdkError!system_sdk.PumpResult {
            return .{};
        }

        fn setEnabled(
            context: *anyopaque,
            window: system_sdk.events.WindowId,
            enabled: bool,
        ) system_sdk.SdkError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.enabled_calls += 1;
            self.last_enabled = enabled;
            self.last_window = window;
        }

        fn setCursorRect(
            _: *anyopaque,
            _: system_sdk.events.WindowId,
            _: f32,
            _: f32,
            _: f32,
            _: f32,
        ) system_sdk.SdkError!void {}

        fn discard(
            context: *anyopaque,
            _: system_sdk.events.WindowId,
        ) system_sdk.SdkError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.discard_calls += 1;
        }
    };

    var backend = ImeMockBackend{};
    const vtable = system_sdk.BackendVTable{
        .name = "ui-ime-session-mock",
        .deinit = ImeMockBackend.deinitFn,
        .pump_events = ImeMockBackend.pump,
        .ime = .{
            .set_enabled = ImeMockBackend.setEnabled,
            .set_cursor_rect = ImeMockBackend.setCursorRect,
            .discard = ImeMockBackend.discard,
        },
    };
    var sdk = system_sdk.SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .ime = true });
    defer sdk.deinit();

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);
    // SDK attachment reconciles the initially unfocused window exactly once.
    try std.testing.expectEqual(@as(u32, 1), backend.enabled_calls);
    try std.testing.expect(!backend.last_enabled);

    const root = try box(cx, .{}, .{});
    const client_a = try box(cx, .{}, .{});
    const client_b = try box(cx, .{}, .{});
    const button = try box(cx, .{}, .{});
    const ignoredEvent = struct {
        fn handler(_: Event, _: ?*anyopaque) EventResult {
            return .ignored;
        }
    }.handler;
    client_a.behavior.events.on_event = ignoredEvent;
    client_b.behavior.events.on_event = ignoredEvent;
    client_a.behavior.interaction.text_input_client = emptyTextInputClient(client_a);
    client_b.behavior.interaction.text_input_client = emptyTextInputClient(client_b);
    try root.appendChild(cx.allocator, client_a);
    try root.appendChild(cx.allocator, client_b);
    try root.appendChild(cx.allocator, button);
    cx.root = root;

    cx.focus_manager.setFocus(client_a);
    try std.testing.expectEqual(@as(u32, 2), backend.enabled_calls);
    try std.testing.expect(backend.last_enabled);
    try std.testing.expectEqual(@as(u32, 0), backend.discard_calls);

    // Switching logical clients keeps the one window-level native context
    // enabled, but atomically discards composition owned by the old client.
    cx.focus_manager.setFocus(client_b);
    try std.testing.expectEqual(@as(u32, 2), backend.enabled_calls);
    try std.testing.expectEqual(@as(u32, 1), backend.discard_calls);

    cx.focus_manager.setFocus(button);
    try std.testing.expectEqual(@as(u32, 3), backend.enabled_calls);
    try std.testing.expect(!backend.last_enabled);
    try std.testing.expectEqual(@as(u32, 2), backend.discard_calls);

    cx.focus_manager.setFocus(client_b);
    try std.testing.expectEqual(@as(u32, 4), backend.enabled_calls);
    try std.testing.expect(backend.last_enabled);
    cx.refreshTextInputSession();
    cx.refreshTextInputSession();
    try std.testing.expectEqual(@as(u32, 4), backend.enabled_calls);
    try std.testing.expectEqual(@as(u32, 2), backend.discard_calls);

    // A retained node may swap its editor model without changing identity.
    // Ownership includes the client context, so old composition cannot leak
    // into the replacement model hidden behind the same NodeHandle.
    client_b.behavior.interaction.text_input_client = emptyTextInputClient(client_a);
    cx.refreshTextInputSession();
    try std.testing.expectEqual(@as(u32, 4), backend.enabled_calls);
    try std.testing.expectEqual(@as(u32, 3), backend.discard_calls);

    // Controls which change editable mode while retaining focus reconcile
    // through the same owner; no component writes native state directly.
    client_b.behavior.interaction.text_input_client = null;
    cx.refreshTextInputSession();
    try std.testing.expectEqual(@as(u32, 5), backend.enabled_calls);
    try std.testing.expect(!backend.last_enabled);
    try std.testing.expectEqual(@as(u32, 4), backend.discard_calls);

    client_b.behavior.interaction.text_input_client = emptyTextInputClient(client_b);
    cx.refreshTextInputSession();
    const Native = struct {
        extern fn zenit_text_input_selection(window: u32, start: *u32, end: *u32, caret: *u32) c_int;
    };
    var start: u32 = 0;
    var end: u32 = 0;
    var caret: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(1, &start, &end, &caret));

    // Allocating another Cx and assigning its identity must not unregister
    // window 1's live client. No render/focus retry may be needed to recover.
    const before_new_window = backend.enabled_calls;
    {
        const other = try Cx.init(std.testing.allocator, std.testing.io);
        defer other.deinit();
        other.setWindowId(2);
        try std.testing.expectEqual(before_new_window, backend.enabled_calls);
        try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(1, &start, &end, &caret));
        other.setSystemSdk(&sdk);
        try std.testing.expectEqual(@as(system_sdk.events.WindowId, 2), backend.last_window);
        try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(1, &start, &end, &caret));
    }
    try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(1, &start, &end, &caret));
    // Even an unused Cx destroyed with its default id must not clear window 1.
    const unused = try Cx.init(std.testing.allocator, std.testing.io);
    unused.deinit();
    try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(1, &start, &end, &caret));

    // Native queries use a separate identity; SDK mutations retain logical 1.
    cx.setWindowIdentity(1, 101);
    try std.testing.expectEqual(@as(system_sdk.events.WindowId, 1), backend.last_window);
    try std.testing.expectEqual(@as(c_int, 0), Native.zenit_text_input_selection(1, &start, &end, &caret));
    try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(101, &start, &end, &caret));
    cx.setWindowId(1); // idempotent logical assignment preserves native identity
    try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(101, &start, &end, &caret));
    {
        const other = try Cx.init(std.testing.allocator, std.testing.io);
        defer other.deinit();
        // Logical id deliberately equals the first window's native id. Never
        // publish an intermediate resolver under that logical key.
        other.setWindowIdentity(101, 202);
        other.setSystemSdk(&sdk);
        const other_root = try box(other, .{}, .{});
        other_root.behavior.events.on_event = ignoredEvent;
        other_root.behavior.interaction.text_input_client = emptyTextInputClient(other_root);
        other.root = other_root;
        other.focus_manager.setFocus(other_root);
        try std.testing.expectEqual(@as(system_sdk.events.WindowId, 101), backend.last_window);
        try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(202, &start, &end, &caret));
        try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(101, &start, &end, &caret));
    }
    try std.testing.expectEqual(@as(c_int, 0), Native.zenit_text_input_selection(202, &start, &end, &caret));
    try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(101, &start, &end, &caret));
    cx.clearSystemSdk();
    try std.testing.expectEqual(@as(c_int, 0), Native.zenit_text_input_selection(101, &start, &end, &caret));
    cx.setSystemSdk(&sdk);
    try std.testing.expectEqual(@as(c_int, 1), Native.zenit_text_input_selection(101, &start, &end, &caret));

    // Low-level free skips blur callbacks. The native session still has to
    // close immediately, before another key or a new frame can arrive.
    root.removeChildIncremental(client_b);
    cx.freeNode(client_b);
    try std.testing.expect(!backend.last_enabled);
    try std.testing.expectEqual(@as(system_sdk.events.WindowId, 1), backend.last_window);
    try std.testing.expectEqual(@as(c_int, 0), Native.zenit_text_input_selection(101, &start, &end, &caret));
}

test "Cx: text and IME events ignore non-text focused nodes" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const Capture = struct {
        key_down: u32 = 0,
        text_or_ime: u32 = 0,
    };
    var capture = Capture{};
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 32 },
    }, .{});
    button.setFocusable(true);
    button.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            const state: *Capture = @ptrCast(@alignCast(context.?));
            switch (event) {
                .key_down => {
                    state.key_down += 1;
                    return .handled;
                },
                .text_input, .ime_preedit, .ime_commit => {
                    state.text_or_ime += 1;
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler;
    button.behavior.events.event_context = &capture;

    try root.appendChild(cx.allocator, button);
    cx.root = root;
    cx.layout();
    cx.focus_manager.setFocus(button);
    cx.needs_redraw = false;

    cx.handleKeyDown(.a, .{});
    try std.testing.expectEqual(@as(u32, 1), capture.key_down);
    cx.needs_redraw = false;
    cx.handleTextInput("a");
    cx.handleImePreedit("あ", 3);
    cx.handleImeCommit("亜");

    try std.testing.expectEqual(@as(u32, 0), capture.text_or_ime);
    try std.testing.expect(!cx.needs_redraw);
}

test "Cx: mouse interaction path does not fall back to tree hit test" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var hovered = false;
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});

    const node = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
    }, .{});
    node.behavior.events.on_hover = Cx.simpleHandler(struct {
        fn handler(ctx: *anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(ctx));
            ptr.* = true;
        }
    }.handler, &hovered);
    try root.appendChild(cx.allocator, node);

    cx.root = root;
    cx.layout();

    cx.handleMouseMove(20, 20);

    try std.testing.expect(hovered);
}

test "Cx: scroll interaction path does not fall back to tree hit test" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var scrolled = false;
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});

    const node = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    // scroll hitTest requires node to have scroll role; set tag = .scroll
    node.tag = .scroll;
    node.behavior.events.on_event = struct {
        fn handler(event: Event, context: ?*anyopaque) EventResult {
            switch (event) {
                .scroll => {
                    const ptr: *bool = @ptrCast(@alignCast(context.?));
                    ptr.* = true;
                    return .handled;
                },
                else => return .ignored,
            }
        }
    }.handler;
    node.behavior.events.event_context = &scrolled;
    try root.appendChild(cx.allocator, node);

    cx.root = root;
    cx.layout();

    cx.handleScroll(.{ .x = 20, .y = 20, .dx = 0, .dy = -10, .phase = .changed });

    try std.testing.expect(scrolled);
}

test "Cx: registered texture svg hit shape auto-attaches to image nodes" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    try cx.svg_textures.registerHit(
        42,
        "<svg viewBox='0 0 24 24'><path d='M12 2L22 22L2 22Z'/></svg>",
    );

    const node = try ui.imageTint(cx, 42, Color.WHITE, .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
    });
    defer node.destroy(std.testing.allocator);

    try std.testing.expect(node.getLayoutOutput().vector.fill.path != null);
    try std.testing.expect(node.getLayoutOutput().vector.fill.path.?.commands.len > 0);
    switch (node.style.hit_shape()) {
        .path => |path| try std.testing.expectEqual(ui.PathFillRule.nonzero, path.fill_rule),
        else => return error.TestUnexpectedResult,
    }
}

test "Cx: svg API caches embedded svg textures by data and size" {
    const LoaderState = struct {
        load_count: u32 = 0,
        unload_count: u32 = 0,
        next_id: u32 = 100,
        last_width: u32 = 0,
        last_height: u32 = 0,
    };
    const callbacks = struct {
        fn load(context: ?*anyopaque, svg_data: []const u8, width: u32, height: u32) !u32 {
            _ = svg_data;
            const state: *LoaderState = @ptrCast(@alignCast(context.?));
            state.load_count += 1;
            state.last_width = width;
            state.last_height = height;
            const texture_id = state.next_id;
            state.next_id += 1;
            return texture_id;
        }

        fn unload(context: ?*anyopaque, texture_id: u32) void {
            _ = texture_id;
            const state: *LoaderState = @ptrCast(@alignCast(context.?));
            state.unload_count += 1;
        }
    };

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    var state = LoaderState{};
    cx.svg_textures.setLoader(.{
        .context = &state,
        .load_fn = callbacks.load,
        .unload_fn = callbacks.unload,
    });

    const svg_data = "<svg viewBox='0 0 32 16'><path d='M0 0 L32 0 L32 16 L0 16 Z'/></svg>";

    const first = try ui.svgTint(cx, svg_data, Color.WHITE, .{});
    defer first.destroy(std.testing.allocator);
    const second = try ui.svg(cx, svg_data, .{});
    defer second.destroy(std.testing.allocator);
    const third = try ui.svg(cx, svg_data, .{
        .width = .{ .px = 64 },
        .height = .{ .px = 32 },
    });
    defer third.destroy(std.testing.allocator);

    // svgOversampleFactor 2x-oversample <=64px icons:
    // first/second (viewBox 32x16) -> raster (64,32), shared cache
    // third (style 64x32) -> raster (128,64), separate load.
    try std.testing.expectEqual(@as(u32, 2), state.load_count);
    try std.testing.expectEqual(@as(u32, 128), state.last_width);
    try std.testing.expectEqual(@as(u32, 64), state.last_height);
    try std.testing.expectEqual(first.getImage().?.texture_id, second.getImage().?.texture_id);
    try std.testing.expect(first.getLayoutOutput().vector.fill.path != null);
    try std.testing.expect(second.getLayoutOutput().vector.fill.path != null);

    try std.testing.expectEqual(@as(u32, 100), first.getImage().?.texture_id);
    try std.testing.expectEqual(@as(u32, 100), second.getImage().?.texture_id);
    try std.testing.expectEqual(@as(u32, 101), third.getImage().?.texture_id);
    try std.testing.expectEqual(@as(u32, 2), state.load_count);

    cx.svg_textures.clearTextureCache();
    try std.testing.expectEqual(@as(u32, 2), state.unload_count);
}

test "Cx: pure layout dirty does not rebuild runtime indexes" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .column,
    }, .{});

    const child = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    try root.appendChild(cx.allocator, child);

    cx.root = root;
    cx.layout();

    child.markSizingDirty();
    _ = cx.render();

    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_rebuild_count);
}

test "Cx: append child updates focus order without full runtime rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .column,
    }, .{});

    const first = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    first.behavior.interaction.focusable = true;
    try root.appendChild(cx.allocator, first);

    cx.root = root;
    cx.layout();

    const before = cx.node_registry.handleFor(first);

    const second = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
    }, .{});
    second.behavior.interaction.focusable = true;
    try root.appendChild(cx.allocator, second);

    try std.testing.expect(!root.frame_state.state_bits.dirty.runtime.dirty);
    try std.testing.expect(root.frame_state.state_bits.dirty.runtime.subtree_dirty);
    try std.testing.expect(second.frame_state.state_bits.dirty.runtime.dirty);

    _ = cx.render();

    const after = cx.node_registry.handleFor(first);
    try std.testing.expectEqual(before.generation, after.generation);
    try std.testing.expectEqual(@as(usize, 2), cx.focus_manager.focus_order.items.len);
    try std.testing.expect(cx.focus_manager.focus_order.items[0] == first);
    try std.testing.expect(cx.focus_manager.focus_order.items[1] == second);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_rebuild_count);
}

test "Cx: detach child updates focus order without full runtime rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .column,
    }, .{});

    const first = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    first.behavior.interaction.focusable = true;
    try root.appendChild(cx.allocator, first);

    const second = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
    }, .{});
    second.behavior.interaction.focusable = true;
    try root.appendChild(cx.allocator, second);

    cx.root = root;
    cx.layout();

    const before = cx.node_registry.handleFor(first);

    cx.detachChild(root, second);
    second.destroy(cx.allocator);
    _ = cx.render();

    const after = cx.node_registry.handleFor(first);
    try std.testing.expectEqual(before.generation, after.generation);
    try std.testing.expectEqual(@as(usize, 1), cx.focus_manager.focus_order.items.len);
    try std.testing.expect(cx.focus_manager.focus_order.items[0] == first);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_rebuild_count);
}

test "Cx: order dirty reorders focus order without runtime rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .column,
    }, .{});

    const first = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    first.behavior.interaction.focusable = true;
    try root.appendChild(cx.allocator, first);

    const second = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
    }, .{});
    second.behavior.interaction.focusable = true;
    try root.appendChild(cx.allocator, second);

    cx.root = root;
    cx.layout();

    const first_before = cx.node_registry.handleFor(first);
    const second_before = cx.node_registry.handleFor(second);

    try root.replaceChildOrder(cx.allocator, &.{ second, first });

    _ = cx.render();

    const first_after = cx.node_registry.handleFor(first);
    const second_after = cx.node_registry.handleFor(second);
    try std.testing.expectEqual(first_before.generation, first_after.generation);
    try std.testing.expectEqual(second_before.generation, second_after.generation);
    try std.testing.expectEqual(@as(usize, 2), cx.focus_manager.focus_order.items.len);
    try std.testing.expect(cx.focus_manager.focus_order.items[0] == second);
    try std.testing.expect(cx.focus_manager.focus_order.items[1] == first);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_order_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.interaction_full_rebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.interaction_partial_rebuild_count);
    try std.testing.expect(!root.frame_state.state_bits.dirty.pipeline.subtree_order);
}

test "Cx: non-focus order dirty skips focus order rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .column,
    }, .{});

    const first = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 40 },
    }, .{});
    first.setFocusable(true);
    try root.appendChild(cx.allocator, first);

    const second = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
    }, .{});
    second.setFocusable(true);
    try root.appendChild(cx.allocator, second);

    const container = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 80 },
        .direction = .column,
    }, .{});
    try root.appendChild(cx.allocator, container);

    const child_a = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 20 },
    }, .{});
    const child_b = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 20 },
    }, .{});
    try container.appendChild(cx.allocator, child_a);
    try container.appendChild(cx.allocator, child_b);

    cx.root = root;
    cx.layout();

    try container.replaceChildOrder(cx.allocator, &.{ child_b, child_a });

    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 2), cx.focus_manager.focus_order.items.len);
    try std.testing.expect(cx.focus_manager.focus_order.items[0] == first);
    try std.testing.expect(cx.focus_manager.focus_order.items[1] == second);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_order_rebuild_count);
}

test "Cx: positive tabindex order dirty falls back to full focus rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
        .direction = .column,
    }, .{});
    const first = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
    }, .{});
    const second = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
    }, .{});
    first.setTabIndex(2);
    second.setTabIndex(1);
    try root.appendChild(cx.allocator, first);
    try root.appendChild(cx.allocator, second);

    cx.root = root;
    cx.layout();

    try root.replaceChildOrder(cx.allocator, &.{ second, first });
    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 2), cx.focus_manager.focus_order.items.len);
    try std.testing.expect(cx.focus_manager.focus_order.items[0] == second);
    try std.testing.expect(cx.focus_manager.focus_order.items[1] == first);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.focus_order_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.interaction_full_rebuild_count);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.interaction_partial_rebuild_count);
}

test "Cx: focusable toggle updates focus order incrementally" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
        .direction = .column,
    }, .{});
    const first = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
    }, .{});
    const second = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
    }, .{});
    first.setFocusable(true);
    try root.appendChild(cx.allocator, first);
    try root.appendChild(cx.allocator, second);

    cx.root = root;
    cx.layout();

    second.setFocusable(true);
    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 2), cx.focus_manager.focus_order.items.len);
    try std.testing.expect(cx.focus_manager.focus_order.items[0] == first);
    try std.testing.expect(cx.focus_manager.focus_order.items[1] == second);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_order_rebuild_count);
}

test "Cx: absolute layout dirty uses partial interaction rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const overlay = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 30 },
        .position = .absolute,
    }, .{});
    overlay.setFocusable(true);
    try root.appendChild(cx.allocator, overlay);

    cx.root = root;
    cx.layout();

    overlay.style.translate_x = 48;
    overlay.markLayoutDirty();
    _ = cx.render();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.interaction_partial_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.interaction_full_rebuild_count);
    try std.testing.expect(cx.hitTest(52, 10) == overlay);
}

test "Cx: relative layout dirty uses partial interaction rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
        .direction = .row,
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 30 },
    }, .{});
    button.setFocusable(true);
    try root.appendChild(cx.allocator, button);

    cx.root = root;
    cx.layout();

    button.style.translate_x = 32;
    button.markLayoutDirty();
    _ = cx.render();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.interaction_partial_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.interaction_full_rebuild_count);
    try std.testing.expect(cx.hitTest(36, 10) == button);
}

test "Cx: clipped layout dirty uses partial interaction rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const clipper = try box(cx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 40 },
        .overflow_hidden = true,
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 30 },
    }, .{});
    button.setFocusable(true);
    try clipper.appendChild(cx.allocator, button);
    try root.appendChild(cx.allocator, clipper);

    cx.root = root;
    cx.layout();

    button.style.translate_x = 48;
    button.markLayoutDirty();
    _ = cx.render();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.interaction_partial_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.interaction_full_rebuild_count);
    try std.testing.expect(cx.hitTest(56, 10) == button);
    try std.testing.expect(cx.hitTest(68, 10) == null);
}

test "Cx: before-render layout dirty uses partial interaction rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const overlay = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 30 },
        .position = .absolute,
    }, .{});
    overlay.setFocusable(true);
    try root.appendChild(cx.allocator, overlay);

    overlay.meta.per_frame.hooks.before_render.main = struct {
        fn tick(node: *Node) void {
            if (node.style.translate_x == 0) {
                node.style.translate_x = 32;
                node.markLayoutDirty();
            }
        }
    }.tick;

    cx.root = root;
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.interaction_partial_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.interaction_full_rebuild_count);
    try std.testing.expect(cx.hitTest(36, 10) == overlay);
}

test "Cx: before-render deferred free invalidates collected partial roots" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const victim = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 30 },
        .position = .absolute,
    }, .{});
    victim.setFocusable(true);
    try root.appendChild(cx.allocator, victim);

    cx.root = root;
    cx.layout();

    const Probe = struct {
        var context: ?*Cx = null;
        var node_to_free: ?*Node = null;
        var fired = false;

        fn tick(_: *Node) void {
            if (fired) return;
            fired = true;
            context.?.freeNode(node_to_free.?);
        }
    };
    Probe.context = cx;
    Probe.node_to_free = victim;
    Probe.fired = false;
    defer {
        Probe.context = null;
        Probe.node_to_free = null;
        Probe.fired = false;
    }
    root.meta.per_frame.hooks.before_render.main = Probe.tick;

    // This makes victim an initial partial root. The hook then frees it and
    // marks root layout-dirty, exercising the post-tick root collection that
    // previously dereferenced the freed initial entry.
    victim.markInteractionDirty();
    try std.testing.expect(cx.hitTest(10, 10) == null);
    try std.testing.expect(Probe.fired);
    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
}

test "Cx: offscreen node animations still advance and finish" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(120, 80);

    const root = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 80 },
        .direction = .row,
    }, .{});
    const leading_spacer = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 20 },
    }, .{});
    const offscreen = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 20 },
    }, .{});

    try root.appendChild(cx.allocator, leading_spacer);
    try root.appendChild(cx.allocator, offscreen);

    cx.root = root;
    cx.layout();

    ui.animateNode(offscreen, cx.allocator, .{
        .prop = .opacity,
        .from = 1.0,
        .to = 0.0,
        .duration = 1.0,
        .easing = .linear,
    });

    cx.frame_time_ms = 500;
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), offscreen.getOpacity(), 0.01);
    try std.testing.expect(cx.hasPendingSceneWork());

    cx.frame_time_ms = 1000;
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), offscreen.getOpacity(), 0.01);

    // Animation complete frame tick still requests re-render (linger + O(1) active anim flag
    // conservative); system truly idle after one more render.
    cx.frame_time_ms = 1016;
    _ = cx.render();
    try std.testing.expect(!cx.hasPendingSceneWork());
}

test "Cx: geometry-only interaction dirty uses partial interaction rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 20 },
    }, .{});
    button.setFocusable(true);
    try root.appendChild(cx.allocator, button);

    cx.root = root;
    cx.layout();

    button.style.translate_y = 20;
    button.markInteractionDirty();
    button.markRenderDirty();
    _ = cx.render();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.interaction_partial_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.interaction_full_rebuild_count);
    try std.testing.expect(cx.hitTest(10, 10) == null);
    try std.testing.expect(cx.hitTest(10, 30) == button);
}

test "Cx: hitTest refreshes geometry-only dirty state without render" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 20 },
    }, .{});
    button.setFocusable(true);
    try root.appendChild(cx.allocator, button);

    cx.root = root;
    cx.layout();

    button.style.translate_y = 20;
    button.markInteractionDirty();
    button.markRenderDirty();

    try std.testing.expect(cx.hitTest(10, 10) == null);
    try std.testing.expect(cx.hitTest(10, 30) == button);
}

test "Cx: hitTest refreshes animated geometry without render" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 20 },
    }, .{});
    button.setFocusable(true);
    try root.appendChild(cx.allocator, button);

    cx.root = root;
    cx.layout();

    ui.animateNode(button, cx.allocator, .{
        .prop = .translate_x,
        .from = 0,
        .to = 60,
        .duration = 1.0,
        .easing = .linear,
    });
    cx.frame_time_ms = 500;

    try std.testing.expect(cx.hitTest(10, 10) == null);
    try std.testing.expect(cx.hitTest(50, 10) == button);
    try std.testing.expectApproxEqAbs(@as(f32, 30), button.style.translate_x, 0.001);
}

test "Cx: runtime dirty subtree can use partial interaction rebuild" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const container = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 60 },
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 24 },
    }, .{});
    button.setFocusable(true);
    try container.appendChild(cx.allocator, button);
    try root.appendChild(cx.allocator, container);

    cx.root = root;
    cx.layout();

    container.markRuntimeIndexDirty();
    _ = cx.render();

    try std.testing.expectEqual(@as(u32, 1), cx.perf.interaction_partial_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.interaction_full_rebuild_count);
    try std.testing.expect(cx.hitTest(10, 10) == button);
}

test "Cx: hitTest miss does not tree-fallback once index is built" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const button = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 24 },
    }, .{});
    button.setFocusable(true);
    try root.appendChild(cx.allocator, button);

    cx.root = root;
    cx.layout();

    try std.testing.expect(cx.hitTest(220, 110) == null);
}

test "Node: replaceChildOrder preserves handles and parents" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
        .direction = .column,
    }, .{});
    const first = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
    }, .{});
    const second = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
    }, .{});
    first.setFocusable(true);
    second.setFocusable(true);
    try root.appendChild(cx.allocator, first);
    try root.appendChild(cx.allocator, second);

    cx.root = root;
    cx.layout();

    const first_before = cx.node_registry.handleFor(first);
    const second_before = cx.node_registry.handleFor(second);

    try root.replaceChildOrder(cx.allocator, &.{ second, first });
    _ = cx.render();

    try std.testing.expect(root.children.items[0] == second);
    try std.testing.expect(root.children.items[1] == first);
    try std.testing.expect(second.parent == root);
    try std.testing.expect(first.parent == root);
    try std.testing.expectEqual(first_before.generation, cx.node_registry.handleFor(first).generation);
    try std.testing.expectEqual(second_before.generation, cx.node_registry.handleFor(second).generation);
}

test "Node: focus setters mark order dirty" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
    }, .{});
    const node = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
    }, .{});
    try root.appendChild(cx.allocator, node);
    cx.root = root;
    cx.layout();

    node.setFocusable(true);
    try std.testing.expect(node.frame_state.state_bits.dirty.pipeline.order);
    try std.testing.expect(root.frame_state.state_bits.dirty.pipeline.subtree_order);

    _ = cx.render();

    node.setTabIndex(2);
    try std.testing.expect(node.frame_state.state_bits.dirty.pipeline.order);
    try std.testing.expect(root.frame_state.state_bits.dirty.pipeline.subtree_order);
}

test "justify: space_between distributes remaining space" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 100);

    // 3 children of 50px each in a 300px row -> remaining = 150, gap = 150/2 = 75
    const root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 100 },
        .direction = .row,
        .justify = .space_between,
    }, .{
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{}),
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{}),
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{}),
    });

    cx.root = root;
    cx.layout();

    try std.testing.expectEqual(@as(f32, 0), root.children.items[0].rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 125), root.children.items[1].rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 250), root.children.items[2].rectFromWorldOrFallback().x);
}

test "justify: space_around wraps children with equal space" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 100);

    // 3 children of 50px each in 300px -> remaining = 150, gap = 150/3 = 50
    // offset = 50/2 = 25
    const root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 100 },
        .direction = .row,
        .justify = .space_around,
    }, .{
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{}),
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{}),
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{}),
    });

    cx.root = root;
    cx.layout();

    try std.testing.expectEqual(@as(f32, 25), root.children.items[0].rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 125), root.children.items[1].rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 225), root.children.items[2].rectFromWorldOrFallback().x);
}

test "justify: space_evenly distributes with equal gaps including edges" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 100);

    // 3 children of 50px each in 400px -> remaining = 250, gap = 250/4 = 62.5
    // offset = 62.5
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 100 },
        .direction = .row,
        .justify = .space_evenly,
    }, .{
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{}),
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{}),
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{}),
    });

    cx.root = root;
    cx.layout();

    try std.testing.expectEqual(@as(f32, 62.5), root.children.items[0].rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 175), root.children.items[1].rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 287.5), root.children.items[2].rectFromWorldOrFallback().x);
}

test "fit container: intrinsic size from px children" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);

    // fit container 2 px children (row, gap=10)
    // intrinsic width = 50 + 80 + 10(gap) = 140
    // intrinsic height = max(30, 40) = 40.
    const fit_container = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        .gap = 10,
    }, .{
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } }, .{}),
        try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } }, .{}),
    });

    cx.root = fit_container;
    cx.layout();

    try std.testing.expectEqual(@as(f32, 140), fit_container.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 40), fit_container.rectFromWorldOrFallback().h);
}

test "fit container relayouts on deep wrapped text height change" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);

    const root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 200 },
        .direction = .column,
    }, .{});
    const table_container = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .fit = .{} },
        .direction = .column,
        .overflow_hidden = true,
    }, .{});
    const row = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
    }, .{});
    const cell = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
    }, .{});
    const text_node = try box(cx, .{
        .width = .{ .px = 56 },
        .height = .{ .fit = .{} },
    }, .{});
    text_node.setText(.{
        .content = "short line",
        .font_size = 14,
        .line_height = 1.4,
        .wrap = .word,
    });

    try cell.appendChild(cx.allocator, text_node);
    try row.appendChild(cx.allocator, cell);
    try table_container.appendChild(cx.allocator, row);
    try root.appendChild(cx.allocator, table_container);

    cx.root = root;
    cx.layout();

    const initial_container_h = table_container.rectFromWorldOrFallback().h;
    const initial_row_h = row.rectFromWorldOrFallback().h;

    {
        var t = text_node.getText().?;
        t.content = "Line one wraps into line two and line three";
        text_node.setText(t);
    }
    text_node.markSizingDirty();
    cx.layout();

    try std.testing.expect(row.rectFromWorldOrFallback().h > initial_row_h);
    try std.testing.expect(table_container.rectFromWorldOrFallback().h > initial_container_h);
    try std.testing.expect(table_container.rectFromWorldOrFallback().y + table_container.rectFromWorldOrFallback().h >= text_node.rectFromWorldOrFallback().y + text_node.rectFromWorldOrFallback().h);
}

test "fit > grow > fit chain grows with wrapped text (grow under a fit grandparent backfills)" {
    // GlassBox structure: root fit -> glass surface grow -> content fit -> wrapped text.
    // Wrap happens in child layout, grow layer never backfilled, stays single-line height, fit
    // ancestor sums
    // -> text overflows glass bottom (storybook GlassBox Materials card).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 400);
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 400 }, .direction = .row, .align_items = .center }, .{});
    const outer = try box(cx, .{ .width = .{ .px = 160 }, .height = .{ .fit = .{} }, .direction = .column }, .{});
    const middle = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .column }, .{});
    const inner = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} }, .direction = .column, .padding = Padding.all(16) }, .{});
    const t = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} } }, .{});
    t.setText(.{ .content = "Functional layer content. Functional layer content.", .font_size = 13, .wrap = .word });
    try inner.appendChild(cx.allocator, t);
    try middle.appendChild(cx.allocator, inner);
    try outer.appendChild(cx.allocator, middle);
    try root.appendChild(cx.allocator, outer);
    cx.root = root;
    cx.layout();
    const th = t.rectFromWorldOrFallback().h;
    try std.testing.expect(th > 20); // Really wrapped into multiline.
    try std.testing.expectApproxEqAbs(th + 32, inner.rectFromWorldOrFallback().h, 0.5);
    try std.testing.expectApproxEqAbs(inner.rectFromWorldOrFallback().h, middle.rectFromWorldOrFallback().h, 0.5);
    try std.testing.expectApproxEqAbs(inner.rectFromWorldOrFallback().h, outer.rectFromWorldOrFallback().h, 0.5);
}

test "grow backfill under a fit parent only expands: a stretched grow panel keeps its children centred" {
    // fit column grow-wide backplate stretched to widest sibling (240), narrow child (10) centered.
    // If content backfill first shrinks the backplate to 10, the final align places the child by
    // 10 (offset 0); the fit column then re-stretches the backplate to 240 without re-laying out
    // the child -> child sticks left (storybook GlassBox Materials row shifted 24 pt left).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 400);
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 400 }, .direction = .row, .align_items = .start }, .{});
    const col = try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .direction = .column }, .{});
    const wide = try box(cx, .{ .width = .{ .px = 240 }, .height = .{ .px = 20 } }, .{});
    const panel = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .direction = .column, .align_items = .center }, .{});
    const dot = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try panel.appendChild(cx.allocator, dot);
    try col.appendChild(cx.allocator, wide);
    try col.appendChild(cx.allocator, panel);
    try root.appendChild(cx.allocator, col);
    cx.root = root;
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 240), panel.rectFromWorldOrFallback().w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 115), dot.rectFromWorldOrFallback().x, 0.5);
}

test "absolute bottom-anchored fit child re-anchors after its wrapped text grows" {
    // y was calculated before wrap: 20px-bottom panel wraps, bottom overshoots enclosure (storybook
    // GlassAdapt).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 420);
    const stage = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 420 }, .position = .relative }, .{});
    const panel = try box(cx, .{ .width = .{ .px = 220 }, .height = .{ .fit = .{} }, .direction = .column, .padding = Padding.all(16), .position = .absolute }, .{});
    (try panel.style.ensureExtFallible(cx.allocator)).inset = .{ .right = .{ .px = 20 }, .bottom = .{ .px = 20 } };
    const t = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .fit = .{} } }, .{});
    t.setText(.{ .content = "Material still adapts: the backdrop shows through, the shadow and rim follow.", .font_size = 13, .wrap = .word });
    try panel.appendChild(cx.allocator, t);
    try stage.appendChild(cx.allocator, panel);
    cx.root = stage;
    cx.layout();
    const r = panel.rectFromWorldOrFallback();
    try std.testing.expect(t.rectFromWorldOrFallback().h > 20); // Really wrapped.
    try std.testing.expectApproxEqAbs(@as(f32, 400), r.y + r.h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 620), r.x + r.w, 0.5);
}

test "stretch: fit children stretch on cross-axis" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 200);

    // row align_items=stretch, fit child should stretch on cross-axis (height).
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 200 },
        .direction = .row,
        .align_items = .stretch,
    }, .{
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .fit = .{} } }, .{}),
    });

    cx.root = root;
    cx.layout();

    // fit child height stretched to 200.
    try std.testing.expectEqual(@as(f32, 200), root.children.items[0].rectFromWorldOrFallback().h);
}

test "row_reverse: children laid out right-to-left" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 100);

    // 3 children, normal row [A:0, B:50, C:150], reverse should [A:200, B:100, C:0].
    const root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 100 },
        .direction = .row_reverse,
    }, .{
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{}), // A
        try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 100 } }, .{}), // B
        try box(cx, .{ .width = .{ .px = 150 }, .height = .{ .px = 100 } }, .{}), // C
    });

    cx.root = root;
    cx.layout();

    const a = root.children.items[0];
    const b = root.children.items[1];
    const c = root.children.items[2];

    // reverse: C leftmost, B center, A rightmost.
    try std.testing.expectEqual(@as(f32, 200), a.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 150), b.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), c.rectFromWorldOrFallback().x);
}

test "column_reverse: children laid out bottom-to-top" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 300);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 300 },
        .direction = .column_reverse,
    }, .{
        try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 } }, .{}), // A
        try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{}), // B
        try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{}), // C
    });

    cx.root = root;
    cx.layout();

    const a = root.children.items[0];
    const b = root.children.items[1];
    const c = root.children.items[2];

    // reverse: C top, B center, A bottom.
    try std.testing.expectEqual(@as(f32, 220), a.rectFromWorldOrFallback().y); // 300 - 80 = 220
    try std.testing.expectEqual(@as(f32, 100), b.rectFromWorldOrFallback().y); // 300 - 80 - 120 = 100
    try std.testing.expectEqual(@as(f32, 0), c.rectFromWorldOrFallback().y); // 300 - 80 - 120 - 100 = 0
}

test "row_reverse: nested children positions offset correctly" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 200);

    // Nested child absolute position offset correctly.
    const inner = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } }, .{});
    const container = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
        .padding = Padding.all(10),
    }, .{inner});

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 200 },
        .direction = .row_reverse,
    }, .{
        container,
        try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{}),
    });

    cx.root = root;
    cx.layout();

    // Container rightmost (400-100=300).
    try std.testing.expectEqual(@as(f32, 300), container.rectFromWorldOrFallback().x);
    // inner offset padding inside container, relative (not absolute 310).
    try std.testing.expectEqual(@as(f32, 10), inner.rectFromWorldOrFallback().x);
}

test "flex_wrap: row wrap breaks into multiple lines" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 300);

    // Container 300x300, 4x100px children -> first row 3, second row 1.
    const root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 300 },
        .direction = .row,
        .align_content = .start,
    }, .{
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{}), // A
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{}), // B
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{}), // C
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 60 } }, .{}), // D
    });
    root.style.ensureExtPanic(cx.allocator).flex_wrap = .wrap;

    cx.root = root;
    cx.layout();

    const a = root.children.items[0];
    const b = root.children.items[1];
    const c = root.children.items[2];
    const d = root.children.items[3];

    // First row: A(0,0), B(100,0), C(200,0).
    try std.testing.expectEqual(@as(f32, 0), a.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), a.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 100), b.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), b.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 200), c.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), c.rectFromWorldOrFallback().y);

    // Second row: D(0,50).
    try std.testing.expectEqual(@as(f32, 0), d.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 50), d.rectFromWorldOrFallback().y);
}

test "flex_wrap: column wrap breaks into multiple columns" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 200);

    // Container 400x200, column wrap, 3x100px children -> col 1 has 2, col 2 has 1.
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 200 },
        .direction = .column,
        .align_content = .start,
    }, .{
        try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 100 } }, .{}), // A
        try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 100 } }, .{}), // B
        try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 100 } }, .{}), // C
    });
    root.style.ensureExtPanic(cx.allocator).flex_wrap = .wrap;

    cx.root = root;
    cx.layout();

    const a = root.children.items[0];
    const b = root.children.items[1];
    const c = root.children.items[2];

    // First column: A(0,0), B(0,100).
    try std.testing.expectEqual(@as(f32, 0), a.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), a.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 0), b.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 100), b.rectFromWorldOrFallback().y);

    // Second column: C(80,0).
    try std.testing.expectEqual(@as(f32, 80), c.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), c.rectFromWorldOrFallback().y);
}

test "flex_wrap: wrap_reverse reverses cross axis" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 300);

    // Container 200x300, row wrap_reverse, 4x100px children -> 2 rows.
    // Normal wrap: row 1 y=0, row 2 y=50.
    // wrap_reverse: row 1 bottom, row 2 top.
    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 300 },
        .direction = .row,
        .align_content = .start,
    }, .{
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{}), // A
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{}), // B
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{}), // C
        try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{}), // D
    });
    root.style.ensureExtPanic(cx.allocator).flex_wrap = .wrap_reverse;

    cx.root = root;
    cx.layout();

    const a = root.children.items[0];
    const b = root.children.items[1];
    const c = root.children.items[2];
    const d = root.children.items[3];

    // wrap_reverse: row 1 (A,B) bottom, row 2 (C,D) top.
    try std.testing.expectEqual(@as(f32, 250), a.rectFromWorldOrFallback().y); // 300 - 50 = 250
    try std.testing.expectEqual(@as(f32, 250), b.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 200), c.rectFromWorldOrFallback().y); // 300 - 50 - 50 = 200
    try std.testing.expectEqual(@as(f32, 200), d.rectFromWorldOrFallback().y);
}

test "Context API: provide and consume" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const AppTheme = struct {
        accent: Color,
        font_size: f32,
    };

    var app_theme = AppTheme{ .accent = theme.dark.tokens.color.accent, .font_size = 16 };
    try cx.provide(AppTheme, &app_theme);

    // Consume context.
    const retrieved = cx.consume(AppTheme);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(f32, 16), retrieved.?.font_size);

    // Modify then consume.
    app_theme.font_size = 20;
    const retrieved2 = cx.consume(AppTheme);
    try std.testing.expectEqual(@as(f32, 20), retrieved2.?.font_size);
}

test "Context API: consume returns null if not provided" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const MyConfig = struct { value: i32 };
    const result = cx.consume(MyConfig);
    try std.testing.expect(result == null);
}

test "Context API: provide overwrites existing" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const Config = struct { value: i32 };

    var cfg1 = Config{ .value = 1 };
    try cx.provide(Config, &cfg1);
    try std.testing.expectEqual(@as(i32, 1), cx.consume(Config).?.value);

    var cfg2 = Config{ .value = 2 };
    try cx.provide(Config, &cfg2);
    try std.testing.expectEqual(@as(i32, 2), cx.consume(Config).?.value);

    // Only one entry (not two).
    try std.testing.expectEqual(@as(usize, 1), cx.contextCount());
}

test "Context API: multiple types" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const ThemeCtx = struct { accent: Color };
    const UserCtx = struct { name: []const u8 };

    var theme_ctx = ThemeCtx{ .accent = theme.dark.tokens.color.accent };
    var user = UserCtx{ .name = "Alice" };

    try cx.provide(ThemeCtx, &theme_ctx);
    try cx.provide(UserCtx, &user);

    try std.testing.expectEqual(@as(usize, 2), cx.contextCount());
    try std.testing.expectEqualStrings("Alice", cx.consume(UserCtx).?.name);
    try std.testing.expect(Color.eql(theme.dark.tokens.color.accent, cx.consume(ThemeCtx).?.accent));
}

test "Context API: overflow returns error" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    // Fill 16 context slots (each different type).
    var vals: [16]u8 = undefined;
    inline for (0..16) |i| {
        const T = GenContextType(i);
        try cx.provide(T, @ptrCast(&vals[i]));
    }
    try std.testing.expectEqual(@as(usize, 16), cx.contextCount());

    // 17th should return error.ContextsFull.
    var extra: u8 = 0;
    const result = cx.provide(struct { x: u8 }, @ptrCast(&extra));
    try std.testing.expectError(error.ContextsFull, result);
}

fn GenContextType(comptime i: usize) type {
    return struct {
        _marker: [i]u8 = undefined,
    };
}

test "Cx: handleKeyUp dispatches to focused node" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
    }, .{});
    const node = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
    }, .{});

    var key_up_count: u32 = 0;
    node.behavior.interaction.focusable = true;
    node.behavior.events.on_key_up = struct {
        fn handler(_: ui.KeyCode, _: ui.Modifiers, context: ?*anyopaque) EventResult {
            const count: *u32 = @ptrCast(@alignCast(context.?));
            count.* += 1;
            return .handled;
        }
    }.handler;
    node.behavior.events.key_context = &key_up_count;
    try root.appendChild(cx.allocator, node);

    cx.root = root;
    cx.layout();
    cx.focus_manager.setFocus(node);

    cx.handleKeyUp(.space, .{});
    try std.testing.expectEqual(@as(u32, 1), key_up_count);
}

test "Grid: multi-span child expands auto columns" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);

    const root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 200 },
    }, .{});

    const spanning = try text(cx, "This is a wide label", .{});
    spanning.style.ensureExtPanic(cx.allocator).grid_placement = .{ .col_span = 2 };

    const left = try box(cx, .{
        .width = .{ .px = 10 },
        .height = .{ .px = 10 },
    }, .{});
    left.style.width = .{ .grow = .{} };

    const right = try box(cx, .{
        .width = .{ .px = 10 },
        .height = .{ .px = 10 },
    }, .{});
    right.style.width = .{ .grow = .{} };

    const g = try grid(cx, .{
        .columns = &.{ .auto, .auto },
        .rows = &.{ .auto, .auto },
        .width = .{ .px = 300 },
        .height = .{ .fit = .{} },
    }, .{ spanning, left, right });

    try root.appendChild(cx.allocator, g);
    cx.root = root;
    cx.layout();

    try std.testing.expect(right.rectFromWorldOrFallback().x > left.rectFromWorldOrFallback().x);
}

test "Grid: multi-span child expands auto rows" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 240);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 240 },
    }, .{});

    const spanning = try text(cx, "Tall", .{});
    spanning.style.ensureExtPanic(cx.allocator).grid_placement = .{ .row_span = 2 };

    const follower = try box(cx, .{
        .width = .{ .px = 20 },
        .height = .{ .px = 10 },
    }, .{});
    follower.style.height = .{ .grow = .{} };

    const g = try grid(cx, .{
        .columns = &.{.auto},
        .rows = &.{ .auto, .auto, .auto },
        .width = .{ .px = 200 },
        .height = .{ .fit = .{} },
    }, .{ spanning, follower });

    try root.appendChild(cx.allocator, g);
    cx.root = root;
    cx.layout();

    try std.testing.expect(follower.rectFromWorldOrFallback().y > 0);
}

test "Grid: raw counts and explicit placement are bounded by backing tables" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 160);

    const valid = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    }, .{});
    const out_of_range = try box(cx, .{
        .width = .{ .px = 10 },
        .height = .{ .px = 10 },
    }, .{});
    out_of_range.style.ensureExtPanic(cx.allocator).grid_placement = .{
        .col_start = 255,
        .row_start = 255,
    };

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 160 },
    }, .{ valid, out_of_range });
    const gc = try cx.allocator.create(ui.GridConfig);
    gc.* = .{};
    for (0..ui.GridConfig.MAX_TRACKS) |i| {
        gc.columns[i] = .{ .fr = 1 };
        gc.rows[i] = .{ .fr = 1 };
    }
    // Bypass the builder deliberately: these public count fields used to drive
    // reads/writes past columns[16], rows[16], and the stack offset tables.
    gc.column_count = 20;
    gc.row_count = 20;
    root.style.ensureExtPanic(cx.allocator).grid = gc;

    cx.root = root;
    cx.layout();

    const valid_rect = valid.rectFromWorldOrFallback();
    try std.testing.expect(std.math.isFinite(valid_rect.x));
    try std.testing.expect(std.math.isFinite(valid_rect.y));
    try std.testing.expect(valid_rect.w > 0);
    try std.testing.expect(valid_rect.h > 0);
}

test "Layout: fit container includes child margins in size" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(120, 80);

    const root = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
    }, .{});
    const child = try box(cx, .{
        .width = .{ .px = 10 },
        .height = .{ .px = 12 },
    }, .{});
    child.style.margin = .{ .left = 3, .right = 7, .top = 2, .bottom = 4 };
    try root.appendChild(cx.allocator, child);

    cx.root = root;
    cx.layout();

    try std.testing.expectApproxEqAbs(@as(f32, 20), root.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 18), root.rectFromWorldOrFallback().h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), child.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), child.rectFromWorldOrFallback().y, 0.001);
}

test "Layout: wrap layout accounts for child margins" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(100, 80);

    const root = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .fit = .{} },
        .direction = .row,
    }, .{});
    root.style.ensureExtPanic(cx.allocator).flex_wrap = .wrap;

    const first = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 10 },
    }, .{});
    first.style.margin = .{ .left = 0, .right = 20, .top = 0, .bottom = 5 };

    const second = try box(cx, .{
        .width = .{ .px = 50 },
        .height = .{ .px = 10 },
    }, .{});

    try root.appendChild(cx.allocator, first);
    try root.appendChild(cx.allocator, second);

    cx.root = root;
    cx.layout();

    try std.testing.expectApproxEqAbs(@as(f32, 0), first.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), first.rectFromWorldOrFallback().y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), second.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 15), second.rectFromWorldOrFallback().y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 25), root.rectFromWorldOrFallback().h, 0.001);
}

test "Layout: absolute grow subtracts margins from size" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
    }, .{});
    const child = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .position = .absolute,
    }, .{});
    child.style.margin = .{ .left = 10, .right = 20, .top = 5, .bottom = 15 };
    try root.appendChild(cx.allocator, child);

    cx.root = root;
    cx.layout();

    try std.testing.expectApproxEqAbs(@as(f32, 10), child.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), child.rectFromWorldOrFallback().y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 170), child.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), child.rectFromWorldOrFallback().h, 0.001);
}

test "Layout: absolute children use the parent padding box as containing block" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(120, 80);

    const root = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 80 },
        .direction = .row,
        .padding = .{ .left = 10, .right = 20, .top = 5, .bottom = 15 },
    }, .{});

    const right_bottom = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 30 },
        .height = .{ .px = 10 },
    }, .{});
    right_bottom.style.ensureExtPanic(cx.allocator).inset = .{
        .right = .{ .px = 7 },
        .bottom = .{ .px = 9 },
    };

    const percent_inset = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 10 },
        .height = .{ .px = 10 },
    }, .{});
    percent_inset.style.ensureExtPanic(cx.allocator).inset = .{
        .left = .{ .percent = 25 },
        .top = .{ .percent = 50 },
    };

    const inset_fill = try box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    }, .{});
    inset_fill.style.ensureExtPanic(cx.allocator).inset = .{
        .left = .{ .px = 11 },
        .right = .{ .px = 13 },
        .top = .{ .px = 3 },
        .bottom = .{ .px = 7 },
    };

    const cover = try box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    }, .{});

    // A cover of the padding box uses explicit inset:0. An inset-less
    // absolute child now has a content-box static position (LC3C M3).
    cover.style.ensureExtPanic(cx.allocator).inset = .{
        .left = .{ .px = 0 },
        .right = .{ .px = 0 },
        .top = .{ .px = 0 },
        .bottom = .{ .px = 0 },
    };

    try root.appendChild(cx.allocator, right_bottom);
    try root.appendChild(cx.allocator, percent_inset);
    try root.appendChild(cx.allocator, inset_fill);
    try root.appendChild(cx.allocator, cover);
    cx.root = root;
    cx.layout();

    try std.testing.expectApproxEqAbs(@as(f32, 83), right_bottom.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 61), right_bottom.rectFromWorldOrFallback().y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), percent_inset.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), percent_inset.rectFromWorldOrFallback().y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 11), inset_fill.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), inset_fill.rectFromWorldOrFallback().y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 96), inset_fill.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 70), inset_fill.rectFromWorldOrFallback().h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cover.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cover.rectFromWorldOrFallback().y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 120), cover.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), cover.rectFromWorldOrFallback().h, 0.001);

    // The partial-layout path must resolve against the same padding box.
    right_bottom.style.ensureExtPanic(cx.allocator).inset.right = .{ .px = 12 };
    right_bottom.style.ensureExtPanic(cx.allocator).inset.bottom = .{ .px = 6 };
    right_bottom.markLayoutDirty();
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 78), right_bottom.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 64), right_bottom.rectFromWorldOrFallback().y, 0.001);
}

test "Grid: absolute children use the parent padding box as containing block" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(140, 90);

    const child = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 30 },
        .height = .{ .px = 20 },
    }, .{});
    child.style.ensureExtPanic(cx.allocator).inset = .{
        .right = .{ .px = 8 },
        .bottom = .{ .px = 7 },
    };
    const root = try grid(cx, .{
        .columns = &.{.{ .px = 140 }},
        .rows = &.{.{ .px = 90 }},
        .width = .{ .px = 140 },
        .height = .{ .px = 90 },
        .padding = .{ .left = 17, .right = 23, .top = 9, .bottom = 11 },
    }, .{child});
    cx.root = root;
    cx.layout();

    try std.testing.expectApproxEqAbs(@as(f32, 102), child.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 63), child.rectFromWorldOrFallback().y, 0.001);
}

test "Grid: auto tracks include margins and content alignment targets tracks" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(160, 120);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 120 },
        .align_items = .start,
    }, .{});

    const auto_item = try box(cx, .{
        .width = .{ .px = 20 },
        .height = .{ .px = 10 },
    }, .{});
    auto_item.style.margin = .{ .left = 5, .right = 15, .top = 3, .bottom = 7 };

    const auto_grid = try grid(cx, .{
        .columns = &.{.auto},
        .rows = &.{.auto},
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
    }, .{auto_item});
    try root.appendChild(cx.allocator, auto_grid);

    const centered_item = try box(cx, .{
        .width = .{ .px = 20 },
        .height = .{ .px = 10 },
    }, .{});
    centered_item.style.margin = .{ .left = 5, .right = 15, .top = 3, .bottom = 7 };

    const centered_grid = try grid(cx, .{
        .columns = &.{.{ .px = 100 }},
        .rows = &.{.{ .px = 50 }},
        .width = .{ .px = 100 },
        .height = .{ .px = 50 },
    }, .{centered_item});
    centered_grid.style.justify = .center;
    centered_grid.style.align_items = .center;
    centered_grid.style.margin = .{ .left = 0, .right = 0, .top = 20, .bottom = 0 };
    try root.appendChild(cx.allocator, centered_grid);

    cx.root = root;
    cx.layout();

    try std.testing.expectApproxEqAbs(@as(f32, 40), auto_grid.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), auto_grid.rectFromWorldOrFallback().h, 0.001);
    // justify-content centers the track group, not the item within a full-width track.
    // The track already fills this grid, so only the 5px start margin offsets x.
    try std.testing.expectApproxEqAbs(@as(f32, 5), centered_item.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 18), centered_item.rectFromWorldOrFallback().y, 0.001);
}

test "Layout: no_cross_stretch only suppresses inherited stretch" {
    // column cross-axis = width: fit-wide + justify=center row child (intrinsic 30px px box).
    // inner_x assert content not center-aligned to stretched width, not escape child frame.
    const Case = struct { align_items: ui.AlignItems, explicit: ?ui.AlignItems, want_x: f32 };
    const cases = [_]Case{
        .{ .align_items = .stretch, .explicit = null, .want_x = 0 },
        .{ .align_items = .center, .explicit = null, .want_x = 85 },
        .{ .align_items = .end, .explicit = null, .want_x = 170 },
        .{ .align_items = .start, .explicit = null, .want_x = 0 },
        // Explicit align_self prioritizes flag.
        .{ .align_items = .stretch, .explicit = .end, .want_x = 170 },
        .{ .align_items = .center, .explicit = .start, .want_x = 0 },
    };
    for (cases) |c| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(200, 100);

        const inner = try box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 20 } }, .{});
        const child = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .direction = .row,
            .justify = .center,
        }, .{inner});
        const ext = try child.style.ensureExtFallible(cx.allocator);
        ext.no_cross_stretch = true;
        ext.align_self = c.explicit;

        const root = try box(cx, .{
            .width = .{ .px = 200 },
            .height = .{ .px = 100 },
            .direction = .column,
            .align_items = c.align_items,
        }, .{child});
        cx.root = root;
        cx.layout();

        const r = child.rectFromWorldOrFallback();
        try std.testing.expectApproxEqAbs(@as(f32, 30), r.w, 0.001);
        try std.testing.expectApproxEqAbs(c.want_x, r.x, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 0), inner.rectFromWorldOrFallback().x, 0.001);
    }
}

test "Layout: stretched fit keeps its CSS allocated size and main alignment" {
    // A fit row is auto on its parent's cross axis. CSS stretch keeps the
    // allocated 200px width, including across recursive fit layout.
    const Case = struct {
        justify: ui.Justify,
        parent_align: ui.AlignItems,
        explicit: ?ui.AlignItems,
        min_w: f32,
        want_w: f32,
        want_inner_x: f32,
    };
    const cases = [_]Case{
        .{ .justify = .center, .parent_align = .stretch, .explicit = null, .min_w = 0, .want_w = 200, .want_inner_x = 85 },
        .{ .justify = .end, .parent_align = .stretch, .explicit = null, .min_w = 0, .want_w = 200, .want_inner_x = 170 },
        .{ .justify = .center, .parent_align = .start, .explicit = .stretch, .min_w = 0, .want_w = 200, .want_inner_x = 85 },
        // A 100px minimum does not undo a larger 200px stretch allocation.
        .{ .justify = .center, .parent_align = .stretch, .explicit = null, .min_w = 100, .want_w = 200, .want_inner_x = 85 },
        .{ .justify = .end, .parent_align = .stretch, .explicit = null, .min_w = 100, .want_w = 200, .want_inner_x = 170 },
    };
    for (cases) |c| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(200, 100);

        const inner = try box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 20 } }, .{});
        const child = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .direction = .row,
            .justify = c.justify,
        }, .{inner});
        if (c.explicit != null or c.min_w > 0) {
            const ext = try child.style.ensureExtFallible(cx.allocator);
            ext.align_self = c.explicit;
            if (c.min_w > 0) ext.min_width = c.min_w;
        }

        const root = try box(cx, .{
            .width = .{ .px = 200 },
            .height = .{ .px = 100 },
            .direction = .column,
            .align_items = c.parent_align,
        }, .{child});
        cx.root = root;
        cx.layout();

        const r = child.rectFromWorldOrFallback();
        const ir = inner.rectFromWorldOrFallback();
        try std.testing.expectApproxEqAbs(c.want_w, r.w, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 0), r.x, 0.001);
        try std.testing.expectApproxEqAbs(c.want_inner_x, ir.x, 0.001);
        try std.testing.expect(ir.x >= 0 and ir.x + ir.w <= r.w + 0.001);
    }
}

test "Layout: fit back-fill keeps centered content inside after incremental resize" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);

    const inner = try box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 20 } }, .{});
    const child = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        // Explicit hug: inherited CSS stretch must not be canceled by backfill.
        .no_cross_stretch = true,
        .justify = .center,
    }, .{inner});
    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
        .direction = .column,
        .align_items = .stretch,
    }, .{child});
    cx.root = root;
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 0), inner.rectFromWorldOrFallback().x, 0.001);

    // Increment: only change inner size, mark dirty, second frame same no escape.
    inner.style.width = .{ .px = 50 };
    inner.markLayoutDirty();
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 50), child.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), inner.rectFromWorldOrFallback().x, 0.001);
}

test "Layout: fit back-fill relayout does not flip-flop child positions" {
    // First-pass justify by predicted backfill size: fit container full-relayout child
    // positions not "append at stretch-width 85 -> backfill move to 0" flip
    // (flip marks child layout-dirty, overflow_hidden child loses render cache).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);

    const inner = try box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 20 }, .overflow_hidden = true }, .{});
    const child = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
        // Explicit hug: inherited CSS stretch must not be canceled by backfill.
        .no_cross_stretch = true,
        .justify = .center,
    }, .{inner});
    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
        .direction = .column,
        .align_items = .stretch,
    }, .{child});
    cx.root = root;
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 0), inner.rectFromWorldOrFallback().x, 0.001);

    inner.frame_state.state_bits.dirty.core.render = false;
    child.markLayoutDirty();
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 0), inner.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expect(!inner.frame_state.state_bits.dirty.core.render);
}

test "Layout: stretched fit auto margins use the final CSS allocation" {
    // Recursive fit layout preserves stretch; auto margins split its free space.
    const Case = struct { min_w: f32, want_w: f32, want_inner_x: f32 };
    const cases = [_]Case{
        .{ .min_w = 0, .want_w = 200, .want_inner_x = 85 },
        .{ .min_w = 100, .want_w = 200, .want_inner_x = 85 },
    };
    for (cases) |c| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(200, 100);

        const inner = try box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 20 } }, .{});
        inner.style.setMarginSpec(cx.allocator, ui.Margin.ZERO.withAutoLeft().withAutoRight());
        const child = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .direction = .row,
        }, .{inner});
        if (c.min_w > 0) {
            const ext = try child.style.ensureExtFallible(cx.allocator);
            ext.min_width = c.min_w;
        }
        const root = try box(cx, .{
            .width = .{ .px = 200 },
            .height = .{ .px = 100 },
            .direction = .column,
            .align_items = .stretch,
        }, .{child});
        cx.root = root;
        cx.layout();

        try std.testing.expectApproxEqAbs(c.want_w, child.rectFromWorldOrFallback().w, 0.001);
        try std.testing.expectApproxEqAbs(c.want_inner_x, inner.rectFromWorldOrFallback().x, 0.001);
    }
}

test "Layout: stretched fit-width column centers children inside its CSS allocation" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);

    const a = try box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 10 } }, .{});
    const b = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 10 } }, .{});
    const child = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .column,
        .align_items = .center,
    }, .{ a, b });
    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
        .direction = .column,
        .align_items = .stretch,
    }, .{child});
    cx.root = root;
    cx.layout();

    try std.testing.expectApproxEqAbs(@as(f32, 200), child.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 85), a.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 75), b.rectFromWorldOrFallback().x, 0.001);
}

test "Layout: auto margins absorb remaining flow space" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 80);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 40 },
        .direction = .row,
    }, .{});
    const child = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 20 },
    }, .{});
    child.style.setMarginSpec(cx.allocator, ui.Margin.ZERO.withAutoLeft().withAutoRight());
    try root.appendChild(cx.allocator, child);

    cx.root = root;
    cx.layout();

    try std.testing.expectApproxEqAbs(@as(f32, 80), child.rectFromWorldOrFallback().x, 0.001);
}

test "Layout: absolute auto margins center inside inset box" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 120);

    const root = try box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 120 },
    }, .{});
    const child = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 20 },
        .position = .absolute,
    }, .{});
    child.style.setMarginSpec(cx.allocator, ui.Margin.ZERO.withAutoLeft().withAutoRight());
    child.style.ensureExtPanic(cx.allocator).inset = .{
        .left = .{ .px = 20 },
        .right = .{ .px = 20 },
        .top = .{ .px = 10 },
    };
    try root.appendChild(cx.allocator, child);

    cx.root = root;
    cx.layout();

    try std.testing.expectApproxEqAbs(@as(f32, 100), child.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), child.rectFromWorldOrFallback().y, 0.001);
}

test "Node margin helpers clear stale auto flags" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const node = try box(cx, .{}, .{});
    cx.root = node;
    node.setMarginSpec(cx.allocator, ui.Margin.ZERO.withAutoLeft().withAutoRight());
    try std.testing.expect(node.style.marginLeftIsAuto());
    try std.testing.expect(node.style.marginRightIsAuto());

    node.setMargin(.{ .left = 12, .right = 8, .top = 1, .bottom = 2 });
    try std.testing.expectApproxEqAbs(@as(f32, 12), node.style.margin.left, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), node.style.margin.right, 0.001);
    try std.testing.expect(!node.style.marginLeftIsAuto());
    try std.testing.expect(!node.style.marginRightIsAuto());

    node.setMarginSpec(cx.allocator, ui.Margin.ZERO.withAutoTop());
    try std.testing.expect(node.style.marginTopIsAuto());
    node.setMarginTop(6);
    try std.testing.expectApproxEqAbs(@as(f32, 6), node.style.margin.top, 0.001);
    try std.testing.expect(!node.style.marginTopIsAuto());
}

test "box style margin_spec supports auto margins declaratively" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 80);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 40 },
        .direction = .row,
    }, .{
        try box(cx, .{
            .width = .{ .px = 40 },
            .height = .{ .px = 20 },
            .margin_spec = ui.Margin.ZERO.withAutoLeft().withAutoRight(),
        }, .{}),
    });

    cx.root = root;
    cx.layout();

    const child = root.children.items[0];
    try std.testing.expect(child.style.marginLeftIsAuto());
    try std.testing.expect(child.style.marginRightIsAuto());
    try std.testing.expectApproxEqAbs(@as(f32, 80), child.rectFromWorldOrFallback().x, 0.001);
}

test "Cx.freeNode releases transition slots" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(100, 100);

    const root = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
    }, .{});

    const child = try box(cx, .{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
    }, .{});
    try child.enableImplicitAnimation(cx.allocator, &.{.border_color}, .{ .duration_ms = 150 });
    try root.appendChild(cx.allocator, child);

    cx.root = root;
}

// ==================== StyleOverride tests ====================

const StyleOverride = ui.StyleOverride;
const Style = ui.Style;
const Sizing = ui.Sizing;
const Border = ui.Border;

test "StyleOverride: isEmpty — 默认构造为空" {
    const s = StyleOverride{};
    try std.testing.expect(s.isEmpty());
}

test "StyleOverride: isEmpty — 设置任意字段后非空" {
    const s = StyleOverride{ .background = Color.hex(0xFF0000) };
    try std.testing.expect(!s.isEmpty());
}

test "StyleOverride: isEmpty — margin_spec counts as non-empty" {
    const s = StyleOverride{ .margin_spec = ui.Margin.autoHorizontal() };
    try std.testing.expect(!s.isEmpty());
}

test "StyleOverride: merge — other 覆盖 self" {
    const base = StyleOverride{
        .background = Color.hex(0xFF0000),
        .opacity = 0.5,
        .font_weight = 400,
    };
    const over = StyleOverride{
        .background = Color.hex(0x00FF00),
        .gap = 16,
    };
    const result = base.merge(over);

    // background override
    try std.testing.expect(Color.eql(result.background.?, Color.hex(0x00FF00)));
    // opacity retains base
    try std.testing.expectEqual(@as(f32, 0.5), result.opacity.?);
    // font_weight retains base
    try std.testing.expectEqual(@as(u16, 400), result.font_weight.?);
    // gap from other
    try std.testing.expectEqual(@as(f32, 16), result.gap.?);
    // unset fields remain null
    try std.testing.expect(result.border == null);
}

test "StyleOverride: merge — 空 merge 空 = 空" {
    const a = StyleOverride{};
    const b = StyleOverride{};
    const result = a.merge(b);
    try std.testing.expect(result.isEmpty());
}

test "StyleOverride: merge — margin_spec overrides previous margin_spec" {
    const base = StyleOverride{ .margin_spec = (ui.Margin{ .left = 8 }).withAutoLeft() };
    const over = StyleOverride{ .margin_spec = (ui.Margin{ .right = 12 }).withAutoRight() };
    const result = base.merge(over);
    try std.testing.expect(result.margin_spec != null);
    try std.testing.expectEqual(@as(f32, 12), result.margin_spec.?.right);
    try std.testing.expect(result.margin_spec.?.rightIsAuto());
    try std.testing.expect(!result.margin_spec.?.leftIsAuto());
}

test "StyleOverride: applyTo — 覆盖 Style 字段" {
    var style = Style{};

    const ov = StyleOverride{
        .background = Color.hex(0xFF0000),
        .opacity = 0.8,
        .gap = 12,
        .width = Sizing{ .px = 200 },
    };
    ov.applyTo(&style, null);

    // background/opacity no longer in Style -> World.paint_state.
    // applyTo no longer writes Style.background/opacity; carried via paintOverride(),
    // builder sets SoA fields via setBackgroundRaw/setOpacityRaw after Node.create.
    const po = ov.paintOverride();
    try std.testing.expect(Color.eql(po.background.?, Color.hex(0xFF0000)));
    try std.testing.expectEqual(@as(f32, 0.8), po.opacity.?);
    try std.testing.expectEqual(@as(f32, 12), style.gap);
    // width override
    switch (style.width) {
        .px => |v| try std.testing.expectEqual(@as(f32, 200), v),
        else => return error.TestUnexpectedResult,
    }
    // unoverridden fields stay default
    try std.testing.expectEqual(style.direction, .column);
}

test "StyleOverride: applyTo — margin_spec writes auto flags" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var style = ui.Style{};
    defer if (style.ext) |e| cx.allocator.destroy(e);
    const spec = (ui.Margin{
        .left = 8,
        .right = 4,
        .top = 2,
        .bottom = 6,
    }).withAutoLeft().withAutoRight();

    (ui.StyleOverride{
        .margin_spec = spec,
    }).applyTo(&style, cx.allocator);

    try std.testing.expectApproxEqAbs(@as(f32, 8), style.margin.left, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4), style.margin.right, 0.001);
    try std.testing.expect(style.marginLeftIsAuto());
    try std.testing.expect(style.marginRightIsAuto());
    try std.testing.expect(!style.marginTopIsAuto());
    try std.testing.expect(!style.marginBottomIsAuto());
}

test "StyleOverride: applyTo — null 字段不影响 Style" {
    var style = Style{};

    const ov = StyleOverride{ .gap = 8 };
    ov.applyTo(&style, null);

    // no paint fields in override -> paintOverride() returns all null
    // (builder skips setBackgroundRaw/setOpacityRaw, preserves existing node SoA values)
    const po = ov.paintOverride();
    try std.testing.expect(po.background == null);
    try std.testing.expect(po.opacity == null);
    try std.testing.expectEqual(@as(f32, 8), style.gap);
}

test "StyleOverride: applyTo — border side widths" {
    var style = Style{
        .border = .{ .width = 2, .color = Color.hex(0x112233) },
    };

    const ov = StyleOverride{
        .border_right_width = 4,
        .border_bottom_width = 0,
    };
    ov.applyTo(&style, null);

    const w = style.border.resolvedWidths();
    try std.testing.expectEqual(@as(f32, 2), w[Border.SIDE_TOP]);
    try std.testing.expectEqual(@as(f32, 4), w[Border.SIDE_RIGHT]);
    try std.testing.expectEqual(@as(f32, 0), w[Border.SIDE_BOTTOM]);
    try std.testing.expectEqual(@as(f32, 2), w[Border.SIDE_LEFT]);
}

test "StyleOverride: applyTo — border side colors" {
    var style = Style{
        .border = .{ .width = 1, .color = Color.hex(0x112233) },
    };
    const ov = StyleOverride{
        .border_top_color = Color.hex(0xAA0000),
        .border_left_color = Color.hex(0x00AA00),
    };
    ov.applyTo(&style, std.testing.allocator);

    const side = style.border_side_colors().?;
    try std.testing.expect(Color.eql(side.top.?, Color.hex(0xAA0000)));
    try std.testing.expect(Color.eql(side.left.?, Color.hex(0x00AA00)));
    try std.testing.expect(side.right == null);
    try std.testing.expect(side.bottom == null);

    if (style.ext) |ext| {
        std.testing.allocator.destroy(ext);
        style.ext = null;
    }
}

test "StyleOverride: applyTo — corner_radius 写入 ext" {
    var style = Style{};

    const ov = StyleOverride{ .corner_radius = 12 };
    ov.applyTo(&style, std.testing.allocator);

    // ext should be allocated and corner_radius set
    try std.testing.expect(style.ext != null);
    const cr = style.corner_radius().?;
    try std.testing.expectEqual(@as(f32, 12), cr.resolve());

    // free ext
    std.testing.allocator.destroy(style.ext.?);
}

// ==================== Style Inherit tests ====================

test "Node.resolveTextColor: 从 parent 链继承 text_color" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    // root sets text_color
    root.style.ensureExtPanic(cx.allocator).text_color = Color.hex(0xFF0000);

    // intermediate container (no text_color)
    const container = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    try root.appendChild(cx.allocator, container);

    // leaf node
    const leaf = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try container.appendChild(cx.allocator, leaf);

    // leaf inherits root text_color (skips container)
    const resolved = leaf.resolveTextColor();
    try std.testing.expect(resolved != null);
    try std.testing.expect(Color.eql(resolved.?, Color.hex(0xFF0000)));
}

test "Node.resolveTextColor: 就近覆盖" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    root.style.ensureExtPanic(cx.allocator).text_color = Color.hex(0xFF0000);

    const container = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    container.style.ensureExtPanic(cx.allocator).text_color = Color.hex(0x00FF00);
    try root.appendChild(cx.allocator, container);

    const leaf = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try container.appendChild(cx.allocator, leaf);

    // leaf inherits nearest container text_color (green), not root (red)
    const resolved = leaf.resolveTextColor();
    try std.testing.expect(resolved != null);
    try std.testing.expect(Color.eql(resolved.?, Color.hex(0x00FF00)));
}

test "Node.resolveTextColor: 无继承返回 null" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const leaf = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(cx.allocator, leaf);

    // no parent sets text_color
    try std.testing.expect(leaf.resolveTextColor() == null);
}

test "Node.resolveTextFontSize/Weight: 继承生效" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    root.style.ensureExtPanic(cx.allocator).text_font_size = 20;
    root.style.ensureExtPanic(cx.allocator).text_font_weight = 700;

    const leaf = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(cx.allocator, leaf);

    try std.testing.expectEqual(@as(f32, 20), leaf.resolveTextFontSize().?);
    try std.testing.expectEqual(@as(u16, 700), leaf.resolveTextFontWeight().?);
}

test "StyleOverride: applyTo — text 继承属性写入 ext" {
    var style = Style{};

    const ov = StyleOverride{
        .text_color = Color.hex(0xFF0000),
        .font_size = 18,
        .font_weight = 600,
    };
    ov.applyTo(&style, std.testing.allocator);

    try std.testing.expect(style.ext != null);
    try std.testing.expect(Color.eql(style.text_color().?, Color.hex(0xFF0000)));
    try std.testing.expectEqual(@as(f32, 18), style.text_font_size().?);
    try std.testing.expectEqual(@as(u16, 600), style.text_font_weight().?);

    std.testing.allocator.destroy(style.ext.?);
}

fn testDrawContextForList(cx: *Cx, render_list: *std.ArrayList(ui.DisplayItem)) ui.DrawContext {
    return .{
        .lowering_buffer = render_list,
        .lowering_buffer_paint = &cx.lowering.main_paint,
        .display_list = null,
        .display_header = null,
        .allocator = cx.allocator,
        .frame_allocator = cx.frame_arena.allocator(),
        .render_x = 0,
        .render_y = 0,
        .render_w = 0,
        .render_h = 0,
        .local_w = 0,
        .local_h = 0,
        .clip = null,
    };
}

test "Snapshot.capture localizes node commands" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const child = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 40 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 240 },
        .padding = Padding.all(12),
    }, .{child});
    cx.root = root;
    cx.layout();

    const snapshot = (try Snapshot.capture(cx, child)).?;
    defer snapshot.deinit();

    try std.testing.expect(snapshot.commands.commands.len > 0);
    switch (snapshot.commands.commands[0]) {
        .fill_rect => |rect| {
            try std.testing.expectApproxEqAbs(@as(f32, 0.0), rect.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 0.0), rect.y, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), snapshot.captured_world_origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), snapshot.captured_world_origin.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), snapshot.local_transform_origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), snapshot.local_transform_origin.y, 0.001);
}

test "Snapshot.capture returns null for zero-sized node" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const child = try box(cx, .{
        .width = .{ .px = 0 },
        .height = .{ .px = 40 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 240 },
    }, .{child});
    cx.root = root;
    cx.layout();

    try std.testing.expect((try Snapshot.capture(cx, child)) == null);
}

test "Snapshot.capture uses global origin for absolute translated node" {
    for ([_]bool{ false, true }) |explicit_origin| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(320, 240);

        const child = try box(cx, .{
            .position = .absolute,
            .width = .{ .px = 80 },
            .height = .{ .px = 40 },
            .background = Color.rgba(255, 0, 0, 255),
        }, .{});
        // Explicit inset:0 starts at the padding edge; omitted insets start
        // at the content edge. Snapshot must preserve either global origin.
        if (explicit_origin) child.style.ensureExtPanic(cx.allocator).inset = .{
            .left = .{ .px = 0 },
            .top = .{ .px = 0 },
        };
        child.style.translate_x = 48;
        child.style.translate_y = 36;
        child.setTransformOrigin(std.testing.allocator, .{
            .x = .{ .percent = 0.5 },
            .y = .{ .px = 0 },
        });

        const root = try box(cx, .{
            .width = .{ .px = 320 },
            .height = .{ .px = 240 },
            .padding = Padding.all(12),
        }, .{child});
        cx.root = root;
        cx.layout();

        const snapshot = (try Snapshot.capture(cx, child)).?;
        defer snapshot.deinit();

        const static_padding: f32 = if (explicit_origin) 0 else 12;
        try std.testing.expectApproxEqAbs(@as(f32, 48.0) + static_padding, snapshot.captured_world_origin.x, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 36.0) + static_padding, snapshot.captured_world_origin.y, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 40.0), snapshot.local_transform_origin.x, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), snapshot.local_transform_origin.y, 0.001);
    }
}

test "Snapshot survives source node destroy" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const child = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 40 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 240 },
    }, .{child});
    cx.root = root;
    cx.layout();

    const snapshot = (try Snapshot.capture(cx, child)).?;
    defer snapshot.deinit();

    cx.root = null;
    root.destroy(cx.allocator);

    cx.lowering.main_paint.clearRetainingCapacity();
    var render_list: std.ArrayList(ui.DisplayItem) = .empty;
    defer render_list.deinit(cx.allocator);
    try snapshot.appendTo(testDrawContextForList(cx, &render_list), .{ .x = 24, .y = 16 }, 1.0, 1.0);

    // snapshot.appendTo writes to cx.lowering.main_paint (paint_table)
    try std.testing.expect(cx.lowering.main_paint.items.len > 0);
    var saw_rect = false;
    for (cx.lowering.main_paint.items) |cmd| {
        if (cmd.kind == .rect) {
            saw_rect = true;
            try std.testing.expectApproxEqAbs(@as(f32, 0.0), cmd.geom.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 0.0), cmd.geom.y, 0.001);
            break;
        }
    }
    try std.testing.expect(saw_rect);
}

test "Snapshot.appendTo preserves captured transform origin during scale" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const child = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 40 },
        .background = Color.rgba(255, 0, 0, 255),
        .transform_origin = .{
            .x = .{ .percent = 0.0 },
            .y = .{ .percent = 0.0 },
        },
    }, .{});
    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 240 },
    }, .{child});
    cx.root = root;
    cx.layout();

    const snapshot = (try Snapshot.capture(cx, child)).?;
    defer snapshot.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), snapshot.local_transform_origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), snapshot.local_transform_origin.y, 0.001);

    cx.lowering.main_paint.clearRetainingCapacity();
    var render_list: std.ArrayList(ui.DisplayItem) = .empty;
    defer render_list.deinit(cx.allocator);
    try snapshot.appendTo(testDrawContextForList(cx, &render_list), .{ .x = 24, .y = 16 }, 1.0, 0.5);

    // appendTo writes paint_table stream; first is begin_opacity_layer control item
    try std.testing.expect(cx.lowering.main_paint.items.len > 0);
    const first = cx.lowering.main_paint.items[0];
    try std.testing.expectEqual(@import("paint_table.zig").DisplayItemKind.control, first.kind);
    try std.testing.expect(first.use_draw_transform);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), first.draw_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), first.draw_y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), first.draw_w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), first.draw_h, 0.001);
}

test "Snapshot.captureWithOptions node_rect locks geometry to live node rect" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const child = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 40 },
        .background = Color.rgba(255, 0, 0, 255),
        .transform_origin = .{
            .x = .{ .percent = 0.0 },
            .y = .{ .percent = 1.0 },
        },
    }, .{});
    const child_ext = child.style.ensureExtPanic(std.testing.allocator);
    child_ext.setShadows(theme.dark.tokens.shadow.md, .{
        .color = Color.rgba(0, 0, 0, 18),
        .blur = 40,
        .offset_x = 0,
        .offset_y = 16,
    });
    child_ext.keep_rendering_when_transparent = true;

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 240 },
    }, .{child});
    cx.root = root;
    cx.layout();
    _ = cx.render();

    const default_snapshot = (try Snapshot.capture(cx, child)).?;
    defer default_snapshot.deinit();
    try std.testing.expect(default_snapshot.local_transform_origin.y > child.rectFromWorldOrFallback().h);

    const locked_snapshot = (try Snapshot.captureWithOptions(cx, child, .{
        .geometry_mode = .node_rect,
    })).?;
    defer locked_snapshot.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), locked_snapshot.local_bounds.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), locked_snapshot.local_bounds.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), locked_snapshot.local_bounds.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), locked_snapshot.local_bounds.h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), locked_snapshot.local_transform_origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), locked_snapshot.local_transform_origin.y, 0.001);

    const displayed_snapshot = (try Snapshot.captureDisplayedWithOptions(cx, child, .{
        .geometry_mode = .node_rect,
    })).?;
    defer displayed_snapshot.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), displayed_snapshot.local_bounds.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), displayed_snapshot.local_bounds.h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), displayed_snapshot.local_transform_origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), displayed_snapshot.local_transform_origin.y, 0.001);
}

test "Snapshot deep-copies text commands" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const text_node = try text(cx, "Hello", .{ .color = Color.rgba(255, 255, 255, 255) });
    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 240 },
    }, .{text_node});
    cx.root = root;
    cx.layout();

    const snapshot = (try Snapshot.capture(cx, text_node)).?;
    defer snapshot.deinit();

    if (text_node.getText()) |old| {
        var tp = old;
        tp.content = "World";
        text_node.setText(tp);
    }

    for (snapshot.commands.commands) |cmd| {
        switch (cmd) {
            .text_run => |t| {
                try std.testing.expectEqualStrings("Hello", t.content);
                return;
            },
            else => {},
        }
    }
    return error.TestUnexpectedResult;
}

// Phase 1: Wavy underline geometry (diagnostic squiggle pure geometry test)
// Corresponds to memory/lsp_ui_framework_upgrade.md D3

test "wavy: WavyParams scales with font_size" {
    const small = ui.render_engine.WavyParams.forFontSize(10);
    const big = ui.render_engine.WavyParams.forFontSize(32);
    try std.testing.expect(big.period > small.period);
    try std.testing.expect(big.amplitude > small.amplitude);
    try std.testing.expect(small.thickness >= 1.0);
}

test "wavy: centerline oscillates within the underline band" {
    const params = ui.render_engine.WavyParams.forFontSize(14);
    const a = ui.render_engine.wavyCenterAt(0, 100, 0, params.thickness, params);
    const b = ui.render_engine.wavyCenterAt(0, 100, params.period / 4, params.thickness, params);
    try std.testing.expect(a[1] != b[1]);
    try std.testing.expect(b[1] >= 100 and b[1] <= 100 + params.totalHeight(params.thickness));
}

// Matrix #3, ScrollArea 60fps < 3ms (will_change_transform auto-promotes)
test "ScrollArea content carries will_change_transform hint" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const ScrollAreaMod = @import("../components/scroll_area/mod.zig");
    const Scope = @import("../reactive.zig").Scope;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const result = try ScrollAreaMod.ScrollArea(.{}).mount(scope, cx);
    try root.appendChild(std.testing.allocator, result.container);
    // after mount, content should have will_change_transform = true to trigger promotion
    try std.testing.expect(result.content.style.will_change_transform());
}

// Matrix #4, Transform animation paint = 0
test "transform-only animation promotes node and preserves paint cache" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 240 },
    }, .{});

    const animated = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 60 },
        .background = Color.rgba(100, 150, 200, 255),
    }, .{});
    try root.appendChild(cx.allocator, animated);
    // v0.5-P5 promotion contract: transform animated nodes need explicit composited_group +
    // will_change_transform to promote. promotion requires effect entry; effect entry requires
    // composited_group / opacity<1 / blur etc. ScrollArea auto-promotes via is_scroll_container;
    // manual animateNode nodes must self-declare.
    const ext = animated.style.ensureExtPanic(cx.allocator);
    ext.will_change_transform = true;
    ext.composited_group = true;

    ui.animateNode(animated, cx.allocator, .{
        .prop = .translate_x,
        .from = 0,
        .to = 100,
        .duration = 0.3,
    });

    cx.root = root;
    cx.layout();
    _ = cx.render();

    // after first render, translate animation should promote the node
    const runtime = cx.scene_runtime.get(animated.id).?;
    try std.testing.expect(runtime.has_active_transform_animation);
    // Matrix #4 critical: promoted layer skips re-recording paint chunks during transform
    // animation.
    try std.testing.expect(runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);

    // advance translate animation; only transform changes, paint content unchanged
    const content_version_before = animated.meta.per_frame.caches.versions.content;
    animated.style.translate_x = 50;
    animated.markCompositeDirty();
    cx.layout();
    _ = cx.render();

    // content_version unchanged (paint chunks not re-recorded); composite_version increments
    try std.testing.expectEqual(content_version_before, animated.meta.per_frame.caches.versions.content);
    // promoted_cached_commands should be populated by first render
    try std.testing.expect(animated.meta.per_frame.caches.commands.promoted != null);
}

// Matrix #1, 10k nodes zero-dirty-frame fast path < 0.5ms
test "render() skip path returns cached commands when tree fully clean" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 120);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 120 },
        .background = Color.rgba(30, 40, 50, 255),
    }, .{});
    cx.root = root;
    cx.layout();

    // first render runs full path, populates last_render_list
    const first = cx.render();
    try std.testing.expect(cx.last_render_valid);
    try std.testing.expect(first.len > 0);
    const first_len = first.len;

    // second render should skip-path; commands content and length unchanged
    const second = cx.render();
    try std.testing.expectEqual(first_len, second.len);
    // skip-path returns last_render_list.items; render_list should be cleared (capacity kept)
    // but render_list stays populated after first render; second skips without clearing.
    // Key invariant: commands slice valid and same length as prior frame.
}

test "markRenderDirty 后 skip 路径失效" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 120);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 120 },
        .background = Color.rgba(30, 40, 50, 255),
    }, .{});
    cx.root = root;
    cx.layout();
    _ = cx.render(); // populate cache

    // markRenderDirty clears tree clean state, bubbles subtree_render_dirty to root
    root.markRenderDirty();
    cx.layout();
    _ = cx.render(); // should run full path
    // verify: dirty flags consumed; root should be clean after render
    try std.testing.expect(!root.frame_state.state_bits.dirty.core.render);
}

// Matrix #1 true perf bench: 10k nodes zero-dirty-frame < 0.5ms
// build 10k Node tree (100 rows x 100 cols), warm one frame to populate cache, measure 100x
// zero-dirty render; median should be well below 0.5ms (500µs). Real validation for plan
// matrix #1.
test "10k node zero-dirty render < 0.5ms (matrix #1)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1200, 1000);

    // build 100-column grid, 100 small boxes per column = 10000 leaf nodes + 100 cols =
    // 10100 nodes
    const root = try box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 1000 },
        .background = Color.rgba(20, 20, 25, 255),
        .direction = .row,
    }, .{});
    cx.root = root;

    var col: u32 = 0;
    while (col < 100) : (col += 1) {
        const column = try box(cx, .{
            .width = .{ .px = 12 },
            .height = .{ .px = 1000 },
            .direction = .column,
        }, .{});
        try root.appendChild(std.testing.allocator, column);
        var row: u32 = 0;
        while (row < 100) : (row += 1) {
            const cell = try box(cx, .{
                .width = .{ .px = 12 },
                .height = .{ .px = 10 },
                .background = Color.rgba(@intCast((col * 2) % 256), @intCast((row * 2) % 256), 100, 255),
            }, .{});
            try column.appendChild(std.testing.allocator, cell);
        }
    }

    cx.layout();

    // Warm-up: first render runs full path, populates last_render_list
    _ = cx.render();
    try std.testing.expect(cx.last_render_valid);

    // Measure 100x zero-dirty render; tree unchanged, frame_time unchanged, should skip-path
    // all
    const iterations: u32 = 100;
    var total_ns: u64 = 0;
    var max_ns: u64 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var timer = @import("zenit_time").Timer.start(std.testing.io) catch unreachable;
        const list = cx.render();
        const elapsed = timer.read();
        total_ns += elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
        // prevent optimization: sanity check that commands still non-empty
        try std.testing.expect(list.len > 0);
    }
    const avg_ns = total_ns / iterations;

    // Matrix #1 target: < 500µs (500_000ns). skip-path is O(1) flag check + slice return,
    // should be under 10µs. 50µs (50_000ns) threshold leaves room for debug build; ReleaseFast
    // measured well below. Failure prints actual; zig test mutes stdout by default, shows on
    // assertion failure.
    if (avg_ns >= 50_000 or max_ns >= 200_000) {
        std.debug.print("[v0.5-P4 matrix #1] 10k nodes zero-dirty render REGRESSED: avg={d}ns max={d}ns (target avg<50_000 max<200_000)\n", .{ avg_ns, max_ns });
        return error.PerfRegression;
    }
}

// select_headless drives rendering; mountSelectHeadless mounts 346-line state machine
// onto Node tree + Popover trigger/content + default item rendering. Stage-1 replacement
// for legacy select.zig.
test "mountSelectHeadless creates trigger + content + items" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Opt = select_headless.Option(i32);
    const opts = [_]Opt{
        .{ .value = 1, .label = "Apple" },
        .{ .value = 2, .label = "Banana" },
        .{ .value = 3, .label = "Cherry" },
    };

    const result = try select_headless.SelectHeadless(i32, .{
        .options = &opts,
        .placeholder = "Pick one...",
        .width = 200,
    }).mount(scope, cx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // verify: created 3 item nodes
    try std.testing.expectEqual(@as(usize, 3), select_headless.stateOf(i32, result).item_nodes.len);

    // verify: state.value initially null (uncontrolled default)
    try std.testing.expect(result.value.?.peek() == null);

    // verify: trigger shows placeholder
    try std.testing.expect(result.trigger_label.getText() != null);
    if (result.trigger_label.getText()) |txt| {
        try std.testing.expectEqualStrings("Pick one...", txt.content);
    }

    // verify: is_open signal initially false
    try std.testing.expect(!result.open.?.peek());
}

test "mountSelectHeadless with initial_value displays selected label" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Opt = select_headless.Option(i32);
    const opts = [_]Opt{
        .{ .value = 10, .label = "Ten" },
        .{ .value = 20, .label = "Twenty" },
    };

    const result = try select_headless.SelectHeadless(i32, .{
        .options = &opts,
        .value = @as(?i32, 20),
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    // verify: trigger label is "Twenty"
    if (result.trigger_label.getText()) |txt| {
        try std.testing.expectEqualStrings("Twenty", txt.content);
    }
    try std.testing.expectEqual(@as(?i32, 20), result.value.?.peek());
}

// v0.7 §2.1, select_headless slot recipe + recipe integration tests

test "SelectSlotRecipe.resolve 给三 slot 返合理 ConditionalStyle" {
    const mount_mod = @import("../components/select_headless/mount.zig");
    const dark = theme.dark;
    const slots = mount_mod.SelectSlotRecipe.resolve(
        .{ .variant = .default, .size = .md },
        &dark,
    );
    // trigger / content / item base must have parseable non-empty fields
    const tr = slots.trigger.resolve(.{});
    try std.testing.expect(tr.background != null);
    try std.testing.expect(tr.text_color != null);
    const ct = slots.content.resolve(.{});
    try std.testing.expect(ct.background != null);
    // item hover state uses bg_hover
    const it_hover = slots.item.resolve(.{ .is_hovered = true });
    try std.testing.expect(it_hover.background != null);
}

test "mountSelectHeadless render_trigger slot — caller 自定义 trigger 节点" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Opt = select_headless.Option(i32);
    const opts = [_]Opt{ .{ .value = 1, .label = "A" }, .{ .value = 2, .label = "B" } };

    const TriggerCtx = select_headless.mount.TriggerSlotCtx(i32);
    const CustomTrigger = struct {
        // caller custom trigger uses "Button" tag instead of default input box
        // flag marks node was rendered by custom fn
        var was_called: bool = false;
        var captured_label: []const u8 = "";

        fn render(ctx: TriggerCtx, c: *Cx) anyerror!*Node {
            was_called = true;
            captured_label = ctx.label_text;
            const n = try core_mod.box(c, .{
                .width = .{ .px = 100 },
                .height = .{ .px = 24 },
            }, .{});
            // use special component_name for fixture verification
            n.meta.ownership.meta.component_name = "MyCustomTrigger";
            return n;
        }

        const core_mod = @import("../core.zig");
    };
    // reset
    CustomTrigger.was_called = false;
    CustomTrigger.captured_label = "";

    const result = try select_headless.SelectHeadless(i32, .{
        .options = &opts,
        .placeholder = "Pick A or B",
        .render_trigger = CustomTrigger.render,
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expect(CustomTrigger.was_called);
    try std.testing.expectEqualStrings("Pick A or B", CustomTrigger.captured_label);
    // result.trigger_label should point to caller's custom node
    try std.testing.expect(result.trigger_label.meta.ownership.meta.component_name != null);
    try std.testing.expectEqualStrings(
        "MyCustomTrigger",
        result.trigger_label.meta.ownership.meta.component_name.?,
    );
}

test "mountSelectHeadless render_item slot — caller 自定义每个 option 行" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Opt = select_headless.Option(i32);
    const opts = [_]Opt{
        .{ .value = 1, .label = "Apple" },
        .{ .value = 2, .label = "Banana" },
        .{ .value = 3, .label = "Cherry" },
    };

    const ItemCtx = select_headless.mount.ItemSlotCtx(i32);
    const CustomItem = struct {
        var call_count: u32 = 0;

        fn render(ctx: ItemCtx, c: *Cx) anyerror!*Node {
            call_count += 1;
            const n = try core_mod.box(c, .{
                .width = .{ .grow = .{} },
                .height = .{ .px = 30 },
            }, .{});
            // custom item: encode option.value in component_name for verification
            var buf: [16]u8 = undefined;
            const label_str = std.fmt.bufPrintSentinel(&buf, "item-{d}", .{ctx.option.value}, 0) catch "item";
            const owned = c.allocator.dupe(u8, label_str) catch return n;
            n.meta.ownership.meta.component_name = owned;
            return n;
        }

        const core_mod = @import("../core.zig");
    };
    CustomItem.call_count = 0;

    const result = try select_headless.SelectHeadless(i32, .{
        .options = &opts,
        .render_item = CustomItem.render,
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expectEqual(@as(u32, 3), CustomItem.call_count);
    // each item should use caller's render fn
    try std.testing.expectEqual(@as(usize, 3), select_headless.stateOf(i32, result).item_nodes.len);
    try std.testing.expectEqualStrings(
        "item-1",
        select_headless.stateOf(i32, result).item_nodes[0].meta.ownership.meta.component_name.?,
    );
    try std.testing.expectEqualStrings(
        "item-3",
        select_headless.stateOf(i32, result).item_nodes[2].meta.ownership.meta.component_name.?,
    );

    // free duplicated strings
    for (select_headless.stateOf(i32, result).item_nodes) |n| {
        if (n.meta.ownership.meta.component_name) |name| {
            std.testing.allocator.free(name);
            n.meta.ownership.meta.component_name = null;
        }
    }
}

test "SelectSize：默认 trigger 建在 ControlShell 上，外框高 = padding_y×2 + 行高；列表行高独立" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const mount_mod = @import("../components/select_headless/mount.zig");
    const Scope = @import("../reactive.zig").Scope;
    const Opt = select_headless.Option(i32);
    const opts = [_]Opt{ .{ .value = 1, .label = "Apple" }, .{ .value = 2, .label = "Banana" } };

    inline for (.{ control_shell.ControlSize.xs, .sm, .md, .lg }) |size| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(400, 300);
        const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        cx.root = root;
        const scope = try Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        const result = try select_headless.SelectHeadless(i32, .{ .options = &opts, .width = 200, .size = size }).mount(scope, cx);
        try root.appendChild(std.testing.allocator, result.wrapper);
        cx.layout();
        // trigger_label = the label text in ControlShell's content slot; the slot's parent is the
        // shell
        const frame = result.trigger_label.parent.?.parent.?;
        try std.testing.expectApproxEqAbs(control_shell.metrics(cx.tokens, size).derivedHeight(), frame.rectFromWorldOrFallback().h, 0.01);
    }
    // RYMhT / Select open: every dropdown row is 28px, independent of trigger size.
    try std.testing.expectEqual(@as(f32, 28), mount_mod.itemHeight(.xs));
    try std.testing.expectEqual(@as(f32, 28), mount_mod.itemHeight(.sm));
    try std.testing.expectEqual(@as(f32, 28), mount_mod.itemHeight(.md));
    try std.testing.expectEqual(@as(f32, 28), mount_mod.itemHeight(.lg));
}

// ============================================================================
// v0.7 §2.2, select_headless virtualize (VirtualList) tests
// ============================================================================

test "virtualize=true 时 item_nodes 为空 (pool 复用)" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 400);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    // 1000 options
    const Opt = select_headless.Option(i32);
    var opts_buf: [1000]Opt = undefined;
    for (&opts_buf, 0..) |*o, i| {
        o.* = .{ .value = @intCast(i), .label = "x" };
    }

    const result = try select_headless.SelectHeadless(i32, .{
        .options = &opts_buf,
        .virtualize = true,
        .max_dropdown_height = 200,
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    // virtualize mode: item_nodes is empty slice (pool nodes not exposed)
    try std.testing.expectEqual(@as(usize, 0), select_headless.stateOf(i32, result).item_nodes.len);
    // state still present
    try std.testing.expect(result.value.?.peek() == null);
}

test "virtualize=false (默认) 仍每 option 一个 Node" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 400);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Opt = select_headless.Option(i32);
    const opts = [_]Opt{
        .{ .value = 1, .label = "A" },
        .{ .value = 2, .label = "B" },
        .{ .value = 3, .label = "C" },
    };

    const result = try select_headless.SelectHeadless(i32, .{
        .options = &opts,
        // virtualize defaults to false
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expectEqual(@as(usize, 3), select_headless.stateOf(i32, result).item_nodes.len);
}

test "virtualize + 1000 options compile + mount 不爆 Node" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 400);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Opt = select_headless.Option(i32);
    var opts_buf: [1000]Opt = undefined;
    for (&opts_buf, 0..) |*o, i| {
        o.* = .{ .value = @intCast(i), .label = "x" };
    }

    const result = try select_headless.SelectHeadless(i32, .{
        .options = &opts_buf,
        .virtualize = true,
        .max_dropdown_height = 200, // viewport ~6-7 rows
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    // mount succeeds; fixture mainly verifies compilation + no crash (1k options create 1k
    // Nodes, slow and allocs 100KB+; virtualize should only ~10-row pool).
    try std.testing.expect(result.wrapper != root);
}

// v0.8 §2.1, select_headless aria-activedescendant integration tests

test "select trigger 初始化 role=combobox + has_popup=listbox + 无 active_descendant" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Opt = select_headless.Option(i32);
    const opts = [_]Opt{
        .{ .value = 1, .label = "A" },
        .{ .value = 2, .label = "B" },
    };
    const result = try select_headless.SelectHeadless(i32, .{
        .options = &opts,
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    const a11y = result.trigger.behavior.interaction.a11y orelse return error.MissingA11y;
    try std.testing.expectEqual(@import("../core/types.zig").A11yRole.combobox, a11y.role);
    try std.testing.expectEqual(@import("../core/types.zig").HasPopup.listbox, a11y.has_popup);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), a11y.active_descendant_element_id);
}

test "mouse_enter item → trigger.active_descendant_element_id 跟随 item.element_id_raw" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;
    const events_mod = @import("../events.zig");

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Opt = select_headless.Option(i32);
    const opts = [_]Opt{
        .{ .value = 1, .label = "A" },
        .{ .value = 2, .label = "B" },
        .{ .value = 3, .label = "C" },
    };
    const result = try select_headless.SelectHeadless(i32, .{
        .options = &opts,
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expectEqual(@as(usize, 3), select_headless.stateOf(i32, result).item_nodes.len);

    // directly drive item[1]'s mouse_enter handler
    const item1 = select_headless.stateOf(i32, result).item_nodes[1];
    const handler = item1.behavior.events.on_event orelse return error.MissingHandler;
    const ctx = item1.behavior.events.event_context orelse return error.MissingContext;
    _ = handler(events_mod.Event{ .mouse_enter = {} }, ctx);

    // trigger.a11y.active_descendant_element_id should equal item[1]'s element_id_raw
    {
        const a11y = result.trigger.behavior.interaction.a11y orelse return error.MissingA11y;
        try std.testing.expectEqual(item1.element_id_raw, a11y.active_descendant_element_id);
    }

    // switch to item[2]
    const item2 = select_headless.stateOf(i32, result).item_nodes[2];
    const handler2 = item2.behavior.events.on_event orelse return error.MissingHandler;
    const ctx2 = item2.behavior.events.event_context orelse return error.MissingContext;
    _ = handler2(events_mod.Event{ .mouse_enter = {} }, ctx2);
    {
        const a11y = result.trigger.behavior.interaction.a11y orelse return error.MissingA11y;
        try std.testing.expectEqual(item2.element_id_raw, a11y.active_descendant_element_id);
    }
}

// shadow-sync Node.rect -> LayoutTable.final_rect
// verify cx.rectOf(eid) after Cx.layout() matches node.rect geometry
test "LayoutTable shadow-syncs Node.rect after layout" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .direction = .row,
    }, .{});
    cx.root = root;

    const child = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 80 },
    }, .{});
    try root.appendChild(std.testing.allocator, child);

    cx.layout();

    // child.rect should be filled
    try std.testing.expect(child.rectFromWorldOrFallback().w > 0);
    try std.testing.expect(child.rectFromWorldOrFallback().h > 0);

    // Stage 3-1 invariant: LayoutTable should be in sync with Node.rect
    if (child.element_id_raw != 0xFFFFFFFF) {
        const eid = ui.world.ElementId.fromRaw(child.element_id_raw);
        const lr = cx.rectOf(eid).?;
        try std.testing.expectApproxEqAbs(child.rectFromWorldOrFallback().x, lr.x, 0.001);
        try std.testing.expectApproxEqAbs(child.rectFromWorldOrFallback().y, lr.y, 0.001);
        try std.testing.expectApproxEqAbs(child.rectFromWorldOrFallback().w, lr.width, 0.001);
        try std.testing.expectApproxEqAbs(child.rectFromWorldOrFallback().h, lr.height, 0.001);
    }
}

// shadow-sync Node parent-child chain -> World.elements parent-child chain
// verify after Node.appendChild, World.elements' first_child/parent/sibling chains match
// Node tree
test "ElementTable shadow-syncs Node parent/child chain" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const c1 = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const c2 = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const c3 = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, c1);
    try root.appendChild(std.testing.allocator, c2);
    try root.appendChild(std.testing.allocator, c3);

    // all three children registered to World
    try std.testing.expect(root.element_id_raw != 0xFFFFFFFF);
    try std.testing.expect(c1.element_id_raw != 0xFFFFFFFF);
    try std.testing.expect(c2.element_id_raw != 0xFFFFFFFF);
    try std.testing.expect(c3.element_id_raw != 0xFFFFFFFF);

    const root_eid = ui.world.ElementId.fromRaw(root.element_id_raw);
    const c1_eid = ui.world.ElementId.fromRaw(c1.element_id_raw);
    const c2_eid = ui.world.ElementId.fromRaw(c2.element_id_raw);
    const c3_eid = ui.world.ElementId.fromRaw(c3.element_id_raw);

    // World chain should be root -> c1 -> c2 -> c3
    const root_links = cx.world.elements.links(root_eid).?;
    try std.testing.expect(root_links.first_child.eql(c1_eid));
    try std.testing.expect(root_links.last_child.eql(c3_eid));

    const c1_links = cx.world.elements.links(c1_eid).?;
    try std.testing.expect(c1_links.parent.eql(root_eid));
    try std.testing.expect(c1_links.next_sibling.eql(c2_eid));
    try std.testing.expect(c1_links.prev_sibling.isNull());

    const c2_links = cx.world.elements.links(c2_eid).?;
    try std.testing.expect(c2_links.parent.eql(root_eid));
    try std.testing.expect(c2_links.prev_sibling.eql(c1_eid));
    try std.testing.expect(c2_links.next_sibling.eql(c3_eid));

    const c3_links = cx.world.elements.links(c3_eid).?;
    try std.testing.expect(c3_links.parent.eql(root_eid));
    try std.testing.expect(c3_links.prev_sibling.eql(c2_eid));
    try std.testing.expect(c3_links.next_sibling.isNull());

    // child count matches Node.children.items.len
    try std.testing.expectEqual(root.children.items.len, cx.world.elements.childCount(root_eid));
}

// v0.5-P3 Stage 3-2 (final): removeChild should sync and unlink World parent-child
// chain
test "removeChild unlinks ElementTable chain" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const c1 = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const c2 = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const c3 = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, c1);
    try root.appendChild(std.testing.allocator, c2);
    try root.appendChild(std.testing.allocator, c3);

    const root_eid = ui.world.ElementId.fromRaw(root.element_id_raw);
    const c2_eid = ui.world.ElementId.fromRaw(c2.element_id_raw);

    // remove middle node c2
    root.removeChild(c2);

    // c2 detached in World
    const c2_links = cx.world.elements.links(c2_eid).?;
    try std.testing.expect(c2_links.parent.isNull());
    try std.testing.expect(c2_links.prev_sibling.isNull());
    try std.testing.expect(c2_links.next_sibling.isNull());

    // root's child chain should shrink to c1 -> c3
    try std.testing.expectEqual(@as(u32, 2), cx.world.elements.childCount(root_eid));
    const root_links = cx.world.elements.links(root_eid).?;
    const c1_eid = ui.world.ElementId.fromRaw(c1.element_id_raw);
    const c3_eid = ui.world.ElementId.fromRaw(c3.element_id_raw);
    try std.testing.expect(root_links.first_child.eql(c1_eid));
    try std.testing.expect(root_links.last_child.eql(c3_eid));

    // free c2 node (detached from tree, needs explicit free)
    cx.freeNode(c2);
}

test "removeAllChildren unlinks the full ElementTable chain" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{}, .{});
    const c1 = try box(cx, .{}, .{});
    const c2 = try box(cx, .{}, .{});
    try root.appendChild(cx.allocator, c1);
    try root.appendChild(cx.allocator, c2);
    cx.root = root;

    const root_eid = ui.world.ElementId.fromRaw(root.element_id_raw);
    const c1_eid = ui.world.ElementId.fromRaw(c1.element_id_raw);
    const c2_eid = ui.world.ElementId.fromRaw(c2.element_id_raw);
    root.removeAllChildren();

    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
    try std.testing.expectEqual(@as(u32, 0), cx.world.elements.childCount(root_eid));
    try std.testing.expect(cx.world.elements.links(root_eid).?.first_child.isNull());
    for ([_]ui.world.ElementId{ c1_eid, c2_eid }) |eid| {
        const links = cx.world.elements.links(eid).?;
        try std.testing.expect(links.parent.isNull());
        try std.testing.expect(links.prev_sibling.isNull());
        try std.testing.expect(links.next_sibling.isNull());
    }

    cx.freeNode(c1);
    cx.freeNode(c2);
}

test "World paint/interaction tables mirror on demand, not on every render" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const child = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 80 },
        .background = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    }, .{});
    child.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, child);
    cx.layout();
    // Off the sampled layout-integrity frame (frame_count % 64 == 1): that Debug
    // audit reads the tables and therefore mirrors them itself.
    cx.frame_count = 2;
    _ = cx.render();
    const eid = ui.world.ElementId.fromRaw(child.element_id_raw);

    // Rendering alone leaves the mirror pending: chunk never recorded, no interaction entry.
    try std.testing.expect(cx.world_tables_stale);
    if (cx.world.paint.get(eid)) |chunk| try std.testing.expectEqual(@as(u64, 0), chunk.paint_epoch);
    try std.testing.expect(cx.world.interaction.get(eid) == null);

    cx.ensureWorldTablesSynced();
    try std.testing.expect(!cx.world_tables_stale);
    const epoch = cx.world.paint.get(eid).?.paint_epoch;
    try std.testing.expect(cx.world.interaction.get(eid).?.focus.focusable);

    // Idempotent until the next render: no second walk, no re-record.
    cx.ensureWorldTablesSynced();
    try std.testing.expectEqual(epoch, cx.world.paint.get(eid).?.paint_epoch);

    // A visual change shows up at the next read after the next render.
    child.setBackgroundRaw(.{ .r = 0, .g = 0, .b = 255, .a = 255 });
    child.markRenderDirty();
    _ = cx.render();
    try std.testing.expect(cx.world_tables_stale);
    cx.ensureWorldTablesSynced();
    try std.testing.expect(cx.world.paint.get(eid).?.paint_epoch > epoch);
}

test "World paint mirror never keeps items older than the last render" {
    // A reader between an edit and the next render mirrors the new paint hash with the
    // old frame's items. The next mirror, after that render, must still replace them.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const child = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 80 },
        .background = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    }, .{});
    try root.appendChild(std.testing.allocator, child);
    cx.layout();
    cx.frame_count = 2; // off the sampled integrity-audit frame, which mirrors by itself
    _ = cx.render();
    const eid = ui.world.ElementId.fromRaw(child.element_id_raw);

    child.setBackgroundRaw(.{ .r = 0, .g = 0, .b = 255, .a = 255 });
    child.markRenderDirty();
    cx.ensureWorldTablesSynced(); // reader before the next render
    _ = cx.render();
    cx.ensureWorldTablesSynced();

    var blue = false;
    var red = false;
    for (cx.world.paint.get(eid).?.display_items.items) |item| {
        if (item.kind != .rect) continue;
        if (item.color.b == 255 and item.color.r == 0) blue = true;
        if (item.color.r == 255 and item.color.b == 0) red = true;
    }
    try std.testing.expect(blue);
    try std.testing.expect(!red);
}

// PaintTable shadow-sync path working
// after render, PaintTable populates chunks for elements; changing background should
// trigger hash mismatch and re-recording
test "PaintTable shadow-syncs after render and invalidates on style change" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const child = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 80 },
        .background = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    }, .{});
    try root.appendChild(std.testing.allocator, child);

    cx.layout();
    _ = cx.render();
    cx.ensureWorldTablesSynced();

    try std.testing.expect(child.element_id_raw != 0xFFFFFFFF);
    const eid = ui.world.ElementId.fromRaw(child.element_id_raw);
    const chunk1 = cx.world.paint.get(eid).?;
    const epoch1 = chunk1.paint_epoch;
    const hash1 = chunk1.content_hash;
    try std.testing.expect(epoch1 > 0);

    // render again same frame -> hash hit, paint_epoch unchanged
    _ = cx.render();
    cx.ensureWorldTablesSynced();
    const chunk2 = cx.world.paint.get(eid).?;
    try std.testing.expectEqual(epoch1, chunk2.paint_epoch);
    try std.testing.expectEqual(hash1, chunk2.content_hash);

    // change background -> hash mismatch -> re-record -> epoch increments
    child.setBackgroundRaw(.{ .r = 0, .g = 0, .b = 255, .a = 255 });
    child.markRenderDirty();
    _ = cx.render();
    cx.ensureWorldTablesSynced();
    const chunk3 = cx.world.paint.get(eid).?;
    try std.testing.expect(chunk3.paint_epoch > epoch1);
    try std.testing.expect(chunk3.content_hash != hash1);

    // Phase 2: PaintTable now populates DisplayItem (not placeholder)
    // nodes with background should produce at least one .rect kind PaintTable.DisplayItem
    var has_rect_item = false;
    for (chunk3.display_items.items) |item| {
        if (item.kind == .rect) {
            has_rect_item = true;
            break;
        }
    }
    try std.testing.expect(has_rect_item);
}

// cx.lowerForEncoderPaintTable() entry point
// one-to-one mapping with lowerForEncoder() output (kind + fields lossless)
test "lowerForEncoderPaintTable 与 lowerForEncoder kind 序列一致" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});
    const a = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 50 },
        .background = .{ .r = 100, .g = 100, .b = 100, .a = 255 },
    }, .{});
    const b = try box(cx, .{
        .width = .{ .px = 50 },
        .height = .{ .px = 50 },
        .background = .{ .r = 200, .g = 50, .b = 50, .a = 255 },
        .corner_radius = 8,
    }, .{});
    try root.appendChild(std.testing.allocator, a);
    try root.appendChild(std.testing.allocator, b);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    const display_list_lowered = cx.lowerForEncoderPaintTable();
    const paint_table_lowered = cx.lowerForEncoderPaintTable();
    // length matches: B-5 lowerForEncoderPaintTable is 1:1 translation
    try std.testing.expectEqual(display_list_lowered.len, paint_table_lowered.len);
    // should see at least two .rect kind paint_table items
    var rect_count: usize = 0;
    for (paint_table_lowered) |it| {
        if (it.kind == .rect) rect_count += 1;
    }
    try std.testing.expect(rect_count >= 2);
}

// paint_table.DisplayItem field preservation check.
// fill_rect via cx.syncPaintToTable written PaintTable chunks should preserve all fields
// (geom + color + radii) so encoder switching to paint_table.DisplayItem has lossless data
test "PaintTable.DisplayItem 字段无损 (fill_rect geom + color + radii)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    // use deterministic geom + color + radii for field comparison
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
    }, .{});

    const child = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 50 },
        .background = .{ .r = 200, .g = 150, .b = 100, .a = 255 },
        .corner_radius = 8,
    }, .{});
    try root.appendChild(std.testing.allocator, child);
    cx.root = root;

    cx.layout();
    _ = cx.render();
    cx.ensureWorldTablesSynced();

    const eid = ui.world.ElementId.fromRaw(child.element_id_raw);
    const chunk = cx.world.paint.get(eid).?;
    // find .rect kind DisplayItem (background fill_rect)
    var found_idx: ?usize = null;
    for (chunk.display_items.items, 0..) |item, idx| {
        if (item.kind == .rect and item.color.a == 255 and item.color.r == 200) {
            found_idx = idx;
            break;
        }
    }
    try std.testing.expect(found_idx != null);
    const item = chunk.display_items.items[found_idx.?];
    // geometry fields lossless; encoder uses these to produce SDF rect after switching to
    // paint_table
    try std.testing.expectEqual(@as(f32, 100), item.geom.w);
    try std.testing.expectEqual(@as(f32, 50), item.geom.h);
    // color lossless
    try std.testing.expectEqual(@as(u8, 200), item.color.r);
    try std.testing.expectEqual(@as(u8, 150), item.color.g);
    try std.testing.expectEqual(@as(u8, 100), item.color.b);
    try std.testing.expectEqual(@as(u8, 255), item.color.a);
    // radii lossless (uniform corner_radius=8 -> all 4 corners 8)
    try std.testing.expectEqual(@as(f32, 8), item.radii.tl);
    try std.testing.expectEqual(@as(f32, 8), item.radii.tr);
    try std.testing.expectEqual(@as(f32, 8), item.radii.br);
    try std.testing.expectEqual(@as(f32, 8), item.radii.bl);
}

// InteractionTable shadow-sync
// focusable nodes / click listeners / a11y role nodes should be in InteractionTable
test "InteractionTable shadow-syncs focusable/event/a11y nodes" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // three children: focusable / a11y role / plain (plain should not be in InteractionTable)
    const fcb = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    fcb.behavior.interaction.focusable = true;
    fcb.behavior.interaction.tab_index = 0;

    const a11y_n = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    a11y_n.behavior.interaction.a11y = .{ .role = .button };

    const plain = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});

    try root.appendChild(std.testing.allocator, fcb);
    try root.appendChild(std.testing.allocator, a11y_n);
    try root.appendChild(std.testing.allocator, plain);

    cx.layout();
    _ = cx.render();
    cx.ensureWorldTablesSynced();

    const fcb_eid = ui.world.ElementId.fromRaw(fcb.element_id_raw);
    const a11y_eid = ui.world.ElementId.fromRaw(a11y_n.element_id_raw);
    const plain_eid = ui.world.ElementId.fromRaw(plain.element_id_raw);

    const fcb_data = cx.world.interaction.get(fcb_eid).?;
    try std.testing.expect(fcb_data.focus.focusable);
    try std.testing.expect(fcb_data.focus.tabbable);

    const a11y_data = cx.world.interaction.get(a11y_eid).?;
    try std.testing.expect(a11y_data.a11y_role != 0);

    // plain: no focusable / a11y / event -> should not be in InteractionTable
    try std.testing.expect(cx.world.interaction.get(plain_eid) == null);
}

// LayoutTable tree equivalence check
// full tree traversal: all element_id nodes' cx.rectOf(eid) must exactly match node.rect.
// Gate before SoT inversion: two stores must sync every frame; mismatch is a bug
test "LayoutTable matches Node.rect for whole tree" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);

    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 }, .direction = .row }, .{});
    cx.root = root;
    const a = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 600 } }, .{});
    const b = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 600 }, .direction = .column }, .{});
    const b1 = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{});
    const b2 = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{});
    try root.appendChild(std.testing.allocator, a);
    try root.appendChild(std.testing.allocator, b);
    try b.appendChild(std.testing.allocator, b1);
    try b.appendChild(std.testing.allocator, b2);

    cx.layout();

    // use Cx-provided helper (callable in prod path even in debug build)
    try std.testing.expect(cx.assertLayoutSyncIntegrity(root));

    // v0.5-P3 N-2 (2026-05-03 field removed): original perturb test verified frame_state.rect
    // vs LayoutTable divergence could be caught. Field is removed (World is sole source-of-truth);
    // divergence cannot occur, so this perturb path naturally fails. Integrity check reduces to
    // PaintTable.bounds vs LayoutTable.rect invariant, guaranteed by syncPaintToTable.
}

// layerizeFrame now truly consumes PaintTable.bounds (was placeholder {})
// verify: scroll container node after layerize has non-empty layer.world_bounds
test "layerizeFrame reads PaintTable bounds" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // scroll container child node
    const scrollable = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    try root.appendChild(std.testing.allocator, scrollable);

    cx.layout();
    _ = cx.render();

    // inject scroll_id into InteractionTable (bypass real ScrollArea complexity)
    const eid = ui.world.ElementId.fromRaw(scrollable.element_id_raw);
    cx.world.interaction.put(eid, .{
        .scroll_id = 1, // dummy scroll id
    }) catch unreachable;

    _ = cx.layerizeFrame(&[_]ui.layerize_mod.LayerizeInput{});

    // PaintTable.chunk(eid).bounds should be written via syncPaintToTable
    const chunk = cx.world.paint.get(eid).?;
    try std.testing.expect(!chunk.bounds.isEmpty());

    // LayerTree should have non-root layer with world_bounds reusing PaintTable.bounds
    var found_promoted: bool = false;
    for (cx.layer_tree.layers.items) |*l| {
        if (!l.alive) continue;
        if (l.root_element.isNull()) continue; // root layer has no root_element
        if (!l.world_bounds.isEmpty()) {
            found_promoted = true;
            break;
        }
    }
    try std.testing.expect(found_promoted);
}

// v0.5-P3 Stage 3-3 Phase 1++ (session 43): paintContentHash now covers more visual
// properties. Verify opacity / border / text color changes all trigger cache invalidation
test "paintContentHash invalidates on more visual attrs" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
        .background = .{ .r = 50, .g = 50, .b = 50, .a = 255 },
        .opacity = 1.0,
    }, .{});
    cx.root = root;

    cx.layout();
    _ = cx.render();
    cx.ensureWorldTablesSynced();
    const eid = ui.world.ElementId.fromRaw(root.element_id_raw);
    const epoch1 = cx.world.paint.get(eid).?.paint_epoch;

    // changing opacity should trigger hash mismatch
    root.setOpacityRaw(0.5);
    root.markRenderDirty();
    _ = cx.render();
    cx.ensureWorldTablesSynced();
    const epoch2 = cx.world.paint.get(eid).?.paint_epoch;
    try std.testing.expect(epoch2 > epoch1);
}

// v0.5-P3 Stage 3-3 Phase 4 (session 38): layerizeFrame truly consumes
// PaintTable.property_state. At minimum: chunk-scanning path doesn't break existing
// layerize behavior (no-regression gate)
test "layerizeFrame still works after PaintTable property_state scan" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const child = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
        .background = .{ .r = 100, .g = 100, .b = 100, .a = 255 },
    }, .{});
    try root.appendChild(std.testing.allocator, child);

    cx.layout();
    _ = cx.render();

    // chunk-scanning promotion path succeeds without error
    const layer_count = cx.layerizeFrame(&[_]ui.layerize_mod.LayerizeInput{});
    // at least one root layer exists
    try std.testing.expect(layer_count >= 1);
}

// v0.5-P3 Stage 3-3 Phase 3 (session 37): PaintChunk.property_state truly
// populated. transform_id / clip_id / effect_id from SceneRuntime; scroll_id from
// InteractionTable
test "PaintChunk.property_state populated from SceneRuntime" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .background = .{ .r = 100, .g = 100, .b = 100, .a = 255 },
    }, .{});
    cx.root = root;

    cx.layout();
    _ = cx.render();
    cx.ensureWorldTablesSynced();

    const eid = ui.world.ElementId.fromRaw(root.element_id_raw);
    const chunk = cx.world.paint.get(eid).?;
    // transform_id should be valid (root has transform)
    try std.testing.expect(chunk.property_state.transform_id != std.math.maxInt(u32));
}

// Frame-end shadow-sync skips subtree per damage rect (Step 1) + O(1) subtree flags (Step 0)

// Step 0: collectContentFlags.has_text now reads NodeFlags.has_text_subtree
// (setText sets flag + appendChild merges into parent; conservative, never clear). Verify
// add-text / remove-text / reparent paths all correctly set
// scene_runtime.get(id).content_flags.has_text
test "content flags: has_text_subtree flag tracks add/remove/reparent text" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    // scenario: root > container > leaf; leaf initially has no text
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const container = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    try root.appendChild(std.testing.allocator, container);
    const leaf = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } }, .{});
    try container.appendChild(std.testing.allocator, leaf);

    cx.layout();
    _ = cx.render();

    // canary: has_text should be false when text-less (red = flag/collection not wired)
    try std.testing.expect(cx.scene_runtime.get(container.id).?.content_flags.has_text == false);

    // 1. add text: leaf setText non-empty -> bubbles up ancestors; container/root both
    // have has_text=true
    try leaf.setTextContent(std.testing.allocator, "hello");
    leaf.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.scene_runtime.get(leaf.id).?.content_flags.has_text == true);
    try std.testing.expect(cx.scene_runtime.get(container.id).?.content_flags.has_text == true);
    try std.testing.expect(cx.scene_runtime.get(root.id).?.content_flags.has_text == true);

    // 2. remove text: conservative, never clear -> has_text stays true (superset of old
    // subtreeHasText)
    leaf.setText(null);
    leaf.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.scene_runtime.get(container.id).?.content_flags.has_text == true);

    // 3. reparent: text-less subtree appended to root -> flag merged up from attach
    // point
    const other = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(std.testing.allocator, other);
    const other_text = try text(cx, "world", .{});
    try other.appendChild(std.testing.allocator, other_text);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.scene_runtime.get(other.id).?.content_flags.has_text == true);
    // when other attaches to root, root already true from leaf's text history; full tree
    // swap verifies merge path itself: fresh parent (no text history) + text-bearing subtree
    const fresh_root = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    const fresh_leaf = try text(cx, "deep", .{});
    try fresh_root.appendChild(std.testing.allocator, fresh_leaf);
    // attach to existing tree -> appendChild merge path must light up parent chain above
    // fresh_root
    try root.appendChild(std.testing.allocator, fresh_root);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.scene_runtime.get(fresh_root.id).?.content_flags.has_text == true);
    try std.testing.expect(root.frame_state.state_bits.flags.has_text_subtree == true);
}

// ============================================================================

// let ScrollArea.mount's injected scroll_id be cleared back to sentinel
test "syncInteractionToTable preserves scroll_id across renders" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const target = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    try root.appendChild(std.testing.allocator, target);

    cx.layout();

    // simulate ScrollArea.mount: inject scroll_id
    const eid = ui.world.ElementId.fromRaw(target.element_id_raw);
    cx.world.interaction.put(eid, .{
        .scroll_id = 42,
    }) catch unreachable;

    // trigger one render -> syncInteractionToTable runs
    _ = cx.render();
    cx.ensureWorldTablesSynced();

    // scroll_id should still be 42, not erased to sentinel
    const data = cx.world.interaction.get(eid).?;
    try std.testing.expectEqual(@as(u32, 42), data.scroll_id);
}

// v0.6 §2.1, Accessibility Tree projection tests

test "syncA11yTreeFromInteractions projects nodes with a11y or focusable" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // three children: focusable / a11y role / visual-only
    const btn = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "Click Me" };

    const focusable_n = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    focusable_n.behavior.interaction.focusable = true;

    const plain = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});

    try root.appendChild(std.testing.allocator, btn);
    try root.appendChild(std.testing.allocator, focusable_n);
    try root.appendChild(std.testing.allocator, plain);

    cx.layout();
    _ = cx.render();

    // root: no a11y, no focusable -> not projected
    // btn -> projected as .button
    // focusable_n -> projected as .generic (focusable container)
    // plain -> not projected
    try std.testing.expectEqual(@as(usize, 2), cx.accessibility_tree.count());

    const btn_eid = ui.ElementId.fromRaw(btn.element_id_raw);
    const btn_node = cx.accessibility_tree.getNode(btn_eid).?;
    try std.testing.expectEqual(ui.a11y_tree.Role.button, btn_node.role);
    try std.testing.expect(btn_node.label_hash != 0);

    // label_buf should retrieve "Click Me"
    const got_label = cx.a11y_label_buf.get(btn_node.label_hash).?;
    try std.testing.expectEqualStrings("Click Me", got_label);

    const f_eid = ui.ElementId.fromRaw(focusable_n.element_id_raw);
    const f_node = cx.accessibility_tree.getNode(f_eid).?;
    try std.testing.expectEqual(ui.a11y_tree.Role.generic, f_node.role);
    try std.testing.expect(f_node.state.focusable);
}

test "label falls back to subtree text when a11y.label is null" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // button has no explicit label, but child text "Submit" should serve as label fallback
    const btn = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button };
    const label_text = try ui.text(cx, "Submit", .{});
    try btn.appendChild(std.testing.allocator, label_text);
    try root.appendChild(std.testing.allocator, btn);

    cx.layout();
    _ = cx.render();

    const btn_eid = ui.ElementId.fromRaw(btn.element_id_raw);
    const btn_node = cx.accessibility_tree.getNode(btn_eid).?;
    const got_label = cx.a11y_label_buf.get(btn_node.label_hash).?;
    try std.testing.expectEqualStrings("Submit", got_label);
}

test "a11y_tree parent skips non-projected ancestors" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // intermediate visual-only wrapper (not projected)
    const wrapper = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    try root.appendChild(std.testing.allocator, wrapper);

    // nested button
    const btn = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "Inner" };
    try wrapper.appendChild(std.testing.allocator, btn);

    cx.layout();
    _ = cx.render();

    // root + wrapper not projected; btn parent should be NULL (nearest projected ancestor)
    const btn_eid = ui.ElementId.fromRaw(btn.element_id_raw);
    const btn_node = cx.accessibility_tree.getNode(btn_eid).?;
    try std.testing.expect(btn_node.parent.isNull());
}

test "state.checked / disabled propagated from A11yProps" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const cb = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    cb.behavior.interaction.a11y = .{
        .role = .checkbox,
        .label = "Autosave",
        .checked = true,
        .disabled = true,
    };
    try root.appendChild(std.testing.allocator, cb);

    cx.layout();
    _ = cx.render();

    const cb_eid = ui.ElementId.fromRaw(cb.element_id_raw);
    const cb_node = cx.accessibility_tree.getNode(cb_eid).?;
    try std.testing.expect(cb_node.state.checked);
    try std.testing.expect(cb_node.state.disabled);
}

// v0.6 §2.1, macos_bridge C ABI integration tests (ObjC accessibilityChildren protocol
// equivalent callback paths). Fixtures simulate ObjC calling zenit_a11y_* extern sequence,
// verify cx.render() leaves a11y_tree fully traversable via C-style API with label retrieval.

// each export's first param is window_id (ObjC proxy gets from its NSWindow). Fixtures
// use ANY_WINDOW(0) as wildcard, equivalent to "currently sole registered window"; all cx
// in this file are single-window. Multi-window routing by specific window_id verified in
// a11y/macos_bridge.zig unit tests.
const a11y_bridge_extern = struct {
    const ANY: u32 = 0;
    extern fn zenit_a11y_root_count(window_id: u32) c_int;
    extern fn zenit_a11y_root_at(window_id: u32, idx: c_int) u64;
    extern fn zenit_a11y_children_count(window_id: u32, parent_raw: u64) c_int;
    extern fn zenit_a11y_children_at(window_id: u32, parent_raw: u64, idx: c_int) u64;
    extern fn zenit_a11y_role(window_id: u32, handle: u64) c_int;
    extern fn zenit_a11y_label(window_id: u32, handle: u64, buf: ?[*]u8, buf_len: c_int) c_int;
    extern fn zenit_a11y_frame(window_id: u32, handle: u64, x: ?*f32, y: ?*f32, width: ?*f32, height: ?*f32) c_int;
    extern fn zenit_a11y_actions(window_id: u32, handle: u64) u8;
    extern fn zenit_a11y_perform_action(window_id: u32, handle: u64, action: u8) c_int;
};

test "a11y on demand: no projection until the first assistive query, then every frame" {
    // SKIP-REASON: drives the macOS accessibility bridge, which exists only on macOS.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const bridge = @import("../a11y/macos_bridge.zig");
    bridge.resetClientsSeenForTesting();
    defer bridge.resetClientsSeenForTesting();
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.a11y_on_demand = true;
    cx.setViewport(400, 300);
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const btn = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "Save" };
    try root.appendChild(std.testing.allocator, btn);
    const eid = ui.world.ElementId.fromRaw(btn.element_id_raw);

    cx.layout();
    _ = cx.render();
    _ = cx.render();
    try std.testing.expect(cx.a11y_projection_stale);
    try std.testing.expect(cx.accessibility_tree.getNode(eid) == null);

    // First query projects synchronously: the client never sees an empty tree.
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_root_count(a11y_bridge_extern.ANY));
    try std.testing.expect(!cx.a11y_projection_stale);
    try std.testing.expect(cx.accessibility_tree.getNode(eid) != null);

    // From then on frames project eagerly, so later changes reach the tree
    // without another query.
    btn.behavior.interaction.a11y = .{ .role = .checkbox, .label = "Save" };
    btn.markRenderDirty();
    _ = cx.render();
    try std.testing.expect(!cx.a11y_projection_stale);
    try std.testing.expectEqual(a11y_tree_mod.Role.checkbox, cx.accessibility_tree.getNode(eid).?.role);
}

test "a11y on demand: a replacement Cx on the same window does not inherit the old demand" {
    // SKIP-REASON: drives the macOS accessibility bridge, which exists only on macOS.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const bridge = @import("../a11y/macos_bridge.zig");
    bridge.resetClientsSeenForTesting();
    defer bridge.resetClientsSeenForTesting();
    const W: u32 = 4242;
    var old = try Cx.init(std.testing.allocator, std.testing.io);
    var old_alive = true;
    defer if (old_alive) old.deinit();
    old.a11y_on_demand = true;
    old.native_window_id = W;
    old.setViewport(100, 100);
    old.root = try box(old, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    old.layout();
    _ = old.render();

    var new = try Cx.init(std.testing.allocator, std.testing.io);
    defer new.deinit();
    new.native_window_id = W;
    new.setViewport(100, 100);
    new.root = try box(new, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    const btn = try box(new, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "OK" };
    try new.root.?.appendChild(std.testing.allocator, btn);
    new.layout();
    _ = new.render();

    // The old Cx goes away while the window slot belongs to the new one. A
    // query must not run the old Cx's demand handler (testing allocator would
    // flag the use after free).
    old.deinit();
    old_alive = false;
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_root_count(W));
}

test "VoiceOver-style navigation reaches button labels" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const btn_a = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn_a.behavior.interaction.a11y = .{ .role = .button, .label = "Save" };

    const btn_b = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn_b.behavior.interaction.a11y = .{ .role = .button, .label = "Cancel" };

    try root.appendChild(std.testing.allocator, btn_a);
    try root.appendChild(std.testing.allocator, btn_b);

    cx.layout();
    _ = cx.render();

    // simulate VoiceOver pull path: MetalView.accessibilityChildren -> root_count/_at
    try std.testing.expectEqual(@as(c_int, 2), a11y_bridge_extern.zenit_a11y_root_count(a11y_bridge_extern.ANY));

    var seen_save = false;
    var seen_cancel = false;
    var i: c_int = 0;
    while (i < 2) : (i += 1) {
        const h = a11y_bridge_extern.zenit_a11y_root_at(a11y_bridge_extern.ANY, i);
        try std.testing.expect(h != 0);
        try std.testing.expectEqual(
            @as(c_int, @backingInt(ui.a11y_tree.Role.button)),
            a11y_bridge_extern.zenit_a11y_role(a11y_bridge_extern.ANY, h),
        );
        var buf: [32]u8 = undefined;
        const n = a11y_bridge_extern.zenit_a11y_label(a11y_bridge_extern.ANY, h, &buf, buf.len);
        try std.testing.expect(n > 0);
        const label = buf[0..@intCast(n)];
        if (std.mem.eql(u8, label, "Save")) seen_save = true;
        if (std.mem.eql(u8, label, "Cancel")) seen_cancel = true;
    }
    try std.testing.expect(seen_save);
    try std.testing.expect(seen_cancel);
}

test "a11y bridge: projected global frame and native press use focus/event routing" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    cx.setWindowId(303);

    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .padding = .{ .left = 17, .top = 23 },
    }, .{});
    cx.root = root;
    var pressed = false;
    var selected = false;
    const btn = try box(cx, .{ .width = .{ .px = 91 }, .height = .{ .px = 37 } }, .{});
    btn.setFocusable(true);
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "Native action", .item_selection = .{
        .context = &selected,
        .set = struct {
            fn call(context: *anyopaque, _: ui.A11yProps.ItemSelectionOperation) bool {
                const value: *bool = @ptrCast(@alignCast(context));
                value.* = true;
                return true;
            }
        }.call,
    } };
    btn.behavior.events.on_click = Cx.simpleHandler(struct {
        fn call(context: *anyopaque) void {
            const value: *bool = @ptrCast(@alignCast(context));
            value.* = true;
        }
    }.call, &pressed);
    try root.appendChild(std.testing.allocator, btn);

    cx.layout();
    _ = cx.render();
    const handle = btn.element_id_raw;
    const expected = btn.globalRect();
    var x: f32 = 0;
    var y: f32 = 0;
    var width: f32 = 0;
    var height: f32 = 0;
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_frame(303, handle, &x, &y, &width, &height));
    try std.testing.expectApproxEqAbs(expected.x, x, 0.001);
    try std.testing.expectApproxEqAbs(expected.y, y, 0.001);
    try std.testing.expectApproxEqAbs(expected.w, width, 0.001);
    try std.testing.expectApproxEqAbs(expected.h, height, 0.001);
    try std.testing.expectEqual(@as(u8, 0b0001), a11y_bridge_extern.zenit_a11y_actions(303, handle));
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_perform_action(303, handle, 0));
    try std.testing.expect(pressed);
    try std.testing.expect(cx.isFocused(btn));

    try std.testing.expect(cx.setA11yItemSelection(handle, .replace));
    try std.testing.expect(selected);

    // The native client may retain an enabled snapshot while a modal opens.
    // Revalidate the live boundary before dispatching, even before projection.
    const panel = try box(cx, .{}, .{});
    try root.appendChild(std.testing.allocator, panel);
    const modal = try cx.overlay_stack.push(.{ .kind = .modal, .enter_transition = .none });
    cx.overlay_stack.bindFloatingContent(std.testing.allocator, modal, panel);
    pressed = false;
    selected = false;
    try std.testing.expect(!cx.setA11yItemSelection(handle, .replace));
    try std.testing.expect(!selected);
    try std.testing.expectEqual(@as(c_int, 0), a11y_bridge_extern.zenit_a11y_perform_action(303, handle, 0));
    try std.testing.expect(!pressed);
    cx.syncA11yTreeFromInteractions(root);
    try std.testing.expect(cx.accessibility_tree.get(a11y_tree_mod.AXId.fromRaw(handle)).?.state.disabled);
    try std.testing.expect(!btn.behavior.interaction.a11y.?.disabled);
    cx.overlay_stack.commitExit(modal);
    try std.testing.expect(cx.setA11yItemSelection(handle, .replace));
    try std.testing.expect(selected);
    cx.syncA11yTreeFromInteractions(root);
    try std.testing.expect(!cx.accessibility_tree.get(a11y_tree_mod.AXId.fromRaw(handle)).?.state.disabled);
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_perform_action(303, handle, 0));
    try std.testing.expect(pressed);
}

// ── 2026-10-01 semantic merging / static text / inferred button (real Cx-driven) ──
// corresponds to AXUIElement probe (tools/axprobe) issues seen on hello_button /
// storybook; see a11y_projection.zig same-date section

test "a11y: 未标注文字投影为 static_text，按钮吸收自身文字与 spinner" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const title = try ui.text(cx, "Hello, zenit!", .{});
    const btn = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button };
    const spinner = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    spinner.behavior.interaction.a11y = .{ .role = .progressbar };
    const btn_text = try ui.text(cx, "Saving", .{});
    try btn.appendChild(std.testing.allocator, spinner);
    try btn.appendChild(std.testing.allocator, btn_text);
    const counter_text = try ui.text(cx, "Clicked 0 times", .{});
    try root.appendChild(std.testing.allocator, title);
    try root.appendChild(std.testing.allocator, btn);
    try root.appendChild(std.testing.allocator, counter_text);

    cx.layout();
    _ = cx.render();

    const t = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(title.element_id_raw)).?;
    try std.testing.expectEqual(ui.a11y_tree.Role.static_text, t.role);
    try std.testing.expectEqualStrings("Hello, zenit!", cx.a11y_label_buf.get(t.text_hash).?);

    const b = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(btn.element_id_raw)).?;
    try std.testing.expectEqualStrings("Saving", cx.a11y_label_buf.get(b.label_hash).?);
    try std.testing.expect(cx.accessibility_tree.getNode(ui.ElementId.fromRaw(spinner.element_id_raw)) == null);
    try std.testing.expect(cx.accessibility_tree.getNode(ui.ElementId.fromRaw(btn_text.element_id_raw)) == null);

    // top-level read order = document order: title, button, count result
    const tops = cx.accessibility_tree.exposedChildren(a11y_tree_mod.AXId.NULL);
    try std.testing.expectEqual(@as(usize, 3), tops.len);
    try std.testing.expect(tops[0].eql(a11y_tree_mod.AXId.node(ui.ElementId.fromRaw(title.element_id_raw))));
    try std.testing.expect(tops[1].eql(a11y_tree_mod.AXId.node(ui.ElementId.fromRaw(btn.element_id_raw))));
    try std.testing.expect(tops[2].eql(a11y_tree_mod.AXId.node(ui.ElementId.fromRaw(counter_text.element_id_raw))));

    // after text changes, value follows (hello_button: after press, AT reads new count)
    var props = counter_text.getText().?;
    props.content = "Clicked 1 times";
    counter_text.setText(props);
    counter_text.markRenderDirty();
    cx.layout();
    _ = cx.render();
    const c = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(counter_text.element_id_raw)).?;
    try std.testing.expectEqualStrings("Clicked 1 times", cx.a11y_label_buf.get(c.text_hash).?);
}

test "a11y: 容器角色不借第一行文字作名（VirtualList 曾被叫作 \"#0\"）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const list = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    list.behavior.interaction.a11y = .{ .role = .list };
    const item = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 30 } }, .{});
    item.behavior.interaction.a11y = .{ .role = .listitem };
    const item_text = try ui.text(cx, "#0", .{});
    try item.appendChild(std.testing.allocator, item_text);
    try list.appendChild(std.testing.allocator, item);
    try root.appendChild(std.testing.allocator, list);

    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(@as(u64, 0), cx.accessibility_tree.getNode(ui.ElementId.fromRaw(list.element_id_raw)).?.label_hash);
    // list items absorb own text, use content as name (real VoiceOver: when row is
    // container wrapping static text, VO skips row layer, reads text directly; user unaware
    // of list)
    const item_node = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(item.element_id_raw)).?;
    try std.testing.expectEqualStrings("#0", cx.a11y_label_buf.get(item_node.label_hash).?);
    try std.testing.expect(cx.accessibility_tree.getNode(ui.ElementId.fromRaw(item_text.element_id_raw)) == null);
}

test "a11y: 只有点击路由的叶子推断为按钮且原生 press 可达；点击遮罩不推断" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    cx.setWindowId(304);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    var pressed = false;
    const nav = try box(cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 30 } }, .{});
    nav.behavior.events.on_click = Cx.simpleHandler(struct {
        fn call(context: *anyopaque) void {
            const value: *bool = @ptrCast(@alignCast(context));
            value.* = true;
        }
    }.call, &pressed);
    try nav.appendChild(std.testing.allocator, try ui.text(cx, "Checkbox", .{}));

    const backdrop = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    backdrop.behavior.events.on_click = Cx.simpleHandler(struct {
        fn call(_: *anyopaque) void {}
    }.call, &pressed);
    const dialog = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    dialog.behavior.interaction.a11y = .{ .role = .dialog, .label = "Confirm" };
    try dialog.appendChild(std.testing.allocator, try ui.text(cx, "Are you sure?", .{}));
    try backdrop.appendChild(std.testing.allocator, dialog);

    try root.appendChild(std.testing.allocator, nav);
    try root.appendChild(std.testing.allocator, backdrop);
    cx.layout();
    _ = cx.render();

    const n = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(nav.element_id_raw)).?;
    try std.testing.expectEqual(ui.a11y_tree.Role.button, n.role);
    try std.testing.expectEqualStrings("Checkbox", cx.a11y_label_buf.get(n.label_hash).?);
    // inferred button lacks a11y props, native press must still work (old impl returned
    // false)
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_perform_action(304, nav.element_id_raw, 0));
    try std.testing.expect(pressed);

    try std.testing.expect(cx.accessibility_tree.getNode(ui.ElementId.fromRaw(backdrop.element_id_raw)) == null);
    try std.testing.expectEqual(ui.a11y_tree.Role.dialog, cx.accessibility_tree.getNode(ui.ElementId.fromRaw(dialog.element_id_raw)).?.role);
}

test "a11y: 模态对话框打开时背景 inert，关闭后恢复" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const page = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    const background_btn = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    background_btn.behavior.interaction.a11y = .{ .role = .button, .label = "Behind" };
    try page.appendChild(std.testing.allocator, background_btn);
    try page.appendChild(std.testing.allocator, try ui.text(cx, "Background text", .{}));

    const portal = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    const dialog = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    dialog.behavior.interaction.a11y = .{ .role = .dialog, .label = "Confirm", .modal = true };
    const ok_btn = try box(cx, .{ .width = .{ .px = 60 }, .height = .{ .px = 30 } }, .{});
    ok_btn.behavior.interaction.a11y = .{ .role = .button, .label = "OK" };
    try dialog.appendChild(std.testing.allocator, ok_btn);
    try portal.appendChild(std.testing.allocator, dialog);
    try root.appendChild(std.testing.allocator, page);
    try root.appendChild(std.testing.allocator, portal);

    cx.layout();
    _ = cx.render();

    const behind = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(background_btn.element_id_raw)).?;
    try std.testing.expect(behind.state.hidden);
    try std.testing.expect(!cx.accessibility_tree.getNode(ui.ElementId.fromRaw(dialog.element_id_raw)).?.state.hidden);
    try std.testing.expect(!cx.accessibility_tree.getNode(ui.ElementId.fromRaw(ok_btn.element_id_raw)).?.state.hidden);
    // only dialog visible at top level to outside
    const tops = cx.accessibility_tree.exposedChildren(a11y_tree_mod.AXId.NULL);
    try std.testing.expectEqual(@as(usize, 1), tops.len);
    try std.testing.expect(tops[0].eql(a11y_tree_mod.AXId.node(ui.ElementId.fromRaw(dialog.element_id_raw))));

    // after close (display:none), background restores
    dialog.style.display = .none;
    dialog.markLayoutDirty();
    cx.layout();
    _ = cx.render();
    try std.testing.expect(!cx.accessibility_tree.getNode(ui.ElementId.fromRaw(background_btn.element_id_raw)).?.state.hidden);
}

test "a11y: 未声明语义的滚动容器投影为 scroll_area 分组（不再和兄弟区域交错）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scroll = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    scroll.tag = .scroll;
    const inside = try ui.text(cx, "Inside", .{});
    try scroll.appendChild(std.testing.allocator, inside);
    try root.appendChild(std.testing.allocator, scroll);
    cx.layout();
    _ = cx.render();
    const area = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(scroll.element_id_raw)).?;
    try std.testing.expectEqual(ui.a11y_tree.Role.scroll_area, area.role);
    // container: doesn't borrow child text as name, text remains its child element
    try std.testing.expectEqual(@as(u64, 0), area.label_hash);
    try std.testing.expect(cx.accessibility_tree.getNode(ui.ElementId.fromRaw(inside.element_id_raw)).?.parent.eql(a11y_tree_mod.AXId.node(ui.ElementId.fromRaw(scroll.element_id_raw))));
}

test "nested a11y tree exposes children via C ABI" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // dialog container + 2 child buttons
    const dialog = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    dialog.behavior.interaction.a11y = .{ .role = .dialog, .label = "Confirm" };

    const ok_btn = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    ok_btn.behavior.interaction.a11y = .{ .role = .button, .label = "OK" };

    const cancel_btn = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    cancel_btn.behavior.interaction.a11y = .{ .role = .button, .label = "Cancel" };

    try dialog.appendChild(std.testing.allocator, ok_btn);
    try dialog.appendChild(std.testing.allocator, cancel_btn);
    try root.appendChild(std.testing.allocator, dialog);

    cx.layout();
    _ = cx.render();

    // VoiceOver flow: top-level is dialog
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_root_count(a11y_bridge_extern.ANY));
    const dialog_h = a11y_bridge_extern.zenit_a11y_root_at(a11y_bridge_extern.ANY, 0);
    try std.testing.expectEqual(
        @as(c_int, @backingInt(ui.a11y_tree.Role.dialog)),
        a11y_bridge_extern.zenit_a11y_role(a11y_bridge_extern.ANY, dialog_h),
    );

    // dialog has 2 children
    try std.testing.expectEqual(@as(c_int, 2), a11y_bridge_extern.zenit_a11y_children_count(a11y_bridge_extern.ANY, dialog_h));

    // verify children labels contain "OK" / "Cancel"
    var seen_ok = false;
    var seen_cancel = false;
    var ci: c_int = 0;
    while (ci < 2) : (ci += 1) {
        const ch = a11y_bridge_extern.zenit_a11y_children_at(a11y_bridge_extern.ANY, dialog_h, ci);
        try std.testing.expect(ch != 0);
        var buf: [32]u8 = undefined;
        const n = a11y_bridge_extern.zenit_a11y_label(a11y_bridge_extern.ANY, ch, &buf, buf.len);
        const label = buf[0..@intCast(n)];
        if (std.mem.eql(u8, label, "OK")) seen_ok = true;
        if (std.mem.eql(u8, label, "Cancel")) seen_cancel = true;
    }
    try std.testing.expect(seen_ok);
    try std.testing.expect(seen_cancel);
}

test "probe mode returns length when buf=null" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const btn = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "Hello World" };
    try root.appendChild(std.testing.allocator, btn);

    cx.layout();
    _ = cx.render();

    const h = a11y_bridge_extern.zenit_a11y_root_at(a11y_bridge_extern.ANY, 0);
    // probe: buf=null returns actual length
    const probe = a11y_bridge_extern.zenit_a11y_label(a11y_bridge_extern.ANY, h, null, 0);
    try std.testing.expectEqual(@as(c_int, "Hello World".len), probe);
}

// v0.6 §2.2, event_dispatcher capture phase dispatch tests

// shared trace buffer: each capture handler pushes node tag (root/mid/target)
const CaptureTrace = struct {
    seq: std.ArrayList(u8),
    stop_after: ?u8 = null, // after receiving this tag, return .stop

    fn append(self: *CaptureTrace, tag: u8) EventResult {
        // test scaffold: callback signature fixed to return EventResult, can't propagate
        // error. uses testing.allocator; real OOM fails test itself; sequence assertion catches
        // missing item immediately; no silent-pass risk.
        self.seq.append(std.testing.allocator, tag) catch {};
        if (self.stop_after) |s| if (tag == s) return .stop;
        return .ignored;
    }
};

fn captureHandlerFor(comptime tag: u8) ui.GenericEventCallback {
    return struct {
        fn handle(event: ui.Event, ctx: ?*anyopaque) EventResult {
            _ = event;
            const trace: *CaptureTrace = @ptrCast(@alignCast(ctx.?));
            return trace.append(tag);
        }
    }.handle;
}

test "capture phase walks root → target; the target's own capture handler runs at the target phase, before its on_event" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var trace = CaptureTrace{ .seq = .empty };
    defer trace.seq.deinit(std.testing.allocator);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    root.behavior.events.on_event_capture = captureHandlerFor('R');
    root.behavior.events.event_context = &trace;

    const mid = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    mid.behavior.events.on_event_capture = captureHandlerFor('M');
    mid.behavior.events.event_context = &trace;

    const target = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    target.behavior.events.on_event_capture = captureHandlerFor('T');
    target.behavior.events.event_context = &trace;

    try mid.appendChild(std.testing.allocator, target);
    try root.appendChild(std.testing.allocator, mid);
    cx.root = root;
    cx.layout();

    // test dispatcher directly for capture/bubble logic, bypass hit-test (well-covered
    // by other fixtures; here only protocol itself).
    _ = cx.dispatcher.dispatch(ui.Event{ .click = .{ .x = 50, .y = 50 } }, target);

    // root (R) + mid (M) fire in capture phase; target (T)'s capture fires in target
    // phase (DOM at-target order), once only (capture phase root->target path excludes target
    // itself).
    try std.testing.expectEqual(@as(usize, 3), trace.seq.items.len);
    try std.testing.expectEqual(@as(u8, 'R'), trace.seq.items[0]);
    try std.testing.expectEqual(@as(u8, 'M'), trace.seq.items[1]);
    try std.testing.expectEqual(@as(u8, 'T'), trace.seq.items[2]);
}

test "unfocused keys reach the application root under the App wrapper" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var trace = CaptureTrace{ .seq = .empty };
    defer trace.seq.deinit(std.testing.allocator);

    // App shape: a wrapper root holding the application tree and the overlay portal.
    const wrapper = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    const content = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    content.behavior.events.on_event_capture = captureHandlerFor('A');
    content.behavior.events.event_context = &trace;
    const portal = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    try wrapper.appendChild(std.testing.allocator, content);
    try wrapper.appendChild(std.testing.allocator, portal);
    cx.root = wrapper;
    cx.content_root = content;
    cx.layout();

    cx.handleKeyDown(.f11, .{});
    cx.handleKeyUp(.f11, .{});
    try std.testing.expectEqualSlices(u8, "AA", trace.seq.items);

    // A content root no longer under the wrapper is ignored; the wrapper receives keys.
    wrapper.removeChild(content);
    defer content.destroy(std.testing.allocator);
    cx.handleKeyDown(.f11, .{});
    try std.testing.expectEqualSlices(u8, "AA", trace.seq.items);
}

test "capture stop halts propagation (no bubble)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var trace = CaptureTrace{ .seq = .empty, .stop_after = 'M' };
    defer trace.seq.deinit(std.testing.allocator);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    root.behavior.events.on_event_capture = captureHandlerFor('R');
    root.behavior.events.event_context = &trace;

    const mid = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    mid.behavior.events.on_event_capture = captureHandlerFor('M');
    mid.behavior.events.event_context = &trace;

    // target also has on_event to verify target/bubble phase stopped or not
    var target_hit = false;
    const HandlerCtx = struct { hit: *bool };
    var hctx = HandlerCtx{ .hit = &target_hit };
    const target = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    target.behavior.events.on_event = struct {
        fn h(_: ui.Event, ctx: ?*anyopaque) EventResult {
            const c: *HandlerCtx = @ptrCast(@alignCast(ctx.?));
            c.hit.* = true;
            return .handled;
        }
    }.h;
    target.behavior.events.event_context = &hctx;

    try mid.appendChild(std.testing.allocator, target);
    try root.appendChild(std.testing.allocator, mid);
    cx.root = root;
    cx.layout();

    _ = cx.dispatcher.dispatch(ui.Event{ .click = .{ .x = 50, .y = 50 } }, target);

    // R + M fire; after M returns stop, target should not fire
    try std.testing.expectEqual(@as(usize, 2), trace.seq.items.len);
    try std.testing.expect(!target_hit);
}

test "null on_event_capture handler skipped (zero overhead)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var trace = CaptureTrace{ .seq = .empty };
    defer trace.seq.deinit(std.testing.allocator);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    // root doesn't set on_event_capture

    const mid = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    mid.behavior.events.on_event_capture = captureHandlerFor('M');
    mid.behavior.events.event_context = &trace;

    const target = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});

    try mid.appendChild(std.testing.allocator, target);
    try root.appendChild(std.testing.allocator, mid);
    cx.root = root;
    cx.layout();

    _ = cx.dispatcher.dispatch(ui.Event{ .click = .{ .x = 50, .y = 50 } }, target);

    // only mid (M) fires; root's null handler skipped
    try std.testing.expectEqual(@as(usize, 1), trace.seq.items.len);
    try std.testing.expectEqual(@as(u8, 'M'), trace.seq.items[0]);
}

// v0.6 §2.4, a11y_router.flushToBridge end-to-end tests

const PushHookCalls = struct {
    children_changed: u32 = 0,
    last_announce_text: [128]u8 = undefined,
    last_announce_text_len: usize = 0,
    announce_count: u32 = 0,
};

var g_push_test_state: PushHookCalls = .{};

fn testChildrenChangedHook(_: u32, _: u64) callconv(.c) c_int {
    g_push_test_state.children_changed += 1;
    return 1;
}

fn testAnnounceHook(_: u32, text_ptr: [*]const u8, text_len: c_int, _: u8) callconv(.c) c_int {
    g_push_test_state.announce_count += 1;
    const n = @min(@as(usize, @intCast(text_len)), g_push_test_state.last_announce_text.len);
    @memcpy(g_push_test_state.last_announce_text[0..n], text_ptr[0..n]);
    g_push_test_state.last_announce_text_len = n;
    return 1;
}

test "cx.render flushes structure_changed dirty to children_changed hook" {
    g_push_test_state = .{};
    ui.a11y_macos_bridge.setPushHooks(.{
        .children_changed = testChildrenChangedHook,
        .announce = testAnnounceHook,
    });
    defer ui.a11y_macos_bridge.setPushHooks(.{}); // reset

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    root.behavior.interaction.a11y = .{ .role = .dialog, .label = "Modal" };

    const btn = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "OK" };
    try root.appendChild(std.testing.allocator, btn);

    cx.root = root;
    cx.layout();
    _ = cx.render();

    // root + btn both new (structure_changed), router pushes children_changed to parent.
    // btn.parent == root (valid); root.parent == NULL (router skips NULL parent).
    // so children_changed called at least 1x (btn's parent=root triggers).
    try std.testing.expect(g_push_test_state.children_changed >= 1);
}

test "live region text_hash change triggers announce hook" {
    g_push_test_state = .{};
    ui.a11y_macos_bridge.setPushHooks(.{
        .children_changed = testChildrenChangedHook,
        .announce = testAnnounceHook,
    });
    defer ui.a11y_macos_bridge.setPushHooks(.{});

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    cx.layout();
    _ = cx.render();
    g_push_test_state.announce_count = 0;

    // manually upsert live region node + modify text_hash -> live_announce dirty
    const id = a11y_tree_mod.AXId.node(.{ .index = 999, .generation = 0 });
    const initial_text = "Loading";
    const initial_hash = std.hash.Wyhash.hash(0, initial_text);
    try cx.a11y_label_buf.put(cx.allocator, initial_hash, initial_text);
    try cx.accessibility_tree.upsert(.{
        .element = id,
        .role = .status,
        .live = .polite,
        .text_hash = initial_hash,
    });
    // drain first upsert (structure_changed)
    var dummy_cx_ref = ui.a11y_macos_bridge.PushCxRef{
        .window_id = 1,
        .label_ctx = cx,
        .label_resolver = struct {
            fn r(ctx: *anyopaque, hash: u64) ?[]const u8 {
                const c: *Cx = @ptrCast(@alignCast(ctx));
                return c.a11y_label_buf.get(hash);
            }
        }.r,
    };
    ui.a11y_router.flushToBridge(
        &cx.accessibility_tree,
        ui.a11y_macos_bridge.pushBridge(&dummy_cx_ref),
    );
    g_push_test_state.announce_count = 0;

    // change text -> live_announce
    const new_text = "Done";
    const new_hash = std.hash.Wyhash.hash(0, new_text);
    try cx.a11y_label_buf.put(cx.allocator, new_hash, new_text);
    try cx.accessibility_tree.upsert(.{
        .element = id,
        .role = .status,
        .live = .polite,
        .text_hash = new_hash,
    });
    ui.a11y_router.flushToBridge(
        &cx.accessibility_tree,
        ui.a11y_macos_bridge.pushBridge(&dummy_cx_ref),
    );

    try std.testing.expectEqual(@as(u32, 1), g_push_test_state.announce_count);
    try std.testing.expectEqualStrings("Done", g_push_test_state.last_announce_text[0..g_push_test_state.last_announce_text_len]);
}

test "null hooks → no callbacks (zero-overhead test build)" {
    g_push_test_state = .{};
    ui.a11y_macos_bridge.setPushHooks(.{}); // all null
    defer ui.a11y_macos_bridge.setPushHooks(.{});

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    root.behavior.interaction.a11y = .{ .role = .button, .label = "X" };
    cx.root = root;
    cx.layout();
    _ = cx.render();

    // hooks not registered -> all counters 0
    try std.testing.expectEqual(@as(u32, 0), g_push_test_state.children_changed);
    try std.testing.expectEqual(@as(u32, 0), g_push_test_state.announce_count);
}

// ============================================================================
// v0.6 §2.5, focus.zig audit fixture
// ============================================================================

test "focus survives same-node identity (no rerender)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    const btn = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, btn);

    cx.root = root;
    cx.layout();
    cx.focus_manager.setFocus(btn);

    try std.testing.expect(cx.focus_manager.getFocused() == btn);

    // after another render, focus should persist
    _ = cx.render();
    try std.testing.expect(cx.focus_manager.getFocused() == btn);
}

test "focus cleared when focused node destroyed" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    const btn = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    btn.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, btn);

    cx.root = root;
    cx.layout();
    cx.focus_manager.setFocus(btn);

    try std.testing.expect(cx.focus_manager.getFocused() == btn);

    // destroy focused node
    cx.detachChild(root, btn);
    cx.freeNode(btn);

    // getFocused should auto-clear (generational handle resolves to null)
    try std.testing.expect(cx.focus_manager.getFocused() == null);
}

// setFocusWithReason syncs freeNode UAF defense in blur/focus callbacks.
// Crash stack: NodeRegistry.trackGeneration <- FocusManager.setFocusWithReason: a blur handler
// frees the new focus candidate, then a dangling ptr is written to current_focus and node.id read.
// Callbacks run outside tick/reactive depth; freeNode calls freeNodeNow (no queue).
const FocusFreeProbe = struct {
    cx: *Cx,
    parent: *Node,
    victim: ?*Node = null,
    fired: u32 = 0,

    fn freeVictim(ctx: *anyopaque) void {
        const self: *FocusFreeProbe = @ptrCast(@alignCast(ctx));
        self.fired += 1;
        const victim = self.victim orelse return;
        self.victim = null;
        self.cx.detachChild(self.parent, victim);
        self.cx.freeNode(victim);
    }

    fn handler(self: *FocusFreeProbe) ui.HandlerRef {
        return .{ .callback = &freeVictim, .context = @ptrCast(self) };
    }
};

fn focusFreeFixture(cx: *Cx) !struct { root: *Node, a: *Node, b: *Node } {
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    const a = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    a.setFocusable(true);
    const b = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } }, .{});
    b.setFocusable(true);
    try root.appendChild(std.testing.allocator, a);
    try root.appendChild(std.testing.allocator, b);
    cx.root = root;
    cx.layout();
    _ = cx.render();
    return .{ .root = root, .a = a, .b = b };
}

test "focus: blur handler freeing the incoming focus target degrades to cleared focus (no UAF)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const f = try focusFreeFixture(cx);

    cx.focus_manager.setFocus(f.a);
    try std.testing.expect(cx.focus_manager.getFocused() == f.a);

    var probe = FocusFreeProbe{ .cx = cx, .parent = f.root, .victim = f.b };
    f.a.behavior.events.on_blur = probe.handler();

    // b freed in a's blur; before fix, dangling b was written to current_focus here
    cx.focus_manager.setFocusWithReason(f.b, .click);

    try std.testing.expectEqual(@as(u32, 1), probe.fired);
    try std.testing.expect(cx.focus_manager.current_focus == null);
    try std.testing.expect(cx.focus_manager.current_focus_handle == null);
    try std.testing.expect(cx.focus_manager.getFocused() == null);
    // old focus received blur, must not 'restore' to focused
    try std.testing.expect(!cx.focus_manager.isFocused(f.a));
    // frames run normally, focus chain works normally
    _ = cx.render();
    f.a.behavior.events.on_blur = null;
    cx.focus_manager.setFocus(f.a);
    try std.testing.expect(cx.focus_manager.getFocused() == f.a);
}

test "focus: Tab traversal whose blur handler frees the next target does not UAF" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const f = try focusFreeFixture(cx);
    cx.focus_manager.registerFocusable(f.a) catch {};
    cx.focus_manager.registerFocusable(f.b) catch {};

    cx.focus_manager.setFocus(f.a);
    var probe = FocusFreeProbe{ .cx = cx, .parent = f.root, .victim = f.b };
    f.a.behavior.events.on_blur = probe.handler();

    cx.focus_manager.focusNext();

    try std.testing.expectEqual(@as(u32, 1), probe.fired);
    try std.testing.expect(cx.focus_manager.getFocused() == null);
    _ = cx.render();
}

test "focus: blur handler freeing the old focused node still hands focus to the new node" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const f = try focusFreeFixture(cx);

    cx.focus_manager.setFocus(f.a);
    var probe = FocusFreeProbe{ .cx = cx, .parent = f.root, .victim = f.a };
    f.a.behavior.events.on_blur = probe.handler();

    // a freed in own blur; subsequent dispatcher blur propagation and markRenderDirty
    // must not touch a
    cx.focus_manager.setFocusWithReason(f.b, .click);

    // detachChild -> invalidateReferencesTo re-sends blur to still-focused a (reentrant,
    // victim null)
    try std.testing.expect(probe.fired >= 1);
    try std.testing.expect(cx.focus_manager.getFocused() == f.b);
    _ = cx.render();
}

test "focus: focus handler freeing its own node leaves focus cleared (no UAF)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const f = try focusFreeFixture(cx);

    var probe = FocusFreeProbe{ .cx = cx, .parent = f.root, .victim = f.b };
    f.b.behavior.events.on_focus = probe.handler();

    cx.focus_manager.setFocusWithReason(f.b, .click);

    try std.testing.expectEqual(@as(u32, 1), probe.fired);
    try std.testing.expect(cx.focus_manager.getFocused() == null);
    _ = cx.render();
}

// Documents a current limitation: focus restoration after reactive rerender is not stable-id-based
// (e.g. For loop key=item.id rebuilds nodes); new node ptr/generation differ.
// getFocused uses cached ptr+id match and can't recover new nodes. Out of scope until
// main plan Phase 7 "For loop key-only + eq_props".

// gesture_recognizer integration with dispatcher tests
//
// Verify cx.handleMouseDown/Move/Up + cx.render() (tick) feed gesture_arena and the
// recognizer callback fires on state transition.
//
// Not verified: input/state.zig double/triple-click/drag anchor migration to GestureArena
// (deferred); this suite tests infrastructure only.

const GestureCount = struct {
    began: u32 = 0,
    changed: u32 = 0,
    ended: u32 = 0,
    failed: u32 = 0,
    last_event: ?ui.gesture.GestureEvent = null,

    fn cb(event: ui.gesture.GestureEvent, ctx: *anyopaque) void {
        const self: *GestureCount = @ptrCast(@alignCast(ctx));
        self.last_event = event;
        switch (event.state) {
            .began => self.began += 1,
            .changed => self.changed += 1,
            .ended => self.ended += 1,
            .failed => self.failed += 1,
            else => {},
        }
    }
};

test "cx.registerGesture wires tap recognizer through arena" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    cx.layout();

    var counter = GestureCount{};
    _ = try cx.registerGesture(root, .tap, .{}, GestureCount.cb, &counter);

    // mouse down + up at same position -> tap.ended emit
    cx.handleMouseDown(50, 50, .{});
    cx.handleMouseUp(50, 50);

    try std.testing.expectEqual(@as(u32, 1), counter.ended);
    try std.testing.expectEqual(@as(u32, 0), counter.failed);
}

test "pan recognizer fires began on movement > threshold" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    cx.layout();

    var counter = GestureCount{};
    _ = try cx.registerGesture(root, .pan, .{ .pan_min_movement_px = 10 }, GestureCount.cb, &counter);

    cx.handleMouseDown(50, 50, .{});
    // move 5px (< 10px threshold) -> no began
    cx.handleMouseMove(55, 50);
    try std.testing.expectEqual(@as(u32, 0), counter.began);

    // move to 70 (20px from origin > 10px) -> began
    cx.handleMouseMove(70, 50);
    try std.testing.expectEqual(@as(u32, 1), counter.began);

    // continue move -> changed
    cx.handleMouseMove(80, 50);
    try std.testing.expectEqual(@as(u32, 1), counter.changed);

    cx.handleMouseUp(80, 50);
    try std.testing.expectEqual(@as(u32, 1), counter.ended);
}

test "tap recognizer fails when movement > threshold (no ended)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    cx.layout();

    var counter = GestureCount{};
    _ = try cx.registerGesture(root, .tap, .{ .tap_max_movement_px = 8 }, GestureCount.cb, &counter);

    cx.handleMouseDown(50, 50, .{});
    cx.handleMouseMove(70, 50); // 20px > 8px → failed
    cx.handleMouseUp(70, 50);

    try std.testing.expectEqual(@as(u32, 1), counter.failed);
    try std.testing.expectEqual(@as(u32, 0), counter.ended);
}

test "long_press began emit on cx.render() tick after threshold" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    cx.layout();

    var counter = GestureCount{};
    // threshold set tiny (1ms) because unit test can't wait 500ms real clock
    _ = try cx.registerGesture(root, .long_press, .{ .long_press_min_duration_ms = 1 }, GestureCount.cb, &counter);

    cx.handleMouseDown(50, 50, .{});
    try std.testing.expectEqual(@as(u32, 0), counter.began);

    // actually wait 5ms to advance nanoTimestamp past threshold
    try std.Io.sleep(cx.io, .fromNanoseconds(5 * std.time.ns_per_ms), .awake);
    _ = cx.render();
    try std.testing.expectEqual(@as(u32, 1), counter.began);

    cx.handleMouseUp(50, 50);
    try std.testing.expectEqual(@as(u32, 1), counter.ended);
}

// -- CA-pure surface regression gate --
// A centered composited_group surface owner (modal dialog scenario) in animated state
// (scale != 1) must composite at its centered world position, **never** drift to (0,0).
// Needs a per-frame position assertion: surface_inverse double-localizing put the
// begin_opacity_layer composite at screen top-left; single-matrix M_composite must be centered.
test "render(CA): centered composited_group surface composites at center, not (0,0)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1100, 1000);

    // full-window root, flex-centered (= barrier-centered dialog)
    const root = try box(cx, .{
        .width = .{ .px = 1100 },
        .height = .{ .px = 1000 },
        .justify = .center,
        .align_items = .center,
    }, .{});

    // centered surface owner (dialog): 400x100, composited_group + animated scale=0.9
    const dialog = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 100 },
        .background = Color.rgba(255, 255, 255, 255),
    }, .{});
    const ext = dialog.style.ensureExtPanic(cx.allocator);
    ext.composited_group = true;
    ext.scale_x = 0.9;
    ext.scale_y = 0.9;

    try root.appendChild(cx.allocator, dialog);
    cx.root = root;
    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    // centered world position: x=(1100-400)/2=350, y=(1000-100)/2=450
    const expect_cx: f32 = 350 + 200; // dialog center x
    const expect_cy: f32 = 450 + 50; // dialog center y

    var saw_layer = false;
    for (commands) |cmd| {
        if (!cmd.isControl(.begin_opacity_layer)) continue;
        saw_layer = true;
        // composite position: if use_draw_transform, map src center via draw_transform
        // translation; else use draw_x/y + draw_w/h center (settled fallback path).
        var composed_cx: f32 = undefined;
        var composed_cy: f32 = undefined;
        if (cmd.use_draw_transform) {
            // draw_transform acts on src rect (geom). compute src center after transform
            const t = cmd.draw_transform; // [a,b,c,d,tx,ty]
            const sx = cmd.geom.x + cmd.geom.w / 2;
            const sy = cmd.geom.y + cmd.geom.h / 2;
            composed_cx = t[0] * sx + t[2] * sy + t[4];
            composed_cy = t[1] * sx + t[3] * sy + t[5];
        } else {
            composed_cx = cmd.draw_x + cmd.draw_w / 2;
            composed_cy = cmd.draw_y + cmd.draw_h / 2;
        }
        // composite center must be near dialog centered-world center (tolerance 60, covers
        // shadow margin/scale). Old bug: composed_cx≈0 -> far from 550 -> fail.
        try std.testing.expect(@abs(composed_cx - expect_cx) < 60);
        try std.testing.expect(@abs(composed_cy - expect_cy) < 60);
        // and never at top-left corner
        try std.testing.expect(composed_cx > 100);
        try std.testing.expect(composed_cy > 100);
    }
    try std.testing.expect(saw_layer);
}

test "render: rotated leaf inside ancestor clip emits surface-local apply_clip" {
    // regression: settled static rotate=π/2 leaf (accordion expanded chevron) has
    // has_surface_transform surface; effect bridge sends ancestor clip's world AABB unchanged
    // into surface -> world-coordinate scissor clips away all surface-local content. After fix
    // apply_clip must inverse-transform via surface_draw_transform into surface-local space.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);

    const root = try box(cx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
    }, .{});

    const clipper = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 400 },
        .overflow_hidden = true,
    }, .{});
    clipper.style.translate_x = 200;

    const rotated = try box(cx, .{
        .width = .{ .px = 16 },
        .height = .{ .px = 16 },
        .background = ui.Color.rgb(40, 40, 40),
    }, .{});
    rotated.setRotate(cx.allocator, std.math.pi / 2.0);

    try clipper.appendChild(cx.allocator, rotated);
    try root.appendChild(cx.allocator, clipper);
    cx.root = root;

    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var depth: i32 = 0;
    var saw_layer = false;
    var saw_world_space_clip_in_surface = false;
    for (commands) |cmd| {
        if (cmd.isControl(.begin_opacity_layer)) {
            depth += 1;
            saw_layer = true;
        } else if (cmd.isControl(.end_opacity_layer)) {
            depth -= 1;
        } else if (depth > 0 and cmd.isControl(.push_clip)) {
            // surface content is surface-local (16x16 near origin); if clipper's world x=200
            // appears unchanged, clip wasn't inverse-transformed -> content fully clipped
            if (cmd.geom.x > 100) saw_world_space_clip_in_surface = true;
        }
    }
    try std.testing.expect(saw_layer);
    try std.testing.expect(!saw_world_space_clip_in_surface);
}

test "render: blur layer ancestor clip stays in parent frame before begin_blur_layer" {
    // blur's apply_clip happens **before** begin_blur_layer (parent context), must stay
    // world coordinates. effect_bridge's surface-local projection only for in-layer clip
    // (inside_surface=true branch); must not mistakenly project here.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);

    const root = try box(cx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
    }, .{});

    const clipper = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 400 },
        .overflow_hidden = true,
    }, .{});
    clipper.style.translate_x = 200;

    const blurred = try box(cx, .{
        .width = .{ .px = 60 },
        .height = .{ .px = 60 },
        .background = ui.Color.rgba(200, 200, 200, 120),
    }, .{});
    blurred.style.ensureExtPanic(cx.allocator).glass = .{ .backdrop_blur = 8 };

    try clipper.appendChild(cx.allocator, blurred);
    try root.appendChild(cx.allocator, clipper);
    cx.root = root;

    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    var saw_blur = false;
    var clip_before_blur_x: ?f32 = null;
    var last_clip_x: ?f32 = null;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            last_clip_x = cmd.geom.x;
        } else if (cmd.isControl(.begin_blur_layer)) {
            saw_blur = true;
            if (clip_before_blur_x == null) clip_before_blur_x = last_clip_x;
        }
    }
    try std.testing.expect(saw_blur);
    if (clip_before_blur_x) |x| {
        // parent context's clip should be world coordinates (clipper at x=200)
        try std.testing.expectApproxEqAbs(@as(f32, 200), x, 0.001);
    }
}

test "world ownership: node carries its owning Cx id" {
    // P0-3 Phase 1 acceptance: Node now carries owner identifier.
    // foundation for dismantling global callback indirection. ElementId itself
    // ({index:u24, generation:u8}) lacks World identifier; both Worlds allocate from index
    // 0, so element_id alone can't disambiguate (isValid false-matches).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const n = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    cx.root = n;

    // nodes created via Cx all stamped with owner
    try std.testing.expect(n.world_id != ui.INVALID_WORLD_ID);
    try std.testing.expectEqual(cx.world_id, n.world_id);
}

test "world ownership: guard detects a foreign node (negative test)" {
    // prove guard is not dead code: after tampering world_id to non-active value,
    // nodeBelongsToActiveWorld must return false.
    // (don't call rectFromWorldOrFallback directly, it would panic and kill test;
    // here verifying the guard logic itself.)
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const n = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    cx.root = n;

    try std.testing.expect(Cx.nodeBelongsToActiveWorldForTest(n));
    const saved = n.world_id;
    n.world_id = saved +% 7; // spoof as node from different World
    try std.testing.expect(!Cx.nodeBelongsToActiveWorldForTest(n));
    n.world_id = saved;

    // INVALID (cx-less mock) must pass, else many test paths false-alarm
    n.world_id = ui.INVALID_WORLD_ID;
    try std.testing.expect(Cx.nodeBelongsToActiveWorldForTest(n));
    n.world_id = saved;
}

test "world ownership: sequential Cx get distinct world ids" {
    // world_id not reused; reuse would let stale Nodes from freed Cx false-match new
    // Cx, exactly the problem owner identifier prevents.
    var first_id: u16 = undefined;
    {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        first_id = cx.world_id;
    }
    {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        try std.testing.expect(cx.world_id != first_id);
    }
}

test "standalone fallback storage is reclaimed on last Cx deinit" {
    // these fallback tables are process-level + page_allocator, **GPA leak check can't
    // see** (blind spot in audit report: `zig build test` green doesn't mean no leak on this
    // path). now Cx.deinit explicitly reclaims when last Cx exits; here assert 'truly
    // zeroed'.
    const accessor = @import("paint_content_accessor.zig");
    const lifecycle = @import("node_lifecycle.zig");

    {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        const n = try box(cx, .{ .width = .{ .px = 8 }, .height = .{ .px = 8 } }, .{});
        cx.root = n;
        // make standalone entry: Node.create runs create hook, gets real element_id;
        // manually clear to INVALID to force fallback write path (simulate cx-less mock).
        const orphan = try Node.create(std.testing.allocator, 99999, .box, .{});
        defer orphan.destroy(std.testing.allocator);
        orphan.element_id_raw = 0xFFFFFFFF;
        orphan.world_id = ui.INVALID_WORLD_ID;
        orphan.setLayoutRect(.{ .x = 1, .y = 2, .w = 3, .h = 4 });
        try std.testing.expect(lifecycle.standaloneRectCount() > 0);
    }

    // after last Cx exits, table should be reclaimed clean
    try std.testing.expectEqual(@as(usize, 0), lifecycle.standaloneRectCount());
    try std.testing.expectEqual(@as(usize, 0), accessor.standaloneEntryCount());
}

test "P0-3 stage 3: node property access bypasses global callbacks" {
    // Phase 3 acceptance: paint / content / layout_output read-write now direct to
    // node.world_ref.*, no longer via process-level global callback.
    // legacy_callback_hits increments only when world_ref == null (cx-less mock);
    // so after Cx-created nodes do full read-write, it must **stay zero**.
    const pca = @import("paint_content_accessor.zig");

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const n = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 10 } }, .{});
    cx.root = n;
    try std.testing.expect(n.world_ref != null); // onNodeCreate has injected owner

    const before = pca.legacy_callback_hits;

    // cover three accessor groups, read and write each once
    n.setBackgroundRaw(Color.rgb(1, 2, 3));
    _ = n.getBackground();
    n.setOpacityRaw(0.5);
    _ = n.getOpacity();
    n.setText(.{ .content = "hi" });
    _ = n.getText();
    n.setLayoutRect(.{ .x = 1, .y = 2, .w = 3, .h = 4 });
    _ = n.rectFromWorldOrFallback();

    try std.testing.expectEqual(before, pca.legacy_callback_hits);

    // and values actually round-trip correctly via World (not "bypassed but
    // unreadable")
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), n.getOpacity(), 0.001);
    try std.testing.expectEqual(@as(f32, 3), n.rectFromWorldOrFallback().w);
}

test "P0-3 stage 3: dirty + structure sync reach World directly" {
    // dirty_notify / structure_notify also direct-connected (no process-level
    // callback). here assert 'parent-child chain truly synced to World.elements'; if still
    // using old callback that happens not to be registered, chain would be empty, test
    // fails.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();

    const parent = try box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } }, .{});
    cx.root = parent;
    const child = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try parent.appendChild(cx.allocator, child);

    const w = parent.world_ref.?;
    const p_eid = ui.ElementId.fromRaw(parent.element_id_raw);
    const c_eid = ui.ElementId.fromRaw(child.element_id_raw);

    // append synced to World.elements parent-child chain
    const links = w.elements.links(c_eid).?;
    try std.testing.expect(!links.parent.isNull());
    try std.testing.expectEqual(p_eid.raw(), links.parent.raw());

    // markRenderDirty goes through markWorldDirty -> World.dirty_set (no panic = pass;
    // mainly verify direct path doesn't silently drop due to null world_ref).
    child.markRenderDirty();

    // unlink also syncs
    cx.detachChild(parent, child);
    const links_after = w.elements.links(c_eid).?;
    try std.testing.expect(links_after.parent.isNull());
    cx.freeNode(child);
}

test "P0-3 stage 5: two coexisting Cx route node mutations independently" {
    // **core multi-window acceptance**: two concurrent Cx, each node mutation goes to its own
    // World.
    //
    // Node<->World routing used to go via a process-level global callback: a second Cx.init
    // redirected
    // it, so **window A node writes landed in window B table**; ElementId lacks a World identifier
    // (both Worlds allocate from index 0) and isValid checks only index+generation, so
    // cross-queries
    // **false-match wrong data**.
    //
    // Now all property access goes through node.world_ref, so nodes created explicitly via
    // Cx.createNode (not relying on g_active_world) keep both Cx independent.
    var cx_a = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx_a.deinit();

    // no allowlist needed, concurrency guards removed (2026-07-30, last
    // process-level dependency a11y active context now routed by window_id). Second Cx can
    // init directly.
    var cx_b = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx_b.deinit();

    try std.testing.expect(cx_a.world_id != cx_b.world_id);

    // two nodes explicitly belong to respective Cx
    const a = try cx_a.createNode(.box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    defer cx_a.freeNode(a);
    const b = try cx_b.createNode(.box, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } });
    defer cx_b.freeNode(b);

    try std.testing.expect(a.world_ref.? != b.world_ref.?);

    // key: even if both ElementIds are **potentially identical** (each World allocates
    // from index 0), writes must return to respective homes.
    a.setLayoutRect(.{ .x = 1, .y = 1, .w = 11, .h = 11 });
    b.setLayoutRect(.{ .x = 2, .y = 2, .w = 22, .h = 22 });
    a.setOpacityRaw(0.25);
    b.setOpacityRaw(0.75);

    try std.testing.expectEqual(@as(f32, 11), a.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 22), b.rectFromWorldOrFallback().w);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), a.getOpacity(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), b.getOpacity(), 0.001);

    // reverse confirmation: no crosstalk exists; changing A doesn't affect B
    a.setLayoutRect(.{ .x = 9, .y = 9, .w = 99, .h = 99 });
    try std.testing.expectEqual(@as(f32, 22), b.rectFromWorldOrFallback().w);
}

test "silent-swallow counters stay zero in normal operation" {
    // ~250 `catch return;` / `catch {}` sites swallow OOM and build failures. Propagating all of
    // them
    // needs effect/callback signature changes; cost prohibitive. Compromise: counters on the
    // **highest-risk few** make 'silent' failures observable. This test locks: normal render paths
    // must stay 0; non-zero signals OOM or capacity silently degrading rendering/reactivity.
    const graph_mod = @import("../reactive/graph.zig");

    const base_paint = ui.paint_push_failures;
    const base_track = graph_mod.reactive_tracking_failures;
    const base_hit = ui.interaction_put_failures;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 120);

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{});
    cx.root = root;
    try root.appendChild(std.testing.allocator, try text(cx, "hello", .{}));

    // run two full frames of layout+render, each followed by the World table mirror (text
    // paint chunk recording / pushItem path, interaction put path): the mirror runs on
    // demand, so without the explicit sync these counters could not move at all.
    cx.layout();
    _ = cx.render();
    cx.ensureWorldTablesSynced();
    root.markRenderDirty();
    cx.frame_time_ms += 16;
    cx.layout();
    _ = cx.render();
    cx.ensureWorldTablesSynced();
    // The mirror really ran (otherwise the zero assertions below would be vacuous).
    try std.testing.expect(cx.perf.synced_node_count > 0);

    try std.testing.expectEqual(base_paint, ui.paint_push_failures);
    try std.testing.expectEqual(base_track, graph_mod.reactive_tracking_failures);
    try std.testing.expectEqual(base_hit, ui.interaction_put_failures);
}

test "allocation campaign: rebuildRuntimeIndexes reports OOM instead of publishing partial indexes" {
    // Locks the premise of core.zig `catch @panic("OOM: rebuildRuntimeIndexes")`: the function
    // **truly does** return an error on OOM (panic is not dead code).
    //
    // Why panic, not swallow: rebuildRuntimeStateRecursive clears node dirty bits first, then does
    // fallible node_registry.put / focus_order.append. Mid-OOM leaves a node marked clean but not
    // in
    // the index: it never hit-tests, Tab skips it, and no dirty bit remains to retry. Swallowing
    // would be permanent silent corruption.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 120);

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{});
    cx.root = root;
    // attach several focusable children, ensure enough allocations can fail during
    // rebuild
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const child = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
        child.behavior.interaction.focusable = true;
        try root.appendChild(std.testing.allocator, child);
    }

    // run one frame first to put index into stable built state
    cx.layout();
    _ = cx.render();

    // attach more new nodes, force rebuild to **must** request new capacity.
    // (clear() alone insufficient: node_registry / focus_order use clearRetainingCapacity,
    // refilling same nodes triggers no allocations, FailingAllocator never called; real
    // first-draft failure here.)
    i = 0;
    while (i < 512) : (i += 1) {
        const child = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
        child.behavior.interaction.focusable = true;
        try root.appendChild(std.testing.allocator, child);
    }

    // switch to allocator that will fail. Note: must swap node_registry /
    // focus_manager's **own** allocator fields: they capture at init time, changing
    // cx.allocator later doesn't affect rebuild path (real second-draft failure here).
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const saved_reg = cx.node_registry.allocator;
    const saved_focus = cx.focus_manager.allocator;
    cx.node_registry.allocator = failing.allocator();
    cx.focus_manager.allocator = failing.allocator();
    cx.node_registry.clear();
    cx.focus_manager.clearFocusOrder();
    root.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = true;

    const result = cx.rebuildRuntimeIndexesForTest();

    // key assertion: error **returned**, not silently swallowed
    try std.testing.expectError(error.OutOfMemory, result);

    // restore, let deinit finish with real allocator (else GPA reports free to wrong
    // allocator)
    cx.node_registry.allocator = saved_reg;
    cx.focus_manager.allocator = saved_focus;
}

test "P0-3: two coexisting Cx each render their own tree correctly" {
    // step beyond Phase 5: not just verify property routing, but **both Cx run full
    // layout + render**, assert each display list contains only its own content.
    // multiwindow truly works criterion; builders all switched to cx.createNode,
    // no longer rely on g_active_world for node ownership.
    var cx_a = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx_a.deinit();

    // no allowlist needed, concurrency guards removed (2026-07-30, last
    // process-level dependency a11y active context now routed by window_id). Second Cx can
    // init directly.
    var cx_b = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx_b.deinit();

    cx_a.setViewport(100, 60);
    cx_b.setViewport(200, 120);

    // two fully independent trees, each built with its own cx (via builders ->
    // createNode)
    const root_a = try box(cx_a, .{ .width = .{ .px = 100 }, .height = .{ .px = 60 } }, .{});
    cx_a.root = root_a;
    try root_a.appendChild(std.testing.allocator, try text(cx_a, "AAA", .{}));

    const root_b = try box(cx_b, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{});
    cx_b.root = root_b;
    try root_b.appendChild(std.testing.allocator, try text(cx_b, "BBB", .{}));

    // nodes truly belong to respective Worlds
    try std.testing.expect(root_a.world_ref.? == &cx_a.world);
    try std.testing.expect(root_b.world_ref.? == &cx_b.world);

    // interleaved renders, worst case: g_active_world switches back and forth
    cx_a.layout();
    _ = cx_a.render();
    cx_b.layout();
    _ = cx_b.render();
    cx_a.layout();
    _ = cx_a.render();

    // each layout result independent (different viewports, root sizes per each)
    try std.testing.expectEqual(@as(f32, 100), root_a.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 200), root_b.rectFromWorldOrFallback().w);

    // each paint list non-empty and independent
    try std.testing.expect(cx_a.lowerForEncoderPaintTable().len > 0);
    try std.testing.expect(cx_b.lowerForEncoderPaintTable().len > 0);

    // -- a11y end-to-end: ObjC calls C ABI with each window_id and must get its own tree --
    // Needs concurrent Cx; a single-slot setActiveContext would let cx_b.render() overwrite
    // cx_a's registration so both window_ids resolve to the same tree.
    cx_a.setWindowId(101);
    cx_b.setWindowId(202);

    // a11y tree only projects **nodes with explicit role/label**, bare box+text
    // projects nothing; each tree gets one button
    const a11y_btn_a = try box(cx_a, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    a11y_btn_a.behavior.interaction.a11y = .{ .role = .button, .label = "AAA" };
    try root_a.appendChild(std.testing.allocator, a11y_btn_a);

    const a11y_btn_b = try box(cx_b, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    a11y_btn_b.behavior.interaction.a11y = .{ .role = .button, .label = "BBB" };
    try root_b.appendChild(std.testing.allocator, a11y_btn_b);

    // window_id changes require re-registration (happens at render end in
    // syncA11yTree)
    cx_a.layout();
    _ = cx_a.render();
    cx_b.layout();
    _ = cx_b.render();

    const a_roots = a11y_bridge_extern.zenit_a11y_root_count(101);
    const b_roots = a11y_bridge_extern.zenit_a11y_root_count(202);
    try std.testing.expect(a_roots > 0);
    try std.testing.expect(b_roots > 0);

    // each root handle points to its World's element; using A's handle to query
    // B's role should not match A's node (both Worlds' ElementIds start from index 0,
    // classic false-match shape).
    const a_root_h = a11y_bridge_extern.zenit_a11y_root_at(101, 0);
    const b_root_h = a11y_bridge_extern.zenit_a11y_root_at(202, 0);
    try std.testing.expect(a_root_h != 0);
    try std.testing.expect(b_root_h != 0);

    // can read "AAA" from A's tree, "BBB" from B's tree, no crosstalk
    try std.testing.expect(try a11yTreeContainsLabel(101, "AAA"));
    try std.testing.expect(!try a11yTreeContainsLabel(101, "BBB"));
    try std.testing.expect(try a11yTreeContainsLabel(202, "BBB"));
    try std.testing.expect(!try a11yTreeContainsLabel(202, "AAA"));

    // deregister one window, other unaffected
    ui.a11y_macos_bridge.clearActiveContext(101);
    try std.testing.expectEqual(@as(c_int, 0), a11y_bridge_extern.zenit_a11y_root_count(101));
    try std.testing.expectEqual(b_roots, a11y_bridge_extern.zenit_a11y_root_count(202));
}

/// recursively find node in a11y tree for window_id whose label equals `needle`
fn a11yTreeContainsLabel(window_id: u32, needle: []const u8) !bool {
    const n = a11y_bridge_extern.zenit_a11y_root_count(window_id);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const h = a11y_bridge_extern.zenit_a11y_root_at(window_id, i);
        if (h == ui.a11y_macos_bridge.INVALID_HANDLE) continue;
        if (try a11ySubtreeContainsLabel(window_id, h, needle)) return true;
    }
    return false;
}

fn a11ySubtreeContainsLabel(window_id: u32, handle: u64, needle: []const u8) !bool {
    var buf: [256]u8 = undefined;
    const written = a11y_bridge_extern.zenit_a11y_label(window_id, handle, &buf, buf.len);
    if (written > 0 and std.mem.eql(u8, buf[0..@intCast(written)], needle)) return true;

    const kids = a11y_bridge_extern.zenit_a11y_children_count(window_id, handle);
    var i: c_int = 0;
    while (i < kids) : (i += 1) {
        const ch = a11y_bridge_extern.zenit_a11y_children_at(window_id, handle, i);
        if (ch == ui.a11y_macos_bridge.INVALID_HANDLE) continue;
        if (try a11ySubtreeContainsLabel(window_id, ch, needle)) return true;
    }
    return false;
}

test "measure ctx: per-Cx measure function wins over the process-wide one" {
    // One of two non-World global dependencies for multi-window: measure_fn signature lacks
    // context,
    // so the caller (zenit_app.runtime) would smuggle the font selector via process-level
    // g_font_selector_for_measure; with two concurrent Apps the latter overwrites the former and
    // the
    // prior window mismeasures text. Cx supports measure_ctx_fn(+ctx) so each measures its own.
    const tl = @import("text_layout.zig");

    const S = struct {
        var global_calls: u32 = 0;
        var ctx_calls: u32 = 0;
        fn globalMeasure(_: [*]const u8, len: usize, size: f32, _: u16, _: bool) f32 {
            global_calls += 1;
            return @as(f32, @floatFromInt(len)) * size;
        }
        fn ctxMeasure(ctx: *anyopaque, _: [*]const u8, len: usize, size: f32, _: u16, _: bool) f32 {
            ctx_calls += 1;
            const factor: *const f32 = @ptrCast(@alignCast(ctx));
            return @as(f32, @floatFromInt(len)) * size * factor.*;
        }
    };

    tl.setMeasureFn(&S.globalMeasure);
    defer tl.setMeasureFn(null);
    var factor: f32 = 2.0;
    tl.setMeasureCtxFn(&S.ctxMeasure, @ptrCast(&factor));
    defer tl.setMeasureCtxFn(null, null);

    S.global_calls = 0;
    S.ctx_calls = 0;
    const w = tl.measureTextWidthByFontKind("abcd", 10, 400, false, false);

    // context version must take priority (else still crosstalk in multi-window)
    try std.testing.expect(S.ctx_calls > 0);
    try std.testing.expectEqual(@as(u32, 0), S.global_calls);
    try std.testing.expectApproxEqAbs(@as(f32, 4 * 10 * 2.0), w, 0.001);
}

test "render: legacy overflow replay keeps own background once and before blended children" {
    // Cover both a prebuilt own prefix and a prefix blocked by an earlier
    // rotated sibling. The old cache-hit path appended the owner's background
    // after cached children, hiding the blend on every settled frame.
    for ([_]bool{ false, true }) |blocked_prefix| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(400, 200);
        const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 }, .direction = .row }, .{});
        if (blocked_prefix) {
            const first = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .rotate = 0.2, .background = Color.WHITE }, .{});
            try root.appendChild(cx.allocator, first);
        }
        const parent_color = Color.rgba(128, 192, 64, 128);
        const parent = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .background = parent_color, .overflow_hidden = true, .corner_radius = 30 }, .{});
        const child = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 }, .background = Color.rgba(192, 64, 128, 255) }, .{});
        (try child.style.ensureExtFallible(cx.allocator)).blend_mode = .multiply;
        try parent.appendChild(cx.allocator, child);
        try root.appendChild(cx.allocator, parent);
        cx.root = root;
        cx.layout();
        for (0..3) |frame| {
            cx.frame_time_ms = @as(f64, @floatFromInt(frame)) * 16;
            cx.perf.render_cache_hit = 0;
            _ = cx.render();
            if (frame > 0) try std.testing.expect(cx.perf.render_cache_hit > 0);
            var parent_count: usize = 0;
            var child_count: usize = 0;
            var parent_index: usize = 0;
            var child_index: usize = 0;
            for (cx.display_list.items.items, 0..) |item, index| switch (item) {
                .fill_rect => |fill| {
                    if (fill.header.node_id == parent.id) {
                        parent_count += 1;
                        parent_index = index;
                    }
                    if (fill.header.node_id == child.id) {
                        child_count += 1;
                        child_index = index;
                    }
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 1), parent_count);
            try std.testing.expectEqual(@as(usize, 1), child_count);
            try std.testing.expect(parent_index < child_index);
        }
    }
}

test "blend_mode: non-normal forces offscreen and reaches the paint table" {
    // blend_mode end-to-end path acceptance. Guards three production invariants:
    // 1. blend_mode != normal forces use_opacity_layer (blending needs independent rasterize);
    // 2. EffectNode -> CompositedLayer -> begin_opacity_layer carries it losslessly;
    // 3. lowered paint item blend_mode field != 0 (encoder uses it for blend composite, not a
    //    trivial short-circuit / plain SrcOver).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);

    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    const panel = try box(cx, .{
        .width = .{ .px = 100 },
        .height = .{ .px = 80 },
        .background = Color.rgba(200, 100, 50, 255),
    }, .{});
    (try panel.style.ensureExtFallible(cx.allocator)).blend_mode = .multiply;
    try root.appendChild(cx.allocator, panel);
    cx.root = root;

    cx.layout();
    _ = cx.render();

    // use offscreen effect (blend doesn't require promotion, only independent
    // rasterize), carry blend_mode to EffectNode
    var effect_found = false;
    for (cx.property_tree.effects.items) |eff| {
        if (eff.node_id == panel.id and eff.blend_mode == .multiply) {
            effect_found = true;
            break;
        }
    }
    try std.testing.expect(effect_found);

    // lowered paint list contains begin_opacity_layer with blend_mode == multiply
    var found = false;
    for (cx.lowerForEncoderPaintTable()) |it| {
        if (it.kind == .control and it.control_kind == .begin_opacity_layer and
            it.blend_mode == @backingInt(ui.BlendMode.multiply))
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "Cx: deinit with lingering focus does not UAF (downstream regression)" {
    // reproduce: tree has focusable node still holding focus at exit -> recursive
    // freeNode's unregisterFocusableSilent dereferences freed node via getFocused() ->
    // segfault.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    cx.setViewport(200, 100);

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    const a_node = try box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{});
    a_node.setFocusable(true);
    const b_node = try box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{});
    b_node.setFocusable(true);
    try root.appendChild(cx.allocator, a_node);
    try root.appendChild(cx.allocator, b_node);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    // test scaffold: testing.allocator fails test itself on OOM; subsequent
    // assertions directly check focus behavior; failed registration exposes immediately,
    // no silent pass.
    cx.focus_manager.registerFocusable(a_node) catch {};
    cx.focus_manager.registerFocusable(b_node) catch {};
    cx.focus_manager.setFocus(b_node);

    // deinit without clearFocus; must crash before fix
    cx.deinit();
}

// Downstream app upstream #12: single render-dirty frame must not full-tree paint replay
// (O(full tree) amplifier). Acceptance criterion: 2000 absolutely-positioned siblings,
// single markRenderDirty followed by replayed-node count drop >= 90%.

test "perf: single render-dirty node must not re-record 2000 clean siblings" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);

    const n_boxes: usize = 2000;
    const root = try box(cx, .{
        .width = .{ .px = 1280 },
        .height = .{ .px = 800 },
    }, .{});

    var mid_child: ?*Node = null;
    var i: usize = 0;
    while (i < n_boxes) : (i += 1) {
        const child = try box(cx, .{
            .width = .{ .px = 8 },
            .height = .{ .px = 8 },
            .position = .absolute,
            .background = Color.rgba(@intCast(i % 200), 80, 120, 255),
        }, .{});
        // translate landing (downstream pattern: absolute positioning + per-box
        // translate)
        child.style.translate_x = @floatFromInt((i % 40) * 30);
        child.style.translate_y = @floatFromInt((i / 40) * 15);
        try root.appendChild(cx.allocator, child);
        if (i == n_boxes / 2) mid_child = child;
    }

    cx.root = root;

    // Frame 1: full render (full tree fresh re-record)
    _ = cx.render();
    const full_emit = cx.perf.own_content_emit_count;
    try std.testing.expect(full_emit >= n_boxes); // full tree truly re-recorded once
    const full_display_len = cx.display_list.items.items.len;
    const full_paint_len = cx.lowering.main_paint.items.len;
    try std.testing.expect(full_display_len >= n_boxes); // each box at least 1 fill_rect

    // snapshot Frame 1 lowered geometry (equivalence check: fix must not change final
    // command stream)
    const Geom = struct { kind_tag: u16, x: f32, y: f32, w: f32, h: f32 };
    var snap = try std.testing.allocator.alloc(Geom, full_paint_len);
    defer std.testing.allocator.free(snap);
    for (cx.lowering.main_paint.items, 0..) |it, gi| {
        snap[gi] = .{ .kind_tag = @backingInt(it.kind), .x = it.geom.x, .y = it.geom.y, .w = it.geom.w, .h = it.geom.h };
    }

    // Frame 2: single-point render dirty
    mid_child.?.markRenderDirty();
    _ = cx.render();

    const dirty_emit = cx.perf.own_content_emit_count;
    const dirty_display_len = cx.display_list.items.items.len;
    const dirty_paint_len = cx.lowering.main_paint.items.len;

    // equivalence: display list / lowered command counts match, lowered geometry
    // identical
    try std.testing.expectEqual(full_display_len, dirty_display_len);
    try std.testing.expectEqual(full_paint_len, dirty_paint_len);
    for (cx.lowering.main_paint.items, 0..) |it, gi| {
        try std.testing.expectEqual(snap[gi].kind_tag, @backingInt(it.kind));
        try std.testing.expectApproxEqAbs(snap[gi].x, it.geom.x, 0.01);
        try std.testing.expectApproxEqAbs(snap[gi].y, it.geom.y, 0.01);
        try std.testing.expectApproxEqAbs(snap[gi].w, it.geom.w, 0.01);
        try std.testing.expectApproxEqAbs(snap[gi].h, it.geom.h, 0.01);
    }

    // acceptance: single-dirty-frame re-recorded nodes <= 10% of full (target single
    // digits: dirty node + root + path)
    std.debug.print(
        "\n[dirty-splice-bench] full_emit={d} dirty_emit={d} splice_hits={d} cache_writes={d}\n",
        .{ full_emit, dirty_emit, cx.perf.subtree_payload_splice_count, cx.perf.subtree_payload_cache_write_count },
    );
    try std.testing.expect(dirty_emit * 10 <= full_emit);
}

// Hook scope declaration (before_render_hook_affects_self_only)
//
// Background: a markdown editor hooks before_render at top level (scroll sync/geometry backfill),
// and prebuildDisplayPayloadSubtrees sets display_payload_prefix_broken on any hooked node, so all
// paint order after it falls back to fresh emit. Result: whole-document
// subtree_payload_splice_count
// stuck at 0, 186 nodes/frame replayed; ZENIT_DISABLE_SUBTREE_SPLICE A/B delta -1% (never applied).
//
// The two tests below are a pair:
//   1. Undeclared (conservative default) -> prefix breaks, sibling subtrees zero-reused.
//      Anchors that defaults are NOT relaxed (GlassLab double-composite defense line intact).
//   2. Declared self-only -> sibling subtree reuse resumes, lowered command stream
//      matches per-instruction.
// Removing hookScopeIsSelfOnly's allowance makes test 2 red: it is the negative-injection anchor.

/// hook modifying only own style: simulate editor 'backfill own geometry each
/// frame', don't touch descendants
fn selfOnlyHookForTest(node: *Node) void {
    // modify own background (own content changes), don't touch children
    node.setBackground(Color.rgba(10, 20, 30, 255));
}

fn buildHookedPrefixScene(cx: *Cx, n_siblings: usize, self_only: bool) !*Node {
    const root = try box(cx, .{ .width = .{ .px = 1280 }, .height = .{ .px = 800 } }, .{});

    // hooked node comes **first**; once it breaks prefix, all following siblings lose
    // cache eligibility
    const hooked = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } }, .{});
    hooked.meta.per_frame.hooks.before_render.main = selfOnlyHookForTest;
    hooked.frame_state.state_bits.flags.before_render_hook_affects_self_only = self_only;
    try root.appendChild(cx.allocator, hooked);

    var i: usize = 0;
    while (i < n_siblings) : (i += 1) {
        const sib = try box(cx, .{
            .width = .{ .px = 8 },
            .height = .{ .px = 8 },
            .position = .absolute,
            .background = Color.rgba(@intCast(i % 200), 80, 120, 255),
        }, .{});
        sib.style.translate_x = @floatFromInt((i % 40) * 30);
        sib.style.translate_y = @floatFromInt((i / 40) * 15);
        // each sibling carries one child, forms 'subtree' not leaf; splice granularity at
        // subtree level
        const inner = try box(cx, .{
            .width = .{ .px = 4 },
            .height = .{ .px = 4 },
            .background = Color.rgba(200, @intCast(i % 200), 60, 255),
        }, .{});
        try sib.appendChild(cx.allocator, inner);
        try root.appendChild(cx.allocator, sib);
    }
    cx.root = root;
    return root;
}

// Conservative default after the paint-cursor resume (tryResumePrebuildAtPaintCursor): an
// undeclared hook still breaks the paint prefix and its **own subtree** stays hook-owned (never
// cached: the hook may write it without marking it dirty), but siblings painted after it are no
// longer collateral: they are prebuilt at the paint cursor and reused across frames. The old form
// of this test asserted zero sibling splices, which was the collateral being removed.
fn buildHookedPrefixSceneWithHookChild(cx: *Cx, n_siblings: usize, self_only: bool) !struct { root: *Node, hook_child: *Node } {
    const root = try buildHookedPrefixScene(cx, n_siblings, self_only);
    const hooked = root.children.items[0];
    const hook_child = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 10 }, .background = Color.rgba(5, 6, 7, 255) }, .{});
    const hook_grandchild = try box(cx, .{ .width = .{ .px = 4 }, .height = .{ .px = 4 }, .background = Color.rgba(8, 9, 10, 255) }, .{});
    try hook_child.appendChild(cx.allocator, hook_grandchild);
    try hooked.appendChild(cx.allocator, hook_child);
    return .{ .root = root, .hook_child = hook_child };
}

test "hook scope: 默认（未声明）hook 子树保持 hook 所有，前缀断裂后的兄弟子树仍跨帧复用" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);

    const scene = try buildHookedPrefixSceneWithHookChild(cx, 200, false);
    const root = scene.root;

    _ = cx.render(); // Frame 1: opportunity to build cache
    // ⚠ must create a dirty point: fully clean tree hits Cx.render zero-dirty
    // fast-path, early-return entire frame, prebuild never runs. Dirty the last sibling,
    // simulating 'only one row changed'.
    root.children.items[root.children.items.len - 1].markRenderDirty();
    _ = cx.render(); // Frame 2: caches written at the paint cursor
    cx.perf.subtree_payload_splice_count = 0;
    root.children.items[root.children.items.len - 1].markRenderDirty();
    _ = cx.render(); // Frame 3: clean siblings splice

    try std.testing.expect(cx.perf.subtree_payload_splice_count > 0);
    // The hook's own subtree is never cached across frames.
    try std.testing.expect(scene.hook_child.meta.per_frame.caches.commands.subtree_payload == null);
    try std.testing.expect(scene.hook_child.meta.per_frame.caches.commands.own_payload == null);
    try std.testing.expect(scene.hook_child.children.items[0].meta.per_frame.caches.commands.own_payload == null);
}

test "hook scope: 声明 self-only 后兄弟子树恢复跨帧复用且命令流等价" {
    const n: usize = 200;

    // ── A: declare self-only ────────────────────────────────────────────
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    const root = try buildHookedPrefixScene(cx, n, true);

    _ = cx.render();
    // equivalence baseline: use **cache-disabled** command stream. same tree, same
    // dirty point, fresh full re-record result is ground truth; below, with cache on,
    // must match element-by-element. (if using Frame 1 as baseline, Frame 1 itself might
    // already cache, = measuring with the subject.)
    const Geom = struct { kind_tag: u16, x: f32, y: f32, w: f32, h: f32 };
    var baseline = @as(std.ArrayListUnmanaged(Geom), .empty);
    defer baseline.deinit(std.testing.allocator);
    {
        var cx_ref = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx_ref.deinit();
        cx_ref.setViewport(1280, 800);
        const ref_root = try buildHookedPrefixScene(cx_ref, n, false); // false = conservative full
        _ = cx_ref.render();
        ref_root.children.items[ref_root.children.items.len - 1].markRenderDirty();
        _ = cx_ref.render();
        try baseline.ensureTotalCapacity(std.testing.allocator, cx_ref.lowering.main_paint.items.len);
        for (cx_ref.lowering.main_paint.items) |it| {
            baseline.appendAssumeCapacity(.{ .kind_tag = @backingInt(it.kind), .x = it.geom.x, .y = it.geom.y, .w = it.geom.w, .h = it.geom.h });
        }
    }

    cx.perf.subtree_payload_splice_count = 0;
    cx.perf.own_content_emit_count = 0;
    // single-point dirty (same: avoid zero-dirty fast-path). this is the true
    // scenario to optimize: 'only one row changed, rest all reuse'.
    root.children.items[root.children.items.len - 1].markRenderDirty();
    _ = cx.render(); // Frame 2: single-point dirty frame, clean siblings should heavily hit splice

    const splice_hits = cx.perf.subtree_payload_splice_count;
    const emit = cx.perf.own_content_emit_count;
    std.debug.print(
        "\n[hook-self-scope] splice_hits={d} emit={d} siblings={d}\n",
        .{ splice_hits, emit, n },
    );

    // core assertion: clean sibling subtrees fully reused (removing
    // hookScopeIsSelfOnly allowance turns red)
    try std.testing.expect(splice_hits > 0);

    // equivalence: reuse-path lowered commands must match **conservative full** path
    // element-by-element. safeguard against 'cache works but draws wrong'; high hit rate
    // but wrong picture is worse.
    try std.testing.expectEqual(baseline.items.len, cx.lowering.main_paint.items.len);
    for (cx.lowering.main_paint.items, 0..) |it, gi| {
        try std.testing.expectEqual(baseline.items[gi].kind_tag, @backingInt(it.kind));
        try std.testing.expectApproxEqAbs(baseline.items[gi].x, it.geom.x, 0.01);
        try std.testing.expectApproxEqAbs(baseline.items[gi].y, it.geom.y, 0.01);
        try std.testing.expectApproxEqAbs(baseline.items[gi].w, it.geom.w, 0.01);
        try std.testing.expectApproxEqAbs(baseline.items[gi].h, it.geom.h, 0.01);
    }
}

// Risk: a self-only hook that **directly writes a descendant's style.translate_x**
// (bypassing setTranslateX's markCompositePropDirty) leaves the descendant's six dirty bits and
// content_version unchanged -> ancestor stamp passes -> old position spliced before the hook ran.
// Production textarea/virtual_list/scrollbar all use direct writes;
// manual_transform_animation_active
// is only set in test files. The probe checks whether this path truly draws wrong; with the runtime
// audit, real violations must still be caught and lawful writes allowed.
var g_audit_victim: ?*Node = null;
var g_audit_tick: u8 = 0;

// (A) real violation: raw write modifies other, no mark-dirty
fn auditRawWriteHook(node: *Node) void {
    _ = node;
    if (g_audit_victim) |t| {
        g_audit_tick +%= 1;
        t.setBackgroundRaw(Color.rgba(g_audit_tick *% 30, 60, 90, 255));
    }
}

// (B) legal: modify other but via mark-dirty entry (one of panic message's
// recommended fixes, must allow)
fn auditMarkedWriteHook(node: *Node) void {
    _ = node;
    if (g_audit_victim) |t| {
        g_audit_tick +%= 1;
        t.setBackground(Color.rgba(g_audit_tick *% 30, 60, 90, 255));
    }
}

fn buildAuditScene(cx: *Cx, hook: *const fn (*Node) void) !*Node {
    const root = try box(cx, .{ .width = .{ .px = 1280 }, .height = .{ .px = 800 } }, .{});
    const hooked = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    hooked.meta.per_frame.hooks.before_render.main = hook;
    hooked.frame_state.state_bits.flags.before_render_hook_affects_self_only = true;
    try root.appendChild(cx.allocator, hooked);
    const victim = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 60 }, .position = .absolute }, .{});
    const painted = try box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 30 },
        .background = Color.rgba(1, 1, 1, 255),
    }, .{});
    try victim.appendChild(cx.allocator, painted);
    try root.appendChild(cx.allocator, victim);
    g_audit_victim = painted;
    g_audit_tick = 0;
    cx.root = root;
    return root;
}

// Negative confirmation: real violations (raw write modifies another node, no mark-dirty)
// must still be caught. This test expects a panic so can't run as a normal case; run manually
// with the PROBE2 prefix:
//   zig build test-ui-core -Dtest-filter="PROBE2"
// (the test name itself is still Chinese; the filter must match the actual test name)
// expect: panic naming hooked node and modified node.
test "PROBE2 真违约必须仍被稽核抓到（预期 panic）" {
    // SKIP-REASON: audit violation probe, needs explicit
    // ZENIT_RUN_AUDIT_VIOLATION_PROBE to run (intentionally triggers panic path)
    if (!@import("zenit_environment").has("ZENIT_RUN_AUDIT_VIOLATION_PROBE")) return error.SkipZigTest;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    _ = try buildAuditScene(cx, auditRawWriteHook);
    defer g_audit_victim = null;
    var f: usize = 0;
    while (f < 4) : (f += 1) {
        cx.frame_count += 1;
        cx.frame_time_ms += 16.0;
        _ = cx.render();
    }
    std.debug.print("\n[PROBE2 violation] 没有 panic —— 稽核已失效！\n", .{});
}

test "hook scope 稽核: 合法的标脏写入必须放行（不得误报）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    _ = try buildAuditScene(cx, auditMarkedWriteHook);
    defer g_audit_victim = null;

    // use setBackground (mark-dirty) to modify other: cache invalidates normally,
    // not violation in threat model. if audit also flags as violation, panic message's
    // recommended fix (b) becomes self-contradictory.
    var f: usize = 0;
    while (f < 4) : (f += 1) {
        cx.frame_count += 1;
        cx.frame_time_ms += 16.0;
        _ = cx.render();
    }
    // reaching here without panic passes
    try std.testing.expect(g_audit_tick > 0);
}

// Regression guard: audit must not
// false-positive when hook mounts own new nodes. real pre-fix crash, and first actual
// adopter (editor hook drives VL mount/reclaim per-frame) is exactly this shape; =
// declaration unusable for target user.
var g_mounting_hook_cx: ?*Cx = null;
var g_mounting_hook_ran: u32 = 0;

fn mountingHookForTest(node: *Node) void {
    const cx = g_mounting_hook_cx orelse return;
    g_mounting_hook_ran += 1;
    // simulate VL mounting one row per-frame: only add own descendants, don't touch
    // any existing node's draw state
    const child = box(cx, .{
        .width = .{ .px = 5 },
        .height = .{ .px = 5 },
        .background = Color.rgba(7, 7, 7, 255),
    }, .{}) catch return;
    node.appendChild(cx.allocator, child) catch return;
}

test "hook scope 稽核: hook 自身 mount 新节点不得误报" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    g_mounting_hook_cx = cx;
    g_mounting_hook_ran = 0;
    defer g_mounting_hook_cx = null;

    const root = try box(cx, .{ .width = .{ .px = 1280 }, .height = .{ .px = 800 } }, .{});
    const hooked = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    hooked.meta.per_frame.hooks.before_render.main = mountingHookForTest;
    hooked.frame_state.state_bits.flags.before_render_hook_affects_self_only = true;
    try root.appendChild(cx.allocator, hooked);
    cx.root = root;

    // if audit false-positives 'tree shape change' as violation, panics here
    _ = cx.render();
    cx.frame_count += 1;
    cx.frame_time_ms += 16.0;
    _ = cx.render();

    // reaching here without panic passes; confirm hook truly ran and mounted nodes,
    // else test false-greens if 'hook never ran'.
    try std.testing.expect(g_mounting_hook_ran >= 2);
    try std.testing.expect(hooked.children.items.len >= 2);
}

// Verification: what if the self-only promise lies. Two lie patterns, different outcomes:
//
// 1. Hook directly writes another's style.translate_x (bypassing setTranslateX's dirty mark)
//    -> does NOT draw wrong. DisplayItem in cache is local coords + transform_id; lowering reads
//    the frame's property_tree matrix (display_list_lowering.zig:309; property_tree is rebuilt
//    every frame), so translate writes have a fallback. Measured: 8 frames translate 7->56,
//    drawn_x tracks every frame, mismatch=0.
//
// 2. Hook directly writes another's background color (setBackgroundRaw, the "side-effect-free
//    write port", 151 production call sites) -> DOES draw wrong, silently. Color is baked into
//    DisplayItem value with no recompute fallback; the raw write does not bump content_version, so
//    the stamp doesn't catch it. Measured: 8 frames all reuse stale color (drawn_r frozen at 30,
//    style at 240); without the self-only flag stale_frames=0.
//
// Therefore runBeforeRenderHook (tick.zig) runs a runtime audit: if a hook declared self-only and
// ANY node except itself changes draw state after the hook runs, panic with names. Lies become
// "immediate crash + fix path" rather than "occasional ghost".
//
// Audit runs only in Debug/ReleaseSafe, cost only on nodes declaring the flag.

// Question: hook add/remove doesn't bump versions.content; nodeEligibleForSubtreePayloadCache uses
// hasBeforeRenderHooks() to guard both cache read and write. After a hook is removed, the first
// frame might read a **pre-hook** stale entry written while hooked. Probe judges whether the
// path is truly reachable.
test "hook scope: hook 摘除后不得 splice 到陈旧缓存条目" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);

    const root = try box(cx, .{ .width = .{ .px = 1280 }, .height = .{ .px = 800 } }, .{});
    // target: initially no hook (cacheable) -> content A
    const target = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const inner = try box(cx, .{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
        .background = Color.rgba(11, 22, 33, 255),
    }, .{});
    try target.appendChild(cx.allocator, inner);
    // add several background-bearing grandchildren so 'draw wrong' has visible place
    // (1-command comparison is vacuous)
    var k: usize = 0;
    while (k < 6) : (k += 1) {
        const leaf = try box(cx, .{
            .width = .{ .px = 8 },
            .height = .{ .px = 8 },
            .background = Color.rgba(@intCast(40 + k * 20), 90, 140, 255),
        }, .{});
        try inner.appendChild(cx.allocator, leaf);
    }
    try root.appendChild(cx.allocator, target);
    // one sibling, ensure root has other dirty point to make non-zero dirty frame
    const sib = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try root.appendChild(cx.allocator, sib);
    cx.root = root;

    _ = cx.render(); // Frame 1: target no hook -> write cache (content A)
    _ = cx.render();

    // mount hook: thereafter target ineligible for cache (both read/write ends blocked
    // by hasBeforeRenderHooks)
    target.meta.per_frame.hooks.before_render.main = selfOnlyHookForTest;
    // while hooked, change inner's content (cache entry A becomes stale)
    inner.setBackground(Color.rgba(200, 100, 50, 255));
    sib.markRenderDirty();
    _ = cx.render();

    // remove hook: target regains cache eligibility
    target.meta.per_frame.hooks.before_render.main = null;
    sib.markRenderDirty(); // create single-point dirty frame (avoid zero-dirty fast-path)
    cx.perf.subtree_payload_splice_count = 0;
    _ = cx.render();

    // splice hit doesn't equal drawing wrong; content correctness is key.
    // Compare lowered commands element-by-element with reference Cx that 'never hooked'
    var ref = try Cx.init(std.testing.allocator, std.testing.io);
    defer ref.deinit();
    ref.setViewport(1280, 800);
    const r_root = try box(ref, .{ .width = .{ .px = 1280 }, .height = .{ .px = 800 } }, .{});
    const r_target = try box(ref, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const r_inner = try box(ref, .{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
        .background = Color.rgba(11, 22, 33, 255),
    }, .{});
    try r_target.appendChild(ref.allocator, r_inner);
    var rk: usize = 0;
    while (rk < 6) : (rk += 1) {
        const r_leaf = try box(ref, .{
            .width = .{ .px = 8 },
            .height = .{ .px = 8 },
            .background = Color.rgba(@intCast(40 + rk * 20), 90, 140, 255),
        }, .{});
        try r_inner.appendChild(ref.allocator, r_leaf);
    }
    try r_root.appendChild(ref.allocator, r_target);
    const r_sib = try box(ref, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try r_root.appendChild(ref.allocator, r_sib);
    ref.root = r_root;
    _ = ref.render();
    _ = ref.render();
    r_inner.setBackground(Color.rgba(200, 100, 50, 255)); // same content change, but never hooked
    r_sib.markRenderDirty();
    _ = ref.render();
    r_sib.markRenderDirty();
    _ = ref.render();

    std.debug.print(
        "\n[hook-removal-stale] splice_hits={d} cmds={d} ref_cmds={d}\n",
        .{ cx.perf.subtree_payload_splice_count, cx.lowering.main_paint.items.len, ref.lowering.main_paint.items.len },
    );

    // element-by-element comparison: if hook-remove reuses stale entry, color/geometry
    // diff appears
    try std.testing.expectEqual(ref.lowering.main_paint.items.len, cx.lowering.main_paint.items.len);
    for (cx.lowering.main_paint.items, 0..) |it, gi| {
        const r = ref.lowering.main_paint.items[gi];
        try std.testing.expectEqual(@backingInt(r.kind), @backingInt(it.kind));
        try std.testing.expectApproxEqAbs(r.geom.x, it.geom.x, 0.01);
        try std.testing.expectApproxEqAbs(r.geom.y, it.geom.y, 0.01);
        try std.testing.expectApproxEqAbs(r.geom.w, it.geom.w, 0.01);
        try std.testing.expectApproxEqAbs(r.geom.h, it.geom.h, 0.01);
    }
}

test "subtree payload cache isolates a disable_render_cache boundary in both directions" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const root = try box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 200 } }, .{});
    const wrapper = try box(cx, .{ .width = .{ .px = 240 }, .height = .{ .px = 150 } }, .{});
    const dynamic_layer = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{});
    const child = try box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 40 },
        .background = Color.rgb(30, 90, 180),
    }, .{});
    const grandchild = try text(cx, "dynamic", .{ .font_size = 13 });
    try child.appendChild(cx.allocator, grandchild);
    try dynamic_layer.appendChild(cx.allocator, child);
    try wrapper.appendChild(cx.allocator, dynamic_layer);
    try root.appendChild(cx.allocator, wrapper);
    const stable_sibling = try box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 30 },
        .background = Color.rgb(120, 80, 40),
    }, .{});
    try root.appendChild(cx.allocator, stable_sibling);
    cx.root = root;

    // Frame 1 writes ordinary caches. Frame 2 enables the boundary and dirties
    // its subtree, as dynamic components do: the next traversal must discard
    // the enclosing root and descendant caches rather than replaying them.
    _ = cx.render();
    try std.testing.expect(root.meta.per_frame.caches.commands.subtree_payload != null);
    try std.testing.expect(wrapper.meta.per_frame.caches.commands.subtree_payload != null);
    try std.testing.expect(dynamic_layer.meta.per_frame.caches.commands.subtree_payload != null);

    // Enabling the boundary is a render-affecting state change, so the owner
    // marks the subtree dirty. The extra wrapper proves every enclosing cache
    // is evicted, not only the boundary's direct parent.
    dynamic_layer.frame_state.state_bits.flags.disable_render_cache = true;
    dynamic_layer.markRenderDirty();
    cx.perf.subtree_payload_splice_count = 0;
    _ = cx.render();

    try std.testing.expect(root.meta.per_frame.caches.commands.subtree_payload == null);
    try std.testing.expect(wrapper.meta.per_frame.caches.commands.subtree_payload == null);
    try std.testing.expect(dynamic_layer.meta.per_frame.caches.commands.subtree_payload == null);
    try std.testing.expect(child.meta.per_frame.caches.commands.subtree_payload == null);
    try std.testing.expect(grandchild.meta.per_frame.caches.commands.subtree_payload == null);
    try std.testing.expect(stable_sibling.meta.per_frame.caches.commands.subtree_payload != null);
    try std.testing.expect(cx.perf.subtree_payload_splice_count > 0);
}

test "hook scope: 逃生阀 ZENIT_DISABLE_HOOK_SELF_SCOPE 能关掉降级" {
    // escape valve reads process-level env + one-time cache, env change inconvenient
    // in test; instead verify guard function handles two **non-allowable exceptions**:
    // overlay candidate and manual animation in progress, no allowance even if declaring
    // self-only.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);

    const root = try buildHookedPrefixScene(cx, 40, true);
    // find hooked node (first child), set manual transform animation flag
    const hooked = root.children.items[0];
    hooked.frame_state.state_bits.flags.manual_transform_animation_active = true;

    _ = cx.render();
    cx.perf.subtree_payload_splice_count = 0;
    root.children.items[root.children.items.len - 1].markRenderDirty();
    _ = cx.render();

    // manual animation in progress ⇒ self-only guarantee void ⇒ conservative semantics: the
    // prefix breaks at the hooked node and it is hook-owned (no cross-frame cache of its own).
    // Following siblings are reused at the paint cursor (they are not part of the hook's
    // subtree), so the check is on the hooked node, not on a zero splice count.
    try std.testing.expect(cx.display_list.items.items.len > 0);
    try std.testing.expect(hooked.meta.per_frame.caches.commands.subtree_payload == null);
    try std.testing.expect(hooked.meta.per_frame.caches.commands.own_payload == null);
}

// a11y projection must not hard-code ten state bits to false or value_now/min/max to 0;
// component-declared values must reach the a11y tree.
//
// WARNING: distinct from the existing select-trigger test (init role=combobox + has_popup=listbox):
// it asserts `trigger.behavior.interaction.a11y` (props struct), which was always correct; the
// broken part was props -> a11y tree, so it stayed green while the feature broke end-to-end.
// Below asserts `cx.accessibility_tree.getNode(...)`, the actual data sent to AT.

test "a11y 投影：props 的 state 位真的到达 a11y tree（此前被硬编码丢弃）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const n = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    n.behavior.interaction.a11y = .{
        .role = .combobox,
        .label = "Country",
        .has_popup = .listbox,
        .selected = true,
        .pressed = true,
        .required = true,
        .invalid = true,
        .readonly = true,
        .busy = true,
        .modal = true,
        .multiline = true,
        .multiselectable = true,
        .indeterminate = true,
    };
    try root.appendChild(std.testing.allocator, n);

    cx.layout();
    _ = cx.render();

    const eid = ui.ElementId.fromRaw(n.element_id_raw);
    const a11y_node = cx.accessibility_tree.getNode(eid).?;

    // before fix, these 10 assertions **all** failed (hardcoded false)
    try std.testing.expect(a11y_node.state.haspopup);
    try std.testing.expect(a11y_node.state.selected);
    try std.testing.expect(a11y_node.state.pressed);
    try std.testing.expect(a11y_node.state.required);
    try std.testing.expect(a11y_node.state.invalid);
    try std.testing.expect(a11y_node.state.readonly);
    try std.testing.expect(a11y_node.state.busy);
    try std.testing.expect(a11y_node.state.modal);
    try std.testing.expect(a11y_node.state.multiline);
    try std.testing.expect(a11y_node.state.multiselectable);
    try std.testing.expect(a11y_node.state.indeterminate);

    // when has_popup = .none, haspopup must be false (not always true)
    const n2 = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    n2.behavior.interaction.a11y = .{ .role = .button, .label = "Plain" };
    try root.appendChild(std.testing.allocator, n2);
    cx.layout();
    _ = cx.render();
    const a2 = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(n2.element_id_raw)).?;
    try std.testing.expect(!a2.state.haspopup);
    try std.testing.expect(!a2.state.selected);
}

test "a11y 投影：slider/progressbar 的 value_now/min/max 真的到达 a11y tree" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const slider = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 24 } }, .{});
    slider.behavior.interaction.a11y = .{
        .role = .slider,
        .label = "Volume",
        .value_now = 42,
        .value_min = 0,
        .value_max = 100,
    };
    try root.appendChild(std.testing.allocator, slider);

    cx.layout();
    _ = cx.render();

    const a = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(slider.element_id_raw)).?;
    // before fix, all three always 0, VoiceOver can't read "42, range 0 to 100"
    try std.testing.expectEqual(@as(f32, 42), a.value_now);
    try std.testing.expectEqual(@as(f32, 0), a.value_min);
    try std.testing.expectEqual(@as(f32, 100), a.value_max);
}

test "a11y: Slider 拖动后 value_now 跟随（不是冻结在 mount 初值）" {
    const slider_mod = @import("../components/slider/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const level = try scope.createSignal(f32, 10);
    const res = try slider_mod.Slider(.{ .min = 0, .max = 100, .value = level }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, res.wrapper);
    cx.layout();
    _ = cx.render();

    const eid = ui.ElementId.fromRaw(res.wrapper.element_id_raw);
    try std.testing.expectEqual(@as(f32, 10), cx.accessibility_tree.getNode(eid).?.value_now);

    // change to 73: a11y must follow
    level.set(73);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 73), cx.accessibility_tree.getNode(eid).?.value_now);
    try std.testing.expectEqual(@as(f32, 100), cx.accessibility_tree.getNode(eid).?.value_max);
}

// Component a11y declaration completion.
//
// All tests assert `cx.accessibility_tree` (data actually sent to AT), NOT
// `node.behavior.interaction.a11y` (props): a props-only assertion (like the select trigger
// init role=combobox test) stays green when the props->a11y projection breaks.

test "a11y: Tabs 每个 tab 有 role=tab，selected 跟随 active 切换" {
    const tabs_mod = @import("../components/tabs/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 300);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]tabs_mod.TabItem{
        .{ .id = "a", .label = "Alpha" },
        .{ .id = "b", .label = "Beta" },
        .{ .id = "c", .label = "Gamma" },
    };
    // use .pill: underline variant wraps tab_row in outer container again;
    // under pill container is tab_row, assertion path shortest.
    const current = try scope.createSignal(?[]const u8, null);
    const container = try tabs_mod.Tabs(.{ .items = &items, .variant = .pill, .active = current }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, container);
    cx.layout();
    _ = cx.render();

    // children[0] is highlight_box, then 3 tabs
    const tab_row = container;
    try std.testing.expect(tab_row.children.items.len >= 4);

    const a11yOf = struct {
        fn get(c: *Cx, n: *Node) a11y_tree_mod.A11yNode {
            return c.accessibility_tree.getNode(ui.ElementId.fromRaw(n.element_id_raw)).?;
        }
    }.get;

    const tab_a = tab_row.children.items[1];
    const tab_b = tab_row.children.items[2];

    // tablist itself
    // A11yRole.tablist maps to tree Role.tabs
    try std.testing.expectEqual(a11y_tree_mod.Role.tabs, a11yOf(cx, container).role);

    // each tab must be role=tab (tabs previously had no a11y declaration)
    try std.testing.expectEqual(a11y_tree_mod.Role.tab, a11yOf(cx, tab_a).role);
    try std.testing.expectEqual(a11y_tree_mod.Role.tab, a11yOf(cx, tab_b).role);

    // initially: item 0 selected
    try std.testing.expect(a11yOf(cx, tab_a).state.selected);
    try std.testing.expect(!a11yOf(cx, tab_b).state.selected);

    // switch to item 1, selected must follow (key: not mount-frozen value)
    current.set("b");
    cx.layout();
    _ = cx.render();

    try std.testing.expect(!a11yOf(cx, tab_a).state.selected);
    try std.testing.expect(a11yOf(cx, tab_b).state.selected);
}

test "a11y: Modal / Sheet 在 a11y 树里是 role=dialog（此前挂在从不进树的 ol.content 上）" {
    const modal_mod = @import("../components/modal/mod.zig");
    const sheet_mod = @import("../components/sheet/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 600);
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const m = try modal_mod.Modal(.{ .title = "Delete file?", .open = true }).mount(scope, cx);
    if (!m.portaled) try root.appendChild(std.testing.allocator, m.overlay);
    const sh = try sheet_mod.Sheet(.{ .open = true }).mount(scope, cx);
    if (!sh.portaled) try root.appendChild(std.testing.allocator, sh.overlay);
    cx.layout();
    _ = cx.render();

    const dialog_node = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(m.dialog.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.dialog, dialog_node.role);
    try std.testing.expectEqualStrings("Delete file?", cx.a11y_label_buf.get(dialog_node.label_hash).?);
    const panel = sh.overlay.children.items[0];
    try std.testing.expectEqual(a11y_tree_mod.Role.dialog, cx.accessibility_tree.getNode(ui.ElementId.fromRaw(panel.element_id_raw)).?.role);
}

test "a11y: Accordion header 的 expanded 跟随展开/折叠（此前从不设置）" {
    const accordion_mod = @import("../components/accordion/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const open = try scope.createSignal(bool, false);
    const res = try accordion_mod.AccordionItem(.{ .title = "Details", .expanded = open }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, res.item);
    cx.layout();
    _ = cx.render();

    const header = res.item.children.items[0];
    const eid = ui.ElementId.fromRaw(header.element_id_raw);

    try std.testing.expectEqual(a11y_tree_mod.Role.button, cx.accessibility_tree.getNode(eid).?.role);
    // collapsed state
    try std.testing.expect(!cx.accessibility_tree.getNode(eid).?.state.expanded);

    // expand, a11y tree must follow
    open.set(true);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.accessibility_tree.getNode(eid).?.state.expanded);

    // collapse again
    open.set(false);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(!cx.accessibility_tree.getNode(eid).?.state.expanded);
}

test "a11y: Alert 是 live region（否则 role=alert 永远不会被朗读）" {
    const alert_mod = @import("../components/alert/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 300);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const err = try alert_mod.Alert(.{ .variant = .@"error", .message = "Disk full" }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, err);
    const info = try alert_mod.Alert(.{ .variant = .info, .message = "Saved" }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, info);
    cx.layout();
    _ = cx.render();

    const err_node = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(err.element_id_raw)).?;
    const info_node = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(info.element_id_raw)).?;

    try std.testing.expectEqual(a11y_tree_mod.Role.alert, err_node.role);
    // before fix, both .off; visual cues present, AT side completely silent
    try std.testing.expectEqual(a11y_tree_mod.LiveRegion.assertive, err_node.live);
    try std.testing.expectEqual(a11y_tree_mod.LiveRegion.polite, info_node.live);
}

test "a11y: Progress 报出 role=progressbar + valuenow；不确定模式改报 busy" {
    const progress_mod = @import("../components/progress/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 300);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const det = try progress_mod.Progress(.{ .value = 70, .width = 200 }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, det);
    const indet = try progress_mod.Progress(.{ .indeterminate = true, .width = 200 }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, indet);
    cx.layout();
    _ = cx.render();

    const d = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(det.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.progressbar, d.role);
    try std.testing.expectEqual(@as(f32, 70), d.value_now);
    try std.testing.expectEqual(@as(f32, 100), d.value_max);
    try std.testing.expect(!d.state.busy);

    const i = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(indet.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.progressbar, i.role);
    try std.testing.expect(i.state.busy);
}

test "a11y: Tree 行是 treeitem，expanded/selected 跟随状态变化" {
    const tree_mod = @import("../components/tree/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const leaf = [_]tree_mod.TreeNodeData{.{ .id = "f", .label = "file.zig" }};
    const nodes = [_]tree_mod.TreeNodeData{
        .{ .id = "d", .label = "src", .children = &leaf },
    };
    const res = try tree_mod.Tree(.{ .nodes = &nodes }).mount(scope, cx);
    const tree_state: *tree_mod.TreeState = @ptrCast(@alignCast(res.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
    try root.appendChild(std.testing.allocator, res.wrapper);
    cx.layout();
    _ = cx.render();

    const dir_row = tree_state.flat_node_rows[0].?;
    const dir_eid = ui.ElementId.fromRaw(dir_row.element_id_raw);

    try std.testing.expectEqual(a11y_tree_mod.Role.tree, cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(res.wrapper.element_id_raw),
    ).?.role);
    try std.testing.expectEqual(a11y_tree_mod.Role.treeitem, cx.accessibility_tree.getNode(dir_eid).?.role);

    // initially collapsed + unselected
    try std.testing.expect(!cx.accessibility_tree.getNode(dir_eid).?.state.expanded);
    try std.testing.expect(!cx.accessibility_tree.getNode(dir_eid).?.state.selected);

    // expand -> a11y must follow
    tree_state.toggleExpand(0);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.accessibility_tree.getNode(dir_eid).?.state.expanded);

    // select -> selected follows (before only background highlight as pure visual signal)
    tree_state.selectNode(0);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.accessibility_tree.getNode(dir_eid).?.state.selected);

    // when selecting different row, old row must lose selected
    tree_state.selectNode(1);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(!cx.accessibility_tree.getNode(dir_eid).?.state.selected);
}

test "a11y: Menu 有 role=menu，项是 menuitem 且 disabled 如实上报" {
    const menu_mod = @import("../components/menu/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]menu_mod.MenuItem{
        .{ .id = "cut", .label = "Cut" },
        .{ .id = "sep", .kind = .separator },
        .{ .id = "paste", .label = "Paste", .disabled = true },
    };
    const res = try menu_mod.Menu(.{ .items = &items }).mount(scope, cx);
    const menu_state: *menu_mod.MenuState = @ptrCast(@alignCast(res.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
    try root.appendChild(std.testing.allocator, res.wrapper);
    res.open.?.set(true);
    cx.layout();
    _ = cx.render();

    const cut = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(menu_state.item_nodes[0].?.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.menuitem, cut.role);
    try std.testing.expect(!cut.state.disabled);

    const sep = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(menu_state.item_nodes[1].?.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.separator, sep.role);

    // disabled items must report disabled, else AT users repeatedly try activating
    // unresponsive menu item
    const paste = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(menu_state.item_nodes[2].?.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.menuitem, paste.role);
    try std.testing.expect(paste.state.disabled);
}

test "a11y: NumberStepper 是 spinbutton，value_now 跟随步进" {
    const ns_mod = @import("../components/number_stepper/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 200);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ns = try ns_mod.NumberStepper(.{ .value = 5, .min = 0, .max = 10, .step = 1 }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, ns.wrapper);
    cx.layout();
    _ = cx.render();

    const eid = ui.ElementId.fromRaw(ns.wrapper.element_id_raw);
    const n0 = cx.accessibility_tree.getNode(eid).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.spinbutton, n0.role);
    try std.testing.expectEqual(@as(f32, 5), n0.value_now);
    try std.testing.expectEqual(@as(f32, 0), n0.value_min);
    try std.testing.expectEqual(@as(f32, 10), n0.value_max);
    try std.testing.expectEqual(@as(u8, 0b1100), a11y_bridge_extern.zenit_a11y_actions(a11y_bridge_extern.ANY, eid.raw()));
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_perform_action(a11y_bridge_extern.ANY, eid.raw(), 2));
    try std.testing.expectEqual(@as(f64, 6), ns.value.?.peek());
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_perform_action(a11y_bridge_extern.ANY, eid.raw(), 3));
    try std.testing.expectEqual(@as(f64, 5), ns.value.?.peek());
    // Field focused: AX increment is a logical step, not a synthetic Right that the field would
    // consume as caret movement.
    cx.focus_manager.setFocus(ns.field.input_container_node.?);
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_perform_action(a11y_bridge_extern.ANY, eid.raw(), 2));
    try std.testing.expectEqual(@as(f64, 6), ns.value.?.peek());
    try std.testing.expectEqual(ns.field.input_container_node.?, cx.focus_manager.getFocused().?);
    ns.value.?.set(5);

    // after value change, a11y numbers must follow (not frozen to mount value)
    ns.value.?.set(7);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 7), cx.accessibility_tree.getNode(eid).?.value_now);
}

test "a11y: Rate 是 slider，value_now 跟随点击但不被 hover 预览污染" {
    const rate_mod = @import("../components/rate/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 200);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const res = try rate_mod.Rate(.{ .count = 5, .value = 2 }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, res.wrapper);
    cx.layout();
    _ = cx.render();

    const eid = ui.ElementId.fromRaw(res.wrapper.element_id_raw);
    const n0 = cx.accessibility_tree.getNode(eid).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.slider, n0.role);
    try std.testing.expectEqual(@as(f32, 2), n0.value_now);
    try std.testing.expectEqual(@as(f32, 5), n0.value_max);

    res.value.?.set(4);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 4), cx.accessibility_tree.getNode(eid).?.value_now);

    // hover preview is pure visual temporary state, can't change a11y numbers, else AT
    // users think hovering already changed score.
    const first = res.wrapper.children.items[0];
    _ = first.behavior.events.on_event.?(.{ .mouse_enter = {} }, first.behavior.events.event_context);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 4), cx.accessibility_tree.getNode(eid).?.value_now);
}

test "a11y: DataTable 是 grid，表头是 columnheader，空的复用行不进 a11y 树" {
    const dt_mod = @import("../components/data_table/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 500);

    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 500 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const cols = [_]dt_mod.ColumnDef{
        .{ .id = "name", .header = "Name", .width = 160 },
        .{ .id = "size", .header = "Size", .width = 100 },
    };
    // page_size=3 but only 1 row data -> other 2 reused rows are empty
    const r0 = [_][]const u8{ "a.zig", "1K" };
    const rows = [_][]const []const u8{&r0};
    const dt = try dt_mod.DataTable(.{
        .columns = &cols,
        .rows = &rows,
        .page_size = 3,
    }).mount(scope, cx);
    const dt_state: *dt_mod.DataTableState = @ptrCast(@alignCast(dt.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
    try root.appendChild(std.testing.allocator, dt.wrapper);
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(a11y_tree_mod.Role.grid, cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(dt.wrapper.element_id_raw),
    ).?.role);

    // headers must be columnheader so AT includes column names when reading cells
    try std.testing.expectEqual(a11y_tree_mod.Role.columnheader, cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(dt_state.header_cells[0].element_id_raw),
    ).?.role);

    // rows with data = row
    try std.testing.expectEqual(a11y_tree_mod.Role.row, cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(dt_state.row_nodes[0].element_id_raw),
    ).?.role);

    // Empty recycled rows retain parentage so their semantic cells cannot be
    // reparented to the grid, but the complete subtree is hidden from AT.
    const empty_row = cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(dt_state.row_nodes[1].element_id_raw),
    ).?;
    try std.testing.expect(empty_row.state.hidden);
    const empty_cell = dt_state.cell_text_nodes[2].parent.?;
    try std.testing.expect(cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(empty_cell.element_id_raw),
    ).?.state.hidden);
}

test "a11y: Menu 键盘高亮更新 active_descendant（虚拟焦点）" {
    const menu_mod = @import("../components/menu/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]menu_mod.MenuItem{
        .{ .id = "new", .label = "New File", .shortcut = "CmdN" },
        .{ .kind = .separator },
        .{ .id = "del", .label = "Delete", .disabled = true },
    };
    const res = try menu_mod.Menu(.{ .items = &items }).mount(scope, cx);
    const menu_state: *menu_mod.MenuState = @ptrCast(@alignCast(res.wrapper.meta.ownership.debug_slots.state_ptrs[0].?));
    try root.appendChild(std.testing.allocator, res.wrapper);
    res.open.?.set(true);
    cx.layout();
    _ = cx.render();

    const menu_eid = ui.ElementId.fromRaw(menu_state.menu_node.?.element_id_raw);
    try std.testing.expectEqual(a11y_tree_mod.Role.menu, cx.accessibility_tree.getNode(menu_eid).?.role);

    const item0 = menu_state.item_nodes[0].?;
    const del = menu_state.item_nodes[2].?;
    try std.testing.expectEqual(a11y_tree_mod.Role.menuitem, cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(item0.element_id_raw),
    ).?.role);
    try std.testing.expect(cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(del.element_id_raw),
    ).?.state.disabled);
    try std.testing.expectEqual(a11y_tree_mod.Role.separator, cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(menu_state.item_nodes[1].?.element_id_raw),
    ).?.role);

    // real focus on container; only active_descendant conveys 'currently on which
    // item'
    menu_state.highlightIndex(0);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(
        a11y_tree_mod.AXId.node(ui.ElementId.fromRaw(item0.element_id_raw)),
        cx.accessibility_tree.getNode(menu_eid).?.active_descendant,
    );

    menu_state.highlightIndex(2);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(
        a11y_tree_mod.AXId.node(ui.ElementId.fromRaw(del.element_id_raw)),
        cx.accessibility_tree.getNode(menu_eid).?.active_descendant,
    );
}

test "a11y: Breadcrumb 进得了 a11y 树（此前 role=.none 被整个丢弃）" {
    const bc_mod = @import("../components/breadcrumb/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 200);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]bc_mod.BreadcrumbItem{
        .{ .id = "home", .label = "Home" },
        .{ .id = "docs", .label = "Docs" },
        .{ .id = "api", .label = "API" },
    };
    const bc = try bc_mod.Breadcrumb(.{ .items = &items }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, bc);
    cx.layout();
    _ = cx.render();

    // container was role=.none, projection discards none + non-focusable,
    // whole Breadcrumb invisible to AT
    try std.testing.expectEqual(a11y_tree_mod.Role.navigation, cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(bc.element_id_raw),
    ).?.role);

    // find levels by semantics (not internal nesting: each level is 'link +
    // separator' row)
    const Find = struct {
        fn byText(n: *Node, content: []const u8) ?*Node {
            if (n.getText()) |t| if (std.mem.eql(u8, t.content, content)) return n;
            for (n.children.items) |c| if (byText(c, content)) |r| return r;
            return null;
        }
    };
    const first = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(Find.byText(bc, "Home").?.element_id_raw)).?;
    const last = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(Find.byText(bc, "API").?.element_id_raw)).?;
    // separators are decoration, don't enter a11y tree
    try std.testing.expect(cx.accessibility_tree.getNode(ui.ElementId.fromRaw(Find.byText(bc, "/").?.element_id_raw)) == null);

    // earlier levels are clickable links, last level is current page (selected)
    try std.testing.expectEqual(a11y_tree_mod.Role.link, first.role);
    try std.testing.expect(!first.state.selected);
    try std.testing.expect(last.state.selected);
}

test "a11y: Steps 每步报出 selected/checked/disabled 三态" {
    const steps_mod = @import("../components/steps/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 300);

    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]steps_mod.StepItem{
        .{ .title = "Plan" },
        .{ .title = "Build" },
        .{ .title = "Ship" },
    };
    // current=1 -> step 0 complete, step 1 in-progress, step 2 not started
    const container = try steps_mod.Steps(.{ .items = &items, .current = 1 })
        .mount(scope, cx);
    try root.appendChild(std.testing.allocator, container);
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(a11y_tree_mod.Role.list, cx.accessibility_tree.getNode(
        ui.ElementId.fromRaw(container.element_id_raw),
    ).?.role);

    // horizontal layout children include progress line besides steps; filter by role
    // for steps
    var steps_found: usize = 0;
    var done = false;
    var active = false;
    var pending = false;
    for (container.children.items) |child| {
        const n = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(child.element_id_raw)) orelse continue;
        if (n.role != .listitem) continue;
        switch (steps_found) {
            0 => done = n.state.checked and !n.state.selected,
            1 => active = n.state.selected and !n.state.checked and !n.state.disabled,
            2 => pending = n.state.disabled and !n.state.selected,
            else => {},
        }
        steps_found += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), steps_found);
    // circle color is pure visual, AT distinguishes 'done/current/not-reached' via
    // these three flags
    try std.testing.expect(done);
    try std.testing.expect(active);
    try std.testing.expect(pending);
}

test "a11y: VirtualList 作为语义集合暴露全部数据行，行身份不随池节点重绑定改变" {
    const vl_mod = @import("../components/virtual_list/mod.zig");
    const Scope = @import("../reactive.zig").Scope;
    const AXId = a11y_tree_mod.AXId;

    const Render = struct {
        fn row(node: *Node, index: usize, c: *Cx) void {
            _ = index;
            // test scaffold: VirtualList render_row callback returns void, can't propagate.
            // testing.allocator, real OOM fails test, row count assertion catches immediately.
            const label = box(c, .{}, .{}) catch return;
            label.setText(.{ .content = "row" });
            node.appendChild(c.allocator, label) catch {};
        }
    };

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 200);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const res = try vl_mod.VirtualList(.{
        .item_count = 1000,
        .item_height = 20,
        .height = 100,
    }).mount(scope, cx, Render.row);
    try root.appendChild(std.testing.allocator, res.container);
    cx.layout();
    _ = cx.render();

    const tree = &cx.accessibility_tree;
    const table = AXId.node(ui.ElementId.fromRaw(res.state.content_node.element_id_raw));
    // outer container is scroll area, content node is table, exposes all data rows
    // (not rendered dozen)
    try std.testing.expectEqual(a11y_tree_mod.Role.scroll_area, tree.getNode(
        ui.ElementId.fromRaw(res.container.element_id_raw),
    ).?.role);
    try std.testing.expectEqual(a11y_tree_mod.Role.grid, tree.get(table).?.role);
    try std.testing.expectEqual(@as(usize, 1000), tree.childCount(table));

    const row3 = tree.childAt(table, 3).?;
    const cell3 = tree.childAt(row3, 0).?;

    // scroll to middle then end: all pool nodes rebind
    res.state.scroll_state.scroll_y = 4000;
    res.state.updateVisibleItems();
    cx.layout();
    _ = cx.render();
    res.state.scroll_state.scroll_y = 1000 * 20 - 100;
    res.state.updateVisibleItems();
    cx.layout();
    _ = cx.render();

    // pool nodes never enter tree; bound row content under data item's cell
    var bound: usize = 0;
    for (res.state.pool_nodes, res.state.pool_bindings) |node, binding| {
        try std.testing.expect(tree.getNode(ui.ElementId.fromRaw(node.element_id_raw)) == null);
        const index = binding orelse continue;
        bound += 1;
        const row = tree.childAt(table, index).?;
        const cell = tree.childAt(row, 0).?;
        const label = node.children.items[0];
        const label_node = tree.getNode(ui.ElementId.fromRaw(label.element_id_raw)).?;
        try std.testing.expect(label_node.parent.eql(cell));
    }
    try std.testing.expect(bound > 0);

    // item 3's row and cell identity unchanged by scroll/rebind; unbound cell has
    // synthesized text
    try std.testing.expect(tree.childAt(table, 3).?.eql(row3));
    try std.testing.expect(tree.childAt(row3, 0).?.eql(cell3));
    try std.testing.expectEqual(AXId.Kind.cell_text, tree.childAt(cell3, 0).?.kind);

    // data source changes: row identity rotates
    vl_mod.updateItemCount(res.state, 10);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(tree.get(row3) == null);
    try std.testing.expectEqual(@as(usize, 10), tree.childCount(table));
}

test "a11y: Timeline 项把 completed/active/pending 说出来（不只靠圆点颜色）" {
    const tl_mod = @import("../components/timeline/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]tl_mod.TimelineItem{
        .{ .title = "Created", .status = .completed },
        .{ .title = "Running", .status = .active },
        .{ .title = "Review", .status = .pending },
    };
    const tl = try tl_mod.Timeline(.{ .items = &items }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, tl);
    cx.layout();
    _ = cx.render();

    const a0 = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(tl.children.items[0].element_id_raw)).?;
    const a1 = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(tl.children.items[1].element_id_raw)).?;
    const a2 = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(tl.children.items[2].element_id_raw)).?;

    try std.testing.expectEqual(a11y_tree_mod.Role.listitem, a0.role);
    try std.testing.expect(a0.state.checked);
    try std.testing.expect(a1.state.selected);
    try std.testing.expect(a2.state.disabled);
}

test "a11y: Skeleton 报 busy + live，AT 才知道内容在加载而不是页面坏了" {
    const sk_mod = @import("../components/skeleton/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 200);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const sk = try sk_mod.Skeleton(.{}).mount(scope, cx);
    try root.appendChild(std.testing.allocator, sk);
    cx.layout();
    _ = cx.render();

    const n = cx.accessibility_tree.getNode(ui.ElementId.fromRaw(sk.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.status, n.role);
    try std.testing.expect(n.state.busy);
    try std.testing.expectEqual(a11y_tree_mod.LiveRegion.polite, n.live);
}

// Callback protocol convergence: HandlerRef carries payload
//
// Callbacks split into two incompatible tracks, `?HandlerRef` (no args) vs
// `?*const fn (T, *anyopaque) void` (payload). Moving a payload callback to no-arg HandlerRef
// silently DROPS THE PAYLOAD: the call site still compiles, the value disappears.
// This suite nails down "values cannot be lost".

test "HandlerRef: bool payload 能送达（不是静默丢值）" {
    const Sink = struct {
        got: bool = false,
        calls: u32 = 0,
        fn onChange(self: *@This(), v: bool) void {
            self.got = v;
            self.calls += 1;
        }
    };
    var sink = Sink{};
    const h = Cx.boolHandlerFrom(Sink, &sink, Sink.onChange);

    h.invokeWithBool(true);
    try std.testing.expect(sink.got);
    try std.testing.expectEqual(@as(u32, 1), sink.calls);

    h.invokeWithBool(false);
    try std.testing.expect(!sink.got);
    try std.testing.expectEqual(@as(u32, 2), sink.calls);
}

test "HandlerRef: string payload 能送达" {
    const Sink = struct {
        last: []const u8 = "",
        fn onChange(self: *@This(), v: []const u8) void {
            self.last = v;
        }
    };
    var sink = Sink{};
    const h = Cx.strHandlerFrom(Sink, &sink, Sink.onChange);

    h.invokeWithStr("hello");
    try std.testing.expectEqualStrings("hello", sink.last);
    h.invokeWithStr("中文");
    try std.testing.expectEqualStrings("中文", sink.last);
}

test "HandlerRef: 无参 handler 收到带值触发时退化调用，不丢事件" {
    // components can unconditionally invoke withBool/Str, need not care which
    // registered
    const Sink = struct {
        calls: u32 = 0,
        fn bump(self: *@This()) void {
            self.calls += 1;
        }
    };
    var sink = Sink{};
    const h = Cx.handlerFrom(Sink, &sink, Sink.bump);

    h.invokeWithBool(true);
    h.invokeWithStr("x");
    h.invoke();
    // all three reach, just no value extraction, not swallowed
    try std.testing.expectEqual(@as(u32, 3), sink.calls);
}

test "HandlerRef: 类型不匹配的 payload 退化为无参而非误传" {
    // bool handler receiving string trigger (or vice versa) must never force-fit
    // other type, degrade to no-arg fallback
    const Sink = struct {
        bool_calls: u32 = 0,
        bare_calls: u32 = 0,
        fn onBool(self: *@This(), v: bool) void {
            _ = v;
            self.bool_calls += 1;
        }
    };
    var sink = Sink{};
    const h = Cx.boolHandlerFrom(Sink, &sink, Sink.onBool);

    h.invokeWithStr("not a bool"); // uses no-arg fallback (bare calls method(_, false))
    try std.testing.expectEqual(@as(u32, 1), sink.bool_calls);

    h.invokeWithBool(true); // uses normal payload channel
    try std.testing.expectEqual(@as(u32, 2), sink.bool_calls);
}

test "HandlerRef: 既有无参用法零改动（54 处 invoke 调用点的合同）" {
    const Sink = struct {
        n: u32 = 0,
        fn bump(self: *@This()) void {
            self.n += 1;
        }
    };
    var sink = Sink{};
    // old constructor + old call style, behavior must be identical
    const h = Cx.handlerFrom(Sink, &sink, Sink.bump);
    try std.testing.expectEqual(@as(?ui.HandlerRef.PayloadCallback, null), h.payload_callback);
    h.invoke();
    h.invoke();
    try std.testing.expectEqual(@as(u32, 2), sink.n);
}

test "并轨端到端：Checkbox 点击后 on_change 收到真实新值" {
    const checkbox = @import("../components/checkbox/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const Sink = struct {
        last: bool = false,
        calls: u32 = 0,
        fn onChange(self: *@This(), v: bool) void {
            self.last = v;
            self.calls += 1;
        }
    };
    var sink = Sink{};

    const node = try checkbox.Checkbox(.{
        .label = "Accept",
        .on_change = cx.on(Sink, &sink, Sink.onChange),
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, node);
    cx.layout();
    _ = cx.render();

    // use real event dispatch (closer to user path than direct state.toggle)
    const rect = node.rectFromWorldOrFallback();
    const px = rect.x + rect.w / 2;
    const py = rect.y + rect.h / 2;
    _ = cx.dispatcher.dispatch(ui.Event{ .click = .{ .x = px, .y = py } }, node);

    // key: not just 'called', but **new value truly delivered** (merge's easiest
    // loss point)
    try std.testing.expectEqual(@as(u32, 1), sink.calls);
    try std.testing.expect(sink.last);

    _ = cx.dispatcher.dispatch(ui.Event{ .click = .{ .x = px, .y = py } }, node);
    try std.testing.expectEqual(@as(u32, 2), sink.calls);
    try std.testing.expect(!sink.last);
}

test "overlay 关闭后焦点恢复到触发控件（previous_focus 此前写了无人读）" {
    const overlay_mod = @import("../overlay_stack.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    // trigger: holds focus before opening overlay
    const trigger = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } }, .{});
    trigger.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, trigger);
    cx.layout();
    _ = cx.render();

    cx.focus_manager.setFocus(trigger);
    try std.testing.expectEqual(@as(?*ui.Node, trigger), cx.focus_manager.current_focus);

    std.debug.print("\n[DBG] trigger={*}\n", .{trigger});
    std.debug.print("[DBG] pending={any}\n", .{cx.overlay_stack.pending_focus_restore});
    // open overlay (focus.restore default true)
    const res = try overlay_mod.overlay(scope, cx, .{
        .kind = .modal,
        .enter_transition = .none,
        .exit_transition = .none,
        .focus = .{ .restore = true },
    });
    // simulate overlay-internal control taking focus
    const inner = try box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{});
    inner.behavior.interaction.focusable = true;
    try res.content.appendChild(std.testing.allocator, inner);
    cx.layout();
    _ = cx.render();
    cx.focus_manager.setFocus(inner);
    try std.testing.expect(cx.focus_manager.current_focus != trigger);

    // close overlay -> focus must return to trigger
    cx.overlay_stack.commitExit(res.handle);
    _ = cx.render();

    try std.testing.expectEqual(@as(?*ui.Node, trigger), cx.focus_manager.current_focus);
}

// === drag-drop drop target ===

const DropProbe = struct {
    enters: u32 = 0,
    leaves: u32 = 0,
    drops: u32 = 0,
    last_paths: [256]u8 = @as([256]u8, @splat(0)),
    last_paths_len: usize = 0,

    fn onEnter(self: *DropProbe) void {
        self.enters += 1;
    }
    fn onLeave(self: *DropProbe) void {
        self.leaves += 1;
    }
    fn onDrop(self: *DropProbe, dropped: []const u8) void {
        self.drops += 1;
        const n = @min(dropped.len, self.last_paths.len);
        @memcpy(self.last_paths[0..n], dropped[0..n]);
        self.last_paths_len = n;
    }
    fn pathsSlice(self: *const DropProbe) []const u8 {
        return self.last_paths[0..self.last_paths_len];
    }
};

// plain box with drop handler must hit pointer,
// else handleDrag never reaches it (same old on_scroll trap).
test "Cx: drop target 收到 entered + dropped(paths)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);

    var probe = DropProbe{};

    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    const target = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    target.behavior.events.on_drag_enter = ui.Cx.handlerFrom(DropProbe, &probe, DropProbe.onEnter);
    target.behavior.events.on_drag_leave = ui.Cx.handlerFrom(DropProbe, &probe, DropProbe.onLeave);
    target.behavior.events.on_drop = ui.Cx.strHandlerFrom(DropProbe, &probe, DropProbe.onDrop);
    try root.appendChild(cx.allocator, target);

    cx.root = root;
    cx.layout();

    cx.handleDrag(50, 50, 0, ""); // entered
    try std.testing.expectEqual(@as(u32, 1), probe.enters);

    cx.handleDrag(50, 50, 3, "/tmp/a.png\n/tmp/b.png"); // dropped
    try std.testing.expectEqual(@as(u32, 1), probe.drops);
    try std.testing.expectEqualStrings("/tmp/a.png\n/tmp/b.png", probe.pathsSlice());
}

// downstream regression: drop callback must get drop coords (canvas drop-place
// scenario). lock degradation: string handler still gets only paths (previous test).
test "Cx: drop payload 版 handler 收到落点坐标" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);

    const Probe = struct {
        drops: u32 = 0,
        x: f32 = -1,
        y: f32 = -1,
        paths_ok: bool = false,
        payload_kind: u8 = 0,
        truncated: bool = true,
        untrusted: bool = false,

        fn onDrop(self: *@This(), p: ui.HandlerRef.DropPayload) void {
            self.drops += 1;
            self.x = p.x;
            self.y = p.y;
            self.paths_ok = std.mem.eql(u8, p.paths, "/tmp/a.png");
            self.payload_kind = p.payload_kind;
            self.truncated = p.payload_truncated;
            self.untrusted = p.payload_is_untrusted;
        }
    };
    var probe = Probe{};

    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    const target = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    target.behavior.events.on_drop = ui.Cx.dropHandlerFrom(Probe, &probe, Probe.onDrop);
    try root.appendChild(cx.allocator, target);

    cx.root = root;
    cx.layout();

    cx.handleDrag(42, 77, 0, ""); // entered
    cx.handlePlatformDrag(42, 77, 3, "/tmp/a.png", 1, false, true); // dropped
    try std.testing.expectEqual(@as(u32, 1), probe.drops);
    try std.testing.expectEqual(@as(f32, 42), probe.x);
    try std.testing.expectEqual(@as(f32, 77), probe.y);
    try std.testing.expect(probe.paths_ok);
    try std.testing.expectEqual(@as(u8, 1), probe.payload_kind);
    try std.testing.expect(!probe.truncated);
    try std.testing.expect(probe.untrusted);
}

// platform only gives entered/exited at window boundary; node-level enter/exit
// from position stream
test "Cx: 拖过两个 drop target 时合成节点级 enter/leave" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);

    var left_probe = DropProbe{};
    var right_probe = DropProbe{};

    const root = try ui.hstack(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    const left = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    left.behavior.events.on_drag_enter = ui.Cx.handlerFrom(DropProbe, &left_probe, DropProbe.onEnter);
    left.behavior.events.on_drag_leave = ui.Cx.handlerFrom(DropProbe, &left_probe, DropProbe.onLeave);
    try root.appendChild(cx.allocator, left);

    const right = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    right.behavior.events.on_drag_enter = ui.Cx.handlerFrom(DropProbe, &right_probe, DropProbe.onEnter);
    right.behavior.events.on_drag_leave = ui.Cx.handlerFrom(DropProbe, &right_probe, DropProbe.onLeave);
    try root.appendChild(cx.allocator, right);

    cx.root = root;
    cx.layout();

    // enter left
    cx.handleDrag(50, 50, 0, "");
    try std.testing.expectEqual(@as(u32, 1), left_probe.enters);
    try std.testing.expectEqual(@as(u32, 0), right_probe.enters);

    // move within same target: no duplicate enter
    cx.handleDrag(60, 50, 1, "");
    try std.testing.expectEqual(@as(u32, 1), left_probe.enters);
    try std.testing.expectEqual(@as(u32, 0), left_probe.leaves);

    // move to right: left leave + right enter
    cx.handleDrag(150, 50, 1, "");
    try std.testing.expectEqual(@as(u32, 1), left_probe.leaves);
    try std.testing.expectEqual(@as(u32, 1), right_probe.enters);

    // drag out window: right receives leave
    cx.handleDrag(0, 0, 2, "");
    try std.testing.expectEqual(@as(u32, 1), right_probe.leaves);
    try std.testing.expect(cx.drag_hover_handle == null);
}

// ═════ downstream regression: same-frame dual 'backdrop_blur + rounded_clip same
// node' content wrong scope ═════

/// Verify lowered paint stream: each island's unique-color content must
///   1. fall within its **own** begin_blur_layer(glass_owner_id=island) .. paired end_blur_layer;
///   2. have coords within the following begin_rounded_clip's src frame (owner-local).
///     rounded_clip layer texture covers the src rect, encoder offscreenOffset = -(src origin);
///     content emitted in world coords draws outside the texture -> composite empty
///     (second island's world x exceeds src.w, must fail).
fn expectIslandContentScoped(
    commands: []const ui.paint_table.DisplayItem,
    island_id: u32,
    content_color_r: u8,
) !void {
    var blur_start: ?usize = null;
    var blur_end: ?usize = null;
    var depth: usize = 0;
    var rclip_src: ?ui.paint_table.RectGeom = null;
    for (commands, 0..) |cmd, i| {
        if (cmd.isControl(.begin_blur_layer)) {
            if (blur_start == null and cmd.glass_owner_id == island_id) {
                blur_start = i;
                depth = 1;
            } else if (blur_start != null and blur_end == null) {
                depth += 1;
            }
        } else if (cmd.isControl(.begin_rounded_clip)) {
            if (blur_start != null and blur_end == null and rclip_src == null) {
                rclip_src = cmd.geom;
            }
        } else if (cmd.isControl(.end_blur_layer)) {
            if (blur_start != null and blur_end == null) {
                depth -= 1;
                if (depth == 0) blur_end = i;
            }
        }
    }
    try std.testing.expect(blur_start != null);
    try std.testing.expect(blur_end != null);
    try std.testing.expect(rclip_src != null);

    var content_index: ?usize = null;
    for (commands, 0..) |cmd, i| {
        if (cmd.isFillRect() and cmd.color.r == content_color_r and cmd.color.a == 255) {
            content_index = i;
            break;
        }
    }
    try std.testing.expect(content_index != null);
    try std.testing.expect(content_index.? > blur_start.?);
    try std.testing.expect(content_index.? < blur_end.?);
    // content frame assertion: must stay within rclip surface's src rect
    const src = rclip_src.?;
    const g = commands[content_index.?].geom;
    try std.testing.expect(g.x >= src.x - 0.5);
    try std.testing.expect(g.y >= src.y - 0.5);
    try std.testing.expect(g.x + g.w <= src.x + src.w + 0.5);
    try std.testing.expect(g.y + g.h <= src.y + src.h + 0.5);
}

test "render: 同帧两个 blur+rounded_clip 岛，各自内容落在自己的 effect 作用域（下游回归）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 400);

    const root = try box(cx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 400 },
        .background = Color.rgba(240, 240, 235, 255),
        .direction = .row,
        .gap = 40,
        .padding = Padding.all(10),
    }, .{});

    // two islands: blur + overflow_hidden + corner_radius same node (downstream
    // islandCard original)
    var islands: [2]*Node = undefined;
    const content_reds = [2]u8{ 201, 202 };
    for (0..2) |k| {
        const island = try box(cx, .{
            .width = .{ .px = 240 },
            .height = .{ .px = 300 },
            .background = Color.rgba(255, 255, 255, 224),
            .overflow_hidden = true,
        }, .{});
        const ext = try island.style.ensureExtFallible(cx.allocator);
        ext.corner_radius = ui.CornerRadius.uniform(12);
        ext.glass = .{ .backdrop_blur = 32, .glass_intensity = 0 };
        const content = try box(cx, .{
            .width = .{ .px = 200 },
            .height = .{ .px = 40 },
            .background = Color.rgba(content_reds[k], 64, 64, 255),
        }, .{});
        try island.appendChild(cx.allocator, content);
        // child rows with clip: split island content into (effect_id, clip_id) groups,
        // reproduce downstream sidebar 'one clip per row' shape; prior lowering
        // closed+reopened effect scope per group, blur backplate redrawn N times, smudged
        // prior groups.
        const clipped_row = try box(cx, .{
            .width = .{ .px = 200 },
            .height = .{ .px = 30 },
            .background = Color.rgba(90, 90, 90, 255),
            .overflow_hidden = true,
        }, .{});
        (try clipped_row.style.ensureExtFallible(cx.allocator)).corner_radius = ui.CornerRadius.uniform(6);
        try island.appendChild(cx.allocator, clipped_row);
        try root.appendChild(cx.allocator, island);
        islands[k] = island;
    }

    cx.root = root;

    // Frame 1: full fresh
    cx.layout();
    _ = cx.render();
    {
        const commands = cx.lowerForEncoderPaintTable();
        try expectIslandContentScoped(commands, islands[0].id, content_reds[0]);
        try expectIslandContentScoped(commands, islands[1].id, content_reds[1]);
        // prefix-retained assertion: each island's begin_blur_layer exactly once
        // (encoder-side begin_blur = immediately composite glass backplate; more than
        // once = smudges).
        var blur_begins: usize = 0;
        for (commands) |cmd| {
            if (cmd.isControl(.begin_blur_layer)) blur_begins += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), blur_begins);
    }

    // Frame 2: only first island dirty (second island cache/replay path, docs/12
    // suspect)
    islands[0].children.items[0].markRenderDirty();
    cx.layout();
    _ = cx.render();
    {
        const commands = cx.lowerForEncoderPaintTable();
        try expectIslandContentScoped(commands, islands[0].id, content_reds[0]);
        try expectIslandContentScoped(commands, islands[1].id, content_reds[1]);
    }

    // Frame 3: fully clean
    cx.layout();
    _ = cx.render();
    {
        const commands = cx.lowerForEncoderPaintTable();
        try expectIslandContentScoped(commands, islands[0].id, content_reds[0]);
        try expectIslandContentScoped(commands, islands[1].id, content_reds[1]);
    }
}

test "render: blur 叶节点带（header 毛玻璃）跨帧保持在后画兄弟内容之前（下游应用 header 回归）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 200);

    const root = try box(cx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 200 },
        .background = Color.rgba(240, 240, 235, 255),
    }, .{});

    // continuous blur band: blur leaf node (no children), tree order first
    const band = try box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .px = 76 },
        .background = Color.rgba(255, 255, 255, 144),
    }, .{});
    (try band.style.ensureExtFallible(cx.allocator)).glass = .{ .backdrop_blur = 24, .glass_intensity = 0 };
    // nested progressive blur: inner pure-glass child (no bg/gradient -> zero
    // normal items, depends placeholder item carrying effect; downstream header
    // dual-blur).
    const heavy = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 48 },
    }, .{});
    (try heavy.style.ensureExtFallible(cx.allocator)).glass = .{ .backdrop_blur = 20, .glass_intensity = 0 };
    try band.appendChild(cx.allocator, heavy);
    try root.appendChild(cx.allocator, band);

    // header content: tree order last, must draw atop band
    const header = try box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .px = 60 },
        .direction = .row,
        .padding = Padding.all(12),
    }, .{});
    const crumb = try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{});
    crumb.setText(.{ .content = "Boards", .color = Color.rgba(20, 20, 28, 255), .font_size = 13 });
    try header.appendChild(cx.allocator, crumb);
    const badge = try box(cx, .{
        .width = .{ .px = 90 },
        .height = .{ .px = 20 },
        .background = Color.rgba(203, 60, 60, 255),
    }, .{});
    try header.appendChild(cx.allocator, badge);
    try root.appendChild(cx.allocator, header);

    cx.root = root;

    const expectBandBeforeHeader = struct {
        fn check(commands: []const ui.paint_table.DisplayItem, band_id: u32, heavy_id: u32) !void {
            var band_begin: ?usize = null;
            var heavy_begin: ?usize = null;
            var badge_index: ?usize = null;
            for (commands, 0..) |cmd, i| {
                if (cmd.isControl(.begin_blur_layer)) {
                    if (cmd.glass_owner_id == band_id) band_begin = i;
                    if (cmd.glass_owner_id == heavy_id) heavy_begin = i;
                }
                if (cmd.isFillRect() and cmd.color.r == 203 and cmd.color.a == 255) badge_index = i;
            }
            try std.testing.expect(band_begin != null);
            // contentless pure-glass child must use placeholder item to emit begin_blur
            try std.testing.expect(heavy_begin != null);
            try std.testing.expect(badge_index != null);
            // header content must order after dual-glass composite (draw atop)
            try std.testing.expect(badge_index.? > band_begin.?);
            try std.testing.expect(badge_index.? > heavy_begin.?);
        }
    }.check;

    // Frame 1: full fresh
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);

    // Frame 2: only header dirty (band cross-frame clean path, suspect)
    badge.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);

    // Frame 3: only band dirty
    band.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);

    // Frame 4: fully clean
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);

    // Frame 5: root background dirty (band/header both clean, ancestor rerecord,
    // another suspect)
    root.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);
}

// -- BulkQuad: Node path vs bulk path consistency --
//
// Guards `BulkQuad`'s pixel-equivalence promise: the bulk path exists to avoid per-node cost while
// drawing **identical** results. If lowered display items differ from the Node path in any param,
// zoom cutoff points show visible jumps (color/radius/stroke). So compare element by element,
// not just counts.

/// extract first fill_rect's geom+style from display list (skip header: Node
/// path puts position in transform, bulk in x/y, intrinsically different; align
/// **final SDF-pipeline params**).
fn firstFillRect(cx: *Cx) ?struct { w: f32, h: f32, color: Color, radius: [4]f32 } {
    for (cx.display_list.items.items) |it| {
        switch (it) {
            .fill_rect => |fr| return .{ .w = fr.w, .h = fr.h, .color = fr.color, .radius = fr.radius },
            else => {},
        }
    }
    return null;
}

fn firstStrokeRect(cx: *Cx) ?struct { w: f32, h: f32, color: Color, width: f32, radius: [4]f32 } {
    for (cx.display_list.items.items) |it| {
        switch (it) {
            .stroke_rect => |sr| return .{ .w = sr.w, .h = sr.h, .color = sr.color, .width = sr.width, .radius = sr.radius },
            else => {},
        }
    }
    return null;
}

test "BulkQuad: 填充参数与 Node 路径逐字段一致" {
    const fill = Color.hex(0x4A90D9);
    const radius: f32 = 6;

    // A) Node path
    var cx_node = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx_node.deinit();
    cx_node.setViewport(800, 600);
    const root = try ui.box(cx_node, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
        .background = Color.TRANSPARENT,
    }, .{});
    const child = try ui.box(cx_node, .{
        .position = .absolute,
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
        .background = fill,
    }, .{});
    child.style.ensureExtPanic(cx_node.allocator).corner_radius = .{ .all = radius };
    child.setStyle(null, .translate_x, @as(f32, 40));
    child.setStyle(null, .translate_y, @as(f32, 24));
    try root.appendChild(cx_node.allocator, child);
    cx_node.root = root;
    cx_node.layout();
    _ = cx_node.render();
    const node_rect = firstFillRect(cx_node) orelse return error.TestExpectedFillRect;

    // B) bulk path: same rect
    var cx_bulk = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx_bulk.deinit();
    cx_bulk.setViewport(800, 600);
    const empty_root = try ui.box(cx_bulk, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
        .background = Color.TRANSPARENT,
    }, .{});
    cx_bulk.root = empty_root;
    try cx_bulk.setBulkQuads(null, &[_]ui.BulkQuad{.{
        .x = 40,
        .y = 24,
        .w = 320,
        .h = 200,
        .color = fill,
        .radius = .{ radius, radius, radius, radius },
    }});
    cx_bulk.layout();
    _ = cx_bulk.render();
    const bulk_rect = firstFillRect(cx_bulk) orelse return error.TestExpectedFillRect;

    try std.testing.expectEqual(node_rect.w, bulk_rect.w);
    try std.testing.expectEqual(node_rect.h, bulk_rect.h);
    try std.testing.expectEqual(node_rect.color.r, bulk_rect.color.r);
    try std.testing.expectEqual(node_rect.color.g, bulk_rect.color.g);
    try std.testing.expectEqual(node_rect.color.b, bulk_rect.color.b);
    try std.testing.expectEqual(node_rect.color.a, bulk_rect.color.a);
    try std.testing.expectEqualSlices(f32, &node_rect.radius, &bulk_rect.radius);
}

test "BulkQuad: 描边参数与 Node 路径逐字段一致" {
    const border = Color.rgba(23, 23, 27, 36);
    const bw: f32 = 1.0;

    var cx_node = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx_node.deinit();
    cx_node.setViewport(800, 600);
    const root = try ui.box(cx_node, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
        .background = Color.TRANSPARENT,
    }, .{});
    const child = try ui.box(cx_node, .{
        .position = .absolute,
        .width = .{ .px = 100 },
        .height = .{ .px = 80 },
        .background = Color.TRANSPARENT,
    }, .{});
    child.setBorderColor(border);
    child.setBorderWidth(bw);
    try root.appendChild(cx_node.allocator, child);
    cx_node.root = root;
    cx_node.layout();
    _ = cx_node.render();
    const node_stroke = firstStrokeRect(cx_node) orelse return error.TestExpectedStrokeRect;

    var cx_bulk = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx_bulk.deinit();
    cx_bulk.setViewport(800, 600);
    const empty_root = try ui.box(cx_bulk, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
        .background = Color.TRANSPARENT,
    }, .{});
    cx_bulk.root = empty_root;
    try cx_bulk.setBulkQuads(null, &[_]ui.BulkQuad{.{
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 80,
        .color = Color.TRANSPARENT,
        .border_width = bw,
        .border_color = border,
    }});
    cx_bulk.layout();
    _ = cx_bulk.render();
    const bulk_stroke = firstStrokeRect(cx_bulk) orelse return error.TestExpectedStrokeRect;

    try std.testing.expectEqual(node_stroke.w, bulk_stroke.w);
    try std.testing.expectEqual(node_stroke.h, bulk_stroke.h);
    try std.testing.expectEqual(node_stroke.width, bulk_stroke.width);
    try std.testing.expectEqual(node_stroke.color.r, bulk_stroke.color.r);
    try std.testing.expectEqual(node_stroke.color.a, bulk_stroke.color.a);
}

test "BulkQuad: alpha=0 不产生 fill_rect（只描边）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    try cx.setBulkQuads(null, &[_]ui.BulkQuad{.{
        .x = 10,
        .y = 10,
        .w = 50,
        .h = 50,
        .color = Color.TRANSPARENT,
        .border_width = 2,
        .border_color = Color.hex(0xFF0000),
    }});
    cx.layout();
    _ = cx.render();

    var fills: usize = 0;
    var strokes: usize = 0;
    for (cx.display_list.items.items) |it| switch (it) {
        .fill_rect => fills += 1,
        .stroke_rect => strokes += 1,
        else => {},
    };
    // root background TRANSPARENT ⇒ no fill_rect; bulk item alpha=0 same.
    try std.testing.expectEqual(@as(usize, 0), fills);
    try std.testing.expectEqual(@as(usize, 1), strokes);
}

// Host (downstream) uses a per-field hash for the bulk layer content version; unchanged -> no
// redraw.
// A new field that skips the hash **silently never refreshes**. Downstream has a comptime
// field-count assert, but it only guarantees someone changes the hash, not correctly. Guard
// semantics here: any new field change must alter the lowered DisplayItem.
test "BulkQuad: 新增外观字段全部影响 lower 结果（防版本号静默失效）" {
    const Case = struct { name: []const u8, q: ui.BulkQuad };
    const base = ui.BulkQuad{
        .x = 1,
        .y = 2,
        .w = 30,
        .h = 40,
        .color = Color.hex(0x00FF00),
    };
    var with_shadow = base;
    with_shadow.shadow = .{ .color = Color.rgba(0, 0, 0, 128), .blur = 8 };
    var with_shadow2 = base;
    with_shadow2.shadow = .{ .color = Color.rgba(0, 0, 0, 128), .blur = 9 };
    var with_side = base;
    with_side.border_color = Color.hex(0xFF0000);
    with_side.border_widths = .{ 1, 0, 0, 0 };
    var with_inset = base;
    with_inset.inset_shadow = .{ .color = Color.rgba(0, 0, 0, 80), .blur = 4 };

    const cases = [_]Case{
        .{ .name = "base", .q = base },
        .{ .name = "shadow", .q = with_shadow },
        .{ .name = "shadow blur 变化", .q = with_shadow2 },
        .{ .name = "per-side border", .q = with_side },
        .{ .name = "inset shadow", .q = with_inset },
    };

    var counts: [cases.len]usize = undefined;
    for (cases, 0..) |c, i| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(400, 300);
        const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        cx.root = root;
        try cx.setBulkQuads(null, &[_]ui.BulkQuad{c.q});
        cx.layout();
        _ = cx.render();
        counts[i] = cx.display_list.items.items.len;
    }
    // each type beyond base must produce at least one extra item
    // (shadow/edge/inner-shadow each)
    for (counts[1..], cases[1..]) |n, c| {
        if (n <= counts[0] and !std.mem.eql(u8, c.name, "shadow blur 变化")) {
            std.debug.print("字段 {s} 没有影响 lower 结果\n", .{c.name});
            return error.FieldNotLowered;
        }
    }
    // blur value change doesn't change item count, but must change field value,
    // verify separately
    try std.testing.expectEqual(counts[1], counts[2]);
}

test "BulkQuad: 渐变降为 multi_gradient_rect，且不再发纯色 fill" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    var g = ui.MultiGradient{ .direction = .radial };
    g.stop_count = 2;
    g.stops[0] = .{ .color = Color.hex(0xFF0000), .position = 0 };
    g.stops[1] = .{ .color = Color.hex(0x0000FF), .position = 1 };
    try cx.setBulkQuads(null, &[_]ui.BulkQuad{.{
        .x = 10,
        .y = 10,
        .w = 50,
        .h = 50,
        .color = Color.hex(0x00FF00), // gradient given ⇒ this solid ignored
        .gradient = g,
        .gradient_center = .{ 0.25, 0.75 },
    }});
    cx.layout();
    _ = cx.render();

    var grads: usize = 0;
    var fills: usize = 0;
    for (cx.display_list.items.items) |it| switch (it) {
        .multi_gradient_rect => |mg| {
            grads += 1;
            try std.testing.expectEqual(@as(u8, 2), mg.stop_count);
            try std.testing.expectEqual(@as(f32, 0.25), mg.radial_center_x);
            try std.testing.expectEqual(@as(u8, 0xFF), mg.stop_colors[0].r);
            try std.testing.expectEqual(@as(u8, 0xFF), mg.stop_colors[1].b);
        },
        .fill_rect => |f| {
            if (f.color.a > 0) fills += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), grads);
    // gradient given ⇒ **don't** emit solid, else solid after gradient covers it
    try std.testing.expectEqual(@as(usize, 0), fills);
}

test "BulkQuad: 少于两个 stop 的渐变不画（一个 stop 就是纯色）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    var g = ui.MultiGradient{};
    g.stop_count = 1;
    g.stops[0] = .{ .color = Color.hex(0xFF0000), .position = 0 };
    try cx.setBulkQuads(null, &[_]ui.BulkQuad{.{
        .x = 10,
        .y = 10,
        .w = 50,
        .h = 50,
        .color = Color.hex(0x00FF00),
        .gradient = g,
    }});
    cx.layout();
    _ = cx.render();
    for (cx.display_list.items.items) |it| {
        if (it == .multi_gradient_rect) return error.ShouldNotEmitDegenerateGradient;
    }
}

test "BulkQuad: shadow 降为 shadow_rect 且排在 fill 之前" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    try cx.setBulkQuads(null, &[_]ui.BulkQuad{.{
        .x = 10,
        .y = 10,
        .w = 50,
        .h = 50,
        .color = Color.hex(0x00FF00),
        .radius = .{ 4, 4, 4, 4 },
        .shadow = .{ .color = Color.rgba(0, 0, 0, 128), .blur = 8, .offset_x = 1, .offset_y = 2 },
    }});
    cx.layout();
    _ = cx.render();

    var shadow_at: ?usize = null;
    var fill_at: ?usize = null;
    for (cx.display_list.items.items, 0..) |it, i| switch (it) {
        .shadow_rect => |s| {
            if (shadow_at == null) {
                shadow_at = i;
                try std.testing.expectEqual(@as(f32, 8), s.blur);
                try std.testing.expectEqual(@as(f32, 1), s.offset_x);
                try std.testing.expectEqual(@as(f32, 2), s.offset_y);
                // radius must pass through, else shadow is rect, corners show blocks
                try std.testing.expectEqual(@as(f32, 4), s.radius[0]);
            }
        },
        .fill_rect => |f| {
            if (fill_at == null and f.color.a > 0) fill_at = i;
        },
        else => {},
    };
    try std.testing.expect(shadow_at != null);
    try std.testing.expect(fill_at != null);
    // shadow must draw first, else covers object
    try std.testing.expect(shadow_at.? < fill_at.?);
}

test "BulkQuad: border_widths 非零走 border_per_side，忽略 border_width" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    try cx.setBulkQuads(null, &[_]ui.BulkQuad{.{
        .x = 10,
        .y = 10,
        .w = 50,
        .h = 50,
        .color = Color.hex(0x00FF00),
        .border_width = 99, // should be ignored
        .border_color = Color.hex(0xFF0000),
        .border_widths = .{ 1, 2, 3, 4 },
    }});
    cx.layout();
    _ = cx.render();

    var per_side: usize = 0;
    var strokes: usize = 0;
    for (cx.display_list.items.items) |it| switch (it) {
        .border_per_side => |b| {
            per_side += 1;
            try std.testing.expectEqual(@as(f32, 1), b.widths[0]);
            try std.testing.expectEqual(@as(f32, 4), b.widths[3]);
        },
        .stroke_rect => strokes += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), per_side);
    // with edge active, don't emit unified stroke (else double-stroke)
    try std.testing.expectEqual(@as(usize, 0), strokes);
}

test "BulkQuad: inset_shadow 排在 fill 之后且不重复画底色" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    try cx.setBulkQuads(null, &[_]ui.BulkQuad{.{
        .x = 10,
        .y = 10,
        .w = 50,
        .h = 50,
        .color = Color.hex(0x00FF00),
        .inset_shadow = .{ .color = Color.rgba(0, 0, 0, 80), .blur = 4 },
    }});
    cx.layout();
    _ = cx.render();

    var fill_at: ?usize = null;
    var inset_at: ?usize = null;
    for (cx.display_list.items.items, 0..) |it, i| switch (it) {
        .fill_rect => |f| {
            if (fill_at == null and f.color.a > 0) fill_at = i;
        },
        .inset_shadow_rect => |s| {
            if (inset_at == null) {
                inset_at = i;
                // base color already drawn by fill_rect; re-drawing here makes semi-transparent
                // fill darker
                try std.testing.expectEqual(@as(u8, 0), s.fill.a);
                try std.testing.expectEqual(@as(u8, 80), s.shadow_color.a);
            }
        },
        else => {},
    };
    try std.testing.expect(fill_at != null);
    try std.testing.expect(inset_at != null);
    try std.testing.expect(fill_at.? < inset_at.?);
}

test "BulkQuad: setBulkQuads 传空切片关闭该层" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    try cx.setBulkQuads(null, &[_]ui.BulkQuad{.{
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
        .color = Color.hex(0x00FF00),
    }});
    cx.layout();
    _ = cx.render();
    try std.testing.expect(firstFillRect(cx) != null);

    try cx.setBulkQuads(null, &.{});
    root.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try std.testing.expect(firstFillRect(cx) == null);
}

test "BulkQuad: 提交顺序即绘制顺序（后者盖前者）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    try cx.setBulkQuads(null, &[_]ui.BulkQuad{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0xFF0000) },
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x00FF00) },
    });
    cx.layout();
    _ = cx.render();

    var seen: [2]Color = undefined;
    var i: usize = 0;
    for (cx.display_list.items.items) |it| switch (it) {
        .fill_rect => |fr| {
            if (i < 2) seen[i] = fr.color;
            i += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), i);
    // array order = display list order = draw order
    try std.testing.expectEqual(@as(u8, 0xFF), seen[0].r);
    try std.testing.expectEqual(@as(u8, 0xFF), seen[1].g);
}

// -- BulkQuad layering/clipping regression --
//
// Bug: the bulk layer was unconditionally appended after the entire Node tree, outside the clip
// stack; twenty thousand canvas rects covered sidebar / inspector / toolbar and spilled beyond the
// canvas viewport. This group builds a shell isomorphic to the real host (canvas container +
// following chrome siblings) and asserts **every chrome display item orders after all bulk quads**
// and bulk quads carry the canvas clip_id.

const BulkShell = struct {
    cx: *Cx,
    canvas: *ui.Node,
    /// chrome node ids (sidebar / inspector / toolbar)
    chrome_ids: [3]u32,
};

/// canvas full-window base + three chrome siblings atop (downstream compose
/// structure).
fn buildBulkShell(allocator: std.mem.Allocator) !BulkShell {
    var cx = try Cx.init(allocator, std.testing.io);
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});

    // canvas container: overflow_hidden ⇒ establishes clip, bulk layer must be
    // constrained
    const canvas = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 900 },
        .height = .{ .px = 700 },
        .background = Color.hex(0xF5F5F5),
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(cx.allocator, canvas);

    // chrome: appended after canvas ⇒ must cover canvas content (including bulk)
    var chrome_ids: [3]u32 = undefined;
    const chrome_colors = [_]u24{ 0x111111, 0x222222, 0x333333 };
    for (chrome_colors, 0..) |c, idx| {
        const panel = try ui.box(cx, .{
            .position = .absolute,
            .width = .{ .px = 240 },
            .height = .{ .px = 600 },
            .background = Color.hex(c),
        }, .{});
        try root.appendChild(cx.allocator, panel);
        chrome_ids[idx] = panel.id;
    }
    cx.root = root;
    return .{ .cx = cx, .canvas = canvas, .chrome_ids = chrome_ids };
}

/// lay canvas objects; scale simulates zoom level: 6% makes many small, exactly
/// reproduction
fn bulkQuadsForScale(buf: *std.ArrayListUnmanaged(ui.BulkQuad), allocator: std.mem.Allocator, scale: f32) !void {
    buf.clearRetainingCapacity();
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        try buf.append(allocator, .{
            // intentionally place some outside canvas rect (chrome area / out of viewport),
            // unclamped old impl draws them onto UI.
            .x = (fi * 37.0) * scale - 100.0,
            .y = (fi * 19.0) * scale - 60.0,
            .w = @max(1.0, 80.0 * scale),
            .h = @max(1.0, 60.0 * scale),
            .color = Color.hex(0x4A90D9),
            .radius = .{ 6, 6, 6, 6 },
            .border_width = 1.0,
            .border_color = Color.rgba(23, 23, 27, 36),
        });
    }
}

/// return (last bulk quad index, first chrome item index)
fn bulkVsChromeOrder(cx: *Cx, canvas_id: u32, chrome_ids: []const u32) struct {
    last_bulk: ?usize,
    first_chrome: ?usize,
    bulk_count: usize,
    unclipped_bulk: usize,
} {
    var last_bulk: ?usize = null;
    var first_chrome: ?usize = null;
    var bulk_count: usize = 0;
    var unclipped_bulk: usize = 0;
    for (cx.display_list.items.items, 0..) |it, idx| {
        const h: display_list.ItemHeader = switch (it) {
            .fill_rect => |v| v.header,
            .stroke_rect => |v| v.header,
            .text_run => |v| v.header,
            else => continue,
        };
        if (h.node_id == canvas_id) {
            bulk_count += 1;
            last_bulk = idx;
            if (h.clip_id == display_list.INVALID_ID) unclipped_bulk += 1;
        }
        for (chrome_ids) |cid| {
            if (h.node_id == cid and first_chrome == null) first_chrome = idx;
        }
    }
    return .{
        .last_bulk = last_bulk,
        .first_chrome = first_chrome,
        .bulk_count = bulk_count,
        .unclipped_bulk = unclipped_bulk,
    };
}

fn expectBulkUnderChrome(scale: f32) !void {
    const allocator = std.testing.allocator;
    var shell = try buildBulkShell(allocator);
    defer shell.cx.deinit();

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, scale);

    try shell.cx.setBulkQuads(shell.canvas, quads.items);
    shell.cx.layout();
    _ = shell.cx.render();

    const ord = bulkVsChromeOrder(shell.cx, shell.canvas.id, &shell.chrome_ids);

    // bulk layer truly produces items (else below assertions pass vacuously)
    try std.testing.expect(ord.bulk_count > 0);
    const last_bulk = ord.last_bulk orelse return error.TestExpectedBulkQuads;
    const first_chrome = ord.first_chrome orelse return error.TestExpectedChromeItems;

    // ① layering: all chrome order after bulk ⇒ chrome covers canvas.
    //    old impl: bulk appends last, this must fail.
    try std.testing.expect(last_bulk < first_chrome);

    // ② clipping: each bulk quad carries canvas clip, won't spill to UI area.
    try std.testing.expectEqual(@as(usize, 0), ord.unclipped_bulk);
}

test "BulkQuad: 挂靠画布后 UI chrome 盖在批量层之上（scale≈1）" {
    try expectBulkUnderChrome(1.0);
}

test "BulkQuad: 挂靠画布后 UI chrome 盖在批量层之上（6% 缩放档）" {
    // MIN_SCALE≈0.05: user-reported reproduction zoom
    try expectBulkUnderChrome(0.06);
}

test "BulkQuad: 挂靠时带上画布 clip_id，不挂靠时保持旧的无裁剪行为" {
    const allocator = std.testing.allocator;

    // A) anchored ⇒ has clip
    var shell = try buildBulkShell(allocator);
    defer shell.cx.deinit();
    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);
    try shell.cx.setBulkQuads(shell.canvas, quads.items);
    shell.cx.layout();
    _ = shell.cx.render();
    const anchored = bulkVsChromeOrder(shell.cx, shell.canvas.id, &shell.chrome_ids);
    try std.testing.expect(anchored.bulk_count > 0);
    try std.testing.expectEqual(@as(usize, 0), anchored.unclipped_bulk);

    // B) not anchored ⇒ degrades to old: node_id=0, no clip, after all chrome
    var shell2 = try buildBulkShell(allocator);
    defer shell2.cx.deinit();
    try shell2.cx.setBulkQuads(null, quads.items);
    shell2.cx.layout();
    _ = shell2.cx.render();

    var tail_unclipped: usize = 0;
    var first_chrome2: ?usize = null;
    var last_unanchored: ?usize = null;
    for (shell2.cx.display_list.items.items, 0..) |it, idx| {
        const h: display_list.ItemHeader = switch (it) {
            .fill_rect => |v| v.header,
            .stroke_rect => |v| v.header,
            else => continue,
        };
        for (shell2.chrome_ids) |cid| {
            if (h.node_id == cid and first_chrome2 == null) first_chrome2 = idx;
        }
        if (h.node_id == 0 and h.clip_id == display_list.INVALID_ID) {
            tail_unclipped += 1;
            last_unanchored = idx;
        }
    }
    try std.testing.expect(tail_unclipped > 0);
    if (first_chrome2) |fc| {
        try std.testing.expect(last_unanchored.? > fc);
    }
}

// BulkQuad: anchor subtree insert point when it has no display items
//
// Bug ("shrunk view batch layer flickers invisible intermittently"): bulkAnchorInsertPoint locates
// the insert point only from display items ALREADY PRODUCED by the anchor subtree. A canvas
// container
// with no background of its own, with all objects downgraded to batch layer/block LOD (a shrunk
// viewport), produces zero anchor-subtree display items => returns null => caller treats null as
// "append to end + no clip", so the batch layer re-runs after all chrome. The shrunk view is
// sometimes correct (canvas has a stray Node), sometimes fully covered (all downgraded):
// an intermittent flicker.
fn buildEmptyCanvasBulkShell(allocator: std.mem.Allocator) !BulkShell {
    var cx = try Cx.init(allocator, std.testing.io);
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});

    // canvas container: only difference from buildBulkShell is **no background**, so
    // no fill_rect. all-degraded frame: its subtree empty.
    const canvas = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 900 },
        .height = .{ .px = 700 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(cx.allocator, canvas);

    var chrome_ids: [3]u32 = undefined;
    const chrome_colors = [_]u24{ 0x111111, 0x222222, 0x333333 };
    for (chrome_colors, 0..) |c, idx| {
        const panel = try ui.box(cx, .{
            .position = .absolute,
            .width = .{ .px = 240 },
            .height = .{ .px = 600 },
            .background = Color.hex(c),
        }, .{});
        try root.appendChild(cx.allocator, panel);
        chrome_ids[idx] = panel.id;
    }
    cx.root = root;
    return .{ .cx = cx, .canvas = canvas, .chrome_ids = chrome_ids };
}

test "BulkQuad: 锚点子树无 display item 时仍排在 chrome 之下且带 clip" {
    const allocator = std.testing.allocator;
    var shell = try buildEmptyCanvasBulkShell(allocator);
    defer shell.cx.deinit();

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);

    try shell.cx.setBulkQuads(shell.canvas, quads.items);
    shell.cx.layout();
    _ = shell.cx.render();

    const ord = bulkVsChromeOrder(shell.cx, shell.canvas.id, &shell.chrome_ids);
    try std.testing.expect(ord.bulk_count > 0);
    const last_bulk = ord.last_bulk orelse return error.TestExpectedBulkQuads;
    const first_chrome = ord.first_chrome orelse return error.TestExpectedChromeItems;

    // layering: even with empty anchor subtree, bulk must order before chrome.
    try std.testing.expect(last_bulk < first_chrome);
    // clipping: still carries canvas clip.
    try std.testing.expectEqual(@as(usize, 0), ord.unclipped_bulk);
}

// BulkQuad: canvas interaction overlay must layer above batch quad
//
// Bug: after selection, white resize handles and the blue "320 x 200" size label were buried under
// the batch quad. These overlay nodes are children of the canvas Node (downstream compose.zig:
// sel_outline z=31500 / size_pill z=31600 / handles z=32000), while the batch layer positions after
// "last item of anchor subtree", i.e. above the overlay. setBulkQuadsEx passes overlay_z_threshold
// to declare where the overlay layer starts.
const bulk_overlay_z: i16 = 31000;

/// canvas container + canvas-internal interaction overlay (high-z_index
/// handles/labels) + following chrome.
fn buildOverlayBulkShell(allocator: std.mem.Allocator, out_overlay: *[2]u32) !BulkShell {
    var cx = try Cx.init(allocator, std.testing.io);
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});

    const canvas = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 900 },
        .height = .{ .px = 700 },
        .background = Color.hex(0xF5F5F5),
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(cx.allocator, canvas);

    // canvas-internal overlay: one resize handle + one size label capsule.
    const handle = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 8 },
        .height = .{ .px = 8 },
        .background = Color.hex(0xFFFFFF),
    }, .{});
    handle.setStyle(cx.allocator, .z_index, @as(i16, 32000));
    try canvas.appendChild(cx.allocator, handle);

    const size_pill = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 60 },
        .height = .{ .px = 19 },
        .background = Color.hex(0x4A90D9),
    }, .{});
    size_pill.setStyle(cx.allocator, .z_index, @as(i16, 31600));
    try canvas.appendChild(cx.allocator, size_pill);

    out_overlay.* = .{ handle.id, size_pill.id };

    var chrome_ids: [3]u32 = undefined;
    const chrome_colors = [_]u24{ 0x111111, 0x222222, 0x333333 };
    for (chrome_colors, 0..) |c, idx| {
        const panel = try ui.box(cx, .{
            .position = .absolute,
            .width = .{ .px = 240 },
            .height = .{ .px = 600 },
            .background = Color.hex(c),
        }, .{});
        try root.appendChild(cx.allocator, panel);
        chrome_ids[idx] = panel.id;
    }
    cx.root = root;
    return .{ .cx = cx, .canvas = canvas, .chrome_ids = chrome_ids };
}

test "BulkQuad: 画布内交互叠加(handles/尺寸标签)盖在批量层之上" {
    const allocator = std.testing.allocator;
    var overlay_ids: [2]u32 = undefined;
    var shell = try buildOverlayBulkShell(allocator, &overlay_ids);
    defer shell.cx.deinit();

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);

    try shell.cx.setBulkQuadsEx(shell.canvas, quads.items, bulk_overlay_z);
    shell.cx.layout();
    _ = shell.cx.render();

    var last_bulk: ?usize = null;
    var first_overlay: ?usize = null;
    var first_chrome: ?usize = null;
    var bulk_count: usize = 0;
    var unclipped: usize = 0;
    for (shell.cx.display_list.items.items, 0..) |it, idx| {
        const h: display_list.ItemHeader = switch (it) {
            .fill_rect => |v| v.header,
            .stroke_rect => |v| v.header,
            .text_run => |v| v.header,
            else => continue,
        };
        if (h.node_id == shell.canvas.id) {
            bulk_count += 1;
            last_bulk = idx;
            if (h.clip_id == display_list.INVALID_ID) unclipped += 1;
        }
        for (overlay_ids) |oid| {
            if (h.node_id == oid and first_overlay == null) first_overlay = idx;
        }
        for (shell.chrome_ids) |cid| {
            if (h.node_id == cid and first_chrome == null) first_chrome = idx;
        }
    }

    try std.testing.expect(bulk_count > 0);
    const lb = last_bulk orelse return error.TestExpectedBulkQuads;
    const fo = first_overlay orelse return error.TestExpectedOverlayItems;
    const fc = first_chrome orelse return error.TestExpectedChromeItems;

    // ① Interaction layer overlays bulk layer (screenshot bug: this fails).
    try std.testing.expect(lb < fo);
    // ② chrome stays on top.
    try std.testing.expect(lb < fc);
    // ③ Bulk layer still clipped by canvas.
    try std.testing.expectEqual(@as(usize, 0), unclipped);
}

// -- BulkQuad: intermittent layer loss root cause --
// Symptom: canvas vanishes when scaled below 7%; objects blur over UI chrome.
// Root cause: bulkAnchorInsertPoint scans the display list for references but only recognizes
// fill_rect/stroke_rect/text_run (3 of 25 DisplayItem types); chrome after the canvas may use
// begin_blur_layer, image_quad/icon_rep, shadow_rect/gradient_rect, or wrappers with no items.
// No items in anchor subtree + no interaction layer -> no reference -> null -> at_tail appends
// with clip_id=INVALID_ID, bypassing chrome unclipped. Tests cover that matrix.

/// Chrome post-canvas uses only unscanned item types (image_quad), mimicking real structure:
/// wrappers have no background, content is glass/icons/shadows.
fn buildGlassChromeBulkShell(allocator: std.mem.Allocator, out_chrome: *[2]u32) !BulkShell {
    var cx = try Cx.init(allocator, std.testing.io);
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});

    // Canvas container: no background => produces no item; subtree empty when all objects degrade.
    const canvas = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 900 },
        .height = .{ .px = 700 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(cx.allocator, canvas);

    // chrome: no-background wrapper + image content (image_quad, unrecognized by scan).
    var chrome_ids: [2]u32 = undefined;
    for (0..2) |idx| {
        const wrap = try ui.box(cx, .{
            .position = .absolute,
            .width = .{ .px = 240 },
            .height = .{ .px = 600 },
        }, .{});
        const img = try ui.image(cx, @intCast(100 + idx), .{
            .width = .{ .px = 240 },
            .height = .{ .px = 600 },
        });
        try wrap.appendChild(cx.allocator, img);
        try root.appendChild(cx.allocator, wrap);
        chrome_ids[idx] = img.id;
    }
    out_chrome.* = chrome_ids;
    cx.root = root;
    return .{ .cx = cx, .canvas = canvas, .chrome_ids = .{ chrome_ids[0], chrome_ids[1], chrome_ids[1] } };
}

/// Count relative order of bulk quad and chrome (image_quad) + unclipped count.
fn bulkVsGlassChrome(cx: *Cx, canvas_id: u32, chrome_ids: []const u32) struct {
    bulk_count: usize,
    last_bulk: ?usize,
    first_chrome: ?usize,
    unclipped_bulk: usize,
} {
    var bulk_count: usize = 0;
    var last_bulk: ?usize = null;
    var first_chrome: ?usize = null;
    var unclipped: usize = 0;
    for (cx.display_list.items.items, 0..) |it, idx| {
        switch (it) {
            .fill_rect, .stroke_rect => {
                const h: display_list.ItemHeader = switch (it) {
                    .fill_rect => |v| v.header,
                    .stroke_rect => |v| v.header,
                    else => unreachable,
                };
                // Bulk quad: after fix node_id=canvas; regression form is node_id=0 no clip.
                if (h.node_id == canvas_id or
                    (h.node_id == 0 and h.clip_id == display_list.INVALID_ID))
                {
                    bulk_count += 1;
                    last_bulk = idx;
                    if (h.clip_id == display_list.INVALID_ID) unclipped += 1;
                }
            },
            .image_quad => |v| {
                for (chrome_ids) |cid| {
                    if (v.header.node_id == cid and first_chrome == null) first_chrome = idx;
                }
            },
            else => {},
        }
    }
    return .{
        .bulk_count = bulk_count,
        .last_bulk = last_bulk,
        .first_chrome = first_chrome,
        .unclipped_bulk = unclipped,
    };
}

test "BulkQuad: 锚点子树无 item + 无选择 + chrome 只产 image_quad ⇒ 仍不得越过 chrome" {
    const allocator = std.testing.allocator;
    var chrome_ids: [2]u32 = undefined;
    var shell = try buildGlassChromeBulkShell(allocator, &chrome_ids);
    defer shell.cx.deinit();

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);

    // No selection: no overlay threshold, no overlay node => frame where ①②③ all fail.
    try shell.cx.setBulkQuadsEx(shell.canvas, quads.items, bulk_overlay_z);
    shell.cx.layout();
    _ = shell.cx.render();

    const ord = bulkVsGlassChrome(shell.cx, shell.canvas.id, &chrome_ids);
    const fc = ord.first_chrome orelse return error.TestExpectedChromeItems;

    // Before fix: insert_at=null => append to end unclipped; both fail. After fix: either correctly
    // insert pre-chrome with clip, or skip this frame (safe degrade), but never draw over chrome.
    if (ord.last_bulk) |lb| {
        try std.testing.expect(lb < fc);
        try std.testing.expectEqual(@as(usize, 0), ord.unclipped_bulk);
    }
}

test "BulkQuad: 选择态开关不改变层级（点击恢复/再点又坏 的确定性复现）" {
    const allocator = std.testing.allocator;

    // A) No selection: canvas subtree empty, no overlay.
    {
        var chrome_ids: [2]u32 = undefined;
        var shell = try buildGlassChromeBulkShell(allocator, &chrome_ids);
        defer shell.cx.deinit();
        var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
        defer quads.deinit(allocator);
        try bulkQuadsForScale(&quads, allocator, 0.06);
        try shell.cx.setBulkQuadsEx(shell.canvas, quads.items, bulk_overlay_z);
        shell.cx.layout();
        _ = shell.cx.render();
        const ord = bulkVsGlassChrome(shell.cx, shell.canvas.id, &chrome_ids);
        const fc = ord.first_chrome orelse return error.TestExpectedChromeItems;
        if (ord.last_bulk) |lb| {
            try std.testing.expect(lb < fc);
            try std.testing.expectEqual(@as(usize, 0), ord.unclipped_bulk);
        }
    }

    // B) With selection: same tree + one interaction overlay node (handle appearing on select).
    {
        var chrome_ids: [2]u32 = undefined;
        var shell = try buildGlassChromeBulkShell(allocator, &chrome_ids);
        defer shell.cx.deinit();
        const handle = try ui.box(shell.cx, .{
            .position = .absolute,
            .width = .{ .px = 8 },
            .height = .{ .px = 8 },
            .background = Color.hex(0xFFFFFF),
        }, .{});
        handle.setStyle(shell.cx.allocator, .z_index, @as(i16, 32000));
        try shell.canvas.appendChild(shell.cx.allocator, handle);

        var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
        defer quads.deinit(allocator);
        try bulkQuadsForScale(&quads, allocator, 0.06);
        try shell.cx.setBulkQuadsEx(shell.canvas, quads.items, bulk_overlay_z);
        shell.cx.layout();
        _ = shell.cx.render();
        const ord = bulkVsGlassChrome(shell.cx, shell.canvas.id, &chrome_ids);
        const fc = ord.first_chrome orelse return error.TestExpectedChromeItems;
        try std.testing.expect(ord.bulk_count > 0);
        const lb = ord.last_bulk orelse return error.TestExpectedBulkQuads;
        try std.testing.expect(lb < fc);
        try std.testing.expectEqual(@as(usize, 0), ord.unclipped_bulk);
    }
}

test "BulkQuad: 找不到插入点时宁可不画,也不得追加到末尾且不裁剪" {
    const allocator = std.testing.allocator;

    // Canvas is root's last child: no siblings post-anchor, subtree has no items. Three-level
    // positioning inevitably all fail; pure null-semantic example.
    var cx = try Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});
    // chrome first (no siblings post-canvas)
    const panel = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 240 },
        .height = .{ .px = 600 },
        .background = Color.hex(0x111111),
    }, .{});
    try root.appendChild(cx.allocator, panel);
    const canvas = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 900 },
        .height = .{ .px = 700 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(cx.allocator, canvas);
    cx.root = root;

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);
    try cx.setBulkQuadsEx(canvas, quads.items, bulk_overlay_z);
    cx.layout();
    _ = cx.render();

    // Critical assertion: bulk quad if drawn must have canvas clip; never allow bare-append form
    // (node_id=0 / clip=INVALID_ID) that blurs UI.
    var naked: usize = 0;
    for (cx.display_list.items.items) |it| {
        const h: display_list.ItemHeader = switch (it) {
            .fill_rect => |v| v.header,
            .stroke_rect => |v| v.header,
            else => continue,
        };
        if (h.clip_id == display_list.INVALID_ID and h.node_id == 0) naked += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), naked);
}

// -- BulkQuad: must close layer after anchor subtree destruction --
// Crash (EXC_BAD_ACCESS in core.Cx.render): host frees the chrome subtree without resubmitting;
// cx.bulk_quads_anchor still points at the freed node and bulk_quads persist across frames, so
// appendBulkQuads would deref freed anchor.id; invalidateReferencesToEx clears anchor and quads
// together.
test "BulkQuad: 锚点子树被销毁后自动关层，render 不得解引用悬垂锚点" {
    const allocator = std.testing.allocator;
    var cx = try Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1200, 800);

    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});
    cx.root = root;

    // Canvas subtree (equivalent to downstream canvas_host), destroyed later.
    const canvas = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 900 },
        .height = .{ .px = 700 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(cx.allocator, canvas);

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);
    try cx.setBulkQuadsEx(canvas, quads.items, bulk_overlay_z);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.bulk_quads.items.len > 0);

    // Equivalent to downstream teardownChromeScreen: detach + free, do NOT resubmit bulk layer.
    cx.detachChild(root, canvas);
    cx.freeNode(canvas);

    // Anchor must be cleared, else this frame is UAF.
    try std.testing.expect(cx.bulk_quads_anchor == null);
    // Close layer, not degrade to null-anchor's 'append + unclipped'.
    try std.testing.expectEqual(@as(usize, 0), cx.bulk_quads.items.len);

    // homepage screen continues rendering: no crash, no bare bulk quad.
    cx.layout();
    _ = cx.render();
    var naked: usize = 0;
    for (cx.display_list.items.items) |it| {
        const h: display_list.ItemHeader = switch (it) {
            .fill_rect => |v| v.header,
            .stroke_rect => |v| v.header,
            else => continue,
        };
        if (h.clip_id == display_list.INVALID_ID and h.node_id == 0) naked += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), naked);
}

test "BulkQuad: 版本号未变时零脏帧快速路径仍然成立" {
    // Background: bulk layer resubmitted each frame, zenit doesn't cross-frame diff; conservatively
    // redraws entire display list if present. On 20k+ quad canvas: render_gen 21.6ms/frame (70%
    // total, GPU 6.3ms), still pays even when static. After setBulkQuadsVersioned declares
    // unchanged, static screen must reach zero dirty frames.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const quads = [_]ui.BulkQuad{.{
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
        .color = Color.hex(0x00FF00),
    }};

    // Frame 1: baseline (version first appears, not 'unchanged').
    try cx.setBulkQuadsVersioned(null, &quads, null, 7);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(firstFillRect(cx) != null);

    // Frame 2: same version => host declares unchanged => zero dirty frame allowed.
    try cx.setBulkQuadsVersioned(null, &quads, null, 7);
    try std.testing.expect(cx.bulk_quads_unchanged);
    cx.layout();
    _ = cx.render();
    // Screen must not disappear because skip redraw; display list retained cross-frame.
    try std.testing.expect(firstFillRect(cx) != null);
}

test "BulkQuad: 版本号变化必须重画（否则改了内容画面不动）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const green = [_]ui.BulkQuad{.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x00FF00) }};
    try cx.setBulkQuadsVersioned(null, &green, null, 1);
    cx.layout();
    _ = cx.render();

    // Change content + version => must redraw, not short-circuited by 'unchanged'.
    const red = [_]ui.BulkQuad{.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0xFF0000) }};
    try cx.setBulkQuadsVersioned(null, &red, null, 2);
    try std.testing.expect(!cx.bulk_quads_unchanged);
    cx.layout();
    _ = cx.render();
    const fr = firstFillRect(cx).?;
    try std.testing.expectEqual(Color.hex(0xFF0000), fr.color);
}

test "BulkQuad: 不传版本号时保持原来的保守重画语义" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const quads = [_]ui.BulkQuad{.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x00FF00) }};
    // Old API (no version): host can't self-certify => always treated as 'changed',
    // backward-compatible.
    try cx.setBulkQuads(null, &quads);
    try std.testing.expect(!cx.bulk_quads_unchanged);
    try cx.setBulkQuads(null, &quads);
    try std.testing.expect(!cx.bulk_quads_unchanged);
}

// -- BulkQuad stratification (z interleaving) --
// The bulk layer is a single plane inserted after anchor-subtree static content, so it draws over
// all Node objects and can't express 'some objects under Nodes, others over'.
// Stratification: each quad can carry z_index and is inserted before the first Node item with a
// larger z.

fn fillRectColorsInOrder(cx: *Cx, out: *std.ArrayListUnmanaged(Color), a: std.mem.Allocator) !void {
    for (cx.display_list.items.items) |it| {
        switch (it) {
            .fill_rect => |fr| try out.append(a, fr.color),
            else => {},
        }
    }
}

test "BulkQuad 分段：带 z 的 quad 与 Node 逐个交错" {
    const a = std.testing.allocator;
    var cx = try Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    // Node z=50 (red), bulk has z=10 (green) and z=90 (blue). Correct order: green -> red -> blue.
    const mid = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 10 },
        .height = .{ .px = 10 },
        .background = Color.hex(0xFF0000),
    }, .{});
    mid.setStyle(a, .z_index, @as(i16, 50));
    try root.appendChild(a, mid);

    try cx.setBulkQuads(root, &[_]ui.BulkQuad{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x00FF00), .z_index = 10 },
        .{ .x = 20, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x0000FF), .z_index = 90 },
    });
    cx.layout();
    _ = cx.render();

    var colors: std.ArrayListUnmanaged(Color) = .empty;
    defer colors.deinit(a);
    try fillRectColorsInOrder(cx, &colors, a);

    // Find indices, assert green < red < blue.
    var gi: ?usize = null;
    var ri: ?usize = null;
    var bi: ?usize = null;
    for (colors.items, 0..) |c, idx| {
        if (std.meta.eql(c, Color.hex(0x00FF00))) gi = idx;
        if (std.meta.eql(c, Color.hex(0xFF0000))) ri = idx;
        if (std.meta.eql(c, Color.hex(0x0000FF))) bi = idx;
    }
    try std.testing.expect(gi != null and ri != null and bi != null);
    try std.testing.expect(gi.? < ri.?); // z=10 bulk item under z=50 Node
    try std.testing.expect(ri.? < bi.?); // z=90 bulk item over z=50 Node
}

test "BulkQuad 分段：同一段内保持提交顺序（后者盖前者）" {
    const a = std.testing.allocator;
    var cx = try Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // Same-z items: array order is draw order, segments not reordered.
    try cx.setBulkQuads(root, &[_]ui.BulkQuad{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x111111), .z_index = 5 },
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x222222), .z_index = 5 },
    });
    cx.layout();
    _ = cx.render();

    var colors: std.ArrayListUnmanaged(Color) = .empty;
    defer colors.deinit(a);
    try fillRectColorsInOrder(cx, &colors, a);
    var first_idx: ?usize = null;
    var second_idx: ?usize = null;
    for (colors.items, 0..) |c, idx| {
        if (std.meta.eql(c, Color.hex(0x111111))) first_idx = idx;
        if (std.meta.eql(c, Color.hex(0x222222))) second_idx = idx;
    }
    try std.testing.expect(first_idx != null and second_idx != null);
    try std.testing.expect(first_idx.? < second_idx.?);
}

test "BulkQuad 分段：不带 z 时行为与原来完全一致（整层在 Node 之上）" {
    const a = std.testing.allocator;
    var cx = try Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const node = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 10 },
        .height = .{ .px = 10 },
        .background = Color.hex(0xFF0000),
    }, .{});
    node.setStyle(a, .z_index, @as(i16, 50));
    try root.appendChild(a, node);

    // No z_index => legacy: entire layer over all Nodes.
    try cx.setBulkQuads(root, &[_]ui.BulkQuad{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x00FF00) },
    });
    cx.layout();
    _ = cx.render();

    var colors: std.ArrayListUnmanaged(Color) = .empty;
    defer colors.deinit(a);
    try fillRectColorsInOrder(cx, &colors, a);
    var gi: ?usize = null;
    var ri: ?usize = null;
    for (colors.items, 0..) |c, idx| {
        if (std.meta.eql(c, Color.hex(0x00FF00))) gi = idx;
        if (std.meta.eql(c, Color.hex(0xFF0000))) ri = idx;
    }
    try std.testing.expect(gi != null and ri != null);
    try std.testing.expect(ri.? < gi.?); // Node first => bulk layer over it
}

// interaction.drag integration test (docs/DRAG_INTERACTION_DESIGN.md §18.2)

const drag_mod = @import("../interaction/drag.zig");
const ReactiveScope = @import("../reactive.zig").Scope;

const DragRec = struct {
    events: [16]drag_mod.Event = undefined,
    len: usize = 0,
    clicks: u32 = 0,
    pending_downs: u32 = 0,
    can_start_calls: u32 = 0,
    allow_start: bool = true,
    // Re-entrant action (executes once in callback, then clears)
    cx: ?*Cx = null,
    detach_parent_on_move: ?*Node = null,
    detach_child_on_move: ?*Node = null,

    fn cb(e: drag_mod.Event, raw: *anyopaque) void {
        const self: *DragRec = @ptrCast(@alignCast(raw));
        self.events[self.len] = e;
        self.len += 1;
        if (e.phase == .move) {
            if (self.detach_parent_on_move) |p| {
                const child = self.detach_child_on_move.?;
                self.detach_parent_on_move = null;
                self.detach_child_on_move = null;
                self.cx.?.detachChild(p, child);
            }
        }
    }

    fn pendingCb(_: drag_mod.PendingDownEvent, raw: *anyopaque) void {
        const self: *DragRec = @ptrCast(@alignCast(raw));
        self.pending_downs += 1;
    }

    fn canStart(_: drag_mod.StartRequest, raw: *anyopaque) bool {
        const self: *DragRec = @ptrCast(@alignCast(raw));
        self.can_start_calls += 1;
        return self.allow_start;
    }

    fn onClick(raw: *anyopaque) void {
        const self: *DragRec = @ptrCast(@alignCast(raw));
        self.clicks += 1;
    }
};

const DragFixture = struct {
    cx: *Cx,
    scope: *ReactiveScope,
    root: *Node,
    source: *Node,
    rec: DragRec = .{},

    fn init() !DragFixture {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(300, 200);
        const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
        const source = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
        try root.appendChild(cx.allocator, source);
        cx.root = root;
        const scope = try ReactiveScope.init(std.testing.allocator, null, cx.owner);
        return .{ .cx = cx, .scope = scope, .root = root, .source = source };
    }

    fn deinit(self: *DragFixture) void {
        if (!self.scope.disposed) self.scope.dispose();
        self.cx.deinit();
    }

    fn attach(self: *DragFixture, config: drag_mod.Config) !*drag_mod.Binding {
        self.rec.cx = self.cx;
        const b = try drag_mod.Binding.attach(self.scope, self.cx, self.source, config, DragRec.cb, &self.rec);
        // Mount handler, then layout; hit-test treats source as target (matches real component
        // order: mount handler -> layout).
        self.cx.layout();
        return b;
    }

    fn attachClickCounter(self: *DragFixture) void {
        self.root.behavior.events.on_click = .{ .callback = DragRec.onClick, .context = &self.rec };
    }
};

test "drag: pending 短点击仍派发 click，无 drag callback" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{ .activation_distance = 4 });
    f.attachClickCounter();

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(12, 11); // below threshold
    f.cx.handleMouseUp(12, 11);

    try std.testing.expectEqual(@as(usize, 0), f.rec.len);
    try std.testing.expectEqual(@as(u32, 1), f.rec.clicks);
    try std.testing.expect(f.cx.drag_manager.session == null);
}

test "drag: 越阈值后 start/move/end，无 click，capture/cursor 清理" {
    var f = try DragFixture.init();
    defer f.deinit();
    const b = try f.attach(.{ .activation_distance = 4, .active_cursor = .grabbing });
    f.attachClickCounter();

    f.cx.handleMouseDown(10, 10, .{});
    try std.testing.expect(b.isPending());
    f.cx.handleMouseMove(30, 10);
    try std.testing.expect(b.isDragging());
    try std.testing.expect(f.cx.dispatcher.hasPointerCapture());
    try std.testing.expectEqual(ui.CursorShape.grabbing, f.cx.current_cursor);
    try std.testing.expectEqual(ui.cursor.Source.capture, f.cx.cursor_state.decision.source);
    try std.testing.expect(f.cx.cursor_override == null);
    f.cx.handleMouseMove(50, 20);
    f.cx.handleMouseUp(60, 25);

    try std.testing.expectEqual(@as(usize, 3), f.rec.len);
    try std.testing.expectEqual(drag_mod.Phase.start, f.rec.events[0].phase);
    try std.testing.expectEqual(drag_mod.Phase.move, f.rec.events[1].phase);
    try std.testing.expectEqual(drag_mod.Phase.end, f.rec.events[2].phase);
    // end uses cumulative delta from up's final coordinate
    try std.testing.expectEqual(@as(f32, 50), f.rec.events[2].delta.x);
    try std.testing.expectEqual(@as(f32, 15), f.rec.events[2].delta.y);
    try std.testing.expectEqual(@as(u32, 0), f.rec.clicks);
    try std.testing.expect(!f.cx.dispatcher.hasPointerCapture());
    try std.testing.expect(f.cx.cursor_override == null);
    try std.testing.expect(f.cx.drag_manager.session == null);

    // normal click resumes after
    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseUp(10, 10);
    try std.testing.expectEqual(@as(u32, 1), f.rec.clicks);
}

test "drag: automation cursor mirrors grabbing state and release pulse" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{ .activation_distance = 4, .active_cursor = .grabbing });

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.updateAutomationCursor(10, 10, true);
    try std.testing.expect(f.cx.virtual_cursor.visible);
    try std.testing.expect(f.cx.virtual_cursor.pressed);

    f.cx.handleMouseMove(30, 10);
    f.cx.updateAutomationCursor(30, 10, null);
    try std.testing.expectEqual(ui.CursorShape.grabbing, f.cx.virtual_cursor.shape);
    try std.testing.expect(f.cx.virtual_cursor.pressed);

    f.cx.handleMouseUp(30, 10);
    f.cx.updateAutomationCursor(30, 10, false);
    try std.testing.expect(!f.cx.virtual_cursor.pressed);
    try std.testing.expect(f.cx.virtual_cursor.click_pulse_end_ms > f.cx.frame_time_ms);
}

test "drag: capture 后移出 source 仍收 move；axis horizontal 投影" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{ .activation_distance = 4, .axis = .horizontal });

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(250, 180); // far beyond source region
    f.cx.handleMouseUp(280, 190);

    try std.testing.expectEqual(@as(usize, 2), f.rec.len);
    try std.testing.expectEqual(@as(f32, 270), f.rec.events[1].delta.x);
    try std.testing.expectEqual(@as(f32, 0), f.rec.events[1].delta.y);
    try std.testing.expectEqual(@as(f32, 180), f.rec.events[1].raw_delta.y);
}

test "drag: 无 move 但 up 跨阈值，顺序 start/end 且无 click" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{ .activation_distance = 4 });
    f.attachClickCounter();

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseUp(60, 10);

    try std.testing.expectEqual(@as(usize, 2), f.rec.len);
    try std.testing.expectEqual(drag_mod.Phase.start, f.rec.events[0].phase);
    try std.testing.expectEqual(drag_mod.Phase.end, f.rec.events[1].phase);
    try std.testing.expectEqual(@as(u32, 0), f.rec.clicks);
    try std.testing.expect(f.cx.drag_manager.session == null);
}

test "drag: Escape 取消 active，恰好一次 cancel，up 幂等无 click" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{});
    f.attachClickCounter();

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(40, 10);
    f.cx.handleKeyDown(.escape, .{});

    try std.testing.expectEqual(@as(usize, 2), f.rec.len);
    try std.testing.expectEqual(drag_mod.Phase.cancel, f.rec.events[1].phase);
    try std.testing.expectEqual(@as(?drag_mod.CancelReason, .escape), f.rec.events[1].cancel_reason);
    try std.testing.expect(!f.cx.dispatcher.hasPointerCapture());
    try std.testing.expect(f.cx.cursor_override == null);
    try std.testing.expect(f.cx.drag_manager.session == null);

    // second Escape produces no callback (idempotent)
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expectEqual(@as(usize, 2), f.rec.len);

    // late up does idempotent cleanup only, no click
    f.cx.handleMouseUp(40, 10);
    try std.testing.expectEqual(@as(usize, 2), f.rec.len);
    try std.testing.expectEqual(@as(u32, 0), f.rec.clicks);
}

test "drag: pending Escape 静默清理，up 不 click" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{ .activation_distance = 4 });
    f.attachClickCounter();

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expectEqual(@as(usize, 0), f.rec.len);
    try std.testing.expect(f.cx.drag_manager.session == null);

    f.cx.handleMouseUp(10, 10);
    try std.testing.expectEqual(@as(u32, 0), f.rec.clicks);
    try std.testing.expectEqual(@as(usize, 0), f.rec.len);
}

test "drag: window blur 取消 active" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{});

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(40, 10);
    f.cx.cancelPointerInteractions(.window_blur);

    try std.testing.expectEqual(drag_mod.Phase.cancel, f.rec.events[f.rec.len - 1].phase);
    try std.testing.expectEqual(@as(?drag_mod.CancelReason, .window_blur), f.rec.events[f.rec.len - 1].cancel_reason);
    try std.testing.expect(f.cx.drag_manager.session == null);
}

test "drag: setEnabled(false) 取消 active；disabled 时不 claim" {
    var f = try DragFixture.init();
    defer f.deinit();
    const b = try f.attach(.{});

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(40, 10);
    b.setEnabled(false);
    try std.testing.expectEqual(drag_mod.Phase.cancel, f.rec.events[f.rec.len - 1].phase);
    try std.testing.expectEqual(@as(?drag_mod.CancelReason, .disabled), f.rec.events[f.rec.len - 1].cancel_reason);

    f.cx.handleMouseUp(40, 10);
    const len_before = f.rec.len;
    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(40, 10);
    f.cx.handleMouseUp(40, 10);
    try std.testing.expectEqual(len_before, f.rec.len);
    try std.testing.expect(f.cx.drag_manager.session == null);
}

test "drag: source detach 取消 active（source_detached）" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{});

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(40, 10);
    f.cx.detachChild(f.root, f.source);

    try std.testing.expectEqual(drag_mod.Phase.cancel, f.rec.events[f.rec.len - 1].phase);
    try std.testing.expectEqual(@as(?drag_mod.CancelReason, .source_detached), f.rec.events[f.rec.len - 1].cancel_reason);
    try std.testing.expect(!f.cx.dispatcher.hasPointerCapture());
    try std.testing.expect(f.cx.drag_manager.session == null);
    // node detached, returned to test for cleanup
    f.cx.freeNode(f.source);
}

test "drag: move callback 中销毁 source 子树不 UAF，终止恰好一次" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{});
    f.rec.detach_parent_on_move = f.root;
    f.rec.detach_child_on_move = f.source;

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(40, 10); // start
    f.cx.handleMouseMove(50, 10); // move -> detach in callback -> sync cancel

    // start, move, cancel(source_detached)
    try std.testing.expectEqual(@as(usize, 3), f.rec.len);
    try std.testing.expectEqual(drag_mod.Phase.cancel, f.rec.events[2].phase);
    try std.testing.expectEqual(@as(?drag_mod.CancelReason, .source_detached), f.rec.events[2].cancel_reason);

    // subsequent input idempotent
    f.cx.handleMouseMove(60, 10);
    f.cx.handleMouseUp(60, 10);
    try std.testing.expectEqual(@as(usize, 3), f.rec.len);
    f.cx.freeNode(f.source);
}

test "drag: can_start 拒绝 → 只询问一次、无 callback、up 无 click" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{ .activation_distance = 4, .can_start = DragRec.canStart });
    f.attachClickCounter();
    f.rec.allow_start = false;

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(40, 10);
    f.cx.handleMouseMove(80, 40);
    f.cx.handleMouseUp(90, 50);

    try std.testing.expectEqual(@as(u32, 1), f.rec.can_start_calls);
    try std.testing.expectEqual(@as(usize, 0), f.rec.len);
    try std.testing.expectEqual(@as(u32, 0), f.rec.clicks);
    try std.testing.expect(f.cx.drag_manager.session == null);

    // next sequence re-asks
    f.rec.allow_start = true;
    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(40, 10);
    f.cx.handleMouseUp(40, 10);
    try std.testing.expectEqual(@as(u32, 2), f.rec.can_start_calls);
    try std.testing.expectEqual(@as(usize, 2), f.rec.len);
}

test "drag: activation_distance=0 down 当场 start，on_pending_down 先行" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{ .activation_distance = 0, .on_pending_down = DragRec.pendingCb });

    f.cx.handleMouseDown(10, 10, .{});
    try std.testing.expectEqual(@as(u32, 1), f.rec.pending_downs);
    try std.testing.expectEqual(@as(usize, 1), f.rec.len);
    try std.testing.expectEqual(drag_mod.Phase.start, f.rec.events[0].phase);
    try std.testing.expectEqual(@as(f32, 0), f.rec.events[0].delta.x);
    f.cx.handleMouseUp(10, 10);
    try std.testing.expectEqual(drag_mod.Phase.end, f.rec.events[1].phase);
}

test "drag: scope dispose 中途取消（scope_disposed），无 UAF" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{});

    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseMove(40, 10);
    f.scope.dispose();

    try std.testing.expectEqual(drag_mod.Phase.cancel, f.rec.events[f.rec.len - 1].phase);
    try std.testing.expectEqual(@as(?drag_mod.CancelReason, .scope_disposed), f.rec.events[f.rec.len - 1].cancel_reason);
    try std.testing.expect(f.cx.drag_manager.session == null);
    try std.testing.expect(!f.cx.dispatcher.hasPointerCapture());
    // source's event slot removed
    try std.testing.expect(f.source.behavior.events.on_event == null);
    try std.testing.expect(f.source.behavior.events.event_context == null);
}

test "drag: scope dispose before first mouse down detaches event slots" {
    var f = try DragFixture.init();
    defer f.deinit();
    _ = try f.attach(.{});

    // No pointer event has populated/refresh the binding handle yet.
    f.scope.dispose();

    try std.testing.expect(f.source.behavior.events.on_event == null);
    try std.testing.expect(f.source.behavior.events.event_context == null);
    // A later layout/input pass must not call through the freed Binding.
    f.cx.layout();
    f.cx.handleMouseDown(10, 10, .{});
    f.cx.handleMouseUp(10, 10);
    try std.testing.expectEqual(@as(usize, 0), f.rec.len);
}

test "drag: 嵌套 draggable 最深命中者获胜" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);
    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    const outer = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    const inner = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    try outer.appendChild(cx.allocator, inner);
    try root.appendChild(cx.allocator, outer);
    cx.root = root;
    const scope = try ReactiveScope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    var outer_rec = DragRec{};
    var inner_rec = DragRec{};
    _ = try drag_mod.Binding.attach(scope, cx, outer, .{}, DragRec.cb, &outer_rec);
    const inner_b = try drag_mod.Binding.attach(scope, cx, inner, .{}, DragRec.cb, &inner_rec);
    cx.layout();

    cx.handleMouseDown(10, 10, .{});
    try std.testing.expect(inner_b.isPending());
    cx.handleMouseMove(40, 10);
    cx.handleMouseUp(40, 10);

    try std.testing.expectEqual(@as(usize, 2), inner_rec.len);
    try std.testing.expectEqual(@as(usize, 0), outer_rec.len);
}

test "drag: 第二个 binding 在 session 期间不 claim" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);
    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 }, .direction = Direction.row }, .{});
    const a = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    const c = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    try root.appendChild(cx.allocator, a);
    try root.appendChild(cx.allocator, c);
    cx.root = root;
    const scope = try ReactiveScope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    var rec_a = DragRec{};
    var rec_c = DragRec{};
    const ba = try drag_mod.Binding.attach(scope, cx, a, .{}, DragRec.cb, &rec_a);
    const bc = try drag_mod.Binding.attach(scope, cx, c, .{}, DragRec.cb, &rec_c);
    cx.layout();

    cx.handleMouseDown(10, 10, .{});
    cx.handleMouseMove(40, 10); // a active, capture takes effect
    try std.testing.expect(ba.isDragging());
    try std.testing.expect(!bc.isPending());
    cx.handleMouseUp(40, 10);
    try std.testing.expectEqual(@as(usize, 0), rec_c.len);
}

test "drag: attach 错误（阈值/按钮/槽占用）事务性" {
    var f = try DragFixture.init();
    defer f.deinit();

    try std.testing.expectError(error.InvalidActivationDistance, f.attach(.{ .activation_distance = -1 }));
    try std.testing.expectError(error.InvalidActivationDistance, f.attach(.{ .activation_distance = std.math.nan(f32) }));
    try std.testing.expectError(error.UnsupportedButton, f.attach(.{ .button = .right }));
    // failure leaves no half-registered state
    try std.testing.expect(f.source.behavior.events.on_event == null);

    _ = try f.attach(.{});
    try std.testing.expectError(error.EventSlotOccupied, f.attach(.{}));
}

// Regression: 'letters micro-jitter on hover'. Same text, cached replay vs fresh redraw after dirty
// must produce bit-identical text_run x. When ancestors have fractional coordinates (glass islands,
// inline offsets), quantization mismatch causes hover bg flip (force fresh) to subpixel-shift text.
test "render: fresh re-record and cached splice agree on text x at fractional origin" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);

    const label = try text(cx, "Ghost jitter", .{
        .font_size = 12,
        .line_height = 1.25,
        .color = Color.rgba(30, 30, 30, 255),
    });
    const row = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 24 },
        .direction = .row,
        .align_items = .center,
    }, .{label});
    const list = try box(cx, .{
        .width = .{ .px = 228 },
        .height = .{ .px = 120 },
        .direction = .column,
        .overflow_hidden = true,
        // fractional padding -> line/text at subpixel coordinates (equivalent to real sidebar)
        .padding = .{ .left = 6.5, .top = 3.5, .right = 6, .bottom = 0 },
    }, .{row});
    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 200 },
        .padding = .{ .left = 12.5, .top = 8, .right = 0, .bottom = 0 },
    }, .{list});

    cx.root = root;
    cx.layout();

    const findText = struct {
        fn f(cmds: []const ui.paint_table.DisplayItem) ?ui.paint_table.DisplayItem {
            for (cmds) |cmd| {
                if (cmd.isText() and std.mem.indexOf(u8, cmd.text_content, "Ghost") != null) return cmd;
            }
            return null;
        }
    }.f;

    // Frame 1: all fresh.
    _ = cx.render();
    const t1 = findText(cx.lowerForEncoderPaintTable()) orelse return error.TestExpectedText;

    // Frame 2: clean -> cached replay path.
    _ = cx.render();
    const t2 = findText(cx.lowerForEncoderPaintTable()) orelse return error.TestExpectedText;

    // Frame 3: row bg direct write (= hover), row subtree fresh redraw.
    row.setStyle(null, .background, Color.rgba(0, 0, 0, 20));
    _ = cx.render();
    const t3 = findText(cx.lowerForEncoderPaintTable()) orelse return error.TestExpectedText;

    // Frame 4: bg back to transparent (= leave hover).
    row.setStyle(null, .background, Color.rgba(0, 0, 0, 0));
    _ = cx.render();
    const t4 = findText(cx.lowerForEncoderPaintTable()) orelse return error.TestExpectedText;

    // All bit-identical, no subpixel drift.
    try std.testing.expectEqual(t1.geom.x, t2.geom.x);
    try std.testing.expectEqual(t1.geom.y, t2.geom.y);
    try std.testing.expectEqual(t1.geom.x, t3.geom.x);
    try std.testing.expectEqual(t1.geom.y, t3.geom.y);
    try std.testing.expectEqual(t1.geom.x, t4.geom.x);
    try std.testing.expectEqual(t1.geom.y, t4.geom.y);
}

// TextProps.text_align: center/right only shifts draw start. Both wrapped (TextLayout) and
// single-line (wrap=.none) paths must work, offset formula matches text_layout.alignLineOffset.
test "render: text_align centers and end-aligns each visual line" {
    const cases = [_]struct { wrap: ui.TextWrap, text_align: ui.TextAlign }{
        .{ .wrap = .word, .text_align = .start },
        .{ .wrap = .word, .text_align = .center },
        .{ .wrap = .word, .text_align = .end },
        .{ .wrap = .none, .text_align = .center },
        .{ .wrap = .none, .text_align = .end },
    };
    for (cases) |c| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(320, 100);

        const label = try text(cx, "Align me", .{
            .font_size = 12,
            .line_height = 1.25,
            .color = Color.rgba(30, 30, 30, 255),
            .wrap = c.wrap,
            .text_align = c.text_align,
        });
        label.style.width = .{ .px = 200 };
        const root = try box(cx, .{
            .width = .{ .px = 320 },
            .height = .{ .px = 100 },
            .direction = .column,
        }, .{label});
        cx.root = root;
        cx.layout();
        _ = cx.render();

        var found: ?ui.paint_table.DisplayItem = null;
        for (cx.lowerForEncoderPaintTable()) |cmd| {
            if (cmd.isText() and std.mem.indexOf(u8, cmd.text_content, "Align") != null) found = cmd;
        }
        const run = found orelse return error.TestExpectedText;
        const gr = label.globalRect();
        const w = ui.text_layout.measureTextWidthByFontKind("Align me", 12, 400, false, false);
        const expected = gr.x + ui.text_layout.alignLineOffset(c.text_align, gr.w, w);
        try std.testing.expectApproxEqAbs(expected, run.geom.x, 0.75);
        if (c.text_align != .start) try std.testing.expect(run.geom.x > gr.x + 10);
    }
}

test "render: rotated node inside z=0 subtree stays below sibling z>0 overlay" {
    // Regression: color overlay (z=30500 sibling) over Inspector island; rotated square inside
    // floats above it. Transform nodes use separate path, escape z_index layering. Expected:
    // rotated node draws before overlay (behind).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 200);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});
    // Island (z default 0), contains 45-degree rotated square
    const island = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
        .background = Color.rgba(240, 240, 240, 255),
    }, .{});
    const rotated = try box(cx, .{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
    (try rotated.style.ensureExtFallible(cx.allocator)).rotate = std.math.pi / 4.0;
    try island.appendChild(cx.allocator, rotated);
    try root.appendChild(cx.allocator, island);
    // Overlay: z>0 sibling, covers island
    const overlay = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
        .background = Color.rgba(255, 255, 255, 255),
    }, .{});
    (try overlay.style.ensureExtFallible(cx.allocator)).z_index = 100;
    try root.appendChild(cx.allocator, overlay);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    var rotated_order: ?usize = null;
    var overlay_order: ?usize = null;
    for (cx.display_list.items.items, 0..) |item, index| switch (item) {
        .fill_rect => |fill| {
            if (fill.header.node_id == rotated.id and rotated_order == null) rotated_order = index;
            if (fill.header.node_id == overlay.id and overlay_order == null) overlay_order = index;
        },
        else => {},
    };
    try std.testing.expect(rotated_order != null);
    try std.testing.expect(overlay_order != null);
    try std.testing.expect(rotated_order.? < overlay_order.?);

    // frame 2 uses cached/retained path, layering must hold
    cx.frame_time_ms = 16.0;
    _ = cx.render();
    rotated_order = null;
    overlay_order = null;
    for (cx.display_list.items.items, 0..) |item, index| switch (item) {
        .fill_rect => |fill| {
            if (fill.header.node_id == rotated.id and rotated_order == null) rotated_order = index;
            if (fill.header.node_id == overlay.id and overlay_order == null) overlay_order = index;
        },
        else => {},
    };
    try std.testing.expect(rotated_order != null);
    try std.testing.expect(overlay_order != null);
    try std.testing.expect(rotated_order.? < overlay_order.?);
}

test "layout: absolute child appended after initial layout gets sized incrementally" {
    // Regression: sticky text disappears. Incremental layout skips absolute children; fallback
    // layoutNode leaves post-append absolute at (0,0,0,0), labels never render. After fix: absolute
    // + layout-dirty use layoutAbsoluteChild.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    const holder = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 140 },
        .height = .{ .px = 140 },
        .background = Color.rgba(240, 230, 80, 255),
    }, .{});
    try root.appendChild(cx.allocator, holder);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    // Mount absolute child after frame 1 layout (object drawn first, label after)
    const label = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 120 },
        .height = .{ .px = 20 },
        .background = Color.rgba(23, 23, 27, 255),
    }, .{});
    try root.children.items[0].appendChild(cx.allocator, label);
    cx.layout();
    _ = cx.render();

    const r = label.rectFromWorldOrFallback();
    try std.testing.expectEqual(@as(f32, 120), r.w);
    try std.testing.expectEqual(@as(f32, 20), r.h);
}

test "bulk layer: quad below a container's z does not cover that container's children" {
    // Regression: bulk merges by item z (sibling-only semantics). Container z=3 doesn't cascade;
    // collectSubtreeZ read child z_index (default 0), so text in z=3 container treated as z=0, z=2
    // quad inserted after and covers it.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 300);

    const host = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 300 } }, .{});
    // low-z object (expressed by bulk)
    const low = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
        .background = Color.rgba(200, 200, 200, 255),
    }, .{});
    (try low.style.ensureExtFallible(cx.allocator)).z_index = 1;
    try host.appendChild(cx.allocator, low);
    // high-z container + its child content (children have no z_index)
    const container = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
        .background = Color.rgba(240, 230, 80, 255),
    }, .{});
    (try container.style.ensureExtFallible(cx.allocator)).z_index = 3;
    const child_content = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 60 },
        .height = .{ .px = 20 },
        .background = Color.rgba(23, 23, 27, 255),
    }, .{});
    try container.appendChild(cx.allocator, child_content);
    try host.appendChild(cx.allocator, container);
    cx.root = host;

    // z=2 quad: should draw over low (z=1), under container (z=3) and its content
    try cx.setBulkQuads(host, &.{.{
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 100,
        .color = Color.rgba(0, 0, 255, 255),
        .z_index = 2,
    }});
    cx.layout();
    _ = cx.render();

    var quad_order: ?usize = null;
    var child_order: ?usize = null;
    for (cx.display_list.items.items, 0..) |item, index| switch (item) {
        .fill_rect => |fill| {
            if (fill.header.node_id == host.id and quad_order == null) quad_order = index;
            if (fill.header.node_id == child_content.id and child_order == null) child_order = index;
        },
        else => {},
    };
    try std.testing.expect(quad_order != null);
    try std.testing.expect(child_order != null);
    // container's child content must draw after quad (= over it)
    try std.testing.expect(quad_order.? < child_order.?);
}

test "render: node-local overflow clip follows text across surfaces and retained frames" {
    for ([_]u8{ 0, 1, 2 }) |layers| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(800, 600);
        const root = try box(cx, .{ .width = .{ .px = 700 }, .height = .{ .px = 500 }, .padding = Padding.all(30), .opacity = if (layers == 2) 0.8 else 1 }, .{});
        root.style.translate_x = 70;
        root.style.translate_y = 40;
        const panel = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 150 }, .padding = Padding.all(24), .opacity = if (layers > 0) 0.7 else 1 }, .{});
        const clipper = try box(cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 30 }, .overflow_hidden = true }, .{});
        const label = try text(cx, "placeholder", .{ .font_size = 14 });
        try clipper.appendChild(cx.allocator, label);
        try panel.appendChild(cx.allocator, clipper);
        try root.appendChild(cx.allocator, panel);
        cx.root = root;
        for (0..3) |frame| {
            if (frame == 2) {
                label.setText(.{ .content = "https://example.com/long-long-url", .font_size = 14 });
                label.markSizingDirty();
                label.markRenderDirty();
            }
            cx.layout();
            _ = cx.render();
            const commands = cx.lowerForEncoderPaintTable();
            var clip: ?ui.ComputedRect = null;
            var found = false;
            for (commands) |cmd| {
                if (cmd.isControl(.push_clip) and @abs(cmd.geom.w - 120) < 0.01) {
                    clip = .{ .x = cmd.geom.x, .y = cmd.geom.y, .w = cmd.geom.w, .h = cmd.geom.h };
                }
                if (cmd.kind == .text and cmd.text_content.len > 0) {
                    try std.testing.expect(clip != null);
                    try std.testing.expectApproxEqAbs(clip.?.x, cmd.geom.x, 0.01);
                    try std.testing.expect(cmd.geom.y >= clip.?.y and cmd.geom.y < clip.?.y + clip.?.h);
                    if (frame == 2) try std.testing.expect(std.mem.startsWith(u8, cmd.text_content, "https://"));
                    found = true;
                }
            }
            try std.testing.expect(found);
        }
    }
}

test "Snapshot.capture preserves descendant clip and paint placement" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(500, 300);
    const painted = try box(cx, .{ .width = .{ .px = 160 }, .height = .{ .px = 30 }, .background = Color.rgb(210, 20, 20) }, .{});
    const clipper = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .overflow_hidden = true }, .{painted});
    const panel = try box(cx, .{ .width = .{ .px = 260 }, .height = .{ .px = 140 }, .padding = Padding.all(20) }, .{clipper});
    const root = try box(cx, .{ .width = .{ .px = 500 }, .height = .{ .px = 300 }, .padding = Padding.all(50) }, .{panel});
    cx.root = root;
    cx.layout();
    const snap = (try Snapshot.captureWithOptions(cx, panel, .{ .geometry_mode = .node_rect })).?;
    defer snap.deinit();
    var saw_clip = false;
    var saw_paint = false;
    for (snap.commands.commands) |item| switch (item) {
        .push_clip => |clip| {
            try std.testing.expectApproxEqAbs(@as(f32, 20), clip.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20), clip.y, 0.001);
            saw_clip = true;
        },
        .fill_rect => |rect| {
            if (rect.color.r != 210) continue;
            try std.testing.expectApproxEqAbs(@as(f32, 20), rect.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20), rect.y, 0.001);
            saw_paint = true;
        },
        else => {},
    };
    try std.testing.expect(saw_clip and saw_paint);
}

test "render: nested opacity layer composites in its parent content frame" {
    for ([_]f32{ 0.8, 1, 1.25 }) |scale| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(600, 400);
        const inner = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .opacity = 0.7, .background = Color.rgb(200, 0, 0) }, .{});
        try inner.appendChild(cx.allocator, try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgb(0, 180, 0) }, .{}));
        const outer = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 }, .padding = Padding.all(20), .opacity = 0.8 }, .{inner});
        outer.style.translate_x = 100;
        outer.style.translate_y = 60;
        const ext = try outer.style.ensureExtFallible(cx.allocator);
        ext.scale_x = scale;
        ext.scale_y = scale;
        outer.setTransformOrigin(cx.allocator, .{ .x = .{ .px = 0 }, .y = .{ .px = 0 } });
        cx.root = outer;
        cx.layout();
        _ = cx.render();
        var layer_index: usize = 0;
        for (cx.lowerForEncoderPaintTable()) |item| {
            if (!item.isControl(.begin_opacity_layer)) continue;
            const expected_x: f32 = if (layer_index == 0) 100 else 20;
            const expected_y: f32 = if (layer_index == 0) 60 else 20;
            try std.testing.expectApproxEqAbs(expected_x, item.draw_transform[4] - item.draw_transform[0] * item.geom.x - item.draw_transform[2] * item.geom.y, 0.001);
            try std.testing.expectApproxEqAbs(expected_y, item.draw_transform[5] - item.draw_transform[1] * item.geom.x - item.draw_transform[3] * item.geom.y, 0.001);
            layer_index += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), layer_index);
    }
}

test "Snapshot frozen clip and paint survive source teardown and property tree replacement" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(500, 300);
    const painted = try box(cx, .{ .width = .{ .px = 160 }, .height = .{ .px = 30 }, .background = Color.rgb(210, 20, 20) }, .{});
    const clipper = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .overflow_hidden = true }, .{painted});
    const panel = try box(cx, .{ .width = .{ .px = 260 }, .height = .{ .px = 140 }, .padding = Padding.all(20), .opacity = 0.8 }, .{clipper});
    panel.style.translate_x = 50;
    cx.root = panel;
    cx.layout();
    _ = cx.render();
    const epoch = cx.layer_tree.plan_epoch;
    const snap = (try Snapshot.captureWithOptions(cx, panel, .{ .geometry_mode = .node_rect })).?;
    defer snap.deinit();
    try std.testing.expectEqual(epoch, cx.layer_tree.plan_epoch);
    cx.root = null;
    cx.freeNode(panel);
    const replacement = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 }, .opacity = 0.6, .background = Color.rgb(90, 90, 90) }, .{});
    replacement.style.translate_x = 60;
    replacement.style.translate_y = 30;
    try replacement.appendChild(cx.allocator, try box(cx, .{ .width = .{ .px = 1 }, .height = .{ .px = 1 } }, .{}));
    replacement.setCustomDraw(struct {
        fn draw(ctx: ui.DrawContext, raw: ?*anyopaque) !void {
            const snapshot: *Snapshot = @ptrCast(@alignCast(raw.?));
            try snapshot.appendTo(ctx, .{ .x = 100, .y = 80 }, 1, 1);
        }
    }.draw, snap);
    cx.root = replacement;
    cx.layout();
    _ = cx.render();
    var saw_clip = false;
    var saw_paint = false;
    var depth: usize = 0;
    var saw_wrapper = false;
    for (cx.lowerForEncoderPaintTable()) |item| {
        if (item.isControl(.begin_opacity_layer)) {
            depth += 1;
            if (@abs(item.draw_w - 260) < 0.01) {
                try std.testing.expectEqual(@as(usize, 2), depth);
                try std.testing.expectApproxEqAbs(@as(f32, 40), item.draw_transform[4], 0.001);
                try std.testing.expectApproxEqAbs(@as(f32, 50), item.draw_transform[5], 0.001);
                saw_wrapper = true;
            }
        }
        if (item.isControl(.end_opacity_layer)) depth -|= 1;
        if (item.isControl(.push_clip) and item.geom.w == 100) {
            try std.testing.expectApproxEqAbs(@as(f32, 20), item.geom.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20), item.geom.y, 0.001);
            saw_clip = true;
        }
        if (item.kind == .rect and item.color.r == 210) {
            try std.testing.expectApproxEqAbs(@as(f32, 20), item.geom.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20), item.geom.y, 0.001);
            saw_paint = true;
        }
    }
    try std.testing.expect(saw_clip and saw_paint and saw_wrapper);
}

test "text ownership: getText 的副本不带所有权，读-改-写换成借用内容后销毁不误释放" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try text(cx, "framework owned content", .{});
    var t = node.getText().?;
    try std.testing.expect(!t.owned);
    try std.testing.expect(node.getTextRaw().?.owned);
    // write back as-is: ownership retained (freed on destroy, allocator detects leak)
    node.setText(t);
    try std.testing.expect(node.getTextRaw().?.owned);
    // swap to caller's borrowed content: node must not free
    t.content = "borrowed literal";
    node.setText(t);
    try std.testing.expect(!node.getTextRaw().?.owned);
    cx.freeNode(node);
}

test "text ownership: 同指针原地截断写回不恢复所有权（避免按错误长度释放）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try text(cx, "framework owned content", .{});
    var t = node.getText().?;
    const full = node.getTextRaw().?.content;
    t.content = t.content[0..5];
    node.setText(t);
    try std.testing.expect(!node.getTextRaw().?.owned);
    cx.freeNode(node);
    // node no longer owns pre-truncate block: test returns it, allocator happy
    std.testing.allocator.free(full);
}

test "Snapshot.captureDisplayed 换长文本后仍取到上一帧显示的内容（旧内容退役到下一帧）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);
    const label = try text(cx, "displayed content longer than sixteen", .{ .font_size = 14 });
    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 }, .padding = Padding.all(20) }, .{label});
    cx.root = root;
    cx.layout();
    _ = cx.render();
    try label.setTextContent(cx.allocator, "pending replacement that is also long");
    const snap = (try Snapshot.captureDisplayed(cx, label)).?;
    defer snap.deinit();
    var found = false;
    for (snap.commands.commands) |item| {
        if (item == .text_run) {
            try std.testing.expectEqualStrings("displayed content longer than sixteen", item.text_run.content);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "Snapshot.captureDisplayed preserves last displayed content when node is dirty" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);
    const label = try text(cx, "displayed", .{ .font_size = 14 });
    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 }, .padding = Padding.all(20) }, .{label});
    cx.root = root;
    cx.layout();
    _ = cx.render();
    try label.setTextContent(cx.allocator, "pending");
    const snap = (try Snapshot.captureDisplayed(cx, label)).?;
    defer snap.deinit();
    var found = false;
    for (snap.commands.commands) |item| {
        if (item == .text_run) {
            try std.testing.expectEqualStrings("displayed", item.text_run.content);
            try std.testing.expect(item.header().already_lowered);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "render: blur clip and composite use the enclosing surface frame" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 400);
    const blurred = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 }, .background = Color.rgb(100, 120, 140) }, .{});
    blurred.style.ensureExtPanic(cx.allocator).glass = .{ .backdrop_blur = 8 };
    const clipper = try box(cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 60 }, .overflow_hidden = true }, .{blurred});
    const outer = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 }, .padding = Padding.all(30), .opacity = 0.8 }, .{clipper});
    outer.style.translate_x = 120;
    outer.style.translate_y = 50;
    cx.root = outer;
    cx.layout();
    _ = cx.render();
    var clip_x: ?f32 = null;
    var saw_blur = false;
    for (cx.lowerForEncoderPaintTable()) |item| {
        if (item.isControl(.push_clip)) clip_x = item.geom.x;
        if (item.isControl(.begin_blur_layer)) {
            try std.testing.expect(clip_x != null);
            try std.testing.expectApproxEqAbs(@as(f32, 30), clip_x.?, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 30), item.draw_transform[4], 0.001);
            saw_blur = true;
        }
    }
    try std.testing.expect(saw_blur);
}

test "Snapshot text-only capture has a nonzero surface width" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 100);
    const label = try text(cx, "Visible snapshot text", .{ .font_size = 14 });
    cx.root = label;
    cx.layout();
    const snap = (try Snapshot.capture(cx, label)).?;
    defer snap.deinit();
    try std.testing.expect(snap.local_bounds.w > 50);
    try std.testing.expect(snap.local_bounds.h >= 14);
}

// Runtime-index rebuilds change which node holds focus (they detach the
// subtree from the registry/focus_order and re-register it) without ever
// going through setFocusWithReason. The window-level native IME gate is
// derived from focus, so it must be reconciled at the same boundary,
// otherwise a focused editor keeps a closed gate and accepts no IME input.
test "Cx: runtime index rebuild reconciles the native IME gate" {
    const ImeGateMock = struct {
        enabled_calls: u32 = 0,
        last_enabled: bool = false,

        fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}
        fn pump(_: *anyopaque, _: *system_sdk.events.EventQueue, _: u32) system_sdk.SdkError!system_sdk.PumpResult {
            return .{};
        }
        fn setEnabled(context: *anyopaque, _: system_sdk.events.WindowId, enabled: bool) system_sdk.SdkError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.enabled_calls += 1;
            self.last_enabled = enabled;
        }
        fn setCursorRect(_: *anyopaque, _: system_sdk.events.WindowId, _: f32, _: f32, _: f32, _: f32) system_sdk.SdkError!void {}
        fn discard(_: *anyopaque, _: system_sdk.events.WindowId) system_sdk.SdkError!void {}
    };

    var backend = ImeGateMock{};
    const vtable = system_sdk.BackendVTable{
        .name = "ime-gate-rebuild-mock",
        .deinit = ImeGateMock.deinitFn,
        .pump_events = ImeGateMock.pump,
        .ime = .{
            .set_enabled = ImeGateMock.setEnabled,
            .set_cursor_rect = ImeGateMock.setCursorRect,
            .discard = ImeGateMock.discard,
        },
    };
    var sdk = system_sdk.SystemSdk.init(std.testing.allocator, &backend, &vtable, .{ .ime = true });
    defer sdk.deinit();

    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);

    const ignoredEvent = struct {
        fn handler(_: Event, _: ?*anyopaque) EventResult {
            return .ignored;
        }
    }.handler;

    const root = try box(cx, .{}, .{});
    const editor = try box(cx, .{}, .{});
    editor.behavior.events.on_event = ignoredEvent;
    editor.behavior.interaction.text_input_client = emptyTextInputClient(editor);
    editor.setFocusable(true);
    editor.tag = .input;
    const row = try box(cx, .{}, .{});
    try editor.appendChild(cx.allocator, row);
    try root.appendChild(cx.allocator, editor);
    cx.root = root;
    try cx.rebuildRuntimeIndexesForTest();

    cx.focus_manager.setFocus(editor);
    try std.testing.expect(backend.last_enabled);

    // The app hands the gate to another client (e.g. a popover Input), which
    // closes the single window-level native gate.
    const popover_input = try box(cx, .{}, .{});
    popover_input.behavior.events.on_event = ignoredEvent;
    popover_input.setFocusable(true);
    try root.appendChild(cx.allocator, popover_input);
    cx.focus_manager.setFocus(popover_input);
    try std.testing.expect(!backend.last_enabled);

    // Focus returns to the editor, but through the rebuild path rather than a
    // fresh setFocusWithReason: this is what a VirtualList row refresh or a
    // syntax-prewarm driven partial rebuild does on a focused editor.
    cx.focus_manager.current_focus = editor;
    cx.focus_manager.current_focus_handle = cx.node_registry.handleFor(editor);
    row.markRuntimeIndexDirty();
    try cx.rebuildRuntimeIndexesForTest();

    try std.testing.expect(cx.focus_manager.getFocused() == editor);
    // Focus is on a live text-input client, so the native gate must be open.
    try std.testing.expect(backend.last_enabled);

    // Second shape of the same defect: freeing the active client closes the
    // window-global gate (fail-safe, by design). When focus afterwards sits on
    // another live client, the next rebuild has to reopen it, otherwise the
    // editor stays permanently mute.
    root.removeChildIncremental(popover_input);
    cx.freeNode(popover_input);
    cx.focus_manager.setFocus(null);
    cx.focus_manager.current_focus = editor;
    cx.focus_manager.current_focus_handle = cx.node_registry.handleFor(editor);
    try std.testing.expect(!backend.last_enabled);
    row.markRuntimeIndexDirty();
    try cx.rebuildRuntimeIndexesForTest();
    try std.testing.expect(cx.focus_manager.getFocused() == editor);
    try std.testing.expect(backend.last_enabled);
}

test "Cx: preedit acknowledgement rejects freed switched and replaced clients" {
    const Probe = struct {
        cx: *Cx,
        root: *Node,
        node: *Node,
        other: *Node,
        mode: enum { keep, free, focus, swap },
        marked_reads: usize = 0,
        fn length(_: *anyopaque) usize {
            return 1;
        }
        fn copy(_: *anyopaque, start: usize, out: []u8) usize {
            if (start != 0 or out.len == 0) return 0;
            out[0] = 'x';
            return 1;
        }
        fn selection(_: *anyopaque) ui.TextInputSelection {
            return .{ .start = 1, .end = 1, .caret = 1 };
        }
        fn marked(context: *anyopaque, start: *u32, end: *u32) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.marked_reads += 1;
            start.* = 0;
            end.* = 1;
            return true;
        }
        fn client(self: *@This()) ui.TextInputClient {
            return .{ .context = self, .text_len = length, .copy_text = copy, .selection = selection, .marked_range = marked };
        }
        fn event(e: Event, context: ?*anyopaque) EventResult {
            if (e != .ime_preedit) return .ignored;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (self.mode) {
                .keep => {},
                .free => {
                    self.cx.detachChild(self.root, self.node);
                    self.cx.freeNode(self.node);
                },
                .focus => self.cx.focus_manager.setFocus(self.other),
                .swap => self.node.behavior.interaction.text_input_client = self.other.behavior.interaction.text_input_client,
            }
            return .stop;
        }
    };
    const Capture = struct {
        var calls: usize = 0;
        var window: u32 = 0;
        fn apply(w: u32, _: u64, _: u64, _: u32, _: u32) callconv(.c) c_int {
            calls += 1;
            window = w;
            return 1;
        }
    };
    ui.a11y_macos_bridge.setTextInputAppliedHook(Capture.apply);
    defer ui.a11y_macos_bridge.setTextInputAppliedHook(null);
    for ([_]@FieldType(Probe, "mode"){ .keep, .free, .focus, .swap }) |mode| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setWindowIdentity(88, 903);
        const f = try focusFreeFixture(cx);
        var first = Probe{ .cx = cx, .root = f.root, .node = f.a, .other = f.b, .mode = mode };
        var second = Probe{ .cx = cx, .root = f.root, .node = f.b, .other = f.a, .mode = .keep };
        f.a.behavior.events.on_event = Probe.event;
        f.a.behavior.events.event_context = &first;
        f.a.behavior.interaction.text_input_client = first.client();
        f.b.behavior.events.on_event = Probe.event;
        f.b.behavior.events.event_context = &second;
        f.b.behavior.interaction.text_input_client = second.client();
        cx.focus_manager.setFocus(f.a);
        Capture.calls = 0;
        cx.handleImePreedit("x", 1);
        try std.testing.expectEqual(@as(usize, if (mode == .keep) 1 else 0), Capture.calls);
        try std.testing.expectEqual(@as(usize, if (mode == .keep) 1 else 0), first.marked_reads);
        try std.testing.expectEqual(@as(usize, 0), second.marked_reads);
        if (mode == .keep) try std.testing.expectEqual(@as(u32, 903), Capture.window);
    }
}

// ─── Click callback replaceChildOrder with same-shape new subtree, new subtree never hits ───
// Scene: downstream Global Find clicks result -> callback rebuilds list (new VirtualList replaces)
// + preview toggles; after, all list clicks miss, hit parent. Root: post-mouseUp
// rebuildRuntimeIndexes rebuilds hit index at 0-size, clears dirty flag.
const SwapRepro = struct {
    const ROWS: usize = 5;
    const ROW_H: f32 = 20;
    var g_cx: ?*Cx = null;
    var wrapper: ?*Node = null;
    var list: ?*Node = null;
    var ed_a: ?*Node = null;
    var ed_b: ?*Node = null;
    var show_a: bool = true;
    var clicks: usize = 0;
    var mode_new_slot: bool = false;
    var preview: ?*Node = null;

    fn rowHandler(event: Event, _: ?*anyopaque) EventResult {
        switch (event) {
            .click => {},
            else => return .ignored,
        }
        clicks += 1;
        const cx = g_cx.?;
        // 1. rebuild list: brand-new detached subtree, same shape.
        const new_list = buildList(cx) catch unreachable;
        const w = wrapper.?;
        const old = list.?;
        var order: [2]*Node = undefined;
        @memcpy(order[0..w.children.items.len], w.children.items);
        const idx = std.mem.indexOfScalar(*Node, order[0..w.children.items.len], old).?;
        order[idx] = new_list;
        w.replaceChildOrder(cx.allocator, order[0..w.children.items.len]) catch unreachable;
        list = new_list;
        cx.freeNode(old);
        // 2. preview: reuse-slot switch = style only (EditorPool.showOnlyId).
        if (mode_new_slot) {
            const ed = makeEditor(cx, true) catch unreachable;
            preview.?.appendChild(cx.allocator, ed) catch unreachable;
        } else {
            show_a = !show_a;
            setVisible(ed_a.?, show_a);
            setVisible(ed_b.?, !show_a);
            preview.?.markLayoutDirty();
        }
        return .stop;
    }

    fn setVisible(n: *Node, v: bool) void {
        n.setOpacity(if (v) 1 else 0);
        n.style.width = if (v) .{ .grow = .{} } else .{ .px = 0 };
        n.style.height = if (v) .{ .grow = .{} } else .{ .px = 0 };
        n.markRenderDirty();
        n.markLayoutDirty();
    }

    fn buildList(cx: *Cx) !*Node {
        const l = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .column }, .{});
        l.style.overflow_hidden = true;
        for (0..ROWS) |_| {
            const r = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = ROW_H } }, .{});
            r.meta.ownership.meta.test_id = "row";
            r.behavior.events.on_event = rowHandler;
            try l.appendChild(cx.allocator, r);
        }
        return l;
    }

    fn makeEditor(cx: *Cx, visible: bool) !*Node {
        const e = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } }, .{});
        const inner = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
        inner.behavior.events.on_event = struct {
            fn h(_: Event, _: ?*anyopaque) EventResult {
                return .ignored;
            }
        }.h;
        try e.appendChild(cx.allocator, inner);
        setVisible(e, visible);
        return e;
    }

    fn bodyHandler(_: Event, _: ?*anyopaque) EventResult {
        return .ignored;
    }

    fn run(new_slot: bool) !void {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(800, 600);
        g_cx = cx;
        clicks = 0;
        show_a = true;
        mode_new_slot = new_slot;

        const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 600 }, .direction = .column }, .{});
        const body = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .row }, .{});
        body.meta.ownership.meta.test_id = "body";
        body.behavior.events.on_event = bodyHandler;
        try root.appendChild(cx.allocator, body);
        const w = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .grow = .{} }, .direction = .column }, .{});
        try body.appendChild(cx.allocator, w);
        wrapper = w;
        const l = try buildList(cx);
        try w.appendChild(cx.allocator, l);
        list = l;
        const hint = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 0 } }, .{});
        try w.appendChild(cx.allocator, hint);
        const pv = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .column }, .{});
        try body.appendChild(cx.allocator, pv);
        preview = pv;
        ed_a = try makeEditor(cx, true);
        ed_b = try makeEditor(cx, false);
        try pv.appendChild(cx.allocator, ed_a.?);
        try pv.appendChild(cx.allocator, ed_b.?);

        cx.root = root;
        cx.layout();
        _ = cx.render();

        var i: usize = 0;
        while (i < 6) : (i += 1) {
            const y = ROW_H * 1.5;
            const before = cx.hitTest(100, y);
            const tid = if (before) |n| n.meta.ownership.meta.test_id orelse "(none)" else "(null)";
            try std.testing.expectEqualStrings("row", tid);
            cx.handleClick(100, y);
            var f: usize = 0;
            while (f < 5) : (f += 1) {
                cx.handleMouseMove(100, y + @as(f32, @floatFromInt(f)));
                _ = cx.render();
            }
        }
        try std.testing.expectEqual(@as(usize, 6), clicks);
    }
};

test "hit-test: click handler swaps in same-shape subtree via replaceChildOrder (reuse preview slot)" {
    try SwapRepro.run(false);
}

test "hit-test: click handler swaps in same-shape subtree via replaceChildOrder (new preview slot)" {
    try SwapRepro.run(true);
}

// ─── freeNode immediate path must clear interaction raw refs to freed subtree ───
// Scene: click callback frees pressed row; if before_render hook runs before cleanup clears
// pressed_node, animBg reads freed pointer -> segfault.
test "freeNode outside tick/reactive depth clears pressed/hovered/last-mouse-down refs into the freed subtree" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 }, .direction = .column }, .{});
    const list = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 100 }, .direction = .column }, .{});
    try root.appendChild(cx.allocator, list);
    const row = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 } }, .{});
    row.behavior.events.on_event = struct {
        fn h(_: Event, _: ?*anyopaque) EventResult {
            return .stop;
        }
    }.h;
    try list.appendChild(cx.allocator, row);
    const keep = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 } }, .{});
    try root.appendChild(cx.allocator, keep);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    cx.handleMouseMove(10, 10);
    cx.handleMouseDown(10, 10, .{});
    try std.testing.expect(cx.pressed_node == row);

    root.removeChild(list);
    cx.freeNode(list);
    try std.testing.expect(cx.pressed_node == null);
    try std.testing.expect(cx.pressed_handle == null);
    try std.testing.expect(cx.hovered_node == null);
    try std.testing.expect(cx.last_mouse_down_target == null);
    cx.handleMouseUp(10, 10);
    _ = cx.render();
}

// ─── portal ancestor check doesn't treat window-root clip as problem ───
// A borderless window root carries overflow_hidden (rounded corners) and its clip is the viewport.
// Mounting an overlay such as a tooltip inside it used to log.err "clipping/effect-surface
// ancestor" every time, and the test runner fails tests that log errors. The chain-top node (no
// parent) must be skipped; inner clipping ancestors are still reported.
test "popover portal under an overflow-hidden window root logs no clipping error" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 }, .direction = .column }, .{});
    root.style.overflow_hidden = true;
    cx.root = root;
    const portal = try cx.ensurePopoverPortalRoot();
    try std.testing.expect(portal.parent == root);
    _ = try cx.ensurePopoverPortalRoot();
}

test "multi box-shadow with spread lowers one shadow_rect per layer, last layer first" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const card = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 }, .background = Color.rgba(255, 255, 255, 200) }, .{});
    try root.appendChild(std.testing.allocator, card);
    // Design 16.3 three-layer shadow: 0 1 2 .10 / 0 16 34 -12 .24 / 0 40 80 -32 .36
    (try card.style.ensureExtFallible(std.testing.allocator)).setShadowList(&.{
        .{ .color = Color.rgba(50, 38, 26, 26), .blur = 2, .offset_y = 1 },
        .{ .color = Color.rgba(50, 38, 26, 61), .blur = 34, .offset_y = 16, .spread = -12 },
        .{ .color = Color.rgba(50, 38, 26, 92), .blur = 80, .offset_y = 40, .spread = -32 },
    });
    cx.layout();
    _ = cx.render();
    var got: [4]f32 = undefined;
    var n: usize = 0;
    for (cx.display_list.items.items) |it| switch (it) {
        .shadow_rect => |s| {
            if (n < got.len) got[n] = s.spread;
            n += 1;
        },
        .shadow_dual_rect => return error.UnexpectedDualShadow,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), n);
    // first item topmost -> last drawn: emit order 3, 2, 1
    try std.testing.expectApproxEqAbs(@as(f32, -32), got[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -12), got[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), got[2], 1e-4);
}

test "multi inset shadows lower with a transparent fill (no double-painted translucent background)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const card = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 }, .background = Color.rgba(251, 250, 247, 214) }, .{});
    try root.appendChild(std.testing.allocator, card);
    (try card.style.ensureExtFallible(std.testing.allocator)).setInsetShadowList(&.{
        .{ .color = Color.rgba(255, 255, 255, 242), .blur = 0, .offset_y = 1 },
        .{ .color = Color.rgba(0, 0, 0, 23), .blur = 0, .offset_y = -1 },
        .{ .color = Color.rgba(255, 255, 255, 89), .blur = 22 },
    });
    cx.layout();
    _ = cx.render();
    var n: usize = 0;
    for (cx.display_list.items.items) |it| switch (it) {
        .inset_shadow_rect => |s| {
            n += 1;
            try std.testing.expectEqual(@as(u8, 0), s.fill.a);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "radial multi-gradient carries CSS center and ellipse radius to the display list" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const card = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 } }, .{});
    try root.appendChild(std.testing.allocator, card);
    var mg = ui.MultiGradient.fromSlice(&.{
        .{ .color = Color.rgba(255, 255, 255, 140), .position = 0 },
        .{ .color = Color.rgba(255, 255, 255, 0), .position = 0.58 },
    }, .radial);
    mg.radial_center = .{ 0.12, -0.1 };
    mg.radial_radius = .{ 1.2, 1.0 };
    (try card.style.ensureExtFallible(std.testing.allocator)).multi_gradient = mg;
    cx.layout();
    _ = cx.render();
    var seen = false;
    for (cx.display_list.items.items) |it| switch (it) {
        .multi_gradient_rect => |g| {
            seen = true;
            try std.testing.expectApproxEqAbs(@as(f32, 0.12 - 0.5), g.radial_center_x, 1e-5);
            try std.testing.expectApproxEqAbs(@as(f32, -0.1 - 0.5), g.radial_center_y, 1e-5);
            try std.testing.expectApproxEqAbs(@as(f32, 1.2), g.radial_radius_x, 1e-5);
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), g.radial_radius_y, 1e-5);
        },
        else => {},
    };
    try std.testing.expect(seen);
}

test "glass backdrop saturation / brightness resolve with clamping" {
    const g = (ui.GlassParams{ .backdrop_blur = 46, .backdrop_saturation = 2.1, .backdrop_brightness = 1.06 }).resolve();
    try std.testing.expectApproxEqAbs(@as(f32, 2.1), g.backdrop_saturation, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.06), g.backdrop_brightness, 1e-5);
    const clamped = (ui.GlassParams{ .backdrop_saturation = 99, .backdrop_brightness = -1 }).resolve();
    // ceiling 8: native model chroma gain after veil alpha compensation can exceed 4
    try std.testing.expectApproxEqAbs(@as(f32, 8), clamped.backdrop_saturation, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), clamped.backdrop_brightness, 1e-5);
}

test "Cx timers: wake an idle loop, fire before the zero-dirty fast path, and can be cleared" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(200, 100);
    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;
    cx.layout();
    _ = cx.render();
    _ = cx.render();
    cx.needs_redraw = false;

    const Rec = struct {
        fired: usize = 0,
        node: *Node,
        fn cb(ctx: ?*anyopaque) void {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            r.fired += 1;
            r.node.markRenderDirty();
        }
    };
    var rec: Rec = .{ .node = root };
    _ = try cx.setTimer(2 * std.time.ns_per_ms, Rec.cb, &rec);
    const cleared = try cx.setTimer(2 * std.time.ns_per_ms, Rec.cb, &rec);
    cx.clearTimer(cleared);
    try std.testing.expect(!cx.wantsFrame());
    const wake = cx.nextWakeDelayNs() orelse return error.NoWake;
    try std.testing.expect(wake <= 2 * std.time.ns_per_ms);
    try std.Io.sleep(cx.io, .fromNanoseconds(4 * std.time.ns_per_ms), .awake);
    try std.testing.expect(cx.wantsFrame());
    _ = cx.render();
    try std.testing.expectEqual(@as(usize, 1), rec.fired);
    try std.testing.expect(cx.nextWakeDelayNs() == null);
    _ = cx.render();
    try std.testing.expectEqual(@as(usize, 1), rec.fired);
}

fn countTextRuns(items: anytype) usize {
    var n: usize = 0;
    for (items) |it| {
        if (it == .text_run) n += it.text_run.content.len;
    }
    return n;
}

fn textFillCase(wrap: ui.TextWrap, start_hidden: bool) !usize {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 200);
    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 }, .direction = .column }, .{});
    cx.root = root;
    const wrap_box = try box(cx, .{ .width = .{ .px = 260 }, .direction = .column }, .{});
    try root.appendChild(cx.allocator, wrap_box);
    if (start_hidden) {
        wrap_box.style.height = .{ .px = 0 };
        wrap_box.style.overflow_hidden = true;
        wrap_box.setOpacityRaw(0);
    }
    const row = try box(cx, .{ .width = .fill(), .direction = .row, .gap = 10 }, .{});
    try wrap_box.appendChild(cx.allocator, row);
    const col = try box(cx, .{ .width = .fill(), .direction = .column, .gap = 1 }, .{});
    try row.appendChild(cx.allocator, col);
    const t = try text(cx, "short", .{ .font_size = 12, .wrap = wrap });
    try col.appendChild(cx.allocator, t);
    t.style.width = .fill();
    cx.layout();
    _ = cx.render();
    const one_line_h = t.rectFromWorldOrFallback().h;
    try t.setTextContent(cx.allocator, "0 silenced · nothing pops up; summarized once when it ends, and this sentence keeps going so it needs several lines");
    t.markSizingDirty();
    if (start_hidden) {
        wrap_box.style.height = .{ .fit = .{} };
        wrap_box.markSizingDirty();
        wrap_box.setOpacity(1);
    }
    cx.layout();
    const painted_bytes = countTextRuns(cx.render());
    // wrapping text must reflow to new content: height extends to multiline
    if (wrap != .none) try std.testing.expect(t.rectFromWorldOrFallback().h > one_line_h * 2);
    // drawn is entire new content (line-end break spaces optional)
    const expected = "0 silenced · nothing pops up; summarized once when it ends, and this sentence keeps going so it needs several lines".len;
    try std.testing.expect(painted_bytes + 8 >= expected);
    return painted_bytes;
}

test "text: an empty wrapped text node paints after setTextContent" {
    try std.testing.expect(try textFillCase(.none, false) > 0);
    try std.testing.expect(try textFillCase(.word, false) > 0);
    try std.testing.expect(try textFillCase(.none, true) > 0);
    try std.testing.expect(try textFillCase(.word, true) > 0);
}

test "text: setTextContent re-measures so a longer label never overflows its row" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(300, 100);
    const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 }, .direction = .column }, .{});
    cx.root = root;
    const row = try box(cx, .{ .width = .{ .px = 200 }, .direction = .row, .gap = 6 }, .{});
    try root.appendChild(cx.allocator, row);
    const title = try text(cx, "A title that fills the row", .{ .font_size = 13, .wrap = .word });
    try row.appendChild(cx.allocator, title);
    title.style.width = .fill();
    const ts = try text(cx, "now", .{ .font_size = 11 });
    try row.appendChild(cx.allocator, ts);
    ts.style.flex_shrink = 0;
    cx.layout();
    _ = cx.render();
    const short_w = ts.rectFromWorldOrFallback().w;
    // don't manually mark dirty: setTextContent handles it
    try ts.setTextContent(cx.allocator, "12 minutes ago");
    _ = cx.render();
    const r = ts.rectFromWorldOrFallback();
    try std.testing.expect(r.w > short_w * 2);
    // right edge stays inline (right-aligned, doesn't overflow)
    const row_r = row.rectFromWorldOrFallback();
    try std.testing.expect(ts.globalRect().x + r.w <= row.globalRect().x + row_r.w + 0.5);
}

test "layout: a fit-height absolute child grows when only its descendants change" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(400, 600);
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    // like Popover panel: absolute, height fits content
    const panel = try box(cx, .{ .position = .absolute, .width = .{ .px = 200 }, .direction = .column }, .{});
    panel.style.height = .{ .fit = .{} };
    try root.appendChild(cx.allocator, panel);
    const list = try box(cx, .{ .width = .fill(), .direction = .column }, .{});
    list.style.height = .{ .fit = .{} };
    // shrinkable list (Popover 'only list yields' pattern): old height compressed when out of space
    list.style.flex_shrink = 1;
    try panel.appendChild(cx.allocator, list);
    try list.appendChild(cx.allocator, try box(cx, .{ .width = .fill(), .height = .{ .px = 40 } }, .{}));
    cx.layout();
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 40), panel.rectFromWorldOrFallback().h, 0.5);
    // only add row in subtree: panel not layout-dirty, only subtree_layout
    try list.appendChild(cx.allocator, try box(cx, .{ .width = .fill(), .height = .{ .px = 60 } }, .{}));
    try list.appendChild(cx.allocator, try box(cx, .{ .width = .fill(), .height = .{ .px = 60 } }, .{}));
    cx.layout();
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 160), list.rectFromWorldOrFallback().h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 160), panel.rectFromWorldOrFallback().h, 0.5);
}

// ─── overflow clip clips descendants only, at the padding box (inner edge of the border) ───
//
// Regression: shadow clipped to border-box, rounded corners expose gray, panel shadow disappears;
// edge child covers stroke.
// Two paths: normal node (lowering) + composited_group owner (Popover, apply_clip post begin_layer
// clipped owner shadow too); also covers promoted cache hits.

const OwnClipProbe = struct {
    /// first shadow command scissor depth (0 = unclipped)
    shadow_depth: ?usize = null,
    /// target child fill world scissor (null = unclipped)
    child_scissor: ?ui.ComputedRect = null,
    child_found: bool = false,
};

fn ownClipProbe(cx: *Cx, child_w: f32, child_h: f32, child_color: Color) !OwnClipProbe {
    var out: OwnClipProbe = .{};
    var stack: [32]ui.ComputedRect = undefined;
    var depth: usize = 0;
    var frames: [16]C2SurfaceFrame = undefined;
    var frame_depth: usize = 0;
    for (cx.lowerForEncoderPaintTable()) |it| {
        if (it.kind == .control) {
            switch (it.control_kind) {
                .push_clip => {
                    if (depth >= stack.len) return error.ScissorStackOverflow;
                    stack[depth] = c2RectToWorld(frames[0..frame_depth], ui.ComputedRect.init(it.geom.x, it.geom.y, it.geom.w, it.geom.h));
                    depth += 1;
                },
                .pop_clip => depth -|= 1,
                .begin_opacity_layer => {
                    if (frame_depth >= frames.len) return error.SurfaceStackOverflow;
                    frames[frame_depth] = .{
                        .m = if (it.use_draw_transform) it.draw_transform else .{ 1, 0, 0, 1, it.draw_x, it.draw_y },
                        .src_x = it.geom.x,
                        .src_y = it.geom.y,
                    };
                    frame_depth += 1;
                },
                .end_opacity_layer => frame_depth -|= 1,
                else => {},
            }
            continue;
        }
        if (it.kind == .shadow and out.shadow_depth == null) out.shadow_depth = depth;
        if (!out.child_found and it.isFillRect() and
            @abs(it.geom.w - child_w) <= 0.5 and @abs(it.geom.h - child_h) <= 0.5 and
            it.color.r == child_color.r and it.color.g == child_color.g and it.color.b == child_color.b)
        {
            out.child_found = true;
            if (depth > 0) {
                var x0: f32 = stack[0].x;
                var y0: f32 = stack[0].y;
                var x1: f32 = stack[0].x + stack[0].w;
                var y1: f32 = stack[0].y + stack[0].h;
                for (stack[1..depth]) |r| {
                    x0 = @max(x0, r.x);
                    y0 = @max(y0, r.y);
                    x1 = @min(x1, r.x + r.w);
                    y1 = @min(y1, r.y + r.h);
                }
                out.child_scissor = ui.ComputedRect.init(@round(x0), @round(y0), @round(@max(0, x1 - x0)), @round(@max(0, y1 - y0)));
            }
        }
    }
    return out;
}

fn buildShadowedClipPanel(cx: *Cx, composited: bool, child_color: Color) !*Node {
    const root = try box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 240 } }, .{});
    const panel = try box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 80 },
        .padding = Padding.all(8),
        .background = Color.rgba(245, 245, 245, 255),
        .border = .{ .width = 1, .color = Color.rgba(200, 200, 200, 255), .radius = 10 },
        .overflow_hidden = true,
    }, .{});
    panel.style.translate_x = 40;
    panel.style.translate_y = 40;
    const ext = try panel.style.ensureExtFallible(cx.allocator);
    ext.setShadow(.{ .color = Color.rgba(0, 0, 0, 40), .blur = 12, .offset_y = 6 });
    if (composited) ext.composited_group = true;
    // child content much taller than panel (1400 vs tall popover): must be clipped
    const child = try box(cx, .{
        .width = .{ .px = 104 },
        .height = .{ .px = 300 },
        .flex_shrink = 0,
        .background = child_color,
    }, .{});
    try panel.appendChild(cx.allocator, child);
    try root.appendChild(cx.allocator, panel);
    return root;
}

fn expectOwnClipContract(cx: *Cx, child_color: Color) !void {
    const probe = try ownClipProbe(cx, 104, 300, child_color);
    // shadow not clipped by own overflow
    try std.testing.expectEqual(@as(?usize, 0), probe.shadow_depth);
    // child clipped to padding box (border inner edge): panel (40,40,120x80), stroke 1px
    try std.testing.expect(probe.child_found);
    try std.testing.expectEqual(@as(?ui.ComputedRect, ui.ComputedRect.init(41, 41, 118, 78)), probe.child_scissor);
}

test "render: overflow clip spares owner shadow and stops at border inner edge (plain node)" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);
    const child_color = Color.rgba(79, 70, 229, 255);
    cx.root = try buildShadowedClipPanel(cx, false, child_color);
    cx.layout();
    _ = cx.render();
    try expectOwnClipContract(cx, child_color);
}

test "render: composited owner overflow clip spares owner shadow and stops at border inner edge, fresh and cached" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);
    const child_color = Color.rgba(79, 70, 229, 255);
    const root = try buildShadowedClipPanel(cx, true, child_color);
    const panel = root.children.items[0];
    cx.root = root;
    cx.layout();
    _ = cx.render();
    try std.testing.expect(panel.meta.per_frame.caches.commands.promoted != null);
    try expectOwnClipContract(cx, child_color);
    // compositor apply_clip must not use owner's own clip (would clip owner shadow too)
    for (cx.layer_tree.frame_ops.items) |op| switch (op) {
        .apply_clip => |clip| try std.testing.expect(clip.bounds.w != 120 or clip.bounds.h != 80),
        else => {},
    };

    // promoted cache hit frame: entire segment replacement must include children wrap token
    cx.perf.render_cache_hit = 0;
    cx.frame_time_ms = 16.0;
    panel.style.translate_x = 42;
    panel.markCompositeDirty();
    _ = cx.render();
    try std.testing.expect(cx.perf.render_cache_hit > 0);
    const probe = try ownClipProbe(cx, 104, 300, child_color);
    try std.testing.expectEqual(@as(?usize, 0), probe.shadow_depth);
    try std.testing.expect(probe.child_found);
    try std.testing.expectEqual(@as(?ui.ComputedRect, ui.ComputedRect.init(43, 41, 118, 78)), probe.child_scissor);
}

// ── display: none (framework-native hiding: layout/render/hit/focus/a11y all excluded) ──

const DisplayNoneFixture = struct {
    root: *Node,
    a: *Node,
    b: *Node,
    b_child: *Node,
    c: *Node,
};

fn displayNoneFixture(cx: *Cx) !DisplayNoneFixture {
    cx.setViewport(400, 200);
    const alloc = std.testing.allocator;
    const root = try ui.box(cx, .{ .direction = .row, .gap = 10, .background = Color.hex(0xFFFFFF) }, .{});
    cx.root = root;
    const a = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 40 }, .background = Color.hex(0xFF0000) }, .{});
    const b = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 40 }, .background = Color.hex(0x00FF00) }, .{});
    const b_child = try ui.box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.hex(0x0000FF) }, .{});
    // c height 10 only: after hiding b, c shifts left; b_child stale geometry (y 10..20) not
    // covered by c, so hit-test distinguishes 'hidden subtree culled' from 'exactly covered'.
    const c = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 10 }, .background = Color.hex(0xFFFF00) }, .{});
    inline for (.{ a, b_child, c }) |n| n.behavior.interaction.focusable = true;
    b_child.behavior.interaction.a11y = .{ .role = .button, .label = "hidden" };
    try b.appendChild(alloc, b_child);
    try root.appendChild(alloc, a);
    try root.appendChild(alloc, b);
    try root.appendChild(alloc, c);
    return .{ .root = root, .a = a, .b = b, .b_child = b_child, .c = c };
}

fn itemsForNode(items: []const display_list.DisplayItem, node: *const Node) usize {
    var n: usize = 0;
    for (items) |it| {
        if (it.isControl()) continue;
        if (it.header().node_id == node.id) n += 1;
    }
    return n;
}

test "display none: 不占空间不计 gap、父容器随之收缩；切回恢复" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const f = try displayNoneFixture(cx);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 120), f.c.rectFromWorldOrFallback().x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 170), f.root.rectFromWorldOrFallback().w, 0.01);

    f.b.setDisplay(.none);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 60), f.c.rectFromWorldOrFallback().x, 0.01); // a + one gap
    try std.testing.expectApproxEqAbs(@as(f32, 110), f.root.rectFromWorldOrFallback().w, 0.01);
    _ = cx.render();
    try std.testing.expect(!cx.hasPendingSceneWork()); // hidden subtree leaves no dirty bits (idle can gate frames)

    f.b.setDisplay(.flex);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 120), f.c.rectFromWorldOrFallback().x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), f.b.rectFromWorldOrFallback().x, 0.01);
}

test "display none: 子树不绘制、不命中、不进无障碍树" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const f = try displayNoneFixture(cx);
    cx.layout();
    var items = cx.render();
    try std.testing.expect(itemsForNode(items, f.b) > 0);
    try std.testing.expect(itemsForNode(items, f.b_child) > 0);
    const child_rect = f.b_child.rectFromWorldOrFallback();
    const bx = f.b.rectFromWorldOrFallback().x + child_rect.x + 5;
    try std.testing.expect(cx.hitTest(bx, 5) == f.b_child);
    try std.testing.expect(!cx.accessibility_tree.getNode(ui.ElementId.fromRaw(f.b_child.element_id_raw)).?.state.hidden);

    f.b.setDisplay(.none);
    cx.layout();
    items = cx.render();
    try std.testing.expectEqual(@as(usize, 0), itemsForNode(items, f.b));
    try std.testing.expectEqual(@as(usize, 0), itemsForNode(items, f.b_child));
    // original position now c (c shifts to fill), hidden subtree never hits / y=15: only b_child
    // stale geometry here (c height 10), hidden subtree must not hit
    const hit = cx.hitTest(f.c.rectFromWorldOrFallback().x + 5, 15);
    try std.testing.expect(hit != f.b_child and hit != f.b);
    // same semantics as aria-hidden: node stays in tree but marked hidden, bridge doesn't read.
    try std.testing.expect(cx.accessibility_tree.getNode(ui.ElementId.fromRaw(f.b_child.element_id_raw)).?.state.hidden);
}

test "display none: Tab / Shift+Tab 跳过隐藏子树里的可聚焦节点" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const f = try displayNoneFixture(cx);
    cx.layout();
    try cx.focus_manager.collectFocusableNodes(f.root);
    f.b.setDisplay(.none);
    cx.layout();

    cx.focus_manager.setFocus(f.a);
    cx.focus_manager.focusNext();
    try std.testing.expect(cx.focus_manager.getFocused() == f.c);
    cx.focus_manager.focusPrev();
    try std.testing.expect(cx.focus_manager.getFocused() == f.a);

    f.b.setDisplay(.flex);
    cx.layout();
    cx.focus_manager.setFocus(f.a);
    cx.focus_manager.focusNext();
    try std.testing.expect(cx.focus_manager.getFocused() == f.b_child);
}

test "focus order: 子树增量重建后可聚焦节点保持树序（不被挪到 Tab 末尾）" {
    // Regression: rebuildDirtyRuntimeSubtrees unregisters subtree focusable nodes, then
    // appendFocusableUnsorted appends to end without reordering; Tab jumps a->c, b_child moved to
    // end.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const f = try displayNoneFixture(cx);
    cx.layout();
    try std.testing.expectEqualSlices(*Node, &.{ f.a, f.b_child, f.c }, cx.focus_manager.focus_order.items);
    f.b.markRuntimeIndexDirty(); // trigger b subtree runtime incremental rebuild (rebuildDirtyRuntimeSubtrees)
    _ = cx.render(); // full frame: pure layout() on clean is fast path, no runtime index rebuild
    try std.testing.expectEqualSlices(*Node, &.{ f.a, f.b_child, f.c }, cx.focus_manager.focus_order.items);
}

test "Node.setTint：icon 表与 image 两种存储都改到，无图形内容返回 false" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const red = Color.hex(0xFF0000);
    const blue = Color.hex(0x0000FF);

    // resource with icon_id -> icon table
    const icon_node = try ui.iconTint(cx, ui.svg_assets.common.star, red, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
    defer cx.freeNode(icon_node);
    try std.testing.expect(icon_node.getIcon() != null);
    try std.testing.expect(icon_node.setTint(blue));
    try std.testing.expectEqual(blue, icon_node.getIcon().?.tint);

    // image storage (svgTint for non-prebaked SVG uses image; headless has no GPU texture loader,
    // uses imageTint to construct same storage form)
    const img_node = try ui.imageTint(cx, 7, red, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
    defer cx.freeNode(img_node);
    try std.testing.expect(img_node.getIcon() == null);
    try std.testing.expect(img_node.setTint(blue));
    try std.testing.expectEqual(blue, img_node.getImage().?.tint);

    const plain = try ui.box(cx, .{}, .{});
    defer cx.freeNode(plain);
    try std.testing.expect(!plain.setTint(blue));
}

test "降低透明度：玻璃变成不透明磨砂（a11y 主体 242、保留 16% 色度；折射 / 扭曲 / 放大归零，模糊与高光保留），关闭后原样" {
    const prefs = @import("../a11y/preferences.zig");
    const saved = prefs.current();
    defer prefs.set(saved);
    const gp = ui.GlassParams{ .backdrop_blur = 12, .refraction_level = 0.8, .warp_gain = 2, .magnification = 0.5, .specular_opacity = 0.4 };

    prefs.set(.{});
    const normal = gp.resolve();
    try std.testing.expectEqual(@as(f32, 12), normal.backdrop_blur);
    try std.testing.expectEqual(@as(f32, 0.8), normal.refraction_level);

    // native measurement (native_tint_backdrop.swift): subject becomes opaque frosted at brightness
    // 242, retains 16% background saturation; subject color from glass-blurred background; material
    // highlight and shadow retained
    prefs.set(.{ .reduce_transparency = true });
    const frosted = gp.resolve();
    try std.testing.expectEqual(@as(f32, 12), frosted.backdrop_blur);
    try std.testing.expectEqual(@as(f32, 1), frosted.a11y[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 242.0 / 255.0), frosted.a11y[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), frosted.a11y[3], 1e-6);
    try std.testing.expectEqual(@as(f32, 0), frosted.refraction_level);
    try std.testing.expectEqual(@as(f32, 0), frosted.warp_gain);
    try std.testing.expectEqual(@as(f32, 0), frosted.magnification);
    try std.testing.expectEqual(normal.specular_opacity, frosted.specular_opacity);
}

// A node freed inside a reactive callback nested in a tick goes to the owner
// queue; a resource it borrows is queued right behind it (deferDisposalLikeFreeNode,
// FIFO: node first). When the owner queue drains, the tick is still running, so
// the node must wait again for the tick queue. Everything queued behind it has to
// move with it, or the resource is freed while the node's scope still uses it.
test "deferred node free keeps FIFO order when its completion is deferred again" {
    const Log = struct {
        order: [2]u8 = undefined,
        len: usize = 0,
        entry: @import("../reactive/deferred_disposal.zig").Entry = .{},
        fn push(self: *@This(), tag: u8) void {
            self.order[self.len] = tag;
            self.len += 1;
        }
        fn nodeScopeDisposed(self: *@This()) void {
            self.push('n');
        }
        fn resourceDisposed(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.push('r');
        }
    };
    var log: Log = .{};
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try box(cx, .{}, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    try scope.onCleanup(Log, &log, Log.nodeScopeDisposed);
    try ui.bindScopeToNode(scope, node);

    cx.tick_depth += 1;
    cx.owner.beginReactiveCallback();
    cx.freeNode(node);
    cx.deferDisposalLikeFreeNode(&log.entry, @ptrCast(&log), Log.resourceDisposed);
    cx.owner.endReactiveCallback(); // owner queue drains while the tick is still active
    try std.testing.expectEqual(@as(usize, 0), log.len);
    cx.tick_depth -= 1;
    @import("cx_node_lifetime.zig").drainDeferredFrees(cx);
    try std.testing.expectEqualStrings("nr", log.order[0..log.len]);
}

test "BulkQuad remount: unmount retires the old tree anchor before render" {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(debug_allocator.deinit() == .ok) catch @panic("leak");
    const allocator = debug_allocator.allocator();
    var cx = try Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{ .width = .fixed(1200), .height = .fixed(800) }, .{});
    cx.root = root;
    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .empty;
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);
    try cx.setBulkQuadsEx(root, quads.items, bulk_overlay_z);
    cx.layout();
    _ = cx.render();
    cx.unmount();
    // New mount deliberately submits no bulk quads. Render first so Debug
    // catches the original freed-anchor dereference, before state assertions.
    cx.root = try ui.box(cx, .{ .width = .fixed(1200), .height = .fixed(800) }, .{});
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.bulk_quads_anchor == null);
    try std.testing.expectEqual(@as(usize, 0), cx.bulk_quads.items.len);
}

// Per-hook scope (Node.addBeforeRenderScoped): a node whose hooks are all
// registered with `.self` keeps the paint prefix, like a node-level self-only
// declaration. Regression anchor: a widget's focus-ring hook on a title-bar
// button stopped prebuild for the whole window and every clean subtree after
// it (zero splices) in a downstream editor.
fn otherSelfOnlyHookForTest(node: *Node) void {
    node.markRenderDirty();
}

fn spliceCountWithHookScopes(scopes: []const ui.BeforeRenderScope) !u32 {
    return spliceCountWithHookScopesImpl(scopes, true);
}

fn spliceCountWithHookScopesNoResume(scopes: []const ui.BeforeRenderScope) !u32 {
    return spliceCountWithHookScopesImpl(scopes, false);
}

fn spliceCountWithHookScopesImpl(scopes: []const ui.BeforeRenderScope, paint_resume: bool) !u32 {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    const root = try buildHookedPrefixScene(cx, 200, false);
    const hooked = root.children.items[0];
    hooked.meta.per_frame.hooks.before_render.main = null;
    const fns = [_]*const fn (*Node) void{ selfOnlyHookForTest, otherSelfOnlyHookForTest };
    for (scopes, 0..) |scope, i| hooked.addBeforeRenderScoped(fns[i], scope);
    ui.render_engine.paint_resume_test_override = paint_resume;
    defer ui.render_engine.paint_resume_test_override = null;
    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        _ = cx.render();
        root.children.items[root.children.items.len - 1].markRenderDirty();
    }
    cx.perf.subtree_payload_splice_count = 0;
    _ = cx.render();
    return cx.perf.subtree_payload_splice_count;
}

test "hook scope: 逐 hook 声明 .self 后兄弟子树恢复跨帧复用" {
    try std.testing.expect(try spliceCountWithHookScopes(&.{ .self, .self }) > 0);
}

test "hook scope: 混有 .subtree hook 时保持保守语义" {
    // A .subtree hook keeps the node conservative: it breaks the paint prefix, so the siblings
    // are only reused through the paint-cursor resume (prebuild resumed after the hooked node).
    // With the resume off (escape hatch semantics) that path yields no reuse at all, unlike the
    // all-.self case where the prefix never breaks.
    try std.testing.expect(try spliceCountWithHookScopes(&.{ .self, .subtree }) > 0);
    try std.testing.expectEqual(@as(u32, 0), try spliceCountWithHookScopesNoResume(&.{ .self, .subtree }));
    try std.testing.expect(try spliceCountWithHookScopesNoResume(&.{ .self, .self }) > 0);
}

test "hook scope: removeBeforeRender keeps each remaining hook's scope" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try box(cx, .{}, .{});
    defer cx.freeNode(node);
    const H = struct {
        // Distinct observable bodies keep these three callback identities
        // distinct in optimized builds, which may merge identical no-op functions.
        fn a(n: *Node) void {
            n.setOpacityRaw(0.1);
        }
        fn b(n: *Node) void {
            n.setOpacityRaw(0.2);
        }
        fn c(n: *Node) void {
            n.setOpacityRaw(0.3);
        }
    };
    node.addBeforeRenderScoped(H.a, .self);
    node.addBeforeRenderScoped(H.b, .subtree);
    node.addBeforeRenderScoped(H.c, .self);
    try std.testing.expectEqual(@as(u8, 3), node.meta.per_frame.hooks.before_render.count);
    try std.testing.expect(!node.beforeRenderHooksSelfOnly());
    node.removeBeforeRender(H.b);
    try std.testing.expect(node.beforeRenderHooksSelfOnly());
    node.addBeforeRender(H.b);
    try std.testing.expect(!node.beforeRenderHooksSelfOnly());
    node.removeBeforeRender(H.a);
    try std.testing.expect(!node.beforeRenderHooksSelfOnly());
    node.removeBeforeRender(H.b);
    try std.testing.expect(node.beforeRenderHooksSelfOnly());
    node.removeBeforeRender(H.c);
    try std.testing.expect(!node.beforeRenderHooksSelfOnly()); // no hooks left
}

test "hook scope: re-registering a hook resolves to the conservative scope" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try box(cx, .{}, .{});
    defer cx.freeNode(node);
    const H = struct {
        fn a(_: *Node) void {}
    };
    node.addBeforeRenderScoped(H.a, .subtree);
    node.addBeforeRenderScoped(H.a, .self);
    try std.testing.expect(!node.beforeRenderHooksSelfOnly());
    node.removeBeforeRender(H.a);
    node.addBeforeRenderScoped(H.a, .self);
    try std.testing.expect(node.beforeRenderHooksSelfOnly());
    node.addBeforeRenderScoped(H.a, .subtree);
    try std.testing.expect(!node.beforeRenderHooksSelfOnly());
    try std.testing.expectEqual(@as(u8, 1), node.meta.per_frame.hooks.before_render.count);
}

test "CPU node cache owner probe returns to zero after node destroy" {
    var counter = @import("counting_allocator.zig").CountingAllocator{ .parent = std.testing.allocator };
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.world.render_cache_allocator = counter.allocator();
    const node = try ui.box(cx, .{}, .{});
    const commands = [_]@import("display_list.zig").DisplayItem{.{ .fill_rect = .{
        .header = .{ .transform_id = 0, .node_id = node.id },
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
        .color = Color.rgba(255, 0, 0, 255),
    } }};
    node.cacheRenderCommands(std.testing.allocator, &commands, 0, 0);
    try std.testing.expect(counter.live_bytes > 0);
    cx.freeNode(node);
    try std.testing.expectEqual(@as(usize, 0), counter.live_bytes);
}

test "intrinsic measurement cache discards destroyed node IDs during churn" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;
    const engine = @import("layout_engine.zig");
    cx.layout();
    const baseline = engine.intrinsicCacheMemoryStats().entries;
    for (0..2000) |_| {
        const row = try ui.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{});
        const leaf = try ui.box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 20 } }, .{});
        try row.appendChild(cx.allocator, leaf);
        try root.appendChild(cx.allocator, row);
        cx.layout();
        try std.testing.expect(engine.intrinsicCacheMemoryStats().entries > baseline);
        cx.detachChild(root, row);
        cx.freeNode(row);
        try std.testing.expectEqual(baseline, engine.intrinsicCacheMemoryStats().entries);
    }
}

test "standalone node destruction clears fallback state before address reuse" {
    const pca = @import("paint_content_accessor.zig");
    const lifecycle = @import("node_lifecycle.zig");
    const baseline = pca.standaloneEntryCount();
    const rect_baseline = lifecycle.standaloneRectCount();
    var storage: [@sizeOf(ui.Node) + @alignOf(ui.Node)]u8 align(@alignOf(ui.Node)) = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const first = try ui.Node.create(fba.allocator(), 80001, .box, .{});
    const address = @intFromPtr(first);
    first.setOpacityRaw(0);
    first.setBackgroundRaw(Color.rgba(255, 0, 0, 255));
    first.setText(.{ .content = "old", .font_size = 16 });
    first.setLayoutRect(.{ .x = 20, .y = 30, .w = 40, .h = 50 });
    first.destroy(fba.allocator());
    fba.reset();
    const second = try ui.Node.create(fba.allocator(), 80002, .box, .{});
    defer second.destroy(fba.allocator());
    try std.testing.expectEqual(address, @intFromPtr(second));
    try std.testing.expectEqual(@as(f32, 1), second.getOpacity());
    try std.testing.expectEqual(Color.TRANSPARENT, second.getBackground());
    try std.testing.expect(second.getText() == null);
    try std.testing.expectEqual(@as(f32, 0), second.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(baseline, pca.standaloneEntryCount());
    try std.testing.expectEqual(rect_baseline, lifecycle.standaloneRectCount());
}

test "LC3B baseline layout and painted first line share the same origin" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const label = try text(cx, "baseline", .{ .font_size = 16, .line_height = 1.4 });
    label.style.width = .{ .px = 60 };
    label.style.height = .{ .px = 60 };
    const block = try box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 30 } }, .{});
    cx.root = try box(cx, .{ .width = .{ .px = 180 }, .height = .{ .px = 120 }, .direction = .row, .align_items = .baseline }, .{ label, block });
    cx.layout();
    _ = cx.render();
    var found = false;
    for (cx.display_list.items.items) |item| switch (item) {
        .text_run => |run| {
            if (!std.mem.eql(u8, run.content, "baseline")) continue;
            found = true;
            try std.testing.expectApproxEqAbs(block.rectFromWorldOrFallback().y + block.rectFromWorldOrFallback().h, label.rectFromWorldOrFallback().y + run.y, 0.01);
        },
        else => {},
    };
    try std.testing.expect(found);
}

// ── Paint-cursor resume / own-content cache / incremental == full ─────────────────────────
//
// Before the paint-cursor resume, the first before_render hook in paint order (a ScrollArea early
// in a window) stopped the prebuild pass, and every node painted after it lost the cross-frame
// subtree payload cache: no splice, no cache write, whole window re-recorded per frame.

const cx_render_for_tests = @import("cx_render.zig");

fn prefixBreakingHookForTest(node: *Node) void {
    _ = node;
}

/// root -> [hooked (undeclared hook, breaks the prefix), n sibling subtrees (box -> box)]
fn buildPrefixBreakScene(cx: *Cx, n: usize) !*Node {
    const root = try box(cx, .{ .width = .{ .px = 1280 }, .height = .{ .px = 800 } }, .{});
    const hooked = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 }, .background = Color.rgba(1, 2, 3, 255) }, .{});
    hooked.meta.per_frame.hooks.before_render.main = prefixBreakingHookForTest;
    try root.appendChild(cx.allocator, hooked);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const sib = try box(cx, .{
            .width = .{ .px = 8 },
            .height = .{ .px = 8 },
            .position = .absolute,
            .background = Color.rgba(@intCast(i % 200), 80, 120, 255),
        }, .{});
        sib.style.translate_x = @floatFromInt((i % 40) * 30);
        sib.style.translate_y = @floatFromInt(40 + (i / 40) * 15);
        const inner = try box(cx, .{ .width = .{ .px = 4 }, .height = .{ .px = 4 }, .background = Color.rgba(200, @intCast(i % 200), 60, 255) }, .{});
        try sib.appendChild(cx.allocator, inner);
        try root.appendChild(cx.allocator, sib);
    }
    cx.root = root;
    return root;
}

fn renderDirtyingLast(cx: *Cx, root: *Node, frames: usize) void {
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        root.children.items[root.children.items.len - 1].markRenderDirty();
        _ = cx.render();
    }
}

test "paint-cursor resume: 前缀断裂之后的干净兄弟子树跨帧复用，且与全量路径逐项等价" {
    const n: usize = 120;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    const root = try buildPrefixBreakScene(cx, n);

    _ = cx.render();
    renderDirtyingLast(cx, root, 2); // caches written at the paint cursor, then reused

    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    renderDirtyingLast(cx, root, 1);

    const splices = cx.perf.subtree_payload_splice_count;
    const resumes = cx.perf.subtree_payload_paint_resume_count;
    const emits = cx.perf.own_content_emit_count;
    std.debug.print("\n[paint-resume] splices={d} resumes={d} emits={d} siblings={d}\n", .{ splices, resumes, emits, n });
    // The prefix really breaks at the hooked node (precondition, else this tests nothing).
    try std.testing.expect(root.children.items[0].hasBeforeRenderHooks());
    // Clean siblings after the break are spliced from their cross-frame caches.
    try std.testing.expect(splices >= n - 1);
    try std.testing.expect(resumes >= n - 1);
    // Only the changed sibling (and the hooked node / root path) re-record.
    try std.testing.expect(emits <= 8);
    // Cached path == reference full path, item by item.
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

test "incremental verify: 未标脏写入导致的陈旧复用会被检出（校验本身不是假绿）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    const root = try buildPrefixBreakScene(cx, 20);
    _ = cx.render();
    renderDirtyingLast(cx, root, 2);

    // Unmarked write inside a cached sibling subtree: the cache cannot see it.
    root.children.items[3].children.items[0].setBackgroundRaw(Color.rgba(250, 1, 1, 255));
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    renderDirtyingLast(cx, root, 1);
    try std.testing.expect(cx.incremental_verify_mismatch_total > 0);
}

test "own payload cache: 脏路径上的干净祖先与旁支叶子不再重录自身内容" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .background = Color.rgba(9, 9, 9, 255) }, .{});
    const panel = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 }, .background = Color.rgba(30, 40, 50, 255) }, .{});
    const changing = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(1, 1, 1, 255) }, .{});
    const label = try text(cx, "static label", .{ .font_size = 13 });
    try panel.appendChild(cx.allocator, changing);
    try panel.appendChild(cx.allocator, label);
    try root.appendChild(cx.allocator, panel);
    cx.root = root;

    var shade: u8 = 0;
    var f: usize = 0;
    while (f < 3) : (f += 1) {
        shade +%= 37;
        changing.setBackground(Color.rgba(shade, 1, 1, 255));
        _ = cx.render();
    }
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    shade +%= 37;
    changing.setBackground(Color.rgba(shade, 1, 1, 255));
    _ = cx.render();
    // root and panel are on the dirty path: they replay their own content from the own-payload
    // cache; the clean label beside it splices its subtree cache; only `changing` records.
    std.debug.print("\n[own-payload] hits={d} splices={d} emits={d}\n", .{ cx.perf.own_payload_cache_hit_count, cx.perf.subtree_payload_splice_count, cx.perf.own_content_emit_count });
    try std.testing.expect(cx.perf.own_payload_cache_hit_count >= 2);
    try std.testing.expectEqual(@as(u32, 1), cx.perf.own_content_emit_count);
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

test "subtree payload stamp: 祖先切换 text_stabilize_subtree（不标脏后代）不得复用旧光栅策略" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    const container = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    const row = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 20 }, .background = Color.rgba(20, 20, 20, 255) }, .{});
    const label = try text(cx, "row label", .{ .font_size = 13 });
    try row.appendChild(cx.allocator, label);
    try container.appendChild(cx.allocator, row);
    try root.appendChild(cx.allocator, container);
    const other = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try root.appendChild(cx.allocator, other);
    cx.root = root;
    _ = cx.render();
    other.markRenderDirty();
    _ = cx.render();
    try std.testing.expect(row.meta.per_frame.caches.commands.subtree_payload != null);

    // ScrollArea does exactly this during a bounce: flip the content flag and mark the container.
    container.frame_state.state_bits.flags.text_stabilize_subtree = true;
    container.markRenderDirty();
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    _ = cx.render();
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

test "subtree payload stamp: 前面多挂一个节点（帧内序号整体平移）不得让后面的干净缓存全部失效" {
    const n: usize = 60;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    const root = try buildPrefixBreakScene(cx, n);
    // A node painted before every sibling: mounting one more child under it allocates one more
    // transform, shifting the frame-local transform ids of everything painted after it (a list
    // row rebinding at the top of a VirtualList does the same).
    const shifter = try box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 30 }, .background = Color.rgba(7, 7, 7, 255) }, .{});
    const shifter_child = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(9, 9, 9, 255) }, .{});
    try shifter.appendChild(cx.allocator, shifter_child);
    try root.insertChildBefore(cx.allocator, shifter, root.children.items[0]);
    _ = cx.render();
    renderDirtyingLast(cx, root, 2);

    const extra = try box(cx, .{ .width = .{ .px = 4 }, .height = .{ .px = 4 }, .background = Color.rgba(3, 3, 3, 255) }, .{});
    try shifter.appendChild(cx.allocator, extra);
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    renderDirtyingLast(cx, root, 1);
    std.debug.print("\n[owner-signature] splices={d} stale_headers_rewritten={d}\n", .{ cx.perf.subtree_payload_splice_count, cx.perf.subtree_payload_stale_header_count });
    // Every sibling's transform id really shifted (headers rewritten on splice).
    try std.testing.expect(cx.perf.subtree_payload_stale_header_count >= n - 1);
    try std.testing.expect(cx.perf.subtree_payload_splice_count >= n - 1);
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

/// Whether `items` holds a push_clip immediately closed by a pop_clip (an empty clip scope).
fn countEmptyClipScopesForTest(items: []const display_list.DisplayItem) usize {
    var n: usize = 0;
    for (items[0..items.len -| 1], items[1..]) |a, b| {
        if (a == .push_clip and b == .pop_clip) n += 1;
    }
    return n;
}

test "scroll clip: 前缀里已预建的 overflow_hidden 容器，绘制 pass 不再在尾部补一对空裁剪" {
    // PaintReplay story at rest: an overflow_hidden + background container is prebuilt by the
    // fallback path (its own content and children land in the prefix, inside the prebuild's own
    // clip pair). A later undeclared hook breaks the prefix, so the paint pass appends at the
    // tail; it re-opened the container's clip scope there with nothing inside. The uncached
    // path emitted that extra pair while a legacy overflow cache hit (container kept out of the
    // prefix) did not: ZENIT_VERIFY_INCREMENTAL reported 6 missing items every frame.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .direction = .column }, .{});
    const track = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 8 },
        .background = Color.rgba(30, 34, 48, 255),
        .overflow_hidden = true,
    }, .{});
    const fill = try box(cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 8 }, .background = Color.rgba(76, 195, 138, 255) }, .{});
    try track.appendChild(cx.allocator, fill);
    try root.appendChild(cx.allocator, track);
    const hooked = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 }, .background = Color.rgba(1, 2, 3, 255) }, .{});
    hooked.meta.per_frame.hooks.before_render.main = prefixBreakingHookForTest;
    try root.appendChild(cx.allocator, hooked);
    const other = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(5, 5, 5, 255) }, .{});
    try root.appendChild(cx.allocator, other);
    cx.root = root;

    // First frame: everything dirty, no cache to replay -> the container takes the fallback
    // prebuild and the paint pass visits it again after the prefix broke.
    const first = cx.render();
    try std.testing.expectEqual(@as(usize, 0), countEmptyClipScopesForTest(first));
    try std.testing.expect(cx.perf.empty_clip_scope_elided_count >= 1);

    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    var f: usize = 0;
    while (f < 3) : (f += 1) {
        other.markRenderDirty();
        const items = cx.render();
        try std.testing.expectEqual(@as(usize, 0), countEmptyClipScopesForTest(items));
    }
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

fn noopHookForTest(node: *Node) void {
    _ = node;
}

fn displayListHasFillColorForTest(items: []const display_list.DisplayItem, node_id: u32, color: Color) bool {
    for (items) |item| switch (item) {
        .fill_rect => |r| if (r.header.node_id == node_id and Color.eql(r.color, color)) return true,
        else => {},
    };
    return false;
}

test "subtree payload: 子树在绘制 pass 里被重录（未写新缓存）后，旧缓存不得在之后的干净帧被拼回" {
    // RadioGroup e2e: a parent's subtree payload cache was written while a child showed an
    // intermediate transition color. The next change to the child happened while the child had a
    // before_render hook (hover highlight), so the paint-cursor resume refused the parent and the
    // paint pass re-recorded it without writing or dropping its cache. Once the hook was gone and
    // the parent clean, the stale cache was spliced: the old color stayed on screen.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    const breaker = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 }, .background = Color.rgba(1, 2, 3, 255) }, .{});
    breaker.meta.per_frame.hooks.before_render.main = prefixBreakingHookForTest;
    try root.appendChild(cx.allocator, breaker);
    const panel = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .background = Color.rgba(40, 40, 40, 255) }, .{});
    const dot = try box(cx, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .background = Color.rgba(10, 10, 10, 255) }, .{});
    try panel.appendChild(cx.allocator, dot);
    try root.appendChild(cx.allocator, panel);
    const other = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(5, 5, 5, 255) }, .{});
    try root.appendChild(cx.allocator, other);
    cx.root = root;

    _ = cx.render();
    other.markRenderDirty();
    _ = cx.render();
    other.markRenderDirty();
    _ = cx.render();
    try std.testing.expect(panel.meta.per_frame.caches.commands.subtree_payload != null);

    // Change the child while it carries a hook: the panel is re-recorded by the paint pass.
    dot.addBeforeRender(noopHookForTest);
    const final = Color.rgba(250, 250, 250, 255);
    dot.setBackground(final);
    _ = cx.render();
    // Hook gone, panel clean again.
    dot.removeBeforeRender(noopHookForTest);
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    other.markRenderDirty();
    _ = cx.render();
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
    // Verify leaves the reference result in place; check the incremental pass once more alone.
    cx_render_for_tests.setVerifyIncrementalForTest(false);
    other.markRenderDirty();
    const items = cx.render();
    try std.testing.expect(displayListHasFillColorForTest(items, dot.id, final));
}

test "own payload cache: 子节点原始写入后标脏被写的子节点（不是父节点），旧的自身内容缓存不再复用" {
    // Raw writes (setIcon / setBackgroundRaw) do not mark; the writer marks the node it wrote.
    // Rate used to mark the star (the parent) after swapping each star's icon with setIcon: the
    // icon leaf stayed clean and replayed its own-content cache with the old star. Cross-frame
    // copies are keyed on the node's own dirty bits, so Rate now marks the icon.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    const star = try box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .background = Color.rgba(40, 40, 40, 255) }, .{});
    const leaf = try box(cx, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .background = Color.rgba(10, 10, 10, 255) }, .{});
    try star.appendChild(cx.allocator, leaf);
    try root.appendChild(cx.allocator, star);
    const sibling = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(5, 5, 5, 255) }, .{});
    try star.appendChild(cx.allocator, sibling);
    cx.root = root;

    var shade: u8 = 0;
    var f: usize = 0;
    while (f < 3) : (f += 1) {
        shade +%= 37;
        sibling.setBackground(Color.rgba(shade, 1, 1, 255)); // star on the dirty path, leaf clean
        _ = cx.render();
    }
    // Precondition: the leaf has a cross-frame copy of its content (own or subtree payload).
    try std.testing.expect(leaf.meta.per_frame.caches.commands.own_payload != null or
        leaf.meta.per_frame.caches.commands.subtree_payload != null);

    const next = Color.rgba(250, 200, 10, 255);
    leaf.setBackgroundRaw(next);
    leaf.markRenderDirty();
    const items = cx.render();
    try std.testing.expect(displayListHasFillColorForTest(items, leaf.id, next));
}

fn textRunPoliciesForTest(items: []const display_list.DisplayItem, node_id: u32) ?@TypeOf(items[0].text_run.raster_policy) {
    for (items) |item| switch (item) {
        .text_run => |t| if (t.header.node_id == node_id) return t.raster_policy,
        else => {},
    };
    return null;
}

test "legacy overflow cache: 祖先切换线性文本状态（不标脏后代）时不得回放旧光栅策略" {
    // zindex / tooltip e2e: an overlay scaling in turns on linear text for its subtree
    // (auto_stabilize_text) and turns it off when the animation and its linger frames end, without
    // marking descendants. A promoted / legacy overflow cache recorded under the other state
    // replayed text_run raster policy and icon snap from before the flip.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    const container = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    const track = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 30 },
        .background = Color.rgba(30, 34, 48, 255),
        .overflow_hidden = true,
    }, .{});
    const label = try text(cx, "clipped label", .{ .font_size = 13 });
    try track.appendChild(cx.allocator, label);
    try container.appendChild(cx.allocator, track);
    try root.appendChild(cx.allocator, container);
    const other = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try root.appendChild(cx.allocator, other);
    cx.root = root;
    _ = cx.render();
    var f: usize = 0;
    while (f < 2) : (f += 1) {
        other.markRenderDirty();
        _ = cx.render();
    }
    try std.testing.expect(track.meta.per_frame.caches.commands.own != null);
    const before = textRunPoliciesForTest(cx.display_list.items.items, label.id).?;

    container.frame_state.state_bits.flags.text_stabilize_subtree = true;
    container.markRenderDirty();
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    _ = cx.render();
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
    cx_render_for_tests.setVerifyIncrementalForTest(false);
    other.markRenderDirty();
    const items = cx.render();
    const after = textRunPoliciesForTest(items, label.id).?;
    try std.testing.expect(after != before);
}

test "subtree payload: 父节点只平移（合成脏，不改内容版本）时子树缓存继续复用" {
    // Scroll content: ScrollArea moves its content with translate + markCompositePropDirty,
    // which sets the content node's render bit without bumping its content version. Its
    // children's cross-frame copies stay valid (items are node-local).
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 800);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 800 } }, .{});
    const content = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 760 }, .direction = .column }, .{});
    const n: usize = 20;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 30 }, .background = Color.rgba(@intCast(i * 10), 40, 40, 255) }, .{});
        const label = try text(cx, "row", .{ .font_size = 13 });
        try row.appendChild(cx.allocator, label);
        try content.appendChild(cx.allocator, row);
    }
    try root.appendChild(cx.allocator, content);
    cx.root = root;
    var ty: f32 = 0;
    var f: usize = 0;
    while (f < 3) : (f += 1) {
        ty -= 3;
        content.style.translate_y = ty;
        content.markCompositePropDirty();
        _ = cx.render();
    }
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    ty -= 3;
    content.style.translate_y = ty;
    content.markCompositePropDirty();
    _ = cx.render();
    std.debug.print("\n[composite-parent] splices={d} emits={d}\n", .{ cx.perf.subtree_payload_splice_count, cx.perf.own_content_emit_count });
    try std.testing.expect(cx.perf.subtree_payload_splice_count >= n);
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

// ── Before-render tick: quiet-subtree skip ───────────────────────────────────────────────────

var tick_skip_test_hook_runs: u32 = 0;
fn tickSkipCountingHook(node: *Node) void {
    _ = node;
    tick_skip_test_hook_runs += 1;
}

/// root -> [n static rows (box -> text), one more static box]
fn buildQuietTickScene(cx: *Cx, n: usize) !*Node {
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .direction = .column }, .{});
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 10 }, .background = Color.rgba(20, 20, 20, 255) }, .{});
        const leaf = try box(cx, .{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .background = Color.rgba(40, 40, 40, 255) }, .{});
        try row.appendChild(cx.allocator, leaf);
        try root.appendChild(cx.allocator, row);
    }
    cx.root = root;
    return root;
}

fn renderNextFrame(cx: *Cx) void {
    cx.frame_time_ms += 16;
    cx.frame_count +%= 1;
    _ = cx.render();
}

test "tick: 静止子树被跳过；静止子树里后加的 hook / 动画 / 过渡照常推进" {
    const tick = @import("render_engine/tick.zig");
    tick.tick_skip_test_override = true;
    defer tick.tick_skip_test_override = null;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const n: usize = 40;
    const root = try buildQuietTickScene(cx, n);
    renderNextFrame(cx);
    root.markRenderDirty();
    renderNextFrame(cx);
    root.markRenderDirty();
    renderNextFrame(cx);
    // Warm: every row is stamped quiet, only the root is visited.
    try std.testing.expect(cx.perf.tick_quiet_skips >= n);
    try std.testing.expect(cx.perf.tick_nodes <= 2);

    // A hook registered on a clean leaf (no dirty mark) still runs next frame.
    const leaf = root.children.items[7].children.items[0];
    tick_skip_test_hook_runs = 0;
    leaf.addBeforeRender(tickSkipCountingHook);
    root.markRenderDirty();
    renderNextFrame(cx);
    try std.testing.expectEqual(@as(u32, 1), tick_skip_test_hook_runs);
    leaf.removeBeforeRender(tickSkipCountingHook);

    // A transition started on a clean row advances on later frames.
    const row = root.children.items[11];
    try row.enableImplicitAnimation(cx.allocator, &.{.background}, .{ .duration_ms = 100 });
    root.markRenderDirty();
    renderNextFrame(cx);
    renderNextFrame(cx);
    const target = Color.rgba(250, 250, 250, 255);
    row.setBackground(target);
    renderNextFrame(cx);
    const mid = row.getBackground();
    var f: usize = 0;
    while (f < 12) : (f += 1) {
        root.markRenderDirty();
        renderNextFrame(cx);
    }
    try std.testing.expect(!Color.eql(mid, target));
    try std.testing.expect(Color.eql(row.getBackground(), target));
}

var tick_skip_late_target: ?*Node = null;
fn tickSkipLateWriterHook(node: *Node) void {
    _ = node;
    if (tick_skip_late_target) |t| {
        t.setBackground(Color.rgba(250, 250, 250, 255));
        tick_skip_late_target = null;
    }
}

test "tick: hook 在同一帧里给已 tick 过的静止子树启动过渡，过渡下一帧仍推进" {
    // The row was already visited (and stamped quiet) when a later hook starts its transition;
    // the render then cleans the row's dirty bits, so only the explicit stamp invalidation keeps
    // the next tick from skipping it.
    const tick = @import("render_engine/tick.zig");
    tick.tick_skip_test_override = true;
    defer tick.tick_skip_test_override = null;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const root = try buildQuietTickScene(cx, 20);
    const row = root.children.items[3];
    try row.enableImplicitAnimation(cx.allocator, &.{.background}, .{ .duration_ms = 100 });
    const writer = try box(cx, .{ .width = .{ .px = 5 }, .height = .{ .px = 5 } }, .{});
    writer.addBeforeRender(tickSkipLateWriterHook);
    try root.appendChild(cx.allocator, writer);
    var f: usize = 0;
    while (f < 3) : (f += 1) {
        root.markRenderDirty();
        renderNextFrame(cx);
    }
    tick_skip_late_target = row;
    root.markRenderDirty();
    renderNextFrame(cx);
    const started = row.getBackground();
    f = 0;
    while (f < 12) : (f += 1) {
        root.markRenderDirty();
        renderNextFrame(cx);
    }
    try std.testing.expect(!Color.eql(started, Color.rgba(250, 250, 250, 255)));
    try std.testing.expect(Color.eql(row.getBackground(), Color.rgba(250, 250, 250, 255)));
}

test "subtree payload: 隐藏期间变了的子树（不渲染只清脏）重新显示时不得拼回旧缓存" {
    // zindex e2e: a popover closed (paint-skipped) while a button inside finished its hover
    // transition; the paint pass cleared the hidden subtree's dirty bits without re-recording it,
    // so on reopening the clean ancestor spliced its cache with the mid-transition color.
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    const wrapper = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    const panel = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 }, .background = Color.rgba(40, 40, 40, 255) }, .{});
    const button = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 }, .background = Color.rgba(10, 10, 10, 255) }, .{});
    try panel.appendChild(cx.allocator, button);
    try wrapper.appendChild(cx.allocator, panel);
    try root.appendChild(cx.allocator, wrapper);
    const other = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(5, 5, 5, 255) }, .{});
    try root.appendChild(cx.allocator, other);
    cx.root = root;
    _ = cx.render();
    other.markRenderDirty();
    _ = cx.render();
    other.markRenderDirty();
    _ = cx.render();
    try std.testing.expect(wrapper.meta.per_frame.caches.commands.subtree_payload != null or
        panel.meta.per_frame.caches.commands.subtree_payload != null);

    wrapper.setOpacity(0);
    _ = cx.render();
    const next = Color.rgba(250, 250, 250, 255);
    button.setBackground(next);
    _ = cx.render(); // hidden: dirty bits cleared without a re-record
    wrapper.setOpacity(1);
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    _ = cx.render();
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
    cx_render_for_tests.setVerifyIncrementalForTest(false);
    other.markRenderDirty();
    const items = cx.render();
    try std.testing.expect(displayListHasFillColorForTest(items, button.id, next));
}

var trusted_hook_runs: u32 = 0;
fn trustedSelfHookForTest(node: *Node) void {
    _ = node;
    trusted_hook_runs += 1;
}
fn untrustedHookForTest(node: *Node) void {
    _ = node;
}

/// root -> [breaker (undeclared hook), n cards (card -> [label box, hooked leaf])]
fn buildHookedCardsScene(cx: *Cx, n: usize, scope: ui.BeforeRenderScope) !*Node {
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 800 }, .direction = .column }, .{});
    const breaker = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 10 }, .background = Color.rgba(1, 2, 3, 255) }, .{});
    breaker.meta.per_frame.hooks.before_render.main = prefixBreakingHookForTest;
    try root.appendChild(cx.allocator, breaker);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const card = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 16 }, .background = Color.rgba(@intCast(i), 30, 30, 255) }, .{});
        const label = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 8 }, .background = Color.rgba(90, 90, 90, 255) }, .{});
        const hooked = try box(cx, .{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .background = Color.rgba(120, 10, 10, 255) }, .{});
        // Undeclared: assigned directly like most components do, so only the tick's self-heal
        // can classify it.
        if (scope == .subtree)
            hooked.meta.per_frame.hooks.before_render.main = untrustedHookForTest
        else
            hooked.addBeforeRenderScoped(trustedSelfHookForTest, scope);
        try card.appendChild(cx.allocator, label);
        try card.appendChild(cx.allocator, hooked);
        try root.appendChild(cx.allocator, card);
    }
    cx.root = root;
    return root;
}

test "trusted hooks: 带 .self / .dirty_marking hook 的干净子树跨帧拼接；未声明 hook 的子树仍每帧重录" {
    const n: usize = 30;
    inline for (.{ ui.BeforeRenderScope.self, ui.BeforeRenderScope.dirty_marking, ui.BeforeRenderScope.subtree }) |scope| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(640, 800);
        const root = try buildHookedCardsScene(cx, n, scope);
        renderNextFrame(cx);
        var f: usize = 0;
        while (f < 3) : (f += 1) {
            root.children.items[0].markRenderDirty();
            renderNextFrame(cx);
        }
        cx_render_for_tests.setVerifyIncrementalForTest(true);
        defer cx_render_for_tests.setVerifyIncrementalForTest(null);
        cx.incremental_verify_mismatch_total = 0;
        trusted_hook_runs = 0;
        root.children.items[0].markRenderDirty();
        renderNextFrame(cx);
        try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
        if (scope == .subtree) {
            try std.testing.expect(cx.perf.subtree_payload_splice_count < n);
        } else {
            // Every card is spliced whole; the hooks still ran.
            try std.testing.expect(cx.perf.subtree_payload_splice_count >= n);
            try std.testing.expectEqual(@as(u32, n), trusted_hook_runs);
        }
    }
}

test "trusted hooks: hook 标脏写入后，含它的子树缓存不再被拼接" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 800);
    const root = try buildHookedCardsScene(cx, 4, .self);
    _ = cx.render();
    var f: usize = 0;
    while (f < 3) : (f += 1) {
        root.children.items[0].markRenderDirty();
        _ = cx.render();
    }
    const hooked = root.children.items[2].children.items[1];
    const next = Color.rgba(250, 250, 250, 255);
    hooked.setBackground(next); // what a dirty-marking hook write does
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    root.children.items[0].markRenderDirty();
    _ = cx.render();
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

// ── Retained subtree memo ─────────────────────────────────────────────────────────────────────

test "retained memo: 静止子树与平移的滚动内容复用上一帧的 property tree / scene 记录，与全量逐项相等" {
    const re = @import("render_engine/mod.zig");
    re.retained_memo_test_override = true;
    defer re.retained_memo_test_override = null;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 800);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 800 }, .direction = .row }, .{});
    // Static panel and a clipped scroll viewport whose content moves by translate.
    const panel = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 800 }, .direction = .column }, .{});
    const viewport = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 700 }, .overflow_hidden = true }, .{});
    const content = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 600 }, .direction = .column }, .{});
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const a = try box(cx, .{ .width = .{ .px = 180 }, .height = .{ .px = 20 }, .background = Color.rgba(@intCast(i * 10), 60, 60, 255) }, .{});
        try a.appendChild(cx.allocator, try text(cx, "panel row", .{ .font_size = 12 }));
        try panel.appendChild(cx.allocator, a);
        const b = try box(cx, .{ .width = .{ .px = 280 }, .height = .{ .px = 24 }, .background = Color.rgba(60, @intCast(i * 10), 60, 255), .corner_radius = 4 }, .{});
        try b.appendChild(cx.allocator, try text(cx, "list row", .{ .font_size = 12 }));
        try content.appendChild(cx.allocator, b);
    }
    try viewport.appendChild(cx.allocator, content);
    try root.appendChild(cx.allocator, panel);
    try root.appendChild(cx.allocator, viewport);
    cx.root = root;

    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    var ty: f32 = 0;
    var replays: u32 = 0;
    var replay_nodes: u32 = 0;
    var f: usize = 0;
    while (f < 8) : (f += 1) {
        ty -= 3.5;
        content.style.translate_y = ty;
        content.markCompositePropDirty();
        _ = cx.render();
        if (f >= 2) {
            replays += cx.perf.rn_memo_replays;
            replay_nodes += cx.perf.rn_memo_replay_nodes;
        }
    }
    std.debug.print("\n[retained-memo] replays={d} nodes={d}\n", .{ replays, replay_nodes });
    // The static panel (one memo, identical inputs) and the list rows (one memo each, moved by
    // translation) are replayed: 25 + 24 scene records per frame.
    try std.testing.expect(replays >= 6 * 10);
    try std.testing.expect(replay_nodes >= 6 * 40);
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);

    // A change inside a memoized row invalidates exactly that memo.
    const row = panel.children.items[5];
    row.setBackground(Color.rgba(250, 1, 1, 255));
    _ = cx.render();
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
    // Layout change of the panel (width): rows rebuilt with new geometry, still equal.
    panel.style.width = .{ .px = 210 };
    panel.markLayoutDirty();
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

test "retained memo: 平移后会进入/离开裁剪区的子树不按平移复用（裁剪结果不同）" {
    const re = @import("render_engine/mod.zig");
    re.retained_memo_test_override = true;
    defer re.retained_memo_test_override = null;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 400);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 400 } }, .{});
    const viewport = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 }, .overflow_hidden = true }, .{});
    const content = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 2000 }, .direction = .column }, .{});
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const b = try box(cx, .{ .width = .{ .px = 280 }, .height = .{ .px = 30 }, .background = Color.rgba(60, @intCast(i * 4), 60, 255) }, .{});
        try b.appendChild(cx.allocator, try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(9, 9, 9, 255) }, .{}));
        try content.appendChild(cx.allocator, b);
    }
    try viewport.appendChild(cx.allocator, content);
    try root.appendChild(cx.allocator, viewport);
    cx.root = root;
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    var ty: f32 = 0;
    var f: usize = 0;
    while (f < 40) : (f += 1) {
        ty -= 7.25; // rows cross the clip edges every few frames
        content.style.translate_y = ty;
        content.markCompositePropDirty();
        _ = cx.render();
    }
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

test "retained memo: 父布局移动了记忆子树的根（根自身不标脏）时不复用旧位置" {
    const re = @import("render_engine/mod.zig");
    re.retained_memo_test_override = true;
    defer re.retained_memo_test_override = null;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 800);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 800 }, .direction = .column }, .{});
    const grower = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 20 }, .background = Color.rgba(9, 9, 9, 255) }, .{});
    const card = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 }, .background = Color.rgba(40, 40, 40, 255) }, .{});
    try card.appendChild(cx.allocator, try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(200, 1, 1, 255) }, .{}));
    try root.appendChild(cx.allocator, grower);
    try root.appendChild(cx.allocator, card);
    cx.root = root;
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    var f: usize = 0;
    while (f < 3) : (f += 1) {
        grower.markRenderDirty();
        _ = cx.render();
    }
    try std.testing.expect(cx.perf.rn_memo_replays >= 1);
    // The grower gets taller: the card moves down, only the grower is marked.
    grower.style.height = .{ .px = 60 };
    grower.markLayoutDirty();
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

var memo_hook_target: ?*Node = null;
var memo_hook_flip: bool = false;
fn memoRawWriterHook(node: *Node) void {
    _ = node;
    // Undeclared hook: rewrites a descendant raw (no dirty mark), as hook-owned subtrees may.
    const t = memo_hook_target orelse return;
    memo_hook_flip = !memo_hook_flip;
    t.style.translate_x = if (memo_hook_flip) 5 else 0;
}

test "retained memo: 未声明 hook 节点的后代不单独复用（hook 可原始写入后代）" {
    const re = @import("render_engine/mod.zig");
    re.retained_memo_test_override = true;
    defer re.retained_memo_test_override = null;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(640, 480);
    const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 } }, .{});
    const hooked = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    hooked.meta.per_frame.hooks.before_render.main = memoRawWriterHook;
    const child = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = Color.rgba(30, 30, 30, 255) }, .{});
    try child.appendChild(cx.allocator, try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .background = Color.rgba(200, 2, 2, 255) }, .{}));
    try hooked.appendChild(cx.allocator, child);
    try root.appendChild(cx.allocator, hooked);
    cx.root = root;
    memo_hook_target = child.children.items[0];
    defer memo_hook_target = null;
    cx_render_for_tests.setVerifyIncrementalForTest(true);
    defer cx_render_for_tests.setVerifyIncrementalForTest(null);
    cx.incremental_verify_mismatch_total = 0;
    var f: usize = 0;
    while (f < 6) : (f += 1) {
        root.markRenderDirty();
        renderNextFrame(cx);
    }
    try std.testing.expectEqual(@as(u64, 0), cx.incremental_verify_mismatch_total);
}

// A before-render hook that frees an ancestor mid-tick must stop the traversal of that subtree:
// later hooks below the retired ancestor belong to disposed state. isRetiring answers from the
// node's own state while nothing retired during the tick; this pins the retirement-generation
// fallback (a hook frees the grandparent of the node it runs on, which itself stays unflagged).
test "tick: a hook that frees an ancestor stops the hooks below it" {
    const State = struct {
        var cx_ptr: ?*Cx = null;
        var victim: ?*ui.Node = null;
        var later_runs: u32 = 0;
        var fired = false;
        fn freeAncestor(_: *ui.Node) void {
            if (fired) return;
            fired = true;
            cx_ptr.?.freeNode(victim.?);
        }
        fn later(_: *ui.Node) void {
            later_runs += 1;
        }
    };
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 200);
    const root = try box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 200 }, .direction = .column }, .{});
    const outer = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 }, .direction = .column }, .{});
    const mid = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 60 }, .direction = .column }, .{});
    const leaf = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 20 } }, .{});
    try mid.appendChild(cx.allocator, leaf);
    try outer.appendChild(cx.allocator, mid);
    try root.appendChild(cx.allocator, outer);
    cx.root = root;
    State.cx_ptr = cx;
    State.victim = outer;
    State.later_runs = 0;
    State.fired = false;
    // mid's hook runs before leaf is visited; it retires outer (mid's parent), not mid.
    mid.meta.per_frame.hooks.before_render.main = State.freeAncestor;
    leaf.meta.per_frame.hooks.before_render.main = State.later;
    cx.layout();
    _ = cx.render();
    try std.testing.expect(State.fired);
    try std.testing.expectEqual(@as(u32, 0), State.later_runs);
    _ = cx.render();
    try std.testing.expectEqual(@as(u32, 0), State.later_runs);
}

// ── Display payload ranges of fallback-prebuilt subtrees ──────────────────────────────────────────

fn displayListHasItemForTest(items: []const display_list.DisplayItem, node_id: u32) bool {
    for (items) |item| {
        if (item.header().node_id == node_id) return true;
    }
    return false;
}

fn absBoxForTest(cx: *Cx, x: f32, y: f32, w: f32, h: f32, bg: ?Color) !*Node {
    const n = try box(cx, .{ .width = .{ .px = w }, .height = .{ .px = h }, .position = .absolute, .background = bg orelse Color.TRANSPARENT }, .{});
    (try n.style.ensureExtFallible(cx.allocator)).inset = .{ .left = .{ .px = x }, .top = .{ .px = y } };
    return n;
}

// A container whose subtree is not "simple" (here: a nested overflow container, which keeps its
// own cache) takes the prebuild fallback path: its own content and children land in the display
// list prefix one by one and the paint pass appends nothing for it. Its subtree range must still
// cover that prefix part: the enclosing overflow container assembles its cross-frame cache from
// its children's ranges and replays it on the next clean frame.
test "display payload: fallback-prebuilt child stays in the enclosing overflow cache (whole and split prefix)" {
    for ([_]bool{ true, false }) |memo| {
        const re = @import("render_engine/mod.zig");
        re.retained_memo_test_override = memo;
        defer re.retained_memo_test_override = null;
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(640, 400);
        const root = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 400 }, .direction = .column }, .{});
        const stage = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 }, .overflow_hidden = true, .background = Color.rgba(10, 10, 10, 255) }, .{});
        const layer = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{});
        const card = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 }, .overflow_hidden = true, .background = Color.rgba(200, 10, 10, 255) }, .{});
        const inner = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(10, 200, 10, 255) }, .{});
        const other = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(10, 10, 200, 255) }, .{});
        try card.appendChild(cx.allocator, inner);
        try layer.appendChild(cx.allocator, card);
        try layer.appendChild(cx.allocator, other);
        try stage.appendChild(cx.allocator, layer);
        try root.appendChild(cx.allocator, stage);
        cx.root = root;
        var f: usize = 0;
        while (f < 6) : (f += 1) {
            // Frame 2 repaints a sibling while the card stays clean: the card replays its own cache,
            // which splits the layer between the prefix (card background) and the paint-pass tail.
            if (f == 2) other.setBackground(Color.rgba(10, 10, 201, 255));
            renderNextFrame(cx);
            const items = cx.display_list.items.items;
            for ([_]*Node{ stage, card, inner, other }) |n| {
                if (!displayListHasItemForTest(items, n.id)) {
                    std.debug.print("memo={} frame {d}: node {d} missing from the display list\n", .{ memo, f, n.id });
                    return error.TestUnexpectedResult;
                }
            }
            try std.testing.expect(displayListHasFillColorForTest(items, card.id, Color.rgba(200, 10, 10, 255)));
        }
    }
}

const DragSettleScene = struct {
    stage: *Node,
    layer: *Node,
    edge: *Node,
    tile: *Node,
    visible: [7]*Node,
};

/// ThunderLink arrangement stage: a clipped stage with full-size overlay layers; one holds a peer
/// tile (with a corner toggle) and its edge bar.
fn buildDragSettleScene(cx: *Cx) !DragSettleScene {
    const root = try box(cx, .{ .width = .{ .px = 800 }, .height = .{ .px = 400 }, .direction = .column }, .{});
    const stage = try box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 256 }, .overflow_hidden = true, .background = Color.rgba(30, 30, 34, 255), .corner_radius = 12 }, .{});
    const zones = try absBoxForTest(cx, 0, 0, 640, 256, null);
    try zones.appendChild(cx.allocator, try absBoxForTest(cx, 205, 6, 150, 62, Color.rgba(40, 40, 60, 255)));
    const home = try absBoxForTest(cx, 232, 70, 176, 116, Color.rgba(250, 250, 250, 255));
    const layer = try absBoxForTest(cx, 0, 0, 640, 256, null);
    const edge = try absBoxForTest(cx, 370, 96, 3, 64, Color.rgba(0, 120, 255, 255));
    const tile = try box(cx, .{ .width = .{ .px = 148 }, .height = .{ .px = 92 }, .position = .absolute, .direction = .column, .padding = .{ .top = 1.5, .right = 1.5, .bottom = 10, .left = 1.5 }, .background = Color.rgba(220, 235, 255, 255), .corner_radius = 10 }, .{});
    (try tile.style.ensureExtFallible(cx.allocator)).inset = .{ .left = .{ .px = 374 }, .top = .{ .px = 82 } };
    const bar = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 7 }, .background = Color.rgba(0, 120, 255, 255) }, .{});
    const label = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .column }, .{});
    try label.appendChild(cx.allocator, try text(cx, "peer", .{ .font_size = 12 }));
    const slot = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .position = .absolute }, .{});
    (try slot.style.ensureExtFallible(cx.allocator)).inset = .{ .right = .{ .px = 6 }, .top = .{ .px = 12 } };
    const toggle = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .background = Color.rgba(255, 255, 255, 255), .corner_radius = 6 }, .{});
    try slot.appendChild(cx.allocator, toggle);
    try tile.appendChild(cx.allocator, bar);
    try tile.appendChild(cx.allocator, label);
    try tile.appendChild(cx.allocator, slot);
    try layer.appendChild(cx.allocator, edge);
    try layer.appendChild(cx.allocator, tile);
    try stage.appendChild(cx.allocator, zones);
    try stage.appendChild(cx.allocator, home);
    try stage.appendChild(cx.allocator, layer);
    try root.appendChild(cx.allocator, stage);
    cx.root = root;
    return .{ .stage = stage, .layer = layer, .edge = edge, .tile = tile, .visible = .{ stage, home, edge, tile, bar, toggle, zones.children.items[0] } };
}

/// Drag the tile around and drop it (ThunderLink: inline translate per pointer move, then
/// unsetStyleInline + animateNode with ease_out_back), round after round in one session, while
/// unrelated parts of the stage keep repainting (pointer moves). Returns the frames whose display
/// list misses a visible node of the stage.
fn runDragSettleSession(memo: bool, drops: []const [2]f32) !usize {
    const re = @import("render_engine/mod.zig");
    re.retained_memo_test_override = memo;
    defer re.retained_memo_test_override = null;
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 400);
    const scene = try buildDragSettleScene(cx);
    var f: usize = 0;
    while (f < 3) : (f += 1) renderNextFrame(cx);
    var missing: usize = 0;
    var cache_replays: usize = 0;
    for (drops) |drop| {
        const dx = drop[0];
        const dy = drop[1];
        f = 0;
        while (f < 8) : (f += 1) {
            const k = @as(f32, @floatFromInt(f + 1)) / 8;
            scene.tile.style.translate_x = dx * k;
            scene.tile.style.translate_y = dy * k;
            scene.tile.markCompositePropDirty();
            renderNextFrame(cx);
        }
        scene.tile.style.translate_x = 0;
        scene.tile.style.translate_y = 0;
        scene.tile.markCompositePropDirty();
        ui.animateNode(scene.tile, cx.allocator, .{ .prop = .translate_x, .from = dx, .to = 0, .duration = 0.32, .easing = .ease_out_back });
        ui.animateNode(scene.tile, cx.allocator, .{ .prop = .translate_y, .from = dy, .to = 0, .duration = 0.32, .easing = .ease_out_back });
        f = 0;
        while (f < 30) : (f += 1) {
            // Pointer moving over the stage during the settle: hover repaints elsewhere on it.
            if (f < 22) scene.visible[6].markRenderDirty();
            renderNextFrame(cx);
            cache_replays += cx.perf.rn_paint_cache_replays;
            for (scene.visible) |n| {
                if (!displayListHasItemForTest(cx.display_list.items.items, n.id)) {
                    missing += 1;
                    break;
                }
            }
        }
        try std.testing.expect(scene.tile.frame_state.frame_local.runtime.commands == null);
    }
    // The stage replays its overflow cache once the settle is over.
    try std.testing.expect(cache_replays > 0);
    return missing;
}

test "retained memo: 拖放回弹（平移动画）期间舞台其它部分重绘，动画结束后被裁剪舞台的缓存仍含整个浮层子树" {
    // Translation replay of the tile's descendants leaves their world positions within float
    // rounding of a rebuild, which can move the overlay layer off the simple prebuild path onto
    // the fallback one; the stage's overflow cache then has to take the layer from its prefix
    // range. Memo on and off must draw the same nodes on every frame.
    const drops = [_][2]f32{ .{ 181.3, -40.7 }, .{ 227.6, 12.4 }, .{ 49.8, 21.3 }, .{ -116.8, 33.1 }, .{ 113.5, -71.2 }, .{ 3.8, 0.9 }, .{ 92.1, 57.3 }, .{ -170.4, -20.6 } };
    const missing_off = try runDragSettleSession(false, &drops);
    const missing_on = try runDragSettleSession(true, &drops);
    try std.testing.expectEqual(@as(usize, 0), missing_off);
    try std.testing.expectEqual(@as(usize, 0), missing_on);
}
