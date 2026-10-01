/// 动画预设库，常用动画效果的一键封装
///
/// 类似 GSAP registerEffect，每个预设内部调用 animateNode()。
///
/// 用法:
/// ```zig
/// const presets = @import("animation/presets.zig");
///
/// presets.fadeIn(node, allocator, .{});
/// presets.slideInUp(node, allocator, .{ .distance = 30, .duration = 0.4 });
/// presets.scaleIn(node, allocator, .{ .from_scale = 0.8 });
/// presets.shake(node, allocator, .{ .intensity = 10 });
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_animator = @import("node_animator.zig");
const animateNode = node_animator.animateNode;
const Easing = @import("easing.zig").Easing;

// ============ Fade ============

pub const FadeOpts = struct {
    duration: f32 = 0.3,
    easing: Easing = .ease_out_quad,
    delay: f32 = 0,
};

/// 淡入：opacity 0 -> 1
pub fn fadeIn(node: anytype, allocator: Allocator, opts: FadeOpts) void {
    animateNode(node, allocator, .{
        .prop = .opacity,
        .from = 0,
        .to = 1,
        .duration = opts.duration,
        .easing = opts.easing,
        .delay = opts.delay,
    });
}

// ============ Slide ============

pub const SlideOpts = struct {
    distance: f32 = 20,
    duration: f32 = 0.4,
    easing: Easing = .ease_out_cubic,
    delay: f32 = 0,
    fade: bool = true,
};

/// 从下方滑入
pub fn slideInUp(node: anytype, allocator: Allocator, opts: SlideOpts) void {
    animateNode(node, allocator, .{
        .prop = .translate_y,
        .from = opts.distance,
        .to = 0,
        .duration = opts.duration,
        .easing = opts.easing,
        .delay = opts.delay,
    });
    if (opts.fade) {
        animateNode(node, allocator, .{
            .prop = .opacity,
            .from = 0,
            .to = 1,
            .duration = opts.duration * 0.6,
            .easing = opts.easing,
            .delay = opts.delay,
        });
    }
}

/// 从上方滑入
pub fn slideInDown(node: anytype, allocator: Allocator, opts: SlideOpts) void {
    animateNode(node, allocator, .{
        .prop = .translate_y,
        .from = -opts.distance,
        .to = 0,
        .duration = opts.duration,
        .easing = opts.easing,
        .delay = opts.delay,
    });
    if (opts.fade) {
        animateNode(node, allocator, .{
            .prop = .opacity,
            .from = 0,
            .to = 1,
            .duration = opts.duration * 0.6,
            .easing = opts.easing,
            .delay = opts.delay,
        });
    }
}

// ============ Scale ============

pub const ScaleOpts = struct {
    from_scale: f32 = 0.8,
    duration: f32 = 0.3,
    easing: Easing = .ease_out_back,
    delay: f32 = 0,
    fade: bool = true,
};

/// 缩放进入（从小到大）
pub fn scaleIn(node: anytype, allocator: Allocator, opts: ScaleOpts) void {
    animateNode(node, allocator, .{
        .prop = .scale_x,
        .from = opts.from_scale,
        .to = 1.0,
        .duration = opts.duration,
        .easing = opts.easing,
        .delay = opts.delay,
    });
    animateNode(node, allocator, .{
        .prop = .scale_y,
        .from = opts.from_scale,
        .to = 1.0,
        .duration = opts.duration,
        .easing = opts.easing,
        .delay = opts.delay,
    });
    if (opts.fade) {
        animateNode(node, allocator, .{
            .prop = .opacity,
            .from = 0,
            .to = 1,
            .duration = opts.duration * 0.5,
            .easing = .ease_out_quad,
            .delay = opts.delay,
        });
    }
}

// ============ Shake ============

pub const ShakeOpts = struct {
    intensity: f32 = 8,
    duration: f32 = 0.4,
    delay: f32 = 0,
};

/// 摇晃效果（用 elastic 缓动模拟 spring）
pub fn shake(node: anytype, allocator: Allocator, opts: ShakeOpts) void {
    animateNode(node, allocator, .{
        .prop = .translate_x,
        .from = opts.intensity,
        .to = 0,
        .duration = opts.duration,
        .easing = .ease_out_elastic,
        .delay = opts.delay,
    });
}

const TestStyle = struct {
    opacity: f32 = 1.0,
    translate_x: f32 = 0,
    translate_y: f32 = 0,
    width: union(enum) { px: f32, fit, grow: struct {} } = .fit,
    height: union(enum) { px: f32, fit, grow: struct {} } = .fit,
    margin: struct { top: f32 = 0, left: f32 = 0 } = .{},
    gap: f32 = 0,
    border: struct {
        width: f32 = 0,
        pub fn setUniformWidth(self: *@This(), w: f32) void {
            self.width = w;
        }
    } = .{},

    pub fn scale_x(_: *const TestStyle) f32 {
        return test_ext.scale_x;
    }
    pub fn scale_y(_: *const TestStyle) f32 {
        return test_ext.scale_y;
    }
    pub fn corner_radius(_: *const TestStyle) ?struct { all: f32 } {
        return .{ .all = 0 };
    }
    pub fn rotate(_: *const TestStyle) f32 {
        return 0;
    }
    pub fn ensureExtPanic(_: *TestStyle, _: Allocator) *TestStyleExt {
        return &test_ext;
    }
};

