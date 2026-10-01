/// stories.zig，每个组件一个 buildXxx(scope, cx) !*Node 的 story。
///
/// 无状态组件：摆出代表性 variant/size。
/// 有状态组件：用 Signal + on_change / cx.on 接线，使其在 storybook 内真可交互。
/// story 内关键交互元素设细粒度 test_id（story.<key>.<part>）供 e2e 定位。
const std = @import("std");
const ui = @import("ui");
const select_puqef = @import("select_puqef.zig");

const Padding = ui.Padding;
const light = ui.theme.light;

// ── 小工具 ──

fn label(cx: *ui.Cx, txt: []const u8) !*ui.Node {
    return ui.text(cx, txt, .{ .font_size = 13, .color = light.color.fg_secondary });
}

fn row(cx: *ui.Cx, gap: f32) !*ui.Node {
    return ui.box(cx, .{ .direction = .row, .gap = gap, .align_items = .center }, .{});
}

fn col(cx: *ui.Cx, gap: f32) !*ui.Node {
    return ui.box(cx, .{ .direction = .column, .gap = gap }, .{});
}

// ── Button ──

pub fn buildButton(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const icons = ui.assets.common;
    const c = try col(cx, 16);

    const variant_specs = [_]struct { v: W.ButtonVariant, t: []const u8 }{
        .{ .v = .primary, .t = "Primary" },
        .{ .v = .secondary, .t = "Secondary" },
        .{ .v = .ghost, .t = "Ghost" },
        .{ .v = .danger, .t = "Danger" },
        .{ .v = .link, .t = "Link" },
    };
    const size_specs = [_]struct { s: W.ButtonSize, t: []const u8 }{
        .{ .s = .xs, .t = "XS" },
        .{ .s = .sm, .t = "SM" },
        .{ .s = .md, .t = "MD" },
        .{ .s = .lg, .t = "LG" },
    };

    // ── variant × size 全矩阵 ──
    try c.appendChild(a, try label(cx, "Variants × Sizes"));
    const matrix = try col(cx, 8);
    inline for (variant_specs) |vs| {
        const r = try row(cx, 10);
        inline for (size_specs) |ss| {
            try r.appendChild(a, try W.Button(.{
                .label = vs.t,
                .variant = vs.v,
                .size = ss.s,
            }).mount(scope, cx));
        }
        try matrix.appendChild(a, r);
    }
    try c.appendChild(a, matrix);

    // ── 带前置图标（leading icon）每个 variant ──
    try c.appendChild(a, try label(cx, "With leading icon"));
    const icon_row = try row(cx, 10);
    inline for (variant_specs) |vs| {
        try icon_row.appendChild(a, try W.Button(.{
            .label = vs.t,
            .variant = vs.v,
            .icon_asset = icons.plus,
        }).mount(scope, cx));
    }
    try c.appendChild(a, icon_row);

    // ── leading icon × sizes（图标随尺寸缩放）──
    try c.appendChild(a, try label(cx, "Leading icon × sizes"));
    const icon_size_row = try row(cx, 10);
    inline for (size_specs) |ss| {
        try icon_size_row.appendChild(a, try W.Button(.{
            .label = "Download",
            .variant = .secondary,
            .size = ss.s,
            .icon_asset = icons.folder,
            .icon_size = cx.tokens.control.get(ss.s).icon_size,
        }).mount(scope, cx));
    }
    try c.appendChild(a, icon_size_row);

    // ── icon-only（仅图标）每个 variant ──
    try c.appendChild(a, try label(cx, "Icon only"));
    const icon_only_row = try row(cx, 10);
    inline for (variant_specs) |vs| {
        try icon_only_row.appendChild(a, try W.Button(.{
            .variant = vs.v,
            .icon_only = true,
            .icon_asset = icons.star,
        }).mount(scope, cx));
    }
    try c.appendChild(a, icon_only_row);

    // ── icon-only × sizes ──
    try c.appendChild(a, try label(cx, "Icon only × sizes"));
    const icon_only_sizes = try row(cx, 10);
    inline for (size_specs) |ss| {
        try icon_only_sizes.appendChild(a, try W.Button(.{
            .variant = .secondary,
            .icon_only = true,
            .icon_asset = icons.search,
            .size = ss.s,
            .icon_size = cx.tokens.control.get(ss.s).icon_size,
        }).mount(scope, cx));
    }
    try c.appendChild(a, icon_only_sizes);

    // ── loading（加载中）每个 variant ──
    try c.appendChild(a, try label(cx, "Loading"));
    const loading_row = try row(cx, 10);
    inline for (variant_specs) |vs| {
        try loading_row.appendChild(a, try W.Button(.{
            .label = "Saving…",
            .variant = vs.v,
            .loading = true,
        }).mount(scope, cx));
    }
    try c.appendChild(a, loading_row);

    // ── loading × sizes（spinner 随尺寸缩放）──
    try c.appendChild(a, try label(cx, "Loading × sizes"));
    const loading_sizes = try row(cx, 10);
    inline for (size_specs) |ss| {
        try loading_sizes.appendChild(a, try W.Button(.{
            .label = "Loading",
            .variant = .primary,
            .size = ss.s,
            .loading = true,
        }).mount(scope, cx));
    }
    try c.appendChild(a, loading_sizes);

    // ── 状态：normal / disabled / disabled+icon / loading+icon-only ──
    try c.appendChild(a, try label(cx, "States"));
    const states = try row(cx, 10);
    try states.appendChild(a, try W.Button(.{ .label = "Normal" }).mount(scope, cx));
    try states.appendChild(a, try W.Button(.{ .label = "Disabled", .disabled = true }).mount(scope, cx));
    try states.appendChild(a, try W.Button(.{ .label = "Disabled", .disabled = true, .icon_asset = icons.plus }).mount(scope, cx));
    try states.appendChild(a, try W.Button(.{ .label = "Loading", .loading = true }).mount(scope, cx));
    try states.appendChild(a, try W.Button(.{ .icon_only = true, .icon_asset = icons.x_close, .loading = true, .variant = .secondary }).mount(scope, cx));
    try c.appendChild(a, states);

    // ── block（块级，宽度填充）──
    try c.appendChild(a, try label(cx, "Block (full width)"));
    const block_col = try col(cx, 8);
    block_col.style.width = .{ .px = 280 };
    try block_col.appendChild(a, try W.Button(.{ .label = "Block primary", .block = true }).mount(scope, cx));
    try block_col.appendChild(a, try W.Button(.{ .label = "Block + icon", .block = true, .variant = .secondary, .icon_asset = icons.check }).mount(scope, cx));
    try c.appendChild(a, block_col);

    return c;
}

// ── Checkbox ──

const CheckboxStory = struct {
    status: *ui.Node,
    buf: [48]u8 = undefined,

    fn onChange(self: *CheckboxStory, checked: bool) void {
        const txt = std.fmt.bufPrint(&self.buf, "changed → {s}", .{if (checked) "checked" else "unchecked"}) catch return;
        if (self.status.getText()) |old| {
            var t = old;
            t.content = txt;
            // 关键：txt 指向 self.buf（非堆 owned）。必须清 owned/inline_len，
            // 否则 Node.destroy 会 free(non-heap) -> "Invalid free" 崩溃。
            // （setText 信任 caller 的 owned 标志，不做所有权回收，见 content_table.setText。）
            t.owned = false;
            t.inline_len = 0;
            self.status.setText(t);
        }
        self.status.markRenderDirty();
    }
};

pub fn buildCheckbox(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);

    const status = try ui.text(cx, "changed → (none)", .{ .font_size = 13, .color = light.color.fg_secondary });
    status.meta.ownership.meta.test_id = "story.checkbox.status";

    const story = try cx.bindState(CheckboxStory, .{ .status = status });

    const unchecked = try ui.widgets.Checkbox(.{
        .label_text = "Unchecked",
        .initial_checked = false,
        .on_change = ui.Cx.boolHandlerFrom(CheckboxStory, story, CheckboxStory.onChange),
    }).mount(scope, cx);
    unchecked.meta.ownership.meta.test_id = "story.checkbox.box";
    try c.appendChild(a, unchecked);

    try c.appendChild(a, try ui.widgets.Checkbox(.{ .label_text = "Checked", .initial_checked = true }).mount(scope, cx));
    try c.appendChild(a, try ui.widgets.Checkbox(.{ .label_text = "Indeterminate", .indeterminate = true }).mount(scope, cx));
    try c.appendChild(a, try ui.widgets.Checkbox(.{ .label_text = "Disabled", .disabled = true }).mount(scope, cx));
    try c.appendChild(a, status);

    return c;
}

// ── Slider ──

const SliderFeedbackStory = struct {
    basic: ui.widgets.SliderResult,
    stepped: ui.widgets.SliderResult,
    continuous: ui.widgets.SliderResult,
    status: *ui.Node,
    pattern_status: *ui.Node,
    buffer: [96]u8 = undefined,

    fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
        allocator.destroy(@as(*SliderFeedbackStory, @ptrCast(@alignCast(raw))));
    }

    fn toggle(self: *SliderFeedbackStory, enabled: bool) void {
        self.basic.state.haptic_feedback = enabled;
        self.stepped.state.haptic_feedback = enabled;
        self.continuous.state.haptic_feedback = enabled;
        self.refresh();
    }

    fn reset(self: *SliderFeedbackStory) void {
        self.stepped.state.setValue(5);
        self.continuous.state.setValue(5);
    }

    fn selectPattern(self: *SliderFeedbackStory, value: []const u8) void {
        const pattern = std.meta.stringToEnum(ui.widgets.slider.HapticFeedbackPattern, value) orelse return;
        self.basic.state.haptic_pattern = pattern;
        self.stepped.state.haptic_pattern = pattern;
        self.continuous.state.haptic_pattern = pattern;
        self.refresh();
    }

    fn refresh(self: *SliderFeedbackStory) void {
        // Reflect both stepped controls: a missing toggle connection must not
        // advertise "on" while the original 0..100 slider remains disabled.
        const feedback: []const u8 = if (self.basic.state.haptic_feedback != self.stepped.state.haptic_feedback or
            self.continuous.state.haptic_feedback != self.stepped.state.haptic_feedback)
            "mixed"
        else if (self.stepped.state.haptic_feedback)
            "on"
        else
            "off";
        const value = std.fmt.bufPrint(&self.buffer, "Feedback: {s} | stepped: {d:.1} | continuous: {d:.1}", .{
            feedback,
            self.stepped.state.value,
            self.continuous.state.value,
        }) catch unreachable;
        var text = self.status.getText().?;
        text.content = value;
        text.owned = false;
        text.inline_len = 0;
        self.status.setText(text);
        var pattern_text = self.pattern_status.getText().?;
        pattern_text.content = if (self.basic.state.haptic_pattern != self.stepped.state.haptic_pattern or
            self.continuous.state.haptic_pattern != self.stepped.state.haptic_pattern)
            "Pattern: mixed"
        else switch (self.stepped.state.haptic_pattern) {
            .alignment => "Pattern: Alignment",
            .generic => "Pattern: Generic",
            .level_change => "Pattern: Level change",
        };
        pattern_text.owned = false;
        pattern_text.inline_len = 0;
        self.pattern_status.setText(pattern_text);
    }
};

pub fn buildSlider(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);

    const s1 = try ui.widgets.Slider(.{
        .min = 0,
        .max = 100,
        .initial_value = 40,
        .width = 320,
        .show_value = true,
        .test_id = "story.slider.track",
    }).mount(scope, cx);
    s1.wrapper.meta.ownership.meta.test_id = "story.slider.basic";

    const s2 = try ui.widgets.Slider(.{
        .min = 0,
        .max = 10,
        .step = 1,
        .initial_value = 5,
        .width = 320,
        .show_value = true,
        .test_id = "story.slider.stepped.track",
    }).mount(scope, cx);
    s2.wrapper.meta.ownership.meta.test_id = "story.slider.stepped";
    const continuous = try ui.widgets.Slider(.{
        .min = 0,
        .max = 10,
        .step = 0,
        .initial_value = 5,
        .width = 320,
        .show_value = true,
        .test_id = "story.slider.continuous.track",
    }).mount(scope, cx);
    const status = try label(cx, "");
    status.meta.ownership.meta.test_id = "story.slider.feedback.status";
    const pattern_status = try label(cx, "");
    pattern_status.meta.ownership.meta.test_id = "story.slider.feedback.pattern";
    const state = try scope.allocator.create(SliderFeedbackStory);
    state.* = .{ .basic = s1, .stepped = s2, .continuous = continuous, .status = status, .pattern_status = pattern_status };
    try scope.adoptResource(state, SliderFeedbackStory.destroy);
    s2.state.on_change = ui.Cx.handlerFrom(SliderFeedbackStory, state, SliderFeedbackStory.refresh);
    continuous.state.on_change = ui.Cx.handlerFrom(SliderFeedbackStory, state, SliderFeedbackStory.refresh);
    state.refresh();

    try c.appendChild(a, try label(cx, "Haptic feedback: opt in to try"));
    const toggle = try ui.widgets.Switch(.{
        .label_text = "Enable trackpad feedback",
        .initial_checked = false,
        .on_change = ui.Cx.boolHandlerFrom(SliderFeedbackStory, state, SliderFeedbackStory.toggle),
    }).mount(scope, cx);
    toggle.meta.ownership.meta.test_id = "story.slider.feedback.toggle";
    try c.appendChild(a, toggle);
    const pattern_options = [_]ui.widgets.checkbox.RadioOption{
        .{ .value = "alignment", .label_text = "Alignment" },
        .{ .value = "generic", .label_text = "Generic" },
        .{ .value = "level_change", .label_text = "Level change" },
    };
    const patterns = try ui.widgets.RadioGroup(.{
        .options = &pattern_options,
        .value = "alignment",
        .horizontal = true,
        .on_change = ui.Cx.strHandlerFrom(SliderFeedbackStory, state, SliderFeedbackStory.selectPattern),
    }).mount(scope, cx);
    for (patterns.children.items, [_][]const u8{
        "story.slider.pattern.alignment", "story.slider.pattern.generic", "story.slider.pattern.level_change",
    }) |option, test_id| option.meta.ownership.meta.test_id = test_id;
    try c.appendChild(a, patterns);
    try c.appendChild(a, pattern_status);
    try c.appendChild(a, try label(cx, "Native patterns, not intensity levels. Alignment is the default for step snapping."));
    try c.appendChild(a, status);
    try c.appendChild(a, try label(cx, "macOS Force Touch trackpad; device and system settings determine the feel."));
    try c.appendChild(a, try label(cx, "0–100, value 40"));
    try c.appendChild(a, s1.wrapper);
    try c.appendChild(a, try label(cx, "0–10 step 1, value 5"));
    try c.appendChild(a, s2.wrapper);
    try c.appendChild(a, try label(cx, "Continuous (step 0): no feedback"));
    try c.appendChild(a, continuous.wrapper);
    const reset = try ui.widgets.Button(.{
        .label = "Reset both to 5 (no feedback)",
        .variant = .secondary,
        .on_click = ui.Cx.handlerFrom(SliderFeedbackStory, state, SliderFeedbackStory.reset),
    }).mount(scope, cx);
    reset.meta.ownership.meta.test_id = "story.slider.feedback.reset";
    try c.appendChild(a, reset);

    const s3 = try ui.widgets.Slider(.{ .initial_value = 30, .width = 320, .disabled = true }).mount(scope, cx);
    try c.appendChild(a, try label(cx, "Disabled"));
    try c.appendChild(a, s3.wrapper);

    return c;
}

const W = ui.widgets;

// ── Switch ──

/// 开关状态回显，e2e 要断言「拨动真的改了状态」，组件本身不渲染当前值。
const SwitchStory = struct {
    status: *ui.Node,
    buf: [48]u8 = undefined,

    fn onChange(self: *SwitchStory, checked: bool) void {
        const txt = std.fmt.bufPrint(&self.buf, "toggled → {s}", .{if (checked) "on" else "off"}) catch return;
        if (self.status.getText()) |old| {
            var t = old;
            t.content = txt;
            t.owned = false; // txt 指向 self.buf，非堆 owned（同 CheckboxStory）
            t.inline_len = 0;
            self.status.setText(t);
        }
        self.status.markRenderDirty();
    }
};

pub fn buildSwitch(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);

    const status = try ui.text(cx, "toggled → (none)", .{ .font_size = 13, .color = light.color.fg_secondary });
    status.meta.ownership.meta.test_id = "story.switch.status";
    try c.appendChild(a, status);
    const story = try cx.bindState(SwitchStory, .{ .status = status });

    const off_switch = try W.Switch(.{
        .label_text = "Off",
        .initial_checked = false,
        .on_change = ui.Cx.boolHandlerFrom(SwitchStory, story, SwitchStory.onChange),
    }).mount(scope, cx);
    off_switch.meta.ownership.meta.test_id = "story.switch.off";
    try c.appendChild(a, off_switch);
    try c.appendChild(a, try W.Switch(.{ .label_text = "On", .initial_checked = true }).mount(scope, cx));
    try c.appendChild(a, try W.Switch(.{ .label_text = "Disabled", .disabled = true }).mount(scope, cx));
    return c;
}

// ── Radio / RadioGroup ──

/// RadioGroup 选中值回显，互斥选择是 radio 的定义性语义，必须可断言。
const RadioStory = struct {
    status: *ui.Node,
    buf: [48]u8 = undefined,

    fn onChange(self: *RadioStory, value: []const u8) void {
        const txt = std.fmt.bufPrint(&self.buf, "selected → {s}", .{value}) catch return;
        if (self.status.getText()) |old| {
            var t = old;
            t.content = txt;
            t.owned = false;
            t.inline_len = 0;
            self.status.setText(t);
        }
        self.status.markRenderDirty();
    }
};

pub fn buildRadio(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);

    const status = try ui.text(cx, "selected → (none)", .{ .font_size = 13, .color = light.color.fg_secondary });
    status.meta.ownership.meta.test_id = "story.radio.status";
    try c.appendChild(a, status);
    const radio_story = try cx.bindState(RadioStory, .{ .status = status });

    try c.appendChild(a, try label(cx, "Radio"));
    try c.appendChild(a, try W.Radio(.{ .label_text = "Selected", .checked = true, .value = "a", .name = "g" }).mount(scope, cx));
    try c.appendChild(a, try W.Radio(.{ .label_text = "Unselected", .checked = false, .value = "b", .name = "g" }).mount(scope, cx));

    try c.appendChild(a, try label(cx, "RadioGroup"));
    const opts = [_]ui.widgets.checkbox.RadioOption{
        .{ .value = "x", .label_text = "Option X" },
        .{ .value = "y", .label_text = "Option Y" },
        .{ .value = "z", .label_text = "Option Z" },
    };
    const group = try W.RadioGroup(.{
        .options = &opts,
        .value = "x",
        .on_change = ui.Cx.strHandlerFrom(RadioStory, radio_story, RadioStory.onChange),
    }).mount(scope, cx);
    group.meta.ownership.meta.test_id = "story.radio.group";
    try c.appendChild(a, group);
    return c;
}

// ── Badge / StatusBadge ──
pub fn buildBadge(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const r1 = try row(cx, 12);
    inline for (.{ "info", "success", "warning", "error" }, .{ W.badge.BadgeStatus.info, .success, .warning, .@"error" }) |t, st| {
        try r1.appendChild(a, try W.Badge(.{ .text = t, .status = st }).mount(scope, cx));
    }
    try c.appendChild(a, try label(cx, "Badge status"));
    try c.appendChild(a, r1);

    const r2 = try row(cx, 12);
    try r2.appendChild(a, try W.Badge(.{ .count = 5 }).mount(scope, cx));
    try r2.appendChild(a, try W.Badge(.{ .count = 120, .max_count = 99 }).mount(scope, cx));
    try r2.appendChild(a, try W.Badge(.{ .dot = true }).mount(scope, cx));
    try c.appendChild(a, try label(cx, "Count / dot"));
    try c.appendChild(a, r2);

    // ── 尺寸 ──
    try c.appendChild(a, try label(cx, "Sizes (sm / md)"));
    const r_sz = try row(cx, 12);
    inline for (.{ W.badge.BadgeSize.sm, .md }) |sz| {
        try r_sz.appendChild(a, try W.Badge(.{ .count = 8, .size = sz }).mount(scope, cx));
    }
    try c.appendChild(a, r_sz);

    const r3 = try row(cx, 12);
    try r3.appendChild(a, try W.StatusBadge(.{ .label_text = "Online", .status = .success }).mount(scope, cx));
    try r3.appendChild(a, try W.StatusBadge(.{ .label_text = "Error", .status = .@"error" }).mount(scope, cx));
    try c.appendChild(a, try label(cx, "StatusBadge"));
    try c.appendChild(a, r3);
    return c;
}

// ── Card ──
pub fn buildCard(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);

    // ── 变体 ──
    try c.appendChild(a, try label(cx, "Variants (default / outlined / elevated)"));
    try c.appendChild(a, try W.Card(.{ .title = "Default", .subtitle = "with subtitle", .variant = .default, .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Card(.{ .title = "Outlined", .variant = .outlined, .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Card(.{ .title = "Elevated", .variant = .elevated, .width = 320 }).mount(scope, cx));

    // ── body ──
    try c.appendChild(a, try label(cx, "With body"));
    const res = try W.Card(.{ .title = "Card with body", .width = 320 }).mountBody(scope, cx);
    try res.body.appendChild(a, try ui.text(cx, "Body content goes here.", .{ .font_size = 13, .color = light.color.fg_secondary }));
    try c.appendChild(a, res.card);

    // ── 交互态 ──
    try c.appendChild(a, try label(cx, "States (selected / hoverable / interactive / no-pad)"));
    try c.appendChild(a, try W.Card(.{ .title = "Selected", .selected = true, .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Card(.{ .title = "Hoverable", .hoverable = true, .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Card(.{ .title = "Interactive", .interactive = true, .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Card(.{ .title = "No padding", .padded = false, .width = 320 }).mount(scope, cx));
    return c;
}

// ── Divider ──
pub fn buildDivider(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);

    // ── 样式：solid / dashed / dotted ──
    try c.appendChild(a, try label(cx, "Styles (solid / dashed / dotted)"));
    inline for (.{ W.divider.DividerVariant.solid, .dashed, .dotted }) |variant| {
        try c.appendChild(a, try W.Divider(.{ .orientation = .horizontal, .variant = variant }).mount(scope, cx));
    }

    // ── 带 label，三种位置 ──
    try c.appendChild(a, try label(cx, "Labeled (left / center / right)"));
    try c.appendChild(a, try W.Divider(.{ .label_text = "LEFT", .label_position = .left }).mount(scope, cx));
    try c.appendChild(a, try W.Divider(.{ .label_text = "OR", .label_position = .center }).mount(scope, cx));
    try c.appendChild(a, try W.Divider(.{ .label_text = "RIGHT", .label_position = .right }).mount(scope, cx));

    // ── 垂直方向 ──
    try c.appendChild(a, try label(cx, "Vertical"));
    const vrow = try ui.box(cx, .{ .direction = .row, .gap = 12, .align_items = .center, .height = .{ .px = 32 } }, .{});
    try vrow.appendChild(a, try ui.text(cx, "Left", .{ .font_size = 13, .color = light.color.fg_primary }));
    try vrow.appendChild(a, try W.Divider(.{ .orientation = .vertical }).mount(scope, cx));
    try vrow.appendChild(a, try ui.text(cx, "Middle", .{ .font_size = 13, .color = light.color.fg_primary }));
    try vrow.appendChild(a, try W.Divider(.{ .orientation = .vertical }).mount(scope, cx));
    try vrow.appendChild(a, try ui.text(cx, "Right", .{ .font_size = 13, .color = light.color.fg_primary }));
    try c.appendChild(a, vrow);
    return c;
}

// ── Tag ──
pub fn buildTag(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);

    // ── 全部颜色（含 info）──
    const r1 = try row(cx, 8);
    inline for (.{ W.TagColor.neutral, .accent, .success, .warning, .danger, .info }, .{ "neutral", "accent", "success", "warning", "danger", "info" }) |col_, t| {
        try r1.appendChild(a, try W.Tag(.{ .text = t, .color = col_ }).mount(scope, cx));
    }
    try c.appendChild(a, try label(cx, "Colors"));
    try c.appendChild(a, r1);

    // ── 尺寸 ──
    try c.appendChild(a, try label(cx, "Sizes (sm / md)"));
    const r_sz = try row(cx, 8);
    inline for (.{ W.TagSize.sm, .md }, .{ "Small", "Medium" }) |sz, t| {
        try r_sz.appendChild(a, try W.Tag(.{ .text = t, .color = .accent, .size = sz }).mount(scope, cx));
    }
    try c.appendChild(a, r_sz);

    // ── 变体 ──
    try c.appendChild(a, try label(cx, "Variants"));
    const r2 = try row(cx, 8);
    try r2.appendChild(a, try W.Tag(.{ .text = "Default", .variant = .default }).mount(scope, cx));
    try r2.appendChild(a, try W.Tag(.{ .text = "Outline", .variant = .outline }).mount(scope, cx));
    try r2.appendChild(a, try W.Tag(.{ .text = "Closable", .closable = true }).mount(scope, cx));
    try r2.appendChild(a, try W.Tag(.{ .text = "Outline + close", .variant = .outline, .color = .danger, .closable = true }).mount(scope, cx));
    try c.appendChild(a, r2);
    return c;
}

// ── Chip ──
pub fn buildChip(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const icons = ui.assets.common;
    const c = try col(cx, 12);

    // ── 变体（含 disabled）──
    try c.appendChild(a, try label(cx, "Variants"));
    const r = try row(cx, 8);
    try r.appendChild(a, try W.Chip(.{ .label = "Default" }).mount(scope, cx));
    try r.appendChild(a, try W.Chip(.{ .label = "Active", .variant = .active }).mount(scope, cx));
    try r.appendChild(a, try W.Chip(.{ .label = "Outline", .variant = .outline }).mount(scope, cx));
    try r.appendChild(a, try W.Chip(.{ .label = "Disabled", .variant = .disabled }).mount(scope, cx));
    try r.appendChild(a, try W.Chip(.{ .label = "Closable", .closable = true }).mount(scope, cx));
    try c.appendChild(a, r);

    // ── 尺寸 ──
    try c.appendChild(a, try label(cx, "Sizes (xs / sm / md)"));
    const r_sz = try row(cx, 8);
    inline for (.{ W.ChipSize.xs, .sm, .md }, .{ "XS", "SM", "MD" }) |sz, t| {
        try r_sz.appendChild(a, try W.Chip(.{ .label = t, .size = sz, .variant = .active }).mount(scope, cx));
    }
    try c.appendChild(a, r_sz);

    // ── 带图标 ──
    try c.appendChild(a, try label(cx, "With icon"));
    const r_ic = try row(cx, 8);
    try r_ic.appendChild(a, try W.Chip(.{ .label = "Starred", .icon_asset = icons.star }).mount(scope, cx));
    try r_ic.appendChild(a, try W.Chip(.{ .label = "Folder", .icon_asset = icons.folder, .closable = true }).mount(scope, cx));
    try c.appendChild(a, r_ic);
    return c;
}

// ── Progress ──
pub fn buildProgress(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);
    try c.appendChild(a, try label(cx, "Values 25% / 60% / 100%"));
    try c.appendChild(a, try W.Progress(.{ .value = 25, .width = 320, .show_text = true }).mount(scope, cx));
    try c.appendChild(a, try W.Progress(.{ .value = 60, .width = 320, .show_text = true }).mount(scope, cx));
    try c.appendChild(a, try W.Progress(.{ .value = 100, .width = 320, .status = .success, .show_text = true }).mount(scope, cx));

    try c.appendChild(a, try label(cx, "Heights (2 / 4 / 8 / 12)"));
    inline for (.{ 2, 4, 8, 12 }) |h| {
        try c.appendChild(a, try W.Progress(.{ .value = 50, .width = 320, .height = @as(f32, h) }).mount(scope, cx));
    }

    try c.appendChild(a, try label(cx, "Error / indeterminate / no-text"));
    try c.appendChild(a, try W.Progress(.{ .value = 40, .width = 320, .status = .@"error", .show_text = true }).mount(scope, cx));
    try c.appendChild(a, try W.Progress(.{ .indeterminate = true, .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Progress(.{ .value = 70, .width = 320, .show_text = false }).mount(scope, cx));
    return c;
}

// ── Spinner ──
pub fn buildSpinner(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const r = try row(cx, 20);
    // e2e 墨量断言要框到 spinner 本身：story.<key> 的 rect 还含标题/描述文字，
    // 那些文字的像素会把 spinner 画不出来这件事完全盖住（实测 7600+ dark）。
    r.meta.ownership.meta.test_id = "story.spinner.row";
    try r.appendChild(a, try W.Spinner(.{ .size = 16 }).mount(scope, cx));
    try r.appendChild(a, try W.Spinner(.{ .size = 24 }).mount(scope, cx));
    try r.appendChild(a, try W.Spinner(.{ .size = 36 }).mount(scope, cx));
    return r;
}

// ── Skeleton ──
pub fn buildSkeleton(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    // 同 spinner：框到骨架图形本身，避开标题/描述文字的像素。
    c.meta.ownership.meta.test_id = "story.skeleton.col";
    try c.appendChild(a, try W.Skeleton(.{ .variant = .text, .width = 280, .height = 14 }).mount(scope, cx));
    try c.appendChild(a, try W.Skeleton(.{ .variant = .text, .width = 200, .height = 14 }).mount(scope, cx));
    try c.appendChild(a, try W.Skeleton(.{ .variant = .circular, .width = 48, .height = 48 }).mount(scope, cx));
    try c.appendChild(a, try W.Skeleton(.{ .variant = .rectangular, .width = 280, .height = 80 }).mount(scope, cx));
    return c;
}

// ── Alert ──
pub fn buildAlert(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    // 全 4 变体，且都带 closable（× 关闭按钮）
    try c.appendChild(a, try W.Alert(.{ .variant = .info, .title = "Info", .message = "Informational message.", .closable = true }).mount(scope, cx));
    try c.appendChild(a, try W.Alert(.{ .variant = .success, .title = "Success", .message = "It worked.", .closable = true }).mount(scope, cx));
    try c.appendChild(a, try W.Alert(.{ .variant = .warning, .title = "Warning", .message = "Be careful.", .closable = true }).mount(scope, cx));
    try c.appendChild(a, try W.Alert(.{ .variant = .@"error", .title = "Error", .message = "Something broke.", .closable = true }).mount(scope, cx));
    // 无标题（仅 message）
    try c.appendChild(a, try W.Alert(.{ .variant = .info, .message = "Title-less alert with just a message." }).mount(scope, cx));
    return c;
}

// ── Notification（设计稿 § 16 应用内全局提醒）──
pub const buildNotification = @import("notification_story.zig").build;

// ── Timeline ──
pub fn buildTimeline(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const items = [_]W.TimelineItem{
        .{ .title = "Created", .description = "Order placed", .time = "09:00", .status = .completed },
        .{ .title = "Shipped", .description = "In transit", .time = "12:30", .status = .active },
        .{ .title = "Delivered", .description = "Pending", .status = .pending },
    };
    return W.Timeline(.{ .items = &items }).mount(scope, cx);
}

// ── Breadcrumb ──
pub fn buildBreadcrumb(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const items = [_]W.BreadcrumbItem{
        .{ .id = "home", .label_text = "Home" },
        .{ .id = "lib", .label_text = "Library" },
        .{ .id = "data", .label_text = "Data" },
    };
    return W.Breadcrumb(.{ .items = &items }).mount(scope, cx);
}

// ── GlassBox / Liquid Glass ──
//
// 对齐 Apple Liquid Glass（WWDC25）官方示例：
//   • capsule 玻璃 toolbar（分组 = ToolbarSpacer 语义）
//   • 浮动 tab bar capsule + 独立 search 圆钮
//   • .glass / .glassProminent 按钮（prominent = tinted）
//   • regular vs clear 变体（clear 叠在媒体 + 35% dimming 上）
//   • 玻璃永远浮在内容层之上，不叠玻璃（HIG）

/// 彩色内容背景：渐变 + 网格线 + 文字（高频细节层）。玻璃必须叠在
/// 丰富内容上才能看出 blur 磨砂 / 折射，纯渐变太低频看不出来。
fn glassBackdrop(cx: *ui.Cx, height: f32) !*ui.Node {
    const a = cx.allocator;
    const n = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = height },
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .gap = 18,
        .position = .relative,
        .overflow_hidden = true,
    }, .{});
    const ext = try n.style.ensureExtFallible(a);
    ext.corner_radius = ui.CornerRadius.uniform(24);
    ext.multi_gradient = ui.MultiGradient.fromSlice(&[_]ui.GradientStop{
        .{ .color = ui.Color.rgba(94, 58, 197, 255), .position = 0.0 },
        .{ .color = ui.Color.rgba(219, 72, 133, 255), .position = 0.35 },
        .{ .color = ui.Color.rgba(246, 148, 62, 255), .position = 0.68 },
        .{ .color = ui.Color.rgba(58, 160, 222, 255), .position = 1.0 },
    }, .diagonal);

    // ── 网格竖线 ──
    const v_lines = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .position = .absolute,
        .direction = .row,
        .justify = .space_evenly,
    }, .{});
    for (0..24) |_| {
        try v_lines.appendChild(a, try ui.box(cx, .{
            .width = .{ .px = 1 },
            .height = .{ .grow = .{} },
            .background = ui.Color.rgba(255, 255, 255, 120),
        }, .{}));
    }
    try n.appendChild(a, v_lines);

    // ── 网格横线 ──
    const h_lines = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .position = .absolute,
        .direction = .column,
        .justify = .space_evenly,
    }, .{});
    const h_count: usize = @max(2, @as(usize, @intFromFloat(height / 36)));
    for (0..h_count) |_| {
        try h_lines.appendChild(a, try ui.box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 1 },
            .background = ui.Color.rgba(255, 255, 255, 120),
        }, .{}));
    }
    try n.appendChild(a, h_lines);

    // ── 文字层：高频细节，blur 后应变成可辨认的雾状 ──
    const words = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .position = .absolute,
        .direction = .row,
        .justify = .space_evenly,
        .align_items = .center,
    }, .{});
    inline for (.{ "Liquid", "Aa", "玻璃", "0123", "Glass", "≋≋≋", "Bb", "molten" }, 0..) |txt, i| {
        try words.appendChild(a, try ui.text(cx, txt, .{
            .font_size = if (i % 3 == 0) 22 else 13,
            .font_weight = if (i % 2 == 0) 700 else 400,
            .color = if (i % 2 == 0) ui.Color.rgba(255, 255, 255, 235) else ui.Color.rgba(20, 16, 40, 220),
        }));
    }
    try n.appendChild(a, words);

    return n;
}

