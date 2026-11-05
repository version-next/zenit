const ImeReplacement = @import("ime_replacement.zig").ImeReplacement;
/// TextInputState, Input/Textarea core state
/// Defines TextInputState struct and all methods.
const std = @import("std");
const core = @import("../../core.zig");
const theme = core.theme;
const events = @import("../../events.zig");
const KeyCode = events.KeyCode;
const editable_block = @import("../editable_block/mod.zig");
const ImeText = @import("ime_text.zig").ImeText;
const text_utils = @import("text_utils.zig");
const caret_blink = @import("caret_blink.zig");
const edit_reconcile = @import("edit_reconcile.zig");
const HistoryStash = @import("history_stash.zig").HistoryStash;
const textarea_doc_mod = @import("textarea_document.zig");
pub const TextareaDocument = textarea_doc_mod.TextareaDocument;
const core_mod = @import("text_core");
const DocCursor = core_mod.cursor.DocCursor;
const grapheme = core_mod.grapheme;
const text_coordinates = core_mod.text_coordinates;
const wrap_map_mod = core_mod.wrap_map;
pub const TextareaWrapMap = wrap_map_mod.WrapMap(TextareaDocument);
pub const DisplayLineInfo = wrap_map_mod.DisplayLineInfo;
pub const DisplayPoint = wrap_map_mod.DisplayPoint;

pub const UndoSnapshot = editable_block.UndoSnapshot;
const ImeComposePhase = editable_block.ImeComposePhase;
pub const EditableBlockBehavior = editable_block.Behavior;
pub const EditableBlockMetrics = editable_block.Metrics;
pub const InputType = editable_block.InputType;

// Re-export text_utils for convenience
pub const utf8MeasuredAdvancePrefix = text_utils.utf8MeasuredAdvancePrefix;
pub const utf8MeasuredAdvance = text_utils.utf8MeasuredAdvance;
pub const utf8ByteOffsetForMeasuredX = text_utils.utf8ByteOffsetForMeasuredX;

/// Textarea-only undo snapshot (dynamic text, no 256-byte limit)
pub const TaUndoEntry = struct {
    /// Text snapshot (null = empty slot)
    text: ?[]const u8 = null,
    /// Cursor position (byte offset)
    cursor_pos: usize = 0,
    selection_anchor: ?usize = null,

    pub fn deinit(self: *TaUndoEntry, allocator: std.mem.Allocator) void {
        if (self.text) |t| allocator.free(t);
        self.text = null;
    }
};

/// Text input internal state
/// Mergeable edit kinds. Different kinds start new undo unit (Backspace after typing opens new
/// unit).
pub const UndoCoalesceKind = enum(u8) { none, insert, delete_backward, delete_forward };

/// User edit transaction: one event (keyboard/text input/IME commit/AX write) from entry to return.
/// Entry records the pre-edit selection and undo-merge state and logs what the edit did to
/// history. When value binding (binding.zig) finds at edit exit that the landed value != buffer,
/// it fixes the buffer in place instead of replacing it wholesale: reject reverts the history
/// traces and restores the pre-edit selection; rewrite sets the buffer to the landed value, maps
/// the cursor per edit_reconcile.zig and joins the edit's undo unit. Outside a transaction
/// (programmatic writes) there is no checkpoint, so binding can only treat it as an external
/// write.
pub const UserEditTxn = struct {
    /// Nesting depth (AX write can occur during event; only outermost records checkpoint)
    depth: u8 = 0,
    /// Pre-edit cursor/selection anchor (during composition re-conversion, use the selection saved
    /// before composition started, same as cancelling composition)
    cursor: usize = 0,
    anchor: ?usize = null,
    /// Pre-edit undo merge state (restored on reject; consecutive typing not interrupted by one
    /// rejected keystroke)
    coalesce_kind: UndoCoalesceKind = .none,
    coalesce_cursor: usize = 0,
    coalesce_at: ?@import("zenit_time").Instant = null,
    /// Snapshots pushed to undo stack this transaction (popped on reject)
    pushes: u8 = 0,
    /// Undo/redo executed this transaction (reverse on reject to restore stacks)
    history_op: HistoryOp = .none,

    pub const HistoryOp = enum(u8) { none, undo, redo };
};

