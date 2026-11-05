const ImeText = @import("ime_text.zig").ImeText;
/// Input Events, event dispatch + fireOnChange
const core_ui = @import("../../core.zig");
const events = @import("../../events.zig");
const Event = events.Event;
const EventResult = events.EventResult;
const state_mod = @import("state.zig");
const TextInputState = state_mod.TextInputState;
const editable_block = @import("../editable_block/mod.zig");

/// Trigger on_change callback on text change
pub inline fn fireOnChange(state: *TextInputState) void {
    if (state.on_change) |h| h.invokeWithStr(state.getText());
}

/// Single-line Input field (ControlShell root): focus / blur update editing state here, as
/// events, never by replacing the node's on_focus / on_blur (the shell's :focus hooks live there).
/// Blur clears even while disabled (disable revokes focus), then runs as an edit transaction.
pub fn inputFieldEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *TextInputState = @ptrCast(@alignCast(context orelse return .ignored));
    switch (event) {
        .focus => state.focused = true,
        .blur => {
            state.focused = false;
            state.cancelImeComposition();
            state.selection_anchor = null;
            state.syncDocFromCursor();
            state.is_dragging = false;
            state.drag_pointer = null;
            state.suspend_drag_until_mouse_up = false;
            state.consecutive_mouse_downs = 0;
            state.last_mouse_down_instant = null;
        },
        else => {},
    }
    return inputEventHandler(event, context);
}

/// Input event handler
///
/// Each event is one user edit transaction (TextInputState.beginUserEdit): at exit, value binding
/// (fireOnChange -> binding.onBufferChanged) detects whether the parent rewrote/rejected the edit
/// and corrects the buffer in place using the transaction-entry checkpoint.
pub fn inputEventHandler(event: Event, context: ?*anyopaque) EventResult {
    const state: *TextInputState = @ptrCast(@alignCast(context orelse return .ignored));
    if (state.disabled) return .ignored;
    state.beginUserEdit();
    defer state.endUserEdit();
    return handleEvent(state, event);
}

