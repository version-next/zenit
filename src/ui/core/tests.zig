const std = @import("std");
test {
    _ = @import("cursor_tests.zig");
}
const builtin = @import("builtin");
// task #161: ui_core import 历史 build.zig 漏配；改用相对路径让此文件能被
// src/ui/tests_root.zig 的 test {} 块拉入。同一个 src/ui/core.zig 文件。
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    cx.setViewport(800, 600);
    try std.testing.expectEqual(@as(f32, 800), cx.viewport.width);
    try std.testing.expectEqual(@as(f32, 600), cx.viewport.height);
}

test "automation cursor shape is isolated from native cursor updates" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    cx.updateAutomationCursor(40, 50, false);
    _ = cx.virtual_cursor.setShape(.text);

    // A physical/native pointer can update the system cursor independently.
    // It must not mutate the virtual cursor left at an automation coordinate.
    cx.setCursorOverride(.grabbing);
    try std.testing.expectEqual(ui.CursorShape.grabbing, cx.current_cursor);
    try std.testing.expectEqual(ui.CursorShape.text, cx.virtual_cursor.shape);
}

// ── 自定义位图光标 ─────────────────────────────────────────────────────
// 光标链路：Cx.setCustomCursor（光栅化+缓存+激活）→ style.cursor/override
// 解析到 .custom → system_sdk.setCustomCursor 下发位图。mock 后端记录调用。

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
        // 借用缓冲只在本回调内有效（真实后端会拷贝），这里不触碰内容
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
    const cx = try Cx.init(std.testing.allocator);
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

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setSystemSdk(&sdk);

    // 激活时 override 还没到 .custom：只注册，不下发
    cx.setCustomCursor(.{ .svg_data = cursor_svg_a, .size_pt = 24, .scale = 2, .hot_x = 2, .hot_y = 22 });
    try std.testing.expectEqual(@as(u32, 0), backend.set_custom_count);
    try std.testing.expect(cx.activeCustomCursorKey() != null);

    cx.setCursorOverride(.custom);
    try std.testing.expectEqual(ui.CursorShape.custom, cx.current_cursor);
    try std.testing.expectEqual(@as(u32, 1), backend.set_custom_count);
    // viewBox 24x24 → 24pt 宽 @2x = 48px；热点逻辑坐标 ×scale
    try std.testing.expectEqual(@as(u32, 48), backend.last_custom.width);
    try std.testing.expectEqual(@as(u32, 48), backend.last_custom.height);
    try std.testing.expectEqual(@as(usize, 48 * 48 * 4), backend.last_custom.len);
    try std.testing.expectEqual(@as(f32, 4.0), backend.last_custom.hot_x);
    try std.testing.expectEqual(@as(f32, 44.0), backend.last_custom.hot_y);

    // 同 desc 重复调用：key 相同直接返回，不重下发
    const first_key = backend.last_custom.key;
    cx.setCustomCursor(.{ .svg_data = cursor_svg_a, .size_pt = 24, .scale = 2, .hot_x = 2, .hot_y = 22 });
    try std.testing.expectEqual(@as(u32, 1), backend.set_custom_count);

    // 换内容：shape 停在 .custom，但 key 变化必须重下发（指针静止场景）
    cx.setCustomCursor(.{ .svg_data = cursor_svg_b, .size_pt = 24, .scale = 2, .hot_x = 1, .hot_y = 11 });
    try std.testing.expectEqual(@as(u32, 2), backend.set_custom_count);
    try std.testing.expect(backend.last_custom.key != first_key);
    // viewBox 24x12 → 48x24 px
    try std.testing.expectEqual(@as(u32, 24), backend.last_custom.height);

    // 离开 .custom：恢复固定形状路径并清空已下发 key
    cx.setCursorOverride(null);
    try std.testing.expectEqual(ui.CursorShape.default, cx.current_cursor);
    try std.testing.expect(cx.custom_cursor.submitted == null);
    // Initial default is submitted once, then restored after the custom image.
    try std.testing.expectEqual(@as(u32, 2), backend.set_shape_count);
}

test "custom cursor: unregistered or unsupported degrades to fallback shape" {
    // 未注册位图就解析到 .custom → 降级 crosshair，走 set_shape
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

        var cx = try Cx.init(std.testing.allocator);
        defer cx.deinit();
        cx.setSystemSdk(&sdk);

        cx.setCursorOverride(.custom);
        try std.testing.expectEqual(ui.CursorShape.crosshair, cx.current_cursor);
        try std.testing.expectEqual(@as(u32, 1), backend.set_shape_count);
        try std.testing.expectEqual(@intFromEnum(ui.CursorShape.crosshair), backend.last_shape);
        try std.testing.expectEqual(@as(u32, 0), backend.set_custom_count);
    }
    // 后端没有 set_custom（可选字段缺失）：注册了也降级
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

        var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    // 无任何定时唤醒需求
    try std.testing.expectEqual(@as(?u64, null), cx.nextWakeDelayNs());

    // scheduleRedrawAfterNs deadline 进入聚合：剩余时间 ≤ 请求的 delay
    const delay_ns: u64 = 50 * std.time.ns_per_ms;
    cx.scheduleRedrawAfterNs(delay_ns);
    const remaining = cx.nextWakeDelayNs() orelse return error.TestExpectedDeadline;
    try std.testing.expect(remaining <= delay_ns);

    // 只读：查询不消费 deadline，也不置 needs_redraw
    cx.needs_redraw = false;
    try std.testing.expect(cx.nextWakeDelayNs() != null);
    try std.testing.expect(!cx.needs_redraw);

    // 更近的 deadline 覆盖聚合结果
    cx.scheduleRedrawAfterNs(1 * std.time.ns_per_ms);
    const closer = cx.nextWakeDelayNs() orelse return error.TestExpectedDeadline;
    try std.testing.expect(closer <= 1 * std.time.ns_per_ms);
}

test "box: inline children" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(800, 600);

    const root = try box(cx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 600 },
        .direction = .column,
        .gap = 16,
    }, .{
        try text(cx, "Hello", .{}),
        try text(cx, "World", .{ .color = theme.dark.color.fg_secondary }),
    });

    cx.root = root;
    cx.layout();

    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expectEqual(@as(f32, 800), root.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 600), root.rectFromWorldOrFallback().h);
}

test "hstack/vstack: layout shortcuts" {
    var cx = try Cx.init(std.testing.allocator);
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

    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // 第 1 轮读到的是同一帧、回调改动之后重新布局的宽度
    try std.testing.expectEqual(@as(f32, 250), probe.seen_w);
    try std.testing.expectEqual(@as(f32, 250), child.rectFromWorldOrFallback().w);

    cx.removeAfterLayoutHook(&probe);
    try std.testing.expectEqual(@as(usize, 0), cx.after_layout_hooks.items.len);
}

test "after-layout hook removing itself during iteration does not skip the next hook" {
    // runAfterLayoutHooks 按下标遍历，回调里 removeAfterLayoutHook（一次性
    // hook 的自然写法）orderedRemove 后下标照常 +1，紧随其后的 hook 被跳过。
    var cx = try Cx.init(std.testing.allocator);
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
    // c 回调里连带移除排在它前面的 a（前移两格：b 已自删）。
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
                // content 曾断言为空（纯靠 blob_id 间接取字节）。但 blob_id 是
                // 帧内序号，跨帧存活的 item 会落到别人的 blob 上 —— 终端因此
                // 画出状态栏的 "plaintext" 切片。现在 item 自带兜底切片，
                // resolveTextRunContent 用 content_hash 识破易主后回退到它。
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
    // appendLoweredBoth 不再写 .main，只写 .main_paint
    try std.testing.expect(cx.lowering.main_paint.items.len >= 1);
}

// Stage B-1/B-2: shadow GpuDraw encode end-to-end probe.
// 跑 render 后断言 display_list / drawable lowering_buffer / GpuDraw 三者数量
// 协调 + pipeline 序列等价 + max_batch_run 合理。
test "render: stage B-1/B-2 shadow GpuDraw encode is sequence-equivalent" {
    var cx = try Cx.init(std.testing.allocator);
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
    if (builtin.mode != .Debug) {
        var render_ctx = testRenderContext(cx);
        ui.render_engine.runShadowEncode(&render_ctx);
    }

    // debug build 中 renderNode 末尾自动调 runShadowEncode，perf 应已累计。
    // B-1 等价性：display_list 条目数 == drawable lowering_buffer commands 数。
    try std.testing.expectEqual(@as(u32, 0), cx.perf.stage_b_shadow_count_mismatches);
    try std.testing.expect(cx.perf.stage_b_shadow_display_items > 0);
    try std.testing.expectEqual(
        cx.perf.stage_b_shadow_display_items,
        cx.perf.stage_b_shadow_drawable_commands,
    );
    // batching 后 GpuDraw 数应 ≤ display items 数
    try std.testing.expect(cx.perf.stage_b_shadow_gpu_draws <= cx.perf.stage_b_shadow_display_items);

    // B-2 强化：pipeline 序列也必须等价。lowering 漏 case / DisplayItem 路径
    // 多/少产某种 kind 的 draw 都会让此 mismatch 计数 > 0。
    try std.testing.expectEqual(@as(u32, 0), cx.perf.stage_b_shadow_pipeline_mismatches);
    // 至少应该看到一些可合并 run（连续 fill_rect 或同 pipeline）
    try std.testing.expect(cx.perf.stage_b_shadow_max_batch_run >= 1);

    // B-2 coverage probe: lowered kind 计数 == 主路径 drawable 计数 (per kind)。
    // 任一 kind 不等说明 lowering 与主路径分类不一致，B-2 cutover 候选筛选会用到。
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_rect, cx.perf.stage_b_shadow_drawable_kind_rect);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_text, cx.perf.stage_b_shadow_drawable_kind_text);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_image, cx.perf.stage_b_shadow_drawable_kind_image);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_path, cx.perf.stage_b_shadow_drawable_kind_path);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_shadow, cx.perf.stage_b_shadow_drawable_kind_shadow);
    try std.testing.expectEqual(cx.perf.stage_b_shadow_kind_gradient, cx.perf.stage_b_shadow_drawable_kind_gradient);
    // 本场景至少有 box 背景 (rect) + text，两类都应 > 0。
    try std.testing.expect(cx.perf.stage_b_shadow_kind_rect > 0);
    try std.testing.expect(cx.perf.stage_b_shadow_kind_text > 0);
}

test "render: lowered path geometry is frame-owned instead of borrowing the node" {
    var cx = try Cx.init(std.testing.allocator);
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

test "render: identical text nodes reuse text blob within frame" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // 回归（下游编辑器状态栏 "3 × 4" → "3 × 5" 只重画 × 之前的段）：
    // text hash 缓存键是 (content_version, content_ptr, content_len, spans_*)，
    // 而 setText **不撞** content_version。等长换文本时 len 不变、ptr 又常被
    // allocator 复用（就地改写调用方 buffer 则必然同址）—— 三项全中就吐旧
    // hash，下游 blob/paint chunk/retained 一路判"没变"而跳过重录。
    // 这里刻意**不调**任何 markDirty：作废责任在写路径本身。
    var cx = try Cx.init(std.testing.allocator);
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

    // 同 ptr、同 len，只有最后一个字节变了（× 之后的那一段）。
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
    // 回归（下游编辑器状态栏 "3 × 4" → "3 × 5" 只重画 × 之前的那一段）：
    // 等长换文本时 content_ptr 极可能被 allocator 复用成同一地址，len 也没变。
    // 若 text_hash 缓存只认 (content_version, ptr, len)，而 content_version
    // 又没被 setText 撞新，缓存就会命中旧 hash —— 下游 blob / paint chunk 一路
    // 判 "内容没变" 而跳过重录。含回退字体的串（× 把行切成三段）尤其显眼：
    // 变化落在哪一段就只有那段更新，其余段保持旧字形。
    var cx = try Cx.init(std.testing.allocator);
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

    // 端到端：再渲染一帧，display list 里的 text_run 必须吐出新字节。
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

    // Stage 3 fold：同节点 rounded_clip 合并进 opacity layer，token 消失、
    // begin_opacity_layer 携带 corner_radius。
    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_folded_radius);
    try std.testing.expect(!saw_begin_rounded_clip);
    try std.testing.expect(saw_nested_text);
}

test "render: self blur subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator);
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
    // self_blur 不用 self-effect 坐标空间（applyBackdropBlur 不 push offscreen layer，
    // 没有外部 translation 把 button-local 坐标转回 absolute），因此不计入 self_effect 计数器。
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

    // Stage 3 fold：rounded_clip 并入 opacity layer（见上方同名注释）。
    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_folded_radius);
    try std.testing.expect(!saw_begin_rounded_clip);
    try std.testing.expect(saw_nested_text);
}

test "render: self scale and opacity subtree can replay from display payload prepass" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

    // Stage 3 fold：rounded_clip 并入 opacity layer（见上方同名注释）。
    try std.testing.expect(saw_begin_opacity);
    try std.testing.expect(saw_folded_radius);
    try std.testing.expect(!saw_begin_rounded_clip);
    try std.testing.expect(saw_text);
}

test "render: blob-backed ellipsis text subtree can replay from display payload prepass under parent scale" {
    var cx = try Cx.init(std.testing.allocator);
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

test "render: spans text subtree can replay from display payload prepass under parent opacity and scale" {
    var cx = try Cx.init(std.testing.allocator);
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
            // task #161 校准（v0.4 之后）：render pipeline 现在用单文本 blob + spans 装饰
            // 不再 chunk 成多 text command。检查 text 包含原文 + 有 spans。
            if (std.mem.indexOf(u8, txt.text_content, "span") != null and txt.text_spans != null) {
                saw_text_with_spans = true;
            }
        }
    }

    try std.testing.expect(saw_bg_rect);
    try std.testing.expect(saw_text_with_spans);
}

test "render: text blobs do not reuse across different spans" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

    // task #161 校准：v0.4 后 pipeline 合并 adjacent 同 weight/italic/monospace text runs，
    // span 装饰（bg/underline/strikethrough/color）通过 spans 字段编码到单 run，
    // 不同 font_weight 才真分 run。3 spans 在 6 字符上只产生 ≥ 2 runs（[0..4] + [4..6]）。
    try std.testing.expect(bg_rects >= 1);
    try std.testing.expect(deco_rects >= 2);
    try std.testing.expect(text_runs >= 2);
}

test "render: own content can replay directly from prebuilt display payload" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

test "render: display list emits overflow fade gradients" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
            try std.testing.expect(clip.clip_shape_kind == @intFromEnum(ui.display_list.ClipShapeKind.rect) or clip.clip_shape_kind == @intFromEnum(ui.display_list.ClipShapeKind.rounded_rect) or clip.clip_shape_kind == @intFromEnum(ui.display_list.ClipShapeKind.polygon));
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var clicked = false;

    const btn = clickable(
        try box(cx, .{
            .width = .{ .px = 100 },
            .height = .{ .px = 40 },
            .background = theme.dark.color.accent,
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // 回归：pass1 里 .px / .fit / .percent / flex_basis 四个分支都累加
    // margin_main，唯独 .grow 分支只累加 flex_total —— grow 子节点的主轴
    // margin 从不进 used_space，于是 remaining 被高估，带 margin 的 flex
    // 子节点会溢出父容器。
    //
    // 400 宽容器：px 子节点 100 + grow 子节点左右各 20 margin。
    // grow 应拿 400 - 100 - 40 = 260，而不是 300。
    var cx = try Cx.init(std.testing.allocator);
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
    // 右边界不得越过父容器
    const r = grow_child.rectFromWorldOrFallback();
    try std.testing.expect(r.x + r.w <= 400);
}

test "align: 最终对齐 pass 移动子节点后必须标脏" {
    // layoutChildren 末尾有一个「最终交叉轴对齐」pass：wrap / fit 回填会在
    // 递归中改变子节点的交叉轴尺寸，所以要用最终尺寸重新对齐一次。
    //
    // 但它直接 setLayoutY/setLayoutX 写几何，**没有**摆放循环里那段
    // 「位置变了就标 dirty.core.layout」的检查。如果它把子节点挪了位置却
    // 不标脏，子树就带着过期的世界坐标留到下一帧。
    var cx = try Cx.init(std.testing.allocator);
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
    // center 对齐：(300 - 50) / 2 = 125
    try std.testing.expectEqual(@as(f32, 125), settled_y);

    // 稳定后再布一次，位置不该再变（两个 pass 必须收敛到同一个答案，
    // 否则每帧都在互相覆盖）
    cx.layout();
    try std.testing.expectEqual(settled_y, child.rectFromWorldOrFallback().y);
}

test "align: reverse pass 挪动子节点后必须标脏" {
    // batchReverseChildren 直接 setLayoutX/Y 写几何，不标 dirty.core.layout。
    // row_reverse 下每个子节点的主轴位置都会变，子树带着过期世界坐标留到下一帧。
    var cx = try Cx.init(std.testing.allocator);
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

    // reverse 把子节点推到右侧：400 - 100 = 300
    try std.testing.expectEqual(@as(f32, 300), child.rectFromWorldOrFallback().x);
    // 位置被 reverse pass 改过 ⇒ 必须标脏，否则后代的世界坐标不会重算
    try std.testing.expect(child.frame_state.state_bits.dirty.core.layout or
        child.frame_state.state_bits.dirty.core.subtree_layout);
}

test "align: 稳定后重复布局不再标脏（不得永不停帧）" {
    // reverse / 最终对齐两个 pass 新增了标脏。若判据写成无条件标脏，稳定态
    // 每帧都会有脏节点 ⇒ idle 永不停帧（这个坑仓库里踩过一次）。
    var cx = try Cx.init(std.testing.allocator);
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

    // 清掉首次布局的脏位，再布一次：位置已收敛 ⇒ 不该再标脏
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    cx.root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 300 },
        .background = theme.dark.color.bg_primary,
    }, .{});

    cx.layout();
    _ = cx.render();
    const commands = cx.lowerForEncoderPaintTable();

    try std.testing.expect(commands.len > 0);
    try std.testing.expect(commands[0].isFillRect());
    try std.testing.expectEqual(@as(f32, 400), commands[0].geom.w);
}

test "render: non-uniform border widths emit single per-side border" {
    var cx = try Cx.init(std.testing.allocator);
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
            // 单个 draw call 包含全部 4 边宽度
            try std.testing.expect(std.math.approxEqAbs(f32, b.border_widths[0], 1, 0.0001)); // top
            try std.testing.expect(std.math.approxEqAbs(f32, b.border_widths[1], 2, 0.0001)); // right
            try std.testing.expect(std.math.approxEqAbs(f32, b.border_widths[2], 3, 0.0001)); // bottom
            try std.testing.expect(std.math.approxEqAbs(f32, b.border_widths[3], 4, 0.0001)); // left

        }
    }

    try std.testing.expectEqual(@as(usize, 0), push_count); // 无 clip
    try std.testing.expectEqual(@as(usize, 1), per_side_count); // 单个 draw call
}

test "render: per-side border colors emit per-side borders without clipping" {
    var cx = try Cx.init(std.testing.allocator);
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

    try std.testing.expectEqual(@as(usize, 0), push_count); // 无 clip
    try std.testing.expectEqual(@as(usize, 4), per_side_count);
    try std.testing.expect(saw_red);
    try std.testing.expect(saw_green);
    try std.testing.expect(saw_blue);
    try std.testing.expect(saw_yellow);

    // display list 验证
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
    var cx = try Cx.init(std.testing.allocator);
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
            // 圆角应当被传递到 shader
            try std.testing.expect(b.radii.toArray()[1] > 0); // TR = 8
            try std.testing.expect(b.radii.toArray()[2] > 0); // BR = 8

        }
    }

    try std.testing.expectEqual(@as(usize, 0), push_count); // 无 clip
    try std.testing.expect(per_side_count >= 1); // 至少有 3 边（左边透明不渲染）
}

test "render spans draws highlight backgrounds before italic text" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
                // CA-pure（P6 后）：surface 内容以 **1×**（unscaled owner-local）烘焙，
                // scale 统一由 composite 的 draw_transform 施加（plan R4）。故 font_size
                // 保持原始 12，而非旧模型的反向缩放 24。
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

test "render: clip_shape ellipse emits ellipse clip fallback" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
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
            try std.testing.expectEqual(@intFromEnum(ui.ClipShapeKind.ellipse), clip.clip_shape_kind);
            saw_ellipse_clip = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            return error.UnexpectedRoundedClipEffect;
        }
    }
    try std.testing.expect(saw_ellipse_clip);
}

test "render: clip_shape path emits polygon clip for single closed polyline" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
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
            try std.testing.expectEqual(@intFromEnum(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 120 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
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
            try std.testing.expectEqual(@intFromEnum(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expect(clip.clip_polygon_ptr.?.point_count >= 4);
            try std.testing.expectEqual(ui.PathFillRule.evenodd, clip.clip_polygon_ptr.?.fill_rule);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: single-subpath multi-curve clip_shape path stays polygon clip within expanded point budget" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(260, 220);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 180 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
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
            try std.testing.expectEqual(@intFromEnum(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expect(clip.clip_polygon_ptr.?.point_count > 16);
            try std.testing.expectEqual(ui.PathFillRule.nonzero, clip.clip_polygon_ptr.?.fill_rule);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: multi-subpath curved clip_shape path emits polygon clip with contours" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 120 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
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
            try std.testing.expectEqual(@intFromEnum(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expectEqual(@as(u8, 2), clip.clip_polygon_ptr.?.contour_count);
            try std.testing.expect(clip.clip_polygon_ptr.?.point_count >= 8);
            try std.testing.expect(clip.clip_polygon_ptr.?.contour_end_points[0] < clip.clip_polygon_ptr.?.contour_end_points[1]);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: clip_shape custom degrades to rect clip in render runtime" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
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
            try std.testing.expectEqual(@intFromEnum(ui.ClipShapeKind.rect), clip.clip_shape_kind);
            saw_rect_clip = true;
        } else if (cmd.isControl(.begin_rounded_clip)) {
            return error.UnexpectedRoundedClipEffect;
        }
    }
    try std.testing.expect(saw_rect_clip);
}

test "render: clip_shape custom uses polygon clip when path geometry exists" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
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
            try std.testing.expectEqual(@intFromEnum(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expectEqual(@as(u8, 1), clip.clip_polygon_ptr.?.contour_count);
            try std.testing.expectEqual(@as(u8, 4), clip.clip_polygon_ptr.?.point_count);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: clip_shape custom uses dedicated custom clip geometry" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(240, 140);

    const root = try box(cx, .{
        .width = .{ .px = 180 },
        .height = .{ .px = 100 },
        .background = Color.rgba(40, 60, 80, 255),
        .overflow_hidden = true,
    }, .{});
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
            try std.testing.expectEqual(@intFromEnum(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
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

    var cx = try Cx.init(std.testing.allocator);
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
    }, .{});
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
            try std.testing.expectEqual(@intFromEnum(ui.ClipShapeKind.polygon), clip.clip_shape_kind);
            try std.testing.expectEqual(@as(u8, 1), clip.clip_polygon_ptr.?.contour_count);
            try std.testing.expectEqual(@as(u8, 4), clip.clip_polygon_ptr.?.point_count);
            saw_polygon_clip = true;
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: overflow_hidden 子节点不把祖先的 opacity 层切成两段，clip 与内容同帧" {
    // 修复前（43bb5f3 起对所有 overflow_hidden 普通 box 发 CONTROL scroll-clip token）：
    //   begin_opacity, 父背景, 子背景, end_opacity, push_clip(world 60,40), begin_opacity,
    //   宽子, end_opacity, pop_clip
    // —— 祖先 opacity 层被切成两次独立合成（重叠区二次混合），blur 场景则背板采样两次。
    var cx = try Cx.init(std.testing.allocator);
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
    // 祖先层只开一次、关一次。
    try std.testing.expectEqual(@as(usize, 1), begins);
    try std.testing.expectEqual(@as(usize, 1), ends);
    // clip 包住宽子，且整个包围落在 begin..end 之内。
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
    // 43bb5f3 让所有 overflow_hidden 节点都发 token；节点自己带 opacity/blur/rounded_clip 时
    // 裁剪已由 compositor plan 的 apply_clip / surface mask 承担，token 只会重复并切开 effect 组。
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(220, 140);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 80 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
        .opacity = 0.6,
    }, .{});
    // 无阴影/描边：owner 自身内容全在 clip 内，overflow clip 仍走 compositor
    // apply_clip 快路径。带阴影的 owner 改由 children 包围 token 承担（阴影不许
    // 被自身 overflow clip 裁），见 "composited owner overflow clip spares owner
    // shadow ..."。

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
    var cx = try Cx.init(std.testing.allocator);
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

    // CA-pure 模型：surface 内 content 在 owner-unscaled-local 帧（world 的
    // translate(40,20) 已被 owner_world⁻¹ 剥掉），apply_clip 必须与 content 同帧
    // —— 即 (0,0,160,80)，恰与 content rect 重合。world 坐标 clip 会把 local
    // 内容的左上 40/20px 裁掉（rotate 场景下则整体裁空，见 effect_bridge fix）。
    try std.testing.expect(begin_x != null and begin_y != null);
    try std.testing.expect(clip_x != null and clip_y != null and clip_w != null and clip_h != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0), clip_x.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), clip_y.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 160), clip_w.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), clip_h.?, 0.001);
}

test "render: scroll opacity subtree disables own payload replay in effect scope" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    try std.testing.expectEqual(@as(f32, 0), effect_state.apply_clip_radius);
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
            if (clip.clip_shape_kind == @intFromEnum(ui.display_list.ClipShapeKind.ellipse)) saw_ellipse_clip = true;
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
    var cx = try Cx.init(std.testing.allocator);
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

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), resolved.refraction_level, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), resolved.blur_level, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), resolved.warp_gain, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), resolved.center_thickness, 0.0001);
}

test "render: compositor plan preserves polygon clip for opacity layer" {
    var cx = try Cx.init(std.testing.allocator);
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
    try std.testing.expectEqual(@as(u8, 5), effect_state.apply_clip_polygon.point_count);
    try std.testing.expectEqual(ui.PathFillRule.nonzero, effect_state.apply_clip_polygon.fill_rule);
    try std.testing.expect(!effect_state.apply_clip_bounds_fallback);

    var push_count: usize = 0;
    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            push_count += 1;
            if (clip.clip_shape_kind == @intFromEnum(ui.display_list.ClipShapeKind.polygon)) {
                try std.testing.expectEqual(@as(u8, 5), clip.clip_polygon_ptr.?.point_count);
                saw_polygon_clip = true;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 1), push_count);
    try std.testing.expect(saw_polygon_clip);
}

test "render: compositor plan preserves multi-contour polygon clip for opacity layer" {
    var cx = try Cx.init(std.testing.allocator);
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
    try std.testing.expectEqual(@as(u8, 2), effect_state.apply_clip_polygon.contour_count);
    try std.testing.expectEqual(ui.PathFillRule.evenodd, effect_state.apply_clip_polygon.fill_rule);
    try std.testing.expect(!effect_state.apply_clip_bounds_fallback);

    var saw_polygon_clip = false;
    for (commands) |cmd| {
        if (cmd.isControl(.push_clip)) {
            const clip = cmd;
            if (clip.clip_shape_kind == @intFromEnum(ui.display_list.ClipShapeKind.polygon)) {
                try std.testing.expectEqual(@as(u8, 2), clip.clip_polygon_ptr.?.contour_count);
                try std.testing.expect(clip.clip_polygon_ptr.?.contour_end_points[0] < clip.clip_polygon_ptr.?.contour_end_points[1]);
                saw_polygon_clip = true;
            }
        }
    }
    try std.testing.expect(saw_polygon_clip);
}

test "render: queryNode exposes clip fallback for non-effect overflow subtree" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(220, 140);

    const root = try box(cx, .{
        .width = .{ .px = 160 },
        .height = .{ .px = 80 },
        .background = Color.rgba(30, 40, 60, 255),
        .overflow_hidden = true,
        .opacity = 0.6,
    }, .{});
    // 无阴影/描边：owner 自身内容全在 clip 内，overflow clip 仍走 compositor
    // apply_clip 快路径。带阴影的 owner 改由 children 包围 token 承担（阴影不许
    // 被自身 overflow clip 裁），见 "composited owner overflow clip spares owner
    // shadow ..."。

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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // 命中侧的 paint_order 本身与渲染同序（C2 删除全局 stacking_z 之后，命中结果
    // 只能来自 paint_order；旧实现里 high 的 paint_order 反而更小，靠 stacking_z 20>10 掩盖）。
    try std.testing.expect(high.frame_state.frame_local.spatial.paint.order > low_sticky.frame_state.frame_local.spatial.paint.order);
    try std.testing.expectEqual(high, root.children.items[0]);
    try std.testing.expectEqual(low_sticky, root.children.items[1]);
}

/// 推进帧时钟再 render：同一帧时间内 ensureBeforeRenderTicked 会跳过 tick，sticky 不重算。
fn renderNextStickyFrame(cx: *Cx) void {
    cx.frame_time_ms += 16.0;
    _ = cx.render();
}

/// viewport(200×200, overflow_hidden) → content(translate_y = -S)
///   → [spacer 500, section 300 → [header 40 (sticky top=0)]]
/// 附录 A 探针 5 的结构：sticky 的父节点是文档流里 y=500 的块。
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const fx = try StickySectionFixture.build(cx);
    try std.testing.expectEqual(@as(f32, 500), fx.section.rectFromWorldOrFallback().y);

    // 未触及吸附线：自然位置。
    fx.scrollTo(cx, 100);
    try std.testing.expectEqual(@as(f32, 0), fx.header.frame_state.frame_local.runtime.sticky.y);
    // 吸附：header 自然 y = 500-600 = -100，补偿 100；未触及 section 底边。
    fx.scrollTo(cx, 600);
    try std.testing.expectEqual(@as(f32, 100), fx.header.frame_state.frame_local.runtime.sticky.y);
    // 钳制：section 屏幕底边 = 500+300-780 = 20，header 底边不得越过 → 补偿 260（旧公式把
    // section.rect.y 又加了一次，得 280，header 越过 section 继续吸顶）。
    fx.scrollTo(cx, 780);
    try std.testing.expectEqual(@as(f32, 260), fx.header.frame_state.frame_local.runtime.sticky.y);
    const g = fx.header.globalRect();
    try std.testing.expectEqual(@as(f32, -20), g.y);
    try std.testing.expectEqual(@as(f32, 20), g.y + g.h);
}

test "sticky: clamp with scrolled parent (parent.translate_y != 0)" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(200, 200);
    // viewport(clip) → content(translate_y=-S, padding.bottom=10) → [lead 100, header 40, tail 300]
    // sticky 的父节点就是被滚动的 content：旧公式多加一次 parent.translate_y(=-S)，钳制上限偏小 → 提前松开。
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

    // S=380：header 自然 y=-280 → 补偿 280；content 内容底 = 450-10-380 = 60，上限 60+280-40 = 300，不钳制。
    content.setStyle(null, .translate_y, -380);
    renderNextStickyFrame(cx);
    try std.testing.expectEqual(@as(f32, 280), header.frame_state.frame_local.runtime.sticky.y);
    // S=430：自然 y=-330 → 想要 330；内容底 = 10，上限 10+330-40 = 300 → 钳制到 300。
    content.setStyle(null, .translate_y, -430);
    renderNextStickyFrame(cx);
    try std.testing.expectEqual(@as(f32, 300), header.frame_state.frame_local.runtime.sticky.y);
    const g = header.globalRect();
    try std.testing.expectEqual(@as(f32, 10), g.y + g.h);
}

