const ImeReplacement = @import("ime_replacement.zig").ImeReplacement;
const ImeText = @import("ime_text.zig").ImeText;
/// Textarea，独立多行文本编辑组件
///
/// 完全独立于 TextInputState，直接使用 TextareaDocument + DocCursor + WrapMap。
/// 支持：多行编辑、软换行、IME 中文输入、选区、Undo/Redo、VirtualList 虚拟滚动。
const std = @import("std");
const Allocator = std.mem.Allocator;
const core_ui = @import("../../core.zig");
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
const Scope = @import("../../reactive.zig").Scope;
const hooks = @import("../../hooks.zig");
const recipe_mod = @import("../../recipe.zig");
const editable_block = @import("../editable_block/mod.zig");
const styles = @import("styles.zig");
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

// ============================================================================
// Undo Entry
// ============================================================================

const UndoEntry = struct {
    text: ?[]const u8 = null,
    cursor_offset: usize = 0,
    anchor: ?usize = null,

    fn deinit(self: *UndoEntry, allocator: Allocator) void {
        if (self.text) |t| allocator.free(t);
        self.text = null;
    }
};

// ============================================================================
// TextareaState
// ============================================================================

pub const TextareaState = struct {
    // ===== 核心数据模型 =====
    doc: *TextareaDocument,
    cursor: DocCursor(TextareaDocument) = .{},
    /// The same logical byte can have two visual carets at a bidi boundary.
    cursor_affinity: text_coordinates.Affinity = .downstream,
    /// Sticky physical x for repeated Up/Down navigation.
    preferred_visual_x: ?f32 = null,
    wrap_map: *TextareaWrapMap,
    allocator: Allocator,

    // ===== Undo/Redo =====
    undo_stack: [32]UndoEntry = [_]UndoEntry{.{}} ** 32,
    undo_count: u8 = 0,
    redo_stack: [32]UndoEntry = [_]UndoEntry{.{}} ** 32,
    redo_count: u8 = 0,

    // ===== IME =====
    ime_preedit: ImeText = .{},
    ime_preedit_len: usize = 0,
    ime_cursor_utf8_offset: usize = 0,
    /// Persistent composed display text. Dynamic storage avoids truncating a
    /// long wrapped segment before/after the preedit insertion point.
    ime_render_buffer: std.ArrayListUnmanaged(u8) = .{},
    ime_phase: ImeComposePhase = .idle,
    ime_pending_commit: ImeText = .{},
    ime_replacement: ?ImeReplacement = null,
    ime_selection_highlight: bool = false,

    // ===== 渲染节点引用 =====
    cursor_node: ?*Node = null,
    selection_node: ?*Node = null,
    preedit_underline_node: ?*Node = null,
    overlay_node: ?*Node = null,
    /// 选区底层(必须画在文本之下,否则选区色块盖住字形)
    selection_underlay_node: ?*Node = null,
    input_container_node: ?*Node = null,
    focus_ring_host: ?*Node = null,
    /// Mixed bidi selections can produce several rectangles per display line,
    /// so this storage must not impose a line/run-count ceiling.
    extra_sel_nodes: std.ArrayListUnmanaged(*Node) = .{},
    extra_preedit_nodes: std.ArrayListUnmanaged(*Node) = .{},

    // ===== VirtualList =====
    vl_state: ?*VirtualListState = null,

    // ===== 焦点/交互 =====
    focused: bool = false,
    /// 光标闪烁相位（与 TextInputState 共用 caret_blink.CaretBlink）。
    /// 这里原本是一份与 state.zig 逐字节相同的复制实现。
    blink: caret_blink.CaretBlink = .{},
    last_blink_visible: bool = true,
    is_dragging: bool = false,
    suspend_drag_until_mouse_up: bool = false,
    last_mouse_down_instant: ?std.time.Instant = null,
    last_mouse_down_pos: [2]f32 = .{ 0, 0 },
    consecutive_mouse_downs: u8 = 0,
    hover_signal: ?*Signal(bool) = null,
    has_error: bool = false,
    dirty: bool = false,

    // ===== 度量 =====
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

    // ===== 外部引用 =====
    cx_ref: ?*Cx = null,
    tokens: *const ThemeTokens = &theme.dark,
    placeholder_text: ?[]const u8 = null,

    // ===== 回调 =====
    on_change: ?core_ui.HandlerRef = null,

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
        const start_lc = self.doc.offsetToLineCol(selection.start);
        const end_lc = self.doc.offsetToLineCol(selection.end);
        var first = self.wrap_map.bufferToDisplay(start_lc.line, start_lc.col).display_line;
        var last = self.wrap_map.bufferToDisplay(end_lc.line, end_lc.col).display_line;

        // An exclusive end exactly at a soft-wrap boundary belongs to the
        // preceding segment, not to an empty range at the next segment.
        if (selection.end > 0 and last > first) {
            const last_seg = safeSegRange(self.doc, self.wrap_map.displayLineInfo(last, self.doc));
            if (last_seg.start == selection.end) last -= 1;
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

        const text = self.doc.getText();
        var display_line = first;
        while (true) {
            const seg = safeSegRange(self.doc, self.wrap_map.displayLineInfo(display_line, self.doc));
            const lo = @max(selection.start, seg.start);
            const hi = @min(selection.end, seg.end);
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

    // ===== 文本操作 =====

    pub fn getText(self: *const TextareaState) []const u8 {
        return self.doc.getText();
    }

    pub fn setAccessibilitySelection(self: *TextareaState, start_utf8: u32, end_utf8: u32) bool {
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

    pub fn setAccessibilityValue(self: *TextareaState, value: []const u8) bool {
        var prepared = self.doc.prepareReplace(0, self.doc.totalLength(), value) catch return false;
        defer prepared.deinit();
        self.pushUndoChecked() catch return false;
        prepared.commit();
        self.ime_replacement = null;
        self.cancelImeComposition();
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

    // ===== 光标/选区 =====

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
        // 移到 display line（wrap 段）的开头，不是 buffer line 开头
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
        // 移到 display line（wrap 段）的末尾，不是 buffer line 末尾
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

    /// 按 display line 移动（结合 WrapMap）
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
        self.ime_render_buffer.deinit(self.allocator);
        self.extra_sel_nodes.deinit(self.allocator);
        self.extra_preedit_nodes.deinit(self.allocator);
    }

    fn pushUndoChecked(self: *TextareaState) !void {
        const txt = try self.allocator.dupe(u8, self.doc.getText());
        const entry = UndoEntry{ .text = txt, .cursor_offset = self.cursor.offset, .anchor = self.cursor.anchor };
        if (self.undo_count < 32) {
            self.undo_stack[self.undo_count] = entry;
            self.undo_count += 1;
        } else {
            self.undo_stack[0].deinit(self.allocator);
            var i: usize = 0;
            while (i < 31) : (i += 1) self.undo_stack[i] = self.undo_stack[i + 1];
            self.undo_stack[31] = entry;
        }
        var j: u8 = 0;
        while (j < self.redo_count) : (j += 1) self.redo_stack[j].deinit(self.allocator);
        self.redo_count = 0;
    }

    pub fn undo(self: *TextareaState) void {
        if (self.ime_replacement != null) {
            self.cancelImeComposition();
            return;
        }
        self.restoreHistory(false) catch return;
    }

    pub fn redo(self: *TextareaState) void {
        if (self.ime_replacement != null) {
            self.cancelImeComposition();
            return;
        }
        self.restoreHistory(true) catch return;
    }

    fn restoreHistory(self: *TextareaState, redo_direction: bool) !void {
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

    // ===== 键盘 =====

    pub fn handleKeyDown(self: *TextareaState, key: KeyCode, modifiers: Modifiers) bool {
        switch (key) {
            .left => {
                if (modifiers.super) self.moveToLineStart(modifiers.shift) else if (modifiers.alt) self.moveWordLeft(modifiers.shift) else self.moveCursorLeft(modifiers.shift);
                return true;
            },
            .right => {
                if (modifiers.super) self.moveToLineEnd(modifiers.shift) else if (modifiers.alt) self.moveWordRight(modifiers.shift) else self.moveCursorRight(modifiers.shift);
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
                if (modifiers.super) self.deleteToLineStart() else if (modifiers.alt) self.deleteWordBackward() else self.deleteBackward();
                return true;
            },
            .forward_delete => {
                if (modifiers.alt) self.deleteWordForward() else self.deleteForward();
                return true;
            },
            .z => {
                if (modifiers.super) {
                    if (modifiers.shift) self.redo() else self.undo();
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

    // ===== 鼠标 =====

    pub fn handleMouseDown(self: *TextareaState, x: f32, y: f32, modifiers: Modifiers) void {
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
        self.is_dragging = false;
        self.suspend_drag_until_mouse_up = false;
    }

    pub fn handleMouseDrag(self: *TextareaState, x: f32, y: f32) void {
        if (self.suspend_drag_until_mouse_up) return;
        const pos = self.hitTestAt(x, y);
        if (pos != self.cursor.offset) {
            self.cursor.offset = pos;
            self.markDirty();
        }
        self.resetBlink();
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
            return seg.start + position.byte.value;
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

    pub fn cancelImeComposition(self: *TextareaState) void {
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

    fn effectiveImeCursorOffset(self: *const TextareaState) usize {
        return editable_block.effectiveImeCursorOffset(self.ime_preedit_len, self.ime_cursor_utf8_offset, self.ime_selection_highlight);
    }

    fn clearImePreedit(self: *TextareaState) void {
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
        self.blink.reset();
        self.last_blink_visible = true;
    }

    pub fn blinkVisible(self: *TextareaState, now: std.time.Instant) bool {
        return self.blink.visible(now);
    }

    fn nextBlinkDelayNs(self: *const TextareaState, now: std.time.Instant) u64 {
        return self.blink.nextDelayNs(now);
    }

    // ===== 辅助 =====

    fn markDirty(self: *TextareaState) void {
        self.dirty = true;
        // cx.render() 零脏帧 fast-path 跳过 textareaBeforeRender -> state.dirty
        // 永不被读 + VirtualList 不刷新 -> 视觉文本不更新（同 password 之前的 bug）。
        // 把 container node 标 layout dirty 让 fast-path 失效。
        if (self.input_container_node) |n| n.markLayoutDirty();
        if (self.cursor_node) |n| n.markRenderDirty();
        if (self.selection_node) |n| n.markRenderDirty();
        if (self.preedit_underline_node) |n| n.markRenderDirty();
    }

    fn cursorDisplayPoint(self: *const TextareaState) DisplayPoint {
        const lc = self.doc.offsetToLineCol(self.cursor.offset);
        return self.wrap_map.bufferToDisplay(lc.line, lc.col);
    }

    /// 用真实测量函数计算文本宽度（pixel）
    fn measureSlice(self: *const TextareaState, text: []const u8) f32 {
        if (text.len == 0) return 0;
        if (self.cx_ref) |cx| {
            return cx.text.measureTextWidth(text, self.font_size, self.font_weight, false);
        }
        if (self.measure_fn) |mfn| return mfn(text.ptr, text.len, self.font_size, self.font_weight, false);
        return text_layout.measureTextWidthByFontKind(text, self.font_size, self.font_weight, false, false);
    }

    /// 测量 text[0..byte_end] 的宽度
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
        const now_i = std.time.Instant.now() catch null;
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
// 辅助函数
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
    // 过滤控制字符，保留 \n
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
        // ESC 序列必须先于通用控制字符过滤判定（ESC=0x1b < 0x20，放后面就是死代码，
        // 粘贴 "\x1b[31mred" 会留下 "[31mred"）。CSI：ESC '[' 参数/中间字节 终止字节。
        if (b == 0x1b) {
            i += 1;
            if (i < text.len and text[i] == '[') {
                i += 1;
                while (i < text.len and text[i] >= 0x20 and text[i] <= 0x3F) : (i += 1) {}
            }
            if (i < text.len) i += 1; // 终止字节 / 单字符转义
            continue;
        }
        if (b < 0x20 and b != '\t') {
            i += 1;
            continue;
        } // 过滤控制字符
        out[out_len] = b;
        out_len += 1;
        i += 1;
    }
    return out[0..out_len];
}

test "textarea sanitizeText: 剥离 ANSI ESC 序列而非只删 ESC 字节" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("red", sanitizeText("\x1b[31mred", &out));
    try std.testing.expectEqualStrings("ab\nc", sanitizeText("a\x1b[1;2Hb\x1b[0m\r\nc", &out));
    try std.testing.expectEqualStrings("xy", sanitizeText("x\x1bMy", &out));
    try std.testing.expectEqualStrings("x", sanitizeText("x\x1b", &out));
}

// ============================================================================
// 事件处理器
// ============================================================================

pub fn textareaEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *TextareaState = @ptrCast(@alignCast(context orelse return .ignored));

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
            // 剪贴板
            if (e.modifiers.super) {
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
        .mouse_up => |_| {
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
        .click => |_| {
            return .handled;
        },
        .scroll => |scroll| {
            if (state.vl_state) |vl_state| {
                // 优先转发给 VirtualList 的 ScrollArea
                if (vl_state.content_node.parent) |sa_container| {
                    if (sa_container.behavior.events.event_context) |ctx| {
                        const r = scroll_area_event.scrollEventHandler(Event{ .scroll = scroll }, ctx);
                        if (r != .ignored) return r;
                    }
                }
                // Fallback: 直接操作 scroll_state
                if (scroll.dy != 0) {
                    const prev_sy = vl_state.scroll_state.scroll_y;
                    const max_sy = vl_state.scroll_state.maxScrollY();
                    vl_state.scroll_state.scroll_y = std.math.clamp(vl_state.scroll_state.scroll_y - scroll.dy, 0, max_sy);
                    if (vl_state.scroll_state.scroll_y == prev_sy) return .ignored;
                    vl_state.content_node.style.translate_y = -vl_state.scroll_state.effectiveScrollY();
                    vl_state.content_node.markCompositePropDirty();
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

    @import("row_text.zig").set(item_node, cx, line_content, if (has_content) state.tokens.color.fg_primary else state.tokens.color.fg_secondary, state.font_size) catch {
        state.dirty = true;
        @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
        return;
    };
}

// ============================================================================
// beforeRender 钩子
// ============================================================================

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
            .frame_for_range = textareaA11yFrame,
            .range_at_point = textareaA11yRangeAtPoint,
        };
    }

    // 度量同步
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

    // 光标闪烁
    const now = std.time.Instant.now() catch null;
    const blink_visible = if (state.focused and now != null) state.blinkVisible(now.?) else state.focused;
    if (state.focused and now != null) {
        if (state.cx_ref) |cx| cx.scheduleRedrawAfterNs(state.nextBlinkDelayNs(now.?));
        if (blink_visible != state.last_blink_visible) node.markRenderDirty();
    }
    state.last_blink_visible = blink_visible;

    // 拖拽：cursor 更新走 textareaEventHandler.mouse_move -> state.handleMouseDrag。
    // 这里只清理 pressed_node==null 时 stale is_dragging。
    // 不能在 before_render 里读 cx.mouse_x/y 重算 cursor，那个值只有 mouse_move
    // 才更新；mouse_down 后到第一个 mouse_move 之间用到的是上一帧的 stale 坐标，
    // 在 e2e 或 程序合成 click 场景下还停在 (0,0) -> cursor 直接被踢到 doc 开头。
    if (state.is_dragging) {
        if (state.cx_ref) |cx| {
            if (cx.pressed_node == null) state.is_dragging = false;
        }
    }

    // VirtualList 刷新
    if (state.dirty) {
        state.dirty = false;
        if (state.vl_state) |vl_state| {
            const new_lc = @max(@as(u32, 1), state.wrap_map.displayLineCount());
            if (new_lc != vl_state.props.item_count) {
                // updateItemCount 会重建节点，可能触发 markRuntimeIndexDirty。
                // 但焦点在 textarea_node 上（不在 pool 节点），不应丢失。
                virtual_list.updateItemCount(vl_state, new_lc);
            } else {
                virtual_list.refreshRange(vl_state, vl_state.prev_start, vl_state.prev_end);
            }
            const dp = state.cursorDisplayPoint();
            virtual_list.ensureVisible(vl_state, dp.display_line);
        }
        node.markRenderDirty();
    }

    const container_inner_x = state.padding_h;
    const container_inner_y = state.padding_v;
    const cursor_h = @max(@as(f32, 12.0), state.line_height - 2.0);
    // VirtualList scroll offset: overlay 是 absolute 定位在容器内，
    // 但 VL 内容随滚动偏移，光标/选区需要补偿 scroll_y
    const scroll_y: f32 = if (state.vl_state) |vl| vl.scroll_state.effectiveScrollY() else 0;

    // 光标节点
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
            cnode.setBackgroundRaw(if (blink_visible) state.tokens.color.fg_primary else Color.TRANSPARENT);
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

    // 选区节点
    if (state.selection_node) |sel| {
        var placements: std.ArrayListUnmanaged(TextareaState.SelectionPlacement) = .{};
        defer placements.deinit(state.allocator);
        state.collectSelectionPlacements(state.allocator, &placements) catch placements.clearRetainingCapacity();
        if (placements.items.len > 0) {
            const sel_bg = state.tokens.color.selection_bg;
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

    // IME 下划线
    if (state.preedit_underline_node) |line| {
        if (state.hasImePreedit()) {
            const fallback_dp = state.cursorDisplayPoint();
            var display_line = fallback_dp.display_line;
            var rects: std.ArrayListUnmanaged(text_coordinates.SelectionRect) = .{};
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
            const accent = Color.rgba(state.tokens.color.accent.r, state.tokens.color.accent.g, state.tokens.color.accent.b, 220);
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
        esel.parent = overlay;
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
        underline.parent = overlay;
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

test "TextareaState: IME preedit text is fused into display segment content" {
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText("abcd");

    var wm = TextareaWrapMap.init(std.testing.allocator);
    defer wm.deinit();

    var state = TextareaState{
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

    var wm = TextareaWrapMap.init(std.testing.allocator);
    defer wm.deinit();

    var state = TextareaState{
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

    var wm = TextareaWrapMap.init(std.testing.allocator);
    defer wm.deinit();

    var state = TextareaState{
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
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try core_ui.FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const line_text = "ab \u{2067}\u{05D0}\u{05D1} \u{2066}12\u{2069}\u{2069} \u{202E}cd\u{202C} 👩‍💻";
    var document_buffer: [256]u8 = undefined;
    const document_text = try std.fmt.bufPrint(&document_buffer, "{s}\n{s}", .{ line_text, line_text });
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText(document_text);
    var wm = TextareaWrapMap.init(std.testing.allocator);
    defer wm.deinit();
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(10000, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    var state = TextareaState{
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

test "Textarea accessibility range frame shares mixed-bidi VisualLine geometry" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try core_ui.FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const content = "abc \u{05D0}\u{05D1}\u{05D2} 12";
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText(content);
    var wm = TextareaWrapMap.init(std.testing.allocator);
    defer wm.deinit();
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(10_000, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);

    var state = TextareaState{
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
}

test "TextareaState: selection geometry has no sixteen-line ceiling" {
    var cx = try Cx.init(std.testing.allocator);
    defer cx.deinit();
    var fonts = try core_ui.FontSystem.init(std.testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    var source: std.ArrayListUnmanaged(u8) = .{};
    defer source.deinit(std.testing.allocator);
    for (0..40) |line_index| {
        try source.appendSlice(std.testing.allocator, "abc \u{05D0}\u{05D1} 12");
        if (line_index + 1 < 40) try source.append(std.testing.allocator, '\n');
    }
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText(source.items);
    var wm = TextareaWrapMap.init(std.testing.allocator);
    defer wm.deinit();
    wm.setEnabled(true, &doc);
    wm.setWrapWidth(10000, &doc);
    _ = wm.rewrapInterpolatedAll(&doc);
    var state = TextareaState{
        .doc = &doc,
        .wrap_map = &wm,
        .allocator = std.testing.allocator,
        .cx_ref = cx,
        .font_size = 16,
    };
    defer state.deinit();
    state.cursor.anchor = 0;
    state.cursor.offset = doc.totalLength();

    var placements: std.ArrayListUnmanaged(TextareaState.SelectionPlacement) = .{};
    defer placements.deinit(std.testing.allocator);
    try state.collectSelectionPlacements(std.testing.allocator, &placements);
    try std.testing.expect(placements.items.len >= 40);
    for (placements.items) |placement| {
        try std.testing.expect(placement.rect.width >= 0);
        try std.testing.expect(std.math.isFinite(placement.rect.x));
    }
}

test "TextareaState: long IME composition preserves complete graphemes" {
    var long_line: [4096]u8 = [_]u8{'x'} ** 4096;
    var doc = TextareaDocument.init(std.testing.allocator);
    defer doc.deinit();
    doc.setText(&long_line);
    var wm = TextareaWrapMap.init(std.testing.allocator);
    defer wm.deinit();
    var state = TextareaState{
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

    var oversized: [300]u8 = [_]u8{'a'} ** 300;
    const emoji = "👩‍💻";
    @memcpy(oversized[255 .. 255 + emoji.len], emoji);
    state.handleImePreedit(oversized[0 .. 255 + emoji.len], @intCast(255 + emoji.len));
    try std.testing.expectEqual(@as(usize, 255 + emoji.len), state.ime_preedit_len);
    try std.testing.expect(text_coordinates.isGraphemeBoundary(oversized[0 .. 255 + emoji.len], state.ime_preedit_len));
}

// ============================================================================
// 公共 API：Textarea 组件
// ============================================================================

pub const TextareaProps = struct {
    value: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    label_text: ?[]const u8 = null,
    helper: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
    rows: u32 = 4,
    disabled: bool = false,
    required: bool = false,
    readonly: bool = false,
    width: ?f32 = null,
    on_change: ?core_ui.HandlerRef = null,
    context: ?*anyopaque = null,
};

pub fn Textarea(props: TextareaProps) TextareaBuilder {
    return .{ .props = props };
}

pub const TextareaMount = struct {
    wrapper: *Node,
    input: *Node,
    state: *TextareaState,
};

pub const TextareaBuilder = struct {
    props: TextareaProps,

    pub fn placeholder(self: TextareaBuilder, t: []const u8) TextareaBuilder {
        var n = self;
        n.props.placeholder = t;
        return n;
    }
    pub fn label(self: TextareaBuilder, t: []const u8) TextareaBuilder {
        var n = self;
        n.props.label_text = t;
        return n;
    }
    pub fn rows(self: TextareaBuilder, r: u32) TextareaBuilder {
        var n = self;
        n.props.rows = r;
        return n;
    }
    pub fn required(self: TextareaBuilder, value: bool) TextareaBuilder {
        var n = self;
        n.props.required = value;
        return n;
    }
    pub fn readonly(self: TextareaBuilder, value: bool) TextareaBuilder {
        var n = self;
        n.props.readonly = value;
        return n;
    }

    pub fn mount(self: TextareaBuilder, scope: *Scope, cx: *Cx) !*Node {
        return (try self.mountWithState(scope, cx)).wrapper;
    }

    /// Mounts the same component while exposing its editor state for demos and
    /// integrations that need an imperative edit action.
    pub fn mountWithState(self: TextareaBuilder, scope: *Scope, cx: *Cx) !TextareaMount {
        const my_scope = try scope.childScope();
        const allocator = cx.allocator;
        const t = cx.tokens;
        const p = self.props;
        const has_error = p.error_msg != null;
        const line_height: f32 = 20;
        const font_size: f32 = 13;
        const char_width: f32 = 7.8;
        const pad: f32 = 8;

        // TextareaDocument
        const doc = try my_scope.allocator.create(TextareaDocument);
        doc.* = TextareaDocument.init(my_scope.allocator);
        if (p.value) |v| doc.setText(v);
        try my_scope.adoptResource(@ptrCast(doc), struct {
            fn d(ptr: *anyopaque, alloc: Allocator) void {
                const dd: *TextareaDocument = @ptrCast(@alignCast(ptr));
                dd.deinit();
                alloc.destroy(dd);
            }
        }.d);

        // Measure through this window's Cx; the legacy context-free callback
        // can otherwise select a different live window's FontSelector.
        const mfn = cx.text.measure_fn;
        const measured_char_width = cx.text.measureTextWidth("M", font_size, 400, false);
        const real_char_width = if (measured_char_width > 0) measured_char_width else char_width;

        // WrapMap
        const wm = try my_scope.allocator.create(TextareaWrapMap);
        wm.* = TextareaWrapMap.init(my_scope.allocator);
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

        // TextareaState
        const state = try my_scope.allocator.create(TextareaState);
        state.* = TextareaState{
            .doc = doc,
            .wrap_map = wm,
            .allocator = my_scope.allocator,
            .measure_fn = mfn,
            .char_width = real_char_width,
            .font_size = font_size,
            .line_height = line_height,
            .padding_h = pad,
            .padding_v = pad,
            .placeholder_text = p.placeholder,
            .on_change = p.on_change,
            .cx_ref = cx,
            .tokens = t,
            .has_error = has_error,
        };
        if (p.value) |_| state.cursor.offset = doc.totalLength();
        try my_scope.adoptResource(@ptrCast(state), struct {
            fn d(ptr: *anyopaque, alloc: Allocator) void {
                const s: *TextareaState = @ptrCast(@alignCast(ptr));
                s.deinit();
                alloc.destroy(s);
            }
        }.d);

        // 初始化 wrap
        // WrapMap 宽度在 beforeRender 首帧由实际容器宽度初始化（mount 时布局还没完成）
        if (p.width) |w| {
            const inner_w = @max(@as(f32, 0), w - pad * 2);
            state.input_inner_w = inner_w;
            wm.setWrapWidth(inner_w, doc);
        }
        wm.setEnabled(true, doc);
        _ = wm.rewrapInterpolatedAll(doc);
        _ = wm.takePendingPatch();

        const textarea_height = line_height * @as(f32, @floatFromInt(p.rows));
        var wrapper_height: f32 = textarea_height;
        if (p.label_text != null) wrapper_height += 22;
        if (has_error or p.helper != null) wrapper_height += 20;

        // 节点树
        const wrapper = try box(cx, .{ .width = if (p.width) |w| .{ .px = w } else .{ .grow = .{} }, .height = .{ .px = wrapper_height }, .direction = .column, .gap = 4 }, .{});
        wrapper.meta.ownership.meta.component_name = "Textarea";
        wrapper.frame_state.state_bits.flags.disable_render_cache = true;
        try core_ui.bindScopeToNode(my_scope, wrapper);

        // 标签
        if (p.label_text) |lbl| {
            const label_node = try box(cx, .{ .height = .{ .px = 18 } }, .{});
            var label_txt = styles.textareaLabelStyle(t);
            label_txt.content = lbl;
            label_node.setText(label_txt);
            try wrapper.appendChild(allocator, label_node);
        }

        const field_radius: f32 = 8;
        const field_shell = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = textarea_height }, .border = .{ .radius = field_radius }, .direction = .column }, .{});

        const textarea_bg = styles.textareaBackground(t, p.disabled);
        const border_color = styles.textareaInitialBorderColor(t, has_error, p.disabled);
        const textarea_node = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .px = textarea_height }, .background = textarea_bg, .border = .{ .width = 1, .color = border_color, .radius = field_radius }, .overflow_hidden = true }, .{});
        textarea_node.tag = .input;
        textarea_node.setFocusable(true);
        textarea_node.behavior.interaction.a11y = .{
            .role = .textarea,
            // Keep an unlabeled editor unlabeled; its value is exposed through
            // AXValue, not recycled as a changing accessible name.
            .label = p.label_text orelse "",
            .placeholder = p.placeholder,
            .disabled = p.disabled,
            .required = p.required,
            .readonly = p.readonly,
            .invalid = has_error,
            .multiline = true,
        };
        if (!p.disabled and !p.readonly) {
            textarea_node.behavior.interaction.text_input_client = textareaLiveClient(state);
        }
        const te = textarea_node.style.ensureExtPanic(allocator);
        te.hit_shape = .{ .rounded_rect = field_radius };
        te.clip_shape = .{ .rounded_rect = field_radius };
        // 显式声明为 scroll 命中目标，避免滚轮被外层 ScrollArea 抢占。
        te.hit_roles = .{ .pointer = true, .scroll = true, .inspect = true };
        if (!p.disabled) textarea_node.style.cursor = .text;
        state.focus_ring_host = field_shell;
        state.input_container_node = textarea_node;
        textarea_node.applyTransition(allocator, &comptime recipe_mod.transition("border-color 150ms"));

        // VirtualList
        const initial_lc = @max(@as(u32, 1), wm.displayLineCount());
        const vl = try virtual_list.VirtualList(.{ .item_count = initial_lc, .item_height = line_height, .overscan = 3 }).mountWithContext(my_scope, cx, @ptrCast(state), null, textareaRenderItem);
        state.vl_state = vl.state;
        vl.container.style.width = .{ .grow = .{} };
        vl.container.style.height = .{ .grow = .{} };
        vl.container.style.padding = Padding.all(pad);
        const vl_ext = vl.container.style.ensureExtPanic(allocator);
        const textarea_inner_shadow_alpha: u8 = if (t.color.input_bg.r <= 64 and t.color.input_bg.g <= 64 and t.color.input_bg.b <= 64) 84 else 40;
        vl_ext.overflow_fade = .{
            .size = 10,
            .color = Color.rgba(0, 0, 0, textarea_inner_shadow_alpha),
            .edges = .{ .top = true, .bottom = true, .left = false, .right = false },
        };
        // Selection underlay，必须在文本(vl.container)之前 append:
        // 选区色块要画在字形下面。之前选区挂在文本之后的 overlay 里,
        // paint order 反转,选中的字直接被色块盖没。
        const underlay = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .position = .absolute }, .{});
        const ue = underlay.style.ensureExtPanic(allocator);
        ue.inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } };
        ue.hit_behavior = .pass_through;
        state.selection_underlay_node = underlay;

        const sel_node = try box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } }, .{});
        state.selection_node = sel_node;
        try underlay.appendChild(allocator, sel_node);
        try textarea_node.appendChild(allocator, underlay);

        try textarea_node.appendChild(allocator, vl.container);

        // Overlay(preedit 下划线 + 光标，这两个要在文本之上)
        const overlay = try box(cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} }, .position = .absolute }, .{});
        const oe = overlay.style.ensureExtPanic(allocator);
        oe.inset = .{ .top = .{ .px = 0 }, .left = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 } };
        oe.hit_behavior = .pass_through;
        state.overlay_node = overlay;

        const preedit_node = try box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } }, .{});
        state.preedit_underline_node = preedit_node;
        try overlay.appendChild(allocator, preedit_node);

        const cnode = try box(cx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } }, .{});
        state.cursor_node = cnode;
        try overlay.appendChild(allocator, cnode);

        try textarea_node.appendChild(allocator, overlay);
        textarea_node.meta.per_frame.hooks.before_render.main = textareaBeforeRender;

        // 事件
        if (!p.disabled and !p.readonly) {
            textarea_node.behavior.events.on_event = textareaEventHandler;
            textarea_node.behavior.events.event_context = state;

            const state_opaque: *anyopaque = state;
            textarea_node.behavior.events.on_focus = .{
                .callback = struct {
                    fn h(c: *anyopaque) void {
                        const s: *TextareaState = @ptrCast(@alignCast(c));
                        s.focused = true;
                        if (!s.has_error) if (s.input_container_node) |cn| {
                            cn.setBorderColor(styles.borderColor(s.tokens, s.tokens.color.input_border, false, true, false));
                            cn.style.border.width = 1.5;
                            cn.markRenderDirty();
                        };
                        if (s.focus_ring_host) |host| if (host.behavior.events.on_focus) |h2| h2.invoke();
                    }
                }.h,
                .context = state_opaque,
            };
            textarea_node.behavior.events.on_blur = .{
                .callback = struct {
                    fn h(c: *anyopaque) void {
                        const s: *TextareaState = @ptrCast(@alignCast(c));
                        s.focused = false;
                        s.cancelImeComposition();
                        s.cursor.anchor = null;
                        s.is_dragging = false;
                        s.suspend_drag_until_mouse_up = false;
                        s.consecutive_mouse_downs = 0;
                        s.last_mouse_down_instant = null;
                        if (!s.has_error) {
                            const hovered = if (s.hover_signal) |hs| hs.get() else false;
                            if (s.input_container_node) |cn| {
                                cn.setBorderColor(styles.borderColor(s.tokens, s.tokens.color.input_border, hovered, false, false));
                                cn.style.border.width = 1;
                                cn.markRenderDirty();
                            }
                        }
                        if (s.focus_ring_host) |host| if (host.behavior.events.on_blur) |h2| h2.invoke();
                    }
                }.h,
                .context = state_opaque,
            };

            const is_hovered = try hooks.useHover(my_scope, textarea_node);
            state.hover_signal = is_hovered;
            try my_scope.createEffect(.{ .textarea = textarea_node, .is_hovered = is_hovered, .has_error = has_error, .state = state, .tokens = t }, struct {
                fn u(c: anytype) void {
                    const hovered = c.is_hovered.get();
                    if (styles.hoverBorderApplies(c.state.focused, c.has_error))
                        c.textarea.setBorderColor(styles.borderColor(c.tokens, c.tokens.color.input_border, hovered, false, false));
                }
            }.u);
            try hooks.useFocusRing(my_scope, cx, field_shell, .{ .offset = 0 });
        }

        try field_shell.appendChild(allocator, textarea_node);
        try wrapper.appendChild(allocator, field_shell);

        if (p.error_msg orelse p.helper) |ht| {
            const hn = try box(cx, .{ .height = .{ .px = 16 } }, .{});
            var helper_txt = styles.textareaHelperStyle(t, has_error);
            helper_txt.content = ht;
            hn.setText(helper_txt);
            try wrapper.appendChild(allocator, hn);
        }

        return .{
            .wrapper = wrapper,
            .input = textarea_node,
            .state = state,
        };
    }
};

