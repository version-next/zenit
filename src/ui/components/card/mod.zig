/// Card Component.
/// Card container: title / subtitle + content area (children). View in card.yix; style in
/// styles.yss.
/// Features:
/// - Variants: default, outlined, elevated
/// - Interactive (Tab sequence / a11y button) / hoverable
/// - Selected state (pass signal / derived value): 1px accent-border, no hover highlight.
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;

/// Card variant.
pub const CardVariant = enum {
    default,
    outlined,
    elevated,
};

/// Create Card: `W.Card(.{ .title = "Plan", .selected = is_current, .on_click = cx.on(S, s, S.pick)
/// })`.
/// Child elements placed in content via `ui.view.with(W.Card(...), .{ ... })`.
pub const Card = @import("_card.yix.zig").Card;

// ========== Tests ==========

const view = @import("../../view.zig");

const Fixture = struct {
    cx: *Cx,
    scope: *Scope,

    fn init() !Fixture {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        cx.root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        return .{ .cx = cx, .scope = try Scope.init(std.testing.allocator, null, cx.owner) };
    }

    fn deinit(f: Fixture) void {
        f.scope.dispose();
        f.cx.deinit();
    }

    /// Mount under root (layout / click / theme change need tree position).
    fn add(f: Fixture, n: *Node) !*Node {
        try f.cx.root.?.appendChild(std.testing.allocator, n);
        return n;
    }
};

fn findText(n: *Node, text: []const u8) ?*Node {
    if (n.getText()) |t| if (std.mem.eql(u8, t.content, text)) return n;
    for (n.children.items) |c| if (findText(c, text)) |r| return r;
    return null;
}

/// During transition take target value, else current value.
fn backgroundTarget(n: *Node) Color {
    const slot = n.frame_state.frame_local.runtime.transitions.?.find(.background).?;
    return if (slot.active) slot.to_color else n.getBackground();
}

fn borderTarget(n: *Node) Color {
    const slot = n.frame_state.frame_local.runtime.transitions.?.find(.border_color).?;
    return if (slot.active) slot.to_color else n.style.border.color;
}

fn hover(n: *Node, on: bool) void {
    const h = if (on) n.behavior.events.on_hover.? else n.behavior.events.on_leave.?;
    h.callback(h.context);
}

test "Card: 标题 / 副标题 / 子元素都在卡片里，子元素进内容区" {
    const f = try Fixture.init();
    defer f.deinit();
    const card = try f.add(try view.render(f.scope, f.cx, view.with(Card(.{ .title = "Card Title", .subtitle = "Description text", .width = 300 }), .{"body text"})));
    f.cx.layout();
    const title = findText(card, "Card Title").?;
    const sub = findText(card, "Description text").?;
    const body_text = findText(card, "body text").?;
    try std.testing.expectEqual(@as(f32, 300), card.rectFromWorldOrFallback().w);
    // All coords relative to parent: header = 14 padding + title 18 + gap 2 + subtitle 16 + 2;
    // content follows, 8px top and 16px side padding.
    const body = body_text.parent.?;
    try std.testing.expectEqual(title.parent.?, sub.parent.?);
    try std.testing.expectEqual(@as(f32, 14), title.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 18), title.rectFromWorldOrFallback().h);
    try std.testing.expectEqual(@as(f32, 34), sub.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 16), sub.rectFromWorldOrFallback().h);
    try std.testing.expectEqual(card, body.parent.?);
    try std.testing.expectEqual(@as(f32, 52), body.rectFromWorldOrFallback().y);
    try std.testing.expectEqual(@as(f32, 16), body_text.rectFromWorldOrFallback().x);
    try std.testing.expectEqualStrings("Card", card.meta.ownership.meta.component_name.?);
}

test "Card: 没有标题时不建 header；padded = false 时内容贴边" {
    const f = try Fixture.init();
    defer f.deinit();
    const card = try f.add(try view.render(f.scope, f.cx, view.with(Card(.{ .padded = false, .width = 200 }), .{"edge"})));
    f.cx.layout();
    try std.testing.expectEqual(@as(usize, 1), card.children.items.len);
    try std.testing.expectEqual(@as(f32, 0), findText(card, "edge").?.rectFromWorldOrFallback().x);
}

