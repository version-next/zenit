/// command_executor: main thread consumes commands and executes UI operations.
///
/// Minimal: supports IME / click / type / key / query / focused / screenshot.
/// Command dispatch to cx.handleX() API.
const std = @import("std");
const ui = @import("ui");
const Cx = ui.Cx;
const Node = ui.Node;
const KeyCode = ui.events.KeyCode;
const Modifiers = ui.events.Modifiers;

const command_queue = @import("command_queue.zig");
const CommandQueue = command_queue.CommandQueue;
const TestCommand = command_queue.TestCommand;
const tree_serializer = @import("tree_serializer.zig");
const JsonWriter = @import("json_writer.zig").JsonWriter;

// Bounded observation on the UI thread. Keep IDs, never pointers to removable nodes.
const FrameSample = struct { ms: f64, x: f32, y: f32, w: f32, h: f32, opacity: f32, effective_opacity: f32 };
var frame_target: ?command_queue.TestIdPayload = null;
/// Active /scroll_stream: next event index and due time.
var stream: ?struct { spec: command_queue.ScrollStream, sent: u32 = 0, next_ns: i128 } = null;
var frame_samples: [128]FrameSample = undefined;
var frame_count: usize = 0;
var frame_missing: usize = 0;
var frame_overflow: bool = false;
var frame_started: i128 = 0;
var frame_context: usize = 0;
var frame_escape_on_enter: bool = false;
var frame_action_index: ?usize = null;
var frame_capture_path: ?command_queue.TestIdPayload = null;
var frame_capture_after_ms: f64 = 0;
var frame_capture_started_ms: f64 = 0;
var frame_capture_index: ?usize = null;
var frame_capture_failed: bool = false;

pub fn observeSubmittedFrame(ctx: *Cx) void {
    const target = frame_target orelse return;
    if (getCtx() != ctx or frame_context != @intFromPtr(ctx)) return; // Only the currently bound automation window.
    const root = ctx.root orelse return;
    const node = tree_serializer.findByTestId(root, target.getText()) orelse {
        frame_missing += 1;
        return;
    };
    if (frame_count == frame_samples.len) {
        frame_overflow = true;
        return;
    }
    const r = node.globalRect();
    // Timed pixels represent the animation evaluated at frame start, not the
    // later GPU completion instant. Cold/slow submits must not label an
    // initial hidden frame as an intermediate animation frame. Ordinary frame
    // audits retain real submission timestamps.
    const sample_ms = if (frame_capture_after_ms > 0)
        @max(0, ctx.frame_time_ms - frame_capture_started_ms)
    else
        @as(f64, @floatFromInt(@import("zenit_time").monotonicTimestamp(ctx.io) - frame_started)) / 1e6;
    frame_samples[frame_count] = .{ .ms = sample_ms, .x = r.x, .y = r.y, .w = r.w, .h = r.h, .opacity = node.getOpacity(), .effective_opacity = tree_serializer.effectiveOpacity(node, &ctx.overlay_stack) };
    frame_count += 1;
    if (frame_capture_path) |path| {
        if (frame_samples[frame_count - 1].ms >= frame_capture_after_ms) {
            // Capture only the already submitted surface. Disarm before callback;
            // later RPC latency cannot change which frame is returned.
            frame_capture_path = null;
            frame_capture_index = frame_count - 1;
            frame_capture_failed = if (g_capture_screenshot_fn) |capture| !capture(path.getText()) else true;
        }
    }
    const alpha = frame_samples[frame_count - 1].effective_opacity;
    const prior = if (frame_count > 1) frame_samples[frame_count - 2].effective_opacity else 0;
    if (frame_escape_on_enter and alpha > 0 and alpha < 0.999 and alpha > prior) {
        // Record the submitted state before dispatch; the next render observes
        // the reversal. Disarm first because handlers can remove the target.
        frame_escape_on_enter = false;
        frame_action_index = frame_count - 1;
        ctx.handleKeyDown(.escape, .{});
    }
}

// ── Callbacks ──

pub const GetCtxFn = *const fn () ?*Cx;
pub const CaptureScreenshotFn = *const fn (path: []const u8) bool;

pub const RecordingState = struct {
    ok: bool = false,
    active: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    fps: u32 = 0,
    duration_ms: u64 = 0,
    file_size: u64 = 0,
    frame_count: u64 = 0,
    dropped_frames: u64 = 0,
    path: [command_queue.RecordingStartPayload.PATH_CAP]u8 = @as([command_queue.RecordingStartPayload.PATH_CAP]u8, @splat(0)),
    path_len: u16 = 0,
    error_message: [256]u8 = @as([256]u8, @splat(0)),
    error_len: u16 = 0,

    pub fn setPath(self: *RecordingState, value: []const u8) void {
        const len = @min(value.len, self.path.len);
        @memcpy(self.path[0..len], value[0..len]);
        self.path_len = @intCast(len);
    }

    pub fn setError(self: *RecordingState, value: []const u8) void {
        const len = @min(value.len, self.error_message.len);
        @memcpy(self.error_message[0..len], value[0..len]);
        self.error_len = @intCast(len);
    }

    pub fn pathText(self: *const RecordingState) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn errorText(self: *const RecordingState) []const u8 {
        return self.error_message[0..self.error_len];
    }
};

pub const StartRecordingFn = *const fn (path: []const u8, fps: u32) RecordingState;
pub const RecordingStateFn = *const fn () RecordingState;

/// FrameStats snapshot (harness subset of renderer.FrameStats; don't link zenit_app to avoid
/// cycles).
/// Cumulative entry attempts only; excluded host polls are counted separately.
pub const CaretRejections = struct {
    occluded: u64 = 0,
    patch_unavailable: u64 = 0,
    preparation_gpu_failed: u64 = 0,
    host_transition: u64 = 0,
    busy: u64 = 0,
    renderer_disabled: u64 = 0,
    other: u64 = 0,
};

/// Per-stage sums since the last timing reset (renderer.StageTotals mirror;
/// field names match so the app copies them generically). Divide by frames.
pub const StageTotals = struct {
    frames: u64 = 0,
    layout_us: u64 = 0,
    render_gen_us: u64 = 0,
    gpu_encode_us: u64 = 0,
    wait_for_frame_us: u64 = 0,
    acquire_texture_us: u64 = 0,
    cpu_frame_us: u64 = 0,
    total_frame_us: u64 = 0,
    encode_us: u64 = 0,
    flush_us: u64 = 0,
    submit_us: u64 = 0,
    present_us: u64 = 0,
    prep_us: u64 = 0,
    setup_us: u64 = 0,
    teardown_us: u64 = 0,
    thread_kcycles_period: u64 = 0,
    thread_kcycles_frame: u64 = 0,
    thread_kcycles_present: u64 = 0,
    glass_us: u64 = 0,
    pass_native_us: u64 = 0,
    render_passes: u64 = 0,
    draw_calls: u64 = 0,
    backend_draws: u64 = 0,
    backend_draw_us: u64 = 0,
    backend_bind_us: u64 = 0,
    backend_native_draw_us: u64 = 0,
    backend_uniform_snapshots: u64 = 0,
    backend_texture_views: u64 = 0,
    backend_bind_groups: u64 = 0,
    gpu_execute_us: u64 = 0,
};
pub const FrameStatsSnapshot = struct {
    renderer_backend: ?[]const u8 = null,
    gpu_validation_errors: ?u32 = null,
    gpu_software: ?bool = null,
    window_logical_width: ?u32 = null,
    window_logical_height: ?u32 = null,
    window_pixel_width: ?u32 = null,
    window_pixel_height: ?u32 = null,
    clipboard_write_ready: ?bool = null,
    retained_hits: u32 = 0,
    retained_misses: u32 = 0,
    retained_partial_repaints: u32 = 0,
    /// Cumulative count of complete offscreen texture pool acquire failures. > 0 = silent
    /// degradation appeared on screen (blur fewer levels / composite layer not drawn),
    /// direct indicator of 'multiple glass islands flickering together'.
    offscreen_pool_exhausted: u64 = 0,
    /// Cumulative count of text pipeline uniform slot overflows into the backup buffer.
    ///
    /// Like offscreen_pool_exhausted: a direct indicator of 'clip switches far exceed expected per
    /// frame'. Overflow no longer drops text (it switches to the overflow buffer and keeps
    /// drawing), but continued growth still means the clip chain is re-emitted per line; check
    /// clip-prefix retention instead of raising the limit. (Historically, each +1 meant an entire
    /// batch of text was not drawn.)
    text_uniform_overflow: u64 = 0,
    path_draw_calls: u32 = 0,
    frame_count: u64 = 0,
    graphics_footprint_bytes: u64 = 0,
    caret_flipping: bool = false,
    caret_visible: bool = false,
    caret_rect_count: u32 = 0,
    caret_entries: u64 = 0,
    caret_attempts: u64 = 0,
    caret_rejections: CaretRejections = .{},
    caret_gate_blocked: u64 = 0,
    caret_admission_failures: u8 = 0,
    caret_admission_next_ns: i128 = 0,
    caret_flips: u64 = 0,
    caret_last_flip_ms: i64 = 0,
    /// Frames dropped because the drawable no longer matched the live view size.
    stale_drawable_discards: u64 = 0,
    /// Backdrop brightness auto-adapt measured value; -1 = absent (disabled/no glass).
    backdrop_luminance: f32 = -1,
    /// Render invariant: cumulative repeated fill rect count (same node one frame emits identical
    /// fill twice), > 0 = cached-replay double-emit bug.
    paint_duplicate_fills: u64 = 0,
    /// Last double-emit node id (0 = never).
    paint_duplicate_node: u32 = 0,
    /// ZENIT_VERIFY_INCREMENTAL: cumulative cached-vs-full lowered item mismatches (0 = equal).
    incremental_verify_mismatches: u64 = 0,

    // -- Timing (microseconds) --
    // These fields were absent: real GPU time always in renderer.FrameStats, never projected to
    // harness, GPU perf regressions completely unobservable (zero gate).
    //
    // **Per-frame value** (noisy, log reference only, not for assertions):
    /// Latest completed valid GPU time bracket (Metal command buffer / D3D11 query).
    gpu_execute_us: u64 = 0,
    /// Previous frame pure CPU pipeline time (excludes wait/acquire).
    cpu_frame_us: u64 = 0,
    /// Breakdown: which segment regressed.
    layout_us: u64 = 0,
    render_gen_us: u64 = 0,
    gpu_encode_us: u64 = 0,
    // CPU wall-clock breakdown. null means the backend does not publish it.
    wait_for_frame_us: ?u64 = null,
    acquire_texture_us: ?u64 = null,
    encode_us: ?u64 = null,
    flush_us: ?u64 = null,
    glass_count: u32 = 0,
    glass_us: u64 = 0,
    texture_creates: u32 = 0,
    render_passes: u32 = 0,
    blit_passes: u32 = 0,
    compute_passes: u32 = 0,
    pass_native_us: u64 = 0,
    /// Previous frame total time.
    total_frame_us: u64 = 0,
    stage_totals: ?StageTotals = null,

    // **Cross-frame P95** (gate assertion anti-noise statistic; ~120 recent render frames):
    gpu_p95_us: u64 = 0,
    cpu_p95_us: u64 = 0,
    total_p95_us: u64 = 0,
    /// P95 valid sample count, check sufficient before asserting, else judging empty/sparse window
    /// (returns 0 = forever green fake signal).
    timing_samples: u32 = 0,
    /// CPU samples may exist even when GPU timestamps are rejected.
    cpu_timing_samples: u32 = 0,
    gpu_timing_disjoint_samples: u64 = 0,
    gpu_timing_failed_samples: u64 = 0,
    gpu_timing_pending_queries: u32 = 0,
    gpu_timing_query_supported: ?bool = null,
};
pub const GetFrameStatsFn = *const fn () FrameStatsSnapshot;
/// Clear cross-frame timing sample ring (call after perf gate scenario entry).
pub const ResetTimingFn = *const fn () void;

