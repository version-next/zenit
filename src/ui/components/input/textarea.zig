const ImeReplacement = @import("ime_replacement.zig").ImeReplacement;
const ImeText = @import("ime_text.zig").ImeText;
/// Textarea, independent multiline text editing component.
///
/// Completely separate from TextInputState; uses TextareaDocument + DocCursor + WrapMap.
/// Supports: multiline, soft wrapping, IME Chinese input, selection, Undo/Redo, VirtualList
/// virtualization.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core_ui = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core_ui.Cx;
const Node = core_ui.Node;
const box = core_ui.box;
const Color = core_ui.Color;
const Padding = core_ui.Padding;
const Signal = core_ui.Signal;
const theme = core_ui.theme;
const ThemeTokens = theme.ThemeTokens;
const events_mod = @import("../../events.zig");
const Event = events_mod.Event;
const EventResult = events_mod.EventResult;
const KeyCode = events_mod.KeyCode;
const Modifiers = events_mod.Modifiers;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;
const Source = reactive.Source;
const Model = reactive.Model;
const Handler = core_ui.Handler;
const binding_mod = @import("binding.zig");
const hooks = @import("../../hooks.zig");
const recipe_mod = @import("../../recipe.zig");
const editable_block = @import("../editable_block/mod.zig");
const styles = @import("styles.zig");
const control_shell = @import("../control_shell/mod.zig");
const virtual_list = @import("../virtual_list/mod.zig");
const VirtualListState = virtual_list.VirtualListState;
const scroll_area_event = @import("../scroll_area/event.zig");
const text_utils = @import("text_utils.zig");
const caret_blink = @import("caret_blink.zig");

const core_mod = @import("text_core");
const grapheme = core_mod.grapheme;
const DocCursor = core_mod.cursor.DocCursor;
const text_coordinates = core_mod.text_coordinates;
const wrap_map = core_mod.wrap_map;
const DisplayLineInfo = wrap_map.DisplayLineInfo;
const DisplayPoint = wrap_map.DisplayPoint;

const textarea_doc_mod = @import("textarea_document.zig");
const TextareaDocument = textarea_doc_mod.TextareaDocument;
const TextareaWrapMap = wrap_map.WrapMap(TextareaDocument);
const text_layout = @import("../../core/text_layout.zig");
pub const MeasureFn = text_layout.MeasureFn;

const ImeComposePhase = editable_block.ImeComposePhase;
const edit_reconcile = @import("edit_reconcile.zig");
const UserEditTxn = @import("state.zig").UserEditTxn;
const HistoryStash = @import("history_stash.zig").HistoryStash;

// ============================================================================
// Undo Entry
// ============================================================================

const UndoEntry = struct {
    text: ?[]const u8 = null,
    cursor_offset: usize = 0,
    anchor: ?usize = null,

    pub fn deinit(self: *UndoEntry, allocator: Allocator) void {
        if (self.text) |t| allocator.free(t);
        self.text = null;
    }
};

// ============================================================================
// TextareaState
// ============================================================================

