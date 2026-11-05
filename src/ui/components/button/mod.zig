/// Button Component
///
/// View in button.yix (composed on ControlShell), root style / label tier / glyph / loading ring in
/// styles.yss.
///
/// Features:
/// - variant: base, primary, secondary, ghost, danger, link (the shell's tone)
/// - size: xs, sm, md, lg (ControlSize); pill
/// - icon: icon button (SVG asset or texture), icon-only, leading icon (glyph icon fit)
/// - loading: load state (spinning ring, hide icon, no click)
/// - disabled: disabled state
/// - hover / press (held, pointer still inside) / focus resolve on the shell's node; label, glyph
///   and ring follow its foreground (currentColor)
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Scope = core.Scope;
const reactive = @import("../../reactive.zig");
const svg_assets = @import("../../svg_assets.zig");
const events = @import("../../events.zig");
const control_shell = @import("../control_shell/mod.zig");
const text_render = @import("../../core/render_engine/text_render.zig");
const shell_styles = @import("../control_shell/_styles.yss.zig");

/// Button variant, alias to ControlVariant (compatible)
pub const ButtonVariant = control_shell.ControlVariant;

/// Button size, alias to ControlSize (compatible)
pub const ButtonSize = control_shell.ControlSize;

/// Create button: `W.Button(.{ .label = "Save", .disabled = ui.not(dirty), .on_click = cx.on(S, s,
/// S.save) })` (button.yix, composed on ControlShell).
const ui = @import("../../ui.zig");
const button_view = @import("_button.yix.zig");
pub const Button = button_view.Button;
pub const ButtonProps = button_view.ButtonProps;
/// `Button(...)` return type (independent of arguments), for call sites that name element type
pub const ButtonBuilder = @TypeOf(Button(.{}));

// ===== Tests =====

fn findText(n: *Node, text: []const u8) ?*Node {
    if (n.getText()) |t| if (std.mem.eql(u8, t.content, text)) return n;
    for (n.children.items) |c| if (findText(c, text)) |r| return r;
    return null;
}

fn findTag(n: *Node, tag: core.ElementTag) ?*Node {
    for (n.children.items) |c| {
        if (c.tag == tag) return c;
        if (findTag(c, tag)) |r| return r;
    }
    return null;
}

/// Load indicator (self-drawn node)
fn findSpinner(n: *Node) ?*Node {
    for (n.children.items) |c| {
        if (c.meta.per_frame.custom_hooks.draw != null) return c;
        if (findSpinner(c)) |r| return r;
    }
    return null;
}

/// Text color as painted (inherited from the shell's foreground unless the text declares one).
fn paintedText(n: *Node) Color {
    return text_render.resolveNodeLogicalTextProps(n).?.color;
}

/// Glyph tint as painted (currentColor resolved).
fn paintedTint(n: *Node) Color {
    const ic = n.getIcon().?;
    return ic.paintTint(if (ic.tint_current_color) n.resolveTextColor() else null);
}

fn pressAt(cx: *Cx, node: ?*Node) void {
    cx.pressed_node = node;
    cx.notifyPressWatchers();
}

test "Button: basic creation" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{ .label = "Click Me", .variant = .primary, .size = .md }).mount(scope_val, ctx);

    try root.appendChild(std.testing.allocator, btn);

    // ControlShell slots: btn -> [icon slot (hidden: no glyph), content slot -> text]
    try std.testing.expectEqual(@as(usize, 2), btn.children.items.len);
    try std.testing.expect(btn.children.items[0].style.display == .none);
    const content_slot = btn.children.items[1];
    try std.testing.expectEqualStrings("Click Me", content_slot.children.items[0].getText().?.content);
    try std.testing.expectEqualStrings("Button", btn.meta.ownership.meta.component_name.?);
    try std.testing.expectEqual(core.ElementTag.button, btn.tag);
    try std.testing.expectEqual(core.A11yRole.button, btn.behavior.interaction.a11y.?.role);
    try std.testing.expectEqualStrings("Click Me", btn.behavior.interaction.a11y.?.label.?);
}

