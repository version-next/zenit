//! Public Windows App bridge to the shared GPU rendering coordinator.
//! Heap-owned state keeps every borrowed Device/Queue/Surface pointer stable.
const std = @import("std");
const gpu = @import("gpu");
const render = @import("render");
const ui = @import("ui");
const platform = @import("platform");
const app_renderer = @import("renderer.zig");
const SharedGpu = @import("shared_gpu.zig").SharedGpu;
const legacy = @import("windows_paint.zig");
const render_pacing = @import("render_pacing.zig");

const State = struct {
    owned_device: gpu.Backend.Device,
    owned_queue: gpu.Backend.Queue,
    device: *gpu.Backend.Device,
    queue: *gpu.Backend.Queue,
    shared_gpu: ?*SharedGpu,
    surface: gpu.Backend.Surface,
    renderer: app_renderer.AppRenderer,
    width: u32,
    height: u32,
    font_ranges_context: ?*anyopaque = null,
    font_ranges_provider: @TypeOf(@as(ui.Cx, undefined).text.font_ranges_fn) = null,
};

extern fn zenit_windows_desktop_observer_create(*anyopaque) ?*anyopaque;
extern fn zenit_windows_desktop_observer_destroy(*anyopaque) void;
extern fn zenit_windows_desktop_observer_clock() i64;
extern fn zenit_windows_desktop_observer_capture(*anyopaque, u32, u32, i64) c_int;

/// WARP already admits one render frame at a time. FIFO presentation can
/// nevertheless stall the shared queue behind DXGI for hundreds of ms. Sync
/// interval zero lets DWM prefer the latest completed frame; no tearing flag is
/// enabled. Hardware adapters keep FIFO pacing.
fn surfaceConfig(device: *gpu.Backend.Device, width: u32, height: u32) gpu.Backend.SurfaceConfiguration {
    return .{
        .format = gpu.color_format,
        .width = width,
        .height = height,
        .usage = .color_target_and_read,
        .present_mode = if (device.isSoftware()) .immediate else .fifo,
        .maximum_frame_latency = surfaceFrameLatency(),
    };
}

/// A flip-model swap chain holds latency + 1 window-sized buffers for the
/// window's whole life (unlike CAMetalLayer drawables, which idle trim
/// releases). ZENIT_WINDOWS_FRAME_LATENCY=1..3 overrides the default.
fn surfaceFrameLatency() u32 {
    var buf: [8]u8 = undefined;
    const value = @import("zenit_environment").getInto("ZENIT_WINDOWS_FRAME_LATENCY", &buf) orelse return render_pacing.maximum_frame_latency;
    const parsed = std.fmt.parseInt(u32, value, 10) catch return render_pacing.maximum_frame_latency;
    return std.math.clamp(parsed, 1, 3);
}

