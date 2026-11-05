//! EditableText, shell-free editable text.
//!
//! This component deliberately reuses Input's editing engine while omitting
//! ControlShell, borders, backgrounds, focus rings, padding and overflow fade.
//! It starts in display mode; `setEditing` attaches/detaches the input handler
//! so a canvas can keep its normal pointer interaction outside edit mode.
//! `wrap_width` opts into the existing TextareaDocument/WrapMap engine while
//! keeping the same shell-free node and result API.

const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Signal = reactive.Signal;
const Model = reactive.Model;
const Handler = core.Handler;
const binding_mod = @import("binding.zig");
const Binding = binding_mod.TextBinding(TextInputState);

const state_mod = @import("state.zig");
const render_mod = @import("render.zig");
const events_mod = @import("events.zig");
const editable_block = @import("../editable_block/mod.zig");
const TextInputState = state_mod.TextInputState;

pub const EditableTextProps = struct {
    /// Optional r4MT7 field chrome. Canvas editors keep the shell-free default.
    field_chrome: bool = false,
    /// Text value. A literal is the component-owned initial text; a
    /// `*Signal([]const u8)` from `scope.createText` is the value source edits
    /// write to; `ui.split` lets the parent accept, transform or reject each
    /// edit. Same rules as Input.
    value: Model([]const u8) = .{ .local = "" },
    font_size: f32 = 14,
    font_weight: u16 = 400,
    /// Line-height multiplier.
    line_height: f32 = 1.25,
    /// null means grow to the width offered by the parent.
    width: ?f32 = null,
    /// Enable multiline editing and soft wrapping at this fixed width. null
    /// preserves the original single-line behavior. When set, this takes
    /// precedence over `width` and the node height grows with visual lines.
    wrap_width: ?f32 = null,
    /// Called with the landed value after a user edit; retainers must copy it.
    on_change: ?Handler([]const u8) = null,
    /// Who switches editing mode on. `.manual` keeps the pointer free for the host (canvas
    /// cells, app-driven renames) until it calls `setEditing`.
    activation: Activation = .manual,
};

pub const Activation = enum {
    /// The host calls `EditableTextResult.setEditing`.
    manual,
    /// The text is focusable at rest: a press enters editing with the caret at the pressed
    /// position, keyboard focus (Tab) enters it with the caret where it was. Enter (single
    /// line), Escape and losing focus leave it. Edits are already committed as they land.
    click,
};

pub const EditableTextResult = struct {
    node: *Node,
    state: *TextInputState,
    /// Text value signal (null under `ui.split`).
    value: ?*Signal([]const u8),
    binding: *Binding,

    /// Enter or leave editing mode. Leaving editing mode also ends IME and
    /// removes selection state. Repeated calls with the same value are cheap.
    pub fn setEditing(self: EditableTextResult, cx: *Cx, editing: bool) void {
        applyEditing(cx, self.node, self.state, editing);
    }

    /// Update runtime font metrics. This is idempotent and safe to call from a
    /// canvas zoom loop. `line_height_ratio` is a multiplier, not pixels.
    pub fn setMetrics(self: EditableTextResult, font_size: f32, line_height_ratio: f32) void {
        const safe_font_size = @max(font_size, 1);
        const safe_ratio = @max(line_height_ratio, 0.1);
        // no rounding: static text layout line_height = font_size * ratio (text_layout.zig), ceil
        // here makes edit-mode line spacing up to 1px/line larger, host's static/edit dual-mode
        // switch (canvas double-click to edit) jumps entire text at non-integer line-height scale
        // levels.
        const line_height_px = safe_font_size * safe_ratio;
        const state = self.state;
        if (@abs(state.font_size - safe_font_size) <= 0.001 and
            @abs(state.line_height - line_height_px) <= 0.001)
        {
            return;
        }

        const char_width = if (state.cx_ref) |cx_ref| blk: {
            const measured = cx_ref.text.measureTextWidth("M", safe_font_size, state.font_weight, false);
            if (measured > 0) break :blk measured;
            break :blk safe_font_size * 0.6;
        } else safe_font_size * 0.6;
        state.font_size = safe_font_size;
        state.char_width = char_width;
        state.line_height = line_height_px;
        if (state.textarea_wrap) |wrap| {
            wrap.font_size = safe_font_size;
            wrap.char_width = char_width;
            if (state.textarea_doc) |doc| wrap.rebuildAll(doc);
        }
        if (state.text_display_node) |text_node| {
            if (text_node.getText()) |old| {
                var text = old;
                text.font_size = safe_font_size;
                text.line_height = safe_ratio;
                text_node.setText(text);
            }
            text_node.markLayoutDirty();
        }
        if (state.multiline) {
            state.syncMultilineAutoHeight();
        } else {
            self.node.setStyle(null, .height, .{ .px = line_height_px + state.padding_v * 2 });
        }
        state.updateScrollX();
        state.resetBlink();
        self.node.markRenderDirty();
    }

    /// Update the soft-wrap width at runtime. Canvas hosts resize objects and
    /// zoom continuously, so the wrap width must be able to follow the node it
    /// overlays frame by frame. Idempotent and cheap when the width is
    /// unchanged. No-ops on editors mounted without `wrap_width` (single-line
    /// has no wrap engine to reconfigure).
    pub fn setWrapWidth(self: EditableTextResult, width: f32) void {
        const state = self.state;
        const wrap = state.textarea_wrap orelse return;
        const doc = state.textarea_doc orelse return;
        const safe_width = @max(width, 1);
        if (@abs(wrap.wrap_width - safe_width) <= 0.001) return;
        state.input_inner_w = safe_width;
        wrap.setWrapWidth(safe_width, doc);
        // setWrapWidth only marks lines interpolated; rebuild now so the
        // caller-visible line count / auto height are correct this frame.
        wrap.rebuildAll(doc);
        self.node.setStyle(null, .width, .{ .px = safe_width });
        state.syncMultilineAutoHeight();
        state.updateScrollX();
        self.node.markRenderDirty();
    }

    /// Switch the edited document (a canvas overlay reused for another object):
    /// cancels any composition, writes the value signal and applies it now.
    /// Grapheme-safe truncation applies, undo history is cleared (Cmd+Z must
    /// not restore the previous object's text) and on_change is not invoked.
    /// The buffer always ends up equal to the value source: under `ui.split`
    /// the text goes to the parent's write callback (which decides what lands)
    /// and the buffer follows the landed value.
    pub fn setText(self: EditableTextResult, text: []const u8) usize {
        // composition replaced by this switch (not abandoned): don't emit cancel callback, deferred
        // external value no longer overwrites first
        if (self.state.imeIsComposing()) self.state.supersedeImeComposition();
        // programmatic write (often called in effect, so doesn't hit commit's 'only from events'
        // assert): local / bound directly write signal; split hand to parent's write callback.
        if (self.value) |sig| {
            sig.set(text);
        } else if (self.binding.value.write) |w| {
            w.call(text);
        }
        // Apply immediately (an effect may be deferred inside a batch); a
        // later effect run sees equal content and does nothing.
        self.binding.applyExternal(self.binding.value.peek());
        self.node.markRenderDirty();
        return self.state.getText().len;
    }

    pub fn getText(self: EditableTextResult) []const u8 {
        return self.state.getText();
    }
};