/// capsule 玻璃 slab：Apple 默认玻璃形状（圆角 = 高度一半）。
/// shadow 挂 wrapper、glass 挂内层：glass 节点自带 shadow 会把 promoted
/// surface bounds 撑大，合成时出现矩形切块（框架 bug，见 liquid_glass 记录）。
fn glassCapsule(cx: *ui.Cx, height: f32, params: ui.GlassParams) !*ui.Node {
    const radius = height / 2;
    const wrapper = try ui.box(cx, .{
        .height = .{ .px = height },
        .direction = .row,
    }, .{});
    const wext = try wrapper.style.ensureExtFallible(cx.allocator);
    wext.corner_radius = ui.CornerRadius.uniform(radius);
    wext.setShadow(.{ .color = ui.Color.rgba(10, 14, 30, 60), .blur = 14, .offset_y = 5 });
    const n = try ui.box(cx, .{
        .height = .{ .grow = .{} },
        .direction = .row,
        .align_items = .center,
        .gap = 4,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = ui.Color.rgba(255, 255, 255, 20),
        .border = .{ .width = 1, .color = ui.Color.rgba(255, 255, 255, 110), .radius = radius },
    }, .{});
    const ext = try n.style.ensureExtFallible(cx.allocator);
    ext.corner_radius = ui.CornerRadius.uniform(radius);
    ext.glass = params;
    try wrapper.appendChild(cx.allocator, n);
    return wrapper;
}

/// 玻璃 capsule 里的 icon 按钮位（HIG：玻璃层内部用填充分隔，不再叠玻璃）。
fn glassIconSlot(cx: *ui.Cx, asset: ui.SvgAsset) !*ui.Node {
    const slot = try ui.box(cx, .{
        .width = .{ .px = 34 },
        .height = .{ .px = 34 },
        .align_items = .center,
        .justify = .center,
    }, .{});
    var icon_style = ui.Style{};
    icon_style.width = .{ .px = 17 };
    icon_style.height = .{ .px = 17 };
    try slot.appendChild(cx.allocator, try ui.iconTint(cx, asset, ui.Color.rgba(255, 255, 255, 235), icon_style));
    return slot;
}

/// 取 glassCapsule 的内层玻璃节点（wrapper 只负责 shadow）。
fn capsuleBody(n: *ui.Node) *ui.Node {
    return n.children.items[0];
}

fn glassLabel(cx: *ui.Cx, txt: []const u8, weight: u16) !*ui.Node {
    return ui.text(cx, txt, .{ .font_size = 13, .font_weight = weight, .color = ui.Color.rgba(255, 255, 255, 240) });
}

// 官方推荐参数（见 glass.metal 头注释 “Apple 推荐” 列）
fn regularGlass() ui.GlassParams {
    // 与 GlassLab 默认一致：内部近乎无畸变 + rim 内收 + 轻微 pincushion。
    return .{
        .backdrop_blur = 14,
        .glass_intensity = 1.5,
        .specular_opacity = 0.4,
        .specular_saturation = 7.0,
        .refraction_level = 1.0,
        .blur_level = 0.55,
        .warp_gain = 2.4,
        .center_thickness = 13.0,
        .bezel_width = 0.34,
        .edge_field_strength = 3.2,
        .magnification = -0.06,
        .scale_ratio = 1.0,
    };
}

// ── 可拖拽玻璃：按住拖动，实时观察折射/磨砂随背景变化 ──
const GlassDragState = struct {
    cx: *ui.Cx,
    target: *ui.Node,
    dragging: bool = false,
    start_x: f32 = 0,
    start_y: f32 = 0,
    base_tx: f32 = 0,
    base_ty: f32 = 0,
};

fn glassDragHandler(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
    if (context == null) return .ignored;
    const st: *GlassDragState = @ptrCast(@alignCast(context.?));
    switch (event) {
        .mouse_down => |e| {
            st.dragging = true;
            st.start_x = e.x;
            st.start_y = e.y;
            st.base_tx = st.target.style.translate_x;
            st.base_ty = st.target.style.translate_y;
            st.cx.setPointerCapture(st.target);
            return .stop;
        },
        .mouse_move => |e| {
            if (st.dragging) {
                st.target.style.translate_x = st.base_tx + (e.x - st.start_x);
                st.target.style.translate_y = st.base_ty + (e.y - st.start_y);
                st.target.markCompositePropDirty();
                return .stop;
            }
        },
        .mouse_up => {
            if (st.dragging) {
                st.dragging = false;
                st.cx.releasePointerCapture();
                return .stop;
            }
            return .ignored;
        },
        else => {},
    }
    return .ignored;
}

// ── Interactive motion：hover 抬升 / press 下沉 / 弹性回弹 ──
//
// 完整几何层交互动效：hover 悬浮抬升 + 阴影加深 + 玻璃提亮、press 下沉、
// release 欠阻尼弹簧回弹。before_render 逐帧弹簧直接写 style.translate_y
// （与拖拽玻璃 / nav lens 同款机制）。
//
// 两个刻意规避（皆实测）：
//  1. 不用 animateNode, active transform animation 会把 glass 子树推上
//     overlay surface 合成路径。
//  2. 不用 W.GlassBox 组件，组件化 glass + 非零 translate 时后代内容整块
//     消失只剩壳（plain ext.glass 节点 + translate 则正常，拖拽 story 同款；
//     待立案修复）。故 tile 用 plain glass slab 手搭。
const GlassMotionState = struct {
    cx: *ui.Cx,
    /// wrapper：shadow + translate 都挂这里（与拖拽 story 结构一致）。
    target: *ui.Node,
    /// 内层玻璃节点：hover/press 换挡背景亮度（材质响应）。
    body: *ui.Node,
    hovered: bool = false,
    pressed: bool = false,
    /// 弹簧状态：ty 当前位移，vy 速度，goal 目标位移。
    ty: f32 = 0,
    vy: f32 = 0,
    goal: f32 = 0,
    /// 刚度 / 阻尼（帧率基准 ~60fps；damp 越接近 1 越弹）。
    stiff: f32 = 0.25,
    damp: f32 = 0.55,
    shadow_lifted: bool = false,
};

const GLASS_MOTION_LIFT: f32 = -10; // hover 抬升高度
const GLASS_MOTION_SINK: f32 = -3; // press 下沉后仍略高于静息位

fn glassMotionShadow(st: *GlassMotionState, lifted: bool) void {
    // shadow 不参与逐帧插值，hover/rest 两档切换，配合 translate 的连续
    // 动画，视觉上已是"影子随抬升散开"。
    if (st.shadow_lifted == lifted) return;
    st.shadow_lifted = lifted;
    // ext 在 story 构造期已建好（同一节点此前设过 corner_radius/glass/inset），
    // 这里必然命中既有指针、不分配 -> 构造上不可能失败。本函数是 void 回调，无法传播。
    const ext = st.target.style.ensureExtFallible(st.cx.allocator) catch unreachable;
    if (lifted) {
        ext.setShadow(.{ .color = ui.Color.rgba(10, 14, 30, 90), .blur = 30, .offset_y = 14 });
    } else {
        ext.setShadow(.{ .color = ui.Color.rgba(10, 14, 30, 60), .blur = 14, .offset_y = 5 });
    }
    st.target.markRenderDirty();
}

/// 材质响应：静息 20 / hover 36 / press 52 三档白底亮度。
fn glassMotionSurface(st: *GlassMotionState) void {
    const alpha: u8 = if (st.pressed) 52 else if (st.hovered) 36 else 20;
    st.body.setBackgroundRaw(ui.Color.rgba(255, 255, 255, alpha));
    st.body.markRenderDirty();
}

fn glassMotionGoal(st: *GlassMotionState, goal: f32, stiff: f32, damp: f32) void {
    st.goal = goal;
    st.stiff = stiff;
    st.damp = damp;
    // 踢一帧：idle 停帧下 before_render 不会自动再来。
    st.target.markRenderDirty();
}

fn glassMotionBeforeRender(node: *ui.Node) void {
    const raw = node.behavior.events.event_context orelse return;
    const st: *GlassMotionState = @ptrCast(@alignCast(raw));
    const dy = st.goal - st.ty;
    if (@abs(dy) < 0.05 and @abs(st.vy) < 0.05) {
        if (st.ty != st.goal) {
            st.ty = st.goal;
            st.vy = 0;
            node.style.translate_y = st.ty;
            node.markCompositePropDirty();
        }
        return; // 收敛：不再标脏，让 idle 停帧生效
    }
    st.vy = (st.vy + dy * st.stiff) * st.damp;
    st.ty += st.vy;
    node.style.translate_y = st.ty;
    node.markCompositePropDirty();
    node.markRenderDirty(); // 驱动下一帧继续插值
}

fn glassMotionHandler(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
    if (context == null) return .ignored;
    const st: *GlassMotionState = @ptrCast(@alignCast(context.?));
    switch (event) {
        .mouse_enter => {
            st.hovered = true;
            glassMotionSurface(st);
            if (!st.pressed) {
                // hover：平滑抬升（近临界阻尼，无过冲）
                glassMotionGoal(st, GLASS_MOTION_LIFT, 0.25, 0.55);
                glassMotionShadow(st, true);
            }
        },
        .mouse_leave => {
            st.hovered = false;
            st.pressed = false;
            glassMotionSurface(st);
            // 离开：稍带回弹地落回静息位
            glassMotionGoal(st, 0, 0.16, 0.72);
            glassMotionShadow(st, false);
        },
        .mouse_down => {
            st.pressed = true;
            glassMotionSurface(st);
            // press：快速下沉（高刚度急停）
            glassMotionGoal(st, GLASS_MOTION_SINK, 0.5, 0.45);
            return .stop;
        },
        .mouse_up => {
            if (st.pressed) {
                st.pressed = false;
                glassMotionSurface(st);
                if (st.hovered) {
                    // release：欠阻尼弹簧回到悬浮位（明显弹性过冲）
                    glassMotionGoal(st, GLASS_MOTION_LIFT, 0.12, 0.88);
                } else {
                    glassMotionGoal(st, 0, 0.16, 0.72);
                    glassMotionShadow(st, false);
                }
                return .stop;
            }
        },
        else => {},
    }
    return .ignored;
}

/// 一块完整交互动效玻璃 tile：plain glass slab（结构同 glassCapsule：
/// wrapper 管 shadow+translate，内层节点挂 ext.glass）。
fn glassMotionTile(scope: *ui.Scope, cx: *ui.Cx, title: []const u8, subtitle: []const u8, tint: ?ui.Color, test_id: []const u8) !*ui.Node {
    const a = cx.allocator;
    const wrapper = try ui.box(cx, .{ .direction = .column }, .{});
    wrapper.style.cursor = .pointer;
    (try wrapper.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(22);

    var params = regularGlass();
    if (tint) |t| params.glass_tint = t;
    const body = try ui.box(cx, .{
        .width = .{ .px = 190 },
        .direction = .column,
        .gap = 6,
        .padding = ui.Padding.all(16),
        .background = ui.Color.rgba(255, 255, 255, 20),
        .border = .{ .width = 1, .color = ui.Color.rgba(255, 255, 255, 110), .radius = 22 },
    }, .{});
    const bext = try body.style.ensureExtFallible(a);
    bext.corner_radius = ui.CornerRadius.uniform(22);
    bext.glass = params;
    try body.appendChild(a, try ui.text(cx, title, .{ .font_size = 15, .font_weight = 650, .color = ui.Color.rgba(255, 255, 255, 245) }));
    try body.appendChild(a, try ui.text(cx, subtitle, .{ .font_size = 12, .font_weight = 450, .color = ui.Color.rgba(255, 255, 255, 200) }));
    try body.appendChild(a, try glassLabel(cx, "hover · press · release", 450));
    try wrapper.appendChild(a, body);

    const st = try a.create(GlassMotionState);
    st.* = .{ .cx = cx, .target = wrapper, .body = body };
    try scope.registerResource(@ptrCast(st), struct {
        fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            alloc.destroy(@as(*GlassMotionState, @ptrCast(@alignCast(ptr))));
        }
    }.cleanup);
    // 事件挂 wrapper：enter/leave 不吞（返回 ignored），down/up stop 防误拖画布。
    wrapper.behavior.events.event_context = @ptrCast(st);
    wrapper.behavior.events.on_event = glassMotionHandler;
    wrapper.addBeforeRender(glassMotionBeforeRender);
    st.shadow_lifted = true; // 强制首次真正写入 rest 档阴影
    glassMotionShadow(st, false);
    wrapper.meta.ownership.meta.test_id = test_id;
    return wrapper;
}

// ── Floating nav + liquid glass 放大镜 lens ──
const NAV_ITEM_COUNT: usize = 5;

const NavLensState = struct {
    cx: *ui.Cx,
    lens: *ui.Node,
    pill: *ui.Node,
    bar: *ui.Node,
    container: *ui.Node,
    items: [NAV_ITEM_COUNT]*ui.Node,
    slot: usize = 1,
    dragging: bool = false,
    magnified: bool = false,
    start_x: f32 = 0,
    base_tx: f32 = 0,
};

fn navLensParams(magnified: bool) ui.GlassParams {
    return .{
        .backdrop_blur = 5,
        .glass_intensity = 1.3,
        .specular_opacity = 0.16,
        .specular_saturation = 5.0,
        .refraction_level = 1.0,
        .blur_level = 0.12,
        .warp_gain = if (magnified) 2.8 else 2.0,
        .center_thickness = if (magnified) 18.0 else 12.0,
        .bezel_width = 0.42,
        .edge_field_strength = if (magnified) 4.0 else 3.0,
        .magnification = if (magnified) 0.85 else 0.35,
        .scale_ratio = 1.25,
        .center_zoom_radius = 0.62,
    };
}

/// 静止态 = 灰色高亮 pill（无玻璃，缩小在 bar 内）；
/// 按下态 = 透明液态玻璃放大镜 + 整个 nav 微放大。
const NAV_LENS_REST_W: f32 = 112;
const NAV_LENS_REST_H: f32 = 84;
const NAV_LENS_ACTIVE_W: f32 = 156;
const NAV_LENS_ACTIVE_H: f32 = 124;

/// 静止态 = 灰色高亮 pill（无玻璃）；按下态 = 透明液态玻璃放大镜。
/// 注意：不用 scale 做放大（glass + scale 组合会走 overlay surface 合成，
/// 位置有偏移 bug），改真实 width/height 切换。
fn navLensSetMagnified(st: *NavLensState, magnified: bool) void {
    if (st.magnified == magnified) return;
    st.magnified = magnified;
    // ext 在 story 构造期已建好（同一节点此前设过 corner_radius/glass/inset），
    // 这里必然命中既有指针、不分配 -> 构造上不可能失败。本函数是 void 回调，无法传播。
    const ext = st.lens.style.ensureExtFallible(st.cx.allocator) catch unreachable;
    const w: f32 = if (magnified) NAV_LENS_ACTIVE_W else NAV_LENS_REST_W;
    const h: f32 = if (magnified) NAV_LENS_ACTIVE_H else NAV_LENS_REST_H;
    // 尺寸切换时保持中心不动
    const old_r = st.lens.rectFromWorldOrFallback();
    if (old_r.w > 0) st.lens.style.translate_x += (old_r.w - w) / 2;
    st.lens.style.width = .{ .px = w };
    st.lens.style.height = .{ .px = h };
    ext.corner_radius = ui.CornerRadius.uniform(h / 2);
    ext.inset = .{ .top = .{ .px = -(h - NAV_LENS_REST_H) / 2 - 4 } };
    if (magnified) {
        ext.glass = navLensParams(true);
        st.lens.style.border = .{ .width = 1, .color = ui.Color.rgba(255, 255, 255, 160), .radius = h / 2 };
    } else {
        // 静止态 lens 完全不画（仅保留命中区），灰 pill 底座由 bar 内的 pill 节点负责
        ext.glass = null;
        st.lens.style.border = .{ .width = 0, .color = ui.Color.rgba(0, 0, 0, 0), .radius = h / 2 };
    }
    st.lens.markSizingDirty();
    st.lens.markCompositePropDirty();
    st.lens.markRenderDirty();
}

/// slot 的 world 中心 x（未含 translate 的布局帧）
fn navSlotWorldCenter(st: *NavLensState, slot: usize) ?f32 {
    const item_r = st.items[slot].rectFromWorldOrFallback();
    if (item_r.w <= 0) return null;
    return item_r.x + item_r.w / 2;
}

/// 把 node 平移到中心对齐 slot（与父节点坐标基无关：用自身 world rect 求差）
fn navPlaceOnCenter(node: *ui.Node, world_center: f32) void {
    const nr = node.rectFromWorldOrFallback();
    if (nr.w <= 0) return;
    const target = world_center - (nr.x + nr.w / 2);
    if (@abs(node.style.translate_x - target) < 0.5) return;
    node.style.translate_x = target;
    node.markCompositePropDirty();
}

fn navLensSnapToSlot(st: *NavLensState) void {
    const center = navSlotWorldCenter(st, st.slot) orelse {
        // rect 未就绪：驱动下一帧重试（idle 停帧下 before_render 不会自动再来）
        st.container.markRenderDirty();
        return;
    };
    navPlaceOnCenter(st.pill, center);
    if (!st.dragging) navPlaceOnCenter(st.lens, center);
}

fn navLensBeforeRender(node: *ui.Node) void {
    const raw = node.behavior.events.event_context orelse return;
    const st: *NavLensState = @ptrCast(@alignCast(raw));
    if (!st.dragging) navLensSnapToSlot(st);
}

fn navLensHandler(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
    if (context == null) return .ignored;
    const st: *NavLensState = @ptrCast(@alignCast(context.?));
    switch (event) {
        .mouse_enter => return .stop,
        .mouse_leave => return .stop,
        .mouse_down => |e| {
            st.dragging = true;
            st.start_x = e.x;
            st.base_tx = st.lens.style.translate_x;
            navLensSetMagnified(st, true);
            st.cx.setPointerCapture(st.lens);
            return .stop;
        },
        .mouse_move => |e| {
            if (st.dragging) {
                const lens_r = st.lens.rectFromWorldOrFallback();
                const cont_r = st.container.rectFromWorldOrFallback();
                const max_tx = @max(cont_r.w - lens_r.w, 0);
                st.lens.style.translate_x = std.math.clamp(st.base_tx + (e.x - st.start_x), 0, max_tx);
                st.lens.markCompositePropDirty();
                // 拖动中实时更新最近的 slot（松手吸附目标）
                const lens_center = st.lens.style.translate_x + lens_r.w / 2;
                var best: usize = st.slot;
                var best_d: f32 = std.math.floatMax(f32);
                const lens_world_center = st.lens.rectFromWorldOrFallback().x + st.lens.style.translate_x + lens_r.w / 2;
                _ = lens_center;
                for (0..NAV_ITEM_COUNT) |i| {
                    const c = navSlotWorldCenter(st, i) orelse continue;
                    const d = @abs(c - lens_world_center);
                    if (d < best_d) {
                        best_d = d;
                        best = i;
                    }
                }
                st.slot = best;
                navLensSnapToSlot(st); // pill 底座实时跟随最近 slot
                return .stop;
            }
        },
        .mouse_up => {
            if (st.dragging) {
                st.dragging = false;
                st.cx.releasePointerCapture();
                navLensSetMagnified(st, false);
                navLensSnapToSlot(st);
                return .stop;
            }
            return .ignored;
        },
        else => {},
    }
    return .ignored;
}

pub fn buildGlassBox(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const icons = ui.assets.common;
    const c = try col(cx, 20);

    // ── 1. Toolbar：分组玻璃 capsule（ToolbarSpacer 语义 = 两个独立 slab）──
    try c.appendChild(a, try label(cx, "Toolbar: grouped glass capsules (ToolbarSpacer splits slabs)"));
    {
        const bd = try glassBackdrop(cx, 130);
        const bar_row = try ui.box(cx, .{ .direction = .row, .gap = 12, .align_items = .center }, .{});
        const group1 = try glassCapsule(cx, 44, regularGlass());
        inline for (.{ icons.chevron_left, icons.chevron_right }) |asset| {
            try capsuleBody(group1).appendChild(a, try glassIconSlot(cx, asset));
        }
        const group2 = try glassCapsule(cx, 44, regularGlass());
        inline for (.{ icons.plus, icons.folder, icons.star }) |asset| {
            try capsuleBody(group2).appendChild(a, try glassIconSlot(cx, asset));
        }
        try bar_row.appendChild(a, group1);
        try bar_row.appendChild(a, group2);
        try bd.appendChild(a, bar_row);
        try c.appendChild(a, bd);
    }

    // ── 2. Tab bar：浮动 capsule + 独立 search 圆钮（Tab(role: .search)）──
    try c.appendChild(a, try label(cx, "Tab bar: floating capsule + detached search circle"));
    {
        const bd = try glassBackdrop(cx, 130);
        const bar_row = try ui.box(cx, .{ .direction = .row, .gap = 10, .align_items = .center }, .{});
        const tabbar = try glassCapsule(cx, 48, regularGlass());
        inline for (.{ "Today", "Library", "Radio" }, .{ icons.calendar, icons.folder_open, icons.scan }) |txt, asset| {
            const item = try ui.box(cx, .{ .direction = .row, .gap = 6, .align_items = .center, .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 } }, .{});
            var icon_style = ui.Style{};
            icon_style.width = .{ .px = 15 };
            icon_style.height = .{ .px = 15 };
            try item.appendChild(a, try ui.iconTint(cx, asset, ui.Color.rgba(255, 255, 255, 235), icon_style));
            try item.appendChild(a, try glassLabel(cx, txt, 550));
            try capsuleBody(tabbar).appendChild(a, item);
        }
        const search = try glassCapsule(cx, 48, regularGlass());
        try capsuleBody(search).appendChild(a, try glassIconSlot(cx, icons.search));
        try bar_row.appendChild(a, tabbar);
        try bar_row.appendChild(a, search);
        try bd.appendChild(a, bar_row);
        try c.appendChild(a, bd);
    }

    // ── 3. Buttons：.glass 与 .glassProminent（prominent = tinted glass）──
    try c.appendChild(a, try label(cx, "Buttons: .glass and .glassProminent (tinted)"));
    {
        const bd = try glassBackdrop(cx, 120);
        const btn_row = try ui.box(cx, .{ .direction = .row, .gap = 14, .align_items = .center }, .{});
        const plain = try glassCapsule(cx, 40, regularGlass());
        try capsuleBody(plain).appendChild(a, try glassLabel(cx, "Continue", 600));
        var prominent_params = regularGlass();
        prominent_params.glass_tint = ui.Color.rgba(0, 122, 255, 150);
        const prominent = try glassCapsule(cx, 40, prominent_params);
        capsuleBody(prominent).setBackgroundRaw(ui.Color.rgba(0, 122, 255, 90));
        try capsuleBody(prominent).appendChild(a, try glassLabel(cx, "Get", 650));
        var orange_params = regularGlass();
        orange_params.glass_tint = ui.Color.rgba(255, 149, 0, 150);
        const orange = try glassCapsule(cx, 40, orange_params);
        capsuleBody(orange).setBackgroundRaw(ui.Color.rgba(255, 149, 0, 90));
        try capsuleBody(orange).appendChild(a, try glassLabel(cx, "Tinted", 650));
        try btn_row.appendChild(a, plain);
        try btn_row.appendChild(a, prominent);
        try btn_row.appendChild(a, orange);
        try bd.appendChild(a, btn_row);
        try c.appendChild(a, bd);
    }

    // ── 4. GlassBox 面板：regular vs clear 变体 ──
    try c.appendChild(a, try label(cx, "GlassBox panel: .regular vs .clear (clear over 35% dimmed media)"));
    {
        const bd = try glassBackdrop(cx, 220);
        const pair = try ui.box(cx, .{ .direction = .row, .gap = 20, .align_items = .center }, .{});

        const regular_res = try W.GlassBox(.{ .title = "Regular", .subtitle = "adaptive, legible", .width = 240 }).mountBody(scope, cx);
        try regular_res.body.appendChild(a, try glassLabel(cx, "Functional layer content.", 450));
        try pair.appendChild(a, regular_res.box);

        // interactive：hover 提亮高光，press 玻璃增厚 + 微放大
        const inter_res = try W.GlassBox(.{ .title = "Interactive", .subtitle = "hover / press me", .width = 240, .interactive = true }).mountBody(scope, cx);
        try inter_res.body.appendChild(a, try glassLabel(cx, "Glass responds to touch.", 450));
        inter_res.box.meta.ownership.meta.test_id = "story.glassbox.interactive";
        try pair.appendChild(a, inter_res.box);

        // clear 变体：HIG 要求亮媒体上先叠 35% 黑色 dimming 层
        const dimmed = try ui.box(cx, .{
            .direction = .column,
            .padding = ui.Padding.all(10),
            .background = ui.Color.rgba(0, 0, 0, 89), // 35% dimming
        }, .{});
        (try dimmed.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(22);
        const clear_res = try W.GlassBox(.{ .title = "Clear", .subtitle = "media-rich backdrop", .width = 240, .variant = .clear }).mountBody(scope, cx);
        try clear_res.body.appendChild(a, try glassLabel(cx, "Backdrop shows through.", 450));
        try dimmed.appendChild(a, clear_res.box);
        try pair.appendChild(a, dimmed);

        try bd.appendChild(a, pair);
        try c.appendChild(a, bd);
    }

    // ── 5. Interactive motion：hover 抬升 / press 下沉 / 弹性回弹 ──
    try c.appendChild(a, try label(cx, "Interactive motion: hover lift, press sink, elastic release (geometry + material)"));
    {
        const bd = try glassBackdrop(cx, 240);
        const tile_row = try ui.box(cx, .{ .direction = .row, .gap = 20, .align_items = .center }, .{});
        try tile_row.appendChild(a, try glassMotionTile(scope, cx, "Lift", "ease-out rise", null, "story.glassbox.motion.lift"));
        try tile_row.appendChild(a, try glassMotionTile(scope, cx, "Tinted", "prominent blue", ui.Color.rgba(0, 122, 255, 150), "story.glassbox.motion.tinted"));
        try tile_row.appendChild(a, try glassMotionTile(scope, cx, "Elastic", "springy release", ui.Color.rgba(255, 149, 0, 150), "story.glassbox.motion.elastic"));
        try bd.appendChild(a, tile_row);
        try c.appendChild(a, bd);
    }

    // ── 6. Draggable glass：拖动玻璃观察实时折射 ──
    try c.appendChild(a, try label(cx, "Drag the glass: live refraction over the canvas"));
    {
        const bd = try glassBackdrop(cx, 260);
        const drag_node = try glassCapsule(cx, 56, regularGlass());
        drag_node.meta.ownership.meta.test_id = "story.glassbox.drag";
        drag_node.style.cursor = .pointer;
        const body = capsuleBody(drag_node);
        var icon_style = ui.Style{};
        icon_style.width = .{ .px = 18 };
        icon_style.height = .{ .px = 18 };
        try body.appendChild(a, try ui.iconTint(cx, ui.assets.common.mark, ui.Color.rgba(255, 255, 255, 235), icon_style));
        try body.appendChild(a, try glassLabel(cx, "Drag me", 650));

        const st = try a.create(GlassDragState);
        st.* = .{ .cx = cx, .target = drag_node };
        try scope.registerResource(@ptrCast(st), struct {
            fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const state: *GlassDragState = @ptrCast(@alignCast(ptr));
                alloc.destroy(state);
            }
        }.cleanup);
        drag_node.behavior.events.event_context = @ptrCast(st);
        drag_node.behavior.events.on_event = glassDragHandler;

        try bd.appendChild(a, drag_node);
        try c.appendChild(a, bd);
    }

    // ── 7. Floating nav toolbar：选中项盖 liquid glass lens，可拖拽 + 悬停放大 ──
    try c.appendChild(a, try label(cx, "Floating nav: draggable magnifying lens over the active item"));
    {
        const page = try ui.box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 200 },
            .align_items = .center,
            .justify = .center,
            .background = ui.Color.rgba(236, 231, 222, 255),
        }, .{});
        (try page.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(24);

        // 白色浮动 nav bar
        const bar_wrapper = try ui.box(cx, .{ .direction = .row, .position = .relative }, .{});
        const bar = try ui.box(cx, .{
            .direction = .row,
            .align_items = .center,
            .padding = .{ .left = 28, .right = 28, .top = 18, .bottom = 18 },
            .gap = 40,
            .background = ui.Color.rgba(255, 255, 255, 255),
        }, .{});
        const bar_ext = try bar.style.ensureExtFallible(a);
        bar_ext.corner_radius = ui.CornerRadius.uniform(44);
        bar_ext.setShadow(.{ .color = ui.Color.rgba(40, 36, 30, 30), .blur = 24, .offset_y = 10 });
        try bar_wrapper.appendChild(a, bar);

        // 灰色高亮底座：bar 第一个子节点（absolute），天然垫在 items 下面
        const pill = try ui.box(cx, .{
            .width = .{ .px = NAV_LENS_REST_W },
            .height = .{ .px = NAV_LENS_REST_H },
            .position = .absolute,
        }, .{});
        const pill_ext = try pill.style.ensureExtFallible(a);
        pill_ext.corner_radius = ui.CornerRadius.uniform(NAV_LENS_REST_H / 2);
        pill_ext.inset = .{ .top = .{ .px = 3 } };
        pill.setBackgroundRaw(ui.Color.rgba(228, 228, 231, 255));
        try bar.appendChild(a, pill);

        const icons2 = ui.assets.common;
        var item_nodes: [NAV_ITEM_COUNT]*ui.Node = undefined;
        inline for (.{ "Dashboard", "Explore", "Futures", "Rewards", "Exchange" }, .{ icons2.mark, icons2.search, icons2.file_text, icons2.star, icons2.link }, 0..) |txt, asset, i| {
            const item = try ui.box(cx, .{ .direction = .column, .align_items = .center, .gap = 6 }, .{});
            var icon_style = ui.Style{};
            icon_style.width = .{ .px = 22 };
            icon_style.height = .{ .px = 22 };
            try item.appendChild(a, try ui.iconTint(cx, asset, ui.Color.rgba(116, 122, 134, 255), icon_style));
            try item.appendChild(a, try ui.text(cx, txt, .{ .font_size = 15, .font_weight = 600, .color = ui.Color.rgba(28, 30, 36, 255) }));
            try bar.appendChild(a, item);
            item_nodes[i] = item;
        }

        // lens：绝对定位盖在 bar 上，上下出血
        const lens = try ui.box(cx, .{
            .width = .{ .px = NAV_LENS_REST_W },
            .height = .{ .px = NAV_LENS_REST_H },
            .position = .absolute,
        }, .{});
        const lens_ext = try lens.style.ensureExtFallible(a);
        lens_ext.inset = .{ .top = .{ .px = -4 } };
        lens_ext.corner_radius = ui.CornerRadius.uniform(NAV_LENS_REST_H / 2);
        // 静止态：lens 不画任何东西（命中区），玻璃只在按下时出现
        lens.style.cursor = .pointer;
        lens.meta.ownership.meta.test_id = "story.glassbox.navlens";
        try bar_wrapper.appendChild(a, lens);

        const st = try a.create(NavLensState);
        st.* = .{ .cx = cx, .lens = lens, .pill = pill, .bar = bar, .container = bar_wrapper, .items = item_nodes };
        try scope.registerResource(@ptrCast(st), struct {
            fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const state: *NavLensState = @ptrCast(@alignCast(ptr));
                alloc.destroy(state);
            }
        }.cleanup);
        lens.behavior.events.event_context = @ptrCast(st);
        lens.behavior.events.on_event = navLensHandler;
        // snap 挂在 in-flow 容器上（absolute 节点的 before_render 不保证执行）
        bar_wrapper.behavior.events.event_context = @ptrCast(st);
        bar_wrapper.addBeforeRender(navLensBeforeRender);

        try page.appendChild(a, bar_wrapper);
        try c.appendChild(a, page);
    }

    return c;
}

