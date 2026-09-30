/// EditableBlock Core Helpers
///
/// Shared behavior/metering helpers for editable components (Input/Textarea/CodeEditor).
const std = @import("std");
const core = @import("../../core.zig");
const theme = core.theme;
const Node = core.Node;

pub const Behavior = struct {
    multiline: bool = false,
    accept_newline: bool = false,
    soft_wrap: bool = false,
};

pub const InputType = enum {
    text,
    number,
    email,
    password,
    tel,
};

/// 单行 Input 的定长文本缓冲上限（字节）。
///
/// canonical buffer 仍内联在 TextInputState 中，但 undo/redo 快照已改为
/// 按当时文本实际长度分配，因此提高输入上限不再把每个实例的
/// 64×2 个历史槽一起放大。多行 Textarea/EditableText 仍走独立的
/// TextareaDocument + TaUndoEntry 路径。
pub const MAX_INPUT_BYTES: usize = 2048;

pub const UndoSnapshot = struct {
    /// Owned by the TextInputState allocator. null represents an empty value
    /// and also makes an unused slot allocation-free.
    text: ?[]u8 = null,
    cursor_pos: usize = 0,
    selection_anchor: ?usize = null,

    pub fn deinit(self: *UndoSnapshot, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        self.* = .{};
    }
};

pub const ImeComposePhase = enum {
    idle,
    composing,
    commit_pending_end,
};

pub const Metrics = struct {
    char_width: f32 = 7.8,
    font_size: f32 = 13.0,
    font_weight: u16 = 400,
    padding_h: f32 = 8.0,
    padding_v: f32 = 0.0,
    line_height: f32 = 16.0,
};

/// Apply behavior/metrics to an editable state object.
/// `state` is expected to expose the fields used below.
pub fn applyConfig(
    state: anytype,
    behavior: Behavior,
    metrics: Metrics,
    explicit_inner_w: ?f32,
    cx: *core.Cx,
    tokens: *const theme.ThemeTokens,
) void {
    state.multiline = behavior.multiline;
    state.accept_newline = behavior.accept_newline;
    state.soft_wrap = behavior.soft_wrap;

    state.char_width = metrics.char_width;
    state.font_size = metrics.font_size;
    state.font_weight = metrics.font_weight;
    state.padding_h = metrics.padding_h;
    state.padding_v = metrics.padding_v;
    state.line_height = metrics.line_height;
    if (explicit_inner_w) |w| {
        state.input_inner_w = @max(@as(f32, 0), w);
    } else if (state.input_inner_w <= 0) {
        state.input_inner_w = 200;
    }

    state.cx_ref = cx;
    state.tokens = tokens;
}

/// Sync inner text width from the laid out container width.
/// Returns true when width changed enough to require rerender.
pub fn syncInnerWidthFromNode(state: anytype, node: *const core.Node) bool {
    const horizontal_padding = state.padding_h * 2;
    // 全局 hook 读 rect（epoch==0 时 fallback 到 node.rect）。
    const r = node.rectFromWorldOrFallback();
    const next_inner_w = @max(@as(f32, 0), r.w - horizontal_padding);
    const changed = @abs(next_inner_w - state.input_inner_w) > 0.25;
    state.input_inner_w = next_inner_w;
    return changed;
}

pub const RenderCoords = struct {
    layout_x: f32,
    layout_y: f32,
    global_x: f32,
    global_y: f32,
    translate_dx: f32,
    translate_dy: f32,
    inner_layout_x: f32,
    inner_layout_y: f32,
};

/// Compute both layout-space and global-space coordinates for an editable container.
/// Rendering shadow nodes should use layout-space values, while IME cursor rect and
/// hit-testing should use global-space values.
pub fn computeRenderCoords(node: *const Node, padding_h: f32, padding_v: f32) RenderCoords {
    const global = node.globalRect();
    var tx: f32 = 0;
    var ty: f32 = 0;
    var current: ?*const Node = node;
    while (current) |n| {
        tx += n.style.translate_x + n.frame_state.frame_local.runtime.sticky.x;
        ty += n.style.translate_y + n.frame_state.frame_local.runtime.sticky.y;
        current = n.parent;
    }

    // 全局 hook 读 rect（epoch==0 时 fallback 到 node.rect）。
    const r = node.rectFromWorldOrFallback();
    const layout_x = r.x;
    const layout_y = r.y;
    return .{
        .layout_x = layout_x,
        .layout_y = layout_y,
        .global_x = global.x,
        .global_y = global.y,
        .translate_dx = tx,
        .translate_dy = ty,
        .inner_layout_x = layout_x + padding_h,
        .inner_layout_y = layout_y + padding_v,
    };
}

