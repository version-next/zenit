//! Inspector overlay — a one-line dev tool that highlights whatever node
//! the mouse is hovering, with a dashed bounding box and a small label
//! showing dimensions + component name.
//!
//! Usage:
//! ```zig
//! fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
//!     const root = try ui.box(cx, .{ ... }, .{});
//!     // Build your UI ...
//!
//!     // Optional: turn on the inspector overlay (development builds only).
//!     try ui.devtools.overlay.attach(cx, scope, root, .{});
//!
//!     return root;
//! }
//! ```
//!
//! The overlay is a single absolute-positioned node added to the tree;
//! it doesn't intercept pointer events (`hit_behavior = .pass_through`)
//! so user interaction is unaffected.
//!
//! Design notes:
//!   - State (current target, label buffer) lives on a per-`scope` resource;
//!     the overlay's `node.hooks.slots.anim_state` points at it so the per-frame
//!     `on_before_render` hook can read+mutate without globals.
//!   - The overlay node is placed at a high `z_index` so it draws above
//!     popovers/modals/transitions.
//!   - No layout reflow on hover: we only mutate `style.translate_x/y`
//!     and the inset to position the bounding box, plus the label's
//!     text content. Both are paint-only changes.
const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const node_mod = @import("node.zig");
const reactive = @import("../reactive.zig");
const builders = @import("builders.zig");
const inspector_mod = @import("inspector.zig");

const Cx = @import("../core.zig").Cx;
const Node = node_mod.Node;
const Color = types.Color;
const Sizing = types.Sizing;
const Padding = types.Padding;
const Border = types.Border;
const Position = types.Position;
const Scope = reactive.Scope;

/// Overlay appearance + behavior knobs.
pub const Config = struct {
    /// Border color of the highlight box. Default: bright cyan.
    border_color: Color = Color.rgba(0, 210, 220, 220),
    /// Background of the dimension label. Default: dark translucent.
    label_bg: Color = Color.rgba(20, 20, 28, 230),
    /// Label text color.
    label_fg: Color = Color.rgba(240, 248, 255, 255),
    /// Border width in px. 1.5 looks crisp on Retina.
    border_width: f32 = 1.5,
    /// Z-index of the overlay node. Default lifts above popovers (32000)
    /// while leaving room for any caller-defined critical layer.
    z_index: i16 = 32000,
};

/// Per-scope state owned by the overlay. Lives in `scope`'s resource list,
/// referenced from `overlay_node.hooks.slots.anim_state`.
const OverlayState = struct {
    cx: *Cx,
    config: Config,
    /// Outer overlay node (full-viewport pass-through container).
    container: *Node,
    /// Highlight rect (dashed border).
    box: *Node,
    /// Label background (sized to fit text).
    label_bg: *Node,
    /// Label text node.
    label: *Node,
    /// Backing buffer for the label so we don't allocate per frame.
    label_buf: [128]u8 = undefined,
    /// Last node we highlighted; cached so we skip work when hover hasn't moved.
    last_target: ?*Node = null,
    /// Bumps every frame `last_target == null`, used to hide the overlay
    /// without re-laying-out when nothing is hovered.
    hidden: bool = true,
    /// False once the container node has been freed (on_cleanup fired).
    /// The scope-resource destructor must not touch nodes after that.
    nodes_alive: bool = true,
};

