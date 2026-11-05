/// Group Component: composition container HOC.
/// Combines child components into visual unit:
/// - gap = -1 overlaps child borders (avoid double border)
/// - first: zero right corners (TR=0, BR=0), keep left
/// - last: zero left corners (TL=0, BL=0), keep right
/// - between: zero all
/// - only: keep all
/// - no outer border; doesn't affect other child styles.
/// Reference: React Group (CMC UI Kit) attached mode.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Sizing = core.Sizing;
const Scope = core.Scope;
const Padding = core.Padding;
const BorderSideColors = @import("../../core/types.zig").BorderSideColors;

/// Group direction.
pub const GroupOrientation = enum {
    horizontal,
    vertical,
};

/// Child position in Group.
pub const GroupItemPosition = enum {
    first,
    between,
    last,
    only,
};

/// Group properties.
pub const GroupProps = struct {
    /// Direction.
    orientation: GroupOrientation = .horizontal,
    /// Width.
    width: Sizing = .{ .fit = .{} },
    /// Alignment.
    align_items: core.AlignItems = .stretch,
};

/// Group mount return value.
pub const GroupResult = struct {
    container: *Node,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: GroupResult) core.ViewParts {
        return .{ .root = self.container, .slot = self.container };
    }
};

pub fn Group(props: anytype) GroupBuilder {
    return .{ .props = @import("../../reactive.zig").props.coerce(GroupProps, props) };
}

pub const GroupBuilder = struct {
    props: GroupProps,

    pub fn mount(self: GroupBuilder, scope: *Scope, cx: *Cx) !GroupResult {
        const p = self.props;
        const dir: core.Direction = if (p.orientation == .horizontal) .row else .column;

        const container = try view.render(scope, cx, view.box(.{ .style = .{
            .width = p.width,
            .height = .{ .fit = .{} },
            .direction = dir,
            .align_items = p.align_items,
            .no_cross_stretch = p.width == .fit,
            .gap = 0,
        } }, {}));
        container.meta.ownership.meta.component_name = "Group";

        return .{ .container = container };
    }
};

/// Add child node to Group; set per-corner radius by position.
/// Horizontal layout (radii order: TL, TR, BR, BL):
/// - first: keep TL/BL, zero TR/BR
/// - last: keep TR/BR, zero TL/BL
/// - between: zero all
/// - only: keep all.
pub fn addGroupItem(
    container: *Node,
    allocator: Allocator,
    child: *Node,
    pos: GroupItemPosition,
    radius: f32,
) !void {
    // Attachment is component-inline style: it survives the items' own style replays (theme
    // switch, variant change) and stacks under caller overlays. Layout (overlap margin, shared
    // cross-axis width) goes on the item; the frame shape (per-corner radii, the shared edge drawn
    // once) on the node that draws the item's frame (Input: its field, not the label column).
    // Hit / clip shapes follow the per-corner radii (core .auto derivation).
    const horizontal = container.style.direction == .row;
    const frame = child.frameNode();
    const overlap = @max(@as(f32, 1), frame.style.border.width);
    var layout: core.BoxStyle = .{
        .margin = switch (pos) {
            .first, .only => Padding.ZERO,
            .between, .last => if (horizontal) .{ .left = -overlap } else .{ .top = -overlap },
        },
    };
    // Attached vertical controls share the container's cross-axis width.
    // Buttons normally opt out of inherited stretch when used independently.
    if (!horizontal and container.style.align_items == .stretch and child.style.width == .fit) {
        const bounds = child.style.width.fit;
        layout.width = .{ .grow = .{ .min = bounds.min, .max = bounds.max } };
        layout.no_cross_stretch = false;
    }
    var shape: core.BoxStyle = .{
        .corner_radii = switch (pos) {
            .only => .{ .all = radius },
            .first => if (horizontal) .{ .each = .{ radius, 0, 0, radius } } else .{ .each = .{ radius, radius, 0, 0 } },
            .last => if (horizontal) .{ .each = .{ 0, radius, radius, 0 } } else .{ .each = .{ 0, 0, radius, radius } },
            .between => .{ .all = 0 },
        },
        .hit_shape = .auto,
        .clip_shape = .auto,
    };
    // The shared edge is drawn once, by the next item.
    if (pos == .first or pos == .between) {
        if (horizontal) shape.border_right_color = Color.TRANSPARENT else shape.border_bottom_color = Color.TRANSPARENT;
    }
    // All or nothing: stage both writes (every allocation), attach (atomic on failure), and only
    // then commit; a failure leaves the child and its frame exactly as they were.
    if (frame == child) {
        const staged = try child.stageStyleInline(allocator, layout.merge(shape));
        container.appendChild(allocator, child) catch |err| {
            staged.abort();
            return err;
        };
        staged.commit();
        view.pinComponentRoot(child);
        return;
    }
    const item = try child.stageStyleInline(allocator, layout);
    errdefer item.abort();
    const framed = try frame.stageStyleInline(allocator, shape);
    errdefer framed.abort();
    try container.appendChild(allocator, child);
    item.commit();
    framed.commit();
    view.pinComponentRoot(child);
}

