/// Input Render — beforeRender 钩子 + textarea VirtualList 集成
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

fn setA11ySelection(context: *anyopaque, start_utf8: u32, end_utf8: u32) bool {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    return state.setAccessibilitySelection(start_utf8, end_utf8);
}

fn setA11yValue(context: *anyopaque, value: []const u8) bool {
    const state: *TextInputState = @ptrCast(@alignCast(context));
    // Reject oversized native writes before mutation. TextInputState.setText
    // intentionally truncates programmatic writes, but an AX setter must not
    // report failure after silently changing the control to a prefix.
    if (!state.growable and value.len > state.buffer.len) return false;
    if ((state.setTextChecked(value) catch return false) != value.len) return false;
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
        .set_selection = setA11ySelection,
        .frame_for_range = a11yTextFrame,
        .range_at_point = a11yRangeAtPoint,
        .secure = state.input_type == .password,
    };
}

/// 输入框渲染前钩子：光标闪烁、选区高亮、拖拽处理
pub fn inputBeforeRender(node: *Node) void {
    const state: *TextInputState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
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
                .visible_start = 0,
                .visible_end = @intCast(text.len),
                .set_selection = setA11ySelection,
                .set_value = setA11yValue,
                .frame_for_range = a11yTextFrame,
                .range_at_point = a11yRangeAtPoint,
            };
        }
    }
    const coords = editable_block.computeRenderCoords(node, state.padding_h, state.padding_v);

    // border 动画已由 Transition 系统自动处理（enableImplicitAnimation + setBorderColor）

    const now = std.time.Instant.now() catch null;
    const blink_visible = if (state.focused and now != null) state.blinkVisible(now.?) else state.focused;
    if (state.focused and now != null) {
        if (state.cx_ref) |cx| {
            cx.scheduleRedrawAfterNs(state.nextBlinkDelayNs(now.?));
        }
        if (blink_visible != state.last_blink_visible) {
            node.markRenderDirty();
        }
    }
    state.last_blink_visible = blink_visible;

    // 缓存容器全局 x 坐标
    state.container_x = coords.global_x;
    state.container_y = coords.global_y;
    const inner_width_changed = state.updateInnerWidthFromContainer(node);
    if (inner_width_changed) {
        state.updateScrollX();
        // WrapMap: 宽度变化时更新 wrap_width
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

    // 若已聚焦且鼠标按下，确保进入拖拽状态（避免跨帧丢失）
    if (state.cx_ref) |cx| {
        if (state.focused and cx.pressed_node != null and !state.is_dragging and !state.suspend_drag_until_mouse_up) {
            state.is_dragging = true;
            if (state.selection_anchor == null) {
                state.selection_anchor = state.cursor_pos;
            }
        }
    }

    // 拖拽：cursor 更新走 inputEventHandler.mouse_move 路径。
    // 不能在 before_render 用 cx.mouse_x/y 重算 cursor —— 那个值只有 mouse_move
    // 才更新，mouse_down 后到首个 mouse_move 之间是 stale 坐标，e2e 或程序合成
    // click 场景下还停在 (0,0) → cursor 错误 jump 到 0。
    if (state.is_dragging) {
        if (state.cx_ref) |cx| {
            if (cx.pressed_node == null) state.is_dragging = false;
        }
    }

    // 更新文本显示内容（保留模式下 buffer 变化后同步到 text node）
    if (state.text_display_node) |text_nd| {
        // 单行 Input: 直接更新 text content（只在内容实际变化时才标脏）
        if (text_nd.getText()) |old_text| {
            const content_changed = state.syncDisplayTextContent();
            var text = text_nd.getText() orelse old_text;
            const has_content = state.hasVisualValue();
            const new_color = if (state.has_error)
                state.tokens.color.danger
            else if (has_content)
                state.tokens.color.fg_primary
            else
                (state.placeholder_color orelse state.tokens.color.fg_secondary);
            const new_line_height = if (state.font_size > 0 and state.line_height > 0)
                state.line_height / state.font_size
            else
                @as(f32, 1.4);
            const new_padding_left = state.padding_h - state.scroll_x;
            const changed = content_changed or
                !Color.eql(text.color, new_color) or
                @abs(text.line_height - new_line_height) > 0.001 or
                @abs(text_nd.style.padding.left - new_padding_left) > 0.001;
            // syncDisplayTextContent publishes an owned snapshot; retain all
            // of its ownership fields when updating visual properties.
            text.color = new_color;
            text.line_height = new_line_height;
            text_nd.setText(text);
            text_nd.style.padding.left = new_padding_left;
            if (changed) {
                // 内容变化必须标 sizing（不只 layout）：多行 .word wrap 的
                // intrinsic 度量有缓存，markLayoutDirty 不会让它失效——
                // wrap 行盒永远按旧内容画。表现为 IME preedit / 新输入的字
                // 不出现，光标/下划线却按新内容前进（视觉错位）。
                if (content_changed) text_nd.markSizingDirty();
                text_nd.markRenderDirty();
            }
        }
    } else if (state.multiline and state.dirty) {
        // 多行 Textarea: dirty 时通过 VirtualList 更新文本行
        state.dirty = false;
        if (state.vl_state) |vl_state| {
            const new_line_count = countTextareaLines(state);
            if (new_line_count != vl_state.props.item_count) {
                virtual_list.updateItemCount(vl_state, new_line_count);
            } else {
                virtual_list.refreshRange(vl_state, vl_state.prev_start, vl_state.prev_end);
            }
            // 滚动到光标所在 display line
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

    // 单行 Input: overflow fade 边缘由真实 scroll_x 驱动，避免“已到最右仍显示右侧渐变”。
    if (!state.multiline) {
        if (state.cx_ref) |cx| {
            const ext = node.style.ensureExtPanic(cx.allocator);
            if (ext.overflow_fade) |*fade| {
                const content_w = state.displayedTextAdvance();
                const max_scroll = @max(@as(f32, 0), content_w - state.input_inner_w);
                const eps: f32 = 0.75;
                const left_on = state.scroll_x > eps;
                const right_on = state.scroll_x < (max_scroll - eps);
                if (fade.edges.left != left_on or fade.edges.right != right_on) {
                    fade.edges.left = left_on;
                    fade.edges.right = right_on;
                    node.markRenderDirty();
                }
            }
        }
    }

    // 容器内部区域（相对于 editable_surface 自身，子节点 rect 使用此坐标）
    const container_inner_x = state.padding_h;
    const container_inner_y = state.padding_v;
    // 光标高度跟随行高（canvas 缩放会把 font_size/line_height 推到很大,
    // 写死 16 会在放大后显得极小）。14px 字号下 line_height=18 → 16,
    // 与原值一致,常规 Input 不回归。
    var cursor_h: f32 = if (state.line_height > 0) @max(12.0, state.line_height - 2.0) else 16;
    var cursor_y = (node.rectFromWorldOrFallback().h - cursor_h) / 2;

    // 更新光标节点
    if (state.cursor_node) |cursor| {
        if (state.focused) {
            var cursor_x_px: f32 = state.visualCursorAdvance() - state.scroll_x;
            if (state.multiline) {
                if (state.textarea_wrap) |wrap| {
                    if (state.textarea_doc) |doc| {
                        // WrapMap 路径
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
            cursor.setLayoutRect(.{
                .x = cursor_x,
                .y = cursor_y_px,
                .w = 1,
                .h = cursor_h,
            });
            cursor.setBackgroundRaw(if (blink_visible) state.tokens.color.fg_primary else Color.TRANSPARENT);
            cursor.markRenderDirty();

            // IME cursor rect 需要全局坐标
            if (state.cx_ref) |cx| {
                const global = node.globalRect();
                const world_transform = node.frame_state.frame_local.spatial.world.matrix;
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
            cursor.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
            cursor.setBackgroundRaw(Color.TRANSPARENT);
            cursor.markRenderDirty();
        }
    }

    // ── Single-line: 选区 / IME 高亮 / IME 下划线 全部走 text_display_node.text.spans ──
    // glyph 永远在 span 背景之上；offset 用字节坐标，由 text 渲染管线测量，
    // 根除"selection 遮文字"和"位置对不齐 scroll_x"两类 bug。
    if (!state.multiline and state.text_display_node != null) {
        rebuildSingleLineSpans(state);
    }

    // ── Multi-line: 仍走独立 selection_node / preedit_underline_node 的旧路径 ──
    if (state.multiline and state.selection_node != null) {
        updateMultilineSelectionNodes(state, node, container_inner_x, container_inner_y, cursor_y, cursor_h);
        updateMultilinePreeditUnderline(state, container_inner_x, container_inner_y, cursor_y, cursor_h);
    }

    // 持续请求重绘 (光标闪烁)
    if (inner_width_changed) {
        node.markRenderDirty();
    }
}

/// 根据 selection / IME preedit 状态重建 text_display_node 的 spans，
/// 并把 slice 重新绑到 text.spans。
fn rebuildSingleLineSpans(state: *TextInputState) void {
    const text_nd = state.text_display_node orelse return;
    var text_prop = text_nd.getText() orelse return;

    var len: u8 = 0;
    const display_text = text_prop.content;
    const is_password = state.input_type == .password;
    // password 模式下 display_text 是 mask（N 个 ASCII '*'），
    // span 的 start/end 必须按 mask 坐标 = grapheme 索引；
    // 普通模式下 display_text 与 buffer 等价，按字节偏移即可。
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
        // preedit 在 displayed text 中位于 [cursor_off, cursor_off + preedit_units)
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
            // 2) IME marked highlight（整段 preedit 蓝色半透明）
            if (state.shouldShowImeSelectionHighlight()) {
                state.text_spans_buf[len] = .{
                    .start = preedit_start,
                    .end = preedit_end,
                    .bg_color = styles.imeHighlightColor(state.tokens),
                };
                len += 1;
            }
        }
    } else if (if (state.ime_replacement == null) state.selection_anchor else null) |anchor| {
        // 普通文本选区
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
                    .bg_color = state.selection_bg_override orelse state.tokens.color.selection_bg,
                };
                len += 1;
            }
        }
    }

    const new_slice = state.text_spans_buf[0..len];
    // 仅当 slice 长度或内容变化时才标脏（避免每帧无谓重绘）
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

/// Multi-line 选区节点更新（旧逻辑，仅 multiline 用）
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
                // 多行选区
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
                const sel_bg = state.tokens.color.selection_bg;
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
                    // 跨行：高亮只罩每行**文本实际宽度**（去掉行尾空白），
                    // 不铺到 wrap 宽度——铺满会把行右侧的空白也"选中"。
                    // 首行（start_x → 该行文本尾）
                    const first_row_w = displayRowTextWidth(state, start_row) orelse state.input_inner_w;
                    sel.setLayoutRect(.{
                        .x = @round(container_inner_x + start_x),
                        .y = @round(container_inner_y + @as(f32, @floatFromInt(start_row)) * lh),
                        .w = @round(@max(first_row_w - start_x, 4)),
                        .h = lh,
                    });
                    sel.setBackgroundRaw(sel_bg);

                    // 中间行 + 末行
                    const total_rows = end_row - start_row + 1;
                    const extra_needed = total_rows - 1; // 首行已由 sel 处理
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
                    // 隐藏多余节点
                    while (ri < state.extra_sel_count) : (ri += 1) {
                        if (state.extra_sel_nodes[ri]) |esel| {
                            esel.setLayoutRect(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
                            esel.setBackgroundRaw(Color.TRANSPARENT);
                            esel.markRenderDirty();
                        }
                    }
                }
            } else {
                // 单行选区：原有逻辑
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
                    sel.setBackgroundRaw(state.tokens.color.selection_bg);
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

/// 某显示行的文本实际宽度（去掉行尾空白）。跨行选区高亮用——
/// 只罩文本，不铺到 wrap 宽度。无 WrapMap 路径返回 null（caller 回退行宽）。
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

/// Multi-line IME preedit 下划线（旧逻辑，仅 multiline 用）
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

// ========== WrapMap display segment 辅助 ==========

const TextareaDocument = state_mod.TextareaDocument;
const DisplayLineInfo = state_mod.DisplayLineInfo;
const SegRange = struct { start: usize, end: usize };

/// 从 displayLineInfo 计算 buffer 字节范围 [seg_start, seg_end)
/// byte_end 可能是 maxInt(usize)，需要 clamp 到 line_end
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

// ========== 多行选区辅助 ==========

/// 确保 overlay 中有足够的额外选区节点
fn ensureExtraSelNodes(state: *TextInputState, needed: u8, _: *Node) void {
    const overlay = state.textarea_overlay_node orelse return;
    const cx = state.cx_ref orelse return;

    while (state.extra_sel_count < needed) {
        const esel = box(cx, .{
            .width = .{ .px = 0 },
            .height = .{ .px = 0 },
        }, .{}) catch return;
        overlay.appendChild(cx.allocator, esel) catch return;
        esel.parent = overlay;
        state.extra_sel_nodes[state.extra_sel_count] = esel;
        state.extra_sel_count += 1;
    }
}

/// 隐藏所有额外选区节点
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

// ========== Textarea VirtualList 集成 ==========

/// 计算当前 textarea 文本的行数（含软换行）
pub fn countTextareaLines(state: *TextInputState) usize {
    // WrapMap 路径
    if (state.textarea_wrap) |wrap| {
        const dl = wrap.displayLineCount();
        return if (dl > 0) dl else 1;
    }

    // Fallback: 旧路径
    const wrapped = state.buildWrappedDisplayTextChecked(state.placeholder_text) catch {
        state.dirty = true;
        if (state.cx_ref) |cx| {
            if (state.input_container_node) |node| @import("row_text.zig").retry(cx, node);
        }
        return if (state.vl_state) |vl| vl.props.item_count else 1;
    };

    var line_count: usize = 1;
    for (wrapped) |c| {
        if (c == '\n') line_count += 1;
    }
    return line_count;
}

/// VirtualList renderItem 回调：根据行号渲染对应文本行
pub fn textareaRenderItem(item_node: *Node, index: usize, cx: *Cx, user_context: ?*anyopaque) void {
    const state: *TextInputState = @ptrCast(@alignCast(user_context orelse return));
    const has_content = state.hasVisualValue();
    const text_color = if (has_content) state.tokens.color.fg_primary else state.tokens.color.fg_secondary;

    // WrapMap + TextareaDocument 路径
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

    // Fallback: 旧路径
    const wrapped = state.buildWrappedDisplayTextChecked(state.placeholder_text) catch {
        state.dirty = true;
        @import("row_text.zig").retry(cx, state.input_container_node orelse item_node);
        return;
    };

    // 找到第 index 行的内容
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
    var state: TextInputState = .{ .multiline = true, .textarea_doc = &doc, .textarea_wrap = &wm, .allocator = t.allocator, .input_inner_w = 64 };
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
    var state: TextInputState = .{ .allocator = failing.allocator() };
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
    var cx = try Cx.init(t.allocator);
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
    var wm = Map.init(t.allocator);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var s: TextInputState = .{ .textarea_doc = &doc, .textarea_wrap = &wm, .multiline = true, .allocator = t.allocator };
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
    const row = try core.box(cx, .{}, .{});
    cx.root = row;
    var doc = Doc.init(t.allocator);
    defer doc.deinit();
    try doc.setTextChecked("abc");
    var wm = Map.init(t.allocator);
    defer wm.deinit();
    wm.setEnabled(false, &doc);
    var s: TextInputState = .{ .textarea_doc = &doc, .textarea_wrap = &wm, .multiline = true, .allocator = t.allocator };
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
    var cx = try Cx.init(t.allocator);
    defer cx.deinit();
    const root = try core.box(cx, .{}, .{});
    cx.root = root;
    const first = try core.box(cx, .{}, .{});
    try root.appendChild(t.allocator, first);
    const second = try core.box(cx, .{}, .{});
    try root.appendChild(t.allocator, second);
    var s: TextInputState = .{ .multiline = true, .soft_wrap = true, .input_inner_w = 24, .char_width = 8, .allocator = t.allocator };
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
    var cx = try Cx.init(t.allocator);
    defer cx.deinit();
    const row = try core.box(cx, .{}, .{});
    cx.root = row;
    row.setText(.{ .content = "" });
    var s: TextInputState = .{ .allocator = t.allocator, .input_type = .password, .text_display_node = row, .cx_ref = cx };
    defer s.deinit();
    _ = try s.setTextChecked("👩‍💻x");
    s.cursor_pos = "👩‍💻".len;
    const candidate = "漢" ** 1000 ++ "👩‍💻";
    try s.setImePreeditChecked(candidate, candidate.len);
    rebuildSingleLineSpans(&s);
    try t.expectEqualStrings("*" ** 1003, row.getText().?.content);
    try t.expect(row.getText().?.owned);
    try t.expectEqual(@as(u32, 1), row.getText().?.spans[0].start);
    try t.expectEqual(@as(u32, 1002), row.getText().?.spans[0].end);
    try t.expectEqual(@as(usize, 1002), s.visualCursorPos());
    s.cancelImeComposition();
    rebuildSingleLineSpans(&s);
    try t.expectEqualStrings("**", row.getText().?.content);
    try t.expectEqual(@as(usize, 0), row.getText().?.spans.len);
}