pub const TextareaState = struct {
    io: std.Io,
    // ===== Core data model =====
    doc: *TextareaDocument,
    cursor: DocCursor(TextareaDocument) = .{},
    /// The same logical byte can have two visual carets at a bidi boundary.
    cursor_affinity: text_coordinates.Affinity = .downstream,
    /// Sticky physical x for repeated Up/Down navigation.
    preferred_visual_x: ?f32 = null,
    wrap_map: *TextareaWrapMap,
    a11y_scroll_request: ?core_ui.A11yProps.TextScrollRequest = null,
    allocator: Allocator,

    // ===== Undo/Redo =====
    undo_stack: [32]UndoEntry = @as([32]UndoEntry, @splat(.{})),
    undo_count: u8 = 0,
    redo_stack: [32]UndoEntry = @as([32]UndoEntry, @splat(.{})),
    redo_count: u8 = 0,
    /// Current user edit txn (semantics same as TextInputState.user_edit; Textarea has no undo
    /// coalescing)
    user_edit: UserEditTxn = .{},
    /// Redo stack cleared in txn / evicted undo entries (put back on reject; see history_stash.zig)
    undo_stash: HistoryStash(UndoEntry, 32) = .{},

    // ===== IME =====
    ime_preedit: ImeText = .{},
    ime_preedit_len: usize = 0,
    ime_cursor_utf8_offset: usize = 0,
    ime_cursor_visible: bool = true,
    ime_selection_end: ?usize = null,
    /// Persistent composed display text. Dynamic storage avoids truncating a
    /// long wrapped segment before/after the preedit insertion point.
    ime_render_buffer: std.ArrayListUnmanaged(u8) = .empty,
    ime_phase: ImeComposePhase = .idle,
    ime_pending_commit: ImeText = .{},
    ime_replacement: ?ImeReplacement = null,
    ime_selection_highlight: bool = false,

    // ===== Render node refs =====
    cursor_node: ?*Node = null,
    selection_node: ?*Node = null,
    preedit_underline_node: ?*Node = null,
    overlay_node: ?*Node = null,
    /// Selection underlay (must draw under text, else selection color blocks glyphs)
    selection_underlay_node: ?*Node = null,
    input_container_node: ?*Node = null,
    /// Mixed bidi selections can produce several rectangles per display line,
    /// so this storage must not impose a line/run-count ceiling.
    extra_sel_nodes: std.ArrayListUnmanaged(*Node) = .empty,
    extra_preedit_nodes: std.ArrayListUnmanaged(*Node) = .empty,

    // ===== VirtualList =====
    vl_state: ?*VirtualListState = null,

    // ===== Focus / interaction =====
    focused: bool = false,
    /// Caret blink phase (shared with TextInputState caret_blink.CaretBlink).
    /// Originally byte-for-byte copy of state.zig implementation.
    blink: caret_blink.CaretBlink = .{},
    last_blink_visible: bool = true,
    is_dragging: bool = false,
    drag_pointer: ?struct { x: f32, y: f32, time_ms: f64 } = null,
    suspend_drag_until_mouse_up: bool = false,
    last_mouse_down_instant: ?@import("zenit_time").Instant = null,
    last_mouse_down_pos: [2]f32 = .{ 0, 0 },
    consecutive_mouse_downs: u8 = 0,
    has_error: bool = false,
    dirty: bool = false,

    // ===== Metrics =====
    measure_fn: ?MeasureFn = null,
    char_width: f32 = 7.8,
    font_size: f32 = 13.0,
    font_weight: u16 = 400,
    padding_h: f32 = 8.0,
    padding_v: f32 = 8.0,
    line_height: f32 = 20.0,
    input_inner_w: f32 = 0,
    container_x: f32 = 0,
    container_y: f32 = 0,

    // ===== External refs =====
    cx_ref: ?*Cx = null,
    tokens: *const ThemeTokens = &theme.dark,
    placeholder_text: ?[]const u8 = null,

    // ===== Callbacks =====
    on_change: ?core_ui.HandlerRef = null,
    /// After composition canceled: value binding applies writes deferred during composition
    on_ime_cancelled: ?core_ui.HandlerRef = null,
    /// Dynamic disable: true makes event handler ignore all input
    disabled: bool = false,

    const blink_half_period_ns: i128 = 500 * std.time.ns_per_ms;

    const VisualSegment = struct {
        start: usize,
        end: usize,
        display_line: u32,
        line: text_coordinates.VisualLine,

        fn caretX(self: VisualSegment, global_byte: usize, affinity: text_coordinates.Affinity) f32 {
            const local = @min(global_byte -| self.start, self.end - self.start);
            if (self.line.positionToCaret(.{
                .byte = .{ .value = local },
                .affinity = affinity,
            }) catch null) |caret| return caret.x.value;
            for (self.line.caret_stops) |stop| {
                if (stop.position.byte.value == local) return stop.x.value;
            }
            return 0;
        }

        fn visualNeighbour(self: VisualSegment, global_byte: usize, affinity: text_coordinates.Affinity, delta: i32) ?text_coordinates.TextPosition {
            if (delta == 0 or self.line.caret_stops.len == 0) return null;
            const local = @min(global_byte -| self.start, self.end - self.start);
            var current: ?usize = null;
            for (self.line.caret_stops, 0..) |stop, i| {
                if (stop.position.byte.value == local and stop.position.affinity == affinity) {
                    current = i;
                    break;
                }
            }
            if (current == null) {
                for (self.line.caret_stops, 0..) |stop, i| {
                    if (stop.position.byte.value == local) {
                        current = i;
                        break;
                    }
                }
            }
            const index = current orelse return null;
            if (delta < 0) {
                if (index == 0) return null;
                return self.line.caret_stops[index - 1].position;
            }
            if (index + 1 >= self.line.caret_stops.len) return null;
            return self.line.caret_stops[index + 1].position;
        }
    };

    fn visualLineForSegment(self: *const TextareaState, start: usize, end: usize, display_line: u32) ?VisualSegment {
        const cx = self.cx_ref orelse return null;
        const text = self.doc.getText();
        if (start > end or end > text.len) return null;
        const line = cx.text.visualLine(.{
            .text = text[start..end],
            .font_family = "system",
            .font_size = self.font_size,
            .font_weight = self.font_weight,
        }) catch return null;
        return .{ .start = start, .end = end, .display_line = display_line, .line = line };
    }

    fn visualLineAtOffset(self: *const TextareaState, global_byte: usize) ?VisualSegment {
        const byte = @min(global_byte, self.doc.totalLength());
        const lc = self.doc.offsetToLineCol(byte);
        var display_line = self.wrap_map.bufferToDisplay(lc.line, lc.col).display_line;
        const info = self.wrap_map.displayLineInfo(display_line, self.doc);
        var seg = safeSegRange(self.doc, info);
        // A soft-wrap boundary has two physical carets. Affinity chooses which
        // visual line owns the byte.
        if (self.cursor_affinity == .upstream and byte == seg.start and display_line > 0) {
            const previous = safeSegRange(self.doc, self.wrap_map.displayLineInfo(display_line - 1, self.doc));
            if (previous.end == byte) {
                display_line -= 1;
                seg = previous;
            }
        }
        return self.visualLineForSegment(seg.start, seg.end, display_line);
    }

    const SelectionPlacement = struct {
        display_line: u32,
        rect: text_coordinates.SelectionRect,
    };

    /// Resolve a logical document selection into the disjoint rectangles that
    /// are actually visible on each shaped display line.
    fn collectSelectionPlacements(self: *const TextareaState, allocator: Allocator, output: *std.ArrayListUnmanaged(SelectionPlacement)) !void {
        if (self.ime_replacement != null) return;
        const selection = self.cursor.selection() orelse return;
        try self.collectRangePlacements(selection.start, selection.end, allocator, output);
    }

    /// Resolve arbitrary canonical UTF-8 offsets without changing the cursor.
    /// Results use display-line coordinates and the retained row window; they
    /// still need viewport/ancestor clipping before accessibility publication.
    /// Empty ranges have no selection underlay (caret geometry is separate).
    fn collectRangePlacements(self: *const TextareaState, start: usize, end: usize, allocator: Allocator, output: *std.ArrayListUnmanaged(SelectionPlacement)) !void {
        const text = self.doc.getText();
        if (start > end or end > text.len) return error.InvalidTextRange;
        if ((start < text.len and text[start] & 0xc0 == 0x80) or
            (end < text.len and text[end] & 0xc0 == 0x80)) return error.InvalidTextRange;
        if (start == end) return;
        const start_lc = self.doc.offsetToLineCol(start);
        const end_lc = self.doc.offsetToLineCol(end);
        var first = self.wrap_map.bufferToDisplay(start_lc.line, start_lc.col).display_line;
        var last = self.wrap_map.bufferToDisplay(end_lc.line, end_lc.col).display_line;

        // An exclusive end exactly at a soft-wrap boundary belongs to the
        // preceding segment, not to an empty range at the next segment.
        if (end > 0 and last > first) {
            const last_seg = safeSegRange(self.doc, self.wrap_map.displayLineInfo(last, self.doc));
            if (last_seg.start == end) last -= 1;
        }

        // Selection underlays outside VirtualList's retained window cannot be
        // seen. Clipping prevents a million-line selection from creating a
        // million retained Nodes while preserving every visible bidi run.
        if (self.vl_state) |vl| {
            if (vl.initialized and vl.prev_end > vl.prev_start) {
                const visible_first: u32 = @intCast(@min(vl.prev_start, std.math.maxInt(u32)));
                const visible_last: u32 = @intCast(@min(vl.prev_end - 1, std.math.maxInt(u32)));
                first = @max(first, visible_first);
                last = @min(last, visible_last);
            }
        }
        if (first > last) return;

        var display_line = first;
        while (true) {
            const seg = safeSegRange(self.doc, self.wrap_map.displayLineInfo(display_line, self.doc));
            const lo = @max(start, seg.start);
            const hi = @min(end, seg.end);
            if (lo < hi) {
                if (self.visualLineForSegment(seg.start, seg.end, display_line)) |geometry| {
                    const storage = try allocator.alloc(text_coordinates.SelectionRect, @max(geometry.line.caret_stops.len, 1));
                    defer allocator.free(storage);
                    const rects = try geometry.line.selectionRects(.{ .value = lo - seg.start }, .{ .value = hi - seg.start }, storage);
                    for (rects) |rect| try output.append(allocator, .{
                        .display_line = display_line,
                        .rect = rect,
                    });
                } else {
                    const seg_text = text[seg.start..seg.end];
                    const x0 = self.measurePrefix(seg_text, lo - seg.start);
                    const x1 = self.measurePrefix(seg_text, hi - seg.start);
                    try output.append(allocator, .{
                        .display_line = display_line,
                        .rect = .{ .x = @min(x0, x1), .width = @abs(x1 - x0) },
                    });
                }
            }
            if (display_line == last) break;
            display_line += 1;
        }
    }

    // ===== Text operations =====

    pub fn getText(self: *const TextareaState) []const u8 {
        return self.doc.getText();
    }

    pub fn setAccessibilitySelection(self: *TextareaState, start_utf8: u32, end_utf8: u32) bool {
        self.a11y_scroll_request = null;
        const text = self.doc.getText();
        const start = core_mod.text_coordinates.clampByteOffset(text, .{ .value = @min(@as(usize, start_utf8), text.len) }, .backward).value;
        const end = core_mod.text_coordinates.clampByteOffset(text, .{ .value = @min(@as(usize, end_utf8), text.len) }, .backward).value;
        self.cursor.anchor = if (start == end) null else start;
        self.cursor.offset = end;
        self.cursor.preferred_col = null;
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.resetBlink();
        self.markDirty();
        return true;
    }

    /// External full replace (for value binding): cursor to end, clear selection and undo history,
    /// don't fire on_change. On failure the document is unchanged.
    pub fn setTextChecked(self: *TextareaState, value: []const u8) !void {
        var prepared = try self.doc.prepareReplace(0, self.doc.totalLength(), value);
        defer prepared.deinit();
        prepared.commit();
        self.ime_replacement = null;
        self.supersedeImeComposition();
        self.clearUndoHistory();
        self.wrap_map.rebuildAll(self.doc);
        self.cursor.offset = self.doc.totalLength();
        self.cursor.anchor = null;
        self.cursor.preferred_col = null;
        self.resetBlink();
        self.markDirty();
    }

    /// External write from value binding (binding.zig)
    pub fn applyExternalText(self: *TextareaState, v: []const u8) !void {
        try self.setTextChecked(v);
    }

    pub fn clearUndoHistory(self: *TextareaState) void {
        // History void: clear stash too
        self.undo_stash.discard(&self.redo_stack, self.allocator);
        self.user_edit.pushes = 0;
        var i: u8 = 0;
        while (i < self.undo_count) : (i += 1) self.undo_stack[i].deinit(self.allocator);
        self.undo_count = 0;
        var j: u8 = 0;
        while (j < self.redo_count) : (j += 1) self.redo_stack[j].deinit(self.allocator);
        self.redo_count = 0;
    }

    pub fn setAccessibilityValue(self: *TextareaState, value: []const u8) bool {
        self.a11y_scroll_request = null;
        // AX value write is user edit: value binding can fix in place (see reconcileUserEdit)
        self.beginUserEdit();
        defer self.endUserEdit();
        var prepared = self.doc.prepareReplace(0, self.doc.totalLength(), value) catch return false;
        defer prepared.deinit();
        self.pushUndoChecked() catch return false;
        prepared.commit();
        self.ime_replacement = null;
        self.supersedeImeComposition();
        self.wrap_map.rebuildAll(self.doc);
        self.cursor.offset = self.doc.totalLength();
        self.cursor.anchor = null;
        self.cursor.preferred_col = null;
        self.resetBlink();
        self.markDirty();
        if (self.on_change) |handler| handler.invokeWithStr(self.getText());
        return true;
    }

    pub fn insertText(self: *TextareaState, text: []const u8) void {
        self.insertTextChecked(text) catch return;
    }

    pub fn insertTextChecked(self: *TextareaState, text: []const u8) !void {
        if (text.len == 0 and !self.cursor.hasSelection()) return;
        const old = self.doc.getText();
        const anchor = self.cursor.anchor orelse self.cursor.offset;
        const start = text_coordinates.clampByteOffset(old, .{ .value = @min(anchor, self.cursor.offset) }, .backward).value;
        const end = if (anchor == self.cursor.offset) start else text_coordinates.clampByteOffset(old, .{ .value = @max(anchor, self.cursor.offset) }, .forward).value;
        var prepared = try self.doc.prepareReplace(start, end, text);
        defer prepared.deinit();
        try self.pushUndoChecked();
        const old_lc = self.doc.lineCount();
        const first_line = self.doc.offsetToLineCol(start).line;
        prepared.commit();
        self.cursor.offset = start + text.len;
        self.cursor.anchor = null;
        self.cursor.preferred_col = null;
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.wrap_map.applyEdit(self.doc, first_line, old_lc - first_line, self.doc.lineCount() - first_line);
        _ = self.wrap_map.rewrapInterpolatedAll(self.doc);
        _ = self.wrap_map.takePendingPatch();
        self.markDirty();
        self.resetBlink();
    }

    pub fn deleteBackward(self: *TextareaState) void {
        if (self.cursor.hasSelection()) {
            self.doDeleteSelection();
            return;
        }
        if (self.cursor.offset == 0) return;
        const prev = DocCursor(TextareaDocument).prevCharBoundary(self.doc, self.cursor.offset);
        self.doDeleteRange(prev, self.cursor.offset);
    }

    pub fn deleteForward(self: *TextareaState) void {
        if (self.cursor.hasSelection()) {
            self.doDeleteSelection();
            return;
        }
        if (self.cursor.offset >= self.doc.totalLength()) return;
        const next = DocCursor(TextareaDocument).nextCharBoundary(self.doc, self.cursor.offset);
        self.doDeleteRange(self.cursor.offset, next);
    }

    pub fn deleteWordBackward(self: *TextareaState) void {
        if (self.cursor.hasSelection()) {
            self.doDeleteSelection();
            return;
        }
        if (self.cursor.offset == 0) return;
        const word_start = DocCursor(TextareaDocument).prevWordBoundary(self.doc, self.cursor.offset);
        self.doDeleteRange(word_start, self.cursor.offset);
    }

    pub fn deleteWordForward(self: *TextareaState) void {
        if (self.cursor.hasSelection()) {
            self.doDeleteSelection();
            return;
        }
        if (self.cursor.offset >= self.doc.totalLength()) return;
        const word_end = DocCursor(TextareaDocument).nextWordBoundary(self.doc, self.cursor.offset);
        self.doDeleteRange(self.cursor.offset, word_end);
    }

    pub fn deleteToLineStart(self: *TextareaState) void {
        if (self.cursor.hasSelection()) {
            self.doDeleteSelection();
            return;
        }
        const lc = self.doc.offsetToLineCol(self.cursor.offset);
        const line_start = self.doc.getLineStart(lc.line);
        if (line_start < self.cursor.offset) {
            self.doDeleteRange(line_start, self.cursor.offset);
        }
    }

    fn doDeleteSelection(self: *TextareaState) void {
        const sel = self.cursor.selection() orelse return;
        self.doDeleteRange(sel.start, sel.end);
    }

    fn doDeleteRange(self: *TextareaState, start: usize, end: usize) void {
        if (start >= end) return;
        self.pushUndoChecked() catch return;
        const old_lc = self.doc.lineCount();
        const lc_before = self.doc.offsetToLineCol(start);
        self.doc.deleteRange(start, end - start) catch return;
        self.cursor.offset = start;
        self.cursor.anchor = null;
        self.cursor.preferred_col = null;
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        const new_lc = self.doc.lineCount();
        self.wrap_map.applyEdit(self.doc, lc_before.line, old_lc - lc_before.line, new_lc - lc_before.line);
        _ = self.wrap_map.rewrapInterpolatedAll(self.doc);
        _ = self.wrap_map.takePendingPatch();
        self.markDirty();
        self.resetBlink();
    }

    // ===== Cursor / selection =====

    pub fn moveCursorLeft(self: *TextareaState, shift: bool) void {
        self.moveCursorVisual(-1, shift);
    }

    pub fn moveCursorRight(self: *TextareaState, shift: bool) void {
        self.moveCursorVisual(1, shift);
    }

    fn moveCursorVisual(self: *TextareaState, delta: i32, shift: bool) void {
        if (delta == 0) return;
        if (!shift) {
            if (self.cursor.selection()) |selection| {
                self.cursor.moveTo(if (delta < 0) selection.start else selection.end);
                self.cursor_affinity = .downstream;
                self.preferred_visual_x = null;
                self.resetBlink();
                self.markDirty();
                return;
            }
        }
        if (shift and self.cursor.anchor == null) self.cursor.anchor = self.cursor.offset;

        self.preferred_visual_x = null;
        if (self.visualLineAtOffset(self.cursor.offset)) |geometry| {
            if (geometry.visualNeighbour(self.cursor.offset, self.cursor_affinity, delta)) |target| {
                self.cursor.offset = geometry.start + target.byte.value;
                self.cursor_affinity = target.affinity;
                self.cursor.preferred_col = null;
                self.resetBlink();
                self.markDirty();
                return;
            }

            // Continue in physical row-major order at a soft/hard line edge.
            // This keeps horizontal movement visual even when the edge's
            // logical byte is not the logical start/end of an RTL line.
            const line_delta: i64 = if (delta < 0) -1 else 1;
            const target_line_i = @as(i64, geometry.display_line) + line_delta;
            if (target_line_i >= 0 and target_line_i < @as(i64, self.wrap_map.total_display_lines)) {
                const target_dl: u32 = @intCast(target_line_i);
                const target_seg = safeSegRange(self.doc, self.wrap_map.displayLineInfo(target_dl, self.doc));
                if (self.visualLineForSegment(target_seg.start, target_seg.end, target_dl)) |next_line| {
                    const target = if (delta < 0)
                        next_line.line.caret_stops[next_line.line.caret_stops.len - 1].position
                    else
                        next_line.line.caret_stops[0].position;
                    self.cursor.offset = target_seg.start + target.byte.value;
                    self.cursor_affinity = target.affinity;
                    self.cursor.preferred_col = null;
                    self.resetBlink();
                    self.markDirty();
                    return;
                }
            }

            // We had authoritative geometry and reached the document's
            // physical edge. Do not fall back to logical movement and jump
            // back into the same bidi line.
            self.resetBlink();
            self.markDirty();
            return;
        }

        // Geometry is unavailable only in headless/provider-error paths.
        if (delta < 0) self.cursor.moveLeft(self.doc, shift) else self.cursor.moveRight(self.doc, shift);
        self.cursor_affinity = .downstream;
        self.resetBlink();
        self.markDirty();
    }

    pub fn moveCursorUp(self: *TextareaState, shift: bool) void {
        self.moveVerticalVisual(-1, shift);
    }

    pub fn moveCursorDown(self: *TextareaState, shift: bool) void {
        self.moveVerticalVisual(1, shift);
    }

    pub fn moveWordLeft(self: *TextareaState, shift: bool) void {
        self.cursor.moveWordLeft(self.doc, shift);
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.resetBlink();
        self.markDirty();
    }

    pub fn moveWordRight(self: *TextareaState, shift: bool) void {
        self.cursor.moveWordRight(self.doc, shift);
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.resetBlink();
        self.markDirty();
    }

    pub fn moveToLineStart(self: *TextareaState, shift: bool) void {
        // Move to display line start (wrap segment), not buffer line start
        const dp = self.cursorDisplayPoint();
        const info = self.wrap_map.displayLineInfo(dp.display_line, self.doc);
        const seg = safeSegRange(self.doc, info);
        const target = seg.start;
        if (shift) self.cursor.selectTo(target) else self.cursor.moveTo(target);
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.resetBlink();
        self.markDirty();
    }

    pub fn moveToLineEnd(self: *TextareaState, shift: bool) void {
        // Move to display line end (wrap segment), not buffer line end
        const dp = self.cursorDisplayPoint();
        const info = self.wrap_map.displayLineInfo(dp.display_line, self.doc);
        const seg = safeSegRange(self.doc, info);
        const target = seg.end;
        if (shift) self.cursor.selectTo(target) else self.cursor.moveTo(target);
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.resetBlink();
        self.markDirty();
    }

    pub fn moveToDocStart(self: *TextareaState, shift: bool) void {
        if (shift) self.cursor.selectTo(0) else self.cursor.moveTo(0);
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.resetBlink();
        self.markDirty();
    }

    pub fn moveToDocEnd(self: *TextareaState, shift: bool) void {
        const end = self.doc.totalLength();
        if (shift) self.cursor.selectTo(end) else self.cursor.moveTo(end);
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.resetBlink();
        self.markDirty();
    }

    pub fn selectAll(self: *TextareaState) void {
        self.cursor.selectAll(self.doc);
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.resetBlink();
        self.markDirty();
    }

    pub fn selectWordAt(self: *TextareaState, offset: usize) void {
        const bounds = DocCursor(TextareaDocument).wordBoundsAt(self.doc, offset);
        self.cursor.anchor = bounds.start;
        self.cursor.offset = bounds.end;
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.resetBlink();
        self.markDirty();
    }

    pub fn getSelectedText(self: *const TextareaState) ?[]const u8 {
        const sel = self.cursor.selection() orelse return null;
        const txt = self.doc.getText();
        return txt[@min(sel.start, txt.len)..@min(sel.end, txt.len)];
    }

    /// Move by display line (combine WrapMap)
    fn moveVerticalVisual(self: *TextareaState, direction: i2, shift: bool) void {
        if (shift and self.cursor.anchor == null) {
            self.cursor.anchor = self.cursor.offset;
        } else if (!shift) {
            self.cursor.anchor = null;
        }

        const current = self.visualLineAtOffset(self.cursor.offset);
        const current_dl = if (current) |geometry| geometry.display_line else blk: {
            const lc = self.doc.offsetToLineCol(self.cursor.offset);
            break :blk self.wrap_map.bufferToDisplay(lc.line, lc.col).display_line;
        };
        const target_dl_i: i32 = @as(i32, @intCast(current_dl)) + @as(i32, direction);
        const target_x = self.preferred_visual_x orelse if (current) |geometry|
            geometry.caretX(self.cursor.offset, self.cursor_affinity)
        else
            0;
        self.preferred_visual_x = target_x;

        if (target_dl_i < 0) {
            self.cursor.offset = 0;
            self.cursor_affinity = .downstream;
        } else {
            const target_dl: u32 = @intCast(target_dl_i);
            if (target_dl >= self.wrap_map.total_display_lines) {
                self.cursor.offset = self.doc.totalLength();
                self.cursor_affinity = .downstream;
            } else {
                const info = self.wrap_map.displayLineInfo(target_dl, self.doc);
                const seg = safeSegRange(self.doc, info);
                if (self.visualLineForSegment(seg.start, seg.end, target_dl)) |target| {
                    const position = target.line.xToPosition(.{ .value = target_x });
                    self.cursor.offset = seg.start + position.byte.value;
                    self.cursor_affinity = position.affinity;
                } else {
                    const full_txt = self.doc.getText();
                    const seg_text = full_txt[seg.start..seg.end];
                    self.cursor.offset = seg.start + self.hitTestInSegmentFallback(seg_text, target_x);
                    self.cursor_affinity = .downstream;
                }
            }
        }
        self.cursor.preferred_col = null;
        self.resetBlink();
        self.markDirty();
    }

    // ===== Undo/Redo =====

    pub fn deinit(self: *TextareaState) void {
        self.ime_preedit.deinit();
        self.ime_pending_commit.deinit();
        var i: u8 = 0;
        while (i < self.undo_count) : (i += 1) {
            self.undo_stack[i].deinit(self.allocator);
        }
        self.undo_count = 0;

        var j: u8 = 0;
        while (j < self.redo_count) : (j += 1) {
            self.redo_stack[j].deinit(self.allocator);
        }
        self.redo_count = 0;
        self.undo_stash.discard(&self.redo_stack, self.allocator);
        self.ime_render_buffer.deinit(self.allocator);
        self.extra_sel_nodes.deinit(self.allocator);
        self.extra_preedit_nodes.deinit(self.allocator);
    }

    fn pushUndoChecked(self: *TextareaState) !void {
        const txt = try self.allocator.dupe(u8, self.doc.getText());
        const entry = UndoEntry{ .text = txt, .cursor_offset = self.cursor.offset, .anchor = self.cursor.anchor };
        const in_txn = self.user_edit.depth > 0;
        if (self.undo_count < 32) {
            self.undo_stack[self.undo_count] = entry;
            self.undo_count += 1;
        } else {
            // Evicted entries in txn stashed first; put back if edit rejected
            if (!(in_txn and self.undo_stash.keepEvicted(self.undo_stack[0]))) self.undo_stack[0].deinit(self.allocator);
            var i: usize = 0;
            while (i < 31) : (i += 1) self.undo_stack[i] = self.undo_stack[i + 1];
            self.undo_stack[31] = entry;
        }
        if (!(in_txn and self.undo_stash.detachRedo(&self.redo_count))) {
            var j: u8 = 0;
            while (j < self.redo_count) : (j += 1) self.redo_stack[j].deinit(self.allocator);
            self.redo_count = 0;
        }
        if (in_txn) self.user_edit.pushes +|= 1;
    }

    pub fn undo(self: *TextareaState) void {
        if (self.ime_replacement != null) {
            self.cancelImeComposition();
            return;
        }
        self.restoreHistory(false) catch return;
        if (self.user_edit.depth > 0) self.user_edit.history_op = .undo;
    }

    pub fn redo(self: *TextareaState) void {
        if (self.ime_replacement != null) {
            self.cancelImeComposition();
            return;
        }
        self.restoreHistory(true) catch return;
        if (self.user_edit.depth > 0) self.user_edit.history_op = .redo;
    }

    // ===== User edit txn (value binding reconcile in place, binding.zig;
    // semantics see TextInputState.reconcileUserEdit) =====

    pub fn beginUserEdit(self: *TextareaState) void {
        if (self.user_edit.depth == 0) {
            const replacement = self.ime_replacement;
            self.user_edit = .{
                .cursor = if (replacement) |r| r.cursor else self.cursor.offset,
                .anchor = if (replacement) |r| r.anchor else self.cursor.anchor,
            };
        }
        self.user_edit.depth += 1;
    }

    /// Edit done: stash cleared, checkpoint rebuilt from current state (see
    /// TextInputState.settleUserEdit)
    pub fn settleUserEdit(self: *TextareaState) void {
        if (self.user_edit.depth == 0) return;
        self.undo_stash.discard(&self.redo_stack, self.allocator);
        self.user_edit = .{ .depth = self.user_edit.depth, .cursor = self.cursor.offset, .anchor = self.cursor.anchor };
    }

    pub fn endUserEdit(self: *TextareaState) void {
        std.debug.assert(self.user_edit.depth > 0);
        self.user_edit.depth -= 1;
        // Txn ends, edit not rejected: stash freed per original logic
        if (self.user_edit.depth == 0) self.undo_stash.discard(&self.redo_stack, self.allocator);
    }

    /// Reject: doc back to `landed`, selection to pre-edit, undo/redo stacks restored entry by
    /// entry (a rejected undo/redo is reversed). Rewrite: doc becomes `landed`, cursor mapped by
    /// edit_reconcile.zig, joined to this edit's undo unit. Outside a txn degrades to an external
    /// write. On failure the doc is unchanged.
    pub fn reconcileUserEdit(self: *TextareaState, landed: []const u8, rejected: bool) !void {
        if (self.user_edit.depth == 0) return self.applyExternalText(landed);
        const txn = self.user_edit;
        var cursor: usize = undefined;
        var anchor: ?usize = undefined;
        if (rejected) {
            switch (txn.history_op) {
                .undo => self.redo(),
                .redo => self.undo(),
                .none => {},
            }
            cursor = txn.cursor;
            anchor = txn.anchor;
        } else {
            const rewrite = edit_reconcile.Rewrite.diff(self.doc.getText(), landed);
            cursor = rewrite.mapOffset(landed, self.cursor.offset);
            anchor = if (self.cursor.anchor) |a| rewrite.mapOffset(landed, a) else null;
        }
        try self.replaceTextKeepingHistory(landed);
        if (rejected and txn.history_op == .none) {
            // Undo/redo stack entries restored to pre-edit (pop snapshot, put back evicted + redo)
            self.undo_stash.restore(&self.undo_stack, &self.undo_count, &self.redo_stack, &self.redo_count, self.user_edit.pushes, self.allocator);
            self.user_edit.pushes = 0;
        }
        const text = self.doc.getText();
        self.cursor.offset = edit_reconcile.clampOffset(text, cursor);
        self.cursor.anchor = if (anchor) |a| edit_reconcile.clampOffset(text, a) else null;
        if (self.cursor.anchor == self.cursor.offset) self.cursor.anchor = null;
        self.cursor.preferred_col = null;
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.markDirty();
        self.resetBlink();
    }

    /// Change doc to `text`, replacing only the single changed region; no undo snapshot, cursor
    /// untouched. On failure the doc is unchanged.
    fn replaceTextKeepingHistory(self: *TextareaState, text: []const u8) !void {
        const old = self.doc.getText();
        if (std.mem.eql(u8, old, text)) return;
        const rewrite = edit_reconcile.Rewrite.diff(old, text);
        var prepared = try self.doc.prepareReplace(rewrite.prefix, rewrite.old_end, text[rewrite.prefix..rewrite.new_end]);
        defer prepared.deinit();
        const old_lc = self.doc.lineCount();
        const first_line = self.doc.offsetToLineCol(rewrite.prefix).line;
        prepared.commit();
        self.wrap_map.applyEdit(self.doc, first_line, old_lc - first_line, self.doc.lineCount() - first_line);
        _ = self.wrap_map.rewrapInterpolatedAll(self.doc);
        _ = self.wrap_map.takePendingPatch();
    }

    fn restoreHistory(self: *TextareaState, redo_direction: bool) !void {
        // Redo slot may reuse: truly free entries detached in txn
        self.undo_stash.settleRedo(&self.redo_stack, self.allocator);
        const source = if (redo_direction) &self.redo_stack else &self.undo_stack;
        const source_count = if (redo_direction) &self.redo_count else &self.undo_count;
        const target = if (redo_direction) &self.undo_stack else &self.redo_stack;
        const target_count = if (redo_direction) &self.undo_count else &self.redo_count;
        if (source_count.* == 0) return;
        const snapshot = &source[source_count.* - 1];
        var prepared = try self.doc.prepareReplace(0, self.doc.totalLength(), snapshot.text orelse "");
        defer prepared.deinit();
        const current_text = try self.allocator.dupe(u8, self.doc.getText());
        const current: UndoEntry = .{ .text = current_text, .cursor_offset = self.cursor.offset, .anchor = self.cursor.anchor };
        if (target_count.* == target.len) {
            target[0].deinit(self.allocator);
            for (0..target.len - 1) |i| target[i] = target[i + 1];
            target_count.* -= 1;
        }
        target[target_count.*] = current;
        target_count.* += 1;
        prepared.commit();
        self.cursor.offset = @min(snapshot.cursor_offset, self.doc.totalLength());
        self.cursor.anchor = if (snapshot.anchor) |anchor| @min(anchor, self.doc.totalLength()) else null;
        self.cursor.preferred_col = null;
        snapshot.deinit(self.allocator);
        source_count.* -= 1;
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.wrap_map.rebuildAll(self.doc);
        self.markDirty();
        self.resetBlink();
    }

    // ===== Keyboard =====

    pub fn handleKeyDown(self: *TextareaState, key: KeyCode, modifiers: Modifiers) bool {
        switch (key) {
            .home => {
                if (modifiers.ctrl) self.moveToDocStart(modifiers.shift) else self.moveToLineStart(modifiers.shift);
                return true;
            },
            .end => {
                if (modifiers.ctrl) self.moveToDocEnd(modifiers.shift) else self.moveToLineEnd(modifiers.shift);
                return true;
            },
            .left => {
                if (modifiers.super) self.moveToLineStart(modifiers.shift) else if (modifiers.alt or ((@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .linux) and modifiers.ctrl)) self.moveWordLeft(modifiers.shift) else self.moveCursorLeft(modifiers.shift);
                return true;
            },
            .right => {
                if (modifiers.super) self.moveToLineEnd(modifiers.shift) else if (modifiers.alt or ((@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .linux) and modifiers.ctrl)) self.moveWordRight(modifiers.shift) else self.moveCursorRight(modifiers.shift);
                return true;
            },
            .up => {
                if (modifiers.super) self.moveToDocStart(modifiers.shift) else self.moveCursorUp(modifiers.shift);
                return true;
            },
            .down => {
                if (modifiers.super) self.moveToDocEnd(modifiers.shift) else self.moveCursorDown(modifiers.shift);
                return true;
            },
            .delete => {
                if (modifiers.super) self.deleteToLineStart() else if (modifiers.alt or ((@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .linux) and modifiers.ctrl)) self.deleteWordBackward() else self.deleteBackward();
                return true;
            },
            .forward_delete => {
                if (modifiers.alt or ((@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .linux) and modifiers.ctrl)) self.deleteWordForward() else self.deleteForward();
                return true;
            },
            .z => {
                if (events_mod.primaryModifier(modifiers)) {
                    if (modifiers.shift) self.redo() else self.undo();
                    return true;
                }
                return false;
            },
            .y => {
                if ((@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .linux) and modifiers.ctrl) {
                    self.redo();
                    return true;
                }
                return false;
            },
            .a => {
                if (modifiers.super or modifiers.ctrl) {
                    self.selectAll();
                    return true;
                }
                return false;
            },
            .escape => {
                self.cursor.clearSelection();
                self.markDirty();
                return true;
            },
            else => return false,
        }
    }

    // ===== Mouse =====

    pub fn handleMouseDown(self: *TextareaState, x: f32, y: f32, modifiers: Modifiers) void {
        self.drag_pointer = null;
        if (self.imeIsComposing()) self.cancelImeComposition();
        const pos = self.hitTestAt(x, y);
        self.focused = true;

        const click_count = self.registerMouseDownClickCount(x, y);
        if (click_count >= 3) {
            self.selectAll();
            self.suspend_drag_until_mouse_up = true;
            self.is_dragging = false;
            return;
        }
        if (click_count == 2 and !modifiers.shift) {
            self.selectWordAt(pos);
            self.suspend_drag_until_mouse_up = true;
            self.is_dragging = false;
            return;
        }

        self.suspend_drag_until_mouse_up = false;
        if (modifiers.shift) {
            if (self.cursor.anchor == null) self.cursor.anchor = self.cursor.offset;
        } else {
            self.cursor.anchor = pos;
        }
        self.cursor.offset = pos;
        self.is_dragging = true;
        self.resetBlink();
        self.markDirty();
    }

    pub fn handleMouseUp(self: *TextareaState) void {
        self.drag_pointer = null;
        self.is_dragging = false;
        self.suspend_drag_until_mouse_up = false;
    }

    pub fn handleMouseDrag(self: *TextareaState, x: f32, y: f32) void {
        if (self.suspend_drag_until_mouse_up) return;
        self.drag_pointer = .{ .x = x, .y = y, .time_ms = if (self.cx_ref) |cx| cx.frame_time_ms else 0 };
        // Keep selection at the viewport edge; the frame timer advances the
        // scroll offset. Passing the outside y through would jump whole rows.
        const top = self.container_y + self.padding_v;
        const bottom = if (self.input_container_node) |node| self.container_y + node.rectFromWorldOrFallback().h - self.padding_v else y;
        const pos = self.hitTestAt(x, std.math.clamp(y, top, @max(top, bottom - 1)));
        if (pos != self.cursor.offset) {
            self.cursor.offset = pos;
            self.markDirty();
        }
        self.resetBlink();
    }

    pub fn advanceEdgeDrag(self: *TextareaState, time_ms: f64) bool {
        const pointer = if (self.drag_pointer) |*p| p else return false;
        const elapsed = std.math.clamp(time_ms - pointer.time_ms, 0, 100);
        pointer.time_ms = time_ms;
        if (!self.focused or !self.is_dragging or self.suspend_drag_until_mouse_up) return false;
        const vl = self.vl_state orelse return false;
        const node = self.input_container_node orelse return false;
        const top = self.container_y + self.padding_v;
        const bottom = self.container_y + node.rectFromWorldOrFallback().h - self.padding_v;
        const distance = if (pointer.y < top) pointer.y - top else if (pointer.y > bottom) pointer.y - bottom else return false;
        const max_scroll = vl.scroll_state.maxScrollY();
        const scroll = vl.scroll_state.scroll_y;
        if ((distance < 0 and scroll <= 0) or (distance > 0 and scroll >= max_scroll)) return false;
        if (elapsed == 0) return true;
        const speed = 200 + @min(@abs(distance), 200) * 4;
        const step = speed * @as(f32, @floatCast(elapsed / 1000));
        @import("../scroll_area/mod.zig").setScrollY(vl.scroll_state, vl.content_node, scroll + (if (distance < 0) -step else step));
        self.cursor.offset = self.hitTestAt(pointer.x, if (distance < 0) top else @max(top, bottom - 1));
        self.markDirty();
        self.resetBlink();
        return true;
    }

    // ===== Hit test =====

    pub fn hitTestAt(self: *TextareaState, global_x: f32, global_y: f32) usize {
        const target_x = @max(0, global_x - self.container_x - self.padding_h);
        const vl_scroll_y: f32 = if (self.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
        const local_y = @max(0, global_y - self.container_y - self.padding_v + vl_scroll_y);
        const lh = @max(self.line_height, 1.0);
        const target_row: usize = @intFromFloat(@floor(local_y / lh));

        const dl: u32 = @intCast(@min(target_row, if (self.wrap_map.total_display_lines > 0) self.wrap_map.total_display_lines - 1 else 0));
        const info = self.wrap_map.displayLineInfo(dl, self.doc);
        const seg = safeSegRange(self.doc, info);
        self.preferred_visual_x = null;
        if (self.visualLineForSegment(seg.start, seg.end, dl)) |geometry| {
            const position = geometry.line.xToPosition(.{ .value = target_x });
            self.cursor_affinity = position.affinity;
            const byte = seg.start + position.byte.value;
            // Shaping affinity disambiguates bidi caret stops within one row. At a
            // soft-wrap endpoint the same byte also belongs to the adjacent row:
            // preserve the row selected by y before resolving the rendered caret.
            if (byte == seg.end and dl + 1 < self.wrap_map.displayLineCount()) {
                const next = safeSegRange(self.doc, self.wrap_map.displayLineInfo(dl + 1, self.doc));
                if (next.start == byte) self.cursor_affinity = .upstream;
            } else if (byte == seg.start and dl > 0) {
                const previous = safeSegRange(self.doc, self.wrap_map.displayLineInfo(dl - 1, self.doc));
                if (previous.end == byte) self.cursor_affinity = .downstream;
            }
            return byte;
        }
        self.cursor_affinity = .downstream;
        const txt = self.doc.getText();
        return seg.start + self.hitTestInSegmentFallback(txt[seg.start..seg.end], target_x);
    }

    // ===== IME =====

    pub fn hasImePreedit(self: *const TextareaState) bool {
        return self.ime_preedit_len > 0;
    }
    pub fn imeIsComposing(self: *const TextareaState) bool {
        return self.ime_phase == .composing;
    }

    pub fn preeditText(self: *const TextareaState) []const u8 {
        return self.ime_preedit.text();
    }

    pub fn handleImePreedit(self: *TextareaState, text: []const u8, cursor_offset: u32) void {
        self.handleImePreeditChecked(text, cursor_offset) catch return;
    }

    pub fn handleImePreeditChecked(self: *TextareaState, text: []const u8, cursor_offset: u32) !void {
        if (text.len == 0) {
            if (self.ime_phase == .composing) self.cancelImeComposition() else self.clearImePreedit();
            return;
        }
        const candidate = try ImeText.init(self.allocator, text);
        self.publishImePreedit(candidate, cursor_offset);
    }

    fn publishImePreedit(self: *TextareaState, candidate: ImeText, cursor_offset: u32) void {
        self.ime_preedit.deinit();
        self.ime_preedit = candidate;
        self.ime_preedit_len = candidate.len;
        self.ime_cursor_visible = true;
        self.ime_selection_end = null;
        self.ime_cursor_utf8_offset = text_coordinates.clampByteOffset(self.preeditText(), .{ .value = cursor_offset }, .forward).value;
        if (self.cursor.anchor == self.cursor.offset) self.cursor.anchor = null;
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.ime_phase = .composing;
        self.ime_pending_commit.deinit();
        self.markDirty();
        self.resetBlink();
    }

    fn applyImeReplacementRange(self: *TextareaState, start_raw: u32, end_raw: u32) bool {
        if (start_raw == events_mod.ime_no_replacement or end_raw == events_mod.ime_no_replacement or start_raw > end_raw or end_raw > self.doc.totalLength()) return false;
        const text = self.getText();
        const start = text_coordinates.clampByteOffset(text, .{ .value = start_raw }, .backward).value;
        const end = if (start_raw == end_raw) start else text_coordinates.clampByteOffset(text, .{ .value = end_raw }, .forward).value;
        self.cursor.offset = start;
        self.cursor.anchor = if (start == end) null else end;
        return true;
    }

    pub fn handleImePreeditReplace(self: *TextareaState, text: []const u8, cursor_offset: u32, start_raw: u32, end_raw: u32) void {
        self.handleImePreeditReplaceChecked(text, cursor_offset, start_raw, end_raw) catch return;
    }

    pub fn handleImePreeditReplaceChecked(self: *TextareaState, text: []const u8, cursor_offset: u32, start_raw: u32, end_raw: u32) !void {
        if (text.len == 0) {
            try self.handleImePreeditChecked(text, cursor_offset);
            return;
        }
        const candidate = try ImeText.init(self.allocator, text);
        if (text.len > 0) {
            const original = self.cursor;
            if (self.applyImeReplacementRange(start_raw, end_raw)) {
                var replacement = self.ime_replacement orelse ImeReplacement{ .start = self.cursor.offset, .end = self.cursor.anchor orelse self.cursor.offset, .cursor = original.offset, .anchor = original.anchor };
                replacement.start = self.cursor.offset;
                replacement.end = self.cursor.anchor orelse self.cursor.offset;
                self.ime_replacement = replacement;
            }
        }
        self.publishImePreedit(candidate, cursor_offset);
    }

    pub fn handleImeCommitReplaceChecked(self: *TextareaState, text: []const u8, start_raw: u32, end_raw: u32) !void {
        const original = self.cursor;
        errdefer self.cursor = original;
        const applied = self.applyImeReplacementRange(start_raw, end_raw);
        if (applied and text.len == 0) try self.insertTextChecked("");
        try self.handleImeCommitChecked(text);
    }

    pub fn handleImeCommit(self: *TextareaState, text: []const u8) void {
        self.handleImeCommitChecked(text) catch return;
    }

    pub fn handleImeCommitChecked(self: *TextareaState, text: []const u8) !void {
        var candidate = try ImeText.init(self.allocator, text);
        defer candidate.deinit();
        if (text.len > 0 or self.ime_replacement != null) try self.insertTextChecked(candidate.text());
        self.clearImePreedit();
        self.ime_pending_commit.deinit();
        self.ime_pending_commit = candidate;
        candidate = .{};
        self.ime_phase = if (text.len > 0) .commit_pending_end else .idle;
        self.ime_selection_highlight = false;
    }

    pub fn handleImeFallbackTextInput(self: *TextareaState, text: []const u8) void {
        self.handleImeCommit(text);
    }

    pub fn endImePendingCommit(self: *TextareaState) void {
        self.ime_pending_commit.deinit();
        if (self.ime_phase == .commit_pending_end) self.ime_phase = .idle;
    }

    pub fn consumeImePostCommitDuplicate(self: *TextareaState, text: []const u8) bool {
        if (self.ime_phase != .commit_pending_end) return false;
        const duplicate = text.len > 0 and std.mem.eql(u8, self.ime_pending_commit.text(), text);
        self.endImePendingCommit();
        self.ime_selection_highlight = false;
        return duplicate;
    }

    /// Composition abandoned: notify value binding to apply deferred external writes
    pub fn cancelImeComposition(self: *TextareaState) void {
        self.endImeComposition(true);
    }

    /// Composition superseded by single full write (external full replace / AX write): end
    /// composition
    /// without on_ime_cancelled, else deferred value overwrites just-written content (semantics
    /// same
    /// as TextInputState.supersedeImeComposition)
    fn supersedeImeComposition(self: *TextareaState) void {
        self.endImeComposition(false);
    }

    fn endImeComposition(self: *TextareaState, notify: bool) void {
        const was_composing = self.ime_phase == .composing;
        defer if (was_composing and notify) {
            if (self.on_ime_cancelled) |h| h.invoke();
        };
        if (self.ime_replacement) |replacement| {
            self.cursor.offset = @min(replacement.cursor, self.doc.totalLength());
            self.cursor.anchor = if (replacement.anchor) |anchor| @min(anchor, self.doc.totalLength()) else null;
        }
        self.clearImePreedit();
        self.ime_phase = .idle;
        self.ime_pending_commit.deinit();
        self.ime_selection_highlight = false;
    }

    pub fn markImeSelectionHighlight(self: *TextareaState) void {
        if (self.imeIsComposing()) {
            self.ime_selection_highlight = true;
            self.markDirty();
        }
    }

    pub fn setImeAttributes(self: *TextareaState, visible: bool, end: ?u32) void {
        self.ime_cursor_visible = visible;
        self.ime_selection_end = if (end) |value| text_coordinates.clampByteOffset(self.preeditText(), .{ .value = value }, .forward).value else null;
    }
    pub fn handleImeDeleteSurrounding(self: *TextareaState, before: u32, after: u32) !void {
        const caret = self.cursor.offset;
        const anchor = self.cursor.anchor;
        const range = @import("../../core/text_input_protocol.zig").deletion(self.getText(), caret, anchor orelse caret, before, after) orelse return;
        var selected = try ImeText.init(self.allocator, self.getText()[range.selection_start..range.selection_end]);
        defer selected.deinit();
        try self.handleImeCommitReplaceChecked(selected.text(), @intCast(range.start), @intCast(range.end));
        self.cursor.offset = caret - before;
        self.cursor.anchor = if (anchor) |value| value - before else null;
    }

    fn effectiveImeCursorOffset(self: *const TextareaState) usize {
        if (self.ime_selection_end != null) return self.ime_cursor_utf8_offset;
        return editable_block.effectiveImeCursorOffset(self.ime_preedit_len, self.ime_cursor_utf8_offset, self.ime_selection_highlight);
    }

    fn clearImePreedit(self: *TextareaState) void {
        self.ime_cursor_visible = true;
        self.ime_selection_end = null;
        self.ime_preedit.deinit();
        self.ime_replacement = null;
        if (self.ime_preedit_len > 0) {
            self.ime_preedit_len = 0;
            self.ime_cursor_utf8_offset = 0;
            self.markDirty();
            self.resetBlink();
        } else {
            self.ime_preedit_len = 0;
            self.ime_cursor_utf8_offset = 0;
        }
    }

    fn imeInsertOffsetForSegment(self: *const TextareaState, buffer_line: usize, seg_start: usize, seg_end: usize) ?usize {
        if (!self.hasImePreedit()) return null;
        const cursor = self.cursor.offset;
        if (cursor < seg_start) return null;
        if (cursor < seg_end) return cursor - seg_start;
        if (cursor == seg_end) {
            const line_end = self.doc.getLineEnd(buffer_line);
            if (cursor == line_end) return seg_end - seg_start;
        }
        return null;
    }

    fn composeSegmentWithIme(self: *TextareaState, seg_text: []const u8, insert_offset: usize) []const u8 {
        return self.composeSegmentWithImeChecked(seg_text, insert_offset) catch seg_text;
    }

    fn composeSegmentWithImeChecked(self: *TextareaState, seg_text: []const u8, insert_offset: usize) ![]const u8 {
        const required = std.math.add(usize, seg_text.len, self.ime_preedit_len) catch return error.OutOfMemory;
        try self.ime_render_buffer.ensureTotalCapacity(self.allocator, required);
        self.ime_render_buffer.items.len = required;
        if (self.ime_replacement) |replacement| return replacement.compose(seg_text, self.cursor.offset -| insert_offset, self.preeditText(), true, self.ime_render_buffer.items);
        return editable_block.composePreeditIntoBuffer(seg_text, insert_offset, self.preeditText(), self.ime_render_buffer.items);
    }

    const ImeVisualGeometry = struct {
        line: text_coordinates.VisualLine,
        insert_offset: usize,
    };

    fn imeVisualGeometry(self: *TextareaState, geometry: VisualSegment) ?ImeVisualGeometry {
        if (!self.hasImePreedit()) return null;
        const info = self.wrap_map.displayLineInfo(geometry.display_line, self.doc);
        const insert = self.imeInsertOffsetForSegment(info.buffer_line, geometry.start, geometry.end) orelse return null;
        const text = self.doc.getText();
        const composed = self.composeSegmentWithImeChecked(text[geometry.start..geometry.end], insert) catch return null;
        // OOM in the dynamic composition path returns the unmodified segment;
        // never fabricate preedit offsets outside that source.
        const removed = if (self.ime_replacement) |replacement| replacement.removedInSegment(geometry.start, geometry.end - geometry.start) else 0;
        if (composed.len < geometry.end - geometry.start - removed + self.ime_preedit_len) return null;
        const cx = self.cx_ref orelse return null;
        const line = cx.text.visualLine(.{
            .text = composed,
            .font_family = "system",
            .font_size = self.font_size,
            .font_weight = self.font_weight,
        }) catch return null;
        return .{ .line = line, .insert_offset = insert };
    }

    // ===== Blink =====

    pub fn resetBlink(self: *TextareaState) void {
        self.blink.reset(self.io);
        self.last_blink_visible = true;
    }

    pub fn blinkVisible(self: *TextareaState, now: @import("zenit_time").Instant) bool {
        return self.blink.visible(now);
    }

    fn nextBlinkDelayNs(self: *const TextareaState, now: @import("zenit_time").Instant) u64 {
        return self.blink.nextDelayNs(now);
    }

    // ===== Helpers =====

    fn markDirty(self: *TextareaState) void {
        self.dirty = true;
        // cx.render() zero-dirty fast-path skips textareaBeforeRender -> state.dirty never read +
        // VirtualList doesn't refresh -> visual text unchanged (same as password bug before).
        // Mark container layout dirty to fail fast-path.
        if (self.input_container_node) |n| n.markLayoutDirty();
        if (self.cursor_node) |n| n.markRenderDirty();
        if (self.selection_node) |n| n.markRenderDirty();
        if (self.preedit_underline_node) |n| n.markRenderDirty();
    }

    fn cursorDisplayPoint(self: *const TextareaState) DisplayPoint {
        const lc = self.doc.offsetToLineCol(self.cursor.offset);
        return self.wrap_map.bufferToDisplay(lc.line, lc.col);
    }

    /// Compute text width with real measure function (pixel)
    fn measureSlice(self: *const TextareaState, text: []const u8) f32 {
        if (text.len == 0) return 0;
        if (self.cx_ref) |cx| {
            return cx.text.measureTextWidth(text, self.font_size, self.font_weight, false);
        }
        if (self.measure_fn) |mfn| return mfn(text.ptr, text.len, self.font_size, self.font_weight, false);
        return text_layout.measureTextWidthByFontKind(text, self.font_size, self.font_weight, false, false);
    }

    /// Measure text[0..byte_end] width
    fn measurePrefix(self: *const TextareaState, text: []const u8, byte_end: usize) f32 {
        return self.measureSlice(text[0..@min(byte_end, text.len)]);
    }

    /// Provider-error fallback. It has no fixed boundary buffer and still
    /// returns only extended-grapheme boundaries.
    fn hitTestInSegmentFallback(self: *const TextareaState, text: []const u8, target_x: f32) usize {
        return text_utils.utf8ByteOffsetForMeasuredXCx(null, text, target_x, self.char_width, self.font_size, self.font_weight);
    }

    fn registerMouseDownClickCount(self: *TextareaState, x: f32, y: f32) u8 {
        const dx = x - self.last_mouse_down_pos[0];
        const dy = y - self.last_mouse_down_pos[1];
        const dist_sq = dx * dx + dy * dy;
        var is_multi = false;
        const now_i = @import("zenit_time").Instant.now(self.io) catch null;
        if (now_i) |now| {
            if (self.last_mouse_down_instant) |last| {
                is_multi = text_utils.safeElapsedNs(now, last) < events_mod.multi_click_interval_ns and dist_sq < events_mod.multi_click_slop_sq;
            }
            self.last_mouse_down_instant = now;
        } else self.last_mouse_down_instant = null;
        self.last_mouse_down_pos = .{ x, y };
        if (is_multi) self.consecutive_mouse_downs +|= 1 else self.consecutive_mouse_downs = 1;
        return self.consecutive_mouse_downs;
    }
};

// ============================================================================
// Helper functions
// ============================================================================

fn safeSegRange(doc: *const TextareaDocument, info: DisplayLineInfo) struct { start: usize, end: usize } {
    const ls = doc.getLineStart(info.buffer_line);
    const le = doc.getLineEnd(info.buffer_line);
    const seg_start = @min(ls +| info.byte_start, le);
    const seg_end = if (info.byte_end >= std.math.maxInt(usize) / 2) le else @min(ls +| info.byte_end, le);
    return .{ .start = seg_start, .end = seg_end };
}

fn isImeSelectionSpace(text: []const u8) bool {
    return editable_block.isImeSelectionSpace(text);
}

fn fireOnChange(state: *TextareaState) void {
    if (state.on_change) |h| h.invokeWithStr(state.getText());
}

fn sanitizeText(text: []const u8, out: []u8) []const u8 {
    // Filter control chars, preserve \n
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < text.len and out_len < out.len) {
        const b = text[i];
        if (b == '\n') {
            out[out_len] = '\n';
            out_len += 1;
            i += 1;
            continue;
        }
        if (b == '\r') {
            i += 1;
            if (i < text.len and text[i] == '\n') {
                out[out_len] = '\n';
                out_len += 1;
                i += 1;
            }
            continue;
        }
        // ESC sequences before general control filter (ESC=0x1b < 0x20; put after = dead code.
        // Paste "\x1b[31mred" leaves "[31mred"). CSI: ESC '[' params/intermediates terminator.
        if (b == 0x1b) {
            i += 1;
            if (i < text.len and text[i] == '[') {
                i += 1;
                while (i < text.len and text[i] >= 0x20 and text[i] <= 0x3F) : (i += 1) {}
            }
            if (i < text.len) i += 1; // Terminator / single-char escape
            continue;
        }
        if (b < 0x20 and b != '\t') {
            i += 1;
            continue;
        } // Filter control chars
        out[out_len] = b;
        out_len += 1;
        i += 1;
    }
    return out[0..out_len];
}

