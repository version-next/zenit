const std = @import("std");
const gpu = @import("gpu");
const ui = @import("ui");
const env = @import("zenit_environment");
const AppRenderer = @import("app_renderer").AppRenderer;
extern fn zenit_d12_test_hidden_window_create() ?*anyopaque;
extern fn zenit_d12_test_hidden_window_destroy(*anyopaque) void;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;

fn releaseGateAfterDelay(io: std.Io, gate: *anyopaque) void {
    io.sleep(.fromMilliseconds(250), .awake) catch {};
    zenit_d12_test_gate_signal(gate);
}

pub fn run(io: std.Io) !void {
    const a = std.heap.page_allocator;
    const hwnd = zenit_d12_test_hidden_window_create() orelse return error.WindowCreationFailed;
    defer zenit_d12_test_hidden_window_destroy(hwnd);
    var instance = try gpu.Backend.Instance.init(a, .{});
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    defer for (adapters) |*adapter| adapter.deinit();
    var dq = try adapters[0].requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    try @import("render").drawable_extent_contract.run(a, &dq.device, &dq.queue);
    std.debug.print("PASS: 175 percent 1900/1901/1907 drawable edges and native UNORM blend=136\n", .{});
    try checkAliasCopies(&dq.device);
    try checkIdleLuminance(io, a, hwnd, &dq.device, &dq.queue);
    try checkRangeProvider(io, a, hwnd, &dq.device, &dq.queue);
    try checkFrameDamage(io, a, hwnd, &dq.device, &dq.queue);
    try checkOpaqueTextComposite(io, a, hwnd, &dq.device, &dq.queue);
    {
        // Through setFlag: the renderer reads the switch via the cached `flag`,
        // already read by the checks above.
        try env.setFlag("ZENIT_D3D12_SDF_GENERAL_ONLY", "1");
        defer env.setFlag("ZENIT_D3D12_SDF_GENERAL_ONLY", null) catch {};
        try checkFrameDamage(io, a, hwnd, &dq.device, &dq.queue);
        std.debug.print("PASS: optional SDF pipelines unavailable; general pipeline preserves full/partial UI pixel equality\n", .{});
    }

    var surface = gpu.Backend.Surface.init(hwnd);
    defer surface.deinit();
    try surface.configure(a, &dq.device, .{ .format = gpu.color_format, .width = 16, .height = 8, .usage = .color_target_and_read, .present_mode = .immediate });
    const renderer = try a.create(AppRenderer);
    defer a.destroy(renderer);
    try renderer.init(a, io, &dq.device, &dq.queue, &surface, .{ .visual_quality = .full });
    defer renderer.deinit();
    renderer.retain_present_copy = true;
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setWindowMetrics(16, 8, 1);
    cx.root = try ui.box(cx, .{ .width = .{ .px = 16 }, .height = .{ .px = 8 }, .background = ui.Color.hex(0xff0000) }, .{});
    // Idle polling must not require another draw to retire completed GPU
    // resources, nor release any of the three owners ahead of its fence.
    {
        const idle_gate = zenit_d12_test_gate_create(dq.device.context.device.raw, dq.device.context.queue.raw);
        defer {
            zenit_d12_test_gate_signal(idle_gate);
            renderer.frame_sync.drain(3);
            zenit_d12_test_gate_release(idle_gate);
        }
        try renderer.frame_sync.waitForNextFrame();
        var idle_encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        var idle_command = try idle_encoder.finish();
        defer idle_command.deinit();
        renderer.frame_sync.signalOnCompletion(&idle_command);
        try idle_command.submitChecked();
        renderer.prev_frame_cmd_buffer = idle_command.retained();
        renderer.gpu_timing_pending[0] = idle_command.retained();
        _ = renderer.refreshLuminance(cx);
        if (renderer.frame_sync.pending != 1 or renderer.prev_frame_cmd_buffer == null or renderer.gpu_timing_pending[0] == null)
            return error.IdlePollReleasedInflightCommand;
        zenit_d12_test_gate_signal(idle_gate);
        try idle_command.waitChecked(5000);
        _ = renderer.refreshLuminance(cx);
        if (renderer.frame_sync.pending != 0 or renderer.prev_frame_cmd_buffer != null or renderer.gpu_timing_pending[0] != null)
            return error.IdlePollRetainedCompletedCommand;
        if (renderer.frame_count != 0) return error.IdlePollRenderedFrame;
        std.debug.print("PASS: idle poll preserves blocked GPU owners and retires completed frame, presentation and timing references without drawing\n", .{});
    }
    // The idle-owner fixture above submits a real timestamped command. Keep
    // its sample out of the independent seven-frame timestamp assertion.
    std.debug.print("APP_RENDERER_IDLE_FIXTURE_GPU_SAMPLES={d}\n", .{renderer.gpu_timing_ring.len});
    renderer.gpu_timing_ring.reset();
    const before = gpu.Backend.CommandBuffer.error_count.load(.monotonic);
    for (0..7) |i| {
        cx.root.?.setBackground(switch (i % 3) {
            0 => ui.Color.hex(0xff0000),
            1 => ui.Color.hex(0x00ff00),
            else => ui.Color.hex(0x808080),
        });
        try renderer.frame(cx, 16, 8, 1);
        renderer.frame_sync.drain(3);
        if (!renderer.retained_valid) return error.MissingPresentedFrameCopy;
        var pixels: [16 * 8 * 4]u8 = undefined;
        try renderer.retained_tex.?.readBgra8(16, 8, &pixels, 64);
        const expected: [4]u8 = switch (i % 3) {
            0 => .{ 0, 0, 255, 255 },
            1 => .{ 0, 255, 0, 255 },
            else => .{ 128, 128, 128, 255 },
        };
        for (2..6) |y| for (2..14) |x| {
            for (0..4) |c| if (@abs(@as(i32, pixels[(y * 16 + x) * 4 + c]) - expected[c]) > 1) return error.IncorrectAppPresentedPixel;
        };
        for (0..128) |p| std.mem.swap(u8, &pixels[p * 4], &pixels[p * 4 + 2]);
        std.debug.print("APP_RENDERER_FRAME_{d}_RGBA8_HEX={s}\n", .{ i, std.fmt.bytesToHex(pixels, .lower) });
    }
    if (renderer.gpu_timing_ring.len != 6 or renderer.gpu_timing_ring.gpuPercentile(95) == 0)
        return error.MissingAppRendererGpuTimestamps;
    std.debug.print("PASS: AppRenderer seven submitted frames retain six completed native GPU timestamp samples, p95={d}us\n", .{renderer.gpu_timing_ring.gpuPercentile(95)});
    for ([_][2]u32{ .{ 32, 16 }, .{ 16, 8 } }) |size| {
        renderer.prepareSurfaceResize(cx);
        if (renderer.prev_frame_cmd_buffer != null) return error.ResizeRetainedCompletedCommand;
        try surface.configure(a, &dq.device, .{ .format = gpu.color_format, .width = size[0], .height = size[1], .usage = .color_target_and_read, .present_mode = .immediate });
        cx.setWindowMetrics(@floatFromInt(size[0]), @floatFromInt(size[1]), 1);
        cx.needs_redraw = true;
        try renderer.frame(cx, @floatFromInt(size[0]), @floatFromInt(size[1]), 1);
        renderer.frame_sync.drain(3);
        if (renderer.retained_w != size[0] or renderer.retained_h != size[1]) return error.StaleResizeCaptureSize;
    }
    std.debug.print("PASS: AppRenderer completed-command release permits real DXGI resize and restoration with fresh retained dimensions\n", .{});
    // Force a real admission-limit wait independently of machine GPU speed. The
    // animation clock must include the wait that precedes the submitted frame.
    const gate = zenit_d12_test_gate_create(dq.device.context.device.raw, dq.device.context.queue.raw);
    defer {
        zenit_d12_test_gate_signal(gate);
        renderer.frame_sync.drain(3);
        zenit_d12_test_gate_release(gate);
    }
    for (0..renderer.frame_sync.inflight_limit) |_| {
        try renderer.frame_sync.waitForNextFrame();
        var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        var command = try encoder.finish();
        defer command.deinit();
        renderer.frame_sync.signalOnCompletion(&command);
        try command.submitChecked();
    }
    const clock_before = cx.frame_time_ms;
    cx.needs_redraw = true;
    const releaser = try std.Thread.spawn(.{}, releaseGateAfterDelay, .{ io, gate });
    defer releaser.join();
    try renderer.frame(cx, 16, 8, 1);
    const waited_us = renderer.last_frame_stats.wait_for_frame_us;
    const advanced_ms = cx.frame_time_ms - clock_before;
    if (waited_us < 150_000) return error.FrameClockFixtureDidNotBlock;
    if (advanced_ms + 5 < @as(f64, @floatFromInt(waited_us)) / 1000) return error.AnimationClockSampledBeforeGpuWait;
    std.debug.print("PASS: AppRenderer clock includes blocked GPU wait: wait={d}us clock={d:.2}ms\n", .{ waited_us, advanced_ms });
    renderer.frame_sync.drain(3);
    const lease = renderer.offscreen_pool.acquire(&dq.device, 8, 8, renderer.frame_counter) orelse return error.MissingPoolLease;
    if (lease.kind != .pooled) return error.UnexpectedTransientLease;
    if (!renderer.offscreen_pool.release(lease, renderer.frame_counter)) return error.PoolReleaseFailed;
    cx.needs_redraw = true;
    try renderer.frame(cx, 16, 8, 1);
    renderer.frame_sync.drain(3);
    if (renderer.offscreen_pool.entries[lease.slot].?.reusable_after_frame != 0)
        return error.CompletedPoolQuarantineNotReleased;
    {
        var manual = renderer.getEncoder();
        defer manual.deinit();
    }
    if (!renderer.offscreen_pool.release(lease, renderer.frame_counter)) return error.PoolReleaseFailed;
    const protected_until = renderer.offscreen_pool.entries[lease.slot].?.reusable_after_frame;
    cx.needs_redraw = true;
    try renderer.frame(cx, 16, 8, 1);
    renderer.frame_sync.drain(3);
    if (renderer.offscreen_pool.entries[lease.slot].?.reusable_after_frame != protected_until)
        return error.ExternalEncoderQuarantineReleased;
    std.debug.print("PASS: completed managed frames release pool quarantine; external encoders preserve quarantine across later managed frames\n", .{});
    if (gpu.Backend.CommandBuffer.error_count.load(.monotonic) != before) return error.AppRendererEncodingFailed;
    std.debug.print("PASS: production AppRenderer layout/render/encode/retained-copy/FrameSync/submit/Present on hidden HWND; seven frames, 336 interior pixels including sRGB midtone, tolerance one\n", .{});
}

