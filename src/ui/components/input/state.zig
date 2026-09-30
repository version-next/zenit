const ImeReplacement = @import("ime_replacement.zig").ImeReplacement;
/// TextInputState — Input/Textarea 核心状态
///
/// 包含 TextInputState struct 定义及全部方法。
const std = @import("std");
const core = @import("../../core.zig");
const theme = core.theme;
const events = @import("../../events.zig");
const KeyCode = events.KeyCode;
const editable_block = @import("../editable_block/mod.zig");
const ImeText = @import("ime_text.zig").ImeText;
const text_utils = @import("text_utils.zig");
const caret_blink = @import("caret_blink.zig");
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

/// Textarea 专用 undo 快照（动态文本，不受 256 字节限制）
pub const TaUndoEntry = struct {
    /// 文本快照（null = 空 slot）
    text: ?[]const u8 = null,
    /// 光标位置 (字节偏移)
    cursor_pos: usize = 0,
    selection_anchor: ?usize = null,

    fn deinit(self: *TaUndoEntry, allocator: std.mem.Allocator) void {
        if (self.text) |t| allocator.free(t);
        self.text = null;
    }
};

/// 文本输入内部状态
/// 可合并编辑的种类。不同种类之间不合并（打字后按 Backspace 会开新的 undo 单元）。
pub const UndoCoalesceKind = enum(u8) { none, insert, delete_backward, delete_forward };

