/// virtual_list_perf — 演示 ui.widgets.VirtualList 渲染 100k 行
///
/// 关键观感（在 Apple Silicon 上）：
///   - 无论列表大小（10、10k、100k、1M），渲染开销基本不变
///   - 滚动 60fps，无掉帧
///   - cold open 不会卡顿（VirtualList 只构造 viewport + overscan 行数 ~50 个 Node）
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

const Padding = ui.Padding;

const ITEM_COUNT: usize = 100_000;
const ITEM_HEIGHT: f32 = 32;
const PALETTE = [_]ui.Color{
    ui.Color.rgb(242, 242, 247),
    ui.Color.WHITE,
};

fn renderItem(node: *ui.Node, index: usize, cx: *ui.Cx) void {
    node.setBackgroundRaw(PALETTE[index % 2]);
    node.style.padding = Padding.symmetric(8, 16);
    node.style.direction = .row;
    node.style.align_items = .center;
    node.style.gap = 12;

    // ui.text builder 自己 dupe content (≤16 bytes 走 inline_buf；否则 cx.allocator
    // dupe + Node.destroy 时 free)，caller 不必再 dupe。stack buffer 直接传入。
    var idx_buf: [32]u8 = undefined;
    const idx_text = std.fmt.bufPrint(&idx_buf, "#{d}", .{index}) catch "?";
    const idx_node = ui.text(cx, idx_text, .{
        .font_size = 12,
        .font_weight = 500,
        .color = ui.theme.light.color.fg_secondary,
    }) catch return;
    idx_node.style.width = .{ .px = 70 };
    node.appendChild(cx.allocator, idx_node) catch return;

    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Item {d} — Lorem ipsum dolor sit amet", .{index}) catch "?";
    const title_node = ui.text(cx, title, .{
        .font_size = 14,
        .color = ui.theme.light.color.fg_primary,
    }) catch return;
    node.appendChild(cx.allocator, title_node) catch return;
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const allocator = cx.allocator;

    const root = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .column,
        .background = ui.theme.light.color.bg_primary,
    }, .{});

    const header = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 48 },
        .padding = Padding.symmetric(0, 20),
        .direction = .row,
        .align_items = .center,
        .background = ui.theme.light.color.bg_secondary,
    }, .{});
    var hdr_buf: [64]u8 = undefined;
    const hdr_text = try std.fmt.bufPrint(&hdr_buf, "{d:.0}k items rendered through ui.widgets.VirtualList", .{
        @as(f32, @floatFromInt(ITEM_COUNT)) / 1000,
    });
    try header.appendChild(allocator, try ui.text(cx, hdr_text, .{
        .font_size = 14,
        .font_weight = 600,
        .color = ui.theme.light.color.fg_primary,
    }));
    try root.appendChild(allocator, header);

    const list = try ui.widgets.VirtualList(.{
        .item_count = ITEM_COUNT,
        .item_height = ITEM_HEIGHT,
        .overscan = 5,
    }).mount(scope, cx, renderItem);

    list.container.style.width = .{ .grow = .{} };
    list.container.style.height = .{ .grow = .{} };
    try root.appendChild(allocator, list.container);

    return root;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .window = .{ .width = 720, .height = 600, .title = "100k Virtual List" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
