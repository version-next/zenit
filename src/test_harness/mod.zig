/// test_harness, E2E 测试骨架
///
/// 提供 file-based RPC API 让 e2e 测试自动化 UI 交互。
/// 通过 `zig build -Dtest-mode=true` 启用，否则编译期消除。
const std = @import("std");
const build_options = @import("build_options");
const ui = @import("ui");

pub const enabled = build_options.test_mode;

pub const CommandQueue = @import("command_queue.zig").CommandQueue;
pub const TestCommand = @import("command_queue.zig").TestCommand;
const command_executor = @import("command_executor.zig");
const http_server = @import("http_server.zig");

var g_queue: CommandQueue = .{};
var g_thread: ?std.Thread = null;

/// 注册截图回调
pub fn setScreenshotCallback(f: command_executor.CaptureScreenshotFn) void {
    if (!enabled) return;
    command_executor.setCaptureScreenshotFn(f);
}

pub const RecordingState = command_executor.RecordingState;

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
pub const AppRouteFn = command_executor.AppRouteFn;

/// 注册宿主自定义路由（`/myapp/...` 之类）。handler 在主线程执行，
/// 可安全读写宿主 UI 状态；返回 null = 该路径不认，harness 回 404。
pub fn setAppRouteHandler(f: AppRouteFn) void {
    if (!enabled) return;
    command_executor.setAppRouteFn(f);
}

/// 注册 FrameStats 查询回调（/stats 路由）
pub fn setFrameStatsCallback(f: command_executor.GetFrameStatsFn) void {
    if (!enabled) return;
    command_executor.setGetFrameStatsFn(f);
}

/// 注册计时环清零回调（/stats/reset 路由）
pub fn setResetTimingCallback(f: command_executor.ResetTimingFn) void {
    if (!enabled) return;
    command_executor.setResetTimingFn(f);
}

/// 注册窗口 resize 回调（/resize 路由）
pub fn setResizeWindowCallback(f: command_executor.ResizeWindowFn) void {
    if (!enabled) return;
    command_executor.setResizeWindowFn(f);
}

/// 初始化测试线束：设置回调 + 启动 HTTP 服务器线程
pub fn init(get_ctx_fn: command_executor.GetCtxFn, wake_fn: *const fn () void) void {
    if (!enabled) return;
    command_executor.setGetCtxFn(get_ctx_fn);
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

/// 主线程每帧调用：消费并执行命令队列中的测试命令
pub fn drainCommands() void {
    if (!enabled) return;
    command_executor.drainCommands(&g_queue);
}

test {
    // 显式引用子文件测试（本仓库 orphan 测试前科：光 @import 不进 test 块 = 从不编译）。
    _ = @import("http_server.zig");
    _ = @import("command_queue.zig");
    // command_executor.zig 的 2 个测试（console 序列化 / recording 状态序列化）
    // 曾是孤儿：挂进来会让 test-harness 链接失败（经 ui->text 拉进 CoreText 的
    // extern 符号）。已在 build.zig 给 harness_tests 补 addCoreTextBridge。
    _ = @import("command_executor.zig");
    _ = @import("tree_serializer.zig");
}