pub fn EditableText(props: anytype) EditableTextBuilder {
    return .{ .props = reactive.props.coerce(EditableTextProps, props) };
}

pub const EditableTextBuilder = struct {
    props: EditableTextProps,

    pub fn mount(self: EditableTextBuilder, scope: *Scope, cx: *Cx) !*Node {
        return (try self.mountResult(scope, cx)).node;
    }

    pub fn mountResult(self: EditableTextBuilder, scope: *Scope, cx: *Cx) !EditableTextResult {
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const props = self.props;
        const font_size = @max(props.font_size, 1);
        const line_height_ratio = @max(props.line_height, 0.1);
        // same source as setMetrics: no ceil, stays pixel-perfect with static text layout.
        const line_height_px = font_size * line_height_ratio;
        const multiline = props.wrap_width != null;
        const wrap_width = @max(props.wrap_width orelse 0, 1);
        const measured = cx.text.measureTextWidth("M", font_size, props.font_weight, false);
        const measured_char_width = if (measured > 0) measured else font_size * 0.6;

        const state = try my_scope.allocator.create(TextInputState);
        var state_registered = false;
        state.* = .{
            .io = cx.io,
        };
        errdefer if (!state_registered) {
            state.deinit();
            my_scope.allocator.destroy(state);
        };
        state.allocator = allocator;
        state.cx_ref = cx;

        if (multiline) {
            const doc = try my_scope.allocator.create(state_mod.TextareaDocument);
            doc.* = state_mod.TextareaDocument.initFallible(my_scope.allocator) catch |err| {
                my_scope.allocator.destroy(doc);
                return err;
            };
            // adoptResource registration fail: **self** call destroyFn (that is its contract): deinit +
            // destroy here again is double-free (test-core's node-tree sweep segfault,
            // `checkWorkspaceWidgetMountFailure(false, true, false)`). just try.
            try my_scope.adoptResource(@ptrCast(doc), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const typed: *state_mod.TextareaDocument = @ptrCast(@alignCast(ptr));
                    typed.deinit();
                    alloc.destroy(typed);
                }
            }.destroy);

            const wrap = try my_scope.allocator.create(state_mod.TextareaWrapMap);
            wrap.* = state_mod.TextareaWrapMap.init(my_scope.allocator, cx.io);
            wrap.measure_ctx_fn = core.Cx.measureTextWidthCallback;
            wrap.measure_ctx = cx;
            wrap.char_width = measured_char_width;
            wrap.precise_wrap = true;
            wrap.font_size = font_size;
            wrap.font_weight = props.font_weight;
            try my_scope.adoptResource(@ptrCast(wrap), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const typed: *state_mod.TextareaWrapMap = @ptrCast(@alignCast(ptr));
                    typed.deinit();
                    alloc.destroy(typed);
                }
            }.destroy);

            state.textarea_doc = doc;
            state.textarea_wrap = wrap;
            state.textarea_max_bytes = editable_block.MAX_INPUT_BYTES;
            state.input_inner_w = wrap_width;
            wrap.setWrapWidth(wrap_width, doc);
            wrap.setEnabled(true, doc);
        }

        const value = try reactive.resolveTextModel(my_scope, props.value);
        if (value.peek().len > 0) _ = try state.setTextChecked(value.peek());
        // Initial props are not an undoable user edit.
        state.clearUndoHistory();
        try my_scope.registerResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const typed: *TextInputState = @ptrCast(@alignCast(ptr));
                typed.deinit();
                alloc.destroy(typed);
            }
        }.destroy);
        state_registered = true;

        // value binding: edit output / composition cancel both via it
        const binding = try my_scope.allocator.create(Binding);
        binding.* = .{ .state = state, .value = value, .on_change = props.on_change };
        try my_scope.adoptResource(@ptrCast(binding), Binding.destroy);
        binding.install();

        const zero_box: core.BoxStyle = .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } };
        const Parts = struct {
            underlay: ?*core.Node = null,
            selection: ?*core.Node = null,
            text: *core.Node = undefined,
            preedit: ?*core.Node = null,
            cursor: *core.Node = undefined,
        };
        var parts: Parts = .{};
        const node = try view.render(my_scope, cx, view.box(.{
            .style = core.BoxStyle{
                .width = if (multiline)
                    .{ .px = wrap_width }
                else if (props.width) |width|
                    .{ .px = width }
                else
                    .{ .grow = .{} },
                .height = .{ .px = if (multiline)
                    @as(f32, @floatFromInt(@max(@as(u32, 1), state.textarea_wrap.?.displayLineCount()))) * line_height_px
                else
                    line_height_px },
                .overflow_hidden = true,
                .min_width = 0,
            },
            .a11y = core.A11yProps{ .role = .textbox, .label = null, .disabled = false, .multiline = multiline },
            .focusable = false,
        }, .{
            // Selection is an underlay so glyphs remain visible over the
            // highlight. It is intentionally separate from the cursor/IME
            // overlay, which must paint above text.
            if (multiline) view.capture(&parts.underlay, view.box(.{ .style = core.BoxStyle{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .position = .absolute,
                .inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } },
                .hit_behavior = .pass_through,
            } }, view.capture(&parts.selection, view.box(.{ .style = zero_box }, {})))) else null,
            // display text node: box style + text properties with spans contract (borrow state's
            // buffer, display sync takes over)
            view.capture(&parts.text, view.setup(view.box(.{ .style = core.BoxStyle{
                .width = if (multiline) .{ .grow = .{} } else .{ .fit = .{} },
                .height = .{ .fit = .{} },
                .align_self = if (multiline) .stretch else .start,
            } }, {}), core.TextProps{
                .content = state.getText(),
                .color = cx.tokens.tokens.color.fg_primary,
                .font_size = font_size,
                .font_weight = props.font_weight,
                .line_height = line_height_ratio,
                .wrap = if (multiline) .word else .none,
                .spans = state.text_spans_buf[0..0],
                .spans_owned = false,
                .spans_affect_layout = false,
            }, setDisplayText)),
            if (multiline) view.capture(&parts.preedit, view.box(.{ .style = zero_box }, {})) else null,
            view.capture(&parts.cursor, view.box(.{ .style = zero_box }, {})),
        }));
        errdefer cx.freeNode(node);
        // view doesn't declare node tag: edit area is input semantic node
        node.tag = .input;
        node.meta.ownership.meta.component_name = "EditableText";
        node.behavior.events.event_context = state;
        try core.bindScopeToNode(my_scope, node);
        scope_bound = true;
        node.addDebugState(@ptrCast(state));

        state_mod.applyEditableBlockConfig(
            state,
            .{ .multiline = multiline, .accept_newline = multiline, .soft_wrap = multiline },
            .{
                .char_width = measured_char_width,
                .font_size = font_size,
                .padding_h = 0,
                .padding_v = 0,
                .line_height = line_height_px,
            },
            null,
            cx,
            cx.tokens,
        );
        state.font_weight = props.font_weight;
        state.multiline_auto_height = multiline;
        state.input_container_node = node;
        state.textarea_overlay_node = parts.underlay;
        state.selection_node = parts.selection;
        state.text_display_node = parts.text;
        state.preedit_underline_node = parts.preedit;
        state.cursor_node = parts.cursor;

        node.behavior.events.on_focus = Cx.simpleHandler(struct {
            fn handler(context: *anyopaque) void {
                const typed: *TextInputState = @ptrCast(@alignCast(context));
                if (typed.editable_click_activation and !typed.editable_editing) {
                    if (typed.cx_ref) |cx_ref| if (typed.input_container_node) |n| applyEditing(cx_ref, n, typed, true);
                }
                typed.focused = true;
                typed.resetBlink();
            }
        }.handler, @ptrCast(state));
        node.behavior.events.on_blur = Cx.simpleHandler(struct {
            fn handler(context: *anyopaque) void {
                const typed: *TextInputState = @ptrCast(@alignCast(context));
                typed.focused = false;
                typed.selection_anchor = null;
                typed.is_dragging = false;
                typed.suspend_drag_until_mouse_up = false;
                typed.cancelImeComposition();
                // `.click` editing ends with focus; `.manual` hosts decide for themselves.
                if (typed.editable_click_activation and typed.editable_editing) {
                    if (typed.cx_ref) |cx_ref| if (typed.input_container_node) |n| applyEditing(cx_ref, n, typed, false);
                }
            }
        }.handler, @ptrCast(state));
        node.meta.per_frame.hooks.before_render.main = render_mod.inputBeforeRender;

        state.editable_click_activation = props.activation == .click;
        node.behavior.events.on_event = if (state.editable_click_activation) clickDisplayEventHandler else null;
        node.setFocusable(state.editable_click_activation);
        state.updateScrollX();
        // value is Model: external write via effect into buffer (first run same as initial value,
        // short-circuit)
        if (props.field_chrome) {
            const t = cx.tokens;
            const pad_y = @max(@as(f32, 0), (t.tokens.size.control_md - line_height_px) / 2);
            state.padding_h = t.tokens.space.space300;
            state.padding_v = pad_y;
            node.setStyle(cx.allocator, .height, .{ .px = node.style.height.px + pad_y * 2 });
            node.setStyle(cx.allocator, .padding, .{ .top = pad_y, .bottom = pad_y });
            node.setStyle(cx.allocator, .overflow_hidden, false);
            const hovered = try @import("../../hooks.zig").useHover(my_scope, node);
            const focused = try @import("../../hooks.zig").useFocusState(my_scope, cx, node);
            try my_scope.createEffect(.{ .node = node, .cx = cx, .hovered = hovered, .focused = focused.focused }, struct {
                // first run is part of the mount: all or nothing, its error fails it
                fn update(c: anytype) error{OutOfMemory}!void {
                    const visual = @import("styles.zig").editableChrome(c.cx.tokens).resolve(.{ .is_hovered = c.hovered.get(), .is_focused = c.focused.get() });
                    try c.node.setStyleInlineFallible(c.cx.allocator, visual);
                }
            }.update);
            try @import("../../hooks.zig").useFocusRing(my_scope, cx, node, .{ .width = t.tokens.border_width.focus, .offset = t.tokens.size.focus_offset, .color = t.tokens.color.focus_ring });
        }
        try my_scope.createEffect(binding, Binding.valueEffect);
        return .{ .node = node, .state = state, .value = value.asSignal(), .binding = binding };
    }
};

