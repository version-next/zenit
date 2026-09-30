/// Slider Component
///
/// 滑块/范围选择器
///
/// 特性:
/// - min/max/step 范围
/// - 拖拽 + 点击轨道
/// - 键盘 (ArrowLeft/Right ±step, Home/End)
/// - 可选值显示
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Scope = @import("../../reactive.zig").Scope;
const hooks = @import("../../hooks.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const KeyCode = events.KeyCode;
const Modifiers = events.Modifiers;
pub const HapticFeedbackPattern = @import("system_sdk").HapticFeedbackPattern;

/// Slider 属性
// 样式层已析出到 styles.zig
const styles = @import("styles.zig");
const trackStyle = styles.trackStyle;
const fillStyle = styles.fillStyle;
const thumbStyle = styles.thumbStyle;

pub const SliderProps = struct {
    min: f32 = 0,
    max: f32 = 100,
    /// Positive values snap to discrete steps. Zero disables snapping.
    step: f32 = 1,
    /// Opt in to native feedback when pointer input changes a snapped value.
    /// Applications may bind this to their user's preference.
    haptic_feedback: bool = false,
    /// Native semantic pattern, not a weak/medium/strong intensity scale.
    haptic_pattern: HapticFeedbackPattern = .alignment,
    /// 初始值。**只在 mount 时读取一次** —— 之后组件持有自己的
    /// SliderState。需要外部驱动请用 mount 返回的 `result.state.setValue()`
    /// （那条路径会同步视觉与 a11y 数值）。
    initial_value: f32 = 0,
    disabled: bool = false,
    width: f32 = 200,
    track_height: f32 = 4,
    thumb_size: f32 = 16,
    show_value: bool = false,
    on_change: ?core.HandlerRef = null,
    /// 给 track 节点设置的 test_id（供 E2E 测试定位）
    test_id: ?[]const u8 = null,
};

/// Slider 内部状态
pub const SliderState = struct {
    value: f32,
    min: f32,
    max: f32,
    step: f32,
    haptic_feedback: bool = false,
    haptic_pattern: HapticFeedbackPattern = .alignment,
    thumb_size: f32 = 16,
    dragging: bool = false,
    track_node: *Node,
    fill_node: *Node,
    thumb_node: *Node,
    track_area_node: *Node,
    value_text_node: ?*Node = null,
    container_node: *Node,
    on_change: ?core.HandlerRef,
    cx: *Cx,

    fn ratio(self: *const SliderState) f32 {
        if (self.max <= self.min) return 0;
        return std.math.clamp((self.value - self.min) / (self.max - self.min), 0, 1);
    }

    pub fn setValue(self: *SliderState, raw: f32) void {
        self.applyValue(raw, false);
    }

    fn applyValue(self: *SliderState, raw: f32, pointer_driven: bool) void {
        // snap to step
        const clamped = std.math.clamp(raw, self.min, self.max);
        const stepped = if (self.step > 0)
            self.min + @round((clamped - self.min) / self.step) * self.step
        else
            clamped;
        const previous = self.value;
        self.value = std.math.clamp(stepped, self.min, self.max);
        self.updateVisuals();
        // One request per changed snapped value, never per pointer sample or
        // skipped intermediate step. Programmatic/key/a11y changes stay silent.
        // AppKit chooses the performer according to device and user settings.
        if (self.haptic_feedback and pointer_driven and self.step > 0 and std.math.isFinite(self.step) and
            std.math.isFinite(previous) and std.math.isFinite(self.value) and self.value != previous)
        {
            if (self.cx.system_sdk) |sdk| sdk.performHapticFeedback(self.haptic_pattern) catch {};
        }
        // User callbacks may destroy this component; do not access state after.
        if (self.on_change) |handler| handler.invoke();
    }

    fn updateVisuals(self: *SliderState) void {
        // a11y 数值必须跟着拖动走，否则 VoiceOver 永远播报 mount 时的初值。
        if (self.container_node.behavior.interaction.a11y) |*a| {
            a.value_now = self.value;
            a.value_min = self.min;
            a.value_max = self.max;
            if (a.value_range) |*range| {
                range.now = self.value;
                range.min = self.min;
                range.max = self.max;
            }
        }

        const r = self.ratio();
        // 全局 hook 读 rect。
        const tr = self.track_node.rectFromWorldOrFallback();
        const track_w = tr.w;
        const thumb_offset = r * track_w - self.thumb_size / 2;

        self.fill_node.style.width = .{ .percent = r * 100 };
        self.fill_node.markSizingDirty();

        // thumb 用 translate_x 定位：纯 composite 位移，拖动零 relayout。
        // （旧 margin.left 方案是"translate double-apply"时代的防御——该 bug 已证伪清除。）
        self.thumb_node.setTranslateX(thumb_offset);

        // 更新文本
        if (self.value_text_node) |vt| {
            if (vt.getText()) |old| {
                var txt = old;
                var buf: [64]u8 = undefined;
                const content = std.fmt.bufPrint(&buf, "{d:.1}", .{self.value}) catch unreachable; // f32 {d:.1} 最长 < 64
                // void 更新路径无法上抛：OOM 时保留旧文本（不写截断/错误内容）并记录。
                txt.setContent(self.cx.allocator, content) catch |err| {
                    std.log.err("[Slider] value text update failed: {s}", .{@errorName(err)});
                    return;
                };
                vt.setText(txt);
            }
            vt.markRenderDirty();
        }
    }

    fn setFromScreenX(self: *SliderState, screen_x: f32) void {
        const track_global = self.track_node.globalRect();
        const track_x = track_global.x;
        const track_w = track_global.w;
        if (track_w <= 0) return;
        const r = std.math.clamp((screen_x - track_x) / track_w, 0, 1);
        const raw = self.min + r * (self.max - self.min);
        self.applyValue(raw, true);
    }
};

fn setA11ySliderValue(context: *anyopaque, value: f32) bool {
    const state: *SliderState = @ptrCast(@alignCast(context));
    state.setValue(value);
    return true;
}

/// 创建 Slider
pub fn Slider(props: SliderProps) SliderBuilder {
    return SliderBuilder{ .props = props };
}

/// SliderBuilder.mount 的返回结果
pub const SliderResult = struct { wrapper: *Node, state: *SliderState };

pub const SliderBuilder = struct {
    props: SliderProps,

    pub fn min(self: SliderBuilder, v: f32) SliderBuilder {
        var new = self;
        new.props.min = v;
        return new;
    }

    pub fn max(self: SliderBuilder, v: f32) SliderBuilder {
        var new = self;
        new.props.max = v;
        return new;
    }

    pub fn step(self: SliderBuilder, v: f32) SliderBuilder {
        var new = self;
        new.props.step = v;
        return new;
    }

    pub fn hapticFeedback(self: SliderBuilder, enabled: bool) SliderBuilder {
        var new = self;
        new.props.haptic_feedback = enabled;
        return new;
    }

    pub fn hapticPattern(self: SliderBuilder, pattern: HapticFeedbackPattern) SliderBuilder {
        var new = self;
        new.props.haptic_pattern = pattern;
        return new;
    }

    pub fn value(self: SliderBuilder, v: f32) SliderBuilder {
        var new = self;
        new.props.initial_value = v;
        return new;
    }

    pub fn disabled(self: SliderBuilder, d: bool) SliderBuilder {
        var new = self;
        new.props.disabled = d;
        return new;
    }

    pub fn width(self: SliderBuilder, w: f32) SliderBuilder {
        var new = self;
        new.props.width = w;
        return new;
    }

    pub fn onChange(self: SliderBuilder, handler_ref: core.HandlerRef) SliderBuilder {
        var new = self;
        new.props.on_change = handler_ref;
        return new;
    }

    /// 保留模式: mount
    pub fn mount(self: SliderBuilder, scope: *Scope, cx: *Cx) !SliderResult {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        // min > max 时规范化区间：std.math.clamp 在 min > max 时 assert 失败
        const p = blk: {
            var np = self.props;
            if (np.min > np.max) std.mem.swap(f32, &np.min, &np.max);
            break :blk np;
        };

        const accent = if (p.disabled) t.color.fg_disabled else t.color.accent;

        // 外层容器
        const container = try box(cx, .{
            .width = .{ .px = p.width },
            .height = .{ .fit = .{} },
            .direction = .row,
            .align_items = .center,
            .gap = 8,
        }, .{});
        // sweep：container 守到 return；子节点建好即 adopt
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "Slider";
        // value_now/min/max 现在会真正投影进 a11y tree（此前投影层硬编码 0），
        // VoiceOver 才能读出"42，范围 0 到 100"而不是一个无位置的 slider。
        container.behavior.interaction.a11y = .{
            .role = .slider,
            .disabled = p.disabled,
            .value_now = p.initial_value,
            .value_min = p.min,
            .value_max = p.max,
        };
        try core.bindScopeToNode(my_scope, container);
        container.setFocusable(!p.disabled);
        if (p.disabled) container.style.cursor = .not_allowed;

        // 轨道容器 (相对定位，含 track + thumb)
        const track_area = try core.adoptChild(cx, allocator, container, try box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = p.thumb_size },
            .direction = .column,
            .justify = .center,
            .position = .relative,
        }, .{}));

        // 轨道
        const track = try core.adoptChild(cx, allocator, track_area, try box(cx, trackStyle(p, t), .{}));
        track.style.overflow_hidden = true;
        if (p.test_id) |tid| track.meta.ownership.meta.test_id = tid;

        // 填充条
        const initial_ratio = blk: {
            if (p.max <= p.min) break :blk @as(f32, 0);
            break :blk std.math.clamp((p.initial_value - p.min) / (p.max - p.min), 0, 1);
        };

        const fill = try core.adoptChild(cx, allocator, track, try box(cx, fillStyle(p, accent, initial_ratio), .{}));

        // Thumb
        const thumb = try core.adoptChild(cx, allocator, track_area, try box(cx, thumbStyle(p, accent, t), .{}));
        thumb.style.translate_y = 0;
        thumb.style.cursor = if (p.disabled) .not_allowed else .pointer;

        // State
        const state = try allocator.create(SliderState);
        state.* = .{
            .value = std.math.clamp(p.initial_value, p.min, p.max),
            .min = p.min,
            .max = p.max,
            .step = p.step,
            .haptic_feedback = p.haptic_feedback,
            .haptic_pattern = p.haptic_pattern,
            .thumb_size = p.thumb_size,
            .track_node = track,
            .fill_node = fill,
            .thumb_node = thumb,
            .track_area_node = track_area,
            .container_node = container,
            .on_change = p.on_change,
            .cx = cx,
        };
        if (container.behavior.interaction.a11y) |*a11y| {
            a11y.value_range = .{
                .now = state.value,
                .min = state.min,
                .max = state.max,
                .context = state,
                .set_value = setA11ySliderValue,
            };
            a11y.orientation = .horizontal;
        }
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn cleanup(ptr: *anyopaque, alloc: Allocator) void {
                const s: *SliderState = @ptrCast(@alignCast(ptr));
                alloc.destroy(s);
            }
        }.cleanup);

        // 可选值显示
        if (p.show_value) {
            var buf: [16]u8 = undefined;
            const txt_content = std.fmt.bufPrint(&buf, "{d:.1}", .{state.value}) catch "0";
            const text_node = try core.adoptChild(cx, allocator, container, try box(cx, .{
                .width = .{ .fit = .{ .min = 30 } },
                .height = .{ .fit = .{} },
            }, .{}));
            text_node.setText(.{
                .color = t.color.fg_secondary,
                .font_size = t.font_size.sm,
            });
            if (text_node.getText()) |old| {
                var txt = old;
                try txt.setContent(cx.allocator, txt_content);
                text_node.setText(txt);
            }
            state.value_text_node = text_node;
        }

        // event_context 始终设置（on_before_render 依赖它来定位 thumb）
        track_area.behavior.events.event_context = @ptrCast(state);

        // 交互 (拖拽 + 点击轨道 + 键盘) — 仅非 disabled 时启用
        if (!p.disabled) {
            track_area.behavior.events.on_event = sliderEventHandler;
            track_area.on_capture_lost = sliderCaptureLost;

            // Thumb hover 高亮效果：border_color 在 normal 和 hover 之间过渡
            _ = try hooks.useHoverHighlight(my_scope, track_area, thumb, .border_color, accent, t.color.accent_hover, .{});

            container.behavior.events.on_key_down = sliderKeyHandler;
            container.behavior.events.key_context = @ptrCast(state);
        }

        // on_before_render: 首帧布局完成后修正 thumb 位置
        track_area.meta.per_frame.hooks.before_render.main = sliderBeforeRender;

        return .{ .wrapper = container, .state = state };
    }
};