/// Fixed-height box + own text (label / helper): `ui.view.text` builds fit-size text node;
/// "boxed text" with fixed height written here on mount with style + content copy.
const BoxText = struct {
    style: core_ui.TextStyle,
    content: []const u8,

    fn apply(self: BoxText, node: *Node, _: *Scope, cx: *Cx) !void {
        var props: core_ui.TextProps = .{};
        _ = self.style.applyTo(&props);
        node.setText(props);
        try node.setTextContent(cx.allocator, self.content);
    }
};

test "textarea sanitizeText: 剥离 ANSI ESC 序列而非只删 ESC 字节" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("red", sanitizeText("\x1b[31mred", &out));
    try std.testing.expectEqualStrings("ab\nc", sanitizeText("a\x1b[1;2Hb\x1b[0m\r\nc", &out));
    try std.testing.expectEqualStrings("xy", sanitizeText("x\x1bMy", &out));
    try std.testing.expectEqualStrings("x", sanitizeText("x\x1b", &out));
}

// ============================================================================
// Event handlers
// ============================================================================

/// Each event is one user edit txn (see TextareaState.beginUserEdit / events.zig
/// inputEventHandler)
/// Textarea field (ControlShell root): focus / blur update editing state here, as events, never
/// by replacing the node's on_focus / on_blur (the shell's :focus hooks live there). Blur clears
/// even while disabled (disable revokes focus), then runs as an edit transaction.
pub fn textareaFieldEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *TextareaState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .focus => state.focused = true,
        .blur => {
            state.focused = false;
            state.cancelImeComposition();
            state.cursor.anchor = null;
            state.is_dragging = false;
            state.drag_pointer = null;
            state.suspend_drag_until_mouse_up = false;
            state.consecutive_mouse_downs = 0;
            state.last_mouse_down_instant = null;
        },
        else => {},
    }
    return textareaEventHandler(event, context);
}

pub fn textareaEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *TextareaState = @ptrCast(@alignCast(context orelse return .ignored));
    if (state.disabled) return .ignored;
    state.beginUserEdit();
    defer state.endUserEdit();
    return handleTextareaEvent(state, event);
}

