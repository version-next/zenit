/// NumberStepper - numeric field with stacked increase/decrease arrows.
///
/// Editing follows NSTextField + NSStepper / `<input type=number>`: typing only edits a draft;
/// Return or blur parses, clamps and commits it once (invalid / empty reverts); Escape discards
/// the draft; Up / Down step from the draft; Left / Right stay caret movement.
/// Disabling the control while a draft is pending discards it (no commit, no on_change).
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core.Handler;
const Event = core.Event;
const EventResult = core.EventResult;
const view = @import("../../view.zig");
const hooks = @import("../../hooks.zig");
const icons = @import("zenit_system_icons");
const input_mod = @import("../input/mod.zig");

pub const NumberStepperProps = struct {
    /// current value: `f64` uncontrolled initial; `*Signal(f64)` controlled (interactions write
    /// directly); `ui.split` intercepts. out-of-bounds external values display clamped, not written
    /// back.
    value: Model(f64) = .{ .local = 0 },
    min: ?f64 = null,
    max: ?f64 = null,
    step: f64 = 1,
    width: f32 = 140,
    disabled: Source(bool) = .{ .value = false },
    /// called after a user step or text commit lands (landed value)
    on_change: ?Handler(f64) = null,
};

/// NumberStepper runtime (scope-owned): view = f(value, disabled)
pub const NumberStepperRuntime = struct {
    value: reactive.Bound(f64),
    disabled: Source(bool),
    on_change: ?Handler(f64),
    min: ?f64,
    max: ?f64,
    step: f64,
    /// current displayed value (data value clamped to range)
    shown: f64 = 0,
    /// disabled state last applied to the view (render cache only). Interaction gates read the
    /// `disabled` source itself (`disabledNow`): another effect - the embedded field revoking
    /// focus - can call back into this runtime before this runtime's own effect has run.
    applied_disabled: bool = false,
    /// a blur delivered inside an effect commits once the reactive work has settled
    blur_commit: reactive.SignalOwner.SettledTask = .{},
    /// a11y value_text storage: the field text is a draft while editing, never borrow it
    value_text_buf: [32]u8 = undefined,
    /// field text: formatted `shown` at rest, the user's draft while editing (owned text signal)
    text: *Signal([]const u8),
    field: *input_mod.TextInputState,
    minus: *Node,
    plus: *Node,
    /// wrapper node: a11y numeric value for role=spinbutton lives here
    wrapper_node: *Node,
    cx: *Cx,

    fn clampValue(self: *const NumberStepperRuntime, v: f64) f64 {
        return clampTo(self.min, self.max, v);
    }

    fn view(self: *NumberStepperRuntime, comptime tracked: bool) !void {
        const v = self.clampValue(self.value.readAs(tracked));
        const dis = self.disabled.read(tracked);
        if (dis != self.applied_disabled) {
            self.applied_disabled = dis;
            self.applyDisabled();
        }
        // NaN != NaN: an external NaN write formats once
        if (v != self.shown and !(std.math.isNan(v) and std.math.isNan(self.shown))) {
            self.shown = v;
            self.syncText(v);
            self.syncA11y();
        }
    }

    fn viewEffect(self: *NumberStepperRuntime) void {
        self.view(true) catch |err| std.log.err("[NumberStepper] update failed: {}", .{err});
    }

    /// field text color follows the field's own disabled state
    fn applyDisabled(self: *NumberStepperRuntime) void {
        const dis = self.applied_disabled;
        const t = self.cx.tokens;
        if (self.wrapper_node.behavior.interaction.a11y) |*a| a.disabled = dis;
        for ([_]*Node{ self.minus, self.plus }) |btn| {
            btn.style.cursor = if (dis) .default else .pointer;
            if (btn.behavior.interaction.a11y) |*a| a.disabled = dis;
            const label = btn.children.items[0];
            if (label.getText()) |old| {
                var txt = old;
                txt.color = styles.stepBtnLabelStyle(dis, t).color;
                label.setText(txt);
            }
            _ = label.setTint(styles.stepBtnLabelStyle(dis, t).color);
            btn.markRenderDirty();
        }
    }

    fn format(self: *const NumberStepperRuntime, v: f64, buf: []u8) []const u8 {
        return formatValue(self.step, v, buf);
    }

    /// Replace the field text (drops any draft); same content leaves the caret alone.
    fn syncText(self: *NumberStepperRuntime, v: f64) void {
        var buf: [32]u8 = undefined;
        self.text.set(self.format(v, &buf));
    }

    fn syncA11y(self: *NumberStepperRuntime) void {
        // min/max when absent filled with current value, indicates that direction unbounded, better
        // than reporting 0: reporting 0 makes AT think 'already at limit'. value_text points to
        // the runtime's own copy of the formatted value.
        if (self.wrapper_node.behavior.interaction.a11y) |*a| {
            a.value_now = @floatCast(self.shown);
            a.value_min = @floatCast(self.min orelse self.shown);
            a.value_max = @floatCast(self.max orelse self.shown);
            a.value_text = self.format(self.shown, &self.value_text_buf);
            if (a.value_range) |*range| {
                range.now = @floatCast(self.shown);
                range.min = @floatCast(self.min orelse self.shown);
                range.max = @floatCast(self.max orelse self.shown);
            }
        }
        self.wrapper_node.markRenderDirty();
    }

    /// current disabled state, independent of effect order
    fn disabledNow(self: *const NumberStepperRuntime) bool {
        return self.disabled.read(false);
    }

    fn isDirty(self: *const NumberStepperRuntime) bool {
        var buf: [32]u8 = undefined;
        return !std.mem.eql(u8, self.text.peek(), self.format(self.shown, &buf));
    }

    /// draft text parsed, null when it is the displayed value, empty or not a finite number
    fn draftValue(self: *const NumberStepperRuntime) ?f64 {
        if (!self.isDirty()) return null;
        const draft = std.mem.trim(u8, self.text.peek(), " ");
        const v = std.fmt.parseFloat(f64, draft) catch return null;
        return if (std.math.isFinite(v)) v else null;
    }

    /// user input: clamped to range then proposed; the field is rewritten to the landed (or
    /// rejected -> current) value even when unchanged ("05" -> "5"); landing calls on_change
    /// (last step, may destroy component)
    fn propose(self: *NumberStepperRuntime, raw: f64) void {
        if (self.disabledNow() or std.math.isNan(raw)) return;
        const landed = self.value.commit(self.clampValue(raw));
        self.syncText(self.clampValue(self.value.readAs(false)));
        if (landed) |v| if (self.on_change) |h| h.call(v);
    }

    /// Return / blur: commit a dirty draft; unparsable drafts revert to the displayed value.
    /// A disabled control discards its draft instead (like a disabled NSTextField /
    /// `<input type=number>`: it accepts no user value and sends no action / change).
    fn commitDraft(self: *NumberStepperRuntime) void {
        if (!self.isDirty()) return;
        if (self.disabledNow()) return self.syncText(self.shown);
        if (self.draftValue()) |v| self.propose(v) else self.syncText(self.shown);
    }

    /// Blur ends editing. A blur set off by an effect (disabling the field revokes focus, an
    /// effect moving focus) must not propose from inside it: the commit waits until the reactive
    /// work has settled and then sees the settled state (disabled -> discard).
    fn endEditing(self: *NumberStepperRuntime) void {
        self.cx.owner.runOutsideComputation(&self.blur_commit, @ptrCast(self), struct {
            fn run(ptr: *anyopaque) void {
                const rt: *NumberStepperRuntime = @ptrCast(@alignCast(ptr));
                rt.commitDraft();
            }
        }.run);
    }

    /// step baseline: a valid draft (like <input type=number>), else the shown value; when
    /// external writes NaN start from min or 0, else keys fail
    fn base(self: *const NumberStepperRuntime) f64 {
        if (self.draftValue()) |v| return v;
        return if (std.math.isNan(self.shown)) self.min orelse 0 else self.shown;
    }

    fn stepBy(self: *NumberStepperRuntime, direction: f64) void {
        self.propose(self.base() + direction * self.step);
    }

    fn increment(self: *NumberStepperRuntime) void {
        self.stepBy(1);
    }

    fn decrement(self: *NumberStepperRuntime) void {
        self.stepBy(-1);
    }
};

