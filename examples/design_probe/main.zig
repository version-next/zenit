/// design_probe —— pencil 视觉稿还原的验证靶场。
///
/// 用途：把一个 pencil 节点的精确数值翻译成 zenit 代码，渲染出来，
/// 再用 `bun e2e/design_diff.ts` 与设计稿导出图做数值化比对。
///
/// 这里复刻的是 zboard 白板 app 的 `Layer Row` 组件（pencil id `exzZc`），
/// 全部数值直接来自 pencil 的结构化读取，没有一个是肉眼估的：
///
///   frame  width:220 height:24 cornerRadius:4 gap:6 padding:[0,6,0,8]
///          alignItems:center fill:#FFFFFF00
///     icon Disclosure  10x10 lucide/chevron-down  #92929B
///     icon Type Icon   13x13 lucide/square-dashed #92929B
///     text Label       Inter 12 normal            #17171B
///     frame Spacer     width:fill_container height:1
///     frame Rail       48x12 layout:none
///       (三个 12x12 图标 x=0/18/36，enabled:false → 不渲染)
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;

/// 设计稿背景是透明的（#FFFFFF00），导出 PNG 会落在白底上。
/// 比对时两边都要是白底，否则 RMSE 会被背景差淹没。
/// 用 ui.arb 显式标记「有意的任意值」——这是对齐视觉稿的合法逃生舱，
/// 而不是该迁 token 的偷懒字面量（见 scripts/check_style_literals.sh）。
const canvas_bg = ui.arb.hex(0xFFFFFF);

fn layerRow(cx: *ui.Cx) !*ui.Node {
    const row = try ui.box(cx, .{
        .width = .fixed(220),
        .height = .fixed(24),
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .top = 0, .right = 6, .bottom = 0, .left = 8 },
        .border = .{ .radius = 4, .width = 0, .color = ui.arb.hexA(0x000000, 0) },
    }, .{});

    const disclosure = try ui.iconTint(cx, ui.icons.chevron_down, ui.arb.hex(0x92929B), .{
        .width = .fixed(10),
        .height = .fixed(10),
    });
    try row.appendChild(cx.allocator, disclosure);

    const type_icon = try ui.iconTint(cx, ui.icons.square_dashed, ui.arb.hex(0x92929B), .{
        .width = .fixed(13),
        .height = .fixed(13),
    });
    try row.appendChild(cx.allocator, type_icon);

    const label = try ui.text(cx, "Layer", .{
        .color = ui.arb.hex(0x17171B),
        .font_size = ui.arb.px(12),
        .font_weight = 400,
    });
    try row.appendChild(cx.allocator, label);

    // Spacer: width fill_container → .grow
    const spacer = try ui.box(cx, .{
        .width = .fill(),
        .height = .fixed(1),
    }, .{});
    try row.appendChild(cx.allocator, spacer);

    // Rail: 三个图标都是 enabled:false，设计稿里不可见 —— 保留占位尺寸即可。
    const rail = try ui.box(cx, .{
        .width = .fixed(48),
        .height = .fixed(12),
    }, .{});
    try row.appendChild(cx.allocator, rail);

    return row;
}

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    // 外层容器只负责给一个干净白底 + 把组件放在 (0,0) 起点，
    // 让截图裁剪与设计稿导出对齐。
    const root = try ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .background = canvas_bg,
        .direction = .column,
        .align_items = .start,
    }, .{});

    const row = try layerRow(cx);
    row.meta.ownership.meta.test_id = "probe.layer_row";
    try root.appendChild(cx.allocator, row);
    return root;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // 窗口尺寸 = 设计稿节点尺寸，这样截图无需裁剪就能与导出图对齐。
    const app = try App.init(gpa.allocator(), .{
        .window = .{ .width = 220, .height = 24, .title = "design probe" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}
