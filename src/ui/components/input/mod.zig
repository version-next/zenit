/// Input component, facade.
///
/// Text input component: keyboard input, cursor navigation, focus management.
///
/// Features:
/// - Keyboard: text_input event, arrow key navigation
/// - Edit: backspace, delete, Cmd+A select all
/// - Focus: auto focusable register, focus/blur events
/// - State: Scope manages TextInputState lifetime
/// - Labels and helper text
/// - Error state
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const recipe_mod = @import("../../recipe.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Signal = core.Signal;
const createEffect = core.createEffect;
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const hooks = @import("../../hooks.zig");
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Model = reactive.Model;
const Source = reactive.Source;
const Handler = core.Handler;
const editable_block = @import("../editable_block/mod.zig");
const control_shell = @import("../control_shell/mod.zig");
const svg_assets = @import("../../svg_assets.zig");

// ========== Sub-module imports ==========
const state_mod = @import("state.zig");
const render_mod = @import("render.zig");
const events_mod = @import("events.zig");
const styles = @import("styles.zig");
const textarea_mod = @import("textarea.zig");
const binding_mod = @import("binding.zig");
const editable_text_mod = @import("editable_text.zig");

// ========== Public re-exports ==========
pub const TextInputState = state_mod.TextInputState;
pub const UndoSnapshot = editable_block.UndoSnapshot;
pub const InputType = editable_block.InputType;
pub const InputSize = control_shell.ControlSize;
pub const TextareaState = textarea_mod.TextareaState;
pub const inputEventHandler = events_mod.inputEventHandler;
pub const EditableText = editable_text_mod.EditableText;
pub const EditableTextResult = editable_text_mod.EditableTextResult;
pub const EditableTextProps = editable_text_mod.EditableTextProps;
pub const isEditableTextClickHandler = editable_text_mod.isClickActivationHandler;
pub const textareaEventHandler = textarea_mod.textareaEventHandler;

/// The edit state behind a field node (its on_event context), told apart by the handler the
/// input module installed. Tools that inspect a field (test harness, devtools) go through this
/// instead of comparing handler identities themselves.
pub const EditState = union(enum) { input: *TextInputState, textarea: *TextareaState };

pub fn editStateOf(node: *const Node) ?EditState {
    const context = node.behavior.events.event_context orelse return null;
    const handler = node.behavior.events.on_event orelse return null;
    if (handler == events_mod.inputEventHandler or handler == events_mod.inputFieldEventHandler or editable_text_mod.isClickActivationHandler(handler))
        return .{ .input = @ptrCast(@alignCast(context)) };
    if (handler == textarea_mod.textareaEventHandler or handler == textarea_mod.textareaFieldEventHandler)
        return .{ .textarea = @ptrCast(@alignCast(context)) };
    return null;
}

// Re-export text_utils for external consumers
pub const text_utils = @import("text_utils.zig");

/// Input properties
pub const InputProps = struct {
    /// Text value. Literal = component-owned initial; `*Signal([]const u8)` = controlled
    /// (interaction
    /// writes directly), create via `scope.createText` (owning); `ui.split` parent intercepts.
    /// External write: same content doesn't move the cursor, else replace all, cursor to end, undo
    /// history cleared; during composition it is deferred until complete (commit discards it - user
    /// input wins, cancel applies); bypasses input_type filter, doesn't fire on_change.
    /// Non-growable buffer limit 2048 bytes, excess truncated.
    value: Model([]const u8) = .{ .local = "" },
    growable: bool = false,
    /// Placeholder ("" = none; can pass signal)
    placeholder: Source([]const u8) = .{ .value = "" },
    /// Placeholder text color override
    placeholder_color: ?Color = null,
    /// Input type
    input_type: InputType = .text,
    /// Size (unified ControlSize, default md; outer height = padding_y*2 + font_size*line_height,
    /// default theme xs=20/sm=24/md=32/lg=40)
    size: InputSize = .md,
    /// Label ("" = none; can pass signal, hidden when empty)
    label_text: Source([]const u8) = .{ .value = "" },
    /// Helper text ("" = none)
    helper: Source([]const u8) = .{ .value = "" },
    /// Error message ("" = no error; non-empty enters error state, replaces helper)
    error_msg: Source([]const u8) = .{ .value = "" },
    /// Validation supplied by a form wrapper that owns its helper/error message.
    invalid: Source(bool) = .{ .value = false },
    /// Required
    required: bool = false,
    /// Readonly
    readonly: bool = false,
    /// Disabled (can pass signal)
    disabled: Source(bool) = .{ .value = false },
    /// Width
    width: ?f32 = null,
    /// Left icon
    leading_icon_asset: ?svg_assets.Asset = null,
    /// Right append text (e.g. count)
    append_text: ?[]const u8 = null,
    /// Right append icon (e.g. clear / eye)
    append_icon_asset: ?svg_assets.Asset = null,
    /// When embedded in compound control, keep only text editing, parent draws unified shell.
    /// Select/ComboBox use to avoid double border/focus ring.
    embedded: bool = false,
    /// Compound field expanded state (e.g. ComboBox popup), retains accent border while open.
    expanded: Source(bool) = .{ .value = false },
    /// Raised field contact shadow; regular text inputs remain flat.
    raised: bool = false,
    /// The caller's overrides on the field (the framed node, `InputResult.input_container`):
    /// e.g. a toolbar field's height, corner radius or fixed border color. Merged over the size
    /// recipe and over every frame state (hover / focus / invalid / disabled), like
    /// `Button.base_style` on a button. Writing those fields on the field node after mount
    /// does not stick: the frame states re-apply on their next change.
    field_style: core.StyleOverride = .{},
    /// Called after user edit committed (committed value; slice valid during callback only)
    on_change: ?Handler([]const u8) = null,
    /// Single-line Enter (non-composition): current text. Unset, Enter bubbles to parent
    on_submit: ?Handler([]const u8) = null,
};

/// Create input: `W.Input(.{ .value = name, .placeholder = "Your name", .on_submit = cx.on(S, s,
/// S.go) })`
pub fn Input(props: anytype) InputBuilder {
    return .{ .props = reactive.props.coerce(InputProps, props) };
}

/// Input value binding (see binding.zig)
pub const InputBinding = binding_mod.TextBinding(TextInputState);

/// Input surround dynamic parts (scope-owned): label / helper & error text / placeholder /
/// disabled. All static, no effect (synced on mount).
pub const InputChrome = struct {
    state: *TextInputState,
    cx: *Cx,
    tokens: *const core.ThemeTokens,
    label: Source([]const u8),
    helper: Source([]const u8),
    error_msg: Source([]const u8),
    placeholder: Source([]const u8),
    disabled: Source(bool),
    wrapper: *Node,
    input_container: *Node,
    label_row: ?*Node = null,
    label_node: ?*Node = null,
    helper_node: ?*Node = null,
    leading_icon: ?*Node = null,
    append_icon: ?*Node = null,
    /// Owned copy of dynamic placeholder (state.placeholder_text / a11y borrows)
    placeholder_copy: []u8 = &.{},
    invalid: Source(bool),
    /// Frame invalid state (the shell's :invalid) = invalid prop or a non-empty error message.
    invalid_frame: *Signal(bool),
    /// Leading / append icon tone (disabled > invalid > normal).
    icon_tone: *Signal(styles.IconTone),
    shown_disabled: bool = false,

    fn effect(self: *InputChrome) void {
        self.apply(true) catch |err| std.log.err("[Input] updating chrome failed: {}", .{err});
    }

    fn apply(self: *InputChrome, comptime tracked: bool) !void {
        const a = self.cx.allocator;
        if (self.label_node) |ln| {
            const text = self.label.read(tracked);
            if (!std.mem.eql(u8, ln.getText().?.content, text)) try ln.setTextContent(a, text);
            self.label_row.?.setDisplay(if (text.len > 0) .flex else .none);
            if (self.input_container.behavior.interaction.a11y) |*attrs| attrs.label = ln.getText().?.content;
        }
        if (!self.placeholder.isStatic()) {
            const ph = self.placeholder.read(tracked);
            if (!std.mem.eql(u8, self.placeholder_copy, ph)) {
                const copy = try a.dupe(u8, ph);
                a.free(self.placeholder_copy);
                self.placeholder_copy = copy;
                self.state.placeholder_text = if (copy.len > 0) copy else null;
                if (self.input_container.behavior.interaction.a11y) |*attrs| attrs.placeholder = self.state.placeholder_text;
                self.state.dirty = true;
                self.input_container.markRenderDirty();
            }
        }
        const err_text = self.error_msg.read(tracked);
        const help_text = self.helper.read(tracked);
        const has_error = self.invalid.read(tracked) or err_text.len > 0;
        if (has_error != self.state.has_error) {
            self.state.has_error = has_error;
            self.invalid_frame.set(has_error);
            if (self.input_container.behavior.interaction.a11y) |*attrs| attrs.invalid = has_error;
            self.state.dirty = true;
        }
        if (self.helper_node) |hn| {
            const shown = if (has_error) err_text else help_text;
            var txt = hn.getText().?;
            if (!std.mem.eql(u8, txt.content, shown)) {
                try hn.setTextContent(a, shown);
                txt = hn.getText().?;
            }
            txt.color = styles.helperTextStyle(self.tokens, has_error).color;
            hn.setText(txt);
            hn.setDisplay(if (shown.len > 0) .flex else .none);
            hn.markRenderDirty();
        }
        const disabled = self.disabled.read(tracked);
        if (disabled != self.shown_disabled) self.applyDisabled(disabled);
        self.icon_tone.set(if (disabled) .disabled else if (has_error) .invalid else .normal);
    }

    /// Dynamic disable: the frame follows the shell's :disabled; here only behavior (event entry
    /// gated by state.disabled, focus revoked, a11y).
    fn applyDisabled(self: *InputChrome, disabled: bool) void {
        self.shown_disabled = disabled;
        self.state.disabled = disabled;
        const node = self.input_container;
        // Revoke focus first (dispatch blur, complete on_blur cleanup) before unfocusable
        if (disabled) {
            self.state.cancelImeComposition();
            if (self.cx.focus_manager.getFocused() == node) self.cx.clearFocus();
        }
        node.setFocusable(!disabled);
        if (node.behavior.interaction.a11y) |*attrs| attrs.disabled = disabled;
        self.state.dirty = true;
        node.markRenderDirty();
    }

    fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
        const self: *InputChrome = @ptrCast(@alignCast(ptr));
        self.cx.allocator.free(self.placeholder_copy);
        alloc.destroy(self);
    }
};

/// Input mount result (for Group composition)
pub const InputResult = struct {
    /// wrapper root node (includes label/helper, pass to addGroupItem)
    node: *Node,
    /// Input node with actual border/radius
    input_container: *Node,
    /// Edit state (compound controls read cursor/composition detail; write text via `value`.
    /// Lifetime follows Input's internal scope; don't use past wrapper lifetime.
    state: *TextInputState,
    /// Text value signal (`ui.split` returns null)
    value: ?*Signal([]const u8),

    /// After InputResult mount, **on failure** use this to return. Why: `node` is bound to Input's
    /// own
    /// childScope via bindScopeToNode, and that scope is **a subscope of the caller scope**. The
    /// caller's error path can't safely free it either way; both SIGSEGV + 0xaaaa poison:
    ///   - `cx.freeNode(node)`                        -> invalidateReferencesToEx
    ///   - `cx.freeDetachedNodeAfterScopeDispose(node)` -> unregisterSubtree
    /// because caller scope teardown walks the scope tree again.
    ///
    /// Scope cascade alone is insufficient: Scope.disposeNow frees effects/signals/resources only,
    /// **never frees bound nodes** (ScopeBinding.destroy unbinds, not frees; see core.zig
    /// bindScopeToNode comment). Doing nothing leaks (22 items in an OOM-injection test).
    ///
    /// Correct: let Input's childScope exit (remove from the caller's child chain, run its
    /// cleanup),
    /// then free the node subtree. Caller scope teardown then never meets a freed tree.
    ///
    /// Usage:
    ///     const im = try Input(...).mountResult(scope, cx);
    ///     errdefer im.abandon(cx);
    ///     try panel.appendChild(allocator, im.node);
    pub fn abandon(self: InputResult, cx: *Cx) void {
        // Order matters: dispose own scope first (swapRemove from parent's children), parent won't
        // touch tree after; then free node.
        if (self.node.meta.ownership.scope.scope) |own_scope| {
            core.clearNodeScopes(self.node);
            if (!own_scope.disposed) own_scope.dispose();
        }
        cx.freeNode(self.node);
    }

    /// `ui.view` integration (see InputBuilder.viewMount).
    pub fn viewParts(self: InputResult) core.ViewParts {
        return .{ .root = self.node };
    }
};

/// Embedded Input: the compound control draws the frame and its padding; the text starts at the
/// frame's content edge.
fn applyEmbeddedEditing(state: *TextInputState) void {
    state.padding_h = 0;
    if (state.text_display_node) |text| text.style.padding.left = -state.scroll_x;
}

