//! ControlShell: the layout + style base Button / Input / Select / DatePicker / Chip compose.
//!
//!   root (row: frame, padding, radius, interaction colors)
//!   +-- icon    (?View, fit: icon / spinner)
//!   +-- content (?View, grows: label / editable surface)
//!   +-- append  (?View, fit: chevron / clear / count)
//!
//! The component is control_shell.yix (structure, declarative states) + styles.yss (size recipe,
//! Tone, geometry, slots). A slot the caller leaves out builds nothing. Caller-specific looks
//! stack on the element's `style` (overlay layer); Group attaches through Node.frameNode().
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Scope = core.Scope;
const theme = core.theme;

pub const ControlVariant = styles.ControlVariant;
pub const ControlSize = styles.ControlSize;
/// Yix component (control_shell.yix).
pub const ControlShell = @import("_control_shell.yix.zig").ControlShell;
pub const ControlMetrics = styles.ControlMetrics;
pub const metrics = styles.metrics;
pub const glyphSize = styles.glyphSize;
pub const IconFit = styles.IconFit;

// Component style and size contract unified in styles.yss, exported at entry.
const styles = @import("_styles.yss.zig");

// ========== Tests ==========

const TestEnv = struct {
    ctx: *Cx,
    root: *Node,
    scope: *Scope,

    fn init(allocator: std.mem.Allocator) !TestEnv {
        const ctx = try Cx.init(allocator, std.testing.io);
        errdefer ctx.deinit();
        const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 400 } }, .{});
        ctx.root = root;
        const scope = try Scope.init(allocator, null, ctx.owner);
        return .{ .ctx = ctx, .root = root, .scope = scope };
    }

    fn deinit(self: TestEnv) void {
        self.scope.dispose();
        self.ctx.deinit();
    }
};

test {
    _ = @import("_styles.yss.zig");
}

// Per-allocation OOM sweep (see src/ui/components/oom_sweep.zig): all three slots filled, states
// from signals; covers slot boxes + caller content + style runtimes rolling back.
test "control_shell: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("control_shell", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const invalid = try scope.createSignal(bool, false);
            return try view.render(scope, cx, view.col(.{}, view.with(ControlShell(.{ .variant = .field, .invalid = invalid, .focus_ring = @as(?@import("../../hooks.zig").FocusRingConfig, .{}) }), .{}).slots(.{
                .icon = view.box(.{ .style = .{ .width = .{ .px = 12 } } }, {}),
                .content = view.text(.{}, "Label"),
                .append = view.text(.{}, "x"),
            })));
        }
    }.m);
}

// Reference-checked OOM sweep (see oom_sweep.zig): a mount that reports success must look exactly
// like the uninjected mount; `check` also pins the states the reference was given.
test "control_shell(states+overlay): mount 成功即外观完整，任意分配点失败不假成功（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMountVerified("control_shell(states+overlay)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const invalid = try scope.createSignal(bool, true);
            const disabled = try scope.createSignal(bool, false);
            return try view.render(scope, cx, view.attrs(.{ .style = core.BoxStyle{ .padding = Padding.all(6) } }, view.with(ControlShell(.{ .variant = .field, .invalid = invalid, .disabled = disabled, .focus_ring = @as(?@import("../../hooks.zig").FocusRingConfig, .{}) }), .{}).slots(.{
                .icon = view.box(.{ .style = .{ .width = .{ .px = 12 } } }, {}),
                .content = view.text(.{}, "Label"),
            })));
        }
    }.m, struct {
        fn check(root: *Node) anyerror!void {
            const t = &theme.dark;
            try std.testing.expect(Color.eql(t.tokens.color.danger, root.style.border.color));
            try std.testing.expect(root.style.border.width > 0);
            try std.testing.expect(root.style.effectiveRadii()[0] > 0);
            try std.testing.expectEqual(Padding.all(6), root.style.padding);
            try std.testing.expect(root.frame_state.frame_local.runtime.transitions.?.find(.border_color) != null);
        }
    }.check);
}

// ========== Yix ControlShell (control_shell.yix) ==========

fn mountYix(env: TestEnv, element: anytype) !*Node {
    const node = try view.render(env.scope, env.ctx, element);
    try env.root.appendChild(env.ctx.allocator, node);
    env.ctx.layout();
    _ = env.ctx.render();
    return node;
}

/// Settled value of a color the shell eases (transition target while animating).
fn borderTarget(n: *Node) Color {
    if (n.frame_state.frame_local.runtime.transitions) |slots| if (slots.find(.border_color)) |slot| if (slot.active) return slot.to_color;
    return n.style.border.color;
}
fn backgroundTarget(n: *Node) Color {
    if (n.frame_state.frame_local.runtime.transitions) |slots| if (slots.find(.background)) |slot| if (slot.active) return slot.to_color;
    return n.getBackground();
}

