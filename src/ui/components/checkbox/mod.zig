/// Checkbox, Radio, Switch Components
///
/// Signal-driven: hover state is managed via Signal, Effect auto-updates style. Toggle state is
/// kept in StateStore (involves DOM structure change).
///
/// Features:
/// - State management: toggle by StateStore, hover by Signal
/// - Event driven: on_event handles click
/// - Focus support: focusable, Tab navigation
/// - Label support
/// - Disabled state
/// - on_change callback
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const ui_view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const Signal = core.Signal;
const createEffect = core.createEffect;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const hooks = @import("../../hooks.zig");
const svg_assets = @import("../../svg_assets.zig");
const icons = @import("zenit_system_icons");
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const bind_mod = @import("../../bind.zig");
const ui_split = reactive.split;
const eq_mod = @import("../../reactive/eq.zig");

const recipe_mod = @import("../../recipe.zig");

// Style layer factor to styles.yss; aliases below keep call-site and public API unchanged.
const styles = @import("_styles.yss.zig");
pub const CheckboxRecipe = styles.CheckboxRecipe;
pub const SwitchRecipe = styles.SwitchRecipe;
pub const CheckboxColors = styles.CheckboxColors;
const SwitchColors = styles.SwitchColors;
const controlRowStyle = styles.controlRowStyle;
const checkboxBoxStyle = styles.checkboxBoxStyle;
const checkIconStyle = styles.checkIconStyle;
const indetOverlayStyle = styles.indetOverlayStyle;
const controlLabelStyle = styles.controlLabelStyle;
const radioCircleStyle = styles.radioCircleStyle;
const radioDotStyle = styles.radioDotStyle;
const radioGroupContainerStyle = styles.radioGroupContainerStyle;
const switchTrackStyle = styles.switchTrackStyle;
const switchThumbStyle = styles.switchThumbStyle;
const switchLabelStyle = styles.switchLabelStyle;

// Checkbox
//
// Signal-first (docs/SIGNAL_API_DESIGN.md): `checked` is Model (local/bound/split);
// other changeable props are Source. View = f(checked, indeterminate, disabled), derived by one
// effect. Interaction only calls `Bound.propose`; if the parent refuses, the view stays unchanged.

/// Create Checkbox: `W.Checkbox(.{ .label = "Agree", .checked = agree })`.
/// props: checked (controlled value Model(bool))/indeterminate (read-only)/label/disabled/
/// on_change (only report settled value)/check_icon_asset.
/// View in checkbox.yix, style in styles.yss CheckboxParts.
pub const Checkbox = @import("_checkbox.yix.zig").Checkbox;

/// Click or spacebar
fn isToggleEvent(event: Event) bool {
    return switch (event) {
        .click => true,
        .key_down => |e| e.key == .space,
        else => false,
    };
}

// ==================== Radio / RadioGroup ====================

pub const RadioOption = struct {
    value: []const u8,
    label: []const u8,
    disabled: bool = false,
    /// Option node test_id (e2e / a11y locate; borrowed, outlive component)
    test_id: ?[]const u8 = null,
};

/// Standalone Radio: display only (selection logic via RadioGroup). Props: checked / label /
/// disabled (all may signal).
pub const Radio = @import("_radio.yix.zig").Radio;

/// Radio group: W.RadioGroup(.{ .options = &opts, .value = choice }). Props: options / value
/// (controlled Model(?[]const u8), borrows option value string) / disabled / horizontal / on_change
/// (reports settled choice only). View in radio.yix, style in styles.yss RadioParts.
pub const RadioGroup = @import("_radio.yix.zig").RadioGroup;

// ==================== Switch ====================

/// Switch size: md (40x22, default) or sm (32x18) for dense rows and inline toolbars.
pub const SwitchSize = enum { sm, md };

/// Create Switch: W.Switch(.{ .label = "Wi-Fi", .checked = wifi }). Props: checked (controlled
/// Model(bool)) / label / size (sm / md) / disabled / on_change (reports settled value only).
/// View in switch.yix, style in styles.yss SwitchParts.
pub const Switch = @import("_switch.yix.zig").Switch;

