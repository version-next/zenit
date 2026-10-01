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
const Cx = core.Cx;
const Node = core.Node;
const Scope = @import("../../reactive.zig").Scope;

const state_mod = @import("state.zig");
const render_mod = @import("render.zig");
const events_mod = @import("events.zig");
const editable_block = @import("../editable_block/mod.zig");
const TextInputState = state_mod.TextInputState;

pub const EditableTextProps = struct {
    /// Initial text, copied during mount.
    value: ?[]const u8 = null,
    font_size: f32 = 14,
    /// Line-height multiplier.
    line_height: f32 = 1.25,
    /// null means grow to the width offered by the parent.
    width: ?f32 = null,
    /// Enable multiline editing and soft wrapping at this fixed width. null
    /// preserves the original single-line behavior. When set, this takes
    /// precedence over `width` and the node height grows with visual lines.
    wrap_width: ?f32 = null,
    /// Receives the current internal text slice; retainers must copy it.
    on_change: ?core.HandlerRef = null,
};

pub const EditableTextResult = struct {
    node: *Node,
    state: *TextInputState,

    /// Enter or leave editing mode. Leaving editing mode also ends IME and
    /// removes selection state. Repeated calls with the same value are cheap.
    pub fn setEditing(self: EditableTextResult, cx: *Cx, editing: bool) void {
        const currently_editing = self.node.behavior.events.on_event != null;
        if (editing == currently_editing) return;

        if (editing) {
            self.node.behavior.events.on_event = events_mod.inputEventHandler;
            self.node.behavior.interaction.text_input_client = render_mod.textInputClient(self.state);
            self.node.setFocusable(true);
            cx.setFocus(self.node);
        } else {
            if (cx.isFocused(self.node)) cx.clearFocus();
            self.state.focused = false;
            self.state.cancelImeComposition();
            self.state.selection_anchor = null;
            self.state.is_dragging = false;
            self.state.suspend_drag_until_mouse_up = false;
            self.node.behavior.events.on_event = null;
            self.node.behavior.interaction.text_input_client = null;
            self.node.setFocusable(false);
        }
        cx.refreshTextInputSession();
        self.node.markRenderDirty();
    }

    /// Update runtime font metrics. This is idempotent and safe to call from a
    /// canvas zoom loop. `line_height_ratio` is a multiplier, not pixels.
    pub fn setMetrics(self: EditableTextResult, font_size: f32, line_height_ratio: f32) void {
        const safe_font_size = @max(font_size, 1);
        const safe_ratio = @max(line_height_ratio, 0.1);
        // 不取整：静态文本布局的行高是 font_size × ratio（text_layout.zig），
        // 这里 ceil 会让编辑态行距偏大最多 1px/行，宿主的静态/编辑双态
        // 切换（画布双击进编辑）在非整数行高的缩放档位下整段文字跳动。
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
            self.node.setStyle(null, .height, .{ .px = line_height_px });
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

    /// Replace text programmatically. This follows TextInputState.setText:
    /// input is copied, grapheme-safe truncation is applied, and on_change is
    /// not invoked.
    pub fn setText(self: EditableTextResult, text: []const u8) usize {
        if (self.state.imeIsComposing()) self.state.cancelImeComposition();
        const written = self.state.setText(text);
        // EditableText is often reused as a canvas overlay for different
        // objects. A programmatic document switch must not let Cmd+Z restore
        // the previous object's text.
        self.state.clearUndoHistory();
        self.state.updateScrollX();
        self.node.markRenderDirty();
        return written;
    }

    pub fn getText(self: EditableTextResult) []const u8 {
        return self.state.getText();
    }
};

pub fn EditableText(props: EditableTextProps) EditableTextBuilder {
    return .{ .props = props };
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
        // 与 setMetrics 同源：不 ceil，保持与静态文本布局逐像素一致。
        const line_height_px = font_size * line_height_ratio;
        const multiline = props.wrap_width != null;
        const wrap_width = @max(props.wrap_width orelse 0, 1);
        const measured = cx.text.measureTextWidth("M", font_size, 400, false);
        const measured_char_width = if (measured > 0) measured else font_size * 0.6;

        const state = try my_scope.allocator.create(TextInputState);
        var state_registered = false;
        state.* = .{};
        errdefer if (!state_registered) {
            state.deinit();
            my_scope.allocator.destroy(state);
        };
        state.on_change = props.on_change;
        state.allocator = allocator;
        state.cx_ref = cx;

        if (multiline) {
            const doc = try my_scope.allocator.create(state_mod.TextareaDocument);
            doc.* = state_mod.TextareaDocument.initFallible(my_scope.allocator) catch |err| {
                my_scope.allocator.destroy(doc);
                return err;
            };
            // adoptResource 登记失败时**自己**调 destroyFn 释放（起的契约）；
            // 这里再 deinit + destroy 一次就是双重释放（test-core 的 node-tree sweep 段错误，
            // `checkWorkspaceWidgetMountFailure(false, true, false)`）。直接 try。
            try my_scope.adoptResource(@ptrCast(doc), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const typed: *state_mod.TextareaDocument = @ptrCast(@alignCast(ptr));
                    typed.deinit();
                    alloc.destroy(typed);
                }
            }.destroy);

            const wrap = try my_scope.allocator.create(state_mod.TextareaWrapMap);
            wrap.* = state_mod.TextareaWrapMap.init(my_scope.allocator);
            wrap.measure_ctx_fn = core.Cx.measureTextWidthCallback;
            wrap.measure_ctx = cx;
            wrap.char_width = measured_char_width;
            wrap.precise_wrap = true;
            wrap.font_size = font_size;
            wrap.font_weight = 400;
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

        if (props.value) |value| {
            _ = try state.setTextChecked(value);
        }
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

        const node = try core.box(cx, .{
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
        }, .{});
        errdefer cx.freeNode(node);
        node.tag = .input;
        node.meta.ownership.meta.component_name = "EditableText";
        node.behavior.events.event_context = state;
        node.behavior.interaction.a11y = .{ .role = .textbox, .label = null, .disabled = false, .multiline = multiline };
        (try node.style.ensureExtFallible(allocator)).min_width = 0;
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
        state.multiline_auto_height = multiline;
        state.input_container_node = node;

        if (multiline) {
            // Selection is an underlay so glyphs remain visible over the
            // highlight. It is intentionally separate from the cursor/IME
            // overlay, which must paint above text.
            const underlay = try core.box(cx, .{
                .width = .{ .grow = .{} },
                .height = .{ .grow = .{} },
                .position = .absolute,
            }, .{});
            try appendNewChild(cx, node, underlay);
            const underlay_ext = try underlay.style.ensureExtFallible(allocator);
            underlay_ext.inset = .{
                .top = .{ .px = 0 },
                .left = .{ .px = 0 },
                .right = .{ .px = 0 },
                .bottom = .{ .px = 0 },
            };
            underlay_ext.hit_behavior = .pass_through;
            state.textarea_overlay_node = underlay;

            const selection = try core.box(cx, .{
                .width = .{ .px = 0 },
                .height = .{ .px = 0 },
            }, .{});
            state.selection_node = selection;
            try appendNewChild(cx, underlay, selection);
        }

        const text_node = try core.box(cx, .{
            .width = if (multiline) .{ .grow = .{} } else .{ .fit = .{} },
            .height = .{ .fit = .{} },
        }, .{});
        try appendNewChild(cx, node, text_node);
        (try text_node.style.ensureExtFallible(allocator)).align_self = .start;
        text_node.setText(.{
            .content = state.getText(),
            .color = cx.tokens.color.fg_primary,
            .font_size = font_size,
            .line_height = line_height_ratio,
            .wrap = if (multiline) .word else .none,
            .spans = state.text_spans_buf[0..0],
            .spans_owned = false,
            .spans_affect_layout = false,
        });
        state.text_display_node = text_node;

        if (multiline) {
            const preedit_node = try core.box(cx, .{
                .width = .{ .px = 0 },
                .height = .{ .px = 0 },
            }, .{});
            state.preedit_underline_node = preedit_node;
            try appendNewChild(cx, node, preedit_node);
        }

        const cursor_node = try core.box(cx, .{
            .width = .{ .px = 0 },
            .height = .{ .px = 0 },
        }, .{});
        state.cursor_node = cursor_node;
        try appendNewChild(cx, node, cursor_node);

        node.behavior.events.on_focus = Cx.simpleHandler(struct {
            fn handler(context: *anyopaque) void {
                const typed: *TextInputState = @ptrCast(@alignCast(context));
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
            }
        }.handler, @ptrCast(state));
        node.meta.per_frame.hooks.before_render.main = render_mod.inputBeforeRender;

        node.behavior.events.on_event = null;
        node.setFocusable(false);
        state.updateScrollX();
        return .{ .node = node, .state = state };
    }
};