fn checkAliasCopies(device: *gpu.Backend.Device) !void {
    const a = std.heap.page_allocator;
    const pairs = [_][2]gpu.TextureFormat{
        .{ .bgra8_unorm_srgb, .bgra8_unorm }, .{ .bgra8_unorm, .bgra8_unorm_srgb },
        .{ .rgba8_unorm_srgb, .rgba8_unorm }, .{ .rgba8_unorm, .rgba8_unorm_srgb },
    };
    const bytes: [16]u8 = .{ 0, 128, 210, 255, 12, 77, 199, 64, 255, 7, 100, 0, 64, 190, 23, 128 };
    for (pairs) |formats| {
        const native = &device.context.device;
        var src = try native.createTexture(a, .{ .size = .{ .width = 4, .height = 1 }, .format = formats[0], .usage = .{ .copy_src = true, .copy_dst = true } });
        defer src.destroy();
        var dst = try native.createTexture(a, .{ .size = .{ .width = 4, .height = 1 }, .format = formats[1], .usage = .{ .copy_src = true, .copy_dst = true } });
        defer dst.destroy();
        var upload = try native.createBuffer(a, .{ .size = 256, .usage = .{ .map_write = true, .copy_src = true } });
        defer upload.destroy();
        @memcpy((try upload.getMappedRange(0, 16))[0..16], &bytes);
        var readback = try native.createBuffer(a, .{ .size = 256, .usage = .{ .map_read = true, .copy_dst = true } });
        defer readback.destroy();
        var encoder = try native.createCommandEncoder();
        defer encoder.deinit();
        const region = gpu.Backend.native.TextureRegion{ .width = 4, .height = 1 };
        try encoder.copyBufferToTexture(&upload, 0, 256, &src, region);
        try encoder.copyTextureToTexture(&src, region, &dst, region);
        try encoder.copyTextureToBuffer(&dst, region, &readback, 0, 256);
        var command = try encoder.finish();
        defer command.deinit();
        const serial = try device.context.submitCommands(&.{command});
        try device.context.queue.wait(serial, 5000);
        if (!std.mem.eql(u8, try readback.getMappedRange(0, 16), &bytes)) return error.AliasCopyConvertedPixels;
    }
    std.debug.print("PASS: BGRA/RGBA UNORM/sRGB copies in both directions, 64 exact bytes including midtones and alpha (no color conversion)\n", .{});
}