// ── GlassLab：可拖拽玻璃 + 全参数实时调节 ──

const LAB_PARAM_COUNT: usize = 17;

const LabParamSpec = struct {
    name: []const u8,
    min: f32,
    max: f32,
    step: f32,
    default: f32,
};

const LAB_SPECS = [LAB_PARAM_COUNT]LabParamSpec{
    .{ .name = "backdrop_blur", .min = 0, .max = 40, .step = 1, .default = 14 },
    .{ .name = "blur_level", .min = 0, .max = 1, .step = 0.05, .default = 0.55 },
    .{ .name = "refraction_level", .min = 0, .max = 1, .step = 0.05, .default = 1.0 },
    .{ .name = "warp_gain", .min = 0, .max = 3, .step = 0.1, .default = 2.4 },
    .{ .name = "center_thickness", .min = 0, .max = 20, .step = 0.5, .default = 13 },
    .{ .name = "bezel_width", .min = 0.04, .max = 0.45, .step = 0.01, .default = 0.34 },
    .{ .name = "edge_field_strength", .min = 0.2, .max = 4, .step = 0.1, .default = 3.2 },
    .{ .name = "magnification", .min = -1, .max = 2, .step = 0.02, .default = -0.06 },
    .{ .name = "scale_ratio", .min = 0.35, .max = 1.6, .step = 0.05, .default = 1.0 },
    .{ .name = "specular_opacity", .min = 0, .max = 1, .step = 0.02, .default = 0.4 },
    .{ .name = "glass_intensity", .min = 0, .max = 2, .step = 0.05, .default = 1.5 },
    .{ .name = "backdrop_distance", .min = 0, .max = 40, .step = 1, .default = 0 },
    .{ .name = "top_surface (0f 1c 2sq 3cc 4lip)", .min = 0, .max = 4, .step = 1, .default = 2 },
    .{ .name = "bottom_surface (0f 1c 2sq 3cc 4lip)", .min = 0, .max = 4, .step = 1, .default = 0 },
    .{ .name = "bottom_bezel_width", .min = 0.04, .max = 0.45, .step = 0.01, .default = 0.12 },
    .{ .name = "specular_angle (deg)", .min = -180, .max = 180, .step = 5, .default = -60 },
    .{ .name = "specular_saturation", .min = 1, .max = 12, .step = 0.5, .default = 7 },
};

const GlassLabState = struct {
    cx: *ui.Cx,
    glass: *ui.Node,
    section: *ui.Node,
    light_arrow: *ui.Node,
    sliders: [LAB_PARAM_COUNT]*W.slider.SliderState,
};

fn labSquircle(t: f32) f32 {
    const tt = std.math.clamp(t, 0, 1);
    const omt = 1.0 - tt;
    return std.math.pow(f32, @max(1.0 - omt * omt * omt * omt, 1e-6), 0.25);
}

fn labCircleH(t: f32) f32 {
    const omt = 1.0 - std.math.clamp(t, 0, 1);
    return std.math.sqrt(@max(1.0 - omt * omt, 0.0));
}

fn labSmoothstep(e0: f32, e1: f32, x: f32) f32 {
    const tt = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return tt * tt * (3.0 - 2.0 * tt);
}

/// 与 shader sample_surface 同构的高度轮廓（kind: 0 flat/1 circle/2 squircle/3 concave/4 lip）
fn labSurfaceH(kind: u8, t: f32) f32 {
    return switch (kind) {
        0 => 0.0,
        1 => labCircleH(t),
        3 => 1.0 - labSquircle(t),
        4 => blk: {
            const blend = labSmoothstep(0.18, 0.68, t);
            break :blk (1.0 - blend) * labCircleH(t) * 1.06 + blend * (1.0 - labSquircle(t)) * 1.18;
        },
        else => labSquircle(t),
    };
}

/// 镜片侧截面示意：底面平坦，顶面 = center_thickness 平台 + bezel 区 convex
/// squircle 过渡；backdrop_distance 抬高玻璃与底部背板线的间距。
fn labRebuildSection(st: *GlassLabState) void {
    const sw: f32 = 260;
    const sh: f32 = 130;
    const margin: f32 = 8;
    const ct = st.sliders[4].value; // center_thickness 0..20
    const bezel_ratio = st.sliders[5].value; // 0.04..0.45
    const gap = st.sliders[11].value; // backdrop_distance 0..40
    const top_kind: u8 = @intFromFloat(std.math.clamp(st.sliders[12].value, 0, 4));
    const bot_kind: u8 = @intFromFloat(std.math.clamp(st.sliders[13].value, 0, 4));
    const bot_bezel_ratio = st.sliders[14].value;

    const ct_disp = 6.0 + ct * 2.0;
    const bezel_px = @max(bezel_ratio * (sw / 2 - margin), 4.0);
    const bot_bezel_px = @max(bot_bezel_ratio * (sw / 2 - margin), 4.0);
    const amp_top = @min(bezel_px * 0.55, 40.0);
    const amp_bot = @min(bot_bezel_px * 0.5, 26.0);
    const base_y = sh - 22.0 - @min(gap * 0.55, 20.0) - amp_bot * 0.4;

    // 采样集中在 bezel 区（每边 6 点），中心平台只需端点，总点数 ≤32
    const edge_pts: usize = 6;
    var cmds: [34]ui.path.PathCommand = undefined;
    var n: usize = 0;
    const x_l = margin;
    const x_r = sw - margin;
    // 底面：左->右
    {
        var i: usize = 0;
        while (i <= edge_pts) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(edge_pts));
            const x = x_l + bot_bezel_px * t;
            const pt = ui.Point{ .x = x, .y = base_y + amp_bot * labSurfaceH(bot_kind, t) };
            cmds[n] = if (n == 0) .{ .move_to = pt } else .{ .line_to = pt };
            n += 1;
        }
        i = 0;
        while (i <= edge_pts) : (i += 1) {
            const t = 1.0 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(edge_pts));
            const x = x_r - bot_bezel_px * t;
            cmds[n] = .{ .line_to = .{ .x = x, .y = base_y + amp_bot * labSurfaceH(bot_kind, t) } };
            n += 1;
        }
    }
    // 顶面：右->左
    {
        var i: usize = 0;
        while (i <= edge_pts) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(edge_pts));
            const x = x_r - bezel_px * t;
            cmds[n] = .{ .line_to = .{ .x = x, .y = base_y - ct_disp - amp_top * labSurfaceH(top_kind, t) } };
            n += 1;
        }
        i = 0;
        while (i <= edge_pts) : (i += 1) {
            const t = 1.0 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(edge_pts));
            const x = x_l + bezel_px * t;
            cmds[n] = .{ .line_to = .{ .x = x, .y = base_y - ct_disp - amp_top * labSurfaceH(top_kind, t) } };
            n += 1;
        }
    }
    cmds[n] = .{ .close = {} };
    n += 1;
    st.section.setPathHitGeometry(st.cx.allocator, cmds[0..n], .nonzero) catch {};
    st.section.markRenderDirty();
}

// ── GlassEdge：glass 贴窗口边缘（黑边回归）──
//
// 回归目标：backdrop capture 的 pad 超出窗口 RT 的部分被清成透明黑，blur
// 混入后若 glass shader 不按 coverage（alpha）归一化，贴边的 glass 会晕出
// 一圈黑边（画布 app 左右 panel 实拍）。两块全高 panel 经 portal root 钉在
// 窗口最左/最右，左/右/上/下四条窗口边全部吃到 pad 越界 + clamp 路径。
// panel 是无 handler 的空 box：hit-test 默认穿透，不挡 sidebar 导航。
pub fn buildGlassEdge(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Glass panels flush with the window edges: edges must stay clean (no dark fringe)"));
    const portal = cx.popover_portal_root orelse return c;

    const overlay = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .row,
        .justify = .space_between,
    }, .{});
    overlay.meta.ownership.meta.test_id = "story.glassedge.overlay";

    inline for (.{ "left", "right" }) |side| {
        const panel = try ui.box(cx, .{
            .width = .{ .px = 240 },
            .height = .{ .grow = .{} },
            .background = ui.Color.rgba(255, 255, 255, 20),
            .border = .{ .width = 1, .color = ui.Color.rgba(255, 255, 255, 110), .radius = 16 },
        }, .{});
        const ext = try panel.style.ensureExtFallible(a);
        ext.corner_radius = ui.CornerRadius.uniform(16);
        ext.glass = regularGlass();
        panel.meta.ownership.meta.test_id = "story.glassedge." ++ side;
        try overlay.appendChild(a, panel);
    }
    try portal.appendChild(a, overlay);
    // portal 子树不在 story 面板子树里，必须随 story scope dispose 显式摘除,
    // 否则两块全高玻璃永久叠在后续所有 story 上（glassislands e2e 实拍抓到）。
    const Detach = struct { cx: *ui.Cx, portal: *ui.Node, overlay: *ui.Node };
    const d = try a.create(Detach);
    d.* = .{ .cx = cx, .portal = portal, .overlay = overlay };
    try scope.registerResource(@ptrCast(d), struct {
        fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const ctx: *Detach = @ptrCast(@alignCast(ptr));
            // 与 Show 卸载同款：detachChild + cx.freeNode（回收 ElementTable slot
            // + 走 tick_depth 延迟释放守卫），只 removeChild 会整棵泄漏（GPA 实拍）。
            ctx.cx.detachChild(ctx.portal, ctx.overlay);
            ctx.cx.freeNode(ctx.overlay);
            alloc.destroy(ctx);
        }
    }.cleanup);
    return c;
}

// ── GlassIslands：同帧两个 "blur + rounded_clip 同节点" 岛（下游应用回归）──
//
// 回归目标：一个节点同时挂 ext.glass(backdrop_blur) 与 overflow_hidden +
// corner_radius（effect 链 backdrop_blur -> rounded_clip，两个 requires_offscreen）
// 时，同帧存在两个这样的节点 -> 后画节点的内容整体不可见（内容命令没落进
// 自己的 layer 作用域，玻璃背板合成盖在其上）。下游应用 Sidebar+Inspector 实拍。
pub fn buildGlassIslands(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Two blur+rounded-clip islands: BOTH must show their content"));

    const bd = try glassBackdrop(cx, 420);
    // 高频黑白条纹靶压在 first 岛左边缘正下方（islands_row padding 24 -> 岛左缘
    // x=24）：gi=0 承诺"仅 blur"，blur(24) 把 8px 周期条纹平均成灰；rim 区若仍
    // sharp 回退（glass.metal rim_sharp 漏 gi 门控的回归），岛左缘 8px 带会清晰
    // 透出近黑条纹，e2e 按 rim/参照带 darkest pixel 差分断言。单条宽黑条不行：
    // 黑条自身 blur 后也偏暗，sharp/blur 只差 ~25 灰阶，抓不住变异。
    const rim_probe = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 32 },
        .height = .{ .grow = .{} },
        .direction = .row,
        .background = ui.Color.rgba(250, 250, 252, 255),
        .gap = 4,
    }, .{});
    (try rim_probe.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 10 }, .top = .{ .px = 0 } };
    for (0..4) |_| {
        try rim_probe.appendChild(a, try ui.box(cx, .{
            .width = .{ .px = 4 },
            .height = .{ .grow = .{} },
            .background = ui.Color.rgba(4, 4, 6, 255),
        }, .{}));
    }
    try bd.appendChild(a, rim_probe);
    const islands_row = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .direction = .row,
        .justify = .space_between,
        .padding = ui.Padding.all(24),
    }, .{});
    inline for (.{ "first", "second" }) |name| {
        const island = try ui.box(cx, .{
            .width = .{ .px = 220 },
            .height = .{ .px = 320 },
            .direction = .column,
            .gap = 10,
            .padding = ui.Padding.all(16),
            // alpha 40：底色再低一档，rim-band 像素断言需要黑条 sharp/blur 的
            // 对比窗口（96 时 37% 白把 sharp 黑抬到 ~160、blur ~190，抓不住回归）
            .background = ui.Color.rgba(255, 255, 255, 40),
            .border = .{ .width = 1, .color = ui.Color.rgba(255, 255, 255, 140), .radius = 12 },
            .overflow_hidden = true,
        }, .{});
        const ext = try island.style.ensureExtFallible(a);
        ext.corner_radius = ui.CornerRadius.uniform(12);
        ext.glass = .{ .backdrop_blur = 24, .glass_intensity = 0 };
        island.meta.ownership.meta.test_id = "story.glassislands." ++ name;

        try island.appendChild(a, try ui.text(cx, "Island " ++ name, .{
            .font_size = 15,
            .font_weight = 700,
            .color = ui.Color.rgba(20, 20, 28, 255),
        }));
        // 深色内容块：e2e 像素断言的靶（内容丢失 bug 下这里只剩白玻璃底）
        const slab = try ui.box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 120 },
            .background = ui.Color.rgba(24, 28, 40, 255),
        }, .{});
        (try slab.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(8);
        slab.meta.ownership.meta.test_id = "story.glassislands." ++ name ++ ".slab";
        try island.appendChild(a, slab);
        try island.appendChild(a, try ui.text(cx, "content below the slab", .{
            .font_size = 12,
            .color = ui.Color.rgba(40, 44, 56, 255),
        }));
        try islands_row.appendChild(a, island);
    }
    try bd.appendChild(a, islands_row);
    try c.appendChild(a, bd);
    return c;
}

fn labApply(ctx: *anyopaque) void {
    const st: *GlassLabState = @ptrCast(@alignCast(ctx));
    labRebuildSection(st);
    // 光向指示：与 specular_angle 同步旋转
    // ext 在 story 构造期已建好（同一节点此前设过 corner_radius/glass/inset），
    // 这里必然命中既有指针、不分配 -> 构造上不可能失败。本函数是 void 回调，无法传播。
    const arrow_ext = st.light_arrow.style.ensureExtFallible(st.cx.allocator) catch unreachable;
    arrow_ext.rotate = st.sliders[15].value * std.math.pi / 180.0;
    st.light_arrow.markCompositePropDirty();
    const v = st.sliders;
    // ext 在 story 构造期已建好（同一节点此前设过 corner_radius/glass/inset），
    // 这里必然命中既有指针、不分配 -> 构造上不可能失败。本函数是 void 回调，无法传播。
    const ext = st.glass.style.ensureExtFallible(st.cx.allocator) catch unreachable;
    ext.glass = .{
        .backdrop_blur = v[0].value,
        .blur_level = v[1].value,
        .refraction_level = v[2].value,
        .warp_gain = v[3].value,
        .center_thickness = v[4].value,
        .bezel_width = v[5].value,
        .edge_field_strength = v[6].value,
        .magnification = v[7].value,
        .scale_ratio = v[8].value,
        .specular_opacity = v[9].value,
        .glass_intensity = v[10].value,
        .backdrop_distance = v[11].value,
        .surface = @enumFromInt(@as(u8, @intFromFloat(std.math.clamp(v[12].value, 0, 4)))),
        .bottom_surface = @enumFromInt(@as(u8, @intFromFloat(std.math.clamp(v[13].value, 0, 4)))),
        .bottom_bezel_width = v[14].value,
        // 一个角度同时驱动：受光侧 specular/Fresnel 亮边 + 背光侧内阴影（对向联动）
        .specular_angle = v[15].value * std.math.pi / 180.0,
        .specular_saturation = v[16].value,
    };
    st.glass.markRenderDirty();
}

pub fn buildGlassLab(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);

    // ── 画布：网格背景 + 可拖拽玻璃 ──
    const bd = try glassBackdrop(cx, 300);
    const drag_node = try glassCapsule(cx, 116, .{});
    drag_node.meta.ownership.meta.test_id = "story.glasslab.drag";
    drag_node.style.cursor = .pointer;
    const body = capsuleBody(drag_node);
    body.style.padding = .{ .left = 34, .right = 34, .top = 0, .bottom = 0 };
    try body.appendChild(a, try glassLabel(cx, "Drag me", 650));

    const drag_st = try a.create(GlassDragState);
    drag_st.* = .{ .cx = cx, .target = drag_node };
    try scope.registerResource(@ptrCast(drag_st), struct {
        fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const state: *GlassDragState = @ptrCast(@alignCast(ptr));
            alloc.destroy(state);
        }
    }.cleanup);
    drag_node.behavior.events.event_context = @ptrCast(drag_st);
    drag_node.behavior.events.on_event = glassDragHandler;
    try bd.appendChild(a, drag_node);
    try c.appendChild(a, bd);

    // ── 参数面板：两列滑杆 ──
    const st = try a.create(GlassLabState);
    st.cx = cx;
    st.glass = capsuleBody(drag_node);
    st.section = undefined;
    st.light_arrow = undefined;
    try scope.registerResource(@ptrCast(st), struct {
        fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const state: *GlassLabState = @ptrCast(@alignCast(ptr));
            alloc.destroy(state);
        }
    }.cleanup);

    const panel = try ui.box(cx, .{ .direction = .row, .gap = 16 }, .{});
    var columns: [2]*ui.Node = undefined;
    for (0..2) |i| {
        columns[i] = try ui.box(cx, .{ .direction = .column, .gap = 10 }, .{});
        try panel.appendChild(a, columns[i]);
    }

    // ── 镜片侧截面示意（实时跟随 thickness/bezel/distance）──
    const section_col = try ui.box(cx, .{ .direction = .column, .gap = 6 }, .{});
    try section_col.appendChild(a, try label(cx, "lens cross-section"));
    const section_frame = try ui.box(cx, .{
        .width = .{ .px = 260 },
        .height = .{ .px = 130 },
        .position = .relative,
        .background = ui.Color.rgba(244, 246, 250, 255),
        .border = .{ .width = 1, .color = ui.Color.rgba(210, 214, 224, 255), .radius = 10 },
    }, .{});
    (try section_frame.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(10);
    // 底部背板线（玻璃悬浮参照）
    const backdrop_line = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 2 },
        .position = .absolute,
        .background = ui.Color.rgba(150, 158, 172, 255),
    }, .{});
    (try backdrop_line.style.ensureExtFallible(a)).inset = .{ .top = .{ .px = 114 } };
    try section_frame.appendChild(a, backdrop_line);
    // 玻璃截面本体（path 填充）
    const section = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .position = .absolute,
        .background = ui.Color.rgba(120, 168, 255, 150),
    }, .{});
    try section_frame.appendChild(a, section);
    // 光向指示箭头（右上角，绕中心旋转）
    const arrow = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 3 },
        .position = .absolute,
        .background = ui.Color.rgba(240, 170, 40, 255),
    }, .{});
    const arrow_ext0 = try arrow.style.ensureExtFallible(a);
    arrow_ext0.inset = .{ .top = .{ .px = 16 }, .left = .{ .px = 216 } };
    arrow_ext0.corner_radius = ui.CornerRadius.uniform(1.5);
    try section_frame.appendChild(a, arrow);
    try section_col.appendChild(a, section_frame);
    try panel.appendChild(a, section_col);
    inline for (LAB_SPECS, 0..) |spec, i| {
        const prow = try ui.box(cx, .{ .direction = .column, .gap = 2 }, .{});
        try prow.appendChild(a, try ui.text(cx, spec.name, .{ .font_size = 12, .color = light.color.fg_secondary }));
        const sl = try W.Slider(.{
            .min = spec.min,
            .max = spec.max,
            .step = spec.step,
            .initial_value = spec.default,
            .width = 200,
            .show_value = true,
            .on_change = .{ .callback = labApply, .context = @ptrCast(st) },
        }).mount(scope, cx);
        st.sliders[i] = sl.state;
        try prow.appendChild(a, sl.wrapper);
        try columns[i % 2].appendChild(a, prow);
    }
    st.section = section;
    st.light_arrow = arrow;
    try c.appendChild(a, panel);

    labApply(@ptrCast(st));
    return c;
}

// ── Stack (VStack / HStack) ──
pub fn buildStack(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);
    try c.appendChild(a, try label(cx, "HStack gap=8"));
    const h = try W.HStack(.{ .gap = 8 }).mount(scope, cx);
    inline for (.{ "A", "B", "C" }) |t| {
        try h.appendChild(a, try W.Button(.{ .label = t, .variant = .secondary }).mount(scope, cx));
    }
    try c.appendChild(a, h);
    try c.appendChild(a, try label(cx, "VStack gap=8"));
    const v = try W.VStack(.{ .gap = 8 }).mount(scope, cx);
    inline for (.{ "First", "Second", "Third" }) |t| {
        try v.appendChild(a, try W.Tag(.{ .text = t }).mount(scope, cx));
    }
    try c.appendChild(a, v);
    return c;
}

// ── Layout / Box Model ──
//
// 这不是装饰性 demo，而是布局引擎的可视化规范页。固定尺寸和稳定 test_id
// 让人工截图与 Harness 几何断言共享同一棵树，覆盖 CSS padding-box absolute
// containing block、Flex/Grid out-of-flow、尺寸模式、margin/gap 和 overflow。
const layout_col = struct {
    const surface = ui.Color.rgba(248, 250, 252, 255);
    const line = ui.Color.rgba(148, 163, 184, 255);
    const padding = ui.Color.rgba(254, 243, 199, 255);
    const content = ui.Color.rgba(219, 234, 254, 255);
    const flow = ui.Color.rgba(37, 99, 235, 255);
    const flow_alt = ui.Color.rgba(14, 116, 144, 255);
    const absolute = ui.Color.rgba(225, 29, 72, 255);
    const stretch = ui.Color.rgba(22, 163, 74, 210);
    const guide = ui.Color.rgba(100, 116, 139, 150);
    const ink_on_color = ui.Color.rgba(255, 255, 255, 255);
};

fn layoutSection(cx: *ui.Cx, title: []const u8, detail: []const u8) !*ui.Node {
    const section = try col(cx, 3);
    try section.appendChild(cx.allocator, try ui.text(cx, title, .{
        .font_size = 15,
        .font_weight = 700,
        .color = light.color.fg_primary,
    }));
    try section.appendChild(cx.allocator, try ui.text(cx, detail, .{
        .font_size = 12,
        .color = light.color.fg_secondary,
    }));
    return section;
}

fn layoutBadge(cx: *ui.Cx, txt: []const u8, width: f32, height: f32, bg: ui.Color) !*ui.Node {
    const node = try ui.box(cx, .{
        .width = .{ .px = width },
        .height = .{ .px = height },
        .justify = .center,
        .align_items = .center,
        .background = bg,
        .border = .{ .radius = 5 },
    }, .{});
    try node.appendChild(cx.allocator, try ui.text(cx, txt, .{
        .font_size = 11,
        .font_weight = 650,
        .color = layout_col.ink_on_color,
    }));
    return node;
}

fn layoutArena(cx: *ui.Cx, width: f32, height: f32, padding: Padding) !*ui.Node {
    return ui.box(cx, .{
        .width = .{ .px = width },
        .height = .{ .px = height },
        .position = .relative,
        .padding = padding,
        .background = layout_col.padding,
        .border = .{ .width = 1, .color = layout_col.line, .radius = 8 },
        .overflow_hidden = true,
    }, .{});
}