/// Once a state records single-line history it owns heap allocations through
/// `allocator`; callers constructing a state directly must call `deinit`.
pub const TextInputState = struct {
    const blink_half_period_ns: i128 = 500 * std.time.ns_per_ms;

    /// undo/redo 栈深。原来是 32，连续打字每键一个快照时历史只有 ~32 次按键；
    /// 合并落地后一个快照 = 一个输入单元，同样容量能覆盖远更长的历史。
    pub const UNDO_CAPACITY: usize = 64;

    /// 连续输入合并的最大间隔。超过这个静默时间视为新的输入单元
    /// （对齐 AppKit/NSUndoManager 的 grouping-by-idle 行为）。
    pub const undo_coalesce_idle_ns: u64 = 800 * std.time.ns_per_ms;

    /// 文本缓冲区 (固定大小, 避免动态分配 —— 见 editable_block.MAX_INPUT_BYTES)
    buffer: [editable_block.MAX_INPUT_BYTES]u8 = [_]u8{0} ** editable_block.MAX_INPUT_BYTES,
    buffer_len: usize = 0,
    /// Opt-in for fields whose business value must not be silently truncated.
    growable: bool = false,
    input_overflow: ?[]u8 = null,

    cursor_pos: usize = 0,
    /// 同一逻辑 byte 在 bidi/soft-wrap 边界可能有两个视觉位置。
    cursor_affinity: text_coordinates.Affinity = .downstream,
    /// Textarea vertical navigation keeps a visual pixel column, not a UTF-8
    /// byte/codepoint column. Reset by horizontal movement or text mutation.
    preferred_visual_x: ?f32 = null,

    /// 选择锚点 (如果有选择)
    selection_anchor: ?usize = null,

    /// 撤销/重做栈。槽位只持有当时文本的 owned slice，未使用槽为 null。
    undo_stack: [UNDO_CAPACITY]UndoSnapshot = [_]UndoSnapshot{.{}} ** UNDO_CAPACITY,
    undo_count: u8 = 0,
    redo_stack: [UNDO_CAPACITY]UndoSnapshot = [_]UndoSnapshot{.{}} ** UNDO_CAPACITY,
    redo_count: u8 = 0,

    /// ── Undo 合并（coalescing）──
    /// 原生控件把「连续输入」合并成一个 undo 单元，而不是一次按键一个快照。
    /// 记录上一次可合并编辑的种类、结束光标位置与时间戳，用于判定是否续接。
    undo_coalesce_kind: UndoCoalesceKind = .none,
    /// 上一次可合并编辑结束后的光标字节偏移（光标跳走则断开）
    undo_coalesce_cursor: usize = 0,
    /// 上一次可合并编辑的时间戳（ns 单调时钟；超时则断开）
    undo_coalesce_at: ?std.time.Instant = null,

    /// 焦点状态
    focused: bool = false,

    /// 水平滚动偏移 (像素, 正值表示文本向左滚动)
    scroll_x: f32 = 0,

    /// 脏标记 (需要重新渲染)
    dirty: bool = false,

    /// 光标闪烁相位（实现见 caret_blink.zig）。相位算术与输入状态无关，
    /// 已析出成可独立单测的小值类型。
    blink: caret_blink.CaretBlink = .{},
    /// 上一帧可见性，用于只在相位翻转时标脏
    last_blink_visible: bool = true,
    /// 鼠标拖拽中
    is_dragging: bool = false,
    /// 多击检测：最近一次 mouse_down 时间戳
    last_mouse_down_instant: ?std.time.Instant = null,
    /// 多击检测：最近一次 mouse_down 位置
    last_mouse_down_pos: [2]f32 = .{ 0, 0 },
    /// 多击计数（按下阶段）
    consecutive_mouse_downs: u8 = 0,
    /// 多击选词/全选后，按住鼠标期间禁止进入拖拽更新
    suspend_drag_until_mouse_up: bool = false,
    /// 光标节点引用
    cursor_node: ?*core.Node = null,
    /// 选区节点引用（仅 multiline 路径使用；single-line 走 text_display_node 上的 spans）
    selection_node: ?*core.Node = null,
    /// IME 组合下划线节点引用（仅 multiline 路径使用；single-line 走 spans 的 underline）
    preedit_underline_node: ?*core.Node = null,
    /// 文本显示节点引用（保留模式下用于动态更新 text content）
    text_display_node: ?*core.Node = null,
    /// Single-line 的 selection / IME spans 缓冲（owned，与 text_display_node 同生命周期）
    /// 容量足够：1 selection + 1 preedit underline + 1 ime marked highlight = 3
    text_spans_buf: [4]core.TextSpan = undefined,
    text_spans_len: u8 = 0,
    /// Placeholder 文本（用于 beforeRender 判断是否显示 placeholder）
    placeholder_text: ?[]const u8 = null,
    /// Placeholder 颜色覆盖
    placeholder_color: ?core.Color = null,
    /// Focus ring 承载节点（外层不裁剪容器）
    focus_ring_host: ?*core.Node = null,
    /// 是否处于 Group attached 组合场景
    grouped_attached: bool = false,
    /// 输入框容器节点引用（on_focus/on_blur 更新边框样式）
    input_container_node: ?*core.Node = null,
    /// hover Signal 引用（blur 时判断是否保留 hover 边框）
    hover_signal: ?*core.Signal(bool) = null,
    /// 是否有错误状态（on_focus/on_blur 时跳过边框更新）
    has_error: bool = false,
    /// 复合控件嵌入模式：父控件负责 border / hover / focus chrome。
    embedded_chrome: bool = false,
    /// StyleExt 写入使用的 allocator（Group corner radius 透传等）
    /// Owns single-line undo/redo snapshots. Component mounts replace this
    /// fallback with their Scope/Cx allocator and register `deinit`.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    // border 动画已统一到 Transition 系统（enableImplicitAnimation + setBorderColor）
    /// input_container 全局 x (on_before_render 更新)
    container_x: f32 = 0,
    /// input_container 全局 y (on_before_render 更新)
    container_y: f32 = 0,
    /// 字符宽度缓存
    char_width: f32 = 7.8,
    /// 文本字重（400=regular, 500=medium, 700=bold）
    font_weight: u16 = 400,
    /// 文本字号缓存
    font_size: f32 = 13.0,
    /// 水平 padding 缓存
    padding_h: f32 = 8.0,
    /// 垂直 padding 缓存
    padding_v: f32 = 0.0,
    /// 行高缓存
    line_height: f32 = 16.0,
    /// 内部可用宽度缓存
    input_inner_w: f32 = 200.0,
    /// Cx 引用 (拖拽时读取 mouse_x)
    cx_ref: ?*core.Cx = null,

    /// password 模式下单个 '*' 的 advance 缓存。每帧 O(1) 命中 ShapingCache 偏贵，
    /// 而 mask = N 个相同 '*'，advance 是线性的 N × single_star_width，没必要每个
    /// caller 都重 shape。invalidated 当 font_size/weight/cx 任一变化时。
    cached_star_advance: f32 = 0,
    cached_star_font_size: f32 = -1,
    cached_star_font_weight: u16 = 0,

    /// 输入类型
    input_type: InputType = .text,
    /// 是否多行输入
    multiline: bool = false,
    /// 是否接受换行输入
    accept_newline: bool = false,
    /// 是否软换行（按容器宽度自动折行）
    soft_wrap: bool = false,
    /// 无滚动壳的多行编辑器按 WrapMap 的视觉行数自动增长高度。
    /// Textarea 使用 VirtualList/固定 viewport，因此保持 false。
    multiline_auto_height: bool = false,
    /// 文本显示缓冲区（密码掩码 / IME 组合文本）
    // Small projections stay inline; overflow storage retains complete text.
    // Retained text nodes own copies and never borrow these scratch buffers.
    display_buffer: [editable_block.MAX_INPUT_BYTES + 256]u8 = [_]u8{0} ** (editable_block.MAX_INPUT_BYTES + 256),
    /// Last successfully published display snapshot hash.
    display_text_hash: u64 = 0,
    display_overflow: std.ArrayListUnmanaged(u8) = .{},
    wrapped_display_overflow: std.ArrayListUnmanaged(u8) = .{},
    ime_segment_overflow: std.ArrayListUnmanaged(u8) = .{},
    /// 多行软换行渲染缓冲区
    wrapped_display_buffer: [(editable_block.MAX_INPUT_BYTES + 256) * 2]u8 = [_]u8{0} ** ((editable_block.MAX_INPUT_BYTES + 256) * 2),
    /// IME display segment 融合缓冲区（Textarea WrapMap 渲染路径）
    ime_segment_buffer: [editable_block.MAX_INPUT_BYTES + 256]u8 = [_]u8{0} ** (editable_block.MAX_INPUT_BYTES + 256),
    /// IME 预编辑缓冲
    ime_preedit: ImeText = .{},
    ime_preedit_len: usize = 0,
    ime_cursor_utf8_offset: usize = 0,
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

    /// Textarea VirtualList 状态引用（仅 multiline 模式）
    vl_state: ?*@import("../virtual_list/mod.zig").VirtualListState = null,
    /// Textarea 的 overlay 容器节点（承载 selection/cursor/preedit_underline）
    textarea_overlay_node: ?*core.Node = null,
    /// 多行选区额外行节点（selection_node 是第一行，这些是第 2~N 行）
    extra_sel_nodes: [15]?*core.Node = [_]?*core.Node{null} ** 15,
    extra_sel_count: u8 = 0,

    /// === Textarea core 模块集成（仅 multiline 模式） ===
    /// 动态文本文档（替代 buffer[256]）
    textarea_doc: ?*TextareaDocument = null,
    /// 通用光标（替代手工 cursor 逻辑）
    textarea_cursor: DocCursor(TextareaDocument) = .{},
    /// 软换行映射（替代 appendWrappedLines/multilineVisualPosForOffset）
    textarea_wrap: ?*TextareaWrapMap = null,
    /// Textarea 专用 undo/redo 栈（动态文本，不受 256 字节限制）
    ta_undo: [UNDO_CAPACITY]TaUndoEntry = [_]TaUndoEntry{.{}} ** UNDO_CAPACITY,
    ta_undo_count: u8 = 0,
    ta_redo: [UNDO_CAPACITY]TaUndoEntry = [_]TaUndoEntry{.{}} ** UNDO_CAPACITY,
    ta_redo_count: u8 = 0,
    /// Textarea 文本上限（字节），0 = 无限制
    textarea_max_bytes: usize = 0,

    /// Theme tokens 引用 (供 on_before_render 等无 ctx 的回调使用)
    tokens: *const theme.ThemeTokens = &theme.dark,

    /// 宿主可覆写的选区配色（null = 走 tokens.color.selection_bg / 继承文字色）。
    /// 场景：列表行内重命名把"行变成输入框"时，选区要满饱和 accent 底 + 反白
    /// 文字（视线先落到名字上），而全局 selection_bg 是浅色淡蓝。仅单行
    /// spans 路径消费；multiline 的独立 selection_node 不吃 fg（glyph 在
    /// 高亮之上，改 fg 无意义）。
    selection_bg_override: ?core.Color = null,
    selection_fg_override: ?core.Color = null,

    /// 值变化回调（文本内容真正改变时触发，不含纯光标移动）
    /// 2026-07-31 并轨：统一 ?core.HandlerRef，用 invokeWithStr 触发
    /// （payload = 当前全文；⚠ slice 只在回调执行期间有效，需留存请 dupe）。
    on_change: ?core.HandlerRef = null,

    // ========== Doc sync ==========

    /// DocCursor → state.cursor_pos / selection_anchor
    pub fn syncCursorFromDoc(self: *TextInputState) void {
        self.cursor_pos = self.textarea_cursor.offset;
        self.selection_anchor = self.textarea_cursor.anchor;
    }

    /// state.cursor_pos / selection_anchor → DocCursor
    pub fn syncDocFromCursor(self: *TextInputState) void {
        self.textarea_cursor.offset = self.cursor_pos;
        self.textarea_cursor.anchor = self.selection_anchor;
        self.textarea_cursor.preferred_col = null;
    }

    /// Textarea 专用: 保存 undo 快照
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
        if (self.ta_undo_count < UNDO_CAPACITY) {
            self.ta_undo[self.ta_undo_count] = entry;
            self.ta_undo_count += 1;
        } else {
            self.ta_undo[0].deinit(allocator);
            var i: usize = 0;
            while (i < UNDO_CAPACITY - 1) : (i += 1) self.ta_undo[i] = self.ta_undo[i + 1];
            self.ta_undo[UNDO_CAPACITY - 1] = entry;
        }
        // 清空 redo
        var j: u8 = 0;
        while (j < self.ta_redo_count) : (j += 1) self.ta_redo[j].deinit(allocator);
        self.ta_redo_count = 0;
        return true;
    }

    /// Restore text and indexes before moving either history entry.
    fn taRestoreHistory(self: *TextInputState, redo_direction: bool) bool {
        const doc = self.textarea_doc orelse return false;
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

    /// 从 DisplayLineInfo 计算安全的 buffer 字节范围 [start, end)
    /// byte_end 可能是 maxInt(usize)，需 clamp 到 line_end
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

    /// 通知 WrapMap 增量更新 + VirtualList 刷新
    fn notifyWrapEdit(self: *TextInputState, start_line: usize, old_line_count: usize, new_line_count: usize) void {
        if (self.textarea_wrap) |wrap| {
            if (self.textarea_doc) |doc| {
                wrap.applyEdit(doc, start_line, old_line_count, new_line_count);
                _ = wrap.rewrapInterpolatedAll(doc);
                _ = wrap.takePendingPatch();
            }
        }
    }

    /// 释放并清空两种编辑路径的 undo/redo 历史。
    ///
    /// 多行快照持有动态文本，不能像单行固定数组一样只把 count 置零。
    /// EditableText 在切换画布对象时用它阻止 Cmd+Z 恢复上一个对象，同时
    /// Scope dispose 也通过此函数释放所有尚存快照。
    pub fn clearUndoHistory(self: *TextInputState) void {
        self.breakUndoCoalescing();
        var i: usize = 0;
        while (i < self.undo_count) : (i += 1) self.undo_stack[i].deinit(self.allocator);
        self.undo_count = 0;
        i = 0;
        while (i < self.redo_count) : (i += 1) self.redo_stack[i].deinit(self.allocator);
        self.redo_count = 0;

        if (self.textarea_doc) |doc| {
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
        if (self.input_overflow) |bytes| self.allocator.free(bytes);
        self.input_overflow = null;
        self.ime_preedit.deinit();
        self.clearImePendingCommit();
        self.clearUndoHistory();
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
        node.style.height = .{ .px = desired };
        node.markLayoutDirty();
    }

    // ========== Blink ==========

    /// 重置光标闪烁计数 (操作后立即显示光标)
    pub fn resetBlink(self: *TextInputState) void {
        self.blink.reset();
        self.last_blink_visible = true;
    }

    pub fn blinkVisible(self: *TextInputState, now: std.time.Instant) bool {
        return self.blink.visible(now);
    }

    pub fn nextBlinkDelayNs(self: *const TextInputState, now: std.time.Instant) u64 {
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
        return self.hasImePreedit() and self.ime_selection_highlight;
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

    pub fn effectiveImeCursorOffset(self: *const TextInputState) usize {
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

        var display_wrap = TextareaWrapMap.init(allocator);
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
        self.ime_cursor_utf8_offset = text_coordinates.clampByteOffset(
            self.preeditText(),
            .{ .value = cursor_utf8_offset },
            .forward,
        ).value;
        // Preparing the retained snapshot can fail too. Publish phase and
        // selection only once the node can own the complete projection.
        _ = try self.syncDisplayTextContentChecked();
        previous.deinit();
        // 保留非空选区，让后续 ime_commit / fallback text_input 仍能按“覆盖选区”提交。
        // 折叠选区（anchor == cursor）可安全清空。
        if (self.selection_anchor) |anchor| {
            if (anchor == self.cursor_pos) self.selection_anchor = null;
        }
        self.ime_phase = .composing;
        self.clearImePendingCommit();
        self.dirty = true;
        self.resetBlink();
        // preedit 变化改了 display text——必须走标脏链，否则零脏帧 fast-path
        // 跳过 inputBeforeRender/relayout，preedit 字形不上屏而光标已前进
        self.markVisualDirty();
    }

    pub fn clearImePreedit(self: *TextInputState) void {
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

    pub fn cancelImeComposition(self: *TextInputState) void {
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

    /// IME replacementRange 应用：把 [start,end) UTF-8 字节区间设为选区，
    /// 让随后的插入/删除落在该区间上（insertText 会先删选区）。
    /// 哨兵或非法区间（起点大于终点 / 终点越界）不动作 —— 退化为现行
    /// "落在光标处"行为。字符边界钳制由 insertText/deleteRange 内部完成。
    pub fn applyImeReplacementRange(self: *TextInputState, replace_start_utf8: u32, replace_end_utf8: u32) bool {
        if (replace_start_utf8 == events.ime_no_replacement or
            replace_end_utf8 == events.ime_no_replacement) return false;
        if (replace_start_utf8 > replace_end_utf8) return false;
        const doc_len: usize = if (self.textarea_doc) |doc| doc.totalLength() else self.buffer_len;
        const start: usize = replace_start_utf8;
        const end: usize = replace_end_utf8;
        // 桥接层区间可能基于过期文本（异步一帧）——越界时拒绝而不是钳，
        // 宁可退化为现行为也不误删。
        if (end > doc_len) return false;
        const text = self.getText();
        const lo = text_coordinates.clampByteOffset(text, .{ .value = start }, .backward).value;
        const hi = if (start == end) lo else text_coordinates.clampByteOffset(text, .{ .value = end }, .forward).value;
        self.cursor_pos = hi;
        self.selection_anchor = if (lo == hi) null else lo;
        if (self.textarea_doc != null) self.syncDocFromCursor();
        return true;
    }

    /// 带 replacementRange 的 IME commit：非哨兵时本次提交替换该文档区间
    /// （日文再変換、以词改词等会修订已提交文本的 IME）。
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

    /// password 模式下用 mask 字符串替代真实 buffer 内容做测量。
    /// CJK IME 输入到 password 后，buffer 持 UTF-8 多字节字符 (双宽显示)，
    /// 但屏幕上画的是 ASCII '*' (单宽)。光标定位必须按 displayed mask 算，
    /// 否则 cursor 视觉位置与 mask 字符不一致 → 偏移 bug。
    /// 由于 mask 是 N 个完全相同的 '*'，shape 一次拿单宽乘 N 就够，避免长输入
    /// 时 O(N) shape 调用反复磨 ShapingCache。
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

    pub fn restingBorderColor(self: *const TextInputState) core.Color {
        return @import("styles.zig").restingBorderColor(self.tokens, self.has_error, self.hasVisualValue());
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

        // WrapMap 路径: 通过 displayLineInfo 快速定位到 buffer 行
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

        // Fallback: 旧的 O(N²) 路径
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

    // ========== 词边界+选区 ==========

    /// 从 pos 向左查找词边界（CJK 感知：每个 CJK 字符视为独立词）
    pub fn findWordBoundaryLeft(self: *const TextInputState, pos: usize) usize {
        if (pos == 0) return 0;
        if (self.textarea_doc) |doc| {
            return DocCursor(TextareaDocument).prevWordBoundary(doc, pos);
        }
        const text = self.getText();
        var p = pos;

        // 先看左边第一个字符的类别
        const first = text_utils.utf8DecodePrev(text, p);
        const first_class = text_utils.classifyCodepoint(first.cp);

        if (first_class == .cjk) {
            // CJK 字符：只跳一个
            return first.start;
        }

        if (first_class == .separator) {
            // 跳过连续的 separator
            p = first.start;
            while (p > 0) {
                const prev = text_utils.utf8DecodePrev(text, p);
                if (text_utils.classifyCodepoint(prev.cp) != .separator) break;
                p = prev.start;
            }
            // 如果到了开头或遇到 CJK，直接返回
            if (p == 0) return 0;
            const next_prev = text_utils.utf8DecodePrev(text, p);
            if (text_utils.classifyCodepoint(next_prev.cp) == .cjk) return next_prev.start;
            // 继续跳 word 字符
            while (p > 0) {
                const prev = text_utils.utf8DecodePrev(text, p);
                if (text_utils.classifyCodepoint(prev.cp) != .word) break;
                p = prev.start;
            }
            return p;
        }

        // word 类别：跳过连续 word 字符
        p = first.start;
        while (p > 0) {
            const prev = text_utils.utf8DecodePrev(text, p);
            if (text_utils.classifyCodepoint(prev.cp) != .word) break;
            p = prev.start;
        }
        return p;
    }

    /// 从 pos 向右查找词边界（CJK 感知：每个 CJK 字符视为独立词）
    pub fn findWordBoundaryRight(self: *const TextInputState, pos: usize) usize {
        if (self.textarea_doc) |doc| {
            return DocCursor(TextareaDocument).nextWordBoundary(doc, pos);
        }
        const text = self.getText();
        if (pos >= text.len) return text.len;
        var p = pos;

        // 先看右边第一个字符的类别
        var cp: u21 = 0;
        const step = text_utils.utf8DecodeNext(text, p, &cp);
        const first_class = text_utils.classifyCodepoint(cp);

        if (first_class == .cjk) {
            // CJK 字符：只跳一个
            return p + step;
        }

        if (first_class == .word) {
            // 跳过连续 word 字符
            p += step;
            while (p < text.len) {
                var next_cp: u21 = 0;
                const next_step = text_utils.utf8DecodeNext(text, p, &next_cp);
                if (text_utils.classifyCodepoint(next_cp) != .word) break;
                p += next_step;
            }
        } else {
            // separator：跳过连续 separator
            p += step;
            while (p < text.len) {
                var next_cp: u21 = 0;
                const next_step = text_utils.utf8DecodeNext(text, p, &next_cp);
                if (text_utils.classifyCodepoint(next_cp) != .separator) break;
                p += next_step;
            }
        }

        // 跳过后续的 separator（使得光标停在下一个词开头）
        while (p < text.len) {
            var next_cp: u21 = 0;
            const next_step = text_utils.utf8DecodeNext(text, p, &next_cp);
            if (text_utils.classifyCodepoint(next_cp) != .separator) break;
            p += next_step;
        }

        return p;
    }

    /// 获取选中文本
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

    /// 选中 pos 所在的词（CJK 感知：每个 CJK 字符独立选中）
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

        // 解码当前位置的 codepoint
        var cp: u21 = 0;
        const step = text_utils.utf8DecodeNext(text, p, &cp);
        const cls = text_utils.classifyCodepoint(cp);

        if (cls == .cjk) {
            // CJK 字符：只选中这一个字符
            self.selection_anchor = p;
            self.cursor_pos = p + step;
        } else if (cls == .separator) {
            // 选中连续的 separator
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
            // word 字符：选中连续的 word 字符
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

    /// 保存撤销快照。
    ///
    /// 无条件压栈，并**断开** undo 合并链——所有走裸 pushUndo 的编辑
    /// （setText / 词删除 / 行删除 / 粘贴等）都是自成一体的一步。
    /// 连续输入请走 `pushUndoCoalescing`。
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
            return self.taPushUndo();
        }
        // Allocate before touching either history stack. An OOM therefore
        // leaves counts, existing snapshots and the current text unchanged.
        const snapshot = self.makeSingleLineSnapshot() orelse return false;
        self.pushSingleLineSnapshot(&self.undo_stack, &self.undo_count, snapshot);
        self.clearSingleLineStack(&self.redo_stack, &self.redo_count);
        return true;
    }

    /// 断开 undo 合并链。任何「非连续输入」的动作（光标移动、点击、
    /// 失焦、粘贴、选区变化、显式 pushUndo 的编辑）都应调用它，
    /// 这样下一次输入必然开一个新的 undo 单元。
    pub fn breakUndoCoalescing(self: *TextInputState) void {
        self.undo_coalesce_kind = .none;
        self.undo_coalesce_at = null;
    }

    /// 判断某个字符是否是"硬边界"——即使紧挨着输入也要断开 undo 单元。
    /// 空白/换行是原生控件公认的分词点：撤销时按"词"回退而不是整段回退。
    fn isUndoBoundaryText(text: []const u8) bool {
        for (text) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return true;
        }
        return false;
    }

    /// 可合并版本的 pushUndo。
    ///
    /// 断开规则（任一命中就压新快照，否则复用上一个快照 = 合并）：
    ///   1. 编辑种类变化（插入 ↔ 退格 ↔ 前向删除）
    ///   2. 光标不连续：本次编辑起点 ≠ 上次编辑终点（点击/方向键跳转过）
    ///   3. 距上次编辑超过 `undo_coalesce_idle_ns`（默认 800ms）静默
    ///   4. 存在选区（替换选中内容是独立的一步）
    ///   5. 内容含空白/换行等边界字符
    fn pushUndoCoalescing(
        self: *TextInputState,
        kind: UndoCoalesceKind,
        text: []const u8,
    ) bool {
        const now: ?std.time.Instant = std.time.Instant.now() catch null;

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

        // 无论是否压栈，链都要续上：合并的编辑更新终点/时间戳，
        // 边界字符本身不作为下一段的可合并起点（kind=none 强制下次再断一次）。
        self.undo_coalesce_kind = if (isUndoBoundaryText(text)) .none else kind;
        self.undo_coalesce_at = now;
        return true;
    }

    /// 在编辑完成后记录新的合并锚点（光标终点）。
    fn noteUndoCoalesceEnd(self: *TextInputState) void {
        self.undo_coalesce_cursor = self.cursor_pos;
    }

    /// 撤销
    pub fn undo(self: *TextInputState) void {
        if (self.ime_replacement != null) {
            self.cancelImeComposition();
            return;
        }
        if (self.textarea_doc != null) {
            if (self.taRestoreHistory(false)) self.breakUndoCoalescing();
            return;
        }
        if (self.undo_count == 0) return;
        // 单行: 原有逻辑
        // Allocate the current state first. If it fails, undo is a no-op and
        // the target snapshot remains owned by the undo stack.
        const current = self.makeSingleLineSnapshot() orelse return;
        self.breakUndoCoalescing();
        self.pushSingleLineSnapshot(&self.redo_stack, &self.redo_count, current);
        self.undo_count -= 1;
        var snapshot = self.undo_stack[self.undo_count];
        self.undo_stack[self.undo_count] = .{};
        self.restoreSingleLineSnapshot(&snapshot);
        self.dirty = true;
        self.resetBlink();
    }

    /// 重做
    pub fn redo(self: *TextInputState) void {
        if (self.ime_replacement != null) {
            self.cancelImeComposition();
            return;
        }
        if (self.textarea_doc != null) {
            if (self.taRestoreHistory(true)) self.breakUndoCoalescing();
            return;
        }
        if (self.redo_count == 0) return;
        // 单行: 原有逻辑
        const current = self.makeSingleLineSnapshot() orelse return;
        self.breakUndoCoalescing();
        self.pushSingleLineSnapshot(&self.undo_stack, &self.undo_count, current);
        self.redo_count -= 1;
        var snapshot = self.redo_stack[self.redo_count];
        self.redo_stack[self.redo_count] = .{};
        self.restoreSingleLineSnapshot(&snapshot);
        self.dirty = true;
        self.resetBlink();
    }

    // ========== Hit-test+Scroll ==========

    /// 全局 x 坐标 → 字符位置 (hit test)
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
            // password 屏幕显示是 mask '*'，buffer 持真实 UTF-8 字符。click x
            // 必须按 mask 测量找到第 N 个 codepoint，再翻译回 buffer byte offset。
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

        const now_instant = std.time.Instant.now() catch null;
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
    /// document and advances correctly, while glyph layout keeps the stale prefix — the visible
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
        var props = text_node.getText() orelse return false;
        const display = try self.buildDisplayTextChecked(self.placeholder_text);
        if (props.owned and std.mem.eql(u8, props.content, display)) return false;
        const allocator = if (text_node.world_ref) |world| world.allocator else self.allocator;
        const snapshot = try allocator.dupe(u8, display);
        props.content = snapshot;
        props.owned = true;
        props.inline_len = 0;
        self.display_text_hash = std.hash.Wyhash.hash(0, display);
        text_node.setText(props);
        return true;
    }

    /// 把 buffer/ime/cursor 变化通知到渲染管线。
    /// cx.render() 零脏帧 fast-path 会跳过 before_render hook，导致 inputBeforeRender
    /// 不跑 → text.content 不更新（symptom: "输入 n 个字符要再点一下才更新 *"）。
    /// 任何修改了 buffer / cursor / scroll_x / ime 的 caller 都要在结束时调一次。
    pub fn markVisualDirty(self: *TextInputState) void {
        self.syncMultilineAutoHeight();
        _ = self.syncDisplayTextContent();
        // sizing（而非 layout）：display text 内容会变（打字/IME preedit 插拔），
        // 软换行文本的 intrinsic 度量有缓存，markLayoutDirty 不会让它失效——
        // wrap 行盒按旧内容画，表现为 preedit/新字不上屏、光标却按新内容前进。
        if (self.text_display_node) |n| n.markSizingDirty();
        if (self.cursor_node) |n| n.markRenderDirty();
        if (self.selection_node) |n| n.markRenderDirty();
        if (self.preedit_underline_node) |n| n.markRenderDirty();
    }

    /// 更新水平滚动偏移，确保光标始终在可见区域内。
    /// 同时把 visual node 标脏 —— updateScrollX 几乎只在 buffer/cursor/ime/focus
    /// 变化后调用，cx.render() 零脏帧 fast-path 会跳过 inputBeforeRender，
    /// 不在这统一标脏的话视觉 mask 不会更新（"输入 n 个字符要点一下才更新 *"）。
    pub fn updateScrollX(self: *TextInputState) void {
        self.markVisualDirty();
        if (self.multiline) {
            self.scroll_x = 0;
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

                // 边界吸附：避免浮点误差导致“已经到边界但状态不为边界”。
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
    }

    // ========== 文本操作 ==========

    /// 获取当前文本
    pub fn getText(self: *const TextInputState) []const u8 {
        if (self.textarea_doc) |doc| return doc.getText();
        return self.singleLineBuffer()[0..self.buffer_len];
    }

    /// Native accessibility selection ingress. Offsets use the same UTF-8
    /// coordinate model as the editor and are snapped backward to grapheme
    /// boundaries before any state is changed.
    pub fn setAccessibilitySelection(self: *TextInputState, start_utf8: u32, end_utf8: u32) bool {
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

    /// 以编程方式整体替换文本内容。
    ///
    /// 此前单行 Input **没有**任何 setText —— props.value 只在 mount 时读
    /// 一次（mod.zig 把它 memcpy 进 buffer），此后应用无法再改字段内容。
    /// 于是"表单先渲染、数据后到"和"提交后清空表单"这两个基本场景都做不到。
    ///
    /// 语义：
    /// - 内容**拷贝**进内部 buffer，调用方不需要保持 `text` 存活。
    /// - 默认按容量截到完整 grapheme；growable 单行输入保留全文。
    /// - 光标移到末尾、清除选区、清空 IME 预编辑状态。
    /// - 记录一次 undo 快照，所以 setText 可被 Cmd+Z 撤销。
    /// - 多行（Textarea）路径委托给 TextareaDocument.setText。
    ///
    /// 返回实际写入的字节数（<  text.len 表示发生了截断）。
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
            self.cancelImeComposition();
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
        self.cancelImeComposition();
        self.dirty = true;
        self.resetBlink();
        return n;
    }

    /// 清空文本（setText("") 的语义糖）。
    pub fn clearText(self: *TextInputState) void {
        _ = self.setText("");
    }

    /// 插入文本
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

    /// 删除范围 [start, end)
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
            // 同步 DocCursor
            self.textarea_cursor.offset = start;
            self.textarea_cursor.anchor = null;
            self.textarea_cursor.preferred_col = null;
            // 通知 WrapMap
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

        // 移动后面的内容
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

    /// 从 pos 向前回退一个 grapheme cluster，返回该 cluster 的起始字节偏移
    ///
    /// 按 UAX #29 extended grapheme cluster 走而非按 codepoint：否则 ZWJ emoji
    /// 序列 / 组合记号 / 旗帜 / 肤色修饰符会被退格拆成残缺序列。
    pub fn utf8PrevCharStart(self: *const TextInputState, pos: usize) usize {
        if (pos == 0) return 0;
        if (self.textarea_doc) |doc| {
            return DocCursor(TextareaDocument).prevCharBoundary(doc, pos);
        }
        return grapheme.prevBoundary(self.singleLineBuffer()[0..self.buffer_len], pos);
    }

    /// 从 pos 向后跳过一个 grapheme cluster，返回下一个 cluster 的起始字节偏移
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

    /// 向后删除一个字符 (Backspace)
    pub fn deleteBackward(self: *TextInputState) void {
        const cursor = @min(self.cursor_pos, self.getText().len);
        const anchor = @min(self.selection_anchor orelse cursor, self.getText().len);
        const start = if (anchor != cursor) anchor else self.utf8PrevCharStart(cursor);
        self.deleteRangeWithUndo(start, cursor, .delete_backward);
    }

    /// 向前删除一个字符 (Delete)
    pub fn deleteForward(self: *TextInputState) void {
        const cursor = @min(self.cursor_pos, self.getText().len);
        const anchor = @min(self.selection_anchor orelse cursor, self.getText().len);
        const end = if (anchor != cursor) anchor else self.utf8NextCharEnd(cursor);
        self.deleteRangeWithUndo(cursor, end, .delete_forward);
    }

    /// 移动光标 (UTF-8 感知，delta 以字符为单位)
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
            // Multiline: 委托 DocCursor
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

    /// 移到行首
    pub fn moveToStart(self: *TextInputState) void {
        self.cursor_pos = 0;
        self.cursor_affinity = .downstream;
        self.selection_anchor = null;
        self.resetBlink();
    }

    /// 移到行尾
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

    /// 全选
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

    // ========== 键盘 ==========

    /// 处理键盘事件
    pub fn handleKeyDown(self: *TextInputState, key: KeyCode, modifiers: events.Modifiers) bool {
        switch (key) {
            .left => {
                if (modifiers.super) {
                    // Cmd+Left: 移到行首
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
                } else if (modifiers.alt) {
                    // Alt+Left: 按词向左移动
                    if (modifiers.shift and self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_pos;
                    } else if (!modifiers.shift) {
                        self.selection_anchor = null;
                    }
                    self.cursor_pos = self.findWordBoundaryLeft(self.cursor_pos);
                    self.resetBlink();
                } else if (!modifiers.shift and self.selection_anchor != null) {
                    // 无修饰键 + 有选区: 光标跳到选区左端，清除选区
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
                    // Cmd+Right: 移到行尾
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
                } else if (modifiers.alt) {
                    // Alt+Right: 按词向右移动
                    if (modifiers.shift and self.selection_anchor == null) {
                        self.selection_anchor = self.cursor_pos;
                    } else if (!modifiers.shift) {
                        self.selection_anchor = null;
                    }
                    self.cursor_pos = self.findWordBoundaryRight(self.cursor_pos);
                    self.resetBlink();
                } else if (!modifiers.shift and self.selection_anchor != null) {
                    // 无修饰键 + 有选区: 光标跳到选区右端，清除选区
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
                if (modifiers.super or modifiers.alt) {
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
                if (modifiers.alt) {
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
                if (modifiers.super) {
                    if (modifiers.shift) {
                        self.redo();
                    } else {
                        self.undo();
                    }
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
                        // Cmd+Up: 移到文档首
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
                        // Cmd+Down: 移到文档尾
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

    /// 垂直移动光标（上/下一行），保持 x 像素位置最近匹配
    fn moveVertical(self: *TextInputState, direction: i2, extend_selection: bool) void {
        if (extend_selection and self.selection_anchor == null) {
            self.selection_anchor = self.cursor_pos;
        } else if (!extend_selection) {
            self.selection_anchor = null;
        }

        // WrapMap 路径: 按 display line 移动
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

        // Fallback: 旧路径
        const text = self.buildDisplayText(null);
        const cur_pos = self.multilineVisualPosForOffset(text, self.displayCursorByteOffset());
        const target_row_i: i32 = @as(i32, @intCast(cur_pos.row)) + @as(i32, direction);
        if (target_row_i < 0) {
            // 已在首行，移到行首
            self.cursor_pos = 0;
        } else {
            const target_row: usize = @intCast(target_row_i);
            const target_x = cur_pos.x;
            // 在 text 中找 target_row 的最近 x 位置
            self.cursor_pos = self.byteOffsetForRowAndX(text, target_row, target_x);
        }
        self.dirty = true;
        self.resetBlink();
    }

    /// 给定目标行号和 x 像素位置，返回最近的字节偏移
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
                break; // 已过目标行
            }
            if (off >= text.len) break;
            off = nextUtf8CharEnd(text, off);
        }

        if (!best_found) {
            // 目标行超出范围，移到末尾
            return @min(self.cursor_pos, self.buffer_len);
            // 如果是 display text（含 IME），取 buffer_len
        }
        // 映射回 buffer 偏移（displayCursorByteOffset 可能含 IME preedit）
        return @min(best_off, self.buffer_len);
    }

    /// 使用 TextareaDocument（如有）或 fallback 查找当前光标所在行首
    fn docFindLineStart(self: *const TextInputState) usize {
        if (self.textarea_doc) |doc| {
            const lc = doc.offsetToLineCol(self.cursor_pos);
            return doc.getLineStart(lc.line);
        }
        return self.findLineStart(self.cursor_pos);
    }

    /// 找到 pos 所在 buffer 行的行首（上一个 \n 之后或 buffer 开头）
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

    /// 找到 pos 所在 buffer 行的行尾（下一个 \n 或 buffer 末尾）
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

// ========== 委托函数 ==========

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

// ========== grapheme cluster 边界（UAX #29）回归测试 ==========
//
// 这些用例锁住的是"用户感知字符"语义：按 codepoint 走的旧实现会全部失败。

const testing = std.testing;

const gc_family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"; // 👨‍👩‍👧‍👦
const gc_flag_cn = "\u{1F1E8}\u{1F1F3}"; // 🇨🇳
const gc_flag_jp = "\u{1F1EF}\u{1F1F5}"; // 🇯🇵
const gc_thumbs_tone = "\u{1F44D}\u{1F3FB}"; // 👍🏻

fn gcMakeState(text: []const u8) TextInputState {
    var s = TextInputState{};
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
    try testing.expectEqual(@as(usize, 1), s.cursor_pos); // 不是 2
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
    var s = TextInputState{};
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
    var s = TextInputState{};
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
    var cx = try core.Cx.init(testing.allocator);
    defer cx.deinit();
    var fonts = try core.FontSystem.init(testing.allocator);
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
    var cx = try core.Cx.init(testing.allocator);
    defer cx.deinit();
    var fonts = try core.FontSystem.init(testing.allocator);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const content = "abc \u{5D0}\u{5D1}\u{5D2}";
    var full_text_buf: [128]u8 = undefined;
    const full_text = try std.fmt.bufPrint(&full_text_buf, "{s}\n{s}", .{ content, content });
    var doc = TextareaDocument.init(testing.allocator);
    defer doc.deinit();
    doc.setText(full_text);
    var wrap = TextareaWrapMap.init(testing.allocator);
    defer wrap.deinit();
    wrap.setEnabled(true, &doc);
    wrap.setWrapWidth(1000, &doc);
    _ = wrap.rewrapInterpolatedAll(&doc);

    const line = try cx.text.visualLine(.{ .text = content, .font_family = "system", .font_size = 16 });
    try testing.expect(line.caret_stops.len > 3);
    var s = TextInputState{
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

test "single-line undo snapshots are dynamic and release their owned text" {
    try testing.expect(@sizeOf(UndoSnapshot) < editable_block.MAX_INPUT_BYTES / 8);
    try testing.expect(@sizeOf(TextInputState) < 32 * 1024);

    var s = TextInputState{ .allocator = testing.allocator };
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
    var s = TextInputState{ .allocator = testing.allocator };
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
    var s = TextInputState{ .allocator = failing.allocator() };
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
    var s = TextInputState{ .allocator = failing.allocator() };
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
    var s = TextInputState{ .allocator = testing.allocator };
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
    var state: TextInputState = .{ .allocator = failing.allocator() };
    defer state.deinit();
    const long = "中" ** 200;
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
    var s: TextInputState = .{ .allocator = failing.allocator() };
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
            var s: TextInputState = .{ .allocator = failing.allocator(), .multiline = multiline, .accept_newline = multiline, .textarea_doc = if (multiline) &doc else null };
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
            const value = if (multiline) "文\n" ** 300 else "文" ** 200;
            const expected = if (multiline) "文\n" ** 300 ++ " tail" else "文" ** 200 ++ " tail";
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
    var s: TextInputState = .{ .allocator = failing.allocator() };
    defer s.deinit();
    _ = s.setText("abcdef");
    s.selection_anchor = 2;
    s.cursor_pos = 4;
    try s.insertTextChecked(s.getText()[1..5]);
    try t.expectEqualStrings("abbcdeef", s.getText());
    const cursor = s.cursor_pos;
    const anchor = s.selection_anchor;
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, s.handleImeCommitReplaceEventChecked("x" ** 600, 0, 3));
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
            const original = "keep\n" ** 80;
            try doc.setTextChecked(original);

            var s: TextInputState = .{ .multiline = true, .textarea_doc = &doc, .allocator = failing.allocator() };
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
                    _ = s.setText("new\n" ** 120);
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
                        _ = try s.setTextChecked("new\n" ** 120);
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

test "reconversion preedit preserves committed text on cancel and restores undo text" {
    const t = std.testing;
    for ([_]bool{ false, true }) |multiline| {
        var doc = TextareaDocument.init(t.allocator);
        defer doc.deinit();
        var s: TextInputState = .{ .multiline = multiline, .textarea_doc = if (multiline) &doc else null, .allocator = t.allocator };
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
            var s: TextInputState = .{ .multiline = multiline, .textarea_doc = if (multiline) &doc else null, .allocator = failing.allocator() };
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
            const value = "新" ** 200;
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
    var s: TextInputState = .{ .allocator = t.allocator };
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
    var wm = TextareaWrapMap.init(t.allocator);
    defer wm.deinit();
    var s: TextInputState = .{ .multiline = true, .textarea_doc = &doc, .textarea_wrap = &wm, .allocator = t.allocator };
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
        var s: TextInputState = .{ .allocator = t.allocator, .multiline = multiline, .textarea_doc = if (multiline) &doc else null };
        defer s.deinit();
        const original = if (multiline) "x" ** 6000 else "xyz";
        _ = try s.setTextChecked(original);
        s.cursor_pos = 1;
        const candidate = "漢" ** 1000 ++ "👩‍💻";
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
            var cx = try core.Cx.init(failing.allocator());
            defer cx.deinit();
            const row = try core.box(cx, .{}, .{});
            cx.root = row;
            row.setText(.{ .content = "" });
            var doc = TextareaDocument.init(failing.allocator());
            defer doc.deinit();
            var s: TextInputState = .{ .allocator = failing.allocator(), .multiline = multiline, .textarea_doc = if (multiline) &doc else null, .cx_ref = cx, .text_display_node = row };
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
            const candidate = "漢" ** 1000;
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
    var s: TextInputState = .{ .allocator = t.allocator, .multiline = true, .soft_wrap = true, .input_inner_w = 1, .char_width = 8 };
    defer s.deinit();
    const candidate = "👩‍💻" ** 500;
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
    var wm = Map.init(t.allocator);
    defer wm.deinit();
    var s: TextInputState = .{ .allocator = t.allocator, .multiline = true, .soft_wrap = true, .textarea_doc = &doc, .textarea_wrap = &wm, .input_inner_w = 120, .char_width = 12, .font_size = 20 };
    defer s.deinit();
    _ = try s.setTextChecked("x" ** 6000);
    try s.setImePreeditChecked("a" ** 1000, 1000);
    try t.expectEqual(@as(usize, 7000), s.displayCursorByteOffset());
    s.refreshMultilineImeGeometry();
    try t.expect(s.ime_visual_valid);
    try t.expectEqual(@as(u32, 700), s.ime_visual_total_lines);
    try t.expectEqual(@as(u32, 699), s.ime_visual_display_line);
    try t.expectApproxEqAbs(@as(f32, 120), s.ime_visual_cursor_x, 0.01);
    try t.expectEqualStrings("x" ** 6000, doc.getText());
}

test "growable Input preserves long text through insertion undo redo and aliases" {
    const t = std.testing;
    var state: TextInputState = .{ .allocator = t.allocator, .growable = true };
    defer state.deinit();
    const long = "界" ** 1000;
    try t.expectEqual(long.len, try state.setTextChecked(long));
    try t.expectEqualStrings(long, state.getText());
    state.cursor_pos = 3;
    state.selection_anchor = 6;
    try state.insertTextChecked("abc");
    try t.expectEqualStrings("界abc" ++ "界" ** 998, state.getText());
    state.undo();
    try t.expectEqualStrings(long, state.getText());
    state.redo();
    try t.expectEqualStrings("界abc" ++ "界" ** 998, state.getText());
    _ = try state.setTextChecked(state.getText()[3..]);
    try t.expectEqualStrings("abc" ++ "界" ** 998, state.getText());
    state.undo();
    try t.expectEqualStrings("界abc" ++ "界" ** 998, state.getText());
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
            var state: TextInputState = .{ .allocator = failing.allocator(), .growable = true };
            defer state.deinit();
            _ = try state.setTextChecked("old");
            state.clearUndoHistory();
            const old_ptr = state.getText().ptr;
            failing.fail_index = failing.alloc_index + fail_at;
            failing.resize_fail_index = failing.resize_index;
            const long = "界" ** 1000;
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
