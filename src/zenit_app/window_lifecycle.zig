//! Deterministic application-level multi-window lifecycle state.
//!
//! Native handles, Cx instances, and render resources stay in runtime.zig; this
//! small state machine makes close/focus/menu semantics testable without Metal
//! or a WindowServer.

const std = @import("std");

pub const WindowId = u64;
pub const MAX_WINDOWS: usize = 16;

pub const State = struct {
    ids: [MAX_WINDOWS]WindowId = [_]WindowId{0} ** MAX_WINDOWS,
    len: usize = 0,
    pending_close: [MAX_WINDOWS]WindowId = [_]WindowId{0} ** MAX_WINDOWS,
    pending_close_len: usize = 0,
    active_window_id: ?WindowId = null,
    quit_requested: bool = false,

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
            self.quit_requested = true;
        } else if (self.active_window_id == window_id) {
            self.active_window_id = self.ids[self.len - 1];
        }
        return true;
    }

    pub fn requestQuit(self: *State) void {
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