fn checkIdleLuminance(io: std.Io, a: std.mem.Allocator, hwnd: *anyopaque, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    var surface = gpu.Backend.Surface.init(hwnd);
    defer surface.deinit();
    try surface.configure(a, device, .{ .format = gpu.color_format, .width = 64, .height = 64, .usage = .color_target_and_read, .present_mode = .immediate });
    const renderer = try a.create(AppRenderer);
    defer a.destroy(renderer);
    try renderer.init(a, io, device, queue, &surface, .{ .visual_quality = .full });
    defer renderer.deinit();
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setWindowMetrics(64, 64, 1);
    const glass = try ui.box(cx, .{ .width = .{ .px = 48 }, .height = .{ .px = 48 } }, .{});
    const ext = try glass.style.ensureExtFallible(a);
    ext.glass = .{ .backdrop_blur = 4, .glass_intensity = 0 };
    cx.root = try ui.box(cx, .{ .width = .{ .px = 64 }, .height = .{ .px = 64 }, .padding = ui.Padding.all(8) }, .{glass});
    const colors = [_]u24{ 0x808080, 0x000000, 0xffffff };
    const expected = [_]f32{ 0.21586, 0, 1 };
    for (colors, expected) |color, value| {
        cx.root.?.setBackground(ui.Color.hex(color));
        try renderer.frame(cx, 64, 64, 1);
        renderer.frame_sync.drain(3);
        const frame = renderer.frame_count;
        const clock = cx.frame_time_ms;
        if (!renderer.refreshLuminance(cx)) {
            for (renderer.persistent_gpu.luminance_slots) |slot| {
                if (slot.key != std.math.maxInt(u32)) std.debug.print("idle failed color={x} key={d} prev={} cur={} size={d}x{d} value={any} staging={}\n", .{ color, slot.key, slot.prev_pending, slot.cur_pending, slot.prev_w, slot.prev_h, slot.value, slot.staging != null });
            }
            return error.IdleLuminanceDidNotPublish;
        }
        const actual = cx.backdrop_luminance orelse return error.MissingIdleLuminance;
        if (@abs(actual - value) > 0.02) {
            std.debug.print("idle luminance expected={d} actual={d}\n", .{ value, actual });
            return error.IncorrectIdleLuminance;
        }
        if (cx.backdrop_luminance_region_count != 1 or cx.backdrop_luminance_regions[0].node_id != glass.id) return error.IncorrectIdleLuminanceOwner;
        if (renderer.refreshLuminance(cx)) return error.RepeatedIdleLuminanceRedraw;
        if (renderer.frame_count != frame or cx.frame_time_ms != clock) return error.IdleLuminanceAdvancedFrame;
    }
    // Hold the latest fence incomplete. Polling must return before this gate
    // is released; it must not wait for rendering or consume pending samples.
    const gate = zenit_d12_test_gate_create(device.context.device.raw, device.context.queue.raw);
    defer zenit_d12_test_gate_release(gate);
    defer zenit_d12_test_gate_signal(gate);
    var encoder = try gpu.Backend.CommandEncoder.init(queue);
    var pending = try encoder.finish();
    defer pending.deinit();
    try pending.submitChecked();
    defer {
        zenit_d12_test_gate_signal(gate);
        pending.waitUntilCompleted();
    }
    if (renderer.prev_frame_cmd_buffer) |*previous| previous.deinit();
    renderer.prev_frame_cmd_buffer = pending.retained();
    renderer.persistent_gpu.luminance_slots[0].prev_pending = true;
    const releaser = try std.Thread.spawn(.{}, releaseGateAfterDelay, .{ io, gate });
    defer releaser.join();
    const started = try @import("zenit_time").Instant.now(io);
    if (renderer.refreshLuminance(cx)) return error.UnfinishedLuminancePublished;
    const elapsed = (try @import("zenit_time").Instant.now(io)).since(started);
    if (elapsed > 150 * std.time.ns_per_ms) return error.IdleLuminanceWaitedForGpu;
    if (!renderer.persistent_gpu.luminance_slots[0].prev_pending) return error.UnfinishedLuminanceConsumed;
    std.debug.print("PASS: incomplete GPU fence leaves idle luminance pending without waiting ({d}us)\n", .{elapsed / 1000});
    std.debug.print("PASS: idle Glass luminance publishes first frame, gray/black/white transitions and owner without redraw or clock advance; repeated polling unchanged\n", .{});
}

