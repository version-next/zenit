/// interop_probe —— 富剪贴板 + 文件拖出的真机验证探针（脚本驱动，非产品 demo）。
///
/// 与 e2e 注入不同，本探针验证的是**真系统路径**：
///   - 启动时先读系统剪贴板 HTML（外部脚本预置）→ 验证 get 路径；
///   - 随后写入 text+HTML 富剪贴板 → 外部脚本读回验证 set 路径；
///   - 窗口任意处 mouse_down → beginDrag(file_url) 起一次真 AppKit 拖拽
///     会话 → 由 scripts/verify_interop_probe.sh 用 CGEvent 拖到 Finder，
///     以目标目录出现文件为判据。
///
/// 判据全部走 stdout 的 `[PROBE]` 行 + 外部系统状态，脚本 grep。
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

var g_app: *App = undefined;
var g_drag_started: bool = false;

fn onProbeEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
    _ = context;
    switch (event) {
        .mouse_down => |e| {
            // 只有窗口**左半边**是拖拽源区：右半边留给普通点击（聚焦/激活），
            // 否则 verify_menu.sh 的聚焦点击会开出一个空拖拽会话把后续
            // 键盘事件全部吃掉（实锤：Cmd+P 永远到不了事件循环）。
            if (e.x >= 200) return .ignored;
            // 必须在 mousedown 里**立刻**起拖（AppKit 要求当前事件是拖拽源事件；
            // 见 scripts/verify_real_drag.sh 的实测经验）。
            if (g_drag_started) return .ignored;
            g_drag_started = true;
            const token = g_app.sdk.beginDrag(g_app.windowId(), .{
                .payload_kind = .file_url,
                .payload = "/tmp/zenit-dragout/payload.txt",
                .allowed_operations = .{ .copy = true },
            }) catch |err| {
                std.debug.print("[PROBE] beginDrag failed: {}\n", .{err});
                return .ignored;
            };
            std.debug.print("[PROBE] beginDrag ok token={d}\n", .{token});
            return .handled;
        },
        else => {},
    }
    return .ignored;
}

fn onProbeAction(action: ui.actions.Action, context: ?*anyopaque) ui.events.EventResult {
    _ = context;
    std.debug.print("[PROBE] action {s}\n", .{action.name});
    return .handled;
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .background = cx.tokens.color.bg_primary,
    }, .{});
    root.behavior.events.on_event = onProbeEvent;
    root.behavior.events.event_context = root; // 非 null 即可，handler 不用它
    // 原生菜单验收：menu_command → ActionDispatcher → 此 handler 打印
    root.behavior.interaction.key_context = "probe";
    root.behavior.events.on_action = onProbeAction;
    cx.bindCommandAction(100, .{ .context = "probe", .name = "ping" });
    return root;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try App.init(allocator, .{
        .window = .{ .width = 400, .height = 300, .title = "zenit interop probe" },
    });
    defer app.deinit();
    g_app = app;

    // ---- 剪贴板 get 路径：读外部脚本预置的 HTML ----
    if (app.sdk.clipboardGetHtmlAlloc(allocator) catch null) |html| {
        defer allocator.free(html);
        std.debug.print("[PROBE] read-html: {s}\n", .{html});
    } else {
        std.debug.print("[PROBE] read-html: <none>\n", .{});
    }

    // ---- 剪贴板 set 路径：写 text+HTML 双 representation ----
    if (app.sdk.clipboardSetRichText(.{
        .text = "zenit-probe-plain",
        .html = "<b>zenit-probe-html</b>",
    })) |_| {
        std.debug.print("[PROBE] rich-set-ok\n", .{});
    } else |e| {
        std.debug.print("[PROBE] rich-set failed: {}\n", .{e});
    }

    // ---- 原生菜单：真 AppKit 菜单栏点击 / Cmd+P 快捷键验收目标 ----
    // 注意：AppKit 把主菜单第一个顶级项渲染为应用菜单（强制改名为 app 名），
    // 所以自定义菜单前必须有一个占位 app 菜单，否则第一个菜单被吃掉。
    app.setMenuModel(.{ .nodes = &.{
        .{ .id = 1, .kind = .menu, .label = "App" },
        .{ .id = 2, .kind = .menu, .label = "Probe" },
        .{ .id = 3, .parent_id = 2, .kind = .item, .label = "Ping", .key_equivalent = "p", .modifiers = .{ .super = true }, .command_id = 100 },
    } }) catch |e| std.debug.print("[PROBE] menu-set failed: {}\n", .{e});

    try app.runWith(mountUI);
}