var g_get_ctx_fn: ?GetCtxFn = null;
// Main-thread-only barrier for the process's submitted-surface archive. Once
// acknowledged, no window may start another frame artifact write.
var g_frame_capture_finished = false;
pub fn frameCaptureFinished() bool {
    return g_frame_capture_finished;
}
pub var screenshot_windows: @import("screenshot_windows.zig").Registry = .{};
var command_begin: ?*const fn () void = null;
var command_end: ?*const fn () void = null;
pub fn setCommandBoundaryCallbacks(begin: ?*const fn () void, end: ?*const fn () void) void {
    command_begin = begin;
    command_end = end;
}
var g_capture_screenshot_fn: ?CaptureScreenshotFn = null;
var g_start_recording_fn: ?StartRecordingFn = null;
var g_recording_status_fn: ?RecordingStateFn = null;
var g_stop_recording_fn: ?RecordingStateFn = null;
var g_get_frame_stats_fn: ?GetFrameStatsFn = null;
var g_reset_timing_fn: ?ResetTimingFn = null;
var g_resize_window_fn: ?ResizeWindowFn = null;
pub const WindowCommandFn = *const fn (command_queue.WindowCommand) ?command_queue.WindowSnapshot;
var g_window_command_fn: ?WindowCommandFn = null;
pub fn setWindowCommandFn(f: WindowCommandFn) void {
    g_window_command_fn = f;
}
var g_quit_app_fn: ?*const fn () bool = null;
pub fn setQuitAppFn(f: *const fn () bool) void {
    g_quit_app_fn = f;
}

pub fn setGetCtxFn(f: GetCtxFn) void {
    g_get_ctx_fn = f;
}

pub fn setCaptureScreenshotFn(f: CaptureScreenshotFn) void {
    g_capture_screenshot_fn = f;
}

pub fn setRecordingCallbacks(start: StartRecordingFn, status: RecordingStateFn, stop: RecordingStateFn) void {
    g_start_recording_fn = start;
    g_recording_status_fn = status;
    g_stop_recording_fn = stop;
}

pub fn startRecording(path: []const u8, fps: u32) RecordingState {
    return if (g_start_recording_fn) |f| f(path, fps) else .{};
}
pub fn recordingStatus() RecordingState {
    return if (g_recording_status_fn) |f| f() else .{};
}
pub fn stopRecording() RecordingState {
    return if (g_stop_recording_fn) |f| f() else .{};
}

/// CPU patch control: mode 0 query, 1 enable, 2 disable; false = unsupported.
pub const CpuPatchStatus = struct {
    enabled: bool = false,
    cpu_frames: u64 = 0,
    gpu_frames: u64 = 0,
    shown: u32 = 0,
    unchanged_frames: u64 = 0,
    rects: [24][4]u32 = undefined,
    rect_count: usize = 0,
};
pub const CpuPatchFn = *const fn (mode: u8, out: *CpuPatchStatus) bool;
var g_cpu_patch_fn: ?CpuPatchFn = null;
pub fn setCpuPatchFn(f: CpuPatchFn) void {
    g_cpu_patch_fn = f;
}

/// Writes the WindowServer image of the key window to a PNG; 1 = written.
pub const CompositedCaptureFn = *const fn (path: [*:0]const u8) callconv(.c) c_int;
var g_composited_capture_fn: ?CompositedCaptureFn = null;
pub fn setCompositedCaptureFn(f: CompositedCaptureFn) void {
    g_composited_capture_fn = f;
}

pub fn setGetFrameStatsFn(f: GetFrameStatsFn) void {
    g_get_frame_stats_fn = f;
}

pub fn setResetTimingFn(f: ResetTimingFn) void {
    g_reset_timing_fn = f;
}

pub const ResizeWindowFn = *const fn (width: u32, height: u32) bool;

pub fn setResizeWindowFn(f: ResizeWindowFn) void {
    g_resize_window_fn = f;
}

fn getCtx() ?*Cx {
    if (g_get_ctx_fn) |f| {
        const ctx = f() orelse return null;
        return if (ctx.close_requested) null else ctx;
    }
    return null;
}

// -- Per-frame tracking --
// Animation progress assertions ('did transition play') can't poll via RPC: inter-RPC gap depends
// on machine load, exceeding animation duration samples nothing (Notification animation e2e
// intermittent fail). track_start records test_id, host each frame after render calls afterFrame
// logging screen rect, track_stop retrieves all samples at once.
const TrackSample = struct { t_ms: f64, x: f32, y: f32, w: f32, h: f32, found: bool };
const max_track_samples = 2048;
var g_track_id: command_queue.TestIdPayload = .{};
var g_tracking = false;
var g_track_t0: i128 = 0;
var g_track_io: ?std.Io = null;
var g_track_samples: [max_track_samples]TrackSample = undefined;
var g_track_count: usize = 0;
/// Window context at track start; mid-test harness rebind to other window (multi-window rebind)
/// invalidates samples (not same node), track_stop errors.
var g_track_ctx: ?*Cx = null;
var g_track_ctx_changed = false;

/// Host calls after each frame render (runtime mainloop wired): if tracking, record one sample.
pub fn afterFrame() void {
    if (!g_tracking) return;
    recordTrackSample();
}

fn recordTrackSample() void {
    if (g_track_count >= max_track_samples) return;
    const io = g_track_io orelse return;
    const t_ms = @as(f64, @floatFromInt(@import("zenit_time").monotonicTimestamp(io) - g_track_t0)) / 1e6;
    var sample: TrackSample = .{ .t_ms = t_ms, .x = 0, .y = 0, .w = 0, .h = 0, .found = false };
    const current = getCtx();
    if (current != g_track_ctx) {
        g_track_ctx_changed = true;
        return;
    }
    if (current) |ctx| if (ctx.root) |root| if (tree_serializer.findByTestId(root, g_track_id.getText())) |node| {
        const r = node.globalRect();
        sample = .{ .t_ms = t_ms, .x = r.x, .y = r.y, .w = r.w, .h = r.h, .found = true };
    };
    g_track_samples[g_track_count] = sample;
    g_track_count += 1;
}

fn publishTrackSamples(queue: *CommandQueue) void {
    var buf: [max_track_samples * 96 + 64]u8 = undefined;
    if (g_track_ctx_changed) {
        queue.result.setError("tracking window changed while tracking (harness rebound to another window)");
        return;
    }
    var w = std.Io.Writer.fixed(&buf);
    writeTrackSamples(&w, g_track_samples[0..g_track_count], g_track_count >= max_track_samples) catch {
        // Fail loud, never truncate JSON mid-flight.
        queue.result.setError("track samples exceed the result buffer");
        return;
    };
    queue.result.setJson(w.buffered());
}

/// Truncated: sample count hit limit, later frames unrecorded.
fn writeTrackSamples(w: *std.Io.Writer, samples: []const TrackSample, truncated: bool) std.Io.Writer.Error!void {
    try w.print("{{\"truncated\":{},\"samples\":[", .{truncated});
    for (samples, 0..) |s, i| {
        try w.print("{s}{{\"t\":{d:.1},\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.1},\"h\":{d:.1},\"found\":{}}}", .{ if (i == 0) "" else ",", s.t_ms, s.x, s.y, s.w, s.h, s.found });
    }
    try w.writeAll("]}");
}

test "逐帧追踪：样本序列化带 truncated 标记，缓冲写不下时返回错误而不是半截 JSON" {
    const samples = [_]TrackSample{
        .{ .t_ms = 0, .x = 1, .y = 2, .w = 3, .h = 4, .found = true },
        .{ .t_ms = 16.7, .x = 0, .y = 0, .w = 0, .h = 0, .found = false },
    };
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTrackSamples(&w, &samples, false);
    try std.testing.expectEqualStrings(
        "{\"truncated\":false,\"samples\":[{\"t\":0.0,\"x\":1.0,\"y\":2.0,\"w\":3.0,\"h\":4.0,\"found\":true},{\"t\":16.7,\"x\":0.0,\"y\":0.0,\"w\":0.0,\"h\":0.0,\"found\":false}]}",
        w.buffered(),
    );
    var small: [40]u8 = undefined;
    var ws = std.Io.Writer.fixed(&small);
    try std.testing.expectError(error.WriteFailed, writeTrackSamples(&ws, &samples, true));
}

fn publishRecordingState(queue: *CommandQueue, state: RecordingState) void {
    var buf: [2048]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.key("ok");
    jw.booleanValue(state.ok);
    jw.key("active");
    jw.booleanValue(state.active);
    jw.key("width");
    jw.numberValue(@intCast(state.width));
    jw.key("height");
    jw.numberValue(@intCast(state.height));
    jw.key("fps");
    jw.numberValue(@intCast(state.fps));
    jw.key("duration_ms");
    jw.numberValue(@intCast(@min(state.duration_ms, @as(u64, std.math.maxInt(i64)))));
    jw.key("file_size");
    jw.numberValue(@intCast(@min(state.file_size, @as(u64, std.math.maxInt(i64)))));
    jw.key("frame_count");
    jw.numberValue(@intCast(@min(state.frame_count, @as(u64, std.math.maxInt(i64)))));
    jw.key("dropped_frames");
    jw.numberValue(@intCast(@min(state.dropped_frames, @as(u64, std.math.maxInt(i64)))));
    jw.key("codec");
    jw.stringValue("h264");
    jw.key("container");
    jw.stringValue("mp4");
    if (state.path_len > 0) {
        jw.key("path");
        jw.stringValue(state.pathText());
    }
    if (state.error_len > 0) {
        jw.key("error");
        jw.stringValue(state.errorText());
    }
    jw.endObject();
    if (jw.hasOverflowed()) {
        queue.result.setError("recording result overflow");
    } else {
        queue.result.setJson(jw.getWritten());
    }
}

// -- Main entry --

pub fn drainCommands(queue: *CommandQueue) void {
    _ = drainCommandsRequestFrame(queue);
}

/// Returns a one-shot submission request for the commands consumed in this
/// batch. Polling/query wakes alone must not add another animation drawable.
/// Time until the next scroll stream event is due (0: due now); null when no
/// stream runs. The run loop sleeps until then, as it would until a real
/// wheel event arrived.
pub fn streamNextDelayNs(io: anytype) ?u64 {
    const s = stream orelse return null;
    const now = @import("zenit_time").monotonicTimestamp(io);
    return if (s.next_ns <= now) 0 else @intCast(s.next_ns - now);
}

/// Inject every stream event due by now (a high-rate wheel coalesced per
/// loop iteration, as AppKit delivers it).
fn pumpStream(queue: *CommandQueue) void {
    const s = &(stream orelse return);
    const now = @import("zenit_time").monotonicTimestamp(queue.io);
    const ctx = getCtx() orelse {
        stream = null;
        return;
    };
    while (s.sent < s.spec.count and now >= s.next_ns) {
        const span = @max(s.spec.span, 1);
        const forward = (s.sent / span) % 2 == 0;
        const in_span = s.sent % span;
        const phase: ui.events.ScrollPhase = if (!s.spec.phased) .none else if (in_span == 0) .began else .changed;
        ctx.handleScroll(.{ .x = s.spec.x, .y = s.spec.y, .dx = 0, .dy = if (forward) s.spec.step else -s.spec.step, .phase = phase });
        if (s.spec.phased and (in_span + 1 == span or s.sent + 1 == s.spec.count)) {
            ctx.handleScroll(.{ .x = s.spec.x, .y = s.spec.y, .dx = 0, .dy = 0, .phase = .ended });
        }
        s.sent += 1;
        s.next_ns += @intFromFloat(s.spec.interval_ms * std.time.ns_per_ms);
    }
    if (s.sent >= s.spec.count) stream = null;
}

pub fn drainCommandsRequestFrame(queue: *CommandQueue) bool {
    // Injected wheel events request frames as platform wheel events do: through what they
    // change (Cx.handleScroll), never by themselves.
    pumpStream(queue);
    var request_frame = false;
    while (queue.dequeue()) |cmd| {
        request_frame = commandRequestsFrame(cmd) or request_frame;
        const handled = blk: {
            // Snapshot paired callbacks: teardown may rebind the surviving window.
            const end = command_end;
            if (command_begin) |begin| begin();
            defer if (end) |finish| finish();
            break :blk executeCommand(queue, cmd);
        };
        if (handled) {
            queue.signalDone();
        }
    }
    return request_frame;
}