fn setDisplayText(props: core.TextProps, node: *core.Node) void {
    node.setText(props);
}

fn applyEditing(cx: *Cx, node: *Node, state: *TextInputState, editing: bool) void {
    if (editing == state.editable_editing) return;
    state.editable_editing = editing;
    if (editing) {
        node.behavior.events.on_event = if (state.editable_click_activation) clickEditingEventHandler else events_mod.inputEventHandler;
        node.behavior.interaction.text_input_client = render_mod.textInputClient(state);
        node.setFocusable(true);
        // Under `.click` this also runs from on_focus, where the node already holds focus.
        if (!cx.isFocused(node)) cx.setFocus(node);
    } else {
        if (cx.isFocused(node)) cx.clearFocus();
        state.focused = false;
        state.cancelImeComposition();
        state.selection_anchor = null;
        state.is_dragging = false;
        state.suspend_drag_until_mouse_up = false;
        node.behavior.events.on_event = if (state.editable_click_activation) clickDisplayEventHandler else null;
        node.behavior.interaction.text_input_client = null;
        // `.click` stays reachable by pointer and Tab at rest: pointer-down focus is decided
        // before dispatch, so a non-focusable target would have its new focus cleared again.
        node.setFocusable(state.editable_click_activation);
    }
    cx.refreshTextInputSession();
    node.markRenderDirty();
}