pub const InputBuilder = struct {
    props: InputProps,

    /// Retained mode: mount (Scope manages TextInputState lifetime)
    pub fn mount(self: InputBuilder, scope: *Scope, cx: *Cx) !*Node {
        return (try self.mountResult(scope, cx)).node;
    }

    /// `ui.view` integration: `v.capture(&st.input, W.Input(...))` gets edit state, `.parts = .{
    /// .input_container = "id" }` marks input.
    pub fn viewMount(self: InputBuilder, scope: *Scope, cx: *Cx) !InputResult {
        return self.mountResult(scope, cx);
    }

    /// mount and return struct with input_container ref (for Group composition)
    pub fn mountResult(self: InputBuilder, scope: *Scope, cx: *Cx) !InputResult {
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;
        reactive.checkBorrow(my_scope, p.expanded);
        reactive.checkBorrow(my_scope, p.invalid);
        const has_error = p.invalid.peek() or p.error_msg.peek().len > 0;
        const disabled0 = p.disabled.peek();
        // Static disabled: shell draws disabled, no event handlers; dynamic disabled: InputChrome
        // gates
        const static_disabled = p.disabled.isStatic() and disabled0;
        const chrome_dynamic = !p.label_text.isStatic() or !p.helper.isStatic() or !p.error_msg.isStatic() or
            !p.placeholder.isStatic() or !p.disabled.isStatic() or !p.expanded.isStatic() or !p.invalid.isStatic();
        const value = try reactive.resolveTextModel(my_scope, p.value);
        const initial_value = value.peek();

        // Scope allocates TextInputState (retained mode, node not rebuilt, state with scope)
        const state = try my_scope.allocator.create(TextInputState);
        var state_registered = false;
        errdefer if (!state_registered) my_scope.allocator.destroy(state);
        state.* = blk: {
            var initial = TextInputState{ .io = cx.io };
            if (!p.growable and initial_value.len > 0) {
                // Truncate at UTF-8 boundary: @min cuts multibyte mid-sequence, half-char in buffer
                // (same
                // as setText/insertText).
                const copy_len = text_utils.utf8TruncateLen(initial_value, initial.buffer.len);
                @memcpy(initial.buffer[0..copy_len], initial_value[0..copy_len]);
                initial.buffer_len = copy_len;
                initial.cursor_pos = copy_len;
            }
            break :blk initial;
        };
        try my_scope.registerResource(@ptrCast(state), struct {
            fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                const s: *TextInputState = @ptrCast(@alignCast(ptr));
                // Node on_blur/event_context point to this state. Caller disposing scope then
                // detaching node
                // (while focused): detach clearFocus calls freed state (Notifier reply-send tested
                // SIGSEGV).
                // hover signal already freed, can't blur normally: silent revoke. focused node
                // guaranteed alive
                // by FocusManager contract.
                if (s.cx_ref) |c| {
                    if (c.focus_manager.getFocused()) |f| {
                        if (f.behavior.events.event_context == @as(?*anyopaque, @ptrCast(s))) c.focus_manager.abandonFocus(f);
                    }
                }
                s.deinit();
                alloc.destroy(s);
            }
        }.destroy);
        state_registered = true;

        state.growable = p.growable;
        state.allocator = allocator;
        if (p.growable and initial_value.len > 0) {
            _ = try state.setTextChecked(initial_value);
            state.clearUndoHistory();
        }
        state.input_type = p.input_type;
        state.readonly = p.readonly;
        // Value binding: edit exit / composition cancel / Enter submit all via it
        const binding = try my_scope.allocator.create(InputBinding);
        binding.* = .{ .state = state, .value = value, .on_change = p.on_change, .on_submit = p.on_submit };
        try my_scope.adoptResource(@ptrCast(binding), InputBinding.destroy);
        binding.install();
        if (p.on_submit != null) state.on_submit = Cx.strHandlerFrom(InputBinding, binding, InputBinding.onSubmit);
        state.allocator = allocator;
        // Inject cx weak ref, route utf8MeasuredAdvance through cx.shapeText, replace old
        // measureTextWidthByFontKind. state.cx_ref alive until scope dispose.
        state.cx_ref = cx;

        // Read unified size from ControlSize (via theme token)
        const sz = p.size;
        const metrics = styles.fieldMetrics(t, sz);
        const input_font_size = metrics.font_size;
        // Line height from Button/Select (control metrics), don't ceil self, else md 1px tall
        const input_line_height = metrics.lineHeightPx();
        const input_text_line_height = metrics.line_height;
        const input_icon_size = metrics.icon_size;
        const inline_padding_in_content = p.leading_icon_asset == null and p.append_text == null and p.append_icon_asset == null;
        // The frame insets the surface by its border (styles.Frame); the text keeps its position.
        const content_padding_h: f32 = if (inline_padding_in_content) @max(@as(f32, 0), metrics.padding_h - styles.fieldBorderWidth(p.field_style)) else 0;

        // Label (dynamic always built, hidden when empty); helper/error (dynamic always built,
        // hidden).
        // Edit block metrics written to state before tree: display text initial left pad (padding_h
        // -
        // scroll_x) read in declaration
        state_mod.applyEditableBlockConfig(
            state,
            .{ .multiline = false, .accept_newline = false, .soft_wrap = false },
            .{ .char_width = 7.8, .font_size = input_font_size, .padding_h = content_padding_h, .padding_v = 0, .line_height = input_line_height },
            null,
            cx,
            t,
        );
        state.updateScrollX();

        // Display text (inside editable_surface, clipped by overflow_hidden)
        const has_content = state.hasVisualValue();
        // Static placeholder borrows caller literal (same as old); dynamic owned by InputChrome
        const placeholder0: ?[]const u8 = if (p.placeholder.isStatic() and p.placeholder.peek().len > 0) p.placeholder.peek() else null;
        const display_text = state.buildDisplayText(placeholder0);
        // Growable storage may move before the next render, including when
        // refreshing the display subsequently fails. Retain an owned snapshot.
        const retain_display = p.growable and display_text.len > 0;
        const initial_display = if (retain_display) try allocator.dupe(u8, display_text) else display_text;
        var initial_display_owned = retain_display;
        errdefer if (initial_display_owned) allocator.free(initial_display);
        const display_init = DisplayTextInit{
            .props = .{
                .content = if (initial_display.len > 0) initial_display else "",
                .owned = retain_display,
                .color = if (disabled0) t.tokens.color.fg_disabled else styles.displayTextColor(t, has_error, has_content, p.placeholder_color),
                .color_set = true,
                .font_size = input_font_size,
                .line_height = input_text_line_height,
                .spans = state.text_spans_buf[0..0],
                .spans_owned = false,
                // selection / IME highlight purely visual, doesn't affect text layout size.
                .spans_affect_layout = false,
            },
            .owned_flag = &initial_display_owned,
        };

        // Label (dynamic always built, hidden when empty); helper/error (dynamic always built,
        // hidden)
        const has_label_row = !p.label_text.isStatic() or p.label_text.peek().len > 0;
        const helper0 = if (has_error) p.error_msg.peek() else p.helper.peek();
        const has_helper = !p.helper.isStatic() or !p.error_msg.isStatic() or helper0.len > 0;
        const Parts = struct {
            label_row: ?*Node = null,
            label: ?*Node = null,
            shell: core.ViewParts = undefined,
            leading_icon: ?*Node = null,
            editable_surface: *Node = undefined,
            text: *Node = undefined,
            cursor: *Node = undefined,
            append_icon: ?*Node = null,
            helper: ?*Node = null,
        };
        var parts: Parts = .{};
        const icon_size: core.Sizing = .{ .px = input_icon_size };
        // Frame states the shell resolves declaratively (signals: InputChrome updates them).
        const invalid_frame = try my_scope.createSignal(bool, has_error);
        const icon_tone = try my_scope.createSignal(styles.IconTone, if (disabled0) .disabled else if (has_error) .invalid else .normal);
        // A field's value is scrolled inside it and never sets its minimum width (opt out of the
        // CSS automatic minimum): typing must not widen a width-less Input in a row.
        const wrapper = try view.render(my_scope, cx, view.col(.{ .style = core.BoxStyle{
            .width = if (p.embedded) .{ .grow = .{ .min = 0 } } else if (p.width) |w| .{ .px = w } else .{ .grow = .{} },
            .flex_shrink = if (p.embedded) 1 else null,
            .min_width = if (p.embedded or p.width == null) 0 else null,
            .height = .{ .fit = .{} },
            .gap = if (p.embedded) 0 else 4,
        } }, .{
            if (has_label_row) view.capture(&parts.label_row, view.row(.{ .style = .{
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{} },
                .align_items = .center,
                .gap = 4,
            } }, .{
                view.capture(&parts.label, view.text(.{ .style = styles.labelTextStyle(t) }, p.label_text.peek())),
                if (p.required) view.text(.{ .style = styles.requiredMarkStyle(t) }, "*") else null,
            })) else null,
            // The field: ControlShell(.field) draws the frame and every frame state (hover / focus
            // from the node, disabled / invalid / expanded from parameters); Input adds its
            // geometry as an overlay and puts the editing surface in the content slot.
            view.attrs(.{ .style = view.styleBy(styles.Frame{
                .size = sz,
                .width = p.width,
                .raised = p.raised,
                .inline_padding = inline_padding_in_content,
                .embedded = p.embedded,
                .field = p.field_style,
            }, styles.frame) }, view.with(control_shell.ControlShell(.{
                .variant = .field,
                .size = sz,
                .leading_icon = p.leading_icon_asset != null,
                .disabled = p.disabled,
                .invalid = invalid_frame,
                .expanded = p.expanded,
                .embedded = p.embedded,
                .cursor = .text,
                .disabled_cursor = .default,
                .tag = .input,
                // The content slot must shrink with the shell, otherwise its
                // automatic text minimum also expands the clipping surface.
                .content_style = core.BoxStyle{ .height = .{ .grow = .{} }, .align_self = .stretch, .min_width = 0, .min_height = input_line_height },
                .icon_style = core.BoxStyle{ .min_height = input_line_height },
                .append_style = core.BoxStyle{ .min_height = input_line_height },
            }), .{}).capture(&parts.shell).slots(.{
                .icon = if (p.leading_icon_asset) |asset| view.capture(&parts.leading_icon, view.icon(.{
                    .style = .{ .width = icon_size, .height = icon_size },
                    .tint = view.tintBy(icon_tone, styles.iconTint),
                }, asset)) else null,
                .content = .{
                    // Center the single text line in the available height, just like the caret.
                    // The surface still fills content_slot so horizontal clipping is unchanged.
                    view.capture(&parts.editable_surface, view.box(.{ .style = core.BoxStyle{
                        .width = .{ .grow = .{} },
                        .height = .{ .grow = .{} },
                        .align_self = .stretch,
                        .justify = .center,
                        .overflow_hidden = true,
                        .min_width = 0,
                        .overflow_fade = .{
                            .size = 12,
                            .color = styles.overflowFadeColor(t),
                            .edges = .{ .top = false, .bottom = false, .left = true, .right = true },
                        },
                    } }, .{
                        // Display text node: box style (align_self/padding) + text attrs with spans
                        // contract,
                        // DisplayTextInit.apply writes on mount
                        view.capture(&parts.text, view.setup(view.box(.{
                            .style = core.BoxStyle{
                                // Override parent default align_items=stretch, preserve text
                                // intrinsic width for overflow fade
                                .align_self = .start,
                                .padding = .{ .left = state.padding_h - state.scroll_x },
                            },
                        }, {}), display_init, DisplayTextInit.apply)),
                    })),
                    // Single-line Input: selection / IME preedit underline / IME marked highlight
                    // all via
                    // text_display_node.text.spans, glyph always above span background, eliminate
                    // "selection
                    // occludes text" and "position misalign" bugs. Keep cursor_node only (cursor
                    // not text attr).
                    view.capture(&parts.cursor, view.box(.{ .style = .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } } }, {})),
                },
                // No append_text/append_icon, don't build append slot
                .append = if (p.append_text != null or p.append_icon_asset != null) view.row(.{ .style = .{
                    .width = .{ .fit = .{} },
                    .height = .{ .fit = .{} },
                    .align_items = .center,
                    .gap = metrics.gap,
                } }, .{
                    if (p.append_text) |append_text_val| view.text(.{ .style = styles.appendTextStyle(t, input_font_size) }, append_text_val) else null,
                    if (p.append_icon_asset) |asset| view.capture(&parts.append_icon, view.icon(.{
                        .style = .{ .width = icon_size, .height = icon_size },
                        .tint = view.tintBy(icon_tone, styles.iconTint),
                    }, asset)) else null,
                }) else null,
            })),
            if (has_helper) view.capture(&parts.helper, view.text(.{
                .style = styles.helperTextStyle(t, has_error),
                .visible = helper0.len > 0,
            }, helper0)) else null,
        }));
        errdefer cx.freeNode(wrapper);
        wrapper.meta.ownership.meta.component_name = "Input";
        wrapper.frame_state.state_bits.flags.disable_render_cache = true;
        try core.bindScopeToNode(my_scope, wrapper);
        scope_bound = true;
        wrapper.addDebugState(@ptrCast(state));
        wrapper.behavior.events.event_context = state;

        const label_row_node = parts.label_row;
        const label_text_node = parts.label;
        const input_container = parts.shell.root.?;
        const leading_icon_node = parts.leading_icon;
        const append_icon_node = parts.append_icon;
        const editable_surface = parts.editable_surface;

        input_container.setFocusable(true);
        input_container.behavior.interaction.a11y = .{
            .role = .textbox,
            // Explicit empty suppresses core's subtree-text label fallback.
            // The current value (and password mask) must never become the
            // control's changing accessible name.
            .label = if (label_text_node) |ln| ln.getText().?.content else "",
            .placeholder = if (p.placeholder.peek().len > 0) p.placeholder.peek() else null,
            .disabled = disabled0,
            .required = p.required,
            .readonly = p.readonly,
            .invalid = has_error,
            .secure = p.input_type == .password,
        };
        state.input_container_node = input_container;
        render_mod.syncAccessibilityProps(state, input_container);
        if (!static_disabled and !p.readonly) {
            input_container.behavior.interaction.text_input_client = render_mod.textInputClient(state);
        }
        state.has_error = has_error;
        wrapper.setInteractionDelegate(input_container);
        // Group attaches this Input by its field (corner radii, shared edge), not the label column.
        wrapper.setFrameDelegate(input_container);

        editable_surface.behavior.events.event_context = state;
        state.editable_surface_node = editable_surface;
        editable_surface.meta.per_frame.hooks.before_render.main = render_mod.inputBeforeRender;
        state.text_display_node = parts.text;
        state.placeholder_text = placeholder0;
        state.placeholder_color = p.placeholder_color;
        state.cursor_node = parts.cursor;

        // Register event handlers (dynamic disabled still attached, entry gated by state.disabled).
        // Readonly also attached: select/copy/focus work, edit entry gated by state.readonly.
        state.disabled = disabled0;
        if (!static_disabled) {
            input_container.behavior.events.on_event = events_mod.inputFieldEventHandler;
            input_container.behavior.events.event_context = state;
        }

        const helper_text_node = parts.helper;

        if (chrome_dynamic) {
            const chrome = try my_scope.allocator.create(InputChrome);
            chrome.* = .{
                .state = state,
                .cx = cx,
                .tokens = t,
                .label = p.label_text,
                .helper = p.helper,
                .error_msg = p.error_msg,
                .placeholder = p.placeholder,
                .disabled = p.disabled,
                .wrapper = wrapper,
                .input_container = input_container,
                .label_row = label_row_node,
                .label_node = label_text_node,
                .helper_node = helper_text_node,
                .leading_icon = leading_icon_node,
                .append_icon = append_icon_node,
                .invalid = p.invalid,
                .invalid_frame = invalid_frame,
                .icon_tone = icon_tone,
                .shown_disabled = false,
            };
            try my_scope.adoptResource(@ptrCast(chrome), InputChrome.destroy);
            // First sync apply (fail returns), then effect follows
            try chrome.apply(false);
            try my_scope.createEffect(chrome, InputChrome.effect);
        }

        // value is Model: external write via effect into buffer (first run same as init,
        // short-circuit)
        try my_scope.createEffect(binding, InputBinding.valueEffect);

        state.visual_sync_hook = render_mod.inputBeforeRender;
        if (p.embedded) applyEmbeddedEditing(state);

        return .{ .node = wrapper, .input_container = input_container, .state = state, .value = value.asSignal() };
    }
};

/// Single-line Input display text node: besides style, has spans buffer contract (borrow
/// state's spans, not layout) and possible content snapshot - `ui.view.text` writes TextStyle
/// only, here via `view.setup` writes full TextProps.
const DisplayTextInit = struct {
    props: core.TextProps,
    /// Content snapshot ownership: after write to node, node owns (Node.destroy frees), caller
    /// guard lifted
    owned_flag: *bool,

    fn apply(self: DisplayTextInit, node: *Node) void {
        node.setText(self.props);
        self.owned_flag.* = false;
    }
};

/// Multiline text input (standalone impl, uses TextareaDocument + DocCursor + WrapMap)
pub const TextareaProps = textarea_mod.TextareaProps;
pub const TextareaBuilder = textarea_mod.TextareaBuilder;

pub const Textarea = textarea_mod.Textarea;
pub const TextareaResult = textarea_mod.TextareaResult;

// ========== Tests ==========

