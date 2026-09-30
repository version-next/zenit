/// App 模块 — 应用层封装
///
/// 提供从 UI 声明到屏幕显示的完整管线。
const renderer_mod = @import("renderer.zig");
pub const AppRenderer = renderer_mod.AppRenderer;
pub const ClearColor = renderer_mod.ClearColor;
pub const FrameStats = renderer_mod.FrameStats;

pub const ResourcePath = @import("resource_path.zig").ResourcePath;

/// 一站式应用运行时 — 见 runtime.zig
pub const runtime = @import("runtime.zig");

/// E2E test harness 转发口（`-Dtest-mode=true` 时有效，否则整体编译期消除）。
///
/// `runtime.App.run()` 会自己每帧调 `drainTestCommands()`；**自建主循环**的
/// 宿主（下游应用等）必须在自己的循环里调它一次，否则 file-RPC 服务器收得到
/// 请求却永远不执行、不写响应，客户端表现为全部超时。
pub const test_harness = @import("test_harness");

/// 每帧消费一次 E2E 命令队列。自建主循环的宿主在 `processEvents()` 后调用。
pub fn drainTestCommands() void {
    test_harness.drainCommands();
}

/// 注册宿主自定义 E2E 路由。见 `test_harness.setAppRouteHandler`。
pub fn setTestRouteHandler(f: test_harness.AppRouteFn) void {
    test_harness.setAppRouteHandler(f);
}
/// 进程级字体族注册表(id ↔ 族名 + face 缓存)。宿主建一个、
/// `App.setFontRegistry` 装上,画布/UI 才能按族渲染。
/// 从 zenit_app 导出而不是 ui:ui 层不依赖 render(会造成层级倒置)。
pub const FontRegistry = @import("render").FontRegistry;
pub const FamilyId = @import("render").FamilyId;

pub const App = runtime.App;
pub const MultiWindowApp = runtime.MultiWindowApp;
pub const Application = runtime.MultiWindowApp;
pub const AppWindow = runtime.App;
pub const MultiWindowConfig = runtime.MultiWindowConfig;
pub const WindowConfig = runtime.WindowConfig;
pub const FontConfig = runtime.FontConfig;
pub const window_lifecycle = @import("window_lifecycle.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
