/// Tag Component
///
/// Tag/label component for categorization, filtering, etc.
///
/// Features:
/// - Multiple color variants
/// - Closable
/// - Outline mode
/// - Two sizes.
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;

/// Tag color.
pub const TagColor = enum {
    neutral,
    accent,
    success,
    warning,
    danger,
    info,
};

/// Tag variant.
pub const TagVariant = enum {
    default,
    outline,
};

/// Tag size.
pub const TagSize = enum { sm, md };

/// Create Tag: `W.Tag(.{ .label = "Beta", .color = .accent })`. Props: text (empty = no text) /
/// variant / color (can toggle by state) / size / closable / on_close / close_icon_asset. View in
/// tag.yix, styles in styles.yss.
pub const Tag = @import("_tag.yix.zig").Tag;

// ========== Tests ==========

test "Tag: basic text" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tag_node = try Tag(.{ .label = "Hello", .color = .accent }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tag_node);

    // Has 1 child: label_text.
    try std.testing.expectEqual(@as(usize, 1), tag_node.children.items.len);
}

test "Tag: closable" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tag_node = try Tag(.{ .label = "Closable", .closable = true }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tag_node);

    // Has 2 children: label_text + close_btn.
    try std.testing.expectEqual(@as(usize, 2), tag_node.children.items.len);
}

test "Tag: outline variant" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tag_node = try Tag(.{ .label = "Outline", .variant = .outline, .color = .success }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tag_node);

    // Outline has border.
    try std.testing.expectEqual(@as(f32, 1), tag_node.style.border.width);
}

test "Tag: sizes" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const sm = try Tag(.{ .label = "SM", .size = .sm }).mount(scope, ctx);
    const md = try Tag(.{ .label = "MD", .size = .md }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, sm);
    try root.appendChild(std.testing.allocator, md);

    // COMPONENTS.json Tag / *: 22px default height.
    try std.testing.expectEqual(@as(f32, 22), sm.style.height.px);
    try std.testing.expectEqual(@as(f32, 22), md.style.height.px);
}

test "Tag: background color is set" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tag_node = try Tag(.{ .label = "Test", .color = .accent }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tag_node);

    // Validate background not transparent.
    try std.testing.expect(tag_node.getBackground().a > 0);
    try std.testing.expect(tag_node.style.height.px > 0);

    // COMPONENTS.json Tag / accent: dedicated tonal surface.
    try std.testing.expect(tag_node.getBackground().r > 0);
    try std.testing.expect(tag_node.getBackground().g > 0);
    try std.testing.expect(tag_node.getBackground().b > 0);
}

fn label(n: *Node) ?*Node {
    if (n.getText() != null) return n;
    for (n.children.items) |c| if (label(c)) |t| return t;
    return null;
}

test "Tag: 静态 props 不建 effect；关闭按钮调 on_close" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const closed = try scope.createSignal(bool, false);
    const before = ctx.owner.graph.countByKind();
    const plain = try Tag(.{ .label = "Beta", .color = .accent, .variant = .outline }).mount(scope, ctx);
    defer ctx.freeNode(plain);
    try std.testing.expectEqual(before.get(.effect), ctx.owner.graph.countByKind().get(.effect));
    const t = try Tag(.{ .label = "Beta", .color = .accent, .closable = true, .on_close = @import("../../on.zig").set(closed, true) }).mount(scope, ctx);
    defer ctx.freeNode(t);
    const after = ctx.owner.graph.countByKind();
    // Only effect is close button _hover (hover is real interaction state).
    try std.testing.expectEqual(before.get(.effect) + 1, after.get(.effect));
    try std.testing.expectEqual(before.get(.memo), after.get(.memo));
    try std.testing.expectEqualStrings("Tag", t.meta.ownership.meta.component_name.?);
    const close = t.children.items[1];
    const h = close.behavior.events.on_click.?;
    h.callback(h.context);
    try std.testing.expect(closed.get());
}

// Test collection from styles output (see docs/STYLING.md).
test {
    _ = @import("_styles.yss.zig");
}

test "Tag: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tag", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Tag(.{ .label = "Hello", .color = .accent, .closable = true }).mount(scope, cx);
        }
    }.m);
}

test "Tag: dynamic text and color" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const status = try scope.createText("Queued", .{});
    const tone = try scope.createSignal(TagColor, .neutral);
    const tag_node = try Tag(.{ .label = status, .color = tone, .closable = true }).mount(scope, ctx);
    defer ctx.freeNode(tag_node);
    status.set("Running");
    tone.set(.success);
    const text_node = label(tag_node).?;
    try std.testing.expectEqualStrings("Running", text_node.getText().?.content);
    const k = ctx.tokens.tokens.color;
    try std.testing.expect(Color.eql(tag_node.getBackground(), k.success_tag_bg));
    try std.testing.expect(Color.eql(text_node.getText().?.color, k.success));
}

test "tag: 动态文本 / 颜色的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("tag(dynamic)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const status = try scope.createText("Queued", .{});
            const tone = try scope.createSignal(TagColor, .accent);
            return try Tag(.{ .label = status, .color = tone, .closable = true }).mount(scope, cx);
        }
    }.m);
}

test "Tag: recipe follows current theme materials and then color state" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setTheme(&theme.light);
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const color = try scope.createSignal(TagColor, .accent);
    const tag = try Tag(.{ .label = "New", .color = color, .size = .md }).mount(scope, ctx);
    ctx.root = tag;
    var custom = theme.light;
    custom.tokens.font_size.sm = 15;
    custom.tokens.space.space200 = 10;
    // COMPONENTS.json Tag / *: 6px gap uses space150.
    custom.tokens.space.space150 = 7;
    custom.tokens.color.accent = Color.hex(0x123456);
    custom.tokens.color.success = Color.hex(0x456789);
    ctx.setTheme(&custom);
    const text_node = label(tag).?;
    try std.testing.expectEqual(@as(f32, 15), text_node.getText().?.font_size);
    try std.testing.expectEqual(@as(f32, 10), tag.style.padding.left);
    try std.testing.expectEqual(@as(f32, 7), tag.style.gap);
    try std.testing.expectEqual(custom.tokens.color.accent, text_node.getText().?.color);
    color.set(.success);
    try std.testing.expectEqual(custom.tokens.color.success, text_node.getText().?.color);
    ctx.root = null;
    ctx.freeNode(tag);
}