test "Button: variants" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    inline for (.{ ButtonVariant.primary, ButtonVariant.secondary, ButtonVariant.ghost, ButtonVariant.danger }) |v| {
        const btn = try Button(.{ .label = "Test", .variant = v }).mount(scope_val, ctx);
        try root.appendChild(std.testing.allocator, btn);
    }

    try std.testing.expectEqual(@as(usize, 4), root.children.items.len);
}

test "Button: click handler" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    var clicked = false;

    const btn = try Button(.{ .label = "Click", .on_click = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(c));
            ptr.* = true;
        }
    }.handler, &clicked) }).mount(scope_val, ctx);

    try root.appendChild(std.testing.allocator, btn);

    ctx.layout();
    ctx.handleClick(btn.rectFromWorldOrFallback().x + 10, btn.rectFromWorldOrFallback().y + 10);

    try std.testing.expect(clicked);
}

test "Button: ghost icon-only stays bare (no forced chrome)" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{
        .icon_only = true,
        .icon_asset = svg_assets.common.star,
        .variant = .ghost,
    }).mount(scope_val, ctx);

    try root.appendChild(std.testing.allocator, btn);

    try std.testing.expect(Color.eql(btn.getBackground(), Color.TRANSPARENT));
    try std.testing.expect(btn.style.border.width == 0);
}

/// The shell's tone at a state (control_shell/styles.yss Tone: the single color source).
fn toneAt(t: *const core.theme.ThemeTokens, variant: ButtonVariant, state: core.InteractionState) core.StyleOverride {
    return shell_styles.Tone.resolve(.{ .kind = variant }, t).resolve(state);
}

/// Settled value of an eased color (transition target while animating).
fn backgroundTarget(n: *Node) Color {
    if (n.frame_state.frame_local.runtime.transitions) |slots| if (slots.find(.background)) |slot| if (slot.active) return slot.to_color;
    return n.getBackground();
}

test "Button: 悬停 / 按下换底色（按下且指针仍在按钮内），禁用时没有交互态" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope_val = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope_val.dispose();
    const btn = try Button(.{ .label = "Go", .variant = .secondary }).mount(scope_val, ctx);
    defer ctx.freeNode(btn);
    const t = ctx.tokens;
    const rest = toneAt(t, .secondary, .{}).background.?;
    const hover = toneAt(t, .secondary, .{ .is_hovered = true }).background.?;
    const pressed = toneAt(t, .secondary, .{ .is_hovered = true, .is_pressed = true }).background.?;
    try std.testing.expect(!Color.eql(rest, hover) and !Color.eql(hover, pressed));
    try std.testing.expect(Color.eql(rest, backgroundTarget(btn)));
    btn.behavior.events.on_hover.?.invoke();
    try std.testing.expect(Color.eql(hover, backgroundTarget(btn)));
    pressAt(ctx, btn);
    try std.testing.expect(Color.eql(pressed, backgroundTarget(btn)));
    btn.behavior.events.on_leave.?.invoke(); // Press and drag out: back to normal
    try std.testing.expect(Color.eql(rest, backgroundTarget(btn)));
    pressAt(ctx, null);

    const off = try Button(.{ .label = "Off", .variant = .secondary, .disabled = true }).mount(scope_val, ctx);
    defer ctx.freeNode(off);
    const disabled_bg = toneAt(t, .secondary, .{ .is_disabled = true }).background.?;
    try std.testing.expect(Color.eql(disabled_bg, backgroundTarget(off)));
    if (off.behavior.events.on_hover) |h| h.invoke();
    pressAt(ctx, off);
    try std.testing.expect(Color.eql(disabled_bg, backgroundTarget(off)));
    pressAt(ctx, null);
    try std.testing.expect(!off.behavior.interaction.focusable);
}