fn checkRangeProvider(io: std.Io, a: std.mem.Allocator, hwnd: *anyopaque, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    const text = @import("text");
    const render = @import("render");
    const Provider = struct {
        selected: *text.Font,
        calls: usize = 0,
        fn ranges(raw: *anyopaque, opts: render.TextRenderer.FontRangeRequest, _: *text.Font, allocator: std.mem.Allocator) !?*text.FontRanges {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!std.mem.eql(u8, opts.text, "A") or opts.font_size != 24 or opts.use_italic or opts.use_monospace or opts.use_symbols) return error.IncorrectRangeProviderOptions;
            const snapshot = try allocator.create(text.FontRanges);
            errdefer allocator.destroy(snapshot);
            snapshot.* = try text.FontRanges.init(allocator, opts.text, &.{.{ .font = self.selected, .start = 0, .length = 1, .size = 24 }});
            self.calls += 1;
            return snapshot;
        }
    };
    var fonts = try text.FontSystem.init(a, io);
    defer fonts.deinit();
    const primary = try fonts.findFont(.{ .family = "Segoe UI", .size = 24 });
    const selected = try fonts.findFont(.{ .family = "Consolas", .size = 24 });
    var selector = render.FontSelector{ .small = primary, .medium = primary, .large = primary };
    var provider = Provider{ .selected = selected };
    var surface = gpu.Backend.Surface.init(hwnd);
    defer surface.deinit();
    try surface.configure(a, device, .{ .format = gpu.color_format, .width = 128, .height = 64, .usage = .color_target_and_read, .present_mode = .immediate });
    const renderer = try a.create(AppRenderer);
    defer a.destroy(renderer);
    try renderer.init(a, io, device, queue, &surface, .{ .visual_quality = .full });
    defer renderer.deinit();
    renderer.retain_present_copy = true;
    renderer.setFonts(&selector);
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setWindowMetrics(128, 64, 1);
    const label = try ui.text(cx, "A", .{ .font_size = 24 });
    cx.root = try ui.box(cx, .{ .width = .{ .px = 128 }, .height = .{ .px = 64 }, .padding = ui.Padding.all(8) }, .{label});
    var hashes: [4]u64 = undefined;
    for (0..4) |mode| {
        renderer.text_renderer.font_ranges_provider = if (mode == 0 or mode == 3) null else Provider.ranges;
        renderer.text_renderer.font_ranges_context = &provider;
        if (mode == 2) provider.selected = primary;
        label.markRenderDirty();
        try renderer.frame(cx, 128, 64, 1);
        renderer.frame_sync.drain(3);
        var pixels: [128 * 64 * 4]u8 = undefined;
        try renderer.retained_tex.?.readBgra8(128, 64, &pixels, 512);
        hashes[mode] = std.hash.Wyhash.hash(0, &pixels);
        if (renderer.text_renderer.active_font_ranges != null) return error.BorrowedRangeEscapedDraw;
    }
    if (provider.calls < 2 or hashes[0] == hashes[1] or hashes[1] == hashes[2] or hashes[0] != hashes[3]) return error.RangeProviderDidNotAffectSubmittedPixels;
    std.debug.print("PASS: AppRenderer provider options, custom-font pixels, same-address provider mutation, clear restores baseline and borrowed snapshot cleared\n", .{});
}