fn handleTextareaEvent(state: *TextareaState, event: Event) EventResult {
    switch (event) {
        .key_down, .mouse_down, .focus, .blur => state.endImePendingCommit(),
        else => {},
    }

    switch (event) {
        .text_input => |e| {
            var input = ImeText.init(state.allocator, e.text) catch return .handled;
            defer input.deinit();
            input.len = sanitizeText(input.text(), input.mutableText()).len;
            const filtered = input.text();
            if (filtered.len == 0) return .handled;

            if (state.imeIsComposing()) {
                if (isImeSelectionSpace(filtered)) {
                    state.markImeSelectionHighlight();
                    return .handled;
                }
                state.handleImeCommitChecked(filtered) catch return .handled;
                fireOnChange(state);
                return .handled;
            }
            if (state.consumeImePostCommitDuplicate(filtered)) return .handled;
            state.insertTextChecked(filtered) catch return .handled;
            fireOnChange(state);
            return .handled;
        },
        .ime_preedit => |e| {
            var input = ImeText.init(state.allocator, e.text) catch return .handled;
            defer input.deinit();
            input.len = sanitizeText(input.text(), input.mutableText()).len;
            const filtered = input.text();
            state.handleImePreeditReplaceChecked(filtered, e.cursor_utf8_offset, e.replace_start_utf8, e.replace_end_utf8) catch return .handled;
            state.setImeAttributes(e.cursor_visible, e.selection_end_utf8);
            return .handled;
        },
        .ime_delete_surrounding => |e| {
            state.handleImeDeleteSurrounding(e.before_bytes, e.after_bytes) catch return .handled;
            fireOnChange(state);
            return .handled;
        },
        .ime_commit => |e| {
            var input = ImeText.init(state.allocator, e.text) catch return .handled;
            defer input.deinit();
            input.len = sanitizeText(input.text(), input.mutableText()).len;
            const filtered = input.text();
            state.handleImeCommitReplaceChecked(filtered, e.replace_start_utf8, e.replace_end_utf8) catch return .handled;
            fireOnChange(state);
            return .handled;
        },
        .key_down => |e| {
            if (state.ime_replacement != null and (e.modifiers.super or e.modifiers.ctrl) and e.key != .z) state.cancelImeComposition();
            // Clipboard
            if (events_mod.primaryModifier(e.modifiers)) {
                if (state.cx_ref) |cx| {
                    if (core_ui.platform_services.clipboardAvailable(cx.system_sdk)) {
                        switch (e.key) {
                            .c => {
                                if (state.getSelectedText()) |sel| {
                                    _ = core_ui.platform_services.clipboardSetText(cx.system_sdk, sel);
                                }
                                return .handled;
                            },
                            .x => {
                                if (state.getSelectedText()) |sel| {
                                    if (core_ui.platform_services.clipboardSetText(cx.system_sdk, sel)) {
                                        const old_len = state.doc.totalLength();
                                        state.doDeleteSelection();
                                        if (state.doc.totalLength() != old_len) fireOnChange(state);
                                    }
                                }
                                return .handled;
                            },
                            .v => {
                                const allocator = state.allocator;
                                // Keep the basic fixed-buffer backend contract when
                                // length queries are not implemented. Native/full
                                // backends read the complete text before filtering.
                                var fallback: [4096]u8 = undefined;
                                var owned: ?[]const u8 = null;
                                defer if (owned) |bytes| allocator.free(bytes);
                                const clip = blk: {
                                    owned = core_ui.platform_services.clipboardGetTextAllocChecked(cx.system_sdk, allocator) catch |err| {
                                        if (err == error.NotSupported) break :blk core_ui.platform_services.clipboardGetText(cx.system_sdk, &fallback) orelse return .handled;
                                        return .handled;
                                    };
                                    break :blk owned orelse return .handled;
                                };
                                const filtered = sanitizeText(clip, @constCast(clip));
                                if (filtered.len > 0) {
                                    state.insertTextChecked(filtered) catch return .handled;
                                    fireOnChange(state);
                                }
                                return .handled;
                            },
                            else => {},
                        }
                    }
                }
            }

            // IME composing
            if (state.imeIsComposing() and !e.modifiers.super and !e.modifiers.ctrl) {
                if (e.key == .escape) state.cancelImeComposition() else if (e.key == .space) state.markImeSelectionHighlight();
                return .handled;
            }

            // Enter
            if (e.key == .@"return" and !e.modifiers.super and !e.modifiers.ctrl) {
                state.insertTextChecked("\n") catch return .handled;
                fireOnChange(state);
                return .handled;
            }

            const len_before = state.doc.totalLength();
            const undo_before = state.undo_count;
            const redo_before = state.redo_count;
            if (state.handleKeyDown(e.key, e.modifiers)) {
                if (state.doc.totalLength() != len_before or state.undo_count != undo_before or state.redo_count != redo_before) fireOnChange(state);
                return .handled;
            }
            return .ignored;
        },
        .mouse_down => |e| {
            state.handleMouseDown(e.x, e.y, .{ .shift = e.modifiers.shift, .alt = e.modifiers.alt, .super = e.modifiers.super, .ctrl = e.modifiers.ctrl });
            return .handled;
        },
        .mouse_up => {
            state.handleMouseUp();
            return .handled;
        },
        .mouse_move => |e| {
            if (state.suspend_drag_until_mouse_up) {
                state.resetBlink();
                return .handled;
            }
            if (state.is_dragging) {
                state.handleMouseDrag(e.x, e.y);
                return .handled;
            }
            return .ignored;
        },
        .click => {
            return .handled;
        },
        .scroll => |scroll| {
            if (state.vl_state) |vl_state| {
                // Priority forward to VirtualList ScrollArea
                if (vl_state.content_node.parent) |sa_container| {
                    if (sa_container.behavior.events.event_context) |ctx| {
                        const r = scroll_area_event.scrollEventHandler(Event{ .scroll = scroll }, ctx);
                        if (r != .ignored) return r;
                    }
                }
                // Fallback: manipulate scroll_state directly
                if (scroll.dy != 0) {
                    const prev_sy = vl_state.scroll_state.scroll_y;
                    const max_sy = vl_state.scroll_state.maxScrollY();
                    vl_state.scroll_state.scroll_y = std.math.clamp(vl_state.scroll_state.scroll_y - scroll.dy, 0, max_sy);
                    if (vl_state.scroll_state.scroll_y == prev_sy) return .ignored;
                    vl_state.content_node.style.translate_y = -vl_state.scroll_state.effectiveScrollY();
                    vl_state.content_node.markHitLayerMotionPropDirty();
                    return .handled;
                }
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

// ============================================================================
// VirtualList renderItem
// ============================================================================

fn textareaRenderItem(item_node: *Node, index: usize, cx: *Cx, user_context: ?*anyopaque) void {
    const state: *TextareaState = @ptrCast(@alignCast(user_context orelse return));
    const dl: u32 = @intCast(index);
    const info = state.wrap_map.displayLineInfo(dl, state.doc);
    const seg = safeSegRange(state.doc, info);
    const txt = state.doc.getText();
    var line_content = if (seg.start <= seg.end and seg.end <= txt.len) txt[seg.start..seg.end] else "";
    if (state.imeInsertOffsetForSegment(info.buffer_line, seg.start, seg.end)) |insert_offset| {
        line_content = state.composeSegmentWithImeChecked(line_content, insert_offset) catch {
            state.dirty = true;
            @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
            return;
        };
    } else if (state.ime_replacement) |replacement| {
        state.ime_render_buffer.resize(state.allocator, line_content.len) catch {
            state.dirty = true;
            @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
            return;
        };
        line_content = replacement.compose(line_content, seg.start, "", false, state.ime_render_buffer.items);
    }
    const has_content = state.doc.totalLength() > 0 or state.hasImePreedit();
    if (!has_content and index == 0) line_content = state.placeholder_text orelse "";

    @import("row_text.zig").set(item_node, cx, line_content, if (state.disabled) state.tokens.tokens.color.fg_disabled else if (has_content) state.tokens.tokens.color.fg_primary else state.tokens.tokens.color.fg_secondary, state.font_size) catch {
        state.dirty = true;
        @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
        return;
    };
}

// ============================================================================
// beforeRender hook
// ============================================================================

fn textareaA11yScroll(context: *anyopaque, start: u32, end: u32, align_top: bool) bool {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    const text = state.getText();
    if (start > end or end > text.len) return false;
    if ((start < text.len and text[start] & 0xc0 == 0x80) or (end < text.len and text[end] & 0xc0 == 0x80)) return false;
    const first = text_coordinates.clampByteOffset(text, .{ .value = start }, .backward).value;
    const last = text_coordinates.clampByteOffset(text, .{ .value = end }, .forward).value;
    state.a11y_scroll_request = .{ .start = @intCast(first), .end = @intCast(last), .align_top = align_top, .text_hash = std.hash.Wyhash.hash(0, text), .caret = state.cursor.offset, .anchor = state.cursor.anchor };
    if (state.input_container_node) |node| node.markRenderDirty();
    return true;
}

fn applyTextareaA11yScroll(state: *TextareaState) void {
    const request = state.a11y_scroll_request orelse return;
    if (state.wrap_map.enabled and (state.wrap_map.needs_rebuild or state.wrap_map.has_interpolated_lines)) return;
    state.a11y_scroll_request = null;
    const text = state.getText();
    if (request.text_hash != std.hash.Wyhash.hash(0, text) or request.caret != state.cursor.offset or request.anchor != state.cursor.anchor) return;
    const list = state.vl_state orelse return;
    const offset = if (request.align_top) request.start else if (request.end > request.start) grapheme.prevBoundary(text, request.end) else request.end;
    const point = state.doc.offsetToLineCol(offset);
    const row = state.wrap_map.bufferToDisplay(point.line, point.col).display_line;
    virtual_list.scrollIndexIntoView(list, row, if (request.align_top) .start else .end);
}

fn textareaA11yLines(context: *anyopaque, allocator: std.mem.Allocator) ![]u32 {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    return @import("textarea_document.zig").displayLineBoundaries(allocator, state.doc, state.wrap_map);
}

fn textareaA11yGeometry(context: *anyopaque, allocator: Allocator) ![]core_ui.A11yProps.TextGeometrySegment {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    if (state.ime_replacement != null or
        (state.wrap_map.enabled and (state.wrap_map.needs_rebuild or state.wrap_map.has_interpolated_lines)))
        return error.AccessibilityLayoutPending;
    var output: std.ArrayListUnmanaged(core_ui.A11yProps.TextGeometrySegment) = .empty;
    errdefer output.deinit(allocator);
    var first: u32 = 0;
    var last: u32 = if (state.wrap_map.enabled) state.wrap_map.displayLineCount() else @intCast(state.doc.lineCount());
    if (state.vl_state) |vl| {
        if (!vl.initialized) return error.AccessibilityLayoutPending;
        first = @intCast(@min(vl.prev_start, last));
        last = @intCast(@min(vl.prev_end, last));
    }
    const scroll_y = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
    var row = first;
    while (row < last) : (row += 1) {
        const span = safeSegRange(state.doc, state.wrap_map.displayLineInfo(row, state.doc));
        if (span.start == span.end) continue;
        const visual = state.visualLineForSegment(span.start, span.end, row) orelse return error.AccessibilityLayoutPending;
        var segments = visual.line.selectionSegments();
        while (segments.next()) |segment| {
            if (segment.rect.width <= 0) continue;
            if (output.items.len == core_ui.A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
            try output.append(allocator, .{
                .start = @intCast(span.start + segment.start.value),
                .end = @intCast(span.start + segment.end.value),
                .rect = .{
                    .x = state.container_x + state.padding_h + segment.rect.x,
                    .y = state.container_y + state.padding_v + @as(f32, @floatFromInt(row)) * state.line_height - scroll_y,
                    .width = segment.rect.width,
                    .height = state.line_height,
                },
            });
        }
    }
    return output.toOwnedSlice(allocator);
}

fn textareaA11yRows(context: *anyopaque, allocator: Allocator) ![]core_ui.A11yProps.TextRowGeometry {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    if (state.ime_replacement != null or state.input_inner_w <= 0 or
        (state.wrap_map.enabled and (state.wrap_map.needs_rebuild or state.wrap_map.has_interpolated_lines))) return error.AccessibilityLayoutPending;
    var output: std.ArrayListUnmanaged(core_ui.A11yProps.TextRowGeometry) = .empty;
    errdefer output.deinit(allocator);
    var first: u32 = 0;
    var last: u32 = if (state.wrap_map.enabled) state.wrap_map.displayLineCount() else @intCast(state.doc.lineCount());
    if (state.vl_state) |vl| {
        if (!vl.initialized) return error.AccessibilityLayoutPending;
        first = @intCast(@min(vl.prev_start, last));
        last = @intCast(@min(vl.prev_end, last));
    }
    const scroll_y = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
    var row = first;
    while (row < last) : (row += 1) {
        if (output.items.len == core_ui.A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
        const span = safeSegRange(state.doc, state.wrap_map.displayLineInfo(row, state.doc));
        const text = state.getText();
        const end = span.end + @as(usize, @intFromBool(span.end < text.len and text[span.end] == '\n'));
        try output.append(allocator, .{ .start = @intCast(span.start), .end = @intCast(end), .rect = .{
            .x = state.container_x + state.padding_h,
            .y = state.container_y + state.padding_v + @as(f32, @floatFromInt(row)) * state.line_height - scroll_y,
            .width = state.input_inner_w,
            .height = state.line_height,
        } });
    }
    return output.toOwnedSlice(allocator);
}

fn textareaA11yCarets(context: *anyopaque, allocator: Allocator) ![]core_ui.A11yProps.TextCaretGeometry {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    if (state.ime_replacement != null or
        (state.wrap_map.enabled and (state.wrap_map.needs_rebuild or state.wrap_map.has_interpolated_lines)))
        return error.AccessibilityLayoutPending;
    var output: std.ArrayListUnmanaged(core_ui.A11yProps.TextCaretGeometry) = .empty;
    errdefer output.deinit(allocator);
    var first: u32 = 0;
    var last: u32 = if (state.wrap_map.enabled) state.wrap_map.displayLineCount() else @intCast(state.doc.lineCount());
    if (state.vl_state) |vl| {
        if (!vl.initialized) return error.AccessibilityLayoutPending;
        first = @intCast(@min(vl.prev_start, last));
        last = @intCast(@min(vl.prev_end, last));
    }
    const scroll_y = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
    var row = first;
    while (row < last) : (row += 1) {
        const span = safeSegRange(state.doc, state.wrap_map.displayLineInfo(row, state.doc));
        const visual = state.visualLineForSegment(span.start, span.end, row) orelse return error.AccessibilityLayoutPending;
        for (visual.line.caret_stops) |stop| {
            if (output.items.len == core_ui.A11yProps.max_text_geometry_segments) return error.AccessibilityGeometryQuota;
            try output.append(allocator, .{
                .offset = @intCast(span.start + stop.position.byte.value),
                .rect = .{
                    .x = state.container_x + state.padding_h + stop.x.value,
                    .y = state.container_y + state.padding_v + @as(f32, @floatFromInt(row)) * state.line_height - scroll_y,
                    .width = 0,
                    .height = state.line_height,
                },
                .downstream = stop.position.affinity == .downstream,
            });
        }
    }
    return output.toOwnedSlice(allocator);
}

fn textareaBeforeRender(node: *Node) void {
    const state: *TextareaState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    if (node.behavior.interaction.a11y) |*a11y| {
        const selection = state.cursor.selection();
        a11y.value_text = state.getText();
        a11y.multiline = true;
        a11y.editable_text = .{
            .context = state,
            .selection_start = @intCast(if (selection) |s| s.start else state.cursor.offset),
            .selection_end = @intCast(if (selection) |s| s.end else state.cursor.offset),
            .caret = @intCast(state.cursor.offset),
            .uniform_format = true,
            .visible_start = textareaVisibleRange(state).start,
            .visible_end = textareaVisibleRange(state).end,
            .set_selection = struct {
                fn set(context: *anyopaque, start_utf8: u32, end_utf8: u32) bool {
                    const textarea: *TextareaState = @ptrCast(@alignCast(context));
                    return textarea.setAccessibilitySelection(start_utf8, end_utf8);
                }
            }.set,
            .set_value = struct {
                fn set(context: *anyopaque, value: []const u8) bool {
                    const textarea: *TextareaState = @ptrCast(@alignCast(context));
                    return textarea.setAccessibilityValue(value);
                }
            }.set,
            .scroll_into_view = textareaA11yScroll,
            .line_boundaries = textareaA11yLines,
            .geometry_segments = textareaA11yGeometry,
            .row_geometry = textareaA11yRows,
            .caret_geometry = textareaA11yCarets,
            .frame_for_range = textareaA11yFrame,
            .range_at_point = textareaA11yRangeAtPoint,
        };
    }

    // Metrics sync
    const coords = editable_block.computeRenderCoords(node, state.padding_h, state.padding_v);
    state.container_x = coords.global_x;
    state.container_y = coords.global_y;
    const new_inner_w = @max(@as(f32, 0), node.rectFromWorldOrFallback().w - state.padding_h * 2);
    if (new_inner_w > 0 and @abs(new_inner_w - state.input_inner_w) > 0.25) {
        state.input_inner_w = new_inner_w;
        state.wrap_map.setWrapWidth(new_inner_w, state.doc);
        _ = state.wrap_map.rewrapInterpolatedAll(state.doc);
        _ = state.wrap_map.takePendingPatch();
        state.dirty = true;
    }

    if (state.wrap_map.enabled and state.wrap_map.has_interpolated_lines) {
        _ = state.wrap_map.rewrapInterpolatedAll(state.doc);
        _ = state.wrap_map.takePendingPatch();
        state.dirty = true;
        if (state.wrap_map.has_interpolated_lines) {
            if (state.cx_ref) |cx| cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
        }
    }

    // Caret blink
    const now = @import("zenit_time").Instant.now(state.io) catch null;
    const blink_visible = (!state.hasImePreedit() or state.ime_cursor_visible) and (if (state.focused and now != null) state.blinkVisible(now.?) else state.focused);
    if (state.focused and now != null) {
        if (state.cx_ref) |cx| cx.scheduleRedrawAfterNs(state.nextBlinkDelayNs(now.?));
        if (blink_visible != state.last_blink_visible) node.markRenderDirty();
    }
    state.last_blink_visible = blink_visible;

    // Only replay this textarea's recorded drag position, never stale Cx mouse coordinates.
    var edge_scrolling = false;
    if (state.is_dragging) {
        if (state.cx_ref) |cx| {
            if (cx.pressed_node == null or !state.focused) {
                state.is_dragging = false;
                state.drag_pointer = null;
            } else if (state.advanceEdgeDrag(cx.frame_time_ms)) {
                edge_scrolling = true;
                cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
            }
        }
    }

    // VirtualList refresh
    if (state.dirty) {
        state.dirty = false;
        if (state.vl_state) |vl_state| {
            const new_lc = @max(@as(u32, 1), state.wrap_map.displayLineCount());
            if (new_lc != vl_state.item_count) {
                // updateItemCount rebuilds nodes, may trigger markRuntimeIndexDirty.
                // Focus on textarea_node (not pool node), shouldn't be lost.
                virtual_list.updateItemCount(vl_state, new_lc);
            } else {
                virtual_list.refreshRange(vl_state, vl_state.prev_start, vl_state.prev_end);
            }
            const dp = state.cursorDisplayPoint();
            // Autoscroll owns a continuous pixel offset. ensureVisible would
            // round partial bottom rows up every frame and accelerate dragging.
            if (!edge_scrolling) virtual_list.ensureVisible(vl_state, dp.display_line);
        }
        node.markRenderDirty();
    }

    applyTextareaA11yScroll(state);
    if (node.behavior.interaction.a11y) |*props| if (props.editable_text) |*editable| {
        const visible = textareaVisibleRange(state);
        editable.visible_start = visible.start;
        editable.visible_end = visible.end;
    };

    const container_inner_x = state.padding_h;
    const container_inner_y = state.padding_v;
    const cursor_h = @max(@as(f32, 12.0), state.line_height - 2.0);
    // VirtualList scroll offset: overlay absolutely positioned in container,
    // but VL content offset on scroll; cursor/selection need scroll_y compensation
    const scroll_y: f32 = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;

    // Caret node
    if (state.cursor_node) |cnode| {
        if (state.focused) {
            const fallback_dp = state.cursorDisplayPoint();
            const geometry = state.visualLineAtOffset(state.cursor.offset);
            const display_line = if (geometry) |g| g.display_line else fallback_dp.display_line;
            var cursor_x: f32 = 0;
            if (geometry) |g| {
                cursor_x = g.caretX(state.cursor.offset, state.cursor_affinity);
                if (state.imeVisualGeometry(g)) |ime_geometry| {
                    const composed_byte = ime_geometry.insert_offset + state.effectiveImeCursorOffset();
                    const position = text_coordinates.TextPosition{
                        .byte = .{ .value = composed_byte },
                        .affinity = .downstream,
                    };
                    if (ime_geometry.line.positionToCaret(position) catch null) |caret| {
                        cursor_x = caret.x.value;
                    } else {
                        for (ime_geometry.line.caret_stops) |stop| {
                            if (stop.position.byte.value == composed_byte) {
                                cursor_x = stop.x.value;
                                break;
                            }
                        }
                    }
                }
            } else {
                const info = state.wrap_map.displayLineInfo(display_line, state.doc);
                const seg = safeSegRange(state.doc, info);
                const txt = state.doc.getText();
                cursor_x = state.measurePrefix(txt[seg.start..seg.end], state.cursor.offset -| seg.start);
            }
            const cursor_y = @as(f32, @floatFromInt(display_line)) * state.line_height - scroll_y;

            cnode.setLayoutRect(.{ .x = @round(container_inner_x + cursor_x), .y = @round(container_inner_y + cursor_y), .w = 1, .h = cursor_h });
            cnode.setBackgroundRaw(if (blink_visible) state.tokens.tokens.color.fg_primary else Color.TRANSPARENT);
            cnode.markRenderDirty();

            if (state.cx_ref) |cx| {
                const global = node.globalRect();
                _ = cx.setImeCursorRect(global.x + container_inner_x + cursor_x, global.y + container_inner_y + cursor_y, 1, cursor_h);
            }
        } else {
            cnode.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
            cnode.setBackgroundRaw(Color.TRANSPARENT);
            cnode.markRenderDirty();
        }
    }

    // Selection node
    if (state.selection_node) |sel| {
        var placements: std.ArrayListUnmanaged(TextareaState.SelectionPlacement) = .empty;
        defer placements.deinit(state.allocator);
        if (state.hasImePreedit() and state.ime_selection_end != null) {
            if (state.visualLineAtOffset(state.cursor.offset)) |geometry| {
                if (state.imeVisualGeometry(geometry)) |ime| {
                    const begin = @min(state.ime_cursor_utf8_offset, state.ime_selection_end.?);
                    const end = @max(state.ime_cursor_utf8_offset, state.ime_selection_end.?);
                    const storage = state.allocator.alloc(text_coordinates.SelectionRect, @max(ime.line.caret_stops.len, 1)) catch null;
                    if (storage) |rects| {
                        defer state.allocator.free(rects);
                        const resolved = ime.line.selectionRects(.{ .value = ime.insert_offset + begin }, .{ .value = ime.insert_offset + end }, rects) catch rects[0..0];
                        for (resolved) |rect| placements.append(state.allocator, .{ .display_line = geometry.display_line, .rect = rect }) catch {};
                    }
                }
            }
        } else state.collectSelectionPlacements(state.allocator, &placements) catch placements.clearRetainingCapacity();
        if (placements.items.len > 0) {
            const sel_bg = state.tokens.tokens.color.selection_bg;
            const first = placements.items[0];
            sel.setLayoutRect(.{
                .x = @round(container_inner_x + first.rect.x),
                .y = @round(container_inner_y + @as(f32, @floatFromInt(first.display_line)) * state.line_height - scroll_y),
                .w = @round(first.rect.width),
                .h = state.line_height,
            });
            sel.setBackgroundRaw(sel_bg);
            ensureExtraSelNodes(state, placements.items.len - 1);
            const available = @min(placements.items.len - 1, state.extra_sel_nodes.items.len);
            for (placements.items[1 .. available + 1], 0..) |placement, i| {
                const extra = state.extra_sel_nodes.items[i];
                extra.setLayoutRect(.{
                    .x = @round(container_inner_x + placement.rect.x),
                    .y = @round(container_inner_y + @as(f32, @floatFromInt(placement.display_line)) * state.line_height - scroll_y),
                    .w = @round(placement.rect.width),
                    .h = state.line_height,
                });
                extra.setBackgroundRaw(sel_bg);
                extra.markRenderDirty();
            }
            hideExtraSelNodesFrom(state, available);
        } else {
            sel.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
            sel.setBackgroundRaw(Color.TRANSPARENT);
            hideExtraSelNodes(state);
        }
        sel.markRenderDirty();
    }

    // IME underline
    if (state.preedit_underline_node) |line| {
        if (state.hasImePreedit()) {
            const fallback_dp = state.cursorDisplayPoint();
            var display_line = fallback_dp.display_line;
            var rects: std.ArrayListUnmanaged(text_coordinates.SelectionRect) = .empty;
            defer rects.deinit(state.allocator);
            if (state.visualLineAtOffset(state.cursor.offset)) |geometry| {
                display_line = geometry.display_line;
                if (state.imeVisualGeometry(geometry)) |ime_geometry| {
                    const storage_optional = state.allocator.alloc(text_coordinates.SelectionRect, @max(ime_geometry.line.caret_stops.len, 1)) catch null;
                    if (storage_optional) |storage| {
                        defer state.allocator.free(storage);
                        const resolved = ime_geometry.line.selectionRects(.{ .value = ime_geometry.insert_offset }, .{ .value = ime_geometry.insert_offset + state.ime_preedit_len }, storage) catch storage[0..0];
                        rects.appendSlice(state.allocator, resolved) catch {};
                    }
                }
            }

            if (rects.items.len == 0) {
                const info = state.wrap_map.displayLineInfo(display_line, state.doc);
                const seg = safeSegRange(state.doc, info);
                const txt = state.doc.getText();
                const seg_text = txt[seg.start..seg.end];
                const local = state.cursor.offset -| seg.start;
                rects.append(state.allocator, .{
                    .x = state.measurePrefix(seg_text, local),
                    .width = @max(state.measureSlice(state.preeditText()), 4),
                }) catch {};
            }

            const underline_y = container_inner_y + @as(f32, @floatFromInt(display_line)) * state.line_height - scroll_y + cursor_h - 1;
            const accent = Color.rgba(state.tokens.tokens.color.accent.r, state.tokens.tokens.color.accent.g, state.tokens.tokens.color.accent.b, 220);
            if (rects.items.len > 0) {
                const first = rects.items[0];
                line.setLayoutRect(.{ .x = @round(container_inner_x + first.x), .y = @round(underline_y), .w = @round(@max(first.width, 1)), .h = 1.0 });
                line.setBackgroundRaw(accent);
                ensureExtraPreeditNodes(state, rects.items.len - 1);
                const available = @min(rects.items.len - 1, state.extra_preedit_nodes.items.len);
                for (rects.items[1 .. available + 1], 0..) |rect, i| {
                    const extra = state.extra_preedit_nodes.items[i];
                    extra.setLayoutRect(.{ .x = @round(container_inner_x + rect.x), .y = @round(underline_y), .w = @round(@max(rect.width, 1)), .h = 1.0 });
                    extra.setBackgroundRaw(accent);
                    extra.markRenderDirty();
                }
                hideExtraPreeditNodesFrom(state, available);
            } else {
                line.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
                line.setBackgroundRaw(Color.TRANSPARENT);
                hideExtraPreeditNodes(state);
            }
        } else {
            line.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
            line.setBackgroundRaw(Color.TRANSPARENT);
            hideExtraPreeditNodes(state);
        }
        line.markRenderDirty();
    }
}

const VisibleRange = struct { start: u32, end: u32 };

fn textareaVisibleRange(state: *const TextareaState) VisibleRange {
    const line_count = @max(state.wrap_map.total_display_lines, 1);
    const scroll_y = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
    const viewport_h = if (state.input_container_node) |node| @max(node.rectFromWorldOrFallback().h - state.padding_v * 2, state.line_height) else state.line_height;
    const first: u32 = @intFromFloat(@max(@as(f32, 0), @floor(scroll_y / @max(state.line_height, 1))));
    const visible_lines: u32 = @intFromFloat(@ceil(viewport_h / @max(state.line_height, 1)));
    const last = @min(first + @max(visible_lines, 1) - 1, line_count - 1);
    const first_seg = safeSegRange(state.doc, state.wrap_map.displayLineInfo(@min(first, line_count - 1), state.doc));
    const last_seg = safeSegRange(state.doc, state.wrap_map.displayLineInfo(last, state.doc));
    return .{ .start = @intCast(first_seg.start), .end = @intCast(last_seg.end) };
}

fn textareaA11yFrame(context: *anyopaque, start_utf8: u32, end_utf8: u32, out: *core_ui.A11yRect) bool {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    const text = state.doc.getText();
    const requested_start = @min(@as(usize, start_utf8), text.len);
    const requested_end = @min(@as(usize, end_utf8), text.len);
    const start = core_mod.text_coordinates.clampByteOffset(text, .{ .value = requested_start }, .backward).value;
    const end = if (requested_start == requested_end)
        start
    else
        core_mod.text_coordinates.clampByteOffset(text, .{ .value = requested_end }, .forward).value;
    const range_start = @min(start, end);
    const range_end = @max(start, end);
    const start_lc = state.doc.offsetToLineCol(range_start);
    const end_lc = state.doc.offsetToLineCol(range_end);
    const start_dp = state.wrap_map.bufferToDisplay(start_lc.line, start_lc.col);
    const end_dp = state.wrap_map.bufferToDisplay(end_lc.line, end_lc.col);
    const first_row = @min(start_dp.display_line, end_dp.display_line);
    const last_row = @max(start_dp.display_line, end_dp.display_line);
    const start_seg = safeSegRange(state.doc, state.wrap_map.displayLineInfo(start_dp.display_line, state.doc));
    var range_x: f32 = 0;
    var range_width: f32 = @max(state.input_inner_w, 1);
    if (first_row == last_row) {
        var resolved = false;
        if (state.visualLineForSegment(start_seg.start, start_seg.end, first_row)) |geometry| {
            if (range_start == range_end) {
                range_x = geometry.caretX(range_start, .downstream);
                range_width = 1;
                resolved = true;
            } else {
                const storage = state.allocator.alloc(text_coordinates.SelectionRect, @max(geometry.line.caret_stops.len, 1)) catch null;
                if (storage) |rect_storage| {
                    defer state.allocator.free(rect_storage);
                    const rects = geometry.line.selectionRects(.{ .value = range_start -| start_seg.start }, .{ .value = range_end -| start_seg.start }, rect_storage) catch rect_storage[0..0];
                    if (rects.len > 0) {
                        var min_x = rects[0].x;
                        var max_x = rects[0].x + rects[0].width;
                        for (rects[1..]) |rect| {
                            min_x = @min(min_x, rect.x);
                            max_x = @max(max_x, rect.x + rect.width);
                        }
                        range_x = min_x;
                        range_width = @max(max_x - min_x, 1);
                        resolved = true;
                    }
                }
            }
        }
        if (!resolved) {
            const segment = text[start_seg.start..start_seg.end];
            const start_x = state.measurePrefix(segment, range_start -| start_seg.start);
            const end_x = state.measurePrefix(segment, range_end -| start_seg.start);
            range_x = @min(start_x, end_x);
            range_width = @max(@abs(end_x - start_x), 1);
        }
    }
    const scroll_y = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;
    out.* = .{
        .x = state.container_x + state.padding_h + range_x,
        .y = state.container_y + state.padding_v + @as(f32, @floatFromInt(first_row)) * state.line_height - scroll_y,
        .width = range_width,
        .height = @as(f32, @floatFromInt(last_row - first_row + 1)) * @max(state.line_height, 1),
    };
    return true;
}

fn textareaA11yRangeAtPoint(context: *anyopaque, x: f32, y: f32, start_utf8: *u32, end_utf8: *u32) bool {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    const text = state.doc.getText();
    const raw_offset = @min(state.hitTestAt(x, y), text.len);
    const boundary = core_mod.text_coordinates.clampByteOffset(text, .{ .value = raw_offset }, .backward).value;
    const start = if (boundary == text.len and text.len > 0) grapheme.prevBoundary(text, boundary) else boundary;
    const end = if (text.len == 0) 0 else grapheme.nextBoundary(text, start);
    start_utf8.* = @intCast(start);
    end_utf8.* = @intCast(end);
    return true;
}

fn textareaLiveLength(context: *anyopaque) usize {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    return state.doc.totalLength();
}

fn textareaLiveCopy(context: *anyopaque, start_utf8: usize, out: []u8) usize {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    const text = state.doc.getText();
    if (start_utf8 > text.len) return 0;
    const len = @min(out.len, text.len - start_utf8);
    @memcpy(out[0..len], text[start_utf8 .. start_utf8 + len]);
    return len;
}

fn textareaLiveSelection(context: *anyopaque) core_ui.TextInputSelection {
    const state: *TextareaState = @ptrCast(@alignCast(context));
    const selection = state.cursor.selection() orelse return .{
        .start = @intCast(state.cursor.offset),
        .end = @intCast(state.cursor.offset),
        .caret = @intCast(state.cursor.offset),
    };
    return .{
        .start = @intCast(selection.start),
        .end = @intCast(selection.end),
        .caret = @intCast(state.cursor.offset),
    };
}

fn textareaLiveClient(state: *TextareaState) core_ui.TextInputClient {
    return .{
        .context = state,
        .text_len = textareaLiveLength,
        .copy_text = textareaLiveCopy,
        .selection = textareaLiveSelection,
        .is_composing = struct {
            fn read(context: *anyopaque) bool {
                const input: *TextareaState = @ptrCast(@alignCast(context));
                return input.imeIsComposing();
            }
        }.read,
        .set_selection = struct {
            fn set(context: *anyopaque, start_utf8: u32, end_utf8: u32) bool {
                const textarea: *TextareaState = @ptrCast(@alignCast(context));
                return textarea.setAccessibilitySelection(start_utf8, end_utf8);
            }
        }.set,
        .frame_for_range = textareaA11yFrame,
        .range_at_point = textareaA11yRangeAtPoint,
    };
}

fn ensureExtraSelNodes(state: *TextareaState, needed: usize) void {
    const overlay = state.selection_underlay_node orelse return;
    const cx = state.cx_ref orelse return;
    while (state.extra_sel_nodes.items.len < needed) {
        const esel = box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } }, .{}) catch return;
        overlay.appendChild(cx.allocator, esel) catch return;
        state.extra_sel_nodes.append(state.allocator, esel) catch return;
    }
}

fn hideExtraSelNodes(state: *TextareaState) void {
    hideExtraSelNodesFrom(state, 0);
}

fn hideExtraSelNodesFrom(state: *TextareaState, start: usize) void {
    for (state.extra_sel_nodes.items[start..]) |esel| {
        esel.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        esel.setBackgroundRaw(Color.TRANSPARENT);
        esel.markRenderDirty();
    }
}

fn ensureExtraPreeditNodes(state: *TextareaState, needed: usize) void {
    const overlay = state.overlay_node orelse return;
    const cx = state.cx_ref orelse return;
    while (state.extra_preedit_nodes.items.len < needed) {
        const underline = box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } }, .{}) catch return;
        overlay.appendChild(cx.allocator, underline) catch return;
        state.extra_preedit_nodes.append(state.allocator, underline) catch return;
    }
}

