//! Independent file transport. All names live below dev-control/, even when
//! a caller accidentally passes the harness directory as the session root.
const std = @import("std");
const channel = @import("channel.zig");
const A = std.mem.Allocator;
pub const Session = struct {
    allocator: A,
    io: std.Io,
    path: []const u8,
    revision: []const u8,
    generation: []const u8,
    dir: std.Io.Dir,
    lock: std.Io.File,
    stopped_status: []const u8,
    channel: channel.Channel,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    pub fn init(a: A, io: std.Io, root: []const u8, revision: []const u8, generation: []const u8) !Session {
        if (!std.fs.path.isAbsolute(root) or revision.len == 0 or generation.len == 0) return error.InvalidSessionIdentity;
        const path = try std.fs.path.join(a, &.{ root, "dev-control" });
        errdefer a.free(path);
        const rev = try a.dupe(u8, revision);
        errdefer a.free(rev);
        const gen = try a.dupe(u8, generation);
        errdefer a.free(gen);
        try std.Io.Dir.cwd().createDirPath(io, path);
        const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        errdefer dir.close(io);
        const lock = try dir.createFile(io, "session.lock", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
        errdefer lock.close(io);
        // A generation directory is never reused, including after a crash.
        const stopped_status = try std.json.Stringify.valueAlloc(a, .{ .status = "stopped", .revision = rev, .generation = gen }, .{});
        errdefer a.free(stopped_status);
        const identity = try dir.createFile(io, "identity.json", .{ .exclusive = true });
        defer identity.close(io);
        const bytes = try std.json.Stringify.valueAlloc(a, .{ .revision = rev, .generation = gen }, .{});
        defer a.free(bytes);
        try identity.writeStreamingAll(io, bytes);
        return .{ .allocator = a, .io = io, .path = path, .revision = rev, .generation = gen, .dir = dir, .lock = lock, .stopped_status = stopped_status, .channel = .{ .io = io } };
    }
    pub fn start(self: *Session) !void {
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }
    pub fn deinit(self: *Session) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.dir.deleteFile(self.io, "ready") catch {};
        atomicWrite(self.dir, self.io, "health", self.stopped_status) catch {};
        self.allocator.free(self.stopped_status);
        self.lock.close(self.io);
        self.dir.close(self.io);
        self.allocator.free(self.path);
        self.allocator.free(self.revision);
        self.allocator.free(self.generation);
    }
    fn worker(self: *Session) void {
        while (!self.stop.load(.acquire)) {
            self.processRequests() catch {};
            std.Io.sleep(self.io, .fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        }
    }
    fn processRequests(self: *Session) !void {
        var it = self.dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (self.stop.load(.acquire)) return;
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "req-") or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            const id = entry.name[4 .. entry.name.len - 5];
            if (id.len == 0 or id.len > 64) continue;
            var valid = true;
            for (id) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-') valid = false;
            }
            if (!valid) continue;
            try self.handle(entry.name, id);
        }
    }
    fn handle(self: *Session, name: []const u8, id: []const u8) !void {
        var out: [16384]u8 = undefined;
        const text = self.dir.readFileAlloc(self.io, name, self.allocator, .limited(32768)) catch |err| {
            self.dir.deleteFile(self.io, name) catch {};
            return self.respond(id, try errorJson(&out, err));
        };
        defer self.allocator.free(text);
        defer self.dir.deleteFile(self.io, name) catch {};
        const parsed = std.json.parseFromSlice(channel.Request, self.allocator, text, .{ .allocate = .alloc_always }) catch |err| {
            return self.respond(id, try errorJson(&out, err));
        };
        defer parsed.deinit();
        self.channel.submit(parsed.value) catch |err| return self.respond(id, try errorJson(&out, err));
        while (!self.stop.load(.acquire)) {
            const result = self.channel.poll(&out) catch |err| return self.respond(id, try errorJson(&out, err));
            if (result) |body| return self.respond(id, body);
            std.Io.sleep(self.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        }
        const completed = self.channel.poll(&out) catch null;
        try self.respond(id, completed orelse "{\"error\":\"Stopped\"}");
    }
    fn respond(self: *Session, id: []const u8, body: []const u8) !void {
        var name: [100]u8 = undefined;
        try atomicWrite(self.dir, self.io, try std.fmt.bufPrint(&name, "res-{s}.json", .{id}), body);
    }
};
pub fn errorJson(out: []u8, err: anyerror) ![]const u8 {
    return std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
}
/// Same-directory rename is the only publication point. A crash during write
/// leaves a private *.tmp; the previous complete snapshot stays readable.
pub fn atomicWrite(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buffer, "{s}.tmp", .{name});
    errdefer dir.deleteFile(io, tmp) catch {};
    const file = try dir.createFile(io, tmp, .{});
    {
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try dir.rename(tmp, dir, name, io);
}
test "atomic snapshot publication survives interrupted write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try atomicWrite(tmp.dir, io, "snapshot.json", "complete-old");
    try tmp.dir.writeFile(io, .{ .sub_path = "snapshot.json.tmp", .data = "truncated-new" });
    const before = try tmp.dir.readFileAlloc(io, "snapshot.json", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(before);
    try std.testing.expectEqualStrings("complete-old", before);
    try atomicWrite(tmp.dir, io, "snapshot.json", "complete-new");
    const after = try tmp.dir.readFileAlloc(io, "snapshot.json", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("complete-new", after);
}
test "session is exclusive, generation cannot be reused, harness files remain untouched, normal exit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "owner.lock", .data = "harness-owner" });
    var session = try Session.init(a, io, path, "rev", "42");
    try std.testing.expectError(error.WouldBlock, Session.init(a, io, path, "rev", "43"));
    try session.start();
    session.deinit();
    try std.testing.expectError(error.PathAlreadyExists, Session.init(a, io, path, "rev", "42"));
    const owner = try tmp.dir.readFileAlloc(io, "owner.lock", a, .limited(100));
    defer a.free(owner);
    try std.testing.expectEqualStrings("harness-owner", owner);
}