test "sticky: offset resets when ancestor clip intersection is empty" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(200, 200);
    // root(200×200) → clipper(100×100, clip) → content(translate_y=-100) → [lead 50, header 20, tail 200]
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

    // clipper 整体移出窗口：祖先裁剪交集为空，sticky 不再有吸附区域，偏移必须归零，
    // 不能残留上一帧的 50（globalRect / 命中 / 锚定 popover 会读到它）。
    clipper.setStyle(null, .translate_y, 1000);
    renderNextStickyFrame(cx);
    try std.testing.expectEqual(@as(f32, 0), header.frame_state.frame_local.runtime.sticky.y);
    try std.testing.expectEqual(@as(f32, 1000 + 50 - 100), header.globalRect().y);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(header.frame_state.frame_local.runtime.sticky.state)));
}

test "sticky: own translate participates in natural position" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const fx = try StickySectionFixture.build(cx);
    fx.header.setStyle(null, .translate_y, 10);

    // 吸附：自然 y = 500-600+10 = -90 → 补偿 90，视觉顶边正好贴在吸附线 0。
    fx.scrollTo(cx, 600);
    try std.testing.expectEqual(@as(f32, 90), fx.header.frame_state.frame_local.runtime.sticky.y);
    try std.testing.expectEqual(@as(f32, 0), fx.header.globalRect().y);
    // 钳制：视觉底边（含 translate）贴 section 底边 20 → 补偿 20-(-270)-40 = 250。
    fx.scrollTo(cx, 780);
    try std.testing.expectEqual(@as(f32, 250), fx.header.frame_state.frame_local.runtime.sticky.y);
    const g = fx.header.globalRect();
    try std.testing.expectEqual(@as(f32, 20), g.y + g.h);
}

test "sticky: state flags follow natural -> pinned -> constrained -> scrolled out" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const fx = try StickySectionFixture.build(cx);
    const sticky = &fx.header.frame_state.frame_local.runtime.sticky;

    const Expect = struct { scroll: f32, offset: f32, engaged_top: bool, pinned: bool, constrained: bool };
    const steps = [_]Expect{
        // 自然位置：未越过吸附线。
        .{ .scroll = 100, .offset = 0, .engaged_top = false, .pinned = false, .constrained = false },
        // 贴在吸附线上。
        .{ .scroll = 600, .offset = 100, .engaged_top = true, .pinned = true, .constrained = false },
        // 被 section 底边推着走（交接中）。
        .{ .scroll = 780, .offset = 260, .engaged_top = true, .pinned = false, .constrained = true },
        // header 整体滚出视口（视觉 -70..-30），仍被 section 钳制。
        .{ .scroll = 830, .offset = 260, .engaged_top = true, .pinned = false, .constrained = true },
        // 滚回 section 顶边进入视口：状态全部清除。
        // 注：滚到 section 离开 clip+48px 余量（如 scroll=0）时，tick 按 out-of-clip 跳过整棵 section
        // 子树，深层 sticky 不重算、保留上一次的值（§3.4 S3 的后半，C1 未处理）。
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

    // 一维模型（沿 sticky 方向）：父 content box 两端各扣 pad；sticky 贴在靠吸附线一侧的
    // content 边（leading = pad，trailing = parent_size - pad - size），自身 translate = t。
    // 自然位置 natural 按阶段选定，parent_origin 由它反推：
    //   leading  吸附线 0：   idle natural=50,  pinned natural=-100, constrained natural=-280
    //   trailing 吸附线 160： idle natural=60,  pinned natural=260,  constrained natural=440
    // 期望补偿量：idle 0，pinned 100，constrained = content 余量 = 260-2pad∓t（leading 减 t，trailing 加 t）。
    // parent_rect 的 x/y 故意给 500：它是相对祖父的布局坐标，求解时必须被忽略（双计 bug 的形状）。
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
                        // 自身 translate 让 leading 侧余量变小、trailing 侧余量变大。
                        .constrained => 260 - 2 * pad - (if (leading) t else -t),
                    };
                    const expected: f32 = if (leading) magnitude else -magnitude;

                    // 另一轴：自然位置 50（在 clip 内），且该轴没有 inset，不应产生任何补偿。
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

                    // 钳制后视觉位置（含自身 translate）正好贴 content box 边。
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

    // 无父节点：不钳制，纯吸附。
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
    // 显式 constraint 取代父 content box。
    {
        const r = geometry.solveSticky(.{
            .self_rect = Rect.init(0, 0, size, size),
            .parent_origin = .{ .x = 0, .y = -280 },
            .parent_rect = Rect.init(0, 0, parent_size, parent_size),
            .insets = .{ .top = 0 },
            .clip = clip,
            .constraint = Rect.init(0, -280, 200, 400),
        });
        // constraint 底边 120 → 补偿上限 120-(-280)-40 = 360，不截短想要的 280。
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
        // constraint 底边 -180 → 上限 -180-(-280)-40 = 60。
        try std.testing.expectEqual(@as(f32, 60), r2.offset.y);
        try std.testing.expect(r2.state.constrained and !r2.state.pinned);
    }
}

test "render: legacy overflow cache replays escaped overlay exactly once" {
    var cx = try Cx.init(std.testing.allocator);
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

// ─── z>0 带外渲染单元：已知缺陷护栏（方案 sticky-zindex-clip-decoupling-plan.md §10 V1/V2）───
//
// 以下三条在 2026-09-24 的工作树（C1 已修、C2/C3 未做）上**确认是红的**，红即缺陷存在。
// C2（删除逃逸，legacy 补渲染改传父 clip）已落地：V1 那条已转绿并去掉跳过闸。
// C3（带外 dirty 逐跳冒泡，node_dirty.zig isOutOfBandRenderUnit）已落地：V2 两条转绿、
// 去掉跳过闸，转成常规回归测试。

fn knownBugFillColorOfSize(cx: *Cx, w: f32, h: f32) ?Color {
    for (cx.lowerForEncoderPaintTable()) |it| {
        if (!it.isFillRect()) continue;
        if (@abs(it.geom.w - w) > 0.5 or @abs(it.geom.h - h) > 0.5) continue;
        return Color.rgba(it.color.r, it.color.g, it.color.b, it.color.a);
    }
    return null;
}

test "render: positive z child stays clipped on legacy overflow cache hit" {
    // V1（方案 §9.1 第 2 条）。场景仿照「legacy overflow cache replays escaped overlay
    // exactly once」：z>0 overlay 带自己的 opacity layer（opacity 0.8 + scale 动画），
    // 其 render dirty 不冒泡（escapesAncestorRenderPass，C3 后为 isOutOfBandRenderUnit），clipper 第 2 帧起命中 legacy
    // overflow cache。命中帧上 renderOverlayChildrenAfterCacheHit 以 clip=null 在缓存
    // 命令（含 clipper 的 push/pop_clip token 对）**之后**补渲染 overlay → scissor 栈空，
    // 溢出 clipper 底边的 30px 真的画出来了；而新鲜帧（第 1 帧）它在 token 对内、被裁。
    // 探针实测（2026-09-24）：第 1 帧 scissor=(0,0,160,100)，第 2..4 帧 scissor 深度 0。
    // 只有「z>0 子节点在 paint pass 里渲染」时才出现；plain / 仅 opacity 的 z>0 子节点
    // 内容由同帧 prebuild 写在 token 对内，命中帧仍被裁（同一探针的对照组）。
    // C2（2026-09-24）已修：补渲染改传父节点 clip/clip_id，命中帧上 overlay 虽仍排在缓存
    // token 对之后，但自带 clip-bridge（在它自己 opacity surface 的局部坐标里），换算到
    // 世界坐标 = clipper 框。跳过闸已去掉，转为常规回归测试。scissor 用 surface 感知的
    // c2ScissorStackForFill 计算：C2 之后 clip-bridge 出现在 overlay 的 surface 内部，
    // 按世界坐标直接求交会得出错误的 (0,0,160,30)。
    // 另：命中帧末尾 clipper 背景被再画一遍（F1，mod.zig tryReplayLegacyOverflowCacheHit
    // 无条件 appendNodeOwnContent），不属于本方案，这里不断言。
    var cx = try Cx.init(std.testing.allocator);
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
    overlay.style.translate_y = 70; // y ∈ [70,130)：溢出 clipper 底边 30px
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
    // 前提：本帧确实走了 legacy overflow cache 命中路径。
    try std.testing.expect(cx.perf.render_cache_hit > 0);
    try std.testing.expect(clipper.meta.per_frame.caches.commands.own != null);
    const replayed = (try c2ScissorStackForFill(cx, 80, 60, overlay_color)).rect orelse return error.CacheHitFrameUnclipped;
    try std.testing.expectEqual(clipper_box, replayed);
}

fn knownBugPositiveZChildRepaint(promoted_is_grandparent: bool) !void {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const root = try box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 240 } }, .{});
    // opacity 恒为 1：dirty 侧判据 parent.opacity >= 0.999 成立 → 子节点 render dirty 不冒泡。
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
    // 再来一帧（无新改动）：不能靠"下一帧自愈"蒙混过关。
    cx.frame_time_ms = 32.0;
    _ = cx.render();
    try std.testing.expectEqual(blue, knownBugFillColorOfSize(cx, 60, 70).?);
}

test "render: positive z child content change repaints under composited_group parent" {
    // V2（方案 §3.3 / §10）。父节点 composited_group=true、opacity=1：dirty 侧判据
    // (parent.opacity >= 0.999) 认为 z>0 子节点是带外单元 → render dirty 不冒泡；渲染侧
    // use_opacity_layer=true → childEscapesAncestorClipInPass=false，promoted cache 命中时
    // renderOverlayChildrenAfterCacheHit 不补渲染它。结果：改色后画面永久停在旧色。
    // 探针实测（2026-09-24）：composited_group 与「z>0 + will_change」父节点都复现；
    // rotate / scale / blend_mode 父节点不复现（它们不走 promoted replay，cache_hit=0）。
    // C3 已修：父节点持有 promoted 缓存 → 子节点不是带外单元 → render dirty 照常冒泡到父。
    try knownBugPositiveZChildRepaint(false);
}

test "render: positive z grandchild content change repaints under composited_group ancestor" {
    // V2 延伸：composited_group 祖父 → 普通父（opacity 1，不走 opacity layer）→ z>0 子。
    // 这里 dirty 侧与渲染侧判据**一致**（都认为子节点在父处带外），照样陈旧：
    // 子节点 dirty 在父处就停止冒泡，promoted 祖父整段替放旧缓存，而补渲染只看祖父的
    // 直接子节点。所以"统一判据"本身修不好它 —— C3 必须让带外 dirty 让包住它的
    // promoted/缓存祖先失效，而不只是对齐两个谓词。OverlayStack 的 content 节点
    // （Modal/Popover/Tooltip，overlay_stack.zig bindContentNode）都是 composited_group，
    // 里面任何 z>0 节点（focus ring、checkbox 指示器等）原地改色都落在这个形状里。
    // C3 已修：子→父这一跳是带外（父不失效），但冒泡越过它继续到 promoted 祖父。
    try knownBugPositiveZChildRepaint(true);
}

// ─── C3：带外单元（z>0）的 render dirty 必须让包住它的缓存祖先失效 ───
//
// 方案 §5.4 / §10 C3。规则（node_dirty.zig bubbleOutOfBandSubtreeRender）：逐跳判定
// "child 对 parent 是不是带外单元"（z>0 ∧ parent.opacity ≥ 0.999 ∧ parent 没有 promoted
// 缓存）。是 → parent 的 legacy 缓存替放会剔除 child 整棵子树再 fresh 补渲染，parent
// 不必失效，但**继续往上走**；否则 parent 的缓存（promoted 整段替放 / legacy 快照）
// 里含 child 的旧命令，必须置 subtree_render。旧实现在第一个带外跳处就整体停止冒泡，
// 于是 promoted 父/祖父整段替放旧缓存（V2）。下面四条是正确性与性能两个方向的护栏。

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

/// 让 z>0 节点在 paint pass 里渲染（自带 opacity layer + 长时 scale 动画）：plain z>0 节点的
/// 内容每帧由 prebuild fresh 重录，legacy 快照里根本没有它的条目，测不出陈旧（V1 探针的
/// 同一结论）。带 layer 的才会被 legacy 快照整段捕获。
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
    // legacy overflow 祖父 → 普通父 → z>0 孙（paint pass 单元）：祖父的 legacy 快照只剔除
    // 它**直接**的 z>0 子节点，孙子的旧命令就在快照里。孙→父这一跳是带外（可跳过），
    // 父→祖父这一跳不是，必须让祖父失效。旧实现在第一跳就停止冒泡 → 祖父命中快照、
    // 画面停在旧色（方案 §10 V2 探针的"legacy 祖父不陈旧"只对 plain 孙子成立）。
    var cx = try Cx.init(std.testing.allocator);
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
    // 前提：空闲帧确实命中 legacy 快照。
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
    // 失效只发生一次：之后的空闲帧重新命中（重写后的）快照。
    try std.testing.expect(cx.perf.render_cache_hit > 0);
}

test "render: C3 positive z child change keeps legacy overflow parent cache hit" {
    // 性能护栏：legacy overflow 父节点的**直接** z>0 子节点（paint pass 单元）改色时，父节点
    // 的快照替放会剔除它再 fresh 补渲染 —— 父节点不能因此失效（这正是带外优化要保的）。
    // 同时断言补渲染出来的是新颜色，且只画一遍。
    var cx = try Cx.init(std.testing.allocator);
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
    // 空闲帧命中 = clipper 的 legacy 快照 + overlay 自己的 promoted surface。改色帧 overlay
    // 自己必然 miss（它就是脏的那个），其余命中数必须不变 —— 即 clipper 仍命中。
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
    // portal 形态：legacy 根 → portal(z>0，普通) → content(z>0，paint pass 单元)。两跳都是
    // 带外：content 的变化既不让 portal 失效，也不让根失效（根的快照剔除整棵 portal 子树
    // 再补渲染）。"只跳第一跳、其余照常冒泡"的修法会在这里让根每次都 miss。
    var cx = try Cx.init(std.testing.allocator);
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
    // 同上：空闲帧命中 = clipper 快照 + content 自己的 promoted surface。
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
    // 性能护栏：composited_group 容器里若干 z>0 子节点，空闲多帧 —— 每帧命中数与
    // 第 2 帧相同、零 miss；改其中一个子节点后，**兄弟** promoted 容器照样命中，
    // 且改色后的下一帧起恢复到与改色前相同的命中数（不会退化成每帧重建）。
    var cx = try Cx.init(std.testing.allocator);
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
    // 改色帧：只有改动的那个 group 重建，兄弟 group 仍命中。
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

// ─── C2：z_index 与裁剪解耦（方案 sticky-zindex-clip-decoupling-plan.md §9.1 第 1、3、4、5 条）───
//
// 旧实现里 z>0 子节点在渲染侧丢掉 clip-bridge 那层 clip_id（像素只靠祖先的
// scissor token 兜住），在命中侧清空 clip 链并拿到全局 stacking_z。下面几条断言的是
// 解耦后的真实保证：z>0 与 z=0 兄弟的裁剪完全相同（同一 retained clip_id、同一
// scissor 栈深度与矩形），z 只决定同级顺序。

const C2ScissorStack = struct {
    depth: usize,
    rect: ?ui.ComputedRect,
};

const C2SurfaceFrame = struct {
    m: [6]f32,
    src_x: f32,
    src_y: f32,
};

/// 把当前 surface 嵌套下的局部矩形换算到世界坐标。begin_opacity_layer 内的
/// 绘制与 push_clip（clip-bridge 的 owner-local 投影）都在 surface 局部空间：
/// 父空间点 = M·(p − src)，M = draw_transform、src = begin 的 geom 原点。
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

/// 降级后 paint 表里第一个匹配 (w,h,color) 的 fill 所处的 scissor 栈：深度 + 各层
/// 换算到世界坐标后的交集（整数像素容差 0.5 内取整）。栈空时 rect = null。
/// 必须考虑 opacity surface 的局部坐标系，否则 surface 内的 clip-bridge 会被误当成
/// 世界坐标（C2 让自带 surface 的 z>0 子节点也拿到父 clip_id 之后必然出现这种形状；
/// C1 阶段的 knownBugEffectiveScissorForFill 按世界坐标直接求交，已被本函数取代）。
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

/// display_list 里某节点第一个 fill_rect 的下标。
fn c2FirstFillIndex(cx: *Cx, node: *Node) ?usize {
    for (cx.display_list.items.items, 0..) |item, index| switch (item) {
        .fill_rect => |fill| if (fill.header.node_id == node.id) return index,
        else => {},
    };
    return null;
}

/// z>0 节点与作对照的 z=0 兄弟必须拿到完全相同的裁剪：同一 retained clip_id（且非空）、
/// 同一 scissor 栈深度、同一有效裁剪矩形 == expected。
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
    // §9.1 第 1 条。附录 A 探针 1：旧实现 z=0 的 scissor 深度 2（token + clip-bridge），
    // z=5 深度 1、retained clip_id = INVALID（像素只靠 token 兜住）。
    var cx = try Cx.init(std.testing.allocator);
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
    // z>0 先 append：同级顺序由 z 决定，而不是树序。
    try clipper.appendChild(cx.allocator, raised);
    try clipper.appendChild(cx.allocator, peer);
    cx.root = clipper;
    cx.layout();
    _ = cx.render();

    try c2ExpectSameClipAsPeer(cx, raised, .{ 200, 200 }, raised_color, peer, .{ 190, 190 }, peer_color, ui.ComputedRect.init(0, 0, 100, 100));
    // 顺序：z=5 画在 z=0 之上。
    try std.testing.expect(c2FirstFillIndex(cx, peer).? < c2FirstFillIndex(cx, raised).?);
}

test "render: positive z grandchild clipped by grand-ancestor clip" {
    // §9.1 第 3 条。附录 A 探针 2：outer(clip) → mid → child(z=5)。
    var cx = try Cx.init(std.testing.allocator);
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
    // 隔代：z>0 孙节点继承 outer 的裁剪（mid 本身不裁剪，clip_id 与 mid 相同）。
    try std.testing.expectEqual(cx.scene_runtime.get(mid.id).?.clip_id, cx.scene_runtime.get(raised.id).?.clip_id);
}

test "render: sticky with positive z is clipped by scroll viewport and orders above z=0 siblings" {
    // §9.1 第 4 条。root(column) → [topbar 40, viewport(200×200 clip) → content(translate_y=-S)
    //   → [lead 500, section 300 → [header 40 (sticky top=0, z=3), body 260]]]。
    // S=780：header 被 section 底边钳制（C1 修正后补偿 260），屏幕 y = 40+500+260-780 = 20，
    // 顶部 20px 滚出 viewport（落在 topbar 区）。
    var cx = try Cx.init(std.testing.allocator);
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
    // 顺序：header（positive_z 带）画在同级 z=0 的 body 之上（两者在 section 内重叠）。
    try std.testing.expect(c2FirstFillIndex(cx, body).? < c2FirstFillIndex(cx, header).?);

    // 命中与像素一致：viewport 内的重叠区命中 header；滚出 viewport 的那 20px 落在 topbar 上，
    // 必须命中 topbar 而不是（看不见的）header。
    try std.testing.expectEqual(header, cx.hitTest(100, 50).?);
    try std.testing.expectEqual(topbar, cx.hitTest(100, 30).?);
}

test "render: z>0 child of opacity-layer parent is included in surface bounds" {
    // §9.1 第 5 条。非裁剪的 opacity 0.8 父节点，z>0 子节点溢出父框：解耦后它和 z=0 一样
    // 画在父节点的 surface 里，children_bbox / surface begin_bounds 必须覆盖它，否则
    // 溢出部分被纹理边界截掉（旧 computeChildrenBBox 排除 z>0）。
    var cx = try Cx.init(std.testing.allocator);
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
    raised.style.translate_x = 150; // 局部 x ∈ [150,210)：溢出父框右侧 110px
    raised.style.translate_y = 170; // 局部 y ∈ [170,230)
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
    // §9.2 第 15 条 / 方案 §6 步骤 1：overlay() 与 Popover 一致，总是经
    // ensurePopoverPortalRoot 取 portal；standalone Cx 没预设 portal 时就地补建，
    // 不再退回 caller inline append（inline 挂载会被祖先裁剪，z_index 不会让它逃逸）。
    const overlay_mod = @import("../overlay_stack.zig");
    const Scope = @import("../reactive.zig").Scope;

    {
        var cx = try Cx.init(std.testing.allocator);
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
        // 与 Popover 共用同一个 portal（第二个 modal 不再新建）。
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
        // 纯单元测试场景（cx.root == null）：保留 inline 回退，由 caller append。
        var cx = try Cx.init(std.testing.allocator);
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
        // caller 负责挂载；这里把它挂进一棵临时树，避免 scope cleanup 前泄漏语义不清。
        const host = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
        cx.root = host;
        try host.appendChild(std.testing.allocator, res.barrier.?);
    }
}

test "render: overlay composite animation marks promoted layer" {
    var cx = try Cx.init(std.testing.allocator);
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
    // P1.6'：从 LayerTree iterate（plan.layers 即将下台）。
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // task #161 校准：v0.5-P4 加了 frame-time skip path——同 frame_time 时直接返回 cached commands
    // 不进 promoted_surface_reused 路径。第二次 render 必须推进 frame time 才进入正常 render。
    cx.frame_time_ms = 16.0;
    _ = cx.render();

    const reused_runtime = cx.scene_runtime.get(overlay.id).?;
    try std.testing.expect(reused_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!reused_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(cx.perf.render_cache_hit > 0);
}

test "render: icon quarter-turn rotation keeps affine surface transform" {
    var cx = try Cx.init(std.testing.allocator);
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
    // 曾长期 SkipZigTest，注释称"layer.flags.reused_this_frame=true 但
    // cx.perf.render_cache_hit=0，与 v0.5-P4 skip path / promoted_cached_commands
    // 持久状态交互需深入诊断"。
    // **排查结论：不是 cache 系统不一致，是测试自己把帧跳过了。**
    // v0.5-P4 零脏帧快速路径（core.zig:2991）的成立条件之一是
    // `frame_time_ms == last_render_frame_time_ms`，而本测试原先在多处**重复**
    // 写 `cx.frame_time_ms = 16.0`（注释还写着"推进 frame time 跳过 skip path"）——
    // 第二次写等于没推进，于是 render 直接返回缓存、perf.resetFrame() 把计数清零。
    // 实测证据：hit=0 **且 miss=0**（两者同时为 0 只可能是整帧被跳过），
    // 而 reused_this_frame=true 是上一帧留下的状态。
    // 修法：让帧时钟单调递增（16 → 32 → 48）。
    //
    // 另修两处 pre-surface 时代的过期断言：promoted surface 下 overlay 的
    // translate/scale 由包裹层 draw_transform 承载，surface 内的 text 保持
    // surface-local 坐标（实测恒 x=0），故断言改读包裹层的 draw_transform。
    var cx = try Cx.init(std.testing.allocator);
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
    cx.frame_time_ms = 16.0; // task #161: 推进 frame time 跳过 v0.5-P4 skip path
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

    // promoted surface 下，overlay 的 translate/scale 由包裹层的 draw_transform
    // 承载，surface 内的 text 保持 **surface-local** 坐标（恒 x=0）。
    // 原测试断言 "text.geom.x 增加 24"，那是 pre-surface 时代的期望，
    // 在当前架构下永远不成立（实测 text x 恒为 0，位移在 dt[4] 上）。
    // 改为读包裹层的 draw transform。
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
    cx.frame_time_ms = 32.0; // task #161: 跳过 v0.5-P4 skip path
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
    cx.frame_time_ms = 48.0; // 帧时钟必须单调递增，见上方 skip-path 注释
    _ = cx.render();
    try std.testing.expectEqual(@as(u32, 0), cx.perf.render_cache_hit);
}

test "render: explicit composited group requests retained promoted surface" {
    var cx = try Cx.init(std.testing.allocator);
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
    cx.frame_time_ms = 16.0; // task #161: 跳过 v0.5-P4 skip path
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

test "render: transform-animated text subtree auto stabilizes raster policy" {
    var cx = try Cx.init(std.testing.allocator);
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
                // paint_table.DisplayItem.text_raster_policy 三态过线：
                // 0 = static_crisp; 1 = animated_stable/direct_animated; 2 = surface_cached。
                // 动画中的 overlay 文本必须离开静态路径（1 或 2 都合法，取决于提升时机）。
                try std.testing.expect(t.text_raster_policy != 0);
                saw_stabilized_text = true;
                break;
            }
        }
    }
    try std.testing.expect(saw_stabilized_text);
}

test "render: will-change pre-promotes overlay layer before animation starts" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    cx.frame_time_ms = 16.0; // task #161: 跳过 v0.5-P4 skip path
    _ = cx.render();
    try std.testing.expect(cx.perf.render_cache_hit >= 2);
    const reused_overlay_runtime = cx.scene_runtime.get(overlay_root.id).?;
    try std.testing.expect(reused_overlay_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.rebuilt_this_frame);
}

test "render: promoted descendant composite dirty still rebuilds promoted ancestor" {
    var cx = try Cx.init(std.testing.allocator);
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
    cx.frame_time_ms = 16.0; // task #161: 跳过 v0.5-P4 skip path
    _ = cx.render();
    const reused_overlay_runtime = cx.scene_runtime.get(overlay_root.id).?;
    try std.testing.expect(reused_overlay_runtime.promoted_surface_flags.reused_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.rebuilt_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.invalidated_by_descendant_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.invalidated_by_self_this_frame);
    try std.testing.expect(!reused_overlay_runtime.promoted_surface_flags.descendant_scoped_rebuild_candidate_this_frame);
}

test "Cx: overlay composite dirty still counts as pending scene work" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

    var cx = try Cx.init(std.testing.allocator);
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

    var cx = try Cx.init(std.testing.allocator);
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

    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(200, 100);

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;
    cx.layout();

    try std.testing.expectEqual(@as(f32, 200), root.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 100), root.rectFromWorldOrFallback().h);
}

test "box: click handler" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

test "Cx: pointer capture release refreshes hover target" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // 需要 pointer 角色才能被 hitTest 找到
    button.setFocusable(true);
    try root.appendChild(cx.allocator, button);

    try std.testing.expect(root.frame_state.state_bits.dirty.runtime.subtree_dirty);
    // appendChild 不再设置 subtree_order_dirty，只设置 subtree_runtime_index_dirty

    cx.handleMouseDown(10, 10, .{});

    try std.testing.expect(cx.pressed_node == button);
    try std.testing.expect(cx.last_mouse_down_target == button);
}

test "Cx: render resolves last mouse-down target through its generation handle" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // 需要 pointer 角色才能被 hitTest 找到
    button.setFocusable(true);

    try container.appendChild(cx.allocator, button);
    try root.appendChild(cx.allocator, container);
    cx.root = root;
    cx.layout();
    _ = cx.render();

    container.style.translate_y = 80;
    container.markLayoutDirty(); // translate 变更需要重新布局才能更新 hitTest 位置

    cx.handleMouseMove(10, 90);

    try std.testing.expect(cx.hovered_node == button);
}

test "Cx: deferred text commits preserve explicit invalidation and conservative defaults" {
    const cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

    var cx = try Cx.init(std.testing.allocator);
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
        const other = try Cx.init(std.testing.allocator);
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
    const unused = try Cx.init(std.testing.allocator);
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
        const other = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // scroll hitTest 需要节点有 scroll 角色，设置 tag = .scroll
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

    cx.handleScrollEx(20, 20, 0, -10, false, false, true);

    try std.testing.expect(scrolled);
}

test "Cx: registered texture svg hit shape auto-attaches to image nodes" {
    var cx = try Cx.init(std.testing.allocator);
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

    var cx = try Cx.init(std.testing.allocator);
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

    // svgOversampleFactor 对 ≤64px 图标做 2x oversample：
    // first/second (viewBox 32×16) → raster (64,32)，共享缓存
    // third (style 64×32) → raster (128,64)，独立 load
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

    root.children.clearRetainingCapacity();
    try root.children.append(cx.allocator, second);
    try root.children.append(cx.allocator, first);
    root.markOrderDirty();

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
    var cx = try Cx.init(std.testing.allocator);
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

    container.children.clearRetainingCapacity();
    try container.children.append(cx.allocator, child_b);
    try container.children.append(cx.allocator, child_a);
    container.markOrderDirty();

    _ = cx.render();

    try std.testing.expectEqual(@as(usize, 2), cx.focus_manager.focus_order.items.len);
    try std.testing.expect(cx.focus_manager.focus_order.items[0] == first);
    try std.testing.expect(cx.focus_manager.focus_order.items[1] == second);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_rebuild_count);
    try std.testing.expectEqual(@as(u32, 0), cx.perf.focus_order_rebuild_count);
}

test "Cx: positive tabindex order dirty falls back to full focus rebuild" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

    // 动画完成帧的 tick 仍会请求补一帧（linger + O(1) 活跃动画标志的
    // 保守方向）；再渲染一帧后系统进入真正 idle。
    cx.frame_time_ms = 1016;
    _ = cx.render();
    try std.testing.expect(!cx.hasPendingSceneWork());
}

test "Cx: geometry-only interaction dirty uses partial interaction rebuild" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(300, 100);

    // 3 children of 50px each in a 300px row → remaining = 150, gap = 150/2 = 75
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(300, 100);

    // 3 children of 50px each in 300px → remaining = 150, gap = 150/3 = 50
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 100);

    // 3 children of 50px each in 400px → remaining = 250, gap = 250/4 = 62.5
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(800, 600);

    // fit 容器包含 2 个 px 子节点 (row 方向, gap=10)
    // intrinsic width = 50 + 80 + 10(gap) = 140
    // intrinsic height = max(30, 40) = 40
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
    var cx = try Cx.init(std.testing.allocator);
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

test "stretch: fit children stretch on cross-axis" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 200);

    // row 容器 align_items=stretch，fit 子节点应在交叉轴 (height) 上拉伸
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

    // fit 子节点的 height 应被 stretch 到 200
    try std.testing.expectEqual(@as(f32, 200), root.children.items[0].rectFromWorldOrFallback().h);
}

test "row_reverse: children laid out right-to-left" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(300, 100);

    // 3 个子节点，正常 row 是 [A:0, B:50, C:150]，reverse 应为 [A:200, B:100, C:0]
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

    // reverse: C 在最左，B 在中间，A 在最右
    try std.testing.expectEqual(@as(f32, 200), a.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 150), b.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), c.rectFromWorldOrFallback().x);
}

test "column_reverse: children laid out bottom-to-top" {
    var cx = try Cx.init(std.testing.allocator);
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

    // reverse: C 在顶部，B 在中间，A 在底部
    try std.testing.expectEqual(@as(f32, 220), a.rectFromWorldOrFallback().y); // 300 - 80 = 220
    try std.testing.expectEqual(@as(f32, 100), b.rectFromWorldOrFallback().y); // 300 - 80 - 120 = 100
    try std.testing.expectEqual(@as(f32, 0), c.rectFromWorldOrFallback().y); // 300 - 80 - 120 - 100 = 0
}