pub fn buildLayoutBoxModel(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 22);
    c.style.width = .{ .px = 720 };

    // 覆盖矩阵先写在页首，截图本身即可充当人工验收 checklist。
    const coverage = try ui.box(cx, .{
        .width = .{ .px = 700 },
        .direction = .column,
        .gap = 4,
        .padding = Padding.all(14),
        .background = layout_col.surface,
        .border = .{ .width = 1, .color = layout_col.line, .radius = 8 },
    }, .{});
    try coverage.appendChild(a, try ui.text(cx, "Coverage matrix", .{
        .font_size = 13,
        .font_weight = 700,
        .color = light.color.fg_primary,
    }));
    try coverage.appendChild(a, try label(cx, "padding / border / content · px / fit / percent / grow · margin / gap"));
    try coverage.appendChild(a, try label(cx, "row / justify / align · Grid px + fr · absolute inset / percent / stretch · overflow clip"));
    try c.appendChild(a, coverage);

    // 1) CSS padding-box anatomy. Parent 700×180, asymmetric padding
    // L32/R44/T28/B20. Absolute right:0/bottom:0 must touch the padding edge
    // (Zenit 的 border 为 paint-only，所以该 edge 与本地 rect edge 重合)。
    try c.appendChild(a, try layoutSection(cx, "1. Padding-box anatomy + absolute edges", "amber = padding box · blue = content box · red = right:0 / bottom:0 · navy = content edge"));
    const anatomy = try layoutArena(cx, 700, 180, .{ .left = 32, .right = 44, .top = 28, .bottom = 20 });
    anatomy.meta.ownership.meta.test_id = "story.layoutbox.absolute.parent";

    const content_guide = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .justify = .center,
        .align_items = .center,
        .background = layout_col.content,
        .border = .{ .width = 1, .color = ui.Color.rgba(96, 165, 250, 255), .radius = 4 },
    }, .{});
    (try content_guide.style.ensureExtFallible(a)).inset = .{
        .left = .{ .px = 32 },
        .right = .{ .px = 44 },
        .top = .{ .px = 28 },
        .bottom = .{ .px = 20 },
    };
    content_guide.meta.ownership.meta.test_id = "story.layoutbox.absolute.content-guide";
    try content_guide.appendChild(a, try ui.text(cx, "content 624 × 132", .{
        .font_size = 12,
        .font_weight = 650,
        .color = ui.Color.rgba(30, 64, 175, 255),
    }));
    try anatomy.appendChild(a, content_guide);

    const origin = try layoutBadge(cx, "0,0", 38, 26, layout_col.stretch);
    origin.style.position = .absolute;
    (try origin.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    origin.meta.ownership.meta.test_id = "story.layoutbox.absolute.origin";
    try anatomy.appendChild(a, origin);

    const outer_edge = try layoutBadge(cx, "edge", 44, 30, layout_col.absolute);
    outer_edge.style.position = .absolute;
    (try outer_edge.style.ensureExtFallible(a)).inset = .{ .right = .{ .px = 0 }, .bottom = .{ .px = 0 } };
    outer_edge.meta.ownership.meta.test_id = "story.layoutbox.absolute.outer-edge";
    try anatomy.appendChild(a, outer_edge);

    const content_edge = try layoutBadge(cx, "content", 58, 30, layout_col.flow);
    content_edge.style.position = .absolute;
    (try content_edge.style.ensureExtFallible(a)).inset = .{ .right = .{ .px = 44 }, .bottom = .{ .px = 20 } };
    content_edge.meta.ownership.meta.test_id = "story.layoutbox.absolute.content-edge";
    try anatomy.appendChild(a, content_edge);
    try c.appendChild(a, anatomy);
    try c.appendChild(a, try label(cx, "Expected: content=(32,28 624×132), red right/bottom gap=0, navy right gap=44 bottom gap=20"));

    // 2) Percentage resolution and double-sided grow stretch.
    try c.appendChild(a, try layoutSection(cx, "2. Percentage inset + double-sided stretch", "Percentages resolve against the full padding box; left+right/top+bottom constrain grow size."));
    const inset_row = try row(cx, 16);

    const percent_col = try col(cx, 6);
    try percent_col.appendChild(a, try label(cx, "left:25% · top:50% → (85.5, 75)"));
    const percent_parent = try layoutArena(cx, 342, 150, Padding.all(20));
    percent_parent.meta.ownership.meta.test_id = "story.layoutbox.percent.parent";
    const vguide = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = 1 },
        .height = .{ .grow = .{} },
        .background = layout_col.guide,
    }, .{});
    (try vguide.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 85.5 } };
    try percent_parent.appendChild(a, vguide);
    const hguide = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .px = 1 },
        .background = layout_col.guide,
    }, .{});
    (try hguide.style.ensureExtFallible(a)).inset = .{ .top = .{ .px = 75 } };
    try percent_parent.appendChild(a, hguide);
    const percent_marker = try layoutBadge(cx, "25/50", 52, 28, layout_col.absolute);
    percent_marker.style.position = .absolute;
    (try percent_marker.style.ensureExtFallible(a)).inset = .{
        .left = .{ .percent = 25 },
        .top = .{ .percent = 50 },
    };
    percent_marker.meta.ownership.meta.test_id = "story.layoutbox.percent.marker";
    try percent_parent.appendChild(a, percent_marker);
    try percent_col.appendChild(a, percent_parent);
    try inset_row.appendChild(a, percent_col);

    const stretch_col = try col(cx, 6);
    try stretch_col.appendChild(a, try label(cx, "L14 / R22 / T18 / B12 + grow"));
    const stretch_parent = try layoutArena(cx, 342, 150, .{ .left = 26, .right = 12, .top = 10, .bottom = 22 });
    stretch_parent.meta.ownership.meta.test_id = "story.layoutbox.stretch.parent";
    const stretch_child = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .justify = .center,
        .align_items = .center,
        .background = layout_col.stretch,
        .border = .{ .radius = 5 },
    }, .{});
    (try stretch_child.style.ensureExtFallible(a)).inset = .{
        .left = .{ .px = 14 },
        .right = .{ .px = 22 },
        .top = .{ .px = 18 },
        .bottom = .{ .px = 12 },
    };
    stretch_child.meta.ownership.meta.test_id = "story.layoutbox.stretch.child";
    try stretch_child.appendChild(a, try ui.text(cx, "306 × 120", .{
        .font_size = 12,
        .font_weight = 650,
        .color = layout_col.ink_on_color,
    }));
    try stretch_parent.appendChild(a, stretch_child);
    try stretch_col.appendChild(a, stretch_parent);
    try inset_row.appendChild(a, stretch_col);
    try c.appendChild(a, inset_row);

    // 3) Flex and Grid both keep absolute children out of normal placement,
    // while using the same padding-box containing block for inset resolution.
    try c.appendChild(a, try layoutSection(cx, "3. Flex vs Grid: in-flow content and out-of-flow absolute", "Flow items start at padding.left; the red absolute marker consumes no gap, track, or flex space."));
    const engines = try row(cx, 16);

    const flex_col = try col(cx, 6);
    try flex_col.appendChild(a, try label(cx, "Flex row · padding 20 · gap 12 · margins on B"));
    const flex_parent = try layoutArena(cx, 342, 170, Padding.all(20));
    flex_parent.style.direction = .row;
    flex_parent.style.gap = 12;
    flex_parent.style.align_items = .center;
    flex_parent.meta.ownership.meta.test_id = "story.layoutbox.flex.parent";
    const flow_a = try layoutBadge(cx, "A 64", 64, 56, layout_col.flow);
    flow_a.meta.ownership.meta.test_id = "story.layoutbox.flex.a";
    try flex_parent.appendChild(a, flow_a);
    const flow_b = try layoutBadge(cx, "B +m", 64, 56, layout_col.flow_alt);
    flow_b.style.margin = .{ .left = 8, .right = 6, .top = 0, .bottom = 0 };
    flow_b.meta.ownership.meta.test_id = "story.layoutbox.flex.b";
    try flex_parent.appendChild(a, flow_b);
    const flow_grow = try layoutBadge(cx, "grow", 10, 56, ui.Color.rgba(124, 58, 237, 255));
    flow_grow.style.width = .{ .grow = .{} };
    flow_grow.style.margin.right = 10;
    flow_grow.meta.ownership.meta.test_id = "story.layoutbox.flex.grow";
    try flex_parent.appendChild(a, flow_grow);
    const flex_abs = try layoutBadge(cx, "abs", 34, 34, layout_col.absolute);
    flex_abs.style.position = .absolute;
    (try flex_abs.style.ensureExtFallible(a)).inset = .{ .right = .{ .px = 0 }, .top = .{ .px = 0 } };
    flex_abs.meta.ownership.meta.test_id = "story.layoutbox.flex.absolute";
    try flex_parent.appendChild(a, flex_abs);
    try flex_col.appendChild(a, flex_parent);
    try engines.appendChild(a, flex_col);

    const grid_col = try col(cx, 6);
    try grid_col.appendChild(a, try label(cx, "Grid · 70px / 1fr / 2fr · gap 8"));
    const grid_a = try layoutBadge(cx, "70px", 10, 52, layout_col.flow);
    grid_a.style.width = .{ .grow = .{} };
    grid_a.meta.ownership.meta.test_id = "story.layoutbox.grid.a";
    const grid_b = try layoutBadge(cx, "1fr", 10, 52, layout_col.flow_alt);
    grid_b.style.width = .{ .grow = .{} };
    grid_b.meta.ownership.meta.test_id = "story.layoutbox.grid.b";
    const grid_c = try layoutBadge(cx, "2fr", 10, 52, ui.Color.rgba(124, 58, 237, 255));
    grid_c.style.width = .{ .grow = .{} };
    grid_c.meta.ownership.meta.test_id = "story.layoutbox.grid.c";
    const grid_abs = try layoutBadge(cx, "abs", 34, 34, layout_col.absolute);
    grid_abs.style.position = .absolute;
    (try grid_abs.style.ensureExtFallible(a)).inset = .{ .right = .{ .px = 0 }, .bottom = .{ .px = 0 } };
    grid_abs.meta.ownership.meta.test_id = "story.layoutbox.grid.absolute";
    const grid_parent = try ui.grid(cx, .{
        .columns = &.{ .{ .px = 70 }, .{ .fr = 1 }, .{ .fr = 2 } },
        .rows = &.{.{ .px = 52 }},
        .column_gap = 8,
        .width = .{ .px = 342 },
        .height = .{ .px = 170 },
        .padding = Padding.all(20),
        .background = layout_col.padding,
        .border = .{ .width = 1, .color = layout_col.line, .radius = 8 },
        .align_items = .center,
    }, .{ grid_a, grid_b, grid_c, grid_abs });
    grid_parent.meta.ownership.meta.test_id = "story.layoutbox.grid.parent";
    try grid_col.appendChild(a, grid_parent);
    try engines.appendChild(a, grid_col);
    try c.appendChild(a, engines);

    // 4) Sizing modes share the parent's content width, while the parent still
    // owns padding. This row makes px/percent/fit/grow contributions visible.
    try c.appendChild(a, try layoutSection(cx, "4. Sizing modes inside one Flex row", "Parent 700 wide, padding 20 → content 660. The 20% item is 132 wide; grow receives the remainder."));
    const sizing_parent = try ui.box(cx, .{
        .width = .{ .px = 700 },
        .height = .{ .px = 100 },
        .direction = .row,
        .align_items = .center,
        .gap = 10,
        .padding = Padding.all(20),
        .background = layout_col.content,
        .border = .{ .width = 1, .color = layout_col.line, .radius = 8 },
    }, .{});
    sizing_parent.meta.ownership.meta.test_id = "story.layoutbox.sizing.parent";
    const sizing_px = try layoutBadge(cx, "px 80", 80, 44, layout_col.flow);
    sizing_px.meta.ownership.meta.test_id = "story.layoutbox.sizing.px";
    try sizing_parent.appendChild(a, sizing_px);
    const sizing_percent = try layoutBadge(cx, "20%", 10, 44, layout_col.flow_alt);
    sizing_percent.style.width = .{ .percent = 20 };
    sizing_percent.meta.ownership.meta.test_id = "story.layoutbox.sizing.percent";
    try sizing_parent.appendChild(a, sizing_percent);
    const sizing_fit = try layoutBadge(cx, "fit content", 10, 44, ui.Color.rgba(124, 58, 237, 255));
    sizing_fit.style.width = .{ .fit = .{} };
    sizing_fit.meta.ownership.meta.test_id = "story.layoutbox.sizing.fit";
    try sizing_parent.appendChild(a, sizing_fit);
    const sizing_grow = try layoutBadge(cx, "grow", 10, 44, layout_col.stretch);
    sizing_grow.style.width = .{ .grow = .{} };
    sizing_grow.meta.ownership.meta.test_id = "story.layoutbox.sizing.grow";
    try sizing_parent.appendChild(a, sizing_grow);
    try c.appendChild(a, sizing_parent);

    // 5) Main-axis distribution and cross-axis alignment. Each sample uses the
    // same content width, so start/center/end drift is immediately visible.
    try c.appendChild(a, try layoutSection(cx, "5. Flex distribution: justify + align + gap", "Three identical 220×92 parents; only justify changes. Cross axis stays centered."));
    const justify_row = try row(cx, 16);
    inline for (.{ ui.JustifyContent.start, .center, .end }, .{ "start", "center", "end" }) |justify, name| {
        const sample_col = try col(cx, 5);
        try sample_col.appendChild(a, try label(cx, name));
        const sample = try ui.box(cx, .{
            .width = .{ .px = 220 },
            .height = .{ .px = 92 },
            .direction = .row,
            .justify = justify,
            .align_items = .center,
            .gap = 8,
            .padding = Padding.all(12),
            .background = layout_col.content,
            .border = .{ .width = 1, .color = layout_col.line, .radius = 8 },
        }, .{});
        try sample.appendChild(a, try layoutBadge(cx, "1", 36, 30, layout_col.flow));
        try sample.appendChild(a, try layoutBadge(cx, "2", 36, 30, layout_col.flow_alt));
        try sample_col.appendChild(a, sample);
        try justify_row.appendChild(a, sample_col);
    }
    try c.appendChild(a, justify_row);

    // 6) Overflow is part of the box model contract. Same overflowing absolute
    // child in both arenas; only the left parent clips at its padding-box edge.
    try c.appendChild(a, try layoutSection(cx, "6. Overflow clipping", "The rose block starts at (280,55), size 100×60. Left clips; right remains visible."));
    const overflow_row = try row(cx, 16);
    inline for (.{ true, false }, .{ "overflow_hidden", "overflow_visible" }) |clipped, name| {
        const sample_col = try col(cx, 5);
        try sample_col.appendChild(a, try label(cx, name));
        const sample = try ui.box(cx, .{
            .width = .{ .px = 342 },
            .height = .{ .px = 110 },
            .position = .relative,
            .padding = Padding.all(12),
            .background = layout_col.surface,
            .border = .{ .width = 1, .color = layout_col.line, .radius = 8 },
            .overflow_hidden = clipped,
        }, .{});
        const overflow_child = try layoutBadge(cx, "100 × 60", 100, 60, layout_col.absolute);
        overflow_child.style.position = .absolute;
        (try overflow_child.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 280 }, .top = .{ .px = 55 } };
        try sample.appendChild(a, overflow_child);
        try sample_col.appendChild(a, sample);
        try overflow_row.appendChild(a, sample_col);
    }
    try c.appendChild(a, overflow_row);

    return c;
}

// ── Tabs ──
/// Tabs 的选中态回显，e2e 要断言「点了就真的切过去」，需要一个可观测的出口。
/// 组件本身不渲染"当前选中是谁"，所以 story 把 on_change 的 payload 打到一行
/// 文本上（同 CheckboxStory 的做法）。
const TabsStory = struct {
    status: *ui.Node,
    buf: [64]u8 = undefined,

    fn onChange(self: *TabsStory, tab_id: []const u8) void {
        const txt = std.fmt.bufPrint(&self.buf, "active → {s}", .{tab_id}) catch return;
        if (self.status.getText()) |old| {
            var t = old;
            t.content = txt;
            // txt 指向 self.buf（非堆 owned），必须清 owned/inline_len，
            // 否则 Node.destroy 会 free(non-heap)。同 CheckboxStory。
            t.owned = false;
            t.inline_len = 0;
            self.status.setText(t);
        }
        self.status.markRenderDirty();
    }
};

pub fn buildTabs(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);
    const items = [_]W.tabs.TabItem{
        .{ .id = "t1", .label_text = "Overview" },
        .{ .id = "t2", .label_text = "Details" },
        .{ .id = "t3", .label_text = "Settings", .badge = 3 },
        .{ .id = "t4", .label_text = "Disabled", .disabled = true },
    };

    const status = try ui.text(cx, "active → (none)", .{ .font_size = 13, .color = light.color.fg_secondary });
    status.meta.ownership.meta.test_id = "story.tabs.status";
    try c.appendChild(a, status);
    const story = try cx.bindState(TabsStory, .{ .status = status });

    // ── 变体 ──
    inline for (.{ W.tabs.TabsVariant.underline, .pill, .tab }, .{ "underline", "pill", "tab" }) |variant, name| {
        try c.appendChild(a, try label(cx, name));
        const tabs_node = try W.Tabs(.{
            .items = &items,
            .variant = variant,
            .on_change = ui.Cx.strHandlerFrom(TabsStory, story, TabsStory.onChange),
        }).mount(scope, cx);
        if (variant == .underline) tabs_node.meta.ownership.meta.test_id = "story.tabs.underline";
        try c.appendChild(a, tabs_node);
    }

    // ── 尺寸 ──
    const size_items = [_]W.tabs.TabItem{
        .{ .id = "a", .label_text = "One" },
        .{ .id = "b", .label_text = "Two" },
        .{ .id = "c", .label_text = "Three" },
    };
    try c.appendChild(a, try label(cx, "Sizes (xs / sm / md / lg)"));
    inline for (.{ W.tabs.TabsSize.xs, .sm, .md, .lg }) |sz| {
        try c.appendChild(a, try W.Tabs(.{ .items = &size_items, .variant = .pill, .size = sz }).mount(scope, cx));
    }
    return c;
}

// ── Accordion ──
pub fn buildAccordion(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const acc = try W.Accordion(.{ .exclusive = false, .gap = 8 }).mount(scope, cx);
    inline for (.{ "Section One", "Section Two", "Section Three" }, 0..) |title, i| {
        const item = try W.AccordionItem(.{ .title = title, .expanded = (i == 0) }).mount(scope, cx);
        try item.body.appendChild(a, try ui.text(cx, "Panel body content.", .{ .font_size = 13, .color = light.color.fg_secondary }));
        try acc.container.appendChild(a, item.item);
    }
    return acc.container;
}

// ── Menu（trigger+popover：item 在弹层里，story 给 trigger 加按钮，e2e 点开验 item）──
pub fn buildMenu(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 8);
    try c.appendChild(a, try label(cx, "Click the trigger to open the menu"));
    const items = [_]W.MenuItem{
        .{ .id = "cut", .label_text = "Cut", .shortcut = "⌘X" },
        .{ .id = "copy", .label_text = "Copy", .shortcut = "⌘C" },
        .{ .id = "sep", .kind = .separator },
        .{ .id = "del", .label_text = "Delete", .danger = true },
    };
    const m = try W.Menu(.{ .items = &items }).mount(scope, cx);
    // 给 trigger 放一个有标签的按钮，让 story 可见可点
    try m.trigger.appendChild(a, try W.Button(.{ .label = "Actions ▾", .variant = .secondary }).mount(scope, cx));
    m.wrapper.meta.ownership.meta.test_id = "story.menu.trigger";
    try c.appendChild(a, m.wrapper);
    return c;
}

// ── DropdownMenu（同 Menu：trigger+popover）──
pub fn buildDropdownMenu(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 8);
    try c.appendChild(a, try label(cx, "Click the trigger to open the dropdown"));
    const items = [_]W.DropdownItem{
        .{ .id = "new", .label_text = "New File" },
        .{ .id = "open", .label_text = "Open…" },
        .{ .id = "sep", .kind = .separator },
        .{ .id = "save", .label_text = "Save" },
    };
    const dm = try W.DropdownMenu(.{ .items = &items }).mount(scope, cx);
    try dm.trigger.appendChild(a, try W.Button(.{ .label = "File ▾", .variant = .secondary }).mount(scope, cx));
    dm.wrapper.meta.ownership.meta.test_id = "story.dropdown.trigger";
    try c.appendChild(a, dm.wrapper);
    return c;
}

// ── Steps ──
pub fn buildSteps(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const icons = ui.assets.common;
    const c = try col(cx, 24);
    const items = [_]W.StepItem{
        .{ .title = "Account", .description = "Create account" },
        .{ .title = "Profile", .description = "Fill details" },
        .{ .title = "Done", .description = "Finish" },
    };

    // 水平：completed step 用真实 check 图标（不传 check_icon_asset 时回退成 "v" 字符不美观）
    try c.appendChild(a, try label(cx, "Horizontal (step 2 active)"));
    try c.appendChild(a, try W.Steps(.{ .items = &items, .initial_current = 1, .check_icon_asset = icons.check }).mount(scope, cx));

    // 垂直
    try c.appendChild(a, try label(cx, "Vertical"));
    try c.appendChild(a, try W.Steps(.{ .items = &items, .initial_current = 2, .direction = .vertical, .check_icon_asset = icons.check }).mount(scope, cx));
    return c;
}

// ── Rate ──
pub fn buildRate(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);
    const r1 = try W.Rate(.{ .count = 5, .value = 3 }).mount(scope, cx);
    try c.appendChild(a, try label(cx, "value 3 / 5"));
    try c.appendChild(a, r1.wrapper);
    const r2 = try W.Rate(.{ .count = 5, .value = 4, .disabled = true }).mount(scope, cx);
    try c.appendChild(a, try label(cx, "readonly value 4"));
    try c.appendChild(a, r2.wrapper);

    // ── count 变体 ──
    const r3 = try W.Rate(.{ .count = 10, .value = 7 }).mount(scope, cx);
    try c.appendChild(a, try label(cx, "count 10, value 7"));
    try c.appendChild(a, r3.wrapper);

    // ── size 变体 ──
    try c.appendChild(a, try label(cx, "Sizes (16 / 24 / 36)"));
    const sizes_row = try row(cx, 24);
    inline for (.{ 16, 24, 36 }) |sz| {
        const rn = try W.Rate(.{ .count = 5, .value = 3, .size = @as(f32, sz) }).mount(scope, cx);
        try sizes_row.appendChild(a, rn.wrapper);
    }
    try c.appendChild(a, sizes_row);
    return c;
}

// ── Tree ──
pub fn buildTree(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const leaves = [_]W.TreeNodeData{
        .{ .id = "main", .label_text = "main.zig" },
        .{ .id = "root", .label_text = "root.zig" },
    };
    const nodes = [_]W.TreeNodeData{
        .{ .id = "src", .label_text = "src", .children = &leaves },
        .{ .id = "readme", .label_text = "README.md" },
    };
    const t = try W.Tree(.{ .nodes = &nodes }).mount(scope, cx);
    return t.wrapper;
}

// ── Table ──
const TABLE_NAMES = [_][]const u8{ "Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace", "Heidi" };
const TABLE_ROLES = [_][]const u8{ "Admin", "User", "User", "Editor", "User", "Admin", "Editor", "User" };
fn tableCell(cell: *ui.Node, row_i: usize, col_i: usize, c: *ui.Cx) void {
    var buf: [16]u8 = undefined;
    const txt: []const u8 = switch (col_i) {
        0 => TABLE_NAMES[row_i % TABLE_NAMES.len],
        1 => TABLE_ROLES[row_i % TABLE_ROLES.len],
        else => std.fmt.bufPrint(&buf, "{d}", .{20 + row_i * 3}) catch "?",
    };
    const child = ui.text(c, txt, .{ .font_size = 13, .color = light.color.fg_primary }) catch return;
    cell.appendChild(c.allocator, child) catch {};
}
pub fn buildTable(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const cols = [_]W.ColumnDef{
        .{ .id = "name", .header = "Name", .width = 160 },
        .{ .id = "role", .header = "Role", .width = 120 },
        .{ .id = "age", .header = "Age", .width = 80, .sortable = true },
    };
    const t = try W.Table(.{ .columns = &cols, .row_count = 8, .striped = true, .render_cell = tableCell }).mount(scope, cx);
    return t.wrapper;
}

// ── Calendar ──
pub fn buildCalendar(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const cal = try W.Calendar(.{ .initial_year = 2026, .initial_month = 5 }).mount(scope, cx);
    return cal.wrapper;
}

// ── DatePicker ──
pub fn buildDatePicker(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const dp = try W.DatePicker(.{ .placeholder = "Pick a date", .initial_year = 2026, .initial_month = 5 }).mount(scope, cx);
    return dp.wrapper;
}

// ── DateRangePicker ──
pub fn buildDateRangePicker(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const drp = try W.DateRangePicker(.{ .initial_year = 2026, .initial_month = 5 }).mount(scope, cx);
    return drp.wrapper;
}

// ── Tooltip ──
pub fn buildTooltip(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Hover a button to see the tooltip (4 positions)"));

    // 四个主方向各一个 trigger，间距大些避免弹层重叠。
    const grid = try ui.box(cx, .{ .direction = .row, .gap = 24, .align_items = .center }, .{});
    const positions = [_]struct { p: W.tooltip.TooltipPosition, t: []const u8 }{
        .{ .p = .top, .t = "Top" },
        .{ .p = .bottom, .t = "Bottom" },
        .{ .p = .left, .t = "Left" },
        .{ .p = .right, .t = "Right" },
    };
    inline for (positions) |spec| {
        const tt = try W.Tooltip(.{ .text = spec.t ++ " tooltip", .position = spec.p }).mount(scope, cx);
        try tt.trigger.appendChild(a, try W.Button(.{ .label = spec.t, .variant = .secondary }).mount(scope, cx));
        try grid.appendChild(a, tt.wrapper);
    }
    try c.appendChild(a, grid);
    return c;
}

// ── Modal（用 trigger 按钮打开）──
const ModalStory = struct {
    visible: *ui.Signal(bool),
    fn open(self: *ModalStory) void {
        self.visible.set(true);
    }
};
pub fn buildModal(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const vis = try scope.createSignal(bool, false);
    const st = try cx.bindState(ModalStory, .{ .visible = vis });
    const btn = try W.Button(.{ .label = "Open Modal", .on_click = cx.on(ModalStory, st, ModalStory.open) }).mount(scope, cx);
    btn.meta.ownership.meta.test_id = "story.modal.open";
    try c.appendChild(a, btn);

    const m = try W.Modal(.{ .title = "Example Modal", .width = 400 }).visible(vis).mount(scope, cx);
    m.dialog.meta.ownership.meta.test_id = "story.modal.dialog";
    try m.body.appendChild(a, try ui.text(cx, "Modal body content.", .{ .font_size = 14, .color = light.color.fg_primary }));
    // 带 hover 样式的按钮：damage-rect e2e 用它触发"层内小块变化 -> 部分重绘"
    const ok_btn = try W.Button(.{ .label = "OK" }).mount(scope, cx);
    ok_btn.meta.ownership.meta.test_id = "story.modal.ok";
    try m.body.appendChild(a, ok_btn);
    // portaled 时 overlay 已挂到 window-root portal（覆盖整窗口）；未 portal 时才内联。
    if (!m.portaled) try c.appendChild(a, m.overlay);
    return c;
}

// ── Sheet（用 trigger 按钮打开）──
const SheetStory = struct {
    visible: *ui.Signal(bool),
    fn open(self: *SheetStory) void {
        self.visible.set(true);
    }
};
pub fn buildSheet(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const vis = try scope.createSignal(bool, false);
    const st = try cx.bindState(SheetStory, .{ .visible = vis });
    const sbtn = try W.Button(.{ .label = "Open Sheet", .on_click = cx.on(SheetStory, st, SheetStory.open) }).mount(scope, cx);
    sbtn.meta.ownership.meta.test_id = "story.sheet.open";
    try c.appendChild(a, sbtn);

    const sh = try W.Sheet(.{ .side = .right, .width = 320 }).visible(vis).mount(scope, cx);
    sh.panel.meta.ownership.meta.test_id = "story.sheet.panel";
    try sh.content.appendChild(a, try ui.text(cx, "Sheet panel content.", .{ .font_size = 14, .color = light.color.fg_primary }));
    if (!sh.portaled) try c.appendChild(a, sh.overlay);
    return c;
}

// ── Popover ──
pub fn buildPopover(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Click the button to toggle the popover"));
    const pop = try W.Popover(.{ .position = .bottom_start, .trigger = .click }).mount(scope, cx);
    try pop.trigger.appendChild(a, try W.Button(.{ .label = "Toggle Popover" }).mount(scope, cx));
    try pop.content.appendChild(a, try ui.text(cx, "Popover content!", .{ .font_size = 13, .color = light.color.fg_primary }));
    try c.appendChild(a, pop.wrapper);

    // ── 其它位置 + hover 触发 ──
    try c.appendChild(a, try label(cx, "Positions (top / right) + hover trigger"));
    const grid = try ui.box(cx, .{ .direction = .row, .gap = 24, .align_items = .center }, .{});

    const ptop = try W.Popover(.{ .position = .top, .trigger = .click }).mount(scope, cx);
    try popSetup(a, cx, scope, ptop, "Top", "Opens above");
    try grid.appendChild(a, ptop.wrapper);

    const pright = try W.Popover(.{ .position = .right, .trigger = .click }).mount(scope, cx);
    try popSetup(a, cx, scope, pright, "Right", "Opens to the right");
    try grid.appendChild(a, pright.wrapper);

    const phover = try W.Popover(.{ .position = .bottom, .trigger = .hover }).mount(scope, cx);
    try popSetup(a, cx, scope, phover, "Hover me", "Hover-triggered");
    try grid.appendChild(a, phover.wrapper);

    try c.appendChild(a, grid);

    // ── 块类型下拉（与编辑器选区工具条的 block type 菜单同构）──
    // 回归锚（e2e "popover: block dropdown shadow"）：白底 + 圆角 10 + 1px 描边 +
    // 双层阴影（contact 0/1/3 + ambient 0/8/28）+ fade_fast。阴影必须完整柔和地
    // 落在面板四周，圆角外不得出现被矩形裁出来的灰块。
    try c.appendChild(a, try label(cx, "Block dropdown (editor toolbar shape): shadow must stay soft around rounded corners"));
    const pblock = try W.Popover(.{
        .position = .bottom_start,
        .trigger = .click,
        .width = 168,
        .offset = .{ .static = 6 },
        .enter_transition = .fade_fast,
        .exit_transition = .fade_fast,
        .viewport_padding = 12,
        .shift_main_axis = true,
        .prewarm_hidden_layout = false,
        .detach_hidden_content = true,
    }).mount(scope, cx);
    pblock.trigger.meta.ownership.meta.test_id = "story.popover.block.trigger";
    pblock.chrome.meta.ownership.meta.test_id = "story.popover.block.content";
    try pblock.trigger.appendChild(a, try W.Button(.{ .label = "Block Menu", .variant = .secondary }).mount(scope, cx));
    {
        const panel = pblock.chrome;
        panel.style.direction = .column;
        panel.style.align_items = .stretch;
        panel.style.gap = 0;
        panel.style.padding = ui.Padding.symmetric(4, 4);
        panel.style.height = .{ .fit = .{} };
        panel.setBackground(ui.Color.rgba(255, 255, 255, 255));
        panel.style.border = .{ .radius = 10, .width = 1, .color = ui.Color.rgba(224, 224, 228, 255) };
        panel.style.overflow_hidden = false;
        const ext = panel.style.ensureExtPanic(cx.allocator);
        ext.z_index = 82; // 下游编辑器浮层同款：覆盖 popover 分配的层级
        ext.setShadows(
            .{ .color = ui.Color.rgba(0, 0, 0, 15), .blur = 3, .offset_y = 1 },
            .{ .color = ui.Color.rgba(0, 0, 0, 36), .blur = 28, .offset_y = 8 },
        );
        const rows = [_][]const u8{ "Text", "Heading 1", "Heading 2", "Heading 3", "Quote", "Bullet", "Task", "Code block" };
        for (rows) |row_label| {
            const menu_row = try ui.box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .px = 28 },
                .direction = .row,
                .align_items = .center,
                .padding = ui.Padding.symmetric(0, 8),
                .border = .{ .radius = 6 },
            }, .{});
            try menu_row.appendChild(a, try ui.text(cx, row_label, .{ .font_size = 13, .color = light.color.fg_primary }));
            try panel.appendChild(a, menu_row);
        }
    }
    try c.appendChild(a, pblock.wrapper);

    // ── 对照：静态（非合成层）overflow_hidden 圆角卡片 + 阴影 + 溢出蓝块 ──
    // 与 tall popover 同一组视觉合同，但不经过 composited surface：
    // 阴影不被自身 clip 裁、蓝块被圆角内沿裁、描边不被内容盖住。
    try c.appendChild(a, try label(cx, "Static overflow_hidden card (reference): shadow outside, content clipped inside the border"));
    const card = try ui.box(cx, .{
        .direction = .column,
        .padding = ui.Padding.all(8),
        .width = .{ .px = 220 },
        .height = .{ .px = 80 },
        .background = light.color.bg_secondary,
        .border = .{ .radius = 10, .width = 1, .color = light.color.border },
        .overflow_hidden = true,
    }, .{});
    card.meta.ownership.meta.test_id = "story.popover.static.card";
    {
        const ext = card.style.ensureExtPanic(cx.allocator);
        ext.clip_shape = .{ .rounded_rect = 10 };
        ext.setShadows(
            .{ .color = ui.Color.rgba(0, 0, 0, 40), .blur = 12, .offset_y = 4 },
            .{ .color = ui.Color.rgba(0, 0, 0, 18), .blur = 40, .offset_y = 16 },
        );
    }
    // 竖向渐变：漏出卡片下沿的是哪一段一眼可辨（纯色看不出溢出/滚动位置）
    try card.appendChild(a, try storyGradientSlab(cx, 204, 400));
    try c.appendChild(a, card);

    // ── 超高内容：两侧都放不下 -> autosize 把 max_height 收紧到可用高度 ──
    // 回归锚（e2e "popover: tall content"）：修前面板保持完整高度、best-fit 只挪
    // translate，下缘越过 trigger 把 reference element 盖住。
    try c.appendChild(a, try label(cx, "Tall content: panel must shrink to the viewport, never cover its trigger"));
    // fit_or_scroll：autosize 把 max_height 收到可用高度后，超出部分在面板内纵向滚动
    const ptall = try W.Popover(.{
        .position = .bottom_start,
        .trigger = .click,
        .size_policy = .fit_or_scroll,
        .max_width = 236,
        .max_height = 2000,
    }).mount(scope, cx);
    ptall.trigger.meta.ownership.meta.test_id = "story.popover.tall.trigger";
    // fit_or_scroll 下 content 是 ScrollArea 内容节点、chrome 才是面板外壳
    ptall.chrome.meta.ownership.meta.test_id = "story.popover.tall.content";
    ptall.content.meta.ownership.meta.test_id = "story.popover.tall.scroll_content";
    try ptall.trigger.appendChild(a, try W.Button(.{ .label = "Tall Popover", .variant = .secondary }).mount(scope, cx));
    const tall = try ui.box(cx, .{ .direction = .column, .gap = 6, .padding = ui.Padding.all(8), .width = .{ .px = 220 }, .height = .{ .fit = .{} } }, .{});
    try tall.appendChild(a, try ui.text(cx, "Top of tall content", .{ .font_size = 13, .color = light.color.fg_primary }));
    // 1400px 渐变块：任何合理窗口高度都放不下；渐变让滚动位置可见
    try tall.appendChild(a, try storyGradientSlab(cx, 204, 1400));
    try tall.appendChild(a, try ui.text(cx, "Bottom of tall content", .{ .font_size = 13, .color = light.color.fg_primary }));
    try ptall.content.appendChild(a, tall);
    try c.appendChild(a, ptall.wrapper);
    return c;
}

