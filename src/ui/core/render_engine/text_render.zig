/// 文本渲染：文字属性解析、多行/单行文字渲染、Span 分段、省略号、溢出淡出
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const text_utils = @import("text_utils.zig");
const render_context_mod = @import("render_context.zig");

const Node = node_mod.Node;

pub fn resolveNodeLogicalTextProps(node: *Node) ?types.TextProps {
    var t = node.getText() orelse return null;
    const inherited = node.resolveInheritedTextStyle();
    if (inherited.color) |c| t.color = c;
    if (inherited.font_size) |s| t.font_size = s;
    if (inherited.font_weight) |w| t.font_weight = w;
    return t;
}

/// 计算 overflow_hidden 容器直接子节点的内容边界（相对于容器左上角）
/// 返回 (min_x, min_y, max_x, max_y) — 含 translate/padding 偏移
///
/// 三种滚动机制都覆盖：
/// - translate_x/y（ScrollArea 等）
/// - 负 padding（Input 的 padding.left = -scroll_x）
/// - 子节点超出容器（内容自然溢出）
pub const ContentExtent = struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 };

pub fn computeContentExtent(node: *Node) ContentExtent {
    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    var first = true;
    for (node.children.items) |child| {
        if (child.getOpacity() == 0) continue;
        // 全局 hook 读 rect。
        const cr = child.rectFromWorldOrFallback();
        // 跳过宽高都为 0 的辅助节点（如 selection_node/cursor_node/preedit_underline_node），
        // 它们的 rect 默认 {0,0,0,0} 会误判为"内容溢出顶部"
        if (cr.w <= 0 and cr.h <= 0) continue;
        const child_pad = child.style.padding;
        // 内容起点：rect 位置 + translate + padding（负 padding → 内容前移）
        const x1 = cr.x + child.style.translate_x + @min(child_pad.left, @as(f32, 0));
        const y1 = cr.y + child.style.translate_y + @min(child_pad.top, @as(f32, 0));
        // 内容终点：rect 边界 + translate（rect.w 已含正 padding）
        var x2 = cr.x + child.style.translate_x + cr.w - @min(child_pad.right, @as(f32, 0));
        const y2 = cr.y + child.style.translate_y + cr.h - @min(child_pad.bottom, @as(f32, 0));

        // 文本节点在某些布局路径下 rect.w 可能是"可见片段宽度"，不是完整文本宽度。
        // overflow_fade 需要完整内容边界，因此用文本 intrinsic 宽度兜底。
        if (child.getText()) |text_props| {
            if (text_props.content.len > 0) {
                const approx_char_w = @max(@as(f32, 1), text_props.font_size * 0.55);
                const intrinsic_text_w = text_utils.utf8DisplayWidth(text_props.content, approx_char_w);
                const intrinsic_w = intrinsic_text_w + @max(child_pad.left, @as(f32, 0)) + @max(child_pad.right, @as(f32, 0));
                x2 = @max(x2, x1 + intrinsic_w);
            }
        }
        if (first) {
            min_x = x1;
            min_y = y1;
            max_x = x2;
            max_y = y2;
            first = false;
        } else {
            min_x = @min(min_x, x1);
            min_y = @min(min_y, y1);
            max_x = @max(max_x, x2);
            max_y = @max(max_y, y2);
        }
    }
    return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

/// paint pass overflow_fade 已不直接 emit；display_list 端
/// (mod.zig appendNodeOverflowFade) 写 gradient_rect，lowering 时产出对应
/// DisplayItem.gradient_rect — 视觉等价。本函数保留空壳是因为调用方仍在
/// paint pass 内调；下刀连调用方一起删。
pub fn renderOverflowFade(
    cx: *render_context_mod.RenderContext,
    node: *Node,
    render_x: f32,
    render_y: f32,
    render_w: f32,
    render_h: f32,
    fade: types.OverflowFade,
) !void {
    _ = cx;
    _ = node;
    _ = render_x;
    _ = render_y;
    _ = render_w;
    _ = render_h;
    _ = fade;
}
