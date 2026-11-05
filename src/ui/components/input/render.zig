/// Input Render: beforeRender hook + textarea VirtualList integration
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const editable_block = @import("../editable_block/mod.zig");
const state_mod = @import("state.zig");
const styles = @import("styles.zig");
const TextInputState = state_mod.TextInputState;
const text_utils = @import("text_utils.zig");
const virtual_list = @import("../virtual_list/mod.zig");
const SelectionRect = @import("text_core").text_coordinates.SelectionRect;
const grapheme = @import("text_core").grapheme;

fn scrollA11yRange(context: *anyopaque, start: u32, end: u32, align_top: bool) bool {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    const text = state.getText();
    if (start > end or end > text.len or state.input_type == .password) return false;
    const coordinates = @import("text_core").text_coordinates;
    if ((start < text.len and text[start] & 0xc0 == 0x80) or (end < text.len and text[end] & 0xc0 == 0x80)) return false;
    const first = coordinates.clampByteOffset(text, .{ .value = start }, .backward).value;
    const last = coordinates.clampByteOffset(text, .{ .value = end }, .forward).value;
    state.a11y_scroll_request = .{ .start = @intCast(first), .end = @intCast(last), .align_top = align_top, .text_hash = std.hash.Wyhash.hash(0, text), .caret = state.cursor_pos, .anchor = state.selection_anchor };
    state.markVisualDirty();
    return true;
}

fn applyA11yScroll(state: *TextInputState) void {
    const request = state.a11y_scroll_request orelse return;
    if (state.multiline) if (state.textarea_wrap) |wrap| {
        if (wrap.enabled and (wrap.needs_rebuild or wrap.has_interpolated_lines)) return;
    };
    state.a11y_scroll_request = null;
    const text = state.getText();
    if (request.text_hash != std.hash.Wyhash.hash(0, text) or request.caret != state.cursor_pos or request.anchor != state.selection_anchor) return;
    const position: usize = if (request.align_top) request.start else if (request.end > request.start) grapheme.prevBoundary(text, request.end) else request.end;
    if (state.multiline) {
        const list = state.vl_state orelse return;
        const row = state.multilineVisualPosForOffset(text, position).row;
        virtual_list.scrollIndexIntoView(list, row, if (request.align_top) .start else .end);
    } else {
        const offset: usize = if (request.align_top) request.start else request.end;
        const x = if (state.cx_ref) |cx| text_utils.visualCaretX(cx, text, .{ .byte = .{ .value = offset }, .affinity = .downstream }, state.font_size, state.font_weight) orelse return else text_utils.utf8MeasuredAdvancePrefixCx(null, text, offset, state.char_width, state.font_size, state.font_weight);
        const width = text_utils.utf8MeasuredAdvanceCx(state.cx_ref, text, state.char_width, state.font_size, state.font_weight);
        state.scroll_x = std.math.clamp(x - (if (request.align_top) @as(f32, 0) else state.input_inner_w), 0, @max(@as(f32, 0), width - state.input_inner_w));
    }
}

fn a11yLineBoundaries(context: *anyopaque, allocator: std.mem.Allocator) ![]u32 {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    if (state.multiline) {
        const doc = state.textarea_doc orelse return error.AccessibilityLayoutPending;
        const map = state.textarea_wrap orelse return error.AccessibilityLayoutPending;
        return @import("textarea_document.zig").displayLineBoundaries(allocator, doc, map);
    }
    const length = state.getText().len;
    if (length > std.math.maxInt(u32)) return error.AccessibilityTextTooLarge;
    const offsets = try allocator.alloc(u32, if (length == 0) 1 else 2);
    offsets[0] = 0;
    if (length != 0) offsets[1] = @intCast(length);
    return offsets;
}

fn setA11ySelection(context: *anyopaque, start_utf8: u32, end_utf8: u32) bool {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    return state.setAccessibilitySelection(start_utf8, end_utf8);
}

