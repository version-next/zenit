/// stories.zig: one buildXxx(scope, cx) !*Node story per component.
///
/// Convention (ui.view, see docs/VIEW_DSL.md):
///   - each story returns `v.render(scope, cx, element tree)`, no manual appendChild,
///     no post-mount node mutation;
///   - styles from styles.zig (`S.stack(12)` / `S.line(10)` / `S.storyLabel` ...);
///   - events via `ui.on.*` signal, state echo via `v.fmt` / `ui.map` derive;
///   - test_id: container / text take `.test_id` directly, component root via `v.attrs`,
///     component internal parts via `.parts`.
///
/// Stateless component: showcase representative variant/size.
/// Stateful component: wire a Signal, interactive within storybook.
/// Key interactions get fine-grained test_id (story.<key>.<part>) for e2e lookup.
const std = @import("std");
const ui = @import("ui");
const select_puqef = @import("select_puqef.zig");
const S = @import("styles.zig");

const v = ui.view;
const W = ui.widgets;
const Padding = ui.Padding;
const light = ui.theme.modes.light;

// -- Glass story (Liquid Glass section below) still uses imperative tree helper --
fn labelNode(cx: *ui.Cx, txt: []const u8) !*ui.Node {
    return ui.text(cx, txt, .{ .font_size = 13, .color = light.tokens.color.fg_secondary });
}

/// Demo column of a fixed width, for stories whose components fill their parent's width (the
/// story panel centres a story root that hugs its content).
fn demoWidth(comptime w: f32) ui.BoxStyle {
    return .{ .width = .{ .px = w }, .direction = .column };
}

fn row(cx: *ui.Cx, gap: f32) !*ui.Node {
    return ui.box(cx, .{ .direction = .row, .gap = gap, .align_items = .center, .no_cross_stretch = true }, .{});
}

fn col(cx: *ui.Cx, gap: f32) !*ui.Node {
    return ui.box(cx, .{ .direction = .column, .gap = gap, .no_cross_stretch = true }, .{});
}

/// Regression: story status row (13px primary).
fn regBody(t: *const ui.theme.Values) ui.TextStyle {
    return .{ .font_size = 13, .color = t.tokens.color.fg_primary };
}

/// absolute child offset from container top-left.
fn insetLeftTop(left: f32, top: f32) ui.Inset {
    return .{ .left = .{ .px = left }, .top = .{ .px = top } };
}

// -- Utilities --

const label_props = .{ .style = S.storyLabel };

/// Subsection label
fn label(txt: []const u8) v.Text(@TypeOf(label_props), []const u8) {
    return v.text(label_props, txt);
}

// ── Button ──

const ButtonVariantSpec = struct { v: W.ButtonVariant, t: []const u8 };
const ButtonSizeSpec = struct { s: W.ButtonSize, t: []const u8 };

const button_variants = [_]ButtonVariantSpec{
    .{ .v = .base, .t = "Base" },
    .{ .v = .primary, .t = "Primary" },
    .{ .v = .secondary, .t = "Secondary" },
    .{ .v = .ghost, .t = "Ghost" },
    .{ .v = .danger, .t = "Danger" },
    .{ .v = .link, .t = "Link" },
};
const button_sizes = [_]ButtonSizeSpec{
    .{ .s = .xs, .t = "XS" },
    .{ .s = .sm, .t = "SM" },
    .{ .s = .md, .t = "MD" },
    .{ .s = .lg, .t = "LG" },
};

const ButtonEl = @TypeOf(W.Button(.{}));
const BadgeEl = @TypeOf(W.Badge(.{}));

const ButtonViews = struct {
    const icons = ui.assets.common;
    const row_props = .{ .style = S.line(10) };

    fn matrixRow(vs: ButtonVariantSpec) v.Box(@TypeOf(row_props), [button_sizes.len]ButtonEl, .row) {
        return v.row(row_props, v.listWith(vs, &button_sizes, matrixCell));
    }
    fn matrixCell(vs: ButtonVariantSpec, ss: ButtonSizeSpec) ButtonEl {
        return W.Button(.{ .label = vs.t, .variant = vs.v, .size = ss.s });
    }
    fn withIcon(vs: ButtonVariantSpec) ButtonEl {
        return W.Button(.{ .label = vs.t, .variant = vs.v, .icon_asset = icons.plus });
    }
    fn iconBySize(cx: *ui.Cx, ss: ButtonSizeSpec) ButtonEl {
        return W.Button(.{
            .label = "Download",
            .variant = .secondary,
            .size = ss.s,
            .icon_asset = icons.folder,
            .icon_size = ui.widgets.control_shell.metrics(cx.tokens, ss.s).icon_size,
        });
    }
    fn iconOnly(vs: ButtonVariantSpec) ButtonEl {
        return W.Button(.{ .variant = vs.v, .icon_only = true, .icon_asset = icons.star });
    }
    fn iconOnlyBySize(cx: *ui.Cx, ss: ButtonSizeSpec) ButtonEl {
        return W.Button(.{
            .variant = .secondary,
            .icon_only = true,
            .icon_asset = icons.search,
            .size = ss.s,
            .icon_size = ui.widgets.control_shell.metrics(cx.tokens, ss.s).icon_size,
        });
    }
    fn loading(vs: ButtonVariantSpec) ButtonEl {
        return W.Button(.{ .label = "Saving…", .variant = vs.v, .loading = true });
    }
    fn loadingBySize(ss: ButtonSizeSpec) ButtonEl {
        return W.Button(.{ .label = "Loading", .variant = .primary, .size = ss.s, .loading = true });
    }
};

pub fn buildButton(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const B = ButtonViews;
    const icons = B.icons;
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        // -- variant x size full matrix --
        label("Variants × Sizes"),
        v.col(.{ .style = S.stack(8) }, v.list(&button_variants, B.matrixRow)),

        // -- with leading icon each variant --
        label("With leading icon"),
        v.row(.{ .style = S.line(10) }, v.list(&button_variants, B.withIcon)),

        // -- leading icon x sizes (icon scales with size) --
        label("Leading icon × sizes"),
        v.row(.{ .style = S.line(10) }, v.listWith(cx, &button_sizes, B.iconBySize)),

        // -- icon-only (icon alone) each variant --
        label("Icon only"),
        v.row(.{ .style = S.line(10) }, v.list(&button_variants, B.iconOnly)),

        // ── icon-only × sizes ──
        label("Icon only × sizes"),
        v.row(.{ .style = S.line(10) }, v.listWith(cx, &button_sizes, B.iconOnlyBySize)),

        // -- loading (in progress) each variant --
        label("Loading"),
        v.row(.{ .style = S.line(10) }, v.list(&button_variants, B.loading)),

        // -- loading x sizes (spinner scales with size) --
        label("Loading × sizes"),
        v.row(.{ .style = S.line(10) }, v.list(&button_sizes, B.loadingBySize)),

        // -- state: normal / disabled / disabled+icon / loading+icon-only --
        label("States"),
        v.row(.{ .style = S.line(10) }, .{
            W.Button(.{ .label = "Normal" }),
            W.Button(.{ .label = "Disabled", .disabled = true }),
            W.Button(.{ .label = "Disabled", .disabled = true, .icon_asset = icons.plus }),
            W.Button(.{ .label = "Loading", .loading = true }),
            W.Button(.{ .icon_only = true, .icon_asset = icons.x_close, .loading = true, .variant = .secondary }),
        }),

        // -- block (block-level, width fill) --
        label("Block (full width)"),
        v.col(.{ .style = .{ S.stack(8), S.fixedWidth(280) } }, .{
            W.Button(.{ .label = "Block primary", .block = true }),
            W.Button(.{ .label = "Block + icon", .block = true, .variant = .secondary, .icon_asset = icons.check }),
        }),
    }));
}

// ── Checkbox ──

/// Checkbox story: Signal driven. Checked state is signal, also data source for
/// two checkboxes (either toggles write it, both follow it). status text from on_change-
/// written `last` derived (reflects user-initiated change only).
const CheckboxStory = struct {
    fn word(value: ?bool) []const u8 {
        const c = value orelse return "(none)";
        return if (c) "checked" else "unchecked";
    }
};

pub fn buildCheckbox(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const agree = try scope.createSignal(bool, false);
    const last = try scope.createSignal(?bool, null);

    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.attrs(.{ .test_id = "story.checkbox.box" }, W.Checkbox(.{
            .label = "Unchecked",
            .checked = agree,
            .on_change = ui.on.assignAs(bool, last),
        })),
        // Second view of same signal: tap any, other follows
        W.Checkbox(.{ .label = "Mirror of Unchecked", .checked = agree }),
        v.attrs(.{ .test_id = "story.checkbox.checked" }, W.Checkbox(.{ .label = "Checked", .checked = true })),
        v.attrs(.{ .test_id = "story.checkbox.indeterminate" }, W.Checkbox(.{ .label = "Indeterminate", .indeterminate = true })),
        W.Checkbox(.{ .label = "Disabled", .disabled = true }),
        W.Checkbox(.{ .label = "Disabled selected", .checked = true, .disabled = true }),
        W.Checkbox(.{ .label = "Disabled mixed", .indeterminate = true, .disabled = true }),
        v.text(.{ .style = S.storyLabel, .test_id = "story.checkbox.status" }, v.fmt("changed → {s}", .{ui.map(last, CheckboxStory.word)})),
    }));
}

// ── Slider ──

/// Slider feedback playground: three sliders share feedback toggle + mode signal;
/// stepped / continuous value held by story, status line derived from them.
const SliderFeedbackStory = struct {
    pattern: *ui.Signal(ui.widgets.slider.HapticFeedbackPattern),
    stepped: *ui.Signal(f32),
    continuous: *ui.Signal(f32),

    fn reset(self: *SliderFeedbackStory) void {
        self.stepped.set(5);
        self.continuous.set(5);
    }

    fn selectPattern(self: *SliderFeedbackStory, value: []const u8) void {
        const pattern = std.meta.stringToEnum(ui.widgets.slider.HapticFeedbackPattern, value) orelse return;
        self.pattern.set(pattern);
    }

    fn onOff(enabled: bool) []const u8 {
        return if (enabled) "on" else "off";
    }

    fn patternName(pattern: ui.widgets.slider.HapticFeedbackPattern) []const u8 {
        return switch (pattern) {
            .alignment => "Alignment",
            .generic => "Generic",
            .level_change => "Level change",
        };
    }
};

const slider_pattern_options = [_]ui.widgets.checkbox.RadioOption{
    .{ .value = "alignment", .label = "Alignment", .test_id = "story.slider.pattern.alignment" },
    .{ .value = "generic", .label = "Generic", .test_id = "story.slider.pattern.generic" },
    .{ .value = "level_change", .label = "Level change", .test_id = "story.slider.pattern.level_change" },
};

pub fn buildSlider(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const feedback = try scope.createSignal(bool, false);
    const state = try scope.createState(SliderFeedbackStory, .{
        .pattern = try scope.createSignal(ui.widgets.slider.HapticFeedbackPattern, .alignment),
        .stepped = try scope.createSignal(f32, 5),
        .continuous = try scope.createSignal(f32, 5),
    });

    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        label("0–100, value 40"),
        v.attrs(.{ .test_id = "story.slider.basic" }, W.Slider(.{
            .label_text = "Basic slider",
            .min = 0,
            .max = 100,
            .value = 40,
            .width = 320,
            .show_value = true,
            .haptic_feedback = feedback,
            .haptic_pattern = state.pattern,
            .test_id = "story.slider.track",
        })),
        label("0–10 step 1, value 5"),
        v.attrs(.{ .test_id = "story.slider.stepped" }, W.Slider(.{
            .label_text = "Stepped slider",
            .min = 0,
            .max = 10,
            .step = 1,
            .value = state.stepped,
            .width = 320,
            .show_value = true,
            .haptic_feedback = feedback,
            .haptic_pattern = state.pattern,
            .test_id = "story.slider.stepped.track",
        })),
        label("Continuous (step 0): no feedback"),
        W.Slider(.{
            .label_text = "Continuous slider",
            .min = 0,
            .max = 10,
            .step = 0,
            .value = state.continuous,
            .width = 320,
            .show_value = true,
            .haptic_feedback = feedback,
            .haptic_pattern = state.pattern,
            .test_id = "story.slider.continuous.track",
        }),
        label("Disabled"),
        W.Slider(.{ .label_text = "Disabled slider", .value = 30, .width = 320, .disabled = true }),
        label("Haptic feedback (opt in): the sliders above snap with a trackpad tick"),
        v.attrs(.{ .test_id = "story.slider.feedback.toggle" }, W.Switch(.{
            .label = "Enable trackpad feedback",
            .checked = feedback,
        })),
        W.RadioGroup(.{
            .options = &slider_pattern_options,
            .value = "alignment",
            .horizontal = true,
            .on_change = ui.on.call(state, SliderFeedbackStory.selectPattern),
        }),
        v.text(.{ .style = S.storyLabel, .test_id = "story.slider.feedback.pattern" }, v.fmt("Pattern: {s}", .{ui.map(state.pattern, SliderFeedbackStory.patternName)})),
        label("Native patterns, not intensity levels. Alignment is the default for step snapping."),
        v.text(.{ .style = S.storyLabel, .test_id = "story.slider.feedback.status" }, v.fmt("Feedback: {s} | stepped: {d:.1} | continuous: {d:.1}", .{
            ui.map(feedback, SliderFeedbackStory.onOff), state.stepped, state.continuous,
        })),
        label("macOS Force Touch trackpad; device and system settings determine the feel."),
        v.attrs(.{ .test_id = "story.slider.feedback.reset" }, W.Button(.{
            .label = "Reset both to 5 (no feedback)",
            .variant = .secondary,
            .on_click = ui.on.call(state, SliderFeedbackStory.reset),
        })),
    }));
}

// ── Switch ──

/// Toggle state echo, e2e asserts "flipping truly changed state", component itself
/// doesn't render current value. Switch story: Signal driven, status from on_change-
/// written `last` derived.
const SwitchStory = struct {
    fn word(value: ?bool) []const u8 {
        const on = value orelse return "(none)";
        return if (on) "on" else "off";
    }
};

pub fn buildSwitch(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const last = try scope.createSignal(?bool, null);
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.attrs(.{ .test_id = "story.switch.off" }, W.Switch(.{
            .label = "Off",
            .on_change = ui.on.assignAs(bool, last),
        })),
        W.Switch(.{ .label = "On", .checked = true }),
        W.Switch(.{ .label = "Disabled", .disabled = true }),
        v.text(.{ .style = S.storyLabel, .test_id = "story.switch.status" }, v.fmt("toggled → {s}", .{ui.map(last, SwitchStory.word)})),
    }));
}

// ── Radio / RadioGroup ──

/// Radio story: selected is signal (RadioGroup data source), status derived from
/// it, independent Radio selected also driven by same signal.
const RadioStory = struct {
    fn word(value: ?[]const u8) []const u8 {
        return value orelse "(none)";
    }

    fn isX(value: ?[]const u8) bool {
        const s = value orelse return false;
        return std.mem.eql(u8, s, "x");
    }
};

const radio_options = [_]ui.widgets.checkbox.RadioOption{
    .{ .value = "x", .label = "Option X" },
    .{ .value = "y", .label = "Option Y" },
    .{ .value = "z", .label = "Option Z" },
};
const radio_plan_options = [_]ui.widgets.checkbox.RadioOption{
    .{ .value = "monthly", .label = "Monthly" },
    .{ .value = "yearly", .label = "Yearly" },
    .{ .value = "lifetime", .label = "Lifetime", .disabled = true },
};

pub fn buildRadio(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const selected = try scope.createSignal(?[]const u8, "x");
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        label("Radio"),
        W.Radio(.{ .label = "Selected", .checked = true }),
        W.Radio(.{ .label = "Unselected", .checked = false }),
        // Independent Radio also driven by derived value
        W.Radio(.{ .label = "Mirrors Option X", .checked = ui.map(selected, RadioStory.isX) }),
        label("RadioGroup"),
        v.attrs(.{ .test_id = "story.radio.group" }, W.RadioGroup(.{ .options = &radio_options, .value = selected })),
        label("Horizontal, one option disabled"),
        v.attrs(.{ .test_id = "story.radio.plan" }, W.RadioGroup(.{ .options = &radio_plan_options, .value = @as(?[]const u8, "monthly"), .horizontal = true })),
        label("Whole group disabled"),
        W.RadioGroup(.{ .options = &radio_plan_options, .value = @as(?[]const u8, "yearly"), .horizontal = true, .disabled = true }),
        v.text(.{ .style = S.storyLabel, .test_id = "story.radio.status" }, v.fmt("selected → {s}", .{ui.map(selected, RadioStory.word)})),
    }));
}

// ── Badge / StatusBadge ──
const InboxStory = struct {
    fn add(n: ?u32) ?u32 {
        return (n orelse 0) + 1;
    }

    fn empty(value: ?u32) bool {
        return (value orelse 0) == 0;
    }
};

const BadgeSpec = struct { t: []const u8, st: W.badge.BadgeStatus };
const badge_statuses = [_]BadgeSpec{
    .{ .t = "info", .st = .info },
    .{ .t = "success", .st = .success },
    .{ .t = "warning", .st = .warning },
    .{ .t = "error", .st = .@"error" },
};
const badge_sizes = [_]W.badge.BadgeSize{ .sm, .md };

fn statusBadge(b: BadgeSpec) BadgeEl {
    return W.Badge(.{ .label = b.t, .status = b.st });
}

fn sizedBadge(sz: W.badge.BadgeSize) BadgeEl {
    return W.Badge(.{ .count = 8, .size = sz });
}

pub fn buildBadge(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Live: count signal drives badge text, zero when derived dot
    const unread = try scope.createSignal(?u32, 3);
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        label("Badge status"),
        v.row(.{ .style = S.line(12) }, v.list(&badge_statuses, statusBadge)),
        label("Count / dot"),
        v.row(.{ .style = S.line(12) }, .{
            W.Badge(.{ .count = 5 }),
            W.Badge(.{ .count = 120, .max_count = 99 }),
            W.Badge(.{ .dot = true }),
        }),
        // -- Sizes --
        label("Sizes (sm / md)"),
        v.row(.{ .style = S.line(12) }, v.list(&badge_sizes, sizedBadge)),
        label("Live inbox (signal-driven)"),
        v.row(.{ .style = S.line(12) }, .{
            v.attrs(.{ .test_id = "story.badge.live" }, W.Badge(.{ .count = unread, .dot = ui.map(unread, InboxStory.empty), .status = .@"error" })),
            v.attrs(.{ .test_id = "story.badge.add" }, W.Button(.{ .label = "+1", .size = .sm, .on_click = ui.on.update(unread, InboxStory.add) })),
            v.attrs(.{ .test_id = "story.badge.clear" }, W.Button(.{ .label = "Clear", .size = .sm, .variant = .secondary, .on_click = ui.on.set(unread, @as(?u32, 0)) })),
        }),
        label("StatusBadge"),
        v.row(.{ .style = S.line(12) }, .{
            W.StatusBadge(.{ .label = "Online", .status = .success }),
            W.StatusBadge(.{ .label = "Error", .status = .@"error" }),
        }),
    }));
}

// ── Card ──

const CardPickStory = struct {
    const Plan = enum { basic, pro };
    fn name(p: Plan) []const u8 {
        return @tagName(p);
    }
};

pub fn buildCard(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Select: two cards' selected from same signal, tap writes signal
    const plan = try scope.createSignal(CardPickStory.Plan, .basic);
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        // -- Variants --
        label("Variants (default / outlined / elevated)"),
        W.Card(.{ .title = "Default", .subtitle = "with subtitle", .variant = .default, .width = 320 }),
        W.Card(.{ .title = "Outlined", .variant = .outlined, .width = 320 }),
        W.Card(.{ .title = "Elevated", .variant = .elevated, .width = 320 }),

        // ── body ──
        label("With body"),
        v.with(W.Card(.{ .title = "Card with body", .width = 320 }), .{
            v.text(.{ .style = S.storyLabel }, "Body content goes here."),
        }),

        // -- Interactive state --
        label("States (selected / hoverable / interactive / no-pad)"),
        W.Card(.{ .title = "Selected", .selected = true, .width = 320 }),
        W.Card(.{ .title = "Hoverable", .hoverable = true, .width = 320 }),
        W.Card(.{ .title = "Interactive", .interactive = true, .width = 320 }),
        W.Card(.{ .title = "No padding", .padded = false, .width = 320 }),

        label("Pick a plan"),
        v.row(.{ .style = S.stack(12) }, .{
            v.attrs(.{ .test_id = "story.card.basic" }, W.Card(.{ .title = "Basic", .subtitle = "Free", .variant = .outlined, .width = 154, .selected = ui.eq(plan, .basic), .on_click = ui.on.set(plan, .basic) })),
            v.attrs(.{ .test_id = "story.card.pro" }, W.Card(.{ .title = "Pro", .subtitle = "$8 / month", .variant = .outlined, .width = 154, .selected = ui.eq(plan, .pro), .on_click = ui.on.set(plan, .pro) })),
        }),
        v.text(.{ .style = S.storyLabel, .test_id = "story.card.status" }, v.fmt("plan → {s}", .{ui.map(plan, CardPickStory.name)})),
    }));
}

// ── Divider ──
const DividerS = struct {
    fn verticalRow(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 12, .align_items = .center, .height = .{ .px = 32 } };
    }
    fn word(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_primary };
    }
};

pub fn buildDivider(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = ui.BoxStyle{ .width = .{ .px = 480 }, .direction = .column, .gap = 16 } }, .{
        // -- Style: solid / dashed / dotted --
        label("Styles (solid / dashed / dotted)"),
        W.Divider(.{ .orientation = .horizontal, .variant = .solid }),
        W.Divider(.{ .orientation = .horizontal, .variant = .dashed }),
        W.Divider(.{ .orientation = .horizontal, .variant = .dotted }),

        // -- with label, three positions --
        label("Labeled (left / center / right)"),
        W.Divider(.{ .label = "LEFT", .label_position = .left }),
        W.Divider(.{ .label = "OR", .label_position = .center }),
        W.Divider(.{ .label = "RIGHT", .label_position = .right }),

        // -- vertical direction --
        label("Vertical"),
        v.row(.{ .style = DividerS.verticalRow }, .{
            v.text(.{ .style = DividerS.word }, "Left"),
            W.Divider(.{ .orientation = .vertical }),
            v.text(.{ .style = DividerS.word }, "Middle"),
            W.Divider(.{ .orientation = .vertical }),
            v.text(.{ .style = DividerS.word }, "Right"),
        }),
    }));
}

// ── Tag ──
const TagColorSpec = struct { c: W.TagColor, t: []const u8 };
const TagSizeSpec = struct { s: W.TagSize, t: []const u8 };
const tag_colors = [_]TagColorSpec{
    .{ .c = .neutral, .t = "neutral" },
    .{ .c = .accent, .t = "accent" },
    .{ .c = .success, .t = "success" },
    .{ .c = .warning, .t = "warning" },
    .{ .c = .danger, .t = "danger" },
    .{ .c = .info, .t = "info" },
};
const tag_sizes = [_]TagSizeSpec{
    .{ .s = .sm, .t = "Small" },
    .{ .s = .md, .t = "Medium" },
};

const TagEl = @TypeOf(W.Tag(.{ .label = "" }));

const TagViews = struct {
    fn colored(s: TagColorSpec) TagEl {
        return W.Tag(.{ .label = s.t, .color = s.c, .closable = true });
    }
    fn outlined(s: TagColorSpec) TagEl {
        return W.Tag(.{ .label = s.t, .color = s.c, .variant = .outline, .closable = true });
    }
    fn sized(s: TagSizeSpec) TagEl {
        return W.Tag(.{ .label = s.t, .color = .accent, .size = s.s });
    }
};

/// Reset handler for demos whose dismissible items each hide via their own signal.
const ResetPair = struct {
    a: *ui.Signal(bool),
    b: *ui.Signal(bool),
    c: ?*ui.Signal(bool) = null,
    fn run(p: ResetPair) void {
        p.a.set(true);
        p.b.set(true);
        if (p.c) |c| c.set(true);
    }
};

pub fn buildTag(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // closable tags really leave: on_close clears their own signal; Reset brings them back
    const beta = try scope.createSignal(bool, true);
    const urgent = try scope.createSignal(bool, true);
    const reset = try ui.on.bind(scope, ResetPair{ .a = beta, .b = urgent }, ResetPair.run);
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        // -- all colors (incl info) --
        label("Colors"),
        v.row(.{ .style = S.line(8) }, v.list(&tag_colors, TagViews.colored)),
        v.row(.{ .style = S.line(8) }, v.list(&tag_colors, TagViews.outlined)),

        // -- Sizes --
        label("Sizes (sm / md)"),
        v.row(.{ .style = S.line(8) }, v.list(&tag_sizes, TagViews.sized)),

        // -- Variants --
        label("Variants"),
        v.row(.{ .style = S.line(8) }, .{
            W.Tag(.{ .label = "Default", .variant = .default }),
            W.Tag(.{ .label = "Outline", .variant = .outline }),
        }),

        // -- Closable: × removes the tag --
        label("Closable"),
        v.row(.{ .style = S.line(8) }, .{
            v.show(beta, .{v.attrs(.{ .test_id = "story.tag.beta" }, W.Tag(.{ .label = "Beta", .color = .accent, .closable = true, .on_close = ui.on.set(beta, false) }))}),
            v.show(urgent, .{v.attrs(.{ .test_id = "story.tag.urgent" }, W.Tag(.{ .label = "Urgent", .variant = .outline, .color = .danger, .closable = true, .on_close = ui.on.set(urgent, false) }))}),
            v.attrs(.{ .test_id = "story.tag.reset" }, W.Button(.{ .label = "Reset", .size = .sm, .variant = .ghost, .on_click = reset })),
        }),
    }));
}

// ── Chip ──
const ChipSizeSpec = struct { s: W.ChipSize, t: []const u8 };
const chip_sizes = [_]ChipSizeSpec{
    .{ .s = .xs, .t = "XS" },
    .{ .s = .sm, .t = "SM" },
    .{ .s = .md, .t = "MD" },
};

fn sizedChip(s: ChipSizeSpec) @TypeOf(W.Chip(.{ .label = "" })) {
    return W.Chip(.{ .label = s.t, .size = s.s, .selected = true });
}

pub fn buildChip(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const icons = ui.assets.common;
    // filter chips: readonly = false makes a chip a toggle; each owns a selected signal
    const f_open = try scope.createSignal(bool, true);
    const f_mine = try scope.createSignal(bool, false);
    const f_urgent = try scope.createSignal(bool, false);
    const folder = try scope.createSignal(bool, true);
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        label("Filter chips (readonly = false: click toggles)"),
        v.row(.{ .style = S.line(8) }, .{
            v.attrs(.{ .test_id = "story.chip.open" }, W.Chip(.{ .label = "Open", .readonly = false, .selected = f_open, .on_click = ui.on.toggle(f_open) })),
            v.attrs(.{ .test_id = "story.chip.mine" }, W.Chip(.{ .label = "Assigned to me", .readonly = false, .selected = f_mine, .on_click = ui.on.toggle(f_mine) })),
            v.attrs(.{ .test_id = "story.chip.urgent" }, W.Chip(.{ .label = "Urgent", .readonly = false, .selected = f_urgent, .on_click = ui.on.toggle(f_urgent) })),
        }),

        // -- Variants (incl disabled) --
        label("Variants"),
        v.row(.{ .style = S.line(8) }, .{
            W.Chip(.{ .label = "Default" }),
            W.Chip(.{ .label = "Active", .selected = true }),
            W.Chip(.{ .label = "Outline", .variant = .outline }),
            W.Chip(.{ .label = "Disabled", .disabled = true }),
            W.Chip(.{ .label = "Closable", .closable = true }),
        }),

        // -- Sizes --
        label("Sizes (xs / sm / md)"),
        v.row(.{ .style = S.line(8) }, v.list(&chip_sizes, sizedChip)),

        // -- with icon --
        label("With icon"),
        v.row(.{ .style = S.line(8) }, .{
            W.Chip(.{ .label = "Starred", .icon_asset = icons.star }),
            v.show(folder, .{v.attrs(.{ .test_id = "story.chip.folder" }, W.Chip(.{ .label = "Folder", .icon_asset = icons.folder, .closable = true, .readonly = false, .on_close = ui.on.set(folder, false) }))}),
        }),
    }));
}

// ── Progress ──
/// Progress Signal demo: one progress signal drives progress (value + state),
/// text mirror and button disabled, all derived declaration, no manual sync.
const UploadStory = struct {
    done: *ui.Signal(f32),

    fn step(s: *UploadStory) void {
        s.done.set(@min(100, s.done.peek() + 10));
    }

    fn reset(s: *UploadStory) void {
        s.done.set(0);
    }

    fn status(pct: f32) W.progress.ProgressStatus {
        return if (pct >= 100) .success else .normal;
    }

    fn full(pct: f32) bool {
        return pct >= 100;
    }
};

const progress_heights = [_]f32{ 2, 4, 8, 12 };

fn heightProgress(h: f32) @TypeOf(W.Progress(.{})) {
    return W.Progress(.{ .value = 50, .width = 320, .height = h });
}

pub fn buildProgress(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const done = try scope.createSignal(f32, 30);
    const upload = try scope.createState(UploadStory, .{ .done = done });
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        label("Live (signal-driven)"),
        v.attrs(.{ .test_id = "story.progress.live" }, W.Progress(.{ .value = done, .status = ui.map(done, UploadStory.status), .width = 320, .show_text = true })),
        v.text(.{ .style = S.storyLabel, .test_id = "story.progress.live.status" }, v.fmt("live = {d:.0}%", .{done})),
        v.row(.{ .style = S.line(8) }, .{
            v.attrs(.{ .test_id = "story.progress.step" }, W.Button(.{ .label = "+10%", .size = .sm, .disabled = ui.map(done, UploadStory.full), .on_click = ui.on.call(upload, UploadStory.step) })),
            v.attrs(.{ .test_id = "story.progress.reset" }, W.Button(.{ .label = "Reset", .size = .sm, .variant = .secondary, .on_click = ui.on.call(upload, UploadStory.reset) })),
        }),

        label("Values 25% / 60% / 100%"),
        W.Progress(.{ .value = 25, .width = 320, .show_text = true }),
        W.Progress(.{ .value = 60, .width = 320, .show_text = true }),
        W.Progress(.{ .value = 100, .width = 320, .status = .success, .show_text = true }),

        label("Heights (2 / 4 / 8 / 12)"),
        v.list(&progress_heights, heightProgress),

        label("Error / indeterminate / no-text"),
        W.Progress(.{ .value = 40, .width = 320, .status = .@"error", .show_text = true }),
        W.Progress(.{ .indeterminate = true, .width = 320 }),
        W.Progress(.{ .value = 70, .width = 320, .show_text = false }),
    }));
}

// ── Spinner ──
pub fn buildSpinner(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // e2e uses dedicated shape node for locate, avoids other content pixel masking
    // spinner draw issue.
    return v.render(scope, cx, v.row(.{ .style = S.line(20), .test_id = "story.spinner.row" }, .{
        v.attrs(.{ .test_id = "story.spinner.0" }, W.Spinner(.{ .size = 16 })),
        v.attrs(.{ .test_id = "story.spinner.1" }, W.Spinner(.{ .size = 24 })),
        v.attrs(.{ .test_id = "story.spinner.2" }, W.Spinner(.{ .size = 36 })),
        // custom colour and stroke
        v.attrs(.{ .test_id = "story.spinner.3" }, W.Spinner(.{ .size = 36, .stroke_width = 2, .color = ui.Color.rgba(52, 199, 89, 255) })),
        v.attrs(.{ .test_id = "story.spinner.4" }, W.Spinner(.{ .size = 36, .stroke_width = 5, .color = ui.Color.rgba(255, 59, 48, 255) })),
    }));
}

// ── Skeleton ──
pub fn buildSkeleton(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Same as spinner: pixel assert locates skeleton shape directly.
    return v.render(scope, cx, v.col(.{ .style = S.stack(12), .test_id = "story.skeleton.col" }, .{
        W.Skeleton(.{ .variant = .text, .width = 280, .height = 14 }),
        W.Skeleton(.{ .variant = .text, .width = 200, .height = 14 }),
        W.Skeleton(.{ .variant = .circular, .width = 48, .height = 48 }),
        W.Skeleton(.{ .variant = .rectangular, .width = 280, .height = 80 }),
    }));
}

// ── Alert ──
pub fn buildAlert(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // closable alerts dismiss themselves through on_close; Restore brings them back
    const a_info = try scope.createSignal(bool, true);
    const a_ok = try scope.createSignal(bool, true);
    const a_warn = try scope.createSignal(bool, true);
    const restore = try ui.on.bind(scope, ResetPair{ .a = a_info, .b = a_ok, .c = a_warn }, ResetPair.run);
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.show(a_info, .{v.attrs(.{ .test_id = "story.alert.info" }, W.Alert(.{ .variant = .info, .title = "A new version is ready", .message = "Update when you’re ready. Your workspace will be restored.", .action_label = "View update", .action_icon_asset = ui.icons.arrow_up_right, .closable = true, .on_close = ui.on.set(a_info, false) }))}),
        v.show(a_ok, .{v.attrs(.{ .test_id = "story.alert.success" }, W.Alert(.{ .variant = .success, .title = "All changes saved", .message = "Your project is up to date across your devices.", .closable = true, .on_close = ui.on.set(a_ok, false) }))}),
        v.show(a_warn, .{v.attrs(.{ .test_id = "story.alert.warning" }, W.Alert(.{ .variant = .warning, .title = "You’re working offline", .message = "Changes stay on this device until you reconnect.", .action_label = "Retry connection", .action_icon_asset = ui.icons.rotate_cw, .closable = true, .on_close = ui.on.set(a_warn, false) }))}),
        // not closable: no × at all
        W.Alert(.{
            .variant = .@"error",
            .title = "We couldn’t save your changes",
            .message = "Your edits are safe. Check your connection and try again.",
            .action_label = "Try again",
            .action_icon_asset = ui.icons.rotate_ccw,
        }),
        // No title (message only)
        W.Alert(.{ .variant = .info, .message = "Title-less alert with just a message." }),
        v.attrs(.{ .test_id = "story.alert.restore" }, W.Button(.{ .label = "Restore", .size = .sm, .variant = .secondary, .on_click = restore })),
    }));
}

// -- Notification (design § 16 in-app global alert) --
pub const buildNotification = @import("notification_story.zig").build;
pub const buildPaintReplay = @import("paint_replay_story.zig").build;

// ── Timeline ──
const timeline_items = [_]W.TimelineItem{
    .{ .title = "Created", .description = "Order placed", .time = "09:00", .status = .completed },
    .{ .title = "Shipped", .description = "In transit", .time = "12:30", .status = .active },
    .{ .title = "Delivered", .description = "Pending", .status = .pending },
};

pub fn buildTimeline(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.box(.{ .style = demoWidth(360) }, .{W.Timeline(.{ .items = &timeline_items })}));
}

// ── Breadcrumb ──
const breadcrumb_items = [_]W.BreadcrumbItem{
    .{ .id = "home", .label = "Home" },
    .{ .id = "lib", .label = "Library" },
    .{ .id = "data", .label = "Data" },
};

pub fn buildBreadcrumb(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // earlier levels report their id; the last level is the current page (not clickable)
    const picked = try scope.createText("(none)", .{});
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.attrs(.{ .test_id = "story.breadcrumb.path" }, W.Breadcrumb(.{ .items = &breadcrumb_items, .on_select = ui.on.assign(picked) })),
        label("Custom separator"),
        W.Breadcrumb(.{ .items = &breadcrumb_items, .separator = "›" }),
        v.text(.{ .style = S.storyLabel, .test_id = "story.breadcrumb.status" }, v.fmt("selected → {s}", .{picked})),
    }));
}

// -- GlassBox / Liquid Glass --
//
// This story group uses public API only: `GlassGroup(.{ .spacing, .scroll_edge })`
// <-> `GlassEffectContainer(spacing:)`, `GlassShape(.{ .shape, .glass_style, .tint_color,
// .interactive, .enabled, .id, .transition })` <-> `.glassEffect(.regular/.clear/
// .identity .tint() .interactive(), in: shape, isEnabled:)`, `glassSetEnabled` <->
// isEnabled + glassEffectTransition(.materialize), `glassMorphTo` <-> glassEffectID.
// Material/blend/transition values come from docs/GLASS_NATIVE_FIDELITY.md native
// measurement; do not hand-tune params in stories.

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

    // -- Grid vertical lines --
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

    // -- Grid horizontal lines --
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

    // -- Text layer: high-frequency detail, blur should become recognizable haze --
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