fn commandRequestsFrame(cmd: TestCommand) bool {
    return switch (cmd) {
        .window => |command| command != .status and command != .close and command != .minimize,
        // These commands observe state; reset_timing changes measurements only.
        .health,
        .windows,
        .query_tree,
        .query_selector,
        .get_focused,
        .screen_pos,
        .recording_status,
        .input_state,
        .frame_stats,
        .reset_timing,
        .console_query,
        .quit_app,
        => false,
        // A wheel event requests a frame through what it changes (Cx.handleScroll), as a
        // platform wheel event does: a wheel against a pinned end renders nothing.
        .scroll => false,
        // Input, resize, screenshots and recording/control mutations request
        // one immediate frame. Custom routes have no readonly declaration, so
        // they conservatively follow the same contract, even with an empty body.
        else => true,
    };
}

/// Host custom route handler: return JSON slice written to `out`, null = unrecognized route.
/// **Called from main thread** (drainCommands inside), safe to read/write host UI state.
pub const AppRouteFn = *const fn (path: []const u8, body: []const u8, out: []u8) ?[]const u8;
var g_app_route_fn: ?AppRouteFn = null;

/// Runtime-owned routes (e.g. the Windows /perf/ switches), tried before the
/// application's handler so neither replaces the other.
var g_runtime_route_fn: ?AppRouteFn = null;
pub fn setRuntimeRouteFn(f: ?AppRouteFn) void {
    g_runtime_route_fn = f;
}
pub fn setAppRouteFn(f: AppRouteFn) void {
    g_app_route_fn = f;
}

fn setScreenshotError(queue: *CommandQueue, code: []const u8) void {
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\",\"code\":\"{s}\"}}", .{ code, code }) catch unreachable;
    queue.result.setJson(json);
    queue.result.success = false;
}