fn appendA11yGeometry(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(core.A11yProps.TextGeometrySegment),
    line: @import("text_core").text_coordinates.VisualLine,
    byte_start: usize,
    x: f32,
    y: f32,
    height: f32,
) !void {
    var segments = line.selectionSegments();
    while (segments.next()) |segment| {
        if (segment.rect.width <= 0) continue;
        if (output.items.len == core.A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
        try output.append(allocator, .{
            .start = @intCast(byte_start + segment.start.value),
            .end = @intCast(byte_start + segment.end.value),
            .rect = .{ .x = x + segment.rect.x, .y = y, .width = segment.rect.width, .height = height },
        });
    }
}

fn a11yGeometry(context: *anyopaque, allocator: std.mem.Allocator) ![]core.A11yProps.TextGeometrySegment {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    if (state.input_type == .password) return error.AccessibilitySecureText;
    if (state.ime_replacement != null or state.hasImePreedit()) return error.AccessibilityLayoutPending;
    var output: std.ArrayListUnmanaged(core.A11yProps.TextGeometrySegment) = .empty;
    errdefer output.deinit(allocator);
    if (state.multiline) {
        const doc = state.textarea_doc orelse return error.AccessibilityLayoutPending;
        const map = state.textarea_wrap orelse return error.AccessibilityLayoutPending;
        if (map.enabled and (map.needs_rebuild or map.has_interpolated_lines)) return error.AccessibilityLayoutPending;
        var first: u32 = 0;
        var last: u32 = if (map.enabled) map.displayLineCount() else @intCast(doc.lineCount());
        if (state.vl_state) |vl| {
            if (!vl.initialized) return error.AccessibilityLayoutPending;
            first = @intCast(@min(vl.prev_start, last));
            last = @intCast(@min(vl.prev_end, last));
        }
        const scroll_y = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
        var row = first;
        while (row < last) : (row += 1) {
            const span = displaySegRange(doc, map.displayLineInfo(row, doc));
            if (span.start == span.end) continue;
            const visual = state.visualLineForSegment(span.start, span.end, row) orelse return error.AccessibilityLayoutPending;
            try appendA11yGeometry(allocator, &output, visual.line, span.start, state.container_x + state.padding_h, state.container_y + state.padding_v + @as(f32, @floatFromInt(row)) * state.line_height - scroll_y, state.line_height);
        }
    } else if (state.getText().len > 0) {
        const cx = state.cx_ref orelse return error.AccessibilityLayoutPending;
        const line = try cx.text.visualLine(.{ .text = state.getText(), .font_family = "system", .font_size = state.font_size, .font_weight = state.font_weight });
        try appendA11yGeometry(allocator, &output, line, 0, state.container_x + state.padding_h - state.scroll_x, if (state.text_display_node) |node| node.globalRect().y else state.container_y + state.padding_v, state.line_height);
    }
    return output.toOwnedSlice(allocator);
}

fn appendA11yCarets(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(core.A11yProps.TextCaretGeometry),
    line: @import("text_core").text_coordinates.VisualLine,
    byte_start: usize,
    x: f32,
    y: f32,
    height: f32,
) !void {
    for (line.caret_stops) |stop| {
        if (output.items.len == core.A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
        try output.append(allocator, .{
            .offset = @intCast(byte_start + stop.position.byte.value),
            .rect = .{ .x = x + stop.x.value, .y = y, .width = 0, .height = height },
            .downstream = stop.position.affinity == .downstream,
        });
    }
}

fn a11yRowGeometry(context: *anyopaque, allocator: std.mem.Allocator) ![]core.A11yProps.TextRowGeometry {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    if (state.input_type == .password) return error.AccessibilitySecureText;
    if (state.ime_replacement != null or state.hasImePreedit() or state.input_inner_w <= 0) return error.AccessibilityLayoutPending;
    var output: std.ArrayListUnmanaged(core.A11yProps.TextRowGeometry) = .empty;
    errdefer output.deinit(allocator);
    if (state.multiline) {
        const doc = state.textarea_doc orelse return error.AccessibilityLayoutPending;
        const map = state.textarea_wrap orelse return error.AccessibilityLayoutPending;
        if (map.enabled and (map.needs_rebuild or map.has_interpolated_lines)) return error.AccessibilityLayoutPending;
        var first: u32 = 0;
        var last: u32 = if (map.enabled) map.displayLineCount() else @intCast(doc.lineCount());
        if (state.vl_state) |vl| {
            if (!vl.initialized) return error.AccessibilityLayoutPending;
            first = @intCast(@min(vl.prev_start, last));
            last = @intCast(@min(vl.prev_end, last));
        }
        const scroll_y = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
        var row = first;
        while (row < last) : (row += 1) {
            if (output.items.len == core.A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
            const span = displaySegRange(doc, map.displayLineInfo(row, doc));
            const end = span.end + @as(usize, @intFromBool(span.end < doc.getText().len and doc.getText()[span.end] == '\n'));
            try output.append(allocator, .{ .start = @intCast(span.start), .end = @intCast(end), .rect = .{
                .x = state.container_x + state.padding_h,
                .y = state.container_y + state.padding_v + @as(f32, @floatFromInt(row)) * state.line_height - scroll_y,
                .width = state.input_inner_w,
                .height = state.line_height,
            } });
        }
    } else {
        try output.append(allocator, .{ .start = 0, .end = @intCast(state.getText().len), .rect = .{
            .x = state.container_x + state.padding_h,
            .y = if (state.text_display_node) |node| node.globalRect().y else state.container_y + state.padding_v,
            .width = state.input_inner_w,
            .height = state.line_height,
        } });
    }
    return output.toOwnedSlice(allocator);
}

fn a11yCaretGeometry(context: *anyopaque, allocator: std.mem.Allocator) ![]core.A11yProps.TextCaretGeometry {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    if (state.input_type == .password) return error.AccessibilitySecureText;
    if (state.ime_replacement != null or state.hasImePreedit()) return error.AccessibilityLayoutPending;
    var output: std.ArrayListUnmanaged(core.A11yProps.TextCaretGeometry) = .empty;
    errdefer output.deinit(allocator);
    if (state.multiline) {
        const doc = state.textarea_doc orelse return error.AccessibilityLayoutPending;
        const map = state.textarea_wrap orelse return error.AccessibilityLayoutPending;
        if (map.enabled and (map.needs_rebuild or map.has_interpolated_lines)) return error.AccessibilityLayoutPending;
        var first: u32 = 0;
        var last: u32 = if (map.enabled) map.displayLineCount() else @intCast(doc.lineCount());
        if (state.vl_state) |vl| {
            if (!vl.initialized) return error.AccessibilityLayoutPending;
            first = @intCast(@min(vl.prev_start, last));
            last = @intCast(@min(vl.prev_end, last));
        }
        const scroll_y = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
        var row = first;
        while (row < last) : (row += 1) {
            const span = displaySegRange(doc, map.displayLineInfo(row, doc));
            const visual = state.visualLineForSegment(span.start, span.end, row) orelse return error.AccessibilityLayoutPending;
            try appendA11yCarets(allocator, &output, visual.line, span.start, state.container_x + state.padding_h, state.container_y + state.padding_v + @as(f32, @floatFromInt(row)) * state.line_height - scroll_y, state.line_height);
        }
    } else {
        const cx = state.cx_ref orelse return error.AccessibilityLayoutPending;
        const line = try cx.text.visualLine(.{ .text = state.getText(), .font_family = "system", .font_size = state.font_size, .font_weight = state.font_weight });
        try appendA11yCarets(allocator, &output, line, 0, state.container_x + state.padding_h - state.scroll_x, if (state.text_display_node) |node| node.globalRect().y else state.container_y + state.padding_v, state.line_height);
    }
    return output.toOwnedSlice(allocator);
}

fn setA11yValue(context: *anyopaque, value: []const u8) bool {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    // Reject oversized native writes before mutation. TextInputState.setText
    // intentionally truncates programmatic writes, but an AX setter must not
    // report failure after silently changing the control to a prefix.
    if (!state.growable and value.len > state.buffer.len) return false;
    // AX value write is user edit: value binding can correct in place (see
    // TextInputState.reconcileUserEdit).
    state.beginUserEdit();
    defer state.endUserEdit();
    if ((state.setTextChecked(value) catch return false) != value.len) return false;
    state.a11y_scroll_request = null;
    state.updateScrollX();
    if (state.input_container_node) |node| syncAccessibilityProps(state, node);
    if (state.on_change) |handler| handler.invokeWithStr(state.getText());
    return true;
}

pub fn a11yTextFrame(context: *anyopaque, start_utf8: u32, end_utf8: u32, out: *core.A11yRect) bool {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    const text = state.getText();
    const requested_start: usize = @min(@as(usize, start_utf8), text.len);
    const requested_end: usize = @min(@as(usize, end_utf8), text.len);
    const start = @import("text_core").text_coordinates.clampByteOffset(
        text,
        .{ .value = requested_start },
        .backward,
    ).value;
    const end = if (requested_start == requested_end)
        start
    else
        @import("text_core").text_coordinates.clampByteOffset(
            text,
            .{ .value = requested_end },
            .forward,
        ).value;
    if (state.multiline) {
        const a = state.multilineVisualPosForOffset(text, start);
        const b = state.multilineVisualPosForOffset(text, end);
        const first_row = @min(a.row, b.row);
        const last_row = @max(a.row, b.row);
        const scroll_y = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
        out.* = .{
            .x = state.container_x + state.padding_h + (if (first_row == last_row) @min(a.x, b.x) else 0),
            .y = state.container_y + state.padding_v + @as(f32, @floatFromInt(first_row)) * state.line_height - scroll_y,
            .width = if (first_row == last_row) @max(@abs(b.x - a.x), 1) else @max(state.input_inner_w, 1),
            .height = @as(f32, @floatFromInt(last_row - first_row + 1)) * @max(state.line_height, 1),
        };
        return true;
    }
    const start_x = if (state.cx_ref) |cx| text_utils.visualCaretX(cx, text, .{
        .byte = .{ .value = start },
        .affinity = .downstream,
    }, state.font_size, state.font_weight) orelse text_utils.utf8MeasuredAdvancePrefixCx(state.cx_ref, text, start, state.char_width, state.font_size, state.font_weight) else text_utils.utf8MeasuredAdvancePrefixCx(state.cx_ref, text, start, state.char_width, state.font_size, state.font_weight);
    const end_x = if (state.cx_ref) |cx| text_utils.visualCaretX(cx, text, .{
        .byte = .{ .value = end },
        .affinity = .upstream,
    }, state.font_size, state.font_weight) orelse text_utils.utf8MeasuredAdvancePrefixCx(state.cx_ref, text, end, state.char_width, state.font_size, state.font_weight) else text_utils.utf8MeasuredAdvancePrefixCx(state.cx_ref, text, end, state.char_width, state.font_size, state.font_weight);
    out.* = .{
        .x = state.container_x + state.padding_h - state.scroll_x + @min(start_x, end_x),
        // A single-line Input centers its line box; use that laid-out origin.
        .y = if (state.text_display_node) |node| node.globalRect().y else state.container_y + state.padding_v,
        .width = @max(@abs(end_x - start_x), 1),
        .height = @max(state.line_height, 1),
    };
    return true;
}

pub fn a11yRangeAtPoint(context: *anyopaque, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    const saved_affinity = state.cursor_affinity;
    const text = state.getText();
    const raw_offset = @min(state.hitTestCursorPosAt(x, y), text.len);
    state.cursor_affinity = saved_affinity;
    const boundary = @import("text_core").text_coordinates.clampByteOffset(
        text,
        .{ .value = raw_offset },
        .backward,
    ).value;
    const start = if (boundary == text.len and text.len > 0) grapheme.prevBoundary(text, boundary) else boundary;
    const end = if (text.len == 0) 0 else grapheme.nextBoundary(text, start);
    start_utf8.* = @intCast(start);
    end_utf8.* = @intCast(end);
    return true;
}

fn liveTextLength(context: *anyopaque) usize {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    return state.getText().len;
}

fn liveTextCopy(context: *anyopaque, start_utf8: usize, out: []u8) usize {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    const value = state.getText();
    if (start_utf8 > value.len) return 0;
    const len = @min(out.len, value.len - start_utf8);
    @memcpy(out[0..len], value[start_utf8 .. start_utf8 + len]);
    return len;
}

fn liveTextSelection(context: *anyopaque) core.TextInputSelection {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    const anchor = state.selection_anchor orelse state.cursor_pos;
    return .{
        .start = @intCast(@min(anchor, state.cursor_pos)),
        .end = @intCast(@max(anchor, state.cursor_pos)),
        .caret = @intCast(state.cursor_pos),
    };
}

pub fn textInputClient(state: *TextInputState) core.TextInputClient {
    return .{
        .context = state,
        .text_len = liveTextLength,
        .copy_text = liveTextCopy,
        .selection = liveTextSelection,
        .is_composing = struct {
            fn read(context: *anyopaque) bool {
                const input: *TextInputState = @ptrCast(@alignCast(context));
                return input.imeIsComposing();
            }
        }.read,
        .set_selection = setA11ySelection,
        .frame_for_range = a11yTextFrame,
        .range_at_point = a11yRangeAtPoint,
        .secure = state.input_type == .password,
    };
}

/// Publish model metadata independently of whether paint visits this control.
/// UI Automation must be able to read/set offscreen fields before first paint.
pub fn syncAccessibilityProps(state: *TextInputState, node: *Node) void {
    const a11y_node = state.input_container_node orelse node;
    if (a11y_node.behavior.interaction.a11y) |*a11y| {
        // Password values and ranges are intentionally not exported. A role
        // alone never enables AppKit's editable text protocol.
        if (state.input_type == .password) {
            a11y.value_text = null;
            a11y.editable_text = null;
        } else {
            const text = state.getText();
            const anchor = state.selection_anchor orelse state.cursor_pos;
            a11y.value_text = text;
            a11y.editable_text = .{
                .context = state,
                .selection_start = @intCast(@min(anchor, state.cursor_pos)),
                .selection_end = @intCast(@max(anchor, state.cursor_pos)),
                .caret = @intCast(state.cursor_pos),
                .uniform_format = true,
                .visible_start = 0,
                .visible_end = @intCast(text.len),
                .set_selection = setA11ySelection,
                .set_value = setA11yValue,
                .scroll_into_view = scrollA11yRange,
                .line_boundaries = a11yLineBoundaries,
                .geometry_segments = a11yGeometry,
                .row_geometry = a11yRowGeometry,
                .caret_geometry = a11yCaretGeometry,
                .frame_for_range = a11yTextFrame,
                .range_at_point = a11yRangeAtPoint,
            };
        }
    }
}

/// Hand the caret blink to the system compositor (core/compositor_sprite.zig)
/// while the field is focused without IME preedit: a two-frame loop (lit for
/// the first half period) timed by the field's own blink clock. The caret is
/// repainted on every frame, so leaving the sprite needs no overlap frame.
/// Returns true while the compositor owns the blink.
fn caretSprite(state: *TextInputState) bool {
    const cx = state.cx_ref orelse return false;
    const cursor = state.cursor_node orelse {
        cx.sprites.unregister(state);
        return false;
    };
    if (!state.focused or state.hasImePreedit()) {
        cx.sprites.unregister(state);
        return false;
    }
    cx.sprites.registerWith(cx.allocator, cursor.id, caret_period_ms, state, caretDrawAt, caretRepaint, .{
        .frame_count = 2,
        .phase = caretPhase,
        .fresh_on_exit = true,
    }) catch return false;
    return cx.sprites.isActive(cursor.id);
}

const caret_period_ms: f64 = 2 * @as(f64, @floatFromInt(@import("caret_blink.zig").half_period_ns)) / std.time.ns_per_ms;

fn caretDrawAt(ctx: core.DrawContext, context: ?*anyopaque, now_ms: f64) anyerror!void {
    const state: *TextInputState = @ptrCast(@alignCast(context orelse return));
    if (now_ms >= caret_period_ms / 2) return;
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    try dl.append(.{ .fill_rect = .{
        .header = header,
        .x = 0,
        .y = 0,
        .w = ctx.local_w,
        .h = ctx.local_h,
        .color = state.tokens.tokens.color.fg_primary,
    } });
}

fn caretRepaint(context: ?*anyopaque) void {
    const state: *TextInputState = @ptrCast(@alignCast(context orelse return));
    if (state.cursor_node) |cursor| cursor.markRenderDirty();
}

fn caretPhase(context: ?*anyopaque) f64 {
    const state: *TextInputState = @ptrCast(@alignCast(context orelse return 0));
    const epoch = state.blink.epoch orelse return 0;
    const now = @import("zenit_time").Instant.now(state.io) catch return 0;
    const period_ns: u64 = @intFromFloat(caret_period_ms * std.time.ns_per_ms);
    return @as(f64, @floatFromInt(now.since(epoch) % period_ns)) / std.time.ns_per_ms;
}

/// Input beforeRender hook: cursor blink, selection highlight, drag handling.
pub fn inputBeforeRender(node: *Node) void {
    const state: *TextInputState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    syncAccessibilityProps(state, node);
    const coords = editable_block.computeRenderCoords(node, state.padding_h, state.padding_v);

    // Border animation handled automatically by Transition system (enableImplicitAnimation +
    // setBorderColor).

    const now = @import("zenit_time").Instant.now(state.io) catch null;
    const blink_visible = (!state.hasImePreedit() or state.ime_cursor_visible) and (if (state.focused and now != null) state.blinkVisible(now.?) else state.focused);
    // While the compositor blinks the caret (see caretSprite) no frame is
    // scheduled for the phase flips.
    const blink_composited = caretSprite(state);
    if (state.focused and now != null and !blink_composited) {
        if (state.cx_ref) |cx| {
            cx.scheduleRedrawAfterNs(state.nextBlinkDelayNs(now.?));
        }
        if (blink_visible != state.last_blink_visible) {
            node.markRenderDirty();
        }
    }
    state.last_blink_visible = blink_visible;
    if (state.focused and !blink_composited) if (state.cx_ref) |cx| {
        cx.caret_shown = blink_visible;
    };

    // Cache container global x coordinate.
    state.container_x = coords.global_x;
    state.container_y = coords.global_y;
    const inner_width_changed = state.updateInnerWidthFromContainer(node);
    if (inner_width_changed) {
        state.updateScrollX();
        // WrapMap: update wrap_width when width changes.
        if (state.textarea_wrap) |wrap| {
            if (state.textarea_doc) |doc| {
                wrap.setWrapWidth(state.input_inner_w, doc);
                _ = wrap.rewrapInterpolatedAll(doc);
                _ = wrap.takePendingPatch();
            }
        }
    }
    if (state.textarea_wrap) |wrap| {
        if (state.textarea_doc) |doc| {
            if (wrap.enabled and wrap.has_interpolated_lines) {
                _ = wrap.rewrapInterpolatedAll(doc);
                _ = wrap.takePendingPatch();
                state.dirty = true;
                state.markVisualDirty();
                node.markRenderDirty();
                if (wrap.has_interpolated_lines) {
                    if (state.cx_ref) |cx| cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
                }
            }
        }
    }
    state.refreshMultilineImeGeometry();
    state.syncMultilineAutoHeight();

    // If focused and mouse down, ensure enter drag state (avoid losing across frames).
    if (state.cx_ref) |cx| {
        if (state.focused and cx.pressed_node != null and !state.is_dragging and !state.suspend_drag_until_mouse_up) {
            state.is_dragging = true;
            if (state.selection_anchor == null) {
                state.selection_anchor = state.cursor_pos;
            }
        }
    }

    // Replay only the pointer recorded by this input after a real drag move.
    // Cx mouse coordinates can still belong to the previous synthetic click.
    if (state.is_dragging) {
        if (state.cx_ref) |cx| {
            if (cx.pressed_node == null or !state.focused) {
                state.is_dragging = false;
                state.drag_pointer = null;
            } else if (state.advanceEdgeDrag(cx.frame_time_ms)) {
                cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
            }
        }
    }

    // Update text display content (in retain mode, sync buffer changes to text node).
    if (state.text_display_node) |text_nd| {
        // Single-line Input: directly update text content (mark dirty only when content actually
        // changes).
        if (text_nd.getText()) |old_text| {
            const content_changed = state.syncDisplayTextContent();
            var text = text_nd.getText() orelse old_text;
            const has_content = state.hasVisualValue();
            const new_color = if (state.disabled)
                state.tokens.tokens.color.fg_disabled
            else if (has_content)
                state.tokens.tokens.color.fg_primary
            else
                (state.placeholder_color orelse state.tokens.tokens.color.fg_secondary);
            const new_line_height = if (state.font_size > 0 and state.line_height > 0)
                state.line_height / state.font_size
            else
                @as(f32, 1.4);
            const new_padding_left = state.padding_h - state.scroll_x;
            const padding_changed = @abs(text_nd.style.padding.left - new_padding_left) > 0.001;
            const changed = content_changed or
                !Color.eql(text.color, new_color) or
                @abs(text.line_height - new_line_height) > 0.001 or
                padding_changed;
            // syncDisplayTextContent publishes an owned snapshot; retain all
            // of its ownership fields when updating visual properties.
            text.color = new_color;
            text.color_set = true;
            text.line_height = new_line_height;
            text_nd.setText(text);
            text_nd.style.padding.left = new_padding_left;
            if (changed) {
                // Content change must mark sizing, not just layout: multi-line .word wrap's
                // intrinsic measure is cached, markLayoutDirty does not invalidate it; wrap lines
                // always paint old content. Symptom: IME preedit / new input text does not appear,
                // cursor/underline advances per new content (visual misalignment).
                if (content_changed) text_nd.markSizingDirty();
                // Horizontal scrolling moves the text through a layout
                // property. Render dirt alone leaves its old paint position
                // cached while the caret moves to the new scroll offset.
                if (padding_changed) text_nd.markLayoutDirty();
                text_nd.markRenderDirty();
            }
        }
    } else if (state.multiline and state.dirty) {
        // Multi-line Textarea: update text lines via VirtualList when dirty.
        state.dirty = false;
        if (state.vl_state) |vl_state| {
            const new_line_count = countTextareaLines(state);
            if (new_line_count != vl_state.item_count) {
                virtual_list.updateItemCount(vl_state, new_line_count);
            } else {
                virtual_list.refreshRange(vl_state, vl_state.prev_start, vl_state.prev_end);
            }
            // Scroll to display line containing cursor.
            if (state.textarea_wrap) |wrap| {
                if (state.textarea_doc) |doc| {
                    const lc = doc.offsetToLineCol(state.cursor_pos);
                    const dp = wrap.bufferToDisplay(lc.line, lc.col);
                    virtual_list.ensureVisible(vl_state, dp.display_line);
                }
            } else {
                const cursor_text = state.buildDisplayText(null);
                const cursor_off = state.displayCursorByteOffset();
                const cursor_vis = state.multilineVisualPosForOffset(cursor_text, cursor_off);
                virtual_list.ensureVisible(vl_state, cursor_vis.row);
            }
        }
    }

    applyA11yScroll(state);

    // Single-line Input: overflow fade edges driven by real scroll_x, avoiding 'already at right
    // but right gradient visible'.
    if (!state.multiline) {
        if (state.cx_ref) |cx| {
            const ext = node.style.ensureExtPanic(cx.allocator);
            if (ext.overflow_fade) |*fade| {
                const content_w = state.displayedTextAdvance();
                const max_scroll = @max(@as(f32, 0), content_w - state.input_inner_w);
                const eps: f32 = 0.75;
                const background = if (state.input_container_node) |field| field.getBackground() else Color.TRANSPARENT;
                // A solid field can cover overflowing glyphs with its own paint.
                // On transparent/embedded fields retain the hard clip: painting
                // their translucent tint again would create another dark seam.
                const can_fade = background.a == 255;
                const left_on = can_fade and state.scroll_x > eps;
                const right_on = can_fade and state.scroll_x < (max_scroll - eps);
                if (fade.edges.left != left_on or fade.edges.right != right_on or
                    fade.color == null or !Color.eql(fade.color.?, background))
                {
                    fade.edges.left = left_on;
                    fade.edges.right = right_on;
                    fade.color = background;
                    node.markRenderDirty();
                }
            }
        }
    }

    // Container interior area (relative to editable_surface itself, child node rects use this
    // coordinate).
    const container_inner_x = state.padding_h;
    const container_inner_y = state.padding_v;
    // Cursor height follows line height (canvas scaling pushes font_size/line_height very large;
    // hardcoded 16 becomes tiny when zoomed). At 14px font: line_height=18 -> 16, same as original,
    // standard Input not regressed.
    var cursor_h: f32 = if (state.line_height > 0) @max(12.0, state.line_height - 2.0) else 16;
    var cursor_y = (node.rectFromWorldOrFallback().h - cursor_h) / 2;

    // Update cursor node.
    if (state.cursor_node) |cursor| {
        if (state.focused) {
            var cursor_x_px: f32 = state.visualCursorAdvance() - state.scroll_x;
            if (state.multiline) {
                if (state.textarea_wrap) |wrap| {
                    if (state.textarea_doc) |doc| {
                        // WrapMap path.
                        const lc = doc.offsetToLineCol(state.cursor_pos);
                        const dp = wrap.bufferToDisplay(lc.line, lc.col);
                        const info = wrap.displayLineInfo(dp.display_line, doc);
                        const seg = displaySegRange(doc, info);
                        const txt = doc.getText();
                        const seg_text = txt[seg.start..seg.end];
                        const col_in_seg = if (state.cursor_pos >= seg.start) state.cursor_pos - seg.start else 0;
                        if (state.cx_ref) |cx| {
                            var visual_text = seg_text;
                            var visual_byte = @min(col_in_seg, seg_text.len);
                            if (state.hasImePreedit() and state.cursor_pos >= seg.start and state.cursor_pos <= seg.end) {
                                visual_text = state.composeDisplaySegmentWithIme(seg_text, visual_byte);
                                visual_byte += state.effectiveImeCursorOffset();
                            }
                            cursor_x_px = text_utils.visualCaretX(cx, visual_text, .{
                                .byte = .{ .value = @min(visual_byte, visual_text.len) },
                                .affinity = state.cursor_affinity,
                            }, state.font_size, state.font_weight) orelse cursor_x_px;
                        }
                        cursor_y = container_inner_y + @as(f32, @floatFromInt(dp.display_line)) * state.line_height;
                        cursor_h = @max(12.0, state.line_height - 2.0);
                        if (state.ime_visual_valid) {
                            cursor_x_px = state.ime_visual_cursor_x;
                            cursor_y = container_inner_y + @as(f32, @floatFromInt(state.ime_visual_display_line)) * state.line_height;
                        }
                    }
                } else {
                    const cursor_text = state.buildDisplayText(null);
                    const cursor_off = state.displayCursorByteOffset();
                    const pos = state.multilineVisualPosForOffset(cursor_text, cursor_off);
                    cursor_x_px = pos.x;
                    cursor_y = container_inner_y + @as(f32, @floatFromInt(pos.row)) * state.line_height;
                    cursor_h = @max(12.0, state.line_height - 2.0);
                }
            }

            const cursor_x = @round(container_inner_x + cursor_x_px);
            const cursor_y_px = @round(cursor_y);
            // A composited blink keeps the GPU caret lit: its items are
            // replaced by the sprite, and must exist for it to stay admitted.
            syncCursorVisual(cursor, .{
                .x = cursor_x,
                .y = cursor_y_px,
                .w = 1,
                .h = cursor_h,
            }, if (blink_visible or blink_composited) state.tokens.tokens.color.fg_primary else Color.TRANSPARENT);

            // IME cursor rect needs global coordinates.
            if (state.cx_ref) |cx| {
                const global = node.globalRect();
                // Live transform: the hit index stores matrices in hit-layer space (a scrolled
                // ancestor moves without a rebuild), not world space.
                const world_transform = node.worldTransform();
                const has_world_transform = world_transform.a != 1 or world_transform.b != 0 or
                    world_transform.c != 0 or world_transform.d != 1 or world_transform.tx != 0 or world_transform.ty != 0;
                const caret_world = if (has_world_transform)
                    world_transform.transformRect(core.ComputedRect.init(cursor_x, cursor_y_px, 1, cursor_h))
                else
                    core.ComputedRect.init(global.x + cursor_x, global.y + cursor_y_px, 1, cursor_h);
                _ = cx.setImeCursorRect(
                    caret_world.x,
                    caret_world.y,
                    caret_world.w,
                    caret_world.h,
                );
            }
        } else {
            syncCursorVisual(cursor, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, Color.TRANSPARENT);
        }
    }

    // Single-line: selection / IME highlight / IME underline all via text_display_node.text.spans.
    // Glyphs always above span backgrounds; offset uses byte coordinates, measured by text render
    // pipeline, eliminating 'selection occludes text' and 'position misaligned with scroll_x' bugs.
    if (!state.multiline and state.text_display_node != null) {
        rebuildSingleLineSpans(state);
    }

    // Multi-line: still uses old path of independent selection_node / preedit_underline_node.
    if (state.multiline and state.selection_node != null) {
        updateMultilineSelectionNodes(state, node, container_inner_x, container_inner_y, cursor_y, cursor_h);
        updateMultilinePreeditUnderline(state, container_inner_x, container_inner_y, cursor_y, cursor_h);
    }

    // Continuous redraw request (cursor blink).
    if (inner_width_changed) {
        node.markRenderDirty();
    }
}

/// Write the caret's frame and color, marking it render-dirty only when either changed. The
/// hook runs every frame; an unconditional mark kept the caret (and through subtree_render every
/// ancestor up to the window root) dirty on idle frames, so nothing on that path could be reused.
fn syncCursorVisual(cursor: *Node, rect: core.ComputedRect, color: Color) void {
    const old_rect = cursor.rectFromWorldOrFallback();
    const old_color = cursor.getBackground();
    cursor.setLayoutRect(rect);
    cursor.setBackgroundRaw(color);
    const same_rect = old_rect.x == rect.x and old_rect.y == rect.y and old_rect.w == rect.w and old_rect.h == rect.h;
    if (!same_rect or !std.meta.eql(old_color, color)) cursor.markRenderDirty();
}

/// Rebuild text_display_node spans per selection / IME preedit state, rebind slice to text.spans.
fn rebuildSingleLineSpans(state: *TextInputState) void {
    const text_nd = state.text_display_node orelse return;
    var text_prop = text_nd.getText() orelse return;

    var len: u8 = 0;
    const display_text = text_prop.content;
    const is_password = state.input_type == .password;
    // In password mode, display_text is mask (N ASCII '*'s); span start/end by mask coordinate =
    // grapheme index. In normal mode, display_text equals buffer, use byte offset.
    const cursor_off_raw = @min(state.cursor_pos, state.getText().len);
    const cursor_off = if (is_password)
        text_utils.utf8GraphemeLen(state.getText()[0..cursor_off_raw])
    else
        cursor_off_raw;
    const preedit_units = if (is_password)
        text_utils.utf8GraphemeLen(state.preeditText())
    else
        state.ime_preedit_len;

    if (state.hasImePreedit()) {
        // Preedit in displayed text lies in [cursor_off, cursor_off + preedit_units).
        const preedit_start: u32 = @intCast(@min(cursor_off, display_text.len));
        const preedit_end: u32 = @intCast(@min(cursor_off + preedit_units, display_text.len));
        if (preedit_end > preedit_start) {
            // 1) underline
            state.text_spans_buf[len] = .{
                .start = preedit_start,
                .end = preedit_end,
                .underline = true,
                .underline_color = styles.imePreeditUnderlineColor(state.tokens),
            };
            len += 1;
            // IME marked highlight (entire preedit blue semi-transparent).
            if (state.shouldShowImeSelectionHighlight()) {
                state.text_spans_buf[len] = .{
                    .start = preedit_start + @as(u32, @intCast(if (state.ime_selection_end) |end| if (is_password) text_utils.utf8GraphemeLen(state.preeditText()[0..@min(end, state.ime_cursor_utf8_offset)]) else @min(end, state.ime_cursor_utf8_offset) else 0)),
                    .end = if (state.ime_selection_end) |end| preedit_start + @as(u32, @intCast(if (is_password) text_utils.utf8GraphemeLen(state.preeditText()[0..@max(end, state.ime_cursor_utf8_offset)]) else @max(end, state.ime_cursor_utf8_offset))) else preedit_end,
                    .bg_color = styles.imeHighlightColor(state.tokens),
                };
                len += 1;
            }
        }
    } else if (if (state.ime_replacement == null) state.selection_anchor else null) |anchor| {
        // Regular text selection.
        const lo_raw = @min(anchor, state.cursor_pos);
        const hi_raw = @max(anchor, state.cursor_pos);
        const lo = if (is_password)
            text_utils.utf8GraphemeLen(state.getText()[0..@min(lo_raw, state.getText().len)])
        else
            lo_raw;
        const hi = if (is_password)
            text_utils.utf8GraphemeLen(state.getText()[0..@min(hi_raw, state.getText().len)])
        else
            hi_raw;
        if (hi > lo) {
            const start: u32 = @intCast(@min(lo, display_text.len));
            const end: u32 = @intCast(@min(hi, display_text.len));
            if (end > start) {
                state.text_spans_buf[len] = .{
                    .start = start,
                    .end = end,
                    .color = state.selection_fg_override,
                    .bg_color = state.selection_bg_override orelse state.tokens.tokens.color.selection_bg,
                };
                len += 1;
            }
        }
    }

    const new_slice = state.text_spans_buf[0..len];
    // Mark dirty only when slice length or content changes (avoid needless redraws each frame).
    const old_slice = text_prop.spans;
    var changed = old_slice.len != new_slice.len;
    if (!changed) {
        var i: usize = 0;
        while (i < new_slice.len) : (i += 1) {
            if (!std.meta.eql(old_slice[i], new_slice[i])) {
                changed = true;
                break;
            }
        }
    }
    text_prop.spans = new_slice;
    text_nd.setText(text_prop);
    state.text_spans_len = len;
    if (changed) text_nd.markRenderDirty();
}

/// Multi-line selection node update (old logic, multi-line only).
fn updateMultilineSelectionNodes(
    state: *TextInputState,
    node: *Node,
    container_inner_x: f32,
    container_inner_y: f32,
    cursor_y: f32,
    cursor_h: f32,
) void {
    const sel = state.selection_node orelse return;
    if (state.shouldShowImeSelectionHighlight()) {
        var preedit_start_px = state.imePreeditStartAdvance() - state.scroll_x;
        var preedit_width_px = @max(state.imePreeditAdvance(), @max(4.0, state.char_width * 0.5));
        var highlight_y = cursor_y + 2;
        if (state.ime_visual_valid) {
            preedit_start_px = state.ime_visual_underline_x;
            preedit_width_px = state.ime_visual_underline_width;
            highlight_y = container_inner_y + @as(f32, @floatFromInt(state.ime_visual_display_line)) * state.line_height + 2;
        } else if (state.multiline) {
            if (state.textarea_wrap) |wrap| {
                if (state.textarea_doc) |doc| {
                    const lc = doc.offsetToLineCol(state.cursor_pos);
                    const dp = wrap.bufferToDisplay(lc.line, lc.col);
                    const info = wrap.displayLineInfo(dp.display_line, doc);
                    const seg = displaySegRange(doc, info);
                    if (textareaPreeditVisualSpan(state, doc, seg)) |span| {
                        preedit_start_px = span.x;
                        preedit_width_px = @max(span.width, @max(4.0, state.char_width * 0.5));
                    }
                    highlight_y = container_inner_y + @as(f32, @floatFromInt(dp.display_line)) * state.line_height + 2;
                }
            } else {
                const cursor_text = state.buildDisplayText(null);
                const preedit_start = @min(state.cursor_pos, state.buffer_len);
                const preedit_end = preedit_start + state.ime_preedit_len;
                const start_pos = state.multilineVisualPosForOffset(cursor_text, preedit_start);
                const end_pos = state.multilineVisualPosForOffset(cursor_text, preedit_end);
                preedit_start_px = start_pos.x;
                preedit_width_px = if (start_pos.row == end_pos.row)
                    @max(end_pos.x - start_pos.x, @max(4.0, state.char_width * 0.5))
                else
                    @max(state.input_inner_w - start_pos.x, @max(4.0, state.char_width * 0.5));
                highlight_y = container_inner_y + @as(f32, @floatFromInt(start_pos.row)) * state.line_height + 2;
            }
        }
        sel.setLayoutRect(.{
            .x = @round(container_inner_x + preedit_start_px),
            .y = @round(highlight_y),
            .w = @round(preedit_width_px),
            .h = @max(@as(f32, 1.0), @round(cursor_h - 4)),
        });
        sel.setBackgroundRaw(styles.imeHighlightColor(state.tokens));
    } else if (if (state.ime_replacement == null) state.selection_anchor else null) |anchor| {
        const sel_start = @min(anchor, state.cursor_pos);
        const sel_end = @max(anchor, state.cursor_pos);
        if (sel_start != sel_end) {
            if (state.multiline) {
                // Multi-line selection.
                var start_row: usize = 0;
                var start_x: f32 = 0;
                var end_row: usize = 0;
                var end_x: f32 = 0;
                var bidi_rect_storage: [16]SelectionRect = undefined;
                var bidi_rect_count: usize = 0;
                if (state.textarea_wrap) |wrap| {
                    if (state.textarea_doc) |doc| {
                        const s_lc = doc.offsetToLineCol(sel_start);
                        const s_dp = wrap.bufferToDisplay(s_lc.line, s_lc.col);
                        const e_lc = doc.offsetToLineCol(sel_end);
                        const e_dp = wrap.bufferToDisplay(e_lc.line, e_lc.col);
                        start_row = s_dp.display_line;
                        end_row = e_dp.display_line;
                        if (state.textareaVisualLineAtOffset(sel_start)) |geometry| {
                            start_x = geometry.caretX(sel_start, .downstream);
                        }
                        if (state.textareaVisualLineAtOffset(sel_end)) |geometry| {
                            end_x = geometry.caretX(sel_end, .downstream);
                        }
                        if (start_row == end_row) {
                            const info = wrap.displayLineInfo(s_dp.display_line, doc);
                            const seg = displaySegRange(doc, info);
                            if (state.visualLineForSegment(seg.start, seg.end, s_dp.display_line)) |geometry| {
                                const rects = geometry.line.selectionRects(
                                    .{ .value = sel_start -| seg.start },
                                    .{ .value = sel_end -| seg.start },
                                    &bidi_rect_storage,
                                ) catch &.{};
                                bidi_rect_count = rects.len;
                            }
                        }
                    }
                } else {
                    const display_text = state.buildDisplayText(null);
                    const start_pos = state.multilineVisualPosForOffset(display_text, sel_start);
                    const end_pos = state.multilineVisualPosForOffset(display_text, sel_end);
                    start_row = start_pos.row;
                    start_x = start_pos.x;
                    end_row = end_pos.row;
                    end_x = end_pos.x;
                }
                const sel_bg = state.tokens.tokens.color.selection_bg;
                const lh = state.line_height;

                if (start_row == end_row) {
                    if (bidi_rect_count > 0) {
                        const first = bidi_rect_storage[0];
                        sel.setLayoutRect(.{
                            .x = @round(container_inner_x + first.x),
                            .y = @round(container_inner_y + @as(f32, @floatFromInt(start_row)) * lh),
                            .w = @round(first.width),
                            .h = lh,
                        });
                        sel.setBackgroundRaw(sel_bg);
                        const extra_count: u8 = @intCast(@min(bidi_rect_count - 1, 15));
                        ensureExtraSelNodes(state, extra_count, node);
                        var rect_index: usize = 1;
                        while (rect_index < bidi_rect_count and rect_index <= 15) : (rect_index += 1) {
                            if (state.extra_sel_nodes[rect_index - 1]) |extra| {
                                const rect = bidi_rect_storage[rect_index];
                                extra.setLayoutRect(.{
                                    .x = @round(container_inner_x + rect.x),
                                    .y = @round(container_inner_y + @as(f32, @floatFromInt(start_row)) * lh),
                                    .w = @round(rect.width),
                                    .h = lh,
                                });
                                extra.setBackgroundRaw(sel_bg);
                                extra.markRenderDirty();
                            }
                        }
                        while (rect_index - 1 < state.extra_sel_count) : (rect_index += 1) {
                            if (state.extra_sel_nodes[rect_index - 1]) |extra| {
                                extra.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
                                extra.setBackgroundRaw(Color.TRANSPARENT);
                                extra.markRenderDirty();
                            }
                        }
                    } else {
                        sel.setLayoutRect(.{
                            .x = @round(container_inner_x + @min(start_x, end_x)),
                            .y = @round(container_inner_y + @as(f32, @floatFromInt(start_row)) * lh),
                            .w = @round(@abs(end_x - start_x)),
                            .h = lh,
                        });
                        sel.setBackgroundRaw(sel_bg);
                        hideExtraSelNodes(state);
                    }
                } else {
                    // Cross-line: highlight covers only **actual text width per line** (strip
                    // trailing space), not full wrap width; full wrap would 'select' trailing
                    // whitespace. First line (start_x -> line text end).
                    const first_row_w = displayRowTextWidth(state, start_row) orelse state.input_inner_w;
                    sel.setLayoutRect(.{
                        .x = @round(container_inner_x + start_x),
                        .y = @round(container_inner_y + @as(f32, @floatFromInt(start_row)) * lh),
                        .w = @round(@max(first_row_w - start_x, 4)),
                        .h = lh,
                    });
                    sel.setBackgroundRaw(sel_bg);

                    // Middle lines + final line.
                    const total_rows = end_row - start_row + 1;
                    const extra_needed = total_rows - 1; // First line already handled by sel.
                    ensureExtraSelNodes(state, @intCast(@min(extra_needed, 15)), node);

                    var ri: usize = 0;
                    while (ri < @min(extra_needed, 15)) : (ri += 1) {
                        const row = start_row + 1 + ri;
                        const is_last = (row == end_row);
                        if (state.extra_sel_nodes[ri]) |esel| {
                            const row_w: f32 = if (is_last)
                                end_x
                            else
                                displayRowTextWidth(state, row) orelse state.input_inner_w;
                            esel.setLayoutRect(.{
                                .x = @round(container_inner_x),
                                .y = @round(container_inner_y + @as(f32, @floatFromInt(row)) * lh),
                                .w = @round(@max(row_w, 4)),
                                .h = lh,
                            });
                            esel.setBackgroundRaw(sel_bg);
                            esel.markRenderDirty();
                        }
                    }
                    // Hide extra nodes.
                    while (ri < state.extra_sel_count) : (ri += 1) {
                        if (state.extra_sel_nodes[ri]) |esel| {
                            esel.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
                            esel.setBackgroundRaw(Color.TRANSPARENT);
                            esel.markRenderDirty();
                        }
                    }
                }
            } else {
                // Single-line selection: original logic.
                const text = state.getText();
                const start_px_raw = text_utils.utf8MeasuredAdvancePrefixCx(state.cx_ref, text, sel_start, state.char_width, state.font_size, state.font_weight) - state.scroll_x;
                const end_px_raw = text_utils.utf8MeasuredAdvancePrefixCx(state.cx_ref, text, sel_end, state.char_width, state.font_size, state.font_weight) - state.scroll_x;
                const clip_max = @max(@as(f32, 0), state.input_inner_w);
                const vis_start = std.math.clamp(@min(start_px_raw, end_px_raw), @as(f32, 0), clip_max);
                const vis_end = std.math.clamp(@max(start_px_raw, end_px_raw), @as(f32, 0), clip_max);
                const vis_w = @max(@as(f32, 0), vis_end - vis_start);
                if (vis_w > 0) {
                    sel.setLayoutRect(.{
                        .x = @round(container_inner_x + vis_start),
                        .y = @round(cursor_y),
                        .w = @round(vis_w),
                        .h = cursor_h,
                    });
                    sel.setBackgroundRaw(state.tokens.tokens.color.selection_bg);
                } else {
                    sel.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
                    sel.setBackgroundRaw(Color.TRANSPARENT);
                }
            }
        } else {
            sel.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
            sel.setBackgroundRaw(Color.TRANSPARENT);
            hideExtraSelNodes(state);
        }
    } else {
        sel.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        sel.setBackgroundRaw(Color.TRANSPARENT);
        hideExtraSelNodes(state);
    }
    sel.markRenderDirty();
}

/// Actual text width for display line (strip trailing space). Used by cross-line selection
/// highlight, covers only text, not full wrap width. Returns null without WrapMap path (caller
/// falls back to line width).
fn displayRowTextWidth(state: *TextInputState, row: usize) ?f32 {
    const wrap = state.textarea_wrap orelse return null;
    const doc = state.textarea_doc orelse return null;
    if (row >= wrap.total_display_lines) return null;
    const info = wrap.displayLineInfo(@intCast(row), doc);
    const seg = displaySegRange(doc, info);
    var txt = doc.getText()[seg.start..seg.end];
    while (txt.len > 0 and (txt[txt.len - 1] == ' ' or txt[txt.len - 1] == '\t')) txt = txt[0 .. txt.len - 1];
    return text_utils.utf8MeasuredAdvancePrefixCx(state.cx_ref, txt, txt.len, state.char_width, state.font_size, state.font_weight);
}

/// Multi-line IME preedit underline (old logic, multi-line only).
fn updateMultilinePreeditUnderline(
    state: *TextInputState,
    container_inner_x: f32,
    container_inner_y: f32,
    cursor_y: f32,
    cursor_h: f32,
) void {
    const line = state.preedit_underline_node orelse return;
    if (state.hasImePreedit()) {
        var preedit_start_px = state.imePreeditStartAdvance() - state.scroll_x;
        var preedit_width_px = @max(state.imePreeditAdvance(), @max(4.0, state.char_width * 0.5));
        var underline_y = cursor_y + cursor_h - 1;
        if (state.ime_visual_valid) {
            preedit_start_px = state.ime_visual_underline_x;
            preedit_width_px = state.ime_visual_underline_width;
            underline_y = container_inner_y + @as(f32, @floatFromInt(state.ime_visual_display_line)) * state.line_height + cursor_h - 1;
        } else if (state.multiline) {
            if (state.textarea_wrap) |wrap| {
                if (state.textarea_doc) |doc| {
                    const lc = doc.offsetToLineCol(state.cursor_pos);
                    const dp = wrap.bufferToDisplay(lc.line, lc.col);
                    const info = wrap.displayLineInfo(dp.display_line, doc);
                    const seg = displaySegRange(doc, info);
                    if (textareaPreeditVisualSpan(state, doc, seg)) |span| {
                        preedit_start_px = span.x;
                        preedit_width_px = @max(span.width, @max(4.0, state.char_width * 0.5));
                    }
                    underline_y = container_inner_y + @as(f32, @floatFromInt(dp.display_line)) * state.line_height + cursor_h - 1;
                }
            } else {
                const cursor_text = state.buildDisplayText(null);
                const preedit_start = @min(state.cursor_pos, state.buffer_len);
                const preedit_end = preedit_start + state.ime_preedit_len;
                const start_pos = state.multilineVisualPosForOffset(cursor_text, preedit_start);
                const end_pos = state.multilineVisualPosForOffset(cursor_text, preedit_end);
                preedit_start_px = start_pos.x;
                preedit_width_px = if (start_pos.row == end_pos.row)
                    @max(end_pos.x - start_pos.x, @max(4.0, state.char_width * 0.5))
                else
                    @max(state.input_inner_w - start_pos.x, @max(4.0, state.char_width * 0.5));
                underline_y = container_inner_y + @as(f32, @floatFromInt(start_pos.row)) * state.line_height + cursor_h - 1;
            }
        }
        line.setLayoutRect(.{
            .x = @round(container_inner_x + preedit_start_px),
            .y = @round(underline_y),
            .w = @round(preedit_width_px),
            .h = 1.0,
        });
        line.setBackgroundRaw(styles.imePreeditUnderlineColor(state.tokens));
    } else {
        line.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        line.setBackgroundRaw(Color.TRANSPARENT);
    }
    line.markRenderDirty();
}

// WrapMap display segment helpers.

const TextareaDocument = state_mod.TextareaDocument;
const DisplayLineInfo = state_mod.DisplayLineInfo;
const SegRange = struct { start: usize, end: usize };

/// Compute buffer byte range [seg_start, seg_end) from displayLineInfo. byte_end may be
/// maxInt(usize), must clamp to line_end.
fn displaySegRange(doc: *const TextareaDocument, info: DisplayLineInfo) SegRange {
    const line_start = doc.getLineStart(info.buffer_line);
    const line_end = doc.getLineEnd(info.buffer_line);
    const seg_start = @min(line_start +| info.byte_start, line_end);
    const seg_end = if (info.byte_end >= std.math.maxInt(usize) / 2)
        line_end
    else
        @min(line_start +| info.byte_end, line_end);
    return .{ .start = seg_start, .end = seg_end };
}

fn textareaPreeditVisualSpan(
    state: *TextInputState,
    doc: *const TextareaDocument,
    seg: SegRange,
) ?struct { x: f32, width: f32 } {
    const cx = state.cx_ref orelse return null;
    if (!state.hasImePreedit() or state.cursor_pos < seg.start or state.cursor_pos > seg.end) return null;
    const text = doc.getText()[seg.start..seg.end];
    const insert = state.cursor_pos - seg.start;
    const composed = state.composeDisplaySegmentWithIme(text, insert);
    const line = cx.text.visualLine(.{
        .text = composed,
        .font_family = "system",
        .font_size = state.font_size,
        .font_weight = state.font_weight,
    }) catch return null;
    var storage: [16]SelectionRect = undefined;
    const rects = line.selectionRects(
        .{ .value = insert },
        .{ .value = insert + state.ime_preedit_len },
        &storage,
    ) catch return null;
    if (rects.len == 0) return null;
    var min_x = rects[0].x;
    var max_x = rects[0].x + rects[0].width;
    for (rects[1..]) |rect| {
        min_x = @min(min_x, rect.x);
        max_x = @max(max_x, rect.x + rect.width);
    }
    return .{ .x = min_x, .width = max_x - min_x };
}

// Multi-line selection helpers.

/// Ensure overlay has enough extra selection nodes.
fn ensureExtraSelNodes(state: *TextInputState, needed: u8, _: *Node) void {
    const overlay = state.textarea_overlay_node orelse return;
    const cx = state.cx_ref orelse return;

    while (state.extra_sel_count < needed) {
        const esel = box(cx, .{
            .width = .{ .px = 0 },
            .height = .{ .px = 0 },
        }, .{}) catch return;
        overlay.appendChild(cx.allocator, esel) catch return;
        state.extra_sel_nodes[state.extra_sel_count] = esel;
        state.extra_sel_count += 1;
    }
}

/// Hide all extra selection nodes.
fn hideExtraSelNodes(state: *TextInputState) void {
    var i: u8 = 0;
    while (i < state.extra_sel_count) : (i += 1) {
        if (state.extra_sel_nodes[i]) |esel| {
            esel.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
            esel.setBackgroundRaw(Color.TRANSPARENT);
            esel.markRenderDirty();
        }
    }
}

// Textarea VirtualList integration.

/// Compute current textarea text line count (including soft wraps).
pub fn countTextareaLines(state: *TextInputState) usize {
    // WrapMap path.
    if (state.textarea_wrap) |wrap| {
        const dl = wrap.displayLineCount();
        return if (dl > 0) dl else 1;
    }

    // Fallback: old path.
    const wrapped = state.buildWrappedDisplayTextChecked(state.placeholder_text) catch {
        state.dirty = true;
        if (state.cx_ref) |cx| {
            if (state.input_container_node) |node| @import("row_text.zig").retry(cx, node);
        }
        return if (state.vl_state) |vl| vl.item_count else 1;
    };

    var line_count: usize = 1;
    for (wrapped) |c| {
        if (c == '\n') line_count += 1;
    }
    return line_count;
}

/// VirtualList renderItem callback: render text line per index.
pub fn textareaRenderItem(item_node: *Node, index: usize, cx: *Cx, user_context: ?*anyopaque) void {
    const state: *TextInputState = @ptrCast(@alignCast(user_context orelse return));
    const has_content = state.hasVisualValue();
    const text_color = if (state.disabled) state.tokens.tokens.color.fg_disabled else if (has_content) state.tokens.tokens.color.fg_primary else state.tokens.tokens.color.fg_secondary;

    // WrapMap + TextareaDocument path.
    if (state.textarea_wrap) |wrap| {
        if (state.textarea_doc) |doc| {
            const dl: u32 = @intCast(index);
            const info = wrap.displayLineInfo(dl, doc);
            const txt = doc.getText();
            const seg = displaySegRange(doc, info);
            var line_content = if (seg.start <= seg.end and seg.end <= txt.len) txt[seg.start..seg.end] else "";
            if (state.imeInsertOffsetForDisplaySegment(doc, info.buffer_line, seg.start, seg.end)) |insert_offset| {
                line_content = state.composeDisplaySegmentWithImeChecked(line_content, insert_offset) catch {
                    state.dirty = true;
                    @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
                    return;
                };
            } else if (state.ime_replacement) |replacement| {
                const out = state.imeSegmentStorage(line_content.len) catch {
                    state.dirty = true;
                    @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
                    return;
                };
                line_content = replacement.compose(line_content, seg.start, "", false, out);
            }

            @import("row_text.zig").set(item_node, cx, line_content, text_color, state.font_size) catch {
                state.dirty = true;
                @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
                return;
            };
            return;
        }
    }

    // Fallback: old path.
    const wrapped = state.buildWrappedDisplayTextChecked(state.placeholder_text) catch {
        state.dirty = true;
        @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
        return;
    };

    // Find content of line index.
    var line_start: usize = 0;
    var current_line: usize = 0;
    var i: usize = 0;
    var line_content: []const u8 = "";

    while (i <= wrapped.len) : (i += 1) {
        if (i < wrapped.len and wrapped[i] != '\n') continue;
        if (current_line == index) {
            line_content = wrapped[line_start..i];
            break;
        }
        current_line += 1;
        line_start = i + 1;
        if (i == wrapped.len) break;
    }

    @import("row_text.zig").set(item_node, cx, line_content, text_color, state.font_size) catch {
        state.dirty = true;
        @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
        return;
    };
}

test "legacy input frame retries pending wrap without a width change" {
    const t = std.testing;
    const Doc = @import("textarea_document.zig").TextareaDocument;
    const Map = @import("text_core").wrap_map.WrapMap(Doc);
    var doc = Doc.init(t.allocator);
    defer doc.deinit();
    doc.setText((@as([("abcdefgh").len * (8)]u8, @bitCast(@as([8][("abcdefgh").len]u8, @splat(("abcdefgh").*)))) ++ ""));
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var wm = Map.init(failing.allocator(), @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 8;
    wm.wrap_width = 64;
    wm.setEnabled(true, &doc);
    wm.rebuildAll(&doc);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    wm.rebuildAll(&doc);
    try t.expect(wm.has_interpolated_lines);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    var state: TextInputState = .{ .io = @import("std").testing.io, .multiline = true, .textarea_doc = &doc, .textarea_wrap = &wm, .allocator = t.allocator, .input_inner_w = 64 };
    defer state.deinit();
    var node: Node = .{ .id = 1, .tag = .box, .style = .{}, .children = .empty };
    node.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 100 });
    node.behavior.events.event_context = &state;
    inputBeforeRender(&node);
    try t.expectEqual(@as(f32, 64), state.input_inner_w);
    try t.expect(!wm.has_interpolated_lines);
    try t.expect(!wm.needs_rebuild);
    try t.expectEqual(@as(u32, 8), wm.total_display_lines);
}

test "input accessibility same length failed replacement reports failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator() };
    defer state.deinit();
    _ = state.setText("old");
    failing.fail_index = failing.alloc_index;
    try std.testing.expect(!setA11yValue(&state, "new"));
    try std.testing.expectEqualStrings("old", state.getText());
}

test "IME rendered rows retain independent bytes across reconversion and model updates" {
    const t = std.testing;
    const Doc = @import("textarea_document.zig").TextareaDocument;
    const Map = @import("text_core").wrap_map.WrapMap(Doc);
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const first = try core.box(cx, .{}, .{});
    try root.appendChild(t.allocator, first);
    const second = try core.box(cx, .{}, .{});
    try root.appendChild(t.allocator, second);
    var doc = Doc.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abc\ndefgh");
    var wm = Map.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var s: TextInputState = .{ .io = @import("std").testing.io, .textarea_doc = &doc, .textarea_wrap = &wm, .multiline = true, .allocator = t.allocator };
    defer s.deinit();
    s.cursor_pos = doc.totalLength();
    s.handleImePreeditReplaceEvent("候选", 6, 1, 8);
    textareaRenderItem(first, 0, cx, &s);
    try t.expectEqualStrings("a候选", first.getText().?.content);
    textareaRenderItem(second, 1, cx, &s);
    try t.expectEqualStrings("h", second.getText().?.content);
    try t.expectEqualStrings("a候选", first.getText().?.content);
    s.cancelImeComposition();
    textareaRenderItem(first, 0, cx, &s);
    textareaRenderItem(second, 1, cx, &s);
    try t.expectEqualStrings("abc", first.getText().?.content);
    try t.expectEqualStrings("defgh", second.getText().?.content);
    // Retained nodes must not borrow canonical document memory either.
    try doc.setTextChecked((@as([("replacement").len * (600)]u8, @bitCast(@as([600][("replacement").len]u8, @splat(("replacement").*)))) ++ ""));
    try t.expectEqualStrings("abc", first.getText().?.content);
    try t.expectEqualStrings("defgh", second.getText().?.content);
}

test "IME row allocation failure retains text and schedules retry without another edit" {
    const t = std.testing;
    const Doc = @import("textarea_document.zig").TextareaDocument;
    const Map = @import("text_core").wrap_map.WrapMap(Doc);
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var cx = try Cx.init(failing.allocator(), std.testing.io);
    defer cx.deinit();
    const row = try core.box(cx, .{}, .{});
    cx.root = row;
    var doc = Doc.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abc");
    var wm = Map.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var s: TextInputState = .{ .io = @import("std").testing.io, .textarea_doc = &doc, .textarea_wrap = &wm, .multiline = true, .allocator = t.allocator };
    defer s.deinit();
    s.cursor_pos = 3;
    textareaRenderItem(row, 0, cx, &s);
    const old_ptr = row.getText().?.content.ptr;
    s.setImePreedit("候选", 6);
    s.dirty = false;
    failing.fail_index = failing.alloc_index;
    textareaRenderItem(row, 0, cx, &s);
    try t.expect(failing.has_induced_failure);
    try t.expectEqualStrings("abc", row.getText().?.content);
    try t.expectEqual(old_ptr, row.getText().?.content.ptr);
    try t.expectEqualStrings("abc", s.getText());
    try t.expect(s.imeIsComposing());
    try t.expect(s.dirty);
    try t.expect(cx.next_redraw_delay_ns.? <= 16 * std.time.ns_per_ms);
    failing.fail_index = std.math.maxInt(usize);
    textareaRenderItem(row, 0, cx, &s);
    try t.expectEqualStrings("abc候选", row.getText().?.content);
    const new_ptr = row.getText().?.content.ptr;
    // Repeated frames and style-only changes reuse the owned bytes.
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    s.font_size = 18;
    textareaRenderItem(row, 0, cx, &s);
    try t.expectEqual(allocations, failing.alloc_index);
    try t.expectEqual(new_ptr, row.getText().?.content.ptr);
    try t.expectEqual(@as(f32, 18), row.getText().?.font_size);
    failing.fail_index = std.math.maxInt(usize);
}

test "fallback wrapped rows own text across recomposition and cancellation" {
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const first = try core.box(cx, .{}, .{});
    try root.appendChild(t.allocator, first);
    const second = try core.box(cx, .{}, .{});
    try root.appendChild(t.allocator, second);
    var s: TextInputState = .{ .io = @import("std").testing.io, .multiline = true, .soft_wrap = true, .input_inner_w = 24, .char_width = 8, .allocator = t.allocator };
    defer s.deinit();
    _ = try s.setTextChecked("abcdef");
    textareaRenderItem(first, 0, cx, &s);
    textareaRenderItem(second, 1, cx, &s);
    try t.expectEqualStrings("abc", first.getText().?.content);
    try t.expectEqualStrings("def", second.getText().?.content);
    s.cursor_pos = 0;
    s.setImePreedit("XYZ", 3);
    textareaRenderItem(first, 0, cx, &s);
    try t.expectEqualStrings("XYZ", first.getText().?.content);
    try t.expectEqualStrings("def", second.getText().?.content);
    s.cancelImeComposition();
    textareaRenderItem(second, 0, cx, &s);
    try t.expectEqualStrings("abc", second.getText().?.content);
    try t.expectEqualStrings("XYZ", first.getText().?.content);
}

test "long password preedit spans use the same grapheme mask coordinates" {
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    const row = try core.box(cx, .{}, .{});
    cx.root = row;
    row.setText(.{ .content = "" });
    var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .input_type = .password, .text_display_node = row, .cx_ref = cx };
    defer s.deinit();
    _ = try s.setTextChecked("👩‍💻x");
    s.cursor_pos = "👩‍💻".len;
    const candidate = (@as([("漢").len * (1000)]u8, @bitCast(@as([1000][("漢").len]u8, @splat(("漢").*)))) ++ "") ++ "👩‍💻";
    try s.setImePreeditChecked(candidate, candidate.len);
    rebuildSingleLineSpans(&s);
    try t.expectEqualStrings((@as([("*").len * (1003)]u8, @bitCast(@as([1003][("*").len]u8, @splat(("*").*)))) ++ ""), row.getText().?.content);
    try t.expect(row.getTextRaw().?.owned);
    try t.expectEqual(@as(u32, 1), row.getText().?.spans[0].start);
    try t.expectEqual(@as(u32, 1002), row.getText().?.spans[0].end);
    try t.expectEqual(@as(usize, 1002), s.visualCursorPos());
    s.cancelImeComposition();
    rebuildSingleLineSpans(&s);
    try t.expectEqualStrings("**", row.getText().?.content);
    try t.expectEqual(@as(usize, 0), row.getText().?.spans.len);
}