fn handleEvent(state: *TextInputState, event: Event) EventResult {
    if (state.readonly) {
        switch (event) {
            .text_input, .ime_preedit, .ime_commit, .ime_delete_surrounding => return .handled,
            .key_down => |e| {
                if (e.key == .tab) return .ignored; // Focus traversal, never insert indentation.
                const allowed = switch (e.key) {
                    .left, .right, .up, .down, .home, .end, .page_up, .page_down, .escape => true,
                    .a, .c => events.primaryModifier(e.modifiers),
                    else => false,
                };
                if (!allowed) return .handled;
            },
            else => {},
        }
    }

    switch (event) {
        .key_down, .mouse_down, .focus, .blur => state.endImePendingCommit(),
        else => {},
    }

    switch (event) {
        .text_input => |e| {
            var input = ImeText.init(state.allocator, e.text) catch return .handled;
            defer input.deinit();
            input.len = state_mod.sanitizeInputText(state, input.text(), input.mutableText()).len;
            const filtered = input.text();
            if (filtered.len == 0) {
                return .handled;
            }

            if (state.imeIsComposing()) {
                // Space in candidate phase usually 'page/word select' action, shouldn't land text.
                if (state_mod.isImeSelectionSpace(filtered)) {
                    state.markImeSelectionHighlight();
                    state.updateScrollX();
                    return .handled;
                }
                // Some IME only report text_input (no ime_commit) on commit.
                state.handleImeCommitEventChecked(filtered) catch return .handled;
                state.updateScrollX();
                fireOnChange(state);
                return .handled;
            }

            if (state.consumeImePostCommitDuplicate(filtered)) {
                state.updateScrollX();
                return .handled;
            }

            state.insertTextChecked(filtered) catch return .handled;
            state.updateScrollX();
            fireOnChange(state);
            return .handled;
        },
        .ime_preedit => |e| {
            var input = ImeText.init(state.allocator, e.text) catch return .handled;
            defer input.deinit();
            input.len = state_mod.sanitizeInputText(state, input.text(), input.mutableText()).len;
            const filtered = input.text();
            state.handleImePreeditReplaceEventChecked(filtered, e.cursor_utf8_offset, e.replace_start_utf8, e.replace_end_utf8) catch return .handled;
            state.setImeAttributes(e.cursor_visible, e.selection_end_utf8);
            state.updateScrollX();
            return .handled;
        },
        .ime_delete_surrounding => |e| {
            state.handleImeDeleteSurrounding(e.before_bytes, e.after_bytes) catch return .handled;
            state.updateScrollX();
            fireOnChange(state);
            return .handled;
        },
        .ime_commit => |e| {
            var input = ImeText.init(state.allocator, e.text) catch return .handled;
            defer input.deinit();
            input.len = state_mod.sanitizeInputText(state, input.text(), input.mutableText()).len;
            const filtered = input.text();
            state.handleImeCommitReplaceEventChecked(filtered, e.replace_start_utf8, e.replace_end_utf8) catch return .handled;
            state.updateScrollX();
            fireOnChange(state);
            return .handled;
        },
        .key_down => |e| {
            if (state.ime_replacement != null and (e.modifiers.super or e.modifiers.ctrl) and e.key != .z) state.cancelImeComposition();
            // Clipboard shortcuts (intercepted before handleKeyDown)
            if (events.primaryModifier(e.modifiers)) {
                if (state.cx_ref) |cx| {
                    if (core_ui.platform_services.clipboardAvailable(cx.system_sdk)) {
                        switch (e.key) {
                            .c => {
                                // Cmd+C: copy (disabled for password fields, like
                                // NSSecureTextField)
                                if (state.input_type == .password) return .handled;
                                if (state.getSelectedText()) |sel| {
                                    _ = core_ui.platform_services.clipboardSetText(cx.system_sdk, sel);
                                }
                                return .handled;
                            },
                            .x => {
                                // Cmd+X: cut (disabled for password fields: neither write clipboard
                                // nor delete text)
                                if (state.input_type == .password) return .handled;
                                if (state.getSelectedText()) |sel| {
                                    if (core_ui.platform_services.clipboardSetText(cx.system_sdk, sel)) {
                                        if (state.pushUndo()) {
                                            state.deleteRange(state.selection_anchor.?, state.cursor_pos);
                                            state.updateScrollX();
                                            fireOnChange(state);
                                        }
                                    }
                                }
                                return .handled;
                            },
                            .v => {
                                const allocator = state.allocator;
                                // Keep the basic fixed-buffer backend contract when
                                // length queries are not implemented. Native/full
                                // backends read the complete text before filtering.
                                var fallback: [editable_block.MAX_INPUT_BYTES + 1]u8 = undefined;
                                var owned: ?[]const u8 = null;
                                defer if (owned) |bytes| allocator.free(bytes);
                                const clip = blk: {
                                    owned = core_ui.platform_services.clipboardGetTextAllocChecked(cx.system_sdk, allocator) catch |err| {
                                        if (err == error.NotSupported) break :blk core_ui.platform_services.clipboardGetText(cx.system_sdk, &fallback) orelse return .handled;
                                        return .handled;
                                    };
                                    break :blk owned orelse return .handled;
                                };
                                const filtered = state_mod.sanitizeInputText(state, clip, @constCast(clip));
                                if (filtered.len > 0) {
                                    const previous_kind = state.undo_coalesce_kind;
                                    state.undo_coalesce_kind = .none;
                                    state.insertTextChecked(filtered) catch {
                                        state.undo_coalesce_kind = previous_kind;
                                        return .handled;
                                    };
                                    state.breakUndoCoalescing();
                                    state.updateScrollX();
                                    fireOnChange(state);
                                }
                                return .handled;
                            },
                            else => {},
                        }
                    }
                }
            }

            if (state.imeIsComposing() and !e.modifiers.super and !e.modifiers.ctrl) {
                if (e.key == .escape) {
                    state.cancelImeComposition();
                    state.updateScrollX();
                } else if (e.key == .space) {
                    state.markImeSelectionHighlight();
                    state.updateScrollX();
                }
                return .handled;
            }

            if (!state.accept_newline and e.key == .@"return" and !e.modifiers.super and !e.modifiers.ctrl) {
                if (state.on_submit) |h| {
                    h.invokeWithStr(state.getText());
                    return .handled;
                }
            }

            if (state.accept_newline and e.key == .@"return" and !e.modifiers.super and !e.modifiers.ctrl) {
                state.insertTextChecked("\n") catch return .handled;
                state.updateScrollX();
                fireOnChange(state);
                return .handled;
            }

            const len_before = if (state.textarea_doc) |d| d.totalLength() else state.buffer_len;
            const undo_before = if (state.textarea_doc != null) state.ta_undo_count else state.undo_count;
            const redo_before = if (state.textarea_doc != null) state.ta_redo_count else state.redo_count;
            if (state.handleKeyDown(e.key, e.modifiers)) {
                state.updateScrollX();
                const len_after = if (state.textarea_doc) |d| d.totalLength() else state.buffer_len;
                const undo_after = if (state.textarea_doc != null) state.ta_undo_count else state.undo_count;
                const redo_after = if (state.textarea_doc != null) state.ta_redo_count else state.redo_count;
                // Equal-length undo/redo still publishes a different document;
                // failed history preparation and composition cancellation do not.
                if (len_after != len_before or undo_after != undo_before or redo_after != redo_before) fireOnChange(state);
                return .handled;
            }
            return .ignored;
        },
        .mouse_down => |e| {
            state.drag_pointer = null;
            if (state.imeIsComposing()) {
                state.cancelImeComposition();
            }
            const pos = state.hitTestCursorPosAt(e.x, e.y);
            state.focused = true; // Ensure click focuses
            const down_click_count = state.registerMouseDownClickCount(e.x, e.y);

            if (down_click_count >= 3) {
                // Triple-click select all immediately on press, avoid lag waiting for mouse_up.
                state.selectAll();
                state.suspend_drag_until_mouse_up = true;
                state.is_dragging = false;
                state.resetBlink();
                state.updateScrollX();
                return .handled;
            }

            if (down_click_count == 2 and !e.modifiers.shift) {
                // Double-click select word immediately on press, speed up input/textarea response.
                state.selectWordAt(pos);
                state.suspend_drag_until_mouse_up = true;
                state.is_dragging = false;
                state.resetBlink();
                state.updateScrollX();
                return .handled;
            }

            // Single-click: position cursor, set drag anchor
            state.suspend_drag_until_mouse_up = false;
            if (e.modifiers.shift) {
                if (state.selection_anchor == null) {
                    state.selection_anchor = state.cursor_pos;
                }
            } else {
                state.selection_anchor = pos; // New anchor = click position
            }
            state.cursor_pos = pos;
            state.is_dragging = true;
            state.resetBlink();
            state.updateScrollX();
            return .handled;
        },
        .mouse_up => {
            state.drag_pointer = null;
            state.is_dragging = false;
            state.suspend_drag_until_mouse_up = false;
            state.markVisualDirty();
            return .handled;
        },
        .mouse_move => |e| {
            if (state.suspend_drag_until_mouse_up) {
                state.resetBlink();
                return .handled;
            }
            if (state.is_dragging) {
                state.drag_pointer = .{ .x = e.x, .y = e.y, .time_ms = if (state.cx_ref) |cx| cx.frame_time_ms else 0 };
                const pos = state.hitTestCursorPosAt(e.x, e.y);
                if (pos != state.cursor_pos) {
                    state.cursor_pos = pos;
                    state.updateScrollX();
                }
                state.resetBlink();
                return .handled;
            }
            return .ignored;
        },
        .click => |e| {
            if (e.click_count >= 2 and state.consecutive_mouse_downs >= e.click_count) {
                // Already handled double/triple-click in mouse_down phase; avoid repeat hit-test.
                return .handled;
            }
            if (e.click_count >= 3) {
                // Triple-click select all
                state.selectAll();
                state.updateScrollX();
            } else if (e.click_count == 2) {
                // Double-click select word
                const pos = state.hitTestCursorPosAt(e.x, e.y);
                state.selectWordAt(pos);
                state.updateScrollX();
            }
            return .handled;
        },
        .scroll => |scroll| {
            // Multiline mode: forward scroll events to VirtualList ScrollArea
            if (state.multiline) {
                if (state.vl_state) |vl_state| {
                    const scroll_area_event = @import("../scroll_area/event.zig");
                    const container = vl_state.content_node.parent orelse return .ignored;
                    if (container.behavior.events.event_context) |ctx| {
                        return scroll_area_event.scrollEventHandler(Event{ .scroll = scroll }, ctx);
                    }
                }
            }
            return .ignored;
        },
        else => return .ignored,
    }
}