fn checkFrameDamage(io: std.Io, a: std.mem.Allocator, hwnd: *anyopaque, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    const text = @import("text");
    const render = @import("render");
    var fonts = try text.FontSystem.init(a, io);
    defer fonts.deinit();
    const font = try fonts.findFont(.{ .family = "Segoe UI", .size = 16 });
    var selector = render.FontSelector{ .small = font, .medium = font, .large = font };
    var surface = gpu.Backend.Surface.init(hwnd);
    defer surface.deinit();
    try surface.configure(a, device, .{ .format = gpu.color_format, .width = 256, .height = 128, .usage = .color_target_and_read, .present_mode = .immediate });
    const renderer = try a.create(AppRenderer);
    defer a.destroy(renderer);
    try renderer.init(a, io, device, queue, &surface, .{ .visual_quality = .full });
    defer renderer.deinit();
    renderer.retain_present_copy = true;
    renderer.setFonts(&selector);
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setWindowMetrics(256, 128, 1);
    const child = try ui.box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 24 }, .background = ui.Color.hex(0xc05030) }, .{});
    const label = try ui.text(cx, "Alpha", .{ .font_size = 16 });
    const clip = try ui.box(cx, .{ .width = .{ .px = 84 }, .height = .{ .px = 28 }, .overflow = .hidden }, .{label});
    cx.root = try ui.box(cx, .{ .width = .{ .px = 256 }, .height = .{ .px = 128 }, .background = ui.Color.hex(0x807060), .padding = ui.Padding.all(12) }, .{ child, clip });
    const before = gpu.Backend.CommandBuffer.error_count.load(.monotonic);
    for (0..9) |stage| {
        // Establish a cache, then move/shrink/recolor the foreground rectangle.
        renderer.retained_enabled = true;
        try renderer.frame(cx, 256, 128, 1);
        switch (stage) {
            1 => child.setMarginLeft(17),
            2 => child.setWidth(12),
            3 => child.setBackground(ui.Color.hex(0x3090b0)),
            4 => child.setMarginTop(23),
            5 => try label.setTextContent(a, "Longer clipped text"),
            6 => clip.setWidth(34),
            7 => cx.root.?.removeChild(child),
            8 => try cx.root.?.appendChild(a, child),
            else => {},
        }
        cx.needs_redraw = true;
        try renderer.frame(cx, 256, 128, 1);
        renderer.frame_sync.drain(3);
        var partial: [256 * 128 * 4]u8 = undefined;
        try renderer.retained_tex.?.readBgra8(256, 128, &partial, 1024);
        renderer.retained_enabled = false;
        cx.needs_redraw = true;
        try renderer.frame(cx, 256, 128, 1);
        renderer.frame_sync.drain(3);
        var full: [256 * 128 * 4]u8 = undefined;
        try renderer.retained_tex.?.readBgra8(256, 128, &full, 1024);
        if (!std.mem.eql(u8, &partial, &full)) return error.PartialFramePixelMismatch;
    }
    // The static prefix must survive suffix opacity changes, while mutations
    // to the background invalidate it. Compare the entire native surface.
    cx.root.?.removeChild(clip);
    try cx.root.?.appendChild(a, clip);
    clip.setOpacity(0.5);
    for (0..7) |stage| {
        renderer.retained_enabled = true;
        try renderer.frame(cx, 256, 128, 1);
        clip.setOpacity(0.2 + @as(f32, @floatFromInt(stage)) * 0.1);
        if (stage == 2) cx.root.?.setBackground(ui.Color.hex(0x456789));
        if (stage == 4) child.setBackground(ui.Color.hex(0x806040));
        if (stage == 5) child.setMarginLeft(25);
        if (stage == 6) child.setWidth(8);
        cx.needs_redraw = true;
        try renderer.frame(cx, 256, 128, 1);
        renderer.frame_sync.drain(3);
        var cached: [256 * 128 * 4]u8 = undefined;
        try renderer.retained_tex.?.readBgra8(256, 128, &cached, 1024);
        renderer.retained_enabled = false;
        cx.needs_redraw = true;
        try renderer.frame(cx, 256, 128, 1);
        renderer.frame_sync.drain(3);
        var full: [256 * 128 * 4]u8 = undefined;
        try renderer.retained_tex.?.readBgra8(256, 128, &full, 1024);
        if (!std.mem.eql(u8, &cached, &full)) return error.BackgroundPrefixPixelMismatch;
    }
    if (device.isSoftware() and renderer.background_reuse_count < 2) return error.BackgroundPrefixNotExercised;
    if (device.isSoftware() and renderer.background_partial_count < 3) return error.BackgroundPartialNotExercised;
    std.debug.print("PASS: static prefix opacity changes and full/partial background invalidation match full redraw; reuse={d} partial={d}\n", .{ renderer.background_reuse_count, renderer.background_partial_count });
    if (device.isSoftware() and (renderer.frame_partial_count < 4 or renderer.frame_reuse_count < 1)) return error.FrameDamagePathNotExercised;
    if (gpu.Backend.CommandBuffer.error_count.load(.monotonic) != before) return error.FrameDamageEncodingFailed;
    std.debug.print("PASS: frame damage movement/shrink/color/text/clip/removal/reinsert/unchanged match complete redraw byte-for-byte; partial={d} reuse={d}\n", .{ renderer.frame_partial_count, renderer.frame_reuse_count });
}