test "Button: label stays inside pill when placed in a stretch column" {
    // Regression: a fit-width Button directly under an align_items=.stretch
    // column (framework default) used to be stretched to the column width,
    // and its justify=center content got centered against that stretched
    // width, landing far outside the pill's own visual box (label looked
    // missing in Modal/Sheet/Form trigger buttons). no_cross_stretch fixes it.
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(800, 200);

    // wide column with default align_items (.stretch)
    const col = try box(ctx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 200 },
        .direction = .column,
    }, .{});
    ctx.root = col;

    const scope_val = try Scope.init(allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{ .label = "Open Modal", .variant = .primary }).mount(scope_val, ctx);
    try col.appendChild(allocator, btn);

    ctx.layout();

    const br = btn.rectFromWorldOrFallback();
    // Button keeps intrinsic (fit) width, NOT stretched to the 800px column.
    try std.testing.expect(br.w < 400);

    // The content slot's rect is relative to the button: it must sit inside
    // the button's own box. (The previous version compared the label rect,
    // relative to the content slot, against the button rect, which was
    // vacuous: it passed even when the slot had drifted to x≈366.)
    const content_slot = btn.children.items[btn.children.items.len - 1];
    const sr = content_slot.rectFromWorldOrFallback();
    try std.testing.expect(sr.x >= -0.5);
    try std.testing.expect(sr.x + sr.w <= br.w + 0.5);
}

const CrossAlignProbe = struct {
    col_w: f32,
    btn_x: f32,
    btn_w: f32,
    slot_x: f32,
    slot_w: f32,

    fn expectLabelInside(self: @This()) !void {
        try std.testing.expect(self.slot_w > 0);
        try std.testing.expect(self.slot_x >= -0.5);
        try std.testing.expect(self.slot_x + self.slot_w <= self.btn_w + 0.5);
        // justify=center: content horizontally centered in button
        try std.testing.expectApproxEqAbs((self.btn_w - self.slot_w) / 2.0, self.slot_x, 0.5);
    }
};

/// 800px-wide column (specify align_items) with one Button, layout then return button rect relative
/// column (x/width).
fn probeButtonInColumn(align_items: core.AlignItems, block: bool) !CrossAlignProbe {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(800, 200);

    const col = try box(ctx, .{
        .width = .{ .px = 800 },
        .height = .{ .px = 200 },
        .direction = .column,
        .align_items = align_items,
    }, .{});
    ctx.root = col;

    const scope_val = try Scope.init(allocator, null, ctx.owner);
    defer scope_val.dispose();

    const btn = try Button(.{ .label = "Click me", .block = block }).mount(scope_val, ctx);
    try col.appendChild(allocator, btn);

    ctx.layout();

    const cr = col.rectFromWorldOrFallback();
    const br = btn.rectFromWorldOrFallback();
    // Content slot rect relative button itself: label must fall in button's own visible frame.
    const sr = btn.children.items[btn.children.items.len - 1].rectFromWorldOrFallback();
    return .{ .col_w = cr.w, .btn_x = br.x - cr.x, .btn_w = br.w, .slot_x = sr.x, .slot_w = sr.w };
}

test "Button: default stretch column keeps intrinsic width, start-aligned" {
    const r = try probeButtonInColumn(.stretch, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.btn_x, 0.5);
}

test "Button: parent align_items=.center centers a non-block button" {
    const r = try probeButtonInColumn(.center, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs((r.col_w - r.btn_w) / 2.0, r.btn_x, 0.5);
}

test "Button: parent align_items=.end end-aligns a non-block button" {
    const r = try probeButtonInColumn(.end, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs(r.col_w - r.btn_w, r.btn_x, 0.5);
}

test "Button: parent align_items=.start start-aligns a non-block button" {
    const r = try probeButtonInColumn(.start, false);
    try r.expectLabelInside();
    try std.testing.expect(r.btn_w > 0 and r.btn_w < 400);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.btn_x, 0.5);
}

test "Button: block button still fills the column width" {
    const stretch = try probeButtonInColumn(.stretch, true);
    try stretch.expectLabelInside();
    try std.testing.expectApproxEqAbs(stretch.col_w, stretch.btn_w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), stretch.btn_x, 0.5);
}