test "Card: 变体决定边框与阴影" {
    const f = try Fixture.init();
    defer f.deinit();
    const t = f.cx.tokens;
    const plain = try Card(.{}).mount(f.scope, f.cx);
    defer f.cx.freeNode(plain);
    const outlined = try Card(.{ .variant = .outlined }).mount(f.scope, f.cx);
    defer f.cx.freeNode(outlined);
    const elevated = try Card(.{ .variant = .elevated }).mount(f.scope, f.cx);
    defer f.cx.freeNode(elevated);
    // COMPONENTS.json Card / *: transparent default outline, 1px outlined/elevated.
    try std.testing.expectEqual(@as(f32, 1), plain.style.border.width);
    try std.testing.expect(Color.eql(t.tokens.color.transparent, plain.style.border.color));
    try std.testing.expect(Color.eql(t.tokens.color.border, outlined.style.border.color));
    try std.testing.expectEqual(@as(f32, 1), elevated.style.border.width);
    try std.testing.expect(elevated.style.shadow() != null);
    try std.testing.expect(Color.eql(t.tokens.color.bg_primary, elevated.getBackground()));
}

test "Card: 可点击的卡片进 Tab 序、对 AT 报按钮（名称取标题），点击回调" {
    const f = try Fixture.init();
    defer f.deinit();
    var clicked = false;
    const card = try f.add(try Card(.{ .title = "Pro", .width = 200, .height = 100, .on_click = f.cx.on(bool, &clicked, struct {
        fn handler(ptr: *bool) void {
            ptr.* = true;
        }
    }.handler) }).mount(f.scope, f.cx));
    f.cx.layout();
    f.cx.handleClick(card.rectFromWorldOrFallback().x + 10, card.rectFromWorldOrFallback().y + 10);
    try std.testing.expect(clicked);
    // Clickable card must be keyboard-accessible + have role for a11y (WCAG 2.1.1 / 4.1.2).
    try std.testing.expect(card.behavior.interaction.focusable);
    const a11y = card.behavior.interaction.a11y orelse return error.TestExpectedA11yProps;
    try std.testing.expectEqual(core.A11yRole.button, a11y.role);
    try std.testing.expectEqualStrings("Pro", a11y.label.?);
}

test "Card: 纯展示卡片不进 Tab 序、没有语义节点" {
    const f = try Fixture.init();
    defer f.deinit();
    const card = try Card(.{ .width = 200, .height = 100, .title = "Static" }).mount(f.scope, f.cx);
    defer f.cx.freeNode(card);
    // Display-only card in Tab sequence creates empty landing for keyboard users.
    try std.testing.expect(!card.behavior.interaction.focusable);
    try std.testing.expect(card.behavior.interaction.a11y == null);
}

test "Card: selected from a signal switches the border and a11y selected" {
    const f = try Fixture.init();
    defer f.deinit();
    const picked = try f.scope.createSignal(bool, false);
    const card = try Card(.{ .title = "Pro", .variant = .outlined, .selected = picked, .interactive = true }).mount(f.scope, f.cx);
    defer f.cx.freeNode(card);
    const t = f.cx.tokens;
    try std.testing.expectEqual(@as(f32, 1), card.style.border.width);
    try std.testing.expect(!card.behavior.interaction.a11y.?.selected);

    // COMPONENTS.json Card / selected: 1px accent_border.
    picked.set(true);
    try std.testing.expectEqual(@as(f32, 1), card.style.border.width);
    try std.testing.expect(Color.eql(borderTarget(card), t.tokens.color.accent_border));
    try std.testing.expect(card.behavior.interaction.a11y.?.selected);

    picked.set(false);
    try std.testing.expectEqual(@as(f32, 1), card.style.border.width);
    try std.testing.expect(Color.eql(borderTarget(card), t.tokens.color.border));
}