test "worker answers deadline while UI never drains, malformed requests fail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var session = try Session.init(a, io, path, "rev", "stalled-ui");
    defer session.deinit();
    try atomicWrite(session.dir, io, "req-stalled.json", "{\"command\":\"snapshot\",\"timeout_ms\":2}");
    try atomicWrite(session.dir, io, "req-invalid.json", "{\"command\":\"quit\",\"timeout_ms\":0}");
    try session.start();
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + std.time.ns_per_s;
    for ([_][]const u8{ "res-stalled.json", "res-invalid.json" }, [_][]const u8{ "Timeout", "InvalidTimeout" }) |name, expected| {
        while (true) {
            const bytes = session.dir.readFileAlloc(io, name, a, .limited(100)) catch |err| {
                if (err != error.FileNotFound) return err;
                if (std.Io.Clock.awake.now(io).nanoseconds > deadline) return error.TestWorkerDidNotAnswer;
                try std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .awake);
                continue;
            };
            defer a.free(bytes);
            try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
            break;
        }
    }
    try std.testing.expect(session.channel.take() == null);
}
fn sessionOOM(a: A) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var session = try Session.init(a, std.testing.io, path, "revision", "generation");
    defer session.deinit();
}
test "session partial initialization allocation failure releases ownership and storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sessionOOM, .{});
}

test "atomic writer I/O fault after a real short write preserves the previous snapshot" {
    const Fault = struct {
        var original: @TypeOf(std.testing.io.vtable.operate) = undefined;
        var wrote_prefix = false;
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            switch (operation) {
                .file_write_streaming => |write| {
                    if (wrote_prefix) return .{ .file_write_streaming = error.InputOutput };
                    wrote_prefix = true;
                    var short = write;
                    short.header = &.{};
                    short.data = &.{write.data[0][0..@min(3, write.data[0].len)]};
                    short.splat = 1;
                    return original(userdata, .{ .file_write_streaming = short });
                },
                else => return original(userdata, operation),
            }
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try atomicWrite(tmp.dir, io, "snapshot.json", "previous complete snapshot");
    var vtable = io.vtable.*;
    Fault.original = vtable.operate;
    Fault.wrote_prefix = false;
    vtable.operate = Fault.operate;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.InputOutput, atomicWrite(tmp.dir, failing_io, "snapshot.json", "replacement interrupted halfway"));
    try std.testing.expect(Fault.wrote_prefix);
    const bytes = try tmp.dir.readFileAlloc(io, "snapshot.json", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("previous complete snapshot", bytes);
}