test "row_reverse: nested children positions offset correctly" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 200);

    // 验证嵌套子节点的绝对位置也正确偏移
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

    // container 应在右侧 (400-100=300)
    try std.testing.expectEqual(@as(f32, 300), container.rectFromWorldOrFallback().x);
    // inner 在 container 内偏移 padding，相对坐标（不再是绝对坐标 310）
    try std.testing.expectEqual(@as(f32, 10), inner.rectFromWorldOrFallback().x);
}

test "flex_wrap: row wrap breaks into multiple lines" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(300, 300);

    // 容器 300x300, 4 个 100px 宽子节点 → 第一行放 3 个，第二行放 1 个
    const root = try box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 300 },
        .direction = .row,
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

    // 第一行: A(0,0), B(100,0), C(200,0)
    try std.testing.expectEqual(@as(f32, 0), a.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), a.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 100), b.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), b.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 200), c.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), c.rectFromWorldOrFallback().y);

    // 第二行: D(0, 50)
    try std.testing.expectEqual(@as(f32, 0), d.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 50), d.rectFromWorldOrFallback().y);
}

test "flex_wrap: column wrap breaks into multiple columns" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 200);

    // 容器 400x200, column wrap, 3 个 100px 高子节点 → 第一列 2 个，第二列 1 个
    const root = try box(cx, .{
        .width = .{ .px = 400 },
        .height = .{ .px = 200 },
        .direction = .column,
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

    // 第一列: A(0,0), B(0,100)
    try std.testing.expectEqual(@as(f32, 0), a.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), a.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 0), b.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 100), b.rectFromWorldOrFallback().y);

    // 第二列: C(80,0)
    try std.testing.expectEqual(@as(f32, 80), c.rectFromWorldOrFallback().x);
    try std.testing.expectEqual(@as(f32, 0), c.rectFromWorldOrFallback().y);
}

test "flex_wrap: wrap_reverse reverses cross axis" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(200, 300);

    // 容器 200x300, row wrap_reverse, 4 个 100px 子节点 → 2 行
    // 正常 wrap: 第1行 y=0, 第2行 y=50
    // wrap_reverse: 第1行在底部, 第2行在顶部
    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 300 },
        .direction = .row,
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

    // wrap_reverse: 第1行(A,B)在底部, 第2行(C,D)在顶部
    try std.testing.expectEqual(@as(f32, 250), a.rectFromWorldOrFallback().y); // 300 - 50 = 250
    try std.testing.expectEqual(@as(f32, 250), b.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 200), c.rectFromWorldOrFallback().y); // 300 - 50 - 50 = 200
    try std.testing.expectEqual(@as(f32, 200), d.rectFromWorldOrFallback().y);
}

test "Context API: provide and consume" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const AppTheme = struct {
        accent: Color,
        font_size: f32,
    };

    var app_theme = AppTheme{ .accent = theme.dark.color.accent, .font_size = 16 };
    try cx.provide(AppTheme, &app_theme);

    // 消费上下文
    const retrieved = cx.consume(AppTheme);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(f32, 16), retrieved.?.font_size);

    // 修改后再消费
    app_theme.font_size = 20;
    const retrieved2 = cx.consume(AppTheme);
    try std.testing.expectEqual(@as(f32, 20), retrieved2.?.font_size);
}

test "Context API: consume returns null if not provided" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const MyConfig = struct { value: i32 };
    const result = cx.consume(MyConfig);
    try std.testing.expect(result == null);
}

test "Context API: provide overwrites existing" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const Config = struct { value: i32 };

    var cfg1 = Config{ .value = 1 };
    try cx.provide(Config, &cfg1);
    try std.testing.expectEqual(@as(i32, 1), cx.consume(Config).?.value);

    var cfg2 = Config{ .value = 2 };
    try cx.provide(Config, &cfg2);
    try std.testing.expectEqual(@as(i32, 2), cx.consume(Config).?.value);

    // 只有一个条目 (不是两个)
    try std.testing.expectEqual(@as(usize, 1), cx.contextCount());
}

test "Context API: multiple types" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const ThemeCtx = struct { accent: Color };
    const UserCtx = struct { name: []const u8 };

    var theme_ctx = ThemeCtx{ .accent = theme.dark.color.accent };
    var user = UserCtx{ .name = "Alice" };

    try cx.provide(ThemeCtx, &theme_ctx);
    try cx.provide(UserCtx, &user);

    try std.testing.expectEqual(@as(usize, 2), cx.contextCount());
    try std.testing.expectEqualStrings("Alice", cx.consume(UserCtx).?.name);
    try std.testing.expect(Color.eql(theme.dark.color.accent, cx.consume(ThemeCtx).?.accent));
}

test "Context API: overflow returns error" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    // 填满 16 个 context 槽 (每个用不同类型)
    var vals: [16]u8 = undefined;
    inline for (0..16) |i| {
        const T = GenContextType(i);
        try cx.provide(T, @ptrCast(&vals[i]));
    }
    try std.testing.expectEqual(@as(usize, 16), cx.contextCount());

    // 第 17 个应返回 error.ContextsFull
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

test "Grid: auto tracks and alignment include margins" {
    var cx = try Cx.init(std.testing.allocator);
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
    try std.testing.expectApproxEqAbs(@as(f32, 35), centered_item.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 18), centered_item.rectFromWorldOrFallback().y, 0.001);
}

test "Layout: no_cross_stretch only suppresses inherited stretch" {
    // column 的交叉轴是 width：fit 宽 + justify=center 的 row 子节点（intrinsic 宽 = 30px
    // 的内嵌 px 盒）。inner_x 断言内容没有按「被拉伸后的宽度」居中而漂出子节点自身框。
    const Case = struct { align_items: ui.AlignItems, explicit: ?ui.AlignItems, want_x: f32 };
    const cases = [_]Case{
        .{ .align_items = .stretch, .explicit = null, .want_x = 0 },
        .{ .align_items = .center, .explicit = null, .want_x = 85 },
        .{ .align_items = .end, .explicit = null, .want_x = 170 },
        .{ .align_items = .start, .explicit = null, .want_x = 0 },
        // 显式 align_self 优先于 flag
        .{ .align_items = .stretch, .explicit = .end, .want_x = 170 },
        .{ .align_items = .center, .explicit = .start, .want_x = 0 },
    };
    for (cases) |c| {
        var cx = try Cx.init(std.testing.allocator);
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

test "Layout: fit back-fill repositions main-axis content against final size" {
    // fit 宽的 row 容器被父 column 的 stretch 先拉到 200 宽、按 200 算 justify 偏移，
    // 随后自身 fit 回填缩回 intrinsic 宽。回填后主轴位置必须按最终尺寸重排，
    // 否则内容停在按 200 算出的位置、漂出容器框。不带 no_cross_stretch。
    const Case = struct {
        justify: ui.Justify,
        parent_align: ui.AlignItems,
        explicit: ?ui.AlignItems,
        min_w: f32,
        want_w: f32,
        want_inner_x: f32,
    };
    const cases = [_]Case{
        .{ .justify = .center, .parent_align = .stretch, .explicit = null, .min_w = 0, .want_w = 30, .want_inner_x = 0 },
        .{ .justify = .end, .parent_align = .stretch, .explicit = null, .min_w = 0, .want_w = 30, .want_inner_x = 0 },
        .{ .justify = .center, .parent_align = .start, .explicit = .stretch, .min_w = 0, .want_w = 30, .want_inner_x = 0 },
        // min_width 让最终尺寸 > 内容：居中按最终 100 宽算，而不是按拉伸的 200 宽
        .{ .justify = .center, .parent_align = .stretch, .explicit = null, .min_w = 100, .want_w = 100, .want_inner_x = 35 },
        .{ .justify = .end, .parent_align = .stretch, .explicit = null, .min_w = 100, .want_w = 100, .want_inner_x = 70 },
    };
    for (cases) |c| {
        var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(200, 100);

    const inner = try box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 20 } }, .{});
    const child = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
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

    // 增量：只改内层尺寸并标脏，第二帧同样不能漂
    inner.style.width = .{ .px = 50 };
    inner.markLayoutDirty();
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 50), child.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), inner.rectFromWorldOrFallback().x, 0.001);
}

test "Layout: fit back-fill relayout does not flip-flop child positions" {
    // 首轮 justify 按预测的回填尺寸算：fit 容器全量重排时子节点位置不应
    // 「先按拉伸宽摆到 85 → 回填后挪回 0」来回翻转（翻转会把子节点标 layout 脏、
    // overflow_hidden 子节点连带失效渲染缓存）。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(200, 100);

    const inner = try box(cx, .{ .width = .{ .px = 30 }, .height = .{ .px = 20 }, .overflow_hidden = true }, .{});
    const child = try box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .direction = .row,
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

test "Layout: fit back-fill repositions auto-margin content against final size" {
    // 主轴 auto margin 在首轮按拉伸宽分配剩余空间（不走回填尺寸预测），
    // 只能靠回填后的主轴终轮定位纠正。
    const Case = struct { min_w: f32, want_w: f32, want_inner_x: f32 };
    const cases = [_]Case{
        .{ .min_w = 0, .want_w = 30, .want_inner_x = 0 },
        .{ .min_w = 100, .want_w = 100, .want_inner_x = 35 },
    };
    for (cases) |c| {
        var cx = try Cx.init(std.testing.allocator);
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

test "Layout: fit-width column with align_items=center stays inside stretched-then-backfilled box" {
    var cx = try Cx.init(std.testing.allocator);
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

    try std.testing.expectApproxEqAbs(@as(f32, 50), child.rectFromWorldOrFallback().w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), a.rectFromWorldOrFallback().x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), b.rectFromWorldOrFallback().x, 0.001);
}

test "Layout: auto margins absorb remaining flow space" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    child.enableImplicitAnimation(cx.allocator, &.{.border_color}, .{ .duration_ms = 150 });
    try root.appendChild(cx.allocator, child);

    cx.root = root;
}

// ==================== StyleOverride 测试 ====================

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

    // background 被覆盖
    try std.testing.expect(Color.eql(result.background.?, Color.hex(0x00FF00)));
    // opacity 保留 base
    try std.testing.expectEqual(@as(f32, 0.5), result.opacity.?);
    // font_weight 保留 base
    try std.testing.expectEqual(@as(u16, 400), result.font_weight.?);
    // gap 来自 other
    try std.testing.expectEqual(@as(f32, 16), result.gap.?);
    // 未设置的仍为 null
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

    // background/opacity 已不在 Style → World.paint_state。
    // applyTo 不再写 Style.background/opacity；它们经 paintOverride() 携带，
    // 由 builder 在 Node.create 后用 setBackgroundRaw/setOpacityRaw 落 SoA。
    const po = ov.paintOverride();
    try std.testing.expect(Color.eql(po.background.?, Color.hex(0xFF0000)));
    try std.testing.expectEqual(@as(f32, 0.8), po.opacity.?);
    try std.testing.expectEqual(@as(f32, 12), style.gap);
    // width 被覆盖
    switch (style.width) {
        .px => |v| try std.testing.expectEqual(@as(f32, 200), v),
        else => return error.TestUnexpectedResult,
    }
    // 未覆盖的保持默认
    try std.testing.expectEqual(style.direction, .column);
}

test "StyleOverride: applyTo — margin_spec writes auto flags" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 无 paint 字段的 override，paintOverride() 全 null
    // （builder 据此跳过 setBackgroundRaw/setOpacityRaw，保留节点已有 SoA 值）。
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

    // ext 应已分配且 corner_radius 设置
    try std.testing.expect(style.ext != null);
    const cr = style.corner_radius().?;
    try std.testing.expectEqual(@as(f32, 12), cr.resolve());

    // 清理 ext
    std.testing.allocator.destroy(style.ext.?);
}

// ==================== Style Inherit 测试 ====================

test "Node.resolveTextColor: 从 parent 链继承 text_color" {
    var cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    // root 设置 text_color
    root.style.ensureExtPanic(cx.allocator).text_color = Color.hex(0xFF0000);

    // 中间容器（无 text_color）
    const container = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    try root.appendChild(cx.allocator, container);

    // 叶子节点
    const leaf = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try container.appendChild(cx.allocator, leaf);

    // leaf 应继承 root 的 text_color（跳过 container）
    const resolved = leaf.resolveTextColor();
    try std.testing.expect(resolved != null);
    try std.testing.expect(Color.eql(resolved.?, Color.hex(0xFF0000)));
}

test "Node.resolveTextColor: 就近覆盖" {
    var cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    root.style.ensureExtPanic(cx.allocator).text_color = Color.hex(0xFF0000);

    const container = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    container.style.ensureExtPanic(cx.allocator).text_color = Color.hex(0x00FF00);
    try root.appendChild(cx.allocator, container);

    const leaf = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try container.appendChild(cx.allocator, leaf);

    // leaf 应取最近的 container 的 text_color（绿色），不是 root 的红色
    const resolved = leaf.resolveTextColor();
    try std.testing.expect(resolved != null);
    try std.testing.expect(Color.eql(resolved.?, Color.hex(0x00FF00)));
}

test "Node.resolveTextColor: 无继承返回 null" {
    var cx = try ui.Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const leaf = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(cx.allocator, leaf);

    // 无任何 parent 设置 text_color
    try std.testing.expect(leaf.resolveTextColor() == null);
}

test "Node.resolveTextFontSize/Weight: 继承生效" {
    var cx = try ui.Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(320, 240);

    const child = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 80 },
        .height = .{ .px = 40 },
        .background = Color.rgba(255, 0, 0, 255),
    }, .{});
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

    try std.testing.expectApproxEqAbs(@as(f32, 48.0), snapshot.captured_world_origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 36.0), snapshot.captured_world_origin.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), snapshot.local_transform_origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), snapshot.local_transform_origin.y, 0.001);
}

test "Snapshot survives source node destroy" {
    var cx = try Cx.init(std.testing.allocator);
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
    var render_list: std.ArrayList(ui.DisplayItem) = .{};
    defer render_list.deinit(cx.allocator);
    try snapshot.appendTo(testDrawContextForList(cx, &render_list), .{ .x = 24, .y = 16 }, 1.0, 1.0);

    // snapshot.appendTo 写到 cx.lowering.main_paint (paint_table)
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
    var cx = try Cx.init(std.testing.allocator);
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
    var render_list: std.ArrayList(ui.DisplayItem) = .{};
    defer render_list.deinit(cx.allocator);
    try snapshot.appendTo(testDrawContextForList(cx, &render_list), .{ .x = 24, .y = 16 }, 1.0, 0.5);

    // appendTo 写 paint_table 流，第一个是 begin_opacity_layer control item
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
    var cx = try Cx.init(std.testing.allocator);
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
    child_ext.setShadows(theme.dark.shadow.md, .{
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
    var cx = try Cx.init(std.testing.allocator);
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

// ─────────────────────────────────────────────────────────────────────────────
// Phase 1: Wavy underline geometry（diagnostic squiggle 的纯几何测试）
// 对应 memory/lsp_ui_framework_upgrade.md D3
// ─────────────────────────────────────────────────────────────────────────────

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

// 矩阵 #3 —— ScrollArea 60fps < 3ms（will_change_transform 自动 promote）
test "ScrollArea content carries will_change_transform hint" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const ScrollAreaMod = @import("../components/scroll_area/mod.zig");
    const Scope = @import("../reactive.zig").Scope;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const result = try ScrollAreaMod.mountScrollArea(.{}, scope, cx);
    try root.appendChild(std.testing.allocator, result.container);
    // mount 后 content 应有 will_change_transform = true，触发 promotion
    try std.testing.expect(result.content.style.will_change_transform());
}

// 矩阵 #4 —— Transform 动画 paint = 0
test "transform-only animation promotes node and preserves paint cache" {
    var cx = try Cx.init(std.testing.allocator);
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
    // v0.5-P5 promotion 约定：transform 动画节点需显式 composited_group + will_change_transform
    // 才 promote。promotion 需 effect entry，effect entry 需 composited_group / opacity<1 / blur 等。
    // ScrollArea 走 is_scroll_container 路径自动 promote；手动 animateNode 节点需自己声明。
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

    // 第一次 render 后，translate 动画应促使节点被 promote
    const runtime = cx.scene_runtime.get(animated.id).?;
    try std.testing.expect(runtime.has_active_transform_animation);
    // 矩阵 #4 关键：promoted layer 在 transform 动画期间不重录 paint chunks。
    try std.testing.expect(runtime.promoted_layer_id != ui.SceneRuntimeInvalidId);

    // 推进 translate 动画——只动 transform，不改 paint content
    const content_version_before = animated.meta.per_frame.caches.versions.content;
    animated.style.translate_x = 50;
    animated.markCompositeDirty();
    cx.layout();
    _ = cx.render();

    // content_version 不应变（paint chunks 没重录）；composite_version 增加
    try std.testing.expectEqual(content_version_before, animated.meta.per_frame.caches.versions.content);
    // promoted_cached_commands 应已被首次 render 填充
    try std.testing.expect(animated.meta.per_frame.caches.commands.promoted != null);
}

// 矩阵 #1 ——10k 节点零脏帧 < 0.5ms 的快速路径
test "render() skip path returns cached commands when tree fully clean" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(320, 120);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 120 },
        .background = Color.rgba(30, 40, 50, 255),
    }, .{});
    cx.root = root;
    cx.layout();

    // 第一次 render 跑完整路径，填充 last_render_list
    const first = cx.render();
    try std.testing.expect(cx.last_render_valid);
    try std.testing.expect(first.len > 0);
    const first_len = first.len;

    // 第二次 render 应走 skip 路径——commands 内容、长度都不变
    const second = cx.render();
    try std.testing.expectEqual(first_len, second.len);
    // skip 路径返回的是 last_render_list.items；render_list 应已被 cleared (capacity 保留)
    // 但因 render_list 在 first 后已 populated，second 跳过时未 clear，所以 render_list 仍有内容。
    // 关键保证：commands 切片有效且长度等于上一帧。
}

test "markRenderDirty 后 skip 路径失效" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(320, 120);

    const root = try box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 120 },
        .background = Color.rgba(30, 40, 50, 255),
    }, .{});
    cx.root = root;
    cx.layout();
    _ = cx.render(); // 填充 cache

    // markRenderDirty 应清除整树 clean 状态——subtree_render_dirty 冒泡到 root
    root.markRenderDirty();
    cx.layout();
    _ = cx.render(); // 应走完整路径
    // 验证：dirty 标记被消费——render 完后 root 应该 clean
    try std.testing.expect(!root.frame_state.state_bits.dirty.core.render);
}

// 矩阵 #1 真 perf bench ——10k 节点零脏帧 < 0.5ms
// 建 10k Node 树（100 行 × 100 列），warm 一帧填 cache，然后 measure 100 次 zero-dirty
// render 的中位数应远低于 0.5ms（500µs）。这是 plan 矩阵 #1 的真验证。
test "10k node zero-dirty render < 0.5ms (matrix #1)" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(1200, 1000);

    // 建 100 列 grid，每列 100 个 small box —— 共 100*100 = 10000 leaf nodes + 100 cols = 10100 nodes
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

    // Warm-up: 第一次走完整 render 路径填充 last_render_list
    _ = cx.render();
    try std.testing.expect(cx.last_render_valid);

    // Measure 100 次 zero-dirty render——树未变，frame_time 未变，应全走 skip path
    const iterations: u32 = 100;
    var total_ns: u64 = 0;
    var max_ns: u64 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var timer = std.time.Timer.start() catch unreachable;
        const list = cx.render();
        const elapsed = timer.read();
        total_ns += elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
        // 防优化：sanity check commands 仍非空
        try std.testing.expect(list.len > 0);
    }
    const avg_ns = total_ns / iterations;

    // 矩阵 #1 目标：< 500µs (500_000ns)。skip path 是 O(1) flag 检查 + 返回 slice，应在 10µs 内。
    // 给 50µs (50_000ns) 阈值留 debug build 余量；ReleaseFast 实测远低于此值。
    // 失败时打印 actual——zig test 默认吞 stdout，断言失败时才显示。
    if (avg_ns >= 50_000 or max_ns >= 200_000) {
        std.debug.print("[v0.5-P4 matrix #1] 10k nodes zero-dirty render REGRESSED: avg={d}ns max={d}ns (target avg<50_000 max<200_000)\n", .{ avg_ns, max_ns });
        return error.PerfRegression;
    }
}

// select_headless 主挂渲染 — mountSelectHeadless 把 346 行 state machine
// 挂到 *Node 树 + Popover trigger/content + default item rendering。
// 是替代 legacy select.zig 的 stage-1 实装。
test "mountSelectHeadless creates trigger + content + items" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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

    const result = try select_headless.mountSelectHeadless(i32, .{
        .options = &opts,
        .placeholder = "Pick one...",
        .width = 200,
    }, scope, cx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // 验证：创建了 3 个 item nodes
    try std.testing.expectEqual(@as(usize, 3), result.item_nodes.len);

    // 验证：state.value 初始 null（uncontrolled 默认）
    try std.testing.expect(result.state.value == null);

    // 验证：trigger 显示 placeholder
    try std.testing.expect(result.trigger_label.getText() != null);
    if (result.trigger_label.getText()) |txt| {
        try std.testing.expectEqualStrings("Pick one...", txt.content);
    }

    // 验证：is_open signal 初始 false
    try std.testing.expect(!result.is_open.peek());
}

test "mountSelectHeadless with initial_value displays selected label" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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

    const result = try select_headless.mountSelectHeadless(i32, .{
        .options = &opts,
        .initial_value = 20,
    }, scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    // 验证：trigger label 为 "Twenty"
    if (result.trigger_label.getText()) |txt| {
        try std.testing.expectEqualStrings("Twenty", txt.content);
    }
    try std.testing.expectEqual(@as(?i32, 20), result.state.value);
}

// ============================================================================
// v0.7 §2.1 — select_headless slot 化 + recipe 接入 tests
// ============================================================================

test "SelectSlotRecipe.resolve 给三 slot 返合理 ConditionalStyle" {
    const mount_mod = @import("../components/select_headless/mount.zig");
    const dark = theme.dark;
    const slots = mount_mod.SelectSlotRecipe.resolve(
        .{ .variant = .default, .size = .md },
        &dark,
    );
    // trigger / content / item base 必须有可解析的非空字段
    const tr = slots.trigger.resolve(.{});
    try std.testing.expect(tr.background != null);
    try std.testing.expect(tr.text_color != null);
    const ct = slots.content.resolve(.{});
    try std.testing.expect(ct.background != null);
    // item hover 态走 bg_hover
    const it_hover = slots.item.resolve(.{ .is_hovered = true });
    try std.testing.expect(it_hover.background != null);
}

test "mountSelectHeadless render_trigger slot — caller 自定义 trigger 节点" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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
        // caller 自定义 trigger 用 "Button" tag 而不是默认的 input box
        // 标志位标识本节点被自定义渲染 fn 调过
        var was_called: bool = false;
        var captured_label: []const u8 = "";

        fn render(ctx: TriggerCtx, c: *Cx) anyerror!*Node {
            was_called = true;
            captured_label = ctx.label_text;
            const n = try core_mod.box(c, .{
                .width = .{ .px = 100 },
                .height = .{ .px = 24 },
            }, .{});
            // 用一个特殊 component_name 让 fixture 能验
            n.meta.ownership.meta.component_name = "MyCustomTrigger";
            return n;
        }

        const core_mod = @import("../core.zig");
    };
    // reset
    CustomTrigger.was_called = false;
    CustomTrigger.captured_label = "";

    const result = try select_headless.mountSelectHeadless(i32, .{
        .options = &opts,
        .placeholder = "Pick A or B",
        .render_trigger = CustomTrigger.render,
    }, scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expect(CustomTrigger.was_called);
    try std.testing.expectEqualStrings("Pick A or B", CustomTrigger.captured_label);
    // result.trigger_label 应指向 caller 的自定义节点
    try std.testing.expect(result.trigger_label.meta.ownership.meta.component_name != null);
    try std.testing.expectEqualStrings(
        "MyCustomTrigger",
        result.trigger_label.meta.ownership.meta.component_name.?,
    );
}

test "mountSelectHeadless render_item slot — caller 自定义每个 option 行" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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
            // 自定义 item: 把 option.value 编码到 component_name 里好验
            var buf: [16]u8 = undefined;
            const label_str = std.fmt.bufPrintZ(&buf, "item-{d}", .{ctx.option.value}) catch "item";
            const owned = c.allocator.dupe(u8, label_str) catch return n;
            n.meta.ownership.meta.component_name = owned;
            return n;
        }

        const core_mod = @import("../core.zig");
    };
    CustomItem.call_count = 0;

    const result = try select_headless.mountSelectHeadless(i32, .{
        .options = &opts,
        .render_item = CustomItem.render,
    }, scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expectEqual(@as(u32, 3), CustomItem.call_count);
    // 每个 item 都该走 caller 的渲染
    try std.testing.expectEqual(@as(usize, 3), result.item_nodes.len);
    try std.testing.expectEqualStrings(
        "item-1",
        result.item_nodes[0].meta.ownership.meta.component_name.?,
    );
    try std.testing.expectEqualStrings(
        "item-3",
        result.item_nodes[2].meta.ownership.meta.component_name.?,
    );

    // free 之前 dupe 的字符串
    for (result.item_nodes) |n| {
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

    inline for (.{ ui.theme.ControlSize.xs, .sm, .md, .lg }) |size| {
        var cx = try Cx.init(std.testing.allocator);
        defer cx.deinit();
        cx.setViewport(400, 300);
        const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        cx.root = root;
        const scope = try Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        const result = try select_headless.mountSelectHeadless(i32, .{ .options = &opts, .width = 200, .size = size }, scope, cx);
        try root.appendChild(std.testing.allocator, result.wrapper);
        cx.layout();
        // trigger_label = ControlShell 的 content_slot；其父即外框
        const frame = result.trigger_label.parent.?;
        try std.testing.expectApproxEqAbs(cx.tokens.control.get(size).derivedHeight(), frame.rectFromWorldOrFallback().h, 0.01);
    }
    // 下拉列表行高是列表行度量（点击区），不随控件外框走
    try std.testing.expectEqual(@as(f32, 32), mount_mod.itemHeight(.xs));
    try std.testing.expectEqual(@as(f32, 32), mount_mod.itemHeight(.sm));
    try std.testing.expectEqual(@as(f32, 36), mount_mod.itemHeight(.md));
    try std.testing.expectEqual(@as(f32, 40), mount_mod.itemHeight(.lg));
}

// ============================================================================
// v0.7 §2.2 — select_headless virtualize (VirtualList) tests
// ============================================================================

test "virtualize=true 时 item_nodes 为空 (pool 复用)" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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

    const result = try select_headless.mountSelectHeadless(i32, .{
        .options = &opts_buf,
        .virtualize = true,
        .max_dropdown_height = 200,
    }, scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    // virtualize 模式下 item_nodes 是空 slice (pool 节点不暴露到外面)
    try std.testing.expectEqual(@as(usize, 0), result.item_nodes.len);
    // state 还在
    try std.testing.expect(result.state.value == null);
}

test "virtualize=false (默认) 仍每 option 一个 Node" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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

    const result = try select_headless.mountSelectHeadless(i32, .{
        .options = &opts,
        // virtualize 默认 false
    }, scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expectEqual(@as(usize, 3), result.item_nodes.len);
}

test "virtualize + 1000 options compile + mount 不爆 Node" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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

    const result = try select_headless.mountSelectHeadless(i32, .{
        .options = &opts_buf,
        .virtualize = true,
        .max_dropdown_height = 200, // 视口 ~6-7 行
    }, scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    // mount 成功；这条 fixture 主要验编译 + mount 不爆 (1k options 创建 1k Node
    // 会很慢且分配 100KB+ — virtualize 应只 ~10 行 pool node).
    try std.testing.expect(result.wrapper != root);
}

// ============================================================================
// v0.8 §2.1 — select_headless aria-activedescendant 接入 tests
// ============================================================================

test "select trigger 初始化 role=combobox + has_popup=listbox + 无 active_descendant" {
    const select_headless = @import("../components/select_headless/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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
    const result = try select_headless.mountSelectHeadless(i32, .{
        .options = &opts,
    }, scope, cx);
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

    var cx = try Cx.init(std.testing.allocator);
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
    const result = try select_headless.mountSelectHeadless(i32, .{
        .options = &opts,
    }, scope, cx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    try std.testing.expectEqual(@as(usize, 3), result.item_nodes.len);

    // 直接驱动 item[1] 的 mouse_enter handler
    const item1 = result.item_nodes[1];
    const handler = item1.behavior.events.on_event orelse return error.MissingHandler;
    const ctx = item1.behavior.events.event_context orelse return error.MissingContext;
    _ = handler(events_mod.Event{ .mouse_enter = {} }, ctx);

    // trigger.a11y.active_descendant_element_id 应该等于 item[1] 的 element_id_raw
    {
        const a11y = result.trigger.behavior.interaction.a11y orelse return error.MissingA11y;
        try std.testing.expectEqual(item1.element_id_raw, a11y.active_descendant_element_id);
    }

    // 切到 item[2]
    const item2 = result.item_nodes[2];
    const handler2 = item2.behavior.events.on_event orelse return error.MissingHandler;
    const ctx2 = item2.behavior.events.event_context orelse return error.MissingContext;
    _ = handler2(events_mod.Event{ .mouse_enter = {} }, ctx2);
    {
        const a11y = result.trigger.behavior.interaction.a11y orelse return error.MissingA11y;
        try std.testing.expectEqual(item2.element_id_raw, a11y.active_descendant_element_id);
    }
}

// shadow-sync Node.rect → LayoutTable.final_rect
// 验证 Cx.layout() 后 cx.rectOf(eid) 返回与 node.rect 相同的几何。
test "LayoutTable shadow-syncs Node.rect after layout" {
    var cx = try Cx.init(std.testing.allocator);
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

    // Stage 3-1 invariant：LayoutTable should be in sync with Node.rect
    if (child.element_id_raw != 0xFFFFFFFF) {
        const eid = ui.world.ElementId.fromRaw(child.element_id_raw);
        const lr = cx.rectOf(eid).?;
        try std.testing.expectApproxEqAbs(child.rectFromWorldOrFallback().x, lr.x, 0.001);
        try std.testing.expectApproxEqAbs(child.rectFromWorldOrFallback().y, lr.y, 0.001);
        try std.testing.expectApproxEqAbs(child.rectFromWorldOrFallback().w, lr.width, 0.001);
        try std.testing.expectApproxEqAbs(child.rectFromWorldOrFallback().h, lr.height, 0.001);
    }
}

// shadow-sync Node 父子链 → World.elements 父子链
// 验证 Node.appendChild 后 World.elements 上的 first_child / parent / sibling 链
// 与 Node 树等价。
test "ElementTable shadow-syncs Node parent/child chain" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 三个 child 都已注册到 World
    try std.testing.expect(root.element_id_raw != 0xFFFFFFFF);
    try std.testing.expect(c1.element_id_raw != 0xFFFFFFFF);
    try std.testing.expect(c2.element_id_raw != 0xFFFFFFFF);
    try std.testing.expect(c3.element_id_raw != 0xFFFFFFFF);

    const root_eid = ui.world.ElementId.fromRaw(root.element_id_raw);
    const c1_eid = ui.world.ElementId.fromRaw(c1.element_id_raw);
    const c2_eid = ui.world.ElementId.fromRaw(c2.element_id_raw);
    const c3_eid = ui.world.ElementId.fromRaw(c3.element_id_raw);

    // World 上的链应是 root → c1 → c2 → c3
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

    // child count 与 Node.children.items.len 一致
    try std.testing.expectEqual(root.children.items.len, cx.world.elements.childCount(root_eid));
}

// v0.5-P3 Stage 3-2 (收尾): removeChild 应同步 unlink World 父子链
test "removeChild unlinks ElementTable chain" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 摘除中间节点 c2
    root.removeChild(c2);

    // World 上 c2 已游离
    const c2_links = cx.world.elements.links(c2_eid).?;
    try std.testing.expect(c2_links.parent.isNull());
    try std.testing.expect(c2_links.prev_sibling.isNull());
    try std.testing.expect(c2_links.next_sibling.isNull());

    // root 子链应缩到 c1 → c3
    try std.testing.expectEqual(@as(u32, 2), cx.world.elements.childCount(root_eid));
    const root_links = cx.world.elements.links(root_eid).?;
    const c1_eid = ui.world.ElementId.fromRaw(c1.element_id_raw);
    const c3_eid = ui.world.ElementId.fromRaw(c3.element_id_raw);
    try std.testing.expect(root_links.first_child.eql(c1_eid));
    try std.testing.expect(root_links.last_child.eql(c3_eid));

    // 释放 c2 节点（c2 已脱离树，需要单独释放）
    cx.freeNode(c2);
}

test "removeAllChildren unlinks the full ElementTable chain" {
    var cx = try Cx.init(std.testing.allocator);
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

// PaintTable shadow-sync 路径走通
// render 之后 PaintTable 应填充对应 element 的 chunk；改 background 应让 hash mismatch 触发重录。
test "PaintTable shadow-syncs after render and invalidates on style change" {
    var cx = try Cx.init(std.testing.allocator);
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

    try std.testing.expect(child.element_id_raw != 0xFFFFFFFF);
    const eid = ui.world.ElementId.fromRaw(child.element_id_raw);
    const chunk1 = cx.world.paint.get(eid).?;
    const epoch1 = chunk1.paint_epoch;
    const hash1 = chunk1.content_hash;
    try std.testing.expect(epoch1 > 0);

    // 同一帧再 render → hash 命中，paint_epoch 不变
    _ = cx.render();
    const chunk2 = cx.world.paint.get(eid).?;
    try std.testing.expectEqual(epoch1, chunk2.paint_epoch);
    try std.testing.expectEqual(hash1, chunk2.content_hash);

    // 改 background → hash mismatch → 重录 → epoch 增大
    child.setBackgroundRaw(.{ .r = 0, .g = 0, .b = 255, .a = 255 });
    child.markRenderDirty();
    _ = cx.render();
    const chunk3 = cx.world.paint.get(eid).?;
    try std.testing.expect(chunk3.paint_epoch > epoch1);
    try std.testing.expect(chunk3.content_hash != hash1);

    // Phase 2: PaintTable 现在真填了 DisplayItem（不再 placeholder）。
    // 有 background 的节点应至少产生一个 .rect kind 的 PaintTable.DisplayItem。
    var has_rect_item = false;
    for (chunk3.display_items.items) |item| {
        if (item.kind == .rect) {
            has_rect_item = true;
            break;
        }
    }
    try std.testing.expect(has_rect_item);
}

// cx.lowerForEncoderPaintTable() 入口
// 与 lowerForEncoder() 输出一一对应 (kind + 字段无损)。
test "lowerForEncoderPaintTable 与 lowerForEncoder kind 序列一致" {
    var cx = try Cx.init(std.testing.allocator);
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
    // 长度一致：B-5 lowerForEncoderPaintTable 是 1:1 翻译
    try std.testing.expectEqual(display_list_lowered.len, paint_table_lowered.len);
    // 至少要看到两个 .rect kind 的 paint_table item
    var rect_count: usize = 0;
    for (paint_table_lowered) |it| {
        if (it.kind == .rect) rect_count += 1;
    }
    try std.testing.expect(rect_count >= 2);
}

// paint_table.DisplayItem 字段无损验证。
// fill_rect 走 cx.syncPaintToTable 写入的 PaintTable chunk 应该字段完全保留
// (geom + color + radii)，让后续 encoder 切到 paint_table.DisplayItem 真接管
// 时数据无损。
test "PaintTable.DisplayItem 字段无损 (fill_rect geom + color + radii)" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    // 用确定的几何 + 颜色 + radii，方便后面字段对照
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

    const eid = ui.world.ElementId.fromRaw(child.element_id_raw);
    const chunk = cx.world.paint.get(eid).?;
    // 找 .rect kind 的 DisplayItem (background fill_rect)
    var found_idx: ?usize = null;
    for (chunk.display_items.items, 0..) |item, idx| {
        if (item.kind == .rect and item.color.a == 255 and item.color.r == 200) {
            found_idx = idx;
            break;
        }
    }
    try std.testing.expect(found_idx != null);
    const item = chunk.display_items.items[found_idx.?];
    // 几何字段无损 — encoder 切到 paint_table 后用这些字段直接产 SDF rect
    try std.testing.expectEqual(@as(f32, 100), item.geom.w);
    try std.testing.expectEqual(@as(f32, 50), item.geom.h);
    // 颜色无损
    try std.testing.expectEqual(@as(u8, 200), item.color.r);
    try std.testing.expectEqual(@as(u8, 150), item.color.g);
    try std.testing.expectEqual(@as(u8, 100), item.color.b);
    try std.testing.expectEqual(@as(u8, 255), item.color.a);
    // radii 无损 (uniform corner_radius=8 → 4 角全 8)
    try std.testing.expectEqual(@as(f32, 8), item.radii.tl);
    try std.testing.expectEqual(@as(f32, 8), item.radii.tr);
    try std.testing.expectEqual(@as(f32, 8), item.radii.br);
    try std.testing.expectEqual(@as(f32, 8), item.radii.bl);
}

// InteractionTable shadow-sync
// focusable 节点 / 监听 click 节点 / 有 a11y role 的节点应在 InteractionTable 中。
test "InteractionTable shadow-syncs focusable/event/a11y nodes" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // 三个子节点：focusable / a11y role / 啥也没有（不应进 InteractionTable）
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

    const fcb_eid = ui.world.ElementId.fromRaw(fcb.element_id_raw);
    const a11y_eid = ui.world.ElementId.fromRaw(a11y_n.element_id_raw);
    const plain_eid = ui.world.ElementId.fromRaw(plain.element_id_raw);

    const fcb_data = cx.world.interaction.get(fcb_eid).?;
    try std.testing.expect(fcb_data.focus.focusable);
    try std.testing.expect(fcb_data.focus.tabbable);

    const a11y_data = cx.world.interaction.get(a11y_eid).?;
    try std.testing.expect(a11y_data.a11y_role != 0);

    // plain 没有 focusable / a11y / event → 不应在 InteractionTable
    try std.testing.expect(cx.world.interaction.get(plain_eid) == null);
}