fn hideExtraPreeditNodes(state: *TextareaState) void {
    hideExtraPreeditNodesFrom(state, 0);
}

fn hideExtraPreeditNodesFrom(state: *TextareaState, start: usize) void {
    for (state.extra_preedit_nodes.items[start..]) |underline| {
        underline.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        underline.setBackgroundRaw(Color.TRANSPARENT);
        underline.markRenderDirty();
    }
}

fn frameBorderTarget(n: *Node) Color {
    if (n.frame_state.frame_local.runtime.transitions) |slots| if (slots.find(.border_color)) |slot| if (slot.active) return slot.to_color;
    return n.style.border.color;
}

test "Textarea: 框跟随外壳——静止 / 悬停 / 聚焦（1.5px accent）/ 动态出错（聚焦也保持 1px）/ 动态禁用；编辑态的焦点处理不顶掉外壳钩子" {
    const alloc = std.testing.allocator;
    var cx = try Cx.init(alloc, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;
    const scope = try Scope.init(alloc, null, cx.owner);
    defer scope.dispose();
    const err = try scope.createSignal([]const u8, "");
    const disabled = try scope.createSignal(bool, false);
    const mounted = try Textarea(.{ .value = "a", .error_msg = err, .disabled = disabled }).mountResult(scope, cx);
    try root.appendChild(alloc, mounted.wrapper);
    cx.layout();
    _ = cx.render();
    const c = cx.tokens.tokens.color;
    const field = mounted.input;
    try std.testing.expect(Color.eql(c.border_strong, frameBorderTarget(field)));
    try std.testing.expect(Color.eql(c.input_bg, field.getBackground()));
    try std.testing.expectEqual(@as(f32, 1), field.style.border.width);

    field.behavior.events.on_hover.?.invoke();
    try std.testing.expect(Color.eql(c.accent, frameBorderTarget(field)));
    field.behavior.events.on_leave.?.invoke();
    try std.testing.expect(Color.eql(c.border_strong, frameBorderTarget(field)));

    cx.setFocus(field);
    try std.testing.expect(mounted.state.focused);
    try std.testing.expect(Color.eql(c.accent, frameBorderTarget(field)));
    try std.testing.expectEqual(@as(f32, 1.5), field.style.border.width);
    cx.clearFocus();
    try std.testing.expect(!mounted.state.focused);
    try std.testing.expect(Color.eql(c.border_strong, frameBorderTarget(field)));
    try std.testing.expectEqual(@as(f32, 1), field.style.border.width);

    err.set("required");
    try std.testing.expect(Color.eql(c.danger, frameBorderTarget(field)));
    cx.setFocus(field);
    try std.testing.expect(Color.eql(c.danger, frameBorderTarget(field)));
    try std.testing.expectEqual(@as(f32, 1), field.style.border.width);
    cx.clearFocus();
    err.set("");
    try std.testing.expect(Color.eql(c.border_strong, frameBorderTarget(field)));

    cx.setFocus(field);
    disabled.set(true);
    try std.testing.expect(!cx.isFocused(field));
    try std.testing.expect(!mounted.state.focused);
    try std.testing.expect(Color.eql(c.border, frameBorderTarget(field)));
    try std.testing.expect(!field.behavior.interaction.focusable);
    try std.testing.expectEqual(core_ui.CursorShape.default, field.style.cursor);
}

test "Textarea: embedded leaves the frame to the compound control in every state" {
    const alloc = std.testing.allocator;
    var cx = try Cx.init(alloc, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;
    const scope = try Scope.init(alloc, null, cx.owner);
    defer scope.dispose();
    const err = try scope.createSignal([]const u8, "");
    const mounted = try Textarea(.{ .value = "a", .rows = 1, .error_msg = err, .embedded = true }).mountResult(scope, cx);
    const plain = try Textarea(.{ .value = "a", .rows = 1 }).mountResult(scope, cx);
    try root.appendChild(alloc, mounted.wrapper);
    try root.appendChild(alloc, plain.wrapper);
    cx.layout();
    _ = cx.render();
    const field = mounted.input;
    const transparent = cx.tokens.tokens.color.transparent;
    const expectBare = struct {
        fn check(n: *Node, clear: Color) !void {
            try std.testing.expectEqual(@as(f32, 0), n.style.border.width);
            try std.testing.expect(Color.eql(clear, n.getBackground()));
        }
    }.check;

    try expectBare(field, transparent);
    try std.testing.expectEqual(@as(f32, 0), mounted.state.padding_h);
    // The field fills its wrapper, which the compound control sizes; state changes keep it.
    try std.testing.expectApproxEqAbs(mounted.wrapper.rectFromWorldOrFallback().h, field.rectFromWorldOrFallback().h, 0.01);
    mounted.wrapper.setStyleInline(alloc, .{ .height = .{ .px = 90 } });
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 90), field.rectFromWorldOrFallback().h, 0.01);
    try std.testing.expect(field.meta.per_frame.hooks.slots.focus_ring_anim == null);
    try std.testing.expect(plain.input.meta.per_frame.hooks.slots.focus_ring_anim != null);
    try std.testing.expect(plain.state.padding_h > 0);

    field.behavior.events.on_hover.?.invoke();
    try expectBare(field, transparent);
    field.behavior.events.on_leave.?.invoke();
    cx.setFocus(field);
    try std.testing.expect(mounted.state.focused);
    try expectBare(field, transparent);
    err.set("required");
    try expectBare(field, transparent);
    cx.clearFocus();
    err.set("");
    try expectBare(field, transparent);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 90), field.rectFromWorldOrFallback().h, 0.01);
}

test "Textarea: 占位符行在渲染时保持占位符颜色，不继承外壳的前景色" {
    const alloc = std.testing.allocator;
    var cx = try Cx.init(alloc, std.testing.io);
    defer cx.deinit();
    const root = try box(cx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;
    const scope = try Scope.init(alloc, null, cx.owner);
    defer scope.dispose();
    const mounted = try Textarea(.{ .placeholder = "Write something" }).mountResult(scope, cx);
    try root.appendChild(alloc, mounted.wrapper);
    cx.layout();
    _ = cx.render();
    cx.layout();
    _ = cx.render();
    const painted = @import("../../core/render_engine/text_render.zig").resolveNodeLogicalTextProps;
    const find = struct {
        fn f(n: *Node) ?*Node {
            if (n.getText()) |txt| if (std.mem.eql(u8, txt.content, "Write something")) return n;
            for (n.children.items) |c| if (f(c)) |hit| return hit;
            return null;
        }
    }.f;
    const text_node = find(mounted.input).?;
    try std.testing.expect(Color.eql(cx.tokens.tokens.color.fg_secondary, painted(text_node).?.color));
}

test "TextareaState: IME preedit text is fused into display segment content" {
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText("abcd");

    var wm = TextareaWrapMap.init(std.testing.allocator, @import("std").testing.io);
    defer wm.deinit();

    var state = TextareaState{
        .io = std.testing.io,
        .doc = &doc,
        .wrap_map = &wm,
        .allocator = std.testing.allocator,
    };
    defer state.deinit();
    state.cursor.offset = 2;

    const ni = "\xe4\xbd\xa0";
    state.handleImePreedit(ni, @as(u32, @intCast(ni.len)));

    const insert_offset = state.imeInsertOffsetForSegment(0, 0, 4) orelse unreachable;
    const fused = state.composeSegmentWithIme("abcd", insert_offset);
    try std.testing.expect(std.mem.eql(u8, fused, "ab" ++ ni ++ "cd"));
}

test "TextareaState: IME boundary insertion prefers next wrapped segment" {
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText("abcd");

    var wm = TextareaWrapMap.init(std.testing.allocator, @import("std").testing.io);
    defer wm.deinit();

    var state = TextareaState{
        .io = std.testing.io,
        .doc = &doc,
        .wrap_map = &wm,
        .allocator = std.testing.allocator,
    };
    state.cursor.offset = 2;

    const ni = "\xe4\xbd\xa0";
    state.handleImePreedit(ni, @as(u32, @intCast(ni.len)));

    try std.testing.expect(state.imeInsertOffsetForSegment(0, 0, 2) == null);
    const next = state.imeInsertOffsetForSegment(0, 2, 4) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), next);
}

test "TextareaState: IME selection highlight keeps cursor at preedit end when offset is zero" {
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText("ab");

    var wm = TextareaWrapMap.init(std.testing.allocator, @import("std").testing.io);
    defer wm.deinit();

    var state = TextareaState{
        .io = std.testing.io,
        .doc = &doc,
        .wrap_map = &wm,
        .allocator = std.testing.allocator,
    };

    const preedit = "\xe3\x81\x97\xe3\x82\x85\xe3\x82\x8b"; // しゅる
    state.handleImePreedit(preedit, 0);
    state.markImeSelectionHighlight();
    try std.testing.expectEqual(preedit.len, state.effectiveImeCursorOffset());
}