/// True for every handler whose event context is a `TextInputState` owned by EditableText
/// under `.click` (introspection tools discriminate state types by handler).
pub fn isClickActivationHandler(handler: anytype) bool {
    return handler == clickDisplayEventHandler or handler == clickEditingEventHandler;
}

/// Display mode under `.click`: the press enters editing, then reaches the editing engine so
/// the caret (and any drag selection) starts where the pointer went down.
fn clickDisplayEventHandler(event: core.Event, context: ?*anyopaque) core.EventResult {
    const state: *TextInputState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .mouse_down => |m| if (m.button == .left) {
            const cx = state.cx_ref orelse return .ignored;
            const node = state.input_container_node orelse return .ignored;
            applyEditing(cx, node, state, true);
            return events_mod.inputEventHandler(event, context);
        },
        else => {},
    }
    return .ignored;
}

/// Editing mode under `.click`: Escape and single-line Enter leave editing (outside IME
/// composition, where both belong to the composition); everything else is plain editing.
fn clickEditingEventHandler(event: core.Event, context: ?*anyopaque) core.EventResult {
    const state: *TextInputState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .key_down => |e| if (!state.imeIsComposing() and !e.modifiers.super and !e.modifiers.ctrl and
            (e.key == .escape or (e.key == .@"return" and !state.accept_newline)))
        {
            const cx = state.cx_ref orelse return .ignored;
            const node = state.input_container_node orelse return .ignored;
            applyEditing(cx, node, state, false);
            return .handled;
        },
        else => {},
    }
    return events_mod.inputEventHandler(event, context);
}

// Reference-checked OOM sweep (components/oom_sweep.zig): the field chrome is applied by the
// chrome effect's first run, part of the mount. A mount that reports success must carry it.
test "EditableText(field_chrome): mount 成功即外观完整，任意分配点失败不假成功（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMountVerified("editable_text(field_chrome)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return (try EditableText(.{ .value = "hello", .font_size = 12, .field_chrome = true }).mountResult(scope, cx)).node;
        }
    }.m, struct {
        fn check(root: *Node) anyerror!void {
            try std.testing.expectEqual(@as(f32, 1), root.style.border.width);
            try std.testing.expect(root.style.effectiveRadii()[0] > 0);
        }
    }.check);
}

test "EditableText starts passive and updates runtime metrics" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const root = try core.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    cx.root = root;
    const result = try EditableText(.{ .value = "hello", .font_size = 12 }).mountResult(scope, cx);
    try root.appendChild(cx.allocator, result.node);

    try std.testing.expect(result.node.behavior.events.on_event == null);
    try std.testing.expectEqualStrings("hello", result.getText());
    const advance_before = result.state.visualCursorAdvance();
    result.setMetrics(24, 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 24), result.state.font_size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 36), result.state.line_height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 36), result.node.style.height.px, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), result.state.text_display_node.?.getText().?.font_size, 0.001);
    try std.testing.expect(result.state.visualCursorAdvance() > advance_before * 1.9);
}

test "EditableText editing mode owns focus and detaches the input handler" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{}).mountResult(scope, cx);
    cx.root = result.node;
    result.setEditing(cx, true);
    try std.testing.expect(result.node.behavior.events.on_event != null);
    try std.testing.expect(result.node.behavior.interaction.focusable);
    try std.testing.expect(cx.isFocused(result.node));
    try std.testing.expect(result.state.focused);

    result.state.setImePreedit("kana", 4);
    result.state.selection_anchor = 0;
    result.setEditing(cx, false);
    try std.testing.expect(result.node.behavior.events.on_event == null);
    try std.testing.expect(!result.node.behavior.interaction.focusable);
    try std.testing.expect(!cx.isFocused(result.node));
    try std.testing.expect(!result.state.focused);
    try std.testing.expect(!result.state.imeIsComposing());
    try std.testing.expect(result.state.selection_anchor == null);
}

test "EditableText click activation: press enters editing, Enter / Escape / blur leave it" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "title", .activation = .click }).mountResult(scope, cx);
    cx.root = result.node;
    const events = &result.node.behavior.events;
    // Display mode receives the press and is focusable (pointer-down focus is decided before
    // dispatch), but does not edit.
    try std.testing.expect(events.on_event != null);
    try std.testing.expect(result.node.behavior.interaction.focusable);
    try std.testing.expectEqual(core.EventResult.ignored, events.on_event.?(.{ .text_input = .{ .text = "x" } }, events.event_context));
    try std.testing.expectEqualStrings("title", result.getText());

    _ = events.on_event.?(.{ .mouse_down = .{ .x = 0, .y = 0 } }, events.event_context);
    _ = events.on_event.?(.{ .mouse_up = .{ .x = 0, .y = 0 } }, events.event_context);
    try std.testing.expect(result.state.editable_editing);
    try std.testing.expect(cx.isFocused(result.node));
    _ = events.on_event.?(.{ .key_down = .{ .key = .end, .modifiers = .{} } }, events.event_context);
    _ = events.on_event.?(.{ .text_input = .{ .text = " 2" } }, events.event_context);
    try std.testing.expectEqualStrings("title 2", result.getText());

    try std.testing.expectEqual(core.EventResult.handled, events.on_event.?(.{ .key_down = .{ .key = .@"return", .modifiers = .{} } }, events.event_context));
    try std.testing.expect(!result.state.editable_editing);
    try std.testing.expect(!cx.isFocused(result.node));
    try std.testing.expectEqualStrings("title 2", result.getText());

    _ = events.on_event.?(.{ .mouse_down = .{ .x = 0, .y = 0 } }, events.event_context);
    _ = events.on_event.?(.{ .mouse_up = .{ .x = 0, .y = 0 } }, events.event_context);
    try std.testing.expect(result.state.editable_editing);
    _ = events.on_event.?(.{ .key_down = .{ .key = .escape, .modifiers = .{} } }, events.event_context);
    try std.testing.expect(!result.state.editable_editing);

    _ = events.on_event.?(.{ .mouse_down = .{ .x = 0, .y = 0 } }, events.event_context);
    _ = events.on_event.?(.{ .mouse_up = .{ .x = 0, .y = 0 } }, events.event_context);
    try std.testing.expect(result.state.editable_editing);
    cx.clearFocus();
    try std.testing.expect(!result.state.editable_editing);
    try std.testing.expect(result.node.behavior.interaction.focusable);

    // Keyboard focus enters editing too.
    cx.setFocus(result.node);
    try std.testing.expect(result.state.editable_editing);
    try std.testing.expect(cx.isFocused(result.node));
    _ = events.on_event.?(.{ .text_input = .{ .text = "!" } }, events.event_context);
    try std.testing.expect(std.mem.endsWith(u8, result.getText(), "!"));
}