test "ControlShell: variant × size × iconOnly × leadingIcon 的框、padding、圆角、gap、高度取自 recipe 与 metrics" {
    const env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const t = env.ctx.tokens;
    const sizes = [_]ControlSize{ .xs, .sm, .md, .lg };
    inline for (@import("zenit_reflection").fields(ControlVariant)) |vf| {
        const variant: ControlVariant = @field(ControlVariant, vf.name);
        for (sizes) |size| for ([_]bool{ false, true }) |icon_only| for ([_]bool{ false, true }) |leading| {
            const m = metrics(t, size);
            const shell = try mountYix(env, view.with(ControlShell(.{ .variant = variant, .size = size, .icon_only = icon_only, .leading_icon = leading }), .{}).slots(.{
                .icon = view.box(.{ .style = .{ .width = .{ .px = m.icon_size }, .height = .{ .px = m.icon_size } } }, {}),
                .content = if (icon_only) null else view.text(.{ .style = core.TextStyle{ .font_size = m.font_size, .line_height = m.line_height } }, "Label"),
            }));
            const recipe = styles.Tone.resolve(.{ .kind = variant }, t).resolve(.{});
            try std.testing.expectEqual(styles.geometryPadding(t, size, icon_only, leading, .line_box), shell.style.padding);
            try std.testing.expectEqual(m.radius, shell.style.effectiveRadius());
            try std.testing.expectEqual(m.gap, shell.style.gap);
            try std.testing.expectApproxEqAbs(m.derivedHeight(), shell.rectFromWorldOrFallback().h, 0.01);
            try std.testing.expect(Color.eql(recipe.background orelse Color.TRANSPARENT, shell.getBackground()));
            const border = recipe.border orelse core.Border{};
            try std.testing.expect(Color.eql(recipe.border_color orelse border.color, shell.style.border.color));
            try std.testing.expectEqual(recipe.border_width orelse border.width, shell.style.border.width);
        };
    }
}

test "ControlShell (Yix): 缺席的槽不建节点；三槽按 icon / content / append 排序" {
    const env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const only = try mountYix(env, view.with(ControlShell(.{}), .{}).slots(.{ .content = view.text(.{}, "x") }));
    try std.testing.expectEqual(@as(usize, 1), only.children.items.len);
    var ic: *Node = undefined;
    var tx: *Node = undefined;
    var ap: *Node = undefined;
    const full = try mountYix(env, view.with(ControlShell(.{}), .{}).slots(.{
        .append = view.capture(&ap, view.text(.{}, "a")),
        .content = view.capture(&tx, view.text(.{}, "c")),
        .icon = view.capture(&ic, view.box(.{}, {})),
    }));
    try std.testing.expectEqual(@as(usize, 3), full.children.items.len);
    try std.testing.expect(ic.parent == full.children.items[0]);
    try std.testing.expect(tx.parent == full.children.items[1]);
    try std.testing.expect(ap.parent == full.children.items[2]);
}

test "ControlShell (Yix): field 的 hover / focus / expanded 为 accent，invalid 压过它们，disabled 短路；状态可来自信号" {
    const env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const t = env.ctx.tokens.tokens.color;
    const invalid = try env.scope.createSignal(bool, false);
    const expanded = try env.scope.createSignal(bool, false);
    const disabled = try env.scope.createSignal(bool, false);
    const shell = try mountYix(env, view.with(ControlShell(.{ .variant = .field, .invalid = invalid, .expanded = expanded, .disabled = disabled }), .{}).slots(.{ .content = view.text(.{}, "x") }));
    try std.testing.expect(Color.eql(t.border_strong, borderTarget(shell)));
    try std.testing.expect(Color.eql(t.input_bg, backgroundTarget(shell)));
    const enter = shell.behavior.events.on_hover.?;
    enter.callback(enter.context);
    try std.testing.expect(Color.eql(t.accent, borderTarget(shell)));
    const leave = shell.behavior.events.on_leave.?;
    leave.callback(leave.context);
    try std.testing.expect(Color.eql(t.border_strong, borderTarget(shell)));
    expanded.set(true);
    try std.testing.expect(Color.eql(t.accent, borderTarget(shell)));
    invalid.set(true);
    try std.testing.expect(Color.eql(t.danger, borderTarget(shell)));
    disabled.set(true);
    try std.testing.expect(Color.eql(t.disabled_bg, backgroundTarget(shell)));
    try std.testing.expect(Color.eql(t.border, borderTarget(shell)));
    try std.testing.expectEqual(core.CursorShape.not_allowed, shell.style.cursor);
}

test "ControlShell (Yix): focusRing 为 null 不装焦点环；给配置按配置画，信号更新配置；Button 的 focusRing 透传到外壳" {
    const hooks = @import("../../hooks.zig");
    const env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const red = Color.hex(0xFF0000);
    const blue = Color.hex(0x0000FF);
    const config = try env.scope.createSignal(?hooks.FocusRingConfig, .{ .color = red, .width = 3 });
    const Button = @import("../button/mod.zig").Button;
    const root = try mountYix(env, view.col(.{}, .{
        view.with(ControlShell(.{}), .{}).slots(.{ .content = view.text(.{}, "none") }),
        view.with(ControlShell(.{ .focusable = true, .focus_ring = config }), .{}).slots(.{ .content = view.text(.{}, "ring") }),
        Button(.{ .label = "b", .focus_ring = .{ .color = blue } }),
    }));
    const kids = root.children.items;
    try std.testing.expect(kids[0].meta.per_frame.hooks.slots.focus_ring_anim == null);
    const ring: *hooks.FocusRingAnimState = @ptrCast(@alignCast(kids[1].meta.per_frame.hooks.slots.focus_ring_anim.?));
    try std.testing.expect(Color.eql(red, ring.focus_color));
    try std.testing.expectEqual(@as(f32, 3), ring.focus_width);
    config.set(.{ .color = blue, .width = 2 });
    try std.testing.expect(Color.eql(blue, ring.focus_color));
    try std.testing.expectEqual(@as(f32, 2), ring.focus_width);
    const button_ring: *hooks.FocusRingAnimState = @ptrCast(@alignCast(kids[2].meta.per_frame.hooks.slots.focus_ring_anim.?));
    try std.testing.expect(Color.eql(blue, button_ring.focus_color));
}