/// Once a state records single-line history it owns heap allocations through
/// `allocator`; callers constructing a state directly must call `deinit`.
pub const TextInputState = struct {
    const blink_half_period_ns: i128 = 500 * std.time.ns_per_ms;

    /// Undo/redo stack depth. Originally 32 gave ~32 keystrokes; post-coalesce one snapshot = one
    /// input unit with longer history.
    pub const UNDO_CAPACITY: usize = 64;

    /// Max idle interval for coalescing consecutive input. Exceeding this time starts new unit
    /// (aligns with AppKit NSUndoManager grouping-by-idle).
    pub const undo_coalesce_idle_ns: u64 = 800 * std.time.ns_per_ms;

    /// Text buffer (fixed size, avoids dynamic allocation; see editable_block.MAX_INPUT_BYTES)
    io: std.Io,
    buffer: [editable_block.MAX_INPUT_BYTES]u8 = @as([editable_block.MAX_INPUT_BYTES]u8, @splat(0)),
    buffer_len: usize = 0,
    /// Opt-in for fields whose business value must not be silently truncated.
    growable: bool = false,
    input_overflow: ?[]u8 = null,

    cursor_pos: usize = 0,
    /// Same logical byte may have two visual positions at bidi/soft-wrap boundary.
    cursor_affinity: text_coordinates.Affinity = .downstream,
    /// Textarea vertical navigation keeps a visual pixel column, not a UTF-8
    /// byte/codepoint column. Reset by horizontal movement or text mutation.
    preferred_visual_x: ?f32 = null,

    /// Selection anchor (if selected)
    selection_anchor: ?usize = null,

    /// Undo/redo stack. Slots hold owned text snapshots; unused slots null.
    undo_stack: [UNDO_CAPACITY]UndoSnapshot = @as([UNDO_CAPACITY]UndoSnapshot, @splat(.{})),
    undo_count: u8 = 0,
    redo_stack: [UNDO_CAPACITY]UndoSnapshot = @as([UNDO_CAPACITY]UndoSnapshot, @splat(.{})),
    redo_count: u8 = 0,

    /// -- Undo coalescing --
    /// Native controls merge consecutive input into one undo unit, not per-keystroke snapshots.
    /// Record previous mergeable edit kind, end cursor offset, and timestamp; use to detect
    /// continuation.
    undo_coalesce_kind: UndoCoalesceKind = .none,
    /// Cursor byte offset after last mergeable edit (breaks on cursor jump)
    undo_coalesce_cursor: usize = 0,
    /// Timestamp of last mergeable edit (ns monotonic clock; breaks on timeout)
    undo_coalesce_at: ?@import("zenit_time").Instant = null,
    /// Current user edit transaction (see UserEditTxn; depth == 0 = not in transaction)
    user_edit: UserEditTxn = .{},
    /// Redo stack cleared / undo entries evicted during transaction (restored on reject; see
    /// history_stash.zig)
    undo_stash: HistoryStash(UndoSnapshot, UNDO_CAPACITY) = .{},
    ta_undo_stash: HistoryStash(TaUndoEntry, UNDO_CAPACITY) = .{},

    /// Focus state
    focused: bool = false,

    /// Horizontal scroll offset (pixels; positive = text scrolled left)
    scroll_x: f32 = 0,
    a11y_scroll_request: ?@import("../../core.zig").A11yProps.TextScrollRequest = null,

    /// Dirty flag (needs redraw)
    dirty: bool = false,

    /// Cursor blink phase (see caret_blink.zig). Phase arithmetic independent of input state;
    /// factored into independent unit type.
    blink: caret_blink.CaretBlink = .{},
    /// Previous frame visibility; dirty only on phase flip
    last_blink_visible: bool = true,
    /// Mouse drag in progress
    is_dragging: bool = false,
    /// Only populated by this input's mouse-move handler, never stale Cx coordinates.
    drag_pointer: ?struct { x: f32, y: f32, time_ms: f64 } = null,
    /// Multi-click detection: last mouse_down timestamp
    last_mouse_down_instant: ?@import("zenit_time").Instant = null,
    /// Multi-click detection: last mouse_down position
    last_mouse_down_pos: [2]f32 = .{ 0, 0 },
    /// Multi-click count (press phase)
    consecutive_mouse_downs: u8 = 0,
    /// After multi-click select-word/select-all, block drag update while mouse held
    suspend_drag_until_mouse_up: bool = false,
    /// Cursor node reference
    cursor_node: ?*core.Node = null,
    /// Selection node reference (multiline only; single-line uses text_display_node spans)
    selection_node: ?*core.Node = null,
    /// IME composition underline node reference (multiline only; single-line uses spans underline)
    preedit_underline_node: ?*core.Node = null,
    /// Text display node reference (retained mode: dynamic text content update)
    text_display_node: ?*core.Node = null,
    /// Owns the before-render hook that applies scroll and selection visuals.
    editable_surface_node: ?*core.Node = null,
    /// Keep input visuals in sync when a host renders through a dirty subtree
    /// path that does not visit the editable surface's per-frame hook.
    visual_sync_hook: ?*const fn (*core.Node) void = null,
    visual_sync_active: bool = false,
    /// Single-line selection/IME spans buffer (owned, same lifetime as text_display_node).
    /// Capacity sufficient: 1 selection + 1 preedit underline + 1 ime marked highlight = 3
    text_spans_buf: [4]core.TextSpan = undefined,
    text_spans_len: u8 = 0,
    /// Placeholder text (used in beforeRender to decide placeholder display)
    placeholder_text: ?[]const u8 = null,
    /// Placeholder color override
    placeholder_color: ?core.Color = null,
    /// The field node (ControlShell root: focus target, a11y, text input client)
    input_container_node: ?*core.Node = null,
    /// Invalid (invalid prop or error message): a11y and editing state; the frame color is the
    /// shell's :invalid
    has_error: bool = false,
    /// Dynamic disable: when true, event handlers ignore all input (static disable doesn't install
    /// handler)
    disabled: bool = false,
    /// Allocator for StyleExt writes (Group corner radius pass-through, etc.)
    /// Owns single-line undo/redo snapshots. Component mounts replace this fallback with Scope/Cx
    /// allocator and register deinit.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    // Border animation unified into Transition system (enableImplicitAnimation + setBorderColor)
    /// input_container global x (updated in on_before_render)
    container_x: f32 = 0,
    /// input_container global y (updated in on_before_render)
    container_y: f32 = 0,
    /// Character width cache
    char_width: f32 = 7.8,
    /// Text font weight (400=regular, 500=medium, 700=bold)
    font_weight: u16 = 400,
    /// Text font size cache
    font_size: f32 = 13.0,
    /// Horizontal padding cache
    padding_h: f32 = 8.0,
    /// Vertical padding cache
    padding_v: f32 = 0.0,
    /// Line height cache
    line_height: f32 = 16.0,
    /// Available inner width cache
    input_inner_w: f32 = 200.0,
    /// Cx reference (drag reads mouse_x)
    cx_ref: ?*core.Cx = null,

    /// Password mode single '*' advance cache. Per-frame ShapingCache hit expensive;
    /// mask = N identical '*' has linear advance N x single_star_width; no need per-caller shape.
    /// Invalidated on font_size/weight/cx change.
    cached_star_advance: f32 = 0,
    cached_star_font_size: f32 = -1,
    cached_star_font_weight: u16 = 0,

    /// Input type
    input_type: InputType = .text,
    /// User interaction may select/copy, but cannot mutate this document.
    readonly: bool = false,
    /// Whether multiline input
    multiline: bool = false,
    /// Whether accepts line breaks
    accept_newline: bool = false,
    /// Whether soft-wrap (auto-wrap by container width)
    soft_wrap: bool = false,
    /// Multiline editor without scroll shell auto-grows height by WrapMap visual lines.
    /// Textarea uses VirtualList/fixed viewport, stays false.
    multiline_auto_height: bool = false,
    /// Text display buffer (password mask / IME composition text)
    // Small projections stay inline; overflow storage retains complete text.
    // Retained text nodes own copies and never borrow these scratch buffers.
    display_buffer: [editable_block.MAX_INPUT_BYTES + 256]u8 = @as([(editable_block.MAX_INPUT_BYTES + 256)]u8, @splat(0)),
    /// Last successfully published display snapshot hash.
    display_text_hash: u64 = 0,
    display_overflow: std.ArrayListUnmanaged(u8) = .empty,
    wrapped_display_overflow: std.ArrayListUnmanaged(u8) = .empty,
    ime_segment_overflow: std.ArrayListUnmanaged(u8) = .empty,
    /// Multiline soft-wrap render buffer
    wrapped_display_buffer: [(editable_block.MAX_INPUT_BYTES + 256) * 2]u8 = @as([((editable_block.MAX_INPUT_BYTES + 256) * 2)]u8, @splat(0)),
    /// IME display segment merge buffer (Textarea WrapMap render path)
    ime_segment_buffer: [editable_block.MAX_INPUT_BYTES + 256]u8 = @as([(editable_block.MAX_INPUT_BYTES + 256)]u8, @splat(0)),
    /// IME preedit buffer
    ime_preedit: ImeText = .{},
    ime_preedit_len: usize = 0,
    ime_cursor_utf8_offset: usize = 0,
    ime_cursor_visible: bool = true,
    ime_selection_end: ?usize = null,
    ime_phase: ImeComposePhase = .idle,
    ime_pending_commit: ImeText = .{},
    ime_replacement: ?ImeReplacement = null,
    ime_selection_highlight: bool = false,
    /// During multiline composition the visible document includes preedit
    /// bytes that are not committed to textarea_doc. These cached coordinates
    /// come from a temporary WrapMap over that visible document, keeping the
    /// caret/candidate window/underline and auto-height on the same soft line
    /// as the wrapped text node.
    ime_visual_valid: bool = false,
    ime_visual_display_line: u32 = 0,
    ime_visual_cursor_x: f32 = 0,
    ime_visual_underline_x: f32 = 0,
    ime_visual_underline_width: f32 = 0,
    ime_visual_total_lines: u32 = 0,

    /// Textarea VirtualList state reference (multiline only)
    vl_state: ?*@import("../virtual_list/mod.zig").VirtualListState = null,
    /// Textarea overlay container node (holds selection/cursor/preedit_underline)
    textarea_overlay_node: ?*core.Node = null,
    /// Multiline selection extra row nodes (selection_node is first row; these are rows 2-N)
    extra_sel_nodes: [15]?*core.Node = @as([15]?*core.Node, @splat(null)),
    extra_sel_count: u8 = 0,

    /// === Textarea core module integration (multiline only) ===
    /// Dynamic text document (replaces buffer[256])
    textarea_doc: ?*TextareaDocument = null,
    /// Generic cursor (replaces manual cursor logic)
    textarea_cursor: DocCursor(TextareaDocument) = .{},
    /// Soft-wrap map (replaces appendWrappedLines/multilineVisualPosForOffset)
    textarea_wrap: ?*TextareaWrapMap = null,
    /// Textarea-only undo/redo stack (dynamic text, no 256-byte limit)
    ta_undo: [UNDO_CAPACITY]TaUndoEntry = @as([UNDO_CAPACITY]TaUndoEntry, @splat(.{})),
    ta_undo_count: u8 = 0,
    ta_redo: [UNDO_CAPACITY]TaUndoEntry = @as([UNDO_CAPACITY]TaUndoEntry, @splat(.{})),
    ta_redo_count: u8 = 0,
    /// Textarea text limit (bytes), 0 = unlimited
    textarea_max_bytes: usize = 0,

    /// Theme tokens reference (for callbacks without ctx)
    tokens: *const theme.ThemeTokens = &theme.dark,

    /// Host-override selection color (null = use tokens.color.selection_bg / inherit text color).
    /// Scene: inline rename sets row as input with saturated accent bg + inverted text (focus on
    /// name).
    /// Global selection_bg light blue. Single-line spans only; multiline selection_node doesn't use
    /// fg.
    selection_bg_override: ?core.Color = null,
    selection_fg_override: ?core.Color = null,

    /// Value change callback (fires when text truly changes, not cursor movement).
    /// 2026-07-31 unified: ?core.HandlerRef with invokeWithStr (payload = full text; WARNING: the
    /// slice is valid only during the callback, dupe it if you need to keep it).
    on_change: ?core.HandlerRef = null,
    /// Single-line Enter (non-composition, no line breaks accepted): payload = full text. null
    /// allows Enter to bubble
    on_submit: ?core.HandlerRef = null,
    /// Called after composition cancel: binding applies deferred external writes from composition.
    on_ime_cancelled: ?core.HandlerRef = null,
    /// EditableText only: the component enters editing itself when pressed and leaves it on
    /// Enter (single line), Escape or blur (`EditableTextProps.activation = .click`).
    editable_click_activation: bool = false,
    /// EditableText only: editing mode is on (input handler attached, focusable).
    editable_editing: bool = false,

    // ========== Doc sync ==========

    /// DocCursor -> state.cursor_pos / selection_anchor
    pub fn syncCursorFromDoc(self: *TextInputState) void {
        self.cursor_pos = self.textarea_cursor.offset;
        self.selection_anchor = self.textarea_cursor.anchor;
    }

    /// state.cursor_pos / selection_anchor -> DocCursor
    pub fn syncDocFromCursor(self: *TextInputState) void {
        self.textarea_cursor.offset = self.cursor_pos;
        self.textarea_cursor.anchor = self.selection_anchor;
        self.textarea_cursor.preferred_col = null;
    }

    /// Textarea-only: save undo snapshot
    fn taPushUndo(self: *TextInputState) bool {
        const doc = self.textarea_doc orelse return false;
        const allocator = doc.allocator;
        const txt = doc.getText();
        const snap_text = allocator.dupe(u8, txt) catch return false;
        const entry = TaUndoEntry{
            .text = snap_text,
            .cursor_pos = self.cursor_pos,
            .selection_anchor = self.selection_anchor,
        };
        const in_txn = self.user_edit.depth > 0;
        if (self.ta_undo_count < UNDO_CAPACITY) {
            self.ta_undo[self.ta_undo_count] = entry;
            self.ta_undo_count += 1;
        } else {
            // Evicted entries during transaction stashed; restored on reject.
            if (!(in_txn and self.ta_undo_stash.keepEvicted(self.ta_undo[0]))) self.ta_undo[0].deinit(allocator);
            var i: usize = 0;
            while (i < UNDO_CAPACITY - 1) : (i += 1) self.ta_undo[i] = self.ta_undo[i + 1];
            self.ta_undo[UNDO_CAPACITY - 1] = entry;
        }
        // Clear redo stack (in-place detach during transaction; see history_stash.zig)
        if (!(in_txn and self.ta_undo_stash.detachRedo(&self.ta_redo_count))) {
            var j: u8 = 0;
            while (j < self.ta_redo_count) : (j += 1) self.ta_redo[j].deinit(allocator);
            self.ta_redo_count = 0;
        }
        return true;
    }

    /// Restore text and indexes before moving either history entry.
    fn taRestoreHistory(self: *TextInputState, redo_direction: bool) bool {
        const doc = self.textarea_doc orelse return false;
        // Redo slots may be reused: evicted entries during transaction freed first.
        self.ta_undo_stash.settleRedo(&self.ta_redo, doc.allocator);
        const source = if (redo_direction) &self.ta_redo else &self.ta_undo;
        const source_count = if (redo_direction) &self.ta_redo_count else &self.ta_undo_count;
        const target = if (redo_direction) &self.ta_undo else &self.ta_redo;
        const target_count = if (redo_direction) &self.ta_undo_count else &self.ta_redo_count;
        if (source_count.* == 0) return false;
        const snapshot = &source[source_count.* - 1];
        var prepared = doc.prepareReplace(0, doc.totalLength(), snapshot.text orelse "") catch return false;
        defer prepared.deinit();
        const current_text = doc.allocator.dupe(u8, doc.getText()) catch return false;
        const current: TaUndoEntry = .{ .text = current_text, .cursor_pos = self.cursor_pos, .selection_anchor = self.selection_anchor };
        // Everything that can fail is complete. Publish both stacks and document.
        if (target_count.* == UNDO_CAPACITY) {
            target[0].deinit(doc.allocator);
            for (0..UNDO_CAPACITY - 1) |i| target[i] = target[i + 1];
            target_count.* -= 1;
        }
        target[target_count.*] = current;
        target_count.* += 1;
        prepared.commit();
        self.cursor_pos = @min(snapshot.cursor_pos, doc.totalLength());
        self.selection_anchor = if (snapshot.selection_anchor) |anchor| @min(anchor, doc.totalLength()) else null;
        snapshot.deinit(doc.allocator);
        source_count.* -= 1;
        self.syncDocFromCursor();
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        if (self.textarea_wrap) |wrap| wrap.rebuildAll(doc);
        self.dirty = true;
        self.resetBlink();
        return true;
    }

    /// Compute safe buffer byte range [start, end) from DisplayLineInfo.
    /// byte_end may be maxInt(usize); clamp to line_end
    fn safeSegRange(doc: *const TextareaDocument, info: DisplayLineInfo) struct { start: usize, end: usize } {
        const line_start = doc.getLineStart(info.buffer_line);
        const line_end = doc.getLineEnd(info.buffer_line);
        const seg_start = @min(line_start +| info.byte_start, line_end);
        const seg_end = if (info.byte_end >= std.math.maxInt(usize) / 2)
            line_end
        else
            @min(line_start +| info.byte_end, line_end);
        return .{ .start = seg_start, .end = seg_end };
    }

    /// Notify WrapMap incremental update + VirtualList refresh
    fn notifyWrapEdit(self: *TextInputState, start_line: usize, old_line_count: usize, new_line_count: usize) void {
        if (self.textarea_wrap) |wrap| {
            if (self.textarea_doc) |doc| {
                wrap.applyEdit(doc, start_line, old_line_count, new_line_count);
                _ = wrap.rewrapInterpolatedAll(doc);
                _ = wrap.takePendingPatch();
            }
        }
    }

    /// Free and clear undo/redo history for both edit paths.
    /// Multiline snapshots hold dynamic text; cannot just zero count like fixed array.
    /// EditableText uses this to block Cmd+Z recovery on canvas switch; Scope dispose also frees
    /// remaining snapshots.
    pub fn clearUndoHistory(self: *TextInputState) void {
        self.breakUndoCoalescing();
        // History fully invalidated: stash also freed, no restorable state in transaction.
        self.undo_stash.discard(&self.redo_stack, self.allocator);
        self.user_edit.pushes = 0;
        var i: usize = 0;
        while (i < self.undo_count) : (i += 1) self.undo_stack[i].deinit(self.allocator);
        self.undo_count = 0;
        i = 0;
        while (i < self.redo_count) : (i += 1) self.redo_stack[i].deinit(self.allocator);
        self.redo_count = 0;

        if (self.textarea_doc) |doc| {
            self.ta_undo_stash.discard(&self.ta_redo, doc.allocator);
            i = 0;
            while (i < self.ta_undo_count) : (i += 1) self.ta_undo[i].deinit(doc.allocator);
            self.ta_undo_count = 0;
            i = 0;
            while (i < self.ta_redo_count) : (i += 1) self.ta_redo[i].deinit(doc.allocator);
            self.ta_redo_count = 0;
        }
    }

    /// Scope-owned cleanup hook. The document and WrapMap themselves are
    /// separate resources and must outlive this call.
    fn singleLineBuffer(self: *const TextInputState) []const u8 {
        return self.input_overflow orelse &self.buffer;
    }

    fn mutableBuffer(self: *TextInputState) []u8 {
        return self.input_overflow orelse &self.buffer;
    }

    /// Allocate a candidate without invalidating any displayed/borrowed bytes.
    fn prepareInputGrowth(self: *TextInputState, required: usize) !?[]u8 {
        if (required <= self.singleLineBuffer().len) return null;
        if (!self.growable) return error.NoSpaceLeft;
        const capacity = @max(required, std.math.mul(usize, self.singleLineBuffer().len, 2) catch required);
        const candidate = try self.allocator.alloc(u8, capacity);
        @memcpy(candidate[0..self.buffer_len], self.getText());
        return candidate;
    }

    fn commitInputGrowth(self: *TextInputState, candidate: ?[]u8) void {
        if (candidate) |bytes| {
            if (self.input_overflow) |old| self.allocator.free(old);
            self.input_overflow = bytes;
        }
    }

    pub fn deinit(self: *TextInputState) void {
        if (self.cx_ref) |cx| cx.sprites.unregister(self);
        if (self.input_overflow) |bytes| self.allocator.free(bytes);
        self.input_overflow = null;
        self.ime_preedit.deinit();
        self.clearImePendingCommit();
        self.clearUndoHistory();
        self.discardHistoryStash();
        self.display_overflow.deinit(self.allocator);
        self.wrapped_display_overflow.deinit(self.allocator);
        self.ime_segment_overflow.deinit(self.allocator);
    }

    /// Keep shell-free multiline editors exactly as tall as their visual rows.
    pub fn syncMultilineAutoHeight(self: *TextInputState) void {
        if (!self.multiline_auto_height) return;
        const node = self.input_container_node orelse return;
        const line_count: u32 = if (self.ime_visual_valid)
            @max(@as(u32, 1), self.ime_visual_total_lines)
        else if (self.textarea_wrap) |wrap|
            @max(@as(u32, 1), wrap.displayLineCount())
        else
            1;
        const desired = @as(f32, @floatFromInt(line_count)) * self.line_height + self.padding_v * 2;
        const unchanged = switch (node.style.height) {
            .px => |height| @abs(height - desired) <= 0.001,
            else => false,
        };
        if (unchanged) return;
        // Component-inline: a layered field keeps it across its own style replays.
        node.setStyleInline(self.allocator, .{ .height = .{ .px = desired } });
    }

    // ========== Blink ==========

    /// Reset cursor blink counter (show cursor immediately after action)
    pub fn resetBlink(self: *TextInputState) void {
        self.blink.reset(self.io);
        self.last_blink_visible = true;
    }

    pub fn blinkVisible(self: *TextInputState, now: @import("zenit_time").Instant) bool {
        return self.blink.visible(now);
    }

    pub fn nextBlinkDelayNs(self: *const TextInputState, now: @import("zenit_time").Instant) u64 {
        return self.blink.nextDelayNs(now);
    }

    // ========== IME ==========

    pub fn hasImePreedit(self: *const TextInputState) bool {
        return self.ime_preedit_len > 0;
    }

    pub fn imeIsComposing(self: *const TextInputState) bool {
        return self.ime_phase == .composing;
    }

    pub fn shouldShowImeSelectionHighlight(self: *const TextInputState) bool {
        return self.hasImePreedit() and (if (self.ime_selection_end) |end| end != self.ime_cursor_utf8_offset else self.ime_selection_highlight);
    }

    fn clearImePendingCommit(self: *TextInputState) void {
        self.ime_pending_commit.deinit();
    }

    pub fn endImePendingCommit(self: *TextInputState) void {
        self.clearImePendingCommit();
        if (self.ime_phase == .commit_pending_end) self.ime_phase = .idle;
    }

    fn isImePendingCommitText(self: *const TextInputState, text: []const u8) bool {
        return text.len > 0 and std.mem.eql(u8, self.ime_pending_commit.text(), text);
    }

    pub fn setImeAttributes(self: *TextInputState, visible: bool, end: ?u32) void {
        self.ime_cursor_visible = visible;
        self.ime_selection_end = if (end) |value| text_coordinates.clampByteOffset(self.preeditText(), .{ .value = value }, .forward).value else null;
    }
    pub fn handleImeDeleteSurrounding(self: *TextInputState, before: u32, after: u32) !void {
        const caret = self.cursor_pos;
        const anchor = self.selection_anchor;
        const range = @import("../../core/text_input_protocol.zig").deletion(self.getText(), caret, anchor orelse caret, before, after) orelse return;
        var selected = try ImeText.init(self.allocator, self.getText()[range.selection_start..range.selection_end]);
        defer selected.deinit();
        try self.handleImeCommitReplaceEventChecked(selected.text(), @intCast(range.start), @intCast(range.end));
        self.cursor_pos = caret - before;
        self.selection_anchor = if (anchor) |value| value - before else null;
        self.syncDocFromCursor();
    }

    pub fn effectiveImeCursorOffset(self: *const TextInputState) usize {
        if (self.ime_selection_end != null) return self.ime_cursor_utf8_offset;
        const raw = editable_block.effectiveImeCursorOffset(
            self.ime_preedit_len,
            self.ime_cursor_utf8_offset,
            self.ime_selection_highlight,
        );
        return text_coordinates.clampByteOffset(
            self.preeditText(),
            .{ .value = raw },
            .forward,
        ).value;
    }

    pub fn imeInsertOffsetForDisplaySegment(self: *const TextInputState, doc: *const TextareaDocument, buffer_line: usize, seg_start: usize, seg_end: usize) ?usize {
        if (!self.hasImePreedit()) return null;
        const cursor = self.cursor_pos;
        if (cursor < seg_start) return null;
        if (cursor < seg_end) return cursor - seg_start;
        if (cursor == seg_end) {
            const line_end = doc.getLineEnd(buffer_line);
            if (cursor == line_end) return seg_end - seg_start;
        }
        return null;
    }

    pub fn composeDisplaySegmentWithIme(self: *TextInputState, seg_text: []const u8, insert_offset: usize) []const u8 {
        return self.composeDisplaySegmentWithImeChecked(seg_text, insert_offset) catch seg_text;
    }

    pub fn composeDisplaySegmentWithImeChecked(self: *TextInputState, seg_text: []const u8, insert_offset: usize) ![]const u8 {
        const required = std.math.add(usize, seg_text.len, self.ime_preedit_len) catch return error.OutOfMemory;
        const out = try self.imeSegmentStorage(required);
        if (self.ime_replacement) |replacement| return replacement.compose(seg_text, self.cursor_pos -| insert_offset, self.preeditText(), true, out);
        return editable_block.composePreeditIntoBuffer(seg_text, insert_offset, self.preeditText(), out);
    }

    /// Recompute multiline IME geometry from the *visible* document
    /// (committed text + preedit). The canonical WrapMap intentionally remains
    /// committed-only so editing offsets and undo history never observe
    /// transient IME bytes.
    pub fn refreshMultilineImeGeometry(self: *TextInputState) void {
        self.ime_visual_valid = false;
        self.ime_visual_total_lines = 0;
        if (!self.multiline or !self.hasImePreedit() or self.textarea_doc == null or self.textarea_wrap == null) return;

        const allocator = self.textarea_doc.?.allocator;
        const visible = self.buildDisplayTextChecked(null) catch return;
        var display_doc: TextareaDocument = .{ .allocator = allocator };
        defer display_doc.deinit();
        display_doc.setTextChecked(visible) catch return;

        var display_wrap = TextareaWrapMap.init(allocator, self.io);
        defer display_wrap.deinit();
        const canonical_wrap = self.textarea_wrap.?;
        display_wrap.measure_fn = canonical_wrap.measure_fn;
        display_wrap.measure_ctx_fn = canonical_wrap.measure_ctx_fn;
        display_wrap.measure_ctx = canonical_wrap.measure_ctx;
        display_wrap.char_width = self.char_width;
        display_wrap.precise_wrap = canonical_wrap.precise_wrap;
        display_wrap.font_size = self.font_size;
        display_wrap.font_weight = self.font_weight;
        display_wrap.tab_size = canonical_wrap.tab_size;
        display_wrap.setWrapWidth(self.input_inner_w, &display_doc);
        display_wrap.setEnabled(true, &display_doc);
        display_wrap.rebuildAll(&display_doc);
        _ = display_wrap.rewrapInterpolatedAll(&display_doc);
        if (display_wrap.needs_rebuild or display_wrap.has_interpolated_lines) return;

        const cursor_byte = @min(self.cursor_pos + self.effectiveImeCursorOffset(), display_doc.totalLength());
        const lc = display_doc.offsetToLineCol(cursor_byte);
        const point = display_wrap.bufferToDisplay(lc.line, lc.col);
        const info = display_wrap.displayLineInfo(point.display_line, &display_doc);
        const seg = safeSegRange(&display_doc, info);
        const segment = display_doc.getText()[seg.start..seg.end];
        const local_cursor = @min(cursor_byte -| seg.start, segment.len);

        var cursor_x = text_utils.utf8MeasuredAdvancePrefixCx(
            self.cx_ref,
            segment,
            local_cursor,
            self.char_width,
            self.font_size,
            self.font_weight,
        );
        var underline_start_x = cursor_x;
        var underline_end_x = cursor_x;
        if (self.cx_ref) |cx| {
            if (cx.text.visualLine(.{
                .text = segment,
                .font_family = "system",
                .font_size = self.font_size,
                .font_weight = self.font_weight,
            }) catch null) |line| {
                if (line.positionToCaret(.{
                    .byte = .{ .value = local_cursor },
                    .affinity = .downstream,
                }) catch null) |caret| cursor_x = caret.x.value;

                const preedit_start = @min(self.cursor_pos, display_doc.totalLength());
                const preedit_end = @min(self.cursor_pos + self.ime_preedit_len, display_doc.totalLength());
                const visible_start = std.math.clamp(preedit_start, seg.start, seg.end) - seg.start;
                const visible_end = std.math.clamp(preedit_end, seg.start, seg.end) - seg.start;
                if (line.positionToCaret(.{
                    .byte = .{ .value = visible_start },
                    .affinity = .downstream,
                }) catch null) |caret| underline_start_x = caret.x.value;
                if (line.positionToCaret(.{
                    .byte = .{ .value = visible_end },
                    .affinity = .upstream,
                }) catch null) |caret| underline_end_x = caret.x.value;
            }
        }

        self.ime_visual_valid = true;
        self.ime_visual_display_line = point.display_line;
        self.ime_visual_cursor_x = cursor_x;
        self.ime_visual_underline_x = @min(underline_start_x, underline_end_x);
        self.ime_visual_underline_width = @max(@abs(underline_end_x - underline_start_x), @max(4.0, self.char_width * 0.5));
        self.ime_visual_total_lines = @max(@as(u32, 1), display_wrap.displayLineCount());
    }

    pub fn preeditText(self: *const TextInputState) []const u8 {
        return self.ime_preedit.text();
    }

    fn scratch(self: *TextInputState, inline_bytes: []u8, overflow: *std.ArrayListUnmanaged(u8), required: usize) ![]u8 {
        if (required <= inline_bytes.len) return inline_bytes[0..required];
        try overflow.resize(self.allocator, required);
        return overflow.items;
    }

    pub fn imeSegmentStorage(self: *TextInputState, required: usize) ![]u8 {
        return self.scratch(&self.ime_segment_buffer, &self.ime_segment_overflow, required);
    }

    fn prepareImePreedit(self: *TextInputState, text: []const u8) !ImeText {
        var candidate = try ImeText.init(self.allocator, text);
        errdefer candidate.deinit();
        // Reserve complete display projections before changing selection or
        // replacing the previous candidate. Cached nodes own their snapshots.
        const required = std.math.add(usize, self.getText().len, text.len) catch return error.OutOfMemory;
        _ = try self.scratch(&self.display_buffer, &self.display_overflow, required);
        _ = try self.imeSegmentStorage(required);
        const wrapped = std.math.mul(usize, required, 2) catch return error.OutOfMemory;
        _ = try self.scratch(&self.wrapped_display_buffer, &self.wrapped_display_overflow, wrapped);
        return candidate;
    }

    pub fn setImePreedit(self: *TextInputState, text: []const u8, cursor_utf8_offset: u32) void {
        self.setImePreeditChecked(text, cursor_utf8_offset) catch return;
    }

    pub fn setImePreeditChecked(self: *TextInputState, text: []const u8, cursor_utf8_offset: u32) !void {
        var candidate = try self.prepareImePreedit(text);
        errdefer candidate.deinit();
        try self.publishImePreedit(candidate, cursor_utf8_offset);
    }

    fn publishImePreedit(self: *TextInputState, candidate: ImeText, cursor_utf8_offset: u32) !void {
        const saved_cursor = self.cursor_pos;
        const saved_anchor = self.selection_anchor;
        const saved_doc_cursor = self.textarea_cursor;
        const saved_replacement = self.ime_replacement;
        errdefer {
            self.cursor_pos = saved_cursor;
            self.selection_anchor = saved_anchor;
            self.textarea_cursor = saved_doc_cursor;
            self.ime_replacement = saved_replacement;
        }
        // NSNotFound means replace the current selection, not append at its
        // active end. Stage it just like explicit reconversion so preedit hides
        // the selected text without mutating the document/history until commit.
        if (candidate.len > 0 and self.ime_replacement == null) {
            if (self.selection_anchor) |anchor| {
                if (anchor != self.cursor_pos) {
                    const start = @min(anchor, self.cursor_pos);
                    const end = @max(anchor, self.cursor_pos);
                    self.ime_replacement = .{ .start = start, .end = end, .cursor = self.cursor_pos, .anchor = anchor };
                    self.cursor_pos = start;
                    self.selection_anchor = end;
                    self.syncDocFromCursor();
                }
            }
        }
        var previous = self.ime_preedit;
        const previous_cursor = self.ime_cursor_utf8_offset;
        errdefer {
            self.ime_preedit = previous;
            self.ime_preedit_len = previous.len;
            self.ime_cursor_utf8_offset = previous_cursor;
        }
        self.ime_preedit = candidate;
        self.ime_preedit_len = candidate.len;
        self.ime_cursor_visible = true;
        self.ime_selection_end = null;
        self.ime_cursor_utf8_offset = text_coordinates.clampByteOffset(
            self.preeditText(),
            .{ .value = cursor_utf8_offset },
            .forward,
        ).value;
        // Preparing the retained snapshot can fail too. Publish phase and
        // selection only once the node can own the complete projection.
        _ = try self.syncDisplayTextContentChecked();
        previous.deinit();
        // Keep non-empty selection for ime_commit / fallback text_input to apply over-selection.
        // Collapsed selection (anchor == cursor) safe to clear.
        if (self.selection_anchor) |anchor| {
            if (anchor == self.cursor_pos) self.selection_anchor = null;
        }
        self.ime_phase = .composing;
        self.clearImePendingCommit();
        self.dirty = true;
        self.resetBlink();
        // Preedit change modifies display text; must mark dirty, else zero-dirty fast-path skips
        // inputBeforeRender/relayout.
        self.markVisualDirty();
    }

    pub fn clearImePreedit(self: *TextInputState) void {
        self.ime_cursor_visible = true;
        self.ime_selection_end = null;
        self.ime_preedit.deinit();
        self.ime_replacement = null;
        self.ime_visual_valid = false;
        self.ime_visual_total_lines = 0;
        if (self.ime_preedit_len > 0) {
            self.ime_preedit_len = 0;
            self.ime_cursor_utf8_offset = 0;
            self.dirty = true;
            self.resetBlink();
            self.markVisualDirty();
        } else {
            self.ime_preedit_len = 0;
            self.ime_cursor_utf8_offset = 0;
        }
    }

    /// Composition abandoned: return to pre-composition baseline and notify binding
    /// (on_ime_cancelled) to apply deferred external writes.
    pub fn cancelImeComposition(self: *TextInputState) void {
        self.endImeComposition(true);
    }

    /// Composition replaced by single write (setText / AX write): end composition but do NOT emit
    /// on_ime_cancelled.
    /// Replace write becomes baseline; if emitted, binding applies deferred value, overwriting
    /// just-written content (AX write lost).
    /// Deferred writes thereafter handled normally: AX write proposed via on_change, landing
    /// invalidates defer.
    pub fn supersedeImeComposition(self: *TextInputState) void {
        self.endImeComposition(false);
    }

    fn endImeComposition(self: *TextInputState, notify: bool) void {
        const was_composing = self.ime_phase == .composing;
        defer if (was_composing and notify) {
            if (self.on_ime_cancelled) |h| h.invoke();
        };
        if (self.ime_replacement) |replacement| {
            self.cursor_pos = @min(replacement.cursor, self.getText().len);
            self.selection_anchor = if (replacement.anchor) |anchor| @min(anchor, self.getText().len) else null;
            self.syncDocFromCursor();
        }
        self.clearImePreedit();
        self.ime_phase = .idle;
        self.clearImePendingCommit();
        self.ime_selection_highlight = false;
    }

    /// IME replacementRange: set [start,end) UTF-8 bytes as selection for subsequent insert/delete.
    /// Sentinel or invalid range (start > end / out-of-bounds) no-op, degrade to cursor behavior.
    /// Char-boundary clamping done inside insertText/deleteRange.
    pub fn applyImeReplacementRange(self: *TextInputState, replace_start_utf8: u32, replace_end_utf8: u32) bool {
        if (replace_start_utf8 == events.ime_no_replacement or
            replace_end_utf8 == events.ime_no_replacement) return false;
        if (replace_start_utf8 > replace_end_utf8) return false;
        const doc_len: usize = if (self.textarea_doc) |doc| doc.totalLength() else self.buffer_len;
        const start: usize = replace_start_utf8;
        const end: usize = replace_end_utf8;
        // Bridge range may be stale (async frame); reject out-of-bounds rather than clamp.
        // Prefer degraded behavior over incorrect deletion.
        if (end > doc_len) return false;
        const text = self.getText();
        const lo = text_coordinates.clampByteOffset(text, .{ .value = start }, .backward).value;
        const hi = if (start == end) lo else text_coordinates.clampByteOffset(text, .{ .value = end }, .forward).value;
        self.cursor_pos = hi;
        self.selection_anchor = if (lo == hi) null else lo;
        if (self.textarea_doc != null) self.syncDocFromCursor();
        return true;
    }

    /// IME commit with replacementRange: non-sentinel replaces document range (Japanese
    /// retransformation, word-replace IME).
    pub fn handleImeCommitReplaceEvent(self: *TextInputState, text: []const u8, replace_start_utf8: u32, replace_end_utf8: u32) void {
        self.handleImeCommitReplaceEventChecked(text, replace_start_utf8, replace_end_utf8) catch return;
    }

    pub fn handleImeCommitReplaceEventChecked(self: *TextInputState, text: []const u8, replace_start_utf8: u32, replace_end_utf8: u32) !void {
        const cursor = self.cursor_pos;
        const anchor = self.selection_anchor;
        const doc_cursor = self.textarea_cursor;
        errdefer {
            self.cursor_pos = cursor;
            self.selection_anchor = anchor;
            self.textarea_cursor = doc_cursor;
        }
        const applied = self.applyImeReplacementRange(replace_start_utf8, replace_end_utf8);
        if (applied and text.len == 0) try self.insertTextChecked("");
        try self.handleImeCommitEventChecked(text);
    }

    /// Stage reconversion as a display replacement; canonical text and history
    /// remain intact until the subsequent checked commit succeeds.
    pub fn handleImePreeditReplaceEvent(self: *TextInputState, text: []const u8, cursor_utf8_offset: u32, replace_start_utf8: u32, replace_end_utf8: u32) void {
        self.handleImePreeditReplaceEventChecked(text, cursor_utf8_offset, replace_start_utf8, replace_end_utf8) catch return;
    }

    pub fn handleImePreeditReplaceEventChecked(self: *TextInputState, text: []const u8, cursor_utf8_offset: u32, replace_start_utf8: u32, replace_end_utf8: u32) !void {
        if (text.len == 0) {
            self.handleImePreeditEvent(text, cursor_utf8_offset);
            return;
        }
        var candidate = try self.prepareImePreedit(text);
        errdefer candidate.deinit();
        const saved_cursor = self.cursor_pos;
        const saved_anchor = self.selection_anchor;
        const saved_doc_cursor = self.textarea_cursor;
        const saved_replacement = self.ime_replacement;
        errdefer {
            self.cursor_pos = saved_cursor;
            self.selection_anchor = saved_anchor;
            self.textarea_cursor = saved_doc_cursor;
            self.ime_replacement = saved_replacement;
        }
        if (text.len > 0) {
            const original_cursor = self.cursor_pos;
            const original_anchor = self.selection_anchor;
            if (self.applyImeReplacementRange(replace_start_utf8, replace_end_utf8)) {
                const start = self.selection_anchor orelse self.cursor_pos;
                const end = self.cursor_pos;
                var replacement = self.ime_replacement orelse ImeReplacement{ .start = start, .end = end, .cursor = original_cursor, .anchor = original_anchor };
                replacement.start = start;
                replacement.end = end;
                self.ime_replacement = replacement;
                self.cursor_pos = start;
                self.selection_anchor = if (start == end) null else end;
                self.syncDocFromCursor();
            }
        }
        try self.publishImePreedit(candidate, cursor_utf8_offset);
    }

    pub fn handleImePreeditEvent(self: *TextInputState, text: []const u8, cursor_utf8_offset: u32) void {
        if (text.len == 0) {
            if (self.ime_phase == .composing) self.cancelImeComposition() else self.clearImePreedit();
            return;
        }
        self.setImePreedit(text, cursor_utf8_offset);
    }

    pub fn handleImeCommitEvent(self: *TextInputState, text: []const u8) void {
        self.handleImeCommitEventChecked(text) catch return;
    }

    pub fn handleImeCommitEventChecked(self: *TextInputState, text: []const u8) !void {
        var candidate = try ImeText.init(self.allocator, text);
        defer candidate.deinit();
        if (text.len > 0 or self.ime_replacement != null) try self.insertTextChecked(candidate.text());
        self.clearImePreedit();
        self.clearImePendingCommit();
        self.ime_pending_commit = candidate;
        candidate = .{};
        self.ime_phase = if (text.len > 0) .commit_pending_end else .idle;
        self.ime_selection_highlight = false;
    }

    pub fn handleImeFallbackTextInput(self: *TextInputState, text: []const u8) void {
        self.handleImeCommitEvent(text);
    }

    pub fn consumeImePostCommitDuplicate(self: *TextInputState, text: []const u8) bool {
        if (self.ime_phase != .commit_pending_end) return false;
        const duplicate = self.isImePendingCommitText(text);
        self.ime_phase = .idle;
        self.clearImePendingCommit();
        self.ime_selection_highlight = false;
        return duplicate;
    }

    pub fn markImeSelectionHighlight(self: *TextInputState) void {
        if (self.imeIsComposing()) {
            self.ime_selection_highlight = true;
            self.dirty = true;
        }
    }

    // ========== Display/Measurement ==========

    pub fn displayedTextLen(self: *const TextInputState) usize {
        const removed = if (self.ime_replacement) |replacement| text_utils.utf8GraphemeLen(self.getText()[@min(replacement.start, self.getText().len)..@min(replacement.end, self.getText().len)]) else 0;
        return text_utils.utf8GraphemeLen(self.getText()) -| removed +
            text_utils.utf8GraphemeLen(self.preeditText());
    }

    pub fn visualCursorPos(self: *const TextInputState) usize {
        if (self.input_type == .password) return self.maskedCpForBufferPrefix(self.cursor_pos) + self.maskedCpForPreeditPrefix(self.effectiveImeCursorOffset());
        const base_units = text_utils.utf8DisplayUnitsPrefix(self.singleLineBuffer()[0..self.buffer_len], self.cursor_pos);
        const preedit_units = text_utils.utf8DisplayUnitsPrefix(
            self.preeditText(),
            self.effectiveImeCursorOffset(),
        );
        return base_units + preedit_units;
    }

    /// Password mode mask replaces real buffer for measurement.
    /// CJK IME into password: buffer holds UTF-8 multibyte (double-width display) but screen draws
    /// single-width ASCII '*'.
    /// Cursor position must calculate from displayed mask; mismatch causes offset bug.
    /// Mask = N identical '*'; shape once, multiply by N, avoid O(N) calls to ShapingCache.
    fn singleStarAdvance(self: *TextInputState) f32 {
        if (self.cached_star_font_size == self.font_size and
            self.cached_star_font_weight == self.font_weight and
            self.cached_star_advance > 0)
        {
            return self.cached_star_advance;
        }
        const adv = text_utils.utf8MeasuredAdvanceCx(self.cx_ref, "*", self.char_width, self.font_size, self.font_weight);
        self.cached_star_advance = adv;
        self.cached_star_font_size = self.font_size;
        self.cached_star_font_weight = self.font_weight;
        return adv;
    }

    fn maskedCpForBufferPrefix(self: *const TextInputState, prefix_byte_end: usize) usize {
        return text_utils.utf8GraphemeLen(self.singleLineBuffer()[0..@min(prefix_byte_end, self.buffer_len)]);
    }

    fn maskedCpForPreeditPrefix(self: *const TextInputState, end_byte: usize) usize {
        return text_utils.utf8GraphemeLen(self.preeditText()[0..@min(end_byte, self.ime_preedit_len)]);
    }

    pub fn visualCursorAdvance(self: *const TextInputState) f32 {
        if (self.input_type == .password) {
            const star = @constCast(self).singleStarAdvance();
            const base_cp = self.maskedCpForBufferPrefix(self.cursor_pos);
            const preedit_cp = self.maskedCpForPreeditPrefix(self.effectiveImeCursorOffset());
            return star * @as(f32, @floatFromInt(base_cp + preedit_cp));
        }
        if (self.cx_ref) |cx| {
            const display = @constCast(self).buildDisplayText(null);
            const display_byte = @min(self.cursor_pos + self.effectiveImeCursorOffset(), display.len);
            if (text_utils.visualCaretX(cx, display, .{
                .byte = .{ .value = display_byte },
                .affinity = if (self.hasImePreedit()) .downstream else self.cursor_affinity,
            }, self.font_size, self.font_weight)) |x| return x;
        }
        const base_adv = if (self.cx_ref) |cx|
            text_utils.visualCaretX(cx, self.singleLineBuffer()[0..self.buffer_len], .{
                .byte = .{ .value = self.cursor_pos },
                .affinity = self.cursor_affinity,
            }, self.font_size, self.font_weight) orelse text_utils.utf8MeasuredAdvancePrefixCx(
                self.cx_ref,
                self.singleLineBuffer()[0..self.buffer_len],
                self.cursor_pos,
                self.char_width,
                self.font_size,
                self.font_weight,
            )
        else
            text_utils.utf8MeasuredAdvancePrefixCx(
                null,
                self.singleLineBuffer()[0..self.buffer_len],
                self.cursor_pos,
                self.char_width,
                self.font_size,
                self.font_weight,
            );
        const preedit_adv = text_utils.utf8MeasuredAdvancePrefixCx(
            self.cx_ref,
            self.preeditText(),
            self.effectiveImeCursorOffset(),
            self.char_width,
            self.font_size,
            self.font_weight,
        );
        return base_adv + preedit_adv;
    }

    pub fn displayedTextAdvance(self: *const TextInputState) f32 {
        if (self.input_type == .password) {
            const star = @constCast(self).singleStarAdvance();
            return star * @as(f32, @floatFromInt(self.displayedTextLen()));
        }
        if (self.hasImePreedit()) {
            const display = @constCast(self).buildDisplayText(null);
            return text_utils.utf8MeasuredAdvanceCx(self.cx_ref, display, self.char_width, self.font_size, self.font_weight);
        }
        return text_utils.utf8MeasuredAdvanceCx(self.cx_ref, self.singleLineBuffer()[0..self.buffer_len], self.char_width, self.font_size, self.font_weight) +
            text_utils.utf8MeasuredAdvanceCx(self.cx_ref, self.preeditText(), self.char_width, self.font_size, self.font_weight);
    }

    pub fn imePreeditStartAdvance(self: *const TextInputState) f32 {
        if (self.input_type == .password) {
            const star = @constCast(self).singleStarAdvance();
            const base_cp = self.maskedCpForBufferPrefix(self.cursor_pos);
            return star * @as(f32, @floatFromInt(base_cp));
        }
        if (self.cx_ref) |cx| {
            const display = @constCast(self).buildDisplayText(null);
            if (text_utils.visualCaretX(cx, display, .{
                .byte = .{ .value = @min(self.cursor_pos, display.len) },
                .affinity = self.cursor_affinity,
            }, self.font_size, self.font_weight)) |x| return x;
        }
        return text_utils.utf8MeasuredAdvancePrefixCx(
            self.cx_ref,
            self.singleLineBuffer()[0..self.buffer_len],
            self.cursor_pos,
            self.char_width,
            self.font_size,
            self.font_weight,
        );
    }

    pub fn imePreeditAdvance(self: *const TextInputState) f32 {
        if (self.input_type == .password) {
            const star = @constCast(self).singleStarAdvance();
            const preedit_cp = self.maskedCpForPreeditPrefix(self.ime_preedit_len);
            return star * @as(f32, @floatFromInt(preedit_cp));
        }
        return text_utils.utf8MeasuredAdvanceCx(
            self.cx_ref,
            self.preeditText(),
            self.char_width,
            self.font_size,
            self.font_weight,
        );
    }

    pub fn hasVisualValue(self: *const TextInputState) bool {
        if (self.textarea_doc) |doc| return doc.totalLength() > 0 or self.hasImePreedit();
        return self.buffer_len > 0 or self.hasImePreedit();
    }

    // ========== Soft-wrap ==========

    pub const MultilineVisualPos = struct {
        row: usize = 0,
        x: f32 = 0,
    };

    pub const TextareaVisualLine = struct {
        start: usize,
        end: usize,
        display_line: u32,
        line: text_coordinates.VisualLine,

        pub fn caretX(self: TextareaVisualLine, global_byte: usize, affinity: text_coordinates.Affinity) f32 {
            const local_byte = @min(global_byte -| self.start, self.end - self.start);
            const exact = self.line.positionToCaret(.{
                .byte = .{ .value = local_byte },
                .affinity = affinity,
            }) catch {
                for (self.line.caret_stops) |stop| {
                    if (stop.position.byte.value == local_byte) return stop.x.value;
                }
                return 0;
            };
            return exact.x.value;
        }

        pub fn visualNeighbour(
            self: TextareaVisualLine,
            global_byte: usize,
            affinity: text_coordinates.Affinity,
            delta: i32,
        ) ?text_coordinates.TextPosition {
            if (delta == 0 or self.line.caret_stops.len == 0) return null;
            const local_byte = @min(global_byte -| self.start, self.end - self.start);
            var current_index: ?usize = null;
            for (self.line.caret_stops, 0..) |stop, i| {
                if (stop.position.byte.value == local_byte and stop.position.affinity == affinity) {
                    current_index = i;
                    break;
                }
            }
            if (current_index == null) {
                for (self.line.caret_stops, 0..) |stop, i| {
                    if (stop.position.byte.value == local_byte) {
                        current_index = i;
                        break;
                    }
                }
            }
            const index = current_index orelse return null;
            const magnitude: usize = @intCast(if (delta < 0) -delta else delta);
            if (delta < 0) {
                if (magnitude > index) return null;
                return self.line.caret_stops[index - magnitude].position;
            }
            if (index + magnitude >= self.line.caret_stops.len) return null;
            return self.line.caret_stops[index + magnitude].position;
        }
    };

    pub fn visualLineForSegment(self: *const TextInputState, start: usize, end: usize, display_line: u32) ?TextareaVisualLine {
        const doc = self.textarea_doc orelse return null;
        const cx = self.cx_ref orelse return null;
        const text = doc.getText();
        if (start > end or end > text.len) return null;
        const line = cx.text.visualLine(.{
            .text = text[start..end],
            .font_family = "system",
            .font_size = self.font_size,
            .font_weight = self.font_weight,
        }) catch return null;
        return .{ .start = start, .end = end, .display_line = display_line, .line = line };
    }

    pub fn textareaVisualLineAtOffset(self: *const TextInputState, global_byte: usize) ?TextareaVisualLine {
        const doc = self.textarea_doc orelse return null;
        const byte = @min(global_byte, doc.totalLength());
        const lc = doc.offsetToLineCol(byte);
        if (self.textarea_wrap) |wrap| {
            var display_line = wrap.bufferToDisplay(lc.line, lc.col).display_line;
            const info = wrap.displayLineInfo(display_line, doc);
            var seg = safeSegRange(doc, info);
            // The same byte can be the downstream start of one soft line and
            // upstream end of the previous line. Affinity selects that side.
            if (self.cursor_affinity == .upstream and byte == seg.start and display_line > 0) {
                const previous_info = wrap.displayLineInfo(display_line - 1, doc);
                const previous_seg = safeSegRange(doc, previous_info);
                if (previous_seg.end == byte) {
                    display_line -= 1;
                    seg = previous_seg;
                }
            }
            return self.visualLineForSegment(seg.start, seg.end, display_line);
        }
        return self.visualLineForSegment(
            doc.getLineStart(lc.line),
            doc.getLineEnd(lc.line),
            @intCast(lc.line),
        );
    }

    pub fn shouldSoftWrap(self: *const TextInputState) bool {
        return self.multiline and self.soft_wrap and self.input_inner_w > 0;
    }

    pub fn updateInnerWidthFromContainer(self: *TextInputState, node: *const core.Node) bool {
        return editable_block.syncInnerWidthFromNode(self, node);
    }

    pub fn displayCursorByteOffset(self: *const TextInputState) usize {
        const base = @min(self.cursor_pos, self.getText().len);
        if (self.ime_preedit_len == 0) return base;
        const preedit_cursor = self.effectiveImeCursorOffset();
        return base + preedit_cursor;
    }

    pub fn multilineVisualPosForOffset(self: *const TextInputState, text: []const u8, end_bytes: usize) MultilineVisualPos {
        if (self.textarea_doc) |doc| {
            if (std.mem.eql(u8, text, doc.getText())) {
                if (self.textareaVisualLineAtOffset(@min(end_bytes, text.len))) |geometry| {
                    return .{
                        .row = geometry.display_line,
                        .x = geometry.caretX(@min(end_bytes, text.len), self.cursor_affinity),
                    };
                }
            }
        }
        var pos = MultilineVisualPos{};
        var i: usize = 0;
        var boundaries = @import("text_core").grapheme.BoundaryCursor.init(text);
        const end = @min(end_bytes, text.len);
        while (i < end) {
            const b = text[i];
            if (b == '\n') {
                pos.row += 1;
                pos.x = 0;
                i += 1;
                continue;
            }

            const step = boundaries.next(i) - i;
            const advance = text_utils.utf8MeasuredAdvanceCx(
                self.cx_ref,
                text[i .. i + step],
                self.char_width,
                self.font_size,
                self.font_weight,
            );
            if (self.shouldSoftWrap() and pos.x > 0 and pos.x + advance > self.input_inner_w) {
                pos.row += 1;
                pos.x = 0;
            }
            pos.x += advance;
            i += step;
        }
        return pos;
    }

    fn nextUtf8CharEnd(text: []const u8, offset: usize) usize {
        if (offset >= text.len) return text.len;
        var cp: u21 = 0;
        const step = text_utils.utf8DecodeNext(text, offset, &cp);
        return @min(offset + step, text.len);
    }

    pub fn hitTestCursorPosMultiline(self: *TextInputState, global_x: f32, global_y: f32) usize {
        const target_x = @max(0, global_x - self.container_x - self.padding_h);
        const local_y = @max(0, global_y - self.container_y - self.padding_v);
        const lh = @max(self.line_height, 1.0);
        const target_row: usize = @intFromFloat(@floor(local_y / lh));

        // WrapMap path: fast locate to buffer line via displayLineInfo
        if (self.textarea_wrap) |wrap| {
            if (self.textarea_doc) |doc| {
                const dl: u32 = @intCast(@min(target_row, if (wrap.total_display_lines > 0) wrap.total_display_lines - 1 else 0));
                const info = wrap.displayLineInfo(dl, doc);
                const seg = safeSegRange(doc, info);
                const txt = doc.getText();
                const seg_text = txt[seg.start..seg.end];

                if (self.visualLineForSegment(seg.start, seg.end, dl)) |geometry| {
                    const position = geometry.line.xToPosition(.{ .value = target_x });
                    self.cursor_affinity = position.affinity;
                    self.preferred_visual_x = null;
                    return seg.start + position.byte.value;
                }
                // Font provider unavailable: keep the grapheme-safe fallback.
                return seg.start + text_utils.utf8ByteOffsetForMeasuredXCx(
                    self.cx_ref,
                    seg_text,
                    target_x,
                    self.char_width,
                    self.font_size,
                    self.font_weight,
                );
            }
        }

        // Fallback: old O(N^2) path
        const text = self.getText();
        var best_off: usize = 0;
        var best_row_dist: usize = std.math.maxInt(usize);
        var best_x_dist: f32 = std.math.inf(f32);

        var off: usize = 0;
        while (true) {
            const pos = self.multilineVisualPosForOffset(text, off);
            const row_dist = if (pos.row > target_row) pos.row - target_row else target_row - pos.row;
            const x_dist = @abs(pos.x - target_x);
            if (row_dist < best_row_dist or (row_dist == best_row_dist and x_dist < best_x_dist)) {
                best_row_dist = row_dist;
                best_x_dist = x_dist;
                best_off = off;
            }
            if (off >= text.len) break;
            off = nextUtf8CharEnd(text, off);
        }
        return best_off;
    }

    pub fn appendWrappedLines(
        self: *TextInputState,
        text: []const u8,
        out: []u8,
    ) []const u8 {
        if (!self.shouldSoftWrap() or text.len == 0) return text;

        var out_len: usize = 0;
        var i: usize = 0;
        var boundaries = @import("text_core").grapheme.BoundaryCursor.init(text);
        var line_x: f32 = 0;
        while (i < text.len and out_len < out.len) {
            const b = text[i];
            if (b == '\n') {
                out[out_len] = '\n';
                out_len += 1;
                i += 1;
                line_x = 0;
                continue;
            }

            const step = boundaries.next(i) - i;
            const advance = text_utils.utf8MeasuredAdvanceCx(
                self.cx_ref,
                text[i .. i + step],
                self.char_width,
                self.font_size,
                self.font_weight,
            );
            if (line_x > 0 and line_x + advance > self.input_inner_w and out_len < out.len) {
                out[out_len] = '\n';
                out_len += 1;
                line_x = 0;
            }

            if (step > out.len - out_len) break;
            const copy_len = step;
            if (copy_len > 0) {
                @memcpy(out[out_len .. out_len + copy_len], text[i .. i + copy_len]);
                out_len += copy_len;
                line_x += advance;
            }
            i += step;
        }
        return out[0..out_len];
    }

    pub fn buildWrappedDisplayTextChecked(self: *TextInputState, placeholder: ?[]const u8) ![]const u8 {
        const display = try self.buildDisplayTextChecked(placeholder);
        if (!self.shouldSoftWrap()) return display;
        const required = std.math.mul(usize, display.len, 2) catch return error.OutOfMemory;
        const out = try self.scratch(&self.wrapped_display_buffer, &self.wrapped_display_overflow, required);
        return self.appendWrappedLines(display, out);
    }

    /// Borrowed until the next display/state operation. Retained nodes must copy.
    pub fn buildDisplayText(self: *TextInputState, placeholder: ?[]const u8) []const u8 {
        return self.buildDisplayTextChecked(placeholder) catch "";
    }

    pub fn buildDisplayTextChecked(self: *TextInputState, placeholder: ?[]const u8) ![]const u8 {
        const text = self.getText();
        if (text.len == 0 and self.ime_preedit_len == 0) return placeholder orelse "";
        if (self.input_type == .password) {
            const out = try self.scratch(&self.display_buffer, &self.display_overflow, self.displayedTextLen());
            @memset(out, '*');
            return out;
        }
        if (self.ime_preedit_len == 0) return text;
        const required = std.math.add(usize, text.len, self.ime_preedit_len) catch return error.OutOfMemory;
        const out = try self.scratch(&self.display_buffer, &self.display_overflow, required);
        if (self.ime_replacement) |replacement| return replacement.compose(text, 0, self.preeditText(), true, out);
        return editable_block.composePreeditIntoBuffer(text, @min(self.cursor_pos, text.len), self.preeditText(), out);
    }

    // ========== Word boundary + selection ==========

    /// Find word boundary leftward from pos (CJK-aware: each CJK char is separate word)
    pub fn findWordBoundaryLeft(self: *const TextInputState, pos: usize) usize {
        if (pos == 0) return 0;
        if (self.textarea_doc) |doc| {
            return DocCursor(TextareaDocument).prevWordBoundary(doc, pos);
        }
        const text = self.getText();
        var p = pos;

        // Check char category left of pos
        const first = text_utils.utf8DecodePrev(text, p);
        const first_class = text_utils.classifyCodepoint(first.cp);

        if (first_class == .cjk) {
            // CJK: skip one only
            return first.start;
        }

        if (first_class == .separator) {
            // Skip consecutive separators
            p = first.start;
            while (p > 0) {
                const prev = text_utils.utf8DecodePrev(text, p);
                if (text_utils.classifyCodepoint(prev.cp) != .separator) break;
                p = prev.start;
            }
            // If at start or encounter CJK, return
            if (p == 0) return 0;
            const next_prev = text_utils.utf8DecodePrev(text, p);
            if (text_utils.classifyCodepoint(next_prev.cp) == .cjk) return next_prev.start;
            // Continue skipping word chars
            while (p > 0) {
                const prev = text_utils.utf8DecodePrev(text, p);
                if (text_utils.classifyCodepoint(prev.cp) != .word) break;
                p = prev.start;
            }
            return p;
        }

        // Word category: skip consecutive word chars
        p = first.start;
        while (p > 0) {
            const prev = text_utils.utf8DecodePrev(text, p);
            if (text_utils.classifyCodepoint(prev.cp) != .word) break;
            p = prev.start;
        }
        return p;
    }

    /// Find word boundary rightward from pos (CJK-aware: each CJK char is separate word)
    pub fn findWordBoundaryRight(self: *const TextInputState, pos: usize) usize {
        if (self.textarea_doc) |doc| {
            return DocCursor(TextareaDocument).nextWordBoundary(doc, pos);
        }
        const text = self.getText();
        if (pos >= text.len) return text.len;
        var p = pos;

        // Check char category right of pos
        var cp: u21 = 0;
        const step = text_utils.utf8DecodeNext(text, p, &cp);
        const first_class = text_utils.classifyCodepoint(cp);

        if (first_class == .cjk) {
            // CJK: skip one only
            return p + step;
        }

        if (first_class == .word) {
            // Skip consecutive word chars
            p += step;
            while (p < text.len) {
                var next_cp: u21 = 0;
                const next_step = text_utils.utf8DecodeNext(text, p, &next_cp);
                if (text_utils.classifyCodepoint(next_cp) != .word) break;
                p += next_step;
            }
        } else {
            // Separator: skip consecutive separators
            p += step;
            while (p < text.len) {
                var next_cp: u21 = 0;
                const next_step = text_utils.utf8DecodeNext(text, p, &next_cp);
                if (text_utils.classifyCodepoint(next_cp) != .separator) break;
                p += next_step;
            }
        }

        // Skip following separators (cursor stops at next word start)
        while (p < text.len) {
            var next_cp: u21 = 0;
            const next_step = text_utils.utf8DecodeNext(text, p, &next_cp);
            if (text_utils.classifyCodepoint(next_cp) != .separator) break;
            p += next_step;
        }

        return p;
    }

    /// Get selected text
    pub fn getSelectedText(self: *const TextInputState) ?[]const u8 {
        const anchor = self.selection_anchor orelse return null;
        const start = @min(anchor, self.cursor_pos);
        const end = @max(anchor, self.cursor_pos);
        if (start == end) return null;
        if (self.textarea_doc) |doc| {
            const txt = doc.getText();
            return txt[@min(start, txt.len)..@min(end, txt.len)];
        }
        return self.singleLineBuffer()[start..end];
    }

    /// Select word at pos (CJK-aware: each CJK char selected independently)
    pub fn selectWordAt(self: *TextInputState, pos: usize) void {
        if (self.textarea_doc) |doc| {
            const bounds = DocCursor(TextareaDocument).wordBoundsAt(doc, pos);
            self.selection_anchor = bounds.start;
            self.cursor_pos = bounds.end;
            self.resetBlink();
            return;
        }
        const text = self.getText();
        if (text.len == 0) return;
        const p = @min(pos, if (text.len > 0) text.len - 1 else 0);

        // Decode codepoint at current position
        var cp: u21 = 0;
        const step = text_utils.utf8DecodeNext(text, p, &cp);
        const cls = text_utils.classifyCodepoint(cp);

        if (cls == .cjk) {
            // CJK: select this char only
            self.selection_anchor = p;
            self.cursor_pos = p + step;
        } else if (cls == .separator) {
            // Select consecutive separators
            var start = p;
            while (start > 0) {
                const prev = text_utils.utf8DecodePrev(text, start);
                if (text_utils.classifyCodepoint(prev.cp) != .separator) break;
                start = prev.start;
            }
            var end = p + step;
            while (end < text.len) {
                var next_cp: u21 = 0;
                const next_step = text_utils.utf8DecodeNext(text, end, &next_cp);
                if (text_utils.classifyCodepoint(next_cp) != .separator) break;
                end += next_step;
            }
            self.selection_anchor = start;
            self.cursor_pos = end;
        } else {
            // Word: select consecutive word chars
            var start = p;
            while (start > 0) {
                const prev = text_utils.utf8DecodePrev(text, start);
                if (text_utils.classifyCodepoint(prev.cp) != .word) break;
                start = prev.start;
            }
            var end = p + step;
            while (end < text.len) {
                var next_cp: u21 = 0;
                const next_step = text_utils.utf8DecodeNext(text, end, &next_cp);
                if (text_utils.classifyCodepoint(next_cp) != .word) break;
                end += next_step;
            }
            self.selection_anchor = start;
            self.cursor_pos = end;
        }
        self.resetBlink();
    }

    // ========== Undo/Redo ==========

    /// Save undo snapshot.
    /// Unconditionally push and break merge chain; all naked pushUndo edits
    /// (setText / word delete / line delete / paste) are standalone.
    /// Consecutive input uses pushUndoCoalescing.
    pub fn pushUndo(self: *TextInputState) bool {
        if (!self.pushUndoRaw()) return false;
        self.undo_coalesce_kind = .none;
        self.undo_coalesce_at = null;
        return true;
    }

    fn makeSingleLineSnapshot(self: *TextInputState) ?UndoSnapshot {
        const owned = if (self.buffer_len == 0)
            null
        else
            self.allocator.dupe(u8, self.singleLineBuffer()[0..self.buffer_len]) catch return null;
        return .{
            .text = owned,
            .cursor_pos = self.cursor_pos,
            .selection_anchor = self.selection_anchor,
        };
    }

    fn restoreSingleLineSnapshot(self: *TextInputState, snapshot: *UndoSnapshot) void {
        const text = snapshot.text orelse "";
        std.debug.assert(text.len <= self.singleLineBuffer().len);
        if (text.len > 0) @memcpy(self.mutableBuffer()[0..text.len], text);
        self.buffer_len = text.len;
        self.cursor_pos = @min(snapshot.cursor_pos, text.len);
        self.selection_anchor = if (snapshot.selection_anchor) |anchor| @min(anchor, text.len) else null;
        snapshot.deinit(self.allocator);
    }

    fn pushSingleLineSnapshot(
        self: *TextInputState,
        stack: *[UNDO_CAPACITY]UndoSnapshot,
        count: *u8,
        snapshot: UndoSnapshot,
    ) void {
        if (count.* < UNDO_CAPACITY) {
            stack[count.*] = snapshot;
            count.* += 1;
            return;
        }

        stack[0].deinit(self.allocator);
        var i: usize = 0;
        while (i < UNDO_CAPACITY - 1) : (i += 1) stack[i] = stack[i + 1];
        // The old tail was moved to the previous slot; overwriting it transfers
        // ownership to the new snapshot without freeing the moved allocation.
        stack[UNDO_CAPACITY - 1] = snapshot;
    }

    fn clearSingleLineStack(self: *TextInputState, stack: *[UNDO_CAPACITY]UndoSnapshot, count: *u8) void {
        var i: usize = 0;
        while (i < count.*) : (i += 1) stack[i].deinit(self.allocator);
        count.* = 0;
    }

    fn pushUndoRaw(self: *TextInputState) bool {
        if (self.textarea_doc != null) {
            if (!self.taPushUndo()) return false;
            self.noteUserEditPush();
            return true;
        }
        // Allocate before touching either history stack. An OOM therefore
        // leaves counts, existing snapshots and the current text unchanged.
        const snapshot = self.makeSingleLineSnapshot() orelse return false;
        const in_txn = self.user_edit.depth > 0;
        // Stash oldest evicted entry during transaction (free no-op after slot cleared).
        if (in_txn and self.undo_count == UNDO_CAPACITY and self.undo_stash.keepEvicted(self.undo_stack[0])) {
            self.undo_stack[0] = .{};
        }
        self.pushSingleLineSnapshot(&self.undo_stack, &self.undo_count, snapshot);
        if (!(in_txn and self.undo_stash.detachRedo(&self.redo_count))) {
            self.clearSingleLineStack(&self.redo_stack, &self.redo_count);
        }
        self.noteUserEditPush();
        return true;
    }

    fn noteUserEditPush(self: *TextInputState) void {
        if (self.user_edit.depth > 0) self.user_edit.pushes +|= 1;
    }

    /// Break undo merge chain. Any non-consecutive action (cursor move, click, blur, paste,
    /// selection change, explicit pushUndo) should call this
    /// so next input starts new undo unit.
    pub fn breakUndoCoalescing(self: *TextInputState) void {
        self.undo_coalesce_kind = .none;
        self.undo_coalesce_at = null;
    }

    /// Check if char is hard boundary, breaking undo even if adjacent to input.
    /// Whitespace/line-break are standard word boundaries: undo rewinds by word, not entire
    /// segment.
    fn isUndoBoundaryText(text: []const u8) bool {
        for (text) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return true;
        }
        return false;
    }

    /// Merge-capable version of pushUndo.
    /// Break (push a new snapshot) if any condition holds, else reuse = merge:
    ///   1. Edit kind changes (insert <-> backspace <-> delete forward)
    ///   2. Cursor discontinuous: edit start != last edit end (jumped via click/arrow)
    ///   3. Idle longer than undo_coalesce_idle_ns (default 800ms)
    ///   4. Selection exists (replacing a selection is separate)
    ///   5. Content contains boundary chars (whitespace/newline)
    fn pushUndoCoalescing(
        self: *TextInputState,
        kind: UndoCoalesceKind,
        text: []const u8,
    ) bool {
        const now: ?@import("zenit_time").Instant = @import("zenit_time").Instant.now(self.io) catch null;

        var breaks = self.selection_anchor != null or isUndoBoundaryText(text);
        if (!breaks) breaks = self.undo_coalesce_kind != kind;
        if (!breaks) breaks = self.undo_coalesce_cursor != self.cursor_pos;
        if (!breaks) {
            if (self.undo_coalesce_at) |last| {
                if (now) |n| {
                    breaks = n.since(last) > undo_coalesce_idle_ns;
                } else breaks = true;
            } else breaks = true;
        }

        if (breaks and !self.pushUndoRaw()) return false;

        // Chain continues regardless of push: merged edits update end/timestamp.
        // Boundary char not merge start-point for next segment (kind=none forces break again).
        self.undo_coalesce_kind = if (isUndoBoundaryText(text)) .none else kind;
        self.undo_coalesce_at = now;
        return true;
    }

    /// Record new merge anchor after edit (cursor end position).
    fn noteUndoCoalesceEnd(self: *TextInputState) void {
        self.undo_coalesce_cursor = self.cursor_pos;
    }

    /// Undo
    pub fn undo(self: *TextInputState) void {
        if (self.ime_replacement != null) {
            self.cancelImeComposition();
            return;
        }
        if (self.textarea_doc != null) {
            if (self.taRestoreHistory(false)) {
                self.breakUndoCoalescing();
                self.noteUserEditHistoryOp(.undo);
            }
            return;
        }
        if (self.undo_count == 0) return;
        // Single-line: original logic.
        // Allocate current state first. If it fails, undo is no-op and target snapshot remains
        // owned by stack.
        const current = self.makeSingleLineSnapshot() orelse return;
        self.breakUndoCoalescing();
        // Redo slots may be reused: evicted entries during transaction freed first.
        self.undo_stash.settleRedo(&self.redo_stack, self.allocator);
        self.pushSingleLineSnapshot(&self.redo_stack, &self.redo_count, current);
        self.undo_count -= 1;
        var snapshot = self.undo_stack[self.undo_count];
        self.undo_stack[self.undo_count] = .{};
        self.restoreSingleLineSnapshot(&snapshot);
        self.dirty = true;
        self.resetBlink();
        self.noteUserEditHistoryOp(.undo);
    }

    fn noteUserEditHistoryOp(self: *TextInputState, op: UserEditTxn.HistoryOp) void {
        if (self.user_edit.depth > 0) self.user_edit.history_op = op;
    }

    /// Redo
    pub fn redo(self: *TextInputState) void {
        if (self.ime_replacement != null) {
            self.cancelImeComposition();
            return;
        }
        if (self.textarea_doc != null) {
            if (self.taRestoreHistory(true)) {
                self.breakUndoCoalescing();
                self.noteUserEditHistoryOp(.redo);
            }
            return;
        }
        if (self.redo_count == 0) return;
        // Single-line: original logic
        const current = self.makeSingleLineSnapshot() orelse return;
        self.breakUndoCoalescing();
        self.pushSingleLineSnapshot(&self.undo_stack, &self.undo_count, current);
        self.redo_count -= 1;
        var snapshot = self.redo_stack[self.redo_count];
        self.redo_stack[self.redo_count] = .{};
        self.restoreSingleLineSnapshot(&snapshot);
        self.dirty = true;
        self.resetBlink();
        self.noteUserEditHistoryOp(.redo);
    }

    // ========== Hit-test+Scroll ==========

    /// Global x -> char position (hit test)
    pub fn hitTestCursorPos(self: *TextInputState, global_x: f32) usize {
        if (self.multiline) {
            return self.hitTestCursorPosMultiline(
                global_x,
                self.container_y + self.padding_v + self.line_height * 0.5,
            );
        }
        const local_x = global_x - self.container_x + self.scroll_x - self.padding_h;
        const target_x = if (local_x <= 0) 0 else local_x;
        if (self.input_type == .password) {
            // Password screen displays mask '*' but buffer holds real UTF-8.
            // Click x must measure by mask to find char N, translate back to buffer byte offset.
            const buffer_text = self.getText();
            var mask_buf: [editable_block.MAX_INPUT_BYTES]u8 = undefined;
            const grapheme_count = text_utils.utf8GraphemeLen(buffer_text);
            const n = @min(grapheme_count, mask_buf.len);
            @memset(mask_buf[0..n], '*');
            const mask = mask_buf[0..n];
            const mask_byte = text_utils.utf8ByteOffsetForMeasuredXCx(self.cx_ref, mask, target_x, self.char_width, self.font_size, self.font_weight);
            // mask is ASCII, one byte per source grapheme.
            return text_utils.utf8ByteOffsetForGraphemeIndex(buffer_text, mask_byte);
        }
        const text = self.getText();
        if (self.cx_ref) |cx| {
            if (text_utils.visualPositionForX(cx, text, target_x, self.font_size, self.font_weight)) |position| {
                self.cursor_affinity = position.affinity;
                return position.byte.value;
            }
        }
        return text_utils.utf8ByteOffsetForMeasuredXCx(self.cx_ref, text, target_x, self.char_width, self.font_size, self.font_weight);
    }

    pub fn hitTestCursorPosAt(self: *TextInputState, global_x: f32, global_y: f32) usize {
        if (self.multiline) {
            return self.hitTestCursorPosMultiline(global_x, global_y);
        }
        return self.hitTestCursorPos(global_x);
    }

    pub fn registerMouseDownClickCount(self: *TextInputState, x: f32, y: f32) u8 {
        const dx = x - self.last_mouse_down_pos[0];
        const dy = y - self.last_mouse_down_pos[1];
        const dist_sq = dx * dx + dy * dy;
        var is_multi_click = false;

        const now_instant = @import("zenit_time").Instant.now(self.io) catch null;
        if (now_instant) |now| {
            if (self.last_mouse_down_instant) |last| {
                const time_delta_ns = text_utils.safeElapsedNs(now, last);
                is_multi_click = time_delta_ns < events.multi_click_interval_ns and dist_sq < events.multi_click_slop_sq;
            }
            self.last_mouse_down_instant = now;
        } else {
            self.last_mouse_down_instant = null;
        }
        self.last_mouse_down_pos = .{ x, y };

        if (is_multi_click) {
            self.consecutive_mouse_downs +|= 1;
        } else {
            self.consecutive_mouse_downs = 1;
        }
        return self.consecutive_mouse_downs;
    }

    /// Rebind the retained text node immediately after the editable buffer changes.
    ///
    /// Multiline storage may reallocate while inserting a newline. Waiting until
    /// `inputBeforeRender` to replace `TextProps.content` leaves the node pointing at the old
    /// allocation during the layout that follows the input event. The caret uses the current
    /// document and advances correctly, while glyph layout keeps the stale prefix, the visible
    /// symptom is text typed after Return disappearing. Keep the before-render sync as a fallback,
    /// but make every normal edit publish its display slice before layout can observe it.
    fn retryDisplay(self: *TextInputState, node: *core.Node) void {
        self.dirty = true;
        if (self.cx_ref) |cx| @import("row_text.zig").retry(cx, node) else node.markLayoutDirty();
    }

    pub fn syncDisplayTextContent(self: *TextInputState) bool {
        return self.syncDisplayTextContentChecked() catch {
            if (self.text_display_node) |node| self.retryDisplay(node);
            return false;
        };
    }

    fn syncDisplayTextContentChecked(self: *TextInputState) !bool {
        const text_node = self.text_display_node orelse return false;
        // Check if node owns same display content (no re-snapshot): read owned raw value.
        var props = text_node.getTextRaw() orelse return false;
        const display = try self.buildDisplayTextChecked(self.placeholder_text);
        // Empty display needs no owned snapshot (an empty dupe allocates nothing), and setText's
        // write-back rule cannot carry ownership for an empty slice: without this check every
        // render-hook write-back would re-snapshot and mark sizing dirty again, forever.
        if ((props.owned or display.len == 0) and std.mem.eql(u8, props.content, display)) return false;
        const allocator = if (text_node.world_ref) |world| world.allocator else self.allocator;
        const snapshot = try allocator.dupe(u8, display);
        props.content = snapshot;
        props.owned = true;
        props.inline_len = 0;
        self.display_text_hash = std.hash.Wyhash.hash(0, display);
        text_node.setText(props);
        return true;
    }

    /// Notify render pipeline of buffer/ime/cursor changes.
    /// cx.render() zero-dirty fast-path skips before_render hook -> inputBeforeRender doesn't run
    /// -> text.content doesn't update.
    /// Any caller modifying buffer/cursor/scroll_x/ime must call this at end.
    pub fn markVisualDirty(self: *TextInputState) void {
        self.syncMultilineAutoHeight();
        _ = self.syncDisplayTextContent();
        // Sizing (not layout): display text changes (typing/IME preedit attach/detach).
        // Soft-wrap text intrinsic measure cached; markLayoutDirty doesn't invalidate.
        // Wrap box draws old content, preedit/new chars off-screen but cursor advances by new
        // content.
        if (self.text_display_node) |n| n.markSizingDirty();
        if (self.editable_surface_node) |n| {
            n.markRenderDirty();
            if (!self.visual_sync_active) {
                if (self.visual_sync_hook) |hook| {
                    self.visual_sync_active = true;
                    defer self.visual_sync_active = false;
                    hook(n);
                }
            }
        }
        if (self.cursor_node) |n| n.markRenderDirty();
        if (self.selection_node) |n| n.markRenderDirty();
        if (self.preedit_underline_node) |n| n.markRenderDirty();
    }

    /// Return true while a held pointer outside the single-line viewport can
    /// advance. Use elapsed frame time, capped after stalls, and stop at bounds.
    pub fn advanceEdgeDrag(self: *TextInputState, time_ms: f64) bool {
        const pointer = if (self.drag_pointer) |*p| p else return false;
        const elapsed = std.math.clamp(time_ms - pointer.time_ms, 0, 100);
        pointer.time_ms = time_ms;
        if (!self.focused or !self.is_dragging or self.suspend_drag_until_mouse_up or self.multiline) return false;
        const left = self.container_x + self.padding_h;
        const right = left + self.input_inner_w;
        const distance = if (pointer.x < left) pointer.x - left else if (pointer.x > right) pointer.x - right else return false;
        const max_scroll = @max(@as(f32, 0), self.displayedTextAdvance() - self.input_inner_w);
        if ((distance < 0 and self.scroll_x <= 0) or (distance > 0 and self.scroll_x >= max_scroll)) return false;
        if (elapsed == 0) return true; // Repeated render hooks in one frame must not move the caret.
        const speed = 200 + @min(@abs(distance), 200) * 4;
        const step = speed * @as(f32, @floatCast(elapsed / 1000));
        self.scroll_x = std.math.clamp(self.scroll_x + (if (distance < 0) -step else step), 0, max_scroll);
        self.cursor_pos = self.hitTestCursorPosAt(if (distance < 0) left else right, pointer.y);
        self.updateScrollX();
        self.resetBlink();
        return true;
    }

    /// Update horizontal scroll to keep cursor visible.
    /// Mark visual node dirty; updateScrollX almost always called after buffer/cursor/ime/focus
    /// change.
    /// cx.render() zero-dirty fast-path skips inputBeforeRender -> visual mask won't update without
    /// unified dirty here.
    pub fn updateScrollX(self: *TextInputState) void {
        if (self.multiline) {
            self.scroll_x = 0;
            self.markVisualDirty();
            return;
        }
        if (self.buffer_len > 0 or self.ime_preedit_len > 0) {
            const cursor_x = self.visualCursorAdvance();
            if (cursor_x - self.scroll_x > self.input_inner_w) {
                self.scroll_x = cursor_x - self.input_inner_w;
            } else if (cursor_x < self.scroll_x) {
                self.scroll_x = cursor_x;
            }
            const text_w = self.displayedTextAdvance();
            if (text_w <= self.input_inner_w) {
                self.scroll_x = 0;
            } else {
                const max_scroll = @max(@as(f32, 0), text_w - self.input_inner_w);
                self.scroll_x = std.math.clamp(self.scroll_x, @as(f32, 0), max_scroll);

                // Boundary snap: avoid floating-point errors causing 'at boundary but state !=
                // boundary'.
                const snap_eps: f32 = 0.75;
                if (self.scroll_x <= snap_eps) {
                    self.scroll_x = 0;
                } else if (self.scroll_x >= max_scroll - snap_eps) {
                    self.scroll_x = max_scroll;
                }
            }
        } else {
            self.scroll_x = 0;
        }
        self.markVisualDirty();
    }

    // ========== Text operations ==========

    /// Get current text
    pub fn getText(self: *const TextInputState) []const u8 {
        if (self.textarea_doc) |doc| return doc.getText();
        return self.singleLineBuffer()[0..self.buffer_len];
    }

    /// Native accessibility selection ingress. Offsets use the same UTF-8
    /// coordinate model as the editor and are snapped backward to grapheme
    /// boundaries before any state is changed.
    pub fn setAccessibilitySelection(self: *TextInputState, start_utf8: u32, end_utf8: u32) bool {
        self.a11y_scroll_request = null;
        const text = self.getText();
        const start = text_coordinates.clampByteOffset(
            text,
            .{ .value = @min(@as(usize, start_utf8), text.len) },
            .backward,
        ).value;
        const end = text_coordinates.clampByteOffset(
            text,
            .{ .value = @min(@as(usize, end_utf8), text.len) },
            .backward,
        ).value;
        self.selection_anchor = if (start == end) null else start;
        self.cursor_pos = end;
        self.syncDocFromCursor();
        self.resetBlink();
        self.updateScrollX();
        return true;
    }

    /// Programmatically replace text content.
    /// props.value is read once at mount (mod.zig memcpy to buffer), so this is the only way for
    /// the
    /// app to change the field later ('render-then-data-arrives', 'clear-after-submit').
    /// Semantics:
    /// - Content is copied into the internal buffer; caller need not keep text alive.
    /// - Default clamps to capacity at a grapheme boundary; growable single-line keeps full text.
    /// - Cursor to end, clear selection, end composition (treated as replaced, no
    ///   on_ime_cancelled).
    /// - Records an undo snapshot (setText can be undone with Cmd+Z).
    /// - Multiline (Textarea) delegates to TextareaDocument.setText.
    /// Returns bytes actually written (< text.len means truncated).
    pub fn setText(self: *TextInputState, text: []const u8) usize {
        return self.setTextChecked(text) catch self.getText().len;
    }

    pub fn setTextChecked(self: *TextInputState, text: []const u8) !usize {
        if (self.textarea_doc) |doc| {
            const n = if (self.textarea_max_bytes > 0)
                text_coordinates.truncateToGraphemeBoundary(text, self.textarea_max_bytes)
            else
                text.len;
            var prepared = try doc.prepareReplace(0, doc.totalLength(), text[0..n]);
            defer prepared.deinit();
            if (!self.pushUndo()) return error.OutOfMemory;
            prepared.commit();
            const total = doc.totalLength();
            self.cursor_pos = total;
            self.selection_anchor = null;
            self.textarea_cursor.offset = total;
            self.textarea_cursor.anchor = null;
            self.textarea_cursor.preferred_col = null;
            if (self.textarea_wrap) |wrap| wrap.rebuildAll(doc);
            self.ime_replacement = null;
            self.supersedeImeComposition();
            self.dirty = true;
            self.resetBlink();
            return total;
        }

        const n = if (self.growable) text.len else text_coordinates.truncateToGraphemeBoundary(text, self.singleLineBuffer().len);
        var incoming = try ImeText.init(self.allocator, text[0..n]);
        defer incoming.deinit();
        const growth = try self.prepareInputGrowth(n);
        errdefer if (growth) |bytes| self.allocator.free(bytes);
        if (!self.pushUndo()) return error.OutOfMemory;
        self.commitInputGrowth(growth);
        @memcpy(self.mutableBuffer()[0..n], incoming.text());
        self.buffer_len = n;
        self.cursor_pos = n;
        self.selection_anchor = null;
        self.ime_replacement = null;
        self.supersedeImeComposition();
        self.dirty = true;
        self.resetBlink();
        return n;
    }

    /// External write from binding (binding.zig): replace all, cursor to end, clear undo history,
    /// no on_change
    pub fn applyExternalText(self: *TextInputState, v: []const u8) !void {
        _ = try self.setTextChecked(v);
        self.clearUndoHistory();
        self.updateScrollX();
    }

    /// User edit transaction entry (event handler / AX write), must pair with endUserEdit.
    /// Only outermost records checkpoint: pre-edit selection and undo merge state.
    pub fn beginUserEdit(self: *TextInputState) void {
        if (self.user_edit.depth == 0) {
            // Cursor moved into replacement range during composition retransformation.
            // Edit didn't happen = cancel composition, return to selection saved before composition
            // (same rule as cancelImeComposition)
            const replacement = self.ime_replacement;
            self.user_edit = .{
                .cursor = if (replacement) |r| r.cursor else self.cursor_pos,
                .anchor = if (replacement) |r| r.anchor else self.selection_anchor,
                .coalesce_kind = self.undo_coalesce_kind,
                .coalesce_cursor = self.undo_coalesce_cursor,
                .coalesce_at = self.undo_coalesce_at,
            };
        }
        self.user_edit.depth += 1;
    }

    pub fn endUserEdit(self: *TextInputState) void {
        std.debug.assert(self.user_edit.depth > 0);
        self.user_edit.depth -= 1;
        // Transaction end and edit not rejected: stashed redo / evicted entries freed per original
        // logic.
        if (self.user_edit.depth == 0) self.discardHistoryStash();
    }

    /// Edit exit complete (binding calls this at onBufferChanged end): result final (landed /
    /// rewritten / rejected / aligned to external write).
    /// Stash freed per original logic, checkpoint rebuilt from current state.
    /// Granularity is per-exit not per-event: if later edits in same transaction (e.g. parent
    /// on_change edits same input), only that one reverts.
    pub fn settleUserEdit(self: *TextInputState) void {
        if (self.user_edit.depth == 0) return;
        self.discardHistoryStash();
        const depth = self.user_edit.depth;
        self.user_edit = .{
            .depth = depth,
            .cursor = self.cursor_pos,
            .anchor = self.selection_anchor,
            .coalesce_kind = self.undo_coalesce_kind,
            .coalesce_cursor = self.undo_coalesce_cursor,
            .coalesce_at = self.undo_coalesce_at,
        };
    }

    fn discardHistoryStash(self: *TextInputState) void {
        self.undo_stash.discard(&self.redo_stack, self.allocator);
        if (self.textarea_doc) |doc| self.ta_undo_stash.discard(&self.ta_redo, doc.allocator);
    }

    /// In-place fix from binding (binding.zig): the proposed text did not land as-is; `landed` is
    /// the
    /// current data source value.
    /// - rejected (data unchanged: parent refused or rewrite == pre-edit): buffer -> landed,
    ///   selection -> pre-edit, undo/redo restored to pre-edit (pushed snapshot popped, cleared
    ///   redo
    ///   and evicted entries restored from stash), merge chain restored: rejection = nothing
    ///   happened.
    /// - else (rewrite): buffer -> landed, cursor/selection mapped per edit_reconcile.zig
    ///   single-delta-range; no new snapshot, the rewrite joins this edit's undo unit, so Cmd+Z
    ///   goes
    ///   to the pre-edit text.
    /// Outside a user transaction (no checkpoint): degrades to an external write. No change on
    /// failure.
    pub fn reconcileUserEdit(self: *TextInputState, landed: []const u8, rejected: bool) !void {
        if (self.user_edit.depth == 0) return self.applyExternalText(landed);
        const txn = self.user_edit;
        const cursor_before = self.cursor_pos;
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
            const rewrite = edit_reconcile.Rewrite.diff(self.getText(), landed);
            cursor = rewrite.mapOffset(landed, self.cursor_pos);
            anchor = if (self.selection_anchor) |a| rewrite.mapOffset(landed, a) else null;
        }
        try self.replaceTextKeepingHistory(landed);

        const text = self.getText();
        self.cursor_pos = edit_reconcile.clampOffset(text, cursor);
        self.selection_anchor = if (anchor) |a| edit_reconcile.clampOffset(text, a) else null;
        if (self.selection_anchor == self.cursor_pos) self.selection_anchor = null;
        if (rejected) {
            if (txn.history_op == .none) self.restoreUserEditHistory();
            self.undo_coalesce_kind = txn.coalesce_kind;
            self.undo_coalesce_cursor = txn.coalesce_cursor;
            self.undo_coalesce_at = txn.coalesce_at;
        } else if (self.undo_coalesce_kind != .none and self.undo_coalesce_cursor == cursor_before) {
            // Merge chain end follows cursor: next keystroke continues into same undo unit.
            self.undo_coalesce_cursor = self.cursor_pos;
        }
        self.syncDocFromCursor();
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.dirty = true;
        self.resetBlink();
        self.updateScrollX();
    }

    /// Reject: restore undo/redo to pre-edit: pop pushed snapshot, restore evicted entries and
    /// cleared redo.
    fn restoreUserEditHistory(self: *TextInputState) void {
        if (self.textarea_doc) |doc| {
            self.ta_undo_stash.restore(&self.ta_undo, &self.ta_undo_count, &self.ta_redo, &self.ta_redo_count, self.user_edit.pushes, doc.allocator);
        } else {
            self.undo_stash.restore(&self.undo_stack, &self.undo_count, &self.redo_stack, &self.redo_count, self.user_edit.pushes, self.allocator);
        }
        self.user_edit.pushes = 0;
    }

    /// Rewrite buffer to text, no undo snapshot, caller handles cursor.
    /// Multiline replaces single delta range only; soft-wrap map incremental update. No change on
    /// failure.
    fn replaceTextKeepingHistory(self: *TextInputState, text: []const u8) !void {
        const old = self.getText();
        if (std.mem.eql(u8, old, text)) return;
        if (self.textarea_doc) |doc| {
            const n = if (self.textarea_max_bytes > 0) text_coordinates.truncateToGraphemeBoundary(text, self.textarea_max_bytes) else text.len;
            const target = text[0..n];
            const rewrite = edit_reconcile.Rewrite.diff(old, target);
            var prepared = try doc.prepareReplace(rewrite.prefix, rewrite.old_end, target[rewrite.prefix..rewrite.new_end]);
            defer prepared.deinit();
            const old_lc = doc.lineCount();
            const first_line = doc.offsetToLineCol(rewrite.prefix).line;
            prepared.commit();
            self.notifyWrapEdit(first_line, old_lc - first_line, doc.lineCount() - first_line);
        } else {
            const n = if (self.growable) text.len else text_coordinates.truncateToGraphemeBoundary(text, self.singleLineBuffer().len);
            var incoming = try ImeText.init(self.allocator, text[0..n]);
            defer incoming.deinit();
            const growth = try self.prepareInputGrowth(n);
            self.commitInputGrowth(growth);
            @memcpy(self.mutableBuffer()[0..n], incoming.text());
            self.buffer_len = n;
        }
        self.dirty = true;
    }

    /// Clear text (syntactic sugar for setText("")).
    pub fn clearText(self: *TextInputState) void {
        _ = self.setText("");
    }

    /// Insert text
    pub fn insertText(self: *TextInputState, text: []const u8) void {
        self.insertTextChecked(text) catch return;
    }

    pub fn insertTextChecked(self: *TextInputState, text: []const u8) !void {
        const old = self.getText();
        const anchor = self.selection_anchor orelse self.cursor_pos;
        const start = text_coordinates.clampByteOffset(old, .{ .value = @min(anchor, self.cursor_pos) }, .backward).value;
        const end = if (anchor == self.cursor_pos) start else text_coordinates.clampByteOffset(old, .{ .value = @max(anchor, self.cursor_pos) }, .forward).value;
        const limit = if (self.textarea_doc != null) self.textarea_max_bytes else if (self.growable) @as(usize, 0) else self.singleLineBuffer().len;
        const remaining = if (limit == 0) text.len else limit -| (old.len - (end - start));
        const insert_len = text_coordinates.truncateToGraphemeBoundary(text, remaining);
        if (text.len > 0 and insert_len == 0) return error.NoSpaceLeft;
        if (insert_len == 0 and start == end) return;
        if (self.textarea_doc) |doc| {
            var prepared = try doc.prepareReplace(start, end, text[0..insert_len]);
            defer prepared.deinit();
            if (!self.pushUndoCoalescing(.insert, text)) return error.OutOfMemory;
            const old_lc = doc.lineCount();
            const first_line = doc.offsetToLineCol(start).line;
            prepared.commit();
            self.cursor_pos = start + insert_len;
            self.selection_anchor = null;
            self.syncDocFromCursor();
            self.notifyWrapEdit(first_line, old_lc - first_line, doc.lineCount() - first_line);
        } else {
            // Inputs may borrow buffer bytes that replacement shifts or removes.
            var incoming = try ImeText.init(self.allocator, text[0..insert_len]);
            defer incoming.deinit();
            const new_len = try std.math.add(usize, self.buffer_len - (end - start), insert_len);
            const growth = try self.prepareInputGrowth(new_len);
            errdefer if (growth) |bytes| self.allocator.free(bytes);
            if (!self.pushUndoCoalescing(.insert, text)) return error.OutOfMemory;
            self.commitInputGrowth(growth);
            @memmove(self.mutableBuffer()[start + insert_len .. new_len], self.singleLineBuffer()[end..self.buffer_len]);
            @memcpy(self.mutableBuffer()[start .. start + insert_len], incoming.text());
            self.buffer_len = new_len;
            self.cursor_pos = start + insert_len;
            self.selection_anchor = null;
        }
        self.cursor_affinity = .downstream;
        self.preferred_visual_x = null;
        self.dirty = true;
        self.resetBlink();
        self.noteUndoCoalesceEnd();
    }

    /// Delete range [start, end)
    pub fn deleteRange(self: *TextInputState, start_raw: usize, end_raw: usize) void {
        if (start_raw == end_raw) return;
        const raw_start = @min(start_raw, end_raw);
        const raw_end = @max(start_raw, end_raw);

        if (self.textarea_doc) |doc| {
            const text = doc.getText();
            const start = text_coordinates.clampByteOffset(text, .{ .value = raw_start }, .backward).value;
            const end = text_coordinates.clampByteOffset(text, .{ .value = raw_end }, .forward).value;
            const total = doc.totalLength();
            if (start >= end or start >= total) return;
            const actual_end = @min(end, total);
            const delete_len = actual_end - start;
            const old_lc = doc.lineCount();
            const lc_before = doc.offsetToLineCol(start);
            doc.deleteRange(start, delete_len) catch return;
            self.cursor_pos = start;
            self.selection_anchor = null;
            self.dirty = true;
            self.resetBlink();
            // Sync DocCursor
            self.textarea_cursor.offset = start;
            self.textarea_cursor.anchor = null;
            self.textarea_cursor.preferred_col = null;
            // Notify WrapMap
            const new_lc = doc.lineCount();
            const affected_start = lc_before.line;
            self.notifyWrapEdit(affected_start, old_lc - affected_start, new_lc - affected_start);
            return;
        }

        const current_text = self.singleLineBuffer()[0..self.buffer_len];
        const start = text_coordinates.clampByteOffset(current_text, .{ .value = raw_start }, .backward).value;
        const end = text_coordinates.clampByteOffset(current_text, .{ .value = raw_end }, .forward).value;
        if (start >= end or start >= self.buffer_len) return;
        const actual_end = @min(end, self.buffer_len);
        const delete_len = actual_end - start;

        // Move content after
        if (actual_end < self.buffer_len) {
            std.mem.copyForwards(
                u8,
                self.mutableBuffer()[start .. self.buffer_len - delete_len],
                self.singleLineBuffer()[actual_end..self.buffer_len],
            );
        }

        self.buffer_len -= delete_len;
        self.cursor_pos = start;
        self.selection_anchor = null;
        self.dirty = true;
        self.resetBlink();
    }

    /// Back one grapheme cluster from pos, return cluster start byte offset.
    /// Use UAX#29 extended grapheme cluster not codepoint: prevents ZWJ emoji sequences / combining
    /// marks / flags / skin-tone modifiers from being backspace-split into broken sequences.
    pub fn utf8PrevCharStart(self: *const TextInputState, pos: usize) usize {
        if (pos == 0) return 0;
        if (self.textarea_doc) |doc| {
            return DocCursor(TextareaDocument).prevCharBoundary(doc, pos);
        }
        return grapheme.prevBoundary(self.singleLineBuffer()[0..self.buffer_len], pos);
    }

    /// Forward one grapheme cluster from pos, return next cluster start byte offset.
    pub fn utf8NextCharEnd(self: *const TextInputState, pos: usize) usize {
        if (self.textarea_doc) |doc| {
            return DocCursor(TextareaDocument).nextCharBoundary(doc, pos);
        }
        if (pos >= self.buffer_len) return self.buffer_len;
        return grapheme.nextBoundary(self.singleLineBuffer()[0..self.buffer_len], pos);
    }

    /// Validate a real deletion before reserving history or breaking redo.
    /// Document deletion itself is allocation-free after history preparation.
    fn deleteRangeWithUndo(self: *TextInputState, start_raw: usize, end_raw: usize, coalesce: ?UndoCoalesceKind) void {
        if (start_raw == end_raw) return;
        const text = self.getText();
        const start = text_coordinates.clampByteOffset(text, .{ .value = @min(start_raw, end_raw) }, .backward).value;
        const end = text_coordinates.clampByteOffset(text, .{ .value = @max(start_raw, end_raw) }, .forward).value;
        if (start >= end) return;
        if (coalesce) |kind| {
            if (!self.pushUndoCoalescing(kind, "")) return;
        } else {
            if (!self.pushUndo()) return;
        }
        self.deleteRange(start, end);
        if (coalesce != null) self.noteUndoCoalesceEnd();
    }

    /// Delete backward one char (Backspace)
    pub fn deleteBackward(self: *TextInputState) void {
        const cursor = @min(self.cursor_pos, self.getText().len);
        const anchor = @min(self.selection_anchor orelse cursor, self.getText().len);
        const start = if (anchor != cursor) anchor else self.utf8PrevCharStart(cursor);
        self.deleteRangeWithUndo(start, cursor, .delete_backward);
    }

    /// Delete forward one char (Delete)
    pub fn deleteForward(self: *TextInputState) void {
        const cursor = @min(self.cursor_pos, self.getText().len);
        const anchor = @min(self.selection_anchor orelse cursor, self.getText().len);
        const end = if (anchor != cursor) anchor else self.utf8NextCharEnd(cursor);
        self.deleteRangeWithUndo(cursor, end, .delete_forward);
    }

    /// Move cursor (UTF-8 aware, delta in chars)
    pub fn moveCursor(self: *TextInputState, delta: i32, extend_selection: bool) void {
        self.breakUndoCoalescing();
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_pos;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }
        self.preferred_visual_x = null;
        if (self.textarea_doc) |doc| {
            if (self.textareaVisualLineAtOffset(self.cursor_pos)) |geometry| {
                if (geometry.visualNeighbour(self.cursor_pos, self.cursor_affinity, delta)) |target| {
                    self.cursor_pos = geometry.start + target.byte.value;
                    self.cursor_affinity = target.affinity;
                    self.syncDocFromCursor();
                    self.resetBlink();
                    return;
                }
            }
            // Multiline: delegate to DocCursor
            self.syncDocFromCursor();
            if (delta < 0) {
                self.textarea_cursor.moveLeft(doc, extend_selection);
            } else if (delta > 0) {
                self.textarea_cursor.moveRight(doc, extend_selection);
            }
            self.syncCursorFromDoc();
            self.cursor_affinity = .downstream;
            self.resetBlink();
            return;
        }

        if (self.input_type != .password) {
            if (self.cx_ref) |cx| {
                const text = self.singleLineBuffer()[0..self.buffer_len];
                if (cx.text.visualLine(.{
                    .text = text,
                    .font_family = "system",
                    .font_size = self.font_size,
                    .font_weight = self.font_weight,
                }) catch null) |line| {
                    var current_index: ?usize = null;
                    for (line.caret_stops, 0..) |stop, i| {
                        if (stop.position.byte.value == self.cursor_pos and stop.position.affinity == self.cursor_affinity) {
                            current_index = i;
                            break;
                        }
                    }
                    if (current_index == null) {
                        for (line.caret_stops, 0..) |stop, i| {
                            if (stop.position.byte.value == self.cursor_pos) {
                                current_index = i;
                                break;
                            }
                        }
                    }
                    if (current_index) |start_index| {
                        const magnitude: usize = @intCast(if (delta < 0) -delta else delta);
                        const target_index = if (delta < 0)
                            start_index -| magnitude
                        else
                            @min(start_index + magnitude, line.caret_stops.len - 1);
                        const target = line.caret_stops[target_index].position;
                        self.cursor_pos = target.byte.value;
                        self.cursor_affinity = target.affinity;
                        self.resetBlink();
                        return;
                    }
                }
            }
        }

        if (delta < 0) {
            var steps: usize = @intCast(-delta);
            while (steps > 0 and self.cursor_pos > 0) : (steps -= 1) {
                self.cursor_pos = self.utf8PrevCharStart(self.cursor_pos);
            }
        } else {
            var steps: usize = @intCast(delta);
            while (steps > 0 and self.cursor_pos < self.buffer_len) : (steps -= 1) {
                self.cursor_pos = self.utf8NextCharEnd(self.cursor_pos);
            }
        }
        self.cursor_affinity = .downstream;
        self.resetBlink();
    }

    /// Move to line start
    pub fn moveToStart(self: *TextInputState) void {
        self.cursor_pos = 0;
        self.cursor_affinity = .downstream;
        self.selection_anchor = null;
        self.resetBlink();
    }

    /// Move to line end
    pub fn moveToEnd(self: *TextInputState) void {
        if (self.textarea_doc) |doc| {
            self.cursor_pos = doc.totalLength();
        } else {
            self.cursor_pos = self.buffer_len;
        }
        self.cursor_affinity = .downstream;
        self.selection_anchor = null;
        self.resetBlink();
    }

    /// Select all
    pub fn selectAll(self: *TextInputState) void {
        self.breakUndoCoalescing();
        self.selection_anchor = 0;
        if (self.textarea_doc) |doc| {
            self.cursor_pos = doc.totalLength();
        } else {
            self.cursor_pos = self.buffer_len;
        }
        self.resetBlink();
    }

    // ========== Keyboard ==========

    /// Handle keyboard event
    pub fn handleKeyDown(self: *TextInputState, key: KeyCode, modifiers: events.Modifiers) bool {
        switch (key) {
            .left => {
                if (modifiers.super) {
                    // Cmd+Left: move to line start
                    if (modifiers.shift and self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_pos;
                    } else if (!modifiers.shift) {
                        self.selection_anchor = null;
                    }
                    self.cursor_pos = if (self.multiline) blk: {
                        if (self.textareaVisualLineAtOffset(self.cursor_pos)) |geometry| {
                            break :blk geometry.start;
                        }
                        if (self.textarea_doc) |doc| {
                            const lc = doc.offsetToLineCol(self.cursor_pos);
                            break :blk doc.getLineStart(lc.line);
                        }
                        break :blk self.findLineStart(self.cursor_pos);
                    } else 0;
                    self.dirty = true;
                    self.resetBlink();
                } else if (modifiers.alt or ((@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .linux) and modifiers.ctrl)) {
                    // Alt+Left: move word-left
                    if (modifiers.shift and self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_pos;
                    } else if (!modifiers.shift) {
                        self.selection_anchor = null;
                    }
                    self.cursor_pos = self.findWordBoundaryLeft(self.cursor_pos);
                    self.resetBlink();
                } else if (!modifiers.shift and self.selection_anchor != null) {
                    // No modifier + selection: cursor to selection left, clear selection
                    const anchor = self.selection_anchor.?;
                    self.cursor_pos = @min(anchor, self.cursor_pos);
                    self.selection_anchor = null;
                    self.resetBlink();
                } else {
                    self.moveCursor(-1, modifiers.shift);
                }
                return true;
            },
            .right => {
                if (modifiers.super) {
                    // Cmd+Right: move to line end
                    if (modifiers.shift and self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_pos;
                    } else if (!modifiers.shift) {
                        self.selection_anchor = null;
                    }
                    self.cursor_pos = if (self.multiline) blk: {
                        if (self.textareaVisualLineAtOffset(self.cursor_pos)) |geometry| {
                            break :blk geometry.end;
                        }
                        if (self.textarea_doc) |doc| {
                            const lc = doc.offsetToLineCol(self.cursor_pos);
                            break :blk doc.getLineEnd(lc.line);
                        }
                        break :blk self.findLineEnd(self.cursor_pos);
                    } else self.buffer_len;
                    self.dirty = true;
                    self.resetBlink();
                } else if (modifiers.alt or ((@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .linux) and modifiers.ctrl)) {
                    // Alt+Right: move word-right
                    if (modifiers.shift and self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_pos;
                    } else if (!modifiers.shift) {
                        self.selection_anchor = null;
                    }
                    self.cursor_pos = self.findWordBoundaryRight(self.cursor_pos);
                    self.resetBlink();
                } else if (!modifiers.shift and self.selection_anchor != null) {
                    // No modifier + selection: cursor to selection right, clear selection
                    const anchor = self.selection_anchor.?;
                    self.cursor_pos = @max(anchor, self.cursor_pos);
                    self.selection_anchor = null;
                    self.resetBlink();
                } else {
                    self.moveCursor(1, modifiers.shift);
                }
                return true;
            },
            .delete => {
                if (modifiers.super or modifiers.alt or ((@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .linux) and modifiers.ctrl)) {
                    const cursor = @min(self.cursor_pos, self.getText().len);
                    const anchor = @min(self.selection_anchor orelse cursor, self.getText().len);
                    const start = if (anchor != cursor)
                        anchor
                    else if (modifiers.super)
                        (if (self.multiline) self.docFindLineStart() else 0)
                    else
                        self.findWordBoundaryLeft(cursor);
                    self.deleteRangeWithUndo(start, cursor, null);
                } else {
                    self.deleteBackward();
                }
                return true;
            },
            .forward_delete => {
                if (modifiers.alt or ((@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .linux) and modifiers.ctrl)) {
                    const cursor = @min(self.cursor_pos, self.getText().len);
                    const anchor = @min(self.selection_anchor orelse cursor, self.getText().len);
                    const end = if (anchor != cursor) anchor else self.findWordBoundaryRight(cursor);
                    self.deleteRangeWithUndo(cursor, end, null);
                } else {
                    self.deleteForward();
                }
                return true;
            },
            .z => {
                if (events.primaryModifier(modifiers)) {
                    if (modifiers.shift) {
                        self.redo();
                    } else {
                        self.undo();
                    }
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
            .@"return" => {
                return false;
            },
            .escape => {
                self.selection_anchor = null;
                return true;
            },
            .a => {
                if (modifiers.super or modifiers.ctrl) {
                    self.selectAll();
                    return true;
                }
                return false;
            },
            .home => {
                if (modifiers.shift and self.selection_anchor == null) {
                    self.selection_anchor = self.cursor_pos;
                } else if (!modifiers.shift) {
                    self.selection_anchor = null;
                }
                self.cursor_pos = 0;
                self.resetBlink();
                return true;
            },
            .end => {
                if (modifiers.shift and self.selection_anchor == null) {
                    self.selection_anchor = self.cursor_pos;
                } else if (!modifiers.shift) {
                    self.selection_anchor = null;
                }
                self.cursor_pos = if (self.textarea_doc) |doc| doc.totalLength() else self.buffer_len;
                self.resetBlink();
                return true;
            },
            .up => {
                if (self.multiline) {
                    if (modifiers.super) {
                        // Cmd+Up: move to doc start
                        if (modifiers.shift and self.selection_anchor == null) {
                            self.selection_anchor = self.cursor_pos;
                        } else if (!modifiers.shift) {
                            self.selection_anchor = null;
                        }
                        self.cursor_pos = 0;
                        self.dirty = true;
                        self.resetBlink();
                    } else {
                        self.moveVertical(-1, modifiers.shift);
                    }
                    return true;
                }
                return false;
            },
            .down => {
                if (self.multiline) {
                    if (modifiers.super) {
                        // Cmd+Down: move to doc end
                        if (modifiers.shift and self.selection_anchor == null) {
                            self.selection_anchor = self.cursor_pos;
                        } else if (!modifiers.shift) {
                            self.selection_anchor = null;
                        }
                        self.cursor_pos = if (self.textarea_doc) |doc| doc.totalLength() else self.buffer_len;
                        self.dirty = true;
                        self.resetBlink();
                    } else {
                        self.moveVertical(1, modifiers.shift);
                    }
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Move cursor vertically (up/down line), preserve closest x pixel position
    fn moveVertical(self: *TextInputState, direction: i2, extend_selection: bool) void {
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_pos;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }

        // WrapMap path: move by display line
        if (self.textarea_wrap) |wrap| {
            if (self.textarea_doc) |doc| {
                const current = self.textareaVisualLineAtOffset(self.cursor_pos);
                const current_dl = if (current) |geometry| geometry.display_line else blk: {
                    const lc = doc.offsetToLineCol(self.cursor_pos);
                    break :blk wrap.bufferToDisplay(lc.line, lc.col).display_line;
                };
                const target_dl_i: i32 = @as(i32, @intCast(current_dl)) + @as(i32, direction);
                if (target_dl_i < 0) {
                    self.cursor_pos = 0;
                    self.cursor_affinity = .downstream;
                } else {
                    const target_dl: u32 = @intCast(target_dl_i);
                    if (target_dl >= wrap.total_display_lines) {
                        self.cursor_pos = doc.totalLength();
                        self.cursor_affinity = .downstream;
                    } else {
                        const info = wrap.displayLineInfo(target_dl, doc);
                        const seg = safeSegRange(doc, info);
                        const cur_x = self.preferred_visual_x orelse if (current) |geometry|
                            geometry.caretX(self.cursor_pos, self.cursor_affinity)
                        else
                            0;
                        self.preferred_visual_x = cur_x;
                        if (self.visualLineForSegment(seg.start, seg.end, target_dl)) |target_geometry| {
                            const position = target_geometry.line.xToPosition(.{ .value = cur_x });
                            self.cursor_pos = seg.start + position.byte.value;
                            self.cursor_affinity = position.affinity;
                        } else {
                            const seg_text = doc.getText()[seg.start..seg.end];
                            self.cursor_pos = seg.start + text_utils.utf8ByteOffsetForMeasuredXCx(
                                self.cx_ref,
                                seg_text,
                                cur_x,
                                self.char_width,
                                self.font_size,
                                self.font_weight,
                            );
                            self.cursor_affinity = .downstream;
                        }
                    }
                }
                self.syncDocFromCursor();
                self.dirty = true;
                self.resetBlink();
                return;
            }
        }

        // Fallback: old path
        const text = self.buildDisplayText(null);
        const cur_pos = self.multilineVisualPosForOffset(text, self.displayCursorByteOffset());
        const target_row_i: i32 = @as(i32, @intCast(cur_pos.row)) + @as(i32, direction);
        if (target_row_i < 0) {
            // Already at first line, move to line start
            self.cursor_pos = 0;
        } else {
            const target_row: usize = @intCast(target_row_i);
            const target_x = cur_pos.x;
            // Find nearest x position for target_row in text
            self.cursor_pos = self.byteOffsetForRowAndX(text, target_row, target_x);
        }
        self.dirty = true;
        self.resetBlink();
    }

    /// Given target row number and x pixel position, return nearest byte offset
    fn byteOffsetForRowAndX(self: *const TextInputState, text: []const u8, target_row: usize, target_x: f32) usize {
        var best_off: usize = 0;
        var best_found = false;
        var best_x_dist: f32 = std.math.inf(f32);

        var off: usize = 0;
        while (true) {
            const pos = self.multilineVisualPosForOffset(text, off);
            if (pos.row == target_row) {
                const x_dist = @abs(pos.x - target_x);
                if (!best_found or x_dist < best_x_dist) {
                    best_x_dist = x_dist;
                    best_off = off;
                    best_found = true;
                }
            } else if (pos.row > target_row and best_found) {
                break; // Passed target row
            }
            if (off >= text.len) break;
            off = nextUtf8CharEnd(text, off);
        }

        if (!best_found) {
            // Target row out of range, move to end
            return @min(self.cursor_pos, self.buffer_len);
            // If display text (includes IME), use buffer_len
        }
        // Map back to buffer offset (displayCursorByteOffset may include IME preedit)
        return @min(best_off, self.buffer_len);
    }

    /// Use TextareaDocument if present or fallback to find line start for current cursor
    fn docFindLineStart(self: *const TextInputState) usize {
        if (self.textarea_doc) |doc| {
            const lc = doc.offsetToLineCol(self.cursor_pos);
            return doc.getLineStart(lc.line);
        }
        return self.findLineStart(self.cursor_pos);
    }

    /// Find buffer line start (after previous \n or buffer start)
    pub fn findLineStart(self: *const TextInputState, pos: usize) usize {
        const text = self.getText();
        if (pos == 0) return 0;
        var i = @min(pos, text.len);
        // A caret immediately after '\n' is already at the next line's start.
        while (i > 0) {
            i -= 1;
            if (text[i] == '\n') return i + 1;
        }
        return 0;
    }

    /// Find buffer line end (next \n or buffer end)
    pub fn findLineEnd(self: *const TextInputState, pos: usize) usize {
        const text = self.getText();
        var i = @min(pos, text.len);
        while (i < text.len) {
            if (text[i] == '\n') return i;
            i += 1;
        }
        return text.len;
    }
};

// ========== Delegate functions ==========

pub fn isImeSelectionSpace(text: []const u8) bool {
    return editable_block.isImeSelectionSpace(text);
}

pub fn sanitizeInputText(state: *const TextInputState, input: []const u8, out: []u8) []const u8 {
    return editable_block.sanitizeInputText(state, input, out);
}

pub fn applyEditableBlockConfig(
    state: *TextInputState,
    behavior: EditableBlockBehavior,
    metrics: EditableBlockMetrics,
    explicit_inner_w: ?f32,
    ctx: *core.Cx,
    tokens: *const theme.ThemeTokens,
) void {
    editable_block.applyConfig(state, behavior, metrics, explicit_inner_w, ctx, tokens);
}

// ========== Grapheme cluster boundary (UAX#29) regression tests ==========
// These cases lock user-perceived-character semantics: codepoint-based old implementation fails
// all.

const testing = std.testing;

const gc_family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"; // 👨‍👩‍👧‍👦
const gc_flag_cn = "\u{1F1E8}\u{1F1F3}"; // 🇨🇳
const gc_flag_jp = "\u{1F1EF}\u{1F1F5}"; // 🇯🇵
const gc_thumbs_tone = "\u{1F44D}\u{1F3FB}"; // 👍🏻

fn gcMakeState(text: []const u8) TextInputState {
    var s = TextInputState{
        .io = std.testing.io,
    };
    @memcpy(s.buffer[0..text.len], text);
    s.buffer_len = text.len;
    s.cursor_pos = text.len;
    return s;
}

test "grapheme: 家庭 emoji 退格一次就删干净" {
    var s = gcMakeState("a" ++ gc_family);
    s.deleteBackward();
    try testing.expectEqualStrings("a", s.buffer[0..s.buffer_len]);
    try testing.expectEqual(@as(usize, 1), s.cursor_pos);
}

test "grapheme: 组合尖音符不被单独删掉" {
    var s = gcMakeState("e\u{0301}");
    s.deleteBackward();
    try testing.expectEqual(@as(usize, 0), s.buffer_len);
}

test "grapheme: 左方向键不会停在基字符与组合记号之间" {
    var s = gcMakeState("xe\u{0301}");
    s.moveCursor(-1, false);
    try testing.expectEqual(@as(usize, 1), s.cursor_pos); // not 2
    s.moveCursor(-1, false);
    try testing.expectEqual(@as(usize, 0), s.cursor_pos);
}

test "grapheme: 旗帜成对，删一次删一面旗" {
    var s = gcMakeState(gc_flag_cn ++ gc_flag_jp);
    s.deleteBackward();
    try testing.expectEqualStrings(gc_flag_cn, s.buffer[0..s.buffer_len]);
    s.deleteBackward();
    try testing.expectEqual(@as(usize, 0), s.buffer_len);
}

test "grapheme: 肤色修饰符不与基 emoji 拆开" {
    var s = gcMakeState(gc_thumbs_tone);
    s.deleteBackward();
    try testing.expectEqual(@as(usize, 0), s.buffer_len);
}

test "grapheme: deleteForward 同样按 cluster" {
    var s = gcMakeState(gc_family ++ "z");
    s.cursor_pos = 0;
    s.deleteForward();
    try testing.expectEqualStrings("z", s.buffer[0..s.buffer_len]);
}

test "grapheme: 选区扩展一次覆盖整个 cluster" {
    var s = gcMakeState("a" ++ gc_family);
    s.moveCursor(-1, true);
    try testing.expectEqual(@as(usize, 1), s.cursor_pos);
    try testing.expectEqual(@as(?usize, s.buffer_len), s.selection_anchor);
}

test "grapheme: 右方向键跨 cluster 前进" {
    var s = gcMakeState(gc_family ++ gc_flag_cn);
    s.cursor_pos = 0;
    s.moveCursor(1, false);
    try testing.expectEqual(gc_family.len, s.cursor_pos);
    s.moveCursor(1, false);
    try testing.expectEqual(gc_family.len + gc_flag_cn.len, s.cursor_pos);
}

test "coordinate ingress: IME cursor inside ZWJ emoji clamps to grapheme end" {
    var s = TextInputState{
        .io = std.testing.io,
    };
    s.setImePreedit("👩‍💻x", 2);
    try testing.expectEqual("👩‍💻".len, s.ime_cursor_utf8_offset);
    try testing.expectEqual("👩‍💻".len, s.effectiveImeCursorOffset());
}

test "coordinate ingress: deletion endpoints expand to whole graphemes" {
    var s = gcMakeState("a" ++ gc_family ++ "z");
    s.deleteRange(2, 3); // both raw offsets are inside the family emoji
    try testing.expectEqualStrings("az", s.buffer[0..s.buffer_len]);
    try testing.expectEqual(@as(usize, 1), s.cursor_pos);
}

test "coordinate ingress: capacity truncation never stores a partial grapheme" {
    var s = TextInputState{
        .io = std.testing.io,
    };
    const prefix_len = s.buffer.len - 2;
    @memset(s.buffer[0..prefix_len], 'x');
    s.buffer_len = prefix_len;
    s.cursor_pos = prefix_len;
    s.insertText(gc_thumbs_tone);
    try testing.expectEqual(prefix_len, s.buffer_len);
    try testing.expectEqual(prefix_len, s.cursor_pos);
}

test "coordinate model: password masks one glyph per source grapheme" {
    var s = gcMakeState("a" ++ gc_family ++ gc_thumbs_tone);
    s.input_type = .password;
    try testing.expectEqual(@as(usize, 3), s.displayedTextLen());
    try testing.expectEqual(gc_family.len + 1, text_utils.utf8ByteOffsetForGraphemeIndex(s.getText(), 2));
}

test "coordinate model: horizontal arrows follow mixed-bidi visual caret order" {
    var cx = try core.Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const content = "abc \u{5D0}\u{5D1}\u{5D2}";
    const line = try cx.text.visualLine(.{ .text = content, .font_family = "system", .font_size = 16 });
    try testing.expect(line.caret_stops.len > 2);
    var s = gcMakeState(content);
    s.cx_ref = cx;
    s.font_size = 16;
    s.cursor_pos = line.caret_stops[0].position.byte.value;
    s.cursor_affinity = line.caret_stops[0].position.affinity;
    var saw_logical_reverse = false;
    var i: usize = 1;
    while (i < line.caret_stops.len) : (i += 1) {
        const previous = s.cursor_pos;
        s.moveCursor(1, false);
        try testing.expectEqual(line.caret_stops[i].position.byte.value, s.cursor_pos);
        try testing.expectEqual(line.caret_stops[i].position.affinity, s.cursor_affinity);
        if (s.cursor_pos < previous) saw_logical_reverse = true;
    }
    try testing.expect(saw_logical_reverse);
}

test "coordinate model: Textarea WrapMap uses visual bidi stops and pixel preferred x" {
    var cx = try core.Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const content = "abc \u{5D0}\u{5D1}\u{5D2}";
    var full_text_buf: [128]u8 = undefined;
    const full_text = try std.fmt.bufPrint(&full_text_buf, "{s}\n{s}", .{ content, content });
    var doc = TextareaDocument.init(testing.allocator);
    defer doc.deinit();
    doc.setText(full_text);
    var wrap = TextareaWrapMap.init(testing.allocator, @import("std").testing.io);
    defer wrap.deinit();
    wrap.setEnabled(true, &doc);
    wrap.setWrapWidth(1000, &doc);
    _ = wrap.rewrapInterpolatedAll(&doc);

    const line = try cx.text.visualLine(.{ .text = content, .font_family = "system", .font_size = 16 });
    try testing.expect(line.caret_stops.len > 3);
    var s = TextInputState{
        .io = std.testing.io,
        .multiline = true,
        .cx_ref = cx,
        .font_size = 16,
        .line_height = 20,
        .input_inner_w = 1000,
        .textarea_doc = &doc,
        .textarea_wrap = &wrap,
        .buffer_len = full_text.len,
    };

    s.cursor_pos = line.caret_stops[0].position.byte.value;
    s.cursor_affinity = line.caret_stops[0].position.affinity;
    var saw_logical_reverse = false;
    var i: usize = 1;
    while (i < line.caret_stops.len) : (i += 1) {
        const previous = s.cursor_pos;
        s.moveCursor(1, false);
        try testing.expectEqual(line.caret_stops[i].position.byte.value, s.cursor_pos);
        try testing.expectEqual(line.caret_stops[i].position.affinity, s.cursor_affinity);
        if (s.cursor_pos < previous) saw_logical_reverse = true;
    }
    try testing.expect(saw_logical_reverse);

    const chosen = line.caret_stops[2];
    s.cursor_pos = chosen.position.byte.value;
    s.cursor_affinity = chosen.position.affinity;
    s.moveVertical(1, false);
    try testing.expectEqual(content.len + 1 + chosen.position.byte.value, s.cursor_pos);
    try testing.expectEqual(chosen.position.affinity, s.cursor_affinity);
    try testing.expectApproxEqAbs(chosen.x.value, s.preferred_visual_x.?, 0.01);
}

test "用户编辑事务：压栈脱离重做栈后同一事务内撤销，脱离的条目先释放再复用槽位（不泄漏）" {
    inline for (.{ false, true }) |multiline| {
        var doc = TextareaDocument.init(testing.allocator);
        defer doc.deinit();
        var s = TextInputState{ .io = std.testing.io, .allocator = testing.allocator, .multiline = multiline, .textarea_doc = if (multiline) &doc else null };
        defer s.deinit();
        s.insertText("a");
        s.insertText(" ");
        s.undo(); // One redo entry
        try testing.expectEqual(@as(u8, 1), if (multiline) s.ta_redo_count else s.redo_count);
        s.beginUserEdit();
        s.insertText("b"); // Push: redo stack in-place detach
        try testing.expectEqual(@as(u8, 0), if (multiline) s.ta_redo_count else s.redo_count);
        s.undo(); // Undo: write redo stack, must free detached entry first
        s.endUserEdit();
        try testing.expect(s.undo_stash.isEmpty() and s.ta_undo_stash.isEmpty());
    }
}

test "用户编辑事务：事务内历史被整体清空后，拒绝还原不会复活清空前的重做条目" {
    var s = TextInputState{ .io = std.testing.io, .allocator = testing.allocator };
    defer s.deinit();
    s.insertText("a");
    s.insertText(" ");
    s.undo();
    try testing.expectEqual(@as(u8, 1), s.redo_count);
    s.beginUserEdit();
    s.insertText("b"); // Push: redo stack in-place detach
    try s.applyExternalText("x"); // Replace all, clear history
    try s.reconcileUserEdit("x", true);
    s.endUserEdit();
    try testing.expectEqual(@as(u8, 0), s.redo_count);
    try testing.expectEqual(@as(u8, 0), s.undo_count);
    try testing.expectEqualStrings("x", s.getText());
}

test "用户编辑事务：同一事务内先有一次已落地的编辑，后一次被拒只回滚它自己" {
    inline for (.{ false, true }) |multiline| {
        var doc = TextareaDocument.init(testing.allocator);
        defer doc.deinit();
        var s = TextInputState{ .io = std.testing.io, .allocator = testing.allocator, .multiline = multiline, .textarea_doc = if (multiline) &doc else null };
        defer s.deinit();
        s.insertText("x");
        s.insertText(" ");
        s.undo();
        try testing.expectEqual(@as(u8, 1), if (multiline) s.ta_redo_count else s.redo_count);
        const undo_before = if (multiline) s.ta_undo_count else s.undo_count;
        s.beginUserEdit();
        s.insertText("a"); // First edit: landed (clear redo)
        s.settleUserEdit();
        s.insertText(" "); // Second edit: rejected
        try s.reconcileUserEdit("xa", true);
        s.endUserEdit();
        try testing.expectEqualStrings("xa", s.getText());
        try testing.expectEqual(@as(usize, 2), s.cursor_pos);
        // Landed edit keeps undo unit; cleared redo doesn't revive
        try testing.expectEqual(undo_before + 1, if (multiline) s.ta_undo_count else s.undo_count);
        try testing.expectEqual(@as(u8, 0), if (multiline) s.ta_redo_count else s.redo_count);
    }
}

test "用户编辑事务：不经值绑定的事务结束时暂存清空，之后被拒还原不复活旧重做条目" {
    inline for (.{ false, true }) |multiline| {
        var doc = TextareaDocument.init(testing.allocator);
        defer doc.deinit();
        var s = TextInputState{ .io = std.testing.io, .allocator = testing.allocator, .multiline = multiline, .textarea_doc = if (multiline) &doc else null };
        defer s.deinit();
        s.insertText("x");
        s.insertText(" ");
        s.undo();
        s.beginUserEdit();
        s.insertText("a"); // Push in transaction: redo stack in-place detach
        s.endUserEdit(); // End transaction: detached entries freed per original logic
        try testing.expect(s.undo_stash.isEmpty() and s.ta_undo_stash.isEmpty());
        s.beginUserEdit();
        s.insertText(" ");
        try s.reconcileUserEdit("xa", true);
        s.endUserEdit();
        try testing.expectEqual(@as(u8, 0), if (multiline) s.ta_redo_count else s.redo_count);
    }
}

test "single-line undo snapshots are dynamic and release their owned text" {
    try testing.expect(@sizeOf(UndoSnapshot) < editable_block.MAX_INPUT_BYTES / 8);
    try testing.expect(@sizeOf(TextInputState) < 32 * 1024);

    var s = TextInputState{ .io = std.testing.io, .allocator = testing.allocator };
    defer s.deinit();
    s.insertText("abc");
    s.insertText(" ");

    try testing.expectEqual(@as(u8, 2), s.undo_count);
    try testing.expectEqual(@as(?[]u8, null), s.undo_stack[0].text);
    try testing.expectEqualStrings("abc", s.undo_stack[1].text.?);
    s.clearUndoHistory();
    try testing.expectEqual(@as(u8, 0), s.undo_count);
    try testing.expectEqual(@as(?[]u8, null), s.undo_stack[1].text);
}

test "single-line undo full-stack eviction transfers ownership exactly once" {
    var s = TextInputState{ .io = std.testing.io, .allocator = testing.allocator };
    defer s.deinit();

    var value_buf: [32]u8 = undefined;
    for (0..TextInputState.UNDO_CAPACITY + 9) |i| {
        const value = try std.fmt.bufPrint(&value_buf, "value-{d}", .{i});
        _ = s.setText(value);
    }
    try testing.expectEqual(@as(u8, @intCast(TextInputState.UNDO_CAPACITY)), s.undo_count);

    var undo_steps: usize = 0;
    while (s.undo_count > 0) : (undo_steps += 1) s.undo();
    try testing.expectEqual(TextInputState.UNDO_CAPACITY, undo_steps);
    // The first nine snapshots were evicted; the oldest retained value is 8.
    try testing.expectEqualStrings("value-8", s.getText());

    while (s.redo_count > 0) s.redo();
    try testing.expectEqualStrings("value-72", s.getText());
}

test "single-line edit OOM preserves text history and coalescing state" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var s = TextInputState{ .io = std.testing.io, .allocator = failing.allocator() };
    defer s.deinit();

    s.insertText("seed"); // empty snapshot needs no allocation
    s.insertText(" "); // allocation #0 succeeds and boundary breaks coalescing
    try testing.expectEqualStrings("seed ", s.getText());
    try testing.expectEqual(@as(u8, 2), s.undo_count);
    const saved_snapshot = s.undo_stack[1].text.?.ptr;
    const saved_cursor = s.cursor_pos;
    const saved_coalesce_cursor = s.undo_coalesce_cursor;
    const saved_coalesce_at = s.undo_coalesce_at;

    s.insertText("x"); // allocation #1 fails
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqualStrings("seed ", s.getText());
    try testing.expectEqual(@as(u8, 2), s.undo_count);
    try testing.expectEqual(saved_snapshot, s.undo_stack[1].text.?.ptr);
    try testing.expectEqual(saved_cursor, s.cursor_pos);
    try testing.expectEqual(saved_coalesce_cursor, s.undo_coalesce_cursor);
    try testing.expectEqual(saved_coalesce_at, s.undo_coalesce_at);
    try testing.expectEqual(UndoCoalesceKind.none, s.undo_coalesce_kind);
}

test "single-line undo OOM is transactional" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var s = TextInputState{ .io = std.testing.io, .allocator = failing.allocator() };
    defer s.deinit();

    s.insertText("seed");
    s.insertText(" "); // allocation #0 creates the second undo target
    const undo_count = s.undo_count;
    const target_ptr = s.undo_stack[1].text.?.ptr;
    s.undo(); // allocation #1 for the current redo snapshot fails

    try testing.expect(failing.has_induced_failure);
    try testing.expectEqualStrings("seed ", s.getText());
    try testing.expectEqual(undo_count, s.undo_count);
    try testing.expectEqual(@as(u8, 0), s.redo_count);
    try testing.expectEqual(target_ptr, s.undo_stack[1].text.?.ptr);
}

test "single-line capacity is 2048 bytes and truncation is grapheme-safe" {
    try testing.expectEqual(@as(usize, 2048), editable_block.MAX_INPUT_BYTES);
    var s = TextInputState{ .io = std.testing.io, .allocator = testing.allocator };
    defer s.deinit();

    var exact: [editable_block.MAX_INPUT_BYTES]u8 = undefined;
    @memset(&exact, 'x');
    try testing.expectEqual(exact.len, s.setText(&exact));
    try testing.expectEqual(exact.len, s.getText().len);

    s.clearUndoHistory();
    const prefix_len = editable_block.MAX_INPUT_BYTES - 4;
    var oversized: [editable_block.MAX_INPUT_BYTES + 4]u8 = undefined;
    @memset(oversized[0..prefix_len], 'x');
    @memcpy(oversized[prefix_len..], gc_thumbs_tone);
    try testing.expectEqual(prefix_len, s.setText(&oversized));
    try testing.expect(std.unicode.utf8ValidateSlice(s.getText()));
    try testing.expectEqualStrings(oversized[0..prefix_len], s.getText());
}

test "IME commit keeps full duplicate candidate and preserves composition on failed undo allocation" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator() };
    defer state.deinit();
    const long = (@as([("中").len * (200)]u8, @bitCast(@as([200][("中").len]u8, @splat(("中").*)))) ++ "");
    state.handleImeCommitEvent(long);
    state.handleImePreeditEvent("", 0);
    try t.expect(state.consumeImePostCommitDuplicate(long));
    try t.expectEqualStrings(long, state.getText());
    state.selection_anchor = 0;
    state.cursor_pos = state.getText().len;
    state.handleImePreeditEvent("候选", 6);
    failing.fail_index = failing.alloc_index;
    state.handleImeCommitEvent("新");
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqualStrings(long, state.getText());
    try t.expect(state.imeIsComposing());
    try t.expectEqualStrings("候选", state.preeditText());
}