test "Card: hover highlights the background only while not selected; outlined highlights the border" {
    const f = try Fixture.init();
    defer f.deinit();
    const t = f.cx.tokens;
    const picked = try f.scope.createSignal(bool, false);
    const card = try Card(.{ .title = "Plan", .selected = picked, .hoverable = true }).mount(f.scope, f.cx);
    defer f.cx.freeNode(card);
    hover(card, true);
    try std.testing.expect(Color.eql(backgroundTarget(card), t.tokens.color.bg_active));
    // COMPONENTS.json Card / selected: 1px accent_border.
    picked.set(true);
    try std.testing.expect(Color.eql(backgroundTarget(card), t.tokens.color.accent_surface));
    picked.set(false);
    try std.testing.expect(Color.eql(backgroundTarget(card), t.tokens.color.bg_active));
    hover(card, false);
    // COMPONENTS.json Card / default: resting surface is bg_secondary.
    try std.testing.expect(Color.eql(backgroundTarget(card), t.tokens.color.bg_secondary));

    const outlined = try Card(.{ .variant = .outlined, .interactive = true }).mount(f.scope, f.cx);
    defer f.cx.freeNode(outlined);
    hover(outlined, true);
    try std.testing.expect(Color.eql(borderTarget(outlined), t.tokens.color.accent));
    try std.testing.expect(Color.eql(backgroundTarget(outlined), t.tokens.color.bg_primary));
}

test "Card: static, non-hover card builds no effect and no hover hook" {
    const f = try Fixture.init();
    defer f.deinit();
    const before = f.cx.owner.graph.countByKind().get(.effect);
    const card = try Card(.{ .title = "Static", .subtitle = "s", .selected = true }).mount(f.scope, f.cx);
    defer f.cx.freeNode(card);
    try std.testing.expectEqual(before, f.cx.owner.graph.countByKind().get(.effect));
    try std.testing.expect(card.behavior.events.on_hover == null);
    try std.testing.expectEqual(@as(f32, 1), card.style.border.width);
}

test "Card: 换主题时颜色跟随" {
    const f = try Fixture.init();
    defer f.deinit();
    const card = try f.add(try Card(.{ .title = "T", .variant = .outlined }).mount(f.scope, f.cx));
    f.cx.setTheme(&core.theme.dark);
    try std.testing.expect(Color.eql(core.theme.dark.tokens.color.bg_primary, card.getBackground()));
    try std.testing.expect(Color.eql(core.theme.dark.tokens.color.border, card.style.border.color));
    try std.testing.expect(Color.eql(core.theme.dark.tokens.color.fg_primary, findText(card, "T").?.getText().?.color));
}

// Test collection from style artifacts (see docs/STYLING.md).
test {
    _ = @import("_styles.yss.zig");
}

// Per-allocation OOM sweep; see src/ui/components/oom_sweep.zig.
test "card: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("card", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Card(.{ .title = "Title", .subtitle = "Sub", .interactive = true, .hoverable = true }).mount(scope, cx);
        }
    }.m);
}

test "card: 动态 selected 的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("card(dynamic)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const picked = try scope.createSignal(bool, true);
            return try Card(.{ .title = "Title", .selected = picked, .hoverable = true }).mount(scope, cx);
        }
    }.m);
}

test "Card: title / subtitle 来自 signal —— 跟随变化，空时移除行与 header，交互卡 a11y 名称跟随" {
    const f = try Fixture.init();
    defer f.deinit();
    const title = try f.scope.createText("Pro", .{});
    const sub = try f.scope.createText("", .{});
    const card = try Card(.{ .title = title, .subtitle = sub, .interactive = true }).mount(f.scope, f.cx);
    defer f.cx.freeNode(card);
    try std.testing.expect(findText(card, "Pro") != null);
    try std.testing.expectEqualStrings("Pro", card.behavior.interaction.a11y.?.label.?);

    title.set("Enterprise");
    try std.testing.expect(findText(card, "Enterprise") != null);
    try std.testing.expectEqualStrings("Enterprise", card.behavior.interaction.a11y.?.label.?);
    sub.set("Billed yearly");
    try std.testing.expect(findText(card, "Billed yearly") != null);

    title.set("");
    sub.set("");
    try std.testing.expect(findText(card, "Billed yearly") == null);
    // Remove entire header: card has only content area (and anchor).
    var boxes: usize = 0;
    for (card.children.items) |c| boxes += @intFromBool(c.children.items.len > 0 or c.style.padding.top > 0);
    try std.testing.expectEqual(@as(usize, 1), boxes);
    try std.testing.expect(card.behavior.interaction.a11y.?.label == null);
}

test "card(dynamic title): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("card(dynamic title)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const title = try scope.createText("T", .{});
            return try Card(.{ .title = title, .subtitle = "s", .interactive = true }).mount(scope, cx);
        }
    }.m);
}