test "Button: mount (retained mode)" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope_val = try Scope.init(allocator, null, ctx.owner);
    defer scope_val.dispose();

    var clicked = false;
    const btn = try Button(.{ .label = "Retained Button", .variant = .primary, .size = .md, .on_click = core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(c));
            ptr.* = true;
        }
    }.handler, &clicked) }).mount(scope_val, ctx);

    try root.appendChild(allocator, btn);

    // Validate node attributes (no icon: btn -> [content_slot])
    try std.testing.expect(findText(btn, "Retained Button") != null);
    try std.testing.expect(btn.meta.ownership.scope.scope != null);
    try std.testing.expect(btn.behavior.interaction.focusable);

    // Verify hover binding
    try std.testing.expect(btn.behavior.events.on_hover != null);

    // Simulate hover
    btn.behavior.events.on_hover.?.invoke();

    // Simulate click
    ctx.layout();
    ctx.handleClick(btn.rectFromWorldOrFallback().x + 10, btn.rectFromWorldOrFallback().y + 10);
    try std.testing.expect(clicked);

    // Scope dispose cleans all Signal/Effect
    scope_val.dispose();
}

test "Button: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("button", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Button(.{ .label = "Click Me", .variant = .primary, .size = .md }).mount(scope, cx);
        }
    }.m);
}

// OOM sweep over the states the style runtime resolves while mounting: variant and disabled from
// sources (the effect's first run), caller overrides, a glyph, and the caller's overlay layer on
// the root (v.attrs). A mount that reports success must look exactly like the uninjected mount
// (oom_sweep's reference check), and the reference itself must carry the states it was given.
test "button(states+overlay): mount 成功即外观完整，任意分配点失败不假成功（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMountVerified("button(states+overlay)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const view = @import("../../view.zig");
            const disabled = try scope.createSignal(bool, true);
            const primary = try scope.createSignal(bool, true);
            const variant = reactive.map(primary, struct {
                fn v(on: bool) ButtonVariant {
                    return if (on) .primary else .ghost;
                }
            }.v);
            return try view.render(scope, cx, view.attrs(.{ .style = core.BoxStyle{ .margin = core.Padding.all(3), .corner_radius = 7 } }, Button(.{
                .label = "Go",
                .variant = variant,
                .disabled = disabled,
                .icon_asset = svg_assets.common.star,
                .base_style = .{ .padding = core.Padding.all(5) },
                .hover_style = core.BoxStyle{ .background = Color.rgba(200, 0, 0, 255) },
            })));
        }
    }.m, struct {
        fn check(root: *Node) anyerror!void {
            const t = &core.theme.dark;
            // disabled primary tone, applied at mount without a transition
            try std.testing.expect(Color.eql(t.tokens.color.disabled_bg, root.getBackground()));
            try std.testing.expect(Color.eql(t.tokens.color.fg_disabled, root.style.ext.?.text_color.?));
            try std.testing.expect(Color.eql(t.tokens.color.fg_disabled, paintedText(findText(root, "Go").?)));
            try std.testing.expect(root.frame_state.frame_local.runtime.transitions.?.find(.background) != null);
            // caller overrides and overlay
            try std.testing.expectEqual(core.Padding.all(5), root.style.padding);
            try std.testing.expectEqual(core.Padding.all(3), root.style.margin);
            for (root.style.effectiveRadii()) |r| try std.testing.expectApproxEqAbs(@as(f32, 7), r, 0.001);
            try std.testing.expect(Color.eql(t.tokens.color.fg_disabled, paintedTint(findTag(root, .image).?)));
        }
    }.check);
}

// ── Signal-first behavior ──