test "Input: accessibility value setter scrolls and publishes before paint" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(300, 200);
    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const mounted = try Input(.{ .value = "initial", .width = 120 }).mountResult(scope, ctx);
    try root.appendChild(std.testing.allocator, mounted.node);
    try std.testing.expectEqualStrings("initial", mounted.input_container.behavior.interaction.a11y.?.value_text.?);
    ctx.layout();
    _ = ctx.render();
    const editable = mounted.input_container.behavior.interaction.a11y.?.editable_text.?;
    try std.testing.expect(editable.set_value.?(editable.context, (@as([("long-text-").len * (40)]u8, @bitCast(@as([40][("long-text-").len]u8, @splat(("long-text-").*)))) ++ "")));
    try std.testing.expect(mounted.state.scroll_x > 0);
    try std.testing.expectEqualStrings((@as([("long-text-").len * (40)]u8, @bitCast(@as([40][("long-text-").len]u8, @splat(("long-text-").*)))) ++ ""), mounted.input_container.behavior.interaction.a11y.?.value_text.?);
    try std.testing.expect(editable.set_value.?(editable.context, ""));
    try std.testing.expectEqual(@as(f32, 0), mounted.state.scroll_x);
    try std.testing.expectEqualStrings("", mounted.input_container.behavior.interaction.a11y.?.value_text.?);
}

test "Input: basic creation" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const input_node = try Input(.{ .label_text = "Email", .placeholder = "Enter your email" }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, input_node);

    // Should have 2 children: label + input container
    try std.testing.expectEqual(@as(usize, 2), input_node.children.items.len);
}

test "Input viewport stays inside its shell through long-text Home and End" {
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    cx.setWindowMetrics(600, 300, 1);
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const mounted = try Input(.{ .width = 320, .label_text = "Name" }).mountResult(scope, cx);
    cx.root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{mounted.node});
    _ = cx.render();
    const state = mounted.state;
    _ = events_mod.inputFieldEventHandler(.{ .focus = .{} }, state);
    var value: [520]u8 = undefined;
    for (0..20) |i| @memcpy(value[i * 26 ..][0..26], "abcdefghijklmnopqrstuvwxyz");
    _ = events_mod.inputEventHandler(.{ .text_input = .{ .text = &value } }, state);
    _ = cx.render();
    const surface = state.editable_surface_node.?;
    const slot = surface.parent.?;
    for (0..4) |_| {
        inline for (.{ core.KeyCode.home, core.KeyCode.end }) |key_value| {
            _ = events_mod.inputEventHandler(.{ .key_down = .{ .key = key_value, .modifiers = .{} } }, state);
            for (0..3) |_| {
                _ = cx.render();
                const shell_width = mounted.input_container.rectFromWorldOrFallback().w;
                try t.expect(slot.rectFromWorldOrFallback().w <= shell_width + 0.01);
                try t.expect(surface.rectFromWorldOrFallback().w <= shell_width + 0.01);
                try t.expectApproxEqAbs(surface.rectFromWorldOrFallback().w - 2 * state.padding_h, state.input_inner_w, 0.01);
                if (key_value == .home) try t.expectEqual(@as(f32, 0), state.scroll_x) else try t.expect(state.scroll_x > 100);
            }
        }
    }
}

test "Input overflow fade follows the field paint without darkening blank pixels" {
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    cx.setWindowMetrics(600, 300, 1);
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const input = try Input(.{ .width = 240, .value = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz" }).mountResult(scope, cx);
    cx.root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{input.node});
    _ = cx.render();
    const state = input.state;
    const surface = state.editable_surface_node.?;
    // Cover a light field, a dark/custom field, and a transparent embedded field.
    // Opaque overlays must match the resolved paint, including theme/disabled
    // transitions; a translucent field cannot be faked by painting its tint twice.
    for ([_]Color{ Color.rgb(255, 255, 255), Color.rgb(31, 47, 63), Color.rgba(80, 90, 100, 128), Color.TRANSPARENT }) |background| {
        input.input_container.setBackgroundRaw(background);
        inline for (.{ core.KeyCode.home, core.KeyCode.end }) |key_value| {
            _ = events_mod.inputEventHandler(.{ .key_down = .{ .key = key_value, .modifiers = .{} } }, state);
            _ = cx.render();
            const fade = surface.style.overflow_fade().?;
            try t.expect(Color.eql(background, fade.color.?));
            try t.expectEqual(background.a == 255 and key_value == .end, fade.edges.left);
            try t.expectEqual(background.a == 255 and key_value == .home, fade.edges.right);
        }
    }
}

test "Input clip and overflow fade stop at the field border; the text keeps its position" {
    const t = std.testing;
    // A caller border wider than the recipe's 1px must be honoured too.
    inline for (.{ core.StyleOverride{}, core.StyleOverride{ .border_width = 2 } }) |field_style| {
        var cx = try Cx.init(t.allocator, std.testing.io);
        defer cx.deinit();
        cx.setWindowMetrics(600, 300, 1);
        const scope = try Scope.init(t.allocator, null, cx.owner);
        defer scope.dispose();
        const input = try Input(.{ .width = 240, .field_style = field_style, .value = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz" }).mountResult(scope, cx);
        cx.root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{input.node});
        _ = cx.render();
        const state = input.state;
        const shell = input.input_container.globalRect();
        const border = input.input_container.style.border.width;
        try t.expect(border > 0);
        try t.expectApproxEqAbs(styles.fieldBorderWidth(field_style), border, 0.001);
        const surface = state.editable_surface_node.?.globalRect();
        // The overlay border takes no layout space; the surface (its clip and fade) sits inside it.
        try t.expectApproxEqAbs(shell.x + border, surface.x, 0.01);
        try t.expectApproxEqAbs(shell.x + shell.w - border, surface.x + surface.w, 0.01);
        // The first glyph still starts the size's padding in from the field edge.
        _ = events_mod.inputEventHandler(.{ .key_down = .{ .key = .home, .modifiers = .{} } }, state);
        _ = cx.render();
        const metrics = styles.fieldMetrics(cx.tokens, .md);
        try t.expectEqual(@as(f32, 0), state.scroll_x);
        try t.expectApproxEqAbs(shell.x + metrics.padding_h, state.text_display_node.?.globalRect().x + state.text_display_node.?.style.padding.left, 0.01);
    }
}

test "Input long text moves paint origin and publishes selection in one update" {
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    cx.setWindowMetrics(600, 300, 1);
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const mounted = try Input(.{ .width = 360, .placeholder = "Type here" }).mountResult(scope, cx);
    cx.root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{mounted.node});
    _ = cx.render();

    const value = (@as([("abcdefghijklmnopqrstuvwxyz").len * (4)]u8, @bitCast(@as([4][("abcdefghijklmnopqrstuvwxyz").len]u8, @splat(("abcdefghijklmnopqrstuvwxyz").*)))) ++ "");
    _ = mounted.state.setText(value);
    mounted.state.updateScrollX();
    _ = cx.render();
    var text_x: ?f32 = null;
    for (cx.lowerForEncoderPaintTable()) |item| {
        if (item.kind == .text and std.mem.eql(u8, item.text_content, value)) text_x = item.geom.x;
    }
    try t.expect(mounted.state.scroll_x > 100);
    try t.expect(text_x != null);
    try t.expect(text_x.? < -100);

    mounted.state.selectAll();
    mounted.state.updateScrollX();
    _ = cx.render();
    const spans = mounted.state.text_display_node.?.getText().?.spans;
    try t.expectEqual(@as(usize, 1), spans.len);
    try t.expectEqual(@as(u32, 0), spans[0].start);
    try t.expectEqual(@as(u32, value.len), spans[0].end);
    try t.expect(spans[0].bg_color != null);
}

// The editing viewport is the field's content box whatever the text is: a long value or the
// caret at Home (text at its unscrolled origin) must not widen the frame's content slot, so
// End restores the exact viewport it had after typing (CSS automatic minimum regression).
test "Input long value keeps the viewport at the field width so End restores the scroll" {
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    cx.setWindowMetrics(600, 300, 1);
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const mounted = try Input(.{ .width = 320 }).mountResult(scope, cx);
    cx.root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{mounted.node});
    cx.layout();
    _ = cx.render();
    const surface = mounted.state.text_display_node.?.parent.?;
    const field_inner_w = mounted.input_container.globalRect().w - mounted.input_container.style.padding.horizontal();

    const value = (@as([("abcdefghijklmnopqrstuvwxyz").len * (4)]u8, @bitCast(@as([4][("abcdefghijklmnopqrstuvwxyz").len]u8, @splat(("abcdefghijklmnopqrstuvwxyz").*)))) ++ "");
    _ = mounted.state.setText(value);
    mounted.state.updateScrollX();
    cx.layout();
    _ = cx.render();
    try t.expectEqual(@as(usize, value.len), mounted.state.cursor_pos);
    const typed_scroll = mounted.state.scroll_x;
    try t.expect(typed_scroll > 100);

    try t.expect(mounted.state.handleKeyDown(.home, .{}));
    mounted.state.updateScrollX();
    cx.layout();
    _ = cx.render();
    try t.expectEqual(@as(f32, 0), mounted.state.scroll_x);
    // Unscrolled long text is the widest the content gets; the viewport stays the field's.
    try t.expectApproxEqAbs(@as(f32, 320), mounted.input_container.globalRect().w, 0.01);
    try t.expectApproxEqAbs(field_inner_w, surface.globalRect().w, 0.01);

    try t.expect(mounted.state.handleKeyDown(.end, .{}));
    mounted.state.updateScrollX();
    cx.layout();
    _ = cx.render();
    try t.expectApproxEqAbs(field_inner_w, surface.globalRect().w, 0.01);
    try t.expectApproxEqAbs(typed_scroll, mounted.state.scroll_x, 0.01);
}

// A width-less Input in a row may take its share of the row but never sets the row's minimum:
// a long value is scrolled inside the field, so typing cannot push the field or its siblings
// past the row (CSS automatic minimum opted out with min-width: 0).
test "Input in a row never overflows the row with its value" {
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    cx.setWindowMetrics(600, 300, 1);
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const mounted = try Input(.{}).mountResult(scope, cx);
    const sibling = try box(cx, .{ .width = .{ .px = 100 }, .min_width = 100, .height = .{ .px = 20 } }, .{});
    const row = try box(cx, .{ .direction = .row, .width = .{ .px = 300 }, .height = .{ .fit = .{} } }, .{ mounted.node, sibling });
    cx.root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 300 } }, .{row});
    cx.layout();
    _ = cx.render();
    try t.expectApproxEqAbs(@as(f32, 200), mounted.node.globalRect().w, 0.01);

    const value = (@as([("abcdefghijklmnopqrstuvwxyz").len * (4)]u8, @bitCast(@as([4][("abcdefghijklmnopqrstuvwxyz").len]u8, @splat(("abcdefghijklmnopqrstuvwxyz").*)))) ++ "");
    _ = mounted.state.setText(value);
    try t.expect(mounted.state.handleKeyDown(.home, .{}));
    mounted.state.updateScrollX();
    cx.layout();
    _ = cx.render();
    const field = mounted.input_container.globalRect();
    const surface = mounted.state.text_display_node.?.parent.?.globalRect();
    try t.expectApproxEqAbs(@as(f32, 200), mounted.node.globalRect().w, 0.01);
    try t.expectApproxEqAbs(@as(f32, 200), field.w, 0.01);
    try t.expect(surface.x + surface.w <= field.x + field.w + 0.01);
    try t.expectApproxEqAbs(@as(f32, 200), sibling.globalRect().x, 0.01);
    try t.expect(mounted.state.scroll_x == 0 and mounted.state.input_inner_w <= field.w);
}

test "Input accessibility publishes value and writable selection but password fails closed" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 160 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const plain = try Input(.{ .value = "hello", .width = 200 }).mountResult(scope, ctx);
    try root.appendChild(allocator, plain.node);
    plain.state.selection_anchor = 1;
    plain.state.cursor_pos = 4;
    const editable_surface = plain.state.text_display_node.?.parent.?;
    editable_surface.meta.per_frame.hooks.before_render.main.?(editable_surface);
    const plain_a11y = plain.input_container.behavior.interaction.a11y.?;
    try std.testing.expectEqualStrings("hello", plain_a11y.value_text.?);
    try std.testing.expectEqual(@as(u32, 1), plain_a11y.editable_text.?.selection_start);
    try std.testing.expectEqual(@as(u32, 4), plain_a11y.editable_text.?.selection_end);
    try std.testing.expect(plain_a11y.editable_text.?.set_selection(
        plain_a11y.editable_text.?.context,
        0,
        2,
    ));
    try std.testing.expectEqual(@as(usize, 0), plain.state.selection_anchor.?);
    try std.testing.expectEqual(@as(usize, 2), plain.state.cursor_pos);

    const password = try Input(.{ .value = "secret", .input_type = .password, .width = 200 }).mountResult(scope, ctx);
    try root.appendChild(allocator, password.node);
    const password_surface = password.state.text_display_node.?.parent.?;
    password_surface.meta.per_frame.hooks.before_render.main.?(password_surface);
    const password_a11y = password.input_container.behavior.interaction.a11y.?;
    try std.testing.expect(password_a11y.value_text == null);
    try std.testing.expect(password_a11y.editable_text == null);
}

test "TextInputState accessibility selection snaps to grapheme boundaries" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    const value = "A👩‍💻B";
    @memcpy(state.buffer[0..value.len], value);
    state.buffer_len = value.len;
    // Start is inside the ZWJ emoji and must snap to its leading boundary;
    // end is the valid boundary immediately before B.
    try std.testing.expect(state.setAccessibilitySelection(2, @intCast(value.len - 1)));
    try std.testing.expectEqual(@as(usize, 1), state.selection_anchor.?);
    try std.testing.expectEqual(value.len - 1, state.cursor_pos);
}

test "Input: with error" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const input_node = try Input(.{ .label_text = "Password", .error_msg = "Password is required" }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, input_node);

    // Should have 3 children: label + input + error
    try std.testing.expectEqual(@as(usize, 3), input_node.children.items.len);
}

test "Textarea: basic" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const textarea_node = try Textarea(.{ .label_text = "Description", .rows = 4 }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, textarea_node);

    try std.testing.expect(textarea_node.children.items.len >= 2);
}

test "TextInputState: insertText" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    try std.testing.expectEqualStrings("hello", state.getText());
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "TextInputState: deleteBackward" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.deleteBackward();
    try std.testing.expectEqualStrings("hell", state.getText());
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
}

test "TextInputState: cursor navigation" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.moveCursor(-2, false);
    try std.testing.expectEqual(@as(usize, 3), state.cursor_pos);
    state.moveCursor(1, false);
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
    state.moveToStart();
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
    state.moveToEnd();
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "Input: Group first should propagate per-corner and avoid uniform clip cut" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 520 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const group_mod = @import("../group/mod.zig");
    const grp = try group_mod.Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, grp.container);

    const mounted = try Input(.{
        .value = "example.com/page",
        .width = 240,
        .leading_icon_asset = svg_assets.common.link,
    }).mountResult(scope, ctx);
    try group_mod.addGroupItem(grp.container, alloc, mounted.node, .first, 8);

    if (mounted.node.meta.per_frame.hooks.before_render.main) |hook| {
        hook(mounted.node);
    }

    const r = mounted.input_container.style.effectiveRadii();
    try std.testing.expectApproxEqAbs(@as(f32, 8), r[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), r[3], 0.001);
    try std.testing.expect(!mounted.input_container.style.overflow_hidden);
}