test "input event route commits full long text once and new key starts independent input" {
    const t = @import("std").testing;
    var state: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator };
    defer state.deinit();
    const value = (@as([("中").len * (200)]u8, @bitCast(@as([200][("中").len]u8, @splat(("中").*)))) ++ "");
    _ = inputEventHandler(.{ .ime_commit = .{ .text = value } }, &state);
    _ = inputEventHandler(.{ .text_input = .{ .text = value } }, &state);
    try t.expectEqualStrings(value, state.getText());
    _ = state.setText("");
    _ = inputEventHandler(.{ .ime_commit = .{ .text = "a" } }, &state);
    _ = inputEventHandler(.{ .key_down = .{ .key = .a } }, &state);
    _ = inputEventHandler(.{ .text_input = .{ .text = "a" } }, &state);
    try t.expectEqualStrings("aa", state.getText());
}

test "input fallback notifies only successful commit and exact duplicate is silent" {
    const std = @import("std");
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
    var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator(), .on_change = .{ .callback = Observer.notify, .context = &observer } };
    defer s.deinit();
    _ = s.setText("seed");
    s.cursor_pos = 4;
    s.selection_anchor = 0;
    s.handleImePreeditEvent("候选", 6);
    failing.fail_index = failing.alloc_index;
    _ = inputEventHandler(.{ .text_input = .{ .text = "新" } }, &s);
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqual(@as(usize, 0), observer.calls);
    try t.expectEqualStrings("seed", s.getText());
    _ = inputEventHandler(.{ .text_input = .{ .text = "新" } }, &s);
    try t.expectEqual(@as(usize, 1), observer.calls);
    try t.expectEqualStrings("新", s.getText());
    _ = inputEventHandler(.{ .text_input = .{ .text = "新" } }, &s);
    try t.expectEqual(@as(usize, 1), observer.calls);
    _ = inputEventHandler(.{ .key_down = .{ .key = .a } }, &s);
    _ = inputEventHandler(.{ .text_input = .{ .text = "新" } }, &s);
    try t.expectEqual(@as(usize, 2), observer.calls);
    try t.expectEqualStrings("新新", s.getText());
}

