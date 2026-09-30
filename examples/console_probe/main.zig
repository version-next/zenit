//! Real-window end-to-end probe for the per-Cx Console and DevTools Console tab.
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");

const MultiWindowApp = zenit_app.MultiWindowApp;
var g_target_cx: ?*ui.Cx = null;

fn mountTarget(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .padding = ui.Padding.all(32),
        .background = cx.tokens.color.bg_primary,
    }, .{try ui.text(cx, "Console probe target", .{
        .font_size = ui.arb.px(22),
        .font_weight = 600,
        .color = cx.tokens.color.fg_primary,
    })});
}

fn mountDevTools(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    return ui.devtools.mountPanel(cx, g_target_cx orelse return error.TargetMissing, .{
        .title = "Console Probe DevTools",
    });
}

fn workerLog(console: *ui.console.Console) void {
    const log = console.scoped("worker");
    for (0..24) |i| log.debug("worker-event-{d}", .{i});
}

fn runSmoke(application: *MultiWindowApp, target: *zenit_app.App, devtools: *zenit_app.App, frames: u64) !void {
    if (!ui.devtools.setViewMode(devtools.cx, "console")) return error.ConsoleModeUnavailable;

    target.cx.console().writeAt(.err, @src(), "needle-error-{d}", .{42});

    var worker = try std.Thread.spawn(.{}, workerLog, .{target.cx.console()});
    worker.join();

    const target_before = target.renderer.frame_count;
    const dev_before = devtools.renderer.frame_count;
    for (0..@max(frames, 12)) |_| _ = try application.tick();
    if (!ui.devtools.refreshConsole(devtools.cx)) return error.ConsoleRefreshFailed;
    if (!ui.devtools.consoleContainsText(devtools.cx, "captured-before-panel-mount")) return error.HistoryMissing;
    if (!ui.devtools.consoleContainsText(devtools.cx, "needle-error-42")) return error.ErrorMissing;
    if (!ui.devtools.consoleContainsText(devtools.cx, "worker-event-23")) return error.WorkerLogMissing;
    if (ui.devtools.consoleVisibleEventCount(devtools.cx) < 26) return error.EventCountTooSmall;

    // Console writes must not dirty the target. DevTools has its own polling
    // chain and must keep rendering while the target remains idle.
    if (target.renderer.frame_count != target_before) return error.ConsoleDirtiedTarget;
    if (devtools.renderer.frame_count <= dev_before) return error.DevToolsDidNotPoll;

    if (!ui.devtools.setConsoleFilter(devtools.cx, "needle-error")) return error.FilterFailed;
    if (ui.devtools.consoleVisibleEventCount(devtools.cx) != 1) return error.FilterCountWrong;
    if (!ui.devtools.setConsoleFilter(devtools.cx, "")) return error.FilterResetFailed;

    target.cx.console().clear();
    for (0..4) |_| _ = try application.tick();
    _ = ui.devtools.refreshConsole(devtools.cx);
    if (ui.devtools.consoleVisibleEventCount(devtools.cx) != 0) return error.ClearFailed;
    target.cx.console().warn("after-clear", .{});
    for (0..4) |_| _ = try application.tick();
    _ = ui.devtools.refreshConsole(devtools.cx);
    if (!ui.devtools.consoleContainsText(devtools.cx, "after-clear")) return error.PostClearLogMissing;

    std.log.info("[console_probe] history + worker + idle-poll + filter + clear: ok", .{});
    std.log.info("[console_probe] smoke ok target_frames={d} devtools_frames={d}", .{
        target.renderer.frame_count,
        devtools.renderer.frame_count,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const smoke_frames: ?u64 = blk: {
        const raw = std.posix.getenv("ZENIT_SMOKE_FRAMES") orelse break :blk null;
        break :blk std.fmt.parseInt(u64, raw, 10) catch null;
    };

    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 16 });
    defer application.deinit();
    const frame_pacing: zenit_app.runtime.FramePacing = if (smoke_frames != null) .poll else .display_link;

    const target = try application.createWindowWith(.{
        .window = .{ .width = 620, .height = 420, .title = "Console Target" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = true,
    }, mountTarget);
    g_target_cx = target.cx;
    // Prove capture starts before DevTools exists.
    target.cx.console().info("captured-before-panel-mount", .{});
    target.cx.console().scoped("router").debug("matched /projects/:id", .{});
    target.cx.console().scoped("network").info("GET /api/projects -> 200 (42ms)", .{});
    target.cx.console().scoped("network").warn("retrying websocket in 800ms", .{});
    target.cx.console().writeAt(.err, @src(), "save failed: PermissionDenied", .{});

    const devtools = try application.createWindowWith(.{
        .window = .{ .width = 940, .height = 620, .title = "Console DevTools" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = true,
    }, mountDevTools);

    // Settle the initial forced frame before measuring target idle behavior.
    for (0..4) |_| _ = try application.tick();
    if (smoke_frames) |frames| {
        try runSmoke(&application, target, devtools, frames);
        return;
    }
    try application.run();
}