test "EditableText programmatic text switch clears IME and prior undo history" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "first" }).mountResult(scope, cx);
    cx.root = result.node;
    result.state.insertText(" edit");
    try std.testing.expect(result.state.undo_count > 0);
    result.state.setImePreedit("中", 3);

    try std.testing.expectEqual(@as(usize, 6), result.setText("second"));
    try std.testing.expectEqualStrings("second", result.getText());
    try std.testing.expect(!result.state.imeIsComposing());
    try std.testing.expectEqual(@as(u8, 0), result.state.undo_count);
    try std.testing.expectEqual(@as(u8, 0), result.state.redo_count);

    result.state.undo();
    try std.testing.expectEqualStrings("second", result.getText());
}

test "EditableText initial value truncates only at a grapheme boundary" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    var value: [editable_block.MAX_INPUT_BYTES + 4]u8 = undefined;
    @memset(value[0 .. editable_block.MAX_INPUT_BYTES - 4], 'x');
    @memcpy(value[editable_block.MAX_INPUT_BYTES - 4 ..], "👍🏽");
    const result = try EditableText(.{ .value = &value }).mountResult(scope, cx);
    cx.root = result.node;
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.getText()));
    try std.testing.expectEqual(editable_block.MAX_INPUT_BYTES - 4, result.getText().len);
}

test "EditableText wrap_width mounts shell-free multiline document with auto height" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{
        .value = "abcdefghij",
        .font_size = 10,
        .line_height = 1.5,
        .width = 400,
        .wrap_width = 24,
    }).mountResult(scope, cx);
    cx.root = result.node;

    const wrap = result.state.textarea_wrap orelse return error.TestExpectedEqual;
    try std.testing.expect(result.state.textarea_doc != null);
    try std.testing.expect(result.state.multiline);
    try std.testing.expect(result.state.soft_wrap);
    try std.testing.expect(result.state.accept_newline);
    try std.testing.expect(result.state.multiline_auto_height);
    try std.testing.expect(result.node.behavior.interaction.a11y.?.multiline);
    try std.testing.expectApproxEqAbs(@as(f32, 24), result.node.style.width.px, 0.001);
    try std.testing.expect(wrap.displayLineCount() > 1);
    const expected_height = @as(f32, @floatFromInt(wrap.displayLineCount())) * result.state.line_height;
    try std.testing.expectApproxEqAbs(expected_height, result.node.style.height.px, 0.001);
    try std.testing.expectEqual(core.TextWrap.word, result.state.text_display_node.?.getText().?.wrap);
    try std.testing.expect(core.Color.eql(result.node.getBackground(), core.Color.TRANSPARENT));
    try std.testing.expectEqual(@as(f32, 0), result.node.style.border.width);
}

test "EditableText multiline hit testing and keyboard navigation use display lines" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{
        .value = "abcdefghij",
        .font_size = 10,
        .wrap_width = 24,
    }).mountResult(scope, cx);
    cx.root = result.node;
    result.node.setLayoutRect(.{ .x = 0, .y = 0, .w = 24, .h = result.node.style.height.px });
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);

    const doc = result.state.textarea_doc.?;
    const wrap = result.state.textarea_wrap.?;
    try std.testing.expect(wrap.displayLineCount() >= 2);
    const second = wrap.displayLineInfo(1, doc);
    const second_start = doc.getLineStart(second.buffer_line) + second.byte_start;
    const hit = result.state.hitTestCursorPosAt(0, result.state.line_height + 1);
    try std.testing.expectEqual(second_start, hit);

    result.state.cursor_pos = 0;
    try std.testing.expect(result.state.handleKeyDown(.down, .{}));
    const moved = doc.offsetToLineCol(result.state.cursor_pos);
    try std.testing.expectEqual(@as(u32, 1), wrap.bufferToDisplay(moved.line, moved.col).display_line);

    result.state.selection_anchor = 0;
    result.state.cursor_pos = second_start;
    result.state.focused = true;
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);
    try std.testing.expect(result.state.selection_node.?.rectFromWorldOrFallback().w > 0);
}

test "EditableText multiline IME commit and undo share the document engine" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "ab", .wrap_width = 60 }).mountResult(scope, cx);
    cx.root = result.node;
    result.node.setLayoutRect(.{ .x = 0, .y = 0, .w = 60, .h = result.node.style.height.px });
    result.state.cursor_pos = 1;
    result.state.handleImePreeditEvent("中", 3);
    result.state.focused = true;
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);

    try std.testing.expect(result.state.imeIsComposing());
    try std.testing.expect(std.mem.indexOf(u8, result.state.text_display_node.?.getText().?.content, "中") != null);
    try std.testing.expect(result.state.preedit_underline_node.?.rectFromWorldOrFallback().w > 0);

    result.state.handleImeCommitEvent("中");
    result.state.updateScrollX();
    try std.testing.expectEqualStrings("a中b", result.getText());
    try std.testing.expect(result.state.ta_undo_count > 0);
    result.state.undo();
    try std.testing.expectEqualStrings("ab", result.getText());
    result.state.redo();
    try std.testing.expectEqualStrings("a中b", result.getText());
}

test "EditableText multiline runtime metrics rewrap and programmatic switch clears history" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "one two three four", .font_size = 10, .wrap_width = 70 }).mountResult(scope, cx);
    cx.root = result.node;
    const lines_before = result.state.textarea_wrap.?.displayLineCount();
    result.setMetrics(20, 1.5);
    const lines_after = result.state.textarea_wrap.?.displayLineCount();
    try std.testing.expect(lines_after >= lines_before);
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(lines_after)) * 30,
        result.node.style.height.px,
        0.001,
    );

    result.state.insertText("!");
    try std.testing.expect(result.state.ta_undo_count > 0);
    try std.testing.expectEqual(@as(usize, 6), result.setText("second"));
    try std.testing.expectEqual(@as(u8, 0), result.state.ta_undo_count);
    try std.testing.expectEqual(@as(u8, 0), result.state.ta_redo_count);
    result.state.undo();
    try std.testing.expectEqualStrings("second", result.getText());

    result.setEditing(cx, true);
    result.state.handleImePreeditEvent("仮", 3);
    result.setEditing(cx, false);
    try std.testing.expect(!result.state.imeIsComposing());
    try std.testing.expect(result.state.selection_anchor == null);
}