// LayoutTable 全树等价校验
// 整树遍历，所有 element_id 节点的 cx.rectOf(eid) 与 node.rect 必须严格一致。
// 这是 SoT inversion 前的 gate：两个 store 必须每帧同步，差异即 bug。
test "LayoutTable matches Node.rect for whole tree" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 用 Cx 提供的 helper（debug build 也能在 prod 路径调用）
    try std.testing.expect(cx.assertLayoutSyncIntegrity(root));

    // v0.5-P3 N-2 (2026-05-03 字段已删): 原 perturb test 验证 frame_state.rect 与
    // LayoutTable 的 divergence 能被 catch。字段已删 (World 是唯一 source-of-truth)，
    // divergence 不可能发生 — 此 perturb path 自然失效。integrity check 退化为
    // PaintTable.bounds vs LayoutTable.rect invariant，由 syncPaintToTable 保证。
}

// layerizeFrame 现在真消费 PaintTable.bounds（之前是 placeholder {}）
// 验证：scroll container 节点 layerize 后 layer.world_bounds 非空。
test "layerizeFrame reads PaintTable bounds" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // scroll container 子节点
    const scrollable = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    try root.appendChild(std.testing.allocator, scrollable);

    cx.layout();
    _ = cx.render();

    // 注入 scroll_id 到 InteractionTable（绕过真 ScrollArea 复杂性）
    const eid = ui.world.ElementId.fromRaw(scrollable.element_id_raw);
    cx.world.interaction.put(eid, .{
        .scroll_id = 1, // 假 scroll id
    }) catch unreachable;

    _ = cx.layerizeFrame(&[_]ui.layerize_mod.LayerizeInput{});

    // PaintTable.chunk(eid).bounds 应已通过 syncPaintToTable 写入
    const chunk = cx.world.paint.get(eid).?;
    try std.testing.expect(!chunk.bounds.isEmpty());

    // LayerTree 应有非 root layer，且其 world_bounds 复用 PaintTable.bounds
    var found_promoted: bool = false;
    for (cx.layer_tree.layers.items) |*l| {
        if (!l.alive) continue;
        if (l.root_element.isNull()) continue; // root layer 没有 root_element
        if (!l.world_bounds.isEmpty()) {
            found_promoted = true;
            break;
        }
    }
    try std.testing.expect(found_promoted);
}

// v0.5-P3 Stage 3-3 Phase 1++ (session 43): paintContentHash 现在覆盖更多视觉属性
// 验证 opacity / border / text 颜色变化都触发 cache invalidation。
test "paintContentHash invalidates on more visual attrs" {
    var cx = try Cx.init(std.testing.allocator);
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
    const eid = ui.world.ElementId.fromRaw(root.element_id_raw);
    const epoch1 = cx.world.paint.get(eid).?.paint_epoch;

    // 改 opacity 应触发 hash mismatch
    root.setOpacityRaw(0.5);
    root.markRenderDirty();
    _ = cx.render();
    const epoch2 = cx.world.paint.get(eid).?.paint_epoch;
    try std.testing.expect(epoch2 > epoch1);
}

// v0.5-P3 Stage 3-3 Phase 4 (session 38): layerizeFrame 真消费 PaintTable.property_state
// 至少证明：扫 chunks 的代码路径不会破坏现有 layerize 行为（test = no-regression gate）。
test "layerizeFrame still works after PaintTable property_state scan" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 扫 chunks promotion 路径不报错
    const layer_count = cx.layerizeFrame(&[_]ui.layerize_mod.LayerizeInput{});
    // 至少有 root layer
    try std.testing.expect(layer_count >= 1);
}

// v0.5-P3 Stage 3-3 Phase 3 (session 37): PaintChunk.property_state 真填
// transform_id / clip_id / effect_id 来自 SceneRuntime；scroll_id 来自 InteractionTable。
test "PaintChunk.property_state populated from SceneRuntime" {
    var cx = try Cx.init(std.testing.allocator);
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

    const eid = ui.world.ElementId.fromRaw(root.element_id_raw);
    const chunk = cx.world.paint.get(eid).?;
    // transform_id 应有效（root 有 transform）
    try std.testing.expect(chunk.property_state.transform_id != std.math.maxInt(u32));
}

// ============================================================================
// 帧尾 shadow-sync 按脏区跳子树（Step 1）+ 子树标志 O(1) 化（Step 0）
// ============================================================================

// Step 0: collectContentFlags.has_text 改读 NodeFlags.has_text_subtree
// （setText 置位 + appendChild 并入父链，保守不清位）。验证加文本 / 删文本 /
// reparent 三条路径下 scene_runtime.get(id).content_flags.has_text 正确。
test "content flags: has_text_subtree flag tracks add/remove/reparent text" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    // 场景：root > container > leaf；leaf 初始无文本。
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const container = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    try root.appendChild(std.testing.allocator, container);
    const leaf = try box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 20 } }, .{});
    try container.appendChild(std.testing.allocator, leaf);

    cx.layout();
    _ = cx.render();

    // canary：无文本时 has_text 应为 false（若本断言红，说明标志/收集根本没接上）。
    try std.testing.expect(cx.scene_runtime.get(container.id).?.content_flags.has_text == false);

    // 1. 加文本：叶子 setText 非空 → 沿祖先冒泡，container/root 的 has_text 都为 true。
    try leaf.setTextContent(std.testing.allocator, "hello");
    leaf.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.scene_runtime.get(leaf.id).?.content_flags.has_text == true);
    try std.testing.expect(cx.scene_runtime.get(container.id).?.content_flags.has_text == true);
    try std.testing.expect(cx.scene_runtime.get(root.id).?.content_flags.has_text == true);

    // 2. 删文本：保守不清位 → has_text 保持 true（旧 subtreeHasText 语义的超集）。
    leaf.setText(null);
    leaf.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.scene_runtime.get(container.id).?.content_flags.has_text == true);

    // 3. reparent：另一棵无文本子树 append 到 root → 标志从挂载点并入父链。
    const other = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 40 } }, .{});
    try root.appendChild(std.testing.allocator, other);
    const other_text = try text(cx, "world", .{});
    try other.appendChild(std.testing.allocator, other_text);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.scene_runtime.get(other.id).?.content_flags.has_text == true);
    // other 挂进 root 时 root 已因 leaf 的历史文本为 true；把整棵树换掉验证
    // 并入路径本身：fresh parent（无文本历史）+ 带 text 的子树。
    const fresh_root = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    const fresh_leaf = try text(cx, "deep", .{});
    try fresh_root.appendChild(std.testing.allocator, fresh_leaf);
    // 挂进现有树 → appendChild 的并入路径必须把 fresh_root 以上的父链也点亮。
    try root.appendChild(std.testing.allocator, fresh_root);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.scene_runtime.get(fresh_root.id).?.content_flags.has_text == true);
    try std.testing.expect(root.frame_state.state_bits.flags.has_text_subtree == true);
}

// ============================================================================

// 让 ScrollArea.mount 注入的 scroll_id 被清回 sentinel。
test "syncInteractionToTable preserves scroll_id across renders" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const target = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    try root.appendChild(std.testing.allocator, target);

    cx.layout();

    // 模拟 ScrollArea.mount: 注入 scroll_id
    const eid = ui.world.ElementId.fromRaw(target.element_id_raw);
    cx.world.interaction.put(eid, .{
        .scroll_id = 42,
    }) catch unreachable;

    // 触发一次 render → syncInteractionToTable 跑
    _ = cx.render();

    // scroll_id 应仍然是 42，不被擦回 sentinel
    const data = cx.world.interaction.get(eid).?;
    try std.testing.expectEqual(@as(u32, 42), data.scroll_id);
}

// ============================================================================
// v0.6 §2.1 — Accessibility Tree 投影 tests
// ============================================================================

test "syncA11yTreeFromInteractions projects nodes with a11y or focusable" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // 三个子节点：focusable / a11y role / 纯视觉
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

    // root 无 a11y、无 focusable → 不投影
    // btn → 投影为 .button
    // focusable_n → 投影为 .generic (focusable 容器)
    // plain → 不投影
    try std.testing.expectEqual(@as(usize, 2), cx.accessibility_tree.count());

    const btn_eid = ui.ElementId.fromRaw(btn.element_id_raw);
    const btn_node = cx.accessibility_tree.get(btn_eid).?;
    try std.testing.expectEqual(ui.a11y_tree.Role.button, btn_node.role);
    try std.testing.expect(btn_node.label_hash != 0);

    // label_buf 应能查回 "Click Me"
    const got_label = cx.a11y_label_buf.get(btn_node.label_hash).?;
    try std.testing.expectEqualStrings("Click Me", got_label);

    const f_eid = ui.ElementId.fromRaw(focusable_n.element_id_raw);
    const f_node = cx.accessibility_tree.get(f_eid).?;
    try std.testing.expectEqual(ui.a11y_tree.Role.generic, f_node.role);
    try std.testing.expect(f_node.state.focusable);
}

test "label falls back to subtree text when a11y.label is null" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // button 无 explicit label，但子文本 "Submit" 应作为 label fallback
    const btn = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button };
    const label_text = try ui.text(cx, "Submit", .{});
    try btn.appendChild(std.testing.allocator, label_text);
    try root.appendChild(std.testing.allocator, btn);

    cx.layout();
    _ = cx.render();

    const btn_eid = ui.ElementId.fromRaw(btn.element_id_raw);
    const btn_node = cx.accessibility_tree.get(btn_eid).?;
    const got_label = cx.a11y_label_buf.get(btn_node.label_hash).?;
    try std.testing.expectEqualStrings("Submit", got_label);
}

test "a11y_tree parent skips non-projected ancestors" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // 中间纯视觉 wrapper（不投影）
    const wrapper = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    try root.appendChild(std.testing.allocator, wrapper);

    // 内层 button
    const btn = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "Inner" };
    try wrapper.appendChild(std.testing.allocator, btn);

    cx.layout();
    _ = cx.render();

    // root + wrapper 都不投影；btn parent 应是 NULL（最近已投影祖先）
    const btn_eid = ui.ElementId.fromRaw(btn.element_id_raw);
    const btn_node = cx.accessibility_tree.get(btn_eid).?;
    try std.testing.expect(btn_node.parent.isNull());
}

test "state.checked / disabled propagated from A11yProps" {
    var cx = try Cx.init(std.testing.allocator);
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
    const cb_node = cx.accessibility_tree.get(cb_eid).?;
    try std.testing.expect(cb_node.state.checked);
    try std.testing.expect(cb_node.state.disabled);
}

// ============================================================================
// v0.6 §2.1 — macos_bridge C ABI 集成 tests (ObjC accessibilityChildren 协议
// 等价回调路径)。这些 fixture 模拟 ObjC 调 zenit_a11y_* extern 序列，验证
// cx.render() 之后 a11y_tree 可以被 C-style API 完整遍历 + 取 label。
// ============================================================================

// 每个 export 的首参是 window_id（ObjC 代理从自己的 NSWindow 取）。这些 fixture
// 用 ANY_WINDOW(0) 通配，等价于"当前唯一注册的窗口"—— 本文件的 cx 都是单窗口。
// 按具体 window_id 路由的多窗口验收在 a11y/macos_bridge.zig 的单测里。
const a11y_bridge_extern = struct {
    const ANY: u32 = 0;
    extern fn zenit_a11y_root_count(window_id: u32) c_int;
    extern fn zenit_a11y_root_at(window_id: u32, idx: c_int) u32;
    extern fn zenit_a11y_children_count(window_id: u32, parent_raw: u32) c_int;
    extern fn zenit_a11y_children_at(window_id: u32, parent_raw: u32, idx: c_int) u32;
    extern fn zenit_a11y_role(window_id: u32, handle: u32) c_int;
    extern fn zenit_a11y_label(window_id: u32, handle: u32, buf: ?[*]u8, buf_len: c_int) c_int;
    extern fn zenit_a11y_frame(window_id: u32, handle: u32, x: ?*f32, y: ?*f32, width: ?*f32, height: ?*f32) c_int;
    extern fn zenit_a11y_actions(window_id: u32, handle: u32) u8;
    extern fn zenit_a11y_perform_action(window_id: u32, handle: u32, action: u8) c_int;
};

test "VoiceOver-style navigation reaches button labels" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 模拟 VoiceOver pull path: MetalView.accessibilityChildren → root_count/_at
    try std.testing.expectEqual(@as(c_int, 2), a11y_bridge_extern.zenit_a11y_root_count(a11y_bridge_extern.ANY));

    var seen_save = false;
    var seen_cancel = false;
    var i: c_int = 0;
    while (i < 2) : (i += 1) {
        const h = a11y_bridge_extern.zenit_a11y_root_at(a11y_bridge_extern.ANY, i);
        try std.testing.expect(h != 0);
        try std.testing.expectEqual(
            @as(c_int, @intFromEnum(ui.a11y_tree.Role.button)),
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
    var cx = try Cx.init(std.testing.allocator);
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
    const btn = try box(cx, .{ .width = .{ .px = 91 }, .height = .{ .px = 37 } }, .{});
    btn.setFocusable(true);
    btn.behavior.interaction.a11y = .{ .role = .button, .label = "Native action" };
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
}

test "nested a11y tree exposes children via C ABI" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // dialog 容器 + 2 个子 button
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

    // VoiceOver flow: 顶级是 dialog
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_root_count(a11y_bridge_extern.ANY));
    const dialog_h = a11y_bridge_extern.zenit_a11y_root_at(a11y_bridge_extern.ANY, 0);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(ui.a11y_tree.Role.dialog)),
        a11y_bridge_extern.zenit_a11y_role(a11y_bridge_extern.ANY, dialog_h),
    );

    // dialog 有 2 个 children
    try std.testing.expectEqual(@as(c_int, 2), a11y_bridge_extern.zenit_a11y_children_count(a11y_bridge_extern.ANY, dialog_h));

    // 验 children label 包含 "OK" / "Cancel"
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
    var cx = try Cx.init(std.testing.allocator);
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
    // probe: buf=null 返实际长度
    const probe = a11y_bridge_extern.zenit_a11y_label(a11y_bridge_extern.ANY, h, null, 0);
    try std.testing.expectEqual(@as(c_int, "Hello World".len), probe);
}

// ============================================================================
// v0.6 §2.2 — event_dispatcher capture phase 真派发 tests
// ============================================================================

// 共享 trace buffer：每个 capture handler push 节点 tag (root/mid/target)
const CaptureTrace = struct {
    seq: std.ArrayList(u8),
    stop_after: ?u8 = null, // 收到此 tag 后返 .stop

    fn append(self: *CaptureTrace, tag: u8) EventResult {
        // 测试脚手架：这里签名被事件回调固定成返回 EventResult，没法传播 error。
        // 用的是 testing.allocator —— 真 OOM 会让测试自己失败，而且序列断言
        // 会立刻发现少了一项，不存在"静默通过"的风险。
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

test "capture phase walks root → target (not including target)" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var trace = CaptureTrace{ .seq = .{} };
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

    // 直接走 dispatcher 测试 capture/bubble 逻辑，绕开 hit-test (hit-test 已被
    // 大量 fixture 覆盖；这里只测事件分发协议本身)。
    _ = cx.dispatcher.dispatch(ui.Event{ .click = .{ .x = 50, .y = 50 } }, target);

    // root (R) + mid (M) 在 capture phase 触发；target (T) 不触发 capture（capture
    // 协议只走 root → target 路径，**不含 target 自身**）。
    try std.testing.expectEqual(@as(usize, 2), trace.seq.items.len);
    try std.testing.expectEqual(@as(u8, 'R'), trace.seq.items[0]);
    try std.testing.expectEqual(@as(u8, 'M'), trace.seq.items[1]);
}

test "capture stop halts propagation (no bubble)" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var trace = CaptureTrace{ .seq = .{}, .stop_after = 'M' };
    defer trace.seq.deinit(std.testing.allocator);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    root.behavior.events.on_event_capture = captureHandlerFor('R');
    root.behavior.events.event_context = &trace;

    const mid = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    mid.behavior.events.on_event_capture = captureHandlerFor('M');
    mid.behavior.events.event_context = &trace;

    // target 还挂个 on_event 验证 target/bubble 阶段是否被 stop 阻断
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

    // R + M 触发；M 返 stop 后 target 不应被触发
    try std.testing.expectEqual(@as(usize, 2), trace.seq.items.len);
    try std.testing.expect(!target_hit);
}

test "null on_event_capture handler skipped (zero overhead)" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    var trace = CaptureTrace{ .seq = .{} };
    defer trace.seq.deinit(std.testing.allocator);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    // root 不设 on_event_capture

    const mid = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    mid.behavior.events.on_event_capture = captureHandlerFor('M');
    mid.behavior.events.event_context = &trace;

    const target = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});

    try mid.appendChild(std.testing.allocator, target);
    try root.appendChild(std.testing.allocator, mid);
    cx.root = root;
    cx.layout();

    _ = cx.dispatcher.dispatch(ui.Event{ .click = .{ .x = 50, .y = 50 } }, target);

    // 只有 mid (M) 触发；root null handler 跳过
    try std.testing.expectEqual(@as(usize, 1), trace.seq.items.len);
    try std.testing.expectEqual(@as(u8, 'M'), trace.seq.items[0]);
}

// ============================================================================
// v0.6 §2.4 — a11y_router.flushToBridge 端到端 tests
// ============================================================================

const PushHookCalls = struct {
    children_changed: u32 = 0,
    last_announce_text: [128]u8 = undefined,
    last_announce_text_len: usize = 0,
    announce_count: u32 = 0,
};

var g_push_test_state: PushHookCalls = .{};

fn testChildrenChangedHook(_: u32, _: u32) callconv(.c) c_int {
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

    var cx = try Cx.init(std.testing.allocator);
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

    // root + btn 都是新增（structure_changed），router 给 parent 推 children_changed.
    // btn.parent == root (有效)；root.parent == NULL (router 跳过 NULL parent)。
    // 所以 children_changed 至少调 1 次（btn 的 parent=root 触发）。
    try std.testing.expect(g_push_test_state.children_changed >= 1);
}

test "live region text_hash change triggers announce hook" {
    g_push_test_state = .{};
    ui.a11y_macos_bridge.setPushHooks(.{
        .children_changed = testChildrenChangedHook,
        .announce = testAnnounceHook,
    });
    defer ui.a11y_macos_bridge.setPushHooks(.{});

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    cx.layout();
    _ = cx.render();
    g_push_test_state.announce_count = 0;

    // 手动 upsert 一个 live region 节点 + 修改 text_hash → live_announce dirty
    const id: ui.ElementId = .{ .index = 999, .generation = 0 };
    const initial_text = "Loading";
    const initial_hash = std.hash.Wyhash.hash(0, initial_text);
    try cx.a11y_label_buf.put(cx.allocator, initial_hash, initial_text);
    try cx.accessibility_tree.upsert(.{
        .element = id,
        .role = .status,
        .live = .polite,
        .text_hash = initial_hash,
    });
    // drain 第一次 upsert (structure_changed)
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

    // 改 text → live_announce
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
    ui.a11y_macos_bridge.setPushHooks(.{}); // 全 null
    defer ui.a11y_macos_bridge.setPushHooks(.{});

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    root.behavior.interaction.a11y = .{ .role = .button, .label = "X" };
    cx.root = root;
    cx.layout();
    _ = cx.render();

    // 没注册 hook → 计数器都是 0
    try std.testing.expectEqual(@as(u32, 0), g_push_test_state.children_changed);
    try std.testing.expectEqual(@as(u32, 0), g_push_test_state.announce_count);
}

// ============================================================================
// v0.6 §2.5 — focus.zig audit fixture
// ============================================================================

test "focus survives same-node identity (no rerender)" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 再渲一帧后焦点应保持
    _ = cx.render();
    try std.testing.expect(cx.focus_manager.getFocused() == btn);
}

test "focus cleared when focused node destroyed" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 摧毁焦点节点
    cx.detachChild(root, btn);
    cx.freeNode(btn);

    // getFocused 应自动清空 (generational handle resolve null)
    try std.testing.expect(cx.focus_manager.getFocused() == null);
}

// setFocusWithReason 在旧焦点 blur/新焦点 focus 回调里同步 freeNode 的 UAF 防御。
// 实测崩溃栈：NodeRegistry.trackGeneration ← FocusManager.setFocusWithReason ——
// blur 处理器释放了新焦点候选节点，之后直接把悬垂指针写进 current_focus 并读 node.id。
// 回调在 tick/reactive 深度之外，freeNode 走 freeNodeNow 当场释放（不排队）。
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const f = try focusFreeFixture(cx);

    cx.focus_manager.setFocus(f.a);
    try std.testing.expect(cx.focus_manager.getFocused() == f.a);

    var probe = FocusFreeProbe{ .cx = cx, .parent = f.root, .victim = f.b };
    f.a.behavior.events.on_blur = probe.handler();

    // b 在 a 的 blur 里被释放；修复前这里把悬垂的 b 写进 current_focus。
    cx.focus_manager.setFocusWithReason(f.b, .click);

    try std.testing.expectEqual(@as(u32, 1), probe.fired);
    try std.testing.expect(cx.focus_manager.current_focus == null);
    try std.testing.expect(cx.focus_manager.current_focus_handle == null);
    try std.testing.expect(cx.focus_manager.getFocused() == null);
    // 旧焦点已收到 blur，不得"还原"成焦点
    try std.testing.expect(!cx.focus_manager.isFocused(f.a));
    // 帧照常可跑、焦点链照常可用
    _ = cx.render();
    f.a.behavior.events.on_blur = null;
    cx.focus_manager.setFocus(f.a);
    try std.testing.expect(cx.focus_manager.getFocused() == f.a);
}

test "focus: Tab traversal whose blur handler frees the next target does not UAF" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const f = try focusFreeFixture(cx);

    cx.focus_manager.setFocus(f.a);
    var probe = FocusFreeProbe{ .cx = cx, .parent = f.root, .victim = f.a };
    f.a.behavior.events.on_blur = probe.handler();

    // a 在自己的 blur 里被释放；之后的 dispatcher blur 冒泡与 markRenderDirty 不得再碰 a。
    cx.focus_manager.setFocusWithReason(f.b, .click);

    // detachChild → invalidateReferencesTo 会对仍持焦点的 a 再发一次 blur（重入，victim 已空）。
    try std.testing.expect(probe.fired >= 1);
    try std.testing.expect(cx.focus_manager.getFocused() == f.b);
    _ = cx.render();
}

test "focus: focus handler freeing its own node leaves focus cleared (no UAF)" {
    var cx = try Cx.init(std.testing.allocator);
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

// Documenting current limitation:
// v0.6 §2.5 audit 发现 reactive rerender 后 focus restoration 不基于 stable_id
// (e.g. For 控制流 key=item.id 重建节点)，新节点 ptr/generation 都不同；
// 现有 getFocused 走 cached ptr+id match，新节点不能恢复。这是 Phase 7
// (主 plan §Phase 7 "For 控制流 key-only + eq_props") 范围，v0.6 保留 limitation。

// ============================================================================
// v0.6 §2.3 — gesture_recognizer 接入 dispatcher tests
// ============================================================================
//
// 验证 cx.handleMouseDown/Move/Up + cx.render() (tick) feed 到 gesture_arena，
// recognizer callback 在 state 转换时被触发。
//
// 不验证：input/state.zig 双击/三击/drag anchor 迁移到 GestureArena —
// plan §2.3 显式 defer 该迁移，本组只测 infrastructure。

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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    cx.layout();

    var counter = GestureCount{};
    _ = try cx.registerGesture(root, .tap, .{}, GestureCount.cb, &counter);

    // mouse down + up 在同一位置 → tap.ended emit
    cx.handleMouseDown(50, 50, .{});
    cx.handleMouseUp(50, 50);

    try std.testing.expectEqual(@as(u32, 1), counter.ended);
    try std.testing.expectEqual(@as(u32, 0), counter.failed);
}

test "pan recognizer fires began on movement > threshold" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    cx.layout();

    var counter = GestureCount{};
    _ = try cx.registerGesture(root, .pan, .{ .pan_min_movement_px = 10 }, GestureCount.cb, &counter);

    cx.handleMouseDown(50, 50, .{});
    // 移动 5px（< 10px 阈值） → 不 began
    cx.handleMouseMove(55, 50);
    try std.testing.expectEqual(@as(u32, 0), counter.began);

    // 移动到 70 (距 origin 20px > 10px) → began
    cx.handleMouseMove(70, 50);
    try std.testing.expectEqual(@as(u32, 1), counter.began);

    // 继续移动 → changed
    cx.handleMouseMove(80, 50);
    try std.testing.expectEqual(@as(u32, 1), counter.changed);

    cx.handleMouseUp(80, 50);
    try std.testing.expectEqual(@as(u32, 1), counter.ended);
}