const ButtonFixture = struct {
    cx: *Cx,
    root: *Node,
    scope: *Scope,
    clicks: u32 = 0,

    fn init() !ButtonFixture {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        const root = try box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
        cx.root = root;
        return .{ .cx = cx, .root = root, .scope = try Scope.init(std.testing.allocator, null, cx.owner) };
    }

    fn deinit(f: *ButtonFixture) void {
        f.scope.dispose();
        f.cx.deinit();
    }

    fn click(f: *ButtonFixture) void {
        f.clicks += 1;
    }

    fn mount(f: *ButtonFixture, b: anytype) !*Node {
        const n = try b.mount(f.scope, f.cx);
        try f.root.appendChild(std.testing.allocator, n);
        return n;
    }

    fn effects(f: *ButtonFixture) usize {
        return f.cx.owner.graph.countByKind().get(.effect);
    }
};

fn firstText(n: *Node) ?*Node {
    for (n.children.items) |c| {
        if (c.getText() != null) return c;
        if (firstText(c)) |r| return r;
    }
    return null;
}

fn textOf(btn: *Node) []const u8 {
    return firstText(btn).?.getText().?.content;
}

fn pressClick(btn: *Node) void {
    if (btn.behavior.events.on_click) |h| h.invoke();
}

test "Button: label, disabled and loading follow their sources" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const label = try f.scope.createText("Save", .{});
    const busy = try f.scope.createSignal(bool, false);
    const saving = try f.scope.createSignal(bool, false);
    const btn = try f.mount(Button(.{
        .label = label,
        .disabled = busy,
        .loading = saving,
        .icon_asset = svg_assets.common.star,
        .on_click = f.cx.on(ButtonFixture, &f, ButtonFixture.click),
    }));
    try std.testing.expectEqualStrings("Save", textOf(btn));
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 1), f.clicks);

    label.set("Save all changes");
    try std.testing.expectEqualStrings("Save all changes", textOf(btn));
    try std.testing.expectEqualStrings("Save all changes", btn.behavior.interaction.a11y.?.label.?);

    busy.set(true); // Disabled: click blocked, unfocusable
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 1), f.clicks);
    try std.testing.expect(!btn.behavior.interaction.focusable);
    try std.testing.expect(btn.behavior.interaction.a11y.?.disabled);
    busy.set(false);
    try std.testing.expect(btn.behavior.interaction.focusable);

    const icon = findTag(btn, .image).?;
    try std.testing.expect(findSpinner(btn) == null); // Not loading: no spinner
    saving.set(true); // Loading: spinner mounted, icon hidden, click blocked
    try std.testing.expect(findSpinner(btn) != null);
    try std.testing.expect(icon.style.display == .none);
    try std.testing.expect(btn.behavior.interaction.a11y.?.busy);
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 1), f.clicks);
    saving.set(false); // Load ends (hidden animation prevents idle forever-frame)
    try std.testing.expect(findSpinner(btn) == null);
    try std.testing.expect(icon.style.display != .none);
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 2), f.clicks);
}

test "Button: variant source switches the background and text color" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const active = try f.scope.createSignal(bool, false);
    const variant = reactive.map(active, struct {
        fn v(on: bool) ButtonVariant {
            return if (on) .primary else .ghost;
        }
    }.v);
    const btn = try f.mount(Button(.{ .label = "Bold", .variant = variant }));
    const bg = struct {
        fn target(n: *Node) Color {
            const slot = n.frame_state.frame_local.runtime.transitions.?.find(.background).?;
            return if (slot.active) slot.to_color else n.getBackground();
        }
    }.target;
    const ghost_bg = bg(btn);
    const ghost_text = paintedText(findText(btn, "Bold").?);
    try std.testing.expect(Color.eql(f.cx.tokens.tokens.color.fg_primary, ghost_text));
    active.set(true);
    try std.testing.expect(Color.eql(f.cx.tokens.tokens.color.button_primary_bg, bg(btn)));
    try std.testing.expect(Color.eql(f.cx.tokens.tokens.color.button_primary_fg, paintedText(findText(btn, "Bold").?)));
    active.set(false);
    try std.testing.expect(Color.eql(ghost_bg, bg(btn)));
}