fn clampTo(min: ?f64, max: ?f64, v: f64) f64 {
    var out = v;
    if (min) |m| out = @max(out, m);
    if (max) |m| out = @min(out, m);
    return out;
}

/// integer step + integer value -> no decimals; NaN -> empty field. @intFromFloat panics on inf /
/// |v| >= 2^63: values outside i64 range use float format
fn formatValue(step: f64, v: f64, buf: []u8) []const u8 {
    if (std.math.isNan(v)) return "";
    const fits_i64 = std.math.isFinite(v) and @abs(v) < 0x1p63;
    const is_int = fits_i64 and v == @trunc(v) and step == @trunc(step);
    return if (is_int)
        std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "?";
}

/// returns true if control handled request (caller focuses based on this)
fn setA11yStepperValue(context: *anyopaque, value: f32) bool {
    const rt: *NumberStepperRuntime = @ptrCast(@alignCast(context));
    if (rt.disabledNow()) return false;
    rt.propose(value);
    return true;
}

/// AX increment / decrement: logical step, never routed through the field's arrow keys
fn stepA11y(context: *anyopaque, direction: i8) bool {
    const rt: *NumberStepperRuntime = @ptrCast(@alignCast(context));
    if (rt.disabledNow()) return false;
    rt.stepBy(@floatFromInt(direction));
    return true;
}

