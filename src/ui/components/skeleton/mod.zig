/// Skeleton Component
///
/// 加载占位骨架屏
///
/// 特性:
/// - text/circular/rectangular 变体
/// - shimmer 动画
/// - 可自定义尺寸
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const ConditionalStyle = core.ConditionalStyle;
const Scope = @import("../../reactive.zig").Scope;

// ── 样式层在 styles.zig ──
const styles = @import("styles.zig");

/// Skeleton 变体
pub const SkeletonVariant = enum {
    text,
    circular,
    rectangular,

    pub fn style(self: SkeletonVariant, t: *const theme.ThemeTokens) ConditionalStyle {
        return styles.variantStyle(self, t);
    }
};

/// Skeleton 属性
pub const SkeletonProps = struct {
    variant: SkeletonVariant = .text,
    width: f32 = 200,
    height: f32 = 16,
    animate: bool = true,
    count: u8 = 1,
    gap: f32 = 8,
};

/// Skeleton 动画状态
const ShimmerState = struct {
    tick: u32 = 0,
    node: *Node,
    base_color: Color,
    highlight_color: Color,
};

/// 创建 Skeleton
/// 占位骨架在视觉上就是"内容还没来"，AT 侧必须靠 busy 说出来，否则屏幕
/// 阅读器只会念到一片什么都没有的空白，用户以为页面坏了。live=polite 让
/// 内容真正到位时能被顺带播报。
fn loadingA11y() core.A11yProps {
    return .{
        .role = .status,
        .label = "Loading",
        .busy = true,
        .live = "polite",
    };
}

pub fn Skeleton(props: SkeletonProps) SkeletonBuilder {
    return SkeletonBuilder{ .props = props };
}

pub const SkeletonBuilder = struct {
    props: SkeletonProps,

    pub fn variant(self: SkeletonBuilder, v: SkeletonVariant) SkeletonBuilder {
        var new = self;
        new.props.variant = v;
        return new;
    }

    pub fn width(self: SkeletonBuilder, w: f32) SkeletonBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    pub fn height(self: SkeletonBuilder, h: f32) SkeletonBuilder {
        var new = self;
        new.props.height = h;
        return new;
    }

    pub fn count(self: SkeletonBuilder, c: u8) SkeletonBuilder {
        var new = self;
        new.props.count = c;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: SkeletonBuilder, scope: *Scope, cx: *Cx) !*Node {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;

        const actual_count = @max(p.count, 1);

        // 单个 skeleton 还是多个
        if (actual_count == 1) {
            const node = try buildSingle(my_scope, cx, allocator, t, p);
            // sweep：bindScopeToNode 失败时节点不能漏
            errdefer cx.freeNode(node);
            try core.bindScopeToNode(my_scope, node);
            node.behavior.interaction.a11y = loadingA11y();
            return node;
        }

        // 多个包在容器里
        const container = try box(cx, .{
            .width = .{ .fit = .{} },
            .height = .{ .fit = .{} },
            .direction = .column,
            .gap = p.gap,
        }, .{});
        // sweep：container 守到 return；子骨架建好即 adopt
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Skeleton";
        try core.bindScopeToNode(my_scope, container);
        // 只有外层容器报 loading, buildSingle 出来的子骨架不带 a11y，
        // 否则 AT 会把"正在加载"念 N 遍。
        container.behavior.interaction.a11y = loadingA11y();

        for (0..actual_count) |_| {
            _ = try core.adoptChild(cx, allocator, container, try buildSingle(my_scope, cx, allocator, t, p));
        }

        return container;
    }
};

fn buildSingle(scope: *Scope, cx: *Cx, allocator: Allocator, t: *const theme.ThemeTokens, p: SkeletonProps) !*Node {
    const radius = styles.skeletonRadius(p.variant, p.width, t);

    const h: f32 = switch (p.variant) {
        .text => p.height,
        .circular => p.width, // 正方形
        .rectangular => p.height,
    };

    const base_color = styles.skeletonBaseColor(t);

    const node = try box(cx, .{
        .width = .{ .px = p.width },
        .height = .{ .px = h },
        .background = base_color,
        .border = .{ .radius = radius },
    }, .{});
    // sweep：shimmer 状态分配 / 登记失败时节点不能漏
    errdefer cx.freeNode(node);
    node.meta.ownership.meta.component_name = "Skeleton";

    if (p.animate) {
        const highlight_color = styles.skeletonHighlightColor(t);

        const shimmer = try allocator.create(ShimmerState);
        shimmer.* = .{
            .node = node,
            .base_color = base_color,
            .highlight_color = highlight_color,
        };
        try scope.adoptResource(@ptrCast(shimmer), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                alloc.destroy(@as(*ShimmerState, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);

        node.meta.per_frame.hooks.slots.anim_state = @ptrCast(shimmer);
        node.meta.per_frame.hooks.before_render.main = shimmerBeforeRender;
    }

    return node;
}

fn shimmerBeforeRender(node: *Node) void {
    if (node.meta.per_frame.hooks.slots.anim_state) |ctx_ptr| {
        const shimmer: *ShimmerState = @ptrCast(@alignCast(ctx_ptr));
        shimmer.tick +%= 1;

        // 视口外跳过重绘，避免阻止 displayLink idle-stop
        if (node.frame_state.state_bits.flags.out_of_viewport) return;

        // 用正弦函数平滑过渡 base ↔ highlight
        const cycle: f32 = @floatFromInt(shimmer.tick % 120);
        const t_val = (1.0 + @sin(cycle * std.math.pi * 2.0 / 120.0)) * 0.5;

        node.setBackgroundRaw(Color.lerp(shimmer.base_color, shimmer.highlight_color, t_val));
        node.markRenderDirty();
    }
}

// ========== 测试 ==========

test "Skeleton: text single" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const sk = try Skeleton(.{ .width = 200, .height = 16 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, sk);
    try std.testing.expect(sk.meta.per_frame.hooks.before_render.main != null);
}

test "Skeleton: circular" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const sk = try Skeleton(.{ .variant = .circular, .width = 48 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, sk);
}

test "Skeleton: multiple" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const sk = try Skeleton(.{ .count = 3, .width = 200 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, sk);
    try std.testing.expectEqual(@as(usize, 3), sk.children.items.len);
}

test "Skeleton: no animation" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const sk = try Skeleton(.{ .animate = false }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, sk);
    try std.testing.expect(sk.meta.per_frame.hooks.before_render.main == null);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "skeleton(count=3): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("skeleton(count=3)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Skeleton(.{ .width = 200, .height = 16, .count = 3 }).mount(scope, cx);
        }
    }.m);
}

test "skeleton: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("skeleton", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Skeleton(.{ .width = 200, .height = 16 }).mount(scope, cx);
        }
    }.m);
}