test "Button: static props add no effects (zero-cost static)" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const e0 = f.effects();
    _ = try f.mount(Button(.{ .label = "A" }));
    const plain = f.effects() - e0;
    const e1 = f.effects();
    _ = try f.mount(Button(.{ .label = "B", .variant = .danger, .disabled = false, .loading = false }));
    try std.testing.expectEqual(plain, f.effects() - e1);
}

test "Button: static loading mounts a spinner up front" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const btn = try f.mount(Button(.{ .label = "Working", .loading = true }));
    try std.testing.expect(findSpinner(btn) != null);
    try std.testing.expect(btn.behavior.interaction.a11y.?.busy);
}

test "button(loading signal): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("button(loading)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const loading = try scope.createSignal(bool, true);
            return try Button(.{ .label = "Busy", .loading = loading, .icon_asset = svg_assets.common.star }).mount(scope, cx);
        }
    }.m);
}

test "Button: static gating installs the caller's handler and context directly" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    var ctx_byte: u8 = 0;
    const ev = struct {
        fn h(_: events.Event, _: ?*anyopaque) events.EventResult {
            return .handled;
        }
    }.h;
    const btn = try f.mount(Button(.{ .label = "Send", .on_event = ev, .event_context = &ctx_byte, .on_click = f.cx.on(ButtonFixture, &f, ButtonFixture.click) }));
    // Caller (e.g. Notification) can overwrite event_context after mount; handler must be its own
    try std.testing.expect(btn.behavior.events.on_event.? == ev);
    try std.testing.expect(btn.behavior.events.event_context.? == @as(*anyopaque, &ctx_byte));
    pressClick(btn);
    try std.testing.expectEqual(@as(u32, 1), f.clicks);
}

test "Button: LKxqO size matrix and interaction foregrounds" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    // LKxqO body = 13/500/radius 6; Foundations overrides lg height to 40.
    inline for (.{ .xs, .sm, .md, .lg }, .{ 20, 24, 32, 40 }) |size, height| {
        const btn = try f.mount(Button(.{ .label = "Size", .size = size, .variant = .secondary }));
        f.cx.layout();
        try std.testing.expectApproxEqAbs(@as(f32, height), btn.rectFromWorldOrFallback().h, 0.01);
        try std.testing.expectEqual(@as(f32, 6), btn.style.effectiveRadii()[0]);
        // As laid out and painted: the size tier's own, the tone's weight inherited.
        try std.testing.expectEqual(@as(f32, 13), firstText(btn).?.resolveTextProps().?.font_size);
        try std.testing.expectEqual(@as(u16, 500), firstText(btn).?.resolveTextProps().?.font_weight);
        try std.testing.expect(btn.style.shadow() != null);
    }
    const icon_button = try f.mount(Button(.{ .icon_only = true, .variant = .secondary, .icon_asset = svg_assets.common.star }));
    const leading = try f.mount(Button(.{ .label = "Add", .icon_asset = svg_assets.common.star }));
    f.cx.layout();
    // LKxqO composition: icon-only 32×32, leading-icon height 32.
    try std.testing.expectApproxEqAbs(@as(f32, 32), icon_button.rectFromWorldOrFallback().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 32), icon_button.rectFromWorldOrFallback().h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 32), leading.rectFromWorldOrFallback().h, 0.01);
    const t = f.cx.tokens;
    inline for (.{ .link, .danger }) |variant| {
        const btn = try f.mount(Button(.{ .label = "Tint", .variant = variant, .icon_asset = svg_assets.common.star }));
        const glyph = findTag(btn, .image).?;
        const rest_color = if (variant == .link) t.tokens.color.accent else t.tokens.color.fg_inverse;
        try std.testing.expectEqual(rest_color, paintedText(firstText(btn).?));
        try std.testing.expectEqual(rest_color, paintedTint(glyph));
        btn.behavior.events.on_hover.?.invoke();
        try std.testing.expectEqual(if (variant == .link) t.tokens.color.accent_hover else t.tokens.color.fg_inverse, paintedText(firstText(btn).?));
        pressAt(f.cx, btn);
        const pressed_color = if (variant == .link) t.tokens.color.accent_pressed else t.tokens.color.fg_inverse;
        try std.testing.expectEqual(pressed_color, paintedText(firstText(btn).?));
        try std.testing.expectEqual(pressed_color, paintedTint(glyph));
        btn.behavior.events.on_leave.?.invoke();
        try std.testing.expectEqual(rest_color, paintedText(firstText(btn).?));
        pressAt(f.cx, null);
    }
}