// ========== Tests ==========

test "Group: vertical buttons share intrinsic group width" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 300);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 }, .direction = .column }, .{});
    ctx.root = root;
    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();
    const group = try Group(.{ .orientation = .vertical }).mount(scope, ctx);
    try root.appendChild(alloc, group.container);
    const Button = @import("../button/mod.zig").Button;
    const top = try Button(.{ .label = "Top" }).mount(scope, ctx);
    const middle = try Button(.{ .label = "Middle" }).mount(scope, ctx);
    const bottom = try Button(.{ .label = "Bottom" }).mount(scope, ctx);
    try addGroupItem(group.container, alloc, top, .first, 8);
    try addGroupItem(group.container, alloc, middle, .between, 8);
    try addGroupItem(group.container, alloc, bottom, .last, 8);
    ctx.layout();
    try std.testing.expect(top.rectFromWorldOrFallback().w > 0 and top.rectFromWorldOrFallback().w < root.rectFromWorldOrFallback().w);
    try std.testing.expectApproxEqAbs(group.container.rectFromWorldOrFallback().w, top.rectFromWorldOrFallback().w, 0.01);
    try std.testing.expectApproxEqAbs(top.rectFromWorldOrFallback().w, middle.rectFromWorldOrFallback().w, 0.01);
    try std.testing.expectApproxEqAbs(top.rectFromWorldOrFallback().w, bottom.rectFromWorldOrFallback().w, 0.01);
}

test "Group: structure" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    try std.testing.expectEqual(@as(f32, 0), result.container.style.gap);
    try std.testing.expectEqual(@as(f32, 0), result.container.style.border.width);
}