/// Test fixture: Cx + root node + scope.
const Fixture = struct {
    cx: *Cx,
    root: *Node,
    scope: *Scope,

    fn init() !Fixture {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
        cx.root = root;
        return .{ .cx = cx, .root = root, .scope = try Scope.init(std.testing.allocator, null, cx.owner) };
    }

    fn deinit(f: Fixture) void {
        f.scope.dispose();
        f.cx.deinit();
    }

    fn add(f: Fixture, node: *Node) !*Node {
        try f.root.appendChild(std.testing.allocator, node);
        return node;
    }

    fn effects(f: Fixture) usize {
        return f.cx.owner.graph.countByKind().get(.effect);
    }
};

/// Dispatch click / spacebar via real event handler (batch processing via Cx entry; here direct
/// handler call).
fn sendClick(node: *Node) EventResult {
    return node.behavior.events.on_event.?(.{ .click = .{ .x = 1, .y = 1, .button = .left, .click_count = 1 } }, node.behavior.events.event_context);
}

fn sendSpace(node: *Node) EventResult {
    return node.behavior.events.on_event.?(.{ .key_down = .{ .key = .space, .raw_keycode = 49, .modifiers = .{} } }, node.behavior.events.event_context);
}

/// Checkbox/Switch is view-declared button semantic node: click run on_click
fn press(node: *Node) void {
    const h = node.behavior.events.on_click.?;
    h.callback(h.context);
}

fn findText(n: *Node, text: []const u8) ?*Node {
    if (n.getText()) |t| if (std.mem.eql(u8, t.content, text)) return n;
    for (n.children.items) |c| if (findText(c, text)) |r| return r;
    return null;
}

fn checkmarkOf(cb: *Node) *Node {
    return cb.children.items[0].children.items[0];
}

fn indetOf(cb: *Node) *Node {
    return cb.children.items[0].children.items[1];
}

const BoolSink = struct {
    last: ?bool = null,
    calls: u32 = 0,
    fn changed(self: *BoolSink, v: bool) void {
        self.last = v;
        self.calls += 1;
    }
};

test "Checkbox: structure — label node only when a label is given" {
    const f = try Fixture.init();
    defer f.deinit();
    const with_label = try f.add(try Checkbox(.{ .label = "Remember me" }).mount(f.scope, f.cx));
    try std.testing.expectEqual(@as(usize, 2), with_label.children.items.len);
    try std.testing.expectEqualStrings("Remember me", with_label.behavior.interaction.a11y.?.label.?);
    const bare = try f.add(try Checkbox(.{}).mount(f.scope, f.cx));
    try std.testing.expectEqual(@as(usize, 1), bare.children.items.len);
    try std.testing.expectEqual(@as(usize, 2), bare.children.items[0].children.items.len); // checkmark + indet
}

test "Checkbox: local model — click toggles view, a11y and reports the landed value" {
    const f = try Fixture.init();
    defer f.deinit();
    var sink = BoolSink{};
    const cb = try f.add(try Checkbox(.{ .checked = true, .on_change = f.cx.on(BoolSink, &sink, BoolSink.changed) }).mount(f.scope, f.cx));
    try std.testing.expectEqual(@as(f32, 1), checkmarkOf(cb).getOpacity());
    press(cb);
    try std.testing.expectEqual(@as(f32, 0), checkmarkOf(cb).getOpacity());
    try std.testing.expect(!cb.behavior.interaction.a11y.?.checked.?);
    try std.testing.expectEqual(@as(?bool, false), sink.last);
    // Keyboard: Space via Cx synthesize click on focus node
    f.cx.setViewport(200, 100);
    f.cx.layout();
    f.cx.focus_manager.setFocus(cb);
    f.cx.handleKeyDown(.space, .{});
    try std.testing.expectEqual(@as(?bool, true), sink.last);
    try std.testing.expectEqual(@as(u32, 2), sink.calls);
}

test "Checkbox: bound model — external set drives the view, clicks write the signal" {
    const f = try Fixture.init();
    defer f.deinit();
    const agree = try f.scope.createSignal(bool, false);
    const cb = try f.add(try Checkbox(.{ .label = "Agree", .checked = agree }).mount(f.scope, f.cx));
    try std.testing.expectEqual(@as(f32, 0), checkmarkOf(cb).getOpacity());
    agree.set(true); // external drive
    try std.testing.expectEqual(@as(f32, 1), checkmarkOf(cb).getOpacity());
    try std.testing.expect(cb.behavior.interaction.a11y.?.checked.?);
    press(cb); // interaction write-back
    try std.testing.expect(!agree.peek());
    try std.testing.expectEqual(@as(f32, 0), checkmarkOf(cb).getOpacity());
}

