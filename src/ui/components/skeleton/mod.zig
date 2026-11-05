/// Skeleton Component
///
/// Loading placeholder skeleton. View in skeleton.yix, styles in styles.yss.
///
/// Features:
/// - text/circular/rectangular variant
/// - shimmer animation (`ui.view.loop`: wall-clock based reciprocal motion, no slowdown at low
///   framerate)
/// - customizable size and count (count can come from signal)
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const ConditionalStyle = core.ConditionalStyle;
const Scope = @import("../../reactive.zig").Scope;

// -- Style layer in styles.yss --
const styles = @import("_styles.yss.zig");

/// Skeleton variant
pub const SkeletonVariant = enum {
    text,
    circular,
    rectangular,
};

/// Create Skeleton: `W.Skeleton(.{ .variant = .text, .width = 200, .height = 14, .count = 3 })`
pub const Skeleton = @import("_skeleton.yix.zig").Skeleton;

// ========== Tests ==========

const render_engine = @import("../../core/render_engine/mod.zig");

const Fixture = struct {
    cx: *Cx,
    scope: *Scope,

    fn init() !Fixture {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        cx.root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
        return .{ .cx = cx, .scope = try Scope.init(std.testing.allocator, null, cx.owner) };
    }

    fn deinit(f: Fixture) void {
        f.scope.dispose();
        f.cx.deinit();
    }

    fn add(f: Fixture, n: *Node) !*Node {
        try f.cx.root.?.appendChild(std.testing.allocator, n);
        return n;
    }
};

fn runFrameHooks(n: *Node) void {
    const h = &n.meta.per_frame.hooks.before_render;
    if (h.main) |f| f(n);
    for (h.hooks[0..h.count]) |f| f.?(n);
}

test "Skeleton: 外层报 loading（只报一次），骨架块按变体与尺寸成形" {
    const f = try Fixture.init();
    defer f.deinit();
    const sk = try f.add(try Skeleton(.{ .width = 200, .height = 16 }).mount(f.scope, f.cx));
    const a11y = sk.behavior.interaction.a11y.?;
    try std.testing.expectEqual(core.A11yRole.status, a11y.role);
    try std.testing.expect(a11y.busy);
    try std.testing.expectEqualStrings("polite", a11y.live.?);
    try std.testing.expectEqual(@as(usize, 1), sk.children.items.len);
    // Explicit height overrides the 12px design default; circular uses radius.dialog.
    const bone = sk.children.items[0];
    try std.testing.expect(bone.behavior.interaction.a11y == null);
    f.cx.layout();
    try std.testing.expectEqual(@as(f32, 200), bone.rectFromWorldOrFallback().w);
    try std.testing.expectEqual(@as(f32, 16), bone.rectFromWorldOrFallback().h);
    try std.testing.expectEqual(@as(f32, 4), bone.style.effectiveRadius());

    const circle = try f.add(try Skeleton(.{ .variant = .circular, .width = 48 }).mount(f.scope, f.cx));
    f.cx.layout();
    const dot = circle.children.items[0];
    try std.testing.expectEqual(@as(f32, 48), dot.rectFromWorldOrFallback().h);
    try std.testing.expectEqual(@as(f32, 12), dot.style.effectiveRadius());
}

test "Skeleton: multiple" {
    const f = try Fixture.init();
    defer f.deinit();
    const sk = try f.add(try Skeleton(.{ .count = 3, .width = 200 }).mount(f.scope, f.cx));
    try std.testing.expectEqual(@as(usize, 3), sk.children.items.len);
}

test "Skeleton: 个数来自信号时随之增减" {
    const f = try Fixture.init();
    defer f.deinit();
    const n = try f.scope.createSignal(u8, 2);
    const sk = try f.add(try Skeleton(.{ .count = n }).mount(f.scope, f.cx));
    const bones = struct {
        fn count(node: *Node) usize {
            var k: usize = 0;
            for (node.children.items) |c| k += @intFromBool(c.style.effectiveRadius() > 0);
            return k;
        }
    }.count;
    try std.testing.expectEqual(@as(usize, 2), bones(sk));
    n.set(5);
    try std.testing.expectEqual(@as(usize, 5), bones(sk));
    n.set(0); // At least one
    try std.testing.expectEqual(@as(usize, 1), bones(sk));
}

test "Skeleton: shimmer 按帧时钟在基色与高亮色之间往返；关掉动画时没有帧 hook" {
    const f = try Fixture.init();
    defer f.deinit();
    const saved = render_engine.current_frame_time_ms;
    defer render_engine.current_frame_time_ms = saved;
    render_engine.current_frame_time_ms = 0;
    const sk = try f.add(try Skeleton(.{}).mount(f.scope, f.cx));
    const bone = sk.children.items[0];
    try std.testing.expect(bone.hasBeforeRenderHooks());
    const t = f.cx.tokens;
    // COMPONENTS.json Skeleton / *: semantic skeleton surface.
    const base = t.tokens.color.skeleton;
    const high = Color.lerp(base, t.tokens.color.bg_primary, 0.25);
    render_engine.current_frame_time_ms = styles.shimmer_period_ms * 0.25; // sin = 1: highlight end
    runFrameHooks(bone);
    try std.testing.expect(Color.eql(high, bone.getBackground()));
    render_engine.current_frame_time_ms = styles.shimmer_period_ms * 0.75; // sin = -1: base color end
    runFrameHooks(bone);
    try std.testing.expect(Color.eql(base, bone.getBackground()));

    const still = try f.add(try Skeleton(.{ .animate = false }).mount(f.scope, f.cx));
    try std.testing.expect(!still.children.items[0].hasBeforeRenderHooks());
    try std.testing.expect(Color.eql(base, still.children.items[0].getBackground()));
}

// styles.yss test collection; this line is required per docs/STYLING.md
test {
    _ = @import("_styles.yss.zig");
}

// Per-allocation point OOM sweep, see src/ui/components/oom_sweep.zig
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