test "EditableText setWrapWidth rewraps at runtime and resizes node" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{
        .value = "one two three four five six",
        .font_size = 10,
        .wrap_width = 200,
    }).mountResult(scope, cx);
    cx.root = result.node;
    const wide_lines = result.state.textarea_wrap.?.displayLineCount();

    result.setWrapWidth(40);
    const narrow_lines = result.state.textarea_wrap.?.displayLineCount();
    try std.testing.expect(narrow_lines > wide_lines);
    try std.testing.expectApproxEqAbs(@as(f32, 40), result.node.style.width.px, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), result.state.input_inner_w, 0.001);
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(narrow_lines)) * result.state.line_height,
        result.node.style.height.px,
        0.001,
    );

    // reflow: line count falls back, repeated same width is no-op
    result.setWrapWidth(200);
    try std.testing.expectEqual(wide_lines, result.state.textarea_wrap.?.displayLineCount());
    result.setWrapWidth(200);
    try std.testing.expectApproxEqAbs(@as(f32, 200), result.node.style.width.px, 0.001);
}

test "EditableText setWrapWidth is a no-op on single-line editors" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "hello", .width = 120 }).mountResult(scope, cx);
    cx.root = result.node;
    result.setWrapWidth(40);
    try std.testing.expectApproxEqAbs(@as(f32, 120), result.node.style.width.px, 0.001);
    try std.testing.expect(result.state.textarea_wrap == null);
}

test "EditableText multiline Return inserts a hard line and grows height" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "a", .wrap_width = 200 }).mountResult(scope, cx);
    cx.root = result.node;
    const height_before = result.node.style.height.px;
    const handled = events_mod.inputEventHandler(.{ .key_down = .{ .key = .@"return" } }, @ptrCast(result.state));

    try std.testing.expect(handled == .handled);
    try std.testing.expectEqualStrings("a\n", result.getText());
    try std.testing.expectEqual(@as(u32, 2), result.state.textarea_wrap.?.displayLineCount());
    try std.testing.expect(result.node.style.height.px > height_before);
    try std.testing.expectApproxEqAbs(result.state.line_height * 2, result.node.style.height.px, 0.001);
}

test "EditableText renders text typed after a hard newline" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 160);
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "first line", .wrap_width = 280 }).mountResult(scope, cx);
    cx.root = result.node;
    result.setEditing(cx, true);
    cx.layout();
    _ = cx.render();

    const returned = events_mod.inputEventHandler(.{ .key_down = .{ .key = .@"return" } }, @ptrCast(result.state));
    try std.testing.expect(returned == .handled);
    result.state.insertText("second line");
    result.state.updateScrollX();
    _ = cx.render();

    try std.testing.expectEqualStrings("first line\nsecond line", result.getText());
    try std.testing.expectEqualStrings(result.getText(), result.state.text_display_node.?.getText().?.content);
    const layout = result.state.text_display_node.?.layoutTextLayout() orelse
        return error.TestExpectedEqual;
    var laid_out_second_line = false;
    for (layout.lines[0..layout.line_count]) |line| {
        if (line.byte_end > "first line\n".len and line.width > 0) laid_out_second_line = true;
    }
    try std.testing.expect(laid_out_second_line);
    var painted_second_line = false;
    for (cx.text_blob_store.blobs.items) |blob| {
        for (cx.text_blob_store.lines(blob)) |line| {
            if (line.byte_end > "first line\n".len and line.width > 0) painted_second_line = true;
        }
    }
    try std.testing.expect(painted_second_line);
}

test "EditableText renders and positions the caret after consecutive hard newlines" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(500, 300);
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    // Match the canvas integration: a retained row wrapper whose fit height is
    // driven by a shell-free multiline editor.
    const wrapper = try core.box(cx, .{
        .width = .{ .px = 367 },
        .direction = .row,
    }, .{});
    const result = try EditableText(.{ .wrap_width = 367 }).mountResult(scope, cx);
    try wrapper.appendChild(cx.allocator, result.node);
    cx.root = wrapper;
    result.setEditing(cx, true);
    result.setMetrics(42, 1.25);
    result.setWrapWidth(367);
    cx.layout();
    _ = cx.render();

    inline for (.{ "first line", "\n", "second line", "\n", "third line" }) |input| {
        const event: core.Event = if (std.mem.eql(u8, input, "\n"))
            .{ .key_down = .{ .key = .@"return" } }
        else
            .{ .text_input = .{ .text = input } };
        try std.testing.expect(events_mod.inputEventHandler(event, @ptrCast(result.state)) == .handled);
        // The native harness/app paints between input events. This is the
        // sequence that exposed a retained layout surviving the second Return.
        _ = cx.render();
    }

    const expected = "first line\nsecond line\nthird line";
    try std.testing.expectEqualStrings(expected, result.getText());
    try std.testing.expectEqual(@as(usize, 3), result.state.textarea_doc.?.lineCount());
    try std.testing.expectEqual(@as(u32, 3), result.state.textarea_wrap.?.displayLineCount());
    try std.testing.expectApproxEqAbs(result.state.line_height * 3, result.node.style.height.px, 0.001);

    const layout = result.state.text_display_node.?.layoutTextLayout() orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 3), layout.line_count);
    var laid_out_third_line = false;
    for (layout.lines[0..layout.line_count]) |line| {
        if (line.byte_end > "first line\nsecond line\n".len and line.width > 0) laid_out_third_line = true;
    }
    try std.testing.expect(laid_out_third_line);
    try std.testing.expect(result.state.cursor_node.?.rectFromWorldOrFallback().y >= result.state.line_height * 2);
}