test "a11yGeometry Input retains shaped spans centered origin and horizontal scroll" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core.FontSystem.init(t.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();
    const text_node = try core.box(cx, .{}, .{});
    cx.root = text_node;
    text_node.setLayoutRect(.{ .x = 10, .y = 70, .w = 100, .h = 20 });
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .cx_ref = cx, .font_size = 16, .line_height = 20, .container_x = 11, .container_y = 13, .padding_h = 7, .padding_v = 5, .text_display_node = text_node };
    defer state.deinit();
    _ = try state.setTextChecked("abc 中😀 \u{05D0}\u{05D1}");
    state.cursor_pos = 2;
    state.selection_anchor = 1;
    state.scroll_x = 23;
    const owned = try a11yGeometry(&state, t.allocator);
    defer t.allocator.free(owned);
    const line = try cx.text.visualLine(.{ .text = state.getText(), .font_family = "system", .font_size = 16 });
    var segments = line.selectionSegments();
    var count: usize = 0;
    while (segments.next()) |segment| {
        if (segment.rect.width <= 0) continue;
        try t.expect(count < owned.len);
        try t.expectEqual(segment.start.value, owned[count].start);
        try t.expectEqual(segment.end.value, owned[count].end);
        try t.expectApproxEqAbs(segment.rect.x - 5, owned[count].rect.x, 0.01);
        try t.expectEqual(text_node.globalRect().y, owned[count].rect.y);
        try t.expectEqual(segment.rect.width, owned[count].rect.width);
        count += 1;
    }
    try t.expect(count > 0 and count == owned.len);
    state.scroll_x += 20;
    const scrolled = try a11yGeometry(&state, t.allocator);
    defer t.allocator.free(scrolled);
    try t.expectEqual(owned.len, scrolled.len);
    for (owned, scrolled) |before, after| {
        try t.expectApproxEqAbs(before.rect.x - 20, after.rect.x, 0.01);
        try t.expectEqual(before.start, after.start);
        try t.expectEqual(before.end, after.end);
    }
    try t.expectEqual(@as(usize, 2), state.cursor_pos);
    try t.expectEqual(@as(?usize, 1), state.selection_anchor);
    try state.setImePreeditChecked("漢", 3);
    try t.expectError(error.AccessibilityLayoutPending, a11yGeometry(&state, t.allocator));
    state.cancelImeComposition();
    state.input_type = .password;
    try t.expectError(error.AccessibilitySecureText, a11yGeometry(&state, t.allocator));
}

