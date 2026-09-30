//! 命中目标解析：interaction / inspect delegate 链与 devtools 命中调试输出。

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const devtoolsHitDebugEnabled = @import("debug_env.zig").devtoolsHitDebugEnabled;

pub fn logDebugNodeSummary(comptime label: []const u8, node: ?*Node) void {
    if (node) |n| {
        const rect = n.globalRect();
        std.debug.print(
            "[devtools-hit] {s}=id={d} tag={s} component={s} test_id={s} rect=({d:.1},{d:.1},{d:.1},{d:.1})\n",
            .{
                label,
                n.id,
                @tagName(n.tag),
                n.meta.ownership.meta.component_name orelse "<none>",
                n.meta.ownership.meta.test_id orelse "<none>",
                rect.x,
                rect.y,
                rect.w,
                rect.h,
            },
        );
    } else {
        std.debug.print("[devtools-hit] {s}=<none>\n", .{label});
    }
}

pub fn resolveInteractionDelegateChain(node: *Node) *Node {
    var current = node;
    var hops: usize = 0;
    while (current.meta.ownership.delegate.interaction) |delegate| : (hops += 1) {
        current = delegate;
        if (hops >= 16) break;
    }
    return current;
}

pub fn resolveInteractionTarget(node_opt: ?*Node) ?*Node {
    var current = node_opt;
    while (current) |node| {
        if (node.meta.ownership.delegate.interaction != null) {
            return resolveInteractionDelegateChain(node);
        }
        current = node.parent;
    }
    return node_opt;
}

pub fn shouldPreserveFocusForOverlayPointerTarget(self: *Cx, node_opt: ?*Node) bool {
    const node = node_opt orelse return false;
    const layer = self.overlay_stack.findLayerForNode(node) orelse return false;
    return switch (layer.config.kind) {
        .non_modal, .toast => true,
        .modal => false,
    };
}

pub fn resolveInspectDelegateChain(node: *Node) *Node {
    var current = node;
    var hops: usize = 0;
    while (current.meta.ownership.delegate.inspect) |delegate| : (hops += 1) {
        if (delegate == current) return current;
        current = delegate;
        if (hops >= 16) break;
    }
    return current;
}

pub fn resolveInspectTarget(node_opt: ?*Node) ?*Node {
    var current = node_opt;
    while (current) |node| {
        if (node.meta.ownership.delegate.inspect != null) {
            return resolveInspectDelegateChain(node);
        }
        current = node.parent;
    }
    return node_opt;
}

var g_devtools_hit_debug_banner_printed: bool = false;

pub fn ensureDevtoolsHitDebugBanner() void {
    if (!devtoolsHitDebugEnabled()) return;
    if (g_devtools_hit_debug_banner_printed) return;
    g_devtools_hit_debug_banner_printed = true;
    std.debug.print("[devtools-hit] enabled via ZENIT_DEVTOOLS_HIT_DEBUG / ZENIT_SCROLL_DEBUG\n", .{});
}