test "TextareaState: production caret order hit testing and vertical x survive isolates and overrides" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core_ui.FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const line_text = "ab \u{2067}\u{05D0}\u{05D1} \u{2066}12\u{2069}\u{2069} \u{202E}cd\u{202C} 👩‍💻";
    var document_buffer: [256]u8 = undefined;
    const document_text = try std.fmt.bufPrint(&document_buffer, "{s}\n{s}", .{ line_text, line_text });
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText(document_text);
    var wm = TextareaWrapMap.init(std.testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(10000, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    var state = TextareaState{
        .io = std.testing.io,
        .doc = &doc,
        .wrap_map = &wm,
        .allocator = std.testing.allocator,
        .cx_ref = cx,
        .font_size = 16,
        .line_height = 20,
        .padding_h = 0,
        .padding_v = 0,
    };
    defer state.deinit();

    const visual = try cx.text.visualLine(.{ .text = line_text, .font_family = "system", .font_size = 16 });
    try std.testing.expect(visual.caret_stops.len > 8);
    state.cursor.offset = visual.caret_stops[0].position.byte.value;
    state.cursor_affinity = visual.caret_stops[0].position.affinity;
    var saw_logical_reverse = false;
    var i: usize = 1;
    while (i < visual.caret_stops.len) : (i += 1) {
        const previous = state.cursor.offset;
        state.moveCursorRight(false);
        try std.testing.expectEqual(visual.caret_stops[i].position.byte.value, state.cursor.offset);
        try std.testing.expectEqual(visual.caret_stops[i].position.affinity, state.cursor_affinity);
        if (state.cursor.offset < previous) saw_logical_reverse = true;
    }
    try std.testing.expect(saw_logical_reverse);

    // Every physical x maps through the exact same VisualLine authority used
    // for rendering; duplicate bidi carets use xToPosition's affinity rule.
    for (visual.caret_stops) |stop| {
        const expected = visual.xToPosition(stop.x);
        const hit = state.hitTestAt(stop.x.value, 10);
        try std.testing.expectEqual(expected.byte.value, hit);
        try std.testing.expectEqual(expected.affinity, state.cursor_affinity);
    }

    const chosen = visual.caret_stops[visual.caret_stops.len / 3];
    const expected_target = visual.xToPosition(chosen.x);
    state.cursor.offset = chosen.position.byte.value;
    state.cursor_affinity = chosen.position.affinity;
    state.moveCursorDown(false);
    try std.testing.expectEqual(line_text.len + 1 + expected_target.byte.value, state.cursor.offset);
    try std.testing.expectEqual(expected_target.affinity, state.cursor_affinity);
    try std.testing.expectApproxEqAbs(chosen.x.value, state.preferred_visual_x.?, 0.01);
}

test "Textarea soft-wrap boundary hit tests retain the clicked visual row" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core_ui.FontSystem.init(std.testing.allocator, std.testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText("مرحبا שלום abc 123 مرحبا שלום abc 123 مرحبا שלום abc 123");
    var wm = TextareaWrapMap.init(std.testing.allocator, std.testing.io);
    defer wm.deinit();
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(110, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    var state = TextareaState{
        .io = std.testing.io,
        .doc = &doc,
        .wrap_map = &wm,
        .allocator = std.testing.allocator,
        .cx_ref = cx,
        .font_size = 13,
        .line_height = 18.2,
        .padding_h = 12,
        .padding_v = 12,
    };
    defer state.deinit();
    try std.testing.expect(wm.displayLineCount() >= 2);
    for (0..wm.displayLineCount()) |row| {
        // Outside either text edge resolves to a line endpoint. An endpoint byte shared
        // by two soft-wrapped rows must keep this row when the caret is rendered.
        for ([_]f32{ 0, 1000 }) |x| {
            state.cursor.offset = state.hitTestAt(x, state.padding_v + (@as(f32, @floatFromInt(row)) + 0.5) * state.line_height);
            const geometry = state.visualLineAtOffset(state.cursor.offset).?;
            try std.testing.expectEqual(@as(u32, @intCast(row)), geometry.display_line);
        }
    }
}

test "Textarea accessibility range frame shares mixed-bidi VisualLine geometry" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core_ui.FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const content = "abc \u{05D0}\u{05D1}\u{05D2} 12";
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText(content);
    var wm = TextareaWrapMap.init(std.testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(10_000, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    var state = TextareaState{
        .io = std.testing.io,
        .doc = &doc,
        .wrap_map = &wm,
        .allocator = std.testing.allocator,
        .cx_ref = cx,
        .font_size = 16,
        .line_height = 20,
        .padding_h = 7,
        .padding_v = 5,
        .container_x = 11,
        .container_y = 13,
        .input_inner_w = 500,
    };
    defer state.deinit();

    const range_start: usize = 4;
    const range_end: usize = 10;
    const line = try cx.text.visualLine(.{ .text = content, .font_family = "system", .font_size = 16 });
    const storage = try std.testing.allocator.alloc(text_coordinates.SelectionRect, line.caret_stops.len);
    defer std.testing.allocator.free(storage);
    const rects = try line.selectionRects(.{ .value = range_start }, .{ .value = range_end }, storage);
    try std.testing.expect(rects.len > 0);
    var expected_min = rects[0].x;
    var expected_max = rects[0].x + rects[0].width;
    for (rects[1..]) |rect| {
        expected_min = @min(expected_min, rect.x);
        expected_max = @max(expected_max, rect.x + rect.width);
    }

    var frame: core_ui.A11yRect = undefined;
    try std.testing.expect(textareaA11yFrame(&state, @intCast(range_start), @intCast(range_end), &frame));
    try std.testing.expectApproxEqAbs(state.container_x + state.padding_h + expected_min, frame.x, 0.01);
    try std.testing.expectApproxEqAbs(@max(expected_max - expected_min, 1), frame.width, 0.01);
    try std.testing.expectApproxEqAbs(state.container_y + state.padding_v, frame.y, 0.01);
    try std.testing.expectApproxEqAbs(state.line_height, frame.height, 0.01);

    var placements: std.ArrayListUnmanaged(TextareaState.SelectionPlacement) = .empty;
    defer placements.deinit(std.testing.allocator);
    // Cross the LTR/RTL boundary and keep each visual piece, rather than
    // replacing the result with the enclosing frame used by the IME API.
    const mixed_rects = try line.selectionRects(.{ .value = 2 }, .{ .value = 6 }, storage);
    try state.collectRangePlacements(2, 6, std.testing.allocator, &placements);
    try std.testing.expectEqual(mixed_rects.len, placements.items.len);
    for (mixed_rects, placements.items) |expected, actual| {
        try std.testing.expectEqual(@as(u32, 0), actual.display_line);
        try std.testing.expectEqualDeep(expected, actual.rect);
    }
    try std.testing.expectEqual(@as(usize, 0), state.cursor.offset);
    try std.testing.expect(state.cursor.anchor == null);
}

test "TextareaState: owned accessibility geometry preserves shaped spans and rejects pending layout" {
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core_ui.FontSystem.init(t.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    const content = "abc \u{05D0}\u{05D1}\u{05D2} 12\nx";
    try doc.setTextChecked(content);
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(10000, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator, .cx_ref = cx, .font_size = 16, .line_height = 20, .container_x = 11, .container_y = 13, .padding_h = 7, .padding_v = 5 };
    defer state.deinit();
    const owned = try textareaA11yGeometry(&state, t.allocator);
    defer t.allocator.free(owned);
    var index: usize = 0;
    for (0..wm.displayLineCount()) |row| {
        const span = safeSegRange(&doc, wm.displayLineInfo(@intCast(row), &doc));
        const line = try cx.text.visualLine(.{ .text = content[span.start..span.end], .font_family = "system", .font_size = 16 });
        var segments = line.selectionSegments();
        while (segments.next()) |segment| {
            if (segment.rect.width <= 0) continue;
            try t.expect(index < owned.len);
            const actual = owned[index];
            try t.expectEqual(span.start + segment.start.value, actual.start);
            try t.expectEqual(span.start + segment.end.value, actual.end);
            try t.expectApproxEqAbs(18 + segment.rect.x, actual.rect.x, 0.01);
            try t.expectApproxEqAbs(18 + @as(f32, @floatFromInt(row)) * 20, actual.rect.y, 0.01);
            try t.expectEqual(segment.rect.width, actual.rect.width);
            try t.expectEqual(@as(f32, 20), actual.rect.height);
            index += 1;
        }
    }
    try t.expect(index > 1 and index == owned.len);
    const preserved = owned[0];
    wm.has_interpolated_lines = true;
    try t.expectError(error.AccessibilityLayoutPending, textareaA11yGeometry(&state, t.allocator));
    wm.has_interpolated_lines = false;
    try doc.setTextChecked("replacement");
    wm.rebuildAll(&doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    try t.expectEqualDeep(preserved, owned[0]);
    try t.expectEqual(@as(usize, 0), state.cursor.offset);
    try t.expect(state.cursor.anchor == null);
}

test "TextareaState: selection geometry has no sixteen-line ceiling" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core_ui.FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..40) |line_index| {
        try source.appendSlice(std.testing.allocator, "abc \u{05D0}\u{05D1} 12");
        if (line_index + 1 < 40) try source.append(std.testing.allocator, '\n');
    }
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText(source.items);
    var wm = TextareaWrapMap.init(std.testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(10000, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    var state = TextareaState{
        .io = std.testing.io,
        .doc = &doc,
        .wrap_map = &wm,
        .allocator = std.testing.allocator,
        .cx_ref = cx,
        .font_size = 16,
    };
    defer state.deinit();
    state.cursor.anchor = 0;
    state.cursor.offset = doc.totalLength();

    var placements: std.ArrayListUnmanaged(TextareaState.SelectionPlacement) = .empty;
    defer placements.deinit(std.testing.allocator);
    try state.collectSelectionPlacements(std.testing.allocator, &placements);
    try std.testing.expect(placements.items.len >= 40);
    for (placements.items) |placement| {
        try std.testing.expect(placement.rect.width >= 0);
        try std.testing.expect(std.math.isFinite(placement.rect.x));
    }
    // Accessibility queries can ask for text unrelated to the live selection.
    // Clearing the cursor must leave arbitrary-range geometry unchanged.
    state.cursor.anchor = null;
    state.cursor.offset = 3;
    var queried: std.ArrayListUnmanaged(TextareaState.SelectionPlacement) = .empty;
    defer queried.deinit(std.testing.allocator);
    try state.collectRangePlacements(0, doc.totalLength(), std.testing.allocator, &queried);
    try std.testing.expectEqualDeep(placements.items, queried.items);
    try std.testing.expectEqual(@as(usize, 3), state.cursor.offset);
    try std.testing.expect(state.cursor.anchor == null);
}

test "TextareaState: arbitrary range geometry respects exclusive wrap ends and scalar bounds" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abcdefgh\nx");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 8;
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(32, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer state.deinit();
    state.cursor.offset = 10;
    state.cursor.anchor = 9;
    var placements: std.ArrayListUnmanaged(TextareaState.SelectionPlacement) = .empty;
    defer placements.deinit(t.allocator);
    try state.collectRangePlacements(0, 4, t.allocator, &placements);
    try t.expectEqual(@as(usize, 1), placements.items.len);
    try t.expectEqual(@as(u32, 0), placements.items[0].display_line);
    placements.clearRetainingCapacity();
    try state.collectRangePlacements(4, 9, t.allocator, &placements);
    try t.expectEqual(@as(usize, 1), placements.items.len);
    try t.expectEqual(@as(u32, 1), placements.items[0].display_line);
    placements.clearRetainingCapacity();
    try state.collectRangePlacements(4, 4, t.allocator, &placements);
    try t.expectEqual(@as(usize, 0), placements.items.len);
    try t.expectError(error.InvalidTextRange, state.collectRangePlacements(4, 3, t.allocator, &placements));
    try t.expectError(error.InvalidTextRange, state.collectRangePlacements(0, 11, t.allocator, &placements));
    try t.expectEqual(@as(usize, 10), state.cursor.offset);
    try t.expectEqual(@as(?usize, 9), state.cursor.anchor);
    try doc.setTextChecked("A中😀B");
    wm.rebuildAll(&doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    try t.expectError(error.InvalidTextRange, state.collectRangePlacements(2, 4, t.allocator, &placements));
    try t.expectError(error.InvalidTextRange, state.collectRangePlacements(1, 6, t.allocator, &placements));
    try t.expectEqual(@as(usize, 0), placements.items.len);
}

test "TextareaState: long IME composition preserves complete graphemes" {
    var long_line: [4096]u8 = @as([4096]u8, @splat('x'));
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText(&long_line);
    var wm = TextareaWrapMap.init(std.testing.allocator, @import("std").testing.io);
    defer wm.deinit();
    var state = TextareaState{
        .io = std.testing.io,
        .doc = &doc,
        .wrap_map = &wm,
        .allocator = std.testing.allocator,
    };
    defer state.deinit();
    state.cursor.offset = 3000;
    state.handleImePreedit("👩‍💻", 2);
    try std.testing.expectEqual("👩‍💻".len, state.ime_cursor_utf8_offset);
    const composed = state.composeSegmentWithIme(doc.getText(), state.cursor.offset);
    try std.testing.expectEqual(long_line.len + "👩‍💻".len, composed.len);
    try std.testing.expectEqualStrings("👩‍💻", composed[3000 .. 3000 + "👩‍💻".len]);

    var oversized: [300]u8 = @as([300]u8, @splat('a'));
    const emoji = "👩‍💻";
    @memcpy(oversized[255 .. 255 + emoji.len], emoji);
    state.handleImePreedit(oversized[0 .. 255 + emoji.len], @intCast(255 + emoji.len));
    try std.testing.expectEqual(@as(usize, 255 + emoji.len), state.ime_preedit_len);
    try std.testing.expect(text_coordinates.isGraphemeBoundary(oversized[0 .. 255 + emoji.len], state.ime_preedit_len));
}

// ============================================================================
// Public API: Textarea component
// ============================================================================

pub const TextareaProps = struct {
    /// Optional field-size specimen from RYMhT. null retains the roomy 100px textarea.
    size: ?@import("../control_shell/mod.zig").ControlSize = null,
    /// Text value. Literal = self-held initial; `*Signal([]const u8)` controlled (interaction
    /// writes directly; must be created by `scope.createText`); `ui.split` intercepted by parent.
    /// External write rules same as Input.
    value: Model([]const u8) = .{ .local = "" },
    /// Placeholder / label / helper / error ("" = none; can pass signal)
    placeholder: Source([]const u8) = .{ .value = "" },
    label_text: Source([]const u8) = .{ .value = "" },
    helper: Source([]const u8) = .{ .value = "" },
    error_msg: Source([]const u8) = .{ .value = "" },
    rows: u32 = 4,
    disabled: Source(bool) = .{ .value = false },
    required: bool = false,
    readonly: bool = false,
    width: ?f32 = null,
    /// Inside a compound control that draws the frame itself (same contract as Input.embedded):
    /// the shell drops its border, background and focus ring, the text sits flush horizontally
    /// (the compound frame pads), and the field flexes in the parent row. The field fills the
    /// returned `wrapper`, so the compound control sizes it through the wrapper (initially the
    /// `rows` / `size` height).
    embedded: bool = false,
    /// Called after user edit settled (landed value; slice only valid during callback)
    on_change: ?Handler([]const u8) = null,
};

/// Create multiline text box: `W.Textarea(.{ .value = notes, .rows = 5 })`
pub fn Textarea(props: anytype) TextareaBuilder {
    return .{ .props = reactive.props.coerce(TextareaProps, props) };
}

pub const TextareaResult = struct {
    wrapper: *Node,
    input: *Node,
    /// Edit state (read cursor / composition etc interaction detail; write text via `value`)
    state: *TextareaState,
    /// Text value signal (`ui.split` is null)
    value: ?*Signal([]const u8),

    /// `ui.view` hookup: `v.capture(&st.ta, W.Textarea(...))` grab edit state,
    /// `.parts = .{ .input = "id" }` mark input.
    pub fn viewParts(self: TextareaResult) core_ui.ViewParts {
        return .{ .root = self.wrapper };
    }
};

/// Textarea value binding (see binding.zig)
pub const TextareaBinding = binding_mod.TextBinding(TextareaState);

const label_row_h: f32 = 22;
const helper_row_h: f32 = 20;

/// Surrounding dynamics (all-static doesn't build effect): label / helper+error / placeholder /
/// disabled
const TextareaChrome = struct {
    state: *TextareaState,
    cx: *Cx,
    tokens: *const ThemeTokens,
    label: Source([]const u8),
    helper: Source([]const u8),
    error_msg: Source([]const u8),
    placeholder: Source([]const u8),
    disabled: Source(bool),
    /// The shell's invalid state (frame color follows it declaratively).
    invalid: *Signal(bool),
    wrapper: *Node,
    textarea_node: *Node,
    field_h: f32,
    /// Embedded: the compound control sizes the wrapper; chrome only shows / hides the rows.
    embedded: bool,
    label_node: ?*Node = null,
    helper_node: ?*Node = null,
    placeholder_copy: []u8 = &.{},
    shown_disabled: bool = false,

    fn effect(self: *TextareaChrome) void {
        self.apply(true) catch |err| std.log.err("[Textarea] updating chrome failed: {}", .{err});
    }

    fn apply(self: *TextareaChrome, comptime tracked: bool) !void {
        const a = self.cx.allocator;
        var height = self.field_h;
        if (self.label_node) |ln| {
            const text = self.label.read(tracked);
            if (!std.mem.eql(u8, ln.getText().?.content, text)) try ln.setTextContent(a, text);
            ln.setDisplay(if (text.len > 0) .flex else .none);
            if (text.len > 0) height += label_row_h;
            if (self.textarea_node.behavior.interaction.a11y) |*attrs| attrs.label = ln.getText().?.content;
        }
        if (!self.placeholder.isStatic()) {
            const ph = self.placeholder.read(tracked);
            if (!std.mem.eql(u8, self.placeholder_copy, ph)) {
                const copy = try a.dupe(u8, ph);
                a.free(self.placeholder_copy);
                self.placeholder_copy = copy;
                self.state.placeholder_text = if (copy.len > 0) copy else null;
                if (self.textarea_node.behavior.interaction.a11y) |*attrs| attrs.placeholder = self.state.placeholder_text;
                self.state.markDirty();
            }
        }
        const err_text = self.error_msg.read(tracked);
        const help_text = self.helper.read(tracked);
        const has_error = err_text.len > 0;
        if (has_error != self.state.has_error) {
            self.state.has_error = has_error;
            self.invalid.set(has_error);
            if (self.textarea_node.behavior.interaction.a11y) |*attrs| attrs.invalid = has_error;
        }
        if (self.helper_node) |hn| {
            const shown = if (has_error) err_text else help_text;
            if (!std.mem.eql(u8, hn.getText().?.content, shown)) try hn.setTextContent(a, shown);
            var txt = hn.getText().?;
            txt.color = styles.textareaHelperStyle(self.tokens, has_error).color;
            hn.setText(txt);
            hn.setDisplay(if (shown.len > 0) .flex else .none);
            if (shown.len > 0) height += helper_row_h;
            hn.markRenderDirty();
        }
        if (!self.embedded) {
            self.wrapper.style.height = .{ .px = height };
            self.wrapper.markLayoutDirty();
        }
        const disabled = self.disabled.read(tracked);
        if (disabled != self.shown_disabled) self.applyDisabled(disabled);
    }

    fn applyDisabled(self: *TextareaChrome, disabled: bool) void {
        self.shown_disabled = disabled;
        self.state.disabled = disabled;
        self.state.markDirty();
        const node = self.textarea_node;
        // Frame and cursor follow the shell's disabled parameter.
        // Blur first (dispatch blur, run original on_blur cleanup) then set unfocusable
        if (disabled) {
            self.state.cancelImeComposition();
            if (self.cx.focus_manager.getFocused() == node) self.cx.clearFocus();
        }
        node.setFocusable(!disabled);
        if (node.behavior.interaction.a11y) |*attrs| attrs.disabled = disabled;
    }

    fn destroy(ptr: *anyopaque, alloc: Allocator) void {
        const self: *TextareaChrome = @ptrCast(@alignCast(ptr));
        self.cx.allocator.free(self.placeholder_copy);
        alloc.destroy(self);
    }
};

pub const TextareaBuilder = struct {
    props: TextareaProps,

    pub fn mount(self: TextareaBuilder, scope: *Scope, cx: *Cx) !*Node {
        return (try self.mountResult(scope, cx)).wrapper;
    }

    /// `ui.view` hookup (see TextareaResult.viewParts).
    pub fn viewMount(self: TextareaBuilder, scope: *Scope, cx: *Cx) !TextareaResult {
        return self.mountResult(scope, cx);
    }

    /// Mount and return edit state + value signal
    pub fn mountResult(self: TextareaBuilder, scope: *Scope, cx: *Cx) !TextareaResult {
        cx.owner.enterMount();
        defer cx.owner.exitMount();
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;
        reactive.checkBorrow(my_scope, p.placeholder);
        reactive.checkBorrow(my_scope, p.label_text);
        reactive.checkBorrow(my_scope, p.helper);
        reactive.checkBorrow(my_scope, p.error_msg);
        reactive.checkBorrow(my_scope, p.disabled);
        const has_error = p.error_msg.peek().len > 0;
        const disabled0 = p.disabled.peek();
        // Static disable as-is: disabled look, no event handler; dynamic by TextareaChrome gate
        const static_disabled = p.disabled.isStatic() and disabled0;
        const chrome_dynamic = !p.label_text.isStatic() or !p.helper.isStatic() or !p.error_msg.isStatic() or
            !p.placeholder.isStatic() or !p.disabled.isStatic();
        const metrics = styles.textareaMetrics(t, p.size, p.rows);
        const line_height = metrics.line_height;
        const font_size = metrics.font_size;
        const char_width: f32 = 7.8;
        const pad = if (p.embedded) 0 else metrics.padding_h;
        const pad_v = metrics.padding_v;

        const value = try reactive.resolveTextModel(my_scope, p.value);

        const doc = try my_scope.allocator.create(TextareaDocument);
        doc.* = TextareaDocument.initFallible(my_scope.allocator) catch |err| {
            my_scope.allocator.destroy(doc);
            return err;
        };
        try my_scope.adoptResource(@ptrCast(doc), struct {
            fn d(ptr: *anyopaque, alloc: Allocator) void {
                const dd: *TextareaDocument = @ptrCast(@alignCast(ptr));
                dd.deinit();
                alloc.destroy(dd);
            }
        }.d);
        const initial_value = value.peek();
        if (initial_value.len > 0) try doc.setTextChecked(initial_value);

        // Measure through this window's Cx; the legacy context-free callback
        // can otherwise select a different live window's FontSelector.
        const mfn = cx.text.measure_fn;
        const measured_char_width = cx.text.measureTextWidth("M", font_size, 400, false);
        const real_char_width = if (measured_char_width > 0) measured_char_width else char_width;

        // WrapMap
        const wm = try my_scope.allocator.create(TextareaWrapMap);
        wm.* = TextareaWrapMap.init(my_scope.allocator, cx.io);
        wm.measure_ctx_fn = Cx.measureTextWidthCallback;
        wm.measure_ctx = cx;
        wm.char_width = real_char_width;
        wm.precise_wrap = true;
        wm.font_size = font_size;
        try my_scope.adoptResource(@ptrCast(wm), struct {
            fn d(ptr: *anyopaque, alloc: Allocator) void {
                const w: *TextareaWrapMap = @ptrCast(@alignCast(ptr));
                w.deinit();
                alloc.destroy(w);
            }
        }.d);

        // Static placeholder borrows caller literal; dynamic held by TextareaChrome copy
        const placeholder0: ?[]const u8 = if (p.placeholder.isStatic() and p.placeholder.peek().len > 0) p.placeholder.peek() else null;

        // TextareaState
        const state = try my_scope.allocator.create(TextareaState);
        state.* = TextareaState{
            .io = cx.io,
            .doc = doc,
            .wrap_map = wm,
            .allocator = my_scope.allocator,
            .measure_fn = mfn,
            .char_width = real_char_width,
            .font_size = font_size,
            .line_height = line_height,
            .padding_h = pad,
            .padding_v = pad_v,
            .placeholder_text = placeholder0,
            .cx_ref = cx,
            .tokens = t,
            .has_error = has_error,
            .disabled = disabled0,
        };
        if (initial_value.len > 0) state.cursor.offset = doc.totalLength();
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn d(ptr: *anyopaque, alloc: Allocator) void {
                const s: *TextareaState = @ptrCast(@alignCast(ptr));
                s.deinit();
                alloc.destroy(s);
            }
        }.d);

        // Value binding: edit outlet / composition cancel both go through it
        const binding = try my_scope.allocator.create(TextareaBinding);
        binding.* = .{ .state = state, .value = value, .on_change = p.on_change };
        try my_scope.adoptResource(@ptrCast(binding), TextareaBinding.destroy);
        binding.install();

        // Initialize wrap.
        // WrapMap width initialized on first beforeRender frame by actual container width (layout
        // not done at mount)
        if (p.width) |w| {
            const inner_w = @max(@as(f32, 0), w - pad * 2);
            state.input_inner_w = inner_w;
            wm.setWrapWidth(inner_w, doc);
        }
        wm.setEnabled(true, doc);
        _ = wm.rewrapInterpolatedAll(doc);
        _ = wm.takePendingPatch();

        const textarea_height = metrics.height;
        const label0 = p.label_text.peek();
        const helper0 = if (has_error) p.error_msg.peek() else p.helper.peek();
        const build_label = !p.label_text.isStatic() or label0.len > 0;
        const build_helper = !p.helper.isStatic() or !p.error_msg.isStatic() or helper0.len > 0;
        var wrapper_height: f32 = textarea_height;
        if (label0.len > 0) wrapper_height += label_row_h;
        if (helper0.len > 0) wrapper_height += helper_row_h;

        const field_radius: f32 = if (p.embedded) 0 else metrics.radius;
        const invalid_frame = try my_scope.createSignal(bool, has_error);
        const fill_inset: core_ui.Inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } };
        const zero_box: core_ui.BoxStyle = .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } };
        const layer_style: core_ui.BoxStyle = .{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
            .position = .absolute,
            .inset = fill_inset,
            .hit_behavior = .pass_through,
        };

        // Node tree (wrapper kept to return, disposedScope bound to it)
        const Parts = struct {
            label: ?*Node = null,
            shell: core_ui.ViewParts = undefined,
            underlay: *Node = undefined,
            selection: *Node = undefined,
            helper: ?*Node = null,
        };
        var parts: Parts = .{};
        const wrapper = try view.render(my_scope, cx, view.col(.{ .style = core_ui.BoxStyle{
            .width = if (p.embedded) .{ .grow = .{ .min = 0 } } else if (p.width) |w| .{ .px = w } else .{ .grow = .{} },
            .flex_shrink = if (p.embedded) 1 else null,
            .min_width = if (p.embedded) 0 else null,
            .height = .{ .px = wrapper_height },
            .gap = 4,
        } }, .{
            // Label (dynamic always built, hidden when empty): fixed-height box + own text
            if (build_label) view.capture(&parts.label, view.setup(view.box(.{
                .style = .{ .height = .{ .px = 18 } },
                .visible = label0.len > 0,
            }, {}), BoxText{ .style = styles.textareaLabelStyle(t), .content = label0 }, BoxText.apply)) else null,
            // The field: ControlShell(.field) draws the frame and every frame state (hover / focus
            // from the node, disabled / invalid from parameters); Textarea adds its fixed-height
            // scroll surface as an overlay and stacks the line list's layers in the content slot.
            view.attrs(.{
                .style = .{ view.styleBy(styles.TextareaFrame{ .width = p.width, .height = if (p.embedded) null else textarea_height, .radius = field_radius }, styles.textareaFrame), view.when(!p.embedded, styles.textarea_focus) },
                .state = .{ .invalid = invalid_frame },
            }, view.with(control_shell.ControlShell(.{
                .variant = .field,
                .size = p.size orelse .md,
                .disabled = p.disabled,
                .invalid = invalid_frame,
                .embedded = p.embedded,
                .focus_ring = if (!p.embedded and !static_disabled and !p.readonly) @as(?hooks.FocusRingConfig, .{}) else null,
                .cursor = .text,
                .disabled_cursor = .default,
                .tag = .input,
                .content_style = core_ui.BoxStyle{
                    .width = .{ .grow = .{} },
                    .height = .{ .grow = .{} },
                    .direction = .column,
                    .align_items = .stretch,
                    .min_height = 0,
                    .min_width = 0,
                },
            }), .{}).capture(&parts.shell).slots(.{
                // Selection underlay, append before text (vl.container): selection color blocks
                // glyphs when after. Before, selection was in overlay after text, paint order
                // inverted, selected text buried.
                .content = view.capture(&parts.underlay, view.box(.{ .style = layer_style }, .{
                    view.capture(&parts.selection, view.box(.{ .style = zero_box }, {})),
                })),
            })),
            // Helper / error text (dynamic always built, hidden when empty): fixed-height + own
            // text
            if (build_helper) view.capture(&parts.helper, view.setup(view.box(.{
                .style = .{ .height = .{ .px = 16 } },
                .visible = helper0.len > 0,
            }, {}), BoxText{ .style = styles.textareaHelperStyle(t, has_error), .content = helper0 }, BoxText.apply)) else null,
        }));
        errdefer cx.freeNode(wrapper);
        wrapper.meta.ownership.meta.component_name = "Textarea";
        wrapper.frame_state.state_bits.flags.disable_render_cache = true;
        try core_ui.bindScopeToNode(my_scope, wrapper);
        scope_bound = true;
        wrapper.addDebugState(@ptrCast(state));

        const label_text_node = parts.label;
        const textarea_node = parts.shell.root.?;
        // Line list layers stack in the content slot; it fills the frame (padding 0, borders
        // take no layout space), so its origin is the frame's.
        const surface = parts.underlay.parent.?;
        textarea_node.setFocusable(!disabled0);
        textarea_node.behavior.interaction.a11y = .{
            .role = .textarea,
            // Keep an unlabeled editor unlabeled; its value is exposed through
            // AXValue, not recycled as a changing accessible name.
            .label = if (label_text_node) |ln| ln.getText().?.content else "",
            .placeholder = placeholder0,
            .disabled = disabled0,
            .required = p.required,
            .readonly = p.readonly,
            .invalid = has_error,
            .multiline = true,
        };
        if (!static_disabled and !p.readonly) {
            textarea_node.behavior.interaction.text_input_client = textareaLiveClient(state);
        }
        state.input_container_node = textarea_node;
        state.selection_underlay_node = parts.underlay;
        state.selection_node = parts.selection;

        // VirtualList (callback component: rows built on-demand by textareaRenderItem;
        // container appended ready). Existing node skips view.mount: it has ambiguous cleanup
        // responsibility for *Node children (see Input's shell.node).
        const initial_lc = @max(@as(u32, 1), wm.displayLineCount());
        const vl = try virtual_list.VirtualList(.{ .item_count = initial_lc, .item_height = line_height, .overscan = 3 }).mountWithContext(my_scope, cx, @ptrCast(state), null, textareaRenderItem);
        _ = try core_ui.adoptChild(cx, allocator, surface, vl.container);
        vl.container.style.width = .{ .grow = .{} };
        vl.container.style.height = .{ .grow = .{} };
        vl.container.style.padding = Padding.symmetric(pad_v, pad);
        const vl_ext = try vl.container.style.ensureExtFallible(allocator);
        const textarea_inner_shadow_alpha: u8 = if (t.tokens.color.input_bg.r <= 64 and t.tokens.color.input_bg.g <= 64 and t.tokens.color.input_bg.b <= 64) 84 else 40;
        vl_ext.overflow_fade = .{
            .size = 10,
            .color = Color.rgba(0, 0, 0, textarea_inner_shadow_alpha),
            .edges = .{ .top = true, .bottom = true, .left = false, .right = false },
        };
        var overlay: *Node = undefined;
        var preedit_underline: *Node = undefined;
        var cursor_node: *Node = undefined;
        try view.mount(my_scope, cx, surface, .{
            // Overlay (IME underline + cursor, both above text)
            view.capture(&overlay, view.box(.{ .style = layer_style }, .{
                view.capture(&preedit_underline, view.box(.{ .style = zero_box }, {})),
                view.capture(&cursor_node, view.box(.{ .style = zero_box }, {})),
            })),
        });
        state.vl_state = vl.state;
        state.overlay_node = overlay;
        state.preedit_underline_node = preedit_underline;
        state.cursor_node = cursor_node;
        textarea_node.meta.per_frame.hooks.before_render.main = textareaBeforeRender;

        // Events (dynamic disable also installs, entry gated by state.disabled)
        if (!static_disabled and !p.readonly) {
            textarea_node.behavior.events.on_event = textareaFieldEventHandler;
            textarea_node.behavior.events.event_context = state;
        }

        const helper_text_node = parts.helper;

        if (chrome_dynamic) {
            const chrome = try my_scope.allocator.create(TextareaChrome);
            chrome.* = .{
                .state = state,
                .cx = cx,
                .tokens = t,
                .label = p.label_text,
                .helper = p.helper,
                .error_msg = p.error_msg,
                .placeholder = p.placeholder,
                .disabled = p.disabled,
                .invalid = invalid_frame,
                .wrapper = wrapper,
                .textarea_node = textarea_node,
                .field_h = textarea_height,
                .embedded = p.embedded,
                .label_node = label_text_node,
                .helper_node = helper_text_node,
                .shown_disabled = disabled0,
            };
            try my_scope.adoptResource(@ptrCast(chrome), TextareaChrome.destroy);
            // First sync apply (fail exits), then effect follows
            try chrome.apply(false);
            try my_scope.createEffect(chrome, TextareaChrome.effect);
        }

        // value is Model: external write enters doc via effect (first run same as initial,
        // short-circuit)
        try my_scope.createEffect(binding, TextareaBinding.valueEffect);

        return .{ .wrapper = wrapper, .input = textarea_node, .state = state, .value = value.asSignal() };
    }
};

test "textarea 用户编辑事务：压栈脱离重做栈后同一事务内撤销不泄漏" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer state.deinit();
    state.insertText("a");
    state.insertText("b");
    state.undo();
    try t.expectEqual(@as(u8, 1), state.redo_count);
    state.beginUserEdit();
    state.insertText("c");
    try t.expectEqual(@as(u8, 0), state.redo_count);
    state.undo();
    state.endUserEdit();
    try t.expect(state.undo_stash.isEmpty());
}