/// 竖向四段渐变色块（靛蓝->粉->橙->青）：用于溢出/滚动回归，位置与颜色一一对应。
fn storyGradientSlab(cx: *ui.Cx, w: f32, h: f32) !*ui.Node {
    const slab = try ui.box(cx, .{ .width = .{ .px = w }, .height = .{ .px = h }, .flex_shrink = 0, .border = .{ .radius = 6 } }, .{});
    const ext = try slab.style.ensureExtFallible(cx.allocator);
    ext.multi_gradient = ui.MultiGradient.fromSlice(&[_]ui.GradientStop{
        .{ .color = zx_indigo, .position = 0.0 },
        .{ .color = ui.Color.rgba(219, 72, 133, 255), .position = 0.35 },
        .{ .color = zx_orange, .position = 0.68 },
        .{ .color = zx_teal, .position = 1.0 },
    }, .vertical);
    return slab;
}

fn popSetup(a: std.mem.Allocator, cx: *ui.Cx, scope: *ui.Scope, pop: anytype, btn: []const u8, content: []const u8) !void {
    try pop.trigger.appendChild(a, try W.Button(.{ .label = btn, .variant = .secondary }).mount(scope, cx));
    try pop.content.appendChild(a, try ui.text(cx, content, .{ .font_size = 13, .color = light.color.fg_primary }));
}

// ── ZIndex（系统层级验证）──
// 验证 z-index manager 的三条合同（e2e 逐条像素断言）：
//   A. 兄弟 z_index 覆盖 DOM 顺序（red z=3 DOM 最先，仍在最上）
//   B. overflow_hidden 容器里的 popover/tooltip 溢出容器、盖住后方障碍物
//      （障碍物内含 rotate 45° 的 transform 节点，transform 层级修复的回归靶）
//   C. 嵌套继承：modal(dialog tier) 里开 popover(overlay tier)，必须压过 dialog
const ZIndexStory = struct {
    visible: *ui.Signal(bool),
    fn open(self: *ZIndexStory) void {
        self.visible.set(true);
    }
};

const zx_red = ui.Color.rgba(220, 50, 47, 255);
const zx_green = ui.Color.rgba(64, 160, 70, 255);
const zx_blue = ui.Color.rgba(38, 90, 220, 255);
const zx_indigo = ui.Color.rgba(79, 70, 229, 255);
const zx_orange = ui.Color.rgba(255, 150, 40, 255);
const zx_yellow = ui.Color.rgba(250, 204, 21, 255);
const zx_teal = ui.Color.rgba(20, 150, 140, 255);

fn zxSlab(cx: *ui.Cx, w: f32, h: f32, color: ui.Color, test_id: []const u8) !*ui.Node {
    const slab = try ui.box(cx, .{ .width = .{ .px = w }, .height = .{ .px = h }, .background = color }, .{});
    slab.meta.ownership.meta.test_id = test_id;
    return slab;
}

pub fn buildZIndex(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);

    // ── A. 兄弟 z_index 排序 ──
    try c.appendChild(a, try label(cx, "Sibling z-index (DOM order reversed, z must win)"));
    const arena = try ui.box(cx, .{ .width = .{ .px = 220 }, .height = .{ .px = 110 }, .position = .relative }, .{});
    arena.meta.ownership.meta.test_id = "story.zindex.siblings";
    const sib_specs = [_]struct { color: ui.Color, z: i16, off: f32 }{
        .{ .color = zx_red, .z = 3, .off = 0 }, // DOM 最先 + z 最高 → 必须最上
        .{ .color = zx_green, .z = 2, .off = 30 },
        .{ .color = zx_blue, .z = 1, .off = 60 },
    };
    for (sib_specs) |spec| {
        const b = try ui.box(cx, .{
            .position = .absolute,
            .width = .{ .px = 130 },
            .height = .{ .px = 80 },
            .background = spec.color,
        }, .{});
        const ext = try b.style.ensureExtFallible(a);
        ext.z_index = spec.z;
        ext.inset = .{ .left = .{ .px = spec.off }, .top = .{ .px = spec.off / 3 } };
        try arena.appendChild(a, b);
    }
    try c.appendChild(a, arena);

    // ── B. overflow 容器 + popover/tooltip + 障碍物 ──
    // stage 用绝对定位把障碍物顶到 clipbox 下缘上方（top=48 < clipbox 高 64），
    // 保证 tooltip 这种矮气泡（trigger 下沿 +offset 起画，~24px 高）也必与障碍物
    // 交叠，否则断言在测空气（第一版 e2e 实测 tooltip 够不到障碍物）。
    try c.appendChild(a, try label(cx, "Overflow container: popover & tooltip must escape clip and cover the obstacle"));
    const stage = try ui.box(cx, .{ .width = .{ .px = 420 }, .height = .{ .px = 150 }, .position = .relative }, .{});
    const clipbox = try ui.box(cx, .{
        .position = .absolute,
        .direction = .row,
        .gap = 16,
        .width = .{ .px = 420 },
        .height = .{ .px = 64 },
        .padding = Padding.all(12),
        .background = ui.Color.rgba(229, 231, 235, 255),
        .overflow_hidden = true,
    }, .{});
    (try clipbox.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    clipbox.meta.ownership.meta.test_id = "story.zindex.clipbox";

    const pop = try W.Popover(.{ .position = .bottom_start, .trigger = .click }).mount(scope, cx);
    pop.trigger.meta.ownership.meta.test_id = "story.zindex.pop.trigger";
    try pop.trigger.appendChild(a, try W.Button(.{ .label = "Pop", .variant = .secondary }).mount(scope, cx));
    try pop.content.appendChild(a, try zxSlab(cx, 180, 90, zx_indigo, "story.zindex.pop.slab"));
    try clipbox.appendChild(a, pop.wrapper);

    const tip = try W.Tooltip(.{ .text = "Tooltip above everything", .position = .bottom }).mount(scope, cx);
    tip.trigger.meta.ownership.meta.test_id = "story.zindex.tip.trigger";
    tip.content.meta.ownership.meta.test_id = "story.zindex.tip.content";
    try tip.trigger.appendChild(a, try W.Button(.{ .label = "Tip", .variant = .secondary }).mount(scope, cx));
    try clipbox.appendChild(a, tip.wrapper);
    try stage.appendChild(a, clipbox);

    // 障碍物：DOM 在 clipbox 之后的兄弟（无 z 时天然画在弹层之上），绝对定位
    // top=48 与 clipbox 下缘交叠。内含 rotate 45° 的 transform 节点,
    // transform 层级穿透的回归靶。
    const obstacle = try ui.box(cx, .{
        .position = .absolute,
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .width = .{ .px = 420 },
        .height = .{ .px = 100 },
        .background = zx_orange,
    }, .{});
    (try obstacle.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 48 } };
    obstacle.meta.ownership.meta.test_id = "story.zindex.obstacle";
    const diamond = try ui.box(cx, .{ .width = .{ .px = 48 }, .height = .{ .px = 48 }, .background = zx_yellow }, .{});
    diamond.meta.ownership.meta.test_id = "story.zindex.diamond";
    (try diamond.style.ensureExtFallible(a)).rotate = std.math.pi / 4.0;
    try obstacle.appendChild(a, diamond);
    try stage.appendChild(a, obstacle);
    try c.appendChild(a, stage);

    // ── C. 复杂布局 + 三级嵌套：modal(dialog) -> body 复杂列布局里有 tooltip 和
    //    popover(嵌套继承压过 dialog) -> popover 里再开第二个 modal（再压过 popover）。
    //    tier 链全程验证：dialog 1000 < 继承 popover < 第二 dialog < tooltip 3000。
    const vis = try scope.createSignal(bool, false);
    const st = try cx.bindState(ZIndexStory, .{ .visible = vis });
    const open_btn = try W.Button(.{ .label = "Open Nested Modal", .on_click = cx.on(ZIndexStory, st, ZIndexStory.open) }).mount(scope, cx);
    open_btn.meta.ownership.meta.test_id = "story.zindex.modal.open";
    try c.appendChild(a, open_btn);

    const m = try W.Modal(.{ .title = "Nested tiers", .width = 440 }).visible(vis).mount(scope, cx);
    m.dialog.meta.ownership.meta.test_id = "story.zindex.modal.dialog";
    try m.body.appendChild(a, try ui.text(cx, "Popover from inside a modal must stack above the dialog.", .{ .font_size = 13, .color = light.color.fg_primary }));

    // 复杂布局：两列嵌套卡片，各自内部再嵌 column，弹层 trigger 埋在深层级里，
    // 验证 z 继承不依赖"trigger 是 modal body 的直接子节点"。
    const cols_row = try ui.box(cx, .{ .direction = .row, .gap = 12, .align_items = .start }, .{});
    inline for (.{ "A", "B" }) |col_name| {
        const card = try ui.box(cx, .{
            .direction = .column,
            .gap = 8,
            .padding = Padding.all(10),
            .background = ui.Color.rgba(243, 244, 246, 255),
        }, .{});
        (try card.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(8);
        try card.appendChild(a, try label(cx, "Deep column " ++ col_name));
        const inner = try ui.box(cx, .{ .direction = .column, .gap = 8 }, .{});
        if (comptime std.mem.eql(u8, col_name, "A")) {
            // 列 A：modal 里的 tooltip（tooltip tier 恒顶）
            const mtip = try W.Tooltip(.{ .text = "Tooltip inside modal", .position = .bottom }).mount(scope, cx);
            mtip.trigger.meta.ownership.meta.test_id = "story.zindex.modal.tip.trigger";
            mtip.content.meta.ownership.meta.test_id = "story.zindex.modal.tip.content";
            try mtip.trigger.appendChild(a, try W.Button(.{ .label = "Tip in modal", .variant = .secondary }).mount(scope, cx));
            try inner.appendChild(a, mtip.wrapper);
        } else {
            // 列 B：modal 里的 popover，popover 内容里再开第二个 modal
            const mpop = try W.Popover(.{ .position = .bottom_start, .trigger = .click }).mount(scope, cx);
            mpop.trigger.meta.ownership.meta.test_id = "story.zindex.modal.pop.trigger";
            try mpop.trigger.appendChild(a, try W.Button(.{ .label = "Pop in modal", .variant = .secondary }).mount(scope, cx));
            const pop_body = try ui.box(cx, .{ .direction = .column, .gap = 8, .padding = Padding.all(8) }, .{});
            try pop_body.appendChild(a, try zxSlab(cx, 160, 70, zx_indigo, "story.zindex.modal.pop.slab"));
            const vis2 = try scope.createSignal(bool, false);
            const st2 = try cx.bindState(ZIndexStory, .{ .visible = vis2 });
            const open2 = try W.Button(.{ .label = "Open Modal 2", .on_click = cx.on(ZIndexStory, st2, ZIndexStory.open) }).mount(scope, cx);
            open2.meta.ownership.meta.test_id = "story.zindex.modal2.open";
            try pop_body.appendChild(a, open2);
            try mpop.content.appendChild(a, pop_body);
            try inner.appendChild(a, mpop.wrapper);

            // 第二个 modal：从 popover 内容里打开，必须压过 popover（dialog tier 序号
            // 递增 + trigger 嵌套继承双保险）
            const m2 = try W.Modal(.{ .title = "Second modal", .width = 300 }).visible(vis2).mount(scope, cx);
            m2.dialog.meta.ownership.meta.test_id = "story.zindex.modal2.dialog";
            try m2.body.appendChild(a, try zxSlab(cx, 200, 80, zx_teal, "story.zindex.modal2.slab"));
            if (!m2.portaled) try c.appendChild(a, m2.overlay);
        }
        try card.appendChild(a, inner);
        try cols_row.appendChild(a, card);
    }
    try m.body.appendChild(a, cols_row);
    if (!m.portaled) try c.appendChild(a, m.overlay);

    return c;
}

// ── Markdown ──
pub fn buildMarkdown(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const md =
        \\# Markdown
        \\
        \\Supports **bold**, *italic*, and `inline code`.
        \\
        \\- bullet one
        \\- bullet two
        \\
        \\> A blockquote line.
    ;
    const res = try W.Markdown(md, .{ .base_font_size = 13 }).render(cx);
    return res.root;
}

// ── Input ──
pub fn buildInput(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const icons = ui.assets.common;
    const c = try col(cx, 12);

    // ── 类型 ──
    try c.appendChild(a, try label(cx, "Types"));
    const n1 = try W.Input(.{ .label_text = "Name", .placeholder = "Your name", .width = 320 }).mount(scope, cx);
    n1.meta.ownership.meta.test_id = "story.input.name";
    try c.appendChild(a, n1);
    try c.appendChild(a, try W.Input(.{ .label_text = "Email", .input_type = .email, .placeholder = "you@example.com", .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Input(.{ .label_text = "Password", .input_type = .password, .placeholder = "••••••••", .width = 320 }).mount(scope, cx));

    // ── 尺寸 ──
    try c.appendChild(a, try label(cx, "Sizes (sm / md / lg)"));
    inline for (.{ W.input.InputSize.sm, .md, .lg }, .{ "Small", "Medium", "Large" }) |sz, ph| {
        try c.appendChild(a, try W.Input(.{ .size = sz, .placeholder = ph, .width = 320 }).mount(scope, cx));
    }

    // ── 带图标 / append ──
    try c.appendChild(a, try label(cx, "With icon / append"));
    try c.appendChild(a, try W.Input(.{ .label_text = "Search", .placeholder = "Type to search…", .leading_icon_asset = icons.search, .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Input(.{ .label_text = "Website", .placeholder = "mysite", .append_text = ".com", .width = 320 }).mount(scope, cx));

    // ── 状态：required / helper / error / readonly / disabled ──
    try c.appendChild(a, try label(cx, "States"));
    try c.appendChild(a, try W.Input(.{ .label_text = "Required", .placeholder = "Mandatory", .required = true, .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Input(.{ .label_text = "With helper", .placeholder = "Username", .helper = "3–20 characters", .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Input(.{ .label_text = "With error", .initial_value = "bad value", .error_msg = "This field is invalid", .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Input(.{ .label_text = "Readonly", .initial_value = "Read only value", .readonly = true, .width = 320 }).mount(scope, cx));
    try c.appendChild(a, try W.Input(.{ .label_text = "Disabled", .placeholder = "Cannot type", .disabled = true, .width = 320 }).mount(scope, cx));
    return c;
}

// ── Textarea ──
pub fn buildTextarea(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);

    const ta = try W.Textarea(.{ .label_text = "Notes", .placeholder = "Write something…", .rows = 5, .width = 420 }).mount(scope, cx);
    ta.meta.ownership.meta.test_id = "story.textarea.box";
    try c.appendChild(a, ta);

    try c.appendChild(a, try W.Textarea(.{ .label_text = "With helper", .placeholder = "Bio", .helper = "Max 500 characters", .rows = 3, .width = 420 }).mount(scope, cx));
    try c.appendChild(a, try W.Textarea(.{ .label_text = "With error", .value = "too short", .error_msg = "Please write more", .rows = 3, .width = 420 }).mount(scope, cx));
    try c.appendChild(a, try W.Textarea(.{ .label_text = "Disabled", .placeholder = "Cannot edit", .disabled = true, .rows = 3, .width = 420 }).mount(scope, cx));
    return c;
}

// ── VirtualList ──
fn vlRender(node: *ui.Node, idx: usize, c: *ui.Cx) void {
    var buf: [32]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "Row {d}", .{idx}) catch return;
    const child = ui.text(c, txt, .{ .font_size = 13, .color = light.color.fg_primary }) catch return;
    node.appendChild(c.allocator, child) catch {};
}
pub fn buildVirtualList(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const vl = try W.VirtualList(.{ .item_count = 1000, .item_height = 28, .width = 320, .height = 360 }).mount(scope, cx, vlRender);
    return vl.container;
}

// ── VirtualList（动态不等高）──
// 每行文本长度不同 + 自动换行 -> 行高事先根本算不出来，只能量。
// 这正是 measure_items 存在的理由：先按 estimate 占位，布局后读回真高并
// 补偿滚动位置。
const vl_dyn_words = [_][]const u8{
    "短",
    "这是一条中等长度的说明文字，占两行左右。",
    "很短",
    "这一条明显更长：动态高度虚拟列表要处理的核心难题在于，行高只有等到内容真正参与布局之后才知道，而虚拟滚动又要求在渲染之前就知道每一行的位置。解法是先用估算值占位，量到真实高度后回填账本，并且补偿滚动位置，让用户正在看的内容不会跳动。",
    "中等：换行会让这一行变高。",
    "一行",
};
fn vlDynRender(node: *ui.Node, idx: usize, c: *ui.Cx) void {
    node.style.padding = ui.Padding.all(8);
    const body = vl_dyn_words[idx % vl_dyn_words.len];
    var buf: [512]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "#{d}  {s}", .{ idx, body }) catch return;
    const child = ui.text(c, txt, .{
        .font_size = 13,
        .color = light.color.fg_primary,
        .wrap = .word,
    }) catch return;
    child.style.width = .{ .grow = .{} };
    node.appendChild(c.allocator, child) catch {};
}
pub fn buildVirtualListDynamic(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const vl = try W.VirtualList(.{
        .item_count = 2000,
        .measure_items = true,
        .estimate_item_height = 44,
        .width = 320,
        .height = 360,
    }).mount(scope, cx, vlDynRender);
    return vl.container;
}

// ── ScrollArea ──
pub fn buildScrollArea(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const sa = try W.mountScrollArea(.{ .width = 320, .height = 320, .direction = .vertical }, scope, cx);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var buf: [32]u8 = undefined;
        const txt = try std.fmt.bufPrint(&buf, "Scrollable line {d}", .{i});
        try sa.content.appendChild(a, try ui.text(cx, txt, .{ .font_size = 13, .color = light.color.fg_primary }));
    }
    return sa.container;
}

// ── Grid ──
fn gridCell(node: *ui.Node, r: usize, col_: usize, c: *ui.Cx, _: ?*anyopaque) void {
    var buf: [32]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d},{d}", .{ r, col_ }) catch return;
    const child = ui.text(c, txt, .{ .font_size = 12, .color = light.color.fg_secondary }) catch return;
    node.appendChild(c.allocator, child) catch {};
}
pub fn buildGrid(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const widths = [_]f32{ 90, 90, 90, 90 };
    const g = try W.mountGrid(.{
        .col_count = 4,
        .row_count = 12,
        .col_widths = &widths,
        .cell_height = 30,
        .width = 380,
        .height = 320,
        .cell_render_fn = gridCell,
    }, scope, cx);
    return g.root;
}

// ── Select · Pencil puQEf component family ──
pub fn buildSelect(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return select_puqef.build(scope, cx);
}

// ── NumberStepper ──
pub fn buildNumberStepper(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const ns = try ui.widgets.NumberStepper(.{ .value = 5, .min = 0, .max = 10 }, scope, cx);
    ns.wrapper.meta.ownership.meta.test_id = "story.stepper.basic";
    try c.appendChild(a, try label(cx, "0–10, step 1"));
    try c.appendChild(a, ns.wrapper);
    const ns2 = try ui.widgets.NumberStepper(.{ .value = 0.5, .step = 0.25, .width = 160 }, scope, cx);
    try c.appendChild(a, try label(cx, "step 0.25"));
    try c.appendChild(a, ns2.wrapper);
    const ns3 = try ui.widgets.NumberStepper(.{ .value = 3, .disabled = true }, scope, cx);
    try c.appendChild(a, try label(cx, "Disabled"));
    try c.appendChild(a, ns3.wrapper);
    return c;
}

// ── TagsInput ──
pub fn buildTagsInput(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const ti = try ui.widgets.TagsInput(.{
        .initial_tags = &.{ "zig", "metal" },
        .width = 380,
    }, scope, cx);
    ti.input.meta.ownership.meta.test_id = "story.tags.input";
    ti.wrapper.meta.ownership.meta.test_id = "story.tags.wrapper";
    try c.appendChild(a, ti.wrapper);
    try c.appendChild(a, try label(cx, "End with comma (or click Add) to commit a tag."));
    return c;
}

// ── FileUpload ──
const FileUploadStory = struct {
    state: *ui.widgets.file_upload.FileUploadState,
    n: u32 = 0,
    buf: [64]u8 = undefined,
    fn browse(self: *FileUploadStory) void {
        // 故意覆盖默认的原生 NSOpenPanel（runModal 会阻塞 e2e harness）：
        // story 演示程序化回填；on_browse 缺省时组件走 cx.openFilePanel
        self.n += 1;
        const path = std.fmt.bufPrint(&self.buf, "/tmp/demo-file-{d}.txt", .{self.n}) catch return;
        self.state.addFile(path) catch {};
    }
};
pub fn buildFileUpload(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const story = try cx.bindState(FileUploadStory, .{ .state = undefined });
    const fu = try ui.widgets.FileUpload(.{
        .width = 380,
        .on_browse = cx.on(FileUploadStory, story, FileUploadStory.browse),
    }, scope, cx);
    story.state = fu.state;
    fu.wrapper.meta.ownership.meta.test_id = "story.upload.wrapper";
    // 拖放 drop zone：e2e 用 dragAt 往这块矩形里注入 entered/dropped
    fu.state.drop_zone.meta.ownership.meta.test_id = "story.upload.dropzone";
    try c.appendChild(a, fu.wrapper);
    return c;
}

// ── DataTable（筛选/分页/列宽调整）──
const DT_COLS = [_]W.ColumnDef{
    .{ .id = "name", .header = "Name", .width = 140 },
    .{ .id = "role", .header = "Role", .width = 120 },
    .{ .id = "city", .header = "City", .width = 140 },
};
const DT_ROWS = [_][]const []const u8{
    &.{ "Alice", "Admin", "Berlin" },
    &.{ "Bob", "User", "Paris" },
    &.{ "Carol", "User", "Tokyo" },
    &.{ "Dave", "Editor", "London" },
    &.{ "Eve", "User", "Madrid" },
    &.{ "Frank", "Admin", "Rome" },
    &.{ "Grace", "Editor", "Oslo" },
    &.{ "Heidi", "User", "Bern" },
};
pub fn buildDataTable(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const dt = try ui.widgets.DataTable(.{
        .columns = &DT_COLS,
        .rows = &DT_ROWS,
        .page_size = 3,
    }, scope, cx);
    if (dt.filter_input) |fi| fi.meta.ownership.meta.test_id = "story.datatable.filter";
    dt.wrapper.meta.ownership.meta.test_id = "story.datatable.table";
    return dt.wrapper;
}

// ── ComboBox / Autocomplete ──
pub fn buildComboBox(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const opts = [_]ui.widgets.ComboOption{
        .{ .value = "ap", .label = "Apple" },
        .{ .value = "ba", .label = "Banana" },
        .{ .value = "ch", .label = "Cherry" },
        .{ .value = "gr", .label = "Grape" },
        .{ .value = "ma", .label = "Mango" },
    };
    const cb = try ui.widgets.ComboBox(.{
        .options = &opts,
        .label_text = "Fruit",
        .placeholder = "Type to search fruit",
        .width = 260,
    }, scope, cx);
    cb.input.meta.ownership.meta.test_id = "story.combobox.input";
    cb.panel.meta.ownership.meta.test_id = "story.combobox.panel";
    try c.appendChild(a, cb.wrapper);
    return c;
}

// ── Form ──
const DemoForm = struct {
    name: []const u8 = "",
    email: []const u8 = "",
};
pub fn buildForm(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    _ = try ui.widgets.FormOf(DemoForm).create(scope, .{ .name = "", .email = "" }, .{ .trigger = .on_blur });
    // 表单字段 UI 用 Input 展示（FormOf 管校验状态；此 story 重在展示字段布局）
    try c.appendChild(a, try W.Input(.{ .label_text = "Name", .placeholder = "Full name", .width = 320, .required = true }).mount(scope, cx));
    try c.appendChild(a, try W.Input(.{ .label_text = "Email", .input_type = .email, .placeholder = "you@example.com", .width = 320, .required = true }).mount(scope, cx));
    try c.appendChild(a, try W.Button(.{ .label = "Submit", .variant = .primary }).mount(scope, cx));
    return c;
}

// ── Icon gallery ──
// 展示 provider-neutral system icon 子集。完整 Lucide/Untitled catalog 的
// 名字不同，不应让 Storybook 或框架组件依赖具体供应商命名。
const GALLERY_ICONS = [_]struct { asset: ui.system_icons.Asset, name: []const u8 }{
    .{ .asset = ui.system_icons.activity, .name = "activity" },
    .{ .asset = ui.system_icons.alert, .name = "alert" },
    .{ .asset = ui.system_icons.audio, .name = "audio" },
    .{ .asset = ui.system_icons.check, .name = "check" },
    .{ .asset = ui.system_icons.close, .name = "close" },
    .{ .asset = ui.system_icons.search, .name = "search" },
    .{ .asset = ui.system_icons.heart, .name = "heart" },
    .{ .asset = ui.system_icons.star, .name = "star" },
    .{ .asset = ui.system_icons.home, .name = "home" },
    .{ .asset = ui.system_icons.settings, .name = "settings" },
    .{ .asset = ui.system_icons.notification, .name = "notification" },
    .{ .asset = ui.system_icons.calendar, .name = "calendar" },
    .{ .asset = ui.system_icons.user, .name = "user" },
    .{ .asset = ui.system_icons.mail, .name = "mail" },
    .{ .asset = ui.system_icons.trash, .name = "trash" },
    .{ .asset = ui.system_icons.download, .name = "download" },
    .{ .asset = ui.system_icons.upload, .name = "upload" },
    .{ .asset = ui.system_icons.edit, .name = "edit" },
    .{ .asset = ui.system_icons.copy, .name = "copy" },
    .{ .asset = ui.system_icons.lock, .name = "lock" },
};

fn iconCell(scope: *ui.Scope, cx: *ui.Cx, asset: ui.system_icons.Asset, name: []const u8) !*ui.Node {
    const a = cx.allocator;
    _ = scope;
    const cell = try ui.box(cx, .{
        .direction = .column,
        .gap = 6,
        .align_items = .center,
        .width = .{ .px = 92 },
        .padding = Padding.all(8),
    }, .{});
    const ic = try ui.iconTint(cx, asset, light.color.fg_primary, .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
    });
    try cell.appendChild(a, ic);
    try cell.appendChild(a, try ui.text(cx, name, .{ .font_size = 11, .color = light.color.fg_tertiary }));
    return cell;
}

pub fn buildIconGallery(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "System icon contract (provider-neutral subset)"));

    // wrap 成多行网格：每行 6 个。
    var current_row = try row(cx, 8);
    var in_row: usize = 0;
    inline for (GALLERY_ICONS) |spec| {
        if (in_row == 6) {
            try c.appendChild(a, current_row);
            current_row = try row(cx, 8);
            in_row = 0;
        }
        try current_row.appendChild(a, try iconCell(scope, cx, spec.asset, spec.name));
        in_row += 1;
    }
    try c.appendChild(a, current_row);

    // 尺寸 + tint 演示行
    try c.appendChild(a, try label(cx, "Sizes & tints"));
    const demo = try row(cx, 16);
    inline for (.{ 16, 24, 32, 48 }) |sz| {
        try demo.appendChild(a, try ui.iconTint(cx, ui.system_icons.alert, light.color.fg_secondary, .{
            .width = .{ .px = @as(f32, sz) },
            .height = .{ .px = @as(f32, sz) },
        }));
    }
    try demo.appendChild(a, try ui.iconTint(cx, ui.system_icons.heart, .{ .r = 220, .g = 40, .b = 60, .a = 255 }, .{
        .width = .{ .px = 32 },
        .height = .{ .px = 32 },
    }));
    try c.appendChild(a, demo);
    return c;
}

// ── VectorPath (fill_path 管线：多相邻 path 节点，验收 encoder 合批) ──

/// 10 角星路径（纯折线 ≤32 点 -> encoder 转 polygon_fill 模式）
fn setStarGeometry(node: *ui.Node, a: std.mem.Allocator, size: f32) !void {
    const half = size / 2.0;
    const outer = size * 0.46;
    const inner = outer * 0.46;
    var commands: [11]ui.path.PathCommand = undefined;
    for (0..10) |i| {
        const radius = if (i % 2 == 0) outer else inner;
        const angle = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * (std.math.pi / 5.0);
        const p = ui.Point{
            .x = half + std.math.cos(angle) * radius,
            .y = half + std.math.sin(angle) * radius,
        };
        commands[i] = if (i == 0) .{ .move_to = p } else .{ .line_to = p };
    }
    commands[10] = .{ .close = {} };
    try node.setPathHitGeometry(a, &commands, .nonzero);
}

/// 20 芒 burst（40 顶点 > polygon 32 点预算 -> 强制 earclip triangles 模式）
fn setBurstGeometry(node: *ui.Node, a: std.mem.Allocator, size: f32) !void {
    const half = size / 2.0;
    const outer = size * 0.46;
    const inner = outer * 0.72;
    var commands: [41]ui.path.PathCommand = undefined;
    for (0..40) |i| {
        const radius = if (i % 2 == 0) outer else inner;
        const angle = @as(f32, @floatFromInt(i)) * (std.math.pi / 20.0);
        const p = ui.Point{
            .x = half + std.math.cos(angle) * radius,
            .y = half + std.math.sin(angle) * radius,
        };
        commands[i] = if (i == 0) .{ .move_to = p } else .{ .line_to = p };
    }
    commands[40] = .{ .close = {} };
    try node.setPathHitGeometry(a, &commands, .nonzero);
}

pub fn buildVectorPath(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 16);

    // 相邻多 path 节点：encoder 侧应合并为少数 draw（polygon 组 + triangles 组）
    try c.appendChild(a, try label(cx, "Batched fill_path: adjacent stars (polygon mode)"));
    const stars = try row(cx, 12);
    const star_colors = [_]ui.Color{
        ui.Color.rgb(235, 87, 87),
        ui.Color.rgb(242, 153, 74),
        ui.Color.rgb(39, 174, 96),
        ui.Color.rgb(45, 156, 219),
    };
    for (star_colors) |color| {
        const n = try ui.box(cx, .{
            .width = .{ .px = 64 },
            .height = .{ .px = 64 },
            .background = color,
        }, .{});
        try setStarGeometry(n, a, 64);
        try stars.appendChild(a, n);
    }
    try c.appendChild(a, stars);

    try c.appendChild(a, try label(cx, "Bursts 40-pt (earclip triangles mode)"));
    const bursts = try row(cx, 12);
    const burst_colors = [_]ui.Color{
        ui.Color.rgb(155, 81, 224),
        ui.Color.rgb(47, 128, 237),
        ui.Color.rgb(33, 150, 83),
    };
    for (burst_colors) |color| {
        const n = try ui.box(cx, .{
            .width = .{ .px = 64 },
            .height = .{ .px = 64 },
            .background = color,
        }, .{});
        try setBurstGeometry(n, a, 64);
        try bursts.appendChild(a, n);
    }
    try c.appendChild(a, bursts);

    return c;
}

// ── Blend Modes（W3C mix-blend：非 normal 走 blend composite pipeline） ──
//
// 颜色特意全用 0/255 分量：sRGB 传递函数在 0.0/1.0 处不变，线性空间与
// sRGB 空间的混合结果一致，e2e 能按精确 RGB 值断言，不受"shader 在
// 线性空间混合"这一实现细节影响。
//   multiply:   yellow(255,255,0) × cyan(0,255,255)  = green(0,255,0)
//   screen:     red(255,0,0)    ∪ blue(0,0,255)      = magenta(255,0,255)
//   difference: |white(255,255,255) − red(255,0,0)|  = cyan(0,255,255)
pub fn buildBlend(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 16);

    const Case = struct {
        name: []const u8,
        test_id: []const u8,
        bg: ui.Color,
        src: ui.Color,
        mode: ui.BlendMode,
    };
    const cases = [_]Case{
        .{ .name = "multiply: yellow x cyan = green", .test_id = "story.blend.multiply", .bg = ui.Color.rgb(255, 255, 0), .src = ui.Color.rgb(0, 255, 255), .mode = .multiply },
        .{ .name = "screen: red + blue = magenta", .test_id = "story.blend.screen", .bg = ui.Color.rgb(255, 0, 0), .src = ui.Color.rgb(0, 0, 255), .mode = .screen },
        .{ .name = "difference: white - red = cyan", .test_id = "story.blend.difference", .bg = ui.Color.rgb(255, 255, 255), .src = ui.Color.rgb(255, 0, 0), .mode = .difference },
    };

    try c.appendChild(a, try label(cx, "Blend modes (exact-color e2e targets)"));
    const tiles = try row(cx, 16);
    for (cases) |case| {
        const cell = try col(cx, 6);
        try cell.appendChild(a, try label(cx, case.name));
        const outer = try ui.box(cx, .{
            .width = .{ .px = 120 },
            .height = .{ .px = 120 },
            .background = case.bg,
            .padding = ui.Padding.all(20),
        }, .{});
        const inner = try ui.box(cx, .{
            .width = .{ .px = 80 },
            .height = .{ .px = 80 },
            .background = case.src,
        }, .{});
        (try inner.style.ensureExtFallible(a)).blend_mode = case.mode;
        inner.meta.ownership.meta.test_id = case.test_id;
        try outer.appendChild(a, inner);
        try cell.appendChild(a, outer);
        try tiles.appendChild(a, cell);
    }
    try c.appendChild(a, tiles);

    // normal 对照组：同 cyan-on-yellow 但不混合，e2e 断言它仍是 cyan，
    // 证明 blend 路径没把普通合成一起改了。
    try c.appendChild(a, try label(cx, "normal control (should stay cyan)"));
    const control_outer = try ui.box(cx, .{
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
        .background = ui.Color.rgb(255, 255, 0),
        .padding = ui.Padding.all(20),
    }, .{});
    const control_inner = try ui.box(cx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 80 },
        .background = ui.Color.rgb(0, 255, 255),
    }, .{});
    control_inner.meta.ownership.meta.test_id = "story.blend.control";
    try control_outer.appendChild(a, control_inner);
    try c.appendChild(a, control_outer);

    return c;
}

