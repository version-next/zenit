/// Text rendering: text property resolve, multi-line/single-line rendering, Span segmentation,
/// ellipsis, overflow fade
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const text_utils = @import("text_utils.zig");
const render_context_mod = @import("render_context.zig");

const Node = node_mod.Node;

/// Paint-side name of Node.resolveTextProps: the same resolution layout measures with.
pub fn resolveNodeLogicalTextProps(node: *Node) ?types.TextProps {
    return node.resolveTextProps();
}

/// Compute content bounds of an overflow_hidden container's direct children (relative to container
/// top-left); returns (min_x, min_y, max_x, max_y), including translate/padding offset.
///
/// Covers three scroll mechanisms:
/// - translate_x/y (ScrollArea etc)
/// - negative padding (Input padding.left = -scroll_x)
/// - children exceeding the container (content naturally overflows)
pub const ContentExtent = struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 };

pub fn computeContentExtent(node: *Node) ContentExtent {
    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    var first = true;
    for (node.children.items) |child| {
        if (child.getOpacity() == 0) continue;
        // Global hook read rect.
        const cr = child.rectFromWorldOrFallback();
        // Skip helper nodes with zero width/height
        // (selection_node/cursor_node/preedit_underline_node); their default {0,0,0,0} rect
        // misclassifies as "content above top".
        if (cr.w <= 0 and cr.h <= 0) continue;
        const child_pad = child.style.contentInsets();
        // Content start: rect position + translate + padding (negative padding -> content shifted
        // forward)
        const x1 = cr.x + child.style.translate_x + @min(child_pad.left, @as(f32, 0));
        const y1 = cr.y + child.style.translate_y + @min(child_pad.top, @as(f32, 0));
        // Content end: rect boundary + translate (rect.w already includes positive padding)
        var x2 = cr.x + child.style.translate_x + cr.w - @min(child_pad.right, @as(f32, 0));
        const y2 = cr.y + child.style.translate_y + cr.h - @min(child_pad.bottom, @as(f32, 0));

        // Text node rect.w may be "visible segment width" under some layout paths, not full text
        // width. overflow_fade needs complete content bounds, so fall back to text intrinsic width.
        if (child.resolveTextProps()) |text_props| {
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

/// Paint pass overflow_fade no longer emits directly; display_list side (mod.zig
/// appendNodeOverflowFade) writes gradient_rect, lowering produces matching
/// DisplayItem.gradient_rect, visually equivalent. Function stub remains because caller still in
/// paint pass; remove caller too on next pass.
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
