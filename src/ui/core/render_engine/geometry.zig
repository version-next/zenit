/// 纯几何工具函数：rect 运算、变换、sticky 偏移
/// 不依赖任何其他渲染子模块
const std = @import("std");

const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const retained_scene = @import("../retained_scene.zig");

const ComputedRect = types.ComputedRect;
const Point = types.Point;
const Padding = types.Padding;
const StickyInsets = types.StickyInsets;
const StickyState = node_mod.StickyState;
const Color = types.Color;
const Transform2D = types.Transform2D;
const Node = node_mod.Node;

pub fn intersectRect(a: ComputedRect, b: ComputedRect) ?ComputedRect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x + a.w, b.x + b.w);
    const y2 = @min(a.y + a.h, b.y + b.h);
    if (x2 <= x1 or y2 <= y1) return null;
    return ComputedRect.init(x1, y1, x2 - x1, y2 - y1);
}

pub fn unionRect(a: ComputedRect, b: ComputedRect) ComputedRect {
    const min_x = @min(a.x, b.x);
    const min_y = @min(a.y, b.y);
    const max_x = @max(a.x + a.w, b.x + b.w);
    const max_y = @max(a.y + a.h, b.y + b.h);
    return ComputedRect.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

pub fn nodeLocalTransform(node: *Node) Transform2D {
    return retained_scene.buildNodeLocalTransform(node, .{ .include_rotation = true });
}

pub fn nodeWorldTransform(parent_transform: Transform2D, node: *Node) Transform2D {
    return retained_scene.buildNodeWorldTransform(node, parent_transform, .{ .include_rotation = true });
}

pub fn expandRect(rect: ComputedRect, left: f32, top: f32, right: f32, bottom: f32) ComputedRect {
    return ComputedRect.init(
        rect.x - left,
        rect.y - top,
        rect.w + left + right,
        rect.h + top + bottom,
    );
}

pub fn computeOpacityLayerBounds(
    node: *Node,
    world_transform: Transform2D,
    render_rect: ComputedRect,
    scale_x_abs: f32,
    scale_y_abs: f32,
    scale_min: f32,
) ComputedRect {
    var bounds = render_rect;

    if (!node.style.overflow_hidden) {
        if (node.getLayoutOutput().artifacts.children_bbox) |bbox| {
            bounds = unionRect(bounds, world_transform.transformRect(bbox));
        }
    }

    // 必须遍历**全部**阴影层（最多 max_shadows 层），只算 shadows[0] 会让后面大 blur
    // 阴影超出 surface 纹理边界被矩形截断（Modal 双阴影 blur=80/offset_y=32 曾露馅）。
    // 正 spread 同样外扩阴影形状（负 spread 只会收缩，不增大外溢）。
    for (node.style.shadowSlice()) |shadow| {
        const spread = @max(@as(f32, 0), shadow.spread);
        const blur_x = (shadow.blur * 2 + spread) * scale_x_abs;
        const blur_y = (shadow.blur * 2 + spread) * scale_y_abs;
        const offset_x = shadow.offset_x * scale_x_abs;
        const offset_y = shadow.offset_y * scale_y_abs;
        bounds = expandRect(
            bounds,
            blur_x + @max(@as(f32, 0), -offset_x),
            blur_y + @max(@as(f32, 0), -offset_y),
            blur_x + @max(@as(f32, 0), offset_x),
            blur_y + @max(@as(f32, 0), offset_y),
        );
    }

    if (node.style.outline()) |out| {
        const outline_margin = (out.offset + out.width) * scale_min;
        bounds = expandRect(bounds, outline_margin, outline_margin, outline_margin, outline_margin);
    }

    return expandRect(bounds, 2, 2, 2, 2);
}

pub fn modulateColorOpacity(color: Color, opacity: f32) Color {
    const alpha = @as(f32, @floatFromInt(color.a)) * std.math.clamp(opacity, 0.0, 1.0);
    return color.withAlpha(@intFromFloat(@round(alpha)));
}

pub fn canInlineLeafOpacity(
    node: *Node,
    has_rotation: bool,
    has_scale: bool,
    prepromote_composite: bool,
    needs_clip: bool,
    blur_radius: f32,
) bool {
    if (has_rotation or has_scale or prepromote_composite) return false;
    if (needs_clip or blur_radius > 0.001) return false;
    if (node.children.items.len != 0) return false;
    if (node.meta.per_frame.custom_hooks.draw != null or node.frame_state.state_bits.flags.has_custom_draw_subtree) return false;
    if (node.getText() != null) return false;
    return true;
}

/// solveSticky 的全部输入。坐标约定：`self_rect`/`parent_rect` 是布局 rect（相对各自父节点），
/// `parent_origin`/`clip`/`constraint` 是屏幕坐标。
pub const StickyInput = struct {
    /// sticky 节点自身的布局 rect（相对父节点）。
    self_rect: ComputedRect,
    /// sticky 节点自身的 translate：参与自然位置（与 tick/globalRect 的屏幕坐标累加一致）。
    self_translate: Point = .{ .x = 0, .y = 0 },
    /// 父节点的屏幕原点 = tick 递归传下来的 offset（已含全部祖先的 rect + translate + sticky，
    /// 其中包括父节点自己的，**不要**再加 parent_rect.x/y 或父节点 translate）。
    parent_origin: Point,
    /// 父节点布局 rect，只用其 w/h；null = 无父节点，不做钳制。
    parent_rect: ?ComputedRect,
    parent_padding: Padding = Padding.ZERO,
    insets: StickyInsets,
    /// 吸附区域：全部 overflow_hidden 祖先框 ∩ 窗口视口（不含 sticky 自身）。
    clip: ComputedRect,
    /// 显式钳制容器（屏幕坐标，已扣 padding）；非 null 时取代父节点 content box。
    constraint: ?ComputedRect = null,
};

pub const StickyResult = struct {
    offset: Point = .{ .x = 0, .y = 0 },
    state: StickyState = .{},
};

/// sticky 偏移求解（纯函数，无副作用）。
/// 某方向自然位置越过吸附线时补偿到吸附线，再被钳制容器（默认父节点 content box）
/// 截短，保证 sticky 不越出容器。top 与 bottom（left 与 right）同时触发时后者覆盖前者。
pub fn solveSticky(in: StickyInput) StickyResult {
    const natural_x = in.parent_origin.x + in.self_rect.x + in.self_translate.x;
    const natural_y = in.parent_origin.y + in.self_rect.y + in.self_translate.y;
    const bounds: ?ComputedRect = in.constraint orelse if (in.parent_rect) |pr| ComputedRect.init(
        in.parent_origin.x + in.parent_padding.left,
        in.parent_origin.y + in.parent_padding.top,
        pr.w - in.parent_padding.left - in.parent_padding.right,
        pr.h - in.parent_padding.top - in.parent_padding.bottom,
    ) else null;

    var x: f32 = 0;
    var y: f32 = 0;
    var x_constrained = false;
    var y_constrained = false;

    if (in.insets.left) |inset_left| {
        const desired_x = in.clip.x + inset_left;
        if (natural_x < desired_x) {
            const want = desired_x - natural_x;
            x = want;
            if (bounds) |b| x = std.math.clamp(want, 0, @max(@as(f32, 0), b.x + b.w - natural_x - in.self_rect.w));
            x_constrained = x < want;
        }
    }
    if (in.insets.top) |inset_top| {
        const desired_y = in.clip.y + inset_top;
        if (natural_y < desired_y) {
            const want = desired_y - natural_y;
            y = want;
            if (bounds) |b| y = std.math.clamp(want, 0, @max(@as(f32, 0), b.y + b.h - natural_y - in.self_rect.h));
            y_constrained = y < want;
        }
    }
    if (in.insets.right) |inset_right| {
        const desired_x = in.clip.x + in.clip.w - inset_right - in.self_rect.w;
        if (natural_x > desired_x) {
            const want = desired_x - natural_x;
            x = want;
            if (bounds) |b| x = std.math.clamp(want, @min(@as(f32, 0), b.x - natural_x), 0);
            x_constrained = x > want;
        }
    }
    if (in.insets.bottom) |inset_bottom| {
        const desired_y = in.clip.y + in.clip.h - inset_bottom - in.self_rect.h;
        if (natural_y > desired_y) {
            const want = desired_y - natural_y;
            y = want;
            if (bounds) |b| y = std.math.clamp(want, @min(@as(f32, 0), b.y - natural_y), 0);
            y_constrained = y > want;
        }
    }

    const engaged = x != 0 or y != 0;
    const constrained = x_constrained or y_constrained;
    return .{
        .offset = .{ .x = x, .y = y },
        .state = .{
            .engaged_top = y > 0,
            .engaged_bottom = y < 0,
            .engaged_left = x > 0,
            .engaged_right = x < 0,
            .pinned = engaged and !constrained,
            .constrained = constrained,
        },
    };
}

/// tick 侧的 sticky 写回：由节点构造 StickyInput -> solveSticky -> 写回偏移与状态，变化时标脏。
/// clip: sticky 的吸附区域（祖先裁剪交集）；null = 交集为空，没有可吸附的区域，偏移与状态清零
/// （不能保留上一帧的值：globalRect / 命中 / 锚定 popover 都会读到它）。
/// offset_x/y: 父节点的屏幕原点（tick 递归累加的全部祖先 rect + translate + sticky）。
pub fn computeStickyOffset(node: *Node, offset_x: f32, offset_y: f32, clip: ?ComputedRect) void {
    const result: StickyResult = if (clip) |c| blk: {
        // 通过全局 hook 从 World.LayoutTable 读 rect。
        const parent = node.parent;
        break :blk solveSticky(.{
            .self_rect = node.rectFromWorldOrFallback(),
            .self_translate = .{ .x = node.style.translate_x, .y = node.style.translate_y },
            .parent_origin = .{ .x = offset_x, .y = offset_y },
            .parent_rect = if (parent) |p| p.rectFromWorldOrFallback() else null,
            .parent_padding = if (parent) |p| p.style.padding else Padding.ZERO,
            .insets = node.style.sticky_insets(),
            .clip = c,
        });
    } else .{};

    const sticky = &node.frame_state.frame_local.runtime.sticky;
    // 状态位变化也算变化（方案 §7.4）：devtools / e2e 序列化读的是同一份 runtime.sticky。
    const changed = result.offset.x != sticky.x or result.offset.y != sticky.y or !result.state.eql(sticky.state);
    sticky.x = result.offset.x;
    sticky.y = result.offset.y;
    sticky.state = result.state;

    // 变化 -> 标脏渲染 + 清除祖先渲染缓存
    if (changed) {
        node.markInteractionDirty();
        node.frame_state.state_bits.dirty.core.render = true;
        node.frame_state.state_bits.dirty.core.subtree_render = true;
        var p = node.parent;
        while (p) |parent| {
            parent.frame_state.state_bits.dirty.core.subtree_render = true;
            parent.invalidateRenderCache();
            if (parent.style.overflow_hidden) break;
            p = parent.parent;
        }
    }
}