// ── Emoji（彩色字形管线：BGRA atlas 页 + shader 彩色分支） ──
//
// 验收靠像素而非文本：灰度字形管线也能把 emoji 画出**形状**（覆盖率掩码），
// 只是丢了颜色。所以 e2e 断言的是"取中心像素，R/G/B 三通道不相等",
// 灰度必然三通道相等，三通道不等只可能来自真正的彩色采样。
//
// 每个 emoji 单独一个 test_id 节点，且刻意选中心区域是大面积纯色的：
//   🟥 U+1F7E5 红方块  🟩 U+1F7E9 绿方块  🟦 U+1F7E6 蓝方块
// 方块类 emoji 中心整块同色，不受字号/抗锯齿/中心点偏移影响，是最稳的
// 像素靶。文字颜色特意设成中性灰，若 shader 错误地把 emoji 乘上文字色，
// 结果会退回灰度（三通道相等），此测立刻变红。
pub fn buildEmoji(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 16);

    try c.appendChild(a, try label(cx, "Color emoji (BGRA atlas page + shader color branch)"));

    const Case = struct { name: []const u8, test_id: []const u8, glyph: []const u8 };
    const cases = [_]Case{
        .{ .name = "red square", .test_id = "story.emoji.red", .glyph = "\u{1F7E5}" },
        .{ .name = "green square", .test_id = "story.emoji.green", .glyph = "\u{1F7E9}" },
        .{ .name = "blue square", .test_id = "story.emoji.blue", .glyph = "\u{1F7E6}" },
    };

    const tiles = try row(cx, 24);
    for (cases) |case| {
        const cell = try col(cx, 6);
        try cell.appendChild(a, try label(cx, case.name));
        // 中性灰文字色：emoji 若被错误地乘上它，会退化成灰度。
        const glyph_node = try ui.text(cx, case.glyph, .{
            .font_size = 64,
            .color = ui.Color.rgb(128, 128, 128),
        });
        glyph_node.meta.ownership.meta.test_id = case.test_id;
        try cell.appendChild(a, glyph_node);
        try tiles.appendChild(a, cell);
    }
    try c.appendChild(a, tiles);

    // 对照组：同一个中性灰颜色下的普通文本，必须仍然是灰度（三通道相等）。
    // 证明彩色分支没有把灰度路径一起改坏。
    try c.appendChild(a, try label(cx, "grayscale control (must stay gray)"));
    const control = try ui.text(cx, "AAAA", .{
        .font_size = 64,
        .color = ui.Color.rgb(128, 128, 128),
    });
    control.meta.ownership.meta.test_id = "story.emoji.control";
    try c.appendChild(a, control);

    // 混排：emoji 与文字同一段，验证 shaping/fallback 与彩色分流能共存于一行。
    try c.appendChild(a, try label(cx, "mixed run"));
    // 显式给 light 文本色：ui.text 的默认 color 是 comptime 求值的
    // theme.dark.color.fg_primary，不随 cx.setTheme(&light) 变化，
    // 漏写会在 storybook 的浅色底上渲染成几乎看不见的浅色字。
    const mixed = try ui.text(cx, "Hello \u{1F600} world \u{1F30D}", .{
        .font_size = 28,
        .color = light.color.fg_primary,
    });
    mixed.meta.ownership.meta.test_id = "story.emoji.mixed";
    try c.appendChild(a, mixed);

    return c;
}

// ── RTL（阿拉伯语 / 希伯来语双向文本） ──
//
// 验收靠像素而非文本：文本节点即使把字形**反向重叠**画在一起，
// query 出来的字符串和节点 rect 也完全正常，只有像素能区分对错。
//
// 判据是**墨迹的水平分布**：正确渲染时 N 个字形沿 pen 依次铺开，
// 墨迹覆盖节点宽度的大部分；若 RTL 被错误地反向定位，字形会挤成
// 一坨互相重叠，墨迹只占很窄一段。所以 e2e 断言"墨迹列跨度占比"
// 有下界，重叠必然让跨度塌缩，此测立刻变红。
//
// 除了纯 RTL，还覆盖数字、中性/镜像标点、combining marks、URL/邮箱与
// 连续方向切换。最后的窄 Textarea 刻意触发 soft wrap，供 e2e 实际验证
// caret、selection rect 与 pointer hit-testing 使用同一套视觉坐标。
pub fn buildRtl(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 10);

    try c.appendChild(a, try label(cx, "RTL bidi text (CoreText 已做 bidi，glyph 数组为视觉序)"));

    const matrix = try ui.box(cx, .{ .direction = .row, .gap = 28, .align_items = .start }, .{});
    const left = try col(cx, 6);
    left.style.width = .{ .px = 350 };
    const right = try col(cx, 6);
    right.style.width = .{ .px = 390 };

    // 纯 RTL：阿拉伯语 "مرحبا"（marhaba）5 个字符，连写后仍应铺开成一条。
    try left.appendChild(a, try label(cx, "plain shaping controls"));
    const arabic = try ui.text(cx, "\u{645}\u{631}\u{62D}\u{628}\u{627}", .{
        .font_size = 36,
        .color = ui.Color.rgb(0, 0, 0),
    });
    arabic.meta.ownership.meta.test_id = "story.rtl.arabic";
    try left.appendChild(a, arabic);

    // 纯 RTL：希伯来语 "שלום"（shalom）4 个字符，无连写，字形间隔清晰。
    const hebrew = try ui.text(cx, "\u{5E9}\u{5DC}\u{5D5}\u{5DD}", .{
        .font_size = 36,
        .color = ui.Color.rgb(0, 0, 0),
    });
    hebrew.meta.ownership.meta.test_id = "story.rtl.hebrew";
    try left.appendChild(a, hebrew);

    // 对照组：等长 LTR 文本。证明"墨迹跨度"这个判据本身在已知正确的
    // 情况下确实成立（否则下界断言可能只是碰巧过）。
    const ltr = try ui.text(cx, "abcde", .{
        .font_size = 36,
        .color = ui.Color.rgb(0, 0, 0),
    });
    ltr.meta.ownership.meta.test_id = "story.rtl.ltr_control";
    try left.appendChild(a, ltr);

    try left.appendChild(a, try label(cx, "numbers + RTL / repeated direction switches"));
    const numbers = try ui.text(cx, "abc \u{645}\u{631}\u{62D}\u{628}\u{627} 123 xyz", .{
        .font_size = 24,
        .color = ui.Color.rgb(0, 0, 0),
    });
    numbers.meta.ownership.meta.test_id = "story.rtl.numbers";
    try left.appendChild(a, numbers);

    // 拉丁 -> 阿拉伯 -> 拉丁 -> 希伯来 -> 数字，连续跨越多个 bidi run。
    const mixed = try ui.text(cx, "ab\u{645}\u{631}\u{62D}\u{628}\u{627}cd", .{
        .font_size = 36,
        .color = ui.Color.rgb(0, 0, 0),
    });
    mixed.meta.ownership.meta.test_id = "story.rtl.mixed";
    try left.appendChild(a, mixed);
    const switches = try ui.text(cx, "abc \u{645}\u{631}\u{62D}\u{628}\u{627} xyz \u{5E9}\u{5DC}\u{5D5}\u{5DD} 123", .{
        .font_size = 24,
        .color = ui.Color.rgb(0, 0, 0),
    });
    switches.meta.ownership.meta.test_id = "story.rtl.switches";
    try left.appendChild(a, switches);

    // Paired-bracket resolution (UAX #9 N0) and mirrored punctuation.
    try right.appendChild(a, try label(cx, "mirrored punctuation: parentheses / brackets"));
    const parens = try ui.text(cx, "\u{645}\u{631}\u{62D}\u{628}\u{627} (abc) \u{5E9}\u{5DC}\u{5D5}\u{5DD}", .{
        .font_size = 24,
        .color = ui.Color.rgb(0, 0, 0),
    });
    parens.meta.ownership.meta.test_id = "story.rtl.mirrored_parens";
    try right.appendChild(a, parens);
    const brackets = try ui.text(cx, "\u{645}\u{631}\u{62D}\u{628}\u{627} [abc] \u{5E9}\u{5DC}\u{5D5}\u{5DD}", .{
        .font_size = 24,
        .color = ui.Color.rgb(0, 0, 0),
    });
    brackets.meta.ownership.meta.test_id = "story.rtl.mirrored_brackets";
    try right.appendChild(a, brackets);

    // Tashkeel 是 combining marks：有无变音符号应保持同一组基字符的推进宽度，
    // 但墨迹必须包含上/下附标。
    try right.appendChild(a, try label(cx, "Arabic tashkeel / combining marks"));
    const tashkeel_base = try ui.text(cx, "\u{645}\u{631}\u{62D}\u{628}\u{627}", .{
        .font_size = 30,
        .color = ui.Color.rgb(0, 0, 0),
    });
    tashkeel_base.meta.ownership.meta.test_id = "story.rtl.tashkeel_base";
    try right.appendChild(a, tashkeel_base);
    const tashkeel = try ui.text(cx, "\u{645}\u{64E}\u{631}\u{652}\u{62D}\u{64E}\u{628}\u{64B}\u{627}", .{
        .font_size = 30,
        .color = ui.Color.rgb(0, 0, 0),
    });
    tashkeel.meta.ownership.meta.test_id = "story.rtl.tashkeel";
    try right.appendChild(a, tashkeel);

    try matrix.appendChild(a, left);
    try matrix.appendChild(a, right);
    try c.appendChild(a, matrix);

    // URL、邮箱以及 ES/CS/ON 类符号经常把相邻数字或 Latin run 粘到错误一侧。
    try c.appendChild(a, try label(cx, "RTL paragraph with URL / email / + - / : symbols"));
    const symbols = try ui.text(cx, "\u{645}\u{631}\u{62D}\u{628}\u{627} https://example.com/a-b?q=1:2 test@example.com +12/34 - \u{5E9}\u{5DC}\u{5D5}\u{5DD}", .{
        .font_size = 17,
        .color = ui.Color.rgb(0, 0, 0),
    });
    symbols.meta.ownership.meta.test_id = "story.rtl.symbols";
    try c.appendChild(a, symbols);

    // 无硬换行的长 RTL 段落，在窄编辑器内产生多条 display line。e2e 会对
    // 两条视觉行的左右位置点击，并跨行拖选，核对 caret/selection 几何。
    try c.appendChild(a, try label(cx, "wrapped editable RTL: caret / selection rect / hit-testing"));
    const editor_text =
        "\u{645}\u{631}\u{62D}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645} abc 123 xyz \u{5E9}\u{5DC}\u{5D5}\u{5DD} " ++
        "https://example.com/a-b?q=1:2 test@example.com +12/34 - 56:78 / " ++
        "abc \u{645}\u{64E}\u{631}\u{652}\u{62D}\u{64E}\u{628}\u{64B}\u{627} xyz \u{5E9}\u{5DC}\u{5D5}\u{5DD} 123 \u{646}\u{647}\u{627}\u{64A}\u{629} \u{627}\u{644}\u{633}\u{637}\u{631}";
    const editor = try ui.widgets.Textarea(.{ .value = editor_text, .rows = 5, .width = 520 }).mount(scope, cx);
    editor.meta.ownership.meta.test_id = "story.rtl.editor";
    try c.appendChild(a, editor);

    return c;
}

// ── GlassMotion：morph / scroll-edge / backdrop 亮度自适应 ──
const GlassMotionStory = struct {
    glass: *ui.widgets.glass_box.AdaptiveGlassBoxState,
    scroll: *ui.widgets.scroll_area.ScrollState,
    content: *ui.Node,
    morphed: bool = false,
    fn morph(self: *GlassMotionStory) void {
        if (self.morphed) {
            ui.widgets.glass_box.glassMorphTo(self.glass, .{ .x = 12, .y = 12, .w = 150, .h = 84, .emphasis = .subtle });
        } else {
            ui.widgets.glass_box.glassMorphTo(self.glass, .{ .x = 190, .y = 26, .w = 260, .h = 140, .emphasis = .prominent });
        }
        self.morphed = !self.morphed;
    }
    fn scrollDown(self: *GlassMotionStory) void {
        // setScrollY 负责 clamp、清惯性并同步 content 的 translate；直接写 scroll_y 内容不会动。
        ui.widgets.scroll_area.setScrollY(self.scroll, self.content, self.scroll.scroll_y + 80);
    }
};
pub fn buildGlassMotion(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);

    // ── morph：绝对定位玻璃在两个几何/profile 之间过渡 ──
    try c.appendChild(a, try label(cx, "Morph: glass transitions between two geometries/profiles"));
    const morph_stage = try glassBackdrop(cx, 200);
    morph_stage.style.justify = .start;
    morph_stage.style.align_items = .start;
    const gm = try ui.widgets.GlassBox(.{ .title = "Morph", .width = 150, .height = 84 }).mountWithState(scope, cx);
    gm.box.style.position = .absolute;
    (try gm.box.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 12 }, .top = .{ .px = 12 } };
    gm.box.meta.ownership.meta.test_id = "story.glassmotion.morph";
    try morph_stage.appendChild(a, gm.box);
    try c.appendChild(a, morph_stage);

    // ── scroll-edge：玻璃工具条覆盖 ScrollArea 顶部，滚动出现边缘渐变 ──
    try c.appendChild(a, try label(cx, "Scroll-edge: glass bar over scrolling content"));
    const se_stage = try ui.box(cx, .{ .width = .{ .px = 420 }, .height = .{ .px = 220 }, .position = .relative }, .{});
    const sa = try W.mountScrollArea(.{ .width = 420, .height = 220, .direction = .vertical }, scope, cx);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var buf: [32]u8 = undefined;
        const txt = try std.fmt.bufPrint(&buf, "Content row {d}", .{i});
        try sa.content.appendChild(a, try ui.text(cx, txt, .{ .font_size = 13, .color = light.color.fg_primary }));
    }
    try se_stage.appendChild(a, sa.container);
    const bar = try ui.widgets.GlassBox(.{ .height = 44, .padding = ui.Padding.symmetric(8, 12) })
        .scrollEdge(.{ .scroll = sa.state, .edge = .top, .fade_width = 28 })
        .mountWithState(scope, cx);
    bar.box.style.position = .absolute;
    bar.box.style.width = .{ .px = 420 };
    (try bar.box.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    bar.box.meta.ownership.meta.test_id = "story.glassmotion.bar";
    try bar.body.appendChild(a, try glassLabel(cx, "Floating glass toolbar", 600));
    try se_stage.appendChild(a, bar.box);
    try c.appendChild(a, se_stage);

    const st = try cx.bindState(GlassMotionStory, .{ .glass = gm.state, .scroll = sa.state, .content = sa.content });
    const controls = try ui.box(cx, .{ .direction = .row, .gap = 10 }, .{});
    const morph_btn = try W.Button(.{ .label = "Morph", .on_click = cx.on(GlassMotionStory, st, GlassMotionStory.morph) }).mount(scope, cx);
    morph_btn.meta.ownership.meta.test_id = "story.glassmotion.morphbtn";
    try controls.appendChild(a, morph_btn);
    const scroll_btn = try W.Button(.{ .label = "Scroll +80", .on_click = cx.on(GlassMotionStory, st, GlassMotionStory.scrollDown) }).mount(scope, cx);
    scroll_btn.meta.ownership.meta.test_id = "story.glassmotion.scrollbtn";
    try controls.appendChild(a, scroll_btn);
    try c.appendChild(a, controls);
    return c;
}

// ── GlassChrome：应用 header 玻璃（下游真实用法验收）──
//
// 与上面几个 glass story 的关键差异：下游应用的 chrome 用的是
// **浅色 + 纯 blur** 这一档，glass_intensity = 0（无液态折射/高光），
// 只有 backdrop_blur，底色是 88% 白，压在浅米色画布上。
// 上面的 story 全是深色高饱和胶囊压彩虹底，那一档的问题（rim 光、
// 折射畸变）在这一档根本不出现；反过来这一档特有的问题，白纱发灰、
// blur 太弱看不出磨砂、1px 硬边被 blur 吃掉、progressive edge 出接缝
// 上面的 story 一个都抓不到。故单列一个 story 对齐下游真实观感。
//
// 参数逐条抄自下游应用的 chrome 实现（theme / glass / header）。

const chrome_col = struct {
    const bar = ui.Color.hex(0xFAF9F6);
    const canvas = ui.Color.hex(0xF6F6F3);
    const ink = ui.Color.hex(0x17171B);
    const ink2 = ui.Color.hex(0x63636D);
    const ink3 = ui.Color.hex(0x78787F);
    const accent = ui.Color.hex(0x2F5BFF);
    const glass_line = ui.Color.rgba(0, 0, 0, 0x14);
};
const CHROME_TOOLBAR_H: f32 = 52;
const CHROME_PALETTE_H: f32 = 40;
const CHROME_ISLAND_M: f32 = 10;
const CHROME_EDGE_H: f32 = 76;

/// progressiveBlurEdge：单节点单 pass 的渐进毛玻璃。
/// 顶部 30% 满 blur -> 底部收敛到 0。平面上下表面 + 零高光/折射/厚度
/// 是为了关掉 Fresnel rim（f_str_top 不受 glass_intensity 门控，
/// 凸面时下缘会亮一条线）。
fn progressiveEdgeGlass() ui.GlassParams {
    return .{
        .backdrop_blur = 180,
        .glass_intensity = 0,
        .blur_level = 0,
        .surface = .flat,
        .bottom_surface = .flat,
        .specular_opacity = 0,
        .refraction_level = 0,
        .warp_gain = 0,
        .center_thickness = 0,
        .blur_gradient = .{
            .direction = .to_bottom,
            .stops = &.{
                .{ .pos = 0.0, .strength = 1.0 },
                .{ .pos = 0.3, .strength = 1.0 },
                .{ .pos = 1.0, .strength = 0.0 },
            },
        },
    };
}

/// pillCard：r20 胶囊 + 双层浅阴影 + backdrop_blur 20 纯毛玻璃。
fn chromePill(cx: *ui.Cx, w: ?f32, h: f32, pad_x: f32) !*ui.Node {
    const a = cx.allocator;
    const n = try ui.box(cx, .{
        .width = if (w) |px| .{ .px = px } else null,
        .height = .{ .px = h },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .padding = ui.Padding.symmetric(0, pad_x),
        .background = ui.Color.rgba(0xFF, 0xFF, 0xFF, 0xE0),
        .border = .{ .width = 1, .color = chrome_col.glass_line, .radius = h / 2 },
    }, .{});
    const ext = try n.style.ensureExtFallible(a);
    ext.corner_radius = ui.CornerRadius.uniform(h / 2);
    ext.setShadows(.{ .color = ui.Color.rgba(0, 0, 0, 0x14), .blur = 2, .offset_y = 1 }, .{ .color = ui.Color.rgba(0, 0, 0, 0x1A), .blur = 8, .offset_y = 3 });
    // 照稿小胶囊 backdrop_blur 20；intensity 0 = 纯 blur，无液态折射/高光
    ext.glass = .{ .backdrop_blur = 20, .glass_intensity = 0 };
    return n;
}

/// 画布背景：浅米色 + 便签/形状/文字，作为玻璃要折射的真实内容。
/// 刻意放高频细节（文字、细网格、硬边色块），blur 弱了一眼看得出来。
fn chromeCanvas(cx: *ui.Cx, w: f32, h: f32) !*ui.Node {
    const a = cx.allocator;
    const n = try ui.box(cx, .{
        .width = .{ .px = w },
        .height = .{ .px = h },
        .background = chrome_col.canvas,
        .position = .relative,
        .overflow_hidden = true,
    }, .{});

    // 细网格（画布点阵感）
    const grid = try ui.box(cx, .{
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .position = .absolute,
        .direction = .column,
        .justify = .space_evenly,
    }, .{});
    const rows: usize = @max(2, @as(usize, @intFromFloat(h / 28)));
    for (0..rows) |_| {
        try grid.appendChild(a, try ui.box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 1 },
            .background = ui.Color.hex(0xE4E3DE),
        }, .{}));
    }
    try n.appendChild(a, grid);

    // 便签：硬边高饱和色块，玻璃压过去时边缘应糊成柔和过渡带
    const notes = [_]struct { x: f32, y: f32, w: f32, h: f32, c: ui.Color, t: []const u8 }{
        .{ .x = 24, .y = 16, .w = 120, .h = 88, .c = ui.Color.hex(0xFFD54A), .t = "Ship v1.0" },
        .{ .x = 168, .y = 34, .w = 108, .h = 76, .c = ui.Color.hex(0x7BD8A6), .t = "Glass QA" },
        .{ .x = 300, .y = 12, .w = 132, .h = 96, .c = ui.Color.hex(0xFF9AA8), .t = "Refract" },
        .{ .x = 452, .y = 40, .w = 104, .h = 72, .c = ui.Color.hex(0x9DBBFF), .t = "Backdrop" },
    };
    inline for (notes) |nt| {
        const card = try ui.box(cx, .{
            .position = .absolute,
            .width = .{ .px = nt.w },
            .height = .{ .px = nt.h },
            .background = nt.c,
            .padding = ui.Padding.all(8),
        }, .{});
        const cext = try card.style.ensureExtFallible(a);
        cext.corner_radius = ui.CornerRadius.uniform(6);
        cext.inset = .{ .left = .{ .px = nt.x }, .top = .{ .px = nt.y } };
        try card.appendChild(a, try ui.text(cx, nt.t, .{
            .font_size = 12,
            .font_weight = 600,
            .color = ui.Color.rgba(20, 20, 26, 230),
        }));
        try n.appendChild(a, card);
    }
    return n;
}

/// 复刻应用 header 的左右两组：back 胶囊 + 两行标题 / zoom 胶囊 + actions 胶囊。
fn chromeHeaderRow(cx: *ui.Cx, scope: *ui.Scope, width: f32) !*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const header = try ui.box(cx, .{
        .width = .{ .px = width },
        .height = .{ .px = CHROME_TOOLBAR_H },
        .direction = .row,
        .align_items = .center,
        .justify = .space_between,
        .padding = ui.Padding.symmetric(0, 12),
    }, .{});

    // ── 左：back 胶囊 + 标题两行 ──
    const identity = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 12 }, .{});
    const back = try chromePill(cx, CHROME_PALETTE_H, CHROME_PALETTE_H, 0);
    back.meta.ownership.meta.test_id = "story.glasschrome.back";
    try back.appendChild(a, try ui.iconTint(cx, ui.system_icons.chevron_left, chrome_col.ink2, .{
        .width = .{ .px = 17 },
        .height = .{ .px = 17 },
    }));
    try identity.appendChild(a, back);

    const title_area = try ui.box(cx, .{ .direction = .column, .gap = 1 }, .{});
    const title_row = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 6 }, .{});
    try title_row.appendChild(a, try ui.text(cx, "Boards", .{ .font_size = 12.5, .color = chrome_col.ink3 }));
    try title_row.appendChild(a, try ui.iconTint(cx, ui.system_icons.chevron_right, chrome_col.ink3, .{
        .width = .{ .px = 11 },
        .height = .{ .px = 11 },
    }));
    try title_row.appendChild(a, try ui.text(cx, "Untitled", .{
        .font_size = 13,
        .font_weight = 600,
        .color = chrome_col.ink,
    }));
    try title_area.appendChild(a, title_row);
    try title_area.appendChild(a, try ui.text(cx, "12 objects", .{
        .font_size = 10.5,
        .color = chrome_col.ink3,
    }));
    try identity.appendChild(a, title_area);
    try header.appendChild(a, identity);

    // ── 右：zoom 胶囊（− 100% +）+ actions 胶囊（⋯）──
    const right = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 12 }, .{});
    const zoom = try chromePill(cx, null, CHROME_PALETTE_H, 4);
    zoom.meta.ownership.meta.test_id = "story.glasschrome.zoom";
    try zoom.appendChild(a, try ui.iconTint(cx, ui.system_icons.minus, chrome_col.ink2, .{
        .width = .{ .px = 14 },
        .height = .{ .px = 14 },
    }));
    const zl = try ui.box(cx, .{
        .width = .{ .px = 40 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
    }, .{});
    try zl.appendChild(a, try ui.text(cx, "100%", .{
        .font_size = 11.5,
        .font_weight = 500,
        .color = chrome_col.ink2,
    }));
    try zoom.appendChild(a, zl);
    try zoom.appendChild(a, try ui.iconTint(cx, ui.system_icons.plus, chrome_col.ink2, .{
        .width = .{ .px = 14 },
        .height = .{ .px = 14 },
    }));
    try right.appendChild(a, zoom);

    const actions = try chromePill(cx, CHROME_PALETTE_H, CHROME_PALETTE_H, 0);
    actions.meta.ownership.meta.test_id = "story.glasschrome.actions";
    try actions.appendChild(a, try ui.iconTint(cx, ui.system_icons.more_horizontal, chrome_col.ink2, .{
        .width = .{ .px = 17 },
        .height = .{ .px = 17 },
    }));
    try right.appendChild(a, actions);
    try header.appendChild(a, right);
    return header;
}

const GlassChromeStory = struct {
    scroll: *ui.widgets.scroll_area.ScrollState,
    content: *ui.Node,

    // setScrollY 自带 clamp 到 [0, maxScrollY]，并同步 content 的 translate。
    fn scrollDown(self: *GlassChromeStory) void {
        ui.widgets.scroll_area.setScrollY(self.scroll, self.content, self.scroll.scroll_y + 90);
    }
    fn scrollUp(self: *GlassChromeStory) void {
        ui.widgets.scroll_area.setScrollY(self.scroll, self.content, self.scroll.scroll_y - 90);
    }
};