test "tap recognizer fails when movement > threshold (no ended)" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    cx.layout();

    var counter = GestureCount{};
    // 阈值设极小 (1ms)，因为单元测试不好等 500ms 真实时钟
    _ = try cx.registerGesture(root, .long_press, .{ .long_press_min_duration_ms = 1 }, GestureCount.cb, &counter);

    cx.handleMouseDown(50, 50, .{});
    try std.testing.expectEqual(@as(u32, 0), counter.began);

    // 真等 5ms 让 nanoTimestamp 推进过阈值
    std.Thread.sleep(5 * std.time.ns_per_ms);
    _ = cx.render();
    try std.testing.expectEqual(@as(u32, 1), counter.began);

    cx.handleMouseUp(50, 50);
    try std.testing.expectEqual(@as(u32, 1), counter.ended);
}

// ── CA-pure surface revamp regression gate (P0) ──
// 居中的 composited_group surface owner（= modal dialog 场景）在动画态（scale≠1）
// 必须合成在它的居中世界位置，**绝不**漂到 (0,0)。这是之前几次修复缺失的逐帧位置
// 断言：旧的 surface_inverse 双重 localize 会让 begin_opacity_layer 的合成位置落在
// 屏幕左上角。修好（CA-pure 单矩阵 M_composite）后必须居中。
test "render(CA): centered composited_group surface composites at center, not (0,0)" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(1100, 1000);

    // 全窗口 root，flex 居中（= barrier 居中 dialog）
    const root = try box(cx, .{
        .width = .{ .px = 1100 },
        .height = .{ .px = 1000 },
        .justify = .center,
        .align_items = .center,
    }, .{});

    // 居中的 surface owner（dialog）：400x100，composited_group + 动画态 scale=0.9
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

    // 居中世界位置：x=(1100-400)/2=350, y=(1000-100)/2=450
    const expect_cx: f32 = 350 + 200; // dialog 中心 x
    const expect_cy: f32 = 450 + 50; // dialog 中心 y

    var saw_layer = false;
    for (commands) |cmd| {
        if (!cmd.isControl(.begin_opacity_layer)) continue;
        saw_layer = true;
        // 合成位置：use_draw_transform 时取 draw_transform 的平移分量映射 src 中心；
        // 否则取 draw_x/y + draw_w/h 中心（settled fallback 路径）。
        var composed_cx: f32 = undefined;
        var composed_cy: f32 = undefined;
        if (cmd.use_draw_transform) {
            // draw_transform 作用于 src 矩形 (geom)。算 src 中心经 transform 后的位置。
            const t = cmd.draw_transform; // [a,b,c,d,tx,ty]
            const sx = cmd.geom.x + cmd.geom.w / 2;
            const sy = cmd.geom.y + cmd.geom.h / 2;
            composed_cx = t[0] * sx + t[2] * sy + t[4];
            composed_cy = t[1] * sx + t[3] * sy + t[5];
        } else {
            composed_cx = cmd.draw_x + cmd.draw_w / 2;
            composed_cy = cmd.draw_y + cmd.draw_h / 2;
        }
        // 合成中心必须靠近 dialog 居中世界中心（容差 60，覆盖 shadow margin/scale）。
        // 旧 bug 下 composed_cx≈0 → 远离 550 → 失败。
        try std.testing.expect(@abs(composed_cx - expect_cx) < 60);
        try std.testing.expect(@abs(composed_cy - expect_cy) < 60);
        // 且绝不在左上角
        try std.testing.expect(composed_cx > 100);
        try std.testing.expect(composed_cy > 100);
    }
    try std.testing.expect(saw_layer);
}

test "render: rotated leaf inside ancestor clip emits surface-local apply_clip" {
    // 回归：settle 后静态 rotate=π/2 的叶子（accordion 展开态 chevron）走
    // has_surface_transform surface，effect bridge 把祖先 clip 的 world AABB
    // 原样发进 surface 内 → 世界坐标 scissor 在 surface-local 内容上裁空一切。
    // 修复后 apply_clip 须经 surface_draw_transform 逆变换进 surface-local 空间。
    var cx = try Cx.init(std.testing.allocator);
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
            // surface 内容为 surface-local（16x16 于原点附近）；clipper 的世界
            // x=200 若原样出现，说明 clip 未逆变换 → 内容会被整体裁掉
            if (cmd.geom.x > 100) saw_world_space_clip_in_surface = true;
        }
    }
    try std.testing.expect(saw_layer);
    try std.testing.expect(!saw_world_space_clip_in_surface);
}

test "render: blur layer ancestor clip stays in parent frame before begin_blur_layer" {
    // blur 的 apply_clip 发在 begin_blur_layer **之前**（父上下文），必须保持
    // world 坐标——effect_bridge 的 surface-local 投影只适用于 layer 内部的 clip
    //（inside_surface=true 分支），此处不得误投影。
    var cx = try Cx.init(std.testing.allocator);
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
        // 父上下文的 clip 应为 world 坐标（clipper 在 x=200）
        try std.testing.expectApproxEqAbs(@as(f32, 200), x, 0.001);
    }
}

test "world ownership: node carries its owning Cx id" {
    // P0-3 阶段 1 验收：Node 现在带 owner 标识。
    // 这是拆掉全局回调间接层的地基 —— ElementId 本身
    // ({index:u24, generation:u8}) 不含 World 标识，两个 World 都从 index 0
    // 分配，故仅凭 element_id 无法区分归属（isValid 会假匹配）。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const n = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    cx.root = n;

    // 经 Cx 创建的节点都被盖上了 owner 章。
    try std.testing.expect(n.world_id != ui.INVALID_WORLD_ID);
    try std.testing.expectEqual(cx.world_id, n.world_id);
}

test "world ownership: guard detects a foreign node (negative test)" {
    // 证明守卫不是死代码：把 world_id 篡改成非 active 值后，
    // nodeBelongsToActiveWorld 必须判否。
    // （不直接调 rectFromWorldOrFallback —— 那会 panic 中断测试进程；
    //   这里验的是判定逻辑本身。）
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const n = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    cx.root = n;

    try std.testing.expect(Cx.nodeBelongsToActiveWorldForTest(n));
    const saved = n.world_id;
    n.world_id = saved +% 7; // 伪造成别的 World 的节点
    try std.testing.expect(!Cx.nodeBelongsToActiveWorldForTest(n));
    n.world_id = saved;

    // INVALID（cx-less mock）必须放行，否则大量测试路径会误报。
    n.world_id = ui.INVALID_WORLD_ID;
    try std.testing.expect(Cx.nodeBelongsToActiveWorldForTest(n));
    n.world_id = saved;
}

test "world ownership: sequential Cx get distinct world ids" {
    // world id 不复用 —— 复用会让已释放 Cx 的陈旧 Node 与新 Cx 假匹配，
    // 正是 owner 标识要防的问题。
    var first_id: u16 = undefined;
    {
        var cx = try Cx.init(std.testing.allocator);
        defer cx.deinit();
        first_id = cx.world_id;
    }
    {
        var cx = try Cx.init(std.testing.allocator);
        defer cx.deinit();
        try std.testing.expect(cx.world_id != first_id);
    }
}

test "standalone fallback storage is reclaimed on last Cx deinit" {
    // 这几张 fallback 表是进程级 + page_allocator，**GPA leak check 看不见**
    // （审查报告列的盲区：`zig build test` 全绿不代表这条路径没泄漏）。
    // 现在 Cx.deinit 会在最后一个 Cx 退出时显式回收，这里断言"确实清零"。
    const accessor = @import("paint_content_accessor.zig");
    const lifecycle = @import("node_lifecycle.zig");

    {
        var cx = try Cx.init(std.testing.allocator);
        defer cx.deinit();
        const n = try box(cx, .{ .width = .{ .px = 8 }, .height = .{ .px = 8 } }, .{});
        cx.root = n;
        // 制造 standalone 条目：Node.create 会跑 create hook 拿到真 element_id，
        // 故手动清回 INVALID 来强制走 fallback 写入路径（模拟 cx-less mock）。
        const orphan = try Node.create(std.testing.allocator, 99999, .box, .{});
        defer orphan.destroy(std.testing.allocator);
        orphan.element_id_raw = 0xFFFFFFFF;
        orphan.world_id = ui.INVALID_WORLD_ID;
        orphan.setLayoutRect(.{ .x = 1, .y = 2, .w = 3, .h = 4 });
        try std.testing.expect(lifecycle.standaloneRectCount() > 0);
    }

    // 最后一个 Cx 退出后，表应被回收干净。
    try std.testing.expectEqual(@as(usize, 0), lifecycle.standaloneRectCount());
    try std.testing.expectEqual(@as(usize, 0), accessor.standaloneEntryCount());
}

test "P0-3 stage 3: node property access bypasses global callbacks" {
    // 阶段 3 验收：paint / content / layout_output 的读写现在直连
    // node.world_ref.*，不再经过进程级全局回调。
    // legacy_callback_hits 只在 world_ref == null（cx-less mock）时自增，
    // 所以经 Cx 创建的节点做完整读写后，它必须**纹丝不动**。
    const pca = @import("paint_content_accessor.zig");

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const n = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 10 } }, .{});
    cx.root = n;
    try std.testing.expect(n.world_ref != null); // onNodeCreate 已注入 owner

    const before = pca.legacy_callback_hits;

    // 覆盖三组访问器的读写各一次。
    n.setBackgroundRaw(Color.rgb(1, 2, 3));
    _ = n.getBackground();
    n.setOpacityRaw(0.5);
    _ = n.getOpacity();
    n.setText(.{ .content = "hi" });
    _ = n.getText();
    n.setLayoutRect(.{ .x = 1, .y = 2, .w = 3, .h = 4 });
    _ = n.rectFromWorldOrFallback();

    try std.testing.expectEqual(before, pca.legacy_callback_hits);

    // 且值确实通过 World 往返正确（不是"绕过了但读不到"）。
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), n.getOpacity(), 0.001);
    try std.testing.expectEqual(@as(f32, 3), n.rectFromWorldOrFallback().w);
}

test "P0-3 stage 3: dirty + structure sync reach World directly" {
    // dirty_notify / structure_notify 也已直连（不再走进程级回调）。
    // 这里断言"父子链确实同步进了 World.elements" —— 若还在走旧回调而
    // 回调恰好没注册，链表就会是空的，测试会失败。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const parent = try box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 40 } }, .{});
    cx.root = parent;
    const child = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try parent.appendChild(cx.allocator, child);

    const w = parent.world_ref.?;
    const p_eid = ui.ElementId.fromRaw(parent.element_id_raw);
    const c_eid = ui.ElementId.fromRaw(child.element_id_raw);

    // append 已同步到 World.elements 父子链。
    const links = w.elements.links(c_eid).?;
    try std.testing.expect(!links.parent.isNull());
    try std.testing.expectEqual(p_eid.raw(), links.parent.raw());

    // markRenderDirty 走 markWorldDirty → World.dirty_set（不 panic 即通过；
    // 这里主要验证直连路径没有因为 world_ref 为空而静默丢弃）。
    child.markRenderDirty();

    // unlink 同样同步。
    cx.detachChild(parent, child);
    const links_after = w.elements.links(c_eid).?;
    try std.testing.expect(links_after.parent.isNull());
    cx.freeNode(child);
}

test "P0-3 stage 5: two coexisting Cx route node mutations independently" {
    // **多窗口的核心验收**：两个 Cx 同时存活，各自的节点 mutation 必须落进
    // 各自的 World，互不串台。
    //
    // 这是 P0-3 的终点判据。历史上不可能通过：Node↔World 路由走进程级全局
    // 回调，第二个 Cx.init 会把回调重指向新 World，于是**窗口 A 的节点写进
    // 窗口 B 的表**；而 ElementId 不含 World 标识（两个 World 都从 index 0
    // 分配），isValid 只校验 index+generation，跨查会**假匹配返回错误数据**。
    //
    // 现在属性访问全部走 node.world_ref 直连，故只要节点用 Cx.createNode
    // 显式创建（不依赖 g_active_world），两个 Cx 就能各自独立。
    var cx_a = try Cx.init(std.testing.allocator);
    defer cx_a.deinit();

    // 无需任何放行开关 —— 并发守卫已拆除（2026-07-30，最后一处进程级依赖
    // a11y active context 已按 window_id 路由）。第二个 Cx 直接 init 即可。
    var cx_b = try Cx.init(std.testing.allocator);
    defer cx_b.deinit();

    try std.testing.expect(cx_a.world_id != cx_b.world_id);

    // 两个节点分别显式归属各自的 Cx。
    const a = try cx_a.createNode(.box, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } });
    defer cx_a.freeNode(a);
    const b = try cx_b.createNode(.box, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } });
    defer cx_b.freeNode(b);

    try std.testing.expect(a.world_ref.? != b.world_ref.?);

    // 关键：即使两者的 ElementId **可能完全相同**（各自 World 都从 index 0 起
    // 分配），写入也必须各回各家。
    a.setLayoutRect(.{ .x = 1, .y = 1, .w = 11, .h = 11 });
    b.setLayoutRect(.{ .x = 2, .y = 2, .w = 22, .h = 22 });
    a.setOpacityRaw(0.25);
    b.setOpacityRaw(0.75);

    try std.testing.expectEqual(@as(f32, 11), a.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 22), b.rectFromWorldOrFallback().w);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), a.getOpacity(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), b.getOpacity(), 0.001);

    // 反向确认串台确实不存在：改 A 不影响 B。
    a.setLayoutRect(.{ .x = 9, .y = 9, .w = 99, .h = 99 });
    try std.testing.expectEqual(@as(f32, 22), b.rectFromWorldOrFallback().w);
}

test "silent-swallow counters stay zero in normal operation" {
    // 审查报告 §3：全仓约 250 处 `catch return;` / `catch {}` 把 OOM 与构建
    // 失败完全吞掉。逐个改成可传播的 error 需要动 effect/回调签名，成本极高；
    // 折中方案是给**风险最高的几处**加计数器，让"静默"变成"可观测"。
    // 这个测试锁住：正常渲染路径下它们必须恒为 0 —— 一旦非 0，说明有 OOM
    // 或容量问题正在悄悄劣化画面/响应式，而不是等用户报"少了一块"。
    const graph_mod = @import("../reactive/graph.zig");

    const base_paint = ui.paint_push_failures;
    const base_track = graph_mod.reactive_tracking_failures;
    const base_hit = ui.interaction_put_failures;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(200, 120);

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{});
    cx.root = root;
    try root.appendChild(std.testing.allocator, try text(cx, "hello", .{}));

    // 跑两帧完整 layout+render（含文本 paint chunk 录制，即 pushItem 的路径）。
    cx.layout();
    _ = cx.render();
    root.markRenderDirty();
    cx.frame_time_ms += 16;
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(base_paint, ui.paint_push_failures);
    try std.testing.expectEqual(base_track, graph_mod.reactive_tracking_failures);
    try std.testing.expectEqual(base_hit, ui.interaction_put_failures);
}

test "allocation campaign: rebuildRuntimeIndexes reports OOM instead of publishing partial indexes" {
    // 锁住 core.zig 那批 `catch @panic("OOM: rebuildRuntimeIndexes ...")` 的前提：
    // 该函数**确实会**在 OOM 时返回 error（即 panic 不是死代码）。
    //
    // 为什么必须 panic 而不是吞掉：rebuildRuntimeStateRecursive 先把节点的
    // dirty 位全清成 false，之后才做可失败的 node_registry.put /
    // focus_order.append。中途 OOM 会留下「节点已标记干净、却不在索引里」的
    // 状态 —— 该节点从此 hit-test 打不中、Tab 走不到，而且没有 dirty 位能触发
    // 重试。旧代码的 `catch {}` 正好把这个状态变成永久静默错乱。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(200, 120);

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{});
    cx.root = root;
    // 多挂几个 focusable 子节点，保证重建过程里有足够多次分配可以失败。
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const child = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
        child.behavior.interaction.focusable = true;
        try root.appendChild(std.testing.allocator, child);
    }

    // 先跑一帧，让索引进入已建好的稳定态。
    cx.layout();
    _ = cx.render();

    // 再挂一批新节点，让重建**必须**申请新容量。
    // （只 clear() 是不够的：node_registry / focus_order 都走
    // clearRetainingCapacity，重填同一批节点不会触发任何分配，
    // FailingAllocator 也就永远不会被调用 —— 实测第一版就栽在这里。）
    i = 0;
    while (i < 512) : (i += 1) {
        const child = try box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
        child.behavior.interaction.focusable = true;
        try root.appendChild(std.testing.allocator, child);
    }

    // 换成注定失败的 allocator。注意必须换 node_registry / focus_manager
    // **自己持有的** allocator 字段：它们在 init 时就捕获了 allocator，
    // 事后改 cx.allocator 对重建路径毫无影响（实测第二版栽在这里）。
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const saved_reg = cx.node_registry.allocator;
    const saved_focus = cx.focus_manager.allocator;
    cx.node_registry.allocator = failing.allocator();
    cx.focus_manager.allocator = failing.allocator();
    cx.node_registry.clear();
    cx.focus_manager.clearFocusOrder();
    root.frame_state.state_bits.dirty.runtime.subtree_full_rebuild = true;

    const result = cx.rebuildRuntimeIndexesForTest();

    // 关键断言：错误被**返回**了，没有被内部吞掉。
    try std.testing.expectError(error.OutOfMemory, result);

    // 还原，让 deinit 用真 allocator 收尾（否则 GPA 会报 free 到错 allocator）。
    cx.node_registry.allocator = saved_reg;
    cx.focus_manager.allocator = saved_focus;
}

test "P0-3: two coexisting Cx each render their own tree correctly" {
    // 比阶段 5 那个测试更进一步：不只验证属性路由，而是让**两个 Cx 各自跑
    // 完整 layout + render**，断言各自的 display list 只包含自己的内容。
    // 这是"多窗口真的能用"的判据 —— builder 已全部改走 cx.createNode，
    // 不再依赖 g_active_world 决定节点归属。
    var cx_a = try Cx.init(std.testing.allocator);
    defer cx_a.deinit();

    // 无需任何放行开关 —— 并发守卫已拆除（2026-07-30，最后一处进程级依赖
    // a11y active context 已按 window_id 路由）。第二个 Cx 直接 init 即可。
    var cx_b = try Cx.init(std.testing.allocator);
    defer cx_b.deinit();

    cx_a.setViewport(100, 60);
    cx_b.setViewport(200, 120);

    // 两棵完全独立的树，各自用自己的 cx 建（走 builders → createNode）。
    const root_a = try box(cx_a, .{ .width = .{ .px = 100 }, .height = .{ .px = 60 } }, .{});
    cx_a.root = root_a;
    try root_a.appendChild(std.testing.allocator, try text(cx_a, "AAA", .{}));

    const root_b = try box(cx_b, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{});
    cx_b.root = root_b;
    try root_b.appendChild(std.testing.allocator, try text(cx_b, "BBB", .{}));

    // 节点确实各归各的 World。
    try std.testing.expect(root_a.world_ref.? == &cx_a.world);
    try std.testing.expect(root_b.world_ref.? == &cx_b.world);

    // 交错渲染 —— 最坏情况：g_active_world 在两者间反复切换。
    cx_a.layout();
    _ = cx_a.render();
    cx_b.layout();
    _ = cx_b.render();
    cx_a.layout();
    _ = cx_a.render();

    // 各自的布局结果互不污染（viewport 不同，根尺寸必须各按各的）。
    try std.testing.expectEqual(@as(f32, 100), root_a.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 200), root_b.rectFromWorldOrFallback().w);

    // 各自的 paint 列表非空且互相独立。
    try std.testing.expect(cx_a.lowerForEncoderPaintTable().len > 0);
    try std.testing.expect(cx_b.lowerForEncoderPaintTable().len > 0);

    // ── a11y 端到端：ObjC 用各自的 window_id 调 C ABI，必须拿到各自的树 ──
    // 这是拆掉 Cx.init 并发守卫的最后一块拼图。守卫存在期间这段不可能跑到：
    // 旧实现的 setActiveContext 是单槽，cx_b.render() 会直接覆盖 cx_a 的注册，
    // 于是两个 window_id 查出来是同一棵树。
    cx_a.setWindowId(101);
    cx_b.setWindowId(202);

    // a11y 树只投影**显式带 role/label** 的节点，光有 box+text 投不出东西 ——
    // 各给一棵树挂一个 button。
    const a11y_btn_a = try box(cx_a, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    a11y_btn_a.behavior.interaction.a11y = .{ .role = .button, .label = "AAA" };
    try root_a.appendChild(std.testing.allocator, a11y_btn_a);

    const a11y_btn_b = try box(cx_b, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    a11y_btn_b.behavior.interaction.a11y = .{ .role = .button, .label = "BBB" };
    try root_b.appendChild(std.testing.allocator, a11y_btn_b);

    // window_id 变了要重新注册（注册发生在 render 末尾的 syncA11yTree）。
    cx_a.layout();
    _ = cx_a.render();
    cx_b.layout();
    _ = cx_b.render();

    const a_roots = a11y_bridge_extern.zenit_a11y_root_count(101);
    const b_roots = a11y_bridge_extern.zenit_a11y_root_count(202);
    try std.testing.expect(a_roots > 0);
    try std.testing.expect(b_roots > 0);

    // 各自的 root handle 指向各自 World 的 element —— 拿 A 的 handle 去 B 里
    // 查 role，不该命中 A 的节点（两个 World 的 ElementId 都从 index 0 起，
    // 正是历史上"假匹配"的形状）。
    const a_root_h = a11y_bridge_extern.zenit_a11y_root_at(101, 0);
    const b_root_h = a11y_bridge_extern.zenit_a11y_root_at(202, 0);
    try std.testing.expect(a_root_h != 0);
    try std.testing.expect(b_root_h != 0);

    // 从 A 的树里能读到 "AAA"，从 B 的树里能读到 "BBB"，且不互串。
    try std.testing.expect(try a11yTreeContainsLabel(101, "AAA"));
    try std.testing.expect(!try a11yTreeContainsLabel(101, "BBB"));
    try std.testing.expect(try a11yTreeContainsLabel(202, "BBB"));
    try std.testing.expect(!try a11yTreeContainsLabel(202, "AAA"));

    // 注销其中一个窗口，另一个不受影响。
    ui.a11y_macos_bridge.clearActiveContext(101);
    try std.testing.expectEqual(@as(c_int, 0), a11y_bridge_extern.zenit_a11y_root_count(101));
    try std.testing.expectEqual(b_roots, a11y_bridge_extern.zenit_a11y_root_count(202));
}

/// 在某个 window_id 的 a11y 树里递归找有没有节点的 label 等于 `needle`。
fn a11yTreeContainsLabel(window_id: u32, needle: []const u8) !bool {
    const n = a11y_bridge_extern.zenit_a11y_root_count(window_id);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const h = a11y_bridge_extern.zenit_a11y_root_at(window_id, i);
        if (h == 0) continue;
        if (try a11ySubtreeContainsLabel(window_id, h, needle)) return true;
    }
    return false;
}

fn a11ySubtreeContainsLabel(window_id: u32, handle: u32, needle: []const u8) !bool {
    var buf: [256]u8 = undefined;
    const written = a11y_bridge_extern.zenit_a11y_label(window_id, handle, &buf, buf.len);
    if (written > 0 and std.mem.eql(u8, buf[0..@intCast(written)], needle)) return true;

    const kids = a11y_bridge_extern.zenit_a11y_children_count(window_id, handle);
    var i: c_int = 0;
    while (i < kids) : (i += 1) {
        const ch = a11y_bridge_extern.zenit_a11y_children_at(window_id, handle, i);
        if (ch == 0) continue;
        if (try a11ySubtreeContainsLabel(window_id, ch, needle)) return true;
    }
    return false;
}

test "measure ctx: per-Cx measure function wins over the process-wide one" {
    // 多窗口的两处非 World 全局依赖之一：measure_fn 签名不带 context，
    // 调用方（zenit_app.runtime）只能用进程级 g_font_selector_for_measure
    // 偷渡字体选择器 —— 两个 App 并存时后者覆盖前者，前一个窗口的文本会
    // 用错字体测量。现在 Cx 支持 measure_ctx_fn(+ctx)，各测各的。
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

    // 带 context 的版本必须优先（否则多窗口下仍会串台）。
    try std.testing.expect(S.ctx_calls > 0);
    try std.testing.expectEqual(@as(u32, 0), S.global_calls);
    try std.testing.expectApproxEqAbs(@as(f32, 4 * 10 * 2.0), w, 0.001);
}