test "a11yGeometry multiline EditableText preserves wrapped rows and rejects estimates" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core.FontSystem.init(t.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abcdefgh\nx");
    var wm = state_mod.TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 8;
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(32, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .cx_ref = cx, .multiline = true, .textarea_doc = &doc, .textarea_wrap = &wm, .font_size = 16, .line_height = 20, .container_x = 11, .container_y = 13, .padding_h = 7, .padding_v = 5 };
    defer state.deinit();
    const owned = try a11yGeometry(&state, t.allocator);
    defer t.allocator.free(owned);
    var count: usize = 0;
    for (0..wm.displayLineCount()) |row| {
        const span = displaySegRange(&doc, wm.displayLineInfo(@intCast(row), &doc));
        const line = try cx.text.visualLine(.{ .text = doc.getText()[span.start..span.end], .font_family = "system", .font_size = 16 });
        var segments = line.selectionSegments();
        while (segments.next()) |segment| {
            if (segment.rect.width <= 0) continue;
            try t.expect(count < owned.len);
            try t.expectEqual(span.start + segment.start.value, owned[count].start);
            try t.expectEqual(span.start + segment.end.value, owned[count].end);
            try t.expectApproxEqAbs(18 + segment.rect.x, owned[count].rect.x, 0.01);
            try t.expectApproxEqAbs(18 + @as(f32, @floatFromInt(row)) * 20, owned[count].rect.y, 0.01);
            count += 1;
        }
    }
    try t.expect(count == owned.len and count >= 3);
    wm.has_interpolated_lines = true;
    try t.expectError(error.AccessibilityLayoutPending, a11yGeometry(&state, t.allocator));
    wm.has_interpolated_lines = false;
    state.textarea_wrap = null;
    try t.expectError(error.AccessibilityLayoutPending, a11yGeometry(&state, t.allocator));
}