test "Checkbox: split model — a rejected proposal leaves value and view unchanged" {
    const f = try Fixture.init();
    defer f.deinit();
    const agree = try f.scope.createSignal(bool, false);
    const Gate = struct {
        agree: *Signal(bool),
        allow: bool = false,
        fn propose(self: *@This(), v: bool) void {
            if (self.allow) self.agree.set(v);
        }
    };
    var gate = Gate{ .agree = agree };
    var sink = BoolSink{};
    const cb = try f.add(try Checkbox(.{
        .checked = ui_split(agree, f.cx.on(Gate, &gate, Gate.propose)),
        .on_change = f.cx.on(BoolSink, &sink, BoolSink.changed),
    }).mount(f.scope, f.cx));
    press(cb);
    try std.testing.expect(!agree.peek());
    try std.testing.expectEqual(@as(f32, 0), checkmarkOf(cb).getOpacity());
    try std.testing.expectEqual(@as(u32, 0), sink.calls);
    gate.allow = true;
    press(cb);
    try std.testing.expect(agree.peek());
    try std.testing.expectEqual(@as(f32, 1), checkmarkOf(cb).getOpacity());
    try std.testing.expectEqual(@as(?bool, true), sink.last);
}

test "Checkbox: indeterminate and disabled follow their sources" {
    const f = try Fixture.init();
    defer f.deinit();
    const mixed = try f.scope.createSignal(bool, true);
    const busy = try f.scope.createSignal(bool, true);
    const cb = try f.add(try Checkbox(.{ .indeterminate = mixed, .disabled = busy }).mount(f.scope, f.cx));
    try std.testing.expectEqual(@as(f32, 1), indetOf(cb).getOpacity());
    try std.testing.expect(cb.behavior.interaction.a11y.?.indeterminate);
    try std.testing.expect(!cb.behavior.interaction.focusable);
    press(cb); // disabled: don't change value
    try std.testing.expect(!cb.behavior.interaction.a11y.?.checked.?);
    busy.set(false);
    try std.testing.expect(cb.behavior.interaction.focusable);
    press(cb); // checked -> true
    try std.testing.expect(cb.behavior.interaction.a11y.?.checked.?);
    try std.testing.expectEqual(@as(f32, 0), indetOf(cb).getOpacity()); // checked no show mixed
    mixed.set(false);
    try std.testing.expect(!cb.behavior.interaction.a11y.?.indeterminate);
}

test "Checkbox: dynamic label from an owned text signal" {
    const f = try Fixture.init();
    defer f.deinit();
    const name = try f.scope.createText("Notify me", .{});
    const cb = try f.add(try Checkbox(.{ .label = name }).mount(f.scope, f.cx));
    try std.testing.expect(findText(cb, "Notify me") != null);
    name.set("Notify me about every reply in this thread");
    try std.testing.expect(findText(cb, "Notify me about every reply in this thread") != null);
    try std.testing.expectEqualStrings("Notify me about every reply in this thread", cb.behavior.interaction.a11y.?.label.?);
}

test "Checkbox: static props add no effects (zero-cost static)" {
    const f = try Fixture.init();
    defer f.deinit();
    const e0 = f.effects();
    _ = try f.add(try Checkbox(.{}).mount(f.scope, f.cx));
    const bare = f.effects() - e0;
    const e1 = f.effects();
    _ = try f.add(try Checkbox(.{ .label = "x", .disabled = false, .indeterminate = false, .checked = true }).mount(f.scope, f.cx));
    try std.testing.expectEqual(bare, f.effects() - e1);
}

test "Checkbox: 方框颜色过渡（底色 / 边框色都插值）" {
    const f = try Fixture.init();
    defer f.deinit();
    const on = try f.scope.createSignal(bool, false);
    const cb = try f.add(try Checkbox(.{ .checked = on }).mount(f.scope, f.cx));
    const box_node = cb.children.items[0];
    try std.testing.expectEqual(f.cx.tokens.tokens.color.checkbox_border, box_node.style.border.color);
    on.set(true);
    const slots = box_node.frame_state.frame_local.runtime.transitions.?;
    try std.testing.expect(slots.find(.background).?.active);
    const border = slots.find(.border_color).?;
    try std.testing.expect(border.active);
    // start color is pre-change, not post-reset baseline
    try std.testing.expectEqual(f.cx.tokens.tokens.color.checkbox_border, border.from_color);
    try std.testing.expectEqual(f.cx.tokens.tokens.color.accent, border.to_color);
    try std.testing.expectEqualStrings("Checkbox", cb.meta.ownership.meta.component_name.?);
}