pub const NumberStepperResult = struct {
    wrapper: *Node,
    increment_button: *Node,
    decrement_button: *Node,
    /// value signal (`ui.split` = null)
    value: ?*Signal(f64),
    /// the embedded field's edit state (focus / caret)
    field: *input_mod.TextInputState,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: NumberStepperResult) core.ViewParts {
        return .{ .root = self.wrapper };
    }
};

fn onMinus(ctx: *anyopaque) void {
    const rt: *NumberStepperRuntime = @ptrCast(@alignCast(ctx));
    rt.decrement();
}

fn onPlus(ctx: *anyopaque) void {
    const rt: *NumberStepperRuntime = @ptrCast(@alignCast(ctx));
    rt.increment();
}

/// Wrapper capture handler: sees the field's keys and focus changes before the field does.
fn onFieldEvent(event: Event, context: ?*anyopaque) EventResult {
    const rt: *NumberStepperRuntime = @ptrCast(@alignCast(context orelse return .ignored));
    const events = &rt.wrapper_node.behavior.events;
    switch (event) {
        .key_down => |e| {
            if (rt.disabledNow() or rt.field.imeIsComposing() or e.modifiers.super or e.modifiers.ctrl) return .ignored;
            switch (e.key) {
                .up => rt.increment(),
                .down => rt.decrement(),
                .escape => {
                    // Discard the draft; a clean field lets Escape reach the parent (dialog close).
                    if (!rt.isDirty()) return .ignored;
                    rt.syncText(rt.shown);
                },
                .@"return" => {
                    // Commit, then let Return continue to the parent (form default action).
                    rt.commitDraft();
                    return .ignored;
                },
                else => return .ignored,
            }
            return .stop;
        },
        // The field is the focus target; the wrapper's focus ring follows it.
        .focus => if (events.on_focus) |h| h.invoke(),
        .blur => {
            if (events.on_blur) |h| h.invoke();
            rt.endEditing();
        },
        else => {},
    }
    return .ignored;
}

// styling extracted to styles.zig
const styles = @import("styles.zig");
const stepBtnStyle = styles.stepBtnStyle;
const stepBtnLabelStyle = styles.stepBtnLabelStyle;
const stepperWrapperStyle = styles.stepperWrapperStyle;

const StepBtnProps = struct { style: core.BoxStyle, a11y: core.A11yProps, on_click: core.HandlerRef };
const StepIconProps = struct { style: core.BoxStyle, tint: core.Color };

fn stepBtn(t: *const core.ThemeTokens, asset: @import("../../svg_assets.zig").Asset, a11y_label: []const u8, on_click: core.HandlerRef) view.Box(StepBtnProps, view.Icon(StepIconProps), null) {
    return view.box(StepBtnProps{
        .style = stepBtnStyle(t),
        .a11y = .{ .role = .button, .label = a11y_label },
        .on_click = on_click,
    }, view.icon(StepIconProps{ .style = styles.stepIconStyle(t), .tint = t.tokens.color.fg_primary }, asset));
}

fn wireStepButton(scope: *Scope, cx: *Cx, rt: *NumberStepperRuntime, node: *Node, disabled: Source(bool)) !void {
    const hovered = try hooks.useHover(scope, node);
    const pressed = try hooks.usePressed(scope, cx, node);
    try scope.createEffect(.{ .node = node, .rt = rt, .hovered = hovered, .pressed = pressed, .disabled = disabled }, struct {
        fn update(c: anytype) void {
            const dis = c.disabled.read(true);
            const hover = c.hovered.get();
            const active = c.pressed.get();
            const visual = styles.stepButtonConditions(c.rt.cx.tokens).resolve(.{ .is_hovered = hover, .is_pressed = active and hover, .is_disabled = dis });
            c.node.setBackground(visual.background.?);
        }
    }.update);
}

/// create NumberStepper: `W.NumberStepper(.{ .value = qty, .min = 0 }).mount(scope, cx)`
pub fn NumberStepper(props: anytype) NumberStepperBuilder {
    return .{ .props = reactive.props.coerce(NumberStepperProps, props) };
}