test "EditableText single-line selection span honors host color overrides" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "hello", .width = 120 }).mountResult(scope, cx);
    cx.root = result.node;
    result.node.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = result.node.style.height.px });
    result.state.selection_anchor = 0;
    result.state.cursor_pos = 5;
    result.state.focused = true;

    // default: use tokens selection_bg, fg inherited (span.color == null)
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);
    var spans = result.state.text_display_node.?.getText().?.spans;
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(core.Color.eql(spans[0].bg_color.?, result.state.tokens.tokens.color.selection_bg));
    try std.testing.expect(spans[0].color == null);

    // override: saturated bottom + inverted text
    result.state.selection_bg_override = core.Color.hex(0x2F5BFF);
    result.state.selection_fg_override = core.Color.hex(0xFFFFFF);
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);
    spans = result.state.text_display_node.?.getText().?.spans;
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(core.Color.eql(spans[0].bg_color.?, core.Color.hex(0x2F5BFF)));
    try std.testing.expect(core.Color.eql(spans[0].color.?, core.Color.hex(0xFFFFFF)));
}

test "EditableText multiline preedit wrapping moves caret and expands transient height" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "abc", .font_size = 10, .wrap_width = 25 }).mountResult(scope, cx);
    cx.root = result.node;
    const committed_lines = result.state.textarea_wrap.?.displayLineCount();
    result.node.setLayoutRect(.{ .x = 0, .y = 0, .w = 25, .h = result.node.style.height.px });
    result.state.focused = true;
    result.state.cursor_pos = result.getText().len;
    result.state.handleImePreeditEvent("中中中中", 12);
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);

    try std.testing.expect(result.state.ime_visual_valid);
    try std.testing.expect(result.state.ime_visual_total_lines > committed_lines);
    try std.testing.expect(result.state.ime_visual_display_line > 0);
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(result.state.ime_visual_total_lines)) * result.state.line_height,
        result.node.style.height.px,
        0.001,
    );
    try std.testing.expect(result.state.cursor_node.?.rectFromWorldOrFallback().y >= result.state.line_height);
    try std.testing.expect(result.state.preedit_underline_node.?.rectFromWorldOrFallback().y >= result.state.line_height);

    result.state.cancelImeComposition();
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);
    try std.testing.expectEqual(committed_lines, result.state.textarea_wrap.?.displayLineCount());
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(committed_lines)) * result.state.line_height,
        result.node.style.height.px,
        0.001,
    );
}

test "EditableText value: 打字写回 signal；外部写入进缓冲且清撤销" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const v = try scope.createText("ab", .{});
    const result = try EditableText(.{ .value = v }).mountResult(scope, cx);
    cx.root = result.node;
    result.setEditing(cx, true);
    _ = events_mod.inputEventHandler(.{ .text_input = .{ .text = "c" } }, @ptrCast(result.state));
    try std.testing.expectEqualStrings("abc", v.peek());
    v.set("other object");
    try std.testing.expectEqualStrings("other object", result.getText());
    try std.testing.expectEqual(@as(u8, 0), result.state.undo_count);
}

test "EditableText setText: 组字中切换文档也立即生效，并写回数据源" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const v = try scope.createText("first", .{});
    const result = try EditableText(.{ .value = v }).mountResult(scope, cx);
    cx.root = result.node;
    result.state.setImePreedit("中", 3);
    try std.testing.expect(result.state.imeIsComposing());
    // in batch: value effect deferred, setText still must swap buffer immediately
    cx.owner.beginBatch();
    _ = result.setText("second");
    try std.testing.expectEqualStrings("second", result.getText());
    cx.owner.endBatch();
    try std.testing.expectEqualStrings("second", v.peek());
    try std.testing.expect(!result.state.imeIsComposing());
}

test "EditableText setText: split 下交给父组件裁决，缓冲跟随落地值" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const Parent = struct {
        sig: *Signal([]const u8),
        accept: bool = true,
        buf: [64]u8 = undefined,
        fn write(self: *@This(), x: []const u8) void {
            if (!self.accept) return;
            const n = @min(x.len, self.buf.len);
            for (x[0..n], 0..) |c, i| self.buf[i] = std.ascii.toUpper(c);
            self.sig.set(self.buf[0..n]);
        }
    };
    var parent = Parent{ .sig = try scope.createText("first", .{}) };
    const result = try EditableText(.{
        .value = reactive.split(parent.sig, cx.on(Parent, &parent, Parent.write)),
    }).mountResult(scope, cx);
    cx.root = result.node;

    // parent rewrites: buffer is settled value, not passed value
    _ = result.setText("second");
    try std.testing.expectEqualStrings("SECOND", parent.sig.peek());
    try std.testing.expectEqualStrings("SECOND", result.getText());
    // parent rejects: buffer stays at data source's current value
    parent.accept = false;
    _ = result.setText("third");
    try std.testing.expectEqualStrings("SECOND", parent.sig.peek());
    try std.testing.expectEqualStrings("SECOND", result.getText());
}

test "EditableText multiline value: split 改写 / 拒绝就地修正（文档引擎路径），撤销自洽" {
    inline for (.{ false, true }) |batched| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        const scope = try Scope.init(std.testing.allocator, null, cx.owner);
        defer scope.dispose();
        const Parent = struct {
            sig: *Signal([]const u8),
            accept: bool = true,
            buf: [128]u8 = undefined,
            fn write(self: *@This(), x: []const u8) void {
                if (!self.accept) return;
                const n = @min(x.len, self.buf.len);
                for (x[0..n], 0..) |c, i| self.buf[i] = std.ascii.toUpper(c);
                self.sig.set(self.buf[0..n]);
            }
        };
        var parent = Parent{ .sig = try scope.createText("AB\nCD", .{}) };
        const result = try EditableText(.{
            .value = reactive.split(parent.sig, cx.on(Parent, &parent, Parent.write)),
            .wrap_width = 200,
        }).mountResult(scope, cx);
        cx.root = result.node;
        const s = result.state;
        try std.testing.expect(s.textarea_doc != null);
        s.cursor_pos = 4;
        s.syncDocFromCursor();

        // new undo unit opened rejected by parent: pushed snapshot must pop
        parent.accept = false;
        _ = events_mod.inputEventHandler(.{ .text_input = .{ .text = "q" } }, @ptrCast(s));
        try std.testing.expectEqualStrings("AB\nCD", result.getText());
        try std.testing.expectEqual(@as(usize, 4), s.cursor_pos);
        try std.testing.expectEqual(@as(u8, 0), s.ta_undo_count);
        parent.accept = true;

        if (batched) cx.owner.beginBatch();
        _ = events_mod.inputEventHandler(.{ .text_input = .{ .text = "x" } }, @ptrCast(s));
        try std.testing.expectEqualStrings("AB\nCXD", result.getText());
        try std.testing.expectEqual(@as(usize, 5), s.cursor_pos);
        try std.testing.expectEqual(@as(usize, 5), s.textarea_cursor.offset);
        if (batched) cx.owner.endBatch();
        try std.testing.expectEqualStrings("AB\nCXD", parent.sig.peek());
        try std.testing.expectEqual(@as(u8, 1), s.ta_undo_count);

        parent.accept = false;
        _ = events_mod.inputEventHandler(.{ .text_input = .{ .text = "q" } }, @ptrCast(s));
        try std.testing.expectEqualStrings("AB\nCXD", result.getText());
        try std.testing.expectEqual(@as(usize, 5), s.cursor_pos);
        try std.testing.expectEqual(@as(u8, 1), s.ta_undo_count);
        parent.accept = true;

        _ = events_mod.inputEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true } } }, @ptrCast(s));
        try std.testing.expectEqualStrings("AB\nCD", result.getText());
        try std.testing.expectEqual(@as(usize, 4), s.cursor_pos);
        try std.testing.expectEqualStrings("AB\nCD", parent.sig.peek());
    }
}

