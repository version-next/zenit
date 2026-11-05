const std = @import("std");
const gpu = @import("gpu");
const AppRenderer = @import("renderer.zig").AppRenderer;

test "caret glass snapshots compare contents across arena addresses and detect material changes" {
    const ui = @import("ui");
    const Item = @typeInfo(@TypeOf(@as(*ui.Cx, undefined).lowerForEncoderPaintTable())).pointer.child;
    const Glass = @typeInfo(@typeInfo(@TypeOf(@as(Item, undefined).glass_ptr)).optional.child).pointer.child;
    const Group = @typeInfo(@typeInfo(@TypeOf(@as(Glass, undefined).group)).optional.child).pointer.child;
    var group: Group = .{};
    const first: Glass = .{ .group = &group, .backdrop_blur = 12 };
    var second = first;
    const Fingerprint = @import("render").PaintFingerprint;
    const Hash = struct {
        fn of(glass: *const Glass) u64 {
            var hash = std.hash.Wyhash.init(0);
            Fingerprint.hashCaretPaintItemInto(&hash, Item{ .kind = .control, .control_kind = .begin_blur_layer, .glass_ptr = glass });
            return hash.final();
        }
    };
    const original = Hash.of(&first);
    try std.testing.expectEqual(original, Hash.of(&second));
    second.backdrop_blur += 1;
    try std.testing.expect(original != Hash.of(&second));
    second = first;
    group.version += 1;
    try std.testing.expect(original != Hash.of(&second));
}

test "caret icon snapshots compare copied representations and detect contour changes" {
    const ui = @import("ui");
    const Item = @typeInfo(@TypeOf(@as(*ui.Cx, undefined).lowerForEncoderPaintTable())).pointer.child;
    const Rep = @typeInfo(@typeInfo(@TypeOf(@as(Item, undefined).icon_rep_ptr)).optional.child).pointer.child;
    const Shape = @typeInfo(@TypeOf(@as(Rep, undefined).shapes)).pointer.child;
    const Contour = @typeInfo(@TypeOf(@as(Shape, undefined).contours)).pointer.child;
    const Point = @typeInfo(@TypeOf(@as(Contour, undefined).points)).pointer.child;
    var points = [_]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const contours = [_]Contour{.{ .points = &points, .closed = false }};
    const shapes = [_]Shape{.{ .contours = &contours, .stroke_width = 1 }};
    const first: Rep = .{ .size = 16, .shapes = &shapes };
    const second = first;
    const Hash = struct {
        fn of(rep: *const Rep) u64 {
            var hash = std.hash.Wyhash.init(0);
            @import("render").PaintFingerprint.hashCaretPaintItemInto(&hash, Item{ .kind = .image, .icon_rep_ptr = rep });
            return hash.final();
        }
    };
    const original = Hash.of(&first);
    try std.testing.expectEqual(original, Hash.of(&second));
    points[1].x += 1;
    try std.testing.expect(original != Hash.of(&second));
}

test "AppRenderer initializes caret ownership from poisoned storage" {
    // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    var surface = gpu.Backend.Surface{};
    var renderer: AppRenderer = undefined;
    @memset(std.mem.asBytes(&renderer), 0xaa);
    try renderer.init(std.testing.allocator, std.testing.io, &device, &queue, &surface, .{});
    defer renderer.deinit();
    try std.testing.expect(renderer.caret_hidden_items == null);
    try std.testing.expect(!renderer.caret_background_capture);
    try std.testing.expect(!renderer.caret_flip_disabled);
    try surface.configure(std.testing.allocator, &device, .{ .format = gpu.color_format, .width = 100, .height = 100 });
    const ui = @import("ui");
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try ui.box(cx, .{}, .{});
    renderer.caret_background_capture = true;
    try renderer.frame(cx, 100, 100, 1);
    try std.testing.expect(renderer.caret_hidden_items != null);
    // A second capture replaces the owned snapshot; resize and cleanup are
    // idempotent and never borrow paint-table storage from a retired frame.
    try renderer.frame(cx, 100, 100, 1);
    renderer.caret_flip_disabled = true;
    renderer.prepareSurfaceResize(cx);
    try std.testing.expect(renderer.caret_flip_disabled);
    renderer.clearCaretPreparation();
    renderer.clearCaretPreparation();
    try std.testing.expect(renderer.caret_hidden_items == null);
    renderer.deinit();
    try renderer.init(std.testing.allocator, std.testing.io, &device, &queue, &surface, .{});
    try std.testing.expect(!renderer.caret_flip_disabled);
}