/// Mount the inspector overlay as a child of `parent`. Returns the overlay's
/// container node so callers can do additional fine-tuning (e.g. adjust
/// `z_index` or temporarily detach it).
///
/// `scope` owns the overlay state; when it's disposed the overlay is removed
/// cleanly. Pass `cx.root_scope` (the default) if you don't have a more
/// specific scope.
pub fn attach(cx: *Cx, scope: *Scope, parent: *Node, config: Config) !*Node {
    const allocator = cx.allocator;

    // Container: full-viewport, pass-through pointer events, high z_index.
    const container = try builders.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .position = .absolute,
    }, .{});
    container.meta.ownership.meta.component_name = "DevtoolsOverlay";
    container.frame_state.state_bits.flags.inspectable = false;
    {
        const ext = try container.style.ensureExtFallible(allocator);
        ext.inset = .{
            .top = .{ .px = 0 },
            .left = .{ .px = 0 },
            .right = .{ .px = 0 },
            .bottom = .{ .px = 0 },
        };
        ext.hit_behavior = .pass_through;
        ext.z_index = config.z_index;
    }

    // Highlight box: absolute-positioned, dashed border, no fill.
    const box = try builders.box(cx, .{
        .width = .{ .px = 0 },
        .height = .{ .px = 0 },
        .position = .absolute,
        .border = .{
            .width = config.border_width,
            .color = config.border_color,
        },
    }, .{});
    box.meta.ownership.meta.component_name = "DevtoolsOverlayBox";
    box.frame_state.state_bits.flags.inspectable = false;
    {
        const ext = try box.style.ensureExtFallible(allocator);
        ext.inset = .{
            .top = .{ .px = 0 },
            .left = .{ .px = 0 },
        };
        ext.hit_behavior = .pass_through;
    }
    try container.appendChild(allocator, box);

    // Label background (anchored to the highlight box's top-left, just above).
    const label_bg = try builders.box(cx, .{
        .width = .{ .fit = .{} },
        .height = .{ .fit = .{} },
        .position = .absolute,
        .padding = Padding.symmetric(2, 6),
        .background = config.label_bg,
    }, .{});
    label_bg.meta.ownership.meta.component_name = "DevtoolsOverlayLabel";
    label_bg.frame_state.state_bits.flags.inspectable = false;
    {
        const ext = try label_bg.style.ensureExtFallible(allocator);
        ext.inset = .{
            .top = .{ .px = 0 },
            .left = .{ .px = 0 },
        };
        ext.hit_behavior = .pass_through;
    }
    try container.appendChild(allocator, label_bg);

    const label = try builders.text(cx, "", .{
        .color = config.label_fg,
        .font_size = 11,
        .font_weight = 500,
    });
    label.frame_state.state_bits.flags.inspectable = false;
    try label_bg.appendChild(allocator, label);

    // Allocate state and tie it to `scope`. The overlay node references state
    // through `anim_state`; `on_before_render` reads/mutates it each frame.
    const state = try scope.allocator.create(OverlayState);
    errdefer scope.allocator.destroy(state);
    state.* = .{
        .cx = cx,
        .config = config,
        .container = container,
        .box = box,
        .label_bg = label_bg,
        .label = label,
    };
    try scope.registerResource(@ptrCast(state), struct {
        fn destroy(ptr: *anyopaque, alloc: Allocator) void {
            const s: *OverlayState = @ptrCast(@alignCast(ptr));
            if (s.nodes_alive) {
                // Scope 先于节点树销毁：树上还挂着指回 state 的 before_render
                // hook / anim_state / on_cleanup，label 文本还 alias 着
                // state.label_buf —— 不摘干净，下一帧 tickBeforeRender 或
                // setTheme 的 hook 遍历就是 use-after-free。
                s.container.meta.per_frame.hooks.before_render.main = null;
                s.container.meta.per_frame.hooks.slots.anim_state = null;
                s.container.meta.ownership.hooks.on_cleanup = null;
                if (s.label.getText()) |old| {
                    var txt = old;
                    txt.content = "";
                    s.label.setText(txt);
                }
            }
            alloc.destroy(s);
        }
    }.destroy);

    container.meta.per_frame.hooks.slots.anim_state = @ptrCast(state);
    container.meta.per_frame.hooks.before_render.main = beforeRender;
    // 反向拆链：节点树先被释放时，标记 nodes_alive=false，
    // 让上面的 scope 析构器跳过对已释放节点的触碰。
    container.meta.ownership.hooks.on_cleanup = Cx.simpleHandler(struct {
        fn cleanup(ptr: *anyopaque) void {
            const s: *OverlayState = @ptrCast(@alignCast(ptr));
            s.nodes_alive = false;
        }
    }.cleanup, @ptrCast(state));

    // Start hidden — until the user moves the mouse over a node, there's
    // nothing to draw.
    setHidden(state, true);

    try parent.appendChild(allocator, container);
    return container;
}

