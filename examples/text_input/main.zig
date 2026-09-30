/// text_input — 演示 ui.widgets.Input 和 ui.widgets.Textarea
///
/// 关键点：这两个组件是 zenit 里**唯一**依赖 text_core 的组件
/// （DocCursor / WrapMap / LineCol —— 见 src/ui/components/input/）。
///
/// 这个 demo 同时也是开源边界 text_core 子图的烟测：
/// 如果哪天 Input/Textarea 意外引入框架边界外的依赖，
/// 这个 example 会和 hello_button/counter_reactive/virtual_list_perf 一起编译失败。
///
/// IME（中日韩输入法）支持：试着切到中文输入法打几个字，
/// 系统会通过 system_sdk 的 ime_preedit/ime_commit 事件直达 ui.Cx。
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

const Padding = ui.Padding;

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const allocator = cx.allocator;

    const root = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .column,
        .gap = 16,
        .padding = Padding.all(32),
        .background = ui.theme.light.color.bg_primary,
    }, .{});

    try root.appendChild(allocator, try ui.text(cx, "Text Input Demo", .{
        .font_size = 22,
        .font_weight = 600,
        .color = ui.theme.light.color.fg_primary,
    }));

    try root.appendChild(allocator, try ui.text(cx, "Tab between fields. Try IME (中文/日本語/한국어) too.", .{
        .font_size = 13,
        .color = ui.theme.light.color.fg_secondary,
    }));

    const name_input = try ui.widgets.Input(.{
        .label_text = "Name",
        .placeholder = "Your name",
        .width = 320,
    }).mount(scope, cx);
    name_input.meta.ownership.meta.test_id = "input.name";
    try root.appendChild(allocator, name_input);

    const email_input = try ui.widgets.Input(.{
        .label_text = "Email",
        .placeholder = "you@example.com",
        .input_type = .email,
        .width = 320,
    }).mount(scope, cx);
    email_input.meta.ownership.meta.test_id = "input.email";
    try root.appendChild(allocator, email_input);

    const pwd_input = try ui.widgets.Input(.{
        .label_text = "Password",
        .placeholder = "••••••••",
        .input_type = .password,
        .width = 320,
    }).mount(scope, cx);
    pwd_input.meta.ownership.meta.test_id = "input.password";
    try root.appendChild(allocator, pwd_input);

    const note_area = try ui.widgets.Textarea(.{
        .label_text = "Notes",
        .placeholder = "Anything you want to remember…",
        .rows = 6,
        .width = 480,
    }).mount(scope, cx);
    note_area.meta.ownership.meta.test_id = "input.notes";
    try root.appendChild(allocator, note_area);

    return root;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .window = .{ .width = 600, .height = 540, .title = "Text Input Demo" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