test "a11yScrollIntoView horizontal request preserves caret and rejects stale text" {
    const t = std.testing;
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .input_inner_w = 20, .char_width = 8 };
    defer state.deinit();
    _ = try state.setTextChecked("abcdefgh");
    state.cursor_pos = 2;
    state.selection_anchor = 1;
    try t.expect(scrollA11yRange(&state, 6, 8, false));
    try t.expectEqual(@as(f32, 0), state.scroll_x);
    applyA11yScroll(&state);
    const measured = text_utils.utf8MeasuredAdvanceCx(null, state.getText(), state.char_width, state.font_size, state.font_weight);
    try t.expectApproxEqAbs(@as(f32, 20), measured - state.scroll_x, 0.01);
    try t.expectEqual(@as(usize, 2), state.cursor_pos);
    try t.expectEqual(@as(?usize, 1), state.selection_anchor);
    try t.expect(scrollA11yRange(&state, 0, 1, true));
    applyA11yScroll(&state);
    try t.expectEqual(@as(f32, 0), state.scroll_x);
    try t.expect(scrollA11yRange(&state, 6, 8, false));
    state.cursor_pos = 3; // A later ordinary cursor action wins over the request.
    applyA11yScroll(&state);
    try t.expectEqual(@as(f32, 0), state.scroll_x);
    try t.expect(scrollA11yRange(&state, 6, 8, false));
    _ = try state.setTextChecked("12345678");
    applyA11yScroll(&state);
    try t.expectEqual(@as(f32, 0), state.scroll_x);
    try t.expect(scrollA11yRange(&state, 6, 8, false));
    try t.expect(state.setAccessibilitySelection(0, 0));
    try t.expect(state.a11y_scroll_request == null);
    try t.expect(!scrollA11yRange(&state, 8, 7, true));
    try t.expect(!scrollA11yRange(&state, 0, 9, true));
    _ = try state.setTextChecked("e\u{0301}x");
    try t.expect(!scrollA11yRange(&state, 2, 3, true));
    try t.expect(scrollA11yRange(&state, 1, 3, true));
    try t.expectEqual(@as(u32, 0), state.a11y_scroll_request.?.start);
    try t.expectEqual(@as(u32, 3), state.a11y_scroll_request.?.end);
    state.input_type = .password;
    try t.expect(!scrollA11yRange(&state, 0, 3, true));
}