/// Per-frame hook: reposition the overlay over `cx.hovered_node` (or hide it).
fn beforeRender(node: *Node) void {
    const state: *OverlayState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    const target = pickHoverTarget(state.cx);

    if (target == null) {
        if (!state.hidden) setHidden(state, true);
        state.last_target = null;
        return;
    }

    if (state.last_target != target) {
        state.last_target = target;
        if (state.hidden) setHidden(state, false);
    }

    const t = target.?;
    // 全变换 world rect（含祖先 scale/rotate）——hit-test 选中节点用的就是
    // 完整变换，高亮必须同口径，否则 scaled 子树里的节点框会脱位。
    const rect = inspector_mod.nodeWorldRect(t);
    // box/label 是 container 的子节点，translate 相对 container 生效；
    // world 坐标必须先减去 container 自身的 world 原点，否则 attach 在
    // 非原点父节点（如 title bar 下方的内容区）时全部高亮双重偏移。
    const org = inspector_mod.nodeWorldRect(state.container);
    const local_x = rect.x - org.x;
    const local_y = rect.y - org.y;

    // Position the box. translate_x/y is the cheapest-to-mutate way to move
    // an absolute-positioned node — no layout pass needed.
    state.box.style.translate_x = local_x;
    state.box.style.translate_y = local_y;
    state.box.style.width = .{ .px = @max(rect.w, 1) };
    state.box.style.height = .{ .px = @max(rect.h, 1) };
    state.box.markRenderDirty();
    state.box.markLayoutDirty();

    // Label text: "{w} × {h}  {component_name}" or "{w} × {h}  #{id}".
    const w_int: i32 = @intFromFloat(@round(rect.w));
    const h_int: i32 = @intFromFloat(@round(rect.h));
    const name_or_id: []const u8 = t.meta.ownership.meta.component_name orelse "";
    const written = if (name_or_id.len > 0)
        std.fmt.bufPrint(&state.label_buf, "{d} × {d}  {s}", .{ w_int, h_int, name_or_id }) catch state.label_buf[0..0]
    else
        std.fmt.bufPrint(&state.label_buf, "{d} × {d}  #{d}", .{ w_int, h_int, t.id }) catch state.label_buf[0..0];

    if (state.label.getText()) |old| {
        var txt = old;
        txt.content = written;
        state.label.setText(txt);
    }
    state.label.markRenderDirty();
    state.label.markLayoutDirty();

    // Anchor the label just above the box; if there's no room, place it inside.
    const label_h: f32 = 18;
    const label_y = if (local_y >= label_h) local_y - label_h else local_y;
    state.label_bg.style.translate_x = local_x;
    state.label_bg.style.translate_y = label_y;
    state.label_bg.markRenderDirty();
}

/// Pick the node we should highlight this frame. Currently just the hovered
/// node, with the obvious filter that we never highlight the overlay itself.
fn pickHoverTarget(cx: *Cx) ?*Node {
    const hovered = cx.hovered_node orelse return null;
    if (!hovered.frame_state.state_bits.flags.inspectable) return null;
    return hovered;
}

/// Toggle the overlay's visibility by collapsing its children to zero size.
/// Cheaper than removing/re-adding nodes, and safe to call from
/// `on_before_render`.
fn setHidden(state: *OverlayState, hidden: bool) void {
    state.hidden = hidden;
    if (hidden) {
        state.box.style.width = .{ .px = 0 };
        state.box.style.height = .{ .px = 0 };
        state.box.markRenderDirty();
        state.box.markLayoutDirty();

        if (state.label.getText()) |__old_t| {
            var __t = __old_t;
            __t.content = "";
            state.label.setText(__t);
        }
        state.label.markRenderDirty();
        state.label.markLayoutDirty();

        // label_bg 是 fit + padding + 不透明背景：只清文本仍会留一个
        // ~12×4px 的残点钉在最后的悬停位置。移出视口（尺寸清零挡不住
        // padding 的自撑尺寸）。
        state.label_bg.style.translate_x = -10_000;
        state.label_bg.style.translate_y = -10_000;
        state.label_bg.markRenderDirty();
        state.label_bg.markLayoutDirty();
    }
}

// ============================================================================
// Tests
// ============================================================================

test "overlay: attach mounts a 4-child container under the parent" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try builders.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const overlay_node = try attach(cx, scope, root, .{});

    // Root now has the overlay container as its only child.
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(overlay_node, root.children.items[0]);

    // Container should hold: highlight box + label background. Label text
    // is nested under the label background, so direct children = 2.
    try std.testing.expectEqual(@as(usize, 2), overlay_node.children.items.len);

    // anim_state was wired so beforeRender can find OverlayState.
    try std.testing.expect(overlay_node.meta.per_frame.hooks.slots.anim_state != null);
    try std.testing.expectEqual(beforeRender, overlay_node.meta.per_frame.hooks.before_render.main.?);
}