test "AppRenderer manual getEncoder and beginFrame preserve pool retirement" {
    // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    var surface = gpu.Backend.Surface{};
    var renderer: AppRenderer = undefined;
    try renderer.init(std.testing.allocator, std.testing.io, &device, &queue, &surface, .{});
    defer renderer.deinit();
    const old = renderer.offscreen_pool.acquireRetained(&device, 17, 1, 64, 64, 1).?;
    renderer.frame_counter = 70;
    {
        var encoder = renderer.getEncoder();
        defer encoder.deinit();
        encoder.beginFrame(100, 100, 1);
        try std.testing.expect(encoder.external_pool_aging);
        try std.testing.expect(renderer.offscreen_pool.resolveTexture(old.lease) == null);
        try std.testing.expectEqual(@as(u32, 0), renderer.offscreen_pool.memorySnapshot(72).retained);
    }
    renderer.frame_counter = 200;
    {
        var encoder = renderer.beginFrame(100, 100, 1);
        defer encoder.deinit();
        try std.testing.expect(encoder.external_pool_aging);
        try std.testing.expectEqual(@as(u32, 0), renderer.offscreen_pool.memorySnapshot(202).live);
    }
    try std.testing.expect(!renderer.offscreen_pool.encoder_active);
    renderer.maintainExternalOffscreenPool(true);

    // A caller can hand control back to the automatic Cx pipeline. Its
    // encoder must still age entries while the escaped-submission latch is on.
    renderer.frame_counter = 210;
    _ = renderer.offscreen_pool.acquire(&device, 64, 64, 1).?;
    try surface.configure(std.testing.allocator, &device, .{ .format = gpu.color_format, .width = 100, .height = 100 });
    const ui = @import("ui");
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{}, .{});
    cx.root = root;
    try renderer.frame(cx, 100, 100, 1);
    try std.testing.expectEqual(@as(u32, 0), renderer.offscreen_pool.memorySnapshot(212).live);
}

test "caret snapshots classify clips and conservatively bound paths transforms and icons" {
    const ui = @import("ui");
    const Item = @typeInfo(@TypeOf(@as(*ui.Cx, undefined).lowerForEncoderPaintTable())).pointer.child;
    const Rep = @typeInfo(@typeInfo(@TypeOf(@as(Item, undefined).icon_rep_ptr)).optional.child).pointer.child;
    const rep: Rep = .{ .size = 16, .shapes = &.{} };
    var renderer: AppRenderer = undefined;
    renderer.allocator = std.testing.allocator;
    renderer.caret_background_capture = false;
    renderer.caret_patch_capture = false;
    const items = try renderer.caretItems(&[_]Item{
        .{ .kind = .control, .control_kind = .push_clip },
        .{ .kind = .control, .control_kind = .pop_clip },
        .{ .kind = .control, .control_kind = .begin_rounded_clip },
        .{ .kind = .control, .control_kind = .end_rounded_clip },
        .{ .kind = .rect, .use_draw_transform = true },
        .{ .kind = .path, .arc_outer_radius = 12, .geom = .{ .x = 100, .y = 100 } },
        .{ .kind = .image, .icon_rep_ptr = &rep, .geom = .{ .x = 500, .y = 500, .w = 1, .h = 1 } },
    });
    defer std.testing.allocator.free(items);
    try std.testing.expect(!items[0].drawable and !items[1].drawable);
    try std.testing.expect(items[2].drawable and !items[3].drawable);
    try std.testing.expect(items[4].unbounded);
    try std.testing.expect(items[5].bounds[2] >= 24);
    try std.testing.expect(items[6].unbounded);
}