test "Input: grouped wrapper propagates trailing seam border side colors to field" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 520 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const group_mod = @import("../group/mod.zig");
    const grp = try group_mod.Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, grp.container);

    const mounted = try Input(.{
        .value = "example.com/page",
        .width = 240,
        .leading_icon_asset = svg_assets.common.link,
    }).mountResult(scope, ctx);
    try group_mod.addGroupItem(grp.container, alloc, mounted.node, .first, 8);

    if (mounted.node.meta.per_frame.hooks.before_render.main) |hook| {
        hook(mounted.node);
    }

    try std.testing.expect(mounted.input_container.style.border_side_colors() != null);
    try std.testing.expect(Color.eql(
        mounted.input_container.style.border_side_colors().?.right.?,
        Color.TRANSPARENT,
    ));
    try std.testing.expectEqual(@as(i32, 0), mounted.input_container.style.z_index());
}

/// Settled border color (transition target while easing).
fn borderTarget(n: *Node) Color {
    if (n.frame_state.frame_local.runtime.transitions) |slots| if (slots.find(.border_color)) |slot| if (slot.active) return slot.to_color;
    return n.style.border.color;
}

test "Input: 聚焦时框是 accent（外壳 :focus），失焦回到静止色；Input 的焦点处理不顶掉外壳的焦点钩子" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();
    const mounted = try Input(.{ .placeholder = "Your name" }).mountResult(scope, ctx);
    try root.appendChild(alloc, mounted.node);
    ctx.layout();
    _ = ctx.render();
    const t = ctx.tokens.tokens.color;
    try std.testing.expect(Color.eql(t.border_strong, borderTarget(mounted.input_container)));
    ctx.focus_manager.setFocus(mounted.input_container);
    try std.testing.expect(mounted.state.focused);
    try std.testing.expect(Color.eql(t.accent, borderTarget(mounted.input_container)));
    ctx.focus_manager.setFocus(null);
    try std.testing.expect(!mounted.state.focused);
    try std.testing.expect(Color.eql(t.border_strong, borderTarget(mounted.input_container)));
}

test "Input: field_style overrides the field over the size recipe and every frame state" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();
    const fixed = Color.hex(0x2944A8);
    const mounted = try Input(.{
        .placeholder = "https://",
        .size = .sm,
        .width = 236,
        .field_style = .{ .height = .{ .px = 28 }, .corner_radius = 6, .border_color = fixed },
    }).mountResult(scope, ctx);
    try root.appendChild(alloc, mounted.node);
    ctx.layout();
    _ = ctx.render();
    const field = mounted.input_container;
    const expectField = struct {
        fn check(n: *Node, c: Color) !void {
            try std.testing.expectEqual(@as(f32, 28), n.style.height.px);
            try std.testing.expectApproxEqAbs(@as(f32, 6), n.style.effectiveRadii()[0], 0.001);
            try std.testing.expect(Color.eql(c, borderTarget(n)));
        }
    }.check;
    try expectField(field, fixed);
    try std.testing.expectApproxEqAbs(@as(f32, 28), field.rectFromWorldOrFallback().h, 0.01);
    // Focus and blur recompute the frame states; the caller's field stays.
    ctx.focus_manager.setFocus(field);
    try expectField(field, fixed);
    ctx.focus_manager.setFocus(null);
    try expectField(field, fixed);
    // The size recipe's other geometry still applies (only the declared fields are replaced).
    try std.testing.expectEqual(@as(f32, 236), field.style.width.px);
}

test "Input: 占位符在渲染时保持占位符颜色，不继承外壳的前景色" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();
    const mounted = try Input(.{ .placeholder = "Your name" }).mountResult(scope, ctx);
    try root.appendChild(alloc, mounted.node);
    ctx.layout();
    _ = ctx.render();
    const painted = @import("../../core/render_engine/text_render.zig").resolveNodeLogicalTextProps;
    const text = mounted.state.text_display_node.?;
    try std.testing.expect(Color.eql(styles.displayTextColor(ctx.tokens, false, false, null), painted(text).?.color));
}

test "TextInputState: insert in middle" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("helo");
    state.moveCursor(-1, false); // cursor at 'o'
    state.insertText("l");
    try std.testing.expectEqualStrings("hello", state.getText());
}

test "TextInputState: selectAll + delete" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.selectAll();
    state.deleteBackward();
    try std.testing.expectEqualStrings("", state.getText());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
}

test "TextInputState: handleKeyDown" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("test");
    // Left arrow
    try std.testing.expect(state.handleKeyDown(.left, .{}));
    try std.testing.expectEqual(@as(usize, 3), state.cursor_pos);
    // Shift+Left should extend selection
    try std.testing.expect(state.handleKeyDown(.left, .{ .shift = true }));
    try std.testing.expectEqual(@as(?usize, 3), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 2), state.cursor_pos);
    // Cmd+A
    try std.testing.expect(state.handleKeyDown(.a, .{ .super = true }));
    try std.testing.expectEqual(@as(?usize, 0), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
    // Backspace deletes selection
    try std.testing.expect(state.handleKeyDown(.delete, .{}));
    try std.testing.expectEqualStrings("", state.getText());
}

test "Input: event handler responds to text_input" {
    const result = events_mod.inputEventHandler(
        Event{ .text_input = .{ .text = "a" } },
        null,
    );
    // null context should return ignored
    try std.testing.expectEqual(EventResult.ignored, result);
}

test "Input: render emits field border and value text" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(360, 120);

    const root = try box(ctx, .{
        .width = .{ .px = 360 },
        .height = .{ .px = 120 },
        .background = ctx.tokens.tokens.color.bg_primary,
    }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const input_node = try Input(.{
        .value = "hello@example.com",
        .width = 280,
        .leading_icon_asset = svg_assets.common.search,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, input_node);

    ctx.layout();
    _ = ctx.render();
    const commands = ctx.lowerForEncoderPaintTable();

    var saw_border = false;
    var saw_text = false;
    for (commands) |cmd| if (cmd.isStrokeRect()) {
        const b = cmd;
        if (b.geom.w >= 200 and b.geom.h >= 24 and b.stroke_width >= 1) {
            saw_border = true;
        }
    } else if (cmd.isText()) {
        const tcmd = cmd;
        if (std.mem.eql(u8, tcmd.text_content, "hello@example.com")) saw_text = true;
    };

    try std.testing.expect(saw_border);
    try std.testing.expect(saw_text);
}

test "Input: double click selects word on mouse_down" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello world");
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .mouse_down = .{ .x = 0, .y = 0 } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .mouse_up = .{ .x = 0, .y = 0 } }, ctx_ptr);
    // Second press triggers word select immediately (no wait for click/mouse_up)
    _ = events_mod.inputEventHandler(Event{ .mouse_down = .{ .x = 0, .y = 0 } }, ctx_ptr);
    try std.testing.expect(state.selection_anchor != null);
    try std.testing.expectEqual(@as(usize, 0), state.selection_anchor.?);
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "TextInputState: ime preedit state update" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.char_width = 8;
    state.font_size = 13;
    state.handleImePreeditEvent("ni", 1);
    try std.testing.expect(state.hasImePreedit());
    try std.testing.expect(state.imeIsComposing());
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
    try std.testing.expectEqual(@as(usize, 2), state.ime_preedit_len);
    try std.testing.expectEqual(@as(usize, 1), state.ime_cursor_utf8_offset);
    try std.testing.expect(state.imePreeditAdvance() > 0);
    try std.testing.expectEqual(@as(f32, 0), state.imePreeditStartAdvance());
    state.handleImePreeditEvent("", 0);
    try std.testing.expect(!state.hasImePreedit());
    try std.testing.expect(!state.imeIsComposing());
}

test "Input: ime_commit inserts text once" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "abc" } }, ctx_ptr);
    try std.testing.expectEqualStrings("abc", state.getText());
}

test "Input: ime_commit should replace selected text instead of appending" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.selectAll();
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "你", .cursor_utf8_offset = 3 } }, ctx_ptr);
    try std.testing.expectEqualStrings("你", state.buildDisplayText(null));
    try std.testing.expectEqualStrings("hello", state.getText());
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "你" } }, ctx_ptr);
    try std.testing.expectEqualStrings("你", state.getText());
}

test "Input: implicit IME selection replacement updates cancels and commits in both directions" {
    for ([_]bool{ false, true }) |backward| {
        var state = TextInputState{
            .io = std.testing.io,
        };
        defer state.deinit();
        state.insertText("a中文Englishz");
        state.cursor_pos = if (backward) 1 else state.getText().len - 1;
        state.selection_anchor = if (backward) state.getText().len - 1 else 1;
        const cursor = state.cursor_pos;
        const anchor = state.selection_anchor;
        const ctx_ptr: ?*anyopaque = @ptrCast(&state);
        for ([_][]const u8{ "d", "df", "夺" }) |candidate| {
            _ = events_mod.inputEventHandler(.{ .ime_preedit = .{ .text = candidate, .cursor_utf8_offset = @intCast(candidate.len) } }, ctx_ptr);
            var expected: [32]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "a{s}z", .{candidate}), state.buildDisplayText(null));
            try std.testing.expectEqualStrings("a中文Englishz", state.getText());
            try std.testing.expectEqual(@as(usize, 1), state.cursor_pos);
        }
        _ = events_mod.inputEventHandler(.{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } }, ctx_ptr);
        try std.testing.expectEqual(cursor, state.cursor_pos);
        try std.testing.expectEqual(anchor, state.selection_anchor);
        try std.testing.expectEqualStrings("a中文Englishz", state.buildDisplayText(null));
        state.handleImePreeditEvent("夺", 3);
        state.handleImeCommitEvent("夺");
        try std.testing.expectEqualStrings("a夺z", state.getText());
        state.undo();
        try std.testing.expectEqualStrings("a中文Englishz", state.getText());
    }
}

test "Input: ime_commit with replacementRange revises committed text" {
    // Japanese reconversion: IME uses replacementRange to revise committed text.
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("こんにちは"); // 15 bytes
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{
        .text = "今日は",
        .replace_start_utf8 = 0,
        .replace_end_utf8 = 15,
    } }, ctx_ptr);
    try std.testing.expectEqualStrings("今日は", state.getText());
    try std.testing.expectEqual(@as(usize, 9), state.cursor_pos);
}

test "Input: ime_commit replacementRange sentinel keeps insert-at-cursor behavior" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("ab");
    state.cursor_pos = 1;
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "x" } }, ctx_ptr);
    try std.testing.expectEqualStrings("axb", state.getText());
}

test "Input: ime replacementRange rejects stale out-of-bounds range" {
    // Bridge layer range may be stale: out-of-bounds must reject entirely, degrade to current
    // behavior.
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("ab");
    try std.testing.expect(!state.applyImeReplacementRange(0, 99));
    try std.testing.expect(!state.applyImeReplacementRange(3, 2));
    try std.testing.expect(!state.applyImeReplacementRange(
        events.ime_no_replacement,
        events.ime_no_replacement,
    ));
    // Current behavior unaffected
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{
        .text = "c",
        .replace_start_utf8 = 0,
        .replace_end_utf8 = 99,
    } }, @ptrCast(&state));
    try std.testing.expectEqualStrings("abc", state.getText());
}

test "Input: ime_preedit with replacementRange pulls committed text back into composition" {
    // Reconversion replaces display only; committed doc and undo stay intact before commit.
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("x漢字y"); // "漢字" = bytes [1,7)
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{
        .text = "かんじ",
        .cursor_utf8_offset = 9,
        .replace_start_utf8 = 1,
        .replace_end_utf8 = 7,
    } }, ctx_ptr);
    try std.testing.expectEqualStrings("x漢字y", state.getText());
    try std.testing.expectEqualStrings("xかんじy", state.buildDisplayText(null));
    try std.testing.expectEqual(@as(usize, 1), state.cursor_pos);
    try std.testing.expect(state.hasImePreedit());
    try std.testing.expect(state.imeIsComposing());
}

test "Input: ime_commit empty text with replacementRange deletes range" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("abcd");
    state.handleImeCommitReplaceEvent("", 1, 3);
    try std.testing.expectEqualStrings("ad", state.getText());
    try std.testing.expectEqual(@as(usize, 1), state.cursor_pos);
}

test "Input: ime composing ignores selection-space text_input" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "に", .cursor_utf8_offset = 1 } }, ctx_ptr);
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = " " } }, ctx_ptr);
    try std.testing.expectEqualStrings("", state.getText());
    try std.testing.expect(state.hasImePreedit());
    try std.testing.expect(state.imeIsComposing());
    try std.testing.expect(state.shouldShowImeSelectionHighlight());
}

test "Input: ime composing marks highlight on key_down space" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "しゅる", .cursor_utf8_offset = 6 } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .key_down = .{ .key = .space, .modifiers = .{} } }, ctx_ptr);
    try std.testing.expect(state.imeIsComposing());
    try std.testing.expect(state.shouldShowImeSelectionHighlight());
    try std.testing.expectEqualStrings("", state.getText());
}

test "TextInputState: ime highlight keeps cursor at preedit end when offset is zero" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.handleImePreeditEvent("しゅる", 0);
    state.markImeSelectionHighlight();
    try std.testing.expectEqual(@as(usize, 9), state.effectiveImeCursorOffset());
    try std.testing.expect(state.visualCursorAdvance() > 0);
}

test "Input: ime composing fallback text_input commits once" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "に", .cursor_utf8_offset = 1 } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = " " } }, ctx_ptr);
    try std.testing.expect(state.shouldShowImeSelectionHighlight());
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = "に" } }, ctx_ptr);
    try std.testing.expectEqualStrings("に", state.getText());
    try std.testing.expect(!state.hasImePreedit());
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
}

test "Input: ime fallback text_input should replace selected text instead of appending" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.selectAll();
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_preedit = .{ .text = "に", .cursor_utf8_offset = 1 } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = "に" } }, ctx_ptr);
    try std.testing.expectEqualStrings("に", state.getText());
}

test "TextInputState: ime preedit start advance follows cursor" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.char_width = 8;
    state.font_size = 13;
    state.insertText("ab");
    state.handleImePreeditEvent("に", 1);
    try std.testing.expect(state.imePreeditStartAdvance() > 0);
}

test "TextInputState: wrap display segment can fuse ime preedit text" {
    var doc = state_mod.TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText("abcd");

    var wrap = state_mod.TextareaWrapMap.init(std.testing.allocator, @import("std").testing.io);
    defer wrap.deinit();

    var state = TextInputState{
        .io = std.testing.io,
    };
    state.multiline = true;
    state.textarea_doc = &doc;
    state.textarea_wrap = &wrap;
    state.cursor_pos = 2;

    const ni = "\xe4\xbd\xa0";
    state.handleImePreeditEvent(ni, @as(u32, @intCast(ni.len)));
    const insert_off = state.imeInsertOffsetForDisplaySegment(&doc, 0, 0, 4) orelse unreachable;
    const fused = state.composeDisplaySegmentWithIme("abcd", insert_off);
    try std.testing.expect(std.mem.eql(u8, fused, "ab" ++ ni ++ "cd"));
}

