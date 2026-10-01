/// counter_reactive，演示 zenit 的响应式系统
///
/// 与 hello_button 不同：
///   - hello_button 用命令式更新（手改 text + markRenderDirty）。
///   - counter_reactive 用 Signal + Memo + textFmt，
///     "声明数据流，框架自动同步 UI"。
///
/// 三个 Signal-driven 的 UI 元素：
///   - 主计数 Signal(u32)，点击 +1
///   - 派生 Memo(u32)，主计数 × 2，自动跟随
///   - "Reset" Button，把 Signal 拨回 0
///
/// 动态文本用 `ui.textFmt(cx, scope, fmt, .{signals...}, props)` 一行声明：
/// 框架内部创建 effect,任一源变化即重新格式化并重绘。
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

/// 样式表：具名纯函数（fn(tokens) -> BoxStyle/TextStyle），与下面的业务逻辑分离。
const S = @import("styles.zig");

const Bindings = struct {
    count: *ui.Signal(u32),

    fn onIncrement(b: *Bindings) void {
        b.count.set(b.count.get() + 1);
    }

    fn onReset(b: *Bindings) void {
        b.count.set(0);
    }
};

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const allocator = cx.allocator;

    const count = try scope.createSignal(u32, 0);
    const doubled = try scope.createMemo(u32, .{ .count = count }, struct {
        fn compute(ctx: anytype) u32 {
            return ctx.count.get() * 2;
        }
    }.compute);

    // boxStyled/textStyled：样式来自 styles.zig 的具名函数，setTheme 自动重放
    const root = try ui.boxStyled(cx, S.root, .{});

    try root.appendChild(allocator, try ui.textStyled(cx, S.title, "Reactive Counter"));

    // textFmt 的内容是响应式的；样式取 mount 时的 token 快照
    try root.appendChild(allocator, try ui.textFmt(cx, scope, "count = {d}", .{count}, S.counterText(cx.tokens)));

    try root.appendChild(allocator, try ui.textFmt(cx, scope, "doubled = {d}", .{doubled}, S.derivedText(cx.tokens)));

    const bindings = try cx.bindState(Bindings, .{ .count = count });
    const inc_handler = cx.on(Bindings, bindings, Bindings.onIncrement);
    const reset_handler = cx.on(Bindings, bindings, Bindings.onReset);

    const button_row = try ui.hstackStyled(cx, S.buttonRow, .{});
    try button_row.appendChild(allocator, try ui.widgets.Button(.{
        .label = "+1",
        .variant = .primary,
        .on_click = inc_handler,
    }).mount(scope, cx));
    try button_row.appendChild(allocator, try ui.widgets.Button(.{
        .label = "Reset",
        .variant = .secondary,
        .on_click = reset_handler,
    }).mount(scope, cx));
    try root.appendChild(allocator, button_row);

    return root;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .window = .{ .width = 480, .height = 360, .title = "Reactive Counter" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