test "shared input keyboard equal-length undo redo notifies the published text" {
    const std = @import("std");
    const t = std.testing;
    const Observer = struct {
        calls: usize = 0,
        text: [3]u8 = undefined,
        fn notify(_: *anyopaque) void {
            unreachable;
        }
        fn changed(value: []const u8, context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            std.debug.assert(value.len == self.text.len);
            @memcpy(&self.text, value);
        }
    };
    for ([_]bool{ false, true }) |multiline| {
        var doc = state_mod.TextareaDocument.init(t.allocator);
        defer doc.deinit();
        var observer: Observer = .{};
        var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .multiline = multiline, .textarea_doc = if (multiline) &doc else null, .on_change = .{ .callback = Observer.notify, .context = &observer, .payload_callback = .{ .string = Observer.changed } } };
        defer s.deinit();
        _ = try s.setTextChecked("old");
        s.cursor_pos = 3;
        s.selection_anchor = 0;
        _ = inputEventHandler(.{ .text_input = .{ .text = "new" } }, &s);
        try t.expectEqualStrings("new", s.getText());
        try t.expectEqual(@as(usize, 1), observer.calls);
        _ = inputEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true } } }, &s);
        try t.expectEqualStrings("old", s.getText());
        try t.expectEqual(@as(usize, 2), observer.calls);
        try t.expectEqualStrings("old", &observer.text);
        _ = inputEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = true } } }, &s);
        try t.expectEqualStrings("new", s.getText());
        try t.expectEqual(@as(usize, 3), observer.calls);
        try t.expectEqualStrings("new", &observer.text);
        _ = inputEventHandler(.{ .key_down = .{ .key = .left } }, &s);
        try t.expectEqual(@as(usize, 3), observer.calls);
    }
}