test "Button: base_style 在 tone 的 :hover / :active / :disabled 之下，hover_style / pressed_style 覆盖 tone 同状态；label 跟随根前景" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const t = f.cx.tokens;
    const red = Color.rgba(200, 0, 0, 255);
    const blue = Color.rgba(0, 0, 200, 255);
    const disabled = try f.scope.createSignal(bool, false);
    // base_style background / text color only: the tone's hover / pressed / disabled still apply.
    const btn = try f.mount(Button(.{ .label = "Go", .variant = .secondary, .disabled = disabled, .base_style = .{ .background = red, .text_color = blue, .padding = core.Padding.all(5) } }));
    f.cx.layout();
    const label = findText(btn, "Go").?;
    try std.testing.expect(Color.eql(red, backgroundTarget(btn)));
    try std.testing.expect(Color.eql(blue, paintedText(label)));
    try std.testing.expectEqual(core.Padding.all(5), btn.style.padding); // over the shell's geometry
    btn.behavior.events.on_hover.?.invoke();
    try std.testing.expect(Color.eql(toneAt(t, .secondary, .{ .is_hovered = true }).background.?, backgroundTarget(btn)));
    pressAt(f.cx, btn);
    try std.testing.expect(Color.eql(toneAt(t, .secondary, .{ .is_hovered = true, .is_pressed = true }).background.?, backgroundTarget(btn)));
    pressAt(f.cx, null);
    btn.behavior.events.on_leave.?.invoke();
    disabled.set(true);
    try std.testing.expect(Color.eql(toneAt(t, .secondary, .{ .is_disabled = true }).background.?, backgroundTarget(btn)));
    try std.testing.expect(Color.eql(t.tokens.color.fg_disabled, paintedText(label)));

    // hover_style / pressed_style win over the tone at their state.
    const custom = try f.mount(Button(.{ .label = "Hi", .variant = .secondary, .hover_style = core.BoxStyle{ .background = red, .text_color = red }, .pressed_style = core.BoxStyle{ .background = blue } }));
    const hi = findText(custom, "Hi").?;
    custom.behavior.events.on_hover.?.invoke();
    try std.testing.expect(Color.eql(red, backgroundTarget(custom)));
    try std.testing.expect(Color.eql(red, paintedText(hi)));
    pressAt(f.cx, custom);
    try std.testing.expect(Color.eql(blue, backgroundTarget(custom)));
    pressAt(f.cx, null);
    custom.behavior.events.on_leave.?.invoke();
    try std.testing.expect(Color.eql(toneAt(t, .secondary, .{}).background.?, backgroundTarget(custom)));
    try std.testing.expect(Color.eql(t.tokens.color.fg_primary, paintedText(hi)));
}

