//! Optional window UI helpers. Applications can compose their own Header per backend.
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const bind = @import("../../bind.zig");
pub const chrome = @import("system_sdk").window_chrome;

pub fn DragRegion(props: anytype, children: anytype) RegionBox(@TypeOf(view.box(props, children)), .drag) {
    return .{ .inner = view.box(props, children) };
}
pub fn ClientRegion(props: anytype, children: anytype) RegionBox(@TypeOf(view.box(props, children)), .client) {
    return .{ .inner = view.box(props, children) };
}
fn RegionBox(comptime Inner: type, comptime region: chrome.Region) type {
    return struct {
        inner: Inner,
        pub fn mount(self: @This(), parent_scope: *core.Scope, cx: *core.Cx) !*core.Node {
            const scope = try parent_scope.childScope();
            errdefer scope.dispose();
            const node = try view.render(scope, cx, self.inner);
            errdefer cx.destroyDetached(node);
            node.behavior.interaction.window_region = region;
            try core.Cx.bindScopeToNode(scope, node);
            return node;
        }
    };
}

pub const ControlsProps = @import("caption.zig").Props;
pub const WindowControls = @import("caption.zig").WindowControls;

/// Row header: custom mode integrates with native controls, fallback/native mode
/// keeps application content as an ordinary toolbar. Pass normal view.row props.
pub fn WindowHeader(props: anytype, children: anytype) Header(@TypeOf(view.row(props, children))) {
    return .{ .inner = view.row(props, children) };
}
fn Header(comptime Inner: type) type {
    return struct {
        inner: Inner,
        pub fn mount(self: @This(), parent_scope: *core.Scope, cx: *core.Cx) !*core.Node {
            const scope = try parent_scope.childScope();
            errdefer scope.dispose();
            const root = try view.render(scope, cx, self.inner);
            errdefer cx.destroyDetached(root);
            if (cx.window_header_node != null) return error.DuplicateWindowHeader;
            const Slot = struct {
                cx: *core.Cx,
                node: *core.Node,
                fn cleanup(slot: *@This()) void {
                    if (slot.cx.window_header_node == slot.node) {
                        slot.cx.window_header_node = null;
                        slot.cx.window_header_offset = .{ 0, 0 };
                    }
                }
            };
            const slot = try scope.createState(Slot, .{ .cx = cx, .node = root });
            try scope.onCleanup(Slot, slot, Slot.cleanup);
            cx.window_header_node = root;
            if (root.style.height == .fit) root.style.height = .{ .px = 52 };
            const controls = try WindowControls(.{ .automatic_only = true }).mount(scope, cx);
            _ = try core.adoptChild(cx, cx.allocator, root, controls);
            const Binding = struct {
                node: *core.Node,
                base: core.Padding,
                allocator: std.mem.Allocator,
                /// The padding write is the only fallible step and comes first: a failure
                /// leaves the header as it was (the first run is part of the mount).
                fn update(b: @This(), state: chrome.State) error{OutOfMemory}!void {
                    try b.syncPadding(state);
                    b.node.behavior.interaction.window_region = if (state.effective_mode == .custom) .drag else .client;
                }

                fn syncPadding(b: @This(), state: chrome.State) error{OutOfMemory}!void {
                    // AppKit reports model-space controls while animating
                    // presentation-space snapshots. Keep the completed Header
                    // inset until the native transition commits its geometry.
                    if (state.fullscreen_transitioning and state.fullscreen_header_hosted) return;
                    var padding = b.base;
                    if (state.effective_mode == .custom and state.controls_owner == .native) {
                        if (!state.controls_geometry_known) {
                            // Unknown native geometry must not expose overlapping UI.
                            padding.left = @max(padding.left, state.width);
                        } else for (state.native_controls[0..state.native_controls_count]) |r| {
                            if (r.x + r.w / 2 < state.width / 2) padding.left = @max(padding.left, r.x + r.w + 8) else padding.right = @max(padding.right, state.width - r.x + 8);
                        }
                    }
                    if (!std.meta.eql(b.node.style.padding, padding)) {
                        try b.node.setStyleInlineFallible(b.allocator, .{ .padding = padding });
                    }
                }
            };
            try bind.bind(scope, try cx.windowChrome(), Binding{ .node = root, .base = root.style.padding, .allocator = cx.allocator }, Binding.update);
            try core.Cx.bindScopeToNode(scope, root);
            return root;
        }
    };
}
