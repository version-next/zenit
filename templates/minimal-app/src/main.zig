//! Minimal zenit app, counter button.
//!
//! Demonstrates the recommended flow:
//!   - `App.runWith(mountUI)`, one call replaces ~110 lines of boilerplate
//!   - `cx.bindState`, no manual u64 ids
//!   - `cx.on(T, state, T.method)`, type-safe handler binding
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

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

    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .column,
        .gap = 16,
        .padding = ui.Padding.all(40),
        .background = cx.tokens.color.bg_primary,
        .align_items = .center,
        .justify = .center,
    }, .{});

    try root.appendChild(allocator, try ui.text(cx, "Hello, zenit!", .{
        .font_size = 24,
        .font_weight = 600,
        .color = cx.tokens.color.fg_primary,
    }));

    const button = try ui.widgets.Button(.{
        .label = "Click me",
        .variant = .primary,
        .on_click = click,
    }).mount(scope, cx);
    button.meta.ownership.meta.test_id = "counter.increment";
    try root.appendChild(allocator, button);

    const label = try ui.text(cx, "Clicked 0 times", .{
        .font_size = 14,
        .color = cx.tokens.color.fg_secondary,
    });
    try root.appendChild(allocator, label);
    counter.label = label;

    return root;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .window = .{ .width = 640, .height = 480, .title = "Hello, zenit" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