fn appendNewChild(cx: *Cx, parent: *core.Node, child: *core.Node) !void {
    parent.appendChild(cx.allocator, child) catch |err| {
        cx.freeNode(child);
        return err;
    };
}

test "EditableText starts passive and updates runtime metrics" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

test "EditableText programmatic text switch clears IME and prior undo history" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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

    // 回宽：行数收敛回去，重复设置同宽是 no-op
    result.setWrapWidth(200);
    try std.testing.expectEqual(wide_lines, result.state.textarea_wrap.?.displayLineCount());
    result.setWrapWidth(200);
    try std.testing.expectApproxEqAbs(@as(f32, 200), result.node.style.width.px, 0.001);
}

test "EditableText setWrapWidth is a no-op on single-line editors" {
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    var cx = try Cx.init(std.testing.allocator);
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
    const layout = result.state.text_display_node.?.getLayoutOutput().artifacts.text_layout orelse
        return error.TestExpectedEqual;
    var laid_out_second_line = false;
    for (layout.lines[0..layout.line_count]) |line| {
        if (line.byte_end > "first line\n".len and line.width > 0) laid_out_second_line = true;
    }
    try std.testing.expect(laid_out_second_line);
    var painted_second_line = false;
    for (cx.text_blob_store.blobs.items) |blob| {
        for (blob.lines[0..blob.line_count]) |line| {
            if (line.byte_end > "first line\n".len and line.width > 0) painted_second_line = true;
        }
    }
    try std.testing.expect(painted_second_line);
}