test "ControlShell (Yix): pins 钉住 hover / pressed（不随指针、不走过渡），null 仍由节点驱动，disabled 压过钉住" {
    const env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const tone = styles.Tone.resolve(.{ .kind = .primary }, env.ctx.tokens);
    const rest = tone.resolve(.{}).background.?;
    const hover = tone.resolve(.{ .is_hovered = true }).background.?;
    const pressed = tone.resolve(.{ .is_hovered = true, .is_pressed = true }).background.?;
    const disabled = tone.resolve(.{ .is_disabled = true }).background.?;
    try std.testing.expect(!Color.eql(rest, hover) and !Color.eql(hover, pressed));
    const root = try mountYix(env, view.col(.{}, .{
        view.with(ControlShell(.{ .variant = .primary, .pins = .{ .hover = true } }), .{}).slots(.{ .content = view.text(.{}, "h") }),
        view.with(ControlShell(.{ .variant = .primary, .pins = .{ .hover = true, .active = true } }), .{}).slots(.{ .content = view.text(.{}, "p") }),
        view.with(ControlShell(.{ .variant = .primary, .pins = .{ .hover = false } }), .{}).slots(.{ .content = view.text(.{}, "off") }),
        view.with(ControlShell(.{ .variant = .primary }), .{}).slots(.{ .content = view.text(.{}, "free") }),
        view.with(ControlShell(.{ .variant = .primary, .disabled = true, .pins = .{ .hover = true } }), .{}).slots(.{ .content = view.text(.{}, "d") }),
    }));
    const kids = root.children.items;
    try std.testing.expect(Color.eql(hover, kids[0].getBackground()));
    try std.testing.expect(Color.eql(pressed, kids[1].getBackground()));
    try std.testing.expect(Color.eql(rest, kids[2].getBackground()));
    try std.testing.expect(Color.eql(disabled, kids[4].getBackground()));
    for (kids[0..4]) |k| {
        k.behavior.events.on_hover.?.invoke();
    }
    try std.testing.expect(Color.eql(hover, backgroundTarget(kids[0])));
    try std.testing.expect(Color.eql(rest, backgroundTarget(kids[2])));
    try std.testing.expect(Color.eql(hover, backgroundTarget(kids[3])));
    for (kids[0..4]) |k| k.behavior.events.on_leave.?.invoke();
    try std.testing.expect(Color.eql(hover, backgroundTarget(kids[0])));
    try std.testing.expect(Color.eql(pressed, backgroundTarget(kids[1])));
    try std.testing.expect(Color.eql(rest, backgroundTarget(kids[3])));
}

test "ControlShell (Yix): 换主题时框与底色跟随" {
    const env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const shell = try mountYix(env, view.with(ControlShell(.{ .variant = .secondary }), .{}).slots(.{ .content = view.text(.{}, "x") }));
    try std.testing.expect(Color.eql(env.ctx.tokens.tokens.color.bg_primary, backgroundTarget(shell)));
    env.ctx.setTheme(&theme.modes.dark);
    try std.testing.expect(Color.eql(theme.modes.dark.tokens.color.bg_primary, backgroundTarget(shell)));
    try std.testing.expect(Color.eql(theme.modes.dark.tokens.color.border, borderTarget(shell)));
}

test "ControlShell (Yix): embedded 去掉框（无边框、无 padding、透明底），任何状态都不画底" {
    const env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const disabled = try env.scope.createSignal(bool, false);
    const shell = try mountYix(env, view.with(ControlShell(.{ .variant = .field, .embedded = true, .disabled = disabled }), .{}).slots(.{ .content = view.text(.{}, "x") }));
    try std.testing.expectEqual(@as(f32, 0), shell.style.border.width);
    try std.testing.expectEqual(Padding.ZERO, shell.style.padding);
    try std.testing.expect(Color.eql(Color.TRANSPARENT, shell.getBackground()));
    disabled.set(true);
    try std.testing.expect(Color.eql(Color.TRANSPARENT, shell.getBackground()));
}

test "review regression 6: existing variant ordinals are stable" {
    inline for (.{ "primary", "secondary", "ghost", "danger", "link", "field" }, 0..) |name, i| {
        try std.testing.expectEqual(i, @backingInt(@field(ControlVariant, name)));
    }
}
