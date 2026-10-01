/// NumberStepper，数值步进器（B5）：[-] 42 [+]
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Padding = core.Padding;
const Scope = @import("../../reactive.zig").Scope;
const KeyCode = core.KeyCode;
const Modifiers = core.Modifiers;
const EventResult = core.EventResult;

pub const NumberStepperProps = struct {
    value: f64 = 0,
    min: ?f64 = null,
    max: ?f64 = null,
    step: f64 = 1,
    width: f32 = 140,
    disabled: bool = false,
    /// 值变化后触发；caller 读 state.value
    on_change: ?core.HandlerRef = null,
};

pub const NumberStepperState = struct {
    value: f64,
    min: ?f64,
    max: ?f64,
    step: f64,
    disabled: bool,
    value_node: *Node,
    /// wrapper 节点：role=spinbutton 的 a11y 数值挂在它身上
    wrapper_node: ?*Node = null,
    buf: [32]u8 = [_]u8{0} ** 32,
    on_change: ?core.HandlerRef,

    fn clampValue(self: *const NumberStepperState, v: f64) f64 {
        var out = v;
        if (self.min) |m| out = @max(out, m);
        if (self.max) |m| out = @min(out, m);
        return out;
    }

    pub fn setValue(self: *NumberStepperState, v: f64) void {
        const clamped = self.clampValue(v);
        if (clamped == self.value) return;
        self.value = clamped;
        self.syncLabel();
        if (self.on_change) |h| h.invoke();
    }

    pub fn increment(self: *NumberStepperState) void {
        if (self.disabled) return;
        self.setValue(self.value + self.step);
    }

    pub fn decrement(self: *NumberStepperState) void {
        if (self.disabled) return;
        self.setValue(self.value - self.step);
    }

    fn syncLabel(self: *NumberStepperState) void {
        // 整数 step + 整数值 -> 无小数显示
        // @intFromFloat 对 inf / |v| >= 2^63 直接 panic：超出 i64 的值走浮点格式化
        const fits_i64 = std.math.isFinite(self.value) and @abs(self.value) < 0x1p63;
        const is_int = fits_i64 and self.value == @trunc(self.value) and self.step == @trunc(self.step);
        const label = if (is_int)
            std.fmt.bufPrint(&self.buf, "{d}", .{@as(i64, @intFromFloat(self.value))}) catch "?"
        else
            std.fmt.bufPrint(&self.buf, "{d:.2}", .{self.value}) catch "?";
        if (self.value_node.getText()) |old| {
            var t = old;
            t.content = label;
            self.value_node.setText(t);
        }
        self.value_node.markRenderDirty();

        // a11y 数值跟着每次步进走。syncLabel 是唯一的值落地点（init 与
        // setValue 都经过这里），挂在这儿就不会有"改了值但 AT 没跟上"的缝。
        // min/max 缺省时用当前值填充，表示该方向无界，总比报 0 强，
        // 报 0 会让 AT 以为"已经到底了"。
        if (self.wrapper_node) |w| {
            if (w.behavior.interaction.a11y) |*a| {
                a.value_now = @floatCast(self.value);
                a.value_min = @floatCast(self.min orelse self.value);
                a.value_max = @floatCast(self.max orelse self.value);
                a.value_text = self.value_node.getText().?.content;
                if (a.value_range) |*range| {
                    range.now = @floatCast(self.value);
                    range.min = @floatCast(self.min orelse self.value);
                    range.max = @floatCast(self.max orelse self.value);
                }
            }
        }
    }
};

fn setA11yStepperValue(context: *anyopaque, value: f32) bool {
    const state: *NumberStepperState = @ptrCast(@alignCast(context));
    state.setValue(value);
    return true;
}

pub const NumberStepperMount = struct {
    wrapper: *Node,
    state: *NumberStepperState,
};

fn onMinus(ctx: *anyopaque) void {
    const s: *NumberStepperState = @ptrCast(@alignCast(ctx));
    s.decrement();
}

fn onPlus(ctx: *anyopaque) void {
    const s: *NumberStepperState = @ptrCast(@alignCast(ctx));
    s.increment();
}

fn onStepKey(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    const state: *NumberStepperState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (key) {
        .right, .up => state.increment(),
        .left, .down => state.decrement(),
        else => return .ignored,
    }
    return .handled;
}

// 样式层已析出到 styles.zig
const styles = @import("styles.zig");
const stepBtnStyle = styles.stepBtnStyle;
const stepBtnLabelStyle = styles.stepBtnLabelStyle;
const stepperWrapperStyle = styles.stepperWrapperStyle;
const stepperValueStyle = styles.stepperValueStyle;

fn stepBtn(cx: *Cx, t: *const core.ThemeTokens, label: []const u8, disabled: bool, a11y_label: []const u8) !*Node {
    const btn = try box(cx, stepBtnStyle(t), .{});
    // sweep：txt 建失败时 btn 不能漏
    errdefer cx.freeNode(btn);
    if (!disabled) btn.style.cursor = .pointer;
    // 子树文本是 "-"/"+"，靠 fallback 会读成"连字符""加号"这种无意义的字符名；
    // 必须显式给语义化 label。
    btn.behavior.interaction.a11y = .{
        .role = .button,
        .label = a11y_label,
        .disabled = disabled,
    };
    const txt = try core.adoptChild(cx, cx.allocator, btn, try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{}));
    var txt_props = stepBtnLabelStyle(disabled, t);
    txt_props.content = label;
    txt.setText(txt_props);
    return btn;
}