// ========== 内部辅助 ==========

fn sliderBeforeRender(node: *Node) void {
    if (node.behavior.events.event_context) |ctx| {
        const state: *SliderState = @ptrCast(@alignCast(ctx));
        // 布局完成后更新 thumb 位置（首帧 track_w 从 0 变为实际值）
        // 全局 hook 读 rect。
        const tr = state.track_node.rectFromWorldOrFallback();
        const track_w = tr.w;
        if (track_w > 0) {
            const r = state.ratio();
            const offset = r * track_w - state.thumb_size / 2;
            state.thumb_node.setTranslateX(offset);
        }
    }
}

fn sliderCaptureLost(node: *Node) void {
    const context = node.behavior.events.event_context orelse return;
    const state: *SliderState = @ptrCast(@alignCast(context));
    state.dragging = false;
}

fn sliderOwnsCapture(state: *const SliderState) bool {
    return state.cx.node_registry.resolve(state.cx.dispatcher.pointer_capture_handle, null) == state.track_area_node;
}

fn sliderEventHandler(event: Event, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    const state: *SliderState = @ptrCast(@alignCast(context.?));

    switch (event) {
        .mouse_down => |e| {
            const cx = state.cx;
            const identity = cx.node_registry.handleFor(state.track_area_node);
            state.dragging = true;
            // Replacing capture invokes the previous owner's callback, which
            // may destroy this slider or transfer capture elsewhere.
            cx.setPointerCapture(state.track_area_node);
            const live = cx.node_registry.resolve(identity, null) orelse return .stop;
            if (live.behavior.events.event_context != context or live.behavior.events.on_event != sliderEventHandler) return .stop;
            if (!sliderOwnsCapture(state)) {
                state.dragging = false;
                return .stop;
            }
            state.setFromScreenX(e.x);
            return .stop;
        },
        .mouse_move => |e| {
            if (state.dragging and !sliderOwnsCapture(state)) state.dragging = false;
            if (state.dragging) {
                state.setFromScreenX(e.x);
                return .stop;
            }
        },
        .mouse_up => {
            if (state.dragging) {
                state.dragging = false;
                if (sliderOwnsCapture(state)) state.cx.releasePointerCapture();
                return .stop;
            }
            return .ignored;
        },
        else => {},
    }
    return .ignored;
}