test "textarea event route commits complete long IME input once" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    var state: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
    defer state.deinit();
    const value = "中\n" ** 300;
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
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    var state: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator() };
    defer state.deinit();
    state.cursor.offset = doc.totalLength();
    state.cursor.anchor = 0;
    failing.fail_index = failing.alloc_index;
    state.handleImeCommit("x" ** 1000);
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
            var wm = TextareaWrapMap.init(t.allocator);
            defer wm.deinit();
            var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = if (fail_model) t.allocator else failing.allocator() };
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
            const value = "中\n" ** 300;
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
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator() };
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
                const original = "keep\n" ** 80;
                try doc.setTextChecked(original);
                var wm = TextareaWrapMap.init(t.allocator);
                defer wm.deinit();
                var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = if (fail_model) t.allocator else failing.allocator() };
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
                        _ = s.setAccessibilityValue("new\n" ** 120);
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
                            try t.expect(s.setAccessibilityValue("new\n" ** 120));
                        },
                        1 => s.undo(),
                        2 => s.redo(),
                        else => unreachable,
                    }
                }
                const expected = switch (operation) {
                    0 => "new\n" ** 120,
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
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator(), .on_change = .{ .callback = Observer.notify, .context = &observer } };
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
        var wm = TextareaWrapMap.init(t.allocator);
        defer wm.deinit();
        var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator() };
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
    doc.setText("abcdefgh" ** 8);
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var wm = Map.init(failing.allocator());
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
    var state: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = t.allocator, .input_inner_w = 64 };
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
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
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
            var wm = TextareaWrapMap.init(t.allocator);
            defer wm.deinit();
            var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = if (fail_model) t.allocator else failing.allocator() };
            defer s.deinit();
            s.cursor.offset = 8;
            s.insertText("!");
            s.undo();
            s.cursor.offset = 8;
            s.cursor.anchor = null;
            s.handleImePreeditReplace("候选", 6, 1, 7);
            const old_undo = s.undo_count;
            const old_redo = s.redo_count;
            const value = "新" ** 200;
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
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
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
    var cx = try Cx.init(t.allocator);
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
    var wm = Map.init(t.allocator);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
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
    _ = try s.composeSegmentWithImeChecked("x" ** 6000, 0);
    try t.expectEqualStrings("abc", first.getText().?.content);
    s.cancelImeComposition();
    // Retained nodes must not borrow canonical document memory either.
    try doc.setTextChecked("replacement" ** 600);
    try t.expectEqualStrings("abc", first.getText().?.content);
    try t.expectEqualStrings("defgh", second.getText().?.content);
}