test "textarea 用户编辑事务：事务内历史被整体清空后，拒绝还原不会复活清空前的重做条目" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer state.deinit();
    state.insertText("a");
    state.insertText("b");
    state.undo();
    try t.expectEqual(@as(u8, 1), state.redo_count);
    state.beginUserEdit();
    state.insertText("c");
    try state.applyExternalText("x");
    try state.reconcileUserEdit("x", true);
    state.endUserEdit();
    try t.expectEqual(@as(u8, 0), state.redo_count);
    try t.expectEqual(@as(u8, 0), state.undo_count);
}

test "textarea 用户编辑事务：同一事务内先有一次已落地的编辑，后一次被拒只回滚它自己" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer state.deinit();
    state.insertText("x");
    state.insertText("y");
    state.undo();
    try t.expectEqual(@as(u8, 1), state.redo_count);
    state.beginUserEdit();
    state.insertText("a");
    state.settleUserEdit();
    state.insertText("b");
    try state.reconcileUserEdit("xa", true);
    state.endUserEdit();
    try t.expectEqualStrings("xa", state.getText());
    try t.expectEqual(@as(usize, 2), state.cursor.offset);
    try t.expectEqual(@as(u8, 2), state.undo_count);
    try t.expectEqual(@as(u8, 0), state.redo_count);
}

test "textarea 用户编辑事务：不经值绑定的事务结束时暂存清空，之后被拒还原不复活旧重做条目" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer state.deinit();
    state.insertText("x");
    state.insertText("y");
    state.undo();
    state.beginUserEdit();
    state.insertText("a");
    state.endUserEdit();
    try t.expect(state.undo_stash.isEmpty());
    state.beginUserEdit();
    state.insertText("b");
    try state.reconcileUserEdit("xa", true);
    state.endUserEdit();
    try t.expectEqual(@as(u8, 0), state.redo_count);
}

test "textarea event route commits complete long IME input once" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer state.deinit();
    const value = (@as([("中\n").len * (300)]u8, @bitCast(@as([300][("中\n").len]u8, @splat(("中\n").*)))) ++ "");
    _ = textareaEventHandler(.{ .ime_commit = .{ .text = value } }, &state);
    _ = textareaEventHandler(.{ .text_input = .{ .text = value } }, &state);
    try t.expectEqualStrings(value, state.getText());
}

test "textarea failed IME replacement retains document selection and undo history" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var doc = TextareaDocument.init(failing.allocator());
    defer doc.deinit();
    doc.setText("keep\nline");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator() };
    defer state.deinit();
    state.cursor.offset = doc.totalLength();
    state.cursor.anchor = 0;
    failing.fail_index = failing.alloc_index;
    state.handleImeCommit((@as([("x").len * (1000)]u8, @bitCast(@as([1000][("x").len]u8, @splat(("x").*)))) ++ ""));
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqualStrings("keep\nline", state.getText());
    try t.expectEqual(@as(?usize, 0), state.cursor.anchor);
    try t.expectEqual(@as(u8, 0), state.undo_count);
}

test "textarea IME insertion preserves composition model and history through every allocation failure" {
    const t = std.testing;
    for ([_]bool{ false, true }) |fail_model| {
        var succeeded = false;
        for (0..200) |failure| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var doc = TextareaDocument.init(if (fail_model) failing.allocator() else t.allocator);
            defer doc.deinit();
            doc.setText("keep tail");
            var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
            defer wm.deinit();
            var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = if (fail_model) t.allocator else failing.allocator() };
            defer s.deinit();
            s.cursor.offset = doc.totalLength();
            s.insertText("!");
            s.undo();
            s.cursor.offset = 4;
            s.cursor.anchor = 0;
            s.handleImePreedit("候选", 6);
            try t.expectEqual(@as(?usize, 0), s.cursor.anchor);
            const old_text = doc.text.items.ptr;
            const old_lines = doc.line_starts.items.ptr;
            const old_undo = s.undo_count;
            const old_redo = s.redo_count;
            const value = (@as([("中\n").len * (300)]u8, @bitCast(@as([300][("中\n").len]u8, @splat(("中\n").*)))) ++ "");
            failing.fail_index = failing.alloc_index + failure;
            failing.resize_fail_index = failing.resize_index;
            const result = s.handleImeCommitChecked(value);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |_| {
                succeeded = true;
            } else |_| {
                try t.expect(failing.has_induced_failure);
                try t.expectEqualStrings("keep tail", s.getText());
                try t.expectEqual(old_text, doc.text.items.ptr);
                try t.expectEqual(old_lines, doc.line_starts.items.ptr);
                try t.expectEqual(old_undo, s.undo_count);
                try t.expectEqual(old_redo, s.redo_count);
                try t.expectEqual(@as(usize, 4), s.cursor.offset);
                try t.expectEqual(@as(?usize, 0), s.cursor.anchor);
                try t.expect(s.imeIsComposing());
                try t.expectEqualStrings("候选", s.preeditText());
                try s.handleImeCommitChecked(value);
            }
            try t.expectEqualStrings(value ++ " tail", s.getText());
            try t.expectEqual(@as(usize, 301), doc.lineCount());
            try t.expect(s.consumeImePostCommitDuplicate(value));
            try t.expect(!s.consumeImePostCommitDuplicate(value));
            s.undo();
            try t.expectEqualStrings("keep tail", s.getText());
            s.redo();
            try t.expectEqualStrings(value ++ " tail", s.getText());
            if (succeeded) break;
        }
        try t.expect(succeeded);
    }
}

test "textarea failed deletion retains selected text and redo history" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    doc.setText("keep\ntail");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator() };
    defer s.deinit();
    s.cursor.offset = doc.totalLength();
    s.insertText("!");
    s.undo();
    s.cursor.anchor = 0;
    s.cursor.offset = 4;
    const undo_count = s.undo_count;
    const redo_count = s.redo_count;
    failing.fail_index = failing.alloc_index;
    s.deleteBackward();
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqualStrings("keep\ntail", s.getText());
    try t.expectEqual(undo_count, s.undo_count);
    try t.expectEqual(redo_count, s.redo_count);
    try t.expectEqual(@as(?usize, 0), s.cursor.anchor);
    try t.expectEqual(@as(usize, 4), s.cursor.offset);
}

test "textarea set and history restore survive every allocation failure" {
    const t = std.testing;
    for ([_]bool{ false, true }) |fail_model| {
        for (0..3) |operation| {
            var succeeded = false;
            for (0..100) |failure| {
                var failing = t.FailingAllocator.init(t.allocator, .{});
                var doc = TextareaDocument.init(if (fail_model) failing.allocator() else t.allocator);
                defer doc.deinit();
                const original = (@as([("keep\n").len * (80)]u8, @bitCast(@as([80][("keep\n").len]u8, @splat(("keep\n").*)))) ++ "");
                try doc.setTextChecked(original);
                var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
                defer wm.deinit();
                var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = if (fail_model) t.allocator else failing.allocator() };
                defer s.deinit();
                s.cursor.offset = original.len;
                s.cursor.anchor = 0;
                try s.insertTextChecked("x");
                if (operation == 2) s.undo();
                const old_text = try t.allocator.dupe(u8, doc.getText());
                defer t.allocator.free(old_text);
                const text_ptr = doc.text.items.ptr;
                const lines_ptr = doc.line_starts.items.ptr;
                const old_cursor = s.cursor.offset;
                const old_anchor = s.cursor.anchor;
                const old_undo = s.undo_count;
                const old_redo = s.redo_count;
                failing.fail_index = failing.alloc_index + failure;
                failing.resize_fail_index = failing.resize_index;
                switch (operation) {
                    0 => {
                        _ = s.setAccessibilityValue((@as([("new\n").len * (120)]u8, @bitCast(@as([120][("new\n").len]u8, @splat(("new\n").*)))) ++ ""));
                    },
                    1 => s.undo(),
                    2 => s.redo(),
                    else => unreachable,
                }
                failing.fail_index = std.math.maxInt(usize);
                failing.resize_fail_index = std.math.maxInt(usize);
                succeeded = s.undo_count != old_undo or s.redo_count != old_redo;
                if (!succeeded) {
                    try t.expect(failing.has_induced_failure);
                    try t.expectEqualStrings(old_text, doc.getText());
                    try t.expectEqual(text_ptr, doc.text.items.ptr);
                    try t.expectEqual(lines_ptr, doc.line_starts.items.ptr);
                    try t.expectEqual(old_cursor, s.cursor.offset);
                    try t.expectEqual(old_anchor, s.cursor.anchor);
                    switch (operation) {
                        0 => {
                            try t.expect(s.setAccessibilityValue((@as([("new\n").len * (120)]u8, @bitCast(@as([120][("new\n").len]u8, @splat(("new\n").*)))) ++ "")));
                        },
                        1 => s.undo(),
                        2 => s.redo(),
                        else => unreachable,
                    }
                }
                const expected = switch (operation) {
                    0 => (@as([("new\n").len * (120)]u8, @bitCast(@as([120][("new\n").len]u8, @splat(("new\n").*)))) ++ ""),
                    1 => original,
                    2 => "x",
                    else => unreachable,
                };
                try t.expectEqualStrings(expected, doc.getText());
                try t.expectEqual(@as(usize, if (operation == 0) 121 else if (operation == 1) 81 else 1), doc.lineCount());
                if (operation == 1) s.redo() else s.undo();
                try t.expectEqualStrings(old_text, doc.getText());
                if (succeeded) break;
            }
            try t.expect(succeeded);
        }
    }
}

test "textarea events notify same length history changes and keep failed edits silent" {
    const t = std.testing;
    const Observer = struct {
        calls: usize = 0,
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    var observer: Observer = .{};
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("old");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator(), .on_change = .{ .callback = Observer.notify, .context = &observer } };
    defer s.deinit();
    try t.expect(s.setAccessibilityValue("new"));
    try t.expectEqual(@as(usize, 1), observer.calls);
    _ = textareaEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true } } }, &s);
    try t.expectEqualStrings("old", s.getText());
    try t.expectEqual(@as(usize, 2), observer.calls);
    failing.fail_index = failing.alloc_index;
    _ = textareaEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = true } } }, &s);
    _ = textareaEventHandler(.{ .key_down = .{ .key = .@"return" } }, &s);
    _ = textareaEventHandler(.{ .key_down = .{ .key = .delete } }, &s);
    try t.expect(!s.setAccessibilityValue("failed"));
    try t.expectEqualStrings("old", s.getText());
    try t.expectEqual(@as(usize, 2), observer.calls);
    failing.fail_index = std.math.maxInt(usize);
    _ = textareaEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = true } } }, &s);
    try t.expectEqualStrings("new", s.getText());
    try t.expectEqual(@as(usize, 3), observer.calls);
}

test "textarea deletion variants require history allocation and no op preserves redo" {
    const t = std.testing;
    const operations = [_]*const fn (*TextareaState) void{
        TextareaState.deleteBackward,     TextareaState.deleteForward,
        TextareaState.deleteWordBackward, TextareaState.deleteWordForward,
        TextareaState.deleteToLineStart,
    };
    for (operations) |operation| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        var doc = TextareaDocument.init(t.allocator);
        defer doc.deinit();
        try doc.setTextChecked("keep\ntail");
        var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
        defer wm.deinit();
        var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator() };
        defer s.deinit();
        s.cursor.offset = 4;
        s.cursor.anchor = 0;
        failing.fail_index = failing.alloc_index;
        operation(&s);
        try t.expectEqualStrings("keep\ntail", s.getText());
        try t.expectEqual(@as(u8, 0), s.undo_count);
        try t.expectEqual(@as(?usize, 0), s.cursor.anchor);
        failing.fail_index = std.math.maxInt(usize);
        operation(&s);
        try t.expectEqualStrings("\ntail", s.getText());
        try t.expectEqual(@as(u8, 1), s.undo_count);
        s.undo();
        try t.expectEqualStrings("keep\ntail", s.getText());
        s.cursor.anchor = null;
        s.cursor.offset = 0;
        s.deleteBackward();
        s.deleteWordBackward();
        s.deleteToLineStart();
        s.cursor.offset = doc.totalLength();
        s.deleteForward();
        s.deleteWordForward();
        try t.expectEqual(@as(u8, 0), s.undo_count);
        try t.expectEqual(@as(u8, 1), s.redo_count);
        s.redo();
        try t.expectEqualStrings("\ntail", s.getText());
    }
}

test "textarea frame retries pending wrap without a width change" {
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
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator, .input_inner_w = 64 };
    defer state.deinit();
    var node: Node = .{ .id = 1, .tag = .box, .style = .{}, .children = .empty };
    node.setLayoutRect(.{ .x = 0, .y = 0, .w = 80, .h = 100 });
    node.behavior.events.event_context = &state;
    textareaBeforeRender(&node);
    try t.expectEqual(@as(f32, 64), state.input_inner_w);
    try t.expect(!wm.has_interpolated_lines);
    try t.expect(!wm.needs_rebuild);
    try t.expectEqual(@as(u32, 8), wm.total_display_lines);
}

test "textarea events honor reconversion range for preedit and commit" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    doc.setText("x漢字y");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer s.deinit();
    s.cursor.offset = 8;
    _ = textareaEventHandler(.{ .ime_preedit = .{ .text = "かんじ", .cursor_utf8_offset = 9, .replace_start_utf8 = 1, .replace_end_utf8 = 7 } }, &s);
    try t.expectEqualStrings("x漢字y", s.getText());
    _ = textareaEventHandler(.{ .ime_commit = .{ .text = "感じ" } }, &s);
    try t.expectEqualStrings("x感じy", s.getText());
    s.undo();
    try t.expectEqualStrings("x漢字y", s.getText());
}

test "textarea reconversion commit preserves candidate and both histories through allocation failure" {
    const t = std.testing;
    for ([_]bool{ false, true }) |fail_model| {
        var completed = false;
        for (0..150) |failure| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var doc = TextareaDocument.init(if (fail_model) failing.allocator() else t.allocator);
            defer doc.deinit();
            doc.setText("x漢字y");
            var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
            defer wm.deinit();
            var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = if (fail_model) t.allocator else failing.allocator() };
            defer s.deinit();
            s.cursor.offset = 8;
            s.insertText("!");
            s.undo();
            s.cursor.offset = 8;
            s.cursor.anchor = null;
            s.handleImePreeditReplace("候选", 6, 1, 7);
            const old_undo = s.undo_count;
            const old_redo = s.redo_count;
            const value = (@as([("新").len * (200)]u8, @bitCast(@as([200][("新").len]u8, @splat(("新").*)))) ++ "");
            failing.fail_index = failing.alloc_index + failure;
            failing.resize_fail_index = failing.resize_index;
            const result = s.handleImeCommitReplaceChecked(value, std.math.maxInt(u32), std.math.maxInt(u32));
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |_| {
                completed = true;
            } else |_| {
                try t.expect(failing.has_induced_failure);
                try t.expectEqualStrings("x漢字y", s.getText());
                try t.expectEqual(old_undo, s.undo_count);
                try t.expectEqual(old_redo, s.redo_count);
                try t.expect(s.ime_replacement != null);
                try t.expect(s.imeIsComposing());
                try t.expectEqualStrings("候选", s.preeditText());
                try t.expectEqual(@as(usize, 1), s.cursor.offset);
                try t.expectEqual(@as(?usize, 7), s.cursor.anchor);
                try s.handleImeCommitReplaceChecked(value, std.math.maxInt(u32), std.math.maxInt(u32));
            }
            try t.expectEqualStrings("x" ++ value ++ "y", s.getText());
            try t.expect(s.ime_replacement == null);
            try t.expect(s.consumeImePostCommitDuplicate(value));
            s.undo();
            try t.expectEqualStrings("x漢字y", s.getText());
            s.redo();
            try t.expectEqualStrings("x" ++ value ++ "y", s.getText());
            if (completed) break;
        }
        try t.expect(completed);
    }
}

test "textarea reconversion cancel display empty commit and explicit commit range" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    doc.setText("x漢字y");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer s.deinit();
    s.cursor.offset = 8;
    s.cursor.anchor = 7;
    s.handleImePreeditReplace("かんじ", 9, 1, 7);
    try t.expectEqualStrings("xかんじy", s.composeSegmentWithIme(doc.getText(), 1));
    s.handleImePreedit("", 0);
    try t.expectEqualStrings("x漢字y", s.getText());
    try t.expectEqual(@as(usize, 8), s.cursor.offset);
    try t.expectEqual(@as(?usize, 7), s.cursor.anchor);
    s.handleImePreeditReplace("候", 3, 2, 6);
    try s.handleImeCommitChecked("");
    try t.expectEqualStrings("xy", s.getText());
    s.undo();
    try t.expectEqualStrings("x漢字y", s.getText());
    try s.handleImeCommitReplaceChecked("Q", 1, 7);
    try t.expectEqualStrings("xQy", s.getText());
    s.undo();
    try t.expectEqualStrings("x漢字y", s.getText());
    try s.handleImeCommitReplaceChecked("", 1, 7);
    try t.expectEqualStrings("xy", s.getText());
    s.undo();
    try t.expectEqualStrings("x漢字y", s.getText());
}

test "IME rendered rows retain independent bytes across reconversion and model updates" {
    const t = std.testing;
    const Doc = @import("textarea_document.zig").TextareaDocument;
    const Map = @import("text_core").wrap_map.WrapMap(Doc);
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    const root = try core_ui.box(cx, .{}, .{});
    cx.root = root;
    const first = try core_ui.box(cx, .{}, .{});
    try root.appendChild(t.allocator, first);
    const second = try core_ui.box(cx, .{}, .{});
    try root.appendChild(t.allocator, second);
    var doc = Doc.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abc\ndefgh");
    var wm = Map.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer s.deinit();
    s.cursor.offset = doc.totalLength();
    s.handleImePreeditReplace("候选", 6, 1, 8);
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
    // Growing composition scratch must not invalidate a previously rendered row.
    s.handleImePreedit("候", 3);
    _ = try s.composeSegmentWithImeChecked((@as([("x").len * (6000)]u8, @bitCast(@as([6000][("x").len]u8, @splat(("x").*)))) ++ ""), 0);
    try t.expectEqualStrings("abc", first.getText().?.content);
    s.cancelImeComposition();
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
    const row = try core_ui.box(cx, .{}, .{});
    cx.root = row;
    var doc = Doc.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abc");
    var wm = Map.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer s.deinit();
    s.cursor.offset = 3;
    textareaRenderItem(row, 0, cx, &s);
    const old_ptr = row.getText().?.content.ptr;
    s.handleImePreedit("候选", 6);
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

test "textarea composition allocation failure preserves the retained row for retry" {
    const t = std.testing;
    var cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    const row = try core_ui.box(cx, .{}, .{});
    cx.root = row;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abc");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var s: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator() };
    defer s.deinit();
    s.cursor.offset = 3;
    s.handleImePreedit("候选", 6);
    textareaRenderItem(row, 0, cx, &s);
    try t.expectEqualStrings("abc候选", row.getText().?.content);
    try doc.setTextChecked((@as([("x").len * (6000)]u8, @bitCast(@as([6000][("x").len]u8, @splat(("x").*)))) ++ ""));
    s.dirty = false;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    textareaRenderItem(row, 0, cx, &s);
    try t.expect(failing.has_induced_failure);
    try t.expectEqualStrings("abc候选", row.getText().?.content);
    try t.expect(s.dirty);
    try t.expect(cx.next_redraw_delay_ns.? <= 16 * std.time.ns_per_ms);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    textareaRenderItem(row, 0, cx, &s);
    try t.expectEqualStrings("xxx候选" ++ (@as([("x").len * (5997)]u8, @bitCast(@as([5997][("x").len]u8, @splat(("x").*)))) ++ ""), row.getText().?.content);
    try t.expectEqualStrings((@as([("x").len * (6000)]u8, @bitCast(@as([6000][("x").len]u8, @splat(("x").*)))) ++ ""), s.getText());
}

test "independent textarea preserves long preedit and its grapheme cursor" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("xyz");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var s: TextareaState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .doc = &doc, .wrap_map = &wm };
    defer s.deinit();
    s.cursor.offset = 1;
    const candidate = (@as([("漢").len * (1000)]u8, @bitCast(@as([1000][("漢").len]u8, @splat(("漢").*)))) ++ "") ++ "👩‍💻";
    s.handleImePreedit(candidate, candidate.len - 1);
    try t.expectEqual(candidate.len, s.ime_preedit_len);
    try t.expectEqual(candidate.len, s.ime_cursor_utf8_offset);
    const display = try s.composeSegmentWithImeChecked("xyz", 1);
    try t.expectEqualStrings("x" ++ candidate ++ "yz", display);
    try t.expectEqualStrings("xyz", s.getText());
    s.cancelImeComposition();
    try t.expectEqualStrings("xyz", s.getText());
}

test "independent long preedit failure preserves reconversion and commits owned input once" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var doc = TextareaDocument.init(failing.allocator());
    defer doc.deinit();
    try doc.setTextChecked("x漢字y");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var s: TextareaState = .{ .io = @import("std").testing.io, .allocator = failing.allocator(), .doc = &doc, .wrap_map = &wm };
    defer s.deinit();
    s.cursor.offset = 8;
    s.cursor.anchor = 7;
    try s.handleImePreeditReplaceChecked("旧", 3, 1, 7);
    failing.fail_index = failing.alloc_index;
    const candidate = (@as([("漢").len * (1000)]u8, @bitCast(@as([1000][("漢").len]u8, @splat(("漢").*)))) ++ "");
    try t.expectError(error.OutOfMemory, s.handleImePreeditReplaceChecked(candidate, candidate.len, 0, 8));
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqualStrings("旧", s.preeditText());
    try t.expectEqual(@as(usize, 1), s.cursor.offset);
    try t.expectEqual(@as(?usize, 7), s.cursor.anchor);
    try t.expectEqual(@as(usize, 1), s.ime_replacement.?.start);
    try s.handleImePreeditReplaceChecked(candidate, candidate.len, 0, 8);
    try s.handleImePreeditChecked(s.preeditText()[3..], candidate.len - 3);
    try t.expectEqualStrings(candidate[3..], s.preeditText());
    try s.handleImeCommitChecked(s.preeditText());
    try t.expectEqualStrings(candidate[3..], s.getText());
    try t.expect(s.consumeImePostCommitDuplicate(candidate[3..]));
    s.undo();
    try t.expectEqualStrings("x漢字y", s.getText());
    s.redo();
    try t.expectEqualStrings(candidate[3..], s.getText());
}

// ========== Value binding & surrounding dynamics (docs/SIGNAL_API_DESIGN.md @4.8) ==========

