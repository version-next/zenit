//! DevTools 的 Box Model 可视化 —— 从 devtools.zig 析出。
//!
//! 画 Inspector 里那张「margin / border / padding / content」同心矩形图。
//! 这一段是纯构建：只读 Node 的布局产物与主题 token，输出一棵展示用节点树，
//! 不碰 DevTools 的面板状态、选中项、tab 切换、事件分发 —— 它夹在 4800 行的
//! devtools.zig 里纯粹是历史堆积。
//!
//! 唯一入口是 `build`，由 Layout Tab 调用一次。

const std = @import("std");
const core = @import("../core.zig");

const Cx = core.Cx;
const Node = core.Node;
const Color = core.Color;
const theme = core.theme;
const Padding = core.Padding;

// ========== Box Model 可视化 ==========

pub const Colors = struct {
    margin_bg: Color,
    border_bg: Color,
    padding_bg: Color,
    content_bg: Color,
    label_fg: Color,
};

pub fn colors(t: *const theme.ThemeTokens) Colors {
    _ = t;
    return .{
        .margin_bg = Color.rgba(243, 171, 115, 50), // 橙色半透明
        .border_bg = Color.rgba(253, 221, 140, 60), // 黄色半透明
        .padding_bg = Color.rgba(147, 196, 125, 50), // 绿色半透明
        .content_bg = Color.rgba(130, 175, 220, 60), // 蓝色半透明
        .label_fg = Color.rgba(100, 100, 100, 255),
    };
}