/// Capsule glass slab: Apple's default glass shape (corner radius = half height). Shadow on
/// wrapper, glass on inner layer: glass node's own shadow expands promoted surface bounds,
/// rectangular chunks on composite (framework bug, see liquid_glass note). Glass foreground:
/// native regular is light matte, foreground must be dark (clear variant uses white).
fn glassInk() ui.Color {
    return ui.Color.rgba(28, 30, 36, 255);
}

/// Icon button in glass capsule (HIG: partition inside glass layer with fill, don't stack
/// glass).
fn glassIconSlot(cx: *ui.Cx, asset: ui.SvgAsset, color: ui.Color) !*ui.Node {
    const slot = try ui.box(cx, .{
        .width = .{ .px = 34 },
        .height = .{ .px = 34 },
        .align_items = .center,
        .justify = .center,
    }, .{});
    var icon_style = ui.Style{};
    icon_style.width = .{ .px = 17 };
    icon_style.height = .{ .px = 17 };
    try slot.appendChild(cx.allocator, try ui.iconTint(cx, asset, color, icon_style));
    return slot;
}

fn glassLabel(cx: *ui.Cx, txt: []const u8, weight: u16, color: ui.Color) !*ui.Node {
    return ui.text(cx, txt, .{ .font_size = 13, .font_weight = weight, .color = color });
}

/// GlassShape body in row (icon / text slot).
fn glassRowBody(entry: ui.widgets.glass_group.GlassShapeEntry) *ui.Node {
    entry.body.style.direction = .row;
    entry.body.style.align_items = .center;
    entry.body.style.gap = 4;
    return entry.body;
}

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

/// Attach drag to node (translate follows hand); GlassShape members recompute shape
/// table at world coords on drag, shapes near same container merge per spacing.
fn attachGlassDrag(scope: *ui.Scope, cx: *ui.Cx, target: *ui.Node) !void {
    const st = try cx.allocator.create(GlassDragState);
    st.* = .{ .cx = cx, .target = target };
    try scope.registerResource(@ptrCast(st), struct {
        fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const state: *GlassDragState = @ptrCast(@alignCast(ptr));
            alloc.destroy(state);
        }
    }.cleanup);
    target.style.cursor = .pointer;
    target.behavior.events.event_context = @ptrCast(st);
    target.behavior.events.on_event = glassDragHandler;
}

pub fn buildGlassBox(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const icons = ui.assets.common;
    const ink = glassInk();
    const c = try col(cx, 20);

    // -- 1. Toolbar: one GlassEffectContainer, two capsule slab (ToolbarSpacer semantic) --
    try c.appendChild(a, try labelNode(cx, "Toolbar: one GlassEffectContainer, two capsule slabs (ToolbarSpacer)"));
    {
        const bd = try glassBackdrop(cx, 130);
        const group = try W.GlassGroup(.{ .spacing = 24, .gap = 16 }).mountWithState(scope, cx);
        const nav = try W.GlassShape(.{ .height = 44, .padding = ui.Padding.symmetric(0, 6), .interactive = true }).mountIn(group, scope, cx);
        inline for (.{ icons.chevron_left, icons.chevron_right }) |asset| {
            try glassRowBody(nav).appendChild(a, try glassIconSlot(cx, asset, ink));
        }
        const actions = try W.GlassShape(.{ .height = 44, .padding = ui.Padding.symmetric(0, 6), .interactive = true }).mountIn(group, scope, cx);
        inline for (.{ icons.plus, icons.folder, icons.star }) |asset| {
            try glassRowBody(actions).appendChild(a, try glassIconSlot(cx, asset, ink));
        }
        try bd.appendChild(a, group.container);
        try c.appendChild(a, bd);
    }

    // -- 2. Tab bar: floating capsule + separate search round button (Tab(role: .search)) --
    try c.appendChild(a, try labelNode(cx, "Tab bar: floating capsule + detached search circle (Tab role .search)"));
    {
        const bd = try glassBackdrop(cx, 130);
        const group = try W.GlassGroup(.{ .spacing = 24, .gap = 12 }).mountWithState(scope, cx);
        const tabbar = try W.GlassShape(.{ .height = 48, .padding = ui.Padding.symmetric(0, 8), .interactive = true }).mountIn(group, scope, cx);
        inline for (.{ "Today", "Library", "Radio" }, .{ icons.calendar, icons.folder_open, icons.scan }) |txt, asset| {
            const item = try ui.box(cx, .{ .direction = .row, .gap = 6, .align_items = .center, .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 } }, .{});
            var icon_style = ui.Style{};
            icon_style.width = .{ .px = 15 };
            icon_style.height = .{ .px = 15 };
            try item.appendChild(a, try ui.iconTint(cx, asset, ink, icon_style));
            try item.appendChild(a, try glassLabel(cx, txt, 550, ink));
            try glassRowBody(tabbar).appendChild(a, item);
        }
        const search = try W.GlassShape(.{ .width = 48, .height = 48, .shape = .circle, .padding = ui.Padding.all(0), .interactive = true }).mountIn(group, scope, cx);
        search.body.style.align_items = .center;
        search.body.style.justify = .center;
        try search.body.appendChild(a, try glassIconSlot(cx, icons.search, ink));
        try bd.appendChild(a, group.container);
        try c.appendChild(a, bd);
    }

    // -- 3. Buttons: .glass and .glassProminent (prominent = Glass.tint + interactive) --
    try c.appendChild(a, try labelNode(cx, "Buttons: .glass and .glassProminent (pressed: the body shifts, no hover change)"));
    {
        const bd = try glassBackdrop(cx, 120);
        const group = try W.GlassGroup(.{ .spacing = 0, .gap = 14 }).mountWithState(scope, cx);
        const plain = try W.GlassShape(.{ .height = 40, .padding = ui.Padding.symmetric(0, 16), .press_feedback = .glass_button }).mountIn(group, scope, cx);
        try glassRowBody(plain).appendChild(a, try glassLabel(cx, "Continue", 600, ink));
        plain.node.meta.ownership.meta.test_id = "story.glassbox.glassbutton";
        const prominent = try W.GlassShape(.{ .height = 40, .padding = ui.Padding.symmetric(0, 16), .press_feedback = .glass_button, .tint_color = ui.Color.rgba(0, 122, 255, 255) }).mountIn(group, scope, cx);
        prominent.node.meta.ownership.meta.test_id = "story.glassbox.prominent";
        try glassRowBody(prominent).appendChild(a, try glassLabel(cx, "Get", 650, ui.Color.WHITE));
        const orange = try W.GlassShape(.{ .height = 40, .padding = ui.Padding.symmetric(0, 16), .press_feedback = .glass_button, .tint_color = ui.Color.rgba(255, 149, 0, 255) }).mountIn(group, scope, cx);
        try glassRowBody(orange).appendChild(a, try glassLabel(cx, "Tinted", 650, ui.Color.WHITE));
        try bd.appendChild(a, group.container);
        try c.appendChild(a, bd);
    }

    // -- 4. Material: .regular / .interactive / .clear (bright media first layer 35% dimming) /
    // isEnabled false -- Title + body cards per HIG rounded rect: `.glassEffect(.regular, in:
    // .rect(cornerRadius: 20))`, width 160, body word-wrapped (same as SwiftUI Text in a fixed
    // frame). A fixed width plus default Capsule and no wrap would overflow the glass right edge
    // and hug the arc, and dynamic width makes one row of four cards overshoot the backboard.
    try c.appendChild(a, try labelNode(cx, "Materials: .regular / .interactive / .clear (over 35% dimmed media) / isEnabled false"));
    {
        const bd = try glassBackdrop(cx, 220);
        const row_box = try ui.box(cx, .{ .direction = .row, .gap = 16, .align_items = .center }, .{});
        const group = try W.GlassGroup(.{ .spacing = 0, .gap = 16 }).mountWithState(scope, cx);
        const card_shape: W.glass_box.GlassBoxShape = .{ .rounded = 20 };
        const card_w: f32 = 160;
        const body_style = ui.TextStyle{ .font_size = 13, .font_weight = 450, .color = cx.tokens.tokens.color.fg_primary, .wrap = .word_break };
        const regular = try W.GlassShape(.{ .title = "Regular", .subtitle = "adaptive, legible", .shape = card_shape, .width = card_w }).mountIn(group, scope, cx);
        try regular.body.appendChild(a, try ui.text(cx, "Functional layer content.", body_style));
        const inter = try W.GlassShape(.{ .title = "Interactive", .subtitle = "hover / press me", .shape = card_shape, .width = card_w, .interactive = true }).mountIn(group, scope, cx);
        try inter.body.appendChild(a, try ui.text(cx, "Glass responds to touch.", body_style));
        inter.node.meta.ownership.meta.test_id = "story.glassbox.interactive";
        const off = try W.GlassShape(.{ .title = "Identity", .subtitle = "isEnabled: false", .shape = card_shape, .width = card_w, .enabled = false }).mountIn(group, scope, cx);
        try off.body.appendChild(a, try ui.text(cx, "No material, content only.", body_style));
        try row_box.appendChild(a, group.container);

        // Clear variant: HIG requires bright media first layer 35% black dimming; own container
        const dimmed = try ui.box(cx, .{
            .direction = .column,
            .padding = ui.Padding.all(10),
            .background = ui.Color.rgba(0, 0, 0, 89), // 35% dimming
        }, .{});
        (try dimmed.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(22);
        const clear_group = try W.GlassGroup(.{ .spacing = 0 }).mountWithState(scope, cx);
        // Dimming corner radius 22, padding 10: concentric 22 - 10 = 12
        const clear = try W.GlassShape(.{ .title = "Clear", .subtitle = "media-rich backdrop", .shape = .{ .rounded = 12 }, .width = card_w, .glass_style = .clear }).mountIn(clear_group, scope, cx);
        var clear_body = body_style;
        clear_body.color = ui.Color.WHITE;
        try clear.body.appendChild(a, try ui.text(cx, "Backdrop shows through.", clear_body));
        try dimmed.appendChild(a, clear_group.container);
        try row_box.appendChild(a, dimmed);

        try bd.appendChild(a, row_box);
        try c.appendChild(a, bd);
    }

    // -- 5. Drag: glasses in same container merge when close, separate when pulled
    // (GlassEffectContainer(spacing:)) --
    try c.appendChild(a, try labelNode(cx, "Drag the glass: live refraction, merges with its neighbour inside one container"));
    {
        const bd = try glassBackdrop(cx, 220);
        const group = try W.GlassGroup(.{ .spacing = 40, .gap = 24 }).mountWithState(scope, cx);
        const anchor = try W.GlassShape(.{ .width = 120, .height = 56, .padding = ui.Padding.all(0) }).mountIn(group, scope, cx);
        anchor.body.style.align_items = .center;
        anchor.body.style.justify = .center;
        try anchor.body.appendChild(a, try glassLabel(cx, "Anchor", 600, ink));
        const drag = try W.GlassShape(.{ .height = 56, .padding = ui.Padding.symmetric(0, 22) }).mountIn(group, scope, cx);
        drag.node.meta.ownership.meta.test_id = "story.glassbox.drag";
        var icon_style = ui.Style{};
        icon_style.width = .{ .px = 18 };
        icon_style.height = .{ .px = 18 };
        try glassRowBody(drag).appendChild(a, try ui.iconTint(cx, icons.mark, ink, icon_style));
        try glassRowBody(drag).appendChild(a, try glassLabel(cx, "Drag me", 650, ink));
        try attachGlassDrag(scope, cx, drag.node);
        try bd.appendChild(a, group.container);
        try c.appendChild(a, bd);
    }

    return c;
}

// -- GlassLab: public API console (variant / tint / shape / interactive / isEnabled /
// spacing) --
//
// Exposes only SwiftUI's outbound Liquid Glass params; material values come from the native
// measurement model and are not tunable. The "Drag me" glass is draggable (gate regression
// anchor: drag geometry + content persist + sidebar scroll no flicker).
const GlassLabStory = struct {
    cx: *ui.Cx,
    group: ui.widgets.glass_group.GlassGroupMount,
    main: ui.widgets.glass_group.GlassShapeEntry,
    companion: ui.widgets.glass_group.GlassShapeEntry,

    fn restyle(self: *GlassLabStory) void {
        self.main.state.last_style = null;
        self.main.node.markRenderDirty();
        self.companion.state.last_style = null;
        self.companion.node.markRenderDirty();
        self.group.state.surface.markRenderDirty();
        self.cx.needs_redraw = true;
    }
    // Variant affects both together: same container shares member 0 blur bank, mixing
    // regular/clear untested config
    fn variantRegular(self: *GlassLabStory) void {
        self.main.state.variant = .regular;
        self.companion.state.variant = .regular;
        self.restyle();
    }
    fn variantClear(self: *GlassLabStory) void {
        self.main.state.variant = .clear;
        self.companion.state.variant = .clear;
        self.restyle();
    }
    fn tintNone(self: *GlassLabStory) void {
        self.main.state.tint_override = null;
        self.restyle();
    }
    fn tintBlue(self: *GlassLabStory) void {
        self.main.state.tint_override = ui.Color.rgba(0, 122, 255, 255);
        self.restyle();
    }
    fn tintOrange(self: *GlassLabStory) void {
        self.main.state.tint_override = ui.Color.rgba(255, 149, 0, 255);
        self.restyle();
    }
    fn shapeCapsule(self: *GlassLabStory) void {
        self.main.state.shape = .capsule;
        self.restyle();
    }
    fn shapeRounded(self: *GlassLabStory) void {
        self.main.state.shape = .{ .rounded = 12 };
        self.restyle();
    }
    fn shapeRect(self: *GlassLabStory) void {
        self.main.state.shape = .{ .rounded = 2 };
        self.restyle();
    }
    fn interactiveChanged(self: *GlassLabStory, on: bool) void {
        self.main.state.interactive = on;
        self.main.state.hovered = false;
        self.main.state.pressed = false;
        self.restyle();
    }
    fn enabledChanged(self: *GlassLabStory, on: bool) void {
        ui.widgets.glass_box.glassSetEnabled(self.main.state, on);
    }
    fn spacingChanged(self: *GlassLabStory, val: f32) void {
        self.group.state.spacing = val;
        self.group.state.link.base_spacing = val;
        self.group.state.table.spacing = val;
        self.group.state.table.version +%= 1;
        self.group.state.surface.markRenderDirty();
        self.cx.needs_redraw = true;
    }
    fn gapChanged(self: *GlassLabStory, val: f32) void {
        self.group.container.style.gap = val;
        self.group.container.markLayoutDirty();
        self.cx.needs_redraw = true;
    }
};

fn labButton(scope: *ui.Scope, cx: *ui.Cx, st: *GlassLabStory, txt: []const u8, comptime handler: fn (*GlassLabStory) void) !*ui.Node {
    return W.Button(.{ .label = txt, .variant = .secondary, .on_click = cx.on(GlassLabStory, st, handler) }).mount(scope, cx);
}

fn labSlider(scope: *ui.Scope, cx: *ui.Cx, st: *GlassLabStory, txt: []const u8, min: f32, max: f32, step: f32, default: f32, comptime handler: fn (*GlassLabStory, f32) void) !*ui.Node {
    const prow = try ui.box(cx, .{ .direction = .column, .gap = 2 }, .{});
    try prow.appendChild(cx.allocator, try ui.text(cx, txt, .{ .font_size = 12, .color = light.tokens.color.fg_secondary }));
    const sig = try scope.createSignal(f32, default);
    const sl = try W.Slider(.{ .min = min, .max = max, .step = step, .value = sig, .width = 220, .show_value = true, .on_change = cx.on(GlassLabStory, st, handler) }).mount(scope, cx);
    try prow.appendChild(cx.allocator, sl.wrapper);
    return prow;
}

pub fn buildGlassLab(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const ink = glassInk();
    const c = try col(cx, 16);

    // -- Stage: two glass in one container, right draggable, near left companion merges --
    const bd = try glassBackdrop(cx, 300);
    const group = try W.GlassGroup(.{ .spacing = 40, .gap = 40, .merge = .always }).mountWithState(scope, cx);
    const companion = try W.GlassShape(.{ .width = 120, .height = 56, .padding = ui.Padding.all(0) }).mountIn(group, scope, cx);
    companion.body.style.align_items = .center;
    companion.body.style.justify = .center;
    try companion.body.appendChild(a, try glassLabel(cx, "Companion", 600, ink));
    const main = try W.GlassShape(.{ .width = 180, .height = 56, .padding = ui.Padding.all(0), .interactive = true }).mountIn(group, scope, cx);
    main.node.meta.ownership.meta.test_id = "story.glasslab.drag";
    main.body.style.align_items = .center;
    main.body.style.justify = .center;
    try main.body.appendChild(a, try glassLabel(cx, "Drag me", 650, ink));
    try attachGlassDrag(scope, cx, main.node);
    try bd.appendChild(a, group.container);
    try c.appendChild(a, bd);

    const st = try cx.bindState(GlassLabStory, .{ .cx = cx, .group = group, .main = main, .companion = companion });

    // -- Console: public API only --
    const panel = try ui.box(cx, .{ .direction = .row, .gap = 24 }, .{});
    const left = try col(cx, 10);
    const right = try col(cx, 10);

    try left.appendChild(a, try labelNode(cx, "Glass variant (.regular / .clear)"));
    const variants = try row(cx, 8);
    try variants.appendChild(a, try labButton(scope, cx, st, "Regular", GlassLabStory.variantRegular));
    try variants.appendChild(a, try labButton(scope, cx, st, "Clear", GlassLabStory.variantClear));
    try left.appendChild(a, variants);

    try left.appendChild(a, try labelNode(cx, "Tint (Glass.tint)"));
    const tints = try row(cx, 8);
    try tints.appendChild(a, try labButton(scope, cx, st, "None", GlassLabStory.tintNone));
    try tints.appendChild(a, try labButton(scope, cx, st, "Blue", GlassLabStory.tintBlue));
    try tints.appendChild(a, try labButton(scope, cx, st, "Orange", GlassLabStory.tintOrange));
    try left.appendChild(a, tints);

    try left.appendChild(a, try labelNode(cx, "Shape (in:)"));
    const shapes = try row(cx, 8);
    try shapes.appendChild(a, try labButton(scope, cx, st, "Capsule", GlassLabStory.shapeCapsule));
    try shapes.appendChild(a, try labButton(scope, cx, st, "Rounded 12", GlassLabStory.shapeRounded));
    try shapes.appendChild(a, try labButton(scope, cx, st, "Rect", GlassLabStory.shapeRect));
    try left.appendChild(a, shapes);

    try right.appendChild(a, try W.Switch(.{ .label = "Interactive (.interactive())", .checked = true, .on_change = cx.on(GlassLabStory, st, GlassLabStory.interactiveChanged) }).mount(scope, cx));
    try right.appendChild(a, try W.Switch(.{ .label = "Enabled (isEnabled + materialize)", .checked = true, .on_change = cx.on(GlassLabStory, st, GlassLabStory.enabledChanged) }).mount(scope, cx));
    try right.appendChild(a, try labSlider(scope, cx, st, "Container spacing (GlassEffectContainer(spacing:))", 0, 80, 4, 40, GlassLabStory.spacingChanged));
    try right.appendChild(a, try labSlider(scope, cx, st, "Gap to companion", 0, 120, 4, 40, GlassLabStory.gapChanged));

    try panel.appendChild(a, left);
    try panel.appendChild(a, right);
    try c.appendChild(a, panel);
    return c;
}

// -- GlassEdge: glass flush with the window's edges --
//
// Glass that reaches a window edge samples past it: the backdrop capture beyond the window RT is
// transparent black, and a glass shader that does not normalise by coverage blurs it in as a
// dark fringe along the edge. The story is a small app scene in the content area (the sidebar
// and the story header stay clear): a smooth colour wallpaper with a few photo cards runs out to
// the window's right and bottom edges; an inspector panel is flush with the right and bottom
// edges (below the header), a toolbar with the bottom edge. The left and top window edges belong
// to Storybook's sidebar and header, which the story leaves alone. The wallpaper changes slowly along each edge's normal,
// so a correct edge reads like the glass a little further in, and a fringe shows as a dark rim
// on colour. Everything sits in the popover portal (whole window), hit-test transparent (no
// handlers), and is detached with the story scope.
const edge_sidebar_w: f32 = 216; // Storybook floating sidebar 8 + 200 + 8 gutter
const edge_wallpaper_top: f32 = 164; // below the title bar and the story note
const edge_inspector_w: f32 = 260;
const edge_header_h: f32 = 52; // Storybook's title bar

fn edgeCard(cx: *ui.Cx, left: f32, top: f32, w: f32, h: f32, c0: ui.Color, c1: ui.Color) !*ui.Node {
    const n = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = w }, .height = .{ .px = h } }, .{});
    const ext = try n.style.ensureExtFallible(cx.allocator);
    ext.inset = .{ .left = .{ .px = left }, .top = .{ .px = top } };
    ext.corner_radius = ui.CornerRadius.uniform(14);
    ext.multi_gradient = ui.MultiGradient.fromSlice(&[_]ui.GradientStop{ .{ .color = c0, .position = 0 }, .{ .color = c1, .position = 1 } }, .diagonal);
    return n;
}

fn edgeLayer(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{ .position = .absolute, .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .row }, .{});
}

pub fn buildGlassEdge(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    // (the story's own panel stays empty: the scene is the window around it)
    const c = try ui.box(cx, .{ .width = .{ .px = 1 }, .height = .{ .px = 1 } }, .{});
    const portal = cx.popover_portal_root orelse return c;

    const overlay = try edgeLayer(cx);
    overlay.meta.ownership.meta.test_id = "story.glassedge.overlay";

    // Wallpaper: the content area right of the sidebar, below the header, out to the window's
    // right and bottom edges
    const wall_layer = try edgeLayer(cx);
    try wall_layer.appendChild(a, try ui.box(cx, .{ .width = .{ .px = edge_sidebar_w }, .height = .{ .grow = .{} } }, .{}));
    const wall_col = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .column }, .{});
    try wall_col.appendChild(a, try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = edge_wallpaper_top } }, .{}));
    const wall = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .position = .relative, .overflow_hidden = true }, .{});
    wall.meta.ownership.meta.test_id = "story.glassedge.wallpaper";
    (try wall.style.ensureExtFallible(a)).multi_gradient = ui.MultiGradient.fromSlice(&[_]ui.GradientStop{
        .{ .color = ui.Color.rgba(255, 196, 120, 255), .position = 0.0 },
        .{ .color = ui.Color.rgba(255, 128, 150, 255), .position = 0.35 },
        .{ .color = ui.Color.rgba(150, 120, 240, 255), .position = 0.7 },
        .{ .color = ui.Color.rgba(90, 170, 255, 255), .position = 1.0 },
    }, .diagonal);
    // photo cards: clear of the window edges (>= 100 pt), one running in under the inspector
    try wall.appendChild(a, try edgeCard(cx, 48, 48, 200, 140, ui.Color.rgba(255, 94, 58, 255), ui.Color.rgba(255, 204, 0, 255)));
    try wall.appendChild(a, try edgeCard(cx, 272, 48, 200, 140, ui.Color.rgba(52, 199, 89, 255), ui.Color.rgba(0, 199, 190, 255)));
    try wall.appendChild(a, try edgeCard(cx, 48, 212, 200, 140, ui.Color.rgba(0, 122, 255, 255), ui.Color.rgba(88, 86, 214, 255)));
    try wall.appendChild(a, try edgeCard(cx, 496, 212, 240, 160, ui.Color.rgba(175, 82, 222, 255), ui.Color.rgba(255, 45, 85, 255)));
    try wall.appendChild(a, try edgeCard(cx, 272, 212, 200, 140, ui.Color.rgba(30, 30, 40, 255), ui.Color.rgba(90, 90, 110, 255)));
    try wall_col.appendChild(a, wall);
    try wall_layer.appendChild(a, wall_col);
    try overlay.appendChild(a, wall_layer);

    const ink = ui.Color.rgba(20, 20, 24, 255);
    // Inspector: flush with the right and bottom edges, below the Storybook header (its
    // controls stay clear)
    const insp_layer = try edgeLayer(cx);
    insp_layer.style.direction = .column;
    insp_layer.style.align_items = .end;
    try insp_layer.appendChild(a, try ui.box(cx, .{ .width = .{ .px = 1 }, .height = .{ .px = edge_header_h } }, .{}));
    const right_m = try W.GlassBox(.{ .width = edge_inspector_w, .height = 1, .corner_radius = 16, .padding = ui.Padding.all(20), .body_gap = 10 }).mountWithState(scope, cx);
    const right = right_m.box;
    right.style.height = .{ .grow = .{} };
    right.meta.ownership.meta.test_id = "story.glassedge.right";
    try right_m.body.appendChild(a, try ui.text(cx, "Inspector", .{ .font_size = 17, .font_weight = 600, .color = ink }));
    inline for (.{ "Fill", "Stroke", "Shadow", "Blur" }) |name| {
        try right_m.body.appendChild(a, try ui.text(cx, name, .{ .font_size = 13, .color = ink }));
    }
    try insp_layer.appendChild(a, right);
    try overlay.appendChild(a, insp_layer);

    // Toolbar: flush with the bottom edge, centred between the sidebar and the inspector
    const bar_layer = try edgeLayer(cx);
    try bar_layer.appendChild(a, try ui.box(cx, .{ .width = .{ .px = edge_sidebar_w }, .height = .{ .grow = .{} } }, .{}));
    const bar_col = try ui.box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .direction = .column, .justify = .end, .align_items = .center }, .{});
    const bar_m = try W.GlassBox(.{ .width = 320, .height = 60, .corner_radius = 20, .padding = ui.Padding.all(0) }).mountWithState(scope, cx);
    const bar = bar_m.box;
    bar.meta.ownership.meta.test_id = "story.glassedge.bottom";
    bar_m.body.style.align_items = .center;
    bar_m.body.style.justify = .center;
    try bar_m.body.appendChild(a, try ui.text(cx, "Edge to edge", .{ .font_size = 15, .font_weight = 600, .color = ink }));
    try bar_col.appendChild(a, bar);
    try bar_layer.appendChild(a, bar_col);
    try bar_layer.appendChild(a, try ui.box(cx, .{ .width = .{ .px = edge_inspector_w }, .height = .{ .grow = .{} } }, .{}));
    try overlay.appendChild(a, bar_layer);

    try portal.appendChild(a, overlay);
    // Portal subtree not in story panel subtree, must explicitly detach on story scope
    // dispose, else the glass permanently stacks on all later stories (glassislands e2e caught).
    const Detach = struct { cx: *ui.Cx, portal: *ui.Node, overlay: *ui.Node };
    const d = try a.create(Detach);
    d.* = .{ .cx = cx, .portal = portal, .overlay = overlay };
    try scope.registerResource(@ptrCast(d), struct {
        fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const ctx: *Detach = @ptrCast(@alignCast(ptr));
            // Same as Show unload: detachChild + cx.freeNode (reclaim ElementTable slot +
            // tick_depth defer guard), only removeChild leaks entire tree (GPA captured).
            ctx.cx.detachChild(ctx.portal, ctx.overlay);
            ctx.cx.freeNode(ctx.overlay);
            alloc.destroy(ctx);
        }
    }.cleanup);
    return c;
}

// -- GlassGroup (M2): container samples once, composites N shapes; pixel-equivalent to a
// single GlassBox --
//
// Two rows in two **identical** backboards (same size, centered): top three independent
// GlassBox, bottom three as GlassGroup members. e2e compares rows per pixel (incl rim /
// shadow outer); mean difference near 0 is the M2 "N=1 equivalent" exit condition. Boards
// are 144px apart (multiple of 8, aligning the window-anchored blur bank grid phase).
pub fn buildGlassGroup(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);

    const bd_single = try glassBackdrop(cx, 128);
    const single = try ui.box(cx, .{ .direction = .row, .gap = 12, .align_items = .center }, .{});
    single.meta.ownership.meta.test_id = "story.glassgroup.single";
    try single.appendChild(a, try W.GlassBox(.{ .title = "Back", .width = 120, .height = 44, .shape = .capsule, .padding = ui.Padding.symmetric(6, 18) }).mount(scope, cx));
    try single.appendChild(a, try W.GlassBox(.{ .width = 44, .height = 44, .shape = .circle, .padding = ui.Padding.all(0) }).mount(scope, cx));
    try single.appendChild(a, try W.GlassBox(.{ .title = "Share", .width = 150, .height = 44, .shape = .capsule, .tint_color = ui.Color.rgba(0, 122, 255, 255), .padding = ui.Padding.symmetric(6, 18) }).mount(scope, cx));
    try single.appendChild(a, try W.GlassBox(.{ .title = "Clear", .width = 110, .height = 44, .shape = .capsule, .glass_style = .clear, .padding = ui.Padding.symmetric(6, 18) }).mount(scope, cx));
    try bd_single.appendChild(a, single);
    try c.appendChild(a, bd_single);

    const bd_group = try glassBackdrop(cx, 128);
    // spacing = 0: turn off merge attraction (native adjacent shapes bulge outward even
    // unmerged at spacing>0), row only validates "one-sample composite" vs single pixel.
    // Same container shares member 0 blur bank: clear and regular separate groups (each own
    // GlassEffectContainer)
    const group_row = try ui.box(cx, .{ .direction = .row, .gap = 12, .align_items = .center }, .{});
    group_row.meta.ownership.meta.test_id = "story.glassgroup.group";
    const group = try W.GlassGroup(.{ .spacing = 0, .gap = 12 }).mountWithState(scope, cx);
    _ = try W.GlassShape(.{ .title = "Back", .width = 120, .height = 44, .shape = .capsule, .padding = ui.Padding.symmetric(6, 18) }).mountIn(group, scope, cx);
    _ = try W.GlassShape(.{ .width = 44, .height = 44, .shape = .circle, .padding = ui.Padding.all(0) }).mountIn(group, scope, cx);
    _ = try W.GlassShape(.{ .title = "Share", .width = 150, .height = 44, .shape = .capsule, .tint_color = ui.Color.rgba(0, 122, 255, 255), .padding = ui.Padding.symmetric(6, 18) }).mountIn(group, scope, cx);
    try group_row.appendChild(a, group.container);
    const clear_group = try W.GlassGroup(.{ .spacing = 0 }).mountWithState(scope, cx);
    _ = try W.GlassShape(.{ .title = "Clear", .width = 110, .height = 44, .shape = .capsule, .glass_style = .clear, .padding = ui.Padding.symmetric(6, 18) }).mountIn(clear_group, scope, cx);
    try group_row.appendChild(a, clear_group.container);
    try bd_group.appendChild(a, group_row);
    try c.appendChild(a, bd_group);
    return c;
}

// -- GlassMerge (M3): two capsules in a GlassGroup merge per spacing/gap, matching the
// native measured neck --
//
// Native GlassEffectContainer measured (native_container_merge.swift, gray 128 base,
// 120x44 capsule): S=40: gap 16/8/0 -> neck 36/58/70 physical px; S=80: 36/20/0 ->
// 36/74/92; S=20: 8/0 -> 26/54. e2e measures the Zenit neck on the same gray and compares.
pub fn buildGlassMerge(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 10);
    const cases = .{ .{ 40, 16 }, .{ 40, 8 }, .{ 40, 0 }, .{ 80, 36 }, .{ 80, 20 }, .{ 80, 0 }, .{ 20, 8 }, .{ 20, 0 } };
    var merge_row: ?*ui.Node = null;
    inline for (cases, 0..) |cs, i| {
        if (i % 2 == 0) {
            merge_row = try ui.box(cx, .{ .direction = .row, .gap = 12, .width = .{ .grow = .{} } }, .{});
            try c.appendChild(a, merge_row.?);
        }
        const bd = try ui.box(cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 84 },
            .direction = .row,
            .align_items = .center,
            .justify = .center,
            .background = ui.Color.rgba(128, 128, 128, 255),
        }, .{});
        const group = try W.GlassGroup(.{ .spacing = cs[0], .gap = cs[1], .merge = .always }).mountWithState(scope, cx);
        group.container.meta.ownership.meta.test_id = std.fmt.comptimePrint("story.glassmerge.s{d}.g{d}", .{ cs[0], cs[1] });
        _ = try W.GlassShape(.{ .width = 120, .height = 44, .shape = .capsule, .padding = ui.Padding.all(0) }).mountIn(group, scope, cx);
        _ = try W.GlassShape(.{ .width = 120, .height = 44, .shape = .capsule, .padding = ui.Padding.all(0) }).mountIn(group, scope, cx);
        try bd.appendChild(a, group.container);
        try merge_row.?.appendChild(a, bd);
    }
    return c;
}

// -- GlassTintMerge: different-tint glass merging in a container (native same geometry,
// gray 128 / white base) --
//
// Geometry identical to scripts/glass_native_model/native_tint_merge.swift: 640x480
// stage, 10 groups GlassEffectContainer(spacing: 40), each two 120x44 capsules (HStack
// gap, negative = overlap), group center x = 165 / 475, y = 48 + 96*row. Native rule:
// the bridge is base glass with no tint, Glass.tint only fills member shapes (outer ~5px
// soft edge), and overlaps apply tint in layers.
const tint_cases = [_]struct { a: ?ui.Color, b: ?ui.Color, gap: f32 }{
    .{ .a = null, .b = sys_blue, .gap = 0 },       .{ .a = null, .b = sys_blue, .gap = 12 },
    .{ .a = sys_blue, .b = sys_orange, .gap = 0 }, .{ .a = sys_blue, .b = sys_orange, .gap = 12 },
    .{ .a = null, .b = sys_blue, .gap = -30 },     .{ .a = sys_blue, .b = sys_orange, .gap = -30 },
    .{ .a = sys_blue, .b = sys_blue, .gap = 12 },  .{ .a = null, .b = null, .gap = 12 },
    .{ .a = sys_red, .b = sys_green, .gap = 4 },   .{ .a = sys_orange, .b = null, .gap = 4 },
};
// macOS 26 light appearance NSColor.systemBlue/Orange/Red/Green (sRGB), i.e. SwiftUI
// .blue etc
const sys_blue = ui.Color.rgba(0, 136, 255, 255);
const sys_orange = ui.Color.rgba(255, 141, 40, 255);
const sys_red = ui.Color.rgba(255, 56, 60, 255);
const sys_green = ui.Color.rgba(52, 199, 89, 255);
/// native_tint_overlap.swift 10 groups: two capsule overlap 60px (latter on top)
const tint_overlap_cases = [_]struct { a: ?ui.Color, b: ?ui.Color, gap: f32 }{
    .{ .a = sys_blue, .b = sys_orange, .gap = -60 }, .{ .a = sys_orange, .b = sys_blue, .gap = -60 },
    .{ .a = sys_red, .b = sys_green, .gap = -60 },   .{ .a = sys_green, .b = sys_red, .gap = -60 },
    .{ .a = sys_blue, .b = sys_blue, .gap = -60 },   .{ .a = sys_orange, .b = sys_orange, .gap = -60 },
    .{ .a = null, .b = sys_blue, .gap = -60 },       .{ .a = sys_blue, .b = null, .gap = -60 },
    .{ .a = null, .b = sys_orange, .gap = -60 },     .{ .a = sys_orange, .b = null, .gap = -60 },
};
fn glassTintStage(scope: *ui.Scope, cx: *ui.Cx, gray: u8, test_id: []const u8) !*ui.Node {
    return glassTintStageCases(scope, cx, gray, test_id, &tint_cases);
}
fn glassTintStageCases(scope: *ui.Scope, cx: *ui.Cx, gray: u8, test_id: []const u8, cases: anytype) !*ui.Node {
    const a = cx.allocator;
    const stage = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .position = .relative, .background = ui.Color.rgba(gray, gray, gray, 255) }, .{});
    stage.meta.ownership.meta.test_id = test_id;
    for (cases, 0..) |tc, i| {
        const ccx: f32 = if (i % 2 == 0) 165 else 475;
        const ccy: f32 = 48 + 96 * @as(f32, @floatFromInt(i / 2));
        const total = 240 + tc.gap;
        const g = try W.GlassGroup(.{ .spacing = 40, .merge = .always, .width = 300, .height = 44 }).mountWithState(scope, cx);
        g.container.style.position = .absolute;
        const gx = ccx - 150;
        (try g.container.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = gx }, .top = .{ .px = ccy - 22 } };
        const x0 = ccx - total / 2 - gx;
        inline for (.{ 0, 1 }) |k| {
            const tint = if (k == 0) tc.a else tc.b;
            const e = try W.GlassShape(.{ .width = 120, .height = 44, .shape = .capsule, .tint_color = tint, .padding = ui.Padding.all(0) }).mountIn(g, scope, cx);
            e.node.style.position = .absolute;
            const mx = if (k == 0) x0 else x0 + 120 + tc.gap;
            (try e.node.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = mx }, .top = .{ .px = 0 } };
        }
        try stage.appendChild(a, g.container);
    }
    return stage;
}
/// native_tint_backdrop.swift grid (first 5 columns bg): row = tint (orange/blue/red/
/// green/none), column = bg (white/gray 128/black/blue/orange), each 160x112, center
/// 120x44 capsule.
fn glassTintBackdropGrid(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const a = cx.allocator;
    const tints = [_]?ui.Color{ sys_orange, sys_blue, sys_red, sys_green, null };
    const backs = [_]ui.Color{ ui.Color.rgba(255, 255, 255, 255), ui.Color.rgba(128, 128, 128, 255), ui.Color.rgba(0, 0, 0, 255), sys_blue, sys_orange };
    const grid = try ui.box(cx, .{ .direction = .column, .width = .{ .px = 800 }, .height = .{ .px = 560 } }, .{});
    grid.meta.ownership.meta.test_id = "story.glasstint.backdrops";
    for (tints) |t| {
        const grid_row = try ui.box(cx, .{ .direction = .row, .height = .{ .px = 112 } }, .{});
        for (backs) |b| {
            const cell = try ui.box(cx, .{ .width = .{ .px = 160 }, .height = .{ .px = 112 }, .align_items = .center, .justify = .center, .background = b }, .{});
            const g = try W.GlassGroup(.{ .spacing = 0 }).mountWithState(scope, cx);
            _ = try W.GlassShape(.{ .width = 120, .height = 44, .shape = .capsule, .tint_color = t, .padding = ui.Padding.all(0) }).mountIn(g, scope, cx);
            try cell.appendChild(a, g.container);
            try grid_row.appendChild(a, cell);
        }
        try grid.appendChild(a, grid_row);
    }
    return grid;
}