test "EditableText multiline value: split 拒绝——文档引擎的重做栈与淘汰条目完整还原" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const Parent = struct {
        sig: *Signal([]const u8),
        fn write(self: *@This(), x: []const u8) void {
            for (x) |c| if (std.ascii.isLower(c)) return;
            self.sig.set(x);
        }
    };
    var parent = Parent{ .sig = try scope.createText("A", .{}) };
    const result = try EditableText(.{
        .value = reactive.split(parent.sig, cx.on(Parent, &parent, Parent.write)),
        .wrap_width = 400,
    }).mountResult(scope, cx);
    cx.root = result.node;
    const s = result.state;
    s.cursor_pos = 1;
    s.syncDocFromCursor();
    const send = struct {
        fn f(st: *TextInputState, ev: core.Event) void {
            _ = events_mod.inputEventHandler(ev, @ptrCast(st));
        }
    }.f;
    const undo = core.Event{ .key_down = .{ .key = .z, .modifiers = .{ .super = true } } };
    const redo = core.Event{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = true } } };

    send(s, .{ .text_input = .{ .text = "B" } });
    send(s, undo);
    try std.testing.expectEqual(@as(u8, 1), s.ta_redo_count);
    const redo_ptr = s.ta_redo[0].text.?.ptr;
    send(s, .{ .text_input = .{ .text = "c" } });
    try std.testing.expectEqualStrings("A", result.getText());
    try std.testing.expectEqual(@as(u8, 1), s.ta_redo_count);
    try std.testing.expectEqual(redo_ptr, s.ta_redo[0].text.?.ptr);
    send(s, redo);
    try std.testing.expectEqualStrings("AB", result.getText());

    const cap = TextInputState.UNDO_CAPACITY;
    while (s.ta_undo_count < cap) send(s, .{ .text_input = .{ .text = " " } });
    send(s, .{ .text_input = .{ .text = " " } });
    const bottom_ptr = s.ta_undo[0].text.?.ptr;
    const top_ptr = s.ta_undo[cap - 1].text.?.ptr;
    const len_before = result.getText().len;
    send(s, .{ .text_input = .{ .text = "z" } });
    try std.testing.expectEqual(len_before, result.getText().len);
    try std.testing.expectEqual(@as(u8, @intCast(cap)), s.ta_undo_count);
    try std.testing.expectEqual(bottom_ptr, s.ta_undo[0].text.?.ptr);
    try std.testing.expectEqual(top_ptr, s.ta_undo[cap - 1].text.?.ptr);
    try std.testing.expect(s.ta_undo_stash.isEmpty());

    send(s, undo);
    try std.testing.expectEqual(@as(u8, 1), s.ta_redo_count);
    send(s, .{ .text_input = .{ .text = "Q" } });
    try std.testing.expectEqual(@as(u8, 0), s.ta_redo_count);
    send(s, .{ .text_input = .{ .text = "q" } });
    try std.testing.expectEqual(@as(u8, 0), s.ta_redo_count);
}

test "EditableText multiline value: 组字中有推迟的外部写入时，AX 写值以 AX 的值为准（文档引擎路径）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const v = try scope.createText("old", .{});
    const result = try EditableText(.{ .value = v, .wrap_width = 300 }).mountResult(scope, cx);
    cx.root = result.node;
    result.node.setLayoutRect(.{ .x = 0, .y = 0, .w = 300, .h = result.node.style.height.px });
    result.state.focused = true;
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);
    const editable = result.node.behavior.interaction.a11y.?.editable_text.?;
    _ = events_mod.inputEventHandler(.{ .ime_preedit = .{ .text = "ni", .cursor_utf8_offset = 2 } }, @ptrCast(result.state));
    v.set("external");
    try std.testing.expectEqualStrings("old", result.getText());
    try std.testing.expect(editable.set_value.?(editable.context, "typed"));
    try std.testing.expectEqualStrings("typed", result.getText());
    try std.testing.expectEqualStrings("typed", v.peek());
    try std.testing.expect(!result.state.imeIsComposing());
}

test "EditableText multiline: AX 写入超过上限的值在改动前拒绝（不能改完缓冲再报失败）" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const v = try scope.createText("keep", .{});
    const result = try EditableText(.{ .value = v, .wrap_width = 300 }).mountResult(scope, cx);
    cx.root = result.node;
    result.node.setLayoutRect(.{ .x = 0, .y = 0, .w = 300, .h = result.node.style.height.px });
    result.state.focused = true;
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);
    const editable = result.node.behavior.interaction.a11y.?.editable_text.?;
    const too_long = (@as([("x").len * ((editable_block.MAX_INPUT_BYTES + 1))]u8, @bitCast(@as([(editable_block.MAX_INPUT_BYTES + 1)][("x").len]u8, @splat(("x").*)))) ++ "");
    try std.testing.expect(!editable.set_value.?(editable.context, too_long));
    try std.testing.expectEqualStrings("keep", result.getText());
    try std.testing.expectEqualStrings("keep", v.peek());
    try std.testing.expectEqual(@as(u8, 0), result.state.ta_undo_count);
}