pub const Painter = struct {
    pub const NativePaintItem = legacy.PaintItem;
    state: *State,
    recording_window: ?*platform.Window = null,
    recording_readback: ?gpu.Backend.Texture.RecordingReadback = null,
    allocator: std.mem.Allocator,
    image_renderer: *render.ImageRenderer,
    fonts: ?*render.FontSelector = null,
    stack_mode: bool = false,
    path_draw_calls: u32 = 0,
    backdrop_luminance: ?f32 = null,
    capture_directory: ?[]u8 = null,
    capture_count: u32 = 0,
    desktop_observer: ?*anyopaque = null,
    desktop_before: i64 = 0,
    capture_failed: bool = false,
    trace_frames: bool = false,
    trace_window_id: u32 = 0,

    pub fn init(a: std.mem.Allocator, io: std.Io, window: *platform.Window, clear: [4]f32) !Painter {
        return initWithSharedGpu(a, io, window, clear, null);
    }
    pub fn initWithSharedGpu(a: std.mem.Allocator, io: std.Io, window: *platform.Window, clear: [4]f32, shared_slot: ?*?*SharedGpu) !Painter {
        const capture_directory = if (@import("test_harness").enabled)
            @import("zenit_environment").getOwned(a, "ZENIT_WINDOWS_FRAME_CAPTURE_DIR") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            }
        else
            null;
        errdefer if (capture_directory) |directory| a.free(directory);
        const state = try a.create(State);
        errdefer a.destroy(state);
        state.shared_gpu = null;
        state.font_ranges_context = null;
        state.font_ranges_provider = null;
        if (shared_slot) |slot| {
            if (slot.* == null) slot.* = try SharedGpu.init(a, window, false, false);
            state.shared_gpu = slot.*;
            state.device = &state.shared_gpu.?.device;
            state.queue = &state.shared_gpu.?.queue;
        } else {
            var instance = try gpu.Backend.Instance.init(a, .{});
            defer instance.deinit();
            const adapters = try instance.enumerateAdapters();
            defer a.free(adapters);
            defer for (adapters) |*adapter| adapter.deinit();
            if (adapters.len == 0) return error.NoGPU;
            const dq = try adapters[0].requestDevice(a, .{});
            state.owned_device = dq.device;
            state.owned_queue = dq.queue;
            state.device = &state.owned_device;
            state.queue = &state.owned_queue;
        }
        errdefer if (state.shared_gpu == null) {
            state.queue.deinit();
            state.device.deinit();
        };
        const size = window.getDrawableSize();
        state.width = size[0];
        state.height = size[1];
        state.surface = gpu.Backend.Surface.init(window.getNativeSurfaceHandle());
        try state.surface.configure(a, state.device, surfaceConfig(state.device, state.width, state.height));
        errdefer state.surface.deinit();
        try state.renderer.init(a, io, state.device, state.queue, &state.surface, .{ .clear_color = .{ .r = clear[0], .g = clear[1], .b = clear[2], .a = clear[3] } });
        errdefer state.renderer.deinit();
        if (state.shared_gpu) |shared| try state.renderer.image_renderer.setSharedTextureStore(&shared.images);
        // Test builds keep a copy of each presented frame for screenshots, except
        // memory/CPU measurement runs (ZENIT_E2E_MEASURE), as on macOS.
        state.renderer.retain_present_copy = @import("test_harness").enabled and !@import("zenit_environment").flag("ZENIT_E2E_MEASURE");
        const desktop_observer = if (capture_directory != null and @import("zenit_environment").flag("ZENIT_WINDOWS_DESKTOP_CAPTURE"))
            zenit_windows_desktop_observer_create(window.getNativeSurfaceHandle()) orelse return error.DesktopObserverUnavailable
        else
            null;
        state.renderer.desktop_capture_stamp = desktop_observer != null;
        return .{ .desktop_observer = desktop_observer, .state = state, .allocator = a, .image_renderer = &state.renderer.image_renderer, .capture_directory = capture_directory, .trace_frames = @import("zenit_environment").flag("ZENIT_WINDOWS_FRAME_TIMING"), .trace_window_id = window.getWindowId() };
    }

    pub fn deinit(self: *Painter, window: *platform.Window) void {
        self.flushRecording(window);
        _ = window.stopWindowRecording();
        if (self.desktop_observer) |observer| zenit_windows_desktop_observer_destroy(observer);
        if (self.capture_directory) |directory| self.allocator.free(directory);
        window.setRenderCallback(null, null);
        self.state.renderer.deinit();
        self.state.surface.deinit();
        if (self.state.shared_gpu == null) {
            self.state.queue.deinit();
            self.state.device.deinit();
        }
        self.allocator.destroy(self.state);
    }

    // Family and locale already belong to App's DirectWrite FontSystem and
    // its owned FontSelector slots; no separate painter text format exists.
    pub fn setDefaultFontFamily(_: *Painter, _: []const u8) !void {}
    pub fn setDefaultLocale(_: *Painter, _: []const u8) !void {}
    pub fn setFonts(self: *Painter, fonts: ?*render.FontSelector) void {
        if (fonts) |f| {
            self.state.renderer.setFonts(f);
        } else {
            if (self.fonts) |old| {
                if (old.drawn_width_ctx == @as(*anyopaque, @ptrCast(&self.state.renderer.text_renderer))) old.setDrawnWidthSource(null, null);
            }
            self.state.renderer.fonts = null;
        }
        self.fonts = fonts;
    }
    pub fn setFallbackStack(self: *Painter, stack: ?*render.font_fallback_stack.FontFallbackStack) void {
        self.state.renderer.text_renderer.setFallbackStack(stack);
    }
    pub fn setFontRangesProvider(self: *Painter, ctx: ?*anyopaque, provider: @TypeOf(@as(ui.Cx, undefined).text.font_ranges_fn)) void {
        self.state.font_ranges_context = ctx;
        self.state.font_ranges_provider = provider;
        self.state.renderer.text_renderer.font_ranges_context = self.state;
        self.state.renderer.text_renderer.font_ranges_provider = if (provider != null) provideFontRanges else null;
    }
    fn provideFontRanges(raw: *anyopaque, opts: render.TextRenderer.FontRangeRequest, font: *@import("text").Font, allocator: std.mem.Allocator) !?*@import("text").FontRanges {
        const state: *State = @ptrCast(@alignCast(raw));
        const provider = state.font_ranges_provider orelse return null;
        const ctx = state.font_ranges_context orelse return error.MissingFontRangesContext;
        return provider(ctx, .{ .text = opts.text, .font_family = "system", .font_family_id = opts.font_family, .font_size = opts.font_size, .font_weight = opts.font_weight, .use_italic = opts.use_italic, .use_monospace = opts.use_monospace, .use_symbols = opts.use_symbols }, font, allocator);
    }
    pub fn refreshLuminance(self: *Painter, cx: *ui.Cx) bool {
        const changed = self.state.renderer.refreshLuminance(cx);
        self.backdrop_luminance = self.state.renderer.backdrop_luminance;
        return changed;
    }
    pub fn update(self: *Painter, cx: *ui.Cx, window: *platform.Window) !void {
        self.recording_window = window;
        self.state.renderer.setRecordingContextCallback(self, recordingFrame);
        self.state.renderer.setRecordingActive(window.windowRecordingStatus().active != 0);
        const logical = window.getLogicalSize();
        const size = window.getDrawableSize();
        if (size[0] == 0 or size[1] == 0) return;
        if (size[0] != self.state.width or size[1] != self.state.height) {
            self.state.renderer.prepareSurfaceResize(cx);
            try self.state.surface.configure(self.allocator, self.state.device, surfaceConfig(self.state.device, size[0], size[1]));
            self.state.width = size[0];
            self.state.height = size[1];
        }
        // The encoder applies the per-renderer stack override without mutating
        // the caller-owned selector (which may be shared by multiple Apps).
        if (self.desktop_observer != null) self.desktop_before = zenit_windows_desktop_observer_clock();
        const render_start = traceNow(self.state.renderer.io, self.trace_frames);
        try self.state.renderer.frame(cx, logical[0], logical[1], window.getScaleFactor());
        const render_end = traceNow(self.state.renderer.io, self.trace_frames);
        @import("windows_accessibility.zig").publish(cx, window) catch |err| {
            @import("windows_accessibility.zig").clear(window);
            std.log.err("Windows accessibility projection: {s}", .{@errorName(err)});
        };
        const accessibility_end = traceNow(self.state.renderer.io, self.trace_frames);
        self.path_draw_calls = self.state.renderer.last_frame_stats.path_draw_calls;
        self.backdrop_luminance = self.state.renderer.backdrop_luminance;
        self.captureSubmittedFrame(cx, window) catch |err| {
            self.capture_failed = true;
            std.log.err("[windows-shared-capture-error] {s}", .{@errorName(err)});
        };
        const capture_end = traceNow(self.state.renderer.io, self.trace_frames);
        if (self.trace_frames) {
            const stats = self.state.renderer.last_frame_stats;
            std.log.info("[windows-shared-frame-timing] window={d} serial={d} frame_ms={d:.3} render_us={?d} accessibility_us={?d} capture_us={?d} slot_wait_us={d} acquire_us={d} layout_us={d} encode_us={d} flush_us={d} prepare_submit_us={d} retained_hits={d} retained_misses={d} retained_partial={d}", .{ window.getWindowId(), self.state.renderer.frame_count, cx.frame_time_ms, traceElapsed(render_start, render_end), traceElapsed(render_end, accessibility_end), traceElapsed(accessibility_end, capture_end), stats.wait_for_frame_us, stats.acquire_texture_us, stats.layout_us, stats.encode_us, stats.flush_us, stats.gpu_encode_us, stats.retained_hits, stats.retained_misses, stats.retained_partial_repaints });
        }
        @import("test_harness").observeSubmittedFrame(cx);
    }

    // Diagnostic readback affects pacing. Capture every submitted frame,
    // including fully opaque and closed endpoints; never request another frame.
    fn captureSubmittedFrame(self: *Painter, cx: *ui.Cx, window: *platform.Window) !void {
        if (@import("test_harness").frameCaptureFinished()) return;
        const directory = self.capture_directory orelse return;
        if (self.capture_failed) return;
        if (self.capture_count >= 256) return error.FrameCaptureLimitExceeded;
        const stem = try std.fmt.allocPrint(self.allocator, "shared-{d}-frame-{d:0>4}", .{ window.getWindowId(), self.capture_count });
        defer self.allocator.free(stem);
        var dir = try std.Io.Dir.cwd().openDir(self.state.renderer.io, directory, .{});
        defer dir.close(self.state.renderer.io);
        const image_name = try std.fmt.allocPrint(self.allocator, "{s}.bmp", .{stem});
        defer self.allocator.free(image_name);
        const image_path = try std.fs.path.join(self.allocator, &.{ directory, image_name });
        defer self.allocator.free(image_path);
        if (!try self.captureBmp(image_path)) return error.MissingSubmittedFrameCapture;
        if (self.desktop_observer) |observer| {
            if (zenit_windows_desktop_observer_capture(observer, self.capture_count, @intCast(self.state.renderer.frame_count), self.desktop_before) != 1)
                return error.MissingDesktopFrameCapture;
        }

        const tree_buffer = try self.allocator.alloc(u8, 1024 * 1024);
        defer self.allocator.free(tree_buffer);
        const tree = try @import("test_harness").submittedTreeJson(cx, tree_buffer);
        const tree_name = try std.fmt.allocPrint(self.allocator, "{s}.tree.json", .{stem});
        defer self.allocator.free(tree_name);
        try dir.writeFile(self.state.renderer.io, .{ .sub_path = tree_name, .data = tree });
        const metadata = try std.json.Stringify.valueAlloc(self.allocator, .{
            .backend = @tagName(gpu.backend_kind),
            .index = self.capture_count,
            .window_id = window.getWindowId(),
            .frame_serial = self.state.renderer.frame_count,
            .frame_time_ms = cx.frame_time_ms,
            .animation_clock_step_ms = cx.test_frame_step_ms,
            .scale = window.getScaleFactor(),
            .frame_work_area = window.frameWorkArea(),
            .width = self.state.renderer.retained_w,
            .height = self.state.renderer.retained_h,
            .cursor = .{ .visible = cx.virtual_cursor.visible, .x = cx.virtual_cursor.x, .y = cx.virtual_cursor.y, .shape = @tagName(cx.virtual_cursor.shape) },
            .desktop = self.desktop_observer != null,
            .image = image_name,
            .tree = tree_name,
        }, .{});
        defer self.allocator.free(metadata);
        const metadata_name = try std.fmt.allocPrint(self.allocator, "{s}.json", .{stem});
        defer self.allocator.free(metadata_name);
        // Metadata is the commit marker, emitted only after both artifacts.
        try dir.writeFile(self.state.renderer.io, .{ .sub_path = metadata_name, .data = metadata });
        std.log.info("[windows-shared-capture] window={d} index={d} serial={d}", .{ window.getWindowId(), self.capture_count, self.state.renderer.frame_count });
        self.capture_count += 1;
    }

    /// Release frame-loop resources of a window that stopped presenting (see
    /// AppRenderer.trimIdleResources). False while its last frame still runs.
    pub fn trimIdle(self: *Painter) bool {
        return self.state.renderer.trimIdleResources();
    }

    pub fn setRetainedEnabled(self: *Painter, enabled: bool) void {
        self.state.renderer.retained_enabled = enabled;
    }
    pub fn retainedStats(self: *Painter) legacy.RetainedStats {
        const r = &self.state.renderer;
        return .{ .hits = @intCast(r.total_retained_hits), .misses = @intCast(r.total_retained_misses), .partial = @intCast(r.total_retained_partial_repaints) };
    }
    pub fn resetTiming(self: *Painter) void {
        self.state.renderer.timing_ring.reset();
        self.state.renderer.stage_totals = .{};
        self.state.renderer.gpu_timing_ring.reset();
        self.state.renderer.gpu_timing_disjoint_samples = 0;
        self.state.renderer.gpu_timing_failed_samples = 0;
        self.state.renderer.frame_count = 0;
    }
    pub fn timingStats(self: *Painter) legacy.TimingStats {
        const r = &self.state.renderer;
        const last = r.last_frame_stats;
        return .{ .frame_count = r.frame_count, .last = .{ .gpu_execute_us = last.gpu_execute_us, .cpu_frame_us = last.cpu_frame_us, .total_frame_us = last.total_frame_us, .layout_us = last.layout_us, .render_gen_us = last.render_gen_us, .gpu_encode_us = last.gpu_encode_us }, .cpu_p95_us = r.timing_ring.cpuPercentile(95), .total_p95_us = r.timing_ring.totalPercentile(95), .cpu_timing_samples = r.timing_ring.len, .gpu_p95_us = r.gpu_timing_ring.gpuPercentile(95), .timing_samples = r.gpu_timing_ring.len, .disjoint_samples = r.gpu_timing_disjoint_samples, .failed_samples = r.gpu_timing_failed_samples, .query_supported = if (r.gpu_timing_ring.len > 0 or r.gpu_timing_disjoint_samples > 0) 1 else 0 };
        // Report support only after a native query actually resolves. Missing
        // results remain unknown; CPU frame timing is never used as a substitute.
    }

    fn finishRecordingReadback(self: *Painter, window: *platform.Window, timeout_ms: u32) !bool {
        if (self.recording_readback) |*pending| {
            if (!try pending.ready(timeout_ms)) return false;
            const bytes = try pending.bytes();
            var frame: platform.Window.RecordingFrame = .{ .bytes = bytes.ptr, .width = pending.width, .height = pending.height, .stride = pending.stride };
            const ok = window.appendWindowRecordingFrame(&frame);
            pending.deinit();
            self.recording_readback = null;
            if (!ok) return error.RecordingStopped;
        }
        return true;
    }

    pub fn flushRecording(self: *Painter, window: *platform.Window) void {
        const complete = self.finishRecordingReadback(window, 5000) catch false;
        if (!complete) window.failWindowRecording("GPU recording readback failed or timed out");
        if (self.recording_readback) |*pending| pending.deinit();
        self.recording_readback = null;
    }

    fn recordingFrame(context: ?*anyopaque, texture: *const gpu.Backend.Texture) bool {
        const self: *Painter = @ptrCast(@alignCast(context orelse return false));
        const window = self.recording_window orelse return false;
        const ready = self.finishRecordingReadback(window, 0) catch {
            window.failWindowRecording("GPU recording readback failed");
            return false;
        };
        if (!ready or !window.windowRecordingFrameDue()) return true;
        self.recording_readback = texture.beginRecordingReadback() catch {
            window.failWindowRecording("GPU recording copy failed");
            return false;
        };
        return true;
    }

    pub fn captureBmp(self: *Painter, path: []const u8) !bool {
        const r = &self.state.renderer;
        if (!r.retained_valid) return false;
        const drain_start = traceNow(self.state.renderer.io, self.trace_frames);
        r.frame_sync.drain(render_pacing.frames_in_flight);
        const drain_end = traceNow(self.state.renderer.io, self.trace_frames);
        const width = r.retained_w;
        const height = r.retained_h;
        const stride = try std.math.mul(usize, width, 4);
        const len = try std.math.mul(usize, stride, height);
        if (len > std.math.maxInt(u32) - 54 or height > std.math.maxInt(i32)) return error.InvalidCaptureSize;
        const bytes = try self.allocator.alloc(u8, 54 + len);
        defer self.allocator.free(bytes);
        @memset(bytes[0..54], 0);
        bytes[0..2].* = .{ 'B', 'M' };
        std.mem.writeInt(u32, bytes[2..6], @intCast(bytes.len), .little);
        std.mem.writeInt(u32, bytes[10..14], 54, .little);
        std.mem.writeInt(u32, bytes[14..18], 40, .little);
        std.mem.writeInt(u32, bytes[18..22], width, .little);
        std.mem.writeInt(i32, bytes[22..26], -@as(i32, @intCast(height)), .little);
        std.mem.writeInt(u16, bytes[26..28], 1, .little);
        std.mem.writeInt(u16, bytes[28..30], 32, .little);
        std.mem.writeInt(u32, bytes[34..38], @intCast(len), .little);
        try r.retained_tex.?.readBgra8(width, height, bytes[54..], @intCast(stride));
        const read_end = traceNow(self.state.renderer.io, self.trace_frames);
        try std.Io.Dir.cwd().writeFile(self.state.renderer.io, .{ .sub_path = path, .data = bytes });
        const write_end = traceNow(self.state.renderer.io, self.trace_frames);
        if (self.trace_frames) std.log.info("[windows-shared-capture-timing] window={d} serial={d} bytes={d} drain_us={?d} readback_prepare_us={?d} write_us={?d}", .{ self.trace_window_id, r.frame_count, bytes.len, traceElapsed(drain_start, drain_end), traceElapsed(drain_end, read_end), traceElapsed(read_end, write_end) });
        return true;
    }
};

fn traceNow(io: std.Io, enabled: bool) ?@import("zenit_time").Instant {
    return if (enabled) @import("zenit_time").Instant.now(io) catch null else null;
}
fn traceElapsed(start: ?@import("zenit_time").Instant, end: ?@import("zenit_time").Instant) ?u64 {
    return if (start != null and end != null) end.?.since(start.?) / std.time.ns_per_us else null;
}