test "Radio: basic" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const radio = try Radio(.{ .label = "Option 1" }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, radio);
    try std.testing.expectEqual(@as(usize, 2), radio.children.items.len);
}

test "Radio: checked render emits inner dot" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(120, 40);

    const root = try box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
        .background = ctx.tokens.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const radio = try Radio(.{
        .checked = true,
        .label = "On",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, radio);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_dot = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.tokens.color.button_primary_fg) and r.geom.w >= 7 and r.geom.h >= 7 and r.geom.w <= 10 and r.geom.h <= 10) {
            saw_dot = true;
        }
    };

    try std.testing.expect(saw_dot);
}

test "Radio: disabled checked uses LKxqO semantic colors without opacity" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 40 },
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const radio = try Radio(.{
        .checked = true,
        .disabled = true,
        .label = "Disabled",
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, radio);

    // LKxqO: disabled background/dot, selected accent border; no blanket fading.
    try std.testing.expectApproxEqAbs(@as(f32, 1), radio.getOpacity(), 0.001);
    try std.testing.expectEqual(ctx.tokens.tokens.color.disabled_bg, radio.children.items[0].getBackground());
    try std.testing.expectEqual(ctx.tokens.tokens.color.fg_disabled, radio.children.items[0].children.items[0].getBackground());
    try std.testing.expectEqual(ctx.tokens.tokens.color.accent, radio.children.items[0].style.border.color);
}

test "RadioGroup: multiple options" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const options = [_]RadioOption{
        .{ .value = "a", .label = "Option A" },
        .{ .value = "b", .label = "Option B" },
        .{ .value = "c", .label = "Option C" },
    };

    const group = try RadioGroup(.{
        .options = &options,
        .value = "b",
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, group);
    try std.testing.expectEqual(@as(usize, 3), optionCount(group));
    // radio group always require one selected (UIA SelectionPattern.IsSelectionRequired)
    try std.testing.expectEqual(core.A11yRole.radiogroup, group.behavior.interaction.a11y.?.role);
    try std.testing.expect(group.behavior.interaction.a11y.?.required);
}

const StrSink = struct {
    last: [16]u8 = undefined,
    len: usize = 0,
    calls: u32 = 0,
    fn changed(self: *StrSink, v: []const u8) void {
        @memcpy(self.last[0..v.len], v);
        self.len = v.len;
        self.calls += 1;
    }
    fn value(self: *const StrSink) []const u8 {
        return self.last[0..self.len];
    }
};

fn radioDotOpacity(group: *Node, i: usize) f32 {
    return option(group, i).children.items[0].children.items[0].getOpacity();
}

/// RadioGroup i-th option (options from signal, keyed list area has anchor nodes before/after)
fn option(group: *Node, i: usize) *Node {
    var k: usize = 0;
    for (group.children.items) |c| {
        if (c.tag == .anchor) continue;
        if (k == i) return c;
        k += 1;
    }
    unreachable;
}

fn optionCount(group: *Node) usize {
    var k: usize = 0;
    for (group.children.items) |c| k += @intFromBool(c.tag != .anchor);
    return k;
}

