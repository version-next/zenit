/// test_harness, E2E test skeleton
///
/// Provides file-based RPC API for e2e test automation of UI interactions. Enable via `zig build
/// -Dtest-mode=true`, otherwise compile-time erased.
const std = @import("std");
const build_options = @import("build_options");
const ui = @import("ui");

pub const enabled = build_options.test_mode;

pub const CommandQueue = @import("command_queue.zig").CommandQueue;
pub const TestCommand = @import("command_queue.zig").TestCommand;
const command_queue = @import("command_queue.zig");
const command_executor = @import("command_executor.zig");
const http_server = @import("http_server.zig");

var g_queue: CommandQueue = undefined;
/// Set once init() gives g_queue a value. An application can mount every
/// window with Config.builtin_test_harness = false, so the runtime's drain
/// calls may run in a test-mode build whose queue was never initialized.
var g_queue_ready = false;
var g_thread: ?std.Thread = null;

/// Queried by submitted-frame capture on the same application thread that
/// executes /frames/capture/finish. Process-wide, including secondary windows.
pub fn frameCaptureFinished() bool {
    return enabled and command_executor.frameCaptureFinished();
}

pub fn setCommandBoundaryCallbacks(begin: ?*const fn () void, end: ?*const fn () void) void {
    if (!enabled) return;
    command_executor.setCommandBoundaryCallbacks(begin, end);
}

pub fn registerScreenshotWindow(io: std.Io, owner: *anyopaque, native_id: u64, capture: ?@import("screenshot_windows.zig").Capture, closing: @import("screenshot_windows.zig").Closing) void {
    if (!enabled) return;
    var session: u128 = command_executor.screenshot_windows.session orelse 0;
    if (command_executor.screenshot_windows.session == null) io.randomSecure(std.mem.asBytes(&session)) catch @panic("harness window session entropy unavailable");
    command_executor.screenshot_windows.register(session, owner, native_id, capture, closing);
}
pub fn bindScreenshotWindow(owner: *anyopaque) void {
    if (enabled) command_executor.screenshot_windows.bound = owner;
}
pub fn unregisterScreenshotWindow(owner: *anyopaque) void {
    if (enabled) command_executor.screenshot_windows.unregister(owner);
}

/// Register screenshot callback
pub fn setScreenshotCallback(f: command_executor.CaptureScreenshotFn) void {
    if (!enabled) return;
    command_executor.setCaptureScreenshotFn(f);
}

pub const RecordingState = command_executor.RecordingState;
/// In-process access to the same app-thread callbacks used by file RPC.
pub const startRecording = command_executor.startRecording;
pub const recordingStatus = command_executor.recordingStatus;
pub const stopRecording = command_executor.stopRecording;

/// Register the app-window recording lifecycle. All callbacks run on the
/// application thread, just like screenshot capture and UI commands.
pub fn setRecordingCallbacks(
    start: command_executor.StartRecordingFn,
    status: command_executor.RecordingStateFn,
    stop: command_executor.RecordingStateFn,
) void {
    if (!enabled) return;
    command_executor.setRecordingCallbacks(start, status, stop);
}

pub const FrameStatsSnapshot = command_executor.FrameStatsSnapshot;
pub const StageTotals = command_executor.StageTotals;
pub const CaretRejections = command_executor.CaretRejections;
pub const AppRouteFn = command_executor.AppRouteFn;

/// Register host-custom routes (`/myapp/...` etc). Handler runs on main thread, can safely
/// read/write host UI state; return null = path not recognized, harness replies 404.
pub fn setAppRouteHandler(f: AppRouteFn) void {
    if (!enabled) return;
    command_executor.setAppRouteFn(f);
}

/// Routes owned by the platform runtime; checked before the app's handler.
pub fn setRuntimeRouteHandler(f: AppRouteFn) void {
    if (!enabled) return;
    command_executor.setRuntimeRouteFn(f);
}

pub const CpuPatchStatus = command_executor.CpuPatchStatus;

/// Register CPU patch control (/cpu_patches route).
pub fn setCpuPatchCallback(f: command_executor.CpuPatchFn) void {
    if (!enabled) return;
    command_executor.setCpuPatchFn(f);
}

/// Register the WindowServer window capture (/screenshot/composited route).
pub fn setCompositedCaptureCallback(f: command_executor.CompositedCaptureFn) void {
    if (!enabled) return;
    command_executor.setCompositedCaptureFn(f);
}

