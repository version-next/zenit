const std = @import("std");
const node_mod = @import("node.zig");
const types = @import("types.zig");

const Node = node_mod.Node;
const HitBehavior = types.HitBehavior;
const HitRoles = types.HitRoles;
const HitShapeSpec = types.HitShapeSpec;
const ClipShapeSpec = types.ClipShapeSpec;

pub fn nodeParticipatesInHitTest(node: *const Node) bool {
    // 与渲染规则对齐：opacity <= 0 时不可见，也不应参与命中。
    // display:none 连同子树退出命中（buildRecursive 在此处剪掉整棵子树）。
    return node.style.display != .none and node.frame_state.state_bits.flags.hit_test_visible and node.getOpacity() > 0;
}

pub fn nodeCreatesHitProxy(node: *const Node) bool {
    if (!nodeParticipatesInHitTest(node)) return false;
    const roles = nodeHitRoles(node);
    return roles.any();
}

pub fn nodeHitRoles(node: *const Node) HitRoles {
    // 逐 role 覆盖：只接管显式写了的那些，其余沿用推导默认值。
    var roles = node.style.hit_roles().apply(defaultRoles(node));
    if (node.frame_state.state_bits.flags.inspect_pick_disabled) roles.inspect = false;
    return roles;
}

pub fn nodeHitBehavior(node: *const Node) HitBehavior {
    return node.style.hit_behavior() orelse defaultBehavior(node);
}

pub fn nodeHitShape(node: *const Node) HitShapeSpec {
    const explicit = node.style.hit_shape();
    return switch (explicit) {
        .auto => defaultHitShape(node),
        else => explicit,
    };
}

pub fn nodeClipShape(node: *const Node) ClipShapeSpec {
    const explicit = node.style.clip_shape();
    return switch (explicit) {
        .auto => defaultClipShape(node),
        else => explicit,
    };
}

fn defaultRoles(node: *const Node) HitRoles {
    // 挂了 on_scroll 专用 handler 的普通节点（画布类）也算 scroll owner，
    // 否则 hit-test 永远命不中它，on_scroll 形同虚设。
    const is_scroll_owner = node.tag == .scroll or
        node.behavior.events.on_scroll != null or
        componentNameEquals(node, "ScrollArea") or
        componentNameEquals(node, "VirtualList");
    // 同理：挂了 drop target handler 的节点必须参与 pointer 命中，
    // 否则 handleDrag 的 hitTestQuery 永远命不中它，on_drop 形同虚设。
    const is_drop_target = node.behavior.events.on_drop != null or
        node.behavior.events.on_drag_enter != null or
        node.behavior.events.on_drag_leave != null;
    // 显式声明"拦截指针"的 hit_behavior 必须隐含 pointer role，否则 roleAllowsQuery
    // 先一步过滤掉该节点，behavior 根本没机会生效（hit_behavior 名不副实）。
    //
    // 必须读裸 style 字段，不能调 nodeHitBehavior()：defaultBehavior 会回调
    // nodeHitRoles -> defaultRoles，改成前者会形成无限递归爆栈。
    const behavior_intercepts = if (node.style.hit_behavior()) |b| switch (b) {
        .@"opaque", .self_only, .self_and_children => true,
        .pass_through, .children_only => false,
    } else false;
    return .{
        .pointer = behavior_intercepts or
            node.cursor_query != null or node.style.cursor != .inherit or
            node.behavior.interaction.focusable or
            node.behavior.events.on_click != null or
            node.behavior.events.on_hover != null or
            node.behavior.events.on_event != null or
            is_drop_target or
            node.tag == .button or
            node.tag == .input,
        .scroll = is_scroll_owner,
        .inspect = node.frame_state.state_bits.flags.inspectable,
    };
}

fn defaultBehavior(node: *const Node) HitBehavior {
    const roles = nodeHitRoles(node);
    if (roles.pointer or roles.scroll) return .self_and_children;
    return .pass_through;
}

fn defaultHitShape(node: *const Node) HitShapeSpec {
    if (componentNameEquals(node, "Spinner")) {
        return .ellipse;
    }
    const radius = node.style.effectiveRadius();
    if (radius > 0.01) {
        // 全局 hook 读 rect。
        const r = node.rectFromWorldOrFallback();
        const half_w = r.w / 2;
        const half_h = r.h / 2;
        if (@abs(r.w - r.h) < 0.01 and radius >= @min(half_w, half_h) - 0.5) {
            return .circle;
        }
        return .{ .rounded_rect = radius };
    }
    return .rect;
}

fn defaultClipShape(node: *const Node) ClipShapeSpec {
    const radius = node.style.effectiveRadius();
    if (radius > 0.01) return .{ .rounded_rect = radius };
    return .rect;
}

fn componentNameEquals(node: *const Node, expected: []const u8) bool {
    return if (node.meta.ownership.meta.component_name) |name|
        std.mem.eql(u8, name, expected)
    else
        false;
}