test "EditableText renders and positions the caret after consecutive hard newlines" {
    var cx = try Cx.init(std.testing.allocator);
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

    const layout = result.state.text_display_node.?.getLayoutOutput().artifacts.text_layout orelse
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();

    const result = try EditableText(.{ .value = "hello", .width = 120 }).mountResult(scope, cx);
    cx.root = result.node;
    result.node.setLayoutRect(.{ .x = 0, .y = 0, .w = 120, .h = result.node.style.height.px });
    result.state.selection_anchor = 0;
    result.state.cursor_pos = 5;
    result.state.focused = true;

    // 默认：走 tokens 的 selection_bg，fg 继承（span.color == null）
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);
    var spans = result.state.text_display_node.?.getText().?.spans;
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(core.Color.eql(spans[0].bg_color.?, result.state.tokens.color.selection_bg));
    try std.testing.expect(spans[0].color == null);

    // 覆写：满饱和底 + 反白文字
    result.state.selection_bg_override = core.Color.hex(0x2F5BFF);
    result.state.selection_fg_override = core.Color.hex(0xFFFFFF);
    result.node.meta.per_frame.hooks.before_render.main.?(result.node);
    spans = result.state.text_display_node.?.getText().?.spans;
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(core.Color.eql(spans[0].bg_color.?, core.Color.hex(0x2F5BFF)));
    try std.testing.expect(core.Color.eql(spans[0].color.?, core.Color.hex(0xFFFFFF)));
}

test "EditableText multiline preedit wrapping moves caret and expands transient height" {
    var cx = try Cx.init(std.testing.allocator);
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