test "Group: addGroupItem per-corner radius" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    const c1 = try box(ctx, .{ .border = .{ .overlay = true, .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
    const c2 = try box(ctx, .{ .border = .{ .overlay = true, .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
    const c3 = try box(ctx, .{ .border = .{ .overlay = true, .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});

    try addGroupItem(result.container, alloc, c1, .first, 8);
    try addGroupItem(result.container, alloc, c2, .between, 8);
    try addGroupItem(result.container, alloc, c3, .last, 8);

    // first: TL=8, TR=0, BR=0, BL=8
    const r1 = c1.style.effectiveRadii();
    try std.testing.expectEqual(@as(f32, 8), r1[0]);
    try std.testing.expectEqual(@as(f32, 0), r1[1]);
    try std.testing.expectEqual(@as(f32, 0), r1[2]);
    try std.testing.expectEqual(@as(f32, 8), r1[3]);

    // between: all 0
    const r2 = c2.style.effectiveRadii();
    try std.testing.expectEqual(@as(f32, 0), r2[0]);

    // last: TL=0, TR=8, BR=8, BL=0
    const r3 = c3.style.effectiveRadii();
    try std.testing.expectEqual(@as(f32, 0), r3[0]);
    try std.testing.expectEqual(@as(f32, 8), r3[1]);
    try std.testing.expectEqual(@as(f32, 8), r3[2]);
    try std.testing.expectEqual(@as(f32, 0), r3[3]);

    // border width/color not modified.
    try std.testing.expectEqual(@as(f32, 1), c1.style.border.width);
    try std.testing.expectEqual(Color.hex(0xE5E5E5), c2.style.border.color);
    try std.testing.expectEqual(@as(f32, -1), c2.style.margin.left);
    try std.testing.expectEqual(@as(f32, -1), c3.style.margin.left);
}

test "Group: overlap follows child border width" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 240 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    const c1 = try box(ctx, .{ .border = .{ .overlay = true, .radius = 8, .width = 2, .color = Color.hex(0xE5E5E5) } }, .{});
    const c2 = try box(ctx, .{ .border = .{ .overlay = true, .radius = 8, .width = 2, .color = Color.hex(0xE5E5E5) } }, .{});

    try addGroupItem(result.container, alloc, c1, .first, 8);
    try addGroupItem(result.container, alloc, c2, .last, 8);

    try std.testing.expectEqual(@as(f32, -2), c2.style.margin.left);
}

test "Group: attached seam keeps leading border on later items" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 240 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    const c1 = try box(ctx, .{ .border = .{ .overlay = true, .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
    const c2 = try box(ctx, .{ .border = .{ .overlay = true, .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});

    try addGroupItem(result.container, alloc, c1, .first, 8);
    try addGroupItem(result.container, alloc, c2, .last, 8);

    try std.testing.expect(Color.eql(c1.style.border_side_colors().?.right.?, Color.TRANSPARENT));
    // The last item overrides no side: its leading (left) border draws the seam.
    if (c2.style.border_side_colors()) |sides| {
        try std.testing.expect(sides.left == null and sides.top == null);
    }
}

// Per-allocation OOM sweep; see src/ui/components/oom_sweep.zig.
test "group: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("group", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Group(.{}).mount(scope, cx)).container;
        }
    }.m);
}

test "Group: addGroupItem 在任意分配点失败时子项与其边框节点原样不变，随后可重试" {
    // hosted_pair: item and its frame delegate both carry a style host (two staged host writes)
    const Kind = enum { plain, input, button, hosted_pair };
    for ([_]Kind{ .plain, .input, .button, .hosted_pair }) |kind| {
        var failure_index: usize = 0;
        while (true) : (failure_index += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const a = failing.allocator();
            const cx = try Cx.init(a, std.testing.io);
            defer cx.deinit();
            cx.root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
            const scope = try Scope.init(a, null, cx.owner);
            defer scope.dispose();
            const g = try Group(.{}).mount(scope, cx);
            try cx.root.?.appendChild(a, g.container);
            const child = switch (kind) {
                .plain => try box(cx, .{ .border = .{ .overlay = true, .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{}),
                .input => (try @import("../input/mod.zig").Input(.{ .value = "zenit", .width = 120 }).mountResult(scope, cx)).node,
                .button => try @import("../button/mod.zig").Button(.{ .label = "Go" }).mount(scope, cx),
                .hosted_pair => pair: {
                    const hover = view.hover(core.BoxStyle{ .opacity = 0.5 });
                    var inner: *Node = undefined;
                    const outer = try view.render(scope, cx, view.box(.{ .style = .{ core.BoxStyle{ .gap = 1 }, hover } }, view.capture(&inner, view.box(.{ .style = .{ core.BoxStyle{ .border = .{ .overlay = true, .radius = 8, .width = 1 } }, hover } }, .{}))));
                    outer.setFrameDelegate(inner);
                    try std.testing.expect(outer.meta.per_frame.hooks.style_host != null and inner.meta.per_frame.hooks.style_host != null);
                    break :pair outer;
                },
            };
            const frame = child.frameNode();
            const before = .{
                .margin = child.style.margin,
                .radii = frame.style.effectiveRadii(),
                .item_ext = child.style.ext != null,
                .frame_ext = frame.style.ext != null,
                .sides = frame.style.border_side_colors() != null,
            };
            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = addGroupItem(g.container, a, child, .first, 4);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |_| {
                try std.testing.expectEqual(g.container, child.parent.?);
                try std.testing.expectEqual(@as(f32, 0), frame.style.effectiveRadii()[1]);
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(child.parent == null);
                try std.testing.expectEqual(before.margin, child.style.margin);
                try std.testing.expectEqual(before.radii, frame.style.effectiveRadii());
                try std.testing.expectEqual(before.item_ext, child.style.ext != null);
                try std.testing.expectEqual(before.frame_ext, frame.style.ext != null);
                try std.testing.expectEqual(before.sides, frame.style.border_side_colors() != null);
                // nothing staged is left behind: the retry stages and lands normally
                try addGroupItem(g.container, a, child, .first, 4);
                try std.testing.expectEqual(@as(f32, 0), frame.style.effectiveRadii()[1]);
            }
        }
    }
}

// Real attachment under OOM: a plain framed box (no style host), an Input (item = label column,
// frame = field) and a Button (style host on its root). A mount that succeeds must have attached
// every item completely (corner radii, overlap margin, seam colors), none silently skipped.
test "group: addGroupItem 挂真实子控件，任意分配点失败时不泄漏、不假成功（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMountVerified("group(items)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const g = try Group(.{}).mount(scope, cx);
            errdefer cx.freeNode(g.container);
            const a = cx.allocator;
            const plain = try box(cx, .{ .border = .{ .overlay = true, .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
            addGroupItem(g.container, a, plain, .first, 8) catch |err| {
                cx.destroyDetached(plain);
                return err;
            };
            const input = try @import("../input/mod.zig").Input(.{ .value = "zenit", .width = 120 }).mountResult(scope, cx);
            addGroupItem(g.container, a, input.node, .between, 8) catch |err| {
                input.abandon(cx);
                return err;
            };
            const button = try @import("../button/mod.zig").Button(.{ .label = "Go" }).mount(scope, cx);
            addGroupItem(g.container, a, button, .last, 8) catch |err| {
                cx.destroyDetached(button);
                return err;
            };
            return g.container;
        }
    }.m, struct {
        fn expectRadii(n: *Node, want: [4]f32) !void {
            const r = n.style.effectiveRadii();
            for (want, r) |w, got| try std.testing.expectApproxEqAbs(w, got, 0.001);
        }
        fn check(root: *Node) anyerror!void {
            const items = root.children.items;
            try std.testing.expectEqual(@as(usize, 3), items.len);
            try expectRadii(items[0].frameNode(), .{ 8, 0, 0, 8 });
            try expectRadii(items[1].frameNode(), .{ 0, 0, 0, 0 });
            try expectRadii(items[2].frameNode(), .{ 0, 8, 8, 0 });
            for (items[0..2]) |item| {
                const sides = item.frameNode().style.border_side_colors() orelse return error.SeamMissing;
                try std.testing.expect(Color.eql(sides.right.?, Color.TRANSPARENT));
            }
            for (items[1..]) |item| try std.testing.expect(item.style.margin.left < 0);
        }
    }.check);
}