test "shared input Enter allocation failure keeps text selection history and notification" {
    const std = @import("std");
    const t = std.testing;
    const Observer = struct {
        calls: usize = 0,
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    for ([_]bool{ false, true }) |multiline| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        var doc = state_mod.TextareaDocument.init(failing.allocator());
        defer doc.deinit();
        var observer: Observer = .{};
        var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator(), .multiline = multiline, .accept_newline = true, .textarea_doc = if (multiline) &doc else null, .on_change = .{ .callback = Observer.notify, .context = &observer } };
        defer s.deinit();
        _ = try s.setTextChecked("seed");
        s.cursor_pos = 4;
        s.selection_anchor = 0;
        const undo = if (multiline) s.ta_undo_count else s.undo_count;
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        _ = inputEventHandler(.{ .key_down = .{ .key = .@"return" } }, &s);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try t.expect(failing.has_induced_failure);
        try t.expectEqualStrings("seed", s.getText());
        try t.expectEqual(@as(usize, 4), s.cursor_pos);
        try t.expectEqual(@as(?usize, 0), s.selection_anchor);
        try t.expectEqual(undo, if (multiline) s.ta_undo_count else s.undo_count);
        try t.expectEqual(@as(usize, 0), observer.calls);
        _ = inputEventHandler(.{ .key_down = .{ .key = .@"return" } }, &s);
        try t.expectEqualStrings("\n", s.getText());
        try t.expectEqual(@as(usize, 1), observer.calls);
    }
}

test "shared input modifier deletion at a boundary preserves redo and stays silent" {
    const std = @import("std");
    const t = std.testing;
    const Observer = struct {
        calls: usize = 0,
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    for ([_]bool{ false, true }) |multiline| {
        var doc = state_mod.TextareaDocument.init(t.allocator);
        defer doc.deinit();
        var observer: Observer = .{};
        var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .multiline = multiline, .textarea_doc = if (multiline) &doc else null, .on_change = .{ .callback = Observer.notify, .context = &observer } };
        defer s.deinit();
        _ = try s.setTextChecked(if (multiline) "a\nb" else "ab");
        try s.insertTextChecked("!");
        s.undo();
        s.cursor_pos = if (multiline) 2 else 0;
        s.selection_anchor = s.cursor_pos;
        const undo = if (multiline) s.ta_undo_count else s.undo_count;
        const redo = if (multiline) s.ta_redo_count else s.redo_count;
        try t.expect(redo > 0);
        _ = inputEventHandler(.{ .key_down = .{ .key = .delete, .modifiers = .{ .super = true } } }, &s);
        try t.expectEqualStrings(if (multiline) "a\nb" else "ab", s.getText());
        try t.expectEqual(undo, if (multiline) s.ta_undo_count else s.undo_count);
        try t.expectEqual(redo, if (multiline) s.ta_redo_count else s.redo_count);
        try t.expectEqual(@as(usize, 0), observer.calls);
        _ = inputEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = true } } }, &s);
        try t.expectEqualStrings(if (multiline) "a\nb!" else "ab!", s.getText());
        try t.expectEqual(@as(usize, 1), observer.calls);
    }
}

test "shared input plain boundary deletion neither allocates nor consumes redo" {
    const std = @import("std");
    const t = std.testing;
    for ([_]bool{ false, true }) |multiline| {
        for ([_]bool{ false, true }) |forward| {
            for ([_]bool{ false, true }) |collapsed_anchor| {
                var failing = t.FailingAllocator.init(t.allocator, .{});
                var doc = state_mod.TextareaDocument.init(failing.allocator());
                defer doc.deinit();
                var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator(), .multiline = multiline, .textarea_doc = if (multiline) &doc else null };
                defer s.deinit();
                _ = try s.setTextChecked("seed");
                try s.insertTextChecked("!");
                s.undo();
                s.cursor_pos = if (forward) 4 else 0;
                s.selection_anchor = if (collapsed_anchor) s.cursor_pos else null;
                const undo = if (multiline) s.ta_undo_count else s.undo_count;
                const redo = if (multiline) s.ta_redo_count else s.redo_count;
                failing.fail_index = failing.alloc_index;
                failing.resize_fail_index = failing.resize_index;
                _ = inputEventHandler(.{ .key_down = .{ .key = if (forward) .forward_delete else .delete } }, &s);
                failing.fail_index = std.math.maxInt(usize);
                failing.resize_fail_index = std.math.maxInt(usize);
                try t.expect(!failing.has_induced_failure);
                try t.expectEqualStrings("seed", s.getText());
                try t.expectEqual(undo, if (multiline) s.ta_undo_count else s.undo_count);
                try t.expectEqual(redo, if (multiline) s.ta_redo_count else s.redo_count);
                try t.expectEqual(if (collapsed_anchor) @as(?usize, s.cursor_pos) else null, s.selection_anchor);
                s.redo();
                try t.expectEqualStrings("seed!", s.getText());
            }
        }
    }
}