test "Input: ime_commit dedupes same text_input" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "한" } }, ctx_ptr);
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = "한" } }, ctx_ptr);
    try std.testing.expectEqualStrings("한", state.getText());
}

test "TextInputState: cancelImeComposition clears selection highlight" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.handleImePreeditEvent("に", 1);
    state.markImeSelectionHighlight();
    try std.testing.expect(state.shouldShowImeSelectionHighlight());
    state.cancelImeComposition();
    try std.testing.expect(!state.shouldShowImeSelectionHighlight());
}

test "Input: allow space immediately after ime_commit" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    const ctx_ptr: ?*anyopaque = @ptrCast(&state);
    _ = events_mod.inputEventHandler(Event{ .ime_commit = .{ .text = "我" } }, ctx_ptr);
    _ = events_mod.inputEventHandler(Event{ .text_input = .{ .text = " " } }, ctx_ptr);
    try std.testing.expectEqualStrings("我 ", state.getText());
}

test "TextInputState: utf8 visual cursor uses codepoint count" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("我a");
    // buffer bytes = 4, codepoints = 2
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
    // display units: me=2, a=1
    try std.testing.expectEqual(@as(usize, 3), state.visualCursorPos());
    try std.testing.expectEqual(@as(usize, 2), state.displayedTextLen());
}

test "TextInputState: hitTestCursorPos maps visual column to utf8 byte offset" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("我a");
    state.container_x = 0;
    state.padding_h = 8.0;
    state.scroll_x = 0;
    state.char_width = 8.0;
    // Visual unit 2 (after a full-width CJK character) maps to utf8 byte offset 3
    const pos = state.hitTestCursorPos(24.0); // 8 (padding) + 8 * 2
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "TextInputState: deleteForward" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.moveToStart();
    state.deleteForward();
    try std.testing.expectEqualStrings("ello", state.getText());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
}

test "sanitizeInputText: filters escape sequences" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.input_type = .text;
    state.multiline = false;
    var buf: [256]u8 = undefined;
    const filtered = state_mod.sanitizeInputText(&state, "\x1b[D", buf[0..]);
    try std.testing.expectEqual(@as(usize, 0), filtered.len);
}

test "sanitizeInputText: newline is gated by accept_newline" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.input_type = .text;
    state.accept_newline = false;
    var buf: [256]u8 = undefined;
    const single_line = state_mod.sanitizeInputText(&state, "a\nb\r\nc", buf[0..]);
    try std.testing.expectEqualStrings("abc", single_line);
    state.accept_newline = true;
    const multi_line = state_mod.sanitizeInputText(&state, "a\nb\r\nc", buf[0..]);
    try std.testing.expectEqualStrings("a\nb\nc", multi_line);
}

test "TextInputState: soft wrap follows behavior config" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.multiline = true;
    state.soft_wrap = false;
    state.input_inner_w = 120;
    try std.testing.expect(!state.shouldSoftWrap());
    state.soft_wrap = true;
    try std.testing.expect(state.shouldSoftWrap());
    state.input_inner_w = 0;
    try std.testing.expect(!state.shouldSoftWrap());
}

test "TextInputState: findWordBoundaryLeft" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello world foo");
    try std.testing.expectEqual(@as(usize, 12), state.findWordBoundaryLeft(15));
    try std.testing.expectEqual(@as(usize, 6), state.findWordBoundaryLeft(11));
    try std.testing.expectEqual(@as(usize, 0), state.findWordBoundaryLeft(5));
    try std.testing.expectEqual(@as(usize, 0), state.findWordBoundaryLeft(0));
}

test "TextInputState: findWordBoundaryRight" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello world foo");
    try std.testing.expectEqual(@as(usize, 6), state.findWordBoundaryRight(0));
    try std.testing.expectEqual(@as(usize, 12), state.findWordBoundaryRight(6));
    try std.testing.expectEqual(@as(usize, 15), state.findWordBoundaryRight(12));
}

test "TextInputState: CJK findWordBoundaryLeft" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c");
    try std.testing.expectEqual(@as(usize, 9), state.findWordBoundaryLeft(12));
    try std.testing.expectEqual(@as(usize, 6), state.findWordBoundaryLeft(9));
    try std.testing.expectEqual(@as(usize, 3), state.findWordBoundaryLeft(6));
    try std.testing.expectEqual(@as(usize, 0), state.findWordBoundaryLeft(3));
}

test "TextInputState: CJK findWordBoundaryRight" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c");
    try std.testing.expectEqual(@as(usize, 3), state.findWordBoundaryRight(0));
    try std.testing.expectEqual(@as(usize, 6), state.findWordBoundaryRight(3));
    try std.testing.expectEqual(@as(usize, 9), state.findWordBoundaryRight(6));
    try std.testing.expectEqual(@as(usize, 12), state.findWordBoundaryRight(9));
}

test "TextInputState: CJK selectWordAt" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c");
    state.selectWordAt(3);
    try std.testing.expectEqual(@as(usize, 3), state.selection_anchor.?);
    try std.testing.expectEqual(@as(usize, 6), state.cursor_pos);
}

test "TextInputState: mixed CJK/ASCII word boundary" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello\xe4\xbd\xa0\xe5\xa5\xbd world");
    try std.testing.expectEqual(@as(usize, 5), state.findWordBoundaryLeft(8));
    try std.testing.expectEqual(@as(usize, 0), state.findWordBoundaryLeft(5));
}

test "TextInputState: selection collapse on left arrow" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.selection_anchor = 1;
    state.cursor_pos = 4;
    _ = state.handleKeyDown(.left, .{});
    try std.testing.expectEqual(@as(usize, 1), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);
}

test "TextInputState: selection collapse on right arrow" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.selection_anchor = 1;
    state.cursor_pos = 4;
    _ = state.handleKeyDown(.right, .{});
    try std.testing.expectEqual(@as(usize, 4), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);
}

test "TextInputState: Alt+Backspace deletes word" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello world");
    _ = state.handleKeyDown(.delete, .{ .alt = true });
    try std.testing.expectEqualStrings("hello ", state.getText());
}

test "TextInputState: Cmd+Backspace deletes to line start" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello world");
    state.cursor_pos = 7;
    _ = state.handleKeyDown(.delete, .{ .super = true });
    try std.testing.expectEqualStrings("orld", state.getText());
}

test "TextInputState: Alt+Right moves by word" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello world foo");
    state.cursor_pos = 0;
    _ = state.handleKeyDown(.right, .{ .alt = true });
    try std.testing.expectEqual(@as(usize, 6), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);
}

test "TextInputState: Alt+Left moves by word" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello world foo");
    _ = state.handleKeyDown(.left, .{ .alt = true });
    try std.testing.expectEqual(@as(usize, 12), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);
}

test "TextInputState: selectWordAt" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello world");
    state.selectWordAt(3);
    try std.testing.expectEqual(@as(?usize, 0), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "TextInputState: undo single insert" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    try std.testing.expectEqualStrings("hello", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
}

test "TextInputState: undo then redo" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
    state.redo();
    try std.testing.expectEqualStrings("hello", state.getText());
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "TextInputState: undo delete" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.deleteBackward();
    try std.testing.expectEqualStrings("hell", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("hello", state.getText());
}

test "TextInputState: new operation clears redo" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.undo();
    try std.testing.expectEqual(@as(u8, 1), state.redo_count);
    state.insertText("world");
    try std.testing.expectEqual(@as(u8, 0), state.redo_count);
}

test "TextInputState: multiple undo — 连续输入合并成一个单元" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    // Type three chars in succession (no cursor jump, no pause, no boundary char) -> merge as one
    // undo step
    state.insertText("a");
    state.insertText("b");
    state.insertText("c");
    try std.testing.expectEqualStrings("abc", state.getText());
    try std.testing.expectEqual(@as(u8, 1), state.undo_count);
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
}

test "undo 合并：光标跳转断开输入单元" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("ab");
    // Cursor jumps to start (simulate click/Home); next input must start new undo unit
    state.cursor_pos = 0;
    state.insertText("X");
    try std.testing.expectEqualStrings("Xab", state.getText());
    try std.testing.expectEqual(@as(u8, 2), state.undo_count);
    state.undo();
    try std.testing.expectEqualStrings("ab", state.getText());
}

test "undo 合并：空格/换行是硬边界" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    state.insertText(" "); // Boundary char forms its own undo step
    state.insertText("world");
    try std.testing.expectEqualStrings("hello world", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("hello ", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("hello", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
}

test "undo 合并：插入与退格是不同种类，互不合并" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("abc");
    state.deleteBackward();
    state.deleteBackward();
    try std.testing.expectEqualStrings("a", state.getText());
    // Two backspaces merge into one step; undo returns to "abc"
    state.undo();
    try std.testing.expectEqualStrings("abc", state.getText());
    state.undo();
    try std.testing.expectEqualStrings("", state.getText());
}

test "undo 合并：超时后断开（idle 阈值）" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("ab");
    // Invalidating merge anchor timestamp manually = simulating pause exceeding idle threshold
    state.undo_coalesce_at = null;
    state.insertText("cd");
    try std.testing.expectEqual(@as(u8, 2), state.undo_count);
    state.undo();
    try std.testing.expectEqualStrings("ab", state.getText());
}

test "undo 合并：栈深提高后能容纳更长历史" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    try std.testing.expectEqual(@as(usize, 64), TextInputState.UNDO_CAPACITY);
    // Each "w" + separator space = 2 undo units; 30 words = 60 units, still within 64-deep stack.
    // Old 32-deep stack lost half the early history, could not undo back to empty.
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        state.insertText("w");
        state.insertText(" ");
    }
    try std.testing.expectEqual(@as(u8, 60), state.undo_count);
    // Undo all the way back to empty text
    var guard: usize = 0;
    while (state.buffer_len > 0 and guard < 200) : (guard += 1) state.undo();
    try std.testing.expectEqualStrings("", state.getText());
}

test "TextInputState: getSelectedText" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello world");
    state.selection_anchor = 0;
    state.cursor_pos = 5;
    const sel = state.getSelectedText();
    try std.testing.expect(sel != null);
    try std.testing.expectEqualStrings("hello", sel.?);
    state.selection_anchor = null;
    try std.testing.expectEqual(@as(?[]const u8, null), state.getSelectedText());
}

test "TextInputState: Cmd+Z undo via handleKeyDown" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("hello");
    try std.testing.expectEqualStrings("hello", state.getText());
    _ = state.handleKeyDown(.z, .{ .super = true });
    try std.testing.expectEqualStrings("", state.getText());
    _ = state.handleKeyDown(.z, .{ .super = true, .shift = true });
    try std.testing.expectEqualStrings("hello", state.getText());
}

test "Textarea: multiline text input inserts and sets dirty" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.multiline = true;
    state.accept_newline = true;
    state.insertText("line1");
    try std.testing.expectEqualStrings("line1", state.getText());
    try std.testing.expect(state.dirty);
    state.dirty = false;
    state.insertText("\nline2");
    try std.testing.expectEqualStrings("line1\nline2", state.getText());
    try std.testing.expect(state.dirty);
    try std.testing.expectEqual(@as(usize, 11), state.cursor_pos);
}

test "Textarea: enter key inserts newline via sanitize" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.input_type = .text;
    state.accept_newline = true;
    var buf: [256]u8 = undefined;
    // When accept_newline=true, \n is retained
    const result = state_mod.sanitizeInputText(&state, "hello\nworld", buf[0..]);
    try std.testing.expectEqualStrings("hello\nworld", result);
    // When accept_newline=false, \n is filtered
    state.accept_newline = false;
    const result2 = state_mod.sanitizeInputText(&state, "hello\nworld", buf[0..]);
    try std.testing.expectEqualStrings("helloworld", result2);
}

test "Textarea: multiline cursor navigation across lines" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.multiline = true;
    state.accept_newline = true;
    state.insertText("abc\ndef\nghi");
    // Cursor at end (position 11)
    try std.testing.expectEqual(@as(usize, 11), state.cursor_pos);
    // Move to line start
    state.moveToStart();
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
    // Move to line end
    state.moveToEnd();
    try std.testing.expectEqual(@as(usize, 11), state.cursor_pos);
    // Move left 3 steps from end to 'g' in "ghi"
    state.moveCursor(-3, false);
    try std.testing.expectEqual(@as(usize, 8), state.cursor_pos);
}

test "Textarea: auxiliary nodes have zero rect by default" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const textarea_node = try Textarea(.{ .label_text = "Test", .rows = 4 }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, textarea_node);

    // Textarea wrapper's second child is field_shell; its textarea child is content container.
    // Textarea container holds VirtualList + overlay; auxiliary nodes in overlay
    // (selection/cursor/preedit_underline) should have zero rect.
    const field_shell = textarea_node.children.items[1]; // field_shell
    const textarea = field_shell.children.items[0]; // textarea box
    // Textarea should have 2 children: VirtualList container + overlay
    try std.testing.expect(textarea.children.items.len >= 2);
    // Overlay is last child
    const overlay = textarea.children.items[textarea.children.items.len - 1];
    for (overlay.children.items) |child| {
        // Auxiliary nodes have zero width and height initially
        try std.testing.expectEqual(@as(f32, 0), child.rectFromWorldOrFallback().w);
        try std.testing.expectEqual(@as(f32, 0), child.rectFromWorldOrFallback().h);
    }
}

// Single-line Input: programmatic writes, capacity, UTF-8 boundaries

test "Input.setText: 程序化替换内容（此前完全不可能）" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    state.insertText("old");
    try std.testing.expectEqualStrings("old", state.getText());

    // Form loaded from network: fill value after first frame. No API existed for this before the
    // fix.
    const n = state.setText("loaded from network");
    try std.testing.expectEqual(@as(usize, 19), n);
    try std.testing.expectEqualStrings("loaded from network", state.getText());
    // Cursor at end, selection cleared
    try std.testing.expectEqual(@as(usize, 19), state.cursor_pos);
    try std.testing.expectEqual(@as(?usize, null), state.selection_anchor);

    // Clear form after submit
    state.clearText();
    try std.testing.expectEqualStrings("", state.getText());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);

    // setText is undoable
    _ = state.handleKeyDown(.z, .{ .super = true });
    try std.testing.expectEqualStrings("loaded from network", state.getText());
}

test "Input: 容量上限支持超过旧 256 字节" {
    var state = TextInputState{
        .io = std.testing.io,
    };
    // 300-byte path; old 256B buffer insufficient
    var long: [300]u8 = undefined;
    @memset(&long, 'x');
    const n = state.setText(&long);
    try std.testing.expectEqual(@as(usize, 300), n);
    try std.testing.expectEqual(@as(usize, 300), state.getText().len);
}

test "Input: 超限截断落在 UTF-8 边界上，不产生半个字符" {
    var state = TextInputState{
        .io = std.testing.io,
    };

    // Construct pure CJK exceeding MAX_INPUT_BYTES (3 bytes per char)
    const cap = editable_block.MAX_INPUT_BYTES;
    var buf = @as(std.ArrayList(u8), .empty);
    defer buf.deinit(std.testing.allocator);
    while (buf.items.len < cap + 60) {
        try buf.appendSlice(std.testing.allocator, "中");
    }

    const n = state.setText(buf.items);
    try std.testing.expect(n <= cap);
    // Critical: written content must be valid UTF-8 (fix prevents cutting mid-char)
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.getText()));
    // 3-byte chars: truncation length must be multiple of 3
    try std.testing.expectEqual(@as(usize, 0), n % 3);

    // insertText path must also respect boundaries
    var s2 = TextInputState{
        .io = std.testing.io,
    };
    _ = s2.setText("");
    var i: usize = 0;
    while (i < cap + 60) : (i += 3) s2.insertText("中");
    try std.testing.expect(std.unicode.utf8ValidateSlice(s2.getText()));
}