pub fn buildGlassTintMerge(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try glassTintStage(scope, cx, 255, "story.glasstint.white"));
    try c.appendChild(a, try labelNode(cx, "Same cases over gray 128"));
    try c.appendChild(a, try glassTintStage(scope, cx, 128, "story.glasstint.gray"));
    try c.appendChild(a, try labelNode(cx, "Overlapping tints (60 px, the second on top): the top colour dominates, darkened by the layer below; the same tint over itself is unchanged"));
    try c.appendChild(a, try glassTintStageCases(scope, cx, 255, "story.glasstint.overlap", &tint_overlap_cases));
    try c.appendChild(a, try labelNode(cx, "Tinted glass over solid backdrops (native_tint_backdrop.swift grid; an inactive window drops the tint for a gray coating)"));
    try c.appendChild(a, try glassTintBackdropGrid(scope, cx));
    return c;
}

// GlassUnion: glassEffectUnion(id:) static composite (native same-geometry control, gray
// 128). Same as scripts/glass_native_model/native_union.swift (640x480 stage): members of
// same union id composite their collective bounding box shape, regardless of spacing / height
// diff / offset; other ids in between same.
fn glassUnionRow(scope: *ui.Scope, cx: *ui.Cx, stage: *ui.Node, cy: f32, spacing: f32, members: []const [5]f32, ids: []const []const u8) !void {
    const a = cx.allocator;
    var min_x: f32 = 1e9;
    var max_x: f32 = -1e9;
    for (members) |m| {
        min_x = @min(min_x, m[0]);
        max_x = @max(max_x, m[0] + m[2]);
    }
    const g = try W.GlassGroup(.{ .spacing = spacing, .merge = .always, .width = max_x - min_x, .height = 120 }).mountWithState(scope, cx);
    g.container.style.position = .absolute;
    (try g.container.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 320 - (max_x - min_x) / 2 }, .top = .{ .px = cy - 60 } };
    for (members, 0..) |m, k| {
        const e = try W.GlassShape(.{ .width = m[2], .height = m[3], .shape = .capsule, .padding = ui.Padding.all(0), .union_id = ids[k] }).mountIn(g, scope, cx);
        e.node.style.position = .absolute;
        (try e.node.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = m[0] - min_x }, .top = .{ .px = 60 - m[3] / 2 + m[4] } };
        _ = m[1];
    }
    try stage.appendChild(a, g.container);
}
pub fn buildGlassUnion(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const stage = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255) }, .{});
    stage.meta.ownership.meta.test_id = "story.glassunion.stage";
    // {x, -, w, h, dy}: x in-row position (HStack layout), dy vertical offset from row center
    try glassUnionRow(scope, cx, stage, 60, 20, &.{ .{ 0, 0, 80, 80, 0 }, .{ 100, 0, 80, 80, 0 }, .{ 200, 0, 80, 80, 0 }, .{ 300, 0, 80, 80, 0 } }, &.{ "1", "1", "2", "2" });
    try glassUnionRow(scope, cx, stage, 150, 20, &.{ .{ 0, 0, 100, 44, 0 }, .{ 140, 0, 100, 44, 0 }, .{ 280, 0, 100, 44, 0 } }, &.{ "u1", "u1", "u1" });
    try glassUnionRow(scope, cx, stage, 230, 20, &.{ .{ 0, 0, 120, 44, 0 }, .{ 136, 0, 60, 60, 0 } }, &.{ "u2", "u2" });
    try glassUnionRow(scope, cx, stage, 320, 20, &.{ .{ 0, 0, 100, 44, -15 }, .{ 120, 0, 100, 44, 15 } }, &.{ "u3", "u3" });
    try glassUnionRow(scope, cx, stage, 420, 12, &.{ .{ 0, 0, 90, 44, 0 }, .{ 102, 0, 90, 44, 0 }, .{ 204, 0, 90, 44, 0 } }, &.{ "a", "b", "a" });
    try c.appendChild(a, stage);
    return c;
}

// -- BlendLab: blend space reference (docs/SRGB_BLENDING_PLAN.md M0) -- Same geometry
// as scripts/glass_native_model/native_blend_reference.swift (640x760, per-section see script
// header comment): half-transparent fill, layer opacity, text, gradient,
// shadow, corner AA edge and scaled image.
/// 32x32 checkerboard texture (8px squares), registered on storybook main start; null =
/// not registered (image slot empty). Texture slot alloc from 0, can't use 0 as sentinel.
pub var g_blend_checker_texture: ?u32 = null;

fn blendAbs(cx: *ui.Cx, parent: *ui.Node, x: f32, y: f32, w: f32, h: f32, color: ui.Color) !*ui.Node {
    const a = cx.allocator;
    const n = try ui.box(cx, .{ .width = .{ .px = w }, .height = .{ .px = h }, .position = .absolute, .background = color }, .{});
    (try n.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = x }, .top = .{ .px = y } };
    try parent.appendChild(a, n);
    return n;
}

pub fn buildBlendLab(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 12);
    const stage = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 760 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255), .overflow_hidden = true }, .{});
    stage.meta.ownership.meta.test_id = "story.blendlab.stage";
    const white = ui.Color.rgba(255, 255, 255, 255);
    const gray = ui.Color.rgba(128, 128, 128, 255);
    const black = ui.Color.rgba(0, 0, 0, 255);
    const red = ui.Color.rgba(255, 59, 48, 255);
    const blue = ui.Color.rgba(0, 122, 255, 255);
    const fills = [_]ui.Color{ black, white, red, blue };
    const alphas = [_]f32{ 0.1, 0.3, 0.5, 0.7, 0.9 };
    const bands = [_]ui.Color{ white, gray, black };
    // Fill
    for (bands, 0..) |band, b| {
        const by: f32 = @floatFromInt(b * 80);
        _ = try blendAbs(cx, stage, 0, by, 640, 80, band);
        for (0..20) |i| {
            var col_ = fills[i / 5];
            col_.a = @intFromFloat(@round(alphas[i % 5] * 255));
            _ = try blendAbs(cx, stage, 8 + 32 * @as(f32, @floatFromInt(i)), by + 25, 28, 30, col_);
        }
    }
    // Layer opacity
    for (bands, 0..) |band, b| {
        const bx: f32 = @floatFromInt(b * 213);
        _ = try blendAbs(cx, stage, bx, 240, 214, 80, band);
        for ([_]f32{ 0.25, 0.5, 0.75 }, 0..) |op, j| {
            const g = try blendAbs(cx, stage, bx + 20 + 65 * @as(f32, @floatFromInt(j)), 260, 40, 40, white);
            _ = try blendAbs(cx, g, 10, 10, 20, 20, red);
            g.setOpacity(op);
        }
    }
    // Text
    _ = try blendAbs(cx, stage, 0, 320, 640, 80, white);
    _ = try blendAbs(cx, stage, 0, 400, 640, 60, gray);
    _ = try blendAbs(cx, stage, 0, 460, 640, 60, black);
    const Row = struct { y: f32, size: f32, weight: u16, color: ui.Color };
    const rows = [_]Row{
        .{ .y = 326, .size = 11, .weight = 400, .color = black },
        .{ .y = 344, .size = 13, .weight = 400, .color = black },
        .{ .y = 364, .size = 13, .weight = 400, .color = ui.Color.rgba(0, 0, 0, 217) },
        .{ .y = 382, .size = 13, .weight = 400, .color = ui.Color.rgba(0, 0, 0, 128) },
        .{ .y = 404, .size = 13, .weight = 400, .color = white },
        .{ .y = 422, .size = 13, .weight = 500, .color = black },
        .{ .y = 440, .size = 17, .weight = 700, .color = white },
        .{ .y = 464, .size = 13, .weight = 400, .color = white },
        .{ .y = 482, .size = 13, .weight = 400, .color = ui.Color.rgba(255, 255, 255, 153) },
        .{ .y = 500, .size = 17, .weight = 400, .color = white },
    };
    for (rows) |r| {
        const t = try ui.text(cx, "Liquid Glass Hamburgefonstiv 0123", .{ .font_size = r.size, .font_weight = r.weight, .color = r.color });
        t.style.position = .absolute;
        (try t.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 12 }, .top = .{ .px = r.y } };
        try stage.appendChild(a, t);
    }
    // Gradient
    _ = try blendAbs(cx, stage, 0, 520, 640, 80, white);
    const grads = [_][2]ui.Color{
        .{ red, ui.Color.rgba(52, 199, 89, 255) },
        .{ black, white },
        .{ blue, ui.Color.rgba(255, 204, 0, 255) },
        .{ ui.Color.rgba(0, 0, 0, 0), black },
    };
    for (grads, 0..) |g, j| {
        const n = try blendAbs(cx, stage, 10 + 155 * @as(f32, @floatFromInt(j)), 530, 140, 60, g[0]);
        (try n.style.ensureExtFallible(a)).multi_gradient = ui.MultiGradient.fromSlice(&[_]ui.GradientStop{
            .{ .color = g[0], .position = 0 },
            .{ .color = g[1], .position = 1 },
        }, .horizontal);
    }
    // Shadow (SwiftUI radius r -> CSS blur 2r)
    _ = try blendAbs(cx, stage, 0, 600, 640, 80, ui.Color.rgba(200, 200, 200, 255));
    const sh = [_][3]f32{ .{ 4, 2, 0.25 }, .{ 12, 6, 0.25 }, .{ 27, 6, 0.10 } };
    for (sh, 0..) |sv, j| {
        const n = try blendAbs(cx, stage, 40 + 200 * @as(f32, @floatFromInt(j)), 620, 100, 40, white);
        const ext = try n.style.ensureExtFallible(a);
        ext.corner_radius = ui.CornerRadius.uniform(10);
        n.style.border = .{ .overlay = true, .width = 0, .color = ui.Color.rgba(0, 0, 0, 0), .radius = 10 };
        ext.setShadow(.{ .color = ui.Color.rgba(0, 0, 0, @intFromFloat(@round(sv[2] * 255))), .blur = 2 * sv[0], .offset_x = 0, .offset_y = sv[1] });
    }
    // Corner edge AA and scaled image
    _ = try blendAbs(cx, stage, 0, 680, 640, 80, white);
    const edge = try blendAbs(cx, stage, 20, 700, 60, 40, black);
    (try edge.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(12);
    edge.style.border = .{ .overlay = true, .width = 0, .color = ui.Color.rgba(0, 0, 0, 0), .radius = 12 };
    if (g_blend_checker_texture) |tex| {
        for ([_][3]f32{ .{ 120, 696, 48 }, .{ 200, 712, 16 } }) |cv| {
            const img = try ui.image(cx, tex, .{ .width = .{ .px = cv[2] }, .height = .{ .px = cv[2] }, .position = .absolute });
            (try img.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = cv[0] }, .top = .{ .px = cv[1] } };
            try stage.appendChild(a, img);
        }
    }
    try c.appendChild(a, stage);
    return c;
}

// -- GlassExtension: backgroundExtensionEffect (native_bg_extension.swift same
// geometry) -- Gray 128 stage 640x480; 8 forty-point color bars (320x200, white block
// 20pt top-left) at x 190, y 140; left 150pt extension zone (view frame from x 40).
const ext_colors = [_]ui.Color{
    ui.Color.rgba(255, 56, 60, 255), ui.Color.rgba(255, 141, 40, 255), ui.Color.rgba(255, 204, 0, 255), ui.Color.rgba(52, 199, 89, 255),
    ui.Color.rgba(0, 200, 179, 255), ui.Color.rgba(0, 136, 255, 255),  ui.Color.rgba(97, 85, 245, 255), ui.Color.rgba(203, 48, 224, 255),
};
fn buildExtStripes(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const root = try ui.box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 200 }, .direction = .row, .position = .relative }, .{});
    for (ext_colors) |c| try root.appendChild(a, try ui.box(cx, .{ .width = .{ .px = 40 }, .height = .{ .px = 200 }, .background = c }, .{}));
    const white = try ui.box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .position = .absolute, .background = ui.Color.WHITE }, .{});
    (try white.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    try root.appendChild(a, white);
    return root;
}
pub fn buildGlassExtension(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const stage = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255), .overflow_hidden = true }, .{});
    stage.meta.ownership.meta.test_id = "story.glassextension.stage";
    const ext = try W.BackgroundExtension(scope, cx, .{ .width = 320, .height = 200, .leading = 150 }, buildExtStripes);
    ext.style.position = .absolute;
    (try ext.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 40 }, .top = .{ .px = 140 } };
    try stage.appendChild(a, ext);
    try c.appendChild(a, stage);
    // both sides: leading and trailing extensions mirror the content outward on each edge
    const stage2 = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 240 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255), .overflow_hidden = true }, .{});
    stage2.meta.ownership.meta.test_id = "story.glassextension.both";
    const ext2 = try W.BackgroundExtension(scope, cx, .{ .width = 320, .height = 160, .leading = 120, .trailing = 120 }, buildExtStripes);
    ext2.style.position = .absolute;
    (try ext2.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 40 }, .top = .{ .px = 40 } };
    try stage2.appendChild(a, ext2);
    try c.appendChild(a, try ui.text(cx, "Leading and trailing", .{ .font_size = 13, .color = ui.Color.rgba(110, 110, 115, 255) }));
    try c.appendChild(a, stage2);
    return c;
}

// -- GlassConcentric: ConcentricRectangle / containerShape (native_concentric.swift
// same geometry) -- Gray 128 stage, each cell 120x120 dark container (corner 30,
// containerShape), cell start (20+140c, 20+140r). Row 0: white concentric rect, padding
// 6/12/24/36; row 1: minimum 10; row 2: glass `.concentric`; row 3: 60x60 asymmetric
// padding (6,18) (18,6) (12,12); last cell glass with same (6,18) (four corners differ:
// top-left 12, rest square).
pub fn buildGlassConcentric(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const stage = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 640 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255) }, .{});
    stage.meta.ownership.meta.test_id = "story.glassconcentric.stage";
    const pads = [_]f32{ 6, 12, 24, 36 };
    const asym = [_][2]f32{ .{ 6, 18 }, .{ 18, 6 }, .{ 12, 12 } };
    for (0..4) |r| {
        for (0..4) |ci| {
            const cell = try ui.box(cx, .{ .width = .{ .px = 120 }, .height = .{ .px = 120 }, .position = .absolute, .background = ui.Color.rgba(64, 64, 64, 255) }, .{});
            const ext = try cell.style.ensureExtFallible(a);
            ext.inset = .{ .left = .{ .px = 20 + 140 * @as(f32, @floatFromInt(ci)) }, .top = .{ .px = 20 + 140 * @as(f32, @floatFromInt(r)) } };
            ext.corner_radius = ui.CornerRadius.uniform(30);
            cell.style.border = .{ .overlay = true, .width = 0, .color = ui.Color.rgba(0, 0, 0, 0), .radius = 30 };
            try W.concentric.containerShape(cell, a, 30);
            const p = pads[ci];
            var child: *ui.Node = undefined;
            if (r < 2) {
                child = try W.concentric.ConcentricRectangle(scope, cx, .{ .width = .{ .px = 120 - 2 * p }, .height = .{ .px = 120 - 2 * p }, .position = .absolute }, .{ .minimum = if (r == 1) 10 else 0, .fill = ui.Color.WHITE });
                (try child.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = p }, .top = .{ .px = p } };
            } else if (r == 2) {
                const g = try W.GlassBox(.{ .width = 120 - 2 * p, .height = 120 - 2 * p, .shape = .{ .concentric = 0 }, .padding = ui.Padding.all(0), .body_gap = 0 }).mount(scope, cx);
                g.style.position = .absolute;
                (try g.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = p }, .top = .{ .px = p } };
                child = g;
            } else if (ci < 3) {
                child = try W.concentric.ConcentricRectangle(scope, cx, .{ .width = .{ .px = 60 }, .height = .{ .px = 60 }, .position = .absolute }, .{ .fill = ui.Color.WHITE });
                (try child.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = asym[ci][0] }, .top = .{ .px = asym[ci][1] } };
            } else {
                const g = try W.GlassBox(.{ .width = 60, .height = 60, .shape = .{ .concentric = 0 }, .padding = ui.Padding.all(0), .body_gap = 0 }).mount(scope, cx);
                g.style.position = .absolute;
                (try g.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 6 }, .top = .{ .px = 18 } };
                child = g;
            }
            try cell.appendChild(a, child);
            try stage.appendChild(a, cell);
        }
    }
    try c.appendChild(a, stage);
    return c;
}

// -- GlassAppKit: NSGlassEffectView parameters (native_appkit_glass_params.swift /
// native_tint_alpha.swift). Striped stage 720x330: rows 1-2 = tintColor alpha 0 / .25 / .5 /
// .75 / 1 (regular red, clear blue); row 3 = default cornerRadius 8 and a capsule, each with a magenta
// square overflowing the bottom-right corner (the contentView is clipped to the glass shape).
pub fn buildGlassAppKit(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try labelNode(cx, "NSGlassEffectView parity: tintColor alpha = tint amount (rows 1-2); default cornerRadius 8; content clipped to the glass shape (row 3)"));
    const stage = try ui.box(cx, .{ .width = .{ .px = 720 }, .height = .{ .px = 330 }, .position = .relative, .background = ui.Color.WHITE, .overflow_hidden = true }, .{});
    stage.meta.ownership.meta.test_id = "story.glassappkit.stage";
    const stripes = [_]ui.Color{ ui.Color.rgba(255, 59, 48, 255), ui.Color.rgba(0, 122, 255, 255), ui.Color.BLACK, ui.Color.rgba(255, 204, 0, 255), ui.Color.rgba(52, 199, 89, 255) };
    var x: f32 = 0;
    var i: usize = 0;
    while (x < 720) : ({
        x += 14;
        i += 1;
    }) {
        const s = try ui.box(cx, .{ .width = .{ .px = 6 }, .height = .{ .px = 330 }, .position = .absolute, .background = stripes[i % stripes.len] }, .{});
        (try s.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = x }, .top = .{ .px = 0 } };
        try stage.appendChild(a, s);
    }
    const alphas = [_]u8{ 0, 64, 128, 191, 255 };
    const tint_ids = [2][5][]const u8{
        .{ "story.glassappkit.tint.0.0", "story.glassappkit.tint.0.64", "story.glassappkit.tint.0.128", "story.glassappkit.tint.0.191", "story.glassappkit.tint.0.255" },
        .{ "story.glassappkit.tint.1.0", "story.glassappkit.tint.1.64", "story.glassappkit.tint.1.128", "story.glassappkit.tint.1.191", "story.glassappkit.tint.1.255" },
    };
    for (0..2) |tint_row| {
        for (alphas, 0..) |alpha, col_i| {
            const tint = if (tint_row == 0) ui.Color.rgba(255, 51, 51, alpha) else ui.Color.rgba(26, 102, 255, alpha);
            const g = try W.GlassBox(.{ .width = 120, .height = 60, .corner_radius = 12, .glass_style = if (tint_row == 0) W.glass_box.GlassEffectStyle.regular else .clear, .tint_color = tint, .padding = ui.Padding.all(0), .body_gap = 0 }).mount(scope, cx);
            g.style.position = .absolute;
            (try g.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 20 + 140 * @as(f32, @floatFromInt(col_i)) }, .top = .{ .px = 20 + 100 * @as(f32, @floatFromInt(tint_row)) } };
            g.meta.ownership.meta.test_id = tint_ids[tint_row][col_i];
            try stage.appendChild(a, g);
        }
    }
    // Default cornerRadius, and a capsule whose radius is only resolved after layout (the
    // content clip follows the per-frame shape).
    const shapes = [_]?W.glass_box.GlassBoxShape{ null, .capsule };
    for (shapes, 0..) |shape, k| {
        const mounted = try W.GlassBox(.{ .width = 120, .height = 60, .shape = shape, .padding = ui.Padding.all(0), .body_gap = 0 }).mountWithState(scope, cx);
        mounted.box.style.position = .absolute;
        (try mounted.box.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 20 + 140 * @as(f32, @floatFromInt(k)) }, .top = .{ .px = 230 } };
        mounted.box.meta.ownership.meta.test_id = if (k == 0) "story.glassappkit.clip.default" else "story.glassappkit.clip.capsule";
        const over = try ui.box(cx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .position = .absolute, .background = ui.Color.rgba(255, 0, 255, 255) }, .{});
        (try over.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 106 }, .top = .{ .px = 46 } };
        try mounted.body.appendChild(a, over);
        try stage.appendChild(a, mounted.box);
    }
    try c.appendChild(a, stage);
    return c;
}

// -- GlassIdiom: the same glass rendered with the measured macOS and iOS profiles
// (GlassIdiom, scripts/glass_native_model/baselines). Stage 720x320: colour bars on the left,
// uniform gray 128 on the right; row 1 = macOS, row 2 = iOS, each a 200x100 panel over the bars
// and over the gray plus a 104x52 compact capsule over the gray.
pub fn buildGlassIdiom(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try labelNode(cx, "GlassIdiom: row 1 macOS, row 2 iOS (iOS regular is clearer, more saturated; compact glass is blurrier and casts a stronger shadow)"));
    const stage = try ui.box(cx, .{ .width = .{ .px = 720 }, .height = .{ .px = 320 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255), .overflow_hidden = true }, .{});
    stage.meta.ownership.meta.test_id = "story.glassidiom.stage";
    const bars = [_]ui.Color{ ui.Color.rgba(255, 0, 0, 255), ui.Color.rgba(0, 255, 0, 255), ui.Color.rgba(0, 0, 255, 255), ui.Color.rgba(255, 255, 0, 255), ui.Color.WHITE, ui.Color.BLACK };
    var x: f32 = 0;
    var i: usize = 0;
    while (x < 300) : ({
        x += 12;
        i += 1;
    }) {
        const b = try ui.box(cx, .{ .width = .{ .px = 12 }, .height = .{ .px = 320 }, .position = .absolute, .background = bars[i % bars.len] }, .{});
        (try b.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = x }, .top = .{ .px = 0 } };
        try stage.appendChild(a, b);
    }
    const idioms = [_]W.glass_box.GlassIdiom{ .macos, .ios };
    const ids = [2][3][]const u8{
        .{ "story.glassidiom.macos.bars", "story.glassidiom.macos.gray", "story.glassidiom.macos.compact" },
        .{ "story.glassidiom.ios.bars", "story.glassidiom.ios.gray", "story.glassidiom.ios.compact" },
    };
    for (idioms, 0..) |idiom, idiom_row| {
        const top = 30 + 150 * @as(f32, @floatFromInt(idiom_row));
        const cells = [_]struct { x: f32, y: f32, w: f32, h: f32 }{
            .{ .x = 50, .y = top, .w = 200, .h = 100 },
            .{ .x = 340, .y = top, .w = 200, .h = 100 },
            .{ .x = 580, .y = top + 24, .w = 104, .h = 52 },
        };
        for (cells, 0..) |cell, k| {
            const g = try W.GlassBox(.{ .width = cell.w, .height = cell.h, .corner_radius = cell.h / 4, .idiom = idiom, .padding = ui.Padding.all(0), .body_gap = 0 }).mount(scope, cx);
            g.style.position = .absolute;
            (try g.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = cell.x }, .top = .{ .px = cell.y } };
            g.meta.ownership.meta.test_id = ids[idiom_row][k];
            try stage.appendChild(a, g);
        }
    }
    try c.appendChild(a, stage);
    return c;
}

// -- GlassIosBars: iOS navigation bar / toolbar / tab bar / glass buttons (glass_bars), the same
// configuration as the native system_* captures (ios-26-5-simulator-iphone-17-pro/system), each on
// a 402 pt wide gray-128 strip.
fn iosStrip(cx: *ui.Cx, h: f32, test_id: []const u8) !*ui.Node {
    return iosStripOn(cx, h, test_id, ui.Color.rgba(128, 128, 128, 255));
}

fn iosStripOn(cx: *ui.Cx, h: f32, test_id: []const u8, bg: ui.Color) !*ui.Node {
    const s = try ui.box(cx, .{ .width = .{ .px = 402 }, .height = .{ .px = h }, .background = bg, .direction = .column }, .{});
    s.meta.ownership.meta.test_id = test_id;
    return s;
}

/// Tab bar selection lens fixtures matching the native captures
/// (baselines/ios-26-5-simulator-iphone-17-pro/interaction/tabbar_hold_t{8,9,10}.png): at rest
/// on Home; held on Library; held and dragged 45 pt toward Radio. Gray 128 strips 402 wide with
/// the platter 19 pt from the top. Compare: scripts/glass_native_model/ios/compare_tab_lens.py.
pub fn buildGlassIosLens(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const icons = ui.icons;
    const c = try col(cx, 12);
    try c.appendChild(a, try labelNode(cx, "iOS tab bar lens fixtures: rest / held on Library / held + dragged 45 pt (compare_tab_lens.py)"));
    const B = W.glass_bars;
    const tabs = [_]B.TabItem{ .{ .icon = icons.house, .label = "Home" }, .{ .icon = icons.library, .label = "Library" }, .{ .icon = icons.radio, .label = "Radio" } };
    const fixtures = [_]struct { id: []const u8, held: ?B.HeldFixture }{
        .{ .id = "story.ioslens.rest", .held = null },
        .{ .id = "story.ioslens.held", .held = .{ .tab = 1 } },
        .{ .id = "story.ioslens.straddle", .held = .{ .tab = 1, .offset = 45 } },
        // held on Home: the lens overhangs the platter's end (its cap and inside over the backdrop)
        .{ .id = "story.ioslens.home", .held = .{ .tab = 0 } },
    };
    // ZENIT_STORYBOOK_LENS_BG=grating[:PERIOD]: the native `fourphase` grating (default 8 pt
    // period, 96 / 160) instead of gray 128, for the displacement-field comparison;
    // sinx:PERIOD:PHASE / siny:PERIOD:PHASE: the native probe's sinusoidal gratings (40..220,
    // one 0.5 pt strip per device pixel at 2x; four-step phase, scratchpad field2.py).
    var env_buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&env_buf);
    const bg = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_STORYBOOK_LENS_BG") catch "";
    const grating = std.mem.startsWith(u8, bg, "grating");
    const sin_x = std.mem.startsWith(u8, bg, "sinx:");
    const sin_y = std.mem.startsWith(u8, bg, "siny:");
    var sin_period: f32 = 48;
    var sin_phase: f32 = 0;
    if (sin_x or sin_y) {
        var it = std.mem.splitScalar(u8, bg[5..], ':');
        sin_period = std.fmt.parseFloat(f32, it.next() orelse "48") catch 48;
        sin_phase = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
    }
    const period: f32 = if (std.mem.indexOfScalar(u8, bg, ':')) |i| (std.fmt.parseFloat(f32, bg[i + 1 ..]) catch 8) else 8;
    for (fixtures) |f| {
        const strip = try iosStrip(cx, 100, f.id);
        if (grating) {
            strip.setBackground(ui.Color.rgba(160, 160, 160, 255));
            strip.style.position = .relative;
            var x: f32 = 0;
            while (x < 402) : (x += period) {
                const bar = try ui.box(cx, .{ .width = .{ .px = period / 2 }, .height = .{ .px = 100 }, .position = .absolute, .background = ui.Color.rgba(96, 96, 96, 255) }, .{});
                (try bar.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = x }, .top = .{ .px = 0 } };
                try strip.appendChild(a, bar);
            }
        }
        if (sin_x or sin_y) {
            strip.style.position = .relative;
            const along: f32 = if (sin_x) 402 else 100;
            var q: f32 = 0;
            while (q < along) : (q += 0.5) {
                const cv = 0.5 + 0.5 * @cos(2 * std.math.pi * (q + 0.25) / sin_period - sin_phase * std.math.pi / 2);
                const lv: u8 = @intFromFloat(@round(40 + 180 * cv));
                const line = try ui.box(cx, .{
                    .width = .{ .px = if (sin_x) 0.5 else 402 },
                    .height = .{ .px = if (sin_x) 100 else 0.5 },
                    .position = .absolute,
                    .background = ui.Color.rgba(lv, lv, lv, 255),
                }, .{});
                (try line.style.ensureExtFallible(a)).inset = if (sin_x) .{ .left = .{ .px = q }, .top = .{ .px = 0 } } else .{ .left = .{ .px = 0 }, .top = .{ .px = q } };
                try strip.appendChild(a, line);
            }
        }
        const tab = try B.GlassTabBar(.{ .tabs = &tabs, .search = .{ .icon = icons.search, .label = "Search" }, .width = 402, .held = f.held, .test_id = f.id }).mount(scope, cx);
        tab.root.style.margin = .{ .top = 19 };
        try strip.appendChild(a, tab.root);
        try c.appendChild(a, strip);
    }
    return c;
}

pub fn buildGlassIosBars(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 10);
    try c.appendChild(a, try labelNode(cx, "iOS bars (idiom .ios): navigation bar, large title, bottom toolbar, tab bar, glass buttons — metrics from UIKit's own view hierarchy"));
    // Gray 128: the backdrop every native measurement was taken over.
    try c.appendChild(a, try iosBarsSet(scope, cx, "story.iosbars", ui.Color.rgba(128, 128, 128, 255)));
    // The same set on a white page (system light, the common app background), framed so the page
    // edge is visible against the white story panel. Glass adapts to what is behind it: the
    // selection plate follows the platter body, so it reads much lighter here than over gray.
    try c.appendChild(a, try labelNode(cx, "Light page (white, system light): the same bars over the common app background"));
    const page = try ui.box(cx, .{ .direction = .column, .padding = ui.Padding.all(16), .background = ui.Color.rgba(255, 255, 255, 255), .border_width = 1, .border_color = ui.Color.rgba(220, 220, 216, 255) }, .{});
    (try page.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(14);
    page.meta.ownership.meta.test_id = "story.iosbars.white.page";
    try page.appendChild(a, try iosBarsSet(scope, cx, "story.iosbars.white", ui.Color.rgba(255, 255, 255, 255)));
    try c.appendChild(a, page);
    return c;
}

/// One set of iOS bars over `bg`: navigation bar, large title, bottom toolbar and tab bar in a
/// column, glass buttons beside them. Test ids are `<p>.nav`, `<p>.tab.home`, `<p>.btn.clear`, ...
fn iosBarsSet(scope: *ui.Scope, cx: *ui.Cx, comptime p: []const u8, bg: ui.Color) !*ui.Node {
    const a = cx.allocator;
    const icons = ui.icons;
    const B = W.glass_bars;
    const bars_row = try ui.box(cx, .{ .direction = .row, .gap = 16, .align_items = .start }, .{});
    const left = try col(cx, 10);

    const nav_strip = try iosStripOn(cx, 70, p ++ ".nav", bg);
    const nav_icons = [_]B.BarIcon{ .{ .icon = icons.ellipsis, .label = "More", .test_id = p ++ ".nav.more" }, .{ .icon = icons.share, .label = "Share", .test_id = p ++ ".nav.share" } };
    const nav = try W.GlassNavigationBar(.{
        .title = "Message",
        .subtitle = "2 unread",
        .back = cx.on(StoryNoop, &story_noop, StoryNoop.f),
        .back_test_id = p ++ ".nav.back",
        .trailing = &[_]B.BarGroup{ .{ .icons = &nav_icons }, .{ .prominent = .{ .title = "Done", .test_id = p ++ ".nav.done" } } },
        .width = 402,
    }).mount(scope, cx);
    nav.root.style.margin = .{ .top = 8 };
    try nav_strip.appendChild(a, nav.root);
    try left.appendChild(a, nav_strip);

    const large_strip = try iosStripOn(cx, 140, p ++ ".large", bg);
    const large = try W.GlassNavigationBar(.{
        .title = "Library",
        .subtitle = "128 items",
        .large_title = true,
        .trailing = &[_]B.BarGroup{.{ .icons = &[_]B.BarIcon{.{ .icon = icons.plus, .label = "Add", .test_id = p ++ ".large.add" }} }},
        .width = 402,
    }).mount(scope, cx);
    large.root.style.margin = .{ .top = 8 };
    try large_strip.appendChild(a, large.root);
    try left.appendChild(a, large_strip);

    const tool_strip = try iosStripOn(cx, 70, p ++ ".toolbar", bg);
    const tool_icons = [_]B.BarIcon{ .{ .icon = icons.folder, .label = "Folder" }, .{ .icon = icons.trash, .label = "Trash" } };
    const tool = try W.GlassBottomToolbar(.{
        .groups = &[_]B.BarGroup{ .{ .icons = &tool_icons }, .flexible_space, .{ .prominent = .{ .icon = icons.square_pen, .label = "Compose", .test_id = p ++ ".toolbar.compose" } } },
        .width = 402,
    }).mount(scope, cx);
    tool.root.style.margin = .{ .top = 11 };
    try tool_strip.appendChild(a, tool.root);
    try left.appendChild(a, tool_strip);

    const tab_strip = try iosStripOn(cx, 84, p ++ ".tabbar", bg);
    const tabs = [_]B.TabItem{ .{ .icon = icons.house, .label = "Home", .test_id = p ++ ".tab.home" }, .{ .icon = icons.library, .label = "Library", .test_id = p ++ ".tab.library" }, .{ .icon = icons.radio, .label = "Radio", .test_id = p ++ ".tab.radio" } };
    const tab = try W.GlassTabBar(.{ .tabs = &tabs, .search = .{ .icon = icons.search, .label = "Search", .test_id = p ++ ".tab.search" }, .width = 402, .test_id = p ++ ".tb" }).mount(scope, cx);
    tab.root.style.margin = .{ .top = 11 };
    try tab_strip.appendChild(a, tab.root);
    try left.appendChild(a, tab_strip);
    try bars_row.appendChild(a, left);

    const btn_strip = try iosStripOn(cx, 380, p ++ ".buttons", bg);
    btn_strip.style.width = .{ .px = 220 };
    btn_strip.style.align_items = .center;
    btn_strip.style.justify = .center;
    btn_strip.style.gap = 18;
    const styles = [_]struct { t: []const u8, s: B.GlassButtonStyle, id: []const u8 }{
        .{ .t = "Glass", .s = .glass, .id = p ++ ".btn.glass" },
        .{ .t = "Prominent", .s = .prominent_glass, .id = p ++ ".btn.prominent" },
        .{ .t = "Clear", .s = .clear_glass, .id = p ++ ".btn.clear" },
        .{ .t = "Prominent Clear", .s = .prominent_clear_glass, .id = p ++ ".btn.prominent_clear" },
    };
    for (styles) |st| try btn_strip.appendChild(a, (try W.GlassButton(.{ .title = st.t, .style = st.s, .test_id = st.id }).mount(scope, cx)).root);
    try btn_strip.appendChild(a, (try W.GlassButton(.{ .icon = icons.heart, .label = "Like", .test_id = p ++ ".btn.icon" }).mount(scope, cx)).root);
    try bars_row.appendChild(a, btn_strip);
    return bars_row;
}

const StoryNoop = struct {
    fn f(_: *StoryNoop) void {}
};
var story_noop = StoryNoop{};