test "failed IME commit preserves pending composition and replacement selection" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator() };
    defer s.deinit();
    _ = s.setText("keep");
    s.selection_anchor = 0;
    s.cursor_pos = 4;
    s.handleImePreeditEvent("候选", 6);
    const pending_cursor = s.cursor_pos;
    const pending_anchor = s.selection_anchor;
    const pending_replacement = s.ime_replacement;
    try t.expectEqualStrings("候选", s.buildDisplayText(null));
    failing.fail_index = failing.alloc_index;
    s.handleImeCommitEvent("新");
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqualStrings("keep", s.getText());
    try t.expect(s.imeIsComposing());
    try t.expect(failing.has_induced_failure);
    try t.expectEqual(pending_cursor, s.cursor_pos);
    try t.expectEqual(pending_anchor, s.selection_anchor);
    try t.expectEqualDeep(pending_replacement, s.ime_replacement);
    try t.expectEqualStrings("候选", s.preeditText());
}

test "IME insertion preserves single and legacy multiline state at every allocation failure" {
    const t = std.testing;
    for ([_]bool{ false, true }) |multiline| {
        var succeeded = false;
        for (0..200) |failure| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var doc = TextareaDocument.init(failing.allocator());
            defer doc.deinit();
            var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator(), .multiline = multiline, .accept_newline = multiline, .textarea_doc = if (multiline) &doc else null };
            defer s.deinit();
            const base = "keep tail";
            _ = s.setText(base);
            s.clearUndoHistory();
            s.cursor_pos = base.len;
            s.insertText("!");
            s.undo();
            s.selection_anchor = 0;
            s.cursor_pos = 4;
            s.handleImePreeditEvent("候选", 6);
            const pending_cursor = s.cursor_pos;
            const pending_anchor = s.selection_anchor;
            const pending_replacement = s.ime_replacement;
            const pending_doc_cursor = s.textarea_cursor;
            const undo_count = s.undo_count;
            const redo_count = s.redo_count;
            const ta_undo_count = s.ta_undo_count;
            const ta_redo_count = s.ta_redo_count;
            const old_text = doc.text.items.ptr;
            const old_lines = doc.line_starts.items.ptr;
            const value = if (multiline) (@as([("文\n").len * (300)]u8, @bitCast(@as([300][("文\n").len]u8, @splat(("文\n").*)))) ++ "") else (@as([("文").len * (200)]u8, @bitCast(@as([200][("文").len]u8, @splat(("文").*)))) ++ "");
            const expected = if (multiline) (@as([("文\n").len * (300)]u8, @bitCast(@as([300][("文\n").len]u8, @splat(("文\n").*)))) ++ "") ++ " tail" else (@as([("文").len * (200)]u8, @bitCast(@as([200][("文").len]u8, @splat(("文").*)))) ++ "") ++ " tail";
            failing.fail_index = failing.alloc_index + failure;
            failing.resize_fail_index = failing.resize_index;
            const result = s.handleImeCommitEventChecked(value);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |_| {
                succeeded = true;
            } else |_| {
                try t.expect(failing.has_induced_failure);
                try t.expectEqualStrings(base, s.getText());
                try t.expectEqual(pending_cursor, s.cursor_pos);
                try t.expectEqual(pending_anchor, s.selection_anchor);
                try t.expectEqualDeep(pending_replacement, s.ime_replacement);
                try t.expectEqualDeep(pending_doc_cursor, s.textarea_cursor);
                try t.expect(s.imeIsComposing());
                try t.expectEqualStrings("候选", s.preeditText());
                try t.expectEqual(undo_count, s.undo_count);
                try t.expectEqual(redo_count, s.redo_count);
                try t.expectEqual(ta_undo_count, s.ta_undo_count);
                try t.expectEqual(ta_redo_count, s.ta_redo_count);
                try t.expectEqual(old_text, doc.text.items.ptr);
                try t.expectEqual(old_lines, doc.line_starts.items.ptr);
                try s.handleImeCommitEventChecked(value);
            }
            try t.expectEqualStrings(expected, s.getText());
            try t.expect(s.consumeImePostCommitDuplicate(value));
            try t.expect(!s.consumeImePostCommitDuplicate(value));
            try t.expect(s.ime_pending_commit.owned == null);
            if (multiline) try t.expectEqual(@as(usize, 301), doc.lineCount());
            s.undo();
            try t.expectEqualStrings(base, s.getText());
            s.redo();
            try t.expectEqualStrings(expected, s.getText());
            if (succeeded) break;
        }
        try t.expect(succeeded);
    }
}

