//! One bounded, owned request slot. No pointers into the producer's stack.
const std = @import("std");
pub const Command = if (@import("build_options").dev_preview)
    enum { health, snapshot, show_error, clear_error, set_persist, set_scroll, set_frame, set_focus, reload_styles, query_style, reload_templates, query_template, activate_template, close_preview_window, quit }
else
    enum { health, snapshot, show_error, clear_error, quit };
pub const Request = if (@import("build_options").dev_preview) struct {
    command: Command,
    timeout_ms: u32 = 1000,
    text: []const u8 = "",
    files: []const []const u8 = &.{},
    test_id: []const u8 = "",
    fail_after: ?usize = null,
    fail_commit_at: ?usize = null,
    occurrence: ?usize = null,
} else struct {
    command: Command,
    timeout_ms: u32 = 1000,
    text: []const u8 = "",
};
pub const Work = struct {
    command: Command = .health,
    deadline: i96 = 0,
    text: [8192]u8 = undefined,
    len: usize = 0,
};
pub const Channel = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    state: enum { idle, pending, running, abandoned, done } = .idle,
    work: Work = .{},
    response: [16384]u8 = undefined,
    len: usize = 0,
    pub fn submit(self: *Channel, request: Request) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .idle) return error.Busy;
        if (request.timeout_ms == 0 or request.timeout_ms > 30000) return error.InvalidTimeout;
        // Serialize all variable fields into local owned bytes before publishing work.
        // In particular no file-name slices from the transport's Parsed value escape submit.
        var encoded: [8192]u8 = undefined;
        var payload = request.text;
        if (@import("build_options").dev_preview) switch (request.command) {
            .reload_templates => {
                var writer = std.Io.Writer.fixed(&encoded);
                std.json.Stringify.value(.{ .files = request.files, .fail_after = request.fail_after, .fail_commit_at = request.fail_commit_at }, .{}, &writer) catch return error.TextTooLarge;
                payload = writer.buffered();
            },
            .reload_styles => {
                var writer = std.Io.Writer.fixed(&encoded);
                std.json.Stringify.value(.{ .files = request.files }, .{}, &writer) catch return error.TextTooLarge;
                payload = writer.buffered();
            },
            .query_template, .activate_template => {
                var writer = std.Io.Writer.fixed(&encoded);
                std.json.Stringify.value(.{ .test_id = request.test_id, .occurrence = request.occurrence }, .{}, &writer) catch return error.TextTooLarge;
                payload = writer.buffered();
            },
            .query_style => {
                var writer = std.Io.Writer.fixed(&encoded);
                std.json.Stringify.value(.{ .test_id = request.test_id }, .{}, &writer) catch return error.TextTooLarge;
                payload = writer.buffered();
            },
            else => {},
        };
        if (payload.len > self.work.text.len) return error.TextTooLarge;
        self.work = .{ .command = request.command, .deadline = self.now() + @as(i96, request.timeout_ms) * std.time.ns_per_ms, .len = payload.len };
        @memcpy(self.work.text[0..payload.len], payload);
        self.state = .pending;
    }
    fn now(self: *Channel) i96 {
        return std.Io.Clock.awake.now(self.io).nanoseconds;
    }
    /// Producer polling never waits for the UI; deadline expiration cancels
    /// unstarted work and abandons running work until its owner completes it.
    pub fn poll(self: *Channel, out: []u8) !?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.now() >= self.work.deadline) {
            self.state = if (self.state == .running or self.state == .abandoned) .abandoned else .idle;
            return error.Timeout;
        }
        if (self.state == .done) {
            self.state = .idle;
            if (self.len > out.len) return error.ResponseTooLarge;
            @memcpy(out[0..self.len], self.response[0..self.len]);
            return out[0..self.len];
        }
        return null;
    }
    pub fn take(self: *Channel) ?Work {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .pending or self.now() >= self.work.deadline) return null;
        self.state = .running;
        return self.work;
    }
    pub fn complete(self: *Channel, body: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .abandoned) {
            self.state = .idle;
            return;
        }
        if (body.len > self.response.len) {
            const err = "{\"error\":\"ResponseTooLarge\"}";
            @memcpy(self.response[0..err.len], err);
            self.len = err.len;
        } else {
            @memcpy(self.response[0..body.len], body);
            self.len = body.len;
        }
        self.state = .done;
    }
};
test "deadline cancels pending work and timeout never leaves caller storage referenced" {
    var channel: Channel = .{ .io = std.testing.io };
    try channel.submit(.{ .command = .quit, .timeout_ms = 1 });
    channel.work.deadline = 0;
    var result: [64]u8 = undefined;
    try std.testing.expect(channel.take() == null);
    try std.testing.expectError(error.Timeout, channel.poll(&result));
    try channel.submit(.{ .command = .show_error, .text = "file.zig:3\nerror" });
    const work = channel.take().?;
    try std.testing.expectEqualStrings("file.zig:3\nerror", work.text[0..work.len]);
    channel.work.deadline = 0;
    try std.testing.expectError(error.Timeout, channel.poll(&result));
    try std.testing.expectError(error.Busy, channel.submit(.{ .command = .health }));
    channel.complete("late");
    try channel.submit(.{ .command = .health });
    _ = channel.take();
    channel.complete("ok");
    try std.testing.expectEqualStrings("ok", (try channel.poll(&result)).?);
}