// Test collection for styles.zig; this line is required, see docs/STYLING.md
test {
    _ = @import("styles.zig");
    _ = @import("edit_reconcile.zig");
    _ = @import("history_stash.zig");
}

test "mounted input reconversion cancels before commands blur and explicit replacement" {
    const t = std.testing;
    inline for (.{ false, true }) |independent| {
        var cx = try Cx.init(t.allocator, std.testing.io);
        defer cx.deinit();
        const root = try box(cx, .{ .width = .{ .px = 520 }, .height = .{ .px = 200 } }, .{});
        cx.root = root;
        const scope = try Scope.init(t.allocator, null, cx.owner);
        defer scope.dispose();
        const ta = @import("textarea.zig");
        const mounted = if (independent) try ta.Textarea(.{ .value = "x漢字y" }).mountResult(scope, cx) else try Input(.{ .value = "x漢字y" }).mountResult(scope, cx);
        try root.appendChild(t.allocator, if (independent) mounted.wrapper else mounted.node);
        const input = if (independent) mounted.input else mounted.input_container;
        const state = if (independent) mounted.state else @as(*TextInputState, @ptrCast(@alignCast(input.behavior.events.event_context.?)));
        const handler = if (independent) ta.textareaEventHandler else events_mod.inputEventHandler;
        cx.setFocus(input);
        if (independent) {
            state.cursor.offset = 8;
            state.cursor.anchor = 7;
        } else {
            state.cursor_pos = 8;
            state.selection_anchor = 7;
        }
        _ = handler(.{ .ime_preedit = .{ .text = "候", .cursor_utf8_offset = 3, .replace_start_utf8 = 1, .replace_end_utf8 = 7 } }, state);
        _ = handler(.{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } }, state);
        try t.expect(state.ime_replacement == null);
        try t.expectEqualStrings("x漢字y", state.getSelectedText().?);
        if (independent) {
            state.cursor.offset = 8;
            state.cursor.anchor = 7;
        } else {
            state.cursor_pos = 8;
            state.selection_anchor = 7;
        }
        _ = handler(.{ .ime_preedit = .{ .text = "候", .cursor_utf8_offset = 3, .replace_start_utf8 = 1, .replace_end_utf8 = 7 } }, state);
        _ = handler(.{ .key_down = .{ .key = .escape } }, state);
        try t.expectEqual(@as(usize, 8), if (independent) state.cursor.offset else state.cursor_pos);
        try t.expectEqual(@as(?usize, 7), if (independent) state.cursor.anchor else state.selection_anchor);
        _ = handler(.{ .ime_preedit = .{ .text = "候", .cursor_utf8_offset = 3, .replace_start_utf8 = 1, .replace_end_utf8 = 7 } }, state);
        cx.clearFocus();
        try t.expectEqualStrings("x漢字y", state.getText());
        try t.expectEqual(@as(?usize, null), if (independent) state.cursor.anchor else state.selection_anchor);
        try t.expect(!state.imeIsComposing());
        _ = handler(.{ .ime_preedit = .{ .text = "候", .cursor_utf8_offset = 3, .replace_start_utf8 = 1, .replace_end_utf8 = 7 } }, state);
        if (independent) try t.expect(state.setAccessibilityValue("done")) else _ = try state.setTextChecked("done");
        try t.expect(!state.imeIsComposing());
        try t.expect(state.ime_replacement == null);
        try t.expectEqualStrings("done", state.getText());
        state.undo();
        try t.expectEqualStrings("x漢字y", state.getText());
    }
}

// devtools mountPanel sweep caught leak in Input; the fixture was `Input(.{})`, which did not go
// through the leading_icon / placeholder / helper branches (the fixture decides coverage).
// Add a sweep that covers all branches.
test "Input: 带 leading_icon / placeholder / helper 的 mountResult 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("input(icon+helper)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const r = try Input(.{
                .placeholder = "Filter (tag, #id)...",
                .size = .sm,
                .leading_icon_asset = svg_assets.common.search,
                .helper = "helper",
            }).mountResult(scope, cx);
            return r.node;
        }
    }.m);
}

// Reference-checked OOM sweep (see oom_sweep.zig): a mount that reports success must look exactly
// like the uninjected mount; `check` also pins the states the reference was given.
test "input(invalid+icon): mount 成功即外观完整，任意分配点失败不假成功（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMountVerified("input(invalid+icon)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const invalid = try scope.createSignal(bool, true);
            const disabled = try scope.createSignal(bool, false);
            return (try Input(.{ .placeholder = "Search", .leading_icon_asset = svg_assets.common.search, .invalid = invalid, .disabled = disabled, .width = 200 }).mountResult(scope, cx)).node;
        }
    }.m, struct {
        fn field(n: *Node) ?*Node {
            if (n.tag == .input) return n;
            for (n.children.items) |c| if (field(c)) |f| return f;
            return null;
        }
        fn check(root: *Node) anyerror!void {
            const t = &core.theme.dark;
            const f = field(root) orelse return error.NoField;
            // the invalid frame (shell :invalid) landed at mount, over a laid-out field
            try std.testing.expect(Color.eql(t.tokens.color.danger, f.style.border.color));
            try std.testing.expect(f.style.border.width > 0);
            try std.testing.expect(f.style.effectiveRadii()[0] > 0);
            try std.testing.expect(f.style.padding.left > 0);
            try std.testing.expect(f.frame_state.frame_local.runtime.transitions != null);
        }
    }.check);
}

test "Input: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("input", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Input(.{}).mount(scope, cx);
        }
    }.m);
}

test "Input centers its text line for every control size and field height" {
    for ([_]InputSize{ .xs, .sm, .md, .lg }) |size| {
        var cx = try Cx.init(std.testing.allocator, std.testing.io);
        defer cx.deinit();
        cx.setViewport(500, 200);
        const scope = try Scope.init(cx.allocator, null, cx.owner);
        defer scope.dispose();
        const input = try Input(.{ .size = size, .width = 240, .placeholder = "https://" }).mountResult(scope, cx);
        cx.root = input.node;
        for (0..2) |frame| {
            if (frame == 1) {
                input.input_container.setStyleInline(cx.allocator, .{ .height = .{ .px = 56 } });
                _ = try input.state.setTextChecked("example.com");
            }
            cx.layout();
            _ = cx.render();
            cx.layout();
            _ = cx.render();
            const line = input.state.text_display_node.?.globalRect();
            const field = input.input_container.globalRect();
            try std.testing.expect(line.h > 0);
            try std.testing.expectApproxEqAbs(field.y + field.h / 2, line.y + line.h / 2, 0.01);
            const surface = input.state.text_display_node.?.parent.?;
            const local_line = input.state.text_display_node.?.rectFromWorldOrFallback();
            try std.testing.expectApproxEqAbs((surface.rectFromWorldOrFallback().h - line.h) / 2, local_line.y, 0.01);
        }
    }
}

test "growable Input initial display owns text across storage growth" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const allocator = failing.allocator();
    var cx = try Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{}, .{});
    cx.root = root;
    const scope = try Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const initial = (@as([("界").len * (1000)]u8, @bitCast(@as([1000][("界").len]u8, @splat(("界").*)))) ++ "");
    const mounted = try Input(.{ .value = initial, .growable = true }).mountResult(scope, cx);
    try root.appendChild(allocator, mounted.node);
    try t.expectEqualStrings(initial, mounted.state.getText());
    const node = mounted.state.text_display_node.?;
    try t.expect(node.getTextRaw().?.owned);
    const rendered = node.getText().?.content;
    try t.expect(rendered.ptr != mounted.state.getText().ptr);
    _ = try mounted.state.setTextChecked((@as([("a").len * (9000)]u8, @bitCast(@as([9000][("a").len]u8, @splat(("a").*)))) ++ ""));
    // Before a display refresh (which may itself fail), old pixels own bytes.
    try t.expectEqualStrings(initial, rendered);
    failing.fail_index = failing.alloc_index;
    try t.expect(!mounted.state.syncDisplayTextContent());
    try t.expect(failing.has_induced_failure);
    try t.expect(node.getTextRaw().?.owned);
    try t.expectEqualStrings(initial, node.getText().?.content);
    failing.fail_index = std.math.maxInt(usize);
    try t.expect(mounted.state.syncDisplayTextContent());
    try t.expect(node.getTextRaw().?.owned);
    try t.expectEqualStrings((@as([("a").len * (9000)]u8, @bitCast(@as([9000][("a").len]u8, @splat(("a").*)))) ++ ""), node.getText().?.content);
}

test "Input: display text written back by the render hook does not re-snapshot every frame" {
    // inputBeforeRender restyles the display text through getText() (a copy without ownership)
    // and setText(). An empty display (empty value, no placeholder) used to lose ownership on that
    // write-back, so every frame re-snapshotted it and marked sizing dirty: the app never went
    // idle and layout after the hook reset the caret to 0x0.
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{}, .{});
    cx.root = root;
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    for ([_][]const u8{ "", "abc" }) |initial| {
        const mounted = try Input(.{ .value = initial }).mountResult(scope, cx);
        try root.appendChild(t.allocator, mounted.node);
        const node = mounted.state.text_display_node.?;
        _ = mounted.state.syncDisplayTextContent();
        node.setText(node.getText().?);
        try t.expect(!mounted.state.syncDisplayTextContent());
    }
}

test "Input: 聚焦时先 dispose scope 再摘节点，blur 不碰已释放的 state" {
    // Notifier reply frame swaps content in place: dispose scope first (freeing TextInputState),
    // then
    // detachChildRetained/invalidateReferencesTo/clearFocus/on_blur. Real app SIGSEGV at
    // HandlerRef.invoke.
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 520 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const parent_scope = try Scope.init(alloc, null, ctx.owner);
    defer parent_scope.dispose();
    const content_scope = try parent_scope.childScope();

    const mounted = try Input(.{ .value = "hi" }).mountResult(content_scope, ctx);
    try root.appendChild(alloc, mounted.node);
    ctx.focus_manager.setFocus(mounted.input_container);
    try std.testing.expect(ctx.focus_manager.getFocused() == mounted.input_container);

    content_scope.dispose();
    core.clearNodeScopes(mounted.node);
    ctx.detachChildRetained(root, mounted.node);
    ctx.freeNode(mounted.node);
    try std.testing.expect(ctx.focus_manager.getFocused() == null);
}

// ========== Value binding (value: Model, docs/SIGNAL_API_DESIGN.md section 4.8) ==========

const BindEnv = struct {
    cx: *Cx,
    scope: *Scope,

    fn init() !BindEnv {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
        return .{ .cx = cx, .scope = try Scope.init(std.testing.allocator, null, cx.owner) };
    }

    fn deinit(self: BindEnv) void {
        self.scope.dispose();
        self.cx.deinit();
    }

    fn send(r: InputResult, ev: Event) void {
        _ = events_mod.inputEventHandler(ev, r.input_container.behavior.events.event_context);
    }
};

const ChangeSpy = struct {
    n: usize = 0,
    last: [64]u8 = undefined,
    last_len: usize = 0,
    submits: usize = 0,
    fn changed(self: *ChangeSpy, v: []const u8) void {
        self.n += 1;
        self.last_len = @min(v.len, self.last.len);
        @memcpy(self.last[0..self.last_len], v[0..self.last_len]);
    }
    fn submitted(self: *ChangeSpy, _: []const u8) void {
        self.submits += 1;
    }
    fn lastText(self: *const ChangeSpy) []const u8 {
        return self.last[0..self.last_len];
    }
};

test "Input value: 打字写回 signal 并以落地值回调；外部写入进缓冲、不回调" {
    const env = try BindEnv.init();
    defer env.deinit();
    var spy = ChangeSpy{};
    const v = try env.scope.createText("hi", .{});
    const r = try Input(.{ .value = v, .on_change = env.cx.on(ChangeSpy, &spy, ChangeSpy.changed) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    try std.testing.expectEqualStrings("hi", r.state.getText());
    try std.testing.expect(r.value.? == v);

    BindEnv.send(r, .{ .text_input = .{ .text = "!" } });
    try std.testing.expectEqualStrings("hi!", v.peek());
    try std.testing.expectEqual(@as(usize, 1), spy.n);
    try std.testing.expectEqualStrings("hi!", spy.lastText());

    v.set("reset");
    try std.testing.expectEqualStrings("reset", r.state.getText());
    try std.testing.expectEqual(@as(usize, 5), r.state.cursor_pos);
    try std.testing.expectEqual(@as(usize, 1), spy.n);

    // External writes are not undoable: Cmd+Z must not write "hi!" back to the data source as a
    // user edit
    BindEnv.send(r, .{ .key_down = .{ .key = .z, .modifiers = .{ .super = true } } });
    try std.testing.expectEqualStrings("reset", v.peek());
    try std.testing.expectEqualStrings("reset", r.state.getText());

    // Typing in the middle: the written-back value returns to the buffer via the effect with
    // identical content, so the cursor must stay at the insertion point (loop-breaking invariant 1)
    r.state.cursor_pos = 2;
    BindEnv.send(r, .{ .text_input = .{ .text = "X" } });
    try std.testing.expectEqualStrings("reXset", v.peek());
    try std.testing.expectEqual(@as(usize, 3), r.state.cursor_pos);
}

test "Input value: 组字中的外部写入推迟——提交丢弃（用户输入优先），取消后应用" {
    const env = try BindEnv.init();
    defer env.deinit();
    const v = try env.scope.createText("", .{});
    const r = try Input(.{ .value = v }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);

    // External write during composition: the buffer does not change
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "ni", .cursor_utf8_offset = 2 } });
    try std.testing.expect(r.state.imeIsComposing());
    v.set("external");
    try std.testing.expectEqualStrings("", r.state.getText());
    // Commit: the user's text is committed and written back; the deferred external write is voided
    BindEnv.send(r, .{ .ime_commit = .{ .text = "你" } });
    try std.testing.expectEqualStrings("你", r.state.getText());
    try std.testing.expectEqualStrings("你", v.peek());

    // Compose again, external write, cancel: after cancel, apply the data source's latest value
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "hao", .cursor_utf8_offset = 3 } });
    v.set("later");
    try std.testing.expectEqualStrings("你", r.state.getText());
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } });
    try std.testing.expect(!r.state.imeIsComposing());
    try std.testing.expectEqualStrings("later", r.state.getText());
}