pub const NumberStepperBuilder = struct {
    props: NumberStepperProps,

    pub fn mount(self: NumberStepperBuilder, scope: *Scope, cx: *Cx) !NumberStepperResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const props = self.props;
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const t = cx.tokens;
        reactive.checkBorrow(my_scope, props.disabled);
        const value = try reactive.resolveModel(f64, my_scope, props.value);
        const initially_disabled = props.disabled.read(false);
        // field text created already formatted: mount never writes it (Signal.set cannot report
        // allocation failure, mount must)
        const v0 = clampTo(props.min, props.max, value.readAs(false));
        var v0_buf: [32]u8 = undefined;
        const text = try my_scope.createText(formatValue(props.step, v0, &v0_buf), .{});

        // runtime created first (reclaimed with my_scope), button clicks point directly to it; node
        // handle filled after mount
        const rt = try my_scope.allocator.create(NumberStepperRuntime);
        // the cleanup reads it before the full init below
        rt.blur_commit = .{};
        try my_scope.adoptResource(@ptrCast(rt), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const r: *NumberStepperRuntime = @ptrCast(@alignCast(ptr));
                // a pending blur commit must not outlive the runtime
                r.blur_commit.cancel();
                alloc.destroy(r);
            }
        }.cleanup);

        const Parts = struct { minus: *Node = undefined, field: input_mod.InputResult = undefined, plus: *Node = undefined };
        var parts: Parts = .{};
        const wrapper = try view.render(my_scope, cx, view.box(.{
            .style = .{ stepperWrapperStyle(props.width, t), .{ .overflow_hidden = true } },
            // role=spinbutton is ARIA's dedicated role for 'numeric input with
            // increment/decrement': AT uses this to prompt user for arrow keys, announce current
            // value and range.
            .a11y = .{ .role = .spinbutton },
        }, .{
            view.box(.{ .style = styles.valueBoxStyle(t) }, view.capture(&parts.field, input_mod.Input(.{
                .value = text,
                .input_type = .number,
                .disabled = props.disabled,
                .embedded = true,
            }))),
            view.col(.{ .style = styles.arrowsStyle(t) }, .{
                view.capture(&parts.plus, stepBtn(t, icons.chevron_up, "Increase", .{ .callback = onPlus, .context = @ptrCast(rt) })),
                view.capture(&parts.minus, stepBtn(t, icons.chevron_down, "Decrease", .{ .callback = onMinus, .context = @ptrCast(rt) })),
            }),
        }));
        wrapper.meta.ownership.meta.component_name = "NumberStepper";
        // sweep: wrapper guards until return (with disposing attached my_scope)
        errdefer cx.freeNode(wrapper);
        try core.bindScopeToNode(my_scope, wrapper);
        scope_bound = true;

        rt.* = .{
            .value = value,
            .disabled = props.disabled,
            .on_change = props.on_change,
            .min = props.min,
            .max = props.max,
            .step = props.step,
            // field text already shows v0; negated disabled state: first view necessarily applies
            .shown = v0,
            .applied_disabled = !initially_disabled,
            .text = text,
            .field = parts.field.state,
            .minus = parts.minus,
            .plus = parts.plus,
            .wrapper_node = wrapper,
            .cx = cx,
        };
        try wireStepButton(my_scope, cx, rt, parts.plus, props.disabled);
        try wireStepButton(my_scope, cx, rt, parts.minus, props.disabled);
        try hooks.useFocusRing(my_scope, cx, wrapper, .{ .width = t.tokens.border_width.focus, .offset = t.tokens.size.focus_offset });
        if (wrapper.behavior.interaction.a11y) |*a11y| {
            const bounded = props.min != null and props.max != null;
            a11y.value_range = .{
                .small_change = @floatCast(props.step),
                .now = 0,
                .min = @floatCast(props.min orelse 0),
                .max = @floatCast(props.max orelse 0),
                // The native value setter is only truthful when both published
                // bounds are real. Unbounded steppers remain operable through
                // increment/decrement actions instead of advertising a direct
                // setter that would be clamped to the synthetic current-value
                // fallback used for missing bounds.
                .context = rt,
                .set_value = if (bounded) setA11yStepperValue else null,
                .step = stepA11y,
            };
        }

        // the field is the focus target; wrapper captures its keys / focus (disable gated at
        // runtime)
        wrapper.behavior.events.on_event_capture = onFieldEvent;
        wrapper.behavior.events.capture_context = @ptrCast(rt);

        rt.syncA11y();
        try rt.view(false);
        // value is Model: local is also signal, interaction changes it, must have effect
        try my_scope.createEffect(rt, NumberStepperRuntime.viewEffect);
        return .{ .wrapper = wrapper, .value = value.asSignal(), .increment_button = parts.plus, .decrement_button = parts.minus, .field = parts.field.state };
    }
};

// ============================================================================

fn runtimeOf(r: NumberStepperResult) *NumberStepperRuntime {
    return @ptrCast(@alignCast(r.wrapper.behavior.events.capture_context.?));
}

