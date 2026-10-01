/// multi_window，两个真原生窗口并存的 demo（多窗口交付验证）
///
/// 验证点：
///   - `MultiWindowApp` 管理两个窗口（各自 Window/GPU surface/SystemSdk/Cx）
///   - Cx.init 并发守卫已拆：第二个 Cx.init 不 panic
///   - 事件按 window 路由：各窗口的按钮各自计数，互不串扰
///   - 文本测量 per-App context：两窗口字体独立测量
///   - a11y C ABI 按 window_id 路由（初始化即注册，不互相覆盖）
///   - 关闭 A 后 B 继续泵事件/渲染；关闭最后一个窗口才退出
///
/// 主循环由公开 `MultiWindowApp.run()` 驱动：第一个窗口的 pump 可阻塞，
/// 其余窗口非阻塞 drain，事件与菜单命令按原生 window_id 路由。
///
/// 冒烟验证：ZENIT_SMOKE_FRAMES=N 跑 N 帧后自动退出（exit 0），供脚本/CI 断言
/// 「两个窗口都真正渲染过」而无需人工关窗。
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
const MultiWindowApp = zenit_app.MultiWindowApp;

const Padding = ui.Padding;

const Counter = struct {
    n: u32 = 0,
    label: ?*ui.Node = null,
    buf: [64]u8 = undefined,
    tag: []const u8 = "?",

    pub fn increment(self: *Counter) void {
        self.n += 1;
        const node = self.label orelse return;
        const content = std.fmt.bufPrint(&self.buf, "[{s}] clicked {d} times", .{ self.tag, self.n }) catch return;
        if (node.getText()) |old| {
            var t = old;
            t.content = content;
            node.setText(t);
        }
        node.markRenderDirty();
    }
};

fn buildWindowUi(cx: *ui.Cx, scope: *ui.Scope, comptime tag: []const u8, comptime heading: []const u8) !*ui.Node {
    const allocator = cx.allocator;

    const counter = try cx.bindState(Counter, .{ .tag = tag });
    const click = cx.on(Counter, counter, Counter.increment);
    _ = scope;

    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .gap = 16,
        .padding = Padding.all(40),
        .background = cx.tokens.color.bg_primary,
        .align_items = .center,
        .justify = .center,
    }, .{});

    try root.appendChild(allocator, try ui.text(cx, heading, .{
        .font_size = 24,
        .font_weight = 600,
        .color = cx.tokens.color.fg_primary,
    }));

    try root.appendChild(allocator, try ui.widgets.Button(.{
        .label = "Click me (" ++ tag ++ ")",
        .variant = .primary,
        .on_click = click,
    }).mount(cx.root_scope.?, cx));

    const label = try ui.text(cx, "[" ++ tag ++ "] clicked 0 times", .{
        .font_size = 14,
        .color = cx.tokens.color.fg_secondary,
    });
    counter.label = label;
    try root.appendChild(allocator, label);

    return root;
}

fn mountWindowA(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return buildWindowUi(cx, scope, "A", "zenit multi-window: A");
}

fn mountWindowB(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return buildWindowUi(cx, scope, "B", "zenit multi-window: B");
}

fn verifyApplicationQuitContract(allocator: std.mem.Allocator) !void {
    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 0 });
    defer application.deinit();

    // Exercise both public creation styles in the real native lifecycle.
    const app_a = try application.createWindow(.{
        .window = .{ .width = 420, .height = 300, .title = "zenit quit-contract A" },
        .frame_pacing = .poll,
        .idle_skip_frames = false,
    });
    try app_a.mount(mountWindowA);
    const app_b = try application.createWindowWith(.{
        .window = .{ .width = 420, .height = 300, .title = "zenit quit-contract B" },
        .frame_pacing = .poll,
        .idle_skip_frames = false,
    }, mountWindowB);

    if (!application.activateWindow(app_a.windowId()) or
        application.activeWindow() == null or
        application.activeWindow().?.windowId() != app_a.windowId())
        return error.ActivationFailed;
    if (!application.activateWindow(app_b.windowId()) or
        application.activeWindow() == null or
        application.activeWindow().?.windowId() != app_b.windowId())
        return error.ActivationFailed;

    _ = try application.tick();
    application.quit();
    try application.run();

    // Application-wide quit ends pumping. It deliberately leaves ownership in
    // place so the deferred manager deinit performs one ordered teardown pass.
    if (application.windowCount() != 2 or MultiWindowApp.nativeWindowCount() != 2)
        return error.QuitDestroyedWindowsEarly;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const smoke_frames: ?u64 = blk: {
        const v = std.posix.getenv("ZENIT_SMOKE_FRAMES") orelse break :blk null;
        break :blk std.fmt.parseInt(u64, v, 10) catch null;
    };
    const frame_pacing: zenit_app.runtime.FramePacing = if (smoke_frames != null) .poll else .display_link;
    const idle_skip_frames = smoke_frames == null;

    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 16 });
    defer application.deinit();

    const app_a = try application.createWindowWith(.{
        .window = .{ .width = 520, .height = 380, .title = "zenit A" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = idle_skip_frames,
    }, mountWindowA);

    const app_b = try application.createWindowWith(.{
        .window = .{ .width = 520, .height = 380, .title = "zenit B" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = idle_skip_frames,
    }, mountWindowB);

    std.log.info("[multi_window] two windows up: a11y window_id A={d} B={d}", .{
        app_a.cx.window_id, app_b.cx.window_id,
    });
    if (app_a.cx.window_id == app_b.cx.window_id) {
        std.log.err("[multi_window] window_id collision — a11y/system API 路由会互相覆盖", .{});
        return error.WindowIdCollision;
    }

    if (smoke_frames) |limit| {
        const a_id = app_a.windowId();
        const b_id = app_b.windowId();
        for (0..@max(limit, 1)) |_| _ = try application.tick();
        const a_frames = app_a.renderer.frame_count;
        const b_frames_before_close = app_b.renderer.frame_count;
        if (a_frames == 0 or b_frames_before_close == 0) return error.WindowDidNotRender;
        std.log.info("[multi_window] smoke ok: A={d} B={d} rendered", .{ a_frames, b_frames_before_close });

        // The pointer for A becomes invalid at this explicit teardown boundary.
        if (!application.closeWindow(a_id)) return error.CloseFailed;
        if (application.windowCount() != 1 or MultiWindowApp.nativeWindowCount() != 1 or application.window(a_id) != null or application.window(b_id) == null)
            return error.SingleWindowCloseFailed;
        for (0..@max(limit / 4, 1)) |_| _ = try application.tick();
        const b_live = application.window(b_id) orelse return error.SurvivorMissing;
        if (b_live.renderer.frame_count <= b_frames_before_close) return error.SurvivorDidNotRender;
        std.log.info("[multi_window] single-close ok: native=1 B continued to frame {d}", .{b_live.renderer.frame_count});

        if (!application.closeWindow(b_id)) return error.CloseFailed;
        if (application.windowCount() != 0 or MultiWindowApp.nativeWindowCount() != 0 or application.shouldContinue())
            return error.LastWindowDidNotExit;
        std.log.info("[multi_window] last-window exit ok: native=0", .{});

        try verifyApplicationQuitContract(allocator);
        if (MultiWindowApp.nativeWindowCount() != 0) return error.ApplicationQuitCleanupFailed;
        std.log.info("[multi_window] app-quit cleanup ok: create styles + activation + native=0", .{});
        return;
    }

    try application.run();
}