test "Input value: ui.split 拒绝时缓冲退回数据源，不回调 on_change" {
    const env = try BindEnv.init();
    defer env.deinit();
    const Parent = struct {
        sig: *Signal([]const u8),
        /// Accepts only all-uppercase
        fn write(self: *@This(), x: []const u8) void {
            for (x) |c| if (std.ascii.isLower(c)) return;
            self.sig.set(x);
        }
    };
    var parent = Parent{ .sig = try env.scope.createText("AB", .{}) };
    var spy = ChangeSpy{};
    const r = try Input(.{
        .value = reactive.split(parent.sig, env.cx.on(Parent, &parent, Parent.write)),
        .on_change = env.cx.on(ChangeSpy, &spy, ChangeSpy.changed),
    }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    try std.testing.expect(r.value == null);
    BindEnv.send(r, .{ .text_input = .{ .text = "c" } });
    try std.testing.expectEqualStrings("AB", r.state.getText());
    try std.testing.expectEqual(@as(usize, 0), spy.n);
    BindEnv.send(r, .{ .text_input = .{ .text = "C" } });
    try std.testing.expectEqualStrings("ABC", r.state.getText());
    try std.testing.expectEqualStrings("ABC", parent.sig.peek());
    try std.testing.expectEqual(@as(usize, 1), spy.n);
}

// ---------- User edit rewritten / rejected by ui.split: fixed in place (binding.zig
// onBufferChanged) ----------

/// Parent component: uppercases the proposed value before it lands; rejects every write when
/// `accept = false`
const UpperParent = struct {
    sig: *Signal([]const u8),
    accept: bool = true,
    buf: [256]u8 = undefined,
    fn write(self: *@This(), x: []const u8) void {
        if (!self.accept) return;
        const n = @min(x.len, self.buf.len);
        for (x[0..n], 0..) |c, i| self.buf[i] = std.ascii.toUpper(c);
        self.sig.set(self.buf[0..n]);
    }
};

/// Parent component: keeps digits only
const DigitsParent = struct {
    sig: *Signal([]const u8),
    buf: [256]u8 = undefined,
    fn write(self: *@This(), x: []const u8) void {
        var n: usize = 0;
        for (x) |c| if (std.ascii.isDigit(c) and n < self.buf.len) {
            self.buf[n] = c;
            n += 1;
        };
        self.sig.set(self.buf[0..n]);
    }
};

/// Parent component: rejects the whole proposal if it contains lowercase letters (rejects
/// everything when `accept = false`)
const UpperOnlyParent = struct {
    sig: *Signal([]const u8),
    accept: bool = true,
    fn write(self: *@This(), x: []const u8) void {
        if (!self.accept) return;
        for (x) |c| if (std.ascii.isLower(c)) return;
        self.sig.set(x);
    }
};

const undo_key = Event{ .key_down = .{ .key = .z, .modifiers = .{ .super = true } } };
const redo_key = Event{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = true } } };

fn expectCaret(r: InputResult, text: []const u8, cursor: usize, anchor: ?usize) !void {
    try std.testing.expectEqualStrings(text, r.state.getText());
    try std.testing.expectEqual(cursor, r.state.cursor_pos);
    try std.testing.expectEqual(anchor, r.state.selection_anchor);
}

test "Input value: split 大写化中间插入——光标留在插入点后，撤销回到编辑前（batch 内外）" {
    inline for (.{ false, true }) |batched| {
        const env = try BindEnv.init();
        defer env.deinit();
        var parent = UpperParent{ .sig = try env.scope.createText("ABCD", .{}) };
        var spy = ChangeSpy{};
        const r = try Input(.{
            .value = reactive.split(parent.sig, env.cx.on(UpperParent, &parent, UpperParent.write)),
            .on_change = env.cx.on(ChangeSpy, &spy, ChangeSpy.changed),
        }).mountResult(env.scope, env.cx);
        defer env.cx.freeNode(r.node);
        r.state.cursor_pos = 2;

        // A real event runs inside the owner batch: valueEffect is deferred to the end of the
        // batch, so the fix must already be applied at the exit
        if (batched) env.cx.owner.beginBatch();
        BindEnv.send(r, .{ .text_input = .{ .text = "x" } });
        try expectCaret(r, "ABXCD", 3, null);
        BindEnv.send(r, .{ .text_input = .{ .text = "y" } });
        try expectCaret(r, "ABXYCD", 4, null);
        if (batched) env.cx.owner.endBatch();
        try expectCaret(r, "ABXYCD", 4, null);
        try std.testing.expectEqualStrings("ABXYCD", parent.sig.peek());
        // on_change receives the landed value, and the buffer already equals it at callback time
        try std.testing.expectEqual(@as(usize, 2), spy.n);
        try std.testing.expectEqualStrings("ABXYCD", spy.lastText());
        // Consecutive input merges into the same undo unit; undo history is not cleared
        try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);

        BindEnv.send(r, undo_key);
        try expectCaret(r, "ABCD", 2, null);
        try std.testing.expectEqualStrings("ABCD", parent.sig.peek());
        BindEnv.send(r, redo_key);
        try expectCaret(r, "ABXYCD", 4, null);
        try std.testing.expectEqualStrings("ABXYCD", parent.sig.peek());
    }
}

test "Input value: split 过滤——混合输入只留数字，光标落在保留内容后，继续输入仍并入同一撤销单元" {
    inline for (.{ false, true }) |batched| {
        const env = try BindEnv.init();
        defer env.deinit();
        var parent = DigitsParent{ .sig = try env.scope.createText("1290", .{}) };
        const r = try Input(.{ .value = reactive.split(parent.sig, env.cx.on(DigitsParent, &parent, DigitsParent.write)) }).mountResult(env.scope, env.cx);
        defer env.cx.freeNode(r.node);
        r.state.cursor_pos = 2;

        if (batched) env.cx.owner.beginBatch();
        BindEnv.send(r, .{ .text_input = .{ .text = "a3b4" } });
        try expectCaret(r, "123490", 4, null);
        BindEnv.send(r, .{ .text_input = .{ .text = "5" } });
        try expectCaret(r, "1234590", 5, null);
        if (batched) env.cx.owner.endBatch();
        try std.testing.expectEqualStrings("1234590", parent.sig.peek());
        try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);

        BindEnv.send(r, undo_key);
        try expectCaret(r, "1290", 2, null);
        try std.testing.expectEqualStrings("1290", parent.sig.peek());
    }
}

test "Input value: split 拒绝——选区回到编辑前、不留撤销条目、合并链不断（batch 内外）" {
    inline for (.{ false, true }) |batched| {
        const env = try BindEnv.init();
        defer env.deinit();
        var parent = UpperOnlyParent{ .sig = try env.scope.createText("ABC", .{}) };
        var spy = ChangeSpy{};
        const r = try Input(.{
            .value = reactive.split(parent.sig, env.cx.on(UpperOnlyParent, &parent, UpperOnlyParent.write)),
            .on_change = env.cx.on(ChangeSpy, &spy, ChangeSpy.changed),
        }).mountResult(env.scope, env.cx);
        defer env.cx.freeNode(r.node);

        if (batched) env.cx.owner.beginBatch();
        // No selection: the cursor stays in place and the undo stack is empty
        r.state.cursor_pos = 1;
        BindEnv.send(r, .{ .text_input = .{ .text = "x" } });
        try expectCaret(r, "ABC", 1, null);
        try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
        // Selection replacement rejected: the selection is restored as-is
        r.state.selection_anchor = 1;
        r.state.cursor_pos = 2;
        BindEnv.send(r, .{ .text_input = .{ .text = "q" } });
        try expectCaret(r, "ABC", 2, 1);
        try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
        // Accepted input: starts a new undo unit
        r.state.selection_anchor = null;
        BindEnv.send(r, .{ .text_input = .{ .text = "Z" } });
        try expectCaret(r, "ABZC", 3, null);
        try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);
        // A rejected key in a merge chain: no push, no break in merging (the next key still merges
        // into the "Z" unit)
        BindEnv.send(r, .{ .text_input = .{ .text = "y" } });
        try expectCaret(r, "ABZC", 3, null);
        BindEnv.send(r, .{ .text_input = .{ .text = "W" } });
        try expectCaret(r, "ABZWC", 4, null);
        try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);
        if (batched) env.cx.owner.endBatch();
        try std.testing.expectEqualStrings("ABZWC", parent.sig.peek());
        try std.testing.expectEqual(@as(usize, 2), spy.n);

        // Rejected backspace: the cursor does not move and the undo stack is unchanged
        parent.accept = false;
        BindEnv.send(r, .{ .key_down = .{ .key = .delete } });
        try expectCaret(r, "ABZWC", 4, null);
        try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);
        // Rejected undo: the inverse operation restores both stacks
        BindEnv.send(r, undo_key);
        try expectCaret(r, "ABZWC", 4, null);
        try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);
        try std.testing.expectEqual(@as(u8, 0), r.state.redo_count);
        parent.accept = true;
        BindEnv.send(r, undo_key);
        try expectCaret(r, "ABC", 2, null);
        try std.testing.expectEqualStrings("ABC", parent.sig.peek());
    }
}

test "Input value: split 下的外部写入语义不变——整段替换、光标到末尾、清撤销、不回调" {
    const env = try BindEnv.init();
    defer env.deinit();
    var parent = UpperParent{ .sig = try env.scope.createText("AB", .{}) };
    var spy = ChangeSpy{};
    const r = try Input(.{
        .value = reactive.split(parent.sig, env.cx.on(UpperParent, &parent, UpperParent.write)),
        .on_change = env.cx.on(ChangeSpy, &spy, ChangeSpy.changed),
    }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    r.state.cursor_pos = 1;
    BindEnv.send(r, .{ .text_input = .{ .text = "x" } });
    try expectCaret(r, "AXB", 2, null);
    try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);

    parent.sig.set("external");
    try expectCaret(r, "external", 8, null);
    try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
    try std.testing.expectEqual(@as(usize, 1), spy.n);

    // Same for external writes inside a batch (the effect is applied at the end of the batch)
    env.cx.owner.beginBatch();
    parent.sig.set("later");
    try expectCaret(r, "external", 8, null);
    env.cx.owner.endBatch();
    try expectCaret(r, "later", 5, null);
    try std.testing.expectEqual(@as(usize, 1), spy.n);
}

test "Input value: IME 提交被改写 / 拒绝——光标按提交点映射；组字中的外部写入仍按外部写入对齐" {
    const env = try BindEnv.init();
    defer env.deinit();
    var parent = UpperParent{ .sig = try env.scope.createText("AB", .{}) };
    const r = try Input(.{ .value = reactive.split(parent.sig, env.cx.on(UpperParent, &parent, UpperParent.write)) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);

    // Composition committed in the middle and uppercased: the cursor lands after the committed
    // content
    r.state.cursor_pos = 1;
    env.cx.owner.beginBatch();
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "x", .cursor_utf8_offset = 1 } });
    BindEnv.send(r, .{ .ime_commit = .{ .text = "xy" } });
    try expectCaret(r, "AXYB", 3, null);
    env.cx.owner.endBatch();
    try std.testing.expectEqualStrings("AXYB", parent.sig.peek());

    // External write deferred during composition; parent rewrites after commit - the baseline is
    // not the data source's value, align it as an external write
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "q", .cursor_utf8_offset = 1 } });
    parent.sig.set("EXT");
    try std.testing.expectEqualStrings("AXYB", r.state.getText());
    BindEnv.send(r, .{ .ime_commit = .{ .text = "q" } });
    try std.testing.expectEqualStrings(parent.sig.peek(), r.state.getText());
    try std.testing.expectEqual(r.state.getText().len, r.state.cursor_pos);
    try std.testing.expect(!r.state.imeIsComposing());

    // After a deferred external write is voided by a commit that landed as-is, rewrites of later
    // edits go back to mapping by edit point
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "k", .cursor_utf8_offset = 1 } });
    parent.sig.set("STALE");
    BindEnv.send(r, .{ .ime_commit = .{ .text = "K" } });
    try std.testing.expectEqualStrings(parent.sig.peek(), r.state.getText());
    const before_len = r.state.getText().len;
    r.state.cursor_pos = 1;
    BindEnv.send(r, .{ .text_input = .{ .text = "m" } });
    try std.testing.expectEqual(@as(usize, 2), r.state.cursor_pos);
    try std.testing.expectEqual(before_len + 1, r.state.getText().len);
    try std.testing.expectEqual(@as(u8, 'M'), r.state.getText()[1]);

    // Cancelling composition still re-reads the data source (nothing changes when there is no
    // deferred write)
    r.state.cursor_pos = 1;
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "z", .cursor_utf8_offset = 1 } });
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } });
    try std.testing.expectEqual(@as(usize, 1), r.state.cursor_pos);
    try std.testing.expectEqualStrings(parent.sig.peek(), r.state.getText());
}