/// Chrome DevTools 风格 Box Model 可视化
/// 这里按当前引擎语义直接画：
/// - `node.rect` = 节点整体 rect（外框）
/// - `content` = rect 减去 padding 后的内容区
/// - padding 四边按真实比例填充在 rect 与 content 之间
pub fn build(cx: *Cx, node: *Node, parent: *Node) !void {
    const t = cx.tokens;
    const c = colors(t);
    const alloc = cx.allocator;
    const p = node.style.padding;
    const rect = node.rectFromWorldOrFallback();
    const rect_w = @max(@as(f32, 0), rect.w);
    const rect_h = @max(@as(f32, 0), rect.h);
    const content_w = @max(@as(f32, 0), rect_w - p.left - p.right);
    const content_h = @max(@as(f32, 0), rect_h - p.top - p.bottom);

    const viz_w: f32 = 220;
    const viz_h: f32 = 150;
    const stage_pad: f32 = 12;
    const draw_w = viz_w - stage_pad * 2;
    const draw_h = viz_h - stage_pad * 2;
    const scale_x = if (rect_w > 0) draw_w / rect_w else 1;
    const scale_y = if (rect_h > 0) draw_h / rect_h else 1;
    const scale = @min(scale_x, scale_y);
    const outer_w = @max(@as(f32, 24), rect_w * scale);
    const outer_h = @max(@as(f32, 24), rect_h * scale);
    const outer_x = (viz_w - outer_w) * 0.5;
    const outer_y = (viz_h - outer_h) * 0.5;
    const content_x = outer_x + p.left * scale;
    const content_y = outer_y + p.top * scale;
    const content_w_s = @max(@as(f32, 0), outer_w - (p.left + p.right) * scale);
    const content_h_s = @max(@as(f32, 0), outer_h - (p.top + p.bottom) * scale);

    const wrapper = try core.box(cx, .{
        .direction = .column,
        .width = .{ .grow = .{} },
        .gap = 6,
        .padding = Padding.symmetric(6, 0),
    }, .{});

    const title = try label(cx, "Rect / Padding / Content", c.label_fg);
    try wrapper.appendChild(alloc, title);

    const stage = try core.box(cx, .{
        .position = .relative,
        .width = .{ .px = viz_w },
        .height = .{ .px = viz_h },
        .align_items = .start,
        .justify = .start,
        .background = Color.rgba(248, 248, 248, 255),
        .border = .{ .width = 1, .color = Color.rgba(220, 220, 220, 255), .radius = 6 },
    }, .{});

    const outer = try core.box(cx, .{
        .position = .absolute,
        .width = .{ .px = outer_w },
        .height = .{ .px = outer_h },
        .background = c.border_bg,
        .border = .{ .width = 1, .color = Color.rgba(224, 158, 37, 255) },
    }, .{});
    outer.setMargin(.{ .left = outer_x, .top = outer_y });
    try stage.appendChild(alloc, outer);

    if (p.top > 0) {
        const top_pad = try core.box(cx, .{
            .position = .absolute,
            .width = .{ .px = outer_w },
            .height = .{ .px = p.top * scale },
            .background = c.padding_bg,
        }, .{});
        top_pad.setMargin(.{ .left = outer_x, .top = outer_y });
        try stage.appendChild(alloc, top_pad);
    }
    if (p.bottom > 0) {
        const bottom_pad = try core.box(cx, .{
            .position = .absolute,
            .width = .{ .px = outer_w },
            .height = .{ .px = p.bottom * scale },
            .background = c.padding_bg,
        }, .{});
        bottom_pad.setMargin(.{ .left = outer_x, .top = outer_y + outer_h - p.bottom * scale });
        try stage.appendChild(alloc, bottom_pad);
    }
    if (p.left > 0 and content_h_s > 0) {
        const left_pad = try core.box(cx, .{
            .position = .absolute,
            .width = .{ .px = p.left * scale },
            .height = .{ .px = content_h_s },
            .background = c.padding_bg,
        }, .{});
        left_pad.setMargin(.{ .left = outer_x, .top = content_y });
        try stage.appendChild(alloc, left_pad);
    }
    if (p.right > 0 and content_h_s > 0) {
        const right_pad = try core.box(cx, .{
            .position = .absolute,
            .width = .{ .px = p.right * scale },
            .height = .{ .px = content_h_s },
            .background = c.padding_bg,
        }, .{});
        right_pad.setMargin(.{ .left = outer_x + outer_w - p.right * scale, .top = content_y });
        try stage.appendChild(alloc, right_pad);
    }

    const content = try core.box(cx, .{
        .position = .absolute,
        .width = .{ .px = content_w_s },
        .height = .{ .px = content_h_s },
        .background = c.content_bg,
        .justify = .center,
        .align_items = .center,
        .border = .{ .width = 1, .color = Color.rgba(79, 111, 196, 255) },
    }, .{});
    // content 建好到挂上 stage 之间还有一次可失败的 text 分配 —— 门控 errdefer 守窗口，
    // 挂接用 adoptChild（append 失败它自己收尸，所以让位标志要在 adopt 之前翻）。
    var content_owned = true;
    errdefer if (content_owned) cx.freeNode(content);
    content.setMargin(.{ .left = content_x, .top = content_y });
    var content_buf: [96]u8 = undefined; // f32 {d:.0} 最长 39 位 ×2 + 分隔符 < 96
    const content_str = std.fmt.bufPrint(&content_buf, "{d:.0} x {d:.0}", .{ content_w, content_h }) catch unreachable;
    const content_label = try core.text(cx, "", .{ .font_size = 10, .color = c.label_fg, .font_weight = 600 });
    if (content_label.getText()) |__old_t| {
        var __t = __old_t;
        try __t.setContent(cx.allocator, content_str);
        content_label.setText(__t);
    }
    _ = try core.adoptChild(cx, alloc, content, content_label);
    content_owned = false;
    _ = try core.adoptChild(cx, alloc, stage, content);

    var rect_buf: [96]u8 = undefined;
    const rect_str = std.fmt.bufPrint(&rect_buf, "rect {d:.0} x {d:.0}", .{ rect_w, rect_h }) catch unreachable;
    const rect_label = try core.text(cx, "", .{ .font_size = 9, .color = c.label_fg, .font_weight = 600 });
    if (rect_label.getText()) |__old_t| {
        var __t = __old_t;
        try __t.setContent(cx.allocator, rect_str);
        rect_label.setText(__t);
    }
    rect_label.style.position = .absolute;
    rect_label.setMargin(.{ .left = outer_x + 4, .top = @max(@as(f32, 0), outer_y - 14) });
    try stage.appendChild(alloc, rect_label);

    if (p.top > 0) {
        const top_label = try value(cx, p.top, c.label_fg);
        top_label.style.position = .absolute;
        top_label.setMargin(.{ .left = outer_x + outer_w * 0.5 - 8, .top = outer_y + @max(@as(f32, 0), p.top * scale * 0.5 - 6) });
        try stage.appendChild(alloc, top_label);
    }
    if (p.bottom > 0) {
        const bottom_label = try value(cx, p.bottom, c.label_fg);
        bottom_label.style.position = .absolute;
        bottom_label.setMargin(.{ .left = outer_x + outer_w * 0.5 - 8, .top = outer_y + outer_h - p.bottom * scale + @max(@as(f32, 0), p.bottom * scale * 0.5 - 6) });
        try stage.appendChild(alloc, bottom_label);
    }
    if (p.left > 0) {
        const left_label = try value(cx, p.left, c.label_fg);
        left_label.style.position = .absolute;
        left_label.setMargin(.{ .left = outer_x + @max(@as(f32, 0), p.left * scale * 0.5 - 6), .top = content_y + content_h_s * 0.5 - 6 });
        try stage.appendChild(alloc, left_label);
    }
    if (p.right > 0) {
        const right_label = try value(cx, p.right, c.label_fg);
        right_label.style.position = .absolute;
        right_label.setMargin(.{ .left = outer_x + outer_w - p.right * scale + @max(@as(f32, 0), p.right * scale * 0.5 - 6), .top = content_y + content_h_s * 0.5 - 6 });
        try stage.appendChild(alloc, right_label);
    }

    try wrapper.appendChild(alloc, stage);
    try parent.appendChild(alloc, wrapper);
}

fn label(cx: *Cx, text_content: []const u8, fg: Color) !*Node {
    return core.text(cx, text_content, .{
        .font_size = 9,
        .color = fg,
        .font_weight = 600,
    });
}

fn value(cx: *Cx, val: f32, fg: Color) !*Node {
    // 本地缓冲足够任何 f32（{d:.1} 最长 < 64）；setContent 拷贝，不依赖缓冲生命周期。
    var buf: [64]u8 = undefined;
    const str = if (val == 0)
        "-"
    else if (val == @round(val))
        std.fmt.bufPrint(&buf, "{d:.0}", .{val}) catch unreachable
    else
        std.fmt.bufPrint(&buf, "{d:.1}", .{val}) catch unreachable;
    const node = try core.text(cx, "", .{
        .font_size = 9,
        .color = fg,
    });
    if (node.getText()) |__old_t| {
        var __t = __old_t;
        try __t.setContent(cx.allocator, str);
        node.setText(__t);
    }
    return node;
}