fn isAsciiControl(b: u8) bool {
    return b < 0x20 or b == 0x7F;
}

fn skipEscapeSequence(input: []const u8, idx: usize) usize {
    if (idx >= input.len or input[idx] != 0x1B) return 0;
    if (idx + 1 >= input.len) return 1;
    const next = input[idx + 1];
    if (next == '[') {
        var j = idx + 2;
        while (j < input.len) : (j += 1) {
            const b = input[j];
            if (b >= 0x40 and b <= 0x7E) {
                j += 1;
                break;
            }
        }
        return j - idx;
    }
    if (next == 'O') {
        var j = idx + 2;
        if (j < input.len) j += 1;
        return j - idx;
    }
    return 1;
}

fn isZeroWidthSeq(text: []const u8, idx: usize) usize {
    if (idx + 2 < text.len and text[idx] == 0xE2 and text[idx + 1] == 0x80) {
        const last = text[idx + 2];
        if (last == 0x8B or last == 0x8C or last == 0x8D) {
            return 3; // U+200B/C/D
        }
    }
    if (idx + 2 < text.len and text[idx] == 0xEF and text[idx + 1] == 0xBB and text[idx + 2] == 0xBF) {
        return 3; // U+FEFF
    }
    return 0;
}

fn isAsciiDigit(b: u8) bool {
    return b >= '0' and b <= '9';
}