fn checkOpaqueTextComposite(io: std.Io, a: std.mem.Allocator, hwnd: *anyopaque, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    const text = @import("text");
    const render = @import("render");
    var fonts = try text.FontSystem.init(a, io);
    defer fonts.deinit();
    const font = try fonts.findFont(.{ .family = "Segoe UI", .size = 14 });
    var selector = render.FontSelector{ .small = font, .medium = font, .large = font };
    selector.setScaleFactor(1.75);
    var surface = gpu.Backend.Surface.init(hwnd);
    defer surface.deinit();
    try surface.configure(a, device, .{ .format = gpu.color_format, .width = 448, .height = 224, .usage = .color_target_and_read, .present_mode = .immediate });
    const renderer = try a.create(AppRenderer);
    defer a.destroy(renderer);
    try renderer.init(a, io, device, queue, &surface, .{ .visual_quality = .full });
    defer renderer.deinit();
    renderer.retain_present_copy = true;
    renderer.retained_enabled = false;
    renderer.setFonts(&selector);
    if (renderer.text_renderer.cleartype_enabled) {
        var backdrop = render.text_render_policy.Backdrop{};
        backdrop.reset(256, 128, false);
        backdrop.add(.{ 0, 0, 48, 128 });
        renderer.text_renderer.beginFrame(256, 128, 1.75);
        renderer.text_renderer.cleartype_allowed = true;
        renderer.text_renderer.lcd_backdrop = &backdrop;
        try renderer.text_renderer.drawTextWithOptions("Consistency", 16, 44, font, render.Color.BLACK, 14, false, null, false, true, 0);
        if (renderer.text_renderer.instances_nearest.items.len == 0) return error.RunModeFixtureEmpty;
        for (renderer.text_renderer.instances_nearest.items) |instance| if (instance.metadata.colorMode() != 0) return error.MixedRunAntialiasing;
        const plain_count = renderer.text_renderer.instances_nearest.items.len;
        try renderer.text_renderer.drawTextWithSpans("Consistency", 16, 44, font, render.Color.BLACK, 14, false, null, false, true, 0, &.{.{ .start = 1, .end = 6, .color = render.Color.RED }});
        if (renderer.text_renderer.instances_nearest.items.len == plain_count) return error.SpanModeFixtureEmpty;
        for (renderer.text_renderer.instances_nearest.items[plain_count..]) |instance| if (instance.metadata.colorMode() != 0) return error.MixedSpanAntialiasing;
        renderer.text_renderer.lcd_backdrop = null;
        renderer.text_renderer.cleartype_allowed = false;
        std.debug.print("PASS: one word crossing the opaque proof boundary uses one grayscale AA mode\n", .{});
    }
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setWindowMetrics(256, 128, 1.75);
    const label = try ui.text(cx, "Sheet panel content.", .{ .font_size = 14, .color = ui.Color.hex(0x1c1612) });
    const group = try ui.box(cx, .{ .width = .{ .px = 224 }, .height = .{ .px = 96 }, .padding = ui.Padding.all(16) }, .{label});
    cx.root = try ui.box(cx, .{ .width = .{ .px = 256 }, .height = .{ .px = 128 }, .background = ui.Color.hex(0xf8f8f8) }, .{group});
    var baseline: [448 * 224 * 4]u8 = undefined;
    var composite: [448 * 224 * 4]u8 = undefined;
    try renderer.frame(cx, 256, 128, 1.75);
    renderer.frame_sync.drain(3);
    try renderer.retained_tex.?.readBgra8(448, 224, &baseline, 1792);
    const lcd_baseline = baseline;
    const system_lcd = renderer.text_renderer.cleartype_enabled;
    if (system_lcd and (renderer.text_renderer.lcd_glyph_count == 0 or renderer.text_renderer.gray_glyph_count != 0)) return error.OpaqueTextNotLCD;
    if (!system_lcd and renderer.text_renderer.lcd_glyph_count != 0) return error.DisabledClearTypeUsedLCD;
    try env.setFlag("ZENIT_TEXT_BASELINE_GRAYSCALE", "1");
    defer env.setFlag("ZENIT_TEXT_BASELINE_GRAYSCALE", null) catch {};
    cx.root.?.markRenderDirty();
    cx.needs_redraw = true;
    try renderer.frame(cx, 256, 128, 1.75);
    renderer.frame_sync.drain(3);
    if (renderer.text_renderer.lcd_glyph_count != 0 or renderer.text_renderer.gray_glyph_count == 0) return error.DirectGrayTextWrongMode;
    try renderer.retained_tex.?.readBgra8(448, 224, &baseline, 1792);
    try env.setFlag("ZENIT_TEXT_BASELINE_GRAYSCALE", null);
    group.style.ensureExtPanic(a).composited_group = true;
    group.markRenderDirty();
    try renderer.frame(cx, 256, 128, 1.75);
    renderer.frame_sync.drain(3);
    if (renderer.text_renderer.lcd_glyph_count != 0 or renderer.text_renderer.gray_glyph_count == 0) return error.CompositeTextNotGrayscale;
    try renderer.retained_tex.?.readBgra8(448, 224, &composite, 1792);
    var max_diff: u32 = 0;
    var legacy_cross_mode_diff: u32 = 0;
    var changed: usize = 0;
    var ink: [2]usize = .{ 0, 0 };
    for (0..448 * 224) |pixel| {
        var sums: [2]u32 = .{ 0, 0 };
        for (0..3) |c| {
            const x = baseline[pixel * 4 + c];
            const y = composite[pixel * 4 + c];
            legacy_cross_mode_diff = @max(legacy_cross_mode_diff, @as(u32, @intCast(@abs(@as(i32, lcd_baseline[pixel * 4 + c]) - @as(i32, y)))));
            const d: u32 = @intCast(@abs(@as(i32, x) - @as(i32, y)));
            max_diff = @max(max_diff, d);
            if (d > 1) changed += 1;
            sums[0] += x;
            sums[1] += y;
        }
        for (0..2) |i| if (sums[i] < 300) {
            ink[i] += 1;
        };
    }
    std.debug.print("LEGACY_CROSS_MODE_DIFF={d}\n", .{legacy_cross_mode_diff});
    std.debug.print("TEXT_COMPOSITE_GRAY_IDENTITY max_diff={d} changed_channels={d} direct_ink={d} composite_ink={d}\n", .{ max_diff, changed, ink[0], ink[1] });
    if (max_diff > 1) return error.OpaqueTextCompositeChangedPixels;
    std.debug.print("PASS: transparent composite text is grayscale, opaque direct text follows system LCD={}; same-mode gray composition max_diff={d}\n", .{ system_lcd, max_diff });
}