fn valueText(r: NumberStepperResult) []const u8 {
    return runtimeOf(r).text.peek();
}

/// Mounted stepper under cx.root, driven through the real dispatcher (wrapper capture -> field).
const Env = struct {
    cx: *Cx,
    scope: *Scope,

    fn init() !Env {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(400, 300);
        cx.root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
        return .{ .cx = cx, .scope = try Scope.init(std.testing.allocator, null, cx.owner) };
    }

    fn deinit(self: Env) void {
        self.scope.dispose();
        self.cx.deinit();
    }

    fn mount(self: Env, builder: NumberStepperBuilder) !NumberStepperResult {
        const r = try builder.mount(self.scope, self.cx);
        try self.cx.root.?.appendChild(std.testing.allocator, r.wrapper);
        // register the subtree for handle-resolved dispatch and lay the field out
        self.cx.layout();
        _ = self.cx.render();
        return r;
    }

    fn field(r: NumberStepperResult) *Node {
        return r.field.input_container_node.?;
    }

    /// one host input transaction, like the platform pump
    fn send(self: Env, r: NumberStepperResult, event: Event) EventResult {
        self.cx.owner.beginBatch();
        defer self.cx.owner.endBatch();
        return self.cx.dispatcher.dispatch(event, field(r));
    }

    fn key(self: Env, r: NumberStepperResult, k: core.KeyCode) EventResult {
        return self.send(r, .{ .key_down = .{ .key = k } });
    }

    /// focus, select all, type: replaces the field text with a draft
    fn typeDraft(self: Env, r: NumberStepperResult, text: []const u8) !void {
        self.cx.focus_manager.setFocus(field(r));
        try std.testing.expect(r.field.focused);
        _ = self.send(r, .{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } });
        _ = self.send(r, .{ .text_input = .{ .text = text } });
    }

    fn blur(self: Env) void {
        self.cx.owner.beginBatch();
        defer self.cx.owner.endBatch();
        self.cx.focus_manager.setFocus(null);
    }
};

const LandSpy = struct {
    n: usize = 0,
    last: f64 = 0,
    fn landed(self: *LandSpy, v: f64) void {
        self.n += 1;
        self.last = v;
    }
};

test "NumberStepper: 步进 + clamp" {
    const env = try Env.init();
    defer env.deinit();
    const ns = try env.mount(NumberStepper(.{ .value = 9, .min = 0, .max = 10, .step = 2 }));
    const rt = runtimeOf(ns);

    try std.testing.expectEqualStrings("9", valueText(ns));
    rt.increment();
    try std.testing.expectEqual(@as(f64, 10), ns.value.?.peek()); // clamp to max
    try std.testing.expectEqualStrings("10", valueText(ns));
    for (0..5) |_| rt.decrement();
    try std.testing.expectEqual(@as(f64, 0), ns.value.?.peek()); // clamp to min
}

test "NumberStepper: inf / 超 i64 范围的值不 panic；NaN 显示为空" {
    const env = try Env.init();
    defer env.deinit();
    const ns = try env.mount(NumberStepper(.{ .value = 0, .step = 1 }));
    const v = ns.value.?;
    v.set(1e19);
    v.set(-0x1p63);
    v.set(std.math.inf(f64));
    v.set(-std.math.inf(f64));
    try std.testing.expect(valueText(ns).len > 0);
    v.set(std.math.nan(f64));
    try std.testing.expectEqualStrings("", valueText(ns));
    v.set(42);
    try std.testing.expectEqualStrings("42", valueText(ns));
}

test "NumberStepper: 输入草稿不落值，回车 parse + clamp 后提交一次并规范化显示" {
    const env = try Env.init();
    defer env.deinit();
    const qty = try env.scope.createSignal(f64, 5);
    var spy = LandSpy{};
    const ns = try env.mount(NumberStepper(.{ .value = qty, .min = 0, .max = 50, .on_change = env.cx.on(LandSpy, &spy, LandSpy.landed) }));

    try env.typeDraft(ns, "07");
    try std.testing.expectEqualStrings("07", valueText(ns));
    try std.testing.expectEqual(@as(f64, 5), qty.peek()); // typing edits a draft only
    try std.testing.expectEqual(@as(usize, 0), spy.n);
    _ = env.key(ns, .@"return");
    try std.testing.expectEqual(@as(f64, 7), qty.peek());
    try std.testing.expectEqualStrings("7", valueText(ns)); // "07" normalized
    try std.testing.expectEqual(@as(usize, 1), spy.n);
    try std.testing.expectEqual(@as(f64, 7), spy.last);

    // out of range clamps
    try env.typeDraft(ns, "999");
    _ = env.key(ns, .@"return");
    try std.testing.expectEqual(@as(f64, 50), qty.peek());
    try std.testing.expectEqualStrings("50", valueText(ns));

    // clean field: Return commits nothing
    _ = env.key(ns, .@"return");
    try std.testing.expectEqual(@as(usize, 2), spy.n);

    // same value in another spelling: no landing, display normalized
    try env.typeDraft(ns, "5e1");
    _ = env.key(ns, .@"return");
    try std.testing.expectEqual(@as(usize, 2), spy.n);
    try std.testing.expectEqualStrings("50", valueText(ns));
}