// -- GlassControls: Liquid Glass slider and toggle (native_slider_toggle.swift same
// geometry) -- Gray 128 stage 640x240: slider width 240, center (320,80); toggle 54x24,
// center (320,170). Hold knob becomes clear glass lens zoomed, release bounces back
// white solid (toggle slides to new position, track cross-fade).
pub fn buildGlassControls(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const stage = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 240 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255) }, .{});
    stage.meta.ownership.meta.test_id = "story.glasscontrols.stage";
    const slider = try W.GlassSlider(.{ .width = 240, .test_id = "story.glasscontrols.slider" }).mount(scope, cx);
    slider.wrapper.style.position = .absolute;
    (try slider.wrapper.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 200 }, .top = .{ .px = 70 } };
    try stage.appendChild(a, slider.wrapper);
    const toggle = try W.GlassToggle(.{ .test_id = "story.glasscontrols.toggle" }).mount(scope, cx);
    toggle.wrapper.style.position = .absolute;
    (try toggle.wrapper.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 293 }, .top = .{ .px = 158 } };
    try stage.appendChild(a, toggle.wrapper);
    try c.appendChild(a, stage);
    return c;
}

// -- GlassControls (iOS): UISlider / UISwitch with the iOS look (idiom .ios). The stage is the
// ios GlassProbe `switches` scene shifted up 300 pt: gray 128, on switch at x 89.7, off
// switch at x 251.7 (63 x 28, centred on y 60), slider (201, 180) 300 wide at 0.5. Held, the knob turns into the
// `_UILiquidLensView` magnifier.
pub fn buildGlassControlsIos(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try labelNode(cx, "iOS slider & switch (idiom .ios): press and hold a knob — it lifts into the Liquid Glass magnifier"));
    const stage = try ui.box(cx, .{ .width = .{ .px = 402 }, .height = .{ .px = 240 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255) }, .{});
    stage.meta.ownership.meta.test_id = "story.glasscontrolsios.stage";
    const on = try W.GlassToggle(.{ .on = true, .idiom = .ios, .test_id = "story.glasscontrolsios.on" }).mount(scope, cx);
    const off = try W.GlassToggle(.{ .idiom = .ios, .test_id = "story.glasscontrolsios.off" }).mount(scope, cx);
    const slider = try W.GlassSlider(.{ .width = 300, .idiom = .ios, .test_id = "story.glasscontrolsios.slider" }).mount(scope, cx);
    const places = [_]struct { n: *ui.Node, x: f32, y: f32 }{
        // UISwitch frames land at x 89.7 / 251.7 (the probe centres their alignment rects)
        .{ .n = on.wrapper, .x = 89.7, .y = 60 - 14 },
        .{ .n = off.wrapper, .x = 251.7, .y = 60 - 14 },
        .{ .n = slider.wrapper, .x = 51, .y = 180 - 17 },
    };
    for (places) |pl| {
        pl.n.style.position = .absolute;
        (try pl.n.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = pl.x }, .top = .{ .px = pl.y } };
        try stage.appendChild(a, pl.n);
    }
    try c.appendChild(a, stage);
    return c;
}

// -- GlassToolbar: NSToolbar glass toolbar (native_appkit_controls.swift same layout,
// titlebar 241 base) --
//
// Native macOS 26.4: each group is one 36pt regular glass capsule, group gap 10; hover /
// press / selected layer is 32x28 stacked black 13 / 26 / 26 (add), the 1x20 divider appears only
// between two adjacent segments that are both unselected, all switching per frame.
const GlassToolbarStory = struct {
    cx: *ui.Cx,
    last: *ui.Signal([]const u8),
    /// e2e can't truly blur window: directly flip cx.window_active and let glass re-parse
    /// material like runtime
    fn toggleInactive(self: *GlassToolbarStory) void {
        self.cx.window_active = !self.cx.window_active;
        if (self.cx.root) |root| root.markSubtreeBeforeRenderHook();
        self.cx.needs_redraw = true;
    }
    fn sidebar(self: *GlassToolbarStory) void {
        self.last.set("sidebar");
    }
    fn share(self: *GlassToolbarStory) void {
        self.last.set("share");
    }
    fn search(self: *GlassToolbarStory) void {
        self.last.set("search");
    }
};

pub fn buildGlassToolbar(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const last = try scope.createSignal([]const u8, "(none)");
    const view = try scope.createSignal(usize, 0);
    const view_dark = try scope.createSignal(usize, 0);
    const st = try cx.bindState(GlassToolbarStory, .{ .cx = cx, .last = last });
    const status = try ui.textFmt(cx, scope, "last: {s} · view: {d} · dark view: {d}", .{ last, view, view_dark }, .{ .font_size = 13, .color = light.tokens.color.fg_secondary });
    status.meta.ownership.meta.test_id = "story.glasstoolbar.status";
    // Light: titlebar 241 (native aqua); Dark: 31 (native darkAqua)
    try c.appendChild(a, try glassToolbarStage(scope, cx, st, view, ui.Color.rgba(241, 241, 241, 255), 52, "story.glasstoolbar."));
    // Dark stage taller: glass bg brightness from blur chain deepest layer (sample > capsule),
    // 52pt high dark bar above/below light page, average > dark family threshold 48/255,
    // capsule won't flip dark; native titlebar outside also dark window content
    try c.appendChild(a, try glassToolbarStage(scope, cx, st, view_dark, ui.Color.rgba(31, 31, 31, 255), 140, "story.glasstoolbar.dark."));
    const inactive = try W.Button(.{ .label = "Simulate inactive window", .on_click = cx.on(GlassToolbarStory, st, GlassToolbarStory.toggleInactive) }).mount(scope, cx);
    inactive.meta.ownership.meta.test_id = "story.glasstoolbar.inactive";
    // the callbacks' result, under the stages
    const foot = try row(cx, 16);
    foot.style.align_items = .center;
    try foot.appendChild(a, inactive);
    try foot.appendChild(a, status);
    try c.appendChild(a, foot);
    return c;
}

fn glassToolbarStage(scope: *ui.Scope, cx: *ui.Cx, st: *GlassToolbarStory, view: *ui.Signal(usize), bg: ui.Color, height: f32, comptime prefix: []const u8) !*ui.Node {
    const a = cx.allocator;
    const stage = try ui.box(cx, .{
        .width = .{ .px = 640 },
        .height = .{ .px = height },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 20, .right = 20 },
        .background = bg,
    }, .{});
    stage.meta.ownership.meta.test_id = prefix ++ "stage";
    const TB = W.glass_toolbar;
    const groups = [_]TB.ToolbarGroup{
        .{ .buttons = &[_]TB.ToolbarButton{
            .{ .icon = ui.icons.panel_left, .label = "Sidebar", .on_click = cx.on(GlassToolbarStory, st, GlassToolbarStory.sidebar), .test_id = prefix ++ "sidebar" },
            .{ .icon = ui.icons.share, .label = "Share", .on_click = cx.on(GlassToolbarStory, st, GlassToolbarStory.share), .test_id = prefix ++ "share" },
        } },
        .{ .segmented = .{
            .icons = &[_]ui.SvgAsset{ ui.icons.list, ui.icons.layout_grid, ui.icons.rows_3 },
            .labels = &[_][]const u8{ "List", "Grid", "Rows" },
            .selected = .{ .bound = view },
            .test_id = prefix ++ "view",
        } },
        .flexible_space,
        .{ .buttons = &[_]TB.ToolbarButton{
            .{ .icon = ui.icons.search, .label = "Search", .on_click = cx.on(GlassToolbarStory, st, GlassToolbarStory.search), .test_id = prefix ++ "search" },
        } },
    };
    const tb = try W.GlassToolbar(.{ .groups = &groups, .test_id = prefix ++ "bar" }).mount(scope, cx);
    try stage.appendChild(a, tb.root);
    return stage;
}

// -- GlassAdapt: scroll white -> black content, floating glass bar (small, flips by bg) +
// large regular panel (no flip, material self-adapts) --
//
// Native rule (native_family_flip.swift): a regular element with smallest edge <= 64pt flips
// by its own bg brightness: sRGB mean < 48/255 enters the dark family, > 120/255 returns to
// light, 0.3s to complete; larger elements (menu, sidebar, panel) don't flip. The glass bar
// uses GlassToolbar (36pt tall), whose dark family layer/icon stack is white; the panel is
// 220pt wide, > 64pt tall.
const GlassAdaptStory = struct {
    cx: *ui.Cx,
    bar: *W.glass_box.AdaptiveGlassBoxState,
    panel: *W.glass_box.AdaptiveGlassBoxState,
    status: *ui.Node,
    last: [96]u8 = undefined,
    last_len: usize = 0,

    fn familyWord(st: *const W.glass_box.AdaptiveGlassBoxState) []const u8 {
        return if (st.family_dark) "dark" else "light";
    }

    /// Each frame write both glasses' family and bg brightness to status (only on change)
    fn refresh(node: *ui.Node) void {
        const self: *GlassAdaptStory = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
        var buf: [96]u8 = undefined;
        const bar_l: f32 = (self.bar.live_luminance_srgb orelse 0) * 255;
        const panel_l: f32 = (self.panel.live_luminance_srgb orelse 0) * 255;
        const txt = std.fmt.bufPrint(&buf, "bar: {s} (backdrop {d:.0}) · panel: {s} (backdrop {d:.0})", .{ familyWord(self.bar), bar_l, familyWord(self.panel), panel_l }) catch return;
        if (std.mem.eql(u8, txt, self.last[0..self.last_len])) return;
        @memcpy(self.last[0..txt.len], txt);
        self.last_len = txt.len;
        self.status.setTextContent(self.cx.allocator, txt) catch return;
        self.status.markSizingDirty();
        self.status.markRenderDirty();
    }
};

pub fn buildGlassAdapt(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const status = try ui.text(cx, "bar: light · panel: light", .{ .font_size = 13, .color = light.tokens.color.fg_secondary });
    status.meta.ownership.meta.test_id = "story.glassadapt.status";
    try c.appendChild(a, status);

    const W_: f32 = 640;
    const H_: f32 = 420;
    const stage = try ui.box(cx, .{ .width = .{ .px = W_ }, .height = .{ .px = H_ }, .position = .relative, .overflow_hidden = true }, .{});
    (try stage.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(16);
    stage.meta.ownership.meta.test_id = "story.glassadapt.stage";

    // Content: white -> black section, each paired with contrast text (glass has something
    // refract / blur)
    const sa = try W.ScrollArea(.{ .width = W_, .height = H_, .direction = .vertical }).mount(scope, cx);
    sa.container.meta.ownership.meta.test_id = "story.glassadapt.scroll";
    const levels = [_]u8{ 255, 236, 200, 150, 100, 60, 30, 0 };
    for (levels) |lv| {
        const band = try ui.box(cx, .{
            .width = .{ .px = W_ },
            .height = .{ .px = 260 },
            .direction = .column,
            .gap = 10,
            .padding = ui.Padding.symmetric(70, 32),
            .background = ui.Color.rgba(lv, lv, lv, 255),
        }, .{});
        const ink = if (lv > 128) ui.Color.rgba(20, 20, 20, 255) else ui.Color.rgba(240, 240, 240, 255);
        var hb: [48]u8 = undefined;
        try band.appendChild(a, try ui.text(cx, try std.fmt.bufPrint(&hb, "Background {d}", .{lv}), .{ .font_size = 22, .font_weight = 700, .color = ink }));
        for (0..4) |_| {
            try band.appendChild(a, try ui.text(cx, "Liquid Glass adapts to what is behind it: small floating controls switch between light and dark, large surfaces keep their family.", .{ .font_size = 14, .color = ink, .wrap = .word_break }));
        }
        try sa.content.appendChild(a, band);
    }
    // Final screen pure black: scroll to bottom, top glass bar also stops on pure black
    try sa.content.appendChild(a, try ui.box(cx, .{ .width = .{ .px = W_ }, .height = .{ .px = H_ }, .background = ui.Color.rgba(0, 0, 0, 255) }, .{}));
    try stage.appendChild(a, sa.container);

    // Floating glass bar: top center (left/right elastic space), no content scroll
    const TB = W.glass_toolbar;
    const groups = [_]TB.ToolbarGroup{
        .flexible_space,
        .{ .buttons = &[_]TB.ToolbarButton{
            .{ .icon = ui.icons.panel_left, .label = "Sidebar", .test_id = "story.glassadapt.sidebar" },
            .{ .icon = ui.icons.share, .label = "Share", .test_id = "story.glassadapt.share" },
        } },
        .{ .segmented = .{ .icons = &[_]ui.SvgAsset{ ui.icons.list, ui.icons.layout_grid, ui.icons.rows_3 } } },
        .flexible_space,
    };
    const tb = try W.GlassToolbar(.{ .groups = &groups, .test_id = "story.glassadapt.bar" }).mount(scope, cx);
    const bar_row = try ui.box(cx, .{ .width = .{ .px = W_ }, .height = .{ .px = 36 }, .position = .absolute, .direction = .row }, .{});
    (try bar_row.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 16 } };
    try bar_row.appendChild(a, tb.root);
    try stage.appendChild(a, bar_row);

    // Large regular panel: bottom-right corner
    const panel = try W.GlassBox(.{ .width = 220, .title = "Regular panel", .subtitle = "larger than 64 pt: keeps its family", .shape = .{ .rounded = 20 } }).mountWithState(scope, cx);
    try panel.body.appendChild(a, try ui.text(cx, "Material still adapts: the backdrop shows through, the shadow and rim follow.", .{ .font_size = 13, .color = cx.tokens.tokens.color.fg_primary, .wrap = .word_break }));
    panel.box.style.position = .absolute;
    (try panel.box.style.ensureExtFallible(a)).inset = .{ .right = .{ .px = 20 }, .bottom = .{ .px = 20 } };
    panel.box.meta.ownership.meta.test_id = "story.glassadapt.panel";
    try stage.appendChild(a, panel.box);
    try c.appendChild(a, stage);

    const st = try cx.bindState(GlassAdaptStory, .{ .cx = cx, .bar = tb.runtime.items.items[0].glass, .panel = panel.state, .status = status });
    status.behavior.events.event_context = @ptrCast(st);
    status.addBeforeRender(GlassAdaptStory.refresh);
    return c;
}

// -- GlassPopover: glass button pops a Liquid Glass popover (SwiftUI `.popover`, gray 128
// base) --
//
// Native macOS 26.4 measured (scripts/glass_native_model/native_menu_morph.swift
// popover): the button doesn't morph into the popover. Popover is independent regular glass
// (no shadow), springs scale from 0 at the arrow tip (opacity follows scale, in spring
// 0.336/0.783, out 0.249s to zero), see Transition.glass_popover. Geometry matches
// native: button 66x24 top-left (127,108); popover body 200x63.75 (31->94.75), corner
// 19, arrow down extends 10.8, arrow tip 105.55 from button 2.5.
pub fn buildGlassPopover(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const stage = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255), .padding = .{ .left = 127, .top = 108 } }, .{});
    stage.meta.ownership.meta.test_id = "story.glasspopover.stage";
    const pop = try W.Popover(.{
        .position = .top,
        .trigger = .click,
        .offset = .{ .static = 2.5 },
        .enter_transition = .glass_popover,
        .exit_transition = .glass_popover,
        .flip = false,
    }).mount(scope, cx);
    pop.chrome.meta.ownership.meta.test_id = "story.glasspopover.panel";
    {
        const panel = pop.chrome;
        panel.setBackground(ui.Color.rgba(0, 0, 0, 0));
        panel.style.border = .{ .overlay = true, .width = 0, .color = ui.Color.rgba(0, 0, 0, 0), .radius = 0 };
        panel.style.padding = ui.Padding.all(0);
        panel.style.overflow_hidden = false;
        const ext = panel.style.ensureExtPanic(a);
        ext.clearShadows();
        ext.clip_shape = .none;
        ext.hit_shape = .rect;
    }
    const body = try W.GlassBox(.{ .width = 200, .height = 74.55, .corner_radius = 19, .arrow = .{ .edge = .bottom }, .drop_shadow = false, .padding = ui.Padding.all(16), .body_gap = 0 }).mountWithState(scope, cx);
    // Native popover text measured opaque (69,69,69). Zenit text alpha blend in linear
    // (AppKit sRGB), semi-black lighter, so use measured opaque gray directly.
    const ink = ui.Color.rgba(69, 69, 69, 255);
    // Native: VStack(alignment: .leading).padding(16).frame(width: 200) -- text block
    // centered in 200 width
    body.body.style.align_items = .center;
    const text_col = try ui.box(cx, .{ .direction = .column, .align_items = .start }, .{});
    try text_col.appendChild(a, try glassLabel(cx, "Popover", 700, ink));
    try text_col.appendChild(a, try glassLabel(cx, "Liquid Glass content", 400, ink));
    try body.body.appendChild(a, text_col);
    try pop.content.appendChild(a, body.box);
    const btn = try W.GlassBox(.{ .width = 66, .height = 24, .shape = .capsule, .press_feedback = .glass_button, .padding = ui.Padding.all(0), .body_gap = 0 }).mountWithState(scope, cx);
    btn.body.style.align_items = .center;
    btn.body.style.justify = .center;
    try btn.body.appendChild(a, try glassLabel(cx, "Details", 400, ui.Color.rgba(0, 0, 0, 255)));
    btn.box.meta.ownership.meta.test_id = "story.glasspopover.button";
    try pop.trigger.appendChild(a, btn.box);
    try stage.appendChild(a, pop.wrapper);
    try c.appendChild(a, stage);

    // -- Menu (SwiftUI Menu, native_menu_morph.swift menu) -- Native: menu panel is regular
    // glass (gray 128 on top 230, no shadow), 88x81.5, corner 11, top-left (108.25, 135),
    // 5.25 left of the button's left, 3.5 below the button's bottom; three rows 24 tall, text
    // indent 16.75, opaque 35 gray. Open appears fully this frame, close is an exp fade
    // (Transition.menu_fade); trigger button stays pressed while the menu is open.
    try c.appendChild(a, try labelNode(cx, "Menu: appears at once (no scale, no fade-in), fades out on dismiss; the trigger stays pressed while open"));
    const mstage = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = 480 }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255), .padding = .{ .left = 108.25, .top = 108 } }, .{});
    mstage.meta.ownership.meta.test_id = "story.glassmenu.stage";
    const menu = try W.Popover(.{
        .position = .bottom_start,
        .trigger = .click,
        .offset = .{ .static = 3.5 },
        .enter_transition = .menu_fade,
        .exit_transition = .menu_fade,
        .flip = false,
    }).mount(scope, cx);
    menu.chrome.meta.ownership.meta.test_id = "story.glassmenu.panel";
    {
        const panel = menu.chrome;
        panel.setBackground(ui.Color.rgba(0, 0, 0, 0));
        panel.style.border = .{ .overlay = true, .width = 0, .color = ui.Color.rgba(0, 0, 0, 0), .radius = 0 };
        panel.style.padding = ui.Padding.all(0);
        panel.style.overflow_hidden = false;
        const ext = panel.style.ensureExtPanic(a);
        ext.clearShadows();
        ext.clip_shape = .none;
        ext.hit_shape = .rect;
    }
    const mpanel = try W.GlassBox(.{ .width = 88, .height = 81.5, .corner_radius = 11, .drop_shadow = false, .padding = .{ .top = 5, .bottom = 4.5, .left = 16.75, .right = 8 }, .body_gap = 0 }).mountWithState(scope, cx);
    const menu_ink = ui.Color.rgba(35, 35, 35, 255);
    for ([_][]const u8{ "Copy", "Paste", "Delete" }) |item| {
        const item_row = try ui.box(cx, .{ .height = .{ .px = 24 }, .align_items = .center, .direction = .row }, .{});
        try item_row.appendChild(a, try glassLabel(cx, item, 400, menu_ink));
        try mpanel.body.appendChild(a, item_row);
    }
    try menu.content.appendChild(a, mpanel.box);
    const trig = try ui.box(cx, .{ .direction = .row, .padding = .{ .left = 5.25 } }, .{});
    const mbtn = try W.GlassBox(.{ .width = 92.5, .height = 23.5, .shape = .capsule, .press_feedback = .glass_button, .padding = ui.Padding.all(0), .body_gap = 0 }).mountWithState(scope, cx);
    mbtn.body.style.direction = .row;
    mbtn.body.style.align_items = .center;
    mbtn.body.style.justify = .center;
    mbtn.body.style.gap = 6;
    try mbtn.body.appendChild(a, try glassLabel(cx, "Actions", 400, ui.Color.rgba(0, 0, 0, 255)));
    var chev = ui.Style{};
    chev.width = .{ .px = 10 };
    chev.height = .{ .px = 10 };
    try mbtn.body.appendChild(a, try ui.iconTint(cx, ui.assets.common.chevron_down, ui.Color.rgba(0, 0, 0, 255), chev));
    mbtn.box.meta.ownership.meta.test_id = "story.glassmenu.button";
    try trig.appendChild(a, mbtn.box);
    try menu.trigger.appendChild(a, trig);
    // Button stays pressed while menu open (effect on Popover scope)
    if (menu.open) |open_sig| {
        const Hold = struct {
            sig: *ui.Signal(bool),
            state: *ui.widgets.glass_box.AdaptiveGlassBoxState,
            fn run(self: *@This()) void {
                ui.widgets.glass_box.glassSetHeld(self.state, self.sig.get());
            }
        };
        const hold = try menu.scope.allocator.create(Hold);
        hold.* = .{ .sig = open_sig, .state = mbtn.state };
        try menu.scope.adoptResource(@ptrCast(hold), struct {
            fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*Hold, @ptrCast(@alignCast(ptr))));
            }
        }.cleanup);
        try menu.scope.createEffect(hold, Hold.run);
    }
    try mstage.appendChild(a, menu.wrapper);
    try c.appendChild(a, mstage);
    return c;
}

// -- GlassSplit: expand / collapse (Apple official approach 1:1, gray 128 base) --
//
// Corresponds to the developer.apple.com "Applying Liquid Glass to custom views" glassEffectID
// example: GlassEffectContainer `if expanded` adds/removes elements + withAnimation. Native
// frame-by-frame (scripts/glass_native_model/native_expand_collapse.swift) uses the same
// geometry as the story. Toolbar: first element 450x44 <-> 150x44, two other 150x44 sub-bars
// inserted/removed; container spacing 24 = HStack gap (Apple recommends spacing <= layout
// gap, static no snap). Card: first 300x146 <-> 150x40, two floating bars inserted/removed;
// container spacing 40. GlassGroup.transact handles all transitions: an inserted sub-bar grows
// from the first element's end cap and collapses back on shrink (matched geometry); on card
// shrink two distant bars exceed spacing -> materialize fade-out, matching native.
const GlassSplitStory = struct {
    cx: *ui.Cx,
    g1: ui.widgets.glass_group.GlassGroupMount,
    g2: ui.widgets.glass_group.GlassGroupMount,
    bars: [3]ui.widgets.glass_group.GlassShapeEntry,
    cards: [3]ui.widgets.glass_group.GlassShapeEntry,
    split: bool = false,
    expanded: bool = false,
    /// 16x slowmo (e2e): transact duration 500 -> 8000ms. Bridge existence depends only on
    /// geometry state, independent of playback speed; native gap 2-22 window ~250ms, 200-400ms
    /// screenshots often land zero frames; at 8x gap 0-9 window still ~400ms, full run rarely
    /// miss one frame.
    slow: bool = false,
    const bar_collapsed = [4]f32{ 0, 0, 450, 44 };
    const bar_split = [3][4]f32{ .{ -24, 0, 150, 44 }, .{ 150, 0, 150, 44 }, .{ 324, 0, 150, 44 } };
    const card_collapsed = [4]f32{ 90, 10, 300, 146 };
    const card_split = [3][4]f32{ .{ 0, 10, 150, 40 }, .{ 330, 10, 150, 40 }, .{ 165, 120, 150, 40 } };
    const GG = ui.widgets.glass_group;
    fn toggleSlow(self: *GlassSplitStory) void {
        self.slow = !self.slow;
    }
    fn toggleBars(self: *GlassSplitStory) void {
        self.split = !self.split;
        const ms: f64 = if (self.slow) 8000 else 500;
        if (self.split) {
            GG.transact(self.g1, .{
                .moves = &.{.{ .entry = self.bars[0], .rect = bar_split[0] }},
                .inserts = &.{ .{ .entry = self.bars[1], .rect = bar_split[1] }, .{ .entry = self.bars[2], .rect = bar_split[2] } },
                .duration_ms = ms,
            });
        } else {
            GG.transact(self.g1, .{
                .moves = &.{.{ .entry = self.bars[0], .rect = bar_collapsed }},
                .removes = &.{ self.bars[1], self.bars[2] },
                .duration_ms = ms,
            });
        }
        self.cx.needs_redraw = true;
    }
    // Tap anytime like toolbar: mid-animation tap reverses mid-path (transact reverses from
    // current geometry)
    fn toggleCard(self: *GlassSplitStory) void {
        self.expanded = !self.expanded;
        const ms: f64 = if (self.slow) 8000 else 500;
        if (self.expanded) {
            GG.transact(self.g2, .{
                .moves = &.{.{ .entry = self.cards[0], .rect = card_split[0] }},
                .inserts = &.{ .{ .entry = self.cards[1], .rect = card_split[1] }, .{ .entry = self.cards[2], .rect = card_split[2] } },
                .duration_ms = ms,
            });
        } else {
            GG.transact(self.g2, .{
                .moves = &.{.{ .entry = self.cards[0], .rect = card_collapsed }},
                .removes = &.{ self.cards[1], self.cards[2] },
                .duration_ms = ms,
            });
        }
        self.cx.needs_redraw = true;
    }
};
fn glassSplitStage(cx: *ui.Cx, height: f32) !*ui.Node {
    const n = try ui.box(cx, .{ .width = .{ .px = 640 }, .height = .{ .px = height }, .position = .relative, .background = ui.Color.rgba(128, 128, 128, 255) }, .{});
    return n;
}
fn glassSplitMember(scope: *ui.Scope, cx: *ui.Cx, group: ui.widgets.glass_group.GlassGroupMount, rect: [4]f32, shape: ui.widgets.glass_box.GlassBoxShape, test_id: []const u8) !ui.widgets.glass_group.GlassShapeEntry {
    const e = try W.GlassShape(.{ .width = rect[2], .height = rect[3], .shape = shape, .padding = ui.Padding.all(0) }).mountIn(group, scope, cx);
    e.node.style.position = .absolute;
    (try e.node.style.ensureExtFallible(cx.allocator)).inset = .{ .left = .{ .px = rect[0] }, .top = .{ .px = rect[1] } };
    e.node.meta.ownership.meta.test_id = test_id;
    return e;
}
pub fn buildGlassSplit(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    const controls = try ui.box(cx, .{ .direction = .row, .gap = 10 }, .{});
    try c.appendChild(a, controls);

    try c.appendChild(a, try labelNode(cx, "Toolbar expands into three capsules (Apple glassEffectID pattern: container spacing 24 = stack spacing, withAnimation)"));
    const stage1 = try glassSplitStage(cx, 140);
    stage1.meta.ownership.meta.test_id = "story.glasssplit.stage1";
    const g1 = try W.GlassGroup(.{ .spacing = 24, .merge = .transitions, .width = 450, .height = 44 }).mountWithState(scope, cx);
    g1.container.style.position = .absolute;
    (try g1.container.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 95 }, .top = .{ .px = 48 } };
    var bars: [3]ui.widgets.glass_group.GlassShapeEntry = undefined;
    inline for (.{ "story.glasssplit.bar0", "story.glasssplit.bar1", "story.glasssplit.bar2" }, 0..) |tid, i| {
        const r = if (i == 0) GlassSplitStory.bar_collapsed else GlassSplitStory.bar_split[i];
        bars[i] = try glassSplitMember(scope, cx, g1, r, .capsule, tid);
        if (i > 0) ui.widgets.glass_box.glassSetEnabledImmediate(bars[i].state, false);
    }
    try stage1.appendChild(a, g1.container);
    try c.appendChild(a, stage1);

    try c.appendChild(a, try labelNode(cx, "Card collapses into three floating bars (300x146 card -> 150x40 bars)"));
    const stage2 = try glassSplitStage(cx, 200);
    stage2.meta.ownership.meta.test_id = "story.glasssplit.stage2";
    const g2 = try W.GlassGroup(.{ .spacing = 40, .merge = .transitions, .width = 480, .height = 170 }).mountWithState(scope, cx);
    g2.container.style.position = .absolute;
    (try g2.container.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 80 }, .top = .{ .px = 15 } };
    var cards: [3]ui.widgets.glass_group.GlassShapeEntry = undefined;
    inline for (.{ "story.glasssplit.card0", "story.glasssplit.card1", "story.glasssplit.card2" }, 0..) |tid, i| {
        const r = if (i == 0) GlassSplitStory.card_collapsed else GlassSplitStory.card_split[i];
        cards[i] = try glassSplitMember(scope, cx, g2, r, .{ .rounded = 16 }, tid);
        if (i > 0) ui.widgets.glass_box.glassSetEnabledImmediate(cards[i].state, false);
    }
    try stage2.appendChild(a, g2.container);
    try c.appendChild(a, stage2);

    const st = try cx.bindState(GlassSplitStory, .{ .cx = cx, .g1 = g1, .g2 = g2, .bars = bars, .cards = cards });
    const b1 = try W.Button(.{ .label = "Split toolbar", .on_click = cx.on(GlassSplitStory, st, GlassSplitStory.toggleBars) }).mount(scope, cx);
    b1.meta.ownership.meta.test_id = "story.glasssplit.splitbtn";
    try controls.appendChild(a, b1);
    const b2 = try W.Button(.{ .label = "Expand card", .on_click = cx.on(GlassSplitStory, st, GlassSplitStory.toggleCard) }).mount(scope, cx);
    b2.meta.ownership.meta.test_id = "story.glasssplit.cardbtn";
    try controls.appendChild(a, b2);
    const b3 = try W.Button(.{ .label = "Slow ×16", .on_click = cx.on(GlassSplitStory, st, GlassSplitStory.toggleSlow) }).mount(scope, cx);
    b3.meta.ownership.meta.test_id = "story.glasssplit.slowbtn";
    try controls.appendChild(a, b3);
    return c;
}

// -- GlassIslands: two "blur + rounded_clip on the same node" islands in one frame --
//
// Regression target: one node has both ext.glass(backdrop_blur) and overflow_hidden +
// corner_radius (effect chain backdrop_blur -> rounded_clip, both requires_offscreen);
// with two such nodes in the same frame, the second-drawn node's content is wholly invisible
// (content commands never fell into its own layer scope and the glass backboard composite
// covers them). Mirrors a downstream app Sidebar+Inspector.
pub fn buildGlassIslands(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = scope;
    const a = cx.allocator;
    const c = try col(cx, 12);
    c.style.ensureExtPanic(a).align_self = .stretch;

    const bd = try glassBackdrop(cx, 420);
    // High-freq black/white stripe target pressed under first island left edge (islands_row
    // padding 24 -> island left x=24): gi=0 pledges "blur only", blur(24) averages 8px period
    // to gray; rim zone if sharp revert (glass.metal rim_sharp missing gi gate regression), 8px
    // left band sharp exposes sharp dark stripe, e2e rim/ref band darkest pixel delta
    // assert. Single black bar no: blurred black bar also dark, sharp/blur diff ~25 gray,
    // can't catch mutation.
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
            // alpha 40: bg one level lower, rim-band pixel assert needs sharp/blur black bar
            // contrast
            // window (96 at 37% white lifts sharp black to ~160, blur ~190, can't catch regression)
            .background = ui.Color.rgba(255, 255, 255, 40),
            .border = .{ .overlay = true, .width = 1, .color = ui.Color.rgba(255, 255, 255, 140), .radius = 12 },
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
        // Dark content block: e2e pixel assert target (missing content bug this only white glass
        // base)
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

// ── Stack (VStack / HStack) ──
const LayoutPreviewS = struct {
    fn chip(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .background = t.tokens.color.bg_secondary, .padding = ui.Padding.symmetric(t.tokens.space.space100, t.tokens.space.space200), .corner_radius = t.tokens.radius.md };
    }
    fn text(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = t.tokens.font_size.sm, .line_height = 1.4, .color = t.tokens.color.fg_primary };
    }
    fn cell(t: *const ui.theme.Values) ui.BoxStyle {
        // COMPONENTS.json Grid: 52px cells separated by 8px.
        return .{ .width = .fixed(52), .height = .fixed(52), .background = t.tokens.color.bg_secondary, .border = .{ .overlay = true, .width = 1, .color = t.tokens.color.border, .radius = t.tokens.radius.md } };
    }
};
const layout_chip_props = .{ .style = LayoutPreviewS.chip };
const layout_text_props = .{ .style = LayoutPreviewS.text };
fn layoutChip(text: []const u8) @TypeOf(v.box(layout_chip_props, v.text(layout_text_props, text))) {
    return v.box(layout_chip_props, v.text(layout_text_props, text));
}

pub fn buildStack(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        label("HStack gap=8"),
        v.with(W.HStack(.{ .gap = 8 }), .{
            layoutChip("One"), layoutChip("Two"), layoutChip("Three"),
        }),
        label("VStack gap=8"),
        v.with(W.VStack(.{ .gap = 8, .align_items = .start }), .{
            layoutChip("One"), layoutChip("Two"), layoutChip("Three"),
        }),
        label("justify: start / center / space_between (width 320)"),
        v.with(W.VStack(.{ .gap = 6 }), .{
            v.with(W.HStack(.{ .gap = 8, .width = 320, .justify = .start, .background = ui.Color.rgba(0, 0, 0, 10) }), .{ W.Tag(.{ .label = "1" }), W.Tag(.{ .label = "2" }), W.Tag(.{ .label = "3" }) }),
            v.with(W.HStack(.{ .gap = 8, .width = 320, .justify = .center, .background = ui.Color.rgba(0, 0, 0, 10) }), .{ W.Tag(.{ .label = "1" }), W.Tag(.{ .label = "2" }), W.Tag(.{ .label = "3" }) }),
            v.with(W.HStack(.{ .gap = 8, .width = 320, .justify = .space_between, .background = ui.Color.rgba(0, 0, 0, 10) }), .{ W.Tag(.{ .label = "1" }), W.Tag(.{ .label = "2" }), W.Tag(.{ .label = "3" }) }),
        }),
        label("wrap: items flow onto the next line"),
        v.with(W.HStack(.{ .gap = 8, .width = 260, .wrap = true }), .{
            W.Tag(.{ .label = "design" }), W.Tag(.{ .label = "gpu" }),     W.Tag(.{ .label = "layout" }),
            W.Tag(.{ .label = "text" }),   W.Tag(.{ .label = "a11y" }),    W.Tag(.{ .label = "animation" }),
            W.Tag(.{ .label = "glass" }),  W.Tag(.{ .label = "signals" }),
        }),
        label("Nested: a toolbar row inside a card column"),
        v.with(W.VStack(.{ .gap = 10, .width = 320, .padding = ui.Padding.all(12), .background = ui.Color.rgba(0, 0, 0, 10) }), .{
            v.text(.{ .style = S.storyBody }, "Release notes"),
            v.with(W.HStack(.{ .gap = 8, .justify = .end }), .{
                W.Button(.{ .label = "Cancel", .size = .sm, .variant = .ghost }),
                W.Button(.{ .label = "Publish", .size = .sm }),
            }),
        }),
    }));
}

// -- Layout / Box Model --
//
// Not a decoration demo but a visual spec page for the layout engine. Fixed sizes and stable
// test_id let manual screenshots and Harness geometry asserts share one tree, covering the CSS
// padding-box absolute containing block, Flex/Grid out-of-flow, size modes, margin/gap and
// overflow.
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
    const violet = ui.Color.rgba(124, 58, 237, 255);
};

