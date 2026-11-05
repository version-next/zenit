/// Badge Component.
/// Status/count display badge.
/// Features:
/// - Variants: info, success, warning, error
/// - Sizes: sm, md
/// - Dot mode
/// View in badge.yix; styles in styles.yss. All props are static value
/// or reactive source; static props don't create effects.
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const Color = core.Color;
const theme = core.theme;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const views = @import("_badge.yix.zig");

/// Badge status.
pub const BadgeStatus = enum {
    info,
    success,
    warning,
    @"error",
};

/// Badge size.
pub const BadgeSize = enum { sm, md };

/// Create Badge: `W.Badge(.{ .count = unread, .dot = ui.map(unread, isZero) })`.
/// Props: text / count / max_count / status / size / dot. Display: text if
/// non-empty, else count if non-null ("N+" if exceeds max_count); dot=true shows 8x8 circle.
pub const Badge = views.Badge;

/// Status badge (status dot + label): `W.StatusBadge(.{ .status = .success, .label = "Online" })`.
pub const StatusBadge = views.StatusBadge;

// ========== Tests ==========

const Env = struct {
    cx: *Cx,
    scope: *Scope,
    root: ?*Node = null,

    fn init() !Env {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        cx.setTheme(&theme.light);
        return .{ .cx = cx, .scope = try Scope.init(std.testing.allocator, null, cx.owner) };
    }
    fn deinit(e: *Env) void {
        e.scope.dispose();
        e.cx.root = null;
        if (e.root) |r| e.cx.freeNode(r);
        e.cx.deinit();
    }
    fn mount(e: *Env, element: anytype) !*Node {
        e.root = try element.mount(e.scope, e.cx);
        e.cx.root = e.root;
        return e.root.?;
    }
};

/// First node with text in subtree.
fn label(n: *Node) ?*Node {
    if (n.getText() != null) return n;
    for (n.children.items) |c| if (label(c)) |t| return t;
    return null;
}

fn labelText(n: *Node) ?[]const u8 {
    return (label(n) orelse return null).getText().?.content;
}

test "Badge: text" {
    var e = try Env.init();
    defer e.deinit();
    const b = try e.mount(Badge(.{ .label = "New", .status = .info }));
    // Root node carries text (node found by test_id has text).
    try std.testing.expectEqualStrings("New", b.getText().?.content);
    try std.testing.expectEqualStrings("Badge", b.meta.ownership.meta.component_name.?);
}

test "Badge: count 与溢出显示" {
    var e = try Env.init();
    defer e.deinit();
    const root = try e.mount(Badge(.{ .count = 42, .status = .success }));
    try std.testing.expectEqualStrings("42", labelText(root).?);
    const b = try Badge(.{ .max_count = 99, .count = 500 }).mount(e.scope, e.cx);
    defer e.cx.freeNode(b);
    try std.testing.expectEqualStrings("99+", labelText(b).?);
}

test "Badge: dot mode 是 8×8 圆点、没有文本" {
    var e = try Env.init();
    defer e.deinit();
    const d = try e.mount(Badge(.{ .dot = true, .status = .@"error", .label = "hidden" }));
    // Root carries text; dot mode is empty text.
    try std.testing.expectEqualStrings("", d.getText().?.content);
    e.cx.layout();
    try std.testing.expectEqual(@as(f32, 8), d.style.width.px);
    try std.testing.expectEqual(@as(f32, 8), d.style.height.px);
    try std.testing.expectEqual(theme.light.tokens.color.danger, d.getBackground());
}

test "Badge: 胶囊高度、内边距、字号与底色来自 size / status token" {
    var e = try Env.init();
    defer e.deinit();
    const b = try e.mount(Badge(.{ .label = "New", .size = .md, .status = .warning }));
    // COMPONENTS.json Badge / warning: tonal surface, 500 label weight.
    const t = theme.light.tokens;
    try std.testing.expectEqual(t.size.lg, b.style.height.px);
    try std.testing.expectEqual(t.space.space200, b.style.padding.left);
    try std.testing.expectEqual(t.color.warning_subtle, b.getBackground());
    const txt = label(b).?.getText().?;
    try std.testing.expectEqual(t.font_size.xs, txt.font_size);
    try std.testing.expectEqual(@as(u16, 500), txt.font_weight);
}