test "NumberStepper: 失焦提交；无效 / 空草稿回滚；Escape 放弃草稿" {
    const env = try Env.init();
    defer env.deinit();
    var spy = LandSpy{};
    const ns = try env.mount(NumberStepper(.{ .value = 3, .on_change = env.cx.on(LandSpy, &spy, LandSpy.landed) }));

    try env.typeDraft(ns, "12");
    env.blur();
    try std.testing.expectEqual(@as(f64, 12), ns.value.?.peek());
    try std.testing.expectEqual(@as(usize, 1), spy.n);

    try env.typeDraft(ns, "-");
    env.blur();
    try std.testing.expectEqual(@as(f64, 12), ns.value.?.peek());
    try std.testing.expectEqualStrings("12", valueText(ns));

    try env.typeDraft(ns, "8");
    _ = env.send(ns, .{ .key_down = .{ .key = .delete } });
    try std.testing.expectEqualStrings("", valueText(ns));
    _ = env.key(ns, .@"return");
    try std.testing.expectEqualStrings("12", valueText(ns));

    try env.typeDraft(ns, "40");
    try std.testing.expectEqual(EventResult.stop, env.key(ns, .escape));
    try std.testing.expectEqualStrings("12", valueText(ns));
    env.blur();
    try std.testing.expectEqual(@as(f64, 12), ns.value.?.peek());
    try std.testing.expectEqual(@as(usize, 1), spy.n);

    // clean field: Escape is left to the parent (dialog close)
    env.cx.focus_manager.setFocus(Env.field(ns));
    try std.testing.expect(env.key(ns, .escape) != .stop);
}

test "NumberStepper: 上下键从草稿步进；左右键留给光标" {
    const env = try Env.init();
    defer env.deinit();
    const ns = try env.mount(NumberStepper(.{ .value = 5, .min = 0, .max = 10 }));

    env.cx.focus_manager.setFocus(Env.field(ns));
    try std.testing.expectEqual(EventResult.stop, env.key(ns, .up));
    try std.testing.expectEqual(@as(f64, 6), ns.value.?.peek());
    _ = env.key(ns, .left);
    _ = env.key(ns, .right);
    try std.testing.expectEqual(@as(f64, 6), ns.value.?.peek());

    try env.typeDraft(ns, "2");
    _ = env.key(ns, .down);
    try std.testing.expectEqual(@as(f64, 1), ns.value.?.peek()); // 2 - 1, not 6 - 1
    try std.testing.expectEqualStrings("1", valueText(ns));
}

test "NumberStepper: Tab 进字段时外框焦点环亮起，点击聚焦不亮，失焦熄灭" {
    const env = try Env.init();
    defer env.deinit();
    const ns = try env.mount(NumberStepper(.{ .value = 1 }));
    env.cx.focus_manager.setFocusWithReason(Env.field(ns), .click);
    try std.testing.expect(ns.wrapper.style.outline() == null);
    env.cx.focus_manager.setFocusWithReason(null, .programmatic);
    env.cx.focus_manager.setFocusWithReason(Env.field(ns), .tab);
    try std.testing.expect(ns.wrapper.style.outline() != null);
    env.blur();
    try std.testing.expectEqual(@as(i32, 0), ns.wrapper.style.z_index());
}

test "NumberStepper: 文本按数字过滤" {
    const env = try Env.init();
    defer env.deinit();
    const ns = try env.mount(NumberStepper(.{ .value = 1 }));
    try env.typeDraft(ns, "a1b2");
    try std.testing.expectEqualStrings("12", valueText(ns));
}

test "NumberStepper: bound value, landed on_change, a11y value_text is an owned copy" {
    const env = try Env.init();
    defer env.deinit();
    const qty = try env.scope.createSignal(f64, 1);
    var spy = LandSpy{};
    const ns = try env.mount(NumberStepper(.{ .value = qty, .min = 1, .max = 99, .on_change = env.cx.on(LandSpy, &spy, LandSpy.landed) }));
    qty.set(1000); // external out-of-bounds: display clamped, not written back
    try std.testing.expectEqualStrings("99", valueText(ns));
    try std.testing.expectEqual(@as(f64, 1000), qty.peek());
    env.cx.focus_manager.setFocus(Env.field(ns));
    _ = env.key(ns, .down);
    try std.testing.expectEqual(@as(f64, 98), qty.peek());
    try std.testing.expectEqual(@as(f64, 98), spy.last);
    try std.testing.expectEqualStrings("98", valueText(ns));
    // drafts rewrite the field text; the announced value stays the committed one
    try env.typeDraft(ns, "4");
    try std.testing.expectEqualStrings("98", ns.wrapper.behavior.interaction.a11y.?.value_text.?);
}