pub fn mountNumberStepper(props: NumberStepperProps, scope: *Scope, cx: *Cx) !NumberStepperMount {
    const my_scope = try scope.childScope();
    const allocator = cx.allocator;
    const t = cx.tokens;

    const state = try my_scope.allocator.create(NumberStepperState);
    try my_scope.adoptResource(@ptrCast(state), struct {
        fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
            alloc.destroy(@as(*NumberStepperState, @ptrCast(@alignCast(ptr))));
        }
    }.cleanup);

    const wrapper = try box(cx, stepperWrapperStyle(props.width, t), .{});
    wrapper.style.overflow_hidden = true;
    wrapper.meta.ownership.meta.component_name = "NumberStepper";
    // sweep：wrapper 守到 return（连带 dispose 绑上的 my_scope）；子节点建好即 adopt
    errdefer cx.freeNode(wrapper);
    try core.bindScopeToNode(my_scope, wrapper);
    // role=spinbutton 是 ARIA 给"带增减按钮的数值输入"的专用角色：AT 据此
    // 提示用户可以用上下键调值，并播报当前值与可用范围。
    wrapper.behavior.interaction.a11y = .{
        .role = .spinbutton,
        .disabled = props.disabled,
    };
    wrapper.setFocusable(!props.disabled);

    const minus = try core.adoptChild(cx, allocator, wrapper, try stepBtn(cx, t, "-", props.disabled, "Decrease"));

    const value_cell = try core.adoptChild(cx, allocator, wrapper, try box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .justify = .center,
        .align_items = .center,
    }, .{}));
    const value_node = try core.adoptChild(cx, allocator, value_cell, try box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} } }, .{}));
    value_node.setText(stepperValueStyle(props.disabled, t));

    const plus = try core.adoptChild(cx, allocator, wrapper, try stepBtn(cx, t, "+", props.disabled, "Increase"));

    state.* = .{
        .value = props.value,
        .min = props.min,
        .max = props.max,
        .step = props.step,
        .disabled = props.disabled,
        .value_node = value_node,
        .wrapper_node = wrapper,
        .on_change = props.on_change,
    };
    // 初始值也走 clamp + 格式化
    state.value = state.clampValue(props.value);
    if (wrapper.behavior.interaction.a11y) |*a11y| {
        a11y.value_range = .{
            .now = @floatCast(state.value),
            .min = @floatCast(state.min orelse state.value),
            .max = @floatCast(state.max orelse state.value),
            // The native value setter is only truthful when both published
            // bounds are real. Unbounded steppers remain operable through
            // increment/decrement actions instead of advertising a direct
            // setter that would be clamped to the synthetic current-value
            // fallback used for missing bounds.
            .context = if (state.min != null and state.max != null) state else null,
            .set_value = if (state.min != null and state.max != null) setA11yStepperValue else null,
        };
    }
    state.syncLabel();

    if (!props.disabled) {
        wrapper.behavior.events.on_key_down = onStepKey;
        wrapper.behavior.events.key_context = @ptrCast(state);
    }

    if (!props.disabled) {
        minus.behavior.events.on_click = .{ .callback = onMinus, .context = @ptrCast(state) };
        plus.behavior.events.on_click = .{ .callback = onPlus, .context = @ptrCast(state) };
    }

    return .{ .wrapper = wrapper, .state = state };
}

// ============================================================================

test "NumberStepper: 步进 + clamp" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ns = try mountNumberStepper(.{ .value = 9, .min = 0, .max = 10, .step = 2 }, scope, cx);
    try root.appendChild(testing.allocator, ns.wrapper);

    try testing.expectEqualStrings("9", ns.state.value_node.getText().?.content);
    ns.state.increment();
    try testing.expectEqual(@as(f64, 10), ns.state.value); // clamp 到 max
    try testing.expectEqualStrings("10", ns.state.value_node.getText().?.content);
    ns.state.decrement();
    ns.state.decrement();
    ns.state.decrement();
    ns.state.decrement();
    ns.state.decrement();
    try testing.expectEqual(@as(f64, 0), ns.state.value); // clamp 到 min
}

test "NumberStepper: inf / 超 i64 范围的值不 panic" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ns = try mountNumberStepper(.{ .value = 0, .step = 1 }, scope, cx);
    try root.appendChild(testing.allocator, ns.wrapper);
    ns.state.setValue(1e19);
    ns.state.setValue(-0x1p63);
    ns.state.setValue(std.math.inf(f64));
    ns.state.setValue(-std.math.inf(f64));
    try testing.expect(ns.state.value_node.getText().?.content.len > 0);
    ns.state.setValue(42);
    try testing.expectEqualStrings("42", ns.state.value_node.getText().?.content);
}

test "NumberStepper: disabled 不响应" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const ns = try mountNumberStepper(.{ .value = 5, .disabled = true }, scope, cx);
    try root.appendChild(testing.allocator, ns.wrapper);
    ns.state.increment();
    try testing.expectEqual(@as(f64, 5), ns.state.value);
}

// styles.zig 的测试收集，这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep，见 src/ui/components/oom_sweep.zig
test "number_stepper: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("number_stepper", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try mountNumberStepper(.{ .value = 9, .min = 0, .max = 10, .step = 2 }, scope, cx)).wrapper;
        }
    }.m);
}