test "accessibility caret geometry Input preserves shaped stops scroll empty text and guards" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core.FontSystem.init(t.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .cx_ref = cx, .font_size = 16, .line_height = 20, .container_x = 11, .container_y = 13, .padding_h = 7, .padding_v = 5, .scroll_x = 23 };
    defer state.deinit();
    _ = try state.setTextChecked("abc 中😀 \u{05D0}\u{05D1}");
    const owned = try a11yCaretGeometry(&state, t.allocator);
    defer t.allocator.free(owned);
    const line = try cx.text.visualLine(.{ .text = state.getText(), .font_family = "system", .font_size = 16 });
    try t.expectEqual(line.caret_stops.len, owned.len);
    for (line.caret_stops, owned) |stop, actual| {
        try t.expectEqual(stop.position.byte.value, actual.offset);
        try t.expectApproxEqAbs(stop.x.value - 5, actual.rect.x, 0.01);
        try t.expectEqual(@as(f32, 18), actual.rect.y);
        try t.expectEqual(@as(f32, 0), actual.rect.width);
        try t.expectEqual(@as(f32, 20), actual.rect.height);
        try t.expectEqual(stop.position.affinity == .downstream, actual.downstream);
    }
    state.scroll_x += 20;
    const scrolled = try a11yCaretGeometry(&state, t.allocator);
    defer t.allocator.free(scrolled);
    for (owned, scrolled) |before, after| {
        try t.expectEqual(before.offset, after.offset);
        try t.expectApproxEqAbs(before.rect.x - 20, after.rect.x, 0.01);
    }
    _ = try state.setTextChecked("");
    const empty = try a11yCaretGeometry(&state, t.allocator);
    defer t.allocator.free(empty);
    try t.expectEqual(@as(usize, 1), empty.len);
    try t.expectEqual(@as(u32, 0), empty[0].offset);
    try state.setImePreeditChecked("漢", 3);
    try t.expectError(error.AccessibilityLayoutPending, a11yCaretGeometry(&state, t.allocator));
    state.cancelImeComposition();
    state.input_type = .password;
    try t.expectError(error.AccessibilitySecureText, a11yCaretGeometry(&state, t.allocator));
    state.input_type = .text;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("A\n\n");
    var map = state_mod.TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer map.deinit();
    state.multiline = true;
    state.textarea_doc = &doc;
    state.textarea_wrap = &map;
    const rows = try a11yCaretGeometry(&state, t.allocator);
    defer t.allocator.free(rows);
    try t.expectEqual(@as(usize, 4), rows.len);
    try t.expectEqual(@as(u32, 2), rows[2].offset);
    try t.expectEqual(@as(u32, 3), rows[3].offset);
    try t.expectEqual(@as(f32, 38), rows[2].rect.y);
    try t.expectEqual(@as(f32, 58), rows[3].rect.y);
    const boxes = try a11yGeometry(&state, t.allocator);
    defer t.allocator.free(boxes);
    try t.expectEqual(@as(usize, 1), boxes.len);
    try t.expectEqual(@as(u32, 0), boxes[0].start);
    try t.expectEqual(@as(u32, 1), boxes[0].end);
}