const LayoutS = struct {
    fn page(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 22, .width = .{ .px = 720 } };
    }
    fn coverage(_: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .width = .{ .px = 700 },
            .gap = 4,
            .padding = Padding.all(14),
            .background = layout_col.surface,
            .border = .{ .overlay = true, .width = 1, .color = layout_col.line, .radius = 8 },
        };
    }
    fn coverageTitle(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .font_weight = 700, .color = t.tokens.color.fg_primary };
    }
    fn sectionTitle(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 15, .font_weight = 700, .color = t.tokens.color.fg_primary };
    }
    fn sectionDetail(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .color = t.tokens.color.fg_secondary };
    }
    fn badgeText(_: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 11, .font_weight = 650, .color = layout_col.ink_on_color };
    }
    fn arena(width: f32, height: f32, padding: Padding) ui.BoxStyle {
        return .{
            .width = .{ .px = width },
            .height = .{ .px = height },
            .position = .relative,
            .padding = padding,
            .background = layout_col.padding,
            .border = .{ .overlay = true, .width = 1, .color = layout_col.line, .radius = 8 },
            .overflow_hidden = true,
        };
    }
    fn contentGuide(_: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .justify = .center,
            .align_items = .center,
            .background = layout_col.content,
            .border = .{ .overlay = true, .width = 1, .color = ui.Color.rgba(96, 165, 250, 255), .radius = 4 },
        };
    }
    fn contentGuideText(_: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .font_weight = 650, .color = ui.Color.rgba(30, 64, 175, 255) };
    }
    fn vguide(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .position = .absolute, .width = .{ .px = 1 }, .height = .{ .grow = .{} }, .background = layout_col.guide };
    }
    fn hguide(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .position = .absolute, .width = .{ .grow = .{} }, .height = .{ .px = 1 }, .background = layout_col.guide };
    }
    fn stretchChild(_: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .justify = .center,
            .align_items = .center,
            .background = layout_col.stretch,
            .border = .{ .radius = 5 },
        };
    }
    fn stretchText(_: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .font_weight = 650, .color = layout_col.ink_on_color };
    }
    fn flexParent(_: *const ui.theme.Values) ui.BoxStyle {
        var s = arena(342, 170, Padding.all(20));
        s.gap = 12;
        s.align_items = .center;
        return s;
    }
    fn sizingParent(_: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .width = .{ .px = 700 },
            .height = .{ .px = 100 },
            .align_items = .center,
            .gap = 10,
            .padding = Padding.all(20),
            .background = layout_col.content,
            .border = .{ .overlay = true, .width = 1, .color = layout_col.line, .radius = 8 },
        };
    }
    fn grow(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .grow = .{} } };
    }
    fn absolute(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .position = .absolute };
    }
    /// Absolute position + four-edge offset
    fn absAt(inset: ui.Inset) ui.BoxStyle {
        return .{ .position = .absolute, .inset = inset };
    }
    /// Offset only (position from same-group style)
    fn at(inset: ui.Inset) ui.BoxStyle {
        return .{ .inset = inset };
    }
    fn fit(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .fit = .{} } };
    }
    /// flex.grow badge: grow + right margin 10 (rest edge stay 0)
    fn growMarginRight(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .grow = .{} }, .margin = .{ .right = 10 } };
    }
};

const LayoutBadge = struct { txt: []const u8, w: f32, h: f32, bg: ui.Color };

/// Color block badge (fixed size + center white text): component form, outer layer via
/// attrs stack position and test_id.
fn layoutBadgeView(p: LayoutBadge, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.box(.{ .style = ui.BoxStyle{
        .width = .{ .px = p.w },
        .height = .{ .px = p.h },
        .justify = .center,
        .align_items = .center,
        .background = p.bg,
        .border = .{ .radius = 5 },
    } }, v.text(.{ .style = LayoutS.badgeText }, p.txt)));
}

fn layoutBadge(txt: []const u8, w: f32, h: f32, bg: ui.Color) v.ComponentOf(layoutBadgeView) {
    return v.component(layoutBadgeView, LayoutBadge{ .txt = txt, .w = w, .h = h, .bg = bg });
}

const LayoutSection = struct { title: []const u8, detail: []const u8 };

fn layoutSectionView(p: LayoutSection, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(3) }, .{
        v.text(.{ .style = LayoutS.sectionTitle }, p.title),
        v.text(.{ .style = LayoutS.sectionDetail }, p.detail),
    }));
}

fn layoutSection(title: []const u8, detail: []const u8) v.ComponentOf(layoutSectionView) {
    return v.component(layoutSectionView, LayoutSection{ .title = title, .detail = detail });
}

fn layoutGridPanel(_: *const ui.theme.Values) ui.BoxStyle {
    return .{
        .width = .{ .px = 342 },
        .height = .{ .px = 170 },
        .padding = Padding.all(20),
        .background = layout_col.padding,
        .border = .{ .overlay = true, .width = 1, .color = layout_col.line, .radius = 8 },
        .align_items = .center,
    };
}

const layout_grid_columns = [_]ui.GridTrackSize{ .{ .px = 70 }, .{ .fr = 1 }, .{ .fr = 2 } };
const layout_grid_rows = [_]ui.GridTrackSize{.{ .px = 52 }};

const JustifySpec = struct { justify: ui.JustifyContent, name: []const u8 };
const layout_justify = [_]JustifySpec{
    .{ .justify = .start, .name = "start" },
    .{ .justify = .center, .name = "center" },
    .{ .justify = .end, .name = "end" },
};

fn justifySampleView(spec: JustifySpec, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(5) }, .{
        label(spec.name),
        v.row(.{ .style = ui.BoxStyle{
            .width = .{ .px = 220 },
            .height = .{ .px = 92 },
            .justify = spec.justify,
            .align_items = .center,
            .gap = 8,
            .padding = Padding.all(12),
            .background = layout_col.content,
            .border = .{ .overlay = true, .width = 1, .color = layout_col.line, .radius = 8 },
        } }, .{
            layoutBadge("1", 36, 30, layout_col.flow),
            layoutBadge("2", 36, 30, layout_col.flow_alt),
        }),
    }));
}

fn justifySample(spec: JustifySpec) v.ComponentOf(justifySampleView) {
    return v.component(justifySampleView, spec);
}

const OverflowSpec = struct { clipped: bool, name: []const u8 };
const layout_overflow = [_]OverflowSpec{
    .{ .clipped = true, .name = "overflow_hidden" },
    .{ .clipped = false, .name = "overflow_visible" },
};

fn overflowSampleView(spec: OverflowSpec, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(5) }, .{
        label(spec.name),
        v.box(.{ .style = ui.BoxStyle{
            .width = .{ .px = 342 },
            .height = .{ .px = 110 },
            .position = .relative,
            .padding = Padding.all(12),
            .background = layout_col.surface,
            .border = .{ .overlay = true, .width = 1, .color = layout_col.line, .radius = 8 },
            .overflow_hidden = spec.clipped,
        } }, v.attrs(.{ .style = LayoutS.absAt(.{ .left = .{ .px = 280 }, .top = .{ .px = 55 } }) }, layoutBadge("100 × 60", 100, 60, layout_col.absolute))),
    }));
}

fn overflowSample(spec: OverflowSpec) v.ComponentOf(overflowSampleView) {
    return v.component(overflowSampleView, spec);
}

pub fn buildLayoutBoxModel(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const L = LayoutS;
    return v.render(scope, cx, v.col(.{ .style = L.page }, .{
        // Coverage matrix written at page top, screenshot itself serves manual acceptance
        // checklist.
        v.col(.{ .style = L.coverage }, .{
            v.text(.{ .style = L.coverageTitle }, "Coverage matrix"),
            label("padding / border / content · px / fit / percent / grow · margin / gap"),
            label("row / justify / align · Grid px + fr · absolute inset / percent / stretch · overflow clip"),
        }),

        // 1) CSS padding-box anatomy. Parent 700x180, asymmetric padding L32/R44/T28/B20.
        // Absolute right:0/bottom:0 must touch padding edge (Zenit border paint-only, so edge
        // matches local rect edge).
        layoutSection("1. Padding-box anatomy + absolute edges", "amber = padding box · blue = content box · red = right:0 / bottom:0 · navy = content edge"),
        v.box(.{ .style = L.arena(700, 180, .{ .left = 32, .right = 44, .top = 28, .bottom = 20 }), .test_id = "story.layoutbox.absolute.parent" }, .{
            v.box(.{ .style = .{ L.contentGuide, L.at(.{ .left = .{ .px = 32 }, .right = .{ .px = 44 }, .top = .{ .px = 28 }, .bottom = .{ .px = 20 } }) }, .test_id = "story.layoutbox.absolute.content-guide" }, v.text(.{ .style = L.contentGuideText }, "content 624 × 132")),
            v.attrs(.{ .test_id = "story.layoutbox.absolute.origin", .style = L.absAt(.{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }) }, layoutBadge("0,0", 38, 26, layout_col.stretch)),
            v.attrs(.{ .test_id = "story.layoutbox.absolute.outer-edge", .style = L.absAt(.{ .right = .{ .px = 0 }, .bottom = .{ .px = 0 } }) }, layoutBadge("edge", 44, 30, layout_col.absolute)),
            v.attrs(.{ .test_id = "story.layoutbox.absolute.content-edge", .style = L.absAt(.{ .right = .{ .px = 44 }, .bottom = .{ .px = 20 } }) }, layoutBadge("content", 58, 30, layout_col.flow)),
        }),
        label("Expected: content=(32,28 624×132), red right/bottom gap=0, navy right gap=44 bottom gap=20"),

        // 2) Percentage resolution and double-sided grow stretch.
        layoutSection("2. Percentage inset + double-sided stretch", "Percentages resolve against the full padding box; left+right/top+bottom constrain grow size."),
        v.row(.{ .style = S.line(16) }, .{
            v.col(.{ .style = S.stack(6) }, .{
                label("left:25% · top:50% → (85.5, 75)"),
                v.box(.{ .style = L.arena(342, 150, Padding.all(20)), .test_id = "story.layoutbox.percent.parent" }, .{
                    v.box(.{ .style = .{ L.vguide, L.at(.{ .left = .{ .px = 85.5 } }) } }, {}),
                    v.box(.{ .style = .{ L.hguide, L.at(.{ .top = .{ .px = 75 } }) } }, {}),
                    v.attrs(.{ .test_id = "story.layoutbox.percent.marker", .style = L.absAt(.{ .left = .{ .percent = 25 }, .top = .{ .percent = 50 } }) }, layoutBadge("25/50", 52, 28, layout_col.absolute)),
                }),
            }),
            v.col(.{ .style = S.stack(6) }, .{
                label("L14 / R22 / T18 / B12 + grow"),
                v.box(.{ .style = L.arena(342, 150, .{ .left = 26, .right = 12, .top = 10, .bottom = 22 }), .test_id = "story.layoutbox.stretch.parent" }, v.box(.{ .style = .{ L.stretchChild, L.at(.{ .left = .{ .px = 14 }, .right = .{ .px = 22 }, .top = .{ .px = 18 }, .bottom = .{ .px = 12 } }) }, .test_id = "story.layoutbox.stretch.child" }, v.text(.{ .style = L.stretchText }, "306 × 120"))),
            }),
        }),

        // 3) Flex and Grid both keep absolute children out of normal placement,
        // while using the same padding-box containing block for inset resolution.
        layoutSection("3. Flex vs Grid: in-flow content and out-of-flow absolute", "Flow items start at padding.left; the red absolute marker consumes no gap, track, or flex space."),
        v.row(.{ .style = S.line(16) }, .{
            v.col(.{ .style = S.stack(6) }, .{
                label("Flex row · padding 20 · gap 12 · margins on B"),
                v.row(.{ .style = L.flexParent, .test_id = "story.layoutbox.flex.parent" }, .{
                    v.attrs(.{ .test_id = "story.layoutbox.flex.a" }, layoutBadge("A 64", 64, 56, layout_col.flow)),
                    v.attrs(.{ .test_id = "story.layoutbox.flex.b", .style = .{ .margin = .{ .left = 8, .right = 6, .top = 0, .bottom = 0 } } }, layoutBadge("B +m", 64, 56, layout_col.flow_alt)),
                    v.attrs(.{ .test_id = "story.layoutbox.flex.grow", .style = L.growMarginRight }, layoutBadge("grow", 10, 56, layout_col.violet)),
                    v.attrs(.{ .test_id = "story.layoutbox.flex.absolute", .style = L.absAt(.{ .right = .{ .px = 0 }, .top = .{ .px = 0 } }) }, layoutBadge("abs", 34, 34, layout_col.absolute)),
                }),
            }),
            v.col(.{ .style = S.stack(6) }, .{
                label("Grid · 70px / 1fr / 2fr · gap 8"),
                v.grid(.{
                    .columns = &layout_grid_columns,
                    .rows = &layout_grid_rows,
                    .column_gap = 8,
                    .style = layoutGridPanel,
                    .test_id = "story.layoutbox.grid.parent",
                }, .{
                    v.attrs(.{ .test_id = "story.layoutbox.grid.a", .style = LayoutS.grow }, layoutBadge("70px", 10, 52, layout_col.flow)),
                    v.attrs(.{ .test_id = "story.layoutbox.grid.b", .style = LayoutS.grow }, layoutBadge("1fr", 10, 52, layout_col.flow_alt)),
                    v.attrs(.{ .test_id = "story.layoutbox.grid.c", .style = LayoutS.grow }, layoutBadge("2fr", 10, 52, layout_col.violet)),
                    v.attrs(.{ .test_id = "story.layoutbox.grid.absolute", .style = LayoutS.absAt(.{ .right = .{ .px = 0 }, .bottom = .{ .px = 0 } }) }, layoutBadge("abs", 34, 34, layout_col.absolute)),
                }),
            }),
        }),

        // 4) Sizing modes share the parent's content width, while the parent still
        // owns padding. This row makes px/percent/fit/grow contributions visible.
        layoutSection("4. Sizing modes inside one Flex row", "Parent 700 wide, padding 20 → content 660. The 20% item is 132 wide; grow receives the remainder."),
        v.row(.{ .style = L.sizingParent, .test_id = "story.layoutbox.sizing.parent" }, .{
            v.attrs(.{ .test_id = "story.layoutbox.sizing.px" }, layoutBadge("px 80", 80, 44, layout_col.flow)),
            v.attrs(.{ .test_id = "story.layoutbox.sizing.percent", .style = .{ .width = .{ .percent = 20 } } }, layoutBadge("20%", 10, 44, layout_col.flow_alt)),
            v.attrs(.{ .test_id = "story.layoutbox.sizing.fit", .style = L.fit }, layoutBadge("fit content", 10, 44, layout_col.violet)),
            v.attrs(.{ .test_id = "story.layoutbox.sizing.grow", .style = L.grow }, layoutBadge("grow", 10, 44, layout_col.stretch)),
        }),

        // 5) Main-axis distribution and cross-axis alignment. Each sample uses the
        // same content width, so start/center/end drift is immediately visible.
        layoutSection("5. Flex distribution: justify + align + gap", "Three identical 220×92 parents; only justify changes. Cross axis stays centered."),
        v.row(.{ .style = S.line(16) }, v.list(&layout_justify, justifySample)),

        // 6) Overflow is part of the box model contract. Same overflowing absolute
        // child in both arenas; only the left parent clips at its padding-box edge.
        layoutSection("6. Overflow clipping", "The rose block starts at (280,55), size 100×60. Left clips; right remains visible."),
        v.row(.{ .style = S.line(16) }, v.list(&layout_overflow, overflowSample)),
    }));
}

// ── Tabs ──
/// Tabs selected state echo, e2e asserts "tap truly switched", need observable outlet.
/// Component doesn't render "currently selected", so story prints on_change payload to
/// text line (same as CheckboxStory).
const TabsStory = struct {
    fn word(id: ?[]const u8) []const u8 {
        return id orelse "(none)";
    }
    fn is(id: ?[]const u8, want: []const u8) bool {
        return std.mem.eql(u8, id orelse "", want);
    }
    fn isT1(id: ?[]const u8) bool {
        return is(id, "t1");
    }
    fn isT2(id: ?[]const u8) bool {
        return is(id, "t2");
    }
    fn isT3(id: ?[]const u8) bool {
        return is(id, "t3");
    }
};

const tab_items = [_]W.tabs.TabItem{
    .{ .id = "t1", .label = "Overview" },
    .{ .id = "t2", .label = "Details" },
    .{ .id = "t3", .label = "Settings", .badge = 3 },
    .{ .id = "t4", .label = "Disabled", .disabled = true },
};
const tab_size_items = [_]W.tabs.TabItem{
    .{ .id = "a", .label = "One" },
    .{ .id = "b", .label = "Two" },
    .{ .id = "c", .label = "Three" },
};
const tab_sizes = [_]W.tabs.TabsSize{ .xs, .sm, .md, .lg };

fn sizedTabs(sz: W.tabs.TabsSize) @TypeOf(W.Tabs(.{ .items = &tab_size_items })) {
    return W.Tabs(.{ .items = &tab_size_items, .variant = .pill, .size = sz });
}

pub fn buildTabs(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Three variant bind same signal: tap any, others switch
    const active = try scope.createSignal(?[]const u8, "t1");
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        // -- Variants --
        label("underline"),
        v.attrs(.{ .test_id = "story.tabs.underline" }, W.Tabs(.{ .items = &tab_items, .variant = .underline, .active = active })),
        // the panels follow the same signal: only the active one lays out and is exposed to AT
        v.attrs(.{ .test_id = "story.tabs.panel.t1" }, v.with(W.TabPanel(.{ .id = "t1", .active = ui.map(active, TabsStory.isT1) }), .{v.text(.{ .style = S.storyLabel }, "Overview panel: the project at a glance.")})),
        v.attrs(.{ .test_id = "story.tabs.panel.t2" }, v.with(W.TabPanel(.{ .id = "t2", .active = ui.map(active, TabsStory.isT2) }), .{v.text(.{ .style = S.storyLabel }, "Details panel: owners, dates and links.")})),
        v.attrs(.{ .test_id = "story.tabs.panel.t3" }, v.with(W.TabPanel(.{ .id = "t3", .active = ui.map(active, TabsStory.isT3) }), .{v.text(.{ .style = S.storyLabel }, "Settings panel: 3 items need attention.")})),
        label("pill"),
        W.Tabs(.{ .items = &tab_items, .variant = .pill, .active = active }),
        label("tab"),
        W.Tabs(.{ .items = &tab_items, .variant = .tab, .active = active }),
        // -- Sizes --
        label("Sizes (xs / sm / md / lg)"),
        v.list(&tab_sizes, sizedTabs),
        v.text(.{ .style = S.storyLabel, .test_id = "story.tabs.status" }, v.fmt("active → {s}", .{ui.map(active, TabsStory.word)})),
    }));
}

// ── Accordion ──
const AccordionSpec = struct { title: []const u8, expanded: bool };
const accordion_sections = [_]AccordionSpec{
    .{ .title = "Section One", .expanded = true },
    .{ .title = "Section Two", .expanded = false },
    .{ .title = "Section Three", .expanded = false },
};
const accordion_body_props = .{ .style = S.storyLabel };

const AccordionModeStory = struct {
    open: [3]*ui.Signal(bool),
    exclusive: bool = false,
    fn useExclusive(self: *AccordionModeStory) void {
        self.exclusive = true;
    }
};
const AccordionItemWriter = struct {
    story: *AccordionModeStory,
    index: usize,
    /// Exclusive mode: opening one section closes the others (mutual expand via data).
    fn write(self: *AccordionItemWriter, expanded: bool) void {
        if (expanded and self.story.exclusive) {
            for (self.story.open, 0..) |sig, i| {
                if (i != self.index) sig.set(false);
            }
        }
        self.story.open[self.index].set(expanded);
    }
};
fn accordionModeItem(title: []const u8, expanded: anytype) @TypeOf(v.with(W.AccordionItem(.{ .title = title, .expanded = expanded }), v.text(accordion_body_props, @as([]const u8, "")))) {
    return v.with(W.AccordionItem(.{ .title = title, .expanded = expanded }), v.text(accordion_body_props, @as([]const u8, "Panel body content.")));
}

pub fn buildAccordion(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    var open: [3]*ui.Signal(bool) = undefined;
    for (&open, 0..) |*sig, i| sig.* = try scope.createSignal(bool, i == 0);
    const mode = try scope.createState(AccordionModeStory, .{ .open = open });
    const w0 = try scope.createState(AccordionItemWriter, .{ .story = mode, .index = 0 });
    const w1 = try scope.createState(AccordionItemWriter, .{ .story = mode, .index = 1 });
    const w2 = try scope.createState(AccordionItemWriter, .{ .story = mode, .index = 2 });
    // exclusive: one ?usize signal; each item derives its expanded state from it
    const faq_open = try scope.createSignal(?usize, 0);
    return v.render(scope, cx, v.col(.{ .style = demoWidth(420) }, .{
        label("Independent: several sections can be open"),
        v.with(W.Accordion(.{ .gap = 8 }), .{
            accordionModeItem(accordion_sections[0].title, ui.split(open[0], ui.on.call(w0, AccordionItemWriter.write))),
            accordionModeItem(accordion_sections[1].title, ui.split(open[1], ui.on.call(w1, AccordionItemWriter.write))),
            accordionModeItem(accordion_sections[2].title, ui.split(open[2], ui.on.call(w2, AccordionItemWriter.write))),
        }),
        // (switches the group above to exclusive writes; Windows a11y selection test)
        v.attrs(.{ .test_id = "story.accordion.exclusive" }, W.Button(.{ .label = "Use exclusive mode", .size = .sm, .variant = .ghost, .on_click = ui.on.call(mode, AccordionModeStory.useExclusive) })),
        label("Exclusive: opening one closes the others"),
        v.attrs(.{ .test_id = "story.accordion.faq" }, v.with(W.Accordion(.{ .gap = 8 }), .{
            v.with(W.AccordionItem(.{ .title = "What is a retained tree?", .variant = .outline, .expanded = W.accordionItemOpen(faq_open, 0) }), v.text(accordion_body_props, @as([]const u8, "Nodes are built once and updated in place."))),
            v.with(W.AccordionItem(.{ .title = "Does it use a WebView?", .variant = .outline, .expanded = W.accordionItemOpen(faq_open, 1) }), v.text(accordion_body_props, @as([]const u8, "No. Metal draws every pixel."))),
            v.with(W.AccordionItem(.{ .title = "Can sections animate?", .variant = .outline, .expanded = W.accordionItemOpen(faq_open, 2) }), v.text(accordion_body_props, @as([]const u8, "Yes: height and chevron follow the same spring."))),
        })),
    }));
}

// -- Menu (trigger+popover: item in popup, story adds trigger button, e2e tap verify
// item) --
const MenuStory = struct {
    fn inc(n: u32) u32 {
        return n + 1;
    }
    /// "Recent" menu items: each "Open another file" swaps array, menu rebuilds
    recent: *ui.Signal([]const W.MenuItem),
    opened: usize = 1,

    const recent_lists = [_][]const W.MenuItem{
        &.{.{ .id = "readme", .label = "README.md", .icon_asset = ui.assets.common.file_text }},
        &.{
            .{ .id = "main", .label = "main.zig", .icon_asset = ui.assets.common.code },
            .{ .id = "readme", .label = "README.md", .icon_asset = ui.assets.common.file_text },
        },
        &.{
            .{ .id = "build", .label = "build.zig", .icon_asset = ui.assets.common.code },
            .{ .id = "main", .label = "main.zig", .icon_asset = ui.assets.common.code },
            .{ .id = "readme", .label = "README.md", .icon_asset = ui.assets.common.file_text },
        },
    };

    fn openAnother(self: *MenuStory) void {
        self.opened = @min(self.opened + 1, recent_lists.len);
        self.recent.set(recent_lists[self.opened - 1]);
    }
};

const menu_items = [_]W.MenuItem{
    .{ .id = "new", .label = "New File", .shortcut = "⌘N", .icon_asset = ui.assets.common.plus },
    .{ .id = "open", .label = "Open…", .shortcut = "⌘O", .icon_asset = ui.assets.common.folder_open },
    .{ .id = "sep1", .kind = .separator },
    .{ .id = "cut", .label = "Cut", .shortcut = "⌘X" },
    .{ .id = "copy", .label = "Copy", .shortcut = "⌘C" },
    .{ .id = "paste", .label = "Paste", .shortcut = "⌘V", .disabled = true },
    .{ .id = "sep2", .kind = .separator },
    .{ .id = "del", .label = "Delete", .danger = true },
};

pub fn buildMenu(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Selected item writes signal, status line from it (static items + string copied by menu;
    // callback id valid only this call, so store owned-text signal)
    const picked = try scope.createText("(none)", .{});
    // Items driven by signal: new array, menu items rebuild
    const story = try scope.createState(MenuStory, .{
        .recent = try scope.createSignal([]const W.MenuItem, MenuStory.recent_lists[0]),
    });
    // per-item command: "Copy" also runs its own on_click (alongside the menu's on_select)
    const copies = try scope.createSignal(u32, 0);
    var items = menu_items;
    items[4].on_click = ui.on.update(copies, MenuStory.inc);
    return v.render(scope, cx, v.col(.{ .style = S.stack(8) }, .{
        v.row(.{ .style = S.line(8) }, .{
            // Put labeled button on trigger, make story visible/tappable
            v.attrs(.{ .test_id = "story.menu.trigger" }, v.with(W.Menu(.{ .items = &items, .on_select = ui.on.assign(picked) }), .{})
                .trigger(W.Button(.{ .label = "Actions ▾", .variant = .secondary }))),
            v.attrs(.{ .test_id = "story.menu.recent" }, v.with(W.Menu(.{ .items = story.recent, .on_select = ui.on.assign(picked), .width = 180 }), .{})
                .trigger(W.Button(.{ .label = "Recent ▾", .variant = .secondary }))),
            v.attrs(.{ .test_id = "story.menu.another" }, W.Button(.{
                .label = "Open another file",
                .variant = .ghost,
                .on_click = ui.on.call(story, MenuStory.openAnother),
            })),
        }),
        v.text(.{ .style = S.storyLabel, .test_id = "story.menu.status" }, v.fmt("picked → {s}", .{picked})),
        v.text(.{ .style = S.storyLabel, .test_id = "story.menu.copies" }, v.fmt("Copy on_click × {d}", .{copies})),
    }));
}

// ── Steps ──
const StepsStory = struct {
    const last: usize = 2;

    fn back(n: usize) usize {
        return n -| 1;
    }
    fn next(n: usize) usize {
        return @min(n + 1, last);
    }
    fn humanIndex(n: usize) usize {
        return n + 1;
    }
    fn atStart(n: usize) bool {
        return n == 0;
    }
    fn atEnd(n: usize) bool {
        return n >= last;
    }
};

const step_items = [_]W.StepItem{
    .{ .title = "Account", .description = "Create account" },
    .{ .title = "Profile", .description = "Fill details" },
    .{ .title = "Done", .description = "Finish" },
};

pub fn buildSteps(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const icons = ui.assets.common;
    // Horizontal: current step signal-driven, Back / Next write signal, title and button
    // disabled from it. Completed step real check icon (no check_icon_asset reverts "v" char
    // ugly)
    const step = try scope.createSignal(usize, 1);
    return v.render(scope, cx, v.col(.{ .style = S.stack(24) }, .{
        v.text(.{ .style = S.storyLabel }, v.fmt("Horizontal (step {d} active)", .{ui.map(step, StepsStory.humanIndex)})),
        v.attrs(.{ .style = ui.BoxStyle{ .width = .{ .px = 420 } } }, W.Steps(.{ .items = &step_items, .current = step, .check_icon_asset = icons.check })),
        v.row(.{ .style = S.stack(8) }, .{
            v.attrs(.{ .test_id = "story.steps.back" }, W.Button(.{
                .label = "Back",
                .variant = .secondary,
                .disabled = ui.map(step, StepsStory.atStart),
                .on_click = ui.on.update(step, StepsStory.back),
            })),
            v.attrs(.{ .test_id = "story.steps.next" }, W.Button(.{
                .label = "Next",
                .disabled = ui.map(step, StepsStory.atEnd),
                .on_click = ui.on.update(step, StepsStory.next),
            })),
        }),
        // Vertical
        label("Vertical"),
        W.Steps(.{ .items = &step_items, .current = 2, .direction = .vertical, .check_icon_asset = icons.check }),
    }));
}

// ── Rate ──
const rate_sizes = [_]f32{ 16, 24, 36 };

fn sizedRate(sz: f32) @TypeOf(W.Rate(.{})) {
    return W.Rate(.{ .count = 5, .value = 3, .size = sz });
}

pub fn buildRate(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Score signal-driven, label derived from it
    const score = try scope.createSignal(f32, 3);
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        v.text(.{ .style = S.storyLabel, .test_id = "story.rate.status" }, v.fmt("value {d:.0} / 5", .{score})),
        v.attrs(.{ .test_id = "story.rate.basic" }, W.Rate(.{ .count = 5, .value = score })),
        label("readonly value 4"),
        W.Rate(.{ .count = 5, .value = 4, .disabled = true }),
        // -- count variant --
        label("count 10, value 7"),
        W.Rate(.{ .count = 10, .value = 7 }),
        // -- size variants --
        label("Sizes (16 / 24 / 36)"),
        v.row(.{ .style = S.line(24) }, v.list(&rate_sizes, sizedRate)),
    }));
}

// ── Tree ──
const tree_leaves = [_]W.TreeNodeData{
    .{ .id = "main", .label = "main.zig" },
    .{ .id = "root", .label = "root.zig" },
};
const tree_nodes = [_]W.TreeNodeData{
    .{ .id = "src", .label = "src", .children = &tree_leaves },
    .{ .id = "readme", .label = "README.md" },
};

const tree_multi_nodes = [_]W.TreeNodeData{
    .{ .id = "a", .label = "Tree A" },
    .{ .id = "b", .label = "Tree B" },
    .{ .id = "c", .label = "Tree C" },
};

pub fn buildTree(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        v.attrs(.{ .test_id = "story.tree.single" }, W.Tree(.{ .label_text = "Single tree", .nodes = &tree_nodes, .selected = @as([]const []const u8, &.{"main"}), .expanded = @as([]const []const u8, &.{"src"}) })),
        v.attrs(.{ .test_id = "story.tree.multi" }, W.Tree(.{ .label_text = "Multi tree", .nodes = &tree_multi_nodes, .selection_mode = .multi })),
    }));
}

// ── Table ──
const TABLE_NAMES = [_][]const u8{ "Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace", "Heidi" };
const TABLE_ROLES = [_][]const u8{ "Admin", "User", "User", "Editor", "User", "Admin", "Editor", "User" };
const TABLE_AGES = [_][]const u8{ "20", "23", "26", "29", "32", "35", "38", "41" };
const TableS = struct {
    fn cell(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_primary };
    }
};
const table_cell_props = .{ .style = TableS.cell };

/// Table only renders: the app owns the data and its order. The story keeps the rows in
/// insertion order and maps each displayed row through the committed sort.
const TableSortStory = struct {
    fn key(c: usize, i: usize) []const u8 {
        return switch (c) {
            0 => TABLE_NAMES[i],
            1 => TABLE_ROLES[i],
            else => TABLE_AGES[i],
        };
    }
    /// source row shown at `row` under `sort` (8 rows: an insertion sort per lookup is fine)
    fn sourceRow(sort: ?W.table.TableSort, r: usize) usize {
        var order: [TABLE_NAMES.len]usize = undefined;
        for (&order, 0..) |*o, i| o.* = i;
        const st = sort orelse return r;
        if (st.direction == .none) return r;
        var i: usize = 1;
        while (i < order.len) : (i += 1) {
            var j = i;
            while (j > 0) : (j -= 1) {
                const o = std.mem.order(u8, key(st.column, order[j]), key(st.column, order[j - 1]));
                if (o != if (st.direction == .asc) std.math.Order.lt else std.math.Order.gt) break;
                std.mem.swap(usize, &order[j - 1], &order[j]);
            }
        }
        return order[r];
    }
    fn version(sort: ?W.table.TableSort) u64 {
        const st = sort orelse return 0;
        return 1 + st.column * 4 + @backingInt(st.direction);
    }
};

fn tableCell(sort: *ui.Signal(?W.table.TableSort), row_i: usize, col_i: usize) v.Text(@TypeOf(table_cell_props), []const u8) {
    return v.text(table_cell_props, TableSortStory.key(col_i, TableSortStory.sourceRow(sort.peek(), row_i % TABLE_NAMES.len)));
}

const table_cols = [_]W.ColumnDef{
    .{ .id = "name", .header = "Name", .width = 160, .sortable = true },
    .{ .id = "role", .header = "Role", .width = 120 },
    .{ .id = "age", .header = "Age", .width = 80, .sortable = true },
};

/// Virtual-body cell (> 50 rows): the name carries the row number so recycled slots are visible.
fn tableVirtualCell(row_i: usize, col_i: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const i = row_i % TABLE_NAMES.len;
    if (col_i == 0) return v.render(scope, cx, v.text(table_cell_props, v.fmt("{s} #{d}", .{ TABLE_NAMES[i], row_i })));
    return v.render(scope, cx, v.text(table_cell_props, TableSortStory.key(col_i, i)));
}

pub fn buildTable(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // header clicks commit the sort; the rows reorder through data_version
    const sort = try scope.createSignal(?W.table.TableSort, null);
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        W.Table(.{
            .columns = &table_cols,
            .row_count = 8,
            .striped = true,
            .sort = sort,
            .data_version = ui.map(sort, TableSortStory.version),
        }).cells(sort, tableCell),
        // Above 50 rows the body is virtualized (pooled slots); rows hover exactly like above.
        v.text(label_props, "Virtual body · 1,000 rows"),
        v.attrs(.{ .test_id = "story.table.virtual" }, W.Table(.{
            .columns = &table_cols,
            .row_count = 1000,
            .striped = true,
            .table_height = 232,
        }).cells({}, tableVirtualCell)),
    }));
}

// ── Calendar ──
pub fn buildCalendar(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, W.Calendar(.{ .month = W.calendar.YearMonth{ .year = 2026, .month = 10 }, .value = @as(?W.calendar.SimpleDate, .{ .year = 2026, .month = 10, .day = 16 }) }));
}

// ── DatePicker ──
pub fn buildDatePicker(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.attrs(.{ .test_id = "story.datepicker.empty" }, W.DatePicker(.{ .placeholder = "Pick a date" })),
        W.DatePicker(.{ .open = true, .test_id = "story.datepicker.open", .value = @as(?W.calendar.SimpleDate, .{ .year = 2026, .month = 10, .day = 16 }) }),
    }));
}

pub fn buildDateTimePicker(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, W.date_picker.DateTimePicker(.{ .open = true, .datetime_value = @as(?W.date_picker.DateTime, .{ .date = .{ .year = 2026, .month = 10, .day = 16 }, .time = .{ .hour = 14, .minute = 30 } }) }));
}

// ── DateRangePicker ──
pub fn buildDateRangePicker(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.attrs(.{ .test_id = "story.daterange.empty" }, W.DateRangePicker(.{})),
        W.DateRangePicker(.{ .confirm_selection = true, .open = true, .value = @as(?W.date_range_picker.DateRange, .{ .start = .{ .year = 2026, .month = 10, .day = 12 }, .end = .{ .year = 2026, .month = 10, .day = 18 } }) }),
    }));
}

// ── Tooltip ──
const TooltipSpec = struct { p: W.tooltip.TooltipPosition, t: []const u8, tip: []const u8 };
const tooltip_positions = [_]TooltipSpec{
    .{ .p = .top, .t = "Top", .tip = "Top tooltip" },
    .{ .p = .bottom, .t = "Bottom", .tip = "Bottom tooltip" },
    .{ .p = .left, .t = "Left", .tip = "Left tooltip" },
    .{ .p = .right, .t = "Right", .tip = "Right tooltip" },
};

fn tooltipAt(spec: TooltipSpec) @TypeOf(v.with(W.Tooltip(.{ .text = "" }), .{}).trigger(W.Button(.{}))) {
    return v.with(W.Tooltip(.{ .text = spec.tip, .position = spec.p }), .{})
        .trigger(W.Button(.{ .label = spec.t, .variant = .secondary }));
}

pub fn buildTooltip(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        // One trigger per cardinal direction, spaced to avoid overlay overlap.
        v.row(.{ .style = S.line(24) }, v.list(&tooltip_positions, tooltipAt)),
    }));
}

// -- Modal (opened via trigger button) --
pub fn buildModal(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const vis = try scope.createSignal(bool, false);
    // When portaled, overlay attaches to window-root portal (covers entire window),
    // viewParts.root is null, parent has no children; component test_ids use .parts.
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.attrs(.{ .test_id = "story.modal.open" }, W.Button(.{ .label = "Open Modal", .on_click = ui.on.set(vis, true) })),
        v.with(W.Modal(.{ .title = "Example Modal", .width = 400, .open = vis }), .{
            v.text(.{ .style = S.storyBody }, "Modal body content."),
            // Button with hover style: damage-rect e2e uses it to trigger "small change in
            // layer -> partial redraw"
            v.attrs(.{ .test_id = "story.modal.ok" }, W.Button(.{ .label = "OK", .on_click = ui.on.set(vis, false) })),
        }).parts(.{ .dialog = "story.modal.dialog" }),
    }));
}