test "insertion snapshots aliased text and failed replacement range restores cursor state" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator() };
    defer s.deinit();
    _ = s.setText("abcdef");
    s.selection_anchor = 2;
    s.cursor_pos = 4;
    try s.insertTextChecked(s.getText()[1..5]);
    try t.expectEqualStrings("abbcdeef", s.getText());
    const cursor = s.cursor_pos;
    const anchor = s.selection_anchor;
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, s.handleImeCommitReplaceEventChecked((@as([("x").len * (600)]u8, @bitCast(@as([600][("x").len]u8, @splat(("x").*)))) ++ ""), 0, 3));
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqual(cursor, s.cursor_pos);
    try t.expectEqual(anchor, s.selection_anchor);
    try t.expectEqualStrings("abbcdeef", s.getText());
    try s.handleImeCommitReplaceEventChecked("", 0, 2);
    try t.expectEqualStrings("bcdeef", s.getText());
    s.undo();
    try t.expectEqualStrings("abbcdeef", s.getText());
}

test "legacy input set and history restore survive every allocation failure" {
    const t = std.testing;
    for (0..3) |operation| {
        var succeeded = false;
        for (0..100) |failure| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var doc = TextareaDocument.init(failing.allocator());
            defer doc.deinit();
            const original = (@as([("keep\n").len * (80)]u8, @bitCast(@as([80][("keep\n").len]u8, @splat(("keep\n").*)))) ++ "");
            try doc.setTextChecked(original);

            var s: TextInputState = .{ .io = @import("std").testing.io, .multiline = true, .textarea_doc = &doc, .allocator = failing.allocator() };
            defer s.deinit();
            s.cursor_pos = original.len;
            s.selection_anchor = 0;
            try s.insertTextChecked("x");
            if (operation == 2) s.undo();
            const old_text = try t.allocator.dupe(u8, doc.getText());
            defer t.allocator.free(old_text);
            const text_ptr = doc.text.items.ptr;
            const lines_ptr = doc.line_starts.items.ptr;
            const old_cursor = s.cursor_pos;
            const old_anchor = s.selection_anchor;
            const old_undo = s.ta_undo_count;
            const old_redo = s.ta_redo_count;
            failing.fail_index = failing.alloc_index + failure;
            failing.resize_fail_index = failing.resize_index;
            switch (operation) {
                0 => {
                    _ = s.setText((@as([("new\n").len * (120)]u8, @bitCast(@as([120][("new\n").len]u8, @splat(("new\n").*)))) ++ ""));
                },
                1 => s.undo(),
                2 => s.redo(),
                else => unreachable,
            }
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            succeeded = s.ta_undo_count != old_undo or s.ta_redo_count != old_redo;
            if (!succeeded) {
                try t.expect(failing.has_induced_failure);
                try t.expectEqualStrings(old_text, doc.getText());
                try t.expectEqual(text_ptr, doc.text.items.ptr);
                try t.expectEqual(lines_ptr, doc.line_starts.items.ptr);
                try t.expectEqual(old_cursor, s.cursor_pos);
                try t.expectEqual(old_anchor, s.selection_anchor);
                switch (operation) {
                    0 => {
                        _ = try s.setTextChecked((@as([("new\n").len * (120)]u8, @bitCast(@as([120][("new\n").len]u8, @splat(("new\n").*)))) ++ ""));
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

test "reconversion preedit preserves committed text on cancel and restores undo text" {
    const t = std.testing;
    for ([_]bool{ false, true }) |multiline| {
        var doc = TextareaDocument.init(t.allocator);
        defer doc.deinit();
        var s: TextInputState = .{ .io = @import("std").testing.io, .multiline = multiline, .textarea_doc = if (multiline) &doc else null, .allocator = t.allocator };
        defer s.deinit();
        _ = s.setText("x漢字y");
        s.cursor_pos = 8;
        s.selection_anchor = null;
        s.handleImePreeditReplaceEvent("かんじ", 9, 1, 7);
        try t.expectEqualStrings("x漢字y", s.getText());
        try t.expectEqualStrings("xかんじy", s.buildDisplayText(null));
        s.cancelImeComposition();
        try t.expectEqualStrings("x漢字y", s.getText());
        try t.expectEqual(@as(usize, 8), s.cursor_pos);
        try t.expectEqual(@as(?usize, null), s.selection_anchor);
        s.handleImePreeditReplaceEvent("かんじ", 9, 1, 7);
        s.handleImeCommitEvent("感じ");
        try t.expectEqualStrings("x感じy", s.getText());
        s.undo();
        try t.expectEqualStrings("x漢字y", s.getText());
    }
}

test "shared input reconversion commit preserves candidate and both histories through allocation failure" {
    const t = std.testing;
    for ([_]bool{ false, true }) |multiline| {
        var completed = false;
        for (0..150) |failure| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var doc = TextareaDocument.init(failing.allocator());
            defer doc.deinit();
            var s: TextInputState = .{ .io = @import("std").testing.io, .multiline = multiline, .textarea_doc = if (multiline) &doc else null, .allocator = failing.allocator() };
            _ = s.setText("x漢字y");
            defer s.deinit();
            s.cursor_pos = 8;
            s.insertText("!");
            s.undo();
            s.cursor_pos = 8;
            s.selection_anchor = null;
            s.handleImePreeditReplaceEvent("候选", 6, 1, 7);
            const old_undo = (if (multiline) s.ta_undo_count else s.undo_count);
            const old_redo = (if (multiline) s.ta_redo_count else s.redo_count);
            const value = (@as([("新").len * (200)]u8, @bitCast(@as([200][("新").len]u8, @splat(("新").*)))) ++ "");
            failing.fail_index = failing.alloc_index + failure;
            failing.resize_fail_index = failing.resize_index;
            const result = s.handleImeCommitReplaceEventChecked(value, std.math.maxInt(u32), std.math.maxInt(u32));
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |_| {
                completed = true;
            } else |_| {
                try t.expect(failing.has_induced_failure);
                try t.expectEqualStrings("x漢字y", s.getText());
                try t.expectEqual(old_undo, (if (multiline) s.ta_undo_count else s.undo_count));
                try t.expectEqual(old_redo, (if (multiline) s.ta_redo_count else s.redo_count));
                try t.expect(s.ime_replacement != null);
                try t.expect(s.imeIsComposing());
                try t.expectEqualStrings("候选", s.preeditText());
                try t.expectEqual(@as(usize, 1), s.cursor_pos);
                try t.expectEqual(@as(?usize, 7), s.selection_anchor);
                try s.handleImeCommitReplaceEventChecked(value, std.math.maxInt(u32), std.math.maxInt(u32));
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

test "shared reconversion cancellation repeated ranges empty commit and password display" {
    const t = std.testing;
    var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator };
    defer s.deinit();
    _ = s.setText("x漢字y");
    s.cursor_pos = 8;
    s.selection_anchor = 7;
    const history = s.undo_count;
    s.handleImePreeditReplaceEvent("かんじ", 9, 1, 7);
    s.handleImePreeditReplaceEvent("候", 3, 1, 4);
    try t.expectEqualStrings("x候字y", s.buildDisplayText(null));
    s.handleImePreeditEvent("", 0);
    try t.expectEqualStrings("x漢字y", s.getText());
    try t.expectEqual(@as(usize, 8), s.cursor_pos);
    try t.expectEqual(@as(?usize, 7), s.selection_anchor);
    try t.expectEqual(history, s.undo_count);
    s.handleImePreeditReplaceEvent("かんじ", 9, 1, 7);
    s.input_type = .password;
    try t.expectEqualStrings("*****", s.buildDisplayText(null));
    s.input_type = .text;
    s.undo(); // First undo cancels the still-uncommitted composition.
    try t.expectEqualStrings("x漢字y", s.getText());
    try t.expectEqual(history, s.undo_count);
    s.handleImePreeditReplaceEvent("候", 3, 2, 6); // inside UTF-8 graphemes
    try t.expectEqualStrings("x候y", s.buildDisplayText(null));
    try s.handleImeCommitEventChecked("");
    try t.expectEqualStrings("xy", s.getText());
    s.undo();
    try t.expectEqualStrings("x漢字y", s.getText());
}

test "reconversion display geometry allocation failure preserves canonical model" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var doc = TextareaDocument.init(failing.allocator());
    defer doc.deinit();
    doc.setText("x漢字y");
    var wm = TextareaWrapMap.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var s: TextInputState = .{ .io = @import("std").testing.io, .multiline = true, .textarea_doc = &doc, .textarea_wrap = &wm, .allocator = t.allocator };
    defer s.deinit();
    s.handleImePreeditReplaceEvent("候", 3, 1, 7);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    s.refreshMultilineImeGeometry();
    try t.expect(!s.ime_visual_valid);
    try t.expectEqualStrings("x漢字y", s.getText());
    try t.expect(s.imeIsComposing());
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    s.refreshMultilineImeGeometry();
    try t.expect(s.ime_visual_valid);
}

test "shared preedit preserves long candidate and the full canonical tail" {
    const t = std.testing;
    for ([_]bool{ false, true }) |multiline| {
        var doc = TextareaDocument.init(t.allocator);
        defer doc.deinit();
        var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .multiline = multiline, .textarea_doc = if (multiline) &doc else null };
        defer s.deinit();
        const original = if (multiline) (@as([("x").len * (6000)]u8, @bitCast(@as([6000][("x").len]u8, @splat(("x").*)))) ++ "") else "xyz";
        _ = try s.setTextChecked(original);
        s.cursor_pos = 1;
        const candidate = (@as([("漢").len * (1000)]u8, @bitCast(@as([1000][("漢").len]u8, @splat(("漢").*)))) ++ "") ++ "👩‍💻";
        s.setImePreedit(candidate, candidate.len - 1);
        try t.expectEqual(candidate.len, s.ime_preedit_len);
        try t.expectEqual(candidate.len, s.effectiveImeCursorOffset());
        const display = s.buildDisplayText(null);
        try t.expectEqual(original.len + candidate.len, display.len);
        try t.expectEqualStrings(candidate, display[1 .. 1 + candidate.len]);
        try t.expectEqualStrings(original[1..], display[1 + candidate.len ..]);
        try t.expectEqualStrings(original, s.getText());
        s.cancelImeComposition();
        try t.expectEqualStrings(original, s.buildDisplayText(null));
    }
}

test "shared preedit update is atomic across candidate scratch and node allocation failures" {
    const t = std.testing;
    for ([_]bool{ false, true }) |multiline| {
        var completed = false;
        for (0..24) |failure| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var cx = try core.Cx.init(failing.allocator(), std.testing.io);
            defer cx.deinit();
            const row = try core.box(cx, .{}, .{});
            cx.root = row;
            row.setText(.{ .content = "" });
            var doc = TextareaDocument.init(failing.allocator());
            defer doc.deinit();
            var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator(), .multiline = multiline, .textarea_doc = if (multiline) &doc else null, .cx_ref = cx, .text_display_node = row };
            defer s.deinit();
            _ = try s.setTextChecked("x漢字y");
            s.insertText("!");
            s.undo();
            s.cursor_pos = 8;
            s.selection_anchor = 7;
            try s.handleImePreeditReplaceEventChecked("旧", 3, 1, 7);
            const undo_count = if (multiline) s.ta_undo_count else s.undo_count;
            const redo_count = if (multiline) s.ta_redo_count else s.redo_count;
            failing.fail_index = failing.alloc_index + failure;
            failing.resize_fail_index = failing.resize_index;
            const candidate = (@as([("漢").len * (1000)]u8, @bitCast(@as([1000][("漢").len]u8, @splat(("漢").*)))) ++ "");
            const result = s.handleImePreeditReplaceEventChecked(candidate, candidate.len, 0, 8);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |_| {
                completed = true;
            } else |err| {
                try t.expectEqual(error.OutOfMemory, err);
                try t.expect(failing.has_induced_failure);
                try t.expectEqualStrings("旧", s.preeditText());
                try t.expectEqualStrings("x旧y", row.getText().?.content);
                try t.expectEqual(@as(usize, 1), s.cursor_pos);
                try t.expectEqual(@as(?usize, 7), s.selection_anchor);
                try t.expectEqual(@as(usize, 1), s.ime_replacement.?.start);
                try t.expectEqual(@as(usize, 7), s.ime_replacement.?.end);
                try s.handleImePreeditReplaceEventChecked(candidate, candidate.len, 0, 8);
            }
            try t.expectEqualStrings("x漢字y", s.getText());
            try t.expectEqual(undo_count, if (multiline) s.ta_undo_count else s.undo_count);
            try t.expectEqual(redo_count, if (multiline) s.ta_redo_count else s.redo_count);
            try t.expectEqualStrings(candidate, row.getText().?.content);
            // Owned candidate can be used as the source of another update.
            try s.setImePreeditChecked(s.preeditText()[3..], candidate.len - 3);
            try t.expectEqualStrings(candidate[3..], row.getText().?.content);
            s.cancelImeComposition();
            try t.expectEqual(@as(usize, 8), s.cursor_pos);
            try t.expectEqual(@as(?usize, 7), s.selection_anchor);
            try t.expectEqualStrings("x漢字y", row.getText().?.content);
            if (completed) break;
        }
        try t.expect(completed);
    }
}

test "long fallback preedit wrapping preserves graphemes and complete display coordinates" {
    const t = std.testing;
    var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .multiline = true, .soft_wrap = true, .input_inner_w = 1, .char_width = 8 };
    defer s.deinit();
    const candidate = (@as([("👩‍💻").len * (500)]u8, @bitCast(@as([500][("👩‍💻").len]u8, @splat(("👩‍💻").*)))) ++ "");
    try s.setImePreeditChecked(candidate, candidate.len);
    const wrapped = try s.buildWrappedDisplayTextChecked(null);
    var lines = std.mem.splitScalar(u8, wrapped, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        try t.expectEqualStrings("👩‍💻", line);
        count += 1;
    }
    try t.expectEqual(@as(usize, 500), count);
    const pos = s.multilineVisualPosForOffset(candidate, s.displayCursorByteOffset());
    try t.expectEqual(@as(usize, 499), pos.row);
    var tiny: [2]u8 = undefined;
    try t.expectEqualStrings("", s.appendWrappedLines("漢", &tiny));
}

test "long shared multiline preedit geometry uses the full visible document" {
    const t = std.testing;
    const Map = @import("text_core").wrap_map.WrapMap(TextareaDocument);
    var doc = TextareaDocument.init(t.allocator);
    defer doc.deinit();
    var wm = Map.init(t.allocator, @import("std").testing.io);
    defer wm.deinit();
    var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .multiline = true, .soft_wrap = true, .textarea_doc = &doc, .textarea_wrap = &wm, .input_inner_w = 120, .char_width = 12, .font_size = 20 };
    defer s.deinit();
    _ = try s.setTextChecked((@as([("x").len * (6000)]u8, @bitCast(@as([6000][("x").len]u8, @splat(("x").*)))) ++ ""));
    try s.setImePreeditChecked((@as([("a").len * (1000)]u8, @bitCast(@as([1000][("a").len]u8, @splat(("a").*)))) ++ ""), 1000);
    try t.expectEqual(@as(usize, 7000), s.displayCursorByteOffset());
    s.refreshMultilineImeGeometry();
    try t.expect(s.ime_visual_valid);
    try t.expectEqual(@as(u32, 700), s.ime_visual_total_lines);
    try t.expectEqual(@as(u32, 699), s.ime_visual_display_line);
    try t.expectApproxEqAbs(@as(f32, 120), s.ime_visual_cursor_x, 0.01);
    try t.expectEqualStrings((@as([("x").len * (6000)]u8, @bitCast(@as([6000][("x").len]u8, @splat(("x").*)))) ++ ""), doc.getText());
}

test "growable Input preserves long text through insertion undo redo and aliases" {
    const t = std.testing;
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .growable = true };
    defer state.deinit();
    const long = (@as([("界").len * (1000)]u8, @bitCast(@as([1000][("界").len]u8, @splat(("界").*)))) ++ "");
    try t.expectEqual(long.len, try state.setTextChecked(long));
    try t.expectEqualStrings(long, state.getText());
    state.cursor_pos = 3;
    state.selection_anchor = 6;
    try state.insertTextChecked("abc");
    try t.expectEqualStrings("界abc" ++ (@as([("界").len * (998)]u8, @bitCast(@as([998][("界").len]u8, @splat(("界").*)))) ++ ""), state.getText());
    state.undo();
    try t.expectEqualStrings(long, state.getText());
    state.redo();
    try t.expectEqualStrings("界abc" ++ (@as([("界").len * (998)]u8, @bitCast(@as([998][("界").len]u8, @splat(("界").*)))) ++ ""), state.getText());
    _ = try state.setTextChecked(state.getText()[3..]);
    try t.expectEqualStrings("abc" ++ (@as([("界").len * (998)]u8, @bitCast(@as([998][("界").len]u8, @splat(("界").*)))) ++ ""), state.getText());
    state.undo();
    try t.expectEqualStrings("界abc" ++ (@as([("界").len * (998)]u8, @bitCast(@as([998][("界").len]u8, @splat(("界").*)))) ++ ""), state.getText());
    _ = try state.setTextChecked(long);
    try state.insertTextChecked(state.getText());
    try t.expectEqualStrings(long ++ long, state.getText());
    state.undo();
    try t.expectEqualStrings(long, state.getText());
    state.redo();
    try t.expectEqualStrings(long ++ long, state.getText());
}