/// Register FrameStats query callback (/stats route)
pub fn setFrameStatsCallback(f: command_executor.GetFrameStatsFn) void {
    if (!enabled) return;
    command_executor.setGetFrameStatsFn(f);
}

/// Register timing ring clear callback (/stats/reset route)
pub fn setResetTimingCallback(f: command_executor.ResetTimingFn) void {
    if (!enabled) return;
    command_executor.setResetTimingFn(f);
}

/// Register window resize callback (/resize route)
pub fn setQuitCallback(f: *const fn () bool) void {
    if (!enabled) return;
    command_executor.setQuitAppFn(f);
}
pub fn setResizeWindowCallback(f: command_executor.ResizeWindowFn) void {
    if (!enabled) return;
    command_executor.setResizeWindowFn(f);
}

/// Initialize test harness: set callbacks + start HTTP server thread
pub fn init(io: std.Io, get_ctx_fn: command_executor.GetCtxFn, wake_fn: *const fn () void) void {
    if (!enabled) return;
    command_executor.setGetCtxFn(get_ctx_fn);
    if (g_thread == null) {
        g_queue = .{ .io = io };
        g_queue_ready = true;
    }
    g_queue.setWakeCallback(wake_fn);
    // App.mount is invoked once per native window. The harness queue and its
    // file-RPC directory are process-global, so MultiWindowApp must keep one
    // worker while allowing the most recently mounted/rebound window callbacks
    // above to become the current automation target.
    if (g_thread != null) return;
    std.debug.print("[test_harness] Initializing...\n", .{});
    g_thread = std.Thread.spawn(.{}, http_server.serverThread, .{&g_queue}) catch |err| {
        std.debug.print("[test_harness] Failed to start HTTP thread: {}\n", .{err});
        return;
    };
    if (g_thread) |t| {
        t.detach();
    }
    std.debug.print("[test_harness] File RPC server started (port {d})\n", .{build_options.e2e_port});
}

/// Main thread post-render each frame: per-frame tracking (track_start/track_stop) record samples
/// here
pub fn afterFrame() void {
    if (!enabled) return;
    command_executor.afterFrame();
}

/// Main thread each frame: consume and execute test commands from queue
pub fn drainCommands() void {
    if (!enabled or !g_queue_ready) return;
    command_executor.drainCommands(&g_queue);
}

/// Hosts with display-tick coalescing use this one-shot result to keep input
/// and capture commands immediate while allowing readonly polling to stay idle.
/// See command_executor.streamNextDelayNs.
pub fn streamNextDelayNs() ?u64 {
    if (!enabled or !g_queue_ready) return null;
    return command_executor.streamNextDelayNs(g_queue.io);
}

pub fn drainCommandsRequestFrame() bool {
    if (!enabled or !g_queue_ready) return false;
    return command_executor.drainCommandsRequestFrame(&g_queue);
}

test {
    // Explicitly reference sub-file tests (this repo has orphan-test history: a bare @import
    // outside a test block = never compiled).
    _ = @import("http_server.zig");
    _ = @import("command_queue.zig");
    // command_executor.zig's 2 tests (console serialize / recording state serialize) were orphans:
    // including breaks harness link (CoreText extern symbols via ui->text path). Added
    // addCoreTextBridge to harness_tests in build.zig.
    _ = @import("command_executor.zig");
    _ = @import("tree_serializer.zig");
}

/// Observe successfully submitted Windows frames; never forces layout or rendering.
pub fn observeSubmittedFrame(ctx: *ui.Cx) void {
    if (!enabled) return;
    command_executor.observeSubmittedFrame(ctx);
}

/// Serialize the same UI state that produced a submitted frame, without
/// advancing layout/animation. Used by opt-in native frame archives.
pub fn submittedTreeJson(ctx: *ui.Cx, buffer: []u8) ![]const u8 {
    if (!enabled) return error.TestHarnessDisabled;
    const root = ctx.root orelse return error.NoRoot;
    return @import("tree_serializer.zig").serializeFrameTree(root, &ctx.overlay_stack, buffer);
}

pub const VisualQualityCommand = command_executor.VisualQualityCommand;
pub fn setVisualQualityCallback(f: command_executor.VisualQualityFn) void {
    if (!enabled) return;
    command_executor.setVisualQualityFn(f);
}

/// Native window controls, executed on the UI thread through the Harness.
pub const WindowCommand = command_queue.WindowCommand;
pub const WindowSnapshot = command_queue.WindowSnapshot;
pub fn setWindowCommandCallback(f: command_executor.WindowCommandFn) void {
    if (!enabled) return;
    command_executor.setWindowCommandFn(f);
}