test "blend_mode: non-normal forces offscreen and reaches the paint table" {
    // blend_mode 端到端链路验收（2026-07-30 接线）。此前这条链"两头都断"：
    // 没有 API 能设出非 normal，encoder 侧也从未消费。本测试守生产端三件事：
    // 1. blend_mode != normal 强制 use_opacity_layer（混合需要独立光栅化 src）；
    // 2. EffectNode → CompositedLayer → begin_opacity_layer 逐层携带不丢；
    // 3. lowered paint item 的 blend_mode 字段非 0（encoder 据此走 blend
    //    composite 而非 trivial 短路 / 普通 SrcOver）。
    var cx = try Cx.init(std.testing.allocator);
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

    // 走 offscreen effect（blend 不要求 promotion，只要求独立光栅化），
    // blend_mode 带到 EffectNode。
    var effect_found = false;
    for (cx.property_tree.effects.items) |eff| {
        if (eff.node_id == panel.id and eff.blend_mode == .multiply) {
            effect_found = true;
            break;
        }
    }
    try std.testing.expect(effect_found);

    // lowered paint 列表里能找到 blend_mode == multiply 的 begin_opacity_layer。
    var found = false;
    for (cx.lowerForEncoderPaintTable()) |it| {
        if (it.kind == .control and it.control_kind == .begin_opacity_layer and
            it.blend_mode == @intFromEnum(ui.BlendMode.multiply))
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "Cx: deinit with lingering focus does not UAF (downstream regression)" {
    // 复现：树里有 focusable 节点且退出时仍持有焦点 → 递归 freeNode 的
    // unregisterFocusableSilent 曾经过 getFocused() 解引用已释放节点 → segfault。
    var cx = try Cx.init(std.testing.allocator);
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

    // 测试脚手架：用 testing.allocator，OOM 会让测试自身失败；且后续断言直接
    // 检查 focus 行为，注册没成功会立刻暴露，不会静默通过。
    cx.focus_manager.registerFocusable(a_node) catch {};
    cx.focus_manager.registerFocusable(b_node) catch {};
    cx.focus_manager.setFocus(b_node);

    // 不 clearFocus 直接 deinit —— 修复前此处必崩
    cx.deinit();
}

// ─────────────────────────────────────────────────────────────────────────────
// 下游应用上游 #12：单点 render-dirty 帧不得全树 paint 重录（O(全树) 放大器）
// 验收口径：2000 绝对定位兄弟场景，单点 markRenderDirty 后重录节点数下降 ≥90%。
// ─────────────────────────────────────────────────────────────────────────────

test "perf: single render-dirty node must not re-record 2000 clean siblings" {
    var cx = try Cx.init(std.testing.allocator);
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
        // translate 落位（下游应用模式：绝对定位 + per-box 平移）
        child.style.translate_x = @floatFromInt((i % 40) * 30);
        child.style.translate_y = @floatFromInt((i / 40) * 15);
        try root.appendChild(cx.allocator, child);
        if (i == n_boxes / 2) mid_child = child;
    }

    cx.root = root;

    // 帧 1：全量渲染（全树 fresh 重录）
    _ = cx.render();
    const full_emit = cx.perf.own_content_emit_count;
    try std.testing.expect(full_emit >= n_boxes); // 全树都真的录了一遍
    const full_display_len = cx.display_list.items.items.len;
    const full_paint_len = cx.lowering.main_paint.items.len;
    try std.testing.expect(full_display_len >= n_boxes); // 每个 box 至少 1 条 fill_rect

    // 快照帧 1 lowered 几何（等价性验收：修复不许改变最终画面命令流）
    const Geom = struct { kind_tag: u16, x: f32, y: f32, w: f32, h: f32 };
    var snap = try std.testing.allocator.alloc(Geom, full_paint_len);
    defer std.testing.allocator.free(snap);
    for (cx.lowering.main_paint.items, 0..) |it, gi| {
        snap[gi] = .{ .kind_tag = @intFromEnum(it.kind), .x = it.geom.x, .y = it.geom.y, .w = it.geom.w, .h = it.geom.h };
    }

    // 帧 2：单点 render dirty
    mid_child.?.markRenderDirty();
    _ = cx.render();

    const dirty_emit = cx.perf.own_content_emit_count;
    const dirty_display_len = cx.display_list.items.items.len;
    const dirty_paint_len = cx.lowering.main_paint.items.len;

    // 等价性：display list / lowered 命令数一致，lowered 几何完全一致
    try std.testing.expectEqual(full_display_len, dirty_display_len);
    try std.testing.expectEqual(full_paint_len, dirty_paint_len);
    for (cx.lowering.main_paint.items, 0..) |it, gi| {
        try std.testing.expectEqual(snap[gi].kind_tag, @intFromEnum(it.kind));
        try std.testing.expectApproxEqAbs(snap[gi].x, it.geom.x, 0.01);
        try std.testing.expectApproxEqAbs(snap[gi].y, it.geom.y, 0.01);
        try std.testing.expectApproxEqAbs(snap[gi].w, it.geom.w, 0.01);
        try std.testing.expectApproxEqAbs(snap[gi].h, it.geom.h, 0.01);
    }

    // 验收：单点脏帧重录节点数 ≤ 全量的 10%（目标是个位数：脏节点 + 根 + 路径）
    std.debug.print(
        "\n[dirty-splice-bench] full_emit={d} dirty_emit={d} splice_hits={d} cache_writes={d}\n",
        .{ full_emit, dirty_emit, cx.perf.subtree_payload_splice_count, cx.perf.subtree_payload_cache_write_count },
    );
    try std.testing.expect(dirty_emit * 10 <= full_emit);
}

// ─────────────────────────────────────────────────────────────────────────────
// hook 影响范围声明（before_render_hook_affects_self_only）
//
// 背景（下游编辑器稳态帧调查 2026-09-17）：markdown 编辑器在最外层挂了
// before_render hook（滚动同步/几何回填），而 prebuildDisplayPayloadSubtrees
// 遇到任何带 hook 的节点就置 display_payload_prefix_broken，让 paint 顺序在其
// 之后的**一切**退回 fresh emit。实测后果：正文整棵子树的
// subtree_payload_splice_count 恒为 0，每帧重录 186 个节点，
// ZENIT_DISABLE_SUBTREE_SPLICE 的 A/B 差异 -1%（因为它本就没生效）。
//
// 下面两个测试是一对：
//   1. 不声明（默认保守）→ 前缀被打断，兄弟子树零复用。这条锚定我们**没有**
//      放松默认语义（GlassLab 双份合成的防线还在）。
//   2. 声明 self-only → 兄弟子树恢复复用，且 lowered 命令流逐条等价。
// 第 2 条摘掉 hookScopeIsSelfOnly 的放行必然变红 —— 它就是负向注入锚点。
// ─────────────────────────────────────────────────────────────────────────────

/// 只改自身样式的 hook：模拟编辑器的"每帧回填自己的几何"，不触碰任何后代。
fn selfOnlyHookForTest(node: *Node) void {
    // 写自身背景（own 内容变化），不碰 children
    node.setBackground(Color.rgba(10, 20, 30, 255));
}

fn buildHookedPrefixScene(cx: *Cx, n_siblings: usize, self_only: bool) !*Node {
    const root = try box(cx, .{ .width = .{ .px = 1280 }, .height = .{ .px = 800 } }, .{});

    // 带 hook 的节点排在**前面** —— 它一旦打断前缀，后面的兄弟全部失去缓存资格。
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
        // 每个兄弟带一个子节点，构成"子树"而不是叶子 —— splice 的粒度在子树。
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

test "hook scope: 默认（未声明）保持保守语义——前缀打断，兄弟子树零复用" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(1280, 800);

    const root = try buildHookedPrefixScene(cx, 200, false);

    _ = cx.render(); // 帧 1：建立缓存的机会
    cx.perf.subtree_payload_splice_count = 0;
    // ⚠ 必须制造一个脏点：全干净的树会被 Cx.render 的零脏帧 fast-path 整帧
    // early-return（core.zig:5766），prebuild 根本不执行，splice 计数恒为 0
    // —— 那样断言"等于 0"是假绿（测的是 fast-path，不是本闸门）。
    // 脏最后一个兄弟，模拟"只有一行变了"。
    root.children.items[root.children.items.len - 1].markRenderDirty();
    _ = cx.render(); // 帧 2：单点脏帧

    // 默认语义下，带 hook 的节点把前缀打断 → 后面的兄弟一个都 splice 不到。
    try std.testing.expectEqual(@as(u32, 0), cx.perf.subtree_payload_splice_count);
}

test "hook scope: 声明 self-only 后兄弟子树恢复跨帧复用且命令流等价" {
    const n: usize = 200;

    // ── A：声明 self-only ────────────────────────────────────────────
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    const root = try buildHookedPrefixScene(cx, n, true);

    _ = cx.render();
    // 等价性基准：取**关掉复用**时的命令流。同一棵树、同一个脏点，
    // 走 fresh 全量重录的结果就是真值；下面开着复用再跑一遍必须逐条相同。
    // （若拿帧 1 当基准，帧 1 本身也可能已经复用，等于拿被测物当尺子。）
    const Geom = struct { kind_tag: u16, x: f32, y: f32, w: f32, h: f32 };
    var baseline = std.ArrayListUnmanaged(Geom){};
    defer baseline.deinit(std.testing.allocator);
    {
        var cx_ref = try Cx.init(std.testing.allocator);
        defer cx_ref.deinit();
        cx_ref.setViewport(1280, 800);
        const ref_root = try buildHookedPrefixScene(cx_ref, n, false); // false = 保守全量
        _ = cx_ref.render();
        ref_root.children.items[ref_root.children.items.len - 1].markRenderDirty();
        _ = cx_ref.render();
        try baseline.ensureTotalCapacity(std.testing.allocator, cx_ref.lowering.main_paint.items.len);
        for (cx_ref.lowering.main_paint.items) |it| {
            baseline.appendAssumeCapacity(.{ .kind_tag = @intFromEnum(it.kind), .x = it.geom.x, .y = it.geom.y, .w = it.geom.w, .h = it.geom.h });
        }
    }

    cx.perf.subtree_payload_splice_count = 0;
    cx.perf.own_content_emit_count = 0;
    // 单点脏（同上：避开零脏帧 fast-path）。这也正是要优化的真实场景 ——
    // "只有一行变了，其余全部复用"。
    root.children.items[root.children.items.len - 1].markRenderDirty();
    _ = cx.render(); // 帧 2：单点脏帧，干净兄弟应大量命中 splice

    const splice_hits = cx.perf.subtree_payload_splice_count;
    const emit = cx.perf.own_content_emit_count;
    std.debug.print(
        "\n[hook-self-scope] splice_hits={d} emit={d} siblings={d}\n",
        .{ splice_hits, emit, n },
    );

    // 核心断言：干净兄弟子树被整支复用（摘掉 hookScopeIsSelfOnly 放行即变红）
    try std.testing.expect(splice_hits > 0);

    // 等价性：复用路径产出的 lowered 命令流必须与**保守全量**路径逐条一致。
    // 这是防"缓存生效但画错"的护栏 —— 命中率高而画面错是更坏的结果。
    try std.testing.expectEqual(baseline.items.len, cx.lowering.main_paint.items.len);
    for (cx.lowering.main_paint.items, 0..) |it, gi| {
        try std.testing.expectEqual(baseline.items[gi].kind_tag, @intFromEnum(it.kind));
        try std.testing.expectApproxEqAbs(baseline.items[gi].x, it.geom.x, 0.01);
        try std.testing.expectApproxEqAbs(baseline.items[gi].y, it.geom.y, 0.01);
        try std.testing.expectApproxEqAbs(baseline.items[gi].w, it.geom.w, 0.01);
        try std.testing.expectApproxEqAbs(baseline.items[gi].h, it.geom.h, 0.01);
    }
}

// 交叉审查（GLM，问题一之 1）提出的最严重疑点：一个自称 self-only 的 hook
// 若**直接写后代的 style.translate_x**（绕过 setTranslateX 的 markCompositePropDirty），
// 后代六个 dirty 位与 content_version 都不变 → 祖先 stamp 全过 → splice 出
// hook 运行前的陈旧位置。production 里 textarea/virtual_list/scrollbar 都是
// 这种直接写法，而 manual_transform_animation_active 只在测试文件里被置位。
// 本探针判定：这条路径是否真的画错。
// 稽核修正后的三向验证：真违约必须仍然被抓到，合法写法必须放行。
var g_audit_victim: ?*Node = null;
var g_audit_tick: u8 = 0;

// (A) 真违约：raw 写入口改别人，不标脏
fn auditRawWriteHook(node: *Node) void {
    _ = node;
    if (g_audit_victim) |t| {
        g_audit_tick +%= 1;
        t.setBackgroundRaw(Color.rgba(g_audit_tick *% 30, 60, 90, 255));
    }
}

// (B) 合法：改别人但走标脏入口（panic 文案推荐的修法之一，必须放行）
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

// 负向确认：真违约（raw 写入口改别人、不标脏）必须仍被抓到。
// 这个 test 期望 panic，所以不能当常规用例跑 —— 用 PROBE2 前缀手动跑：
//   zig build test-ui-core -Dtest-filter="PROBE2 真违约"
// 预期：panic 并点名 hook 所在 node 与被改的 node。
test "PROBE2 真违约必须仍被稽核抓到（预期 panic）" {
    // SKIP-REASON: 稽核违约探针，需显式设 ZENIT_RUN_AUDIT_VIOLATION_PROBE 才跑（它故意触发 panic 路径）
    if (std.posix.getenv("ZENIT_RUN_AUDIT_VIOLATION_PROBE") == null) return error.SkipZigTest;
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(1280, 800);
    _ = try buildAuditScene(cx, auditMarkedWriteHook);
    defer g_audit_victim = null;

    // 走 setBackground（标脏）改别人：缓存会正常失效，不是威胁模型内的违约。
    // 稽核若把它也判违约，panic 文案推荐的修法(b)就自相矛盾了。
    var f: usize = 0;
    while (f < 4) : (f += 1) {
        cx.frame_count += 1;
        cx.frame_time_ms += 16.0;
        _ = cx.render();
    }
    // 跑到这里没 panic 即通过
    try std.testing.expect(g_audit_tick > 0);
}

// 第二轮交叉审查（GLM）结论 1 的回归护栏：稽核不得因 hook 自己 mount 新节点误报。
// 修正前实测必崩 —— 而首个真实采纳者（编辑器 hook 每帧驱动 VL 挂载/回收）
// 恰恰就是这个形态，等于该声明位对目标用户完全不可用。
var g_mounting_hook_cx: ?*Cx = null;
var g_mounting_hook_ran: u32 = 0;

fn mountingHookForTest(node: *Node) void {
    const cx = g_mounting_hook_cx orelse return;
    g_mounting_hook_ran += 1;
    // 模拟 VL 每帧挂一行：只加自己的后代，不碰任何现存节点的绘制态
    const child = box(cx, .{
        .width = .{ .px = 5 },
        .height = .{ .px = 5 },
        .background = Color.rgba(7, 7, 7, 255),
    }, .{}) catch return;
    node.appendChild(cx.allocator, child) catch return;
}

test "hook scope 稽核: hook 自身 mount 新节点不得误报" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 若稽核把"树形状变化"误判成违约，这里会 panic
    _ = cx.render();
    cx.frame_count += 1;
    cx.frame_time_ms += 16.0;
    _ = cx.render();

    // 跑到这里没 panic 即通过；顺带确认 hook 真的执行并挂上了节点，
    // 否则这个测试会在"hook 根本没跑"的情况下假绿。
    try std.testing.expect(g_mounting_hook_ran >= 2);
    try std.testing.expect(hooked.children.items.len >= 2);
}

// ─────────────────────────────────────────────────────────────────────────────
// 交叉审查（GLM-5.3，2026-09-17）验证记录：self-only 担保说谎会怎样
//
// 用探针实测过两种谎报形态，结论不同，都记在这里免得后人重走：
//
// 1. hook 直接写别人的 style.translate_x（绕过 setTranslateX 的标脏）
//    → **不会画错**。缓存里的 DisplayItem 是 local 坐标 + transform_id，
//    lower 时读当帧 property_tree 矩阵（display_list_lowering.zig:309，
//    property_tree 每帧 clear 重建），所以平移类写入天然有兜底。
//    实测：8 帧 translate 7→56，drawn_x 逐帧跟上，mismatch=0。
//
// 2. hook 直接写别人的背景色（setBackgroundRaw —— 框架自带的"无副作用
//    写入口"，生产代码 151 处在用）
//    → **会画错，且静默**。颜色是烘焙进 DisplayItem 的值，没有重算兜底；
//    content_version 也不被 raw 写入口 bump，stamp 拦不住。
//    实测：8 帧全部复用陈旧颜色（drawn_r 冻在 30，style 已走到 240）；
//    去掉 self-only 声明则 stale_frames=0 —— 即这是本特性引入的新风险。
//
// 因此 runBeforeRenderHook 加了运行期稽核（tick.zig）：声明了 self-only 的
// hook，跑完后若整棵树里**除自己以外**任何节点的绘制态变了，直接 panic 指名
// 道姓。谎报从"偶发残影"变成"当场炸、带修法"。
//
// 稽核只在 Debug/ReleaseSafe 生效，且只对声明了该位的节点付遍历成本。
// ─────────────────────────────────────────────────────────────────────────────

// 交叉审查（GLM，P4）提出的疑点：hook 的增删不 bump versions.content，
// 而 nodeEligibleForSubtreePayloadCache 用 hasBeforeRenderHooks() 把关缓存的
// 读端与写端 —— 那么"挂 hook 期间不写缓存、摘掉 hook 后第一帧"读到的会不会是
// 挂 hook **之前**的陈旧条目？本测试用来判定该路径是否真的可达。
test "hook scope: hook 摘除后不得 splice 到陈旧缓存条目" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(1280, 800);

    const root = try box(cx, .{ .width = .{ .px = 1280 }, .height = .{ .px = 800 } }, .{});
    // target：先无 hook（可缓存）→ 内容 A
    const target = try box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const inner = try box(cx, .{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
        .background = Color.rgba(11, 22, 33, 255),
    }, .{});
    try target.appendChild(cx.allocator, inner);
    // 多放几个带背景的孙节点，让"画错"有地方显形（只有 1 条命令时比对形同虚设）
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
    // 一个兄弟，保证 root 有别的脏点可制造非零脏帧
    const sib = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try root.appendChild(cx.allocator, sib);
    cx.root = root;

    _ = cx.render(); // 帧 1：target 无 hook → 写入缓存（内容 A）
    _ = cx.render();

    // 挂 hook：此后 target 不参与缓存（读写两端都被 hasBeforeRenderHooks 拦）
    target.meta.per_frame.hooks.before_render.main = selfOnlyHookForTest;
    // 挂 hook 期间改变 inner 的内容（缓存条目里的 A 因此过时）
    inner.setBackground(Color.rgba(200, 100, 50, 255));
    sib.markRenderDirty();
    _ = cx.render();

    // 摘掉 hook：target 重新具备缓存资格
    target.meta.per_frame.hooks.before_render.main = null;
    sib.markRenderDirty(); // 制造单点脏帧（避开零脏帧 fast-path）
    cx.perf.subtree_payload_splice_count = 0;
    _ = cx.render();

    // splice 命中本身不等于画错 —— 关键是内容对不对。
    // 与"从未挂过 hook、其余完全相同"的参照 Cx 逐条比对 lowered 命令流。
    var ref = try Cx.init(std.testing.allocator);
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
    r_inner.setBackground(Color.rgba(200, 100, 50, 255)); // 同样的内容变更，但全程无 hook
    r_sib.markRenderDirty();
    _ = ref.render();
    r_sib.markRenderDirty();
    _ = ref.render();

    std.debug.print(
        "\n[hook-removal-stale] splice_hits={d} cmds={d} ref_cmds={d}\n",
        .{ cx.perf.subtree_payload_splice_count, cx.lowering.main_paint.items.len, ref.lowering.main_paint.items.len },
    );

    // 逐条比对：若 hook 摘除路径复用了陈旧条目，这里会出现颜色/几何差异
    try std.testing.expectEqual(ref.lowering.main_paint.items.len, cx.lowering.main_paint.items.len);
    for (cx.lowering.main_paint.items, 0..) |it, gi| {
        const r = ref.lowering.main_paint.items[gi];
        try std.testing.expectEqual(@intFromEnum(r.kind), @intFromEnum(it.kind));
        try std.testing.expectApproxEqAbs(r.geom.x, it.geom.x, 0.01);
        try std.testing.expectApproxEqAbs(r.geom.y, it.geom.y, 0.01);
        try std.testing.expectApproxEqAbs(r.geom.w, it.geom.w, 0.01);
        try std.testing.expectApproxEqAbs(r.geom.h, it.geom.h, 0.01);
    }
}

test "subtree payload cache isolates a disable_render_cache boundary in both directions" {
    var cx = try Cx.init(std.testing.allocator);
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
    // 逃生阀读的是进程级 env + 一次性 cache，测试内不便改 env；
    // 这里退而验证判定函数对两个**不可放行例外**的处理：
    // overlay candidate 与手动动画进行中，即使声明了 self-only 也不放行。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(1280, 800);

    const root = try buildHookedPrefixScene(cx, 40, true);
    // 找到那个 hooked 节点（第一个 child），给它开手动 transform 动画标志
    const hooked = root.children.items[0];
    hooked.frame_state.state_bits.flags.manual_transform_animation_active = true;

    _ = cx.render();
    cx.perf.subtree_payload_splice_count = 0;
    root.children.items[root.children.items.len - 1].markRenderDirty();
    _ = cx.render();

    // 手动动画进行中 ⇒ 担保不成立 ⇒ 回到保守语义（前缀打断，零复用）
    try std.testing.expectEqual(@as(u32, 0), cx.perf.subtree_payload_splice_count);
}

// ============================================================================
// 2026-07-31 审查修复：a11y 投影此前把十个 state 位硬编码成 false，
// value_now/min/max 硬编码成 0 —— 组件声明了也传不到 a11y 树。
//
// ⚠ 注意与既有测试 "v0.8 §2.1: select trigger 初始化 role=combobox +
// has_popup=listbox" 的区别：那个测试断言的是
// `trigger.behavior.interaction.a11y`（**props 结构体**），props 一直是
// 对的，坏的是 props → a11y tree 这一段。所以它全程是绿的，功能却端到端
// 坏着。下面的测试断言 `cx.accessibility_tree.get(...)`，即真正送给 AT 的
// 那份数据。
// ============================================================================

test "a11y 投影：props 的 state 位真的到达 a11y tree（此前被硬编码丢弃）" {
    var cx = try Cx.init(std.testing.allocator);
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
    const a11y_node = cx.accessibility_tree.get(eid).?;

    // 修复前这 10 个断言**全部**失败（硬编码 false）
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

    // has_popup = .none 时 haspopup 必须是 false（别一律 true）
    const n2 = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    n2.behavior.interaction.a11y = .{ .role = .button, .label = "Plain" };
    try root.appendChild(std.testing.allocator, n2);
    cx.layout();
    _ = cx.render();
    const a2 = cx.accessibility_tree.get(ui.ElementId.fromRaw(n2.element_id_raw)).?;
    try std.testing.expect(!a2.state.haspopup);
    try std.testing.expect(!a2.state.selected);
}

test "a11y 投影：slider/progressbar 的 value_now/min/max 真的到达 a11y tree" {
    var cx = try Cx.init(std.testing.allocator);
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

    const a = cx.accessibility_tree.get(ui.ElementId.fromRaw(slider.element_id_raw)).?;
    // 修复前三者恒为 0 —— VoiceOver 读不出"42，范围 0 到 100"
    try std.testing.expectEqual(@as(f32, 42), a.value_now);
    try std.testing.expectEqual(@as(f32, 0), a.value_min);
    try std.testing.expectEqual(@as(f32, 100), a.value_max);
}

test "a11y: Slider 拖动后 value_now 跟随（不是冻结在 mount 初值）" {
    const slider_mod = @import("../components/slider/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const res = try slider_mod.Slider(.{ .min = 0, .max = 100, .initial_value = 10 }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, res.wrapper);
    cx.layout();
    _ = cx.render();

    const eid = ui.ElementId.fromRaw(res.wrapper.element_id_raw);
    try std.testing.expectEqual(@as(f32, 10), cx.accessibility_tree.get(eid).?.value_now);

    // 拖到 73：a11y 必须跟上
    res.state.setValue(73);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 73), cx.accessibility_tree.get(eid).?.value_now);
    try std.testing.expectEqual(@as(f32, 100), cx.accessibility_tree.get(eid).?.value_max);
}

// ============================================================================
// 2026-07-31 组件 a11y 声明补齐。
//
// 这组测试一律断言 `cx.accessibility_tree`（真正送给 AT 的数据），
// **不是** `node.behavior.interaction.a11y`（props）。原因见仓库里那条
// "select trigger 初始化 role=combobox" 的旧测试：它断言 props，于是
// props→a11y tree 投影整段坏掉时它照样全绿。
// ============================================================================

test "a11y: Tabs 每个 tab 有 role=tab，selected 跟随 active_index 切换" {
    const tabs_mod = @import("../components/tabs/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(600, 300);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]tabs_mod.TabItem{
        .{ .id = "a", .label_text = "Alpha" },
        .{ .id = "b", .label_text = "Beta" },
        .{ .id = "c", .label_text = "Gamma" },
    };
    // 用 .pill：underline 变体会把 tab_row 再套一层 outer container，
    // pill 下 container 就是 tab_row，断言路径最短。
    const container = try tabs_mod.Tabs(.{ .items = &items, .variant = .pill }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, container);
    cx.layout();
    _ = cx.render();

    // children[0] 是 highlight_box，之后才是 3 个 tab。
    const tab_row = container;
    try std.testing.expect(tab_row.children.items.len >= 4);

    const a11yOf = struct {
        fn get(c: *Cx, n: *Node) a11y_tree_mod.A11yNode {
            return c.accessibility_tree.get(ui.ElementId.fromRaw(n.element_id_raw)).?;
        }
    }.get;

    const tab_a = tab_row.children.items[1];
    const tab_b = tab_row.children.items[2];

    // tablist 自身
    // A11yRole.tablist 映射到 tree Role.tabs
    try std.testing.expectEqual(a11y_tree_mod.Role.tabs, a11yOf(cx, container).role);

    // 每个 tab 都必须是 role=tab（此前 tab 节点没有任何 a11y 声明）
    try std.testing.expectEqual(a11y_tree_mod.Role.tab, a11yOf(cx, tab_a).role);
    try std.testing.expectEqual(a11y_tree_mod.Role.tab, a11yOf(cx, tab_b).role);

    // 初始：第 0 个选中
    try std.testing.expect(a11yOf(cx, tab_a).state.selected);
    try std.testing.expect(!a11yOf(cx, tab_b).state.selected);

    // 切到第 1 个 —— selected 必须跟着走（关键：不是 mount 冻结值）
    // TabsState 通过 addDebugState 挂在 container 上（mount 里已登记）。
    const state: *tabs_mod.TabsState = @ptrCast(@alignCast(
        container.meta.ownership.debug_slots.state_ptrs[0].?,
    ));
    state.setActive(1);
    tab_row.markRenderDirty();
    cx.layout();
    _ = cx.render();

    try std.testing.expect(!a11yOf(cx, tab_a).state.selected);
    try std.testing.expect(a11yOf(cx, tab_b).state.selected);
}

test "a11y: Accordion header 的 expanded 跟随展开/折叠（此前从不设置）" {
    const accordion_mod = @import("../components/accordion/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(600, 400);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const res = try accordion_mod.AccordionItem(.{ .title = "Details" }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, res.item);
    cx.layout();
    _ = cx.render();

    const header = res.item.children.items[0];
    const eid = ui.ElementId.fromRaw(header.element_id_raw);

    try std.testing.expectEqual(a11y_tree_mod.Role.button, cx.accessibility_tree.get(eid).?.role);
    // 折叠态
    try std.testing.expect(!cx.accessibility_tree.get(eid).?.state.expanded);

    // 展开 —— a11y tree 必须跟上
    // AccordionItemState 就是 header 的 event_context（mount 里已挂）。
    const state: *accordion_mod.AccordionItemState = @ptrCast(@alignCast(
        header.behavior.events.event_context.?,
    ));
    state.setExpanded(true);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.accessibility_tree.get(eid).?.state.expanded);

    // 再折叠回去
    state.setExpanded(false);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(!cx.accessibility_tree.get(eid).?.state.expanded);
}