// -- Sheet (opened via trigger button) --
pub fn buildSheet(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const vis = try scope.createSignal(bool, false);
    const vis_left = try scope.createSignal(bool, false);
    const vis_bottom = try scope.createSignal(bool, false);
    return v.render(scope, cx, v.row(.{ .style = S.line(12) }, .{
        v.attrs(.{ .test_id = "story.sheet.open" }, W.Button(.{ .label = "Open Sheet", .on_click = ui.on.set(vis, true) })),
        v.attrs(.{ .test_id = "story.sheet.open.left" }, W.Button(.{ .label = "From left", .variant = .secondary, .on_click = ui.on.set(vis_left, true) })),
        v.attrs(.{ .test_id = "story.sheet.open.bottom" }, W.Button(.{ .label = "From bottom", .variant = .secondary, .on_click = ui.on.set(vis_bottom, true) })),
        v.with(W.Sheet(.{ .side = .right, .width = 320, .open = vis }), v.text(.{ .style = S.storyBody }, "Sheet panel content."))
            .parts(.{ .panel = "story.sheet.panel" }),
        v.with(W.Sheet(.{ .side = .left, .width = 280, .open = vis_left }), v.text(.{ .style = S.storyBody }, "Navigation drawer from the leading edge."))
            .parts(.{ .panel = "story.sheet.panel.left" }),
        v.with(W.Sheet(.{ .side = .bottom, .height = 240, .open = vis_bottom }), v.text(.{ .style = S.storyBody }, "Bottom sheet: Escape or the barrier closes it."))
            .parts(.{ .panel = "story.sheet.panel.bottom" }),
    }));
}

// ── Popover ──
const PopS = struct {
    fn content(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .fixed(220), .padding = ui.Padding.all(t.tokens.space.space400), .gap = t.tokens.space.space200 };
    }
    fn title(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = t.tokens.font_size.md, .font_weight = 600, .line_height = 1.4, .color = t.tokens.color.fg_primary };
    }
    fn caption(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = t.tokens.font_size.sm, .line_height = 1.4, .color = t.tokens.color.fg_secondary };
    }
    /// Body text in popup (13px primary color)
    fn body(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_primary };
    }
    fn blockRow(_: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 28 },
            .align_items = .center,
            .padding = ui.Padding.symmetric(0, 8),
            .border = .{ .radius = 6 },
        };
    }
    fn staticCard(t: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .padding = ui.Padding.all(8),
            .width = .{ .px = 220 },
            .height = .{ .px = 80 },
            .background = t.tokens.color.bg_secondary,
            .border = .{ .overlay = true, .radius = 10, .width = 1, .color = t.tokens.color.border },
            .overflow_hidden = true,
            .clip_shape = .{ .rounded_rect = 10 },
            .shadows = ui.ShadowList.of(&.{
                .{ .color = ui.Color.rgba(0, 0, 0, 40), .blur = 12, .offset_y = 4 },
                .{ .color = ui.Color.rgba(0, 0, 0, 18), .blur = 40, .offset_y = 16 },
            }),
        };
    }
    fn tall(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 6, .padding = ui.Padding.all(8), .width = .{ .px = 220 }, .height = .{ .fit = .{} } };
    }
};

const pop_text_props = .{ .style = PopS.body };

const PopSpec = struct { pos: W.popover.PopoverPosition, trigger: W.popover.PopoverTrigger, btn: []const u8, content: []const u8 };
const pop_positions = [_]PopSpec{
    .{ .pos = .top, .trigger = .click, .btn = "Top", .content = "Opens above" },
    .{ .pos = .right, .trigger = .click, .btn = "Right", .content = "Opens to the right" },
    .{ .pos = .bottom, .trigger = .hover, .btn = "Hover me", .content = "Hover-triggered" },
};

fn popAt(s: PopSpec) @TypeOf(v.with(W.Popover(.{}), v.text(pop_text_props, @as([]const u8, ""))).trigger(W.Button(.{}))) {
    return v.with(W.Popover(.{ .position = s.pos, .trigger = s.trigger }), v.text(pop_text_props, s.content))
        .trigger(W.Button(.{ .label = s.btn, .variant = .secondary }));
}

const block_rows = [_][]const u8{ "Text", "Heading 1", "Heading 2", "Heading 3", "Quote", "Bullet", "Task", "Code block" };
const block_row_props = .{ .style = PopS.blockRow };

fn blockRow(row_label: []const u8) v.Box(@TypeOf(block_row_props), v.Text(@TypeOf(pop_text_props), []const u8), .row) {
    return v.row(block_row_props, v.text(pop_text_props, row_label));
}

/// Panel shell for block-type dropdown: via `.parts` stack background / stroke /
/// dual-layer shadow / z_index on Popover chrome component.
fn blockChrome(_: *const ui.theme.Values) ui.BoxStyle {
    return .{
        .direction = .column,
        .align_items = .stretch,
        .gap = 0,
        .padding = ui.Padding.symmetric(4, 4),
        .height = .{ .fit = .{} },
        .background = ui.Color.rgba(255, 255, 255, 255),
        .border = .{ .overlay = true, .radius = 10, .width = 1, .color = ui.Color.rgba(224, 224, 228, 255) },
        .overflow_hidden = false,
        .z_index = 82, // Same as downstream editor floats: overrides popover-assigned z-layer
        .shadows = ui.ShadowList.of(&.{
            .{ .color = ui.Color.rgba(0, 0, 0, 15), .blur = 3, .offset_y = 1 },
            .{ .color = ui.Color.rgba(0, 0, 0, 36), .blur = 28, .offset_y = 8 },
        }),
    };
}

fn blockDropdownView(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.with(W.Popover(.{
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
    }), v.list(&block_rows, blockRow))
        .trigger(W.Button(.{ .label = "Block Menu", .variant = .secondary }))
        .parts(.{
        .trigger = "story.popover.block.trigger",
        .chrome = .{ .test_id = "story.popover.block.content", .style = blockChrome },
    }));
}

/// Vertical four-segment gradient blocks (indigo -> pink -> orange -> cyan): for
/// overflow/scroll regression, position and color one-to-one.
const SlabProps = struct { style: ui.BoxStyle };

fn storyGradientSlab(w: f32, h: f32) v.Box(SlabProps, void, null) {
    return v.box(SlabProps{ .style = .{
        .width = .{ .px = w },
        .height = .{ .px = h },
        .flex_shrink = 0,
        .border = .{ .radius = 6 },
        .multi_gradient = ui.MultiGradient.fromSlice(&[_]ui.GradientStop{
            .{ .color = zx_indigo, .position = 0.0 },
            .{ .color = ui.Color.rgba(219, 72, 133, 255), .position = 0.35 },
            .{ .color = zx_orange, .position = 0.68 },
            .{ .color = zx_teal, .position = 1.0 },
        }, .vertical),
    } }, {});
}

pub fn buildPopover(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.with(W.Popover(.{ .position = .bottom_start, .trigger = .click }), v.col(.{ .style = PopS.content }, .{
            v.text(.{ .style = PopS.title }, "Popover content"),
            v.text(.{ .style = PopS.caption }, "Contextual content"),
        }))
            .trigger(W.Button(.{ .label = "Toggle Popover" })),

        // -- Other positions + hover trigger --
        label("Positions (top / right) + hover trigger"),
        v.row(.{ .style = S.line(24) }, v.list(&pop_positions, popAt)),

        // -- Block-type dropdown (isomorphic with editor selection toolbar block type menu) --
        // Regression anchor (e2e "popover: block dropdown shadow"): white background + radius 10 +
        // 1px stroke + dual-layer shadow (contact 0/1/3 + ambient 0/8/28) + fade_fast. Shadow must
        // be
        // complete and soft across the panel perimeter; no gray rectangles from clipping outside
        // the
        // rounded corners.
        label("Block-type dropdown (editor toolbar shape)"),
        v.component(blockDropdownView, {}),
    }));
}
/// Popover regression anchors (kept out of the Popover showcase): a static overflow_hidden card
/// as the reference for the composited panel's clipping contract, and a panel too tall for either
/// side, which must shrink to the viewport and scroll instead of covering its trigger.
pub fn buildPopoverRegressions(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        // -- Reference: static (non-composited) overflow_hidden rounded card + shadow +
        // overflow blue block --
        // Same visual contract as tall popover, but not via a composited surface: shadow is not
        // clipped by its own clip, blue block is clipped by the inner radius edge, stroke is not
        // covered by content.
        label("Static overflow_hidden card (reference): shadow outside, content clipped inside the border"),
        // Vertical gradient: which segment leaks from card bottom is immediately obvious
        // (solid color cannot show overflow/scroll position)
        v.col(.{ .style = PopS.staticCard, .test_id = "story.popover.static.card" }, storyGradientSlab(204, 400)),

        // -- Tall content: fits neither side -> autosize tightens max_height to available
        // height --
        // Regression anchor (e2e "popover: tall content"): before fix, panel kept full
        // height, best-fit only moved translate, bottom edge passed trigger obscuring
        // reference element.
        label("Tall content: panel must shrink to the viewport, never cover its trigger"),
        // fit_or_scroll: autosize tightens max_height to available height, excess scrolls
        // vertically within panel; content is ScrollArea child node, chrome is panel shell
        v.with(W.Popover(.{
            .position = .bottom_start,
            .trigger = .click,
            .size_policy = .fit_or_scroll,
            .max_width = 236,
            .max_height = 2000,
        }), v.col(.{ .style = PopS.tall }, .{
            v.text(pop_text_props, "Top of tall content"),
            // 1400px gradient block: fits no reasonable window height; gradient shows scroll
            // position
            storyGradientSlab(204, 1400),
            v.text(pop_text_props, "Bottom of tall content"),
        })).trigger(W.Button(.{ .label = "Tall Popover", .variant = .secondary })).parts(.{
            .trigger = "story.popover.tall.trigger",
            .chrome = "story.popover.tall.content",
            .content = "story.popover.tall.scroll_content",
        }),
    }));
}

// -- ZIndex (system z-layer validation) --
// Verifies the z-index manager's three contracts (e2e pixel assertions per contract):
//   A. Sibling z_index overrides DOM order (red z=3 earliest in DOM, still topmost)
//   B. Popover/tooltip inside an overflow_hidden container escapes it and covers rear
//      obstacles (obstacles contain a rotate 45 degree transform node, regression target
//      for the transform z-layer fix)
//   C. Nested inheritance: popover (overlay tier) inside modal (dialog tier) must
//      override dialog
const zx_red = ui.Color.rgba(220, 50, 47, 255);
const zx_green = ui.Color.rgba(64, 160, 70, 255);
const zx_blue = ui.Color.rgba(38, 90, 220, 255);
const zx_indigo = ui.Color.rgba(79, 70, 229, 255);
const zx_orange = ui.Color.rgba(255, 150, 40, 255);
const zx_yellow = ui.Color.rgba(250, 204, 21, 255);
const zx_teal = ui.Color.rgba(20, 150, 140, 255);

const ZxS = struct {
    fn arena(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 220 }, .height = .{ .px = 110 }, .position = .relative };
    }
    fn stage(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 420 }, .height = .{ .px = 150 }, .position = .relative };
    }
    fn clipbox(_: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .position = .absolute,
            .gap = 16,
            .width = .{ .px = 420 },
            .height = .{ .px = 64 },
            .padding = Padding.all(12),
            .background = ui.Color.rgba(229, 231, 235, 255),
            .overflow_hidden = true,
            .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } },
        };
    }
    fn obstacle(_: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .position = .absolute,
            .align_items = .center,
            .justify = .center,
            .width = .{ .px = 420 },
            .height = .{ .px = 100 },
            .background = zx_orange,
            // top=48 < clipbox height 64: overlaps with clipbox bottom edge
            .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 48 } },
        };
    }
    fn diamond(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 48 }, .height = .{ .px = 48 }, .background = zx_yellow, .rotate = std.math.pi / 4.0 };
    }
    fn colsRow(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 12, .align_items = .start };
    }
    fn deepCard(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 8, .padding = Padding.all(10), .background = ui.Color.rgba(243, 244, 246, 255), .corner_radius = 8 };
    }
    fn popBody(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 8, .padding = Padding.all(8) };
    }
};

const ZxSibling = struct { color: ui.Color, z: i16, off: f32 };
const zx_siblings = [_]ZxSibling{
    .{ .color = zx_red, .z = 3, .off = 0 }, // DOM first + z highest -> must be topmost
    .{ .color = zx_green, .z = 2, .off = 30 },
    .{ .color = zx_blue, .z = 1, .off = 60 },
};

const ZxBoxProps = struct { style: ui.BoxStyle };

fn zxSibling(s: ZxSibling) v.Box(ZxBoxProps, void, null) {
    return v.box(ZxBoxProps{ .style = .{
        .position = .absolute,
        .width = .{ .px = 130 },
        .height = .{ .px = 80 },
        .background = s.color,
        .z_index = s.z,
        .inset = .{ .left = .{ .px = s.off }, .top = .{ .px = s.off / 3 } },
    } }, {});
}

const ZxSlabProps = struct { style: ui.BoxStyle, test_id: []const u8 };

fn zxSlab(w: f32, h: f32, color: ui.Color, test_id: []const u8) v.Box(ZxSlabProps, void, null) {
    return v.box(ZxSlabProps{ .style = .{ .width = .{ .px = w }, .height = .{ .px = h }, .background = color }, .test_id = test_id }, {});
}

pub fn buildZIndex(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const vis = try scope.createSignal(bool, false);
    const vis2 = try scope.createSignal(bool, false);
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        // -- A. Sibling z_index sorting --
        label("Sibling z-index (DOM order reversed, z must win)"),
        v.box(.{ .style = ZxS.arena, .test_id = "story.zindex.siblings" }, v.list(&zx_siblings, zxSibling)),

        // -- B. overflow container + popover/tooltip + obstacles --
        // The stage uses absolute positioning to place obstacles above the clipbox bottom (top=48 <
        // clipbox height 64), ensuring short bubbles like tooltip (drawn from trigger bottom
        // + offset, ~24px high) still overlap obstacles; otherwise the assertion tests empty air.
        label("Overflow container: popover & tooltip must escape clip and cover the obstacle"),
        v.box(.{ .style = ZxS.stage }, .{
            v.row(.{ .style = ZxS.clipbox, .test_id = "story.zindex.clipbox" }, .{
                v.with(W.Popover(.{ .position = .bottom_start, .trigger = .click }), zxSlab(180, 90, zx_indigo, "story.zindex.pop.slab"))
                    .trigger(W.Button(.{ .label = "Pop", .variant = .secondary }))
                    .parts(.{ .trigger = "story.zindex.pop.trigger" }),
                v.with(W.Tooltip(.{ .text = "Tooltip above everything", .position = .bottom }), .{})
                    .trigger(W.Button(.{ .label = "Tip", .variant = .secondary }))
                    .parts(.{ .trigger = "story.zindex.tip.trigger", .content = "story.zindex.tip.content" }),
            }),
            // Obstacles: DOM after clipbox sibling (no z naturally paints above float layer),
            // absolute positioned top=48 overlapping clipbox bottom. Contains rotate 45 degree
            // transform node, regression target for transform z-layer penetration.
            v.row(.{ .style = ZxS.obstacle, .test_id = "story.zindex.obstacle" }, v.box(.{ .style = ZxS.diamond, .test_id = "story.zindex.diamond" }, {})),
        }),

        // C. complex layout + triple-nest: modal(dialog) -> body complex col-layout with tooltip +
        //    popover(inherits over dialog) -> popover opens second modal (over popover). tier chain
        //    full verify: dialog 1000 < inherit popover < second dialog < tooltip 3000.
        v.attrs(.{ .test_id = "story.zindex.modal.open" }, W.Button(.{ .label = "Open Nested Modal", .on_click = ui.on.set(vis, true) })),
        v.with(W.Modal(.{ .title = "Nested tiers", .width = 440, .open = vis }), .{
            v.text(pop_text_props, "Popover from inside a modal must stack above the dialog."),
            // Complex layout: two-column nested cards, each internally nested column, float
            // triggers buried in deep hierarchy, verify z inheritance independent of "trigger is
            // dialog body direct child".
            v.row(.{ .style = ZxS.colsRow }, .{
                v.col(.{ .style = ZxS.deepCard }, .{
                    label("Deep column A"),
                    // Column A: tooltip inside modal (tooltip tier always top)
                    v.col(.{ .style = S.stack(8) }, v.with(W.Tooltip(.{ .text = "Tooltip inside modal", .position = .bottom }), .{})
                        .trigger(W.Button(.{ .label = "Tip in modal", .variant = .secondary }))
                        .parts(.{ .trigger = "story.zindex.modal.tip.trigger", .content = "story.zindex.modal.tip.content" })),
                }),
                v.col(.{ .style = ZxS.deepCard }, .{
                    label("Deep column B"),
                    // Column B: popover inside modal, second modal opened from popover content
                    v.col(.{ .style = S.stack(8) }, v.with(W.Popover(.{ .position = .bottom_start, .trigger = .click }), v.col(.{ .style = ZxS.popBody }, .{
                        zxSlab(160, 70, zx_indigo, "story.zindex.modal.pop.slab"),
                        v.attrs(.{ .test_id = "story.zindex.modal2.open" }, W.Button(.{ .label = "Open Modal 2", .on_click = ui.on.set(vis2, true) })),
                    })).trigger(W.Button(.{ .label = "Pop in modal", .variant = .secondary }))
                        .parts(.{ .trigger = "story.zindex.modal.pop.trigger" })),
                }),
            }),
        }).parts(.{ .dialog = "story.zindex.modal.dialog" }),
        // Second modal: opened from popover content, must override popover (dialog tier
        // sequence increments + trigger nesting inheritance double-ensures). Mount order
        // unchanged from prior version: first modal and its popover mount before second
        // modal.
        v.with(W.Modal(.{ .title = "Second modal", .width = 300, .open = vis2 }), zxSlab(200, 80, zx_teal, "story.zindex.modal2.slab"))
            .parts(.{ .dialog = "story.zindex.modal2.dialog" }),
    }));
}

// ── Markdown ──
pub fn buildMarkdown(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const md =
        \\# Markdown
        \\
        \\Supports **bold**, *italic*, and `inline code`.
        \\
        \\- bullet one
        \\- bullet two
        \\
        \\1. first step
        \\2. second step
        \\
        \\> A blockquote line.
        \\
        \\```
        \\const ui = @import("zenit").ui;
        \\```
        \\
        \\---
        \\
        \\Read the [guide](https://example.com/guide).
    ;
    return v.render(scope, cx, v.box(.{ .style = demoWidth(420) }, .{W.Markdown(.{ .text = md, .options = .{ .base_font_size = 13 } })}));
}

// ── Input ──
const InputEl = @TypeOf(W.Input(.{}));
const InputSizeSpec = struct { size: W.input.InputSize, placeholder: []const u8 };
const input_sizes = [_]InputSizeSpec{
    .{ .size = .sm, .placeholder = "Small" },
    .{ .size = .md, .placeholder = "Medium" },
    .{ .size = .lg, .placeholder = "Large" },
};

fn sizedInput(spec: InputSizeSpec) InputEl {
    return W.Input(.{ .size = spec.size, .placeholder = spec.placeholder, .width = 320 });
}

pub fn buildInput(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const icons = ui.assets.common;
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        // -- Types --
        label("Types"),
        v.attrs(.{ .test_id = "story.input.name", .parts = .{ .input_container = "story.input.name.input" } }, W.Input(.{ .label_text = "Name", .placeholder = "Your name", .width = 320 })),
        v.attrs(.{ .test_id = "story.input.email" }, W.Input(.{ .label_text = "Email", .input_type = .email, .placeholder = "you@example.com", .width = 320 })),
        W.Input(.{ .label_text = "Password", .input_type = .password, .placeholder = "••••••••", .width = 320 }),

        // -- Sizes --
        label("Sizes (sm / md / lg)"),
        v.list(&input_sizes, sizedInput),

        // -- With icon / append --
        label("With icon / append"),
        W.Input(.{ .label_text = "Search", .placeholder = "Type to search…", .leading_icon_asset = icons.search, .width = 320 }),
        W.Input(.{ .label_text = "Website", .placeholder = "mysite", .append_text = ".com", .width = 320 }),

        // -- State: required / helper / error / readonly / disabled --
        label("States"),
        W.Input(.{ .label_text = "Required", .placeholder = "Mandatory", .required = true, .width = 320 }),
        W.Input(.{ .label_text = "With helper", .placeholder = "Username", .helper = "3–20 characters", .width = 320 }),
        v.attrs(.{ .test_id = "story.input.readonly" }, W.Input(.{ .label_text = "Readonly", .value = "Read only value", .readonly = true, .width = 320 })),
        W.Input(.{ .label_text = "Disabled", .placeholder = "Cannot type", .disabled = true, .width = 320 }),
        // Last on purpose: below the fold in the 1000pt test window, so the UIA Value
        // suite can prove SetValue reaches an Input that has not been painted yet.
        v.attrs(.{ .test_id = "story.input.error" }, W.Input(.{ .label_text = "With error", .value = "bad value", .error_msg = "This field is invalid", .width = 320 })),
    }));
}

// ── Textarea ──
pub fn buildTextarea(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.attrs(.{ .test_id = "story.textarea.box" }, W.Textarea(.{ .label_text = "Notes", .placeholder = "Write something…", .rows = 5, .width = 420 })),
        W.Textarea(.{ .label_text = "With helper", .placeholder = "Bio", .helper = "Max 500 characters", .rows = 3, .width = 420 }),
        W.Textarea(.{ .label_text = "With error", .value = "too short", .error_msg = "Please write more", .rows = 3, .width = 420 }),
        W.Textarea(.{ .label_text = "Disabled", .placeholder = "Cannot edit", .disabled = true, .rows = 3, .width = 420 }),
        label("Field sizes / minimum two rows"),
        W.Textarea(.{ .size = .xs, .placeholder = "XS / 44px", .rows = 2, .width = 320 }),
        W.Textarea(.{ .size = .sm, .placeholder = "SM / 52px", .rows = 2, .width = 320 }),
        W.Textarea(.{ .size = .md, .placeholder = "MD / 72px", .rows = 2, .width = 320 }),
        W.Textarea(.{ .size = .lg, .placeholder = "LG / 88px", .rows = 2, .width = 320 }),
    }));
}

// ── VirtualList ──
const ListRowS = struct {
    fn text(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_primary };
    }
    /// Dynamic rows: padding originally on pool node, now borne by row root (pool node
    /// measures by content, geometry unchanged)
    fn dynRow(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .grow = .{} }, .padding = ui.Padding.all(8) };
    }
    fn dynText(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_primary, .wrap = .word_break };
    }
};

fn vlRow(idx: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.text(.{ .style = ListRowS.text }, v.fmt("Row {d}", .{idx})));
}
/// Text for assistive tech for offscreen (unrendered) rows matches rendered vlRow
/// content.
fn vlLabel(idx: usize, buf: []u8, _: ?*anyopaque) []const u8 {
    return std.fmt.bufPrint(buf, "Row {d}", .{idx}) catch "";
}
pub fn buildVirtualList(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, W.VirtualList(.{
        .item_count = 1000,
        .item_height = 28,
        .width = 320,
        .height = 360,
        .item_label_fn = vlLabel,
    }).rows({}, vlRow));
}

// -- VirtualList (dynamic variable height) --
// Each row text length differs + auto wrapping -> row height unknowable beforehand,
// only measurable. This is why measure_items exists: pre-occupy by estimate, measure
// true height after layout, compensate scroll position.
const vl_dyn_words = [_][]const u8{
    "短",
    "这是一条中等长度的说明文字，占两行左右。",
    "很短",
    "这一条明显更长：动态高度虚拟列表要处理的核心难题在于，行高只有等到内容真正参与布局之后才知道，而虚拟滚动又要求在渲染之前就知道每一行的位置。解法是先用估算值占位，量到真实高度后回填账本，并且补偿滚动位置，让用户正在看的内容不会跳动。",
    "中等：换行会让这一行变高。",
    "一行",
};
fn vlDynRow(idx: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.box(.{ .style = ListRowS.dynRow }, .{
        v.text(.{ .style = ListRowS.dynText }, v.fmt("#{d}  {s}", .{ idx, vl_dyn_words[idx % vl_dyn_words.len] })),
    }));
}
fn vlDynLabel(idx: usize, buf: []u8, _: ?*anyopaque) []const u8 {
    return std.fmt.bufPrint(buf, "#{d}  {s}", .{ idx, vl_dyn_words[idx % vl_dyn_words.len] }) catch "";
}
pub fn buildVirtualListDynamic(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, W.VirtualList(.{
        .item_count = 2000,
        .measure_items = true,
        .estimate_item_height = 44,
        .width = 320,
        .height = 360,
        .item_label_fn = vlDynLabel,
    }).rows({}, vlDynRow));
}

// ── ScrollArea ──
const scroll_lines = blk: {
    var lines: [40][]const u8 = undefined;
    for (&lines, 0..) |*line, i| line.* = std.fmt.comptimePrint("Scrollable line {d}", .{i});
    break :blk lines;
};
const scroll_line_props = .{ .style = ListRowS.text };

fn scrollLine(txt: []const u8) v.Text(@TypeOf(scroll_line_props), []const u8) {
    return v.text(scroll_line_props, txt);
}

pub fn buildScrollArea(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.with(W.ScrollArea(.{ .width = 320, .height = 320, .direction = .vertical }), v.list(&scroll_lines, scrollLine)));
}

// ── Grid ──
const GridS = struct {
    fn cell(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 12, .color = t.tokens.color.fg_secondary };
    }
};
const grid_cell_props = .{ .style = GridS.cell };

fn gridCell(r: usize, col_: usize) v.Text(@TypeOf(grid_cell_props), v.Fmt("{d},{d}", struct { usize, usize })) {
    return v.text(grid_cell_props, v.fmt("{d},{d}", .{ r, col_ }));
}
const grid_widths = [_]f32{ 90, 90, 90, 90 };
pub fn buildGrid(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        label("Grid: 52px cells / 8px gap"),
        v.col(.{ .style = S.stack(8) }, .{
            v.row(.{ .style = S.line(8) }, .{ v.box(.{ .style = LayoutPreviewS.cell }, {}), v.box(.{ .style = LayoutPreviewS.cell }, {}), v.box(.{ .style = LayoutPreviewS.cell }, {}) }),
            v.row(.{ .style = S.line(8) }, .{ v.box(.{ .style = LayoutPreviewS.cell }, {}), v.box(.{ .style = LayoutPreviewS.cell }, {}), v.box(.{ .style = LayoutPreviewS.cell }, {}) }),
        }),
        label("Virtualized data grid"),
        W.Grid(.{
            .col_count = 4,
            .row_count = 12,
            .col_widths = &grid_widths,
            .cell_height = 30,
            .width = 380,
            .height = 320,
        }).cells({}, gridCell),
    }));
}

// ── Select · Pencil puQEf component family ──
pub fn buildSelect(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return select_puqef.build(scope, cx);
}

// ── NumberStepper ──
fn storyLabelNode(cx: *ui.Cx, text: []const u8) !*ui.Node {
    return ui.text(cx, text, .{ .font_size = 12, .color = light.tokens.color.fg_secondary });
}

// ── Group ──
// Attached controls: Group zeroes the inner corners and overlaps the shared borders, so a row of
// buttons (or an input with its action) reads as one control.
fn groupRow(scope: *ui.Scope, cx: *ui.Cx, orientation: W.group.GroupOrientation, labels: []const []const u8, comptime prefix: []const u8) !*ui.Node {
    const a = cx.allocator;
    const g = try W.Group(.{ .orientation = orientation }).mount(scope, cx);
    for (labels, 0..) |l, i| {
        const b = try W.Button(.{ .label = l, .variant = .secondary }).mount(scope, cx);
        if (i == 0) b.meta.ownership.meta.test_id = prefix ++ ".first";
        const pos: W.group.GroupItemPosition = if (labels.len == 1) .only else if (i == 0) .first else if (i == labels.len - 1) .last else .between;
        try W.addGroupItem(g.container, a, b, pos, cx.tokens.tokens.radius.control);
    }
    return g.container;
}

pub fn buildGroup(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 12);
    try c.appendChild(a, try storyLabelNode(cx, "Horizontal button group"));
    const h = try groupRow(scope, cx, .horizontal, &.{ "Day", "Week", "Month", "Year" }, "story.group.h");
    h.meta.ownership.meta.test_id = "story.group.h";
    try c.appendChild(a, h);
    try c.appendChild(a, try storyLabelNode(cx, "Input with an attached action"));
    const g = try W.Group(.{}).mount(scope, cx);
    g.container.meta.ownership.meta.test_id = "story.group.input";
    const input = try W.Input(.{ .value = "zenit.dev/docs", .width = 220, .leading_icon_asset = ui.assets.common.link }).mountResult(scope, cx);
    try W.addGroupItem(g.container, a, input.node, .first, cx.tokens.tokens.radius.control);
    const copy = try W.Button(.{ .label = "Copy", .variant = .secondary }).mount(scope, cx);
    try W.addGroupItem(g.container, a, copy, .last, cx.tokens.tokens.radius.control);
    try c.appendChild(a, g.container);
    try c.appendChild(a, try storyLabelNode(cx, "Vertical"));
    try c.appendChild(a, try groupRow(scope, cx, .vertical, &.{ "Top", "Middle", "Bottom" }, "story.group.v"));
    return c;
}

// ── EditableText ──
// The Input editing engine without the control shell: no border, background, focus ring or
// padding, so a heading or a cell edits in place and looks like plain text at rest.
pub fn buildEditableText(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = try scope.createText("Quarterly roadmap", .{});
    const note = try scope.createText("Click any line to edit it in place; the text reflows as you type.", .{});
    return v.render(scope, cx, v.col(.{ .style = demoWidth(420) }, .{
        v.attrs(.{ .test_id = "story.editabletext.title" }, W.EditableText(.{ .value = title, .font_size = 20, .font_weight = 600, .width = 420, .activation = .click, .field_chrome = true })),
        v.attrs(.{ .test_id = "story.editabletext.note" }, W.EditableText(.{ .value = note, .font_size = 13, .wrap_width = 420, .activation = .click, .field_chrome = true })),
        v.text(.{ .style = S.storyLabel, .test_id = "story.editabletext.status" }, v.fmt("title → {s}", .{title})),
    }));
}

pub fn buildNumberStepper(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        label("0–10, step 1"),
        v.attrs(.{ .test_id = "story.stepper.basic", .parts = .{ .increment_button = "story.stepper.increase", .decrement_button = "story.stepper.decrease" } }, W.NumberStepper(.{ .value = 5, .min = 0, .max = 10 })),
        label("step 0.25, clamped to 0–1"),
        W.NumberStepper(.{ .value = 0.25, .step = 0.25, .min = 0, .max = 1, .width = 160 }),
        label("At the maximum"),
        W.NumberStepper(.{ .value = 10, .min = 0, .max = 10 }),
        label("Disabled"),
        W.NumberStepper(.{ .value = 3, .disabled = true }),
    }));
}

// ── TagsInput ──
pub fn buildTagsInput(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.attrs(.{ .test_id = "story.tags.wrapper", .parts = .{ .input = "story.tags.input", .add_button = "story.tags.add" } }, W.TagsInput(.{
            .tags = &[_][]const u8{ "Zig", "UI" },
            .width = 360,
            .placeholder = "Add tag…",
        })),
        label("Return or a trailing comma commits a tag."),
    }));
}

// ── FileUpload ──
const FileUploadStory = struct {
    upload: W.FileUploadResult,
    n: u32 = 0,
    buf: [64]u8 = undefined,
    fn browse(self: *FileUploadStory) void {
        // Override native NSOpenPanel (runModal blocks e2e harness): story demonstrates
        // programmatic refill; when on_browse omitted, component uses cx.openFilePanel
        self.n += 1;
        const path = std.fmt.bufPrint(&self.buf, "/tmp/demo-file-{d}.txt", .{self.n}) catch return;
        self.upload.add(path);
    }
};

/// Browse refill must call Result `add`: v.ref stores mount result in story state.
pub fn buildFileUpload(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const story = try scope.createState(FileUploadStory, .{ .upload = undefined });
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        // Drag drop zone: e2e uses dragAt to inject entered/dropped into this rectangle
        v.attrs(.{ .test_id = "story.upload.wrapper", .parts = .{ .drop_zone = "story.upload.dropzone", .browse_button = "story.upload.choose" } }, v.capture(&story.upload, W.FileUpload(.{
            .width = 320,
            .hint = "Attachment",
            .files = &[_][]const u8{"/tmp/design-system.pdf"},
            .on_browse = ui.on.call(story, FileUploadStory.browse),
        }))),
    }));
}

// -- DataTable (filtering / paging / column width adjustment) --
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
    return v.render(scope, cx, v.attrs(.{
        .test_id = "story.datatable.table",
        .parts = .{ .filter_input = "story.datatable.filter" },
    }, W.DataTable(.{
        .columns = &DT_COLS,
        .rows = &DT_ROWS,
        .page_size = 3,
    })));
}

// ── ComboBox / Autocomplete ──
const combo_options = [_]W.ComboOption{
    .{ .value = "ap", .label = "Apple" },
    .{ .value = "ba", .label = "Banana" },
    .{ .value = "ch", .label = "Cherry" },
    .{ .value = "gr", .label = "Grape" },
    .{ .value = "ma", .label = "Mango" },
    .{ .value = "ki", .label = "Kiwi", .disabled = true },
};
fn comboStatusText(value: ?[]const u8) []const u8 {
    return value orelse "(none)";
}
pub fn buildComboBox(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const selected = try scope.createSignal(?[]const u8, null);
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.text(.{ .style = S.storyLabel, .test_id = "story.combobox.status" }, v.fmt("{s}", .{ui.map(selected, comboStatusText)})),
        v.attrs(.{ .parts = .{ .input = "story.combobox.input", .panel = "story.combobox.panel" } }, W.ComboBox(.{
            .options = &combo_options,
            .label_text = "Fruit",
            .placeholder = "Type to search fruit",
            .width = 260,
            .on_change = ui.on.assignAs(?[]const u8, selected),
        })),
        label("Open / selected / unavailable"),
        W.ComboBox(.{ .options = &combo_options, .value = "ba", .open = true, .width = 260 }),
    }));
}

// ── Form ──
const DemoForm = struct {
    name: []const u8 = "",
    email: []const u8 = "",

    pub const rules = .{
        .name = struct {
            fn validate(val: []const u8) W.form.ValidationResult {
                if (std.mem.trim(u8, val, " ").len == 0) return .{ .valid = false, .message = "Name is required" };
                return .{ .valid = true };
            }
        }.validate,
        .email = struct {
            fn validate(val: []const u8) W.form.ValidationResult {
                if (val.len == 0) return .{ .valid = false, .message = "Email is required" };
                if (std.mem.indexOfScalar(u8, val, '@') == null) return .{ .valid = false, .message = "Enter a valid email address" };
                return .{ .valid = true };
            }
        }.validate,
    };
};

const DemoFormStory = struct {
    status: *ui.Signal([]const u8),
    /// on_submit runs only after every rule passes; the values are valid during the call
    fn submitted(self: *DemoFormStory, values: DemoForm) void {
        var buf: [160]u8 = undefined;
        self.status.set(std.fmt.bufPrint(&buf, "submitted → {s} <{s}>", .{ values.name, values.email }) catch "submitted");
    }
};

pub fn buildForm(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const F = W.FormOf(DemoForm);
    const Field = W.FormFieldOf(DemoForm);
    const story = try scope.createState(DemoFormStory, .{ .status = try scope.createText("(not submitted)", .{}) });
    // FormOf owns the values and validation state; rules run on blur and on Submit
    const form = try F.create(scope, .{}, .{ .trigger = .on_blur, .on_submit = ui.on.call(story, DemoFormStory.submitted) });
    const c = try col(cx, 12);
    const name = try Field.inputField(.name, .{ .label_text = "Name", .required = true, .width = 320 }, .{ .placeholder = "Full name", .width = 320 }, form, scope, cx);
    name.meta.ownership.meta.test_id = "story.form.name";
    try c.appendChild(a, name);
    const email = try Field.inputField(.email, .{ .label_text = "Email", .required = true, .helper = "We never share it.", .width = 320 }, .{ .input_type = .email, .placeholder = "you@example.com", .width = 320 }, form, scope, cx);
    email.meta.ownership.meta.test_id = "story.form.email";
    try c.appendChild(a, email);
    const submit = try W.Button(.{ .label = "Submit", .variant = .primary, .on_click = form.submitHandler() }).mount(scope, cx);
    submit.meta.ownership.meta.test_id = "story.form.submit";
    try c.appendChild(a, submit);
    const status = try ui.textFmt(cx, scope, "{s}", .{story.status}, .{ .font_size = 12, .color = light.tokens.color.fg_secondary });
    status.meta.ownership.meta.test_id = "story.form.status";
    try c.appendChild(a, status);
    return c;
}