test "Input value: split 拒绝——重做栈与栈满淘汰的撤销条目完整还原（被拒绝 = 什么都没发生）" {
    const env = try BindEnv.init();
    defer env.deinit();
    var parent = UpperOnlyParent{ .sig = try env.scope.createText("A", .{}) };
    const r = try Input(.{ .value = reactive.split(parent.sig, env.cx.on(UpperOnlyParent, &parent, UpperOnlyParent.write)) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    const s = r.state;
    s.cursor_pos = 1;

    // Redo stack: a rejected edit after one undo must not clear it
    BindEnv.send(r, .{ .text_input = .{ .text = "B" } });
    BindEnv.send(r, undo_key);
    try expectCaret(r, "A", 1, null);
    try std.testing.expectEqual(@as(u8, 1), s.redo_count);
    const redo_ptr = s.redo_stack[0].text.?.ptr;
    BindEnv.send(r, .{ .text_input = .{ .text = "c" } });
    try expectCaret(r, "A", 1, null);
    try std.testing.expectEqual(@as(u8, 1), s.redo_count);
    try std.testing.expectEqual(redo_ptr, s.redo_stack[0].text.?.ptr);
    BindEnv.send(r, redo_key);
    try expectCaret(r, "AB", 2, null);
    try std.testing.expectEqualStrings("AB", parent.sig.peek());

    // Undo stack full: the oldest entry evicted when a rejected edit is pushed must be put back
    const cap = TextInputState.UNDO_CAPACITY;
    while (s.undo_count < cap) BindEnv.send(r, .{ .text_input = .{ .text = " " } });
    BindEnv.send(r, .{ .text_input = .{ .text = " " } }); // Push once more; the stack bottom has rolled
    const bottom_ptr = s.undo_stack[0].text.?.ptr;
    const top_ptr = s.undo_stack[cap - 1].text.?.ptr;
    const text_before = try std.testing.allocator.dupe(u8, s.getText());
    defer std.testing.allocator.free(text_before);
    BindEnv.send(r, .{ .text_input = .{ .text = "z" } });
    try std.testing.expectEqualStrings(text_before, s.getText());
    try std.testing.expectEqual(@as(u8, @intCast(cap)), s.undo_count);
    try std.testing.expectEqual(bottom_ptr, s.undo_stack[0].text.?.ptr);
    try std.testing.expectEqual(top_ptr, s.undo_stack[cap - 1].text.?.ptr);
    try std.testing.expectEqual(@as(u8, 0), s.redo_count);
    try std.testing.expect(s.undo_stash.isEmpty());

    // After an accepted edit clears the redo stack, a later rejected edit must not resurrect old
    // redo entries
    BindEnv.send(r, undo_key);
    try std.testing.expectEqual(@as(u8, 1), s.redo_count);
    BindEnv.send(r, .{ .text_input = .{ .text = "Q" } });
    try std.testing.expectEqual(@as(u8, 0), s.redo_count);
    BindEnv.send(r, .{ .text_input = .{ .text = "q" } });
    try std.testing.expectEqual(@as(u8, 0), s.redo_count);
}

test "Input value: 父组件在 on_change 里对同一输入再编辑并被拒——只回滚这一次，前一次已落地的编辑保留" {
    const env = try BindEnv.init();
    defer env.deinit();
    var parent = UpperOnlyParent{ .sig = try env.scope.createText("AB", .{}) };
    const Hook = struct {
        state: ?*TextInputState = null,
        fired: bool = false,
        fn changed(self: *@This(), _: []const u8) void {
            if (self.fired) return;
            self.fired = true;
            const st = self.state.?;
            // Programmatically append a lowercase character (the parent will reject it) and go
            // through the edit exit
            st.insertText("q");
            st.on_change.?.invokeWithStr(st.getText());
        }
    };
    var hook = Hook{};
    const r = try Input(.{
        .value = reactive.split(parent.sig, env.cx.on(UpperOnlyParent, &parent, UpperOnlyParent.write)),
        .on_change = env.cx.on(Hook, &hook, Hook.changed),
    }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    hook.state = r.state;
    r.state.cursor_pos = 1;
    BindEnv.send(r, .{ .text_input = .{ .text = "X" } });
    try std.testing.expect(hook.fired);
    try expectCaret(r, "AXB", 2, null);
    try std.testing.expectEqualStrings("AXB", parent.sig.peek());
    try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);
    BindEnv.send(r, undo_key);
    try expectCaret(r, "AB", 1, null);
}

test "Input value: 同一 batch 里外部写入未应用就发生编辑——不一致按外部写入对齐，不误判为拒绝" {
    const env = try BindEnv.init();
    defer env.deinit();
    var parent = UpperOnlyParent{ .sig = try env.scope.createText("ABC", .{}) };
    const r = try Input(.{ .value = reactive.split(parent.sig, env.cx.on(UpperOnlyParent, &parent, UpperOnlyParent.write)) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    r.state.cursor_pos = 1;
    BindEnv.send(r, .{ .text_input = .{ .text = "Q" } });
    try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);

    env.cx.owner.beginBatch();
    parent.sig.set("EXTERNAL"); // valueEffect deferred to end of batch
    parent.accept = false;
    BindEnv.send(r, .{ .text_input = .{ .text = "x" } });
    // External write semantics: replace the whole text, cursor to end, clear undo; not "return to
    // the pre-edit selection"
    try expectCaret(r, "EXTERNAL", 8, null);
    try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
    env.cx.owner.endBatch();
    try expectCaret(r, "EXTERNAL", 8, null);

    // In-place fixing resumes after alignment
    parent.accept = true;
    r.state.cursor_pos = 2;
    BindEnv.send(r, .{ .text_input = .{ .text = "y" } });
    try expectCaret(r, "EXTERNAL", 2, null);
    try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
}

test "Input value: 数据源超出定长缓冲被截断后，被拒的编辑仍就地恢复（不会每键跳尾）" {
    const env = try BindEnv.init();
    defer env.deinit();
    const long = (@as([("A").len * ((editable_block.MAX_INPUT_BYTES + 16))]u8, @bitCast(@as([(editable_block.MAX_INPUT_BYTES + 16)][("A").len]u8, @splat(("A").*)))) ++ "");
    var parent = UpperOnlyParent{ .sig = try env.scope.createText(long, .{}), .accept = false };
    const r = try Input(.{ .value = reactive.split(parent.sig, env.cx.on(UpperOnlyParent, &parent, UpperOnlyParent.write)) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    try std.testing.expectEqual(editable_block.MAX_INPUT_BYTES, r.state.getText().len);
    // Buffer is full: delete one character first, then insert (both rejected)
    r.state.cursor_pos = 5;
    BindEnv.send(r, .{ .key_down = .{ .key = .delete } });
    try std.testing.expectEqual(@as(usize, 5), r.state.cursor_pos);
    try std.testing.expectEqual(editable_block.MAX_INPUT_BYTES, r.state.getText().len);
    try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
    BindEnv.send(r, .{ .key_down = .{ .key = .delete } });
    try std.testing.expectEqual(@as(usize, 5), r.state.cursor_pos);
    try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
}

test "Input value: AX 写值是用户编辑——被 split 改写后可撤销回写值之前" {
    const env = try BindEnv.init();
    defer env.deinit();
    var parent = UpperParent{ .sig = try env.scope.createText("AB", .{}) };
    const r = try Input(.{ .value = reactive.split(parent.sig, env.cx.on(UpperParent, &parent, UpperParent.write)) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    const surface = r.state.text_display_node.?.parent.?;
    surface.meta.per_frame.hooks.before_render.main.?(surface);
    const editable = r.input_container.behavior.interaction.a11y.?.editable_text.?;
    try std.testing.expect(editable.set_value.?(editable.context, "abc"));
    try expectCaret(r, "ABC", 3, null);
    try std.testing.expectEqualStrings("ABC", parent.sig.peek());
    try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);
    BindEnv.send(r, undo_key);
    try expectCaret(r, "AB", 2, null);
    try std.testing.expectEqualStrings("AB", parent.sig.peek());
}

test "Input value: 组字中有推迟的外部写入时，AX 写值以 AX 的值为准（不被推迟的外部值覆盖）" {
    inline for (.{ false, true }) |batched| {
        const env = try BindEnv.init();
        defer env.deinit();
        var spy = ChangeSpy{};
        const v = try env.scope.createText("old", .{});
        const r = try Input(.{ .value = v, .on_change = env.cx.on(ChangeSpy, &spy, ChangeSpy.changed) }).mountResult(env.scope, env.cx);
        defer env.cx.freeNode(r.node);
        const surface = r.state.text_display_node.?.parent.?;
        surface.meta.per_frame.hooks.before_render.main.?(surface);
        const editable = r.input_container.behavior.interaction.a11y.?.editable_text.?;

        BindEnv.send(r, .{ .ime_preedit = .{ .text = "ni", .cursor_utf8_offset = 2 } });
        v.set("external"); // During composition: deferred
        try std.testing.expectEqualStrings("old", r.state.getText());
        if (batched) env.cx.owner.beginBatch();
        try std.testing.expect(editable.set_value.?(editable.context, "typed"));
        try std.testing.expectEqualStrings("typed", r.state.getText());
        if (batched) env.cx.owner.endBatch();
        try std.testing.expectEqualStrings("typed", r.state.getText());
        try std.testing.expectEqualStrings("typed", v.peek());
        try std.testing.expect(!r.state.imeIsComposing());
        try std.testing.expectEqual(@as(usize, 1), spy.n);
        try std.testing.expectEqualStrings("typed", spy.lastText());
        // AX value writes are undoable, returning to the text in the buffer before the write
        BindEnv.send(r, undo_key);
        try std.testing.expectEqualStrings("old", r.state.getText());
        try std.testing.expectEqualStrings("old", v.peek());
    }
}

test "Input value: 组字重转换的提交被拒——选区回到组字开始前（同取消组字）" {
    const env = try BindEnv.init();
    defer env.deinit();
    var parent = UpperOnlyParent{ .sig = try env.scope.createText("ABC", .{}) };
    const r = try Input(.{ .value = reactive.split(parent.sig, env.cx.on(UpperOnlyParent, &parent, UpperOnlyParent.write)) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    r.state.cursor_pos = 3;
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "a", .cursor_utf8_offset = 1, .replace_start_utf8 = 0, .replace_end_utf8 = 1 } });
    try std.testing.expect(r.state.ime_replacement != null);
    BindEnv.send(r, .{ .ime_commit = .{ .text = "q" } });
    try expectCaret(r, "ABC", 3, null);
    try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
    try std.testing.expect(!r.state.imeIsComposing());
}

test "Input: on_submit 在 Enter 时以当前文本调用；组字中的 Enter 不提交；不设时 Enter 冒泡" {
    const env = try BindEnv.init();
    defer env.deinit();
    var spy = ChangeSpy{};
    const r = try Input(.{ .value = "go", .on_submit = env.cx.on(ChangeSpy, &spy, ChangeSpy.submitted) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    const enter = Event{ .key_down = .{ .key = .@"return", .modifiers = .{} } };
    BindEnv.send(r, enter);
    try std.testing.expectEqual(@as(usize, 1), spy.submits);
    BindEnv.send(r, .{ .ime_preedit = .{ .text = "x", .cursor_utf8_offset = 1 } });
    BindEnv.send(r, enter);
    try std.testing.expectEqual(@as(usize, 1), spy.submits);

    const plain = try Input(.{}).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(plain.node);
    try std.testing.expectEqual(EventResult.ignored, events_mod.inputEventHandler(enter, plain.input_container.behavior.events.event_context));
}

test "Input value: 绑定的 signal 不是 createText 创建的 -> 拒绝" {
    const env = try BindEnv.init();
    defer env.deinit();
    const borrowed = try env.scope.createSignal([]const u8, "x");
    try std.testing.expectError(error.TextModelNotOwned, Input(.{ .value = borrowed }).mountResult(env.scope, env.cx));
}

test "input(bound value): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("input(bound)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const v = try scope.createText("hello", .{});
            return (try Input(.{ .value = v, .label_text = "Name", .helper = "h" }).mountResult(scope, cx)).node;
        }
    }.m);
}

test "Input chrome: 标签 / 辅助 / 错误 / 占位符来自 signal —— 跟随变化，错误态同步 a11y 与文字颜色" {
    const env = try BindEnv.init();
    defer env.deinit();
    const label = try env.scope.createText("Email", .{});
    const helper = try env.scope.createText("We never share it", .{});
    const err = try env.scope.createText("", .{});
    const ph = try env.scope.createText("you@example.com", .{});
    const r = try Input(.{ .label_text = label, .helper = helper, .error_msg = err, .placeholder = ph }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    const a11y = &r.input_container.behavior.interaction.a11y.?;
    const label_row = r.node.children.items[0];
    const helper_node = r.node.children.items[r.node.children.items.len - 1];
    try std.testing.expectEqualStrings("Email", a11y.label.?);
    try std.testing.expectEqualStrings("We never share it", helper_node.getText().?.content);
    try std.testing.expectEqualStrings("you@example.com", r.state.placeholder_text.?);
    try std.testing.expect(!a11y.invalid);

    err.set("Invalid address");
    try std.testing.expect(r.state.has_error);
    try std.testing.expect(a11y.invalid);
    try std.testing.expectEqualStrings("Invalid address", helper_node.getText().?.content);
    try std.testing.expect(helper_node.getText().?.color.eql(env.cx.tokens.tokens.color.danger));
    err.set("");
    try std.testing.expect(!r.state.has_error and !a11y.invalid);
    try std.testing.expectEqualStrings("We never share it", helper_node.getText().?.content);

    helper.set("");
    try std.testing.expectEqual(core.Display.none, helper_node.style.display);
    label.set("Work email");
    try std.testing.expectEqualStrings("Work email", a11y.label.?);
    label.set("");
    try std.testing.expectEqual(core.Display.none, label_row.style.display);
    ph.set("name@company.com");
    try std.testing.expectEqualStrings("name@company.com", r.state.placeholder_text.?);
    try std.testing.expectEqualStrings("name@company.com", a11y.placeholder.?);
}

test "Input chrome: disabled 来自 signal —— 禁用时忽略输入、不可聚焦、撤掉焦点；恢复后照常编辑" {
    const env = try BindEnv.init();
    defer env.deinit();
    const d = try env.scope.createSignal(bool, false);
    const v = try env.scope.createText("", .{});
    const r = try Input(.{ .value = v, .disabled = d }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.node);
    try env.cx.root.?.appendChild(env.cx.allocator, r.node);
    env.cx.setFocus(r.input_container);
    try std.testing.expect(env.cx.focus_manager.getFocused() == r.input_container);

    d.set(true);
    try std.testing.expect(env.cx.focus_manager.getFocused() == null);
    try std.testing.expect(r.input_container.behavior.interaction.a11y.?.disabled);
    try std.testing.expectEqual(EventResult.ignored, events_mod.inputEventHandler(.{ .text_input = .{ .text = "x" } }, r.input_container.behavior.events.event_context));
    try std.testing.expectEqualStrings("", v.peek());

    d.set(false);
    BindEnv.send(r, .{ .text_input = .{ .text = "x" } });
    try std.testing.expectEqualStrings("x", v.peek());
    try std.testing.expect(!r.input_container.behavior.interaction.a11y.?.disabled);
    env.cx.detachChild(env.cx.root.?, r.node);
}

test "input(dynamic chrome): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("input(chrome)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const label = try scope.createText("Name", .{});
            const err = try scope.createText("bad", .{});
            const ph = try scope.createText("type", .{});
            const d = try scope.createSignal(bool, true);
            return (try Input(.{ .label_text = label, .error_msg = err, .placeholder = ph, .disabled = d, .leading_icon_asset = @import("zenit_system_icons").search }).mountResult(scope, cx)).node;
        }
    }.m);
}

test "readonly Input mount routes selection and focus without a native text client" {
    const cx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(cx.allocator, null, cx.owner);
    defer scope.dispose();
    const mounted = try Input(.{ .readonly = true, .value = "中文 🧪" }).mountResult(scope, cx);
    cx.root = mounted.node;
    try std.testing.expect(mounted.state.readonly);
    try std.testing.expect(mounted.input_container.behavior.events.on_event == events_mod.inputFieldEventHandler);
    try std.testing.expect(mounted.input_container.behavior.interaction.text_input_client == null);
    cx.setFocus(mounted.input_container);
    try std.testing.expect(mounted.state.focused);
    _ = events_mod.inputEventHandler(.{ .key_down = .{ .key = .a, .modifiers = .{ .super = true } } }, mounted.state);
    try std.testing.expectEqualStrings("中文 🧪", mounted.state.getSelectedText().?);
    _ = events_mod.inputEventHandler(.{ .text_input = .{ .text = "changed" } }, mounted.state);
    try std.testing.expectEqualStrings("中文 🧪", mounted.state.getText());
    cx.clearFocus();
    try std.testing.expect(!mounted.state.focused);
}

test "review regression 4: static disabled border wins over populated and invalid" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var custom = core.theme.high_contrast;
    custom.tokens.color.border = Color.hex(0x123456);
    custom.tokens.color.border_strong = Color.hex(0x654321);
    cx.setTheme(&custom);
    for ([_][]const u8{ "", "error" }) |error_msg| {
        const r = try Input(.{ .disabled = true, .value = "text", .error_msg = error_msg }).mountResult(scope, cx);
        defer cx.freeNode(r.node);
        const slot = r.input_container.frame_state.frame_local.runtime.transitions.?.find(.border_color).?;
        try std.testing.expectEqual(cx.tokens.tokens.color.border, if (slot.active) slot.to_color else r.input_container.style.border.color);
    }
}

test "review regression 7: textarea one row is shorter than two" {
    const t = &core.theme.light;
    try std.testing.expect(styles.textareaMetrics(t, null, 1).height < styles.textareaMetrics(t, null, 2).height);
    inline for (.{ .xs, .sm, .md, .lg }) |size| {
        try std.testing.expect(styles.textareaMetrics(t, size, 1).height < styles.textareaMetrics(t, size, 2).height);
    }
    try std.testing.expectEqual(@as(f32, 100), styles.textareaMetrics(t, null, 4).height);
}