pub fn buildGlassChrome(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);
    const STAGE_W: f32 = 620;

    // ── 1. header 浮在滚动画布之上（画板详情页主场景）──
    try c.appendChild(a, try label(cx, "App header: pure-blur glass pills floating over a scrolling canvas"));
    const stage = try ui.box(cx, .{
        .width = .{ .px = STAGE_W },
        .height = .{ .px = 200 },
        .position = .relative,
        .overflow_hidden = true,
    }, .{});
    (try stage.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(10);

    const sa = try W.mountScrollArea(.{ .width = STAGE_W, .height = 200, .direction = .vertical }, scope, cx);
    // 三屏画布内容，滚动时玻璃下的背景持续变化
    for (0..3) |_| try sa.content.appendChild(a, try chromeCanvas(cx, STAGE_W, 260));
    sa.content.meta.ownership.meta.test_id = "story.glasschrome.canvas";
    try stage.appendChild(a, sa.container);

    // 真实应用的分层：76px 渐进 blur strip 贴顶（header 行本身**无**玻璃），
    // 玻璃胶囊浮在 strip 之上。所以这里必须先挂 strip 再挂 header 行。
    const edge_strip = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = STAGE_W },
        .height = .{ .px = CHROME_EDGE_H },
    }, .{});
    edge_strip.meta.ownership.meta.test_id = "story.glasschrome.edge";
    const sext = try edge_strip.style.ensureExtFallible(a);
    sext.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    sext.glass = progressiveEdgeGlass();
    try stage.appendChild(a, edge_strip);

    // header wrapper：绝对定位 + translate_y = ISLAND_M（同款）。
    // 行本身透明，只有里面的胶囊有玻璃。
    const hdr_wrap = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = STAGE_W },
        .direction = .row,
    }, .{});
    (try hdr_wrap.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    hdr_wrap.setStyle(null, .translate_y, CHROME_ISLAND_M);
    try hdr_wrap.appendChild(a, try chromeHeaderRow(cx, scope, STAGE_W));
    try stage.appendChild(a, hdr_wrap);
    try c.appendChild(a, stage);

    const st = try cx.bindState(GlassChromeStory, .{ .scroll = sa.state, .content = sa.content });
    const controls = try ui.box(cx, .{ .direction = .row, .gap = 10 }, .{});
    const down = try W.Button(.{ .label = "Scroll +90", .on_click = cx.on(GlassChromeStory, st, GlassChromeStory.scrollDown) }).mount(scope, cx);
    down.meta.ownership.meta.test_id = "story.glasschrome.scrolldown";
    try controls.appendChild(a, down);
    const up = try W.Button(.{ .label = "Scroll −90", .on_click = cx.on(GlassChromeStory, st, GlassChromeStory.scrollUp) }).mount(scope, cx);
    up.meta.ownership.meta.test_id = "story.glasschrome.scrollup";
    try controls.appendChild(a, up);
    try c.appendChild(a, controls);

    // ── 2. 渐进式毛玻璃 scroll edge（progressiveBlurEdge）──
    // 顶部 30% 满 blur -> 100% 处收敛到 0。验收点：不该出现下缘切线、
    // 白纱、或接缝，这些是这一档参数特有的失败模式。
    try c.appendChild(a, try label(cx, "Progressive blur scroll edge: full blur at top, fading to none (no seam, no bottom hairline)"));
    const edge_stage = try ui.box(cx, .{
        .width = .{ .px = STAGE_W },
        .height = .{ .px = 150 },
        .position = .relative,
        .overflow_hidden = true,
    }, .{});
    (try edge_stage.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(10);
    const esa = try W.mountScrollArea(.{ .width = STAGE_W, .height = 150, .direction = .vertical }, scope, cx);
    for (0..3) |_| try esa.content.appendChild(a, try chromeCanvas(cx, STAGE_W, 260));
    try edge_stage.appendChild(a, esa.container);

    const edge = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = STAGE_W },
        .height = .{ .px = CHROME_EDGE_H },
    }, .{});
    edge.meta.ownership.meta.test_id = "story.glasschrome.edgebare";
    const eext = try edge.style.ensureExtFallible(a);
    eext.inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    eext.glass = progressiveEdgeGlass();
    try edge_stage.appendChild(a, edge);
    try c.appendChild(a, edge_stage);

    // ── 3. 强度对照阶梯：同一底、只变 backdrop_blur ──
    // 用于判断 20 这档在浅底上到底够不够"磨砂"，单看一个说不清。
    try c.appendChild(a, try label(cx, "backdrop_blur ladder (transparent fill): 0 / 8 / 20 (app) / 40"));
    const ladder_stage = try ui.box(cx, .{
        .width = .{ .px = STAGE_W },
        .height = .{ .px = 150 },
        .position = .relative,
        .overflow_hidden = true,
    }, .{});
    (try ladder_stage.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(10);
    try ladder_stage.appendChild(a, try chromeCanvas(cx, STAGE_W, 150));
    const ladder_row = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = STAGE_W },
        .height = .{ .px = 150 },
        .direction = .row,
        .align_items = .center,
        .justify = .space_evenly,
    }, .{});
    (try ladder_row.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    inline for (.{ 0, 8, 20, 40 }, 0..) |blur, i| {
        const pill = try chromePill(cx, 118, CHROME_PALETTE_H, 0);
        // 诊断：背景全透明，排除 0xE0 白底遮住 blur 的可能
        pill.setStyle(null, .background, ui.Color.rgba(0, 0, 0, 0));
        (try pill.style.ensureExtFallible(a)).glass = .{ .backdrop_blur = blur, .glass_intensity = 0 };
        var buf: [16]u8 = undefined;
        const txt = try std.fmt.bufPrint(&buf, "blur {d}", .{blur});
        try pill.appendChild(a, try ui.text(cx, txt, .{
            .font_size = 12,
            .font_weight = 600,
            .color = chrome_col.ink2,
        }));
        _ = i;
        try ladder_row.appendChild(a, pill);
    }
    try ladder_stage.appendChild(a, ladder_row);
    try c.appendChild(a, ladder_stage);

    // ── 4. 填充不透明度阶梯：blur 固定 20，只变白底 alpha ──
    // 关键对照：应用里用的 0xE0（88% 白）只剩 12% 透光，blur 再大也看不见
    // 玻璃钱花了但没有视觉收益。0x99/0xB0 才真读得出磨砂。
    try c.appendChild(a, try label(cx, "fill alpha ladder at fixed blur 20: 0x66 / 0x99 / 0xB0 / 0xE0 (app): blur is invisible past ~0xB0"));
    const alpha_stage = try ui.box(cx, .{
        .width = .{ .px = STAGE_W },
        .height = .{ .px = 150 },
        .position = .relative,
        .overflow_hidden = true,
    }, .{});
    (try alpha_stage.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(10);
    try alpha_stage.appendChild(a, try chromeCanvas(cx, STAGE_W, 150));
    const alpha_row = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .px = STAGE_W },
        .height = .{ .px = 150 },
        .direction = .row,
        .align_items = .center,
        .justify = .space_evenly,
    }, .{});
    (try alpha_row.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    inline for (.{ 0x66, 0x99, 0xB0, 0xE0 }) |alpha| {
        const pill = try chromePill(cx, 118, CHROME_PALETTE_H, 0);
        pill.setStyle(null, .background, ui.Color.rgba(0xFF, 0xFF, 0xFF, alpha));
        var buf: [16]u8 = undefined;
        const txt = try std.fmt.bufPrint(&buf, "0x{X:0>2}", .{alpha});
        try pill.appendChild(a, try ui.text(cx, txt, .{
            .font_size = 12,
            .font_weight = 600,
            .color = chrome_col.ink2,
        }));
        try alpha_row.appendChild(a, pill);
    }
    try alpha_stage.appendChild(a, alpha_row);
    try c.appendChild(a, alpha_stage);

    return c;
}

// ── CanvasEvents：scroll 修饰键 / magnify / drag / 剪贴板图片（上游能力 e2e 验证）──
const TINY_PNG_2X2_RED = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
    0x24, 0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x84, 0x19, 0x60, 0x0c, 0x00, 0x47, 0xca, 0x07, 0xf9, 0x67, 0x59, 0x6e, 0xb7, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

const CanvasEventsStory = struct {
    cx: *ui.Cx,
    scroll_label: *ui.Node,
    magnify_label: *ui.Node,
    drag_label: *ui.Node,
    clip_label: *ui.Node,
    magnify_accum: f32 = 0,

    fn setLabel(self: *CanvasEventsStory, node: *ui.Node, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, fmt, args) catch return;
        node.setTextContent(self.cx.allocator, txt) catch return;
        node.markRenderDirty();
    }

    fn onScroll(ev: ui.events.ScrollEvent, ctx: ?*anyopaque) ui.events.EventResult {
        const self: *CanvasEventsStory = @ptrCast(@alignCast(ctx.?));
        self.setLabel(self.scroll_label, "scroll dx={d:.0} dy={d:.0} cmd={any} ctrl={any} shift={any}", .{
            ev.dx, ev.dy, ev.modifiers.super, ev.modifiers.ctrl, ev.modifiers.shift,
        });
        return .handled;
    }

    fn onEvent(ev: ui.events.Event, ctx: ?*anyopaque) ui.events.EventResult {
        const self: *CanvasEventsStory = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .magnify => |m| {
                self.magnify_accum += m.magnification;
                self.setLabel(self.magnify_label, "magnify accum={d:.2} phase={s}", .{
                    self.magnify_accum, @tagName(m.phase),
                });
                return .handled;
            },
            .drag => |d| {
                self.setLabel(self.drag_label, "drag {s} paths={s}", .{ @tagName(d.kind), d.paths });
                return .handled;
            },
            else => return .ignored,
        }
    }

    fn clipboardRoundtrip(self: *CanvasEventsStory) void {
        const cx = self.cx;
        if (!ui.platform_services.clipboardSetImagePng(cx.system_sdk, &TINY_PNG_2X2_RED)) {
            self.setLabel(self.clip_label, "clip: set failed", .{});
            return;
        }
        const kinds = ui.platform_services.clipboardProbe(cx.system_sdk);
        const count = ui.platform_services.clipboardImageCount(cx.system_sdk);
        if (ui.platform_services.clipboardGetImageAlloc(cx.system_sdk, cx.allocator, 0)) |img_const| {
            var img = img_const;
            defer img.deinit(cx.allocator);
            // 2x2 纯红 premultiplied RGBA：首像素 R=255 A=255
            const px_ok = img.rgba.len == 16 and img.rgba[0] == 255 and img.rgba[3] == 255;
            self.setLabel(self.clip_label, "clip: image={any} count={d} {d}x{d} px_ok={any} uti={s}", .{
                kinds.image, count, img.width, img.height, px_ok, img.uti orelse "(none)",
            });
        } else {
            self.setLabel(self.clip_label, "clip: image={any} count={d} read failed", .{ kinds.image, count });
        }
    }
};

pub fn buildCanvasEvents(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Canvas events: scroll modifiers / magnify / drag / clipboard image"));

    const canvas = try ui.box(cx, .{
        .width = .{ .px = 420 },
        .height = .{ .px = 160 },
        .background = light.color.bg_secondary,
    }, .{});
    canvas.meta.ownership.meta.test_id = "story.canvasevents.canvas";

    const scroll_label = try ui.text(cx, "scroll (none)", .{ .font_size = 13, .color = light.color.fg_primary });
    scroll_label.meta.ownership.meta.test_id = "story.canvasevents.scroll";
    const magnify_label = try ui.text(cx, "magnify (none)", .{ .font_size = 13, .color = light.color.fg_primary });
    magnify_label.meta.ownership.meta.test_id = "story.canvasevents.magnify";
    const drag_label = try ui.text(cx, "drag (none)", .{ .font_size = 13, .color = light.color.fg_primary });
    drag_label.meta.ownership.meta.test_id = "story.canvasevents.drag";
    const clip_label = try ui.text(cx, "clip (none)", .{ .font_size = 13, .color = light.color.fg_primary });
    clip_label.meta.ownership.meta.test_id = "story.canvasevents.clip";

    const st = try cx.bindState(CanvasEventsStory, .{
        .cx = cx,
        .scroll_label = scroll_label,
        .magnify_label = magnify_label,
        .drag_label = drag_label,
        .clip_label = clip_label,
    });
    canvas.behavior.events.on_scroll = CanvasEventsStory.onScroll;
    canvas.behavior.events.on_event = CanvasEventsStory.onEvent;
    canvas.behavior.events.event_context = st;

    try c.appendChild(a, canvas);
    try c.appendChild(a, scroll_label);
    try c.appendChild(a, magnify_label);
    try c.appendChild(a, drag_label);
    try c.appendChild(a, clip_label);

    const clip_btn = try W.Button(.{ .label = "Clipboard PNG roundtrip", .on_click = cx.on(CanvasEventsStory, st, CanvasEventsStory.clipboardRoundtrip) }).mount(scope, cx);
    clip_btn.meta.ownership.meta.test_id = "story.canvasevents.clipbtn";
    try c.appendChild(a, clip_btn);
    return c;
}

// ── Drag：ui.interaction.drag 基础交互原语（docs/DRAG_INTERACTION_DESIGN.md §18.4）──
//
// 覆盖：自由移动方块 / 水平 resize handle / activation threshold 与 click 计数 /
// cancel 后状态文本 / 键盘等价操作（方向键微调，drag 的 a11y 合同要求）。

const DragStory = struct {
    cx: *ui.Cx,
    subject: *ui.Node,
    status_label: *ui.Node,
    clicks_label: *ui.Node,
    panel: *ui.Node,
    width_label: *ui.Node,

    // 自由移动：从 start 时刻基准 + 累计 delta 计算（§9.2 推荐模式）
    base_tx: f32 = 0,
    base_ty: f32 = 0,
    // 水平 resize
    panel_w: f32 = 240,
    panel_start_w: f32 = 0,
    clicks: u32 = 0,

    const MIN_W: f32 = 120;
    const MAX_W: f32 = 420;

    fn setLabel(self: *DragStory, node: *ui.Node, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, fmt, args) catch return;
        node.setTextContent(self.cx.allocator, txt) catch return;
        node.markRenderDirty();
    }

    fn applyTranslate(self: *DragStory, tx: f32, ty: f32) void {
        self.subject.style.translate_x = tx;
        self.subject.style.translate_y = ty;
        self.subject.markCompositePropDirty();
    }

    fn onMove(event: ui.interaction.drag.Event, raw: *anyopaque) void {
        const self: *DragStory = @ptrCast(@alignCast(raw));
        switch (event.phase) {
            .start => {
                self.base_tx = self.subject.style.translate_x;
                self.base_ty = self.subject.style.translate_y;
                self.setLabel(self.status_label, "state: dragging d=({d:.0},{d:.0})", .{ event.delta.x, event.delta.y });
                self.applyTranslate(self.base_tx + event.delta.x, self.base_ty + event.delta.y);
            },
            .move => {
                self.setLabel(self.status_label, "state: dragging d=({d:.0},{d:.0})", .{ event.delta.x, event.delta.y });
                self.applyTranslate(self.base_tx + event.delta.x, self.base_ty + event.delta.y);
            },
            .end => {
                self.applyTranslate(self.base_tx + event.delta.x, self.base_ty + event.delta.y);
                self.setLabel(self.status_label, "state: end d=({d:.0},{d:.0})", .{ event.delta.x, event.delta.y });
            },
            .cancel => {
                // 本示例的产品策略：cancel 回滚到 drag 前位置（Escape/失焦可观察）
                self.applyTranslate(self.base_tx, self.base_ty);
                self.setLabel(self.status_label, "state: cancel ({s})", .{@tagName(event.cancel_reason.?)});
            },
        }
    }

    fn onResize(event: ui.interaction.drag.Event, raw: *anyopaque) void {
        const self: *DragStory = @ptrCast(@alignCast(raw));
        switch (event.phase) {
            .start => self.panel_start_w = self.panel_w,
            .move, .end => {
                self.panel_w = std.math.clamp(self.panel_start_w + event.delta.x, MIN_W, MAX_W);
                self.panel.style.width = .{ .px = self.panel_w };
                self.panel.markSizingDirty();
                self.setLabel(self.width_label, "width: {d:.0}px", .{self.panel_w});
            },
            .cancel => {
                self.panel_w = self.panel_start_w;
                self.panel.style.width = .{ .px = self.panel_w };
                self.panel.markSizingDirty();
                self.setLabel(self.width_label, "width: {d:.0}px (cancelled)", .{self.panel_w});
            },
        }
    }

    fn onClick(raw: *anyopaque) void {
        const self: *DragStory = @ptrCast(@alignCast(raw));
        self.clicks += 1;
        self.setLabel(self.clicks_label, "clicks: {d} (drag suppresses click)", .{self.clicks});
    }

    // 键盘等价操作：方向键 10px 微调（drag 是 pointer-only，消费组件必须提供等价路径）
    fn onKeyDown(key: ui.events.KeyCode, mods: ui.events.Modifiers, ctx: ?*anyopaque) ui.events.EventResult {
        _ = mods;
        const self: *DragStory = @ptrCast(@alignCast(ctx.?));
        const step: f32 = 10;
        var dx: f32 = 0;
        var dy: f32 = 0;
        switch (key) {
            .left => dx = -step,
            .right => dx = step,
            .up => dy = -step,
            .down => dy = step,
            else => return .ignored,
        }
        self.applyTranslate(self.subject.style.translate_x + dx, self.subject.style.translate_y + dy);
        self.setLabel(self.status_label, "state: keyboard t=({d:.0},{d:.0})", .{
            self.subject.style.translate_x, self.subject.style.translate_y,
        });
        return .stop;
    }
};

pub fn buildDrag(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Drag: ui.interaction.drag primitive (threshold 4px, Escape cancels, arrows nudge when focused)"));

    // ── 1. 自由移动方块（both 轴 + click 计数 + 键盘等价）──
    const arena = try ui.box(cx, .{
        .width = .{ .px = 420 },
        .height = .{ .px = 180 },
        .background = light.color.bg_secondary,
    }, .{});
    (try arena.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(12);

    const subject = try ui.box(cx, .{
        .width = .{ .px = 72 },
        .height = .{ .px = 72 },
        .background = light.color.accent,
        .align_items = .center,
        .justify = .center,
    }, .{});
    (try subject.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(10);
    subject.style.cursor = .grab;
    subject.meta.ownership.meta.test_id = "story.drag.box";
    subject.setFocusable(true);
    try subject.appendChild(a, try ui.text(cx, "drag", .{ .font_size = 13, .color = ui.Color.rgba(255, 255, 255, 255) }));
    try arena.appendChild(a, subject);

    const status_label = try ui.text(cx, "state: idle", .{ .font_size = 13, .color = light.color.fg_primary });
    status_label.meta.ownership.meta.test_id = "story.drag.status";
    const clicks_label = try ui.text(cx, "clicks: 0 (drag suppresses click)", .{ .font_size = 13, .color = light.color.fg_primary });
    clicks_label.meta.ownership.meta.test_id = "story.drag.clicks";

    // ── 2. 水平 resize handle ──
    const resize_row = try row(cx, 0);
    const panel = try ui.box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 80 },
        .background = light.color.bg_tertiary,
        .align_items = .center,
        .justify = .center,
    }, .{});
    panel.meta.ownership.meta.test_id = "story.drag.panel";
    (try panel.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(8);
    const width_label = try ui.text(cx, "width: 240px", .{ .font_size = 13, .color = light.color.fg_primary });
    width_label.meta.ownership.meta.test_id = "story.drag.width";
    try panel.appendChild(a, width_label);

    const handle = try ui.box(cx, .{
        .width = .{ .px = 10 },
        .height = .{ .px = 80 },
        .background = light.color.border,
    }, .{});
    handle.style.cursor = .col_resize;
    handle.meta.ownership.meta.test_id = "story.drag.handle";
    try resize_row.appendChild(a, panel);
    try resize_row.appendChild(a, handle);

    const st = try cx.bindState(DragStory, .{
        .cx = cx,
        .subject = subject,
        .status_label = status_label,
        .clicks_label = clicks_label,
        .panel = panel,
        .width_label = width_label,
    });

    _ = try ui.interaction.drag.Binding.attach(scope, cx, subject, .{
        .activation_distance = 4,
        .active_cursor = .grabbing,
    }, DragStory.onMove, st);
    _ = try ui.interaction.drag.Binding.attach(scope, cx, handle, .{
        .axis = .horizontal,
        .active_cursor = .col_resize,
    }, DragStory.onResize, st);

    // click 计数走独立的 on_click 槽（drag binding 占用 on_event，两者可组合；
    // 越阈值/取消后 dispatcher 会抑制 click，计数不会涨）
    subject.behavior.events.on_click = .{ .callback = DragStory.onClick, .context = @ptrCast(st) };
    // 键盘等价操作走独立的 on_key_down 槽（key_context 与 event_context 分离）
    subject.behavior.events.on_key_down = DragStory.onKeyDown;
    subject.behavior.events.key_context = @ptrCast(st);

    try c.appendChild(a, arena);
    try c.appendChild(a, status_label);
    try c.appendChild(a, clicks_label);
    try c.appendChild(a, try label(cx, "Horizontal resize: drag the handle; delta is axis-projected"));
    try c.appendChild(a, resize_row);
    return c;
}

// ── TextAnimJitter ──
// 文本动画抖动检测 fixture（TEXT_ANIMATION_JITTER_ROOT_FIX_PLAN P3 前哨）。
//
// translate：极慢线性平移（1 逻辑 px/s）+ 非整数字号，各 glyph 小数相位不同，
// 逐 glyph 像素吸附会让相邻字距随时间 ±1 物理像素波动。
// e2e 间隔采样截图，断言字形间距恒定（e2e/text-anim-jitter.test.ts）。
//
// scale / rotate / opacity / backdrop blur：肉眼观察 fixture，覆盖方案 §2.3 的
// 模式接缝（surface 提升/退出、subpixel↔linear 切换）：scale 往返穿越 1.0、
// rotate 连续循环、opacity 往返、静态文本上方 blur 扫动。

/// 往返/循环动画状态（on_complete 里重启；tick 对回调做了延迟调用，安全）。
const TextJitterLoop = struct {
    node: *ui.Node,
    allocator: std.mem.Allocator,
    lo: f32,
    hi: f32,
    dur: f32,
    kind: enum { scale, opacity, rotate },
    // true = 当前这一程的终点是 hi
    to_hi: bool = true,

    fn launch(st: *TextJitterLoop) void {
        const from = if (st.to_hi) st.lo else st.hi;
        const to = if (st.to_hi) st.hi else st.lo;
        switch (st.kind) {
            .scale => {
                // scale_y 不挂回调，仅 scale_x 负责翻转（两轴同步同时长）
                ui.animateNode(st.node, st.allocator, .{
                    .prop = .scale_y,
                    .from = from,
                    .to = to,
                    .duration = st.dur,
                    .easing = .ease_in_out_sine,
                });
                ui.animateNode(st.node, st.allocator, .{
                    .prop = .scale_x,
                    .from = from,
                    .to = to,
                    .duration = st.dur,
                    .easing = .ease_in_out_sine,
                    .on_complete = flip,
                    .on_complete_ctx = @ptrCast(st),
                });
            },
            .opacity => ui.animateNode(st.node, st.allocator, .{
                .prop = .opacity,
                .from = from,
                .to = to,
                .duration = st.dur,
                .easing = .ease_in_out_sine,
                .on_complete = flip,
                .on_complete_ctx = @ptrCast(st),
            }),
            // rotate 不往返：每程 lo->hi 后从头再来（连续旋转）
            .rotate => ui.animateNode(st.node, st.allocator, .{
                .prop = .rotate,
                .from = st.lo,
                .to = st.hi,
                .duration = st.dur,
                .easing = .linear,
                .on_complete = flip,
                .on_complete_ctx = @ptrCast(st),
            }),
        }
    }

    fn flip(ctx: *anyopaque) void {
        const st: *TextJitterLoop = @ptrCast(@alignCast(ctx));
        if (st.kind != .rotate) st.to_hi = !st.to_hi;
        st.launch();
    }

    fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        alloc.destroy(@as(*TextJitterLoop, @ptrCast(@alignCast(ptr))));
    }
};

/// blur 扫动：backdrop_blur 按墙钟正弦在 [0, 24] 摆动（blur 不是 AnimatableProp，
/// 走 before_render 直写，模式同 Spinner）。
/// hook 挂在 in-flow wrapper 上（absolute 节点的 before_render 不保证执行，
/// 见 buildTabs 的 snap 注释）；overlay 指针经 slots.anim_state 传入。
fn textJitterBlurTick(node: *ui.Node) void {
    const overlay: *ui.Node = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    const ext = overlay.style.ext orelse return;
    const now_s = ui.frame.timeMs() / 1000.0;
    const phase: f32 = @floatCast(@sin(now_s * (std.math.tau / 8.0))); // 8s 周期
    if (ext.glass) |*g| g.backdrop_blur = 12.0 + 12.0 * phase;
    if (node.frame_state.state_bits.flags.out_of_viewport) return;
    overlay.markRenderDirty();
    node.markRenderDirty();
}

pub fn buildTextAnimJitter(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 14);

    // ── 1. translate（e2e 门禁用，保持在最前、test_id 不变）──
    try c.appendChild(a, try label(cx, "Translate 1px/s: glyph gaps must stay constant"));
    const wrap = try ui.box(cx, .{
        .width = .{ .px = 560 },
        .height = .{ .px = 56 },
        .padding = Padding.all(12),
        .align_items = .center,
    }, .{});
    wrap.meta.ownership.meta.test_id = "story.textanimjitter.wrap";
    const moving = try ui.text(cx, "H o W l M x H o W l M x H o W l", .{
        .font_size = 16.7,
        .color = light.color.fg_primary,
    });
    try wrap.appendChild(a, moving);
    try c.appendChild(a, wrap);
    ui.animateNode(moving, a, .{
        .prop = .translate_x,
        .from = 0.0,
        .to = 120.0,
        .duration = 120.0,
        .easing = .linear,
    });

    // ── 2. scale 往返（穿越 1.0：提升/退出接缝处不得跳位或忽糊忽锐）──
    try c.appendChild(a, try label(cx, "Scale 0.85 ⇄ 1.15: no snap or sharpness pop at 1.0 crossings"));
    const scale_wrap = try ui.box(cx, .{
        .width = .{ .px = 560 },
        .height = .{ .px = 64 },
        .align_items = .center,
        .justify = .center,
    }, .{});
    const scale_text = try ui.text(cx, "Scale: The quick brown fox 0123456789", .{
        .font_size = 16.7,
        .color = light.color.fg_primary,
    });
    try scale_wrap.appendChild(a, scale_text);
    try c.appendChild(a, scale_wrap);
    const scale_st = try a.create(TextJitterLoop);
    scale_st.* = .{ .node = scale_text, .allocator = a, .lo = 0.85, .hi = 1.15, .dur = 6.0, .kind = .scale };
    try scope.registerResource(@ptrCast(scale_st), TextJitterLoop.cleanup);
    scale_st.launch();

    // ── 3. rotate 连续（文本整块匀速转，笔画不得逐字抖）──
    try c.appendChild(a, try label(cx, "Rotate: continuous slow spin"));
    const rot_wrap = try ui.box(cx, .{
        .width = .{ .px = 560 },
        .height = .{ .px = 110 },
        .align_items = .center,
        .justify = .center,
    }, .{});
    const rot_text = try ui.text(cx, "Rotate 360", .{
        .font_size = 16.7,
        .color = light.color.fg_primary,
    });
    try rot_wrap.appendChild(a, rot_text);
    try c.appendChild(a, rot_wrap);
    const rot_st = try a.create(TextJitterLoop);
    rot_st.* = .{ .node = rot_text, .allocator = a, .lo = 0.0, .hi = std.math.tau, .dur = 16.0, .kind = .rotate };
    try scope.registerResource(@ptrCast(rot_st), TextJitterLoop.cleanup);
    rot_st.launch();

    // ── 4. opacity 往返（提升/退出 opacity layer 时位置与清晰度不得跳）──
    try c.appendChild(a, try label(cx, "Opacity 1.0 ⇄ 0.15: position/sharpness must not shift"));
    const op_wrap = try ui.box(cx, .{
        .width = .{ .px = 560 },
        .height = .{ .px = 48 },
        .align_items = .center,
        .padding = Padding.all(12),
    }, .{});
    const op_text = try ui.text(cx, "Opacity: fading in and out, steadily", .{
        .font_size = 16.7,
        .color = light.color.fg_primary,
    });
    try op_wrap.appendChild(a, op_text);
    try c.appendChild(a, op_wrap);
    const op_st = try a.create(TextJitterLoop);
    op_st.* = .{ .node = op_text, .allocator = a, .lo = 0.15, .hi = 1.0, .dur = 4.0, .kind = .opacity, .to_hi = false };
    try scope.registerResource(@ptrCast(op_st), TextJitterLoop.cleanup);
    op_st.launch();

    // ── 5. backdrop blur 扫动（静态文本上方玻璃 blur 0⇄24：文本不得漂移/闪变）──
    try c.appendChild(a, try label(cx, "Backdrop blur 0 ⇄ 24 over static text: no drift or flicker"));
    const blur_wrap = try ui.box(cx, .{
        .width = .{ .px = 560 },
        .height = .{ .px = 64 },
        .align_items = .center,
        .padding = Padding.all(12),
    }, .{});
    const blur_text = try ui.text(cx, "Blur target: sharp letters behind sweeping glass", .{
        .font_size = 16.7,
        .color = light.color.fg_primary,
    });
    try blur_wrap.appendChild(a, blur_text);
    const glass_overlay = try ui.box(cx, .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
    }, .{});
    const glass_ext = try glass_overlay.style.ensureExtFallible(a);
    glass_ext.glass = .{ .backdrop_blur = 12, .glass_intensity = 0 };
    blur_wrap.meta.per_frame.hooks.slots.anim_state = @ptrCast(glass_overlay);
    blur_wrap.meta.per_frame.hooks.before_render.main = textJitterBlurTick;
    try blur_wrap.appendChild(a, glass_overlay);
    try c.appendChild(a, blur_wrap);

    return c;
}

// ═══════════════════════════════════════════════════════════════════════════
// CORE_REVIEW_2026-08-16 修复批次的 storybook 回归锚（用户可感知修复升级为
// storybook + e2e 双重验证）。每个 story 对应审查报告里的一个批次条目。
// ═══════════════════════════════════════════════════════════════════════════

// ── WordNav（Batch A2：希腊/西里尔词导航 + 家庭 emoji grapheme 簇）──
//
// 修复前症状：cursor.zig 用 `>= 0xE0` 判 multi-byte，2 字节 lead（希腊/西里尔）
// 落进 ASCII 路径又被 `>= 0x80` 立即 break, Alt+<-/-> 原地卡死、双击选出空范围。
// e2e 用 input_state 读回 cursor_pos/anchor 的**字节偏移**断言词边界落点。
//
// 预置文本的字节账本（e2e 断言依赖，改文本必须同步改 e2e）：
//   "αβγ"=0..6  "δεζ"=7..13  "привет"=14..26  "мир"=27..33
//   "hello"=34..39  "world"=40..45  家庭emoji=46..71  "fin"=72..75  total=75
const WORDNAV_TEXT = "αβγ δεζ привет мир hello world \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} fin";

pub fn buildWordNav(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Word navigation: Alt+←/→ jumps whole Greek/Cyrillic words; double-click selects the word; family emoji is one cluster"));

    const ta = try W.Textarea(.{
        .label_text = "Mixed-script sample",
        .value = WORDNAV_TEXT,
        .rows = 3,
        .width = 560,
    }).mount(scope, cx);
    ta.meta.ownership.meta.test_id = "story.wordnav.ta";
    try c.appendChild(a, ta);

    try c.appendChild(a, try label(cx, "Expected Alt+Right stops (byte offsets): 7 14 27 34 40 46 72 75"));
    return c;
}

// ── MultiClick / Gestures（Batch C4 多击与 cancel + Batch A3 long_press tick）──
//
// C4 修复前：reset() 每次 mouse-down 清零 click_count -> double/triple 结构性
// 不可达（e2e 双击断言在旧代码必红）；onTouchUp 丢弃时戳 -> 相隔 10 秒也算
// double（间隔过期不可 e2e 化，story 保留人工观察）；.cancelled 只读不写。
// A3 修复前：注册了 long_press 的应用第一帧 tick 必 panic（epoch 时戳 @intCast
// 溢出），本 story 能加载出首帧就是回归锚；按住 500ms 断言 began 是加强验证。
const MultiClickStory = struct {
    cx: *ui.Cx,
    single_label: *ui.Node,
    double_label: *ui.Node,
    triple_label: *ui.Node,
    long_label: *ui.Node,
    singles: u32 = 0,
    doubles: u32 = 0,
    triples: u32 = 0,
    long_state: LongState = .idle,
    shown_singles: u32 = std.math.maxInt(u32),
    shown_doubles: u32 = std.math.maxInt(u32),
    shown_triples: u32 = std.math.maxInt(u32),
    shown_long: ?LongState = null,
    rec_ids: [4]u32 = .{ 0, 0, 0, 0 },
    /// story 卸载后 arena 里的 recognizer 仍在（无 removeRecognizer API），
    /// callback 会被置 null；alive 是第二道防线。
    alive: bool = true,

    const LongState = enum { idle, began, ended, cancelled };

    fn setLabel(self: *MultiClickStory, node: *ui.Node, comptime fmt: []const u8, args: anytype) void {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, fmt, args) catch return;
        node.setTextContent(self.cx.allocator, txt) catch return;
        node.markRenderDirty();
    }

    fn onGesture(event: ui.gesture.GestureEvent, raw: *anyopaque) void {
        const self: *MultiClickStory = @ptrCast(@alignCast(raw));
        if (!self.alive) return;
        switch (event.kind) {
            .tap => if (event.state == .ended) {
                self.singles += 1;
            },
            .double_tap => if (event.state == .ended) {
                self.doubles += 1;
            },
            .triple_tap => if (event.state == .ended) {
                self.triples += 1;
            },
            .long_press => switch (event.state) {
                .began, .changed => self.long_state = .began,
                .ended => self.long_state = .ended,
                .cancelled => self.long_state = .cancelled,
                else => {},
            },
            else => {},
        }
        self.cx.needs_redraw = true;
    }

    /// before_render：把计数镜像到 label（仅变化时写），并保持出帧,
    /// gesture_arena.tick 只在真渲染帧跑，long_press 的时间判定靠持续出帧推进。
    fn tickHook(node: *ui.Node) void {
        const self: *MultiClickStory = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
        if (self.singles != self.shown_singles) {
            self.shown_singles = self.singles;
            self.setLabel(self.single_label, "single: {d}", .{self.singles});
        }
        if (self.doubles != self.shown_doubles) {
            self.shown_doubles = self.doubles;
            self.setLabel(self.double_label, "double: {d}", .{self.doubles});
        }
        if (self.triples != self.shown_triples) {
            self.shown_triples = self.triples;
            self.setLabel(self.triple_label, "triple: {d}", .{self.triples});
        }
        if (self.shown_long == null or self.long_state != self.shown_long.?) {
            self.shown_long = self.long_state;
            self.setLabel(self.long_label, "long: {s}", .{@tagName(self.long_state)});
        }
        if (node.frame_state.state_bits.flags.out_of_viewport) return;
        node.markRenderDirty();
    }
};