// The transport parser itself rejects mutation commands in non-preview builds.
test "dev mutation commands are erased from the non-preview command schema" {
    inline for (.{ "set_persist", "set_scroll", "set_frame", "set_focus" }) |name| {
        try std.testing.expectEqual(@import("build_options").dev_preview, std.meta.stringToEnum(Command, name) != null);
    }
}

test "preview style request owns arrays and repeated timeout keeps abandoned slot" {
    // SKIP-REASON: dev-control runs only in -Ddev-preview=true builds (test-dev-control step).
    if (!@import("build_options").dev_preview) return error.SkipZigTest;
    var channel: Channel = .{ .io = std.testing.io };
    var path = [_]u8{ 'a', '.', 'y', 's', 's' };
    try channel.submit(.{ .command = .reload_styles, .files = &.{&path} });
    path[0] = 'b';
    const work = channel.take().?;
    try std.testing.expectEqualStrings("{\"files\":[\"a.yss\"]}", work.text[0..work.len]);
    channel.work.deadline = 0;
    var response: [128]u8 = undefined;
    try std.testing.expectError(error.Timeout, channel.poll(&response));
    try std.testing.expectError(error.Timeout, channel.poll(&response));
    try std.testing.expectError(error.Busy, channel.submit(.{ .command = .health }));
    channel.complete("abandoned");
    try channel.submit(.{ .command = .query_style, .test_id = "card" });
    const query = channel.take().?;
    try std.testing.expectEqualStrings("{\"test_id\":\"card\"}", query.text[0..query.len]);
    channel.complete("ok");
    _ = try channel.poll(&response);
}

test "release style command arguments and names are erased" {
    const dev = @import("build_options").dev_preview;
    try std.testing.expectEqual(dev, @hasField(Request, "files"));
    try std.testing.expectEqual(dev, @hasField(Request, "test_id"));
    try std.testing.expectEqual(dev, @hasField(Request, "fail_after"));
    try std.testing.expectEqual(dev, @hasField(Request, "fail_commit_at"));
    try std.testing.expectEqual(dev, @hasField(Request, "occurrence"));
    inline for (.{ "reload_styles", "query_style", "reload_templates", "query_template", "activate_template", "close_preview_window" }) |name| try std.testing.expectEqual(dev, std.meta.stringToEnum(Command, name) != null);
}

test "preview template commit injection and row selection use owned channel bytes" {
    // SKIP-REASON: preview request fields are comptime-erased from non-preview builds.
    if (!@import("build_options").dev_preview) return error.SkipZigTest;
    var channel: Channel = .{ .io = std.testing.io };
    try channel.submit(.{ .command = .reload_templates, .files = &.{"view.yix"}, .fail_commit_at = 3 });
    const reload_work = channel.take().?;
    const parsed = try std.json.parseFromSlice(struct { files: []const []const u8, fail_after: ?usize, fail_commit_at: ?usize }, std.testing.allocator, reload_work.text[0..reload_work.len], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?usize, 3), parsed.value.fail_commit_at);
    channel.complete("ok");
    var response: [128]u8 = undefined;
    _ = try channel.poll(&response);
    try channel.submit(.{ .command = .query_template, .test_id = "row", .occurrence = 1 });
    const row_work = channel.take().?;
    try std.testing.expectEqualStrings("{\"test_id\":\"row\",\"occurrence\":1}", row_work.text[0..row_work.len]);
}