test "shared input failed history and reconversion cancellation do not notify" {
    const std = @import("std");
    const t = std.testing;
    const Observer = struct {
        calls: usize = 0,
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    for ([_]bool{ false, true }) |multiline| {
        for ([_]bool{ false, true }) |redo| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var doc = state_mod.TextareaDocument.init(failing.allocator());
            defer doc.deinit();
            var observer: Observer = .{};
            var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator(), .multiline = multiline, .textarea_doc = if (multiline) &doc else null, .on_change = .{ .callback = Observer.notify, .context = &observer } };
            defer s.deinit();
            _ = try s.setTextChecked("old");
            s.selection_anchor = 0;
            try s.insertTextChecked("new");
            if (redo) s.undo();
            const expected_before = if (redo) "old" else "new";
            const undo_count = if (multiline) s.ta_undo_count else s.undo_count;
            const redo_count = if (multiline) s.ta_redo_count else s.redo_count;
            failing.fail_index = failing.alloc_index;
            failing.resize_fail_index = failing.resize_index;
            _ = inputEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = redo } } }, &s);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try t.expect(failing.has_induced_failure);
            try t.expectEqualStrings(expected_before, s.getText());
            try t.expectEqual(undo_count, if (multiline) s.ta_undo_count else s.undo_count);
            try t.expectEqual(redo_count, if (multiline) s.ta_redo_count else s.redo_count);
            try t.expectEqual(@as(usize, 0), observer.calls);
            s.handleImePreeditReplaceEvent("候", 3, 0, 3);
            _ = inputEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = redo } } }, &s);
            try t.expect(!s.imeIsComposing());
            try t.expectEqualStrings(expected_before, s.getText());
            try t.expectEqual(@as(usize, 0), observer.calls);
            _ = inputEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = redo } } }, &s);
            try t.expectEqualStrings(if (redo) "new" else "old", s.getText());
            try t.expectEqual(@as(usize, 1), observer.calls);
        }
    }
}

test "shared input Enter capacity rejection preserves redo and stays silent" {
    const std = @import("std");
    const t = std.testing;
    const Observer = struct {
        calls: usize = 0,
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    for ([_]bool{ false, true }) |multiline| {
        var doc = state_mod.TextareaDocument.init(t.allocator);
        defer doc.deinit();
        var observer: Observer = .{};
        var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .multiline = multiline, .accept_newline = true, .textarea_doc = if (multiline) &doc else null, .textarea_max_bytes = 4, .on_change = .{ .callback = Observer.notify, .context = &observer } };
        defer s.deinit();
        const original = if (multiline) "seed" else (@as([("a").len * (editable_block.MAX_INPUT_BYTES)]u8, @bitCast(@as([editable_block.MAX_INPUT_BYTES][("a").len]u8, @splat(("a").*)))) ++ "");
        _ = try s.setTextChecked(original);
        s.selection_anchor = 0;
        try s.insertTextChecked("x");
        s.undo();
        s.cursor_pos = s.getText().len;
        s.selection_anchor = null;
        const undo = if (multiline) s.ta_undo_count else s.undo_count;
        const redo = if (multiline) s.ta_redo_count else s.redo_count;
        _ = inputEventHandler(.{ .key_down = .{ .key = .@"return" } }, &s);
        try t.expectEqualStrings(original, s.getText());
        try t.expectEqual(undo, if (multiline) s.ta_undo_count else s.undo_count);
        try t.expectEqual(redo, if (multiline) s.ta_redo_count else s.redo_count);
        try t.expectEqual(@as(usize, 0), observer.calls);
        _ = inputEventHandler(.{ .key_down = .{ .key = .z, .modifiers = .{ .super = true, .shift = true } } }, &s);
        try t.expectEqualStrings("x", s.getText());
        try t.expectEqual(@as(usize, 1), observer.calls);
    }
}