test "caret flips past later text whose glyph ink misses the patch, not past glyphs reaching it" {
    // zeditor: a caret on the last visible editor line, then the status bar's 13 px text.
    // Its generic envelope (800, 564, 174, 40.9) covers the caret's native patch; its glyphs
    // (render.text_ink, measured in test-metal "status bar text ...") start below it.
    const ui = @import("ui");
    const caret_plan = @import("caret_patch_plan.zig");
    const Item = @typeInfo(@TypeOf(@as(*ui.Cx, undefined).lowerForEncoderPaintTable())).pointer.child;
    var renderer: AppRenderer = undefined;
    renderer.allocator = std.testing.allocator;
    renderer.caret_background_capture = false;
    renderer.caret_patch_capture = false;
    const bg: Item = .{ .kind = .rect, .geom = .{ .x = 0, .y = 0, .w = 1200, .h = 620 } };
    const caret: Item = .{ .kind = .rect, .geom = .{ .x = 841, .y = 550, .w = 2, .h = 18 } };
    const status: Item = .{ .kind = .text, .geom = .{ .x = 800, .y = 590.9 }, .text_content = "Ln 1205, Col 18   UTF-8", .text_font_size = 13 };
    const patch = [_][4]f32{.{ 840, 549, 5, 20 }};
    const rects = [_][4]f32{.{ 841, 550, 2, 18 }};
    const Case = struct { ink: ?[4]f32, occluded: bool };
    for ([_]Case{
        .{ .ink = .{ 799, 578, 176, 15 }, .occluded = false },
        // Unknown ink keeps the envelope.
        .{ .ink = null, .occluded = true },
        // Glyphs reaching one pixel into the patch.
        .{ .ink = .{ 799, 568, 176, 15 }, .occluded = true },
    }) |case| {
        const hidden = try renderer.caretItemsInk(&[_]Item{ bg, status }, &.{ null, case.ink });
        defer std.testing.allocator.free(hidden);
        const visible = try renderer.caretItemsInk(&[_]Item{ bg, caret, status }, &.{ null, null, case.ink });
        defer std.testing.allocator.free(visible);
        if (case.occluded) {
            try std.testing.expectError(error.CaretOccluded, caret_plan.select(std.testing.allocator, hidden, visible, &rects, &patch));
        } else {
            const selected = try caret_plan.select(std.testing.allocator, hidden, visible, &rects, &patch);
            defer std.testing.allocator.free(selected);
            try std.testing.expectEqualSlices(bool, &.{ false, true, false }, selected);
        }
    }
}

test "abandoned patch queues one ordinary content paint at the editor caret cadence" {
    // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    var surface = gpu.Backend.Surface{};
    var renderer: AppRenderer = undefined;
    try renderer.init(std.testing.allocator, std.testing.io, &device, &queue, &surface, .{});
    defer renderer.deinit();
    try surface.configure(std.testing.allocator, &device, .{ .format = gpu.color_format, .width = 100, .height = 100 });
    const cx = try @import("ui").Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try @import("ui").box(cx, .{}, .{});
    try renderer.frame(cx, 100, 100, 1);
    cx.caret_half_ns = 750 * std.time.ns_per_ms;
    cx.caret_flip_host = true;
    cx.caret_paint_override = false;
    const now = @import("zenit_time").monotonicTimestamp(cx.io);
    @import("caret_flip_lifecycle.zig").resumeOrdinary(cx, now);
    try std.testing.expect(cx.wantsFrame());
    try std.testing.expect(!cx.caret_flip_host);
    try std.testing.expect(cx.caret_paint_override == null);
    try std.testing.expectEqual(now + 750 * std.time.ns_per_ms, cx.caret_next_ns);
    const before = renderer.frame_count;
    try renderer.frame(cx, 100, 100, 1);
    try std.testing.expectEqual(before + 1, renderer.frame_count);
    try std.testing.expect(!cx.wantsFrame()); // exactly one immediate paint, then sleep
}

test "drawable acquisition retires a completed presentation but preserves an in-flight fence on timeout" {
    // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    var surface = gpu.Backend.Surface{};
    var renderer: AppRenderer = undefined;
    try renderer.init(std.testing.allocator, std.testing.io, &device, &queue, &surface, .{});
    defer renderer.deinit();
    try surface.configure(std.testing.allocator, &device, .{ .format = gpu.color_format, .width = 100, .height = 100 });
    const cx = try @import("ui").Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try @import("ui").box(cx, .{}, .{});
    try renderer.frame(cx, 100, 100, 1);
    const count = renderer.frame_count;
    try std.testing.expect(renderer.prev_frame_cmd_buffer != null);
    const Probe = struct {
        renderer: *AppRenderer,
        saw_owner: bool = false,
        fn timeout(ctx: ?*anyopaque) bool {
            const probe: *@This() = @ptrCast(@alignCast(ctx.?));
            probe.saw_owner = probe.renderer.prev_frame_cmd_buffer != null;
            return true;
        }
    };
    var probe: Probe = .{ .renderer = &renderer };
    renderer.acquire_fault_hook = .{ .ctx = &probe, .should_fail = Probe.timeout };
    renderer.prev_frame_cmd_buffer.?.completed = false;
    try std.testing.expectError(error.SurfaceTimeout, renderer.frame(cx, 100, 100, 1));
    try std.testing.expect(probe.saw_owner);
    try std.testing.expect(renderer.prev_frame_cmd_buffer != null);
    renderer.prev_frame_cmd_buffer.?.completed = true;
    try std.testing.expectError(error.SurfaceTimeout, renderer.frame(cx, 100, 100, 1));
    try std.testing.expect(!probe.saw_owner);
    try std.testing.expect(renderer.prev_frame_cmd_buffer == null);
    try std.testing.expectEqual(count, renderer.frame_count);
    renderer.acquire_fault_hook = null;
    try renderer.frame(cx, 100, 100, 1);
    try std.testing.expectEqual(count + 1, renderer.frame_count);
    try std.testing.expect(renderer.prev_frame_cmd_buffer != null);
}