test "NumberStepper: AX increment / decrement 走逻辑步进，不合成方向键" {
    const env = try Env.init();
    defer env.deinit();
    const ns = try env.mount(NumberStepper(.{ .value = 3 }));
    const range = ns.wrapper.behavior.interaction.a11y.?.value_range.?;
    try std.testing.expect(range.set_value == null); // unbounded: no direct setter
    try std.testing.expect(range.step.?(range.context.?, 1));
    try std.testing.expectEqual(@as(f64, 4), ns.value.?.peek());
    try std.testing.expect(range.step.?(range.context.?, -1));
    try std.testing.expectEqual(@as(f64, 3), ns.value.?.peek());
}

test "NumberStepper: 外部写入 NaN 后按键仍能从 min / 0 起步" {
    const env = try Env.init();
    defer env.deinit();
    const ns = try env.mount(NumberStepper(.{ .value = 3 }));
    ns.value.?.set(std.math.nan(f64));
    runtimeOf(ns).increment();
    try std.testing.expectEqual(@as(f64, 1), ns.value.?.peek());
}

test "NumberStepper: on_change 在宿主 batch 内销毁组件，batch 结束时不运行已销毁的 effect" {
    const env = try Env.init();
    defer env.deinit();
    const Killer = struct {
        cx: *Cx,
        wrapper: *Node = undefined,
        fn changed(self: *@This(), _: f64) void {
            self.cx.detachChild(self.wrapper.parent.?, self.wrapper);
            self.cx.freeNode(self.wrapper);
        }
    };
    var killer = Killer{ .cx = env.cx };
    const ns = try env.mount(NumberStepper(.{ .value = 1, .on_change = env.cx.on(Killer, &killer, Killer.changed) }));
    killer.wrapper = ns.wrapper;
    env.cx.focus_manager.setFocus(Env.field(ns));
    _ = env.key(ns, .up); // view effect destroyed with scope: drain must skip it
    try std.testing.expectEqual(@as(usize, 0), env.cx.root.?.children.items.len);
}

test "NumberStepper: 提交草稿时 on_change 销毁组件不崩" {
    const env = try Env.init();
    defer env.deinit();
    const Killer = struct {
        cx: *Cx,
        wrapper: *Node = undefined,
        fn changed(self: *@This(), _: f64) void {
            self.cx.detachChild(self.wrapper.parent.?, self.wrapper);
            self.cx.freeNode(self.wrapper);
        }
    };
    var killer = Killer{ .cx = env.cx };
    const ns = try env.mount(NumberStepper(.{ .value = 1, .on_change = env.cx.on(Killer, &killer, Killer.changed) }));
    killer.wrapper = ns.wrapper;
    try env.typeDraft(ns, "6");
    _ = env.key(ns, .@"return");
    try std.testing.expectEqual(@as(usize, 0), env.cx.root.?.children.items.len);
}

test "NumberStepper: disabled 不响应；可动态切换" {
    const env = try Env.init();
    defer env.deinit();
    const off = try env.scope.createSignal(bool, true);
    const ns = try env.mount(NumberStepper(.{ .value = 5, .disabled = off }));
    const rt = runtimeOf(ns);
    rt.increment();
    try std.testing.expectEqual(@as(f64, 5), ns.value.?.peek());
    try std.testing.expect(!Env.field(ns).behavior.interaction.focusable);
    try std.testing.expect(rt.plus.behavior.interaction.a11y.?.disabled);
    try std.testing.expect(ns.wrapper.behavior.interaction.a11y.?.disabled);
    off.set(false);
    try std.testing.expect(Env.field(ns).behavior.interaction.focusable);
    try std.testing.expect(!rt.plus.behavior.interaction.a11y.?.disabled);
    rt.plus.behavior.events.on_click.?.callback(rt.plus.behavior.events.on_click.?.context);
    try std.testing.expectEqual(@as(f64, 6), ns.value.?.peek());
}