fn isAsciiAlpha(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

fn isAllowedForType(t: InputType, b: u8) bool {
    return switch (t) {
        .text, .password => true,
        .number => isAsciiDigit(b) or b == '.' or b == '+' or b == '-' or b == 'e' or b == 'E',
        .email => isAsciiDigit(b) or isAsciiAlpha(b) or b == '@' or b == '.' or b == '_' or b == '+' or b == '-' or b == '!' or b == '#' or b == '$' or b == '%' or b == '&' or b == '\'' or b == '*' or b == '/' or b == '=' or b == '?' or b == '^' or b == '`' or b == '{' or b == '|' or b == '}' or b == '~',
        .tel => isAsciiDigit(b) or b == '+' or b == '-' or b == '(' or b == ')',
    };
}

pub fn isImeSelectionSpace(text: []const u8) bool {
    if (text.len == 1 and text[0] == ' ') return true;
    // U+3000 IDEOGRAPHIC SPACE (UTF-8: E3 80 80)
    if (text.len == 3 and text[0] == 0xE3 and text[1] == 0x80 and text[2] == 0x80) return true;
    return false;
}

/// 统一 IME cursor 偏移语义：
/// - 常规: 取系统上报 cursor_utf8_offset（并 clamp 到 preedit 长度）
/// - 选词高亮阶段: 某些 IME 会上报 0，此时应把光标视为 preedit 末尾
pub fn effectiveImeCursorOffset(preedit_len: usize, cursor_utf8_offset: usize, selection_highlight: bool) usize {
    const raw = @min(cursor_utf8_offset, preedit_len);
    if (selection_highlight and raw == 0 and preedit_len > 0) return preedit_len;
    return raw;
}

/// 将 preedit 文本融合到 base_text 的 insert_offset 位置，写入 out 缓冲区。
/// 返回融合后的切片（可能因 out 容量不足而截断）。
pub fn composePreeditIntoBuffer(base_text: []const u8, insert_offset: usize, preedit: []const u8, out: []u8) []const u8 {
    const split = @min(insert_offset, base_text.len);
    const prefix = base_text[0..split];
    const suffix = base_text[split..];

    var out_len: usize = 0;

    const prefix_copy = @min(prefix.len, out.len - out_len);
    if (prefix_copy > 0) {
        @memcpy(out[out_len .. out_len + prefix_copy], prefix[0..prefix_copy]);
        out_len += prefix_copy;
    }

    const preedit_copy = @min(preedit.len, out.len - out_len);
    if (preedit_copy > 0) {
        @memcpy(out[out_len .. out_len + preedit_copy], preedit[0..preedit_copy]);
        out_len += preedit_copy;
    }

    const suffix_copy = @min(suffix.len, out.len - out_len);
    if (suffix_copy > 0) {
        @memcpy(out[out_len .. out_len + suffix_copy], suffix[0..suffix_copy]);
        out_len += suffix_copy;
    }

    return out[0..out_len];
}

/// Normalize and filter incoming text based on editable behavior + input type.
/// `state` is expected to expose: `accept_newline` and `input_type`.
pub fn sanitizeInputText(state: anytype, input: []const u8, out: []u8) []const u8 {
    var i: usize = 0;
    var out_len: usize = 0;

    while (i < input.len and out_len < out.len) {
        const b = input[i];

        if (b == 0x1B) {
            const skip = skipEscapeSequence(input, i);
            i += if (skip > 0) skip else 1;
            continue;
        }

        if (b == '\r') {
            if (state.accept_newline) {
                // normalize CRLF to LF
                if (i + 1 < input.len and input[i + 1] == '\n') {
                    i += 2;
                } else {
                    i += 1;
                }
                if (out_len < out.len) {
                    out[out_len] = '\n';
                    out_len += 1;
                }
                continue;
            }
            i += 1;
            continue;
        }

        if (b == '\n') {
            if (state.accept_newline) {
                out[out_len] = '\n';
                out_len += 1;
            }
            i += 1;
            continue;
        }

        if (isAsciiControl(b)) {
            i += 1;
            continue;
        }

        if (state.input_type == .text or state.input_type == .password) {
            if (b >= 0x80) {
                const skip = isZeroWidthSeq(input, i);
                if (skip > 0) {
                    i += skip;
                    continue;
                }
            }
            out[out_len] = b;
            out_len += 1;
            i += 1;
            continue;
        }

        if (b < 0x80 and isAllowedForType(state.input_type, b)) {
            out[out_len] = b;
            out_len += 1;
        }
        i += 1;
    }

    return out[0..out_len];
}

test "computeRenderCoords separates layout and global coordinates" {
    var ctx = try core.Cx.init(std.testing.allocator);
    defer ctx.deinit();

    const root = try core.box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;
    root.setLayoutRect(.{ .x = 0, .y = 0, .w = 200, .h = 120 });
    root.style.translate_x = 10;
    root.style.translate_y = 20;

    const child = try core.box(ctx, .{ .width = .{ .px = 80 }, .height = .{ .px = 28 } }, .{});
    child.setLayoutRect(.{ .x = 30, .y = 40, .w = 80, .h = 28 });
    child.style.translate_x = 5;
    child.style.translate_y = 7;
    try root.appendChild(std.testing.allocator, child);

    const coords = computeRenderCoords(child, 8, 4);
    try std.testing.expectEqual(@as(f32, 30), coords.layout_x);
    try std.testing.expectEqual(@as(f32, 40), coords.layout_y);
    try std.testing.expectEqual(@as(f32, 45), coords.global_x);
    try std.testing.expectEqual(@as(f32, 67), coords.global_y);
    try std.testing.expectEqual(@as(f32, 15), coords.translate_dx);
    try std.testing.expectEqual(@as(f32, 27), coords.translate_dy);
    try std.testing.expectEqual(@as(f32, 38), coords.inner_layout_x);
    try std.testing.expectEqual(@as(f32, 44), coords.inner_layout_y);
}

test "effectiveImeCursorOffset falls back to preedit end in selection highlight mode" {
    try std.testing.expectEqual(@as(usize, 5), effectiveImeCursorOffset(5, 0, true));
    try std.testing.expectEqual(@as(usize, 2), effectiveImeCursorOffset(5, 2, true));
    try std.testing.expectEqual(@as(usize, 0), effectiveImeCursorOffset(0, 0, true));
}

test "composePreeditIntoBuffer inserts preedit between prefix and suffix" {
    var out: [32]u8 = undefined;
    const ni = "\xe4\xbd\xa0";
    const composed = composePreeditIntoBuffer("abCD", 2, ni, out[0..]);
    try std.testing.expect(std.mem.eql(u8, composed, "ab" ++ ni ++ "CD"));
}