// -- Icon gallery --
// Show provider-neutral system icon subset. Full Lucide/Untitled catalog names
// differ, should not let Storybook or framework components depend on vendor naming.
const GalleryIcon = struct { asset: ui.system_icons.Asset, name: []const u8 };
const GALLERY_ICONS = [_]GalleryIcon{
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

const GalleryS = struct {
    fn cell(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 6, .align_items = .center, .justify = .center, .width = .{ .px = 72 }, .height = .{ .px = 72 }, .corner_radius = 4 };
    }
    fn hover(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .background = t.tokens.color.bg_hover };
    }
    fn icon(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } };
    }
    fn iconTint(t: *const ui.theme.Values) ui.Color {
        return t.tokens.color.fg_primary;
    }
    fn name(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = t.tokens.font_size.xs, .color = t.tokens.color.fg_tertiary };
    }
    fn dangerTint(t: *const ui.theme.Values) ui.Color {
        return t.tokens.color.danger;
    }
    fn demoTint(t: *const ui.theme.Values) ui.Color {
        return t.tokens.color.fg_secondary;
    }
    fn sized(comptime px: f32) fn (*const ui.theme.Values) ui.BoxStyle {
        return struct {
            fn f(_: *const ui.theme.Values) ui.BoxStyle {
                return .{ .width = .{ .px = px }, .height = .{ .px = px } };
            }
        }.f;
    }
};

const gallery_cell_props = .{ .style = .{ GalleryS.cell, v.hover(GalleryS.hover) } };
const gallery_icon_props = .{ .style = GalleryS.icon, .tint = GalleryS.iconTint };
const gallery_name_props = .{ .style = GalleryS.name };
const GalleryCellKids = @Tuple(&.{ v.Icon(@TypeOf(gallery_icon_props)), v.Text(@TypeOf(gallery_name_props), []const u8) });
const gallery_row_props = .{ .style = S.line(0) };

fn galleryCell(spec: GalleryIcon) v.Box(@TypeOf(gallery_cell_props), GalleryCellKids, .column) {
    return v.col(gallery_cell_props, GalleryCellKids{
        v.icon(gallery_icon_props, spec.asset),
        v.text(gallery_name_props, spec.name),
    });
}

pub fn buildIconGallery(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const icons = &GALLERY_ICONS;
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        // YZt6y: 20px glyphs in 72px cells, ten per row.
        v.row(gallery_row_props, v.list(icons[0..10], galleryCell)),
        v.row(gallery_row_props, v.list(icons[10..20], galleryCell)),

        // Size + tint demo row
        label("Sizes & tints"),
        v.row(.{ .style = S.line(16) }, .{
            v.icon(.{ .style = GalleryS.sized(12), .tint = GalleryS.demoTint }, ui.system_icons.alert),
            v.icon(.{ .style = GalleryS.sized(16), .tint = GalleryS.demoTint }, ui.system_icons.alert),
            v.icon(.{ .style = GalleryS.sized(20), .tint = GalleryS.demoTint }, ui.system_icons.alert),
            v.icon(.{ .style = GalleryS.sized(28), .tint = GalleryS.demoTint }, ui.system_icons.alert),
            v.icon(.{ .style = GalleryS.sized(32), .tint = GalleryS.dangerTint }, ui.system_icons.heart),
        }),
    }));
}

// -- VectorPath (fill_path pipeline: multiple adjacent path nodes, validate encoder
// batching) --
/// 10-point star path (pure polyline <= 32 points -> encoder converts to polygon_fill
/// mode)
fn setStarGeometry(size: f32, node: *ui.Node, _: *ui.Scope, cx: *ui.Cx) !void {
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
    try node.setPathHitGeometry(cx.allocator, &commands, .nonzero);
}

/// 20-point burst (40 vertices > polygon 32-point budget -> force earclip triangles
/// mode)
fn setBurstGeometry(size: f32, node: *ui.Node, _: *ui.Scope, cx: *ui.Cx) !void {
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
    try node.setPathHitGeometry(cx.allocator, &commands, .nonzero);
}

/// Path geometry is node-level API (setPathHitGeometry), post-attach use v.setup to
/// set.
const PathTileProps = struct { style: ui.BoxStyle };
const PathTile = v.Box(PathTileProps, void, null);

fn pathTileStyle(color: ui.Color) ui.BoxStyle {
    return .{ .width = .{ .px = 64 }, .height = .{ .px = 64 }, .background = color };
}
fn starTile(color: ui.Color) v.Setup(PathTile, f32, setStarGeometry) {
    return v.setup(v.box(PathTileProps{ .style = pathTileStyle(color) }, {}), @as(f32, 64), setStarGeometry);
}
fn burstTile(color: ui.Color) v.Setup(PathTile, f32, setBurstGeometry) {
    return v.setup(v.box(PathTileProps{ .style = pathTileStyle(color) }, {}), @as(f32, 64), setBurstGeometry);
}

const star_colors = [_]ui.Color{
    ui.Color.rgb(235, 87, 87),
    ui.Color.rgb(242, 153, 74),
    ui.Color.rgb(39, 174, 96),
    ui.Color.rgb(45, 156, 219),
};
const burst_colors = [_]ui.Color{
    ui.Color.rgb(155, 81, 224),
    ui.Color.rgb(47, 128, 237),
    ui.Color.rgb(33, 150, 83),
};

pub fn buildVectorPath(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        // Multiple adjacent path nodes: encoder should merge into fewer draws (polygon group
        // + triangles group)
        v.row(.{ .style = S.line(12) }, v.list(&star_colors, starTile)),
        label("Bursts 40-pt (earclip triangles mode)"),
        v.row(.{ .style = S.line(12) }, v.list(&burst_colors, burstTile)),
    }));
}

// -- Blend Modes (W3C mix-blend: non-normal uses blend composite pipeline) --
//
// Colors intentionally use only 0/255 components: the sRGB transfer function is unchanged at
// 0.0/1.0, so mixing in linear space and sRGB space yields identical results and e2e can
// assert exact RGB values, independent of the "shader mixes in linear space" detail.
//   multiply:   yellow(255,255,0) x cyan(0,255,255)  = green(0,255,0)
//   screen:     red(255,0,0)    union blue(0,0,255)      = magenta(255,0,255)
//   difference: |white(255,255,255) - red(255,0,0)|  = cyan(0,255,255)
const BlendCase = struct {
    name: []const u8,
    test_id: []const u8,
    bg: ui.Color,
    src: ui.Color,
    mode: ui.BlendMode,
};
const blend_cases = [_]BlendCase{
    .{ .name = "multiply: yellow x cyan = green", .test_id = "story.blend.multiply", .bg = ui.Color.rgb(255, 255, 0), .src = ui.Color.rgb(0, 255, 255), .mode = .multiply },
    .{ .name = "screen: red + blue = magenta", .test_id = "story.blend.screen", .bg = ui.Color.rgb(255, 0, 0), .src = ui.Color.rgb(0, 0, 255), .mode = .screen },
    .{ .name = "difference: white - red = cyan", .test_id = "story.blend.difference", .bg = ui.Color.rgb(255, 255, 255), .src = ui.Color.rgb(255, 0, 0), .mode = .difference },
};

const BlendS = struct {
    fn outer(color: ui.Color) ui.BoxStyle {
        return .{ .width = .{ .px = 120 }, .height = .{ .px = 120 }, .background = color, .padding = Padding.all(20) };
    }
    fn inner(color: ui.Color) ui.BoxStyle {
        return .{ .width = .{ .px = 80 }, .height = .{ .px = 80 }, .background = color };
    }
    fn mode(m: ui.BlendMode) ui.BoxStyle {
        return .{ .blend_mode = m };
    }
};

fn blendTileView(case: BlendCase, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(6) }, .{
        label(case.name),
        v.box(.{ .style = BlendS.outer(case.bg) }, .{
            v.box(.{ .style = .{ BlendS.inner(case.src), BlendS.mode(case.mode) }, .test_id = case.test_id }, {}),
        }),
    }));
}
fn blendTile(case: BlendCase) v.ComponentOf(blendTileView) {
    return v.component(blendTileView, case);
}

pub fn buildBlend(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const yellow = ui.Color.rgb(255, 255, 0);
    const cyan = ui.Color.rgb(0, 255, 255);
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        v.row(.{ .style = S.line(16) }, v.list(&blend_cases, blendTile)),

        // normal control: same cyan-on-yellow but no blend, e2e asserts it still cyan,
        // proves blend path didn't alter normal compositing.
        label("normal control (should stay cyan)"),
        v.box(.{ .style = BlendS.outer(yellow) }, .{
            v.box(.{ .style = BlendS.inner(cyan), .test_id = "story.blend.control" }, {}),
        }),
    }));
}

// -- Emoji (color glyph pipeline: BGRA atlas page + shader color branch) --
//
// Validated via pixels, not text: the grayscale glyph pipeline can still render the emoji
// **shape** (coverage mask) and just loses color. So e2e samples the center pixel and asserts
// R/G/B channels are unequal; grayscale has equal channels, so unequal channels can only come
// from true color sampling.
//
// Each emoji is a single test_id node with a deliberately large solid-filled center region:
//   U+1F7E5 red square  U+1F7E9 green square  U+1F7E6 blue square
// Square emoji centers are uniformly colored, unaffected by font size / antialiasing /
// center point offset: the most stable pixel target. Text color is intentionally neutral gray;
// if the shader wrongly multiplies emoji by text color the result degrades to grayscale
// (equal channels) and the test fails immediately.
const EmojiCase = struct { name: []const u8, test_id: []const u8, glyph: []const u8 };
const emoji_cases = [_]EmojiCase{
    .{ .name = "red square", .test_id = "story.emoji.red", .glyph = "\u{1F7E5}" },
    .{ .name = "green square", .test_id = "story.emoji.green", .glyph = "\u{1F7E9}" },
    .{ .name = "blue square", .test_id = "story.emoji.blue", .glyph = "\u{1F7E6}" },
};

const EmojiS = struct {
    /// Neutral gray text color: emoji if wrongly multiplied by it degrades to grayscale.
    fn gray64(_: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 64, .color = ui.Color.rgb(128, 128, 128) };
    }
    fn mixed(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 28, .color = t.tokens.color.fg_primary };
    }
};

fn emojiTileView(case: EmojiCase, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(6) }, .{
        label(case.name),
        v.text(.{ .style = EmojiS.gray64, .test_id = case.test_id }, case.glyph),
    }));
}
fn emojiTile(case: EmojiCase) v.ComponentOf(emojiTileView) {
    return v.component(emojiTileView, case);
}

pub fn buildEmoji(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(16) }, .{
        v.row(.{ .style = S.line(24) }, v.list(&emoji_cases, emojiTile)),

        // grapheme clusters: ZWJ family, skin-tone modifier, flag (regional indicators), keycap
        label("ZWJ sequence · skin tone · flag · keycap"),
        v.text(.{ .style = EmojiS.mixed, .test_id = "story.emoji.clusters" }, "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}  \u{1F44D}\u{1F3FD}  \u{1F1EF}\u{1F1F5}  3\u{FE0F}\u{20E3}"),

        // Control: same neutral gray color on regular text, must still be grayscale (equal
        // channels). Proves color branch didn't break grayscale path.
        label("grayscale control (must stay gray)"),
        v.text(.{ .style = EmojiS.gray64, .test_id = "story.emoji.control" }, "AAAA"),

        // Mixed: emoji and text same segment, verify shaping/fallback and color branching
        // coexist in one line.
        label("mixed run"),
        v.text(.{ .style = EmojiS.mixed, .test_id = "story.emoji.mixed" }, "Hello \u{1F600} world \u{1F30D}"),
    }));
}

// -- RTL (Arabic / Hebrew bidirectional text) --
//
// Validated via pixels, not text: a text node whose glyphs are **backwards-overlapped** still
// has a normal query string and node rect; only pixels distinguish right from wrong.
//
// Criterion is **ink horizontal distribution**: correct render lays N glyphs out sequentially
// along the pen and ink covers most of the node width; if RTL is wrongly reverse-positioned,
// glyphs pile up overlapping and ink covers a narrow span. e2e asserts a lower bound on the
// "ink column span ratio", so overlap collapses the span and fails the test.
//
// Beyond pure RTL, covers digits, neutral/mirror punctuation, combining marks,
// URL/email, continuous direction switches. The last narrow Textarea deliberately triggers
// soft wrap, giving e2e real validation that caret, selection rect and pointer hit-test
// use the same visual coordinates.
const RtlS = struct {
    fn matrix(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .gap = 28, .align_items = .start };
    }
    fn ink(comptime size: f32) fn (*const ui.theme.Values) ui.TextStyle {
        return struct {
            fn f(_: *const ui.theme.Values) ui.TextStyle {
                return .{ .font_size = size, .color = ui.Color.rgb(0, 0, 0) };
            }
        }.f;
    }
};

pub fn buildRtl(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const editor_text =
        "\u{645}\u{631}\u{62D}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645} abc 123 xyz \u{5E9}\u{5DC}\u{5D5}\u{5DD} " ++
        "https://example.com/a-b?q=1:2 test@example.com +12/34 - 56:78 / " ++
        "abc \u{645}\u{64E}\u{631}\u{652}\u{62D}\u{64E}\u{628}\u{64B}\u{627} xyz \u{5E9}\u{5DC}\u{5D5}\u{5DD} 123 \u{646}\u{647}\u{627}\u{64A}\u{629} \u{627}\u{644}\u{633}\u{637}\u{631}";
    return v.render(scope, cx, v.col(.{ .style = S.stack(10) }, .{
        v.row(.{ .style = RtlS.matrix }, .{
            v.col(.{ .style = .{ S.stack(6), S.fixedWidth(350) } }, .{
                label("plain shaping controls"),
                // Pure RTL: Arabic "marhaba" 5 characters, still laid out as one line post-
                // connection.
                v.text(.{ .style = RtlS.ink(36), .test_id = "story.rtl.arabic" }, "\u{645}\u{631}\u{62D}\u{628}\u{627}"),
                // Pure RTL: Hebrew "shalom" 4 characters, no connection, glyph spacing clear.
                v.text(.{ .style = RtlS.ink(36), .test_id = "story.rtl.hebrew" }, "\u{5E9}\u{5DC}\u{5D5}\u{5DD}"),
                // Control: equal-length LTR text. Proves "ink span" criterion itself holds in
                // verified-correct case (else lower-bound assertion might pass by luck).
                v.text(.{ .style = RtlS.ink(36), .test_id = "story.rtl.ltr_control" }, "abcde"),
                label("numbers + RTL / repeated direction switches"),
                v.text(.{ .style = RtlS.ink(24), .test_id = "story.rtl.numbers" }, "abc \u{645}\u{631}\u{62D}\u{628}\u{627} 123 xyz"),
                // Latin -> Arabic -> Latin -> Hebrew -> digits, continuous multi-bidi-run crossing.
                v.text(.{ .style = RtlS.ink(36), .test_id = "story.rtl.mixed" }, "ab\u{645}\u{631}\u{62D}\u{628}\u{627}cd"),
                v.text(.{ .style = RtlS.ink(24), .test_id = "story.rtl.switches" }, "abc \u{645}\u{631}\u{62D}\u{628}\u{627} xyz \u{5E9}\u{5DC}\u{5D5}\u{5DD} 123"),
            }),
            v.col(.{ .style = .{ S.stack(6), S.fixedWidth(390) } }, .{
                // Paired-bracket resolution (UAX #9 N0) and mirrored punctuation.
                label("mirrored punctuation: parentheses / brackets"),
                v.text(.{ .style = RtlS.ink(24), .test_id = "story.rtl.mirrored_parens" }, "\u{645}\u{631}\u{62D}\u{628}\u{627} (abc) \u{5E9}\u{5DC}\u{5D5}\u{5DD}"),
                v.text(.{ .style = RtlS.ink(24), .test_id = "story.rtl.mirrored_brackets" }, "\u{645}\u{631}\u{62D}\u{628}\u{627} [abc] \u{5E9}\u{5DC}\u{5D5}\u{5DD}"),
                // Tashkeel is combining marks: with/without diacritics should maintain same advance
                // width for base character group, ink must include upper/lower diacritics.
                label("Arabic tashkeel / combining marks"),
                v.text(.{ .style = RtlS.ink(30), .test_id = "story.rtl.tashkeel_base" }, "\u{645}\u{631}\u{62D}\u{628}\u{627}"),
                v.text(.{ .style = RtlS.ink(30), .test_id = "story.rtl.tashkeel" }, "\u{645}\u{64E}\u{631}\u{652}\u{62D}\u{64E}\u{628}\u{64B}\u{627}"),
                // Dual-joining BEH controls: ZWNJ explicitly disables joining in the
                // second row. Unlike marhaba (REH is right-joining), the first row must
                // form a continuous baseline independent of platform font metrics.
                v.text(.{ .style = RtlS.ink(36), .test_id = "story.rtl.joined_control" }, "\u{628}\u{628}\u{628}\u{628}"),
                v.text(.{ .style = RtlS.ink(36), .test_id = "story.rtl.isolated_control" }, "\u{628}\u{200C}\u{628}\u{200C}\u{628}\u{200C}\u{628}"),
            }),
        }),

        // URL, email, and ES/CS/ON symbols often attach adjacent digits or Latin run to wrong
        // side.
        label("RTL paragraph with URL / email / + - / : symbols"),
        v.text(.{ .style = RtlS.ink(17), .test_id = "story.rtl.symbols" }, "\u{645}\u{631}\u{62D}\u{628}\u{627} https://example.com/a-b?q=1:2 test@example.com +12/34 - \u{5E9}\u{5DC}\u{5D5}\u{5DD}"),

        // Long RTL paragraph without hard break, soft-wrapped into multiple display lines in
        // narrow editor. e2e clicks left/right of two visual rows, drags cross-row selection,
        // validates caret/selection geometry.
        label("wrapped editable RTL: caret / selection rect / hit-testing"),
        v.attrs(.{ .test_id = "story.rtl.editor" }, W.Textarea(.{ .value = editor_text, .rows = 5, .width = 520 })),
    }));
}

// -- GlassMotion: transition -- glassEffectID morph / scrollEdgeEffectStyle /
// materialize --
const GlassMotionStory = struct {
    glass: *ui.widgets.glass_box.AdaptiveGlassBoxState,
    materialize: *ui.widgets.glass_box.AdaptiveGlassBoxState,
    scroll: *ui.widgets.scroll_area.ScrollState,
    content: *ui.Node,
    morphed: bool = false,
    shown: bool = true,
    fn morph(self: *GlassMotionStory) void {
        if (self.morphed) {
            ui.widgets.glass_box.glassMorphTo(self.glass, .{ .x = 12, .y = 12, .w = 150, .h = 84, .emphasis = .subtle });
        } else {
            ui.widgets.glass_box.glassMorphTo(self.glass, .{ .x = 190, .y = 26, .w = 260, .h = 140, .emphasis = .prominent });
        }
        self.morphed = !self.morphed;
    }
    fn scrollDown(self: *GlassMotionStory) void {
        // setScrollY handles clamp, clear momentum, sync content translate; writing scroll_y
        // directly won't move content.
        ui.widgets.scroll_area.setScrollY(self.scroll, self.content, self.scroll.scroll_y + 80);
    }
    fn toggleMaterialize(self: *GlassMotionStory) void {
        self.shown = !self.shown;
        ui.widgets.glass_box.glassSetEnabled(self.materialize, self.shown);
    }
};
pub fn buildGlassMotion(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);
    // Control row at top: page longer, button at window bottom causes e2e clickTestId to
    // auto-scroll page.
    const controls = try ui.box(cx, .{ .direction = .row, .gap = 10 }, .{});
    try c.appendChild(a, controls);

    // morph (glassEffectID): same shape cross two geometry/profile transition
    try c.appendChild(a, try labelNode(cx, "Morph (glassEffectID): one shape transitions between two geometries/profiles"));
    const morph_stage = try glassBackdrop(cx, 200);
    morph_stage.style.justify = .start;
    morph_stage.style.align_items = .start;
    const morph_group = try W.GlassGroup(.{ .spacing = 0 }).mountWithState(scope, cx);
    morph_group.container.style.width = .{ .grow = .{} };
    morph_group.container.style.height = .{ .grow = .{} };
    morph_group.container.style.ensureExtPanic(a).align_self = .stretch;
    const gm = try W.GlassShape(.{ .title = "Morph", .width = 150, .height = 84, .id = "morph", .transition = .matched_geometry }).mountIn(morph_group, scope, cx);
    gm.node.style.position = .absolute;
    (try gm.node.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 12 }, .top = .{ .px = 12 } };
    gm.node.meta.ownership.meta.test_id = "story.glassmotion.morph";
    try morph_stage.appendChild(a, morph_group.container);
    try c.appendChild(a, morph_stage);

    // -- scroll-edge (scrollEdgeEffectStyle(.soft)): container-level binding, glass bar
    // covers ScrollArea top --
    try c.appendChild(a, try labelNode(cx, "Scroll edge (scrollEdgeEffectStyle .soft): glass bar over scrolling content"));
    const se_stage = try ui.box(cx, .{ .width = .{ .px = 420 }, .height = .{ .px = 220 }, .position = .relative }, .{});
    const sa = try W.ScrollArea(.{ .width = 420, .height = 220, .direction = .vertical }).mount(scope, cx);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var buf: [32]u8 = undefined;
        const txt = try std.fmt.bufPrint(&buf, "Content row {d}", .{i});
        try sa.content.appendChild(a, try ui.text(cx, txt, .{ .font_size = 13, .color = light.tokens.color.fg_primary }));
    }
    try se_stage.appendChild(a, sa.container);
    const bar_group = try W.GlassGroup(.{ .spacing = 0, .width = 420, .height = 44, .scroll_edge = .{ .scroll = sa.state, .edge = .top, .fade_width = 28 } }).mountWithState(scope, cx);
    bar_group.container.style.position = .absolute;
    (try bar_group.container.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } };
    bar_group.container.meta.ownership.meta.test_id = "story.glassmotion.bar";
    const bar = try W.GlassShape(.{ .width = 420, .height = 44, .padding = ui.Padding.symmetric(8, 12) }).mountIn(bar_group, scope, cx);
    const toolbar_label = try ui.text(cx, "Floating glass toolbar", .{ .font_size = 13, .font_weight = 600, .color = cx.tokens.tokens.color.fg_primary });
    toolbar_label.meta.ownership.meta.test_id = "story.glassmotion.label";
    try bar.body.appendChild(a, toolbar_label);
    try se_stage.appendChild(a, bar_group.container);
    try c.appendChild(a, se_stage);

    // -- materialize (glassEffectTransition(.materialize)): appears/disappears per native
    // measured curve --
    try c.appendChild(a, try labelNode(cx, "Materialize (glassEffectTransition): appears/disappears by modulating coating, rim, lens and blur"));
    const mat_stage = try glassBackdrop(cx, 140);
    const mat_group = try W.GlassGroup(.{ .spacing = 0 }).mountWithState(scope, cx);
    const mat = try W.GlassShape(.{ .title = "Materialize", .width = 200, .height = 56, .shape = .capsule, .padding = ui.Padding.symmetric(8, 18), .transition = .materialize }).mountIn(mat_group, scope, cx);
    mat.node.meta.ownership.meta.test_id = "story.glassmotion.materialize";
    try mat_stage.appendChild(a, mat_group.container);
    try c.appendChild(a, mat_stage);

    const st = try cx.bindState(GlassMotionStory, .{ .glass = gm.state, .materialize = mat.state, .scroll = sa.state, .content = sa.content });
    const morph_btn = try W.Button(.{ .label = "Morph", .on_click = cx.on(GlassMotionStory, st, GlassMotionStory.morph) }).mount(scope, cx);
    morph_btn.meta.ownership.meta.test_id = "story.glassmotion.morphbtn";
    try controls.appendChild(a, morph_btn);
    const scroll_btn = try W.Button(.{ .label = "Scroll +80", .on_click = cx.on(GlassMotionStory, st, GlassMotionStory.scrollDown) }).mount(scope, cx);
    scroll_btn.meta.ownership.meta.test_id = "story.glassmotion.scrollbtn";
    try controls.appendChild(a, scroll_btn);
    const toggle_btn = try W.Button(.{ .label = "Toggle glass", .on_click = cx.on(GlassMotionStory, st, GlassMotionStory.toggleMaterialize) }).mount(scope, cx);
    toggle_btn.meta.ownership.meta.test_id = "story.glassmotion.toggle";
    try controls.appendChild(a, toggle_btn);
    return c;
}

// -- GlassChrome: toolbar floats above scrolling content (macOS 26 / AppKit standard usage) --
//
// Replaces a custom chrome (top 76 pt "progressive frosted" bar with hand-written blur 180 +
// gradient, pure-blur capsule with 88% white + stroke + custom dual shadow, slider stairs for
// blur / white opacity). AppKit does it with two native things:
// 1. Controls placed in an NSToolbar glass capsule group (GlassToolbar,
//    native_appkit_controls.swift measured per-item); title is regular text, no glass;
// 2. Toolbar/content division handled by the **titlebar edge** (glass_toolbar.titlebarEdge,
//    native_titlebar_scroll.swift measured): content washes toward the window background
//    color, top 0.85, ~76 pt vanishes, light/dark appearance same curve.
//    scrollEdgeEffectStyle(.soft / .hard) is unchanged on macOS 26.4
//    (native_scroll_edge*.swift).
// Dark scene: toolbar over a ~34 deep band, auto-flips to the dark family.

const chrome_col = struct {
    const canvas = ui.Color.hex(0xF6F6F3);
    const grid = ui.Color.hex(0xE4E3DE);
    const canvas_dark = ui.Color.hex(0x1E1E20);
    const grid_dark = ui.Color.hex(0x2C2C2F);
};

/// Canvas background: light beige (dark: deep gray) + sticky notes / shapes / text,
/// real content scrolling under toolbar. Deliberately high-frequency detail (text,
/// fine grid, hard-edge blocks), blur too weak becomes obvious.
fn chromeCanvas(cx: *ui.Cx, w: f32, h: f32, dark: bool) !*ui.Node {
    const a = cx.allocator;
    const n = try ui.box(cx, .{
        .width = .{ .px = w },
        .height = .{ .px = h },
        .background = if (dark) chrome_col.canvas_dark else chrome_col.canvas,
        .position = .relative,
        .overflow_hidden = true,
    }, .{});

    // Fine grid (canvas stipple feel)
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
            .background = if (dark) chrome_col.grid_dark else chrome_col.grid,
        }, .{}));
    }
    try n.appendChild(a, grid);

    // Sticky notes: hard-edge high-saturation blocks, glass sliding over should soften
    // edges to smooth transition band
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

const GlassChromeStory = struct {
    scroll: *ui.widgets.scroll_area.ScrollState,
    content: *ui.Node,

    // setScrollY clamps to [0, maxScrollY], syncs content translate.
    fn scrollDown(self: *GlassChromeStory) void {
        ui.widgets.scroll_area.setScrollY(self.scroll, self.content, self.scroll.scroll_y + 90);
    }
    fn scrollUp(self: *GlassChromeStory) void {
        ui.widgets.scroll_area.setScrollY(self.scroll, self.content, self.scroll.scroll_y - 90);
    }
};

/// One scene: scroll canvas + titlebar edge + toolbar (back / title / zoom -+ /
/// more). Back returns stage, enter scroll area.
fn chromeScene(scope: *ui.Scope, cx: *ui.Cx, width: f32, height: f32, dark: bool, comptime prefix: []const u8) !struct { stage: *ui.Node, sa: ui.widgets.scroll_area.ScrollAreaResult } {
    const a = cx.allocator;
    const stage = try ui.box(cx, .{ .width = .{ .px = width }, .height = .{ .px = height }, .position = .relative, .overflow_hidden = true }, .{});
    (try stage.style.ensureExtFallible(a)).corner_radius = ui.CornerRadius.uniform(10);
    stage.meta.ownership.meta.test_id = prefix ++ "stage";

    // Content top padding = titlebar height 52: NSScrollView in fullSizeContentView window
    // auto-adds contentInsets.top (native_titlebar_scroll.swift reads 52) -- at rest
    // content under toolbar, scrolling enters titlebar edge
    const sa = try W.ScrollArea(.{ .width = width, .height = height, .direction = .vertical, .padding = .{ .top = 52 }, .background = if (dark) chrome_col.canvas_dark else chrome_col.canvas }).mount(scope, cx);
    for (0..3) |_| try sa.content.appendChild(a, try chromeCanvas(cx, width, 260, dark));
    sa.content.meta.ownership.meta.test_id = prefix ++ "canvas";
    try stage.appendChild(a, sa.container);

    const edge = try W.glass_toolbar.titlebarEdge(cx, .{ .width = width, .dark = dark });
    edge.meta.ownership.meta.test_id = prefix ++ "edge";
    try stage.appendChild(a, edge);

    // 52 pt titlebar contains 36 pt toolbar vertically centered (distance-top 8)
    const TB = W.glass_toolbar;
    const groups = [_]TB.ToolbarGroup{
        .{ .buttons = &[_]TB.ToolbarButton{.{ .icon = ui.system_icons.chevron_left, .label = "Back", .test_id = prefix ++ "back" }} },
        .flexible_space,
        .{ .buttons = &[_]TB.ToolbarButton{
            .{ .icon = ui.system_icons.minus, .label = "Zoom Out", .test_id = prefix ++ "zoomout" },
            .{ .icon = ui.system_icons.plus, .label = "Zoom In", .test_id = prefix ++ "zoomin" },
        } },
        .{ .buttons = &[_]TB.ToolbarButton{.{ .icon = ui.system_icons.more_horizontal, .label = "More", .test_id = prefix ++ "more" }} },
    };
    const tb = try W.GlassToolbar(.{ .groups = &groups, .test_id = prefix ++ "bar" }).mount(scope, cx);
    const bar_row = try ui.box(cx, .{ .width = .{ .px = width }, .height = .{ .px = 36 }, .position = .absolute, .direction = .row, .padding = .{ .left = 12, .right = 12 } }, .{});
    (try bar_row.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 8 } };
    try bar_row.appendChild(a, tb.root);
    try stage.appendChild(a, bar_row);

    // Title: regular text (no glass), follows back capsule
    const title = try ui.text(cx, "Board", .{ .font_size = 15, .font_weight = 700, .color = if (dark) ui.Color.rgba(255, 255, 255, 230) else ui.Color.rgba(0, 0, 0, 217) });
    title.style.position = .absolute;
    (try title.style.ensureExtFallible(a)).inset = .{ .left = .{ .px = 12 + 37.5 + 12 }, .top = .{ .px = 16 } };
    title.meta.ownership.meta.test_id = prefix ++ "title";
    try stage.appendChild(a, title);
    return .{ .stage = stage, .sa = sa };
}

pub fn buildGlassChrome(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const c = try col(cx, 16);
    const STAGE_W: f32 = 620;

    const light_scene = try chromeScene(scope, cx, STAGE_W, 220, false, "story.glasschrome.");
    try c.appendChild(a, light_scene.stage);

    const st = try cx.bindState(GlassChromeStory, .{ .scroll = light_scene.sa.state, .content = light_scene.sa.content });
    const controls = try ui.box(cx, .{ .direction = .row, .gap = 10 }, .{});
    const down = try W.Button(.{ .label = "Scroll +90", .on_click = cx.on(GlassChromeStory, st, GlassChromeStory.scrollDown) }).mount(scope, cx);
    down.meta.ownership.meta.test_id = "story.glasschrome.scrolldown";
    try controls.appendChild(a, down);
    const up = try W.Button(.{ .label = "Scroll −90", .on_click = cx.on(GlassChromeStory, st, GlassChromeStory.scrollUp) }).mount(scope, cx);
    up.meta.ownership.meta.test_id = "story.glasschrome.scrollup";
    try controls.appendChild(a, up);
    try c.appendChild(a, controls);

    try c.appendChild(a, try labelNode(cx, "Dark appearance: the same edge washes toward 34; the toolbar glass flips to the dark family on it"));
    const dark_scene = try chromeScene(scope, cx, STAGE_W, 220, true, "story.glasschrome.dark.");
    try c.appendChild(a, dark_scene.stage);
    return c;
}

// -- CanvasEvents: scroll modifiers / magnify / drag / clipboard image (upstream
// ability e2e validate) --
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

    /// Canvas receives raw events: scroll goes on_scroll slot, magnify / drag go on_event
    /// slot.
    fn attach(self: *CanvasEventsStory, canvas: *ui.Node) void {
        canvas.behavior.events.on_scroll = onScroll;
        canvas.behavior.events.on_event = onEvent;
        canvas.behavior.events.event_context = self;
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
        self.clipboardRead();
    }

    fn clipboardRead(self: *CanvasEventsStory) void {
        const cx = self.cx;
        const kinds = ui.platform_services.clipboardProbe(cx.system_sdk);
        const count = ui.platform_services.clipboardImageCount(cx.system_sdk);
        if (ui.platform_services.clipboardGetImageAlloc(cx.system_sdk, cx.allocator, 0)) |img_const| {
            var img = img_const;
            defer img.deinit(cx.allocator);
            // 2x2 pure red premultiplied RGBA: first pixel R=255 A=255
            const px_ok = img.rgba.len == 16 and img.rgba[0] == 255 and img.rgba[3] == 255;
            self.setLabel(self.clip_label, "clip: image={any} count={d} {d}x{d} px_ok={any} uti={s} rgba_crc32={x}", .{
                kinds.image, count, img.width, img.height, px_ok, img.uti orelse "(none)", std.hash.Crc32.hash(img.rgba),
            });
        } else {
            self.setLabel(self.clip_label, "clip: image={any} count={d} read failed", .{ kinds.image, count });
        }
    }
};

const CanvasEventsS = struct {
    fn canvas(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 420 }, .height = .{ .px = 160 }, .background = t.tokens.color.bg_secondary };
    }
};

pub fn buildCanvasEvents(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const st = try scope.createState(CanvasEventsStory, .{
        .cx = cx,
        .scroll_label = undefined,
        .magnify_label = undefined,
        .drag_label = undefined,
        .clip_label = undefined,
    });
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.setup(v.box(.{ .style = CanvasEventsS.canvas, .test_id = "story.canvasevents.canvas" }, .{}), st, CanvasEventsStory.attach),
        v.capture(&st.scroll_label, v.text(.{ .style = regBody, .test_id = "story.canvasevents.scroll" }, "scroll (none)")),
        v.capture(&st.magnify_label, v.text(.{ .style = regBody, .test_id = "story.canvasevents.magnify" }, "magnify (none)")),
        v.capture(&st.drag_label, v.text(.{ .style = regBody, .test_id = "story.canvasevents.drag" }, "drag (none)")),
        v.capture(&st.clip_label, v.text(.{ .style = regBody, .test_id = "story.canvasevents.clip" }, "clip (none)")),
        v.attrs(.{ .test_id = "story.canvasevents.clipbtn" }, W.Button(.{ .label = "Clipboard PNG roundtrip", .on_click = ui.on.call(st, CanvasEventsStory.clipboardRoundtrip) })),
        v.attrs(.{ .test_id = "story.canvasevents.clipread" }, W.Button(.{ .label = "Read clipboard PNG", .on_click = ui.on.call(st, CanvasEventsStory.clipboardRead) })),
    }));
}

// Drag: ui.interaction.drag base interaction primitive (docs/DRAG_INTERACTION_DESIGN.md
// §18.4). cover: free move box / horizontal resize handle / activation threshold + click
// count / post-cancel state text / keyboard equivalent (arrow keys micro-adjust, drag a11y
// contract requires).

const DragStory = struct {
    cx: *ui.Cx,
    subject: *ui.Node,
    status_label: *ui.Node,
    clicks_label: *ui.Node,
    panel: *ui.Node,
    width_label: *ui.Node,

    // Free move: from start baseline + cumulative delta (9.2 recommended pattern)
    base_tx: f32 = 0,
    base_ty: f32 = 0,
    // Horizontal resize
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

    /// Block: both-axis drag binding + keyboard equivalents. Click count in separate
    /// on_click slot (drag binding uses on_event, both composable; past threshold/cancel
    /// dispatcher suppresses click, count doesn't increment).
    fn attachSubject(self: *DragStory, subject: *ui.Node, scope: *ui.Scope, cx: *ui.Cx) !void {
        self.subject = subject;
        _ = try ui.interaction.drag.Binding.attach(scope, cx, subject, .{
            .activation_distance = 4,
            .active_cursor = .grabbing,
        }, onMove, self);
        // Keyboard equivalents in separate on_key_down slot (key_context and event_context
        // separate)
        subject.behavior.events.on_key_down = onKeyDown;
        subject.behavior.events.key_context = @ptrCast(self);
    }

    fn attachHandle(self: *DragStory, handle: *ui.Node, scope: *ui.Scope, cx: *ui.Cx) !void {
        _ = try ui.interaction.drag.Binding.attach(scope, cx, handle, .{
            .axis = .horizontal,
            .active_cursor = .col_resize,
        }, onResize, self);
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
                // This example product strategy: cancel reverts to pre-drag position (Escape/blur
                // observable)
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

    fn onClick(self: *DragStory) void {
        self.clicks += 1;
        self.setLabel(self.clicks_label, "clicks: {d} (drag suppresses click)", .{self.clicks});
    }

    // Keyboard equivalents: arrow keys 10px nudge (drag is pointer-only, consumers must
    // provide equivalents)
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

const DragS = struct {
    fn arena(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 420 }, .height = .{ .px = 180 }, .background = t.tokens.color.bg_secondary, .corner_radius = 12 };
    }
    fn subject(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 72 }, .height = .{ .px = 72 }, .background = t.tokens.color.accent, .align_items = .center, .justify = .center, .corner_radius = 10, .cursor = .grab };
    }
    fn subjectText(_: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = ui.Color.rgba(255, 255, 255, 255) };
    }
    fn panel(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 240 }, .height = .{ .px = 80 }, .background = t.tokens.color.bg_tertiary, .align_items = .center, .justify = .center, .corner_radius = 8 };
    }
    fn handle(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 10 }, .height = .{ .px = 80 }, .background = t.tokens.color.border, .cursor = .col_resize };
    }
};