test "NumberStepper: 聚焦且有草稿时动态禁用：丢弃草稿、不提交、不触发 on_change" {
    const env = try Env.init();
    defer env.deinit();
    const off = try env.scope.createSignal(bool, false);
    const qty = try env.scope.createSignal(f64, 5);
    var spy = LandSpy{};
    const ns = try env.mount(NumberStepper(.{ .value = qty, .disabled = off, .on_change = env.cx.on(LandSpy, &spy, LandSpy.landed) }));
    try env.typeDraft(ns, "8");
    try std.testing.expectEqualStrings("8", valueText(ns));
    off.set(true);
    try std.testing.expect(!ns.field.focused);
    try std.testing.expectEqual(@as(f64, 5), qty.peek());
    try std.testing.expectEqual(@as(usize, 0), spy.n);
    try std.testing.expectEqualStrings("5", valueText(ns));
    off.set(false);
    try std.testing.expectEqualStrings("5", valueText(ns));
    try std.testing.expect(Env.field(ns).behavior.interaction.focusable);
    try env.typeDraft(ns, "9");
    _ = env.key(ns, .@"return");
    try std.testing.expectEqual(@as(f64, 9), qty.peek());
    try std.testing.expectEqual(@as(usize, 1), spy.n);
}

test "NumberStepper: effect 内移走焦点：草稿在响应式工作结束后提交一次（不在 effect 内提议）" {
    const env = try Env.init();
    defer env.deinit();
    const qty = try env.scope.createSignal(f64, 5);
    var spy = LandSpy{};
    const ns = try env.mount(NumberStepper(.{ .value = qty, .on_change = env.cx.on(LandSpy, &spy, LandSpy.landed) }));
    const other = try box(env.cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    other.setFocusable(true);
    try env.cx.root.?.appendChild(std.testing.allocator, other);
    env.cx.layout();
    const go = try env.scope.createSignal(bool, false);
    try env.scope.createEffect(.{ .go = go, .cx = env.cx, .other = other }, struct {
        fn run(c: anytype) void {
            if (c.go.get()) c.cx.focus_manager.setFocus(c.other);
        }
    }.run);
    try env.typeDraft(ns, "8");
    go.set(true); // the blur lands inside the effect above
    try std.testing.expect(!ns.field.focused);
    try std.testing.expectEqual(@as(f64, 8), qty.peek());
    try std.testing.expectEqual(@as(usize, 1), spy.n);
    try std.testing.expectEqualStrings("8", valueText(ns));
}

test "NumberStepper: effect 移走焦点并同时销毁组件：挂起的失焦提交随组件取消" {
    const env = try Env.init();
    defer env.deinit();
    var spy = LandSpy{};
    const ns = try env.mount(NumberStepper(.{ .value = 5, .on_change = env.cx.on(LandSpy, &spy, LandSpy.landed) }));
    const go = try env.scope.createSignal(bool, false);
    try env.scope.createEffect(.{ .go = go, .cx = env.cx, .wrapper = ns.wrapper }, struct {
        fn run(c: anytype) void {
            if (!c.go.get()) return;
            c.cx.focus_manager.setFocus(null); // queues the blur commit
            c.cx.detachChild(c.wrapper.parent.?, c.wrapper);
            c.cx.freeNode(c.wrapper); // runtime released before the reactive work settles
        }
    }.run);
    try env.typeDraft(ns, "8");
    go.set(true);
    try std.testing.expectEqual(@as(usize, 0), spy.n);
    try std.testing.expect(env.cx.owner.settled_tasks.head == null);
}

test "NumberStepper: 批内禁用并移走焦点：草稿丢弃，不提交" {
    const env = try Env.init();
    defer env.deinit();
    const off = try env.scope.createSignal(bool, false);
    var spy = LandSpy{};
    const ns = try env.mount(NumberStepper(.{ .value = 5, .disabled = off, .on_change = env.cx.on(LandSpy, &spy, LandSpy.landed) }));
    try env.typeDraft(ns, "8");
    // handler context: disabled is written, the stepper's effect has not run yet
    env.cx.owner.beginBatch();
    off.set(true);
    env.cx.focus_manager.setFocus(null);
    env.cx.owner.endBatch();
    try std.testing.expectEqual(@as(f64, 5), ns.value.?.peek());
    try std.testing.expectEqual(@as(usize, 0), spy.n);
    try std.testing.expectEqualStrings("5", valueText(ns));
}

// test collection for styles.zig, this line is required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// per-allocation OOM sweep, see src/ui/components/oom_sweep.zig
test "number_stepper: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("number_stepper", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try NumberStepper(.{ .value = 9, .min = 0, .max = 10, .step = 2 }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "number_stepper: 动态值 / disabled 的 mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("number_stepper(dynamic)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const v = try scope.createSignal(f64, 3);
            const off = try scope.createSignal(bool, false);
            return (try NumberStepper(.{ .value = v, .min = 0, .max = 10, .disabled = off }).mount(scope, cx)).wrapper;
        }
    }.m);
}