test "a11y row geometry Input preserves newline and empty rows without wrapping" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("A\n\n");
    var map = state_mod.TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer map.deinit();
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .multiline = true, .textarea_doc = &doc, .textarea_wrap = &map, .container_x = 11, .container_y = 13, .padding_h = 7, .padding_v = 5, .input_inner_w = 70, .line_height = 20 };
    defer state.deinit();
    const rows = try a11yRowGeometry(&state, t.allocator);
    defer t.allocator.free(rows);
    try t.expectEqual(@as(usize, 3), rows.len);
    for (rows, [_]u32{ 0, 2, 3 }, [_]u32{ 2, 3, 3 }, 0..) |row, start, end, i| {
        try t.expectEqual(start, row.start);
        try t.expectEqual(end, row.end);
        try t.expectEqual(@as(f32, 18), row.rect.x);
        try t.expectEqual(18 + @as(f32, @floatFromInt(i)) * 20, row.rect.y);
        try t.expectEqual(@as(f32, 70), row.rect.width);
    }
    state.input_type = .password;
    try t.expectError(error.AccessibilitySecureText, a11yRowGeometry(&state, t.allocator));
    state.input_type = .text;
    state.input_inner_w = 0;
    try t.expectError(error.AccessibilityLayoutPending, a11yRowGeometry(&state, t.allocator));
    state.input_inner_w = 70;
    map.enabled = true;
    map.has_interpolated_lines = true;
    try t.expectError(error.AccessibilityLayoutPending, a11yRowGeometry(&state, t.allocator));
}