/// scope 卸载时摘 gesture callback：GestureArena 没有 removeRecognizer，
/// 不摘的话 story 卸载后窗口内任意点击仍会调进已失效的 story 上下文。
const MultiClickCleanup = struct {
    cx: *ui.Cx,
    st: *MultiClickStory,

    fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        const self: *MultiClickCleanup = @ptrCast(@alignCast(ptr));
        self.st.alive = false;
        for (self.st.rec_ids) |id| {
            if (id < self.cx.gesture_arena.recognizers.items.len) {
                self.cx.gesture_arena.recognizers.items[id].callback = null;
            }
        }
        alloc.destroy(self);
    }
};

pub fn buildMultiClick(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Gesture arena: tap/double/triple counts + press-and-hold long_press (500ms) + pointer-cancel state"));

    const pad = try ui.box(cx, .{
        .width = .{ .px = 320 },
        .height = .{ .px = 140 },
        .background = light.color.bg_secondary,
        .align_items = .center,
        .justify = .center,
    }, .{});
    (try pad.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(10);
    pad.meta.ownership.meta.test_id = "story.multiclick.pad";
    try pad.appendChild(a, try ui.text(cx, "click / double-click / hold", .{ .font_size = 13, .color = light.color.fg_secondary }));
    try c.appendChild(a, pad);

    const single_label = try ui.text(cx, "single: 0", .{ .font_size = 13, .color = light.color.fg_primary });
    single_label.meta.ownership.meta.test_id = "story.multiclick.single";
    const double_label = try ui.text(cx, "double: 0", .{ .font_size = 13, .color = light.color.fg_primary });
    double_label.meta.ownership.meta.test_id = "story.multiclick.double";
    const triple_label = try ui.text(cx, "triple: 0", .{ .font_size = 13, .color = light.color.fg_primary });
    triple_label.meta.ownership.meta.test_id = "story.multiclick.triple";
    const long_label = try ui.text(cx, "long: idle", .{ .font_size = 13, .color = light.color.fg_primary });
    long_label.meta.ownership.meta.test_id = "story.multiclick.long";
    try c.appendChild(a, single_label);
    try c.appendChild(a, double_label);
    try c.appendChild(a, triple_label);
    try c.appendChild(a, long_label);

    const st = try cx.bindState(MultiClickStory, .{
        .cx = cx,
        .single_label = single_label,
        .double_label = double_label,
        .triple_label = triple_label,
        .long_label = long_label,
    });
    st.alive = true;
    st.rec_ids[0] = try cx.registerGesture(pad, .tap, .{}, MultiClickStory.onGesture, @ptrCast(st));
    st.rec_ids[1] = try cx.registerGesture(pad, .double_tap, .{}, MultiClickStory.onGesture, @ptrCast(st));
    st.rec_ids[2] = try cx.registerGesture(pad, .triple_tap, .{}, MultiClickStory.onGesture, @ptrCast(st));
    st.rec_ids[3] = try cx.registerGesture(pad, .long_press, .{}, MultiClickStory.onGesture, @ptrCast(st));

    pad.meta.per_frame.hooks.slots.anim_state = @ptrCast(st);
    pad.meta.per_frame.hooks.before_render.main = MultiClickStory.tickHook;

    const rc = try a.create(MultiClickCleanup);
    rc.* = .{ .cx = cx, .st = st };
    try scope.registerResource(@ptrCast(rc), MultiClickCleanup.destroy);
    return c;
}

// ── AnimControls（Batch C1 yoyo 重放 / C2 timeline reverse / C6 keyframes
//    批量补齐 / C3 spring 退化参数）──
//
// e2e 全部用**数据值读回**断言（label 文本 / query translate），不做动画中途
// 像素断言（本仓库实测动画截图是噪声源）。
//   C1：yoyo 完成后裸 play() 重放，首 tick 值必须在 from 附近（旧代码从 to 倒播）。
//   C2：reverse 后时间线必须在有限步内完成且停在 t=0（旧代码永转）。
//   C6：kf_now 由按钮显式推进（模拟帧停滞 1s），一次 update 必须批量补齐
//       多个周期（旧代码 if 单周期推进 -> progress 钳 1.0 且 loops 少计）。
//   C3：负 stiffness spring 每帧写进 translate_x，值必须有限（旧代码 NaN）。
const KF_FRAMES = [_]ui.fx.animation.Keyframe{
    .{ .progress = 0.0, .value = 0, .easing = .linear },
    .{ .progress = 1.0, .value = 100, .easing = .linear },
};

const AnimCtlStory = struct {
    cx: *ui.Cx,
    yoyo_ctrl: *ui.fx.AnimationController,
    tl: *ui.fx.Timeline,
    tl_ctrl: *ui.fx.AnimationController,
    spring_ctrl: *ui.fx.AnimationController,
    kf: ui.fx.KeyframeAnimation,
    kf_now: f64 = 0,
    kf_value: f32 = 0,
    spring_ticks: u32 = 0,
    yoyo_box: *ui.Node,
    spring_box: *ui.Node,
    yoyo_label: *ui.Node,
    tl_label: *ui.Node,
    kf_label: *ui.Node,
    spring_label: *ui.Node,
    watch_replay_first: bool = false,
    replay_first: f32 = -1.0,

    fn setLabel(self: *AnimCtlStory, node: *ui.Node, comptime fmt: []const u8, args: anytype) void {
        var buf: [192]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, fmt, args) catch return;
        // 仅在内容变化时写：无条件 setTextContent + markRenderDirty 会把
        // 帧循环钉死在"永远脏"，story 永不 idle。
        if (node.getText()) |t| {
            if (std.mem.eql(u8, t.content, txt)) return;
        }
        node.setTextContent(self.cx.allocator, txt) catch return;
        node.markRenderDirty();
    }

    fn playYoyo(self: *AnimCtlStory) void {
        self.watch_replay_first = true;
        self.yoyo_ctrl.play();
        self.cx.needs_redraw = true;
    }

    fn playTimeline(self: *AnimCtlStory) void {
        self.tl.stop();
        self.tl.play();
        self.cx.needs_redraw = true;
    }

    fn reverseTimeline(self: *AnimCtlStory) void {
        self.tl.reverse();
        self.cx.needs_redraw = true;
    }

    fn kfReset(self: *AnimCtlStory) void {
        self.kf_now = 0;
        self.kf.resetWithTime(0);
        self.kf_value = 0;
        self.cx.needs_redraw = true;
    }

    /// 一次推进 1000ms（keyframes 周期 400ms）：真实复现"帧停滞跨多周期"，
    /// update 的 while 循环必须一次补齐 2 个周期并停在周期内 50% 处。
    fn kfAdvance(self: *AnimCtlStory) void {
        self.kf_now += 1000;
        self.kf_value = self.kf.update(self.kf_now);
        self.cx.needs_redraw = true;
    }

    fn tickHook(node: *ui.Node) void {
        const self: *AnimCtlStory = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
        const now = ui.frame.timeMs();
        const dt = ui.frame.dtSeconds();
        var active = false;

        if (self.yoyo_ctrl.isActive()) {
            _ = self.yoyo_ctrl.tick(now);
            if (self.watch_replay_first) {
                self.replay_first = self.yoyo_ctrl.value;
                self.watch_replay_first = false;
            }
            self.yoyo_box.style.translate_x = self.yoyo_ctrl.value;
            self.yoyo_box.markCompositePropDirty();
            active = true;
        }
        self.setLabel(self.yoyo_label, "yoyo: state={s} value={d:.1} replay_first={d:.1}", .{
            @tagName(self.yoyo_ctrl.play_state), self.yoyo_ctrl.value, self.replay_first,
        });

        if (self.tl.isActive()) {
            _ = self.tl.tick(dt);
            active = true;
        }
        self.setLabel(self.tl_label, "tl: state={s} t={d:.2} v={d:.1}", .{
            @tagName(self.tl.play_state), self.tl.current_time, self.tl_ctrl.value,
        });

        self.setLabel(self.kf_label, "kf: loops={d} value={d:.1} completed={}", .{
            self.kf.completed_loops, self.kf_value, self.kf.completed,
        });

        if (self.spring_ctrl.isActive() and self.spring_ticks < 1800) {
            _ = self.spring_ctrl.tick(now);
            self.spring_ticks += 1;
            self.spring_box.style.translate_x = self.spring_ctrl.value;
            self.spring_box.markCompositePropDirty();
            active = true;
        }
        self.setLabel(self.spring_label, "spring: ticks={d} value={d:.1}", .{
            self.spring_ticks, self.spring_ctrl.value,
        });

        if (node.frame_state.state_bits.flags.out_of_viewport) return;
        if (active) node.markRenderDirty();
    }
};

fn destroyAnimController(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    alloc.destroy(@as(*ui.fx.AnimationController, @ptrCast(@alignCast(ptr))));
}

fn destroyAnimTimeline(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const tl: *ui.fx.Timeline = @ptrCast(@alignCast(ptr));
    tl.deinit();
    alloc.destroy(tl);
}

pub fn buildAnimCtl(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Animation controls: yoyo replay / timeline reverse / keyframes catch-up / degenerate spring"));

    // yoyo tween：20 -> 120 -> 20（loops=2 + yoyo），完成后停在 from。
    const yoyo_ctrl = try a.create(ui.fx.AnimationController);
    yoyo_ctrl.* = ui.fx.AnimationController.initTween(.{ .from = 20, .to = 120, .duration = 0.7, .easing = .linear });
    yoyo_ctrl.yoyo = true;
    yoyo_ctrl.loops = 2;
    try scope.registerResource(@ptrCast(yoyo_ctrl), destroyAnimController);

    // timeline：单条 0->100 线性 2s。
    const tl_ctrl = try a.create(ui.fx.AnimationController);
    tl_ctrl.* = ui.fx.AnimationController.initTween(.{ .from = 0, .to = 100, .duration = 2.0, .easing = .linear });
    try scope.registerResource(@ptrCast(tl_ctrl), destroyAnimController);
    const tl = try a.create(ui.fx.Timeline);
    tl.* = ui.fx.Timeline.init(a);
    try scope.registerResource(@ptrCast(tl), destroyAnimTimeline);
    try tl.add(tl_ctrl, ui.fx.Position.start);

    // 退化 spring：负 stiffness（修复后 precompute 三参全钳，不产 NaN）。
    const spring_ctrl = try a.create(ui.fx.AnimationController);
    spring_ctrl.* = ui.fx.AnimationController.initSpring(.{ .from = 0, .to = 100, .stiffness = -50, .damping = 10, .mass = 1 });
    try scope.registerResource(@ptrCast(spring_ctrl), destroyAnimController);

    // 可视化目标（值断言走 label；箱体只是肉眼观察辅助）
    const arena = try ui.box(cx, .{
        .width = .{ .px = 560 },
        .height = .{ .px = 60 },
        .background = light.color.bg_secondary,
    }, .{});
    const yoyo_box = try ui.box(cx, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .background = light.color.accent }, .{});
    yoyo_box.meta.ownership.meta.test_id = "story.animctl.yoyobox";
    try arena.appendChild(a, yoyo_box);
    const spring_box = try ui.box(cx, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .background = light.color.border }, .{});
    spring_box.meta.ownership.meta.test_id = "story.animctl.springbox";
    try arena.appendChild(a, spring_box);
    try c.appendChild(a, arena);

    const yoyo_label = try ui.text(cx, "yoyo: state=idle value=20.0 replay_first=-1.0", .{ .font_size = 13, .color = light.color.fg_primary });
    yoyo_label.meta.ownership.meta.test_id = "story.animctl.yoyo";
    const tl_label = try ui.text(cx, "tl: state=idle t=0.00 v=0.0", .{ .font_size = 13, .color = light.color.fg_primary });
    tl_label.meta.ownership.meta.test_id = "story.animctl.tl";
    const kf_label = try ui.text(cx, "kf: loops=0 value=0.0 completed=false", .{ .font_size = 13, .color = light.color.fg_primary });
    kf_label.meta.ownership.meta.test_id = "story.animctl.kf";
    const spring_label = try ui.text(cx, "spring: ticks=0 value=0.0", .{ .font_size = 13, .color = light.color.fg_primary });
    spring_label.meta.ownership.meta.test_id = "story.animctl.spring";
    try c.appendChild(a, yoyo_label);
    try c.appendChild(a, tl_label);
    try c.appendChild(a, kf_label);
    try c.appendChild(a, spring_label);

    const st = try cx.bindState(AnimCtlStory, .{
        .cx = cx,
        .yoyo_ctrl = yoyo_ctrl,
        .tl = tl,
        .tl_ctrl = tl_ctrl,
        .spring_ctrl = spring_ctrl,
        .kf = ui.fx.KeyframeAnimation.init(&KF_FRAMES, 400, 4),
        .yoyo_box = yoyo_box,
        .spring_box = spring_box,
        .yoyo_label = yoyo_label,
        .tl_label = tl_label,
        .kf_label = kf_label,
        .spring_label = spring_label,
    });

    const btn_row = try row(cx, 8);
    const yoyo_btn = try W.Button(.{ .label = "Play yoyo", .size = .sm, .on_click = cx.on(AnimCtlStory, st, AnimCtlStory.playYoyo) }).mount(scope, cx);
    yoyo_btn.meta.ownership.meta.test_id = "story.animctl.yoyo_play";
    try btn_row.appendChild(a, yoyo_btn);
    const tl_play_btn = try W.Button(.{ .label = "Play timeline", .size = .sm, .on_click = cx.on(AnimCtlStory, st, AnimCtlStory.playTimeline) }).mount(scope, cx);
    tl_play_btn.meta.ownership.meta.test_id = "story.animctl.tl_play";
    try btn_row.appendChild(a, tl_play_btn);
    const tl_rev_btn = try W.Button(.{ .label = "Reverse timeline", .size = .sm, .on_click = cx.on(AnimCtlStory, st, AnimCtlStory.reverseTimeline) }).mount(scope, cx);
    tl_rev_btn.meta.ownership.meta.test_id = "story.animctl.tl_reverse";
    try btn_row.appendChild(a, tl_rev_btn);
    const kf_reset_btn = try W.Button(.{ .label = "KF reset", .size = .sm, .on_click = cx.on(AnimCtlStory, st, AnimCtlStory.kfReset) }).mount(scope, cx);
    kf_reset_btn.meta.ownership.meta.test_id = "story.animctl.kf_reset";
    try btn_row.appendChild(a, kf_reset_btn);
    const kf_step_btn = try W.Button(.{ .label = "KF +1s", .size = .sm, .on_click = cx.on(AnimCtlStory, st, AnimCtlStory.kfAdvance) }).mount(scope, cx);
    kf_step_btn.meta.ownership.meta.test_id = "story.animctl.kf_step";
    try btn_row.appendChild(a, kf_step_btn);
    try c.appendChild(a, btn_row);

    c.meta.per_frame.hooks.slots.anim_state = @ptrCast(st);
    c.meta.per_frame.hooks.before_render.main = AnimCtlStory.tickHook;

    // spring 自动起播（mount 即驱动，e2e 只读回值）
    spring_ctrl.play();
    cx.needs_redraw = true;
    return c;
}

// ── CleanupHooks（Batch A4：on_cleanup 恰好触发一次）──
//
// 修复前：fireCleanupCallbacks 只置 is_mounted 不清字段，已 mount 节点在
// removeChild -> freeNode 链上必定二次 invoke，计数会显示 2。
// bool 断言抓不到双触发（过程教训 #4），故这里渲染**计数**而非布尔。
const CleanupStory = struct {
    cx: *ui.Cx,
    count: u32 = 0,
    mounted: bool = true,
    count_label: *ui.Node,
    mounted_sig: *ui.Signal(bool),

    fn onChildCleanup(raw: *anyopaque) void {
        const self: *CleanupStory = @ptrCast(@alignCast(raw));
        self.count += 1;
        var buf: [64]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "cleanups: {d}", .{self.count}) catch return;
        self.count_label.setTextContent(self.cx.allocator, txt) catch return;
        self.count_label.markRenderDirty();
        self.cx.needs_redraw = true;
    }

    fn toggle(self: *CleanupStory) void {
        self.mounted = !self.mounted;
        self.mounted_sig.set(self.mounted);
        self.cx.needs_redraw = true;
    }
};

var g_cleanup_story: ?*CleanupStory = null;

fn buildCleanupChild(s: *ui.Scope, c: *ui.Cx) anyerror!*ui.Node {
    _ = s;
    const box = try ui.box(c, .{
        .padding = Padding.all(10),
        .background = light.color.bg_secondary,
    }, .{});
    box.meta.ownership.meta.test_id = "story.cleanup.child";
    try box.appendChild(c.allocator, try ui.text(c, "cleanup child mounted", .{ .font_size = 13, .color = light.color.fg_primary }));
    if (g_cleanup_story) |st| {
        ui.hooks.onCleanup(box, ui.Cx.simpleHandler(CleanupStory.onChildCleanup, @ptrCast(st)));
    }
    return box;
}

pub fn buildCleanup(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "on_cleanup count: unmounting a subtree with a cleanup hook must add exactly 1 (double-fire adds 2)"));

    const count_label = try ui.text(cx, "cleanups: 0", .{ .font_size = 13, .color = light.color.fg_primary });
    count_label.meta.ownership.meta.test_id = "story.cleanup.count";

    const sig = try scope.createSignal(bool, true);
    const st = try cx.bindState(CleanupStory, .{
        .cx = cx,
        .count_label = count_label,
        .mounted_sig = sig,
    });
    st.count = 0;
    st.mounted = true;
    g_cleanup_story = st;

    const holder = try col(cx, 8);
    try ui.Show(scope, holder, sig, cx, buildCleanupChild);
    try c.appendChild(a, holder);
    try c.appendChild(a, count_label);

    const toggle_btn = try W.Button(.{ .label = "Toggle child", .size = .sm, .on_click = cx.on(CleanupStory, st, CleanupStory.toggle) }).mount(scope, cx);
    toggle_btn.meta.ownership.meta.test_id = "story.cleanup.toggle";
    try c.appendChild(a, toggle_btn);
    return c;
}

// ── HeavyText（§5 池化：text renderer overflow instance buffer 保留池）──
//
// 单帧塞 > 32768 个 glyph instance（MAX_INSTANCES，见 src/render/text_renderer.zig）
// 强制走 overflow buffer 路径，修复后该路径是跨帧保留池（曾是每 batch
// createBuffer+destroy）。8 个重叠 absolute 层 × 可见约 40 行 × 约 160 字/行
// ≈ 5 万可见 glyph，稳超预算。e2e 断言区域像素非空白 + app 存活。
pub fn buildHeavyText(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 10);
    try c.appendChild(a, try label(cx, "Heavy text overflow: 8 overlapping layers exceed the 32768 glyph-instance budget (pooled overflow path)"));

    const stack = try ui.box(cx, .{
        .width = .{ .px = 980 },
        .height = .{ .px = 520 },
        .overflow_hidden = true,
        .background = light.color.bg_base,
    }, .{});
    stack.meta.ownership.meta.test_id = "story.heavytext.stack";

    // 确定性 ASCII 词流（8KB）："glyph00 glyph01 …"；harness 序列化会截断到
    // 200 字节，query 不会被巨文本撑爆。
    var text_buf: [8192]u8 = undefined;
    var i: usize = 0;
    var w: usize = 0;
    while (i + 8 <= text_buf.len) : (w += 1) {
        const chunk = std.fmt.bufPrint(text_buf[i..], "glyph{d:0>2} ", .{w % 100}) catch break;
        i += chunk.len;
    }
    const heavy = text_buf[0..i];

    var layer_idx: usize = 0;
    while (layer_idx < 8) : (layer_idx += 1) {
        const layer = try ui.box(cx, .{
            .position = .absolute,
            .width = .{ .px = 980 },
        }, .{});
        const t = try ui.text(cx, heavy, .{
            .font_size = 10,
            .color = light.color.fg_primary,
            .wrap = .word,
        });
        t.style.width = .{ .grow = .{} };
        try layer.appendChild(a, t);
        try stack.appendChild(a, layer);
    }
    try c.appendChild(a, stack);
    return c;
}

// ── Security regressions (2026-08-17 audit) ──

fn appendSvgSafetyCase(parent: *ui.Node, cx: *ui.Cx, name: []const u8, path_data: []const u8) !void {
    const a = cx.allocator;
    const case_row = try row(cx, 10);
    const candidate = try ui.box(cx, .{
        .width = .{ .px = 36 },
        .height = .{ .px = 36 },
        .background = light.color.danger_subtle,
    }, .{});

    if (candidate.setSvgPathHitGeometry(a, path_data, .nonzero)) {
        try case_row.appendChild(a, candidate);
        var accepted_buf: [160]u8 = undefined;
        const accepted = try std.fmt.bufPrint(&accepted_buf, "{s} — UNEXPECTEDLY ACCEPTED", .{name});
        try case_row.appendChild(a, try ui.text(cx, accepted, .{ .font_size = 13, .color = light.color.danger }));
    } else |err| {
        cx.freeNode(candidate);
        var rejected_buf: [160]u8 = undefined;
        const rejected = try std.fmt.bufPrint(&rejected_buf, "{s} — rejected safely ({s})", .{ name, @errorName(err) });
        try case_row.appendChild(a, try ui.iconTint(cx, ui.system_icons.check, light.color.success, .{
            .width = .{ .px = 18 },
            .height = .{ .px = 18 },
        }));
        try case_row.appendChild(a, try ui.text(cx, rejected, .{ .font_size = 13, .color = light.color.fg_primary }));
    }
    try parent.appendChild(a, case_row);
}

/// Exercises the UI path-geometry parser with the two audit payload classes:
/// an operand after close-path (formerly an infinite loop) and a non-finite
/// exponent (formerly able to reach unchecked float-to-int casts). This route
/// stays available in test mode, where the platform SVG texture loader is
/// intentionally absent.
pub fn buildSecuritySvg(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 14);
    try c.appendChild(a, try label(cx, "Malformed SVG corpus: every red-team sample must reject promptly without hanging or crashing"));

    try appendSvgSafetyCase(c, cx, "close operand", "M2 2 L22 2 Z 5");
    try appendSvgSafetyCase(c, cx, "non-finite arc", "M1 1 A1e999 1e999 0 0 1 1e999 1e999");

    const valid_row = try row(cx, 10);
    const valid = try ui.box(cx, .{
        .width = .{ .px = 36 },
        .height = .{ .px = 36 },
        .background = light.color.success,
    }, .{});
    try valid.setSvgPathHitGeometry(a, "M3 12 L9 18 L21 5 Z", .nonzero);
    valid.meta.ownership.meta.test_id = "story.secsvg.valid";
    try valid_row.appendChild(a, valid);
    try valid_row.appendChild(a, try ui.text(cx, "valid control rendered", .{ .font_size = 13, .color = light.color.fg_primary }));
    try c.appendChild(a, valid_row);
    return c;
}

/// Ten nested composited groups exceed the renderer's eight-level opacity
/// stack. Failed inner begins must be paired with no-op ends so the green
/// sibling after the stack still lands on the main render target.
pub fn buildSecurityOpacity(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 14);
    try c.appendChild(a, try label(cx, "10 nested composited opacity groups: depth > 8 must not pop or corrupt an outer render target"));

    const stage = try ui.box(cx, .{
        .width = .{ .px = 520 },
        .height = .{ .px = 250 },
        .padding = Padding.all(10),
        .background = light.color.bg_secondary,
    }, .{});

    var parent = stage;
    var depth: usize = 0;
    while (depth < 10) : (depth += 1) {
        const layer = try ui.box(cx, .{
            .width = .{ .px = 470 - @as(f32, @floatFromInt(depth)) * 24 },
            .height = .{ .px = 210 - @as(f32, @floatFromInt(depth)) * 14 },
            .padding = Padding.all(5),
            .background = if (depth % 2 == 0) light.color.accent_subtle else light.color.bg_base,
            .opacity = 0.92,
        }, .{});
        (try layer.style.ensureExtFallible(a)).composited_group = true;
        try parent.appendChild(a, layer);
        parent = layer;
    }

    const sentinel = try ui.box(cx, .{
        .width = .{ .px = 210 },
        .height = .{ .px = 44 },
        .padding = Padding.all(10),
        .background = light.color.accent,
    }, .{});
    sentinel.meta.ownership.meta.test_id = "story.secopacity.nested";
    try sentinel.appendChild(a, try ui.text(cx, "DEPTH 10 VISIBLE", .{ .font_size = 13, .color = light.color.fg_inverse }));
    try parent.appendChild(a, sentinel);
    try c.appendChild(a, stage);

    const after = try ui.box(cx, .{
        .width = .{ .px = 300 },
        .height = .{ .px = 42 },
        .padding = Padding.all(10),
        .background = light.color.success,
    }, .{});
    after.meta.ownership.meta.test_id = "story.secopacity.after";
    try after.appendChild(a, try ui.text(cx, "AFTER STACK MUST BE VISIBLE", .{ .font_size = 13, .color = light.color.status_fg }));
    try c.appendChild(a, after);
    return c;
}

const security_text_value = "BEGIN|" ++ (" " ** 65_536) ++ "|END";

const SecurityTextStory = struct {
    cx: *ui.Cx,
    status: *ui.Node,
    textarea_state: ?*W.input.TextareaState = null,

    fn changed(self: *SecurityTextStory, value: []const u8) void {
        var buf: [128]u8 = undefined;
        const text_value = std.fmt.bufPrint(&buf, "bytes: {d} · UTF-8 valid: {}", .{
            value.len,
            std.unicode.utf8ValidateSlice(value),
        }) catch return;
        self.status.setTextContent(self.cx.allocator, text_value) catch return;
        self.status.markLayoutDirty();
        self.cx.needs_redraw = true;
    }

    fn replaceWithX(self: *SecurityTextStory) void {
        const state = self.textarea_state orelse return;
        state.selectAll();
        state.insertText("x");
        self.changed(state.getText());
    }
};

/// The u16 whitespace-run overflow and stale-wrap slicing fixes are easiest to
/// verify by editing the real Textarea: load exactly 65,536 consecutive spaces,
/// then replace the long line with one byte while stale wrap breaks still exist.
pub fn buildSecurityText(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "65,536-space editable run: exercises wide run counts and stale wrap-break clamping"));
    try c.appendChild(a, try label(cx, "Select all and replace with x; the editor must stay alive and report bytes: 1"));

    const status = try ui.text(cx, "bytes: 65546 · long space run loaded", .{ .font_size = 13, .color = light.color.fg_primary });
    status.meta.ownership.meta.test_id = "story.sectext.status";
    const story = try cx.bindState(SecurityTextStory, .{ .cx = cx, .status = status });

    const textarea = try W.Textarea(.{
        .label_text = "BEGIN … 65,536 spaces … END",
        .value = security_text_value,
        .rows = 6,
        .width = 560,
        .on_change = ui.Cx.strHandlerFrom(SecurityTextStory, story, SecurityTextStory.changed),
    }).mountWithState(scope, cx);
    story.textarea_state = textarea.state;
    textarea.input.meta.ownership.meta.test_id = "story.sectext.input";

    const replace = try W.Button(.{
        .label = "Replace 65,546 bytes with x",
        .size = .sm,
        .on_click = cx.on(SecurityTextStory, story, SecurityTextStory.replaceWithX),
    }).mount(scope, cx);
    replace.meta.ownership.meta.test_id = "story.sectext.replace";
    try c.appendChild(a, replace);
    try c.appendChild(a, textarea.wrapper);
    try c.appendChild(a, status);
    return c;
}

const TeardownStressStory = struct {
    cx: *ui.Cx,
    visible: *ui.Signal(bool),
    status: *ui.Node,
    mounted: bool = true,
    completed_cycles: u32 = 0,

    fn updateStatus(self: *TeardownStressStory) void {
        var buf: [96]u8 = undefined;
        const text_value = std.fmt.bufPrint(&buf, "grid {s} · completed cycles: {d}", .{
            if (self.mounted) "mounted" else "unmounted",
            self.completed_cycles,
        }) catch return;
        self.status.setTextContent(self.cx.allocator, text_value) catch return;
        self.status.markLayoutDirty();
        self.cx.needs_redraw = true;
    }

    fn toggle(self: *TeardownStressStory) void {
        self.mounted = !self.mounted;
        self.visible.set(self.mounted);
        self.updateStatus();
    }

    fn runTen(self: *TeardownStressStory) void {
        for (0..10) |_| {
            self.mounted = false;
            self.visible.set(false);
            self.mounted = true;
            self.visible.set(true);
            self.completed_cycles += 1;
        }
        self.updateStatus();
    }
};

fn buildTeardownGrid(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const grid = try buildGrid(scope, cx);
    grid.meta.ownership.meta.test_id = "story.teardownstress.grid";
    return grid;
}

/// Direct manual reproducer for the crash reported from rowClick -> Show dispose:
/// every unmount owns a Grid whose Scope cleanup still references its content
/// node, so scope cleanup must complete before deferred node destruction.
pub fn buildTeardownStress(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try label(cx, "Reactive teardown ordering: Scope cleanup must run before Grid nodes are freed"));

    const status = try ui.text(cx, "grid mounted · completed cycles: 0", .{ .font_size = 13, .color = light.color.fg_primary });
    status.meta.ownership.meta.test_id = "story.teardownstress.status";
    const visible = try scope.createSignal(bool, true);
    const story = try cx.bindState(TeardownStressStory, .{
        .cx = cx,
        .visible = visible,
        .status = status,
    });

    const actions = try row(cx, 8);
    const toggle_button = try W.Button(.{
        .label = "Toggle Grid",
        .size = .sm,
        .on_click = cx.on(TeardownStressStory, story, TeardownStressStory.toggle),
    }).mount(scope, cx);
    toggle_button.meta.ownership.meta.test_id = "story.teardownstress.toggle";
    try actions.appendChild(a, toggle_button);

    const stress_button = try W.Button(.{
        .label = "Run 10 cycles",
        .size = .sm,
        .variant = .secondary,
        .on_click = cx.on(TeardownStressStory, story, TeardownStressStory.runTen),
    }).mount(scope, cx);
    stress_button.meta.ownership.meta.test_id = "story.teardownstress.run";
    try actions.appendChild(a, stress_button);
    try c.appendChild(a, actions);
    try c.appendChild(a, status);

    const holder = try col(cx, 8);
    try ui.Show(scope, holder, visible, cx, buildTeardownGrid);
    try c.appendChild(a, holder);
    return c;
}

pub const buildInteractionLifecycle = @import("interaction_lifecycle.zig").build;