test "StatusBadge: 圆点 + 标签；空标签不显示文本" {
    var e = try Env.init();
    defer e.deinit();
    const s = try e.mount(StatusBadge(.{ .label = "Online", .status = .success }));
    try std.testing.expectEqualStrings("Online", labelText(s).?);
    try std.testing.expectEqualStrings("StatusBadge", s.meta.ownership.meta.component_name.?);
    const empty = try StatusBadge(.{}).mount(e.scope, e.cx);
    defer e.cx.freeNode(empty);
    try std.testing.expect(labelText(empty) == null);
}

// Per-allocation OOM sweep; see src/ui/components/oom_sweep.zig.
test "badge(text+status): mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("badge(text+status)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Badge(.{ .label = "New", .status = .info }).mount(scope, cx);
        }
    }.m);
}

test "status_badge: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("status_badge", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try StatusBadge(.{ .label = "Online" }).mount(scope, cx);
        }
    }.m);
}

test "badge(count signal): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("badge(signal)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const n = try scope.createSignal(?u32, 12);
            return try Badge(.{ .count = n }).mount(scope, cx);
        }
    }.m);
}

// -- Signal-first behavior --

test "Badge: count 与 dot 跟随各自的源" {
    var e = try Env.init();
    defer e.deinit();
    const unread = try e.scope.createSignal(?u32, 3);
    const quiet = reactive.map(unread, struct {
        fn f(v: ?u32) bool {
            return (v orelse 0) == 0;
        }
    }.f);
    const b = try e.mount(Badge(.{ .count = unread, .dot = quiet, .status = .@"error" }));
    if (reactive.SignalOwner.debug_checks) try std.testing.expectEqual(@as(u32, 0), e.cx.owner.debug.mount_tracked_reads);
    try std.testing.expectEqualStrings("3", labelText(b).?);
    unread.set(250);
    try std.testing.expectEqualStrings("99+", labelText(b).?);
    unread.set(0); // Dot mode: empty text, 8x8.
    e.cx.layout();
    try std.testing.expectEqualStrings("", b.getText().?.content);
    try std.testing.expectEqual(@as(f32, 8), b.style.width.px);
    unread.set(7);
    e.cx.layout();
    try std.testing.expectEqualStrings("7", labelText(b).?);
    try std.testing.expect(b.style.width == .fit);
}

test "Badge / StatusBadge: static props add no effects or memos" {
    var e = try Env.init();
    defer e.deinit();
    const before = e.cx.owner.graph.countByKind();
    const b = try Badge(.{ .label = "New", .status = .success }).mount(e.scope, e.cx);
    defer e.cx.freeNode(b);
    const s = try StatusBadge(.{ .label = "Online", .status = .success }).mount(e.scope, e.cx);
    defer e.cx.freeNode(s);
    const after = e.cx.owner.graph.countByKind();
    // Static props: content/branch fixed once; variant styles replay only on
    // theme change (node view_theme slot); not in dependency graph.
    try std.testing.expectEqual(before.get(.memo), after.get(.memo));
    try std.testing.expectEqual(before.get(.effect), after.get(.effect));
}

test "Badge: 换主题后跟随新的 token 值" {
    var e = try Env.init();
    defer e.deinit();
    const b = try e.mount(Badge(.{ .label = "New", .size = .md }));
    try std.testing.expectEqual(theme.light.tokens.size.lg, b.style.height.px);
    var custom = theme.light;
    custom.tokens.size.lg = 28;
    custom.tokens.font_size.xs = 13;
    custom.tokens.space.space200 = 10;
    custom.tokens.color.accent_subtle = Color.hex(0x123456);
    e.cx.setTheme(&custom);
    try std.testing.expectEqual(@as(f32, 28), b.style.height.px);
    try std.testing.expectEqual(@as(f32, 13), label(b).?.getText().?.font_size);
    try std.testing.expectEqual(@as(f32, 10), b.style.padding.left);
    // The text-bearing root keeps its API, while explicit line centering tracks
    // both capsule height and font-size changes with the theme.
    try std.testing.expectApproxEqAbs(@as(f32, (28.0 - 13.0 * 1.2) / 2.0), b.style.padding.top, 0.01);
    try std.testing.expectApproxEqAbs(b.style.padding.top, b.style.padding.bottom, 0.01);
    try std.testing.expectEqual(custom.tokens.color.accent_subtle, b.getBackground());
}

test {
    _ = @import("_styles.yss.zig");
}
