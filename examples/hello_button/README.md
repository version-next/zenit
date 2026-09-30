# hello_button — zenit 最小 demo

一个原生 macOS 窗口 + 一个 Button + 一个计数器。点击 Button 计数 +1。

```
┌──────────────────────────┐
│                          │
│    Hello, zenit!      │
│                          │
│      [ Click me ]        │
│                          │
│    Clicked 3 times       │
│                          │
└──────────────────────────┘
```

## 跑起来

```bash
zig build hello-button       # 构建并打 .app bundle（带 ad-hoc codesign）
zig build run-hello-button   # 直接跑（不打 bundle）
open "zig-out/Hello Button.app"
```

## 完整代码

`main.zig` 一共 **81 行**。`main()` 只有 8 行，再加上一个 `mountUI(cx, scope) -> *Node` 回调：

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .window = .{ .width = 640, .height = 480, .title = "Hello Button" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
```

`App.init` 一行做完：
- NSApplication 初始化 + 主菜单
- 窗口创建
- GPU instance / device / queue / surface
- AppRenderer + FontManager + 默认字体加载（Helvetica Neue / Arial / Inter / Menlo fallback 链）
- SystemSdk
- UI Cx + 视口设置 + measure_fn 接线

`app.runWith(mountUI)` 一行做完：
- 创建 root reactive Scope 并绑定到 cx
- 调用你的 `mountUI(cx, scope)` 构建 UI 树
- 设置 `cx.root` / `cx.is_mounted`
- 跑主循环（事件 pump + dispatch + resize 检测 + 每帧渲染）直到窗口关闭

State / 事件 handler 推荐用 `cx.bindState` + `cx.on`，不需要分配 u64 id：

```zig
const counter = try cx.bindState(Counter, .{});
const click = cx.on(Counter, counter, Counter.increment);
```

## 构建依赖

`hello_button` 的 `build.zig` 只 import 2 个 module：

```zig
hello_mod.addImport("ui", ui_module);
hello_mod.addImport("zenit_app", app_module);
```

`zenit_app` 内部 transitively 拉 `system_sdk` + `render` + `gpu` + `platform` + `text` + `text_core` + `icon_ir` + `trace` —— 但**绝不会**拉任何语言工具链、编辑器内核或工作区状态层。这就是 zenit 的开源边界。

可以这样验证：

```bash
zig build hello-button --verbose 2>&1 | grep -oE '\-M[a-z_]+=' | sort -u
```

输出应只有：gpu, icon_ir, platform, render, root, system_sdk, text, text_core, trace, ui, zenit_app — 11 项。没有别的。

## 二进制大小

`hello_button.app`: **5.5 MB**。

包含完整的窗口、布局引擎、Metal 渲染、字体回退链、IME 处理。没有语言工具链、没有编辑器内核 —— 这就是开源边界的实际价值。

## 进阶用法

多窗口应用优先使用公开的 `MultiWindowApp`。如果你需要为 devtools、热重载或自定义宿主绕过 `App.runWith()` 自己控制单窗主循环，`App` 的字段都是 `pub`，可以分步调：

```zig
var app = try App.init(allocator, .{ ... });
defer app.deinit();

try app.mount(mountUI); // 只 mount 不跑主循环

while (custom_condition) {
    _ = try app.sdk.pump(16);
    app.processEvents();
    if (app.should_quit) break;
    try app.maybeReconfigureSurface();
    try app.frame();
}
```

`MultiWindowApp` 统一持有各窗口的 `App`，并处理全局 AppKit 事件、按窗口路由与安全析构；只有需要完全自定义宿主循环的应用才应手动 pump 多个底层对象。

## 架构层次

```
应用代码（你写的）
       │
       ▼
┌─────────────────────────────────────┐
│ app   — App 一站式运行时 helper      │
│        AppRenderer 渲染胶水          │
└──┬──────────────────────────────────┘
   │
   │ uses
   ▼
┌─────┬─────────────┬───────────┬──────────┬────────┐
│ ui  │ system_sdk  │ render    │ gpu      │ text   │
│     │             │           │          │        │
└──┬──┴─────────────┴───────────┴──────────┴────────┘
   │
   │ uses
   ▼
┌──────────────┬────────────┐
│ text_core    │ icon_ir    │
│              │            │
└──────────────┴────────────┘

(没出现在这张图里的：语言工具链、编辑器内核、工作区状态层 —— 都属于应用层，不进 zenit)
```