test "shared keyboard deletion variants retain selected Unicode on failure and undo after retry" {
    const std = @import("std");
    const t = std.testing;
    const cases = [_]struct { key: events.KeyCode, modifiers: events.Modifiers }{
        .{ .key = .delete, .modifiers = .{} },
        .{ .key = .forward_delete, .modifiers = .{} },
        .{ .key = .delete, .modifiers = .{ .super = true } },
        .{ .key = .delete, .modifiers = .{ .alt = true } },
        .{ .key = .forward_delete, .modifiers = .{ .alt = true } },
    };
    for ([_]bool{ false, true }) |multiline| {
        for (cases) |case| {
            var failing = t.FailingAllocator.init(t.allocator, .{});
            var doc = state_mod.TextareaDocument.init(failing.allocator());
            defer doc.deinit();
            var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = failing.allocator(), .multiline = multiline, .textarea_doc = if (multiline) &doc else null };
            defer s.deinit();
            _ = try s.setTextChecked("a漢b");
            s.cursor_pos = 1;
            s.selection_anchor = 4;
            const undo = if (multiline) s.ta_undo_count else s.undo_count;
            failing.fail_index = failing.alloc_index;
            failing.resize_fail_index = failing.resize_index;
            _ = inputEventHandler(.{ .key_down = .{ .key = case.key, .modifiers = case.modifiers } }, &s);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try t.expect(failing.has_induced_failure);
            try t.expectEqualStrings("a漢b", s.getText());
            try t.expectEqual(@as(usize, 1), s.cursor_pos);
            try t.expectEqual(@as(?usize, 4), s.selection_anchor);
            try t.expectEqual(undo, if (multiline) s.ta_undo_count else s.undo_count);
            _ = inputEventHandler(.{ .key_down = .{ .key = case.key, .modifiers = case.modifiers } }, &s);
            try t.expectEqualStrings("ab", s.getText());
            s.undo();
            try t.expectEqualStrings("a漢b", s.getText());
            s.cursor_pos = 4;
            s.selection_anchor = null;
            s.deleteBackward();
            try t.expectEqualStrings("ab", s.getText());
            s.undo();
            try t.expectEqualStrings("a漢b", s.getText());
            s.cursor_pos = 1;
            s.selection_anchor = null;
            s.deleteForward();
            try t.expectEqualStrings("ab", s.getText());
        }
    }
}

test "buffer backed multiline commands keep the current line after newline" {
    const std = @import("std");
    const t = std.testing;
    const cases = [_]struct { text: []const u8, cursor: usize }{
        .{ .text = "a\nb", .cursor = 2 },
        .{ .text = "\nb", .cursor = 1 },
        .{ .text = "a\n\nb", .cursor = 3 },
        .{ .text = "漢\n", .cursor = 4 },
    };
    for (cases) |case| {
        var s: TextInputState = .{ .io = @import("std").testing.io, .allocator = t.allocator, .multiline = true };
        defer s.deinit();
        _ = try s.setTextChecked(case.text);
        try s.insertTextChecked("!");
        s.undo();
        s.cursor_pos = case.cursor;
        s.selection_anchor = null;
        const undo = s.undo_count;
        const redo = s.redo_count;
        _ = inputEventHandler(.{ .key_down = .{ .key = .delete, .modifiers = .{ .super = true } } }, &s);
        try t.expectEqualStrings(case.text, s.getText());
        try t.expectEqual(case.cursor, s.cursor_pos);
        try t.expectEqual(undo, s.undo_count);
        try t.expectEqual(redo, s.redo_count);
        _ = inputEventHandler(.{ .key_down = .{ .key = .left, .modifiers = .{ .super = true } } }, &s);
        try t.expectEqual(case.cursor, s.cursor_pos);
        try t.expectEqual(case.cursor, s.findLineStart(case.cursor));
        try t.expectEqual(case.cursor, s.findLineStart(case.text.len));
        if (case.cursor > 0) try t.expect(s.findLineStart(case.cursor - 1) < case.cursor);
    }
}

test {
    _ = @import("clipboard_tests.zig");
}