test "IME row allocation failure retains text and schedules retry without another edit" {
    const t = std.testing;
    const Doc = @import("textarea_document.zig").TextareaDocument;
    const Map = @import("text_core").wrap_map.WrapMap(Doc);
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var cx = try Cx.init(failing.allocator());
    defer cx.deinit();
    const row = try core_ui.box(cx, .{}, .{});
    cx.root = row;
    var doc = Doc.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abc");
    var wm = Map.init(t.allocator);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = t.allocator };
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
    var cx = try Cx.init(t.allocator);
    defer cx.deinit();
    const row = try core_ui.box(cx, .{}, .{});
    cx.root = row;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abc");
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var s: TextareaState = .{ .doc = &doc, .wrap_map = &wm, .allocator = failing.allocator() };
    defer s.deinit();
    s.cursor.offset = 3;
    s.handleImePreedit("候选", 6);
    textareaRenderItem(row, 0, cx, &s);
    try t.expectEqualStrings("abc候选", row.getText().?.content);
    try doc.setTextChecked("x" ** 6000);
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
    try t.expectEqualStrings("xxx候选" ++ "x" ** 5997, row.getText().?.content);
    try t.expectEqualStrings("x" ** 6000, s.getText());
}

test "independent textarea preserves long preedit and its grapheme cursor" {
    const t = std.testing;
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("xyz");
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    var s: TextareaState = .{ .allocator = t.allocator, .doc = &doc, .wrap_map = &wm };
    defer s.deinit();
    s.cursor.offset = 1;
    const candidate = "漢" ** 1000 ++ "👩‍💻";
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
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    var s: TextareaState = .{ .allocator = failing.allocator(), .doc = &doc, .wrap_map = &wm };
    defer s.deinit();
    s.cursor.offset = 8;
    s.cursor.anchor = 7;
    try s.handleImePreeditReplaceChecked("旧", 3, 1, 7);
    failing.fail_index = failing.alloc_index;
    const candidate = "漢" ** 1000;
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