test "overlay: hidden when nothing is hovered" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try builders.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const overlay_node = try attach(cx, scope, root, .{});

    // hovered_node = null at startup; running the hook shouldn't crash and
    // should leave the box collapsed.
    cx.hovered_node = null;
    overlay_node.meta.per_frame.hooks.before_render.main.?(overlay_node);

    const state: *OverlayState = @ptrCast(@alignCast(overlay_node.meta.per_frame.hooks.slots.anim_state.?));
    try std.testing.expect(state.hidden);
    try std.testing.expectEqual(Sizing{ .px = 0 }, state.box.style.width);
    try std.testing.expectEqual(Sizing{ .px = 0 }, state.box.style.height);
}

test "overlay: positions the highlight over the hovered node" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try builders.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const overlay_node = try attach(cx, scope, root, .{});

    // Simulate a node sitting at (50,30) sized 120×40.
    const target = try builders.box(cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    target.meta.ownership.meta.component_name = "Target";
    try root.appendChild(std.testing.allocator, target);
    target.setLayoutRect(.{ .x = 50, .y = 30, .w = 120, .h = 40 });

    cx.hovered_node = target;
    overlay_node.meta.per_frame.hooks.before_render.main.?(overlay_node);

    const state: *OverlayState = @ptrCast(@alignCast(overlay_node.meta.per_frame.hooks.slots.anim_state.?));
    try std.testing.expect(!state.hidden);
    try std.testing.expectApproxEqAbs(@as(f32, 50), state.box.style.translate_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), state.box.style.translate_y, 0.001);
    try std.testing.expectEqual(Sizing{ .px = 120 }, state.box.style.width);
    try std.testing.expectEqual(Sizing{ .px = 40 }, state.box.style.height);

    // Label content should mention the dimensions and component_name.
    const label_content = state.label.getText().?.content;
    try std.testing.expect(std.mem.indexOf(u8, label_content, "120 × 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, label_content, "Target") != null);
}

test "overlay: attach 在非原点父节点下不双重计入父偏移" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try builders.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    // 内容区壳（如 title bar 下方），世界位置 (100, 50)。
    const wrapper = try builders.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 250 } }, .{});
    try root.appendChild(std.testing.allocator, wrapper);
    wrapper.setLayoutRect(.{ .x = 100, .y = 50, .w = 300, .h = 250 });

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const overlay_node = try attach(cx, scope, wrapper, .{});

    const target = try builders.box(cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 40 } }, .{});
    try wrapper.appendChild(std.testing.allocator, target);
    target.setLayoutRect(.{ .x = 50, .y = 30, .w = 120, .h = 40 });

    cx.hovered_node = target;
    overlay_node.meta.per_frame.hooks.before_render.main.?(overlay_node);

    // box 是 container（挂在 wrapper 下）的子节点：translate 必须是
    // container-local 的 (50, 30)，而不是 world 的 (150, 80) ——
    // 后者叠加 wrapper 自身位置后会画到 (250, 130)。
    const state: *OverlayState = @ptrCast(@alignCast(overlay_node.meta.per_frame.hooks.slots.anim_state.?));
    try std.testing.expectApproxEqAbs(@as(f32, 50), state.box.style.translate_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), state.box.style.translate_y, 0.001);
}

test "overlay: scope 先销毁时摘干净所有指回 state 的引用（UAF 防线）" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try builders.box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    const overlay_node = try attach(cx, scope, root, .{});
    try std.testing.expect(overlay_node.meta.per_frame.hooks.before_render.main != null);
    try std.testing.expect(overlay_node.meta.ownership.hooks.on_cleanup != null);

    // scope 先于节点树销毁（组件级 scope 卸载的顺序）——
    // dispose 后节点树仍在渲染，任何残留引用都是下一帧的 use-after-free。
    scope.dispose();
    try std.testing.expect(overlay_node.meta.per_frame.hooks.before_render.main == null);
    try std.testing.expect(overlay_node.meta.per_frame.hooks.slots.anim_state == null);
    try std.testing.expect(overlay_node.meta.ownership.hooks.on_cleanup == null);
}

test "overlay: skips inspectable=false nodes (so it doesn't highlight itself)" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();

    const root = try builders.box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const overlay_node = try attach(cx, scope, root, .{});

    // Simulate hover landing on the overlay's own box. inspectable=false
    // (set in attach) → overlay should remain hidden.
    cx.hovered_node = overlay_node;
    overlay_node.meta.per_frame.hooks.before_render.main.?(overlay_node);

    const state: *OverlayState = @ptrCast(@alignCast(overlay_node.meta.per_frame.hooks.slots.anim_state.?));
    try std.testing.expect(state.hidden);
}
