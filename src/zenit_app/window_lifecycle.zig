//! Deterministic application-level multi-window lifecycle state.
//!
//! Native handles, Cx instances, and render resources stay in runtime.zig; this
//! small state machine makes close/focus/menu semantics testable without Metal
//! or a WindowServer.

const std = @import("std");

pub const WindowId = u64;
pub const MAX_WINDOWS: usize = 16;

pub const State = struct {
    ids: [MAX_WINDOWS]WindowId = @as([MAX_WINDOWS]WindowId, @splat(0)),
    len: usize = 0,
    pending_close: [MAX_WINDOWS]WindowId = @as([MAX_WINDOWS]WindowId, @splat(0)),
    pending_close_len: usize = 0,
    active_window_id: ?WindowId = null,
    quit_requested: bool = false,
    // A last-close exit is provisional: on_destroy may register a replacement.
    // Explicit/API and accepted native user quits remain sticky.
    quit_source: enum { none, last_window, explicit } = .none,

    pub fn count(self: *const State) usize {
        return self.len;
    }

    pub fn contains(self: *const State, window_id: WindowId) bool {
        return self.indexOf(window_id) != null;
    }

    pub fn add(self: *State, window_id: WindowId) !void {
        if (window_id == 0 or self.contains(window_id)) return error.InvalidWindowId;
        if (self.len == self.ids.len) return error.TooManyWindows;
        self.ids[self.len] = window_id;
        self.len += 1;
        self.active_window_id = window_id;
        if (self.quit_source == .last_window) {
            self.quit_source = .none;
            self.quit_requested = false;
        }
    }

    /// Record native focus only for a still-live window. A late focus
    /// notification from a closing NSWindow cannot resurrect its context.
    pub fn setFocused(self: *State, window_id: WindowId, focused: bool) void {
        if (focused and self.contains(window_id)) self.active_window_id = window_id;
    }

    /// Resolve a custom menu command. A non-zero captured id is authoritative:
    /// if that window has closed, the command is dropped instead of leaking to
    /// whichever window became active afterward. Zero retains the explicit
    /// active-window fallback for custom/non-native backends.
    pub fn menuTarget(self: *const State, captured_window_id: WindowId) ?WindowId {
        if (captured_window_id != 0) {
            return if (self.contains(captured_window_id)) captured_window_id else null;
        }
        const active = self.active_window_id orelse return null;
        return if (self.contains(active)) active else null;
    }

    /// Route a process-global native menu packet after one window's SDK pump
    /// happened to dequeue it. The pump owner is transport provenance only;
    /// the key-window id captured when the command fired remains authoritative.
    pub fn menuTargetFromPump(
        self: *const State,
        pump_owner_window_id: WindowId,
        captured_window_id: WindowId,
    ) ?WindowId {
        if (!self.contains(pump_owner_window_id)) return null;
        return self.menuTarget(captured_window_id);
    }

    pub fn requestClose(self: *State, window_id: WindowId) bool {
        if (!self.contains(window_id)) return false;
        for (self.pending_close[0..self.pending_close_len]) |pending| {
            if (pending == window_id) return true;
        }
        if (self.pending_close_len == self.pending_close.len) return false;
        self.pending_close[self.pending_close_len] = window_id;
        self.pending_close_len += 1;
        return true;
    }

    pub fn popPendingClose(self: *State) ?WindowId {
        if (self.pending_close_len == 0) return null;
        const id = self.pending_close[0];
        var i: usize = 1;
        while (i < self.pending_close_len) : (i += 1) {
            self.pending_close[i - 1] = self.pending_close[i];
        }
        self.pending_close_len -= 1;
        self.pending_close[self.pending_close_len] = 0;
        return id;
    }

    /// Commit resource teardown for one window. The most recently created
    /// surviving window becomes the deterministic fallback until AppKit sends
    /// its next focus notification. Removing the last window exits the app.
    pub fn removed(self: *State, window_id: WindowId) bool {
        const index = self.indexOf(window_id) orelse return false;
        var i = index + 1;
        while (i < self.len) : (i += 1) self.ids[i - 1] = self.ids[i];
        self.len -= 1;
        self.ids[self.len] = 0;
        self.removePending(window_id);

        if (self.len == 0) {
            self.active_window_id = null;
            if (self.quit_source != .explicit) {
                self.quit_source = .last_window;
                self.quit_requested = true;
            }
        } else if (self.active_window_id == window_id) {
            self.active_window_id = self.ids[self.len - 1];
        }
        return true;
    }

    /// Commit teardown and decide where focus goes. Only a window that still
    /// held focus hands it on: a closing panel returns it to its owner,
    /// otherwise the `removed` fallback stands. When focus had already moved
    /// on (closes can finish frames later, after another window was
    /// activated), the active window is left alone and null is returned.
    pub fn removedFocusHandoff(self: *State, window_id: WindowId, owner: ?WindowId) ?WindowId {
        const held_focus = self.active_window_id == window_id;
        if (!self.removed(window_id)) return null;
        if (!held_focus or self.quit_requested) return null;
        if (owner) |owner_id| self.setFocused(owner_id, true);
        return self.active_window_id;
    }

    pub fn requestQuit(self: *State) void {
        self.quit_source = .explicit;
        self.quit_requested = true;
    }

    fn indexOf(self: *const State, window_id: WindowId) ?usize {
        for (self.ids[0..self.len], 0..) |id, i| {
            if (id == window_id) return i;
        }
        return null;
    }

    fn removePending(self: *State, window_id: WindowId) void {
        var write: usize = 0;
        for (self.pending_close[0..self.pending_close_len]) |pending| {
            if (pending == window_id) continue;
            self.pending_close[write] = pending;
            write += 1;
        }
        @memset(self.pending_close[write..self.pending_close_len], 0);
        self.pending_close_len = write;
    }
};

