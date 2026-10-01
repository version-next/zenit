/// devtools_probe, DevTools Performance 面板的真窗口验收探针
///
/// 两个原生窗口：target（可被强制驱动/停帧）+ DevTools panel（mountPanel，
/// 切到 Performance 页）。`ZENIT_SMOKE_FRAMES=N` 下按阶段断言：
///
///   Phase A（active）：每 tick 强制 target 重绘,
///     a) target 帧间隔历史被回填（frame_perf.interval 非空）；
///     b) DevTools FPS 文本离开 mount 初值（"FPS: {n}" 滚动均值且非 0）；
///     c) DevTools 窗口自身持续渲染（保活链没断，历史 bug：target 活跃时
///        DevTools 不调度下一次 poll，面板只有鼠标划过才动）。
///
///   Phase B（idle）：停止驱动 target ≥1.3s,
///     d) target 真停帧（renderer.frame_count 基本不动）；
///     e) DevTools 仍在自轮询渲染（frame_count 继续推进）；
///     f) FPS 文本出现 idle 标注（区分「没在渲染」与「稳定高帧率」）。
///
/// 无 ZENIT_SMOKE_FRAMES 时作为普通 demo 常驻运行，供人工目检。
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
const MultiWindowApp = zenit_app.MultiWindowApp;

const Padding = ui.Padding;

var g_target_cx: ?*ui.Cx = null;

fn mountTarget(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .gap = 12,
        .padding = Padding.all(32),
        .background = cx.tokens.color.bg_primary,
        .align_items = .center,
        .justify = .center,
    }, .{});
    try root.appendChild(cx.allocator, try ui.text(cx, "devtools probe target", .{
        .font_size = ui.arb.px(20),
        .font_weight = 600,
        .color = cx.tokens.color.fg_primary,
    }));
    try root.appendChild(cx.allocator, try ui.text(cx, "smoke 模式下由驱动线程强制重绘/停帧", .{
        .font_size = ui.arb.px(12),
        .color = cx.tokens.color.fg_secondary,
    }));
    return root;
}

fn mountDevtools(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    const target = g_target_cx orelse return error.TargetNotReady;
    return ui.devtools.mountPanel(cx, target, .{ .title = "Probe DevTools" });
}

fn findByTestId(node: *ui.Node, test_id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |tid| {
        if (std.mem.eql(u8, tid, test_id)) return node;
    }
    for (node.children.items) |child| {
        if (findByTestId(child, test_id)) |found| return found;
    }
    return null;
}

fn fpsText(dev_cx: *ui.Cx) ?[]const u8 {
    const root = dev_cx.root orelse return null;
    const node = findByTestId(root, "devtools.perf.fps") orelse return null;
    const tp = node.getText() orelse return null;
    return tp.content;
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

    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 16 });
    defer application.deinit();

    // idle 停帧必须开着：Phase B 验的就是「target 停帧后 DevTools 仍自轮询」。
    const app_target = try application.createWindowWith(.{
        .window = .{ .width = 480, .height = 320, .title = "probe target" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = true,
    }, mountTarget);
    g_target_cx = app_target.cx;

    const app_dev = try application.createWindowWith(.{
        .window = .{ .width = 760, .height = 560, .title = "Probe DevTools" },
        .frame_pacing = frame_pacing,
        .idle_skip_frames = true,
    }, mountDevtools);

    if (!ui.devtools.setViewMode(app_dev.cx, "performance")) {
        std.log.err("[devtools_probe] setViewMode(performance) 失败", .{});
        return error.SetViewModeFailed;
    }

    if (smoke_frames) |limit| {
        // ── Phase A: target 活跃 ──
        for (0..@max(limit, 60)) |_| {
            app_target.cx.needs_redraw = true;
            _ = try application.tick();
        }
        if (app_target.cx.frame_perf.interval.isEmpty() or (app_target.cx.frame_perf.interval.latest() orelse 0) == 0) {
            std.log.err("[devtools_probe] FAIL: 帧间隔历史未回填（数据链仍断）", .{});
            return error.FrameIntervalHistoryEmpty;
        }
        const fps_a = fpsText(app_dev.cx) orelse {
            std.log.err("[devtools_probe] FAIL: 找不到 devtools.perf.fps 节点", .{});
            return error.FpsNodeMissing;
        };
        if (!std.mem.startsWith(u8, fps_a, "FPS: ")) {
            std.log.err("[devtools_probe] FAIL: FPS 文本停在 mount 初值: '{s}'", .{fps_a});
            return error.FpsTextNeverUpdated;
        }
        if (std.mem.startsWith(u8, fps_a, "FPS: 0")) {
            std.log.err("[devtools_probe] FAIL: 活跃期 FPS 为 0: '{s}'", .{fps_a});
            return error.FpsStuckAtZero;
        }
        if (app_dev.renderer.frame_count < 3) {
            std.log.err("[devtools_probe] FAIL: DevTools 窗口活跃期几乎没渲染（保活断链） frames={d}", .{app_dev.renderer.frame_count});
            return error.DevtoolsStarvedWhileTargetActive;
        }
        std.log.info("[devtools_probe] phase-A ok: target_frames={d} dev_frames={d} fps='{s}'", .{
            app_target.renderer.frame_count, app_dev.renderer.frame_count, fps_a,
        });

        // ── Phase B: target 停帧 ──
        const target_frames_before = app_target.renderer.frame_count;
        const dev_frames_before = app_dev.renderer.frame_count;
        const idle_start = try std.time.Instant.now();
        while (true) {
            _ = try application.tick();
            const now = try std.time.Instant.now();
            if (now.since(idle_start) > 1_300_000_000) break;
        }
        // 允许极少量收尾帧（脏标记消费），但不能持续渲染。
        if (app_target.renderer.frame_count > target_frames_before + 5) {
            std.log.err("[devtools_probe] FAIL: target 未真正停帧 {d}→{d}", .{ target_frames_before, app_target.renderer.frame_count });
            return error.TargetNeverIdled;
        }
        if (app_dev.renderer.frame_count <= dev_frames_before + 2) {
            std.log.err("[devtools_probe] FAIL: target 停帧后 DevTools 保活失效 {d}→{d}", .{ dev_frames_before, app_dev.renderer.frame_count });
            return error.DevtoolsKeepaliveDead;
        }
        const fps_b = fpsText(app_dev.cx) orelse return error.FpsNodeMissing;
        if (std.mem.indexOf(u8, fps_b, "idle") == null) {
            std.log.err("[devtools_probe] FAIL: 停帧 >1.3s 后无 idle 标注: '{s}'", .{fps_b});
            return error.IdleIndicatorMissing;
        }
        // 滚动监控：停帧期间图表必须继续向前滚（当前 FPS 掉 0），
        // 而不是把活跃期快照冻在屏上。
        if (!std.mem.startsWith(u8, fps_b, "FPS: 0")) {
            std.log.err("[devtools_probe] FAIL: 停帧后当前 FPS 未掉 0（监控没在滚动）: '{s}'", .{fps_b});
            return error.MonitorNotRolling;
        }
        std.log.info("[devtools_probe] phase-B ok: target {d}→{d} dev {d}→{d} fps='{s}'", .{
            target_frames_before, app_target.renderer.frame_count,
            dev_frames_before,    app_dev.renderer.frame_count,
            fps_b,
        });
        std.log.info("[devtools_probe] smoke ok", .{});
        return;
    }

    try application.run();
}