test "RadioGroup: bound value — external set and clicks, disabled option ignored" {
    const f = try Fixture.init();
    defer f.deinit();
    const opts = [_]RadioOption{ .{ .value = "light", .label = "Light" }, .{ .value = "dark", .label = "Dark" }, .{ .value = "auto", .label = "Auto", .disabled = true } };
    const theme_sig = try f.scope.createSignal(?[]const u8, "light");
    var sink = StrSink{};
    const group = try f.add(try RadioGroup(.{ .options = &opts, .value = theme_sig, .on_change = f.cx.on(StrSink, &sink, StrSink.changed) }).mount(f.scope, f.cx));
    try std.testing.expect(option(group, 0).behavior.interaction.a11y.?.checked.?);
    theme_sig.set("dark"); // external drive
    try std.testing.expect(option(group, 1).behavior.interaction.a11y.?.checked.?);
    try std.testing.expect(!option(group, 0).behavior.interaction.a11y.?.checked.?);
    try std.testing.expectEqual(@as(u32, 0), sink.calls); // program write don't trigger on_change
    press(option(group, 0)); // interaction write-back
    try std.testing.expectEqualStrings("light", theme_sig.peek().?);
    try std.testing.expectEqualStrings("light", sink.value());
    press(option(group, 2)); // disabled item
    try std.testing.expectEqualStrings("light", theme_sig.peek().?);
    try std.testing.expectEqual(@as(u32, 1), sink.calls);
    press(option(group, 0)); // same value: no trigger
    try std.testing.expectEqual(@as(u32, 1), sink.calls);
}

test "RadioGroup: options from a signal rebuild the items" {
    const f = try Fixture.init();
    defer f.deinit();
    const two = [_]RadioOption{ .{ .value = "a", .label = "A" }, .{ .value = "b", .label = "B" } };
    const three = [_]RadioOption{ .{ .value = "a", .label = "A" }, .{ .value = "b", .label = "B" }, .{ .value = "c", .label = "C" } };
    const options = try f.scope.createSignal([]const RadioOption, &two);
    const group = try f.add(try RadioGroup(.{ .options = options, .value = "b" }).mount(f.scope, f.cx));
    try std.testing.expectEqual(@as(usize, 2), optionCount(group));
    options.set(&three);
    try std.testing.expectEqual(@as(usize, 3), optionCount(group));
    try std.testing.expect(option(group, 1).behavior.interaction.a11y.?.checked.?); // selected keep
    press(option(group, 2)); // new option interactive
    try std.testing.expect(option(group, 2).behavior.interaction.a11y.?.checked.?);
    try std.testing.expect(!option(group, 1).behavior.interaction.a11y.?.checked.?);
}

test "Radio: standalone radio follows its sources" {
    const f = try Fixture.init();
    defer f.deinit();
    const on = try f.scope.createSignal(bool, false);
    const r = try f.add(try Radio(.{ .label = "Solo", .checked = on }).mount(f.scope, f.cx));
    try std.testing.expect(!r.behavior.interaction.a11y.?.checked.?);
    on.set(true);
    try std.testing.expect(r.behavior.interaction.a11y.?.checked.?);
}

test "Switch: structure and checked render emits track and thumb" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(140, 40);
    const root = try box(ctx, .{ .width = .{ .px = 140 }, .height = .{ .px = 40 }, .background = ctx.tokens.tokens.color.bg_primary }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const sw = try Switch(.{ .checked = true, .label = "Enabled" }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, sw);
    try std.testing.expectEqual(@as(usize, 2), sw.children.items.len);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();
    var saw_track = false;
    var saw_thumb = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.tokens.color.accent) and r.geom.w >= 38 and r.geom.h >= 20) saw_track = true;
        if (Color.eql(r.color.toColor(), ctx.tokens.tokens.color.fg_inverse) and r.geom.w >= 16 and r.geom.h >= 16 and r.geom.w <= 20 and r.geom.h <= 20) saw_thumb = true;
    };
    try std.testing.expect(saw_track);
    try std.testing.expect(saw_thumb);
}

/// Switch is view-declared button semantic node: click run on_click, Space/Enter via Cx
/// synthesize click on focus node
fn clickSwitch(sw: *Node) void {
    const h = sw.behavior.events.on_click.?;
    h.callback(h.context);
}

test "Switch: sm size takes its track, thumb and travel from the sm size tokens" {
    const f = try Fixture.init();
    defer f.deinit();
    const on = try f.scope.createSignal(bool, true);
    const sw = try f.add(try Switch(.{ .checked = on, .size = .sm }).mount(f.scope, f.cx));
    const size = f.cx.tokens.tokens.size;
    const track = sw.children.items[0];
    const thumb = track.children.items[0];
    try std.testing.expectEqual(size.switch_width_sm, track.style.width.px);
    try std.testing.expectEqual(size.switch_height_sm, track.style.height.px);
    try std.testing.expectEqual(size.switch_thumb_sm, thumb.style.width.px);
    try std.testing.expectEqual(size.switch_thumb_sm, thumb.style.height.px);
    // On: the thumb rests 2px from the track's right edge, as at md.
    try std.testing.expectEqual(size.switch_width_sm - size.switch_thumb_sm - 2, thumb.style.translate_x);
    // md stays the default and keeps its own tokens.
    const md = try f.add(try Switch(.{ .checked = true }).mount(f.scope, f.cx));
    try std.testing.expectEqual(size.switch_width, md.children.items[0].style.width.px);
    try std.testing.expectEqual(size.switch_width - size.switch_thumb - 2, md.children.items[0].children.items[0].style.translate_x);
}