fn sliderKeyHandler(key: KeyCode, _: Modifiers, context: ?*anyopaque) EventResult {
    if (context == null) return .ignored;
    const state: *SliderState = @ptrCast(@alignCast(context.?));

    switch (key) {
        .right => {
            state.setValue(state.value + state.step);
            return .stop;
        },
        .left => {
            state.setValue(state.value - state.step);
            return .stop;
        },
        .home => {
            state.setValue(state.min);
            return .stop;
        },
        .end => {
            state.setValue(state.max);
            return .stop;
        },
        else => return .ignored,
    }
}

// ========== 测试 ==========

test "Slider: basic structure" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Slider(.{
        .min = 0,
        .max = 100,
        .initial_value = 50,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expectEqual(@as(f32, 50), result.state.value);
}

test "Slider: min > max 时 mount 不 assert，区间被规范化" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Slider(.{ .min = 100, .max = 0, .initial_value = 150 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);
    try std.testing.expectEqual(@as(f32, 0), result.state.min);
    try std.testing.expectEqual(@as(f32, 100), result.state.max);
    try std.testing.expectEqual(@as(f32, 100), result.state.value);
    result.state.setValue(-5);
    try std.testing.expectEqual(@as(f32, 0), result.state.value);
}

test "Slider: setValue clamps" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Slider(.{
        .min = 0,
        .max = 100,
        .step = 10,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    result.state.setValue(150);
    try std.testing.expectEqual(@as(f32, 100), result.state.value);

    result.state.setValue(-10);
    try std.testing.expectEqual(@as(f32, 0), result.state.value);
}

test "Slider: step snapping" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Slider(.{
        .min = 0,
        .max = 100,
        .step = 10,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    result.state.setValue(37);
    try std.testing.expectEqual(@as(f32, 40), result.state.value);
}

test "Slider: keyboard" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Slider(.{
        .min = 0,
        .max = 100,
        .step = 5,
        .initial_value = 50,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    _ = sliderKeyHandler(.right, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(f32, 55), result.state.value);

    _ = sliderKeyHandler(.left, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(f32, 50), result.state.value);

    _ = sliderKeyHandler(.home, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(f32, 0), result.state.value);

    _ = sliderKeyHandler(.end, .{}, @ptrCast(result.state));
    try std.testing.expectEqual(@as(f32, 100), result.state.value);
}

test "Slider: show value" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Slider(.{
        .initial_value = 75,
        .show_value = true,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.wrapper);

    // container 应该有 2 个子节点: track_area + value_text
    try std.testing.expectEqual(@as(usize, 2), result.wrapper.children.items.len);
    try std.testing.expect(result.state.value_text_node != null);
}

test "Slider: render emits fill highlight" {
    var ctx = try Cx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setViewport(260, 48);

    const root = try box(ctx, .{
        .width = .{ .px = 260 },
        .height = .{ .px = 48 },
        .background = ctx.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Slider(.{
        .initial_value = 70,
        .width = 220,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.wrapper);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_fill = false;
    for (commands) |cmd| if (cmd.isFillRect()) {
        const r = cmd;
        if (Color.eql(r.color.toColor(), ctx.tokens.color.accent) and r.geom.w > 100 and r.geom.h >= 4) {
            saw_fill = true;
        }
    };

    try std.testing.expect(saw_fill);
}

// styles.zig 的测试收集 —— 这行是必需的，见 docs/STYLING.md
test {
    _ = @import("styles.zig");
}

// 逐分配点 OOM sweep — 见 src/ui/components/oom_sweep.zig
test "slider: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("slider", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Slider(.{ .min = 0, .max = 100, .initial_value = 50 }).mount(scope, cx)).wrapper;
        }
    }.m);
}

test "Slider: pointer step feedback is discrete and programmatic updates are silent" {
    const sdk_mod = @import("system_sdk");
    const Mock = struct {
        count: usize = 0,
        fail: bool = false,
        last_pattern: ?sdk_mod.HapticFeedbackPattern = null,
        fn deinit(_: *anyopaque, _: Allocator) void {}
        fn pump(_: *anyopaque, _: *sdk_mod.EventQueue, _: u32) sdk_mod.SdkError!sdk_mod.PumpResult {
            return .{};
        }
        fn perform(ptr: *anyopaque, pattern: sdk_mod.HapticFeedbackPattern) sdk_mod.SdkError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_pattern = pattern;
            self.count += 1;
            if (self.fail) return error.BackendFailure;
        }
    };
    var backend = Mock{};
    const vt = sdk_mod.BackendVTable{
        .name = "slider-haptic-mock",
        .deinit = Mock.deinit,
        .pump_events = Mock.pump,
        .perform_haptic_feedback = Mock.perform,
    };
    var sdk = sdk_mod.SystemSdk.init(std.testing.allocator, &backend, &vt, .{ .haptic_feedback = true });
    defer sdk.deinit();
    const cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    cx.system_sdk = &sdk;
    cx.setViewport(400, 100);
    const scope = try Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    const slider = try Slider(.{ .min = 0, .max = 10, .step = 1, .initial_value = 5 }).mount(scope, cx);
    cx.root = slider.wrapper;
    cx.layout();
    const rect = slider.state.track_node.globalRect();
    const context: ?*anyopaque = @ptrCast(slider.state);
    // Default-off must hold even on a capable device and a changed step.
    slider.state.setFromScreenX(rect.x + rect.w * 0.7);
    try std.testing.expectEqual(@as(f32, 7), slider.state.value);
    try std.testing.expectEqual(@as(usize, 0), backend.count);
    slider.state.setValue(5);
    // The application can change its user's preference without remounting.
    slider.state.haptic_feedback = true;
    _ = sliderEventHandler(.{ .mouse_down = .{ .x = rect.x + rect.w * 0.5, .y = rect.y } }, context);
    try std.testing.expectEqual(@as(usize, 0), backend.count);
    _ = sliderEventHandler(.{ .mouse_move = .{ .x = rect.x + rect.w * 0.61, .y = rect.y } }, context);
    try std.testing.expectEqual(@as(f32, 6), slider.state.value);
    try std.testing.expectEqual(@as(usize, 1), backend.count);
    try std.testing.expectEqual(sdk_mod.HapticFeedbackPattern.alignment, backend.last_pattern.?);
    _ = sliderEventHandler(.{ .mouse_move = .{ .x = rect.x + rect.w * 0.64, .y = rect.y } }, context);
    try std.testing.expectEqual(@as(usize, 1), backend.count);
    // Crossing several steps in one sample requests just one pulse; clamping
    // beyond an already reached endpoint does not repeat it.
    slider.state.setFromScreenX(rect.x + rect.w * 2);
    slider.state.setFromScreenX(rect.x + rect.w * 3);
    try std.testing.expectEqual(@as(usize, 2), backend.count);
    _ = sliderEventHandler(.{ .mouse_up = .{ .x = rect.x + rect.w, .y = rect.y } }, context);
    _ = sliderEventHandler(.{ .mouse_move = .{ .x = rect.x, .y = rect.y } }, context);
    slider.state.setValue(4);
    _ = sliderKeyHandler(.right, .{}, context);
    _ = setA11ySliderValue(slider.state, 3);
    try std.testing.expectEqual(@as(usize, 2), backend.count);
    slider.state.step = 0;
    slider.state.setFromScreenX(rect.x + rect.w * 0.52);
    try std.testing.expectEqual(@as(usize, 2), backend.count);
    slider.state.step = 1;
    backend.fail = true;
    slider.state.setFromScreenX(rect.x + rect.w * 0.7);
    try std.testing.expectEqual(@as(f32, 7), slider.state.value);
    try std.testing.expectEqual(@as(usize, 3), backend.count);
    sdk.capabilities.haptic_feedback = false;
    slider.state.setFromScreenX(rect.x + rect.w * 0.8);
    try std.testing.expectEqual(@as(f32, 8), slider.state.value);
    try std.testing.expectEqual(@as(usize, 3), backend.count);
    slider.state.haptic_feedback = false;
    sdk.capabilities.haptic_feedback = true;
    slider.state.setFromScreenX(rect.x + rect.w * 0.9);
    try std.testing.expectEqual(@as(usize, 3), backend.count);
    // Selecting a pattern alone never enables feedback or emits a request.
    slider.state.haptic_pattern = .generic;
    slider.state.setFromScreenX(rect.x + rect.w * 0.2);
    try std.testing.expectEqual(@as(usize, 3), backend.count);
    backend.fail = false;
    slider.state.haptic_feedback = true;
    slider.state.setFromScreenX(rect.x + rect.w * 0.3);
    try std.testing.expectEqual(sdk_mod.HapticFeedbackPattern.generic, backend.last_pattern.?);
    slider.state.haptic_pattern = .level_change;
    slider.state.setFromScreenX(rect.x + rect.w * 0.4);
    try std.testing.expectEqual(sdk_mod.HapticFeedbackPattern.level_change, backend.last_pattern.?);
    try std.testing.expectEqual(@as(usize, 5), backend.count);
}

test "Slider: mouse down tolerates destruction from change or previous capture owner" {
    for ([_]bool{ false, true }) |destroy_on_capture_loss| {
        const cx = try Cx.init(std.testing.allocator);
        defer cx.deinit();
        cx.setViewport(400, 100);
        const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
        cx.root = root;
        const scope = try Scope.init(cx.allocator, null, cx.owner);
        defer scope.dispose();
        const slider = try Slider(.{ .initial_value = 0 }).mount(scope, cx);
        try root.appendChild(cx.allocator, slider.wrapper);
        const old_owner = try box(cx, .{}, .{});
        try root.appendChild(cx.allocator, old_owner);
        const State = struct {
            cx: *Cx,
            wrapper: *Node,
            changes: usize = 0,
            removals: usize = 0,
            fn remove(self: *@This()) void {
                self.removals += 1;
                self.cx.detachChild(self.wrapper.parent.?, self.wrapper);
                self.cx.freeNode(self.wrapper);
            }
            fn change(self: *@This()) void {
                self.changes += 1;
                self.remove();
            }
            fn lost(node: *Node) void {
                const self: *@This() = @ptrCast(@alignCast(node.behavior.events.event_context.?));
                self.remove();
            }
        };
        var state = State{ .cx = cx, .wrapper = slider.wrapper };
        slider.state.on_change = Cx.handlerFrom(State, &state, State.change);
        old_owner.behavior.events.event_context = &state;
        if (destroy_on_capture_loss) old_owner.on_capture_lost = State.lost;
        cx.layout();
        const target = slider.state.track_area_node;
        const identity = cx.node_registry.handleFor(target);
        const rect = slider.state.track_node.globalRect();
        if (destroy_on_capture_loss) cx.setPointerCapture(old_owner);
        _ = cx.dispatcher.dispatch(.{ .mouse_down = .{ .x = rect.x + rect.w * 0.7, .y = rect.y } }, target);
        try std.testing.expectEqual(@as(usize, 1), state.removals);
        try std.testing.expectEqual(@as(usize, if (destroy_on_capture_loss) 0 else 1), state.changes);
        try std.testing.expect(cx.node_registry.resolve(identity, null) == null);
        try std.testing.expect(cx.dispatcher.pointer_capture_handle == null);
    }
}

test "Slider: losing or failing to acquire capture ends pointer updates" {
    for ([_]bool{ false, true }) |redirect_during_acquire| {
        const cx = try Cx.init(std.testing.allocator);
        defer cx.deinit();
        cx.setViewport(400, 100);
        const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 100 } }, .{});
        cx.root = root;
        const scope = try Scope.init(cx.allocator, null, cx.owner);
        defer scope.dispose();
        const slider = try Slider(.{ .initial_value = 0 }).mount(scope, cx);
        try root.appendChild(cx.allocator, slider.wrapper);
        const old_owner = try box(cx, .{}, .{});
        const replacement = try box(cx, .{}, .{});
        try root.appendChild(cx.allocator, old_owner);
        try root.appendChild(cx.allocator, replacement);
        const State = struct {
            cx: *Cx,
            replacement: *Node,
            changes: usize = 0,
            fn change(self: *@This()) void {
                self.changes += 1;
            }
            fn lost(node: *Node) void {
                const self: *@This() = @ptrCast(@alignCast(node.behavior.events.event_context.?));
                self.cx.setPointerCapture(self.replacement);
            }
        };
        var state = State{ .cx = cx, .replacement = replacement };
        slider.state.on_change = Cx.handlerFrom(State, &state, State.change);
        old_owner.behavior.events.event_context = &state;
        old_owner.on_capture_lost = State.lost;
        cx.layout();
        const rect = slider.state.track_node.globalRect();
        if (redirect_during_acquire) cx.setPointerCapture(old_owner);
        _ = cx.dispatcher.dispatch(.{ .mouse_down = .{ .x = rect.x + rect.w * 0.5, .y = rect.y } }, slider.state.track_area_node);
        if (!redirect_during_acquire) cx.setPointerCapture(replacement);
        try std.testing.expect(!slider.state.dragging);
        const value = slider.state.value;
        const changes = state.changes;
        _ = cx.dispatcher.dispatch(.{ .mouse_move = .{ .x = rect.x + rect.w * 0.9, .y = rect.y, .dx = 0, .dy = 0 } }, slider.state.track_area_node);
        _ = cx.dispatcher.dispatch(.{ .mouse_up = .{ .x = rect.x + rect.w * 0.9, .y = rect.y } }, slider.state.track_area_node);
        try std.testing.expectEqual(value, slider.state.value);
        try std.testing.expectEqual(changes, state.changes);
        try std.testing.expectEqual(@as(usize, if (redirect_during_acquire) 0 else 1), changes);
        try std.testing.expect(cx.node_registry.resolve(cx.dispatcher.pointer_capture_handle, null) == replacement);
    }
}