test "multi-window lifecycle closes one window without quitting peers" {
    var state = State{};
    try state.add(10);
    try state.add(20);
    state.setFocused(10, true);
    try std.testing.expectEqual(@as(?WindowId, 10), state.active_window_id);

    try std.testing.expect(state.requestClose(10));
    try std.testing.expect(state.requestClose(10)); // idempotent
    try std.testing.expectEqual(@as(?WindowId, 10), state.popPendingClose());
    try std.testing.expect(state.removed(10));
    try std.testing.expectEqual(@as(usize, 1), state.count());
    try std.testing.expectEqual(@as(?WindowId, 20), state.active_window_id);
    try std.testing.expect(!state.quit_requested);
}

test "a panel that finishes closing after focus moved on does not take it back" {
    var state = State{};
    try state.add(1); // editor
    try state.add(2); // panel owned by 1
    state.setFocused(2, true);
    // The panel's close is requested; focus returns to the editor, then a new
    // panel opens before the first one's native close completes.
    try std.testing.expect(state.requestClose(2));
    state.setFocused(1, true);
    try state.add(3);
    try std.testing.expectEqual(@as(?WindowId, null), state.removedFocusHandoff(2, 1));
    try std.testing.expectEqual(@as(?WindowId, 3), state.active_window_id);

    // A panel that still holds focus hands it back to its owner.
    try std.testing.expectEqual(@as(?WindowId, 1), state.removedFocusHandoff(3, 1));
    try std.testing.expectEqual(@as(?WindowId, 1), state.active_window_id);
}

test "focus handoff tolerates owner teardown and duplicate close completion" {
    var state = State{};
    try state.add(1); // owner
    try state.add(2); // panel
    try state.add(3); // surviving peer
    state.setFocused(2, true);
    try std.testing.expectEqual(@as(?WindowId, null), state.removedFocusHandoff(1, null));
    // A dead owner cannot be reactivated; the deterministic live peer wins.
    try std.testing.expectEqual(@as(?WindowId, 3), state.removedFocusHandoff(2, 1));
    try state.add(4); // a replacement opened after the close completed
    try std.testing.expectEqual(@as(?WindowId, null), state.removedFocusHandoff(2, 1));
    state.setFocused(2, true); // late native event for the destroyed panel
    try std.testing.expectEqual(@as(?WindowId, 4), state.active_window_id);
    try std.testing.expectEqual(@as(usize, 2), state.count());
}