test "growable Input allocation failure preserves storage text and history" {
    const t = std.testing;
    for ([_]bool{ false, true }) |insert| {
        var succeeded = false;
        for (0..32) |fail_at| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator(), .growable = true };
            defer state.deinit();
            _ = try state.setTextChecked("old");
            state.clearUndoHistory();
            const old_ptr = state.getText().ptr;
            failing.fail_index = failing.alloc_index + fail_at;
            failing.resize_fail_index = failing.resize_index;
            const long = (@as([("界").len * (1000)]u8, @bitCast(@as([1000][("界").len]u8, @splat(("界").*)))) ++ "");
            const result: anyerror!void = if (insert) state.insertTextChecked(long) else blk: {
                _ = state.setTextChecked(long) catch |err| break :blk err;
                break :blk {};
            };
            if (result) |_| {
                try t.expectEqualStrings(if (insert) "old" ++ long else long, state.getText());
                succeeded = true;
                break;
            } else |err| {
                try t.expectEqual(error.OutOfMemory, err);
                try t.expectEqualStrings("old", state.getText());
                try t.expect(old_ptr == state.getText().ptr);
                try t.expectEqual(@as(u8, 0), state.undo_count);
                try t.expectEqual(@as(u8, 0), state.redo_count);
            }
        }
        try t.expect(succeeded);
    }
}

