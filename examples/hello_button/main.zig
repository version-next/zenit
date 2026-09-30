/// hello_button — zenit 框架的最小可运行 demo
///
/// 一个原生 macOS 窗口 + 一个 Button + 一个计数器文本。
/// 点击 Button 计数 +1，文本响应式更新。
///
/// 用 zenit 的推荐 API：
///   - `App.runWith(mountUI)` 一行启动主循环
///   - `cx.bindState` / `cx.on` 不需要分配 u64 state id
///
/// 应用作者只需要写 mountUI —— 真正的"业务" UI 树构建。
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

/// 样式表：具名纯函数 + 应用层自定义 recipe，与业务逻辑分离。
const S = @import("styles.zig");

const Counter = struct {
    n: u32 = 0,
    label: ?*ui.Node = null,
    buf: [32]u8 = undefined,

    pub fn increment(self: *Counter) void {
        self.n += 1;
        const node = self.label orelse return;
        const content = std.fmt.bufPrint(&self.buf, "Clicked {d} times", .{self.n}) catch return;
        if (node.getText()) |old| {
            var t = old;
            t.content = content;
            node.setText(t);
        }
        node.markRenderDirty();
    }
};

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const allocator = cx.allocator;

    const counter = try cx.bindState(Counter, .{});
    const click = cx.on(Counter, counter, Counter.increment);

    const root = try ui.boxStyled(cx, S.root, .{});

    try root.appendChild(allocator, try ui.textStyled(cx, S.title, "Hello, zenit!"));

    try root.appendChild(allocator, try ui.widgets.Button(.{
        .label = "Click me",
        .variant = .primary,
        .size = .md,
        .on_click = click,
    }).mount(scope, cx));

    // 应用层自定义 recipe（styles.zig 的 PanelRecipe）包住计数文本
    const panel = try ui.boxStyled(cx, S.panel(.highlight), .{});
    const label = try ui.textStyled(cx, S.counterLabel, "Clicked 0 times");
    try panel.appendChild(allocator, label);
    try root.appendChild(allocator, panel);
    counter.label = label;

    return root;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .window = .{ .width = 640, .height = 480, .title = "Hello Button" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