fn executeCommand(queue: *CommandQueue, cmd_in: TestCommand) bool {
    var cmd = cmd_in;
    defer {
        switch (cmd) {
            .text_input => |*p| p.deinit(queue.allocator),
            .ime_preedit => |*p| p.deinit(queue.allocator),
            .ime_commit => |*p| p.deinit(queue.allocator),
            .query_selector => |*p| p.deinit(queue.allocator),
            .drag => |*p| p.deinit(queue.allocator),
            else => {},
        }
    }

    switch (cmd) {
        .health => {
            queue.result.setJson("{\"status\":\"ok\"}");
            return true;
        },
        .click => |c| {
            if (getCtx()) |ctx| {
                // handleMouseUp already synthesizes click event (includes click_count) via
                // dispatcher. Don't call handleClick again—fires mouse_down/up -> extra click ->
                // consecutive_clicks=2 -> textarea/input misidentifies double-click ->
                // selectWordAt. Both down/up must carry modifiers: host judges 'add to selection vs
                // exclusive' usually on up, only down carrying means shift-multiselect e2e silently
                // breaks.
                for (0..c.count) |_| {
                    if (ctx.close_requested) break;
                    ctx.handleMouseDown(c.x, c.y, c.modifiers());
                    if (ctx.close_requested) break;
                    ctx.updateAutomationCursor(c.x, c.y, true);
                    ctx.handleMouseUpEx(c.x, c.y, .left, c.modifiers());
                    ctx.updateAutomationCursor(c.x, c.y, false);
                }
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .click_test_id => |payload| {
            const test_id = payload.getText();
            if (getCtx()) |ctx| {
                if (ctx.root) |root| {
                    if (tree_serializer.findByTestId(root, test_id)) |node| {
                        const handle = ctx.node_registry.handleFor(node);
                        scrollNodeIntoView(ctx, node, false);
                        const visible = ctx.node_registry.resolve(handle, &ctx.perf) orelse {
                            queue.result.setError("click target removed during scroll");
                            return true;
                        };
                        var r = visible.globalRect();
                        var x = r.x + r.w * 0.5;
                        var y = r.y + r.h * 0.5;
                        if (!clickTargetMatches(ctx, handle, x, y)) {
                            const current = ctx.node_registry.resolve(handle, &ctx.perf) orelse {
                                queue.result.setError("click target removed during scene refresh");
                                return true;
                            };
                            // A viewport-visible control may still be covered by
                            // a portal. Scroll it toward the top, then hit-test
                            // again before dispatching a real pointer click.
                            scrollNodeIntoView(ctx, current, true);
                            const refreshed = ctx.node_registry.resolve(handle, &ctx.perf) orelse {
                                queue.result.setError("click target removed during scroll");
                                return true;
                            };
                            r = refreshed.globalRect();
                            x = r.x + r.w * 0.5;
                            y = r.y + r.h * 0.5;
                            if (!clickTargetMatches(ctx, handle, x, y)) {
                                queue.result.setError("click target is occluded or not hit-testable");
                                return true;
                            }
                        }
                        if (!ctx.close_requested) ctx.handleMouseDown(x, y, .{});
                        if (!ctx.close_requested) {
                            ctx.updateAutomationCursor(x, y, true);
                            ctx.handleMouseUp(x, y);
                            ctx.updateAutomationCursor(x, y, false);
                        }
                        var buf: [256]u8 = undefined;
                        const out = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"clicked_x\":{d:.1},\"clicked_y\":{d:.1}}}", .{ x, y }) catch "{\"ok\":true}";
                        queue.result.setJson(out);
                    } else {
                        queue.result.setError("test_id not found");
                    }
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .app_route => |c| {
            if (g_runtime_route_fn) |runtime| {
                var runtime_buf: [command_queue.AppRoutePayload.BODY_CAP * 2]u8 = undefined;
                if (runtime(c.getPath(), c.getBody(), &runtime_buf)) |written| {
                    queue.result.setJson(written);
                    return true;
                }
            }
            const handler = g_app_route_fn orelse {
                queue.result.setError("no app route handler");
                return true;
            };
            var buf: [command_queue.AppRoutePayload.BODY_CAP * 2]u8 = undefined;
            if (handler(c.getPath(), c.getBody(), &buf)) |written| {
                queue.result.setJson(written);
            } else {
                queue.result.setError("app route rejected");
            }
            return true;
        },
        .mouse_down => |c| {
            if (getCtx()) |ctx| {
                ctx.handleMouseDown(c.x, c.y, c.modifiers());
                ctx.updateAutomationCursor(c.x, c.y, true);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .mouse_move => |c| {
            if (getCtx()) |ctx| {
                ctx.handleMouseMoveEx(c.x, c.y, c.modifiers());
                ctx.updateAutomationCursor(c.x, c.y, null);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .pointer_leave => {
            if (getCtx()) |ctx| {
                ctx.handlePointerLeave();
                queue.result.setJson("{\"ok\":true}");
            } else queue.result.setError("no context");
            return true;
        },
        .window_active => |active| {
            if (getCtx()) |ctx| {
                if (ctx.window_active != active) {
                    ctx.window_active = active;
                    // Same follow-up as the runtimes: inactive glass material re-resolves.
                    if (ctx.root) |root| root.markSubtreeBeforeRenderHook();
                }
                ctx.needs_redraw = true;
                queue.result.setJson("{\"ok\":true}");
            } else queue.result.setError("no context");
            return true;
        },
        .mouse_up => |c| {
            if (getCtx()) |ctx| {
                // Must use Ex with modifiers: handleMouseUp hardcodes `.{}`, e2e can never cover
                // 'modifiers on up' path (mouse_up modifiers=false bug hidden this way).
                ctx.handleMouseUpEx(c.x, c.y, .left, c.modifiers());
                ctx.updateAutomationCursor(c.x, c.y, false);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .key_down, .key_up => |payload| {
            if (getCtx()) |ctx| {
                const name = payload.getKeyName();
                const key_code = parseKeyName(name);
                const mods = Modifiers{
                    .shift = payload.shift,
                    .ctrl = payload.ctrl,
                    .alt = payload.alt,
                    .super = payload.super,
                };
                if (cmd == .key_up) ctx.handleKeyUp(key_code, mods) else ctx.handleKeyDown(key_code, mods);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .scroll_stream => |c| {
            if (getCtx() != null and c.count > 0 and c.interval_ms >= 1) {
                stream = .{ .spec = c, .next_ns = @import("zenit_time").monotonicTimestamp(queue.io) };
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("invalid scroll stream");
            }
            return true;
        },
        .scroll => |c| {
            if (getCtx()) |ctx| {
                ctx.handleScroll(.{
                    .x = c.x,
                    .y = c.y,
                    .dx = c.dx,
                    .dy = c.dy,
                    .phase = @fromBackingInt(@intCast(c.phase)),
                    .momentum = @fromBackingInt(@intCast(c.momentum)),
                    .modifiers = .{ .shift = c.shift, .ctrl = c.ctrl, .alt = c.alt, .super = c.super },
                });
                ctx.updateAutomationCursor(c.x, c.y, null);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .magnify => |c| {
            if (getCtx()) |ctx| {
                ctx.handleMagnify(c.magnification, c.x, c.y, @fromBackingInt(@intCast(c.phase)));
                ctx.updateAutomationCursor(c.x, c.y, null);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .drag => |payload| {
            if (getCtx()) |ctx| {
                ctx.handleDrag(payload.x, payload.y, payload.kind, payload.paths.getText());
                ctx.updateAutomationCursor(payload.x, payload.y, null);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .text_input => |payload| {
            if (getCtx()) |ctx| {
                ctx.handleTextInput(payload.getText());
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .ime_preedit => |payload| {
            if (getCtx()) |ctx| {
                if (ctx.focus_manager.current_focus == null) {
                    queue.result.setError("no focused element - click first");
                    return true;
                }
                ctx.handleImePreedit(payload.text.getText(), payload.cursor_utf8_offset);
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .ime_commit => |payload| {
            if (getCtx()) |ctx| {
                if (ctx.focus_manager.current_focus == null) {
                    queue.result.setError("no focused element - click first");
                    return true;
                }
                ctx.handleImeCommit(payload.getText());
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .query_tree => {
            if (getCtx()) |ctx| {
                // Force frame flush: preceding mutating commands (imeCommit / text_input /
                // key_down) complete before_render hook + layout, rect/world up-to-date.
                _ = ctx.render();
                if (ctx.root) |root| {
                    // Write direct to result buffer (no 128KB stack intermediate then truncate);
                    // fail explicit if doesn't fit, never return partial JSON.
                    const json = tree_serializer.serializeTree(root, &ctx.overlay_stack, &queue.result.buf) catch {
                        queue.result.setError("tree too large for RESULT_BUF_SIZE");
                        return true;
                    };
                    queue.result.len = json.len;
                    queue.result.success = true;
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .query_selector => |payload| {
            if (getCtx()) |ctx| {
                _ = ctx.render();
                if (ctx.root) |root| {
                    const json = tree_serializer.queryByTestId(root, &ctx.overlay_stack, payload.getText(), &queue.result.buf) catch {
                        queue.result.setError("query result too large for RESULT_BUF_SIZE");
                        return true;
                    };
                    queue.result.len = json.len;
                    queue.result.success = true;
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .frame_stats => {
            if (g_get_frame_stats_fn) |f| {
                const st = f();
                // 16 numeric fields, 512B insufficient (JsonWriter silent truncate produces invalid
                // JSON, client sees parse error not clear failure).
                var buf: [8192]u8 = undefined;
                var jw = JsonWriter.init(&buf);
                jw.beginObject();
                jw.key("retained_hits");
                jw.numberValue(@intCast(st.retained_hits));
                jw.key("retained_misses");
                jw.numberValue(@intCast(st.retained_misses));
                jw.key("retained_partial_repaints");
                jw.numberValue(@intCast(st.retained_partial_repaints));
                jw.key("offscreen_pool_exhausted");
                jw.numberValue(@intCast(st.offscreen_pool_exhausted));
                jw.key("text_uniform_overflow");
                jw.numberValue(@intCast(st.text_uniform_overflow));
                jw.key("path_draw_calls");
                jw.numberValue(@intCast(st.path_draw_calls));
                jw.key("frame_count");
                jw.numberValue(@intCast(st.frame_count));
                jw.key("caret_flipping");
                jw.booleanValue(st.caret_flipping);
                jw.key("caret_visible");
                jw.booleanValue(st.caret_visible);
                inline for (.{ "graphics_footprint_bytes", "caret_rect_count", "caret_entries", "caret_flips", "caret_last_flip_ms", "caret_attempts", "caret_gate_blocked", "caret_admission_failures", "caret_admission_next_ns", "stale_drawable_discards" }) |field| {
                    jw.key(field);
                    jw.numberValue(@intCast(@field(st, field)));
                }
                jw.key("caret_rejections");
                jw.beginObject();
                inline for (@import("zenit_reflection").fields(CaretRejections)) |field| {
                    jw.key(field.name);
                    jw.numberValue(@intCast(@field(st.caret_rejections, field.name)));
                }
                jw.endObject();
                jw.key("clock_budget_ms");
                if (getCtx()) |ctx| (if (ctx.test_clock_budget_ms) |b| jw.floatValue(@floatCast(b)) else jw.nullValue()) else jw.nullValue();
                jw.key("frame_time_ms");
                if (getCtx()) |ctx| jw.floatValue(@floatCast(ctx.frame_time_ms)) else jw.nullValue();
                jw.key("renderer_backend");
                if (st.renderer_backend) |backend| jw.stringValue(backend) else jw.nullValue();
                jw.key("gpu_validation_errors");
                if (st.gpu_validation_errors) |count| jw.numberValue(count) else jw.nullValue();
                jw.key("gpu_software");
                if (st.gpu_software) |software| jw.booleanValue(software) else jw.nullValue();
                inline for (.{ "window_logical_width", "window_logical_height", "window_pixel_width", "window_pixel_height" }) |field| {
                    jw.key(field);
                    if (@field(st, field)) |value| jw.numberValue(value) else jw.nullValue();
                }
                jw.key("clipboard_write_ready");
                if (st.clipboard_write_ready) |ready| jw.booleanValue(ready) else jw.nullValue();
                jw.key("window_scale");
                if (getCtx()) |ctx| jw.floatValue(ctx.window_scale) else jw.nullValue();
                // new-glass first-frame family probes (Cx.glass_probe_stats, cumulative)
                jw.key("glass_probe");
                if (getCtx()) |ctx| {
                    const ps = ctx.glass_probe_stats;
                    jw.beginObject();
                    jw.key("resolved");
                    jw.numberValue(@intCast(ps.resolved));
                    jw.key("timed_out");
                    jw.numberValue(@intCast(ps.timed_out));
                    jw.key("max_frames");
                    jw.numberValue(@intCast(ps.max_frames));
                    jw.endObject();
                } else jw.nullValue();
                // Hover state: nearest test_id on the hovered path and stationary-pointer
                // re-resolution counters (core/cx_hover.zig).
                jw.key("hover");
                if (getCtx()) |ctx| {
                    jw.beginObject();
                    jw.key("test_id");
                    var hovered_test_id: ?[]const u8 = null;
                    var cur = ctx.hovered_node;
                    while (cur) |n| : (cur = n.parent) {
                        if (n.meta.ownership.meta.test_id) |tid| {
                            hovered_test_id = tid;
                            break;
                        }
                    }
                    if (hovered_test_id) |tid| jw.stringValue(tid) else jw.nullValue();
                    jw.key("reconcile_hit_tests");
                    jw.numberValue(@intCast(ctx.hover_sync.reconcile_hit_tests));
                    jw.key("reconcile_changes");
                    jw.numberValue(@intCast(ctx.hover_sync.reconcile_changes));
                    // Platform presence (cleared by pointer_left) and the resulting liveness.
                    jw.key("pointer_over_content");
                    jw.booleanValue(ctx.hover_sync.pointer_over_content);
                    jw.key("pointer_live");
                    jw.booleanValue(ctx.pointerLive());
                    jw.endObject();
                } else jw.nullValue();
                jw.key("backdrop_luminance_milli");
                jw.numberValue(@intFromFloat(st.backdrop_luminance * 1000));
                jw.key("paint_duplicate_fills");
                jw.numberValue(@intCast(st.paint_duplicate_fills));
                jw.key("paint_duplicate_node");
                jw.numberValue(@intCast(st.paint_duplicate_node));
                jw.key("incremental_verify_mismatches");
                jw.numberValue(@intCast(st.incremental_verify_mismatches));
                jw.key("gpu_execute_us");
                jw.numberValue(@intCast(st.gpu_execute_us));
                jw.key("cpu_frame_us");
                jw.numberValue(@intCast(st.cpu_frame_us));
                jw.key("layout_us");
                jw.numberValue(@intCast(st.layout_us));
                jw.key("render_gen_us");
                jw.numberValue(@intCast(st.render_gen_us));
                jw.key("gpu_encode_us");
                jw.numberValue(@intCast(st.gpu_encode_us));
                inline for (.{ "wait_for_frame_us", "acquire_texture_us", "encode_us", "flush_us" }) |field| {
                    jw.key(field);
                    if (@field(st, field)) |value| jw.numberValue(@intCast(value)) else jw.nullValue();
                }
                inline for (.{ "glass_count", "glass_us", "texture_creates", "render_passes", "blit_passes", "compute_passes", "pass_native_us" }) |field| {
                    jw.key(field);
                    jw.numberValue(@intCast(@field(st, field)));
                }
                jw.key("total_frame_us");
                jw.numberValue(@intCast(st.total_frame_us));
                if (st.stage_totals) |totals| {
                    jw.key("stage_totals");
                    jw.beginObject();
                    inline for (@typeInfo(StageTotals).@"struct".field_names) |name| {
                        jw.key(name);
                        jw.numberValue(@intCast(@field(totals, name)));
                    }
                    jw.endObject();
                }
                jw.key("gpu_p95_us");
                jw.numberValue(@intCast(st.gpu_p95_us));
                jw.key("cpu_p95_us");
                jw.numberValue(@intCast(st.cpu_p95_us));
                jw.key("total_p95_us");
                jw.numberValue(@intCast(st.total_p95_us));
                jw.key("timing_samples");
                jw.numberValue(@intCast(st.timing_samples));
                jw.key("cpu_timing_samples");
                jw.numberValue(@intCast(@max(st.cpu_timing_samples, st.timing_samples)));
                jw.key("gpu_timing_disjoint_samples");
                jw.numberValue(@intCast(st.gpu_timing_disjoint_samples));
                jw.key("gpu_timing_failed_samples");
                jw.numberValue(@intCast(st.gpu_timing_failed_samples));
                jw.key("gpu_timing_pending_queries");
                jw.numberValue(@intCast(st.gpu_timing_pending_queries));
                jw.key("gpu_timing_query_supported");
                if (st.gpu_timing_query_supported) |supported| jw.booleanValue(supported) else jw.nullValue();
                jw.endObject();
                if (jw.hasOverflowed()) queue.result.setError("frame_stats JSON exceeds its buffer") else queue.result.setJson(jw.getWritten());
            } else {
                queue.result.setError("frame_stats not supported");
            }
            return true;
        },
        .sprites => |command| {
            const ctx = getCtx() orelse {
                queue.result.setError("no context");
                return true;
            };
            switch (command) {
                .query => {},
                .debug => ctx.sprites.setDebug(true),
                .enable, .disable => {
                    ctx.sprites.enabled = command == .enable;
                    ctx.needs_redraw = true;
                    if (ctx.root) |root| root.markRenderDirty();
                },
            }
            var active: u32 = 0;
            for (ctx.sprites.sources.items) |source| {
                if (source.active) active += 1;
            }
            var buf: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.print("{{\"enabled\":{},\"sources\":{d},\"active\":{d},\"placements\":{d},\"frame_time_ms\":{d},\"atlas_bytes\":{d},\"building\":{d},\"host_error\":\"{s}\",\"rects\":[", .{
                ctx.sprites.enabled, ctx.sprites.sources.items.len, active, ctx.sprites.placements.items.len, ctx.frame_time_ms, ctx.sprites.host_atlas_bytes, ctx.sprites.host_building, ctx.sprites.host_error,
            }) catch {};
            var first = true;
            for (ctx.sprites.placements.items) |p| {
                if (p.exiting) continue;
                w.print("{s}[{d},{d},{d},{d}]", .{ if (first) "" else ",", p.origin_px[0], p.origin_px[1], p.cell_px[0], p.cell_px[1] }) catch {};
                first = false;
            }
            w.writeAll("],\"reasons\":[") catch {};
            for (ctx.sprites.sources.items, 0..) |source, i| {
                w.print("{s}\"{s}\"", .{ if (i == 0) "" else ",", if (source.active) "active" else source.last_reject }) catch {};
            }
            w.writeAll("]}") catch {
                queue.result.setError("sprites status overflow");
                return true;
            };
            queue.result.setJson(w.buffered());
            return true;
        },
        .cpu_patches => |command| {
            const control = g_cpu_patch_fn orelse {
                queue.result.setError("cpu patches not supported");
                return true;
            };
            var out: CpuPatchStatus = .{};
            const mode: u8 = switch (command) {
                .query, .debug => 0,
                .enable => 1,
                .disable => 2,
            };
            if (!control(mode, &out)) {
                queue.result.setError("cpu patches not supported");
                return true;
            }
            if (command != .query) if (getCtx()) |ctx| {
                ctx.needs_redraw = true;
                if (ctx.root) |root| root.markRenderDirty();
            };
            var buf: [2048]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.print("{{\"enabled\":{},\"cpu_frames\":{d},\"gpu_frames\":{d},\"shown\":{d},\"unchanged_frames\":{d},\"rects\":[", .{ out.enabled, out.cpu_frames, out.gpu_frames, out.shown, out.unchanged_frames }) catch unreachable;
            for (out.rects[0..out.rect_count], 0..) |r, i| w.print("{s}[{d},{d},{d},{d}]", .{ if (i == 0) "" else ",", r[0], r[1], r[2], r[3] }) catch unreachable;
            w.writeAll("]}") catch unreachable;
            queue.result.setJson(w.buffered());
            return true;
        },
        .composited_screenshot => |payload| {
            const capture = g_composited_capture_fn orelse {
                queue.result.setError("composited screenshots not supported");
                return true;
            };
            var path: [@import("command_queue.zig").RecordingStartPayload.PATH_CAP + 1]u8 = undefined;
            @memcpy(path[0..payload.path_len], payload.getPath());
            path[payload.path_len] = 0;
            const status = capture(@ptrCast(&path));
            queue.result.setJson(if (status == 1) "{\"ok\":true}" else "{\"ok\":false}");
            return true;
        },
        .force_frames => |on| {
            const ctx = getCtx() orelse {
                queue.result.setError("no context");
                return true;
            };
            ctx.test_force_frames = on;
            ctx.needs_redraw = true;
            queue.result.setJson("{\"ok\":true}");
            return true;
        },
        .animation_clock => |step| {
            const ctx = getCtx() orelse {
                queue.result.setError("no context");
                return true;
            };
            ctx.setTestFrameStep(if (step == 0) null else step) catch {
                queue.result.setError("invalid step_ms");
                return true;
            };
            ctx.test_clock_budget_ms = null;
            queue.result.setJson("{\"ok\":true}");
            return true;
        },
        .animation_clock_locked => |step| {
            const ctx = getCtx() orelse {
                queue.result.setError("no context");
                return true;
            };
            ctx.setTestFrameStep(step) catch {
                queue.result.setError("invalid step_ms");
                return true;
            };
            ctx.test_clock_budget_ms = 0;
            queue.result.setJson("{\"ok\":true}");
            return true;
        },
        .clock_advance => |ms| {
            const ctx = getCtx() orelse {
                queue.result.setError("no context");
                return true;
            };
            const budget = ctx.test_clock_budget_ms orelse {
                queue.result.setError("clock is not locked");
                return true;
            };
            ctx.test_clock_budget_ms = budget + ms;
            ctx.needs_redraw = true;
            queue.result.setJson("{\"ok\":true}");
            return true;
        },
        .finish_frame_capture => {
            if (!g_frame_capture_finished) std.log.info("[test_harness] frame capture finished", .{});
            g_frame_capture_finished = true;
            queue.result.setJson("{\"ok\":true,\"finished\":true}");
            return true;
        },
        .frames_start => |payload| {
            // Per-frame observation backend-independent (read layout/opacity after each submit);
            // Timed capture must read the already-submitted surface. Windows
            // paint and Linux retained GPU readback both satisfy this contract.
            const os = @import("builtin").os.tag;
            if (payload.capture_path != null and os != .windows and os != .linux) {
                queue.result.setJson("{\"supported\":false}");
                return true;
            }
            const ctx = getCtx() orelse {
                queue.result.setError("no context");
                return true;
            };
            const root = ctx.root orelse {
                queue.result.setError("no root");
                return true;
            };
            // A target the click creates (a page it navigates to) may appear later; frames
            // before it exists count as missing.
            if (payload.click_target == null and tree_serializer.findByTestId(root, payload.target.getText()) == null) {
                queue.result.setError("test_id not found");
                return true;
            }
            if (payload.capture_path != null and g_capture_screenshot_fn == null) {
                queue.result.setError("screenshot not supported");
                return true;
            }
            frame_capture_path = payload.capture_path;
            frame_capture_after_ms = payload.capture_after_ms;
            frame_capture_started_ms = ctx.eventTimeMs();
            frame_capture_index = null;
            frame_capture_failed = false;
            frame_context = @intFromPtr(ctx);
            frame_target = payload.target;
            frame_escape_on_enter = payload.escape_on_enter;
            frame_action_index = null;
            frame_count = 0;
            frame_missing = 0;
            frame_overflow = false;
            frame_started = @import("zenit_time").monotonicTimestamp(ctx.io);
            if (payload.click_target) |click_target| {
                // Observe before dispatching the action on this same UI-thread
                // turn. Reuse hit testing/scrolling and never send native input.
                _ = executeCommand(queue, .{ .click_test_id = click_target });
                if (!queue.result.success) {
                    frame_target = null;
                    frame_capture_path = null;
                    frame_escape_on_enter = false;
                    return true;
                }
            }
            queue.result.setJson("{\"supported\":true}");
            return true;
        },
        .frames_capture_read => {
            if (frame_capture_failed) {
                frame_target = null;
                queue.result.setError("timed frame capture failed");
            } else if (frame_capture_index) |index| {
                frame_target = null;
                const sample = frame_samples[index];
                var buf: [512]u8 = undefined;
                var jw = JsonWriter.init(&buf);
                jw.beginObject();
                jw.key("ok");
                jw.booleanValue(true);
                jw.key("sample_ms");
                jw.floatValue(@floatCast(sample.ms));
                jw.key("requested_ms");
                jw.floatValue(@floatCast(frame_capture_after_ms));
                jw.key("frame_index");
                jw.numberValue(@intCast(index));
                jw.key("x");
                jw.floatValue(sample.x);
                jw.key("effective_opacity");
                jw.floatValue(sample.effective_opacity);
                jw.endObject();
                queue.result.setJson(jw.getWritten());
            } else queue.result.setJson("{\"ready\":false}");
            return true;
        },
        .frames_read => {
            frame_target = null;
            frame_capture_path = null;
            frame_escape_on_enter = false;
            var buf: [32768]u8 = undefined;
            var jw = JsonWriter.init(&buf);
            jw.beginObject();
            jw.key("action_frame_index");
            if (frame_action_index) |index| jw.numberValue(@intCast(index)) else jw.nullValue();
            jw.key("overflow");
            jw.booleanValue(frame_overflow);
            jw.key("missing");
            jw.numberValue(@intCast(frame_missing));
            jw.key("frames");
            jw.beginArray();
            for (frame_samples[0..frame_count]) |sample| {
                jw.beginObject();
                jw.key("ms");
                jw.floatValue(@floatCast(sample.ms));
                jw.key("x");
                jw.floatValue(sample.x);
                jw.key("y");
                jw.floatValue(sample.y);
                jw.key("w");
                jw.floatValue(sample.w);
                jw.key("h");
                jw.floatValue(sample.h);
                jw.key("opacity");
                jw.floatValue(sample.opacity);
                jw.key("effective_opacity");
                jw.floatValue(sample.effective_opacity);
                jw.endObject();
            }
            jw.endArray();
            jw.endObject();
            if (jw.hasOverflowed()) queue.result.setError("frame observation JSON overflow") else queue.result.setJson(jw.getWritten());
            return true;
        },
        .reset_timing => {
            if (g_reset_timing_fn) |f| {
                f();
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("reset_timing not supported");
            }
            return true;
        },
        .console_query => |query| {
            const ctx = getCtx() orelse {
                queue.result.setError("no context");
                return true;
            };
            const limit: usize = @min(@as(usize, query.limit), 200);
            var snapshot = ctx.console().snapshotSince(queue.allocator, query.after_seq, limit) catch {
                queue.result.setError("console snapshot failed");
                return true;
            };
            defer snapshot.deinit(queue.allocator);

            var jw = JsonWriter.init(&queue.result.buf);
            jw.beginObject();
            jw.key("events");
            jw.beginArray();
            for (snapshot.events) |event| {
                jw.beginObject();
                jw.key("seq");
                jw.numberValue(@intCast(event.seq));
                jw.key("monotonic_us");
                jw.numberValue(@intCast(event.monotonic_us));
                jw.key("thread_id");
                jw.numberValue(@intCast(event.thread_id));
                jw.key("level");
                jw.stringValue(event.level.label());
                jw.key("kind");
                jw.stringValue(@tagName(event.kind));
                jw.key("scope");
                jw.stringValue(event.scope);
                jw.key("group_depth");
                jw.numberValue(event.group_depth);
                jw.key("message");
                jw.stringValue(event.message);
                jw.key("truncated");
                jw.booleanValue(event.truncated);
                if (event.source) |source| {
                    jw.key("source");
                    jw.beginObject();
                    jw.key("file");
                    jw.stringValue(source.file);
                    jw.key("fn_name");
                    jw.stringValue(source.fn_name);
                    jw.key("line");
                    jw.numberValue(source.line);
                    jw.key("column");
                    jw.numberValue(source.column);
                    jw.endObject();
                }
                jw.endObject();
            }
            jw.endArray();
            jw.key("next_cursor");
            jw.numberValue(@intCast(snapshot.next_cursor));
            jw.key("oldest_seq");
            jw.numberValue(@intCast(snapshot.oldest_seq));
            jw.key("newest_seq");
            jw.numberValue(@intCast(snapshot.newest_seq));
            jw.key("gap");
            jw.booleanValue(snapshot.gap);
            jw.key("has_more");
            jw.booleanValue(snapshot.has_more);
            jw.key("evicted_total");
            jw.numberValue(@intCast(snapshot.evicted_total));
            jw.key("dropped_oom");
            jw.numberValue(@intCast(snapshot.dropped_oom));
            jw.key("dropped_oversize");
            jw.numberValue(@intCast(snapshot.dropped_oversize));
            jw.key("clear_generation");
            jw.numberValue(@intCast(snapshot.clear_generation));
            jw.endObject();
            if (jw.hasOverflowed()) {
                queue.result.setError("console response too large; use a smaller limit");
            } else {
                queue.result.len = jw.getWritten().len;
                queue.result.success = true;
            }
            return true;
        },
        .console_clear => {
            if (getCtx()) |ctx| {
                ctx.console().clear();
                queue.result.setJson("{\"ok\":true}");
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .get_focused => {
            if (getCtx()) |ctx| {
                if (ctx.focus_manager.current_focus) |focused| {
                    var buf: [4096]u8 = undefined;
                    var jw = JsonWriter.init(&buf);
                    jw.beginObject();
                    jw.key("id");
                    jw.numberValue(@intCast(focused.id));
                    jw.key("tag");
                    jw.stringValue(@tagName(focused.tag));
                    if (focused.meta.ownership.meta.test_id) |tid| {
                        jw.key("test_id");
                        jw.stringValue(tid);
                    }
                    if (focused.meta.ownership.meta.component_name) |cn| {
                        jw.key("component");
                        jw.stringValue(cn);
                    }
                    if (focused.getText()) |t| {
                        jw.key("text");
                        const tlen = @min(t.content.len, 200);
                        jw.stringValue(t.content[0..tlen]);
                    }
                    jw.endObject();
                    queue.result.setJson(jw.getWritten());
                } else {
                    queue.result.setJson("{\"focused\":null}");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .screen_pos => |payload| {
            if (getCtx()) |ctx| {
                _ = ctx.render();
                if (ctx.root) |root| {
                    if (tree_serializer.findByTestId(root, payload.getText())) |node| {
                        scrollNodeIntoView(ctx, node, false);
                        const r = node.globalRect();
                        var buf: [256]u8 = undefined;
                        const out = std.fmt.bufPrint(&buf, "{{\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.1},\"h\":{d:.1}}}", .{ r.x, r.y, r.w, r.h }) catch "{}";
                        queue.result.setJson(out);
                    } else {
                        queue.result.setError("test_id not found");
                    }
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .track_start => |payload| {
            g_track_id = payload;
            g_tracking = true;
            g_track_count = 0;
            g_track_ctx = getCtx();
            g_track_ctx_changed = false;
            g_track_io = queue.io;
            g_track_t0 = @import("zenit_time").monotonicTimestamp(queue.io);
            recordTrackSample(); // Track start position.
            queue.result.setJson("{\"ok\":true}");
            return true;
        },
        .track_stop => {
            g_tracking = false;
            publishTrackSamples(queue);
            return true;
        },
        .input_state => |payload| {
            // Query input/textarea internal state (event_context is *TextInputState).
            if (getCtx()) |ctx| {
                _ = ctx.render();
                if (ctx.root) |root| {
                    if (tree_serializer.findByTestId(root, payload.getText())) |node| {
                        // Find input_container with inputEventHandler in wrapper subtree.
                        const ic = findInputContainer(node) orelse {
                            queue.result.setError("no input_container under test_id");
                            return true;
                        };
                        // textarea / single-line are different state structs: the input module
                        // tells them apart (editStateOf), never a blind cast here.
                        const edit = ui.widgets.input.editStateOf(ic) orelse {
                            queue.result.setError("unknown on_event handler — not input or textarea");
                            return true;
                        };
                        var buf: [4096]u8 = undefined;
                        var jw = JsonWriter.init(&buf);
                        if (edit == .input) {
                            const state = edit.input;
                            // EditableText deliberately reuses inputEventHandler for both
                            // storage modes.  Its multiline variant keeps the canonical
                            // bytes in TextareaDocument, so reading buffer/buffer_len here
                            // reports an empty string while the live editor contains text.
                            // Always go through getText(), and expose the document/wrap
                            // counts needed by full-app newline regressions.
                            const state_text = state.getText();
                            jw.beginObject();
                            jw.key("buffer_len");
                            jw.numberValue(@intCast(state_text.len));
                            jw.key("buffer");
                            jw.stringValue(state_text);
                            jw.key("cursor_pos");
                            jw.numberValue(@intCast(state.cursor_pos));
                            jw.key("anchor");
                            if (state.selection_anchor) |anchor| {
                                jw.numberValue(@intCast(anchor));
                            } else {
                                jw.numberValue(-1);
                            }
                            jw.key("cursor_affinity");
                            jw.stringValue(@tagName(state.cursor_affinity));
                            jw.key("ime_preedit_len");
                            jw.numberValue(@intCast(state.ime_preedit_len));
                            jw.key("ime_phase");
                            jw.stringValue(@tagName(state.ime_phase));
                            jw.key("input_type");
                            jw.stringValue(if (state.multiline) "editable_textarea" else @tagName(state.input_type));
                            jw.key("document_line_count");
                            jw.numberValue(@intCast(if (state.textarea_doc) |doc| doc.lineCount() else 1));
                            jw.key("display_line_count");
                            jw.numberValue(@intCast(if (state.textarea_wrap) |wrap| wrap.displayLineCount() else 1));
                            jw.key("layout_line_count");
                            jw.numberValue(@intCast(blk: {
                                const text_node = state.text_display_node orelse break :blk 0;
                                const layout = text_node.getLayoutOutput().artifacts.text_layout orelse break :blk 0;
                                break :blk layout.line_count;
                            }));
                            jw.key("editor_height");
                            jw.floatValue(ic.rectFromWorldOrFallback().h);
                            jw.key("cursor_rect");
                            if (state.cursor_node) |cursor_node| {
                                const rect = cursor_node.globalRect();
                                jw.beginObject();
                                jw.key("x");
                                jw.floatValue(rect.x);
                                jw.key("y");
                                jw.floatValue(rect.y);
                                jw.key("w");
                                jw.floatValue(rect.w);
                                jw.key("h");
                                jw.floatValue(rect.h);
                                jw.endObject();
                            } else {
                                jw.nullValue();
                            }
                            jw.key("scroll_x");
                            jw.floatValue(state.scroll_x);
                            jw.endObject();
                        } else {
                            const state = edit.textarea;
                            const text = state.getText();
                            jw.beginObject();
                            jw.key("buffer_len");
                            jw.numberValue(@intCast(text.len));
                            jw.key("buffer");
                            jw.stringValue(text);
                            jw.key("cursor_pos");
                            jw.numberValue(@intCast(state.cursor.offset));
                            jw.key("anchor");
                            if (state.cursor.anchor) |a| {
                                jw.numberValue(@intCast(a));
                            } else {
                                jw.numberValue(-1);
                            }
                            jw.key("cursor_affinity");
                            jw.stringValue(@tagName(state.cursor_affinity));
                            jw.key("display_line_count");
                            jw.numberValue(@intCast(state.wrap_map.displayLineCount()));
                            jw.key("line_height");
                            jw.floatValue(state.line_height);
                            jw.key("padding_h");
                            jw.floatValue(state.padding_h);
                            jw.key("padding_v");
                            jw.floatValue(state.padding_v);
                            jw.key("cursor_rect");
                            if (state.cursor_node) |cursor_node| {
                                const rect = cursor_node.globalRect();
                                jw.beginObject();
                                jw.key("x");
                                jw.floatValue(rect.x);
                                jw.key("y");
                                jw.floatValue(rect.y);
                                jw.key("w");
                                jw.floatValue(rect.w);
                                jw.key("h");
                                jw.floatValue(rect.h);
                                jw.endObject();
                            } else {
                                jw.nullValue();
                            }
                            jw.key("selection_rects");
                            jw.beginArray();
                            if (state.selection_node) |selection_node| {
                                const rect = selection_node.globalRect();
                                if (rect.w > 0 and rect.h > 0) {
                                    jw.beginObject();
                                    jw.key("x");
                                    jw.floatValue(rect.x);
                                    jw.key("y");
                                    jw.floatValue(rect.y);
                                    jw.key("w");
                                    jw.floatValue(rect.w);
                                    jw.key("h");
                                    jw.floatValue(rect.h);
                                    jw.endObject();
                                }
                            }
                            for (state.extra_sel_nodes.items) |selection_node| {
                                const rect = selection_node.globalRect();
                                if (rect.w <= 0 or rect.h <= 0) continue;
                                jw.beginObject();
                                jw.key("x");
                                jw.floatValue(rect.x);
                                jw.key("y");
                                jw.floatValue(rect.y);
                                jw.key("w");
                                jw.floatValue(rect.w);
                                jw.key("h");
                                jw.floatValue(rect.h);
                                jw.endObject();
                            }
                            jw.endArray();
                            jw.key("ime_preedit_len");
                            jw.numberValue(@intCast(state.ime_preedit_len));
                            jw.key("ime_phase");
                            jw.stringValue(@tagName(state.ime_phase));
                            jw.key("input_type");
                            jw.stringValue("textarea");
                            jw.key("scroll_x");
                            jw.floatValue(0);
                            jw.key("scroll_y");
                            jw.floatValue(if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0);
                            jw.endObject();
                        }
                        queue.result.setJson(jw.getWritten());
                    } else {
                        queue.result.setError("test_id not found");
                    }
                } else {
                    queue.result.setError("no root");
                }
            } else {
                queue.result.setError("no context");
            }
            return true;
        },
        .windows => {
            var buf: [command_queue.RESULT_BUF_SIZE]u8 = undefined;
            var writer = JsonWriter.init(&buf);
            screenshot_windows.writeJson(&writer);
            if (writer.hasOverflowed()) queue.result.setError("window enumeration overflow") else queue.result.setJson(writer.getWritten());
            return true;
        },
        .screenshot => |payload| {
            const path = payload.getText();
            const id: ?[]const u8 = if (payload.window_id) |token| token.getText() else null;
            // Legacy custom applications without registered windows retain their callback.
            if (id == null and screenshot_windows.session == null and g_capture_screenshot_fn != null) {
                if (!g_capture_screenshot_fn.?(path)) {
                    setScreenshotError(queue, "capture-failed");
                    return true;
                }
            } else {
                screenshot_windows.capture(id, path) catch |err| {
                    setScreenshotError(queue, switch (err) {
                        error.InvalidWindowId => "invalid-window-id",
                        error.WindowNotFound => "window-not-found",
                        error.WindowClosing => "window-closing",
                        error.NoBoundTarget => "no-bound-target",
                        error.CaptureUnsupported => "capture-unsupported",
                        error.CaptureFailed => "capture-failed",
                    });
                    return true;
                };
            }
            var buf: [1024]u8 = undefined;
            var writer = JsonWriter.init(&buf);
            writer.beginObject();
            writer.key("ok");
            writer.boolean(true);
            writer.key("path");
            writer.string(path);
            writer.endObject();
            queue.result.setJson(writer.getWritten());
            return true;
        },
        .window => |command| {
            if (g_window_command_fn) |f| {
                if (f(command)) |state| {
                    var buf: [256]u8 = undefined;
                    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"decoration_height\":{d},\"decorated\":{},\"maximized\":{},\"active\":{},\"suspended\":{},\"width\":{d},\"height\":{d}}}", .{ state.decoration_height, state.decorated, state.maximized, state.active, state.suspended, state.width, state.height }) catch unreachable;
                    queue.result.setJson(json);
                } else queue.result.setError("native window operation failed");
            } else queue.result.setError("native window operations unsupported");
            return true;
        },
        .quit_app => {
            if (g_quit_app_fn) |f| {
                queue.result.setJson(if (f()) "{\"ok\":true}" else "{\"ok\":false}");
            } else queue.result.setError("quit callback unavailable");
            return true;
        },
        .resize_window => |payload| {
            if (g_resize_window_fn) |f| {
                if (f(payload.width, payload.height)) {
                    var buf: [128]u8 = undefined;
                    const out = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"width\":{d},\"height\":{d}}}", .{ payload.width, payload.height }) catch "{\"ok\":true}";
                    queue.result.setJson(out);
                } else {
                    queue.result.setError("resize failed");
                }
            } else {
                queue.result.setError("resize not supported");
            }
            return true;
        },
        .visual_quality => |command| {
            if (g_visual_quality_fn) |f| {
                if (f(command)) |quality| {
                    var buf: [128]u8 = undefined;
                    const json = std.fmt.bufPrint(&buf, "{{\"quality\":\"{s}\"}}", .{quality}) catch unreachable;
                    queue.result.setJson(json);
                } else queue.result.setError("visual quality unsupported");
            } else queue.result.setError("visual quality unsupported");
            return true;
        },
        .recording_start => |payload| {
            if (g_start_recording_fn) |f| {
                publishRecordingState(queue, f(payload.getPath(), payload.fps));
            } else {
                queue.result.setError("window recording not supported");
            }
            return true;
        },
        .recording_status => {
            if (g_recording_status_fn) |f| {
                publishRecordingState(queue, f());
            } else {
                queue.result.setError("window recording not supported");
            }
            return true;
        },
        .recording_stop => {
            if (g_stop_recording_fn) |f| {
                publishRecordingState(queue, f());
            } else {
                queue.result.setError("window recording not supported");
            }
            return true;
        },
    }
}

/// Find input_container with event_context in wrapper subtree (tag=.input).
fn findInputContainer(node: *Node) ?*Node {
    if (node.tag == .input and node.behavior.events.event_context != null) return node;
    for (node.children.items) |child| {
        if (findInputContainer(child)) |found| return found;
    }
    return null;
}

fn clickTargetMatches(ctx: *Cx, handle: anytype, x: f32, y: f32) bool {
    const hit = ctx.hitTest(x, y) orelse return false;
    const target = ctx.node_registry.resolve(handle, &ctx.perf) orelse return false;
    var current: ?*Node = hit;
    while (current) |n| : (current = n.parent) if (n == target) return true;
    current = target;
    while (current) |n| : (current = n.parent) if (n == hit) return true;
    return false;
}

/// Nearest `.scroll` ancestor of `node` (exclusive), or null if none.
fn nearestScrollAncestor(node: *Node) ?*Node {
    var cur: ?*Node = node.parent;
    while (cur) |n| : (cur = n.parent) {
        if (n.tag == .scroll) return n;
    }
    return null;
}

/// Bring `node` into its scroll container's vertical viewport so `globalRect()` lands on-screen,
/// used before harness click/screen_pos so row scrolled out of view (e.g. long sidebar nav) stays
/// clickable.
///
/// **Must drive real ScrollArea `ScrollState.scroll_y`, not direct `content.style.translate_y`**:
/// `scrollbarBeforeRender` re-calculates translate_y each frame from `state.scroll_y` (including
/// maxScroll re-clamp), hand-written translate overwritten next frame (scroll_y still 0),
/// position/visual mismatch, wrong row hit. Solution: calculate node offset in content coords ->
/// set `state.scroll_y` (clamp to [0, content_h-view_h], max from rect not state, state dimensions
/// at command-exec time may be stale) -> sync translate_y + state dims + layout()+render(), after
/// that globalRect reflects new offset. Only nearest .scroll ancestor (storybook sidebar
/// sufficient).
fn scrollNodeIntoView(ctx: *Cx, node: *Node, align_top: bool) void {
    const scroll = nearestScrollAncestor(node) orelse return;
    // Get real ScrollState via container event_context (not guess children[0]/translate).
    const scroll_area = ui.widgets.scroll_area;
    if (scroll.behavior.events.on_event != scroll_area.scrollEventHandler) return;
    const ev_ctx: *scroll_area.ScrollEventCtx = @ptrCast(@alignCast(scroll.behavior.events.event_context orelse return));
    const state = ev_ctx.state;
    const content = ev_ctx.content orelse return;

    const margin: f32 = 8;
    const scroll_rect = scroll.globalRect();
    const node_rect = node.globalRect();
    const content_rect = content.globalRect();
    const view_h = scroll_rect.h - scroll.style.contentInsets().vertical();

    // Node top in content coords (independent of current scroll: content and node shift together).
    const offset_in_content = node_rect.y - content_rect.y;
    // Node distance to container top in visible coords.
    const rel_top = node_rect.y - scroll_rect.y;

    // Fully on-screen: no movement.
    if (!align_top and rel_top >= margin and rel_top + node_rect.h <= view_h - margin) return;

    var target_scroll = state.scroll_y;
    if (align_top or rel_top < margin) {
        // Node clipped above -> align top to margin.
        target_scroll = offset_in_content - margin;
    } else {
        // Node clipped below -> align bottom to view_h - margin.
        target_scroll = offset_in_content + node_rect.h - (view_h - margin);
    }
    // maxScrollY from rect direct (not state.content_height/viewport_height, filled by
    // before_render hook, may be stale or 0 at command-exec time, old value re-clamps target scroll
    // gone, 'wrong row' root cause).
    const max_y = @max(content_rect.h - view_h, 0);
    if (target_scroll < 0) target_scroll = 0;
    if (target_scroll > max_y) target_scroll = max_y;

    if (target_scroll != state.scroll_y) {
        state.scroll_y = target_scroll;
        // Sync viewport/content dims to state too, prevent next-frame before_render re-clamp using
        // old dims and pulling scroll_y back.
        if (view_h > 0) state.viewport_height = view_h;
        if (!state.external_content_height and content_rect.h > 0) state.content_height = content_rect.h;
        // Sync translate_y (matches scroll_y -> before_render hook won't re-correct). Idle frame
        // hook doesn't re-calc translate_y (only on bounce/re-clamp), force it here.
        content.style.translate_y = state.contentTranslateY();
        content.markInteractionDirty();
        content.markRenderDirty();
        ctx.needs_redraw = true;
        ctx.layout();
        _ = ctx.render();
    }
}

fn parseKeyName(name: []const u8) KeyCode {
    if (std.ascii.eqlIgnoreCase(name, "f10")) return .f10;
    if (std.ascii.eqlIgnoreCase(name, "f11")) return .f11;
    if (std.ascii.eqlIgnoreCase(name, "Alt") or std.ascii.eqlIgnoreCase(name, "AltLeft")) return .left_alt;
    if (std.ascii.eqlIgnoreCase(name, "AltRight")) return .right_alt;
    if (std.mem.eql(u8, name, "tab")) return .tab;
    if (std.mem.eql(u8, name, "enter") or std.mem.eql(u8, name, "return")) return .@"return";
    if (std.mem.eql(u8, name, "escape") or std.mem.eql(u8, name, "esc")) return .escape;
    if (std.mem.eql(u8, name, "space")) return .space;
    if (std.mem.eql(u8, name, "backspace") or std.mem.eql(u8, name, "delete")) return .delete;
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "right")) return .right;
    if (std.mem.eql(u8, name, "up")) return .up;
    if (std.mem.eql(u8, name, "down")) return .down;
    if (std.mem.eql(u8, name, "home")) return .home;
    if (std.mem.eql(u8, name, "end")) return .end;
    // Character key.
    if (name.len == 1) {
        const c = name[0];
        switch (c) {
            'a' => return .a,
            'b' => return .b,
            'c' => return .c,
            'd' => return .d,
            'e' => return .e,
            'f' => return .f,
            'g' => return .g,
            'h' => return .h,
            'i' => return .i,
            'j' => return .j,
            'k' => return .k,
            'l' => return .l,
            'm' => return .m,
            'n' => return .n,
            'o' => return .o,
            'p' => return .p,
            'q' => return .q,
            'r' => return .r,
            's' => return .s,
            't' => return .t,
            'u' => return .u,
            'v' => return .v,
            'w' => return .w,
            'x' => return .x,
            'y' => return .y,
            'z' => return .z,
            // Symbol key: cmd[ / cmd] class layer shortcuts only reachable via it.
            '[' => return .left_bracket,
            ']' => return .right_bracket,
            '-' => return .minus,
            '=' => return .equal,
            '/' => return .slash,
            ',' => return .comma,
            '.' => return .period,
            ';' => return .semicolon,
            '\'' => return .quote,
            '\\' => return .backslash,
            '`' => return .grave,
            '0' => return .@"0",
            '1' => return .@"1",
            '2' => return .@"2",
            '3' => return .@"3",
            '4' => return .@"4",
            '5' => return .@"5",
            '6' => return .@"6",
            '7' => return .@"7",
            '8' => return .@"8",
            '9' => return .@"9",
            else => return .unknown,
        }
    }
    return .unknown;
}

var g_console_test_ctx: ?*Cx = null;

fn getConsoleTestCtx() ?*Cx {
    return g_console_test_ctx;
}

fn getNoTestCtx() ?*Cx {
    return null;
}

test "console harness query serializes events and clear mutates the target Cx" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.console().configure(.{ .terminal_level = null });
    cx.console().writeAt(.err, @src(), "harness-needle", .{});

    g_console_test_ctx = cx;
    setGetCtxFn(getConsoleTestCtx);
    defer {
        g_console_test_ctx = null;
        setGetCtxFn(getNoTestCtx);
    }

    var queue = CommandQueue{ .io = std.testing.io, .allocator = std.testing.allocator };
    try std.testing.expect(executeCommand(&queue, .{ .console_query = .{ .after_seq = 0, .limit = 10 } }));
    const body = queue.result.getData();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"message\":\"harness-needle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"level\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"source\":{") != null);

    try std.testing.expect(executeCommand(&queue, .{ .console_clear = {} }));
    try std.testing.expectEqual(@as(usize, 0), cx.console().stats().live_entries);
    try std.testing.expectEqualStrings("{\"ok\":true}", queue.result.getData());
}

test "test-id click rejects an occluding sibling without dispatching to it" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setWindowMetrics(200, 200, 1);
    const root = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;
    const target = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    const cover = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    target.meta.ownership.meta.test_id = "covered-control";
    var target_clicked = false;
    var cover_clicked = false;
    const Callback = struct {
        fn click(context: *anyopaque) void {
            const value: *bool = @ptrCast(@alignCast(context));
            value.* = true;
        }
    };
    target.behavior.events.on_click = Cx.simpleHandler(Callback.click, &target_clicked);
    cover.behavior.events.on_click = Cx.simpleHandler(Callback.click, &cover_clicked);
    try root.appendChild(cx.allocator, target);
    try root.appendChild(cx.allocator, cover);
    cx.layout();
    _ = cx.render();
    g_console_test_ctx = cx;
    setGetCtxFn(getConsoleTestCtx);
    defer {
        g_console_test_ctx = null;
        setGetCtxFn(getNoTestCtx);
    }
    var payload = command_queue.TestIdPayload{ .len = "covered-control".len };
    @memcpy(payload.buf[0..payload.len], "covered-control");
    var queue = CommandQueue{ .io = std.testing.io, .allocator = std.testing.allocator };
    try std.testing.expect(executeCommand(&queue, .{ .click_test_id = payload }));
    try std.testing.expect(!queue.result.success);
    try std.testing.expect(!target_clicked and !cover_clicked);
    cover.setHitTestVisible(false);
    try std.testing.expect(executeCommand(&queue, .{ .click_test_id = payload }));
    try std.testing.expect(queue.result.success);
    try std.testing.expect(target_clicked and !cover_clicked);
}

test "recording state serialization exposes cadence and artifact metadata" {
    var queue: CommandQueue = .{ .io = std.testing.io };
    var state: RecordingState = .{
        .ok = true,
        .active = true,
        .width = 2200,
        .height = 2000,
        .fps = 60,
        .duration_ms = 1234,
        .file_size = 4567,
        .frame_count = 73,
        .dropped_frames = 2,
    };
    state.setPath("/tmp/zenit recording.mp4");
    publishRecordingState(&queue, state);

    const json = queue.result.getData();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"width\":2200") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"frame_count\":73") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dropped_frames\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\":\"/tmp/zenit recording.mp4\"") != null);
}

test "submitted frame observation is bounded, window-specific and stops on read" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var other = try Cx.init(std.testing.allocator, std.testing.io);
    defer other.deinit();
    const root = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    root.meta.ownership.meta.test_id = "observed";
    cx.root = root;
    cx.layout();
    g_console_test_ctx = cx;
    setGetCtxFn(getConsoleTestCtx);
    defer {
        frame_target = null;
        g_console_test_ctx = null;
        setGetCtxFn(getNoTestCtx);
    }
    var payload = command_queue.TestIdPayload{ .len = "observed".len };
    @memcpy(payload.buf[0..payload.len], "observed");
    frame_target = payload;
    frame_context = @intFromPtr(cx);
    frame_started = @import("zenit_time").monotonicTimestamp(cx.io);
    frame_count = 0;
    frame_missing = 0;
    frame_overflow = false;
    observeSubmittedFrame(other);
    try std.testing.expectEqual(@as(usize, 0), frame_count);
    for (0..129) |_| observeSubmittedFrame(cx);
    try std.testing.expectEqual(@as(usize, 128), frame_count);
    try std.testing.expect(frame_overflow);
    // Removing the ID must be detected without dereferencing a saved node.
    root.meta.ownership.meta.test_id = "replaced";
    observeSubmittedFrame(cx);
    try std.testing.expectEqual(@as(usize, 1), frame_missing);
    var queue = CommandQueue{ .io = std.testing.io, .allocator = std.testing.allocator };
    try std.testing.expect(executeCommand(&queue, .{ .frames_read = {} }));
    try std.testing.expect(queue.result.success);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, queue.result.getData(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 128), parsed.value.object.get("frames").?.array.items.len);
    try std.testing.expect(parsed.value.object.get("overflow").?.bool);
    try std.testing.expect(frame_target == null);
    root.meta.ownership.meta.test_id = "observed";
    observeSubmittedFrame(cx);
    try std.testing.expectEqual(@as(usize, 128), frame_count);
}

test "frame Escape action fires once on visible entrance and ignores other windows" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const other = try Cx.init(std.testing.allocator, std.testing.io);
    defer other.deinit();
    const root = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    root.meta.ownership.meta.test_id = "action-target";
    cx.root = root;
    cx.layout();
    g_console_test_ctx = cx;
    setGetCtxFn(getConsoleTestCtx);
    defer {
        frame_target = null;
        frame_escape_on_enter = false;
        frame_action_index = null;
        g_console_test_ctx = null;
        setGetCtxFn(getNoTestCtx);
    }
    var payload = command_queue.TestIdPayload{ .len = "action-target".len };
    @memcpy(payload.buf[0..payload.len], "action-target");
    frame_target = payload;
    frame_context = @intFromPtr(cx);
    frame_started = @import("zenit_time").monotonicTimestamp(cx.io);
    frame_count = 0;
    frame_missing = 0;
    frame_overflow = false;
    frame_escape_on_enter = true;
    frame_action_index = null;
    observeSubmittedFrame(other);
    try std.testing.expectEqual(@as(usize, 0), frame_count);
    root.setOpacity(0);
    observeSubmittedFrame(cx);
    try std.testing.expect(frame_action_index == null);
    root.setOpacity(0.25);
    observeSubmittedFrame(cx);
    try std.testing.expectEqual(@as(?usize, 1), frame_action_index);
    try std.testing.expect(!frame_escape_on_enter);
    root.setOpacity(0.5);
    observeSubmittedFrame(cx);
    try std.testing.expectEqual(@as(?usize, 1), frame_action_index);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), frame_samples[1].effective_opacity, 0.001);
}

test "locked animation clock advances only by granted time" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    cx.frame_time_ms = 500;
    g_console_test_ctx = cx;
    setGetCtxFn(getConsoleTestCtx);
    defer {
        g_console_test_ctx = null;
        setGetCtxFn(getNoTestCtx);
    }
    var queue = CommandQueue{
        .io = std.testing.io,
    };
    try std.testing.expect(executeCommand(&queue, .{ .animation_clock_locked = 20 }));
    // Frozen: active frames render without moving time.
    for (0..3) |_| {
        cx.needs_redraw = true;
        cx.advanceFrameClock();
    }
    try std.testing.expectEqual(@as(f64, 500), cx.frame_time_ms);
    try std.testing.expect(!cx.wantsFrame() or cx.hasPendingSceneWork());
    // A 50 ms grant: active frames step 20, 20, 10, then stop; frames are wanted
    // until the grant is spent.
    try std.testing.expect(executeCommand(&queue, .{ .clock_advance = 50 }));
    try std.testing.expect(cx.wantsFrame());
    for ([_]f64{ 520, 540, 550, 550 }) |expected| {
        cx.needs_redraw = true;
        cx.advanceFrameClock();
        try std.testing.expectEqual(expected, cx.frame_time_ms);
    }
    // An idle scene spends a grant in one step so timers still come due.
    try std.testing.expect(executeCommand(&queue, .{ .clock_advance = 2000 }));
    cx.layout();
    _ = cx.render();
    cx.needs_redraw = false;
    cx.advanceFrameClock();
    try std.testing.expectEqual(@as(f64, 2550), cx.frame_time_ms);
    try std.testing.expectEqual(@as(?f64, 0), cx.test_clock_budget_ms);
    // Realtime clears the lock; advancing an unlocked clock is an error.
    try std.testing.expect(executeCommand(&queue, .{ .animation_clock = 0 }));
    try std.testing.expectEqual(@as(?f64, null), cx.test_clock_budget_ms);
    _ = executeCommand(&queue, .{ .clock_advance = 10 });
    try std.testing.expect(std.mem.indexOf(u8, queue.result.getData(), "not locked") != null);
}

test "animation clock fixed steps preserve time and restore realtime" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.root = try ui.box(cx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    cx.frame_time_ms = 500;
    g_console_test_ctx = cx;
    setGetCtxFn(getConsoleTestCtx);
    defer {
        g_console_test_ctx = null;
        setGetCtxFn(getNoTestCtx);
    }
    var queue = CommandQueue{
        .io = std.testing.io,
    };
    try std.testing.expect(executeCommand(&queue, .{ .animation_clock = 33 }));
    try std.testing.expectEqual(@as(?f32, 33), cx.test_frame_step_ms);
    for (0..3) |_| {
        cx.needs_redraw = true;
        cx.advanceFrameClock();
    }
    try std.testing.expectEqual(@as(f64, 599), cx.frame_time_ms);
    try std.testing.expectEqual(@as(f32, 33), cx.frame_dt_ms);
    // Events stamp the fixed-step frame time, not the wall clock: an animation
    // started by a click must begin at the time the next steps advance from.
    try std.Io.sleep(cx.io, .fromNanoseconds(700 * std.time.ns_per_ms), .awake);
    try std.testing.expectEqual(cx.frame_time_ms, cx.eventTimeMs());
    cx.layout();
    _ = cx.render();
    cx.needs_redraw = false;
    cx.advanceFrameClock();
    try std.testing.expectEqual(@as(f64, 599), cx.frame_time_ms);
    try std.testing.expectError(error.InvalidFrameStep, cx.setTestFrameStep(std.math.nan(f32)));
    try std.testing.expectError(error.InvalidFrameStep, cx.setTestFrameStep(101));
    try std.testing.expectError(error.InvalidFrameStep, cx.setTestFrameStep(-1));
    try std.testing.expectEqual(@as(?f32, 33), cx.test_frame_step_ms);
    try std.testing.expect(executeCommand(&queue, .{ .animation_clock = 0 }));
    try std.testing.expectEqual(@as(?f32, null), cx.test_frame_step_ms);
    cx.needs_redraw = true;
    cx.advanceFrameClock();
    try std.testing.expectEqual(@as(f64, 599), cx.frame_time_ms);
    // Returning to deterministic mode also preserves the logical epoch.
    try cx.setTestFrameStep(20);
    cx.needs_redraw = true;
    cx.advanceFrameClock();
    try std.testing.expectEqual(@as(f64, 619), cx.frame_time_ms);
}

test "timed capture reads one submitted frame after deadline and disarms on read" {
    const Capture = struct {
        var calls: usize = 0;
        fn screenshot(path: []const u8) bool {
            calls += 1;
            return std.mem.eql(u8, path, "timed.bmp");
        }
    };
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } }, .{});
    root.meta.ownership.meta.test_id = "sample";
    cx.root = root;
    cx.layout();
    g_console_test_ctx = cx;
    setGetCtxFn(getConsoleTestCtx);
    const old_capture = g_capture_screenshot_fn;
    g_capture_screenshot_fn = Capture.screenshot;
    defer {
        frame_target = null;
        frame_capture_path = null;
        frame_capture_index = null;
        frame_capture_failed = false;
        g_capture_screenshot_fn = old_capture;
        g_console_test_ctx = null;
        setGetCtxFn(getNoTestCtx);
    }
    var target: command_queue.TestIdPayload = .{ .len = 6 };
    @memcpy(target.buf[0..6], "sample");
    var path: command_queue.TestIdPayload = .{ .len = 9 };
    @memcpy(path.buf[0..9], "timed.bmp");
    frame_target = target;
    frame_capture_path = path;
    frame_context = @intFromPtr(cx);
    frame_count = 0;
    frame_capture_after_ms = 120;
    defer frame_capture_after_ms = 0;
    frame_capture_index = null;
    frame_capture_failed = false;
    frame_escape_on_enter = false;
    Capture.calls = 0;
    frame_capture_started_ms = cx.frame_time_ms;
    // GPU completion can be late while the submitted animation is still at
    // its initial state. Capture follows the frame's evaluated animation time.
    frame_started = @import("zenit_time").monotonicTimestamp(cx.io) - 200 * std.time.ns_per_ms;
    observeSubmittedFrame(cx);
    try std.testing.expectEqual(@as(usize, 0), Capture.calls);
    cx.frame_time_ms += 130;
    observeSubmittedFrame(cx);
    try std.testing.expectEqual(@as(usize, 1), Capture.calls);
    try std.testing.expectEqual(@as(?usize, 1), frame_capture_index);
    observeSubmittedFrame(cx);
    try std.testing.expectEqual(@as(usize, 1), Capture.calls);
    var queue = CommandQueue{ .io = std.testing.io, .allocator = std.testing.allocator };
    _ = executeCommand(&queue, .{ .frames_capture_read = {} });
    try std.testing.expect(queue.result.success);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, queue.result.getData(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
    try std.testing.expect(frame_target == null);
    frame_target = target;
    frame_capture_path = path;
    _ = executeCommand(&queue, .{ .frames_read = {} });
    observeSubmittedFrame(cx);
    try std.testing.expectEqual(@as(usize, 1), Capture.calls);
    try std.testing.expect(frame_capture_path == null);
}

pub const VisualQualityCommand = @import("command_queue.zig").VisualQualityCommand;
pub const VisualQualityFn = *const fn (VisualQualityCommand) ?[]const u8;
var g_visual_quality_fn: ?VisualQualityFn = null;
pub fn setVisualQualityFn(f: VisualQualityFn) void {
    g_visual_quality_fn = f;
}

test "harness pacing: readonly queries do not force an animation submission" {
    const commands = [_]TestCommand{
        .{ .health = {} },         .{ .query_tree = {} },  .{ .query_selector = .{} },
        .{ .get_focused = {} },    .{ .screen_pos = .{} }, .{ .recording_status = {} },
        .{ .input_state = .{} },   .{ .frame_stats = {} }, .{ .reset_timing = {} },
        .{ .console_query = .{} },
    };
    for (commands) |cmd| try std.testing.expect(!commandRequestsFrame(cmd));
}

test "harness quit invokes the app on the dispatch thread without requesting a frame" {
    const Quit = struct {
        var calls: u32 = 0;
        fn run() bool {
            calls += 1;
            return true;
        }
    };
    const previous = g_quit_app_fn;
    defer g_quit_app_fn = previous;
    var queue = CommandQueue{ .io = std.testing.io, .allocator = std.testing.allocator };
    g_quit_app_fn = null;
    try std.testing.expect(executeCommand(&queue, .{ .quit_app = {} }));
    try std.testing.expect(!queue.result.success);
    Quit.calls = 0;
    setQuitAppFn(Quit.run);
    try std.testing.expect(!commandRequestsFrame(.{ .quit_app = {} }));
    try std.testing.expect(executeCommand(&queue, .{ .quit_app = {} }));
    try std.testing.expectEqual(@as(u32, 1), Quit.calls);
    try std.testing.expectEqualStrings("{\"ok\":true}", queue.result.getData());
}

test "harness pacing: input screenshots and opaque routes require an immediate frame" {
    try std.testing.expect(commandRequestsFrame(.{ .mouse_down = .{ .x = 1, .y = 2 } }));
    try std.testing.expect(commandRequestsFrame(.{ .key_down = .{} }));
    try std.testing.expect(commandRequestsFrame(.{ .resize_window = .{ .width = 640, .height = 480 } }));
    try std.testing.expect(commandRequestsFrame(.{ .screenshot = .{} }));
    try std.testing.expect(commandRequestsFrame(.{ .app_route = command_queue.AppRoutePayload.init("/custom", "").? }));
}

test "harness pacing: a wheel event requests a frame only through what it changes" {
    // Like a platform wheel event (pointer_isolation.eventForcesFrame): Cx.handleScroll asks
    // for the frame when a handler moved something.
    try std.testing.expect(!commandRequestsFrame(.{ .scroll = .{ .x = 1, .y = 2, .dx = 0, .dy = 12 } }));
}

test "harness pacing: a consumed batch requests a frame once without a persistent wake" {
    var queue: CommandQueue = .{ .io = std.testing.io };
    queue.commands[0] = .{ .health = {} };
    queue.tail.store(1, .release);
    try std.testing.expect(!drainCommandsRequestFrame(&queue));
    try std.testing.expect(!drainCommandsRequestFrame(&queue));

    queue.commands[1] = .{ .app_route = command_queue.AppRoutePayload.init("/custom", "").? };
    queue.tail.store(2, .release);
    try std.testing.expect(drainCommandsRequestFrame(&queue));
    try std.testing.expect(!drainCommandsRequestFrame(&queue));
}

test "harness command boundary ends before next command including failed commands" {
    const Boundary = struct {
        var begins: usize = 0;
        var ends: usize = 0;
        var depth: usize = 0;
        fn begin() void {
            std.debug.assert(depth == 0 and begins == ends);
            begins += 1;
            depth += 1;
        }
        fn end() void {
            std.debug.assert(depth == 1);
            depth -= 1;
            ends += 1;
        }
    };
    Boundary.begins = 0;
    Boundary.ends = 0;
    Boundary.depth = 0;
    setCommandBoundaryCallbacks(Boundary.begin, Boundary.end);
    defer setCommandBoundaryCallbacks(null, null);
    var queue: CommandQueue = .{ .io = std.testing.io };
    queue.commands[0] = .{ .health = {} };
    queue.commands[1] = .{ .app_route = command_queue.AppRoutePayload.init("/missing", "").? };
    queue.tail.store(2, .release);
    _ = drainCommandsRequestFrame(&queue);
    try std.testing.expectEqual(@as(usize, 2), Boundary.begins);
    try std.testing.expectEqual(Boundary.begins, Boundary.ends);
    try std.testing.expectEqual(@as(usize, 0), Boundary.depth);
}

test "harness multi-click stops generating input after callback requests close" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setWindowMetrics(200, 200, 1);
    const root = try ui.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;
    const State = struct {
        cx: *Cx,
        count: usize = 0,
        fn click(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.cx.close_requested = true;
        }
    };
    var state: State = .{ .cx = cx };
    root.behavior.events.on_click = Cx.simpleHandler(State.click, &state);
    cx.layout();
    _ = cx.render();
    const old = g_get_ctx_fn;
    g_console_test_ctx = cx;
    setGetCtxFn(getConsoleTestCtx);
    defer {
        g_console_test_ctx = null;
        g_get_ctx_fn = old;
    }
    var queue: CommandQueue = .{ .io = std.testing.io };
    try std.testing.expect(executeCommand(&queue, .{ .click = .{ .x = 10, .y = 10, .count = 3 } }));
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expect(getCtx() == null);
}

test "targeted screenshot executor preserves compatible success and structured errors" {
    const old = screenshot_windows;
    defer screenshot_windows = old;
    screenshot_windows = .{};
    const Fake = struct {
        fn closing(_: *anyopaque) bool {
            return false;
        }
        fn capture(_: *anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var owner: u8 = 0;
    screenshot_windows.register(123, &owner, 1, Fake.capture, Fake.closing);
    screenshot_windows.bound = &owner;
    var queue: CommandQueue = .{ .io = std.testing.io };
    var payload: command_queue.ScreenshotPayload = .{};
    const path = "escaped\\path.png";
    @memcpy(payload.path.buf[0..path.len], path);
    payload.path.len = path.len;
    try std.testing.expect(executeCommand(&queue, .{ .screenshot = payload }));
    try std.testing.expectEqualStrings("{\"ok\":true,\"path\":\"escaped\\\\path.png\"}", queue.result.getData());
    payload.window_id = .{};
    const invalid = "7b-999";
    @memcpy(payload.window_id.?.buf[0..invalid.len], invalid);
    payload.window_id.?.len = invalid.len;
    try std.testing.expect(executeCommand(&queue, .{ .screenshot = payload }));
    try std.testing.expect(!queue.result.success);
    try std.testing.expectEqualStrings("{\"error\":\"window-not-found\",\"code\":\"window-not-found\"}", queue.result.getData());
    try std.testing.expect(executeCommand(&queue, .{ .windows = {} }));
    try std.testing.expect(std.mem.indexOf(u8, queue.result.getData(), "\"window_id\":\"7b-1\"") != null);
}