test "Switch: local model toggles and reports; disabled source blocks input" {
    const f = try Fixture.init();
    defer f.deinit();
    var sink = BoolSink{};
    const off = try f.scope.createSignal(bool, false);
    const sw = try f.add(try Switch(.{ .disabled = off, .on_change = f.cx.on(BoolSink, &sink, BoolSink.changed) }).mount(f.scope, f.cx));
    clickSwitch(sw);
    try std.testing.expectEqual(@as(?bool, true), sink.last);
    try std.testing.expect(sw.behavior.interaction.a11y.?.checked.?);
    // Keyboard: Space via Cx synthesize click on focus node
    f.cx.setViewport(200, 100);
    f.cx.layout();
    f.cx.focus_manager.setFocus(sw);
    f.cx.handleKeyDown(.space, .{});
    try std.testing.expectEqual(@as(?bool, false), sink.last);
    off.set(true);
    clickSwitch(sw);
    try std.testing.expectEqual(@as(u32, 2), sink.calls);
    // disabled exit Tab order, a11y sync
    try std.testing.expect(!sw.behavior.interaction.focusable);
    try std.testing.expect(sw.behavior.interaction.a11y.?.disabled);
}

test "Switch: bound model — external set moves the thumb with a transition" {
    const f = try Fixture.init();
    defer f.deinit();
    const wifi = try f.scope.createSignal(bool, false);
    const sw = try f.add(try Switch(.{ .label = "Wi-Fi", .checked = wifi }).mount(f.scope, f.cx));
    const thumb = sw.children.items[0].children.items[0];
    try std.testing.expectEqual(@as(f32, 2), thumb.style.translate_x);
    wifi.set(true);
    try std.testing.expect(sw.behavior.interaction.a11y.?.checked.?);
    // offset advance by transition declare in style (translate-x 200ms), target 20
    const slot = thumb.frame_state.frame_local.runtime.transitions.?.find(.translate_x).?;
    try std.testing.expect(slot.active);
    // LKxqO: off/on labels both use fg_primary; only the thumb moves.
    const label = sw.children.items[1];
    try std.testing.expectEqual(f.cx.tokens.tokens.color.fg_primary, label.getText().?.color);
    clickSwitch(sw);
    try std.testing.expect(!wifi.peek());
}

test "Switch: split model — rejected toggle keeps the signal" {
    const f = try Fixture.init();
    defer f.deinit();
    const on = try f.scope.createSignal(bool, true);
    const Deny = struct {
        fn propose(_: *@This(), _: bool) void {}
    };
    var deny = Deny{};
    const sw = try f.add(try Switch(.{ .checked = ui_split(on, f.cx.on(Deny, &deny, Deny.propose)) }).mount(f.scope, f.cx));
    clickSwitch(sw);
    try std.testing.expect(on.peek());
    try std.testing.expect(sw.behavior.interaction.a11y.?.checked.?);
}

test "Switch: 静态 props 不建 memo；焦点环已挂上" {
    const f = try Fixture.init();
    defer f.deinit();
    const before = f.cx.owner.graph.countByKind().get(.memo);
    const sw = try f.add(try Switch(.{ .label = "Static", .checked = true }).mount(f.scope, f.cx));
    try std.testing.expectEqual(before, f.cx.owner.graph.countByKind().get(.memo));
    try std.testing.expect(sw.meta.per_frame.hooks.slots.focus_ring_anim != null);
    try std.testing.expectEqualStrings("Switch", sw.meta.ownership.meta.component_name.?);
}

test {
    _ = @import("_styles.yss.zig");
}

// per-alloc OOM sweep, see src/ui/components/oom_sweep.zig
test "checkbox(indeterminate): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("checkbox(indeterminate)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Checkbox(.{ .label = "check", .indeterminate = true }).mount(scope, cx);
        }
    }.m);
}