const TaEnv = struct {
    cx: *Cx,
    scope: *Scope,

    fn init() !TaEnv {
        const cx = try Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.root = try box(cx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
        return .{ .cx = cx, .scope = try Scope.init(std.testing.allocator, null, cx.owner) };
    }

    fn deinit(self: TaEnv) void {
        self.scope.dispose();
        self.cx.deinit();
    }

    fn send(r: TextareaResult, ev: Event) EventResult {
        return textareaEventHandler(ev, @ptrCast(r.state));
    }
};

test "Textarea value: 打字写回 signal；外部写入进文档且不可撤销；组字中推迟" {
    const env = try TaEnv.init();
    defer env.deinit();
    const Spy = struct {
        n: usize = 0,
        fn f(self: *@This(), _: []const u8) void {
            self.n += 1;
        }
    };
    var spy = Spy{};
    const v = try env.scope.createText("a", .{});
    const r = try Textarea(.{ .value = v, .on_change = env.cx.on(Spy, &spy, Spy.f) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.wrapper);
    try std.testing.expectEqualStrings("a", r.state.getText());

    _ = TaEnv.send(r, .{ .text_input = .{ .text = "b" } });
    try std.testing.expectEqualStrings("ab", v.peek());
    try std.testing.expectEqual(@as(usize, 1), spy.n);

    v.set("line1\nline2");
    try std.testing.expectEqualStrings("line1\nline2", r.state.getText());
    try std.testing.expectEqual(@as(usize, 1), spy.n);
    _ = TaEnv.send(r, .{ .key_down = .{ .key = .z, .modifiers = .{ .super = true } } });
    try std.testing.expectEqualStrings("line1\nline2", v.peek());

    _ = TaEnv.send(r, .{ .ime_preedit = .{ .text = "ni", .cursor_utf8_offset = 2 } });
    v.set("external");
    try std.testing.expectEqualStrings("line1\nline2", r.state.getText());
    _ = TaEnv.send(r, .{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } });
    try std.testing.expectEqualStrings("external", r.state.getText());

    _ = TaEnv.send(r, .{ .ime_preedit = .{ .text = "ni", .cursor_utf8_offset = 2 } });
    v.set("lost");
    _ = TaEnv.send(r, .{ .ime_commit = .{ .text = "你" } });
    try std.testing.expectEqualStrings("external你", r.state.getText());
    try std.testing.expectEqualStrings("external你", v.peek());
}

test "Textarea value: ui.split 拒绝时文档退回数据源" {
    const env = try TaEnv.init();
    defer env.deinit();
    const Parent = struct {
        sig: *Signal([]const u8),
        fn write(_: *@This(), _: []const u8) void {}
    };
    var parent = Parent{ .sig = try env.scope.createText("keep", .{}) };
    const r = try Textarea(.{ .value = reactive.split(parent.sig, env.cx.on(Parent, &parent, Parent.write)) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.wrapper);
    _ = TaEnv.send(r, .{ .text_input = .{ .text = "x" } });
    try std.testing.expectEqualStrings("keep", r.state.getText());
}

// ---------- User edit rewritten/rejected by ui.split: fix in place (binding.zig onBufferChanged)
// ----------

const TaUpperParent = struct {
    sig: *Signal([]const u8),
    accept: bool = true,
    reject_lower: bool = false,
    buf: [256]u8 = undefined,
    fn write(self: *@This(), x: []const u8) void {
        if (!self.accept) return;
        if (self.reject_lower) {
            for (x) |c| if (std.ascii.isLower(c)) return;
        }
        const n = @min(x.len, self.buf.len);
        for (x[0..n], 0..) |c, i| self.buf[i] = std.ascii.toUpper(c);
        self.sig.set(self.buf[0..n]);
    }
};

const ta_undo_key = Event{ .key_down = .{ .key = .z, .modifiers = .{ .super = true } } };
const ta_redo_key = Event{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = true } } };

fn expectTaCaret(r: TextareaResult, text: []const u8, cursor: usize, anchor: ?usize) !void {
    try std.testing.expectEqualStrings(text, r.state.getText());
    try std.testing.expectEqual(cursor, r.state.cursor.offset);
    try std.testing.expectEqual(anchor, r.state.cursor.anchor);
}

test "Textarea value: split 大写化中间插入——光标留在插入点后，撤销回到编辑前（batch 内外）" {
    inline for (.{ false, true }) |batched| {
        const env = try TaEnv.init();
        defer env.deinit();
        var parent = TaUpperParent{ .sig = try env.scope.createText("AB\nCD", .{}) };
        const r = try Textarea(.{ .value = reactive.split(parent.sig, env.cx.on(TaUpperParent, &parent, TaUpperParent.write)) }).mountResult(env.scope, env.cx);
        defer env.cx.freeNode(r.wrapper);
        r.state.cursor.offset = 1;

        if (batched) env.cx.owner.beginBatch();
        _ = TaEnv.send(r, .{ .text_input = .{ .text = "x" } });
        try expectTaCaret(r, "AXB\nCD", 2, null);
        _ = TaEnv.send(r, .{ .key_down = .{ .key = .@"return" } });
        _ = TaEnv.send(r, .{ .text_input = .{ .text = "yz" } });
        try expectTaCaret(r, "AX\nYZB\nCD", 5, null);
        if (batched) env.cx.owner.endBatch();
        try expectTaCaret(r, "AX\nYZB\nCD", 5, null);
        try std.testing.expectEqualStrings("AX\nYZB\nCD", parent.sig.peek());
        try std.testing.expectEqual(@as(u8, 3), r.state.undo_count);

        _ = TaEnv.send(r, ta_undo_key);
        try expectTaCaret(r, "AX\nB\nCD", 3, null);
        try std.testing.expectEqualStrings("AX\nB\nCD", parent.sig.peek());
        _ = TaEnv.send(r, ta_undo_key);
        _ = TaEnv.send(r, ta_undo_key);
        try expectTaCaret(r, "AB\nCD", 1, null);
        _ = TaEnv.send(r, ta_redo_key);
        try expectTaCaret(r, "AXB\nCD", 2, null);
        try std.testing.expectEqualStrings("AXB\nCD", parent.sig.peek());
    }
}

test "Textarea value: split 拒绝——选区回到编辑前、不留撤销条目；被拒的撤销把栈还原（batch 内外）" {
    inline for (.{ false, true }) |batched| {
        const env = try TaEnv.init();
        defer env.deinit();
        var parent = TaUpperParent{ .sig = try env.scope.createText("AB\nC", .{}), .reject_lower = true };
        const r = try Textarea(.{ .value = reactive.split(parent.sig, env.cx.on(TaUpperParent, &parent, TaUpperParent.write)) }).mountResult(env.scope, env.cx);
        defer env.cx.freeNode(r.wrapper);

        if (batched) env.cx.owner.beginBatch();
        r.state.cursor.offset = 1;
        _ = TaEnv.send(r, .{ .text_input = .{ .text = "x" } });
        try expectTaCaret(r, "AB\nC", 1, null);
        try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
        r.state.cursor.anchor = 1;
        r.state.cursor.offset = 4;
        _ = TaEnv.send(r, .{ .text_input = .{ .text = "q" } });
        try expectTaCaret(r, "AB\nC", 4, 1);
        try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);
        r.state.cursor.anchor = null;
        _ = TaEnv.send(r, .{ .text_input = .{ .text = "D" } });
        try expectTaCaret(r, "AB\nCD", 5, null);
        if (batched) env.cx.owner.endBatch();
        try std.testing.expectEqualStrings("AB\nCD", parent.sig.peek());
        try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);

        parent.accept = false;
        _ = TaEnv.send(r, .{ .key_down = .{ .key = .delete } });
        try expectTaCaret(r, "AB\nCD", 5, null);
        try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);
        _ = TaEnv.send(r, ta_undo_key);
        try expectTaCaret(r, "AB\nCD", 5, null);
        try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);
        try std.testing.expectEqual(@as(u8, 0), r.state.redo_count);
        parent.accept = true;
        _ = TaEnv.send(r, ta_undo_key);
        try expectTaCaret(r, "AB\nC", 4, null);
    }
}

test "Textarea value: 组字中有推迟的外部写入时，AX 写值以 AX 的值为准" {
    inline for (.{ false, true }) |batched| {
        const env = try TaEnv.init();
        defer env.deinit();
        const v = try env.scope.createText("old", .{});
        const r = try Textarea(.{ .value = v }).mountResult(env.scope, env.cx);
        defer env.cx.freeNode(r.wrapper);
        _ = TaEnv.send(r, .{ .ime_preedit = .{ .text = "ni", .cursor_utf8_offset = 2 } });
        v.set("external");
        try std.testing.expectEqualStrings("old", r.state.getText());
        if (batched) env.cx.owner.beginBatch();
        try std.testing.expect(r.state.setAccessibilityValue("typed\nline"));
        try std.testing.expectEqualStrings("typed\nline", r.state.getText());
        if (batched) env.cx.owner.endBatch();
        try std.testing.expectEqualStrings("typed\nline", r.state.getText());
        try std.testing.expectEqualStrings("typed\nline", v.peek());
        try std.testing.expect(!r.state.imeIsComposing());
        _ = TaEnv.send(r, ta_undo_key);
        try std.testing.expectEqualStrings("old", r.state.getText());
        try std.testing.expectEqualStrings("old", v.peek());
    }
}

test "Textarea value: split 拒绝——重做栈与栈满淘汰的撤销条目完整还原" {
    const env = try TaEnv.init();
    defer env.deinit();
    var parent = TaUpperParent{ .sig = try env.scope.createText("A", .{}), .reject_lower = true };
    const r = try Textarea(.{ .value = reactive.split(parent.sig, env.cx.on(TaUpperParent, &parent, TaUpperParent.write)) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.wrapper);
    const s = r.state;
    s.cursor.offset = 1;

    _ = TaEnv.send(r, .{ .text_input = .{ .text = "B" } });
    _ = TaEnv.send(r, ta_undo_key);
    try expectTaCaret(r, "A", 1, null);
    try std.testing.expectEqual(@as(u8, 1), s.redo_count);
    const redo_ptr = s.redo_stack[0].text.?.ptr;
    _ = TaEnv.send(r, .{ .text_input = .{ .text = "c" } });
    try expectTaCaret(r, "A", 1, null);
    try std.testing.expectEqual(@as(u8, 1), s.redo_count);
    try std.testing.expectEqual(redo_ptr, s.redo_stack[0].text.?.ptr);
    _ = TaEnv.send(r, ta_redo_key);
    try expectTaCaret(r, "AB", 2, null);

    while (s.undo_count < 32) _ = TaEnv.send(r, .{ .text_input = .{ .text = "X" } });
    _ = TaEnv.send(r, .{ .text_input = .{ .text = "X" } });
    const bottom_ptr = s.undo_stack[0].text.?.ptr;
    const top_ptr = s.undo_stack[31].text.?.ptr;
    const len_before = s.getText().len;
    _ = TaEnv.send(r, .{ .text_input = .{ .text = "z" } });
    try std.testing.expectEqual(len_before, s.getText().len);
    try std.testing.expectEqual(@as(u8, 32), s.undo_count);
    try std.testing.expectEqual(bottom_ptr, s.undo_stack[0].text.?.ptr);
    try std.testing.expectEqual(top_ptr, s.undo_stack[31].text.?.ptr);
    try std.testing.expect(s.undo_stash.isEmpty());

    // Accepted edit clears redo stack, later rejected edits can't revive old redo entries
    _ = TaEnv.send(r, ta_undo_key);
    try std.testing.expectEqual(@as(u8, 1), s.redo_count);
    _ = TaEnv.send(r, .{ .text_input = .{ .text = "Q" } });
    try std.testing.expectEqual(@as(u8, 0), s.redo_count);
    _ = TaEnv.send(r, .{ .text_input = .{ .text = "q" } });
    try std.testing.expectEqual(@as(u8, 0), s.redo_count);
}

test "Textarea value: IME 提交被大写化光标在提交后；外部写入语义不变；AX 写值被改写" {
    const env = try TaEnv.init();
    defer env.deinit();
    var parent = TaUpperParent{ .sig = try env.scope.createText("AB", .{}) };
    const r = try Textarea(.{ .value = reactive.split(parent.sig, env.cx.on(TaUpperParent, &parent, TaUpperParent.write)) }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.wrapper);

    r.state.cursor.offset = 1;
    env.cx.owner.beginBatch();
    _ = TaEnv.send(r, .{ .ime_preedit = .{ .text = "x", .cursor_utf8_offset = 1 } });
    _ = TaEnv.send(r, .{ .ime_commit = .{ .text = "xy" } });
    try expectTaCaret(r, "AXYB", 3, null);
    env.cx.owner.endBatch();
    try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);

    parent.sig.set("one\ntwo");
    try expectTaCaret(r, "one\ntwo", 7, null);
    try std.testing.expectEqual(@as(u8, 0), r.state.undo_count);

    try std.testing.expect(r.state.setAccessibilityValue("three"));
    try expectTaCaret(r, "THREE", 5, null);
    try std.testing.expectEqualStrings("THREE", parent.sig.peek());
    try std.testing.expectEqual(@as(u8, 1), r.state.undo_count);
    r.state.undo();
    try std.testing.expectEqualStrings("one\ntwo", r.state.getText());
}

test "Textarea chrome: 标签 / 错误 / 禁用来自 signal" {
    const env = try TaEnv.init();
    defer env.deinit();
    const label = try env.scope.createText("Notes", .{});
    const err = try env.scope.createText("", .{});
    const d = try env.scope.createSignal(bool, false);
    const v = try env.scope.createText("", .{});
    const r = try Textarea(.{ .value = v, .label_text = label, .error_msg = err, .disabled = d, .rows = 3 }).mountResult(env.scope, env.cx);
    defer env.cx.freeNode(r.wrapper);
    const a11y = &r.input.behavior.interaction.a11y.?;
    try std.testing.expectEqualStrings("Notes", a11y.label.?);
    const h0 = r.wrapper.style.height.px;

    err.set("Required");
    try std.testing.expect(r.state.has_error and a11y.invalid);
    try std.testing.expectEqual(h0 + helper_row_h, r.wrapper.style.height.px);
    label.set("");
    try std.testing.expectEqual(h0 + helper_row_h - label_row_h, r.wrapper.style.height.px);

    d.set(true);
    try std.testing.expect(a11y.disabled);
    try std.testing.expectEqual(EventResult.ignored, TaEnv.send(r, .{ .text_input = .{ .text = "x" } }));
    try std.testing.expectEqualStrings("", v.peek());
    d.set(false);
    _ = TaEnv.send(r, .{ .text_input = .{ .text = "x" } });
    try std.testing.expectEqualStrings("x", v.peek());
}

test "textarea: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("textarea", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return (try Textarea(.{ .value = "hello\nworld", .label_text = "Notes", .helper = "h", .width = 300 }).mountResult(scope, cx)).wrapper;
        }
    }.m);
}

// Reference-checked OOM sweep (see oom_sweep.zig): a mount that reports success must look exactly
// like the uninjected mount; `check` also pins the states the reference was given.
test "textarea(error+disabled): mount 成功即外观完整，任意分配点失败不假成功（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMountVerified("textarea(error+disabled)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const err_msg = try scope.createText("Required", .{});
            const disabled = try scope.createSignal(bool, false);
            return (try Textarea(.{ .value = "a\nb", .label_text = "Notes", .error_msg = err_msg, .disabled = disabled, .width = 240 }).mountResult(scope, cx)).wrapper;
        }
    }.m, struct {
        fn invalidFrame(n: *Node) bool {
            if (n.style.border.width > 0 and Color.eql(theme.dark.tokens.color.danger, n.style.border.color)) return true;
            for (n.children.items) |c| if (invalidFrame(c)) return true;
            return false;
        }
        fn check(root: *Node) anyerror!void {
            // the error message drives the frame's :invalid border at mount
            try std.testing.expect(invalidFrame(root));
        }
    }.check);
}

test "textarea(dynamic): mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("textarea(dynamic)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const v = try scope.createText("a\nb", .{});
            const label = try scope.createText("L", .{});
            const ph = try scope.createText("type", .{});
            const d = try scope.createSignal(bool, true);
            return (try Textarea(.{ .value = v, .label_text = label, .placeholder = ph, .disabled = d }).mountResult(scope, cx)).wrapper;
        }
    }.m);
}

test "textarea accessibility lines use current wrapping and reject pending layout" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abcdefgh\nx");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.char_width = 8;
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(32, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer state.deinit();
    const wrapped = try textareaA11yLines(&state, t.allocator);
    defer t.allocator.free(wrapped);
    try t.expectEqualSlices(u32, &.{ 0, 4, 9, 10 }, wrapped);
    wm.setWrapWidth(64, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    const wide = try textareaA11yLines(&state, t.allocator);
    defer t.allocator.free(wide);
    try t.expectEqualSlices(u32, &.{ 0, 9, 10 }, wide);
    wm.has_interpolated_lines = true;
    try t.expectError(error.AccessibilityLayoutPending, textareaA11yLines(&state, t.allocator));
    wm.has_interpolated_lines = false;
    wm.setEnabled(false, &doc);
    try doc.setTextChecked("");
    const empty = try textareaA11yLines(&state, t.allocator);
    defer t.allocator.free(empty);
    try t.expectEqualSlices(u32, &.{0}, empty);
}

test "textarea accessibility teardown keeps scroll cells alive through owned scope disposal" {
    const allocator = std.testing.allocator;
    const cx = try Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(320, 240);
    const root = try box(cx, .{ .width = .{ .px = 320 }, .height = .{ .px = 240 } }, .{});
    cx.root = root;
    const scope = try Scope.init(allocator, null, cx.owner);
    cx.root_scope = scope;
    const mounted = try Textarea(.{ .value = "hello wrapped world", .width = 100 }).mountResult(scope, cx);
    try root.appendChild(allocator, mounted.wrapper);
    try std.testing.expect(cx.scroll_ctx_cells.items.len > 0);
    // Cx owns scope teardown. External scope.dispose() before Cx.deinit()
    // does not exercise this lifetime order and previously hid the VM crash.
}

test "accessibility caret geometry Textarea retains blank and terminal rows" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core_ui.FontSystem.init(t.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("A\n\n");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.rebuildAll(&doc);
    var state: TextareaState = .{ .io = @import("std").testing.io, .doc = &doc, .wrap_map = &wm, .allocator = t.allocator, .cx_ref = cx, .font_size = 16, .line_height = 20, .container_x = 11, .container_y = 13, .padding_h = 7, .padding_v = 5 };
    defer state.deinit();
    const owned = try textareaA11yCarets(&state, t.allocator);
    defer t.allocator.free(owned);
    try t.expectEqual(@as(usize, 4), owned.len);
    try t.expectEqual(@as(u32, 2), owned[2].offset);
    try t.expectEqual(@as(u32, 3), owned[3].offset);
    try t.expectEqual(@as(f32, 38), owned[2].rect.y);
    try t.expectEqual(@as(f32, 58), owned[3].rect.y);
    try t.expectEqual(@as(f32, 18), owned[2].rect.x);
    try t.expectEqual(@as(f32, 0), owned[3].rect.width);
    try t.expectEqual(@as(f32, 20), owned[3].rect.height);
    const boxes = try textareaA11yGeometry(&state, t.allocator);
    defer t.allocator.free(boxes);
    try t.expectEqual(@as(usize, 1), boxes.len);
    try t.expectEqual(@as(u32, 0), boxes[0].start);
    try t.expectEqual(@as(u32, 1), boxes[0].end);
    state.wrap_map.enabled = true;
    state.wrap_map.has_interpolated_lines = true;
    try t.expectError(error.AccessibilityLayoutPending, textareaA11yCarets(&state, t.allocator));
}

test "a11y row geometry Textarea preserves blank terminal and wrapped spans" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("A\n\n");
    var map = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer map.deinit();
    var state: TextareaState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .doc = &doc, .wrap_map = &map, .container_x = 11, .container_y = 13, .padding_h = 7, .padding_v = 5, .input_inner_w = 70, .line_height = 20 };
    const rows = try textareaA11yRows(&state, t.allocator);
    defer t.allocator.free(rows);
    try t.expectEqual(@as(usize, 3), rows.len);
    try t.expectEqual(@as(u32, 2), rows[1].start);
    try t.expectEqual(@as(u32, 3), rows[1].end);
    try t.expectEqual(@as(u32, 3), rows[2].start);
    try t.expectEqual(rows[2].start, rows[2].end);
    try t.expectEqual(@as(f32, 18), rows[1].rect.x);
    try t.expectEqual(@as(f32, 38), rows[1].rect.y);
    try t.expectEqual(@as(f32, 70), rows[1].rect.width);
    try doc.setTextChecked("abcdefgh\nx");
    map.char_width = 8;
    map.setEnabled(true, &doc);
    map.setWrapWidth(32, &doc);
    _ = map.rewrapInterpolatedAll(&doc);
    const wrapped = try textareaA11yRows(&state, t.allocator);
    defer t.allocator.free(wrapped);
    try t.expectEqual(@as(usize, 3), wrapped.len);
    try t.expectEqual(@as(u32, 0), wrapped[0].start);
    try t.expectEqual(@as(u32, 4), wrapped[0].end);
    try t.expectEqual(@as(u32, 4), wrapped[1].start);
    try t.expectEqual(@as(u32, 9), wrapped[1].end);
    try t.expectEqual(@as(u32, 9), wrapped[2].start);
    try t.expectEqual(@as(u32, 10), wrapped[2].end);
    map.has_interpolated_lines = true;
    try t.expectError(error.AccessibilityLayoutPending, textareaA11yRows(&state, t.allocator));
}

test "Textarea Home End navigation retains shift anchor and UTF8 offsets" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    doc.setText("abc\n你de\nxyz");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    wm.rebuildAll(&doc);
    var state: TextareaState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .doc = &doc, .wrap_map = &wm };
    defer state.deinit();
    state.cursor.offset = 7;
    try t.expect(state.handleKeyDown(.home, .{}));
    try t.expectEqual(@as(usize, 4), state.cursor.offset);
    try t.expect(state.handleKeyDown(.end, .{ .shift = true }));
    try t.expectEqual(@as(usize, 9), state.cursor.offset);
    try t.expectEqual(@as(?usize, 4), state.cursor.anchor);
    try t.expect(state.handleKeyDown(.home, .{ .ctrl = true, .shift = true }));
    try t.expectEqual(@as(usize, 0), state.cursor.offset);
    try t.expectEqual(@as(?usize, 4), state.cursor.anchor);
    try t.expect(state.handleKeyDown(.end, .{ .ctrl = true }));
    try t.expectEqual(doc.totalLength(), state.cursor.offset);
    try t.expectEqual(@as(?usize, null), state.cursor.anchor);
}

test "IME textarea surrounding deletion preserves selected bytes and cursor direction" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.insertAt(0, "A你SEL好Z");
    var wrap = TextareaWrapMap.init(t.allocator, t.io);
    defer wrap.deinit();
    var state: TextareaState = .{ .io = t.io, .allocator = t.allocator, .doc = &doc, .wrap_map = &wrap };
    defer state.deinit();
    state.cursor.offset = 4;
    state.cursor.anchor = 7;
    try state.handleImeDeleteSurrounding(3, 3);
    try t.expectEqualStrings("ASELZ", state.getText());
    try t.expectEqual(@as(usize, 1), state.cursor.offset);
    try t.expectEqual(@as(?usize, 4), state.cursor.anchor);
    try state.handleImeDeleteSurrounding(2, 0);
    try t.expectEqualStrings("ASELZ", state.getText());
    state.handleImePreedit("你好吗", 3);
    state.setImeAttributes(false, 6);
    try t.expect(!state.ime_cursor_visible);
    try t.expectEqual(@as(usize, 3), state.effectiveImeCursorOffset());
    state.clearImePreedit();
    try t.expect(state.ime_cursor_visible);
}

test "Textarea placeholder paints only while document is empty and never becomes its value" {
    const t = std.testing;
    const cx = try Cx.init(t.allocator, t.io);
    defer cx.deinit();
    const scope = try Scope.init(t.allocator, null, cx.owner);
    defer scope.dispose();
    const result = try Textarea(.{ .placeholder = "Write a longer message…", .width = 320 }).mountResult(scope, cx);
    defer cx.freeNode(result.wrapper);
    const row = try core_ui.box(cx, .{}, .{});
    defer cx.freeNode(row);
    textareaRenderItem(row, 0, cx, result.state);
    try t.expectEqualStrings("Write a longer message…", row.getText().?.content);
    try t.expectEqualStrings("", result.value.?.peek());
    result.value.?.set("Actual content");
    textareaRenderItem(row, 0, cx, result.state);
    try t.expectEqualStrings("Actual content", row.getText().?.content);
}