test "focus handoff is suppressed during quit and last-close replacement stays active" {
    var state = State{};
    try state.add(1);
    try state.add(2);
    state.requestQuit();
    try std.testing.expectEqual(@as(?WindowId, null), state.removedFocusHandoff(2, 1));
    try std.testing.expect(state.quit_requested);
    try std.testing.expectEqual(@as(?WindowId, null), state.removedFocusHandoff(1, null));
    try state.add(3);
    try std.testing.expect(state.quit_requested); // explicit quit remains sticky

    var replacement = State{};
    try replacement.add(1);
    try std.testing.expectEqual(@as(?WindowId, null), replacement.removedFocusHandoff(1, null));
    try std.testing.expect(replacement.quit_requested);
    try replacement.add(2); // on_destroy opens a replacement window
    try std.testing.expect(!replacement.quit_requested);
    try std.testing.expectEqual(@as(?WindowId, 2), replacement.active_window_id);
}

test "multi-window lifecycle exits only after the last window teardown" {
    var state = State{};
    try state.add(1);
    try state.add(2);
    try std.testing.expect(state.removed(2));
    try std.testing.expect(!state.quit_requested);
    try std.testing.expect(state.removed(1));
    try std.testing.expect(state.quit_requested);
    try std.testing.expectEqual(@as(usize, 0), state.count());
}

test "menu routing captures active context and drops stale targets" {
    var state = State{};
    try state.add(101);
    try state.add(202);
    state.setFocused(101, true);
    try std.testing.expectEqual(@as(?WindowId, 101), state.menuTarget(0));
    try std.testing.expectEqual(@as(?WindowId, 202), state.menuTarget(202));

    try std.testing.expect(state.removed(101));
    // A queued command captured for the closed window must not jump to 202.
    try std.testing.expectEqual(@as(?WindowId, null), state.menuTarget(101));
    try std.testing.expectEqual(@as(?WindowId, 202), state.menuTarget(0));
}

test "global menu packet dequeued by A dispatches only to captured B" {
    var state = State{};
    const window_a: WindowId = 101;
    const window_b: WindowId = 202;
    try state.add(window_a);
    try state.add(window_b);
    state.setFocused(window_a, true);

    var delivered_a: usize = 0;
    var delivered_b: usize = 0;
    const target = state.menuTargetFromPump(window_a, window_b) orelse
        return error.MissingMenuTarget;
    if (target == window_a) delivered_a += 1;
    if (target == window_b) delivered_b += 1;

    try std.testing.expectEqual(@as(usize, 0), delivered_a);
    try std.testing.expectEqual(@as(usize, 1), delivered_b);
}

test "application quit stops pumping before owner-driven teardown" {
    var state = State{};
    try state.add(11);
    try state.add(22);

    state.requestQuit();
    try std.testing.expect(state.quit_requested);
    // Cmd-Q / MultiWindowApp.quit() ends run(); ownership stays intact until
    // the caller's deferred MultiWindowApp.deinit() tears down every window.
    try std.testing.expectEqual(@as(usize, 2), state.count());

    try std.testing.expect(state.removed(22));
    try std.testing.expect(state.removed(11));
    try std.testing.expectEqual(@as(usize, 0), state.count());
}

test "multi-window lifecycle rejects invalid and excess registrations" {
    var state = State{};
    try std.testing.expectError(error.InvalidWindowId, state.add(0));
    try state.add(1);
    try std.testing.expectError(error.InvalidWindowId, state.add(1));
    for (2..MAX_WINDOWS + 1) |id| try state.add(@intCast(id));
    try std.testing.expectError(error.TooManyWindows, state.add(999));
}

test "last-window destroy callback can add a replacement and resume pumping" {
    var state = State{};
    try state.add(1);
    try std.testing.expect(state.removed(1));
    try std.testing.expect(state.quit_requested);
    try state.add(2);
    try std.testing.expect(!state.quit_requested);
    try std.testing.expectEqual(@as(?WindowId, 2), state.active_window_id);
}

test "adding windows cannot withdraw explicit or user quit" {
    for ([_]bool{ false, true }) |close_last| {
        var state = State{};
        try state.add(1);
        state.requestQuit();
        if (close_last) try std.testing.expect(state.removed(1));
        try state.add(2);
        try std.testing.expect(state.quit_requested);
    }
    var state = State{};
    try state.add(1);
    _ = state.removed(1);
    state.requestQuit(); // Explicit quit after the automatic last-close exit.
    try state.add(2);
    try std.testing.expect(state.quit_requested);
}