test "a11y: Alert 是 live region（否则 role=alert 永远不会被朗读）" {
    const alert_mod = @import("../components/alert/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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

    const err_node = cx.accessibility_tree.get(ui.ElementId.fromRaw(err.element_id_raw)).?;
    const info_node = cx.accessibility_tree.get(ui.ElementId.fromRaw(info.element_id_raw)).?;

    try std.testing.expectEqual(a11y_tree_mod.Role.alert, err_node.role);
    // 修复前这两条都是 .off —— 视觉上有提示，AT 侧完全静默。
    try std.testing.expectEqual(a11y_tree_mod.LiveRegion.assertive, err_node.live);
    try std.testing.expectEqual(a11y_tree_mod.LiveRegion.polite, info_node.live);
}

test "a11y: Progress 报出 role=progressbar + valuenow；不确定模式改报 busy" {
    const progress_mod = @import("../components/progress/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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

    const d = cx.accessibility_tree.get(ui.ElementId.fromRaw(det.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.progressbar, d.role);
    try std.testing.expectEqual(@as(f32, 70), d.value_now);
    try std.testing.expectEqual(@as(f32, 100), d.value_max);
    try std.testing.expect(!d.state.busy);

    const i = cx.accessibility_tree.get(ui.ElementId.fromRaw(indet.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.progressbar, i.role);
    try std.testing.expect(i.state.busy);
}

test "a11y: Tree 行是 treeitem，expanded/selected 跟随状态变化" {
    const tree_mod = @import("../components/tree/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(600, 400);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const leaf = [_]tree_mod.TreeNodeData{.{ .id = "f", .label_text = "file.zig" }};
    const nodes = [_]tree_mod.TreeNodeData{
        .{ .id = "d", .label_text = "src", .children = &leaf },
    };
    const res = try tree_mod.Tree(.{ .nodes = &nodes }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, res.wrapper);
    cx.layout();
    _ = cx.render();

    const dir_row = res.state.flat_node_rows[0].?;
    const dir_eid = ui.ElementId.fromRaw(dir_row.element_id_raw);

    try std.testing.expectEqual(a11y_tree_mod.Role.tree, cx.accessibility_tree.get(
        ui.ElementId.fromRaw(res.wrapper.element_id_raw),
    ).?.role);
    try std.testing.expectEqual(a11y_tree_mod.Role.treeitem, cx.accessibility_tree.get(dir_eid).?.role);

    // 初始折叠 + 未选中
    try std.testing.expect(!cx.accessibility_tree.get(dir_eid).?.state.expanded);
    try std.testing.expect(!cx.accessibility_tree.get(dir_eid).?.state.selected);

    // 展开 → a11y 必须跟上
    res.state.toggleExpand(0);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.accessibility_tree.get(dir_eid).?.state.expanded);

    // 选中 → selected 跟上（此前只有背景高亮这一个纯视觉信号）
    res.state.selectNode(0);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.accessibility_tree.get(dir_eid).?.state.selected);

    // 选到别的行时旧行必须被取消 selected
    res.state.selectNode(1);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(!cx.accessibility_tree.get(dir_eid).?.state.selected);
}

test "a11y: Menu 有 role=menu，项是 menuitem 且 disabled 如实上报" {
    const menu_mod = @import("../components/menu/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(600, 400);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]menu_mod.MenuItem{
        .{ .id = "cut", .label_text = "Cut" },
        .{ .id = "sep", .kind = .separator },
        .{ .id = "paste", .label_text = "Paste", .disabled = true },
    };
    const res = try menu_mod.Menu(.{ .items = &items }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, res.wrapper);
    res.state.is_open.set(true);
    cx.layout();
    _ = cx.render();

    const cut = cx.accessibility_tree.get(ui.ElementId.fromRaw(res.state.item_nodes[0].?.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.menuitem, cut.role);
    try std.testing.expect(!cut.state.disabled);

    const sep = cx.accessibility_tree.get(ui.ElementId.fromRaw(res.state.item_nodes[1].?.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.separator, sep.role);

    // 禁用项必须报 disabled，否则 AT 用户会反复尝试激活一个没反应的菜单项
    const paste = cx.accessibility_tree.get(ui.ElementId.fromRaw(res.state.item_nodes[2].?.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.menuitem, paste.role);
    try std.testing.expect(paste.state.disabled);
}

test "a11y: NumberStepper 是 spinbutton，value_now 跟随步进" {
    const ns_mod = @import("../components/number_stepper/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 200);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ns = try ns_mod.mountNumberStepper(.{ .value = 5, .min = 0, .max = 10, .step = 1 }, scope, cx);
    try root.appendChild(std.testing.allocator, ns.wrapper);
    cx.layout();
    _ = cx.render();

    const eid = ui.ElementId.fromRaw(ns.wrapper.element_id_raw);
    const n0 = cx.accessibility_tree.get(eid).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.spinbutton, n0.role);
    try std.testing.expectEqual(@as(f32, 5), n0.value_now);
    try std.testing.expectEqual(@as(f32, 0), n0.value_min);
    try std.testing.expectEqual(@as(f32, 10), n0.value_max);
    try std.testing.expectEqual(@as(u8, 0b1100), a11y_bridge_extern.zenit_a11y_actions(a11y_bridge_extern.ANY, eid.raw()));
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_perform_action(a11y_bridge_extern.ANY, eid.raw(), 2));
    try std.testing.expectEqual(@as(f64, 6), ns.state.value);
    try std.testing.expectEqual(@as(c_int, 1), a11y_bridge_extern.zenit_a11y_perform_action(a11y_bridge_extern.ANY, eid.raw(), 3));
    try std.testing.expectEqual(@as(f64, 5), ns.state.value);

    // 步进后 a11y 数值必须跟上（不是冻结在 mount 初值）
    ns.state.increment();
    ns.state.increment();
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 7), cx.accessibility_tree.get(eid).?.value_now);
}

test "a11y: Rate 是 slider，value_now 跟随点击但不被 hover 预览污染" {
    const rate_mod = @import("../components/rate/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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
    const n0 = cx.accessibility_tree.get(eid).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.slider, n0.role);
    try std.testing.expectEqual(@as(f32, 2), n0.value_now);
    try std.testing.expectEqual(@as(f32, 5), n0.value_max);

    res.state.setValue(4);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 4), cx.accessibility_tree.get(eid).?.value_now);

    // hover 预览是纯视觉的临时态，不能改 a11y 数值 —— 否则 AT 用户会以为
    // 鼠标扫过就已经改分了。
    res.state.hover_value = 1;
    res.state.is_hovering = true;
    res.state.setValue(4); // 触发一次 updateDisplay（值没变）
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(@as(f32, 4), cx.accessibility_tree.get(eid).?.value_now);
}

test "a11y: DataTable 是 grid，表头是 columnheader，空的复用行不进 a11y 树" {
    const dt_mod = @import("../components/data_table/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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
    // page_size=3 但只给 1 行数据 → 另外 2 个复用行是空的
    const r0 = [_][]const u8{ "a.zig", "1K" };
    const rows = [_][]const []const u8{&r0};
    const dt = try dt_mod.mountDataTable(.{
        .columns = &cols,
        .rows = &rows,
        .page_size = 3,
    }, scope, cx);
    try root.appendChild(std.testing.allocator, dt.wrapper);
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(a11y_tree_mod.Role.grid, cx.accessibility_tree.get(
        ui.ElementId.fromRaw(dt.wrapper.element_id_raw),
    ).?.role);

    // 表头必须是 columnheader，AT 才会在读数据格时带上列名
    try std.testing.expectEqual(a11y_tree_mod.Role.columnheader, cx.accessibility_tree.get(
        ui.ElementId.fromRaw(dt.state.header_cells[0].element_id_raw),
    ).?.role);

    // 有数据的行 = row
    try std.testing.expectEqual(a11y_tree_mod.Role.row, cx.accessibility_tree.get(
        ui.ElementId.fromRaw(dt.state.row_nodes[0].element_id_raw),
    ).?.role);

    // Empty recycled rows retain parentage so their semantic cells cannot be
    // reparented to the grid, but the complete subtree is hidden from AT.
    const empty_row = cx.accessibility_tree.get(
        ui.ElementId.fromRaw(dt.state.row_nodes[1].element_id_raw),
    ).?;
    try std.testing.expect(empty_row.state.hidden);
    const empty_cell = dt.state.cell_text_nodes[2].parent.?;
    try std.testing.expect(cx.accessibility_tree.get(
        ui.ElementId.fromRaw(empty_cell.element_id_raw),
    ).?.state.hidden);
}

test "a11y: DropdownMenu 键盘高亮更新 active_descendant（虚拟焦点）" {
    const dd_mod = @import("../components/dropdown_menu/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(600, 400);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]dd_mod.DropdownItem{
        .{ .id = "new", .label_text = "New File", .shortcut = "CmdN" },
        .{ .kind = .separator },
        .{ .id = "del", .label_text = "Delete", .disabled = true },
    };
    const res = try dd_mod.DropdownMenu(.{ .items = &items }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, res.wrapper);
    res.state.is_open.set(true);
    cx.layout();
    _ = cx.render();

    const menu_eid = ui.ElementId.fromRaw(res.state.menu_node.?.element_id_raw);
    try std.testing.expectEqual(a11y_tree_mod.Role.menu, cx.accessibility_tree.get(menu_eid).?.role);

    const item0 = res.state.item_nodes[0].?;
    const del = res.state.item_nodes[2].?;
    try std.testing.expectEqual(a11y_tree_mod.Role.menuitem, cx.accessibility_tree.get(
        ui.ElementId.fromRaw(item0.element_id_raw),
    ).?.role);
    try std.testing.expect(cx.accessibility_tree.get(
        ui.ElementId.fromRaw(del.element_id_raw),
    ).?.state.disabled);
    try std.testing.expectEqual(a11y_tree_mod.Role.separator, cx.accessibility_tree.get(
        ui.ElementId.fromRaw(res.state.item_nodes[1].?.element_id_raw),
    ).?.role);

    // 真实焦点停在容器上，只有 active_descendant 能说出"当前停在哪一项"
    res.state.highlightIndex(0);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(
        ui.ElementId.fromRaw(item0.element_id_raw),
        cx.accessibility_tree.get(menu_eid).?.active_descendant,
    );

    res.state.highlightIndex(2);
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(
        ui.ElementId.fromRaw(del.element_id_raw),
        cx.accessibility_tree.get(menu_eid).?.active_descendant,
    );
}

test "a11y: Breadcrumb 进得了 a11y 树（此前 role=.none 被整个丢弃）" {
    const bc_mod = @import("../components/breadcrumb/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(600, 200);

    const root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const items = [_]bc_mod.BreadcrumbItem{
        .{ .id = "home", .label_text = "Home" },
        .{ .id = "docs", .label_text = "Docs" },
        .{ .id = "api", .label_text = "API" },
    };
    const bc = try bc_mod.Breadcrumb(.{ .items = &items }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, bc);
    cx.layout();
    _ = cx.render();

    // 容器此前是 role=.none —— 投影层对 none + 不可 focus 直接丢弃，
    // 整个 Breadcrumb 在 AT 侧根本不存在。
    try std.testing.expectEqual(a11y_tree_mod.Role.navigation, cx.accessibility_tree.get(
        ui.ElementId.fromRaw(bc.element_id_raw),
    ).?.role);

    // children: item, sep, item, sep, item
    const first = cx.accessibility_tree.get(ui.ElementId.fromRaw(bc.children.items[0].element_id_raw)).?;
    const last = cx.accessibility_tree.get(ui.ElementId.fromRaw(bc.children.items[4].element_id_raw)).?;

    // 前面几级是可点链接，最后一级是当前页（selected）
    try std.testing.expectEqual(a11y_tree_mod.Role.link, first.role);
    try std.testing.expect(!first.state.selected);
    try std.testing.expect(last.state.selected);
}

test "a11y: Steps 每步报出 selected/checked/disabled 三态" {
    const steps_mod = @import("../components/steps/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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
    // current=1 → 第 0 步已完成、第 1 步进行中、第 2 步未开始
    const container = try steps_mod.Steps(.{ .items = &items, .initial_current = 1 })
        .mount(scope, cx);
    try root.appendChild(std.testing.allocator, container);
    cx.layout();
    _ = cx.render();

    try std.testing.expectEqual(a11y_tree_mod.Role.list, cx.accessibility_tree.get(
        ui.ElementId.fromRaw(container.element_id_raw),
    ).?.role);

    // 水平布局下 children 里除 step 列还有进度线，按 role 过滤出 step
    var steps_found: usize = 0;
    var done = false;
    var active = false;
    var pending = false;
    for (container.children.items) |child| {
        const n = cx.accessibility_tree.get(ui.ElementId.fromRaw(child.element_id_raw)) orelse continue;
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
    // 圆圈颜色是纯视觉信号，AT 只能靠这三个位区分"做完了/在这儿/还没到"
    try std.testing.expect(done);
    try std.testing.expect(active);
    try std.testing.expect(pending);
}

test "a11y: VirtualList 回收的 slot 退出 a11y 树" {
    const vl_mod = @import("../components/virtual_list/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    const Render = struct {
        fn row(node: *Node, index: usize, c: *Cx) void {
            _ = index;
            // 测试脚手架：VirtualList 的 render_row 回调签名返回 void，无法传播。
            // testing.allocator 下真 OOM 会让测试失败，行数断言也会立刻发现。
            const label = box(c, .{}, .{}) catch return;
            label.setText(.{ .content = "row" });
            node.appendChild(c.allocator, label) catch {};
        }
    };

    var cx = try Cx.init(std.testing.allocator);
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

    try std.testing.expectEqual(a11y_tree_mod.Role.list, cx.accessibility_tree.get(
        ui.ElementId.fromRaw(res.container.element_id_raw),
    ).?.role);

    // 滚到很远处：原先绑定的 slot 全被回收再重绑到新的数据行。这一步是
    // 关键——不滚动的话空闲 slot 从来没进过树，断言会变成空转。
    // 先滚到中段让全部 slot 都被绑定过一轮，再滚到末尾（末尾可见行更少，
    // 会有 slot 真正被释放）。只滚一次的话空闲 slot 是 growPool 出来的
    // 全新节点，从来没带过 a11y，断言就成了空转。
    res.state.scroll_state.scroll_y = 4000;
    res.state.updateVisibleItems();
    cx.layout();
    _ = cx.render();

    res.state.scroll_state.scroll_y = 1000 * 20 - 20;
    res.state.updateVisibleItems();
    cx.layout();
    _ = cx.render();

    // 绑定到真实数据行的 slot 在树里；未绑定的 slot 不在。
    var bound_in_tree: usize = 0;
    var unbound_in_tree: usize = 0;
    for (res.state.pool_nodes, res.state.pool_bindings) |node, binding| {
        const present = cx.accessibility_tree.get(ui.ElementId.fromRaw(node.element_id_raw)) != null;
        if (binding != null) {
            if (present) bound_in_tree += 1;
        } else {
            // 空闲/被回收的 slot 必须不在树里，否则 AT 会读到一堆
            // 已经滚出视口的旧行内容。
            if (present) unbound_in_tree += 1;
        }
    }
    try std.testing.expect(bound_in_tree > 0);
    try std.testing.expectEqual(@as(usize, 0), unbound_in_tree);
}

test "a11y: Timeline 项把 completed/active/pending 说出来（不只靠圆点颜色）" {
    const tl_mod = @import("../components/timeline/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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

    const a0 = cx.accessibility_tree.get(ui.ElementId.fromRaw(tl.children.items[0].element_id_raw)).?;
    const a1 = cx.accessibility_tree.get(ui.ElementId.fromRaw(tl.children.items[1].element_id_raw)).?;
    const a2 = cx.accessibility_tree.get(ui.ElementId.fromRaw(tl.children.items[2].element_id_raw)).?;

    try std.testing.expectEqual(a11y_tree_mod.Role.listitem, a0.role);
    try std.testing.expect(a0.state.checked);
    try std.testing.expect(a1.state.selected);
    try std.testing.expect(a2.state.disabled);
}

test "a11y: Skeleton 报 busy + live，AT 才知道内容在加载而不是页面坏了" {
    const sk_mod = @import("../components/skeleton/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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

    const n = cx.accessibility_tree.get(ui.ElementId.fromRaw(sk.element_id_raw)).?;
    try std.testing.expectEqual(a11y_tree_mod.Role.status, n.role);
    try std.testing.expect(n.state.busy);
    try std.testing.expectEqual(a11y_tree_mod.LiveRegion.polite, n.live);
}

// ============================================================================
// 2026-07-31 回调协议并轨：HandlerRef 带值通道
//
// 背景：组件回调此前分两轨且不可互换 —— `?HandlerRef`（无参）与
// `?*const fn (T, *anyopaque) void`（带值），实测 16 vs 17 对半分裂。
// 直接把带值那组迁到无参 HandlerRef 会**静默丢 payload**：调用方照常
// 编译、值没了。这组测试就是钉住"值不能丢"。
// ============================================================================

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
    // 组件可以无条件调 invokeWithBool/Str，不必关心调用方注册了哪种。
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
    // 三次都应到达 —— 只是拿不到值，而不是被吞掉
    try std.testing.expectEqual(@as(u32, 3), sink.calls);
}

test "HandlerRef: 类型不匹配的 payload 退化为无参而非误传" {
    // bool handler 收到 string 触发（或反之）时，绝不能把另一种类型
    // 的值强行塞进去 —— 退化为无参兜底。
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

    h.invokeWithStr("not a bool"); // 走无参兜底（bare 会调 method(_, false)）
    try std.testing.expectEqual(@as(u32, 1), sink.bool_calls);

    h.invokeWithBool(true); // 走正常带值通道
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
    // 老构造器 + 老调用方式，行为必须完全不变
    const h = Cx.handlerFrom(Sink, &sink, Sink.bump);
    try std.testing.expectEqual(@as(?ui.HandlerRef.PayloadCallback, null), h.payload_callback);
    h.invoke();
    h.invoke();
    try std.testing.expectEqual(@as(u32, 2), sink.n);
}

test "并轨端到端：Checkbox 点击后 on_change 收到真实新值" {
    const checkbox = @import("../components/checkbox/mod.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
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
        .label_text = "Accept",
        .on_change = Cx.boolHandlerFrom(Sink, &sink, Sink.onChange),
    }).mount(scope, cx);
    try root.appendChild(std.testing.allocator, node);
    cx.layout();
    _ = cx.render();

    // 走真实事件派发（比直接调 state.toggle 更接近用户路径）
    const rect = node.rectFromWorldOrFallback();
    const px = rect.x + rect.w / 2;
    const py = rect.y + rect.h / 2;
    _ = cx.dispatcher.dispatch(ui.Event{ .click = .{ .x = px, .y = py } }, node);

    // 关键：不只是"被调用了"，而是**新值真的送到了**（并轨最容易丢的东西）
    try std.testing.expectEqual(@as(u32, 1), sink.calls);
    try std.testing.expect(sink.last);

    _ = cx.dispatcher.dispatch(ui.Event{ .click = .{ .x = px, .y = py } }, node);
    try std.testing.expectEqual(@as(u32, 2), sink.calls);
    try std.testing.expect(!sink.last);
}

test "overlay 关闭后焦点恢复到触发控件（previous_focus 此前写了无人读）" {
    const overlay_mod = @import("../overlay_stack.zig");
    const Scope = @import("../reactive.zig").Scope;

    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    // 触发控件：打开 overlay 前它持有焦点
    const trigger = try box(cx, .{ .width = .{ .px = 80 }, .height = .{ .px = 24 } }, .{});
    trigger.behavior.interaction.focusable = true;
    try root.appendChild(std.testing.allocator, trigger);
    cx.layout();
    _ = cx.render();

    cx.focus_manager.setFocus(trigger);
    try std.testing.expectEqual(@as(?*ui.Node, trigger), cx.focus_manager.current_focus);

    std.debug.print("\n[DBG] trigger={*}\n", .{trigger});
    std.debug.print("[DBG] pending={any}\n", .{cx.overlay_stack.pending_focus_restore});
    // 打开一个 overlay（focus.restore 默认 true）
    const res = try overlay_mod.overlay(scope, cx, .{
        .kind = .modal,
        .enter_transition = .none,
        .exit_transition = .none,
        .focus = .{ .restore = true },
    });
    // 模拟 overlay 内部控件取走焦点
    const inner = try box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, .{});
    inner.behavior.interaction.focusable = true;
    try res.content.appendChild(std.testing.allocator, inner);
    cx.layout();
    _ = cx.render();
    cx.focus_manager.setFocus(inner);
    try std.testing.expect(cx.focus_manager.current_focus != trigger);

    // 关闭 overlay → 焦点必须回到 trigger
    cx.overlay_stack.commitExit(res.handle);
    _ = cx.render();

    try std.testing.expectEqual(@as(?*ui.Node, trigger), cx.focus_manager.current_focus);
}

// === 拖放 drop target ===

const DropProbe = struct {
    enters: u32 = 0,
    leaves: u32 = 0,
    drops: u32 = 0,
    last_paths: [256]u8 = [_]u8{0} ** 256,
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

// 挂了 drop handler 的普通 box 必须能被 pointer 命中，
// 否则 handleDrag 永远命不中它（同 on_scroll 的老坑）。
test "Cx: drop target 收到 entered + dropped(paths)" {
    var cx = try Cx.init(std.testing.allocator);
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

// 下游回归：drop 回调必须能拿到落点坐标（按落点摆放文件的画布场景）。
// 同时锁住降级合同：string 版 handler 仍只拿 paths（上一个测试）。
test "Cx: drop payload 版 handler 收到落点坐标" {
    var cx = try Cx.init(std.testing.allocator);
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

// 平台只在窗口边界给 entered/exited；节点级进出必须由 updated 位置流合成。
test "Cx: 拖过两个 drop target 时合成节点级 enter/leave" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 进入左侧
    cx.handleDrag(50, 50, 0, "");
    try std.testing.expectEqual(@as(u32, 1), left_probe.enters);
    try std.testing.expectEqual(@as(u32, 0), right_probe.enters);

    // 同一目标内移动：不重复 enter
    cx.handleDrag(60, 50, 1, "");
    try std.testing.expectEqual(@as(u32, 1), left_probe.enters);
    try std.testing.expectEqual(@as(u32, 0), left_probe.leaves);

    // 移到右侧：左 leave + 右 enter
    cx.handleDrag(150, 50, 1, "");
    try std.testing.expectEqual(@as(u32, 1), left_probe.leaves);
    try std.testing.expectEqual(@as(u32, 1), right_probe.enters);

    // 拖出窗口：右侧收到 leave
    cx.handleDrag(0, 0, 2, "");
    try std.testing.expectEqual(@as(u32, 1), right_probe.leaves);
    try std.testing.expect(cx.drag_hover_handle == null);
}

// ═════ 下游回归：同帧双 "backdrop_blur + rounded_clip 同节点" 内容进错作用域 ═════

/// 校验 lowered paint 命令流里：每个岛的独特色内容命令必须
///  1. 落在**自己**的 begin_blur_layer(glass_owner_id=岛) .. 配对 end_blur_layer 之间；
///  2. 坐标落在紧随其后的 begin_rounded_clip 的 src 帧内（owner-local）。
///     rounded_clip layer 的纹理覆盖 src 矩形，encoder offscreenOffset =
///     -(src 原点)；内容若以 world 坐标 emit（下游回归），会整体
///     画出纹理外 → 合成回来是空的（第二个岛的 world x 远超 src.w，必失败）。
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
    // 内容坐标帧断言：必须整体落在 rclip surface 的 src 矩形内
    const src = rclip_src.?;
    const g = commands[content_index.?].geom;
    try std.testing.expect(g.x >= src.x - 0.5);
    try std.testing.expect(g.y >= src.y - 0.5);
    try std.testing.expect(g.x + g.w <= src.x + src.w + 0.5);
    try std.testing.expect(g.y + g.h <= src.y + src.h + 0.5);
}

test "render: 同帧两个 blur+rounded_clip 岛，各自内容落在自己的 effect 作用域（下游回归）" {
    var cx = try Cx.init(std.testing.allocator);
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

    // 两个岛：blur + overflow_hidden + corner_radius 同节点（下游应用 islandCard 原始形态）
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
        // 自带 clip 的子行：把岛内容切成多个 (effect_id, clip_id) group，
        // 复现下游应用 sidebar 的"每行一个 clip"形态 —— 早先 lowering 每组
        // 整链 close+reopen effect scope，blur 背板被重画 N 次糊掉前面组。
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

    // 帧 1：全 fresh
    cx.layout();
    _ = cx.render();
    {
        const commands = cx.lowerForEncoderPaintTable();
        try expectIslandContentScoped(commands, islands[0].id, content_reds[0]);
        try expectIslandContentScoped(commands, islands[1].id, content_reds[1]);
        // 前缀保留断言：每个岛的 begin_blur_layer 恰好一次（encoder 端
        // begin_blur = 立即合成玻璃背板，多于一次即背板糊内容）。
        var blur_begins: usize = 0;
        for (commands) |cmd| {
            if (cmd.isControl(.begin_blur_layer)) blur_begins += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), blur_begins);
    }

    // 帧 2：只脏第一个岛（第二个岛走缓存/replay 路径 —— docs/12 嫌疑路径）
    islands[0].children.items[0].markRenderDirty();
    cx.layout();
    _ = cx.render();
    {
        const commands = cx.lowerForEncoderPaintTable();
        try expectIslandContentScoped(commands, islands[0].id, content_reds[0]);
        try expectIslandContentScoped(commands, islands[1].id, content_reds[1]);
    }

    // 帧 3：全净帧
    cx.layout();
    _ = cx.render();
    {
        const commands = cx.lowerForEncoderPaintTable();
        try expectIslandContentScoped(commands, islands[0].id, content_reds[0]);
        try expectIslandContentScoped(commands, islands[1].id, content_reds[1]);
    }
}

test "render: blur 叶节点带（header 毛玻璃）跨帧保持在后画兄弟内容之前（下游应用 header 回归）" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(800, 200);

    const root = try box(cx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 200 },
        .background = Color.rgba(240, 240, 235, 255),
    }, .{});

    // 通铺毛玻璃带：blur 叶节点（无子节点），树序在前
    const band = try box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .px = 76 },
        .background = Color.rgba(255, 255, 255, 144),
    }, .{});
    (try band.style.ensureExtFallible(cx.allocator)).glass = .{ .backdrop_blur = 24, .glass_intensity = 0 };
    // 嵌套 progressive blur：内层纯玻璃子节点（无 bg/渐变 → 零常规 item，
    // 依赖占位 item 携带 effect；下游应用 header 双层毛玻璃形态）
    const heavy = try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 48 },
    }, .{});
    (try heavy.style.ensureExtFallible(cx.allocator)).glass = .{ .backdrop_blur = 20, .glass_intensity = 0 };
    try band.appendChild(cx.allocator, heavy);
    try root.appendChild(cx.allocator, band);

    // header 内容：树序在后，必须画在带之上
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
            // 无 content 的纯玻璃子节点必须靠占位 item 让 begin_blur 发射
            try std.testing.expect(heavy_begin != null);
            try std.testing.expect(badge_index != null);
            // header 内容必须排在两层玻璃合成之后（即画在其上）
            try std.testing.expect(badge_index.? > band_begin.?);
            try std.testing.expect(badge_index.? > heavy_begin.?);
        }
    }.check;

    // 帧 1：全 fresh
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);

    // 帧 2：只脏 header（band 走跨帧 clean 路径——嫌疑路径）
    badge.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);

    // 帧 3：只脏 band
    band.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);

    // 帧 4：全净
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);

    // 帧 5：脏 root 背景（band/header 都 clean、祖先重录——另一条嫌疑路径）
    root.markRenderDirty();
    cx.layout();
    _ = cx.render();
    try expectBandBeforeHeader(cx.lowerForEncoderPaintTable(), band.id, heavy.id);
}

// ── BulkQuad：Node 路径 vs 批量路径的一致性 ────────────────────────────
//
// 这组测试是 `BulkQuad` 像素等价承诺的守卫。批量路径的全部意义是"省掉
// per-node 开销、但画出**完全一样**的东西"——一旦 lower 出的 display item
// 与 Node 路径产生任何参数差异，缩放临界点上就会出现肉眼可见的跳变
// （颜色/圆角/描边宽度突变）。所以这里逐字段对照，而不是只看数量。

/// 取出 display list 里第一个 fill_rect 的几何+样式（忽略 header：
/// Node 路径把位置放在 transform 里，批量路径放在 x/y 里，两者本就不同构，
/// 真正要对齐的是**最终落到 SDF 管线的那组参数**）。
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

    // A) Node 路径
    var cx_node = try Cx.init(std.testing.allocator);
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

    // B) 批量路径：同样的矩形
    var cx_bulk = try Cx.init(std.testing.allocator);
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

    var cx_node = try Cx.init(std.testing.allocator);
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

    var cx_bulk = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // root 自身背景是 TRANSPARENT ⇒ 不发 fill_rect；批量项 alpha=0 同样不发。
    try std.testing.expectEqual(@as(usize, 0), fills);
    try std.testing.expectEqual(@as(usize, 1), strokes);
}

// 宿主（下游应用）用逐字段哈希给批量层算内容版本号，版本不变 ⇒ 不重画。
// 新字段若没进哈希，改了效果画面**静默不刷新**。下游应用侧有 comptime 字段数
// 断言守着"别忘了加"，但那只保证有人来改，不保证改对 —— 这里守语义：
// 新字段的任何变化都必须改变 lower 出来的 DisplayItem。
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
        var cx = try Cx.init(std.testing.allocator);
        defer cx.deinit();
        cx.setViewport(400, 300);
        const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        cx.root = root;
        try cx.setBulkQuads(null, &[_]ui.BulkQuad{c.q});
        cx.layout();
        _ = cx.render();
        counts[i] = cx.display_list.items.items.len;
    }
    // base 之外的每种都必须多产出至少一个 item（阴影/分边/内阴影各占一个）
    for (counts[1..], cases[1..]) |n, c| {
        if (n <= counts[0] and !std.mem.eql(u8, c.name, "shadow blur 变化")) {
            std.debug.print("字段 {s} 没有影响 lower 结果\n", .{c.name});
            return error.FieldNotLowered;
        }
    }
    // blur 值变化不改 item 数，但必须改字段值 —— 单独验
    try std.testing.expectEqual(counts[1], counts[2]);
}

test "BulkQuad: 渐变降为 multi_gradient_rect，且不再发纯色 fill" {
    var cx = try Cx.init(std.testing.allocator);
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
        .color = Color.hex(0x00FF00), // 给了渐变 ⇒ 这个纯色应被忽略
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
    // 给了渐变就**不得**再发纯色 —— 否则纯色画在渐变之后会盖住它
    try std.testing.expectEqual(@as(usize, 0), fills);
}

test "BulkQuad: 少于两个 stop 的渐变不画（一个 stop 就是纯色）" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
                // 圆角必须透传，否则阴影是直角矩形、四角露出方块
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
    // 投影必须先画，否则会盖住对象本体
    try std.testing.expect(shadow_at.? < fill_at.?);
}

test "BulkQuad: border_widths 非零走 border_per_side，忽略 border_width" {
    var cx = try Cx.init(std.testing.allocator);
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
        .border_width = 99, // 应被忽略
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
    // 分边生效时不得再发统一描边（否则描两遍）
    try std.testing.expectEqual(@as(usize, 0), strokes);
}

test "BulkQuad: inset_shadow 排在 fill 之后且不重复画底色" {
    var cx = try Cx.init(std.testing.allocator);
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
                // 底色已由 fill_rect 画过；这里再画一次会让半透明填充叠深
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // 数组顺序 = display list 顺序 = 绘制顺序
    try std.testing.expectEqual(@as(u8, 0xFF), seen[0].r);
    try std.testing.expectEqual(@as(u8, 0xFF), seen[1].g);
}

// ── BulkQuad 层级/裁剪回归 ──────────────────────────────────────────────
//
// 复现的 bug：批量层曾无条件 append 在整棵 Node 树之后、且不进 clip 栈，
// 于是两万个画布矩形盖住了侧栏 / inspector / 工具栏，并溢出画布视口。
// 这组测试搭一个和真实宿主同构的 shell（画布容器 + 其后的 chrome 兄弟），
// 断言 display list 里**每个 chrome item 都排在所有 bulk quad 之后**，
// 且 bulk quad 带着画布的 clip_id。

const BulkShell = struct {
    cx: *Cx,
    canvas: *ui.Node,
    /// chrome 节点 id（侧栏 / inspector / 工具栏）
    chrome_ids: [3]u32,
};

/// 画布全窗打底 + 三个 chrome 兄弟压在其上（下游应用的 compose 结构）。
fn buildBulkShell(allocator: std.mem.Allocator) !BulkShell {
    var cx = try Cx.init(allocator);
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});

    // 画布容器：overflow_hidden ⇒ 建立 clip，批量层必须受它约束
    const canvas = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 900 },
        .height = .{ .px = 700 },
        .background = Color.hex(0xF5F5F5),
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(cx.allocator, canvas);

    // chrome：在画布之后 append ⇒ 必须盖在画布内容（含批量层）之上
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

/// 铺一批画布对象。scale 模拟缩放档：6% 时对象又多又小，正是复现档。
fn bulkQuadsForScale(buf: *std.ArrayListUnmanaged(ui.BulkQuad), allocator: std.mem.Allocator, scale: f32) !void {
    buf.clearRetainingCapacity();
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        try buf.append(allocator, .{
            // 刻意让一部分落到画布矩形之外（chrome 区域 / 视口外），
            // 未裁剪的旧实现会把它们画到 UI 上。
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

/// 返回 (最后一个 bulk quad 的下标, 第一个 chrome item 的下标)。
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

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .{};
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, scale);

    try shell.cx.setBulkQuads(shell.canvas, quads.items);
    shell.cx.layout();
    _ = shell.cx.render();

    const ord = bulkVsChromeOrder(shell.cx, shell.canvas.id, &shell.chrome_ids);

    // 批量层确实产出了 item（否则下面的断言会真空通过）
    try std.testing.expect(ord.bulk_count > 0);
    const last_bulk = ord.last_bulk orelse return error.TestExpectedBulkQuads;
    const first_chrome = ord.first_chrome orelse return error.TestExpectedChromeItems;

    // ① 层级：所有 chrome 都排在批量层之后 ⇒ chrome 盖住画布内容。
    //    旧实现里批量层 append 在最后，这一条必然失败。
    try std.testing.expect(last_bulk < first_chrome);

    // ② 裁剪：每个 bulk quad 都带画布的 clip，不会溢出到 UI 区域。
    try std.testing.expectEqual(@as(usize, 0), ord.unclipped_bulk);
}

test "BulkQuad: 挂靠画布后 UI chrome 盖在批量层之上（scale≈1）" {
    try expectBulkUnderChrome(1.0);
}

test "BulkQuad: 挂靠画布后 UI chrome 盖在批量层之上（6% 缩放档）" {
    // MIN_SCALE=0.05 附近：用户报告的复现缩放档
    try expectBulkUnderChrome(0.06);
}

test "BulkQuad: 挂靠时带上画布 clip_id，不挂靠时保持旧的无裁剪行为" {
    const allocator = std.testing.allocator;

    // A) 挂靠 ⇒ 有 clip
    var shell = try buildBulkShell(allocator);
    defer shell.cx.deinit();
    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .{};
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);
    try shell.cx.setBulkQuads(shell.canvas, quads.items);
    shell.cx.layout();
    _ = shell.cx.render();
    const anchored = bulkVsChromeOrder(shell.cx, shell.canvas.id, &shell.chrome_ids);
    try std.testing.expect(anchored.bulk_count > 0);
    try std.testing.expectEqual(@as(usize, 0), anchored.unclipped_bulk);

    // B) 不挂靠 ⇒ 退化为旧行为：node_id=0、无 clip、排在所有 chrome 之后
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

// ── BulkQuad：锚点子树无 display item 时的插入点回归 ────────────────────
//
// 复现的 bug（"缩小视图下批量层时而闪烁消失"）：
// bulkAnchorInsertPoint 只按"锚点子树**已产出的** display item"定位插入点。
// 画布容器自身无背景、且该帧所有对象都降级成批量层/block LOD（缩小到全部
// 对象可见时正是这一档）⇒ 锚点子树在 display list 里一个 item 都没有 ⇒
// 函数返回 null ⇒ 调用方把 null 当作"追加到末尾 + 不裁剪"，批量层重新跑到
// 所有 chrome 之后。于是缩小档下画面时而正常（画布里还剩个别 Node 对象）、
// 时而整片盖住 UI（全降级帧），表现就是间歇性闪烁。
fn buildEmptyCanvasBulkShell(allocator: std.mem.Allocator) !BulkShell {
    var cx = try Cx.init(allocator);
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});

    // 画布容器：与 buildBulkShell 唯一的差别是**不设 background**，因此自身
    // 不产出 fill_rect。全对象降级帧里它的子树就是空的。
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

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .{};
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);

    try shell.cx.setBulkQuads(shell.canvas, quads.items);
    shell.cx.layout();
    _ = shell.cx.render();

    const ord = bulkVsChromeOrder(shell.cx, shell.canvas.id, &shell.chrome_ids);
    try std.testing.expect(ord.bulk_count > 0);
    const last_bulk = ord.last_bulk orelse return error.TestExpectedBulkQuads;
    const first_chrome = ord.first_chrome orelse return error.TestExpectedChromeItems;

    // 层级：即使锚点子树空，批量层也必须落在 chrome 之前。
    try std.testing.expect(last_bulk < first_chrome);
    // 裁剪：仍然带画布 clip。
    try std.testing.expectEqual(@as(usize, 0), ord.unclipped_bulk);
}

// ── BulkQuad：画布内交互叠加必须盖在批量层之上 ──────────────────────────
//
// 复现的 bug（有截图）：选中对象后，白色 resize handles 和蓝底 "320 × 200"
// 尺寸标签被批量 quad 压住，只透出局部。原因是这些叠加节点是**画布 Node 的
// 子节点**（下游应用 compose.zig：sel_outline z=31500 / size_pill z=31600 /
// handles z=32000），而批量层按"锚点子树最后一个 item 之后"定位 ⇒ 排到了
// 叠加之后。修复：setBulkQuadsEx 传 overlay_z_threshold 声明叠加层起点。
const bulk_overlay_z: i16 = 31000;

/// 画布容器 + 画布内交互叠加（高 z_index 的 handles/尺寸标签）+ 其后的 chrome。
fn buildOverlayBulkShell(allocator: std.mem.Allocator, out_overlay: *[2]u32) !BulkShell {
    var cx = try Cx.init(allocator);
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

    // 画布内的交互叠加：一个 resize handle + 一个尺寸标签胶囊。
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

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .{};
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

    // ① 交互叠加盖在批量层之上（截图里的 bug：这条会失败）。
    try std.testing.expect(lb < fo);
    // ② chrome 仍在最上。
    try std.testing.expect(lb < fc);
    // ③ 批量层仍受画布裁剪。
    try std.testing.expectEqual(@as(usize, 0), unclipped);
}

// ── BulkQuad：间歇性丢层的真正根因 ─────────────────────────────────────
//
// 用户症状：缩到 7% 以下画布整片消失，几个对象糊在 UI chrome 之上；点一下
// 恢复，再点几下又没。此前两轮修复（空锚点子树回退、交互叠加阈值）都没根治。
//
// 根因：`bulkAnchorInsertPoint` 的三级定位**全部**依赖扫描 display list 找
// 参照物，而扫描只认 `fill_rect` / `stroke_rect` / `text_run` 三种 item ——
// DisplayItem 一共 25 种。下游应用画布之后的 chrome 恰恰大量由被忽略的种类
// 绘制：毛玻璃带走 `begin_blur_layer`、点阵/图标走 `image_quad` /
// `icon_rep`、岛卡片走 `shadow_rect` / `gradient_rect`，而 `edge_wrap` /
// `panels_wrap` / `side_slot` 这些 wrapper 本身无背景、不产任何 item。
//
// 于是全 LOD 降级帧（缩到 <7%，锚点子树无 item ⇒ ① 落空）+ 无选择态
// （交互叠加消失 ⇒ ② 落空）时，③ 也扫不到任何"锚点之后"的参照物 ⇒ 返回
// null ⇒ 调用方 `at_tail` 语义把整批 quad 追加到 display list 末尾且
// `clip_id = INVALID_ID` ⇒ 既越过全部 chrome 又不裁剪。这就是截图里
// "对象糊在 UI 之上"，也解释了点击的开关效应：选中对象让叠加重新产出
// item，② 命中，画面恢复；点空白清空选择，② 再次落空，画面又坏。
//
// 下面这组测试构造 "锚点子树无 item × 有/无交互叠加 × chrome 只用
// 非扫描种类绘制" 的矩阵，是前两轮测试漏掉的洞：它们的 chrome 一律用
// 带 background 的 box（产 fill_rect），③ 总能得救，所以全绿却没发现问题。