const TestStyleExt = struct {
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    corner_radius: struct { all: f32 } = .{ .all = 0 },
    rotate: f32 = 0,
};

var test_ext = TestStyleExt{};

const TestNode = struct {
    style: TestStyle = .{},
    frame_state: struct {
        rect: struct { w: f32 = 100, h: f32 = 40 } = .{},
        frame_local: struct {
            runtime: struct { commands: ?*node_animator.NodeAnimations = null, transitions: ?*anyopaque = null } = .{},
        } = .{},
    } = .{},
    render_dirty: bool = false,
    layout_dirty: bool = false,
    dirty: struct {
        pipeline: struct {
            order: bool = false,
            subtree_order: bool = false,
            interaction: bool = false,
            subtree_interaction: bool = false,
            composite: bool = false,
            subtree_composite: bool = false,
        } = .{},
    } = .{},

    pub fn markRenderDirty(self: *TestNode) void {
        self.render_dirty = true;
    }
    pub fn markCompositeDirty(self: *TestNode) void {
        self.render_dirty = true;
    }
    pub fn markInteractionDirty(self: *TestNode) void {
        self.dirty.pipeline.interaction = true;
    }
    pub fn markLayoutDirty(self: *TestNode) void {
        self.layout_dirty = true;
    }
    pub fn markSizingDirty(self: *TestNode) void {
        self.layout_dirty = true;
    }
    pub fn invalidateRenderCache(_: *TestNode) void {}
    pub fn requestCompositeAnimationLinger(self: *TestNode, _: bool, _: bool) void {
        self.render_dirty = true;
    }
    pub fn setMarginTop(self: *TestNode, v: f32) void {
        self.style.margin.top = v;
        self.markLayoutDirty();
    }
    pub fn setMarginLeft(self: *TestNode, v: f32) void {
        self.style.margin.left = v;
        self.markLayoutDirty();
    }
};

test "presets.fadeIn starts from transparent and ramps over first frames" {
    var node = TestNode{};
    fadeIn(&node, std.testing.allocator, .{ .duration = 0.3 });
    defer if (node.frame_state.frame_local.runtime.commands) |anims| std.testing.allocator.destroy(anims);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), node.style.opacity, 0.0001);

    var last = node.style.opacity;
    for (0..10) |_| {
        _ = node.frame_state.frame_local.runtime.commands.?.tick(&node, std.testing.allocator, 1.0 / 60.0);
        try std.testing.expect(node.style.opacity + 0.0001 >= last);
        last = node.style.opacity;
    }
    try std.testing.expect(node.style.opacity < 1.0);
}

test "presets.slideInUp starts below and does not flash at final position" {
    var node = TestNode{};
    slideInUp(&node, std.testing.allocator, .{ .distance = 20, .duration = 0.3 });
    defer if (node.frame_state.frame_local.runtime.commands) |anims| std.testing.allocator.destroy(anims);

    try std.testing.expectApproxEqAbs(@as(f32, 20.0), node.style.translate_y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), node.style.opacity, 0.0001);

    var last_translate = node.style.translate_y;
    var last_opacity = node.style.opacity;
    for (0..10) |_| {
        _ = node.frame_state.frame_local.runtime.commands.?.tick(&node, std.testing.allocator, 1.0 / 60.0);
        try std.testing.expect(node.style.translate_y <= last_translate + 0.0001);
        try std.testing.expect(node.style.opacity + 0.0001 >= last_opacity);
        last_translate = node.style.translate_y;
        last_opacity = node.style.opacity;
    }
    try std.testing.expect(node.style.translate_y > 0);
}

test "presets.slideInDown starts above and does not flash at final position" {
    var node = TestNode{};
    slideInDown(&node, std.testing.allocator, .{ .distance = 20, .duration = 0.3 });
    defer if (node.frame_state.frame_local.runtime.commands) |anims| std.testing.allocator.destroy(anims);

    try std.testing.expectApproxEqAbs(@as(f32, -20.0), node.style.translate_y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), node.style.opacity, 0.0001);

    var last_translate = node.style.translate_y;
    var last_opacity = node.style.opacity;
    for (0..10) |_| {
        _ = node.frame_state.frame_local.runtime.commands.?.tick(&node, std.testing.allocator, 1.0 / 60.0);
        try std.testing.expect(node.style.translate_y >= last_translate - 0.0001);
        try std.testing.expect(node.style.opacity + 0.0001 >= last_opacity);
        last_translate = node.style.translate_y;
        last_opacity = node.style.opacity;
    }
    try std.testing.expect(node.style.translate_y < 0);
}