// per-alloc OOM sweep, see src/ui/components/oom_sweep.zig
test "radio_group: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("radio_group", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const opts = [_]RadioOption{ .{ .value = "a", .label = "A" }, .{ .value = "b", .label = "B", .disabled = true } };
            return try RadioGroup(.{ .options = &opts, .value = "a" }).mount(scope, cx);
        }
    }.m);
}

// per-alloc OOM sweep, see src/ui/components/oom_sweep.zig
test "switch: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("switch", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Switch(.{ .label = "toggle", .checked = true }).mount(scope, cx);
        }
    }.m);
}

test "radio_group(options signal): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("radio_group(signal)", struct {
        const opts = [_]RadioOption{ .{ .value = "a", .label = "A" }, .{ .value = "b", .label = "B" } };
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const o = try scope.createSignal([]const RadioOption, &opts);
            const v = try scope.createSignal(?[]const u8, "a");
            return try RadioGroup(.{ .options = o, .value = v }).mount(scope, cx);
        }
    }.m);
}

test "RadioGroup: static options are copied, so a caller's stack array may go away" {
    const f = try Fixture.init();
    defer f.deinit();
    var sink = StrSink{};
    const group = blk: {
        var opts = [_]RadioOption{ .{ .value = "a", .label = "A" }, .{ .value = "b", .label = "B" } };
        const g = try RadioGroup(.{ .options = &opts, .on_change = f.cx.on(StrSink, &sink, StrSink.changed) }).mount(f.scope, f.cx);
        opts[1] = .{ .value = "clobbered", .label = "X" }; // caller later clobber/free own array
        break :blk g;
    };
    _ = try f.add(group);
    press(option(group, 1));
    try std.testing.expectEqualStrings("b", sink.value());
}

test "RadioGroup: mount builds the selected state directly (no transition at mount)" {
    const f = try Fixture.init();
    defer f.deinit();
    const opts = [_]RadioOption{ .{ .value = "x", .label = "X" }, .{ .value = "y", .label = "Y" } };
    const group = try f.add(try RadioGroup(.{ .options = &opts, .value = "y" }).mount(f.scope, f.cx));
    for (group.children.items) |radio| {
        const circle = radio.children.items[0];
        const dot = circle.children.items[0];
        for ([_]*Node{ circle, dot }) |n| {
            if (n.frame_state.frame_local.runtime.transitions) |slots| try std.testing.expect(!slots.any_active);
        }
    }
    try std.testing.expectEqual(@as(f32, 1), radioDotOpacity(group, 1));
}

test "RadioGroup: an equal-content options array does not rebuild the items" {
    const f = try Fixture.init();
    defer f.deinit();
    // string literal deduplicate (same addr), need 'same content, diff addr' must use separate
    // buffer
    const Arrays = struct {
        var va1 = "a".*;
        var la1 = "A".*;
        var vb1 = "b".*;
        var lb1 = "B".*;
        var va2 = "a".*;
        var la2 = "A".*;
        var vb2 = "b".*;
        var lb2 = "B".*;
        var a: [2]RadioOption = undefined;
        var b: [2]RadioOption = undefined;
    };
    Arrays.a = .{ .{ .value = &Arrays.va1, .label = &Arrays.la1 }, .{ .value = &Arrays.vb1, .label = &Arrays.lb1 } };
    Arrays.b = .{ .{ .value = &Arrays.va2, .label = &Arrays.la2 }, .{ .value = &Arrays.vb2, .label = &Arrays.lb2 } };
    // memo switch between two same-content diff-addr arrays: memo compare key byte-wise, propagate
    // down
    const which = try f.scope.createSignal(bool, false);
    const options = try f.scope.createMemo([]const RadioOption, .{ .which = which }, struct {
        fn pick(c: anytype) []const RadioOption {
            return if (c.which.get()) Arrays.b[0..] else Arrays.a[0..];
        }
    }.pick);
    const group = try f.add(try RadioGroup(.{ .options = options }).mount(f.scope, f.cx));
    const first = group.children.items[0];
    which.set(true);
    // confirm view truly re-ran (memo byte compare, diff addr means propagate), just no rebuild
    try std.testing.expect(options.peek().ptr == &Arrays.b);
    try std.testing.expect(group.children.items[0] == first);
}