pub fn buildDrag(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const st = try scope.createState(DragStory, .{
        .cx = cx,
        .subject = undefined,
        .status_label = undefined,
        .clicks_label = undefined,
        .panel = undefined,
        .width_label = undefined,
    });
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        // -- 1. Free-moving block (both axes + click count + keyboard equivalents) --
        v.box(.{ .style = DragS.arena }, .{
            v.setup(v.box(.{ .style = DragS.subject, .test_id = "story.drag.box", .focusable = true, .on_click = ui.on.call(st, DragStory.onClick) }, .{
                v.text(.{ .style = DragS.subjectText }, "drag"),
            }), st, DragStory.attachSubject),
        }),
        v.capture(&st.status_label, v.text(.{ .style = regBody, .test_id = "story.drag.status" }, "state: idle")),
        v.capture(&st.clicks_label, v.text(.{ .style = regBody, .test_id = "story.drag.clicks" }, "clicks: 0 (drag suppresses click)")),
        // -- 2. Horizontal resize handle --
        label("Horizontal resize: drag the handle; delta is axis-projected"),
        v.row(.{ .style = S.line(0) }, .{
            v.capture(&st.panel, v.box(.{ .style = DragS.panel, .test_id = "story.drag.panel" }, .{
                v.capture(&st.width_label, v.text(.{ .style = regBody, .test_id = "story.drag.width" }, "width: 240px")),
            })),
            v.setup(v.box(.{ .style = DragS.handle, .test_id = "story.drag.handle" }, .{}), st, DragStory.attachHandle),
        }),
    }));
}

// -- TextAnimJitter --
// Text animation jitter detection fixture.
//
// translate: extremely slow linear move (1 logical px/s) + non-integer font size, so each
// glyph has a different fractional phase and per-glyph pixel snap makes glyph spacing vary
// +- 1 physical pixel over time. e2e samples screenshots at intervals and asserts glyph
// spacing is constant (e2e/text-anim-jitter.test.ts).
//
// scale / rotate / opacity / backdrop blur: eyeball fixtures covering 2.3 pattern seams
// (surface promotion/demotion, subpixel <-> linear switch): scale traverses 1.0 forward/back,
// rotate loops continuously, opacity goes forward/back, static text above has a blur sweep.

/// Forward/backward loop animation state (restarted in on_complete; tick defers
/// callbacks, safe).
const TextJitterLoop = struct {
    node: *ui.Node,
    allocator: std.mem.Allocator,
    lo: f32,
    hi: f32,
    dur: f32,
    kind: Kind,
    // true = current animation run ends at hi
    to_hi: bool = true,

    const Kind = enum { scale, opacity, rotate };

    /// Starts playback after attach; state belongs to story scope, released on unmount.
    const Spec = struct { lo: f32, hi: f32, dur: f32, kind: Kind, to_hi: bool = true };

    fn start(spec: Spec, node: *ui.Node, scope: *ui.Scope, cx: *ui.Cx) !void {
        const st = try scope.createState(TextJitterLoop, .{
            .node = node,
            .allocator = cx.allocator,
            .lo = spec.lo,
            .hi = spec.hi,
            .dur = spec.dur,
            .kind = spec.kind,
            .to_hi = spec.to_hi,
        });
        st.launch();
    }

    fn launch(st: *TextJitterLoop) void {
        const from = if (st.to_hi) st.lo else st.hi;
        const to = if (st.to_hi) st.hi else st.lo;
        switch (st.kind) {
            .scale => {
                // scale_y has no callback, only scale_x handles flip (both axes sync same duration)
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
            // rotate doesn't reverse: after each run lo->hi restarts (continuous rotation)
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
};

/// translate gate: uniform 120px move in 120s (1 logical px/s).
fn startTextJitterTranslate(_: void, node: *ui.Node, _: *ui.Scope, cx: *ui.Cx) void {
    ui.animateNode(node, cx.allocator, .{
        .prop = .translate_x,
        .from = 0.0,
        .to = 120.0,
        .duration = 120.0,
        .easing = .linear,
    });
}

/// blur sweep: backdrop_blur oscillates [0, 24] by wall-clock sine (blur not
/// AnimatableProp, direct write in before_render, same pattern as Spinner).
/// hook on in-flow wrapper (before_render not guaranteed on absolute nodes, see
/// buildTabs snap comment); overlay pointer passed via slots.anim_state.
fn textJitterBlurTick(node: *ui.Node) void {
    const overlay: *ui.Node = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.anim_state orelse return));
    const ext = overlay.style.ext orelse return;
    const now_s = ui.frame.timeMs() / 1000.0;
    const phase: f32 = @floatCast(@sin(now_s * (std.math.tau / 8.0))); // 8s period
    if (ext.glass) |*g| g.backdrop_blur = 12.0 + 12.0 * phase;
    if (node.frame_state.state_bits.flags.out_of_viewport) return;
    overlay.markRenderDirty();
    node.markRenderDirty();
}

/// After overlay attaches: install sweep hook on its in-flow parent (wrapper).
fn attachTextJitterBlur(_: void, overlay: *ui.Node) void {
    const wrap = overlay.parent.?;
    wrap.meta.per_frame.hooks.slots.anim_state = @ptrCast(overlay);
    wrap.meta.per_frame.hooks.before_render.main = textJitterBlurTick;
}

const TextJitterS = struct {
    fn text(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 16.7, .color = t.tokens.color.fg_primary };
    }
    fn translateWrap(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 560 }, .height = .{ .px = 56 }, .padding = Padding.all(12), .align_items = .center };
    }
    fn scaleWrap(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 560 }, .height = .{ .px = 64 }, .align_items = .center, .justify = .center };
    }
    fn rotateWrap(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 560 }, .height = .{ .px = 110 }, .align_items = .center, .justify = .center };
    }
    fn opacityWrap(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 560 }, .height = .{ .px = 48 }, .align_items = .center, .padding = Padding.all(12) };
    }
    fn blurWrap(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 560 }, .height = .{ .px = 64 }, .align_items = .center, .padding = Padding.all(12) };
    }
    /// Constant style (applied once at mount): hook overwrites glass.backdrop_blur every
    /// frame, cannot be overridden by theme replay.
    const overlay: ui.BoxStyle = .{
        .position = .absolute,
        .width = .{ .grow = .{} },
        .height = .{ .grow = .{} },
        .glass = .{ .backdrop_blur = 12, .glass_intensity = 0 },
    };
};

pub fn buildTextAnimJitter(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const T = TextJitterS;
    return v.render(scope, cx, v.col(.{ .style = S.stack(14) }, .{
        // -- 1. translate (e2e gate, keep frontmost, test_id unchanged) --
        label("Translate 1px/s: glyph gaps must stay constant"),
        v.box(.{ .style = T.translateWrap, .test_id = "story.textanimjitter.wrap" }, .{
            v.setup(v.text(.{ .style = T.text }, "H o W l M x H o W l M x H o W l"), {}, startTextJitterTranslate),
        }),

        // -- 2. scale forward/back (crosses 1.0: no jumps or softness changes at
        // promotion/demotion seams) --
        label("Scale 0.85 ⇄ 1.15: no snap or sharpness pop at 1.0 crossings"),
        v.box(.{ .style = T.scaleWrap }, .{
            v.setup(v.text(.{ .style = T.text }, "Scale: The quick brown fox 0123456789"), TextJitterLoop.Spec{ .lo = 0.85, .hi = 1.15, .dur = 6.0, .kind = .scale }, TextJitterLoop.start),
        }),

        // -- 3. rotate continuous (text block uniform rotation, no per-character jitter) --
        label("Rotate: continuous slow spin"),
        v.box(.{ .style = T.rotateWrap }, .{
            v.setup(v.text(.{ .style = T.text }, "Rotate 360"), TextJitterLoop.Spec{ .lo = 0.0, .hi = std.math.tau, .dur = 16.0, .kind = .rotate }, TextJitterLoop.start),
        }),

        // -- 4. opacity forward/back (no position/clarity jumps when opacity layer
        // promoted/demoted) --
        label("Opacity 1.0 ⇄ 0.15: position/sharpness must not shift"),
        v.box(.{ .style = T.opacityWrap }, .{
            v.setup(v.text(.{ .style = T.text }, "Opacity: fading in and out, steadily"), TextJitterLoop.Spec{ .lo = 0.15, .hi = 1.0, .dur = 4.0, .kind = .opacity, .to_hi = false }, TextJitterLoop.start),
        }),

        // -- 5. backdrop blur sweep (glass above static text blur 0<->24: no text
        // drift/flicker) --
        label("Backdrop blur 0 ⇄ 24 over static text: no drift or flicker"),
        v.box(.{ .style = T.blurWrap }, .{
            v.text(.{ .style = T.text }, "Blur target: sharp letters behind sweeping glass"),
            v.setup(v.box(.{ .style = T.overlay }, .{}), {}, attachTextJitterBlur),
        }),
    }));
}

// 2026-08-16 core review fix batch storybook regression anchors (user-visible
// fixes upgraded to storybook + e2e dual validation). Each story corresponds to one
// batch entry in review report.

// WordNav (Greek/Cyrillic word nav + family emoji grapheme clusters)
//
// Regression: cursor.zig used `>= 0xE0` for the multi-byte check, so 2-byte leads
// (Greek/Cyrillic) fell into the ASCII path and hit `>= 0x80` immediately -> stuck at the
// same position, Alt+<-/-> froze, double-click selected an empty range. e2e uses input_state
// to read cursor_pos/anchor byte offsets and assert word boundary landing.
//
// Byte ledger for preset text (e2e asserts depend on it; change text = sync e2e):
//   "αβγ"=0..6  "δεζ"=7..13  "привет"=14..26  "мир"=27..33
//   "hello"=34..39  "world"=40..45  family emoji=46..71  "fin"=72..75  total=75
const WORDNAV_TEXT = "αβγ δεζ привет мир hello world \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} fin";

pub fn buildWordNav(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.attrs(.{ .test_id = "story.wordnav.ta" }, W.Textarea(.{
            .label_text = "Mixed-script sample",
            .value = WORDNAV_TEXT,
            .rows = 3,
            .width = 560,
        })),
        label("Expected Alt+Right stops (byte offsets): 7 14 27 34 40 46 72 75"),
    }));
}

// -- MultiClick / Gestures (multi-click and cancel + long_press tick) --
// Multi-click: reset() must not zero click_count on every mouse-down, else double/triple is
// structurally unreachable (e2e double-click assertion); onTouchUp used to discard the timestamp,
// so two taps 10s apart still counted as a double (interval expiry is not e2e-able, kept for manual
// observation); .cancelled was only read, never written.
// long_press: an app registering it must not panic on the first frame tick (epoch timestamp
// @intCast overflow); the story loading its first frame is the regression anchor; holding
// 500ms and asserting began is additional validation.
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
    /// After story unloads, arena recognizers remain (no removeRecognizer API),
    /// callbacks set null; alive is second line of defense.
    alive: bool = true,

    const LongState = enum { idle, began, ended, cancelled };

    fn setLabel(self: *MultiClickStory, node: *ui.Node, comptime fmt: []const u8, args: anytype) void {
        var buf: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, fmt, args) catch return;
        node.setTextContent(self.cx.allocator, txt) catch return;
        node.markRenderDirty();
    }

    /// After pad attaches: register four recognizers + count mirror hook, unhook
    /// callbacks on scope unmount.
    fn attachPad(self: *MultiClickStory, pad: *ui.Node, scope: *ui.Scope, cx: *ui.Cx) !void {
        self.rec_ids[0] = try cx.registerGesture(pad, .tap, .{}, onGesture, @ptrCast(self));
        self.rec_ids[1] = try cx.registerGesture(pad, .double_tap, .{}, onGesture, @ptrCast(self));
        self.rec_ids[2] = try cx.registerGesture(pad, .triple_tap, .{}, onGesture, @ptrCast(self));
        self.rec_ids[3] = try cx.registerGesture(pad, .long_press, .{}, onGesture, @ptrCast(self));

        pad.meta.per_frame.hooks.slots.anim_state = @ptrCast(self);
        pad.meta.per_frame.hooks.before_render.main = tickHook;

        const rc = try cx.allocator.create(MultiClickCleanup);
        rc.* = .{ .cx = cx, .st = self };
        try scope.adoptResource(@ptrCast(rc), MultiClickCleanup.destroy);
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

    /// before_render: mirror the count to the label (write only on change) and keep frames being
    /// produced; gesture_arena.tick only runs on real render frames, so long_press timing depends
    /// on continuous frame advancement.
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

/// Unhook gesture callbacks on scope unmount: GestureArena has no removeRecognizer,
/// unhooked leads to clicks anywhere in window invoking dead story context after
/// unload.
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

const MultiClickS = struct {
    fn pad(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 320 }, .height = .{ .px = 140 }, .background = t.tokens.color.bg_secondary, .align_items = .center, .justify = .center, .corner_radius = 10 };
    }
};

pub fn buildMultiClick(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const st = try scope.createState(MultiClickStory, .{
        .cx = cx,
        .single_label = undefined,
        .double_label = undefined,
        .triple_label = undefined,
        .long_label = undefined,
    });
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        v.setup(v.box(.{ .style = MultiClickS.pad, .test_id = "story.multiclick.pad" }, .{
            v.text(.{ .style = S.storyLabel }, "click / double-click / hold"),
        }), st, MultiClickStory.attachPad),
        v.capture(&st.single_label, v.text(.{ .style = regBody, .test_id = "story.multiclick.single" }, "single: 0")),
        v.capture(&st.double_label, v.text(.{ .style = regBody, .test_id = "story.multiclick.double" }, "double: 0")),
        v.capture(&st.triple_label, v.text(.{ .style = regBody, .test_id = "story.multiclick.triple" }, "triple: 0")),
        v.capture(&st.long_label, v.text(.{ .style = regBody, .test_id = "story.multiclick.long" }, "long: idle")),
    }));
}

// -- AnimControls (yoyo replay / timeline reverse / keyframes batch fill / spring degenerate
// params) --
// e2e uses entirely **data value readback** assertions (label text / query translate), no
// mid-animation pixel assertions (animation screenshots are a noise source in this repo).
//   yoyo: bare play() replay after yoyo completes, first tick value must be near from.
//   reverse: after reverse the timeline must complete in finite steps and stop at t=0.
//   keyframes: kf_now is advanced explicitly by a button (simulates a 1s frame stall); a
//   single update must batch-fill multiple cycles (single-cycle advance would clamp progress
//   at 1.0 and undercount loops).
//   spring: negative stiffness writes to translate_x each frame, value must be finite (not NaN).
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
        // Write only when content changes: unconditional setTextContent +
        // markRenderDirty pins frame loop to "always dirty", story never idles.
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

    /// One advance 1000ms (keyframes period 400ms): actually recreates "frame stall
    /// spanning multiple cycles", update while loop must batch-fill 2 cycles, stop at 50%
    /// into cycle.
    fn kfAdvance(self: *AnimCtlStory) void {
        self.kf_now += 1000;
        self.kf_value = self.kf.update(self.kf_now);
        self.cx.needs_redraw = true;
    }

    /// Install drive hook after root attaches (labels/boxes already captured).
    fn attachTick(self: *AnimCtlStory, root: *ui.Node) void {
        root.meta.per_frame.hooks.slots.anim_state = @ptrCast(self);
        root.meta.per_frame.hooks.before_render.main = tickHook;
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

fn destroyAnimTimeline(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const tl: *ui.fx.Timeline = @ptrCast(@alignCast(ptr));
    tl.deinit();
    alloc.destroy(tl);
}

const AnimCtlS = struct {
    fn arena(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 560 }, .height = .{ .px = 60 }, .background = t.tokens.color.bg_secondary };
    }
    fn yoyoBox(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .background = t.tokens.color.accent };
    }
    fn springBox(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .background = t.tokens.color.border };
    }
};

pub fn buildAnimCtl(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const a = cx.allocator;
    const Ctrl = ui.fx.AnimationController;

    // yoyo tween: 20 -> 120 -> 20 (loops=2 + yoyo), stops at from after complete.
    const yoyo_ctrl = try scope.createState(Ctrl, Ctrl.initTween(.{ .from = 20, .to = 120, .duration = 0.7, .easing = .linear }));
    yoyo_ctrl.yoyo = true;
    yoyo_ctrl.loops = 2;

    // timeline: single 0->100 linear 2s.
    const tl_ctrl = try scope.createState(Ctrl, Ctrl.initTween(.{ .from = 0, .to = 100, .duration = 2.0, .easing = .linear }));
    const tl = try a.create(ui.fx.Timeline);
    tl.* = ui.fx.Timeline.init(a);
    try scope.adoptResource(@ptrCast(tl), destroyAnimTimeline);
    try tl.add(tl_ctrl, ui.fx.Position.start);

    // Degenerate spring: negative stiffness (after fix precompute three params
    // clamped, no NaN).
    const spring_ctrl = try scope.createState(Ctrl, Ctrl.initSpring(.{ .from = 0, .to = 100, .stiffness = -50, .damping = 10, .mass = 1 }));

    const st = try scope.createState(AnimCtlStory, .{
        .cx = cx,
        .yoyo_ctrl = yoyo_ctrl,
        .tl = tl,
        .tl_ctrl = tl_ctrl,
        .spring_ctrl = spring_ctrl,
        .kf = ui.fx.KeyframeAnimation.init(&KF_FRAMES, 400, 4),
        .yoyo_box = undefined,
        .spring_box = undefined,
        .yoyo_label = undefined,
        .tl_label = undefined,
        .kf_label = undefined,
        .spring_label = undefined,
    });

    const root = try v.render(scope, cx, v.setup(v.col(.{ .style = S.stack(12) }, .{
        // Visualization target (value assertions via label; boxes visual aid only)
        v.box(.{ .style = AnimCtlS.arena }, .{
            v.capture(&st.yoyo_box, v.box(.{ .style = AnimCtlS.yoyoBox, .test_id = "story.animctl.yoyobox" }, .{})),
            v.capture(&st.spring_box, v.box(.{ .style = AnimCtlS.springBox, .test_id = "story.animctl.springbox" }, .{})),
        }),
        v.capture(&st.yoyo_label, v.text(.{ .style = regBody, .test_id = "story.animctl.yoyo" }, "yoyo: state=idle value=20.0 replay_first=-1.0")),
        v.capture(&st.tl_label, v.text(.{ .style = regBody, .test_id = "story.animctl.tl" }, "tl: state=idle t=0.00 v=0.0")),
        v.capture(&st.kf_label, v.text(.{ .style = regBody, .test_id = "story.animctl.kf" }, "kf: loops=0 value=0.0 completed=false")),
        v.capture(&st.spring_label, v.text(.{ .style = regBody, .test_id = "story.animctl.spring" }, "spring: ticks=0 value=0.0")),
        v.row(.{ .style = S.line(8) }, .{
            v.attrs(.{ .test_id = "story.animctl.yoyo_play" }, W.Button(.{ .label = "Play yoyo", .size = .sm, .on_click = ui.on.call(st, AnimCtlStory.playYoyo) })),
            v.attrs(.{ .test_id = "story.animctl.tl_play" }, W.Button(.{ .label = "Play timeline", .size = .sm, .on_click = ui.on.call(st, AnimCtlStory.playTimeline) })),
            v.attrs(.{ .test_id = "story.animctl.tl_reverse" }, W.Button(.{ .label = "Reverse timeline", .size = .sm, .on_click = ui.on.call(st, AnimCtlStory.reverseTimeline) })),
            v.attrs(.{ .test_id = "story.animctl.kf_reset" }, W.Button(.{ .label = "KF reset", .size = .sm, .on_click = ui.on.call(st, AnimCtlStory.kfReset) })),
            v.attrs(.{ .test_id = "story.animctl.kf_step" }, W.Button(.{ .label = "KF +1s", .size = .sm, .on_click = ui.on.call(st, AnimCtlStory.kfAdvance) })),
        }),
    }), st, AnimCtlStory.attachTick));

    // spring auto-plays (driven on mount, e2e reads values only)
    spring_ctrl.play();
    cx.needs_redraw = true;
    return root;
}

// -- CleanupHooks: on_cleanup fires exactly once --
// fireCleanupCallbacks must clear fields, else mounted nodes run cleanup twice in the
// removeChild -> freeNode chain. Bool assertions can't catch double invocation, so the
// story renders the **count**, not a boolean.
const CleanupStory = struct {
    cx: *ui.Cx,
    count: u32 = 0,
    mounted: bool = true,
    count_label: *ui.Node,
    mounted_sig: *ui.Signal(bool),

    fn onChildCleanup(self: *CleanupStory) void {
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

    fn attachChild(self: *CleanupStory, child: *ui.Node) void {
        ui.hooks.onCleanup(child, ui.on.call(self, onChildCleanup));
    }
};

const CleanupS = struct {
    fn child(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .padding = Padding.all(10), .background = t.tokens.color.bg_secondary };
    }
};

pub fn buildCleanup(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const sig = try scope.createSignal(bool, true);
    // Node on_cleanup fires after story scope disposed (unmount order: dispose scope
    // first, then release nodes), state can't belong to story scope (released first), use
    // cx.bindState (lives until Cx destroyed).
    const st = try cx.bindState(CleanupStory, .{
        .cx = cx,
        .count_label = undefined,
        .mounted_sig = sig,
    });
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        label("on_cleanup count: unmounting a subtree with a cleanup hook must add exactly 1 (double-fire adds 2)"),
        v.col(.{ .style = .{ S.stack(8), .{ .no_cross_stretch = false } } }, .{
            v.show(sig, .{
                v.setup(v.box(.{ .style = CleanupS.child, .test_id = "story.cleanup.child" }, .{
                    v.text(.{ .style = regBody }, "cleanup child mounted"),
                }), st, CleanupStory.attachChild),
            }),
        }),
        v.capture(&st.count_label, v.text(.{ .style = regBody, .test_id = "story.cleanup.count" }, "cleanups: 0")),
        v.attrs(.{ .test_id = "story.cleanup.toggle" }, W.Button(.{ .label = "Toggle child", .size = .sm, .on_click = ui.on.call(st, CleanupStory.toggle) })),
    }));
}

// -- HeavyText: text renderer overflow instance buffer retained pool --
// A single frame with > 32768 glyph instances (MAX_INSTANCES, see src/render/text_renderer.zig)
// forces the overflow buffer path (a cross-frame retained pool). 8 overlapping absolute
// layers x ~40 visible lines x ~160 chars/line ~= 50k visible glyphs reliably exceeds the
// budget. e2e asserts region pixels non-blank + app alive.
const HeavyTextS = struct {
    fn stack(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 980 }, .height = .{ .px = 520 }, .overflow_hidden = true, .background = t.tokens.color.bg_base };
    }
    fn layer(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .position = .absolute, .width = .{ .px = 980 } };
    }
    fn text(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 10, .color = t.tokens.color.fg_primary, .wrap = .word_break };
    }
};

const heavy_text_layers = @as([8]u0, @splat(0));

const HeavyTextViews = struct {
    const layer_props = .{ .style = HeavyTextS.layer };
    const text_props = .{ .style = HeavyTextS.text };

    fn layer(heavy: []const u8, _: u0) v.Box(@TypeOf(layer_props), v.Text(@TypeOf(text_props), []const u8), null) {
        return v.box(layer_props, v.text(text_props, heavy));
    }
};

pub fn buildHeavyText(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    // Deterministic ASCII word stream (8KB): "glyph00 glyph01 ..."; harness
    // serialization truncates to 200 bytes, query won't overflow huge text. Text node
    // copies content on mount, stack buffer only needs to outlive render.
    var text_buf: [8192]u8 = undefined;
    var i: usize = 0;
    var w: usize = 0;
    while (i + 8 <= text_buf.len) : (w += 1) {
        const chunk = std.fmt.bufPrint(text_buf[i..], "glyph{d:0>2} ", .{w % 100}) catch break;
        i += chunk.len;
    }
    const heavy: []const u8 = text_buf[0..i];

    return v.render(scope, cx, v.col(.{ .style = S.stack(10) }, .{
        label("Heavy text overflow: 8 overlapping layers exceed the 32768 glyph-instance budget (pooled overflow path)"),
        v.box(.{ .style = HeavyTextS.stack, .test_id = "story.heavytext.stack" }, v.listWith(heavy, &heavy_text_layers, HeavyTextViews.layer)),
    }));
}

// ── Security regressions (2026-08-17 audit) ──

const SecSvgS = struct {
    fn candidate(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 36 }, .height = .{ .px = 36 }, .background = t.tokens.color.danger_subtle };
    }
    fn valid(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 36 }, .height = .{ .px = 36 }, .background = t.tokens.color.success };
    }
    fn danger(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.danger };
    }
    fn successTint(t: *const ui.theme.Values) ui.Color {
        return t.tokens.color.success;
    }
};

const SvgSafetyCase = struct { name: []const u8, path: []const u8 };

/// One red-team sample: testing parsing itself, try parse on detached candidate
/// node first, declare this row by result.
fn svgSafetyCase(case: SvgSafetyCase, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const candidate = try v.render(scope, cx, v.box(.{ .style = SecSvgS.candidate }, .{}));
    var buf: [160]u8 = undefined;
    if (candidate.setSvgPathHitGeometry(cx.allocator, case.path, .nonzero)) {
        const accepted: []const u8 = try std.fmt.bufPrint(&buf, "{s} — UNEXPECTEDLY ACCEPTED", .{case.name});
        return v.render(scope, cx, v.row(.{ .style = S.line(10) }, .{
            candidate,
            v.text(.{ .style = SecSvgS.danger }, accepted),
        }));
    } else |err| {
        cx.freeNode(candidate);
        const rejected: []const u8 = try std.fmt.bufPrint(&buf, "{s} — rejected safely ({s})", .{ case.name, @errorName(err) });
        return v.render(scope, cx, v.row(.{ .style = S.line(10) }, .{
            v.icon(.{ .style = .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } }, .tint = SecSvgS.successTint }, ui.system_icons.check),
            v.text(.{ .style = regBody }, rejected),
        }));
    }
}

fn applySvgHitPath(path: []const u8, node: *ui.Node, _: *ui.Scope, cx: *ui.Cx) !void {
    try node.setSvgPathHitGeometry(cx.allocator, path, .nonzero);
}

/// Exercises the UI path-geometry parser with the two audit payload classes:
/// an operand after close-path (formerly an infinite loop) and a non-finite
/// exponent (formerly able to reach unchecked float-to-int casts). This route
/// stays available in test mode, where the platform SVG texture loader is
/// intentionally absent.
pub fn buildSecuritySvg(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(14) }, .{
        label("Malformed SVG corpus: every red-team sample must reject promptly without hanging or crashing"),
        v.component(svgSafetyCase, SvgSafetyCase{ .name = "close operand", .path = "M2 2 L22 2 Z 5" }),
        v.component(svgSafetyCase, SvgSafetyCase{ .name = "non-finite arc", .path = "M1 1 A1e999 1e999 0 0 1 1e999 1e999" }),
        v.row(.{ .style = S.line(10) }, .{
            v.setup(v.box(.{ .style = SecSvgS.valid, .test_id = "story.secsvg.valid" }, .{}), @as([]const u8, "M3 12 L9 18 L21 5 Z"), applySvgHitPath),
            v.text(.{ .style = regBody }, "valid control rendered"),
        }),
    }));
}

const SecOpacityS = struct {
    fn stage(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 520 }, .height = .{ .px = 250 }, .padding = Padding.all(10), .background = t.tokens.color.bg_secondary };
    }
    fn layer(comptime depth: usize) fn (*const ui.theme.Values) ui.BoxStyle {
        return struct {
            fn f(t: *const ui.theme.Values) ui.BoxStyle {
                const d: f32 = @floatFromInt(depth);
                return .{
                    .width = .{ .px = 470 - d * 24 },
                    .height = .{ .px = 210 - d * 14 },
                    .padding = Padding.all(5),
                    .background = if (depth % 2 == 0) t.tokens.color.accent_subtle else t.tokens.color.bg_base,
                    .opacity = 0.92,
                    .composited_group = true,
                };
            }
        }.f;
    }
    fn sentinel(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 210 }, .height = .{ .px = 44 }, .padding = Padding.all(10), .background = t.tokens.color.accent };
    }
    fn sentinelText(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.fg_inverse };
    }
    fn after(t: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .{ .px = 300 }, .height = .{ .px = 42 }, .padding = Padding.all(10), .background = t.tokens.color.success };
    }
    fn afterText(t: *const ui.theme.Values) ui.TextStyle {
        return .{ .font_size = 13, .color = t.tokens.color.status_fg };
    }
};

const sec_opacity_depth = 10;

const sec_opacity_sentinel_props = .{ .style = SecOpacityS.sentinel, .test_id = "story.secopacity.nested" };
const sec_opacity_sentinel_text = .{ .style = SecOpacityS.sentinelText };
const SecOpacitySentinel = v.Box(@TypeOf(sec_opacity_sentinel_props), v.Text(@TypeOf(sec_opacity_sentinel_text), []const u8), null);

fn secOpacitySentinel() SecOpacitySentinel {
    return v.box(sec_opacity_sentinel_props, v.text(sec_opacity_sentinel_text, @as([]const u8, "DEPTH 10 VISIBLE")));
}

/// Compositing group at depth (0 outermost), innermost holds sentinel.
fn SecOpacityLayer(comptime depth: usize) type {
    return struct {
        const props = .{ .style = SecOpacityS.layer(depth) };
        const innermost = depth + 1 == sec_opacity_depth;
        const Inner = if (innermost) SecOpacitySentinel else SecOpacityLayer(depth + 1).El;
        const El = v.Box(@TypeOf(props), Inner, null);

        fn el() El {
            const inner = if (innermost) secOpacitySentinel() else SecOpacityLayer(depth + 1).el();
            return v.box(props, inner);
        }
    };
}

/// Ten nested composited groups exceed the renderer's eight-level opacity
/// stack. Failed inner begins must be paired with no-op ends so the green
/// sibling after the stack still lands on the main render target.
pub fn buildSecurityOpacity(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = S.stack(14) }, .{
        label("10 nested composited opacity groups: depth > 8 must not pop or corrupt an outer render target"),
        v.box(.{ .style = SecOpacityS.stage }, SecOpacityLayer(0).el()),
        v.box(.{ .style = SecOpacityS.after, .test_id = "story.secopacity.after" }, .{
            v.text(.{ .style = SecOpacityS.afterText }, "AFTER STACK MUST BE VISIBLE"),
        }),
    }));
}

const security_text_value = "BEGIN|" ++ ((@as([(" ").len * (65_536)]u8, @bitCast(@as([65_536][(" ").len]u8, @splat((" ").*)))) ++ "")) ++ "|END";

const SecurityTextStory = struct {
    cx: *ui.Cx,
    status: *ui.Signal([]const u8),
    textarea: ?W.input.TextareaResult = null,

    fn changed(self: *SecurityTextStory, value: []const u8) void {
        var buf: [128]u8 = undefined;
        const text_value = std.fmt.bufPrint(&buf, "bytes: {d} · UTF-8 valid: {}", .{
            value.len,
            std.unicode.utf8ValidateSlice(value),
        }) catch return;
        self.status.set(text_value);
        self.cx.needs_redraw = true;
    }

    fn replaceWithX(self: *SecurityTextStory) void {
        const state = (self.textarea orelse return).state;
        // Take user edit path (regress wrap breakpoint overflow), submit through edit
        // exit: write back value + on_change
        state.selectAll();
        state.insertText("x");
        if (state.on_change) |h| h.invokeWithStr(state.getText());
    }
};

/// The u16 whitespace-run overflow and stale-wrap slicing fixes are easiest to
/// verify by editing the real Textarea: load exactly 65,536 consecutive spaces,
/// then replace the long line with one byte while stale wrap breaks still exist.
pub fn buildSecurityText(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const story = try scope.createState(SecurityTextStory, .{
        .cx = cx,
        .status = try scope.createText("bytes: 65546 · long space run loaded", .{}),
    });
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        label("65,536-space editable run: exercises wide run counts and stale wrap-break clamping"),
        label("Select all and replace with x; the editor must stay alive and report bytes: 1"),
        v.attrs(.{ .test_id = "story.sectext.replace" }, W.Button(.{
            .label = "Replace 65,546 bytes with x",
            .size = .sm,
            .on_click = ui.on.call(story, SecurityTextStory.replaceWithX),
        })),
        // replace button uses Textarea edit state (v.ref gets TextareaResult)
        v.attrs(.{ .parts = .{ .input = "story.sectext.input" } }, v.capture(&story.textarea, W.Textarea(.{
            .label_text = "BEGIN … 65,536 spaces … END",
            .value = security_text_value,
            .rows = 6,
            .width = 560,
            .on_change = ui.on.call(story, SecurityTextStory.changed),
        }))),
        v.text(.{ .style = regBody, .test_id = "story.sectext.status" }, story.status),
    }));
}

const TeardownStressStory = struct {
    cx: *ui.Cx,
    visible: *ui.Signal(bool),
    status: *ui.Signal([]const u8),
    mounted: bool = true,
    completed_cycles: u32 = 0,

    fn updateStatus(self: *TeardownStressStory) void {
        var buf: [96]u8 = undefined;
        const text_value = std.fmt.bufPrint(&buf, "grid {s} · completed cycles: {d}", .{
            if (self.mounted) "mounted" else "unmounted",
            self.completed_cycles,
        }) catch return;
        self.status.set(text_value);
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

/// Direct manual reproducer for the crash reported from rowClick -> Show dispose:
/// every unmount owns a Grid whose Scope cleanup still references its content
/// node, so scope cleanup must complete before deferred node destruction.
pub fn buildTeardownStress(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const visible = try scope.createSignal(bool, true);
    const story = try scope.createState(TeardownStressStory, .{
        .cx = cx,
        .visible = visible,
        .status = try scope.createText("grid mounted · completed cycles: 0", .{}),
    });
    return v.render(scope, cx, v.col(.{ .style = S.stack(12) }, .{
        label("Reactive teardown ordering: Scope cleanup must run before Grid nodes are freed"),
        v.row(.{ .style = S.line(8) }, .{
            v.attrs(.{ .test_id = "story.teardownstress.toggle" }, W.Button(.{
                .label = "Toggle Grid",
                .size = .sm,
                .on_click = ui.on.call(story, TeardownStressStory.toggle),
            })),
            v.attrs(.{ .test_id = "story.teardownstress.run" }, W.Button(.{
                .label = "Run 10 cycles",
                .size = .sm,
                .variant = .secondary,
                .on_click = ui.on.call(story, TeardownStressStory.runTen),
            })),
        }),
        v.text(.{ .style = regBody, .test_id = "story.teardownstress.status" }, story.status),
        v.col(.{ .style = .{ S.stack(8), .{ .no_cross_stretch = false } } }, .{
            v.show(visible, .{
                v.attrs(.{ .test_id = "story.teardownstress.grid", .style = .{ .no_cross_stretch = false } }, v.component(buildGrid, {})),
            }),
        }),
    }));
}

pub const buildInteractionLifecycle = @import("interaction_lifecycle.zig").build;

// Lazy aliases: the registry resolves these only when their story is selected.
pub const buildFormComposition = @import("form_composition.zig").build;
pub const buildScrolling = @import("scrolling_story.zig").build;
pub const buildViewDsl = @import("view_dsl_story.zig").build;
pub const buildComponentWall = @import("component_wall.zig").build;
pub const buildControls = @import("controls/mod.zig").build;
pub const buildCornerClip = @import("corner_clip/mod.zig").build;
pub const buildPopoverText = @import("popover_text/mod.zig").build;
pub const buildCjkWeights = @import("cjk_weights/mod.zig").build;