test "Input stationary edge drag preserves anchor and stops at bounds" {
    const t = std.testing;
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .focused = true, .is_dragging = true, .input_inner_w = 80 };
    defer state.deinit();
    _ = try state.setTextChecked((@as([("你abc").len * (40)]u8, @bitCast(@as([40][("你abc").len]u8, @splat(("你abc").*)))) ++ ""));
    state.cursor_pos = 0;
    state.selection_anchor = 0;
    try t.expect(!state.advanceEdgeDrag(100)); // No move: never use stale global pointer.
    state.drag_pointer = .{ .x = 120, .y = 0, .time_ms = 0 };
    try t.expect(state.advanceEdgeDrag(100));
    try t.expect(state.scroll_x > 0 and state.cursor_pos > 0);
    try t.expectEqual(@as(?usize, 0), state.selection_anchor);
    try t.expect(state.getText()[state.cursor_pos] & 0xc0 != 0x80);
    const saved_scroll = state.scroll_x;
    const saved_cursor = state.cursor_pos;
    try t.expect(state.advanceEdgeDrag(100));
    try t.expectEqual(saved_scroll, state.scroll_x);
    try t.expectEqual(saved_cursor, state.cursor_pos);
    state.is_dragging = false;
    try t.expect(!state.advanceEdgeDrag(200));
    try t.expectEqual(saved_scroll, state.scroll_x);
    state.is_dragging = true;
    state.drag_pointer = .{ .x = 40, .y = 0, .time_ms = 200 };
    try t.expect(!state.advanceEdgeDrag(300)); // Re-entering the viewport stops repetition.
    state.drag_pointer = .{ .x = -30, .y = 0, .time_ms = 300 };
    for (0..20) |i| _ = state.advanceEdgeDrag(@floatFromInt(400 + i * 100));
    try t.expectEqual(@as(f32, 0), state.scroll_x);
    try t.expectEqual(@as(usize, 0), state.cursor_pos);
    try t.expect(!state.advanceEdgeDrag(2500));
}

test "IME relative deletion excludes selected bytes and preserves backwards selection" {
    var state = gcMakeState("A你SEL好Z");
    defer state.deinit();
    state.cursor_pos = 4;
    state.selection_anchor = 7;
    try state.handleImeDeleteSurrounding(3, 3);
    try testing.expectEqualStrings("ASELZ", state.getText());
    try testing.expectEqual(@as(usize, 1), state.cursor_pos);
    try testing.expectEqual(@as(?usize, 4), state.selection_anchor);
    try state.handleImeDeleteSurrounding(2, 0);
    try testing.expectEqualStrings("ASELZ", state.getText());
    state.setImePreedit("你好吗", 3);
    state.setImeAttributes(false, 6);
    try testing.expect(!state.ime_cursor_visible);
    try testing.expectEqual(@as(usize, 3), state.effectiveImeCursorOffset());
    try testing.expect(state.shouldShowImeSelectionHighlight());
    state.clearImePreedit();
    try testing.expect(state.ime_cursor_visible);
}