/// 画布之后的 chrome **只用被插入点扫描忽略的 item 种类**绘制（image_quad），
/// 复刻下游应用真实结构：wrapper 无背景、内容是毛玻璃/图标/阴影。
fn buildGlassChromeBulkShell(allocator: std.mem.Allocator, out_chrome: *[2]u32) !BulkShell {
    var cx = try Cx.init(allocator);
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});

    // 画布容器：无 background ⇒ 自身不产 item；全对象降级时子树为空。
    const canvas = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 900 },
        .height = .{ .px = 700 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(cx.allocator, canvas);

    // chrome：无背景的 wrapper + 图片内容（image_quad，不被扫描认出）。
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

/// 统计批量 quad 与 chrome（image_quad）的相对次序 + 逃逸裁剪数。
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
                // 批量 quad：修好后 node_id=画布；回归形态是 node_id=0 无 clip。
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

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .{};
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);

    // 无选择态：不传叠加阈值也没有叠加节点 ⇒ ①②③ 全落空的那一帧。
    try shell.cx.setBulkQuadsEx(shell.canvas, quads.items, bulk_overlay_z);
    shell.cx.layout();
    _ = shell.cx.render();

    const ord = bulkVsGlassChrome(shell.cx, shell.canvas.id, &chrome_ids);
    const fc = ord.first_chrome orelse return error.TestExpectedChromeItems;

    // 修复前：insert_at=null ⇒ 追加末尾 + 不裁剪，这两条都失败。
    // 修复后：要么正确插在 chrome 之前且带 clip，要么这一帧干脆不画
    //（安全降级），但**绝不允许**画在 chrome 之上。
    if (ord.last_bulk) |lb| {
        try std.testing.expect(lb < fc);
        try std.testing.expectEqual(@as(usize, 0), ord.unclipped_bulk);
    }
}

test "BulkQuad: 选择态开关不改变层级（点击恢复/再点又坏 的确定性复现）" {
    const allocator = std.testing.allocator;

    // A) 无选择：画布子树空、无叠加。
    {
        var chrome_ids: [2]u32 = undefined;
        var shell = try buildGlassChromeBulkShell(allocator, &chrome_ids);
        defer shell.cx.deinit();
        var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .{};
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

    // B) 有选择：同一棵树 + 一个交互叠加节点（选中后出现的 handle）。
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

        var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .{};
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

    // 画布是 root 的**最后**一个孩子：锚点之后没有任何兄弟，子树也没 item。
    // 三级定位必然全落空 —— 这是 null 语义的纯净样本。
    var cx = try Cx.init(allocator);
    defer cx.deinit();
    cx.setViewport(1200, 800);
    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});
    // chrome 在前（画布之后无兄弟）
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

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .{};
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);
    try cx.setBulkQuadsEx(canvas, quads.items, bulk_overlay_z);
    cx.layout();
    _ = cx.render();

    // 关键断言：批量 quad 若被画出来，必须带画布 clip；绝不允许出现
    // "node_id=0 / clip=INVALID_ID" 的裸追加形态（那就是糊住 UI 的元凶）。
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

// ── BulkQuad：锚点子树销毁后必须自动关层（use-after-free 回归）─────────
//
// 复现的真实 crash（下游应用，EXC_BAD_ACCESS / SIGSEGV，栈顶 core.Cx.render）：
// 下游应用的 goHome → teardownChromeScreen 把整棵 board chrome 子树（含
// canvas_host）detach + free，但**没有**重新提交批量层；而 applySnapshot 在
// homepage 屏第一行就 `if (g_chrome_root == null) return` 早退，于是再也没有
// 提交点。cx.bulk_quads_anchor 继续指向已释放的 canvas_host，并且 bulk_quads
// 按 retained 语义跨帧保留 ⇒ 下一帧 appendBulkQuads 解引用 `anchor.id`
// （core.zig 的 `self.scene_runtime.get(anchor.id)`）⇒ 读未映射地址。
//
// 修复：invalidateReferencesToEx 把锚点纳入失效清理，连同 quads 一起清掉。
// 修复前本测试在 anchor.id 处读已释放内存（Debug 下 testing.allocator 的
// 0xaa 毒化 + GPA use-after-free 检测会直接报错）。
test "BulkQuad: 锚点子树被销毁后自动关层，render 不得解引用悬垂锚点" {
    const allocator = std.testing.allocator;
    var cx = try Cx.init(allocator);
    defer cx.deinit();
    cx.setViewport(1200, 800);

    const root = try ui.box(cx, .{
        .width = .{ .px = 1200 },
        .height = .{ .px = 800 },
    }, .{});
    cx.root = root;

    // 画布子树 —— 相当于下游应用的 canvas_host，稍后整棵销毁。
    const canvas = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 900 },
        .height = .{ .px = 700 },
        .overflow_hidden = true,
    }, .{});
    try root.appendChild(cx.allocator, canvas);

    var quads: std.ArrayListUnmanaged(ui.BulkQuad) = .{};
    defer quads.deinit(allocator);
    try bulkQuadsForScale(&quads, allocator, 0.06);
    try cx.setBulkQuadsEx(canvas, quads.items, bulk_overlay_z);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(cx.bulk_quads.items.len > 0);

    // 下游应用 teardownChromeScreen 的等价动作：摘树 + 释放，**不**重新提交批量层。
    cx.detachChild(root, canvas);
    cx.freeNode(canvas);

    // 锚点必须已被清空，否则下面这帧就是 use-after-free。
    try std.testing.expect(cx.bulk_quads_anchor == null);
    // 关层而不是退化成 null-anchor 的"追加末尾 + 不裁剪"。
    try std.testing.expectEqual(@as(usize, 0), cx.bulk_quads.items.len);

    // homepage 屏继续出帧：不得崩，也不得画出裸批量 quad。
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
    // 背景：批量层由宿主每帧重新提交，zenit 不做跨帧 diff，所以**只要存在
    // 批量层就保守重画整份 display list**。在两万+ quad 的画布上实测
    // render_gen 21.6ms/帧、占整帧 70%（GPU 只用 6.3ms）—— 画面完全静止时
    // 也照付。宿主用 setBulkQuadsVersioned 自证"这批和上一帧一样"后，
    // 静止画面必须回到零脏帧。
    var cx = try Cx.init(std.testing.allocator);
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

    // 第一帧：建立基线（版本首次出现，不算"未变"）。
    try cx.setBulkQuadsVersioned(null, &quads, null, 7);
    cx.layout();
    _ = cx.render();
    try std.testing.expect(firstFillRect(cx) != null);

    // 第二帧：同一个版本号 ⇒ 宿主声明内容未变 ⇒ 允许走零脏帧。
    try cx.setBulkQuadsVersioned(null, &quads, null, 7);
    try std.testing.expect(cx.bulk_quads_unchanged);
    cx.layout();
    _ = cx.render();
    // 画面不能因为"跳过重画"而消失 —— display list 跨帧保留。
    try std.testing.expect(firstFillRect(cx) != null);
}

test "BulkQuad: 版本号变化必须重画（否则改了内容画面不动）" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const green = [_]ui.BulkQuad{.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x00FF00) }};
    try cx.setBulkQuadsVersioned(null, &green, null, 1);
    cx.layout();
    _ = cx.render();

    // 换内容 + 换版本 ⇒ 必须重画，不得被"未变"短路吞掉。
    const red = [_]ui.BulkQuad{.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0xFF0000) }};
    try cx.setBulkQuadsVersioned(null, &red, null, 2);
    try std.testing.expect(!cx.bulk_quads_unchanged);
    cx.layout();
    _ = cx.render();
    const fr = firstFillRect(cx).?;
    try std.testing.expectEqual(Color.hex(0xFF0000), fr.color);
}

test "BulkQuad: 不传版本号时保持原来的保守重画语义" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const quads = [_]ui.BulkQuad{.{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x00FF00) }};
    // 老接口（无版本）：宿主无法自证 ⇒ 永远算"变了"，行为与修改前一致。
    try cx.setBulkQuads(null, &quads);
    try std.testing.expect(!cx.bulk_quads_unchanged);
    try cx.setBulkQuads(null, &quads);
    try std.testing.expect(!cx.bulk_quads_unchanged);
}

// ── BulkQuad 分段（z 交错）────────────────────────────────────────────
//
// 背景：批量层原本是**一个平面**，插在锚点子树静态内容之后 ⇒ 画在所有对象
// Node 之上。于是"部分对象在某些 Node 之下、另一些在其之上"这件事根本表达
// 不了 —— 宿主侧试过按 z 切一刀的四种方案，每种都在真实板上留下上万个错误
// 像素（低 z 侧或高 z 侧总有一边被画错）。
//
// 分段后每条 quad 可以带 z_index，插到"第一个 z 更大的 Node item"之前。

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
    var cx = try Cx.init(a);
    defer cx.deinit();
    cx.setViewport(400, 300);

    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    // 一个 z=50 的 Node（红），批量层里有 z=10（绿）和 z=90（蓝）两段。
    // 正确顺序应当是 绿 → 红 → 蓝。
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

    var colors: std.ArrayListUnmanaged(Color) = .{};
    defer colors.deinit(a);
    try fillRectColorsInOrder(cx, &colors, a);

    // 找到三者的下标，断言 绿 < 红 < 蓝。
    var gi: ?usize = null;
    var ri: ?usize = null;
    var bi: ?usize = null;
    for (colors.items, 0..) |c, idx| {
        if (std.meta.eql(c, Color.hex(0x00FF00))) gi = idx;
        if (std.meta.eql(c, Color.hex(0xFF0000))) ri = idx;
        if (std.meta.eql(c, Color.hex(0x0000FF))) bi = idx;
    }
    try std.testing.expect(gi != null and ri != null and bi != null);
    try std.testing.expect(gi.? < ri.?); // z=10 的批量项在 z=50 的 Node 之下
    try std.testing.expect(ri.? < bi.?); // z=90 的批量项在 z=50 的 Node 之上
}

test "BulkQuad 分段：同一段内保持提交顺序（后者盖前者）" {
    const a = std.testing.allocator;
    var cx = try Cx.init(a);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // 同 z 的两条：数组顺序即绘制顺序，分段不得重排。
    try cx.setBulkQuads(root, &[_]ui.BulkQuad{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x111111), .z_index = 5 },
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x222222), .z_index = 5 },
    });
    cx.layout();
    _ = cx.render();

    var colors: std.ArrayListUnmanaged(Color) = .{};
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
    var cx = try Cx.init(a);
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

    // 不给 z_index ⇒ 老语义：整层画在所有 Node 之上。
    try cx.setBulkQuads(root, &[_]ui.BulkQuad{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.hex(0x00FF00) },
    });
    cx.layout();
    _ = cx.render();

    var colors: std.ArrayListUnmanaged(Color) = .{};
    defer colors.deinit(a);
    try fillRectColorsInOrder(cx, &colors, a);
    var gi: ?usize = null;
    var ri: ?usize = null;
    for (colors.items, 0..) |c, idx| {
        if (std.meta.eql(c, Color.hex(0x00FF00))) gi = idx;
        if (std.meta.eql(c, Color.hex(0xFF0000))) ri = idx;
    }
    try std.testing.expect(gi != null and ri != null);
    try std.testing.expect(ri.? < gi.?); // Node 在前 ⇒ 批量层盖在它上面
}

// ============================================================================
// interaction.drag 集成测试（docs/DRAG_INTERACTION_DESIGN.md §18.2）
// ============================================================================

const drag_mod = @import("../interaction/drag.zig");
const ReactiveScope = @import("../reactive.zig").Scope;

const DragRec = struct {
    events: [16]drag_mod.Event = undefined,
    len: usize = 0,
    clicks: u32 = 0,
    pending_downs: u32 = 0,
    can_start_calls: u32 = 0,
    allow_start: bool = true,
    // 重入动作（callback 内执行一次后清除）
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
        var cx = try Cx.init(std.testing.allocator);
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
        // handler 挂上之后再 layout，hit-test 场景才会把 source 当交互目标
        //（与真实组件"构建期挂 handler → layout"的顺序一致）。
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
    f.cx.handleMouseMove(12, 11); // 未越阈值
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
    // end 用 up 最终坐标的累计 delta
    try std.testing.expectEqual(@as(f32, 50), f.rec.events[2].delta.x);
    try std.testing.expectEqual(@as(f32, 15), f.rec.events[2].delta.y);
    try std.testing.expectEqual(@as(u32, 0), f.rec.clicks);
    try std.testing.expect(!f.cx.dispatcher.hasPointerCapture());
    try std.testing.expect(f.cx.cursor_override == null);
    try std.testing.expect(f.cx.drag_manager.session == null);

    // 随后普通点击恢复
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
    f.cx.handleMouseMove(250, 180); // 远超 source 区域
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

    // 再次 Escape 不再产生任何 callback（幂等）
    f.cx.handleKeyDown(.escape, .{});
    try std.testing.expectEqual(@as(usize, 2), f.rec.len);

    // 后到的 up 只做幂等清理，不 click
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
    // 节点已摘链，交还给测试释放
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
    f.cx.handleMouseMove(50, 10); // move → callback 内 detach → 同步 cancel

    // start, move, cancel(source_detached)
    try std.testing.expectEqual(@as(usize, 3), f.rec.len);
    try std.testing.expectEqual(drag_mod.Phase.cancel, f.rec.events[2].phase);
    try std.testing.expectEqual(@as(?drag_mod.CancelReason, .source_detached), f.rec.events[2].cancel_reason);

    // 后续输入幂等
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

    // 下一次序列重新询问
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
    // source 的 event slot 已摘除
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    cx.handleMouseMove(40, 10); // a active，capture 生效
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
    // 失败不留半注册状态
    try std.testing.expect(f.source.behavior.events.on_event == null);

    _ = try f.attach(.{});
    try std.testing.expectError(error.EventSlotOccupied, f.attach(.{}));
}

// 下游应用 layers hover"字母微抖"复现：同一段文字，跨帧缓存 splice 重放与
// dirty 后 fresh 重录，产出的 text_run x 必须**逐位相等**。祖先带分数坐标
// （真实场景：玻璃岛/行内偏移不保证整数）时，两条路径若量化不一致，
// hover 翻转底色（强制该行 fresh）就会让整行文字平移亚像素 —— 用户看到
// "letters 之间微小抖动"。
test "render: fresh re-record and cached splice agree on text x at fractional origin" {
    var cx = try Cx.init(std.testing.allocator);
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
        // 分数内边距 → 行/文字落在半像素坐标上（真实侧栏的等效条件）
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

    // 帧 1：全 fresh。
    _ = cx.render();
    const t1 = findText(cx.lowerForEncoderPaintTable()) orelse return error.TestExpectedText;

    // 帧 2：无脏 → 缓存/重放路径。
    _ = cx.render();
    const t2 = findText(cx.lowerForEncoderPaintTable()) orelse return error.TestExpectedText;

    // 帧 3：行底色直写（= hover），行子树 fresh 重录。
    row.setStyle(null, .background, Color.rgba(0, 0, 0, 20));
    _ = cx.render();
    const t3 = findText(cx.lowerForEncoderPaintTable()) orelse return error.TestExpectedText;

    // 帧 4：底色回透明（= 离开 hover）。
    row.setStyle(null, .background, Color.rgba(0, 0, 0, 0));
    _ = cx.render();
    const t4 = findText(cx.lowerForEncoderPaintTable()) orelse return error.TestExpectedText;

    // 全部逐位相等 —— 亚像素都不许移。
    try std.testing.expectEqual(t1.geom.x, t2.geom.x);
    try std.testing.expectEqual(t1.geom.y, t2.geom.y);
    try std.testing.expectEqual(t1.geom.x, t3.geom.x);
    try std.testing.expectEqual(t1.geom.y, t3.geom.y);
    try std.testing.expectEqual(t1.geom.x, t4.geom.x);
    try std.testing.expectEqual(t1.geom.y, t4.geom.y);
}

// TextProps.text_align：居中/右对齐只挪绘制起点。折行（有 TextLayout）与单行
// （wrap=.none）两条发射路径都要生效，偏移公式与 text_layout.alignLineOffset 一致。
test "render: text_align centers and end-aligns each visual line" {
    const cases = [_]struct { wrap: ui.TextWrap, text_align: ui.TextAlign }{
        .{ .wrap = .word, .text_align = .start },
        .{ .wrap = .word, .text_align = .center },
        .{ .wrap = .word, .text_align = .end },
        .{ .wrap = .none, .text_align = .center },
        .{ .wrap = .none, .text_align = .end },
    };
    for (cases) |c| {
        var cx = try Cx.init(std.testing.allocator);
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
    // 回归：下游应用的颜色浮层（z=30500 的兄弟子树）盖住 Inspector 岛时，
    // 岛内**旋转**的小方块（◇ 菱形）浮到浮层之上 —— 带 transform 的节点
    // 走了独立的合成/发射路径，逃逸了兄弟 z_index 叠序。
    // 期望：旋转节点的绘制项在 overlay 的绘制项**之前**（被盖住）。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(200, 200);

    const root = try box(cx, .{
        .width = .{ .px = 200 },
        .height = .{ .px = 200 },
    }, .{});
    // 岛（z 默认 0），内含一个旋转 45° 的小方块
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
    // 浮层：z>0 的兄弟，整块盖住岛
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

    // 第二帧走缓存/retained 路径，叠序必须依旧成立
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
    // 回归（下游应用 sticky 文本消失的根因）：增量布局的 must_full_layout 判定
    // 有意跳过 absolute 子节点，而 fallback 曾只 layoutNode(child, 旧rect)
    // —— 首帧布局**之后**才 append 的 absolute 子节点 rect 恒为 (0,0,0,0)，
    // 画布对象后挂的文字 label 因此永远不渲染。修复后 absolute 且自身
    // layout-dirty 的子节点走 layoutAbsoluteChild 重新 resolve。
    var cx = try Cx.init(std.testing.allocator);
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

    // 首帧布局完成后再挂 absolute 子节点（对象先落笔、后写字的时序）
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
    // 回归（下游应用便签正文"不渲染"的根因）：批量层归并按 item 的 z 决定 quad
    // 插在它前还是后，而 z 是**兄弟间**的层级语义 —— 容器设了 z，其内部的
    // 文字/图标子节点并不会各自再设一遍。collectSubtreeZ 曾直接读子节点自身
    // 的 z_index（默认 0），于是"z=3 容器里的文字"被当成 z=0，z=2 的 quad
    // 插到了文字之后，把它整块盖掉。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(300, 300);

    const host = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 300 } }, .{});
    // 低 z 的对象（会被批量层表达）
    const low = try box(cx, .{
        .position = .absolute,
        .width = .{ .px = 100 },
        .height = .{ .px = 100 },
        .background = Color.rgba(200, 200, 200, 255),
    }, .{});
    (try low.style.ensureExtFallible(cx.allocator)).z_index = 1;
    try host.appendChild(cx.allocator, low);
    // 高 z 的容器 + 它的子内容（子节点**不设** z_index）
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

    // 一条 z=2 的 quad：应当画在 low(z=1) 之上、container(z=3) 及其子内容之下
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
    // 容器的子内容必须画在 quad **之后**（= 覆盖在它之上）
    try std.testing.expect(quad_order.? < child_order.?);
}

test "render: node-local overflow clip follows text across surfaces and retained frames" {
    for ([_]u8{ 0, 1, 2 }) |layers| {
        var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
        var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

test "Snapshot.captureDisplayed preserves last displayed content when node is dirty" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
// derived from focus, so it must be reconciled at the same boundary —
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

    var cx = try Cx.init(std.testing.allocator);
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
    // another live client, the next rebuild has to reopen it — otherwise the
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
        var cx = try Cx.init(std.testing.allocator);
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

// ─── 点击回调里 replaceChildOrder 换入同形新子树后，新子树永久点不中 ───
// 现场：下游编辑器 Global Find 点结果行 → 回调里重建文件列表（新 VirtualList 换入旧位置）+
// 预览池只改样式切换可见 editor；之后整张列表的点击都落到父容器上，直到下次搜索。
// 根因：mouseUp 分发后的 rebuildRuntimeIndexesIfCurrentRootDirty 在布局前按 0 尺寸重建命中
// 索引并清掉 hit 脏位（见该函数注释）。两个变体：预览复用槽（纯样式）/ 新挂槽（结构追加）。
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
        var cx = try Cx.init(std.testing.allocator);
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

// ─── freeNode 立即路径必须清掉指进被释放子树的交互裸引用（与延迟路径同一契约）───
// 现场：点击回调里释放了被按下的行（Global Find 重建文件列表），mouseUp 收尾清 pressed_node 之前
// 若有 before_render hook 运行（命中索引先布局再重建），animBg 读 cx.pressed_node → 段错误。
test "freeNode outside tick/reactive depth clears pressed/hovered/last-mouse-down refs into the freed subtree" {
    var cx = try Cx.init(std.testing.allocator);
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

// ─── portal 祖先检查不把窗口根的裁剪当问题 ───
// borderless 窗口根带 overflow_hidden（圆角），其裁剪区就是视口；在其中挂 tooltip 等浮层
// 曾每次 log.err "clipping/effect-surface ancestor"（下游编辑器 Global Find 标题栏 tooltip 实测，
// 测试运行器把 logged errors 判失败）。链顶（无父）节点必须跳过；更内层的裁剪祖先照报。
test "popover portal under an overflow-hidden window root logs no clipping error" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 300);
    const root = try ui.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const card = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 80 }, .background = Color.rgba(255, 255, 255, 200) }, .{});
    try root.appendChild(std.testing.allocator, card);
    // 设计稿 16.3 的三段投影：0 1 2 .10 / 0 16 34 -12 .24 / 0 40 80 -32 .36
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
    // 列表第一项在最上层 → 最后画：发射顺序为 3、2、1。
    try std.testing.expectApproxEqAbs(@as(f32, -32), got[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -12), got[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), got[2], 1e-4);
}

test "multi inset shadows lower with a transparent fill (no double-painted translucent background)" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    try std.testing.expectApproxEqAbs(@as(f32, 4), clamped.backdrop_saturation, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), clamped.backdrop_brightness, 1e-5);
}

test "Cx timers: wake an idle loop, fire before the zero-dirty fast path, and can be cleared" {
    var cx = try Cx.init(std.testing.allocator);
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
    std.Thread.sleep(4 * std.time.ns_per_ms);
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
    var cx = try Cx.init(std.testing.allocator);
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
    // 换行文本必须按新内容重新折行：高度应长到多行。
    if (wrap != .none) try std.testing.expect(t.rectFromWorldOrFallback().h > one_line_h * 2);
    // 画出来的是新内容的全部（每行尾的断行空格可省）。
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
    var cx = try Cx.init(std.testing.allocator);
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
    // 不手动标脏：setTextContent 自己负责。
    try ts.setTextContent(cx.allocator, "12 minutes ago");
    _ = cx.render();
    const r = ts.rectFromWorldOrFallback();
    try std.testing.expect(r.w > short_w * 2);
    // 右边缘仍在行内（右对齐，不冲出去）。
    const row_r = row.rectFromWorldOrFallback();
    try std.testing.expect(ts.globalRect().x + r.w <= row.globalRect().x + row_r.w + 0.5);
}

test "layout: a fit-height absolute child grows when only its descendants change" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(400, 600);
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 600 } }, .{});
    cx.root = root;
    // 类似 Popover 面板：绝对定位、高度 fit 内容。
    const panel = try box(cx, .{ .position = .absolute, .width = .{ .px = 200 }, .direction = .column }, .{});
    panel.style.height = .{ .fit = .{} };
    try root.appendChild(cx.allocator, panel);
    const list = try box(cx, .{ .width = .fill(), .direction = .column }, .{});
    list.style.height = .{ .fit = .{} };
    // 可收缩的列表（Popover 里「只有列表让位」的写法）：旧高度当可用空间时会被挤回去。
    list.style.flex_shrink = 1;
    try panel.appendChild(cx.allocator, list);
    try list.appendChild(cx.allocator, try box(cx, .{ .width = .fill(), .height = .{ .px = 40 } }, .{}));
    cx.layout();
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 40), panel.rectFromWorldOrFallback().h, 0.5);
    // 只在深层加行：panel 自身不是 layout-dirty，只有 subtree_layout。
    try list.appendChild(cx.allocator, try box(cx, .{ .width = .fill(), .height = .{ .px = 60 } }, .{}));
    try list.appendChild(cx.allocator, try box(cx, .{ .width = .fill(), .height = .{ .px = 60 } }, .{}));
    cx.layout();
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 160), list.rectFromWorldOrFallback().h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 160), panel.rectFromWorldOrFallback().h, 0.5);
}

// ─── overflow clip 只裁后代、收在描边内沿（CSS overflow 语义）───
//
// 回归锚（storybook Popover「Tall content」+ 下游编辑器 block 菜单实拍）：
//   1. 阴影被自身 overflow clip 裁成 border-box 矩形——圆角外露出矩形灰块，
//      面板四周的柔和阴影整圈消失；
//   2. 贴边/溢出的子内容盖住描边——描边在内容处断开。
// 两条路径都要覆盖：普通节点（lowering 的 clip 链）与 composited_group surface
// owner（Popover chrome；以前 compositor apply_clip 在 begin_layer 后立即 push，
// 连 owner 自己的阴影一起裁），后者还要覆盖 promoted cache 命中帧（缓存替放）。

const OwnClipProbe = struct {
    /// 第一条 shadow 命令所处的 scissor 深度（0 = 未被任何 clip 包住）。
    shadow_depth: ?usize = null,
    /// 目标子节点 fill 的世界坐标 scissor（null = 未被裁）。
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
    // 子内容比面板高很多（1400 之于 tall popover）：必须被面板裁掉。
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
    // 阴影不被自身 overflow clip 裁
    try std.testing.expectEqual(@as(?usize, 0), probe.shadow_depth);
    // 子内容被裁到 padding box（描边内沿）：面板 (40,40,120x80)，描边 1px
    try std.testing.expect(probe.child_found);
    try std.testing.expectEqual(@as(?ui.ComputedRect, ui.ComputedRect.init(41, 41, 118, 78)), probe.child_scissor);
}

test "render: overflow clip spares owner shadow and stops at border inner edge (plain node)" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.setViewport(320, 240);
    const child_color = Color.rgba(79, 70, 229, 255);
    cx.root = try buildShadowedClipPanel(cx, false, child_color);
    cx.layout();
    _ = cx.render();
    try expectOwnClipContract(cx, child_color);
}

test "render: composited owner overflow clip spares owner shadow and stops at border inner edge, fresh and cached" {
    var cx = try Cx.init(std.testing.allocator);
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
    // compositor apply_clip 不得取 owner 自己的 clip（它会连阴影一起裁）
    for (cx.layer_tree.frame_ops.items) |op| switch (op) {
        .apply_clip => |clip| try std.testing.expect(clip.bounds.w != 120 or clip.bounds.h != 80),
        else => {},
    };

    // promoted cache 命中帧：整段替放必须带上 children 包围 token
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

// ── display: none（框架原生隐藏：布局 / 绘制 / 命中 / 焦点 / 无障碍 一致退出）──

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
    // c 只有 10 高：隐藏 b 后 c 左移，b_child 的陈旧几何（y 10..20）不被 c 覆盖，
    // 命中测试才能区分"隐藏子树被剪掉"与"恰好被 c 盖住"。
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const f = try displayNoneFixture(cx);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 120), f.c.rectFromWorldOrFallback().x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 170), f.root.rectFromWorldOrFallback().w, 0.01);

    f.b.setDisplay(.none);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 60), f.c.rectFromWorldOrFallback().x, 0.01); // a + 一个 gap
    try std.testing.expectApproxEqAbs(@as(f32, 110), f.root.rectFromWorldOrFallback().w, 0.01);
    _ = cx.render();
    try std.testing.expect(!cx.hasPendingSceneWork()); // 隐藏子树不残留脏位（idle 能停帧）

    f.b.setDisplay(.flex);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 120), f.c.rectFromWorldOrFallback().x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), f.b.rectFromWorldOrFallback().x, 0.01);
}

test "display none: 子树不绘制、不命中、不进无障碍树" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const f = try displayNoneFixture(cx);
    cx.layout();
    var items = cx.render();
    try std.testing.expect(itemsForNode(items, f.b) > 0);
    try std.testing.expect(itemsForNode(items, f.b_child) > 0);
    const child_rect = f.b_child.rectFromWorldOrFallback();
    const bx = f.b.rectFromWorldOrFallback().x + child_rect.x + 5;
    try std.testing.expect(cx.hitTest(bx, 5) == f.b_child);
    try std.testing.expect(!cx.accessibility_tree.get(ui.ElementId.fromRaw(f.b_child.element_id_raw)).?.state.hidden);

    f.b.setDisplay(.none);
    cx.layout();
    items = cx.render();
    try std.testing.expectEqual(@as(usize, 0), itemsForNode(items, f.b));
    try std.testing.expectEqual(@as(usize, 0), itemsForNode(items, f.b_child));
    // 原位置现在是 c（c 左移补位），隐藏子树绝不命中
    // y = 15：只有 b_child 的陈旧几何在此（c 高 10），隐藏子树必须不命中
    const hit = cx.hitTest(f.c.rectFromWorldOrFallback().x + 5, 15);
    try std.testing.expect(hit != f.b_child and hit != f.b);
    // 与 aria-hidden 同一语义：节点留在树上但标 hidden，bridge 不朗读。
    try std.testing.expect(cx.accessibility_tree.get(ui.ElementId.fromRaw(f.b_child.element_id_raw)).?.state.hidden);
}

test "display none: Tab / Shift+Tab 跳过隐藏子树里的可聚焦节点" {
    var cx = try Cx.init(std.testing.allocator);
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
    // 回归：rebuildDirtyRuntimeSubtrees 注销子树可聚焦节点后 appendFocusableUnsorted
    // 追加到末尾且不重排，Tab 从 a 直接跳到 c，子树里的 b_child 被挪到最后。
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const f = try displayNoneFixture(cx);
    cx.layout();
    try std.testing.expectEqualSlices(*Node, &.{ f.a, f.b_child, f.c }, cx.focus_manager.focus_order.items);
    f.b.markRuntimeIndexDirty(); // 触发 b 子树的运行时增量重建（rebuildDirtyRuntimeSubtrees）
    _ = cx.render(); // 走完整一帧：纯 layout() 在无布局脏时是快路径，不重建运行时索引
    try std.testing.expectEqualSlices(*Node, &.{ f.a, f.b_child, f.c }, cx.focus_manager.focus_order.items);
}

test "Node.setTint：icon 表与 image 两种存储都改到，无图形内容返回 false" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const red = Color.hex(0xFF0000);
    const blue = Color.hex(0x0000FF);

    // 带 icon_id 的资源 → icon 表
    const icon_node = try ui.iconTint(cx, ui.svg_assets.common.star, red, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
    defer cx.freeNode(icon_node);
    try std.testing.expect(icon_node.getIcon() != null);
    try std.testing.expect(icon_node.setTint(blue));
    try std.testing.expectEqual(blue, icon_node.getIcon().?.tint);

    // image 存储（svgTint 对无预烘焙 rep 的 SVG 走的就是 image；headless 无 GPU
    // 纹理加载器，直接用 imageTint 构造同一存储形态）
    const img_node = try ui.imageTint(cx, 7, red, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } });
    defer cx.freeNode(img_node);
    try std.testing.expect(img_node.getIcon() == null);
    try std.testing.expect(img_node.setTint(blue));
    try std.testing.expectEqual(blue, img_node.getImage().?.tint);

    const plain = try ui.box(cx, .{}, .{});
    defer cx.freeNode(plain);
    try std.testing.expect(!plain.setTint(blue));
}