test "AppRenderer successful new submission restarts stopped maintenance" {
    // SKIP-REASON: drives the null backend's fake device / queue / surface; real GPU
    // backends cover submission restart through their own presentation tests.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    var surface = gpu.Backend.Surface{};
    var renderer: AppRenderer = undefined;
    try renderer.init(std.testing.allocator, std.testing.io, &device, &queue, &surface, .{});
    defer renderer.deinit();
    try surface.configure(std.testing.allocator, &device, .{ .format = gpu.color_format, .width = 100, .height = 100 });
    const ui = @import("ui");
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try ui.box(cx, .{}, .{});
    renderer.pool_maintenance_retry.stopped = true;
    renderer.pool_maintenance_retry.deadline_ns = std.math.maxInt(u64);
    try renderer.frame(cx, 100, 100, 1);
    try std.testing.expect(renderer.prev_frame_cmd_buffer != null);
    try std.testing.expect(!renderer.pool_maintenance_retry.stopped);
    try std.testing.expectEqual(@as(u64, 0), renderer.pool_maintenance_retry.deadline_ns);
}

test "AppRenderer discards a drawable whose size no longer matches the live view and recovers" {
    // SKIP-REASON: drives the null backend's fake surface, whose drawable is
    // exactly the configured extent; Metal drawables follow drawableSize.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    var surface = gpu.Backend.Surface{};
    var renderer: AppRenderer = undefined;
    try renderer.init(std.testing.allocator, std.testing.io, &device, &queue, &surface, .{});
    defer renderer.deinit();
    try surface.configure(std.testing.allocator, &device, .{ .format = gpu.color_format, .width = 100, .height = 100 });
    const cx = try @import("ui").Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try @import("ui").box(cx, .{}, .{});
    const View = struct {
        size: [2]u32,
        fn live(ctx: *anyopaque) [2]u32 {
            const view: *@This() = @ptrCast(@alignCast(ctx));
            return view.size;
        }
    };
    var view: View = .{ .size = .{ 100, 100 } };
    renderer.present_size_probe = .{ .ctx = &view, .live_pixels = View.live };
    try renderer.frame(cx, 100, 100, 1);
    const presented = renderer.frame_count;
    // The view grew after the frame was configured: nothing reaches the screen,
    // and the aborted attempt consumes no frame slot or counter.
    view.size = .{ 120, 100 };
    try std.testing.expectError(error.DrawableSizeStale, renderer.frame(cx, 100, 100, 1));
    try std.testing.expect(!renderer.last_frame_presented);
    try std.testing.expectEqual(presented, renderer.frame_count);
    try std.testing.expectEqual(@as(u64, 1), renderer.stale_drawable_discards);
    // Reconfigured to the live size, the redraw presents.
    try surface.configure(std.testing.allocator, &device, .{ .format = gpu.color_format, .width = 120, .height = 100 });
    try renderer.frame(cx, 120, 100, 1);
    try std.testing.expect(renderer.last_frame_presented);
    try std.testing.expectEqual(presented + 1, renderer.frame_count);
    // Sources that never agree cannot stop presentation: bounded discards.
    view.size = .{ 121, 100 };
    try std.testing.expectError(error.DrawableSizeStale, renderer.frame(cx, 120, 100, 1));
    try std.testing.expectError(error.DrawableSizeStale, renderer.frame(cx, 120, 100, 1));
    try renderer.frame(cx, 120, 100, 1);
    try std.testing.expectEqual(presented + 2, renderer.frame_count);
    try std.testing.expectEqual(@as(u64, 3), renderer.stale_drawable_discards);
}

test "caret preparation scratch is reused per size and released by idle trim" {
    // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    var device = gpu.Backend.Device{};
    var queue = gpu.Backend.Queue{};
    var surface = gpu.Backend.Surface{};
    var renderer: AppRenderer = undefined;
    try renderer.init(std.testing.allocator, std.testing.io, &device, &queue, &surface, .{});
    defer renderer.deinit();
    const before = device.texture_count;
    const first = try renderer.caretScratch(200, 100);
    const first_binding = first.binding();
    for (0..4) |_| try std.testing.expect(first_binding.eql((try renderer.caretScratch(200, 100)).binding()));
    try std.testing.expectEqual(before + 1, device.texture_count);
    const resized = try renderer.caretScratch(300, 100);
    try std.testing.expectEqual(@as(u32, 300), resized.size.width);
    try std.testing.expectEqual(before + 2, device.texture_count);
    try std.testing.expect(renderer.trimIdleResources());
    try std.testing.expect(renderer.caret_scratch == null);
}