test "Button: hover_style 改字重时 label 按绘制的字重重新测量（布局与绘制同一份文字属性）" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    f.root.style.width = .{ .px = 800 };
    f.root.style.align_items = .start;
    // Weight-aware stand-in for the platform measure (the test build's fallback ignores weight).
    f.cx.text.measure_fn = struct {
        fn m(_: [*]const u8, len: usize, font_size: f32, font_weight: u16, _: bool) f32 {
            return @as(f32, @floatFromInt(len)) * font_size * (0.4 + @as(f32, @floatFromInt(font_weight)) / 2000);
        }
    }.m;
    const btn = try f.mount(Button(.{ .label = "Weighted", .variant = .secondary, .hover_style = .{ .font_weight = 700 } }));
    // References: the label string at the tone's weight and at the hover weight.
    const regular = try core.text(f.cx, "Weighted", .{ .font_size = 13, .font_weight = 500, .line_height = 1.2 });
    const bold = try core.text(f.cx, "Weighted", .{ .font_size = 13, .font_weight = 700, .line_height = 1.2 });
    try f.root.appendChild(std.testing.allocator, regular);
    try f.root.appendChild(std.testing.allocator, bold);
    f.cx.layout();
    const label = findText(btn, "Weighted").?;
    const width = struct {
        fn of(n: *Node) f32 {
            return n.rectFromWorldOrFallback().w;
        }
    }.of;
    try std.testing.expect(width(regular) < width(bold));
    try std.testing.expectEqual(@as(u16, 500), text_render.resolveNodeLogicalTextProps(label).?.font_weight);
    try std.testing.expectApproxEqAbs(width(regular), width(label), 0.01);
    const rest_w = btn.rectFromWorldOrFallback().w;
    btn.behavior.events.on_hover.?.invoke();
    f.cx.layout();
    try std.testing.expectEqual(@as(u16, 700), text_render.resolveNodeLogicalTextProps(label).?.font_weight);
    try std.testing.expectApproxEqAbs(width(bold), width(label), 0.01);
    try std.testing.expectApproxEqAbs(rest_w + width(bold) - width(regular), btn.rectFromWorldOrFallback().w, 0.01);
    btn.behavior.events.on_leave.?.invoke();
    f.cx.layout();
    try std.testing.expectApproxEqAbs(width(regular), width(label), 0.01);
    try std.testing.expectApproxEqAbs(rest_w, btn.rectFromWorldOrFallback().w, 0.01);
}

test "Button: loading 显示环（当前色）并隐藏图标，环与图标都在 icon 槽；无图标的 loading 也走 leading 几何；icon_tint 覆盖当前色" {
    var f = try ButtonFixture.init();
    defer f.deinit();
    const t = f.cx.tokens;
    const loading = try f.scope.createSignal(bool, false);
    const plain = try f.mount(Button(.{ .label = "Save", .variant = .secondary, .loading = loading }));
    f.cx.layout();
    const icon_slot = plain.children.items[0];
    try std.testing.expect(icon_slot.style.display == .none); // no glyph: the slot takes no room
    const rest_w = plain.rectFromWorldOrFallback().w;
    loading.set(true);
    f.cx.layout();
    try std.testing.expect(icon_slot.style.display != .none);
    try std.testing.expect(findSpinner(plain) != null);
    // Leading glyph geometry (narrower left side, tighter gap) + ring.
    const m = control_shell.metrics(t, .md);
    try std.testing.expectEqual(@as(f32, 10), plain.style.padding.left);
    try std.testing.expectApproxEqAbs(rest_w + t.tokens.size.icon + t.tokens.space.space150 - (m.padding_h - 10), plain.rectFromWorldOrFallback().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 32), plain.rectFromWorldOrFallback().h, 0.01);
    loading.set(false);
    f.cx.layout();
    try std.testing.expectApproxEqAbs(rest_w, plain.rectFromWorldOrFallback().w, 0.01);

    const tinted = try f.mount(Button(.{ .label = "Star", .variant = .secondary, .icon_asset = svg_assets.common.star, .icon_tint = t.tokens.color.accent }));
    try std.testing.expectEqual(t.tokens.color.accent, paintedTint(findTag(tinted, .image).?));
    const current = try f.mount(Button(.{ .label = "Star", .variant = .danger, .icon_asset = svg_assets.common.star }));
    try std.testing.expectEqual(t.tokens.color.fg_inverse, paintedTint(findTag(current, .image).?));
}
