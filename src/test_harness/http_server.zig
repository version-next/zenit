/// http_server: test HTTP server (file RPC mode)
///
/// Listens to file RPC dir; TS client writes req-XXX.json, server reads then writes res-XXX.json.
/// No real TCP socket: Zig 0.15 stdlib TCP server API unstable.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const command_queue = @import("command_queue.zig");
const ui = @import("ui");
const CommandQueue = command_queue.CommandQueue;
const TestCommand = command_queue.TestCommand;
const TextPayload = command_queue.TextPayload;
const TestIdPayload = command_queue.TestIdPayload;
const RecordingStartPayload = command_queue.RecordingStartPayload;
const MousePayload = command_queue.MousePayload;
const KeyPayload = command_queue.KeyPayload;

const PORT: u16 = build_options.e2e_port;
const MAX_BODY_SIZE = 2 * 1024 * 1024;
const FILE_RPC_POLL_MS: u64 = 10;
const OwnerPid = if (builtin.os.tag == .windows) u32 else std.c.pid_t;

fn ownerPid() OwnerPid {
    if (comptime builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return std.c.getpid();
}

const RequestResult = struct {
    status: u16,
    body: []const u8,
};

fn readFileCompat(dir: std.Io.Dir, io: std.Io, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return dir.readFileAlloc(io, path, allocator, .limited(MAX_BODY_SIZE));
}

fn fileRpcDirFromEnv() []const u8 {
    const raw = @import("zenit_environment").getNative("ZENIT_E2E_FILE_RPC_DIR") orelse return "";
    return std.mem.span(raw);
}

fn defaultFileRpcDir(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "/tmp/zenit_e2e_rpc_{d}", .{PORT}) catch "/tmp/zenit_e2e_rpc";
}

pub fn serverThread(queue: *CommandQueue) void {
    var rpc_dir_buf: [128]u8 = undefined;
    const rpc_dir = blk: {
        const env_path = fileRpcDirFromEnv();
        if (env_path.len > 0) break :blk env_path;
        break :blk defaultFileRpcDir(&rpc_dir_buf);
    };
    runFileRpcServer(queue, rpc_dir) catch |err| {
        std.debug.print("[test_harness] File RPC server error: {}\n", .{err});
    };
}

const OWNER_FILE = "owner.json";
const OWNER_LOCK_FILE = "owner.lock";

/// Single-owner lock: one file-RPC dir, one active server instance at a time.
///
/// Concurrent e2e runs sharing one dir let a random instance serve each request, giving false
/// 'test_id not found' failures. Conflicts must fail explicitly.
///
/// Protocol: the server holds an exclusive lock on owner.lock for the life of its process; the
/// kernel releases it when the process exits or crashes, so there is no residue to judge and
/// no stale file to delete (deleting by path raced: a slow claimant could remove the new
/// owner's file and both would serve). Whoever holds the lock writes owner.json (pid +
/// timestamp) for timeout diagnostics. The lock is separate from owner.json because Windows
/// byte-range locks are mandatory: readers of a locked owner.json would fail.
fn claimFileRpcOwnership(io: std.Io, rpc_dir: []const u8) !std.Io.File {
    var dir = try std.Io.Dir.cwd().openDir(io, rpc_dir, .{});
    defer dir.close(io);

    const lock = dir.createFile(io, OWNER_LOCK_FILE, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.FileRpcDirAlreadyOwned,
        else => return err,
    };
    errdefer lock.close(io);

    var buf: [128]u8 = undefined;
    // pid written as JSON string to reuse findJsonString (file's minimal parser only
    // recognizes string values).
    const body = std.fmt.bufPrint(&buf, "{{\"pid\":\"{d}\",\"claimed_at_ns\":\"{d}\"}}", .{
        ownerPid(),
        @import("zenit_time").nanoTimestamp(io),
    }) catch unreachable;
    // Written whole, then renamed into place: readers never see it empty.
    const tmp_name = OWNER_FILE ++ ".tmp";
    {
        const f = try dir.createFile(io, tmp_name, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, body);
    }
    try dir.rename(tmp_name, dir, OWNER_FILE, io);
    return lock;
}

fn parseOwnerPid(text: []const u8) ?OwnerPid {
    const pid_str = findJsonString(text, "pid") orelse return null;
    return std.fmt.parseInt(OwnerPid, pid_str, 10) catch null;
}

fn runFileRpcServer(queue: *CommandQueue, rpc_dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(queue.io, rpc_dir);
    // Held (never closed) until the process exits: that releases ownership.
    _ = claimFileRpcOwnership(queue.io, rpc_dir) catch |err| switch (err) {
        error.FileRpcDirAlreadyOwned => {
            std.debug.print(
                "[test_harness] REFUSING to serve file RPC: {s} is already owned by a live " ++
                    "server instance (see its owner.json). Two servers on one dir answer " ++
                    "requests at random — set a unique ZENIT_E2E_FILE_RPC_DIR per run.\n",
                .{rpc_dir},
            );
            return;
        },
        else => return err,
    };
    std.debug.print("[test_harness] File RPC server listening at {s} (owner pid {d})\n", .{ rpc_dir, ownerPid() });

    while (true) {
        try processFileRpcRequests(queue, rpc_dir);
        try std.Io.sleep(queue.io, .fromNanoseconds(FILE_RPC_POLL_MS * std.time.ns_per_ms), .awake);
    }
}

fn processFileRpcRequests(queue: *CommandQueue, rpc_dir: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(queue.io, rpc_dir, .{ .iterate = true });
    defer dir.close(queue.io);

    var iter = dir.iterate();
    while (try iter.next(queue.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "req-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        handleFileRpcRequest(queue, rpc_dir, entry.name) catch |err| {
            std.debug.print("[test_harness] file RPC request error for {s}: {}\n", .{ entry.name, err });
        };
    }
}

fn handleFileRpcRequest(queue: *CommandQueue, rpc_dir: []const u8, entry_name: []const u8) !void {
    if (entry_name.len <= 9) return;
    const id = entry_name[4 .. entry_name.len - 5];

    var dir = try std.Io.Dir.cwd().openDir(queue.io, rpc_dir, .{});
    defer dir.close(queue.io);

    var work_name_buf: [128]u8 = undefined;
    const work_name = try std.fmt.bufPrint(&work_name_buf, "wrk-{s}.json", .{id});
    dir.rename(entry_name, dir, work_name, queue.io) catch return;
    defer dir.deleteFile(queue.io, work_name) catch {};

    const req_text = try readFileCompat(dir, queue.io, work_name, std.heap.page_allocator);
    defer std.heap.page_allocator.free(req_text);

    const method = findJsonString(req_text, "method") orelse "GET";
    const path = findJsonString(req_text, "path") orelse "/health";
    const body_heap = findJsonStringLarge(req_text, "body_json");
    defer if (body_heap) |b| std.heap.page_allocator.free(b);
    const body = if (body_heap) |b| b else "";

    const result = dispatchRequest(queue, method, path, body);
    var res_name_buf: [128]u8 = undefined;
    const res_name = try std.fmt.bufPrint(&res_name_buf, "res-{s}.json", .{id});
    var res_tmp_name_buf: [128]u8 = undefined;
    const res_tmp_name = try std.fmt.bufPrint(&res_tmp_name_buf, "res-{s}.tmp", .{id});

    // A response file is the publication boundary of the file-RPC protocol.
    // Writing directly to `res-*.json` allowed the polling client to observe a
    // short prefix before writeFile completed.  Small health responses exposed
    // this as random `{ raw: ... }` results even though the app stayed alive.
    // Publish exactly like requests do: complete a private temp file, then
    // atomically rename it into the namespace watched by the client.
    dir.deleteFile(queue.io, res_tmp_name) catch {};
    errdefer dir.deleteFile(queue.io, res_tmp_name) catch {};
    try dir.writeFile(queue.io, .{
        .sub_path = res_tmp_name,
        .data = result.body,
    });
    try dir.rename(res_tmp_name, dir, res_name, queue.io);
}

fn dispatchRequest(queue: *CommandQueue, method: []const u8, path: []const u8, body: []const u8) RequestResult {
    if (std.mem.eql(u8, method, "GET")) {
        if (std.mem.eql(u8, path, "/health")) {
            const result = queue.submitAndWait(.{ .health = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/tree")) {
            const result = queue.submitAndWait(.{ .query_tree = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/windows")) {
            const result = queue.submitAndWait(.{ .windows = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/focused")) {
            const result = queue.submitAndWait(.{ .get_focused = {} });
            return .{ .status = 200, .body = result.getData() };
        }
    }

    if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.eql(u8, path, "/click")) {
            if (parseClick(body)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid click payload\"}" };
        }
        if (std.mem.eql(u8, path, "/mouse_down")) {
            if (parseMousePoint(body, .mouse_down)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid payload\"}" };
        }
        if (std.mem.eql(u8, path, "/mouse_move")) {
            if (parseMousePoint(body, .mouse_move)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid payload\"}" };
        }
        if (std.mem.eql(u8, path, "/pointer_leave")) {
            const result = queue.submitAndWait(.{ .pointer_leave = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/window_active")) {
            const active = findJsonBool(body, "active") orelse
                return .{ .status = 400, .body = "{\"error\":\"invalid window_active payload\"}" };
            const result = queue.submitAndWait(.{ .window_active = active });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/mouse_up")) {
            if (parseMousePoint(body, .mouse_up)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid payload\"}" };
        }
        if (std.mem.eql(u8, path, "/key_up")) {
            if (parseKeyDown(body)) |cmd| {
                const result = queue.submitAndWait(.{ .key_up = cmd.key_down });
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid key_up payload\"}" };
        }
        if (std.mem.eql(u8, path, "/key_down")) {
            if (parseKeyDown(body)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid key_down payload\"}" };
        }
        if (std.mem.eql(u8, path, "/text_input")) {
            if (parseTextInput(body, std.heap.page_allocator)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid text_input payload\"}" };
        }
        if (std.mem.eql(u8, path, "/ime_preedit")) {
            if (parseImePreedit(body, std.heap.page_allocator)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid ime_preedit payload\"}" };
        }
        if (std.mem.eql(u8, path, "/ime_commit")) {
            if (parseImeCommit(body, std.heap.page_allocator)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid ime_commit payload\"}" };
        }
        if (std.mem.eql(u8, path, "/query")) {
            if (parseQuery(body, std.heap.page_allocator)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"missing test_id\"}" };
        }
        if (std.mem.eql(u8, path, "/input_state")) {
            if (findJsonString(body, "test_id")) |test_id| {
                var payload = TestIdPayload{};
                copyTestId(test_id, &payload);
                const result = queue.submitAndWait(.{ .input_state = payload });
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"missing test_id\"}" };
        }
        if (std.mem.eql(u8, path, "/screen_pos")) {
            if (findJsonString(body, "test_id")) |test_id| {
                var payload = TestIdPayload{};
                copyTestId(test_id, &payload);
                const result = queue.submitAndWait(.{ .screen_pos = payload });
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"missing test_id\"}" };
        }
        if (std.mem.eql(u8, path, "/track_start")) {
            if (findJsonString(body, "test_id")) |test_id| {
                var payload = TestIdPayload{};
                copyTestId(test_id, &payload);
                const result = queue.submitAndWait(.{ .track_start = payload });
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"missing test_id\"}" };
        }
        if (std.mem.eql(u8, path, "/track_stop")) {
            const result = queue.submitAndWait(.{ .track_stop = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/scroll_stream")) {
            const result = queue.submitAndWait(.{ .scroll_stream = .{
                .x = @floatCast(findJsonNumber(body, "x") orelse return .{ .status = 400, .body = "{\"error\":\"x required\"}" }),
                .y = @floatCast(findJsonNumber(body, "y") orelse return .{ .status = 400, .body = "{\"error\":\"y required\"}" }),
                .step = @floatCast(findJsonNumber(body, "step") orelse 12),
                .span = @intFromFloat(@max(1, findJsonNumber(body, "span") orelse 30)),
                .count = @intFromFloat(@max(0, findJsonNumber(body, "count") orelse 0)),
                .interval_ms = @floatCast(findJsonNumber(body, "interval_ms") orelse 8.33),
                .phased = (findJsonNumber(body, "phased") orelse 0) != 0,
            } });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/scroll")) {
            if (parseScroll(body)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid scroll payload\"}" };
        }
        if (std.mem.eql(u8, path, "/resize")) {
            const w = findJsonNumber(body, "width");
            const h = findJsonNumber(body, "height");
            if (w != null and h != null and w.? >= 1 and h.? >= 1) {
                const result = queue.submitAndWait(.{ .resize_window = .{
                    .width = @intFromFloat(w.?),
                    .height = @intFromFloat(h.?),
                } });
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid resize payload\"}" };
        }
        if (std.mem.eql(u8, path, "/window")) {
            const action = findJsonString(body, "action") orelse "status";
            const command = std.meta.stringToEnum(command_queue.WindowCommand, action) orelse
                return .{ .status = 400, .body = "{\"error\":\"invalid window action\"}" };
            const result = queue.submitAndWait(.{ .window = command });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/quit")) {
            const result = queue.submitAndWait(.{ .quit_app = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/magnify")) {
            if (parseMagnify(body)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid magnify payload\"}" };
        }
        if (std.mem.eql(u8, path, "/drag")) {
            if (parseDrag(body, std.heap.page_allocator)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid drag payload\"}" };
        }
        if (std.mem.eql(u8, path, "/stats")) {
            const result = queue.submitAndWait(.{ .frame_stats = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/frames/capture/finish")) {
            const result = queue.submitAndWait(.{ .finish_frame_capture = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/frames/capture")) {
            const Payload = struct { test_id: []const u8, click_test_id: []const u8, path: []const u8, after_ms: std.json.Value };
            const parsed = std.json.parseFromSlice(Payload, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch
                return .{ .status = 400, .body = "{\"error\":\"invalid timed capture payload\"}" };
            defer parsed.deinit();
            const v = parsed.value;
            const after_ms: f64 = switch (v.after_ms) {
                .integer => |value| @floatFromInt(value),
                .float => |value| value,
                else => return .{ .status = 400, .body = "{\"error\":\"capture delay must be numeric\"}" },
            };
            if (!std.math.isFinite(after_ms) or after_ms < 1 or after_ms > 2000)
                return .{ .status = 400, .body = "{\"error\":\"invalid capture delay\"}" };
            for ([_][]const u8{ v.test_id, v.click_test_id, v.path }) |value| {
                if (value.len == 0 or value.len > 256 or std.mem.indexOfScalar(u8, value, 0) != null)
                    return .{ .status = 400, .body = "{\"error\":\"invalid capture identifier/path\"}" };
            }
            var target: TestIdPayload = .{};
            var click: TestIdPayload = .{};
            var output: TestIdPayload = .{};
            copyTestId(v.test_id, &target);
            copyTestId(v.click_test_id, &click);
            copyTestId(v.path, &output);
            if (builtin.os.tag != .windows and builtin.os.tag != .linux) return .{ .status = 400, .body = "{\"error\":\"timed capture requires Windows or Linux\"}" };
            const started = queue.submitAndWait(.{ .frames_start = .{ .target = target, .click_target = click, .capture_path = output, .capture_after_ms = after_ms } });
            if (!started.success) return .{ .status = 400, .body = started.getData() };
            // File-RPC thread waits; the UI/render thread keeps animating. No
            // clock stepping, redraw request or host-timed screenshot call.
            const began = @import("zenit_time").monotonicTimestamp(queue.io);
            while (@import("zenit_time").monotonicTimestamp(queue.io) - began < 5 * std.time.ns_per_s) {
                const sampled = queue.submitAndWait(.{ .frames_capture_read = {} });
                if (!sampled.success or std.mem.indexOf(u8, sampled.getData(), "\"ok\":true") != null)
                    return .{ .status = 200, .body = sampled.getData() };
                std.Io.sleep(queue.io, .fromNanoseconds(8 * std.time.ns_per_ms), .awake) catch return .{ .status = 503, .body = "{\"error\":\"capture canceled\"}" };
            }
            _ = queue.submitAndWait(.{ .frames_read = {} });
            return .{ .status = 408, .body = "{\"error\":\"timed frame capture timeout\"}" };
        }
        if (std.mem.eql(u8, path, "/frames/start")) {
            const FrameStart = struct { test_id: []const u8, action: ?[]const u8 = null, click_test_id: ?[]const u8 = null };
            const parsed = std.json.parseFromSlice(FrameStart, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch
                return .{ .status = 400, .body = "{\"error\":\"invalid frame observation payload\"}" };
            defer parsed.deinit();
            const id = parsed.value.test_id;
            var payload: TestIdPayload = .{};
            if (id.len == 0 or id.len > payload.buf.len) return .{ .status = 400, .body = "{\"error\":\"invalid test_id length\"}" };
            copyTestId(id, &payload);
            const action = parsed.value.action;
            if (action) |value| {
                if (!std.mem.eql(u8, value, "escape_on_enter")) return .{ .status = 400, .body = "{\"error\":\"unsupported frame action\"}" };
            }
            var click_target: ?TestIdPayload = null;
            if (parsed.value.click_test_id) |click_id| {
                var click_payload: TestIdPayload = .{};
                if (click_id.len == 0 or click_id.len > click_payload.buf.len) return .{ .status = 400, .body = "{\"error\":\"invalid click_test_id length\"}" };
                copyTestId(click_id, &click_payload);
                click_target = click_payload;
            }
            const result = queue.submitAndWait(.{ .frames_start = .{ .target = payload, .escape_on_enter = action != null, .click_target = click_target } });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/redraw")) {
            const on = std.mem.indexOf(u8, body, "\"continuous\":true") != null or std.mem.indexOf(u8, body, "\"continuous\": true") != null;
            const result = queue.submitAndWait(.{ .force_frames = on });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/clock")) {
            const step = findJsonNumber(body, "step_ms") orelse return .{ .status = 400, .body = "{\"error\":\"step_ms required\"}" };
            if (!std.math.isFinite(step) or (step != 0 and (step < 1 or step > 100))) return .{ .status = 400, .body = "{\"error\":\"invalid step_ms\"}" };
            const locked = findJsonBool(body, "locked") orelse false;
            if (locked and step == 0) return .{ .status = 400, .body = "{\"error\":\"locked clock needs step_ms\"}" };
            const result = queue.submitAndWait(if (locked) .{ .animation_clock_locked = @floatCast(step) } else .{ .animation_clock = @floatCast(step) });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/clock/advance")) {
            const ms = findJsonNumber64(body, "ms") orelse return .{ .status = 400, .body = "{\"error\":\"ms required\"}" };
            if (!std.math.isFinite(ms) or ms < 0 or ms > 60_000) return .{ .status = 400, .body = "{\"error\":\"invalid ms\"}" };
            const result = queue.submitAndWait(.{ .clock_advance = ms });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/frames/read")) {
            const result = queue.submitAndWait(.{ .frames_read = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/stats/reset")) {
            const result = queue.submitAndWait(.{ .reset_timing = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/console")) {
            const after_seq = if (findJsonString(body, "after_seq")) |raw|
                std.fmt.parseInt(u64, raw, 10) catch 0
            else
                0;
            const limit_f = findJsonNumber(body, "limit") orelse 100;
            const limit: u16 = @intFromFloat(std.math.clamp(limit_f, 1, 200));
            const result = queue.submitAndWait(.{ .console_query = .{ .after_seq = after_seq, .limit = limit } });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/console/clear")) {
            const result = queue.submitAndWait(.{ .console_clear = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/screenshot")) {
            const payload = parseScreenshot(body) catch |err| return .{ .status = 400, .body = switch (err) {
                error.InvalidWindowId => "{\"error\":\"invalid-window-id\",\"code\":\"invalid-window-id\"}",
                error.InvalidPayload => "{\"error\":\"invalid screenshot payload\"}",
            } };
            const result = queue.submitAndWait(.{ .screenshot = payload });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/visual-quality")) {
            const value = findJsonString(body, "mode") orelse "status";
            const mode = std.meta.stringToEnum(@import("command_queue.zig").VisualQualityCommand, value) orelse
                return .{ .status = 400, .body = "{\"error\":\"invalid visual quality\"}" };
            const result = queue.submitAndWait(.{ .visual_quality = mode });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/sprites")) {
            const command: @import("command_queue.zig").SpritesCommand = if (findJsonBool(body, "debug") orelse false) .debug else if (findJsonBool(body, "enabled")) |on| (if (on) .enable else .disable) else .query;
            const result = queue.submitAndWait(.{ .sprites = command });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/cpu_patches")) {
            const command: @import("command_queue.zig").SpritesCommand = if (findJsonBool(body, "enabled")) |on| (if (on) .enable else .disable) else .query;
            const result = queue.submitAndWait(.{ .cpu_patches = command });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/screenshot/composited")) {
            const command = parseRecordingStart(body) orelse
                return .{ .status = 400, .body = "{\"error\":\"path required\"}" };
            const result = queue.submitAndWait(.{ .composited_screenshot = command.recording_start });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/recording/start")) {
            const command = parseRecordingStart(body) orelse
                return .{ .status = 400, .body = "{\"error\":\"invalid recording payload\"}" };
            const result = queue.submitAndWait(command);
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/recording/status")) {
            const result = queue.submitAndWait(.{ .recording_status = {} });
            return .{ .status = 200, .body = result.getData() };
        }
        if (std.mem.eql(u8, path, "/recording/stop")) {
            const result = queue.submitAndWait(.{ .recording_stop = {} });
            return .{ .status = 200, .body = result.getData() };
        }
    }

    // Custom host routes: any `/app/...` or host-prefix path not claimed by builtin routes
    // forwarded as-is to host-registered handler (GET/POST accepted).
    if (command_queue.AppRoutePayload.init(path, body)) |payload| {
        const result = queue.submitAndWait(.{ .app_route = payload });
        if (result.success) return .{ .status = 200, .body = result.getData() };
    }

    return .{ .status = 404, .body = "{\"error\":\"unknown route\"}" };
}

// ── parsers ──

fn parseClick(body: []const u8) ?TestCommand {
    if (findJsonString(body, "test_id")) |test_id| {
        var payload = TestIdPayload{};
        copyTestId(test_id, &payload);
        return .{ .click_test_id = payload };
    }
    var payload = parseMousePayload(body) orelse return null;
    if (findJsonNumber(body, "count")) |count| {
        if (!(count >= 1 and count <= 4) or @floor(count) != count) return null;
        payload.count = @intFromFloat(count);
    }
    return .{ .click = payload };
}

/// x/y plus four modifier keys. `/click` and `/mouse_*` share logic to prevent divergence.
fn parseMousePayload(body: []const u8) ?MousePayload {
    const x = findJsonNumber(body, "x") orelse return null;
    const y = findJsonNumber(body, "y") orelse return null;
    // Modifiers use key_down convention: field presence = true (value irrelevant).
    // Omitted -> all false -> identical to old `{x, y}` request behavior.
    return .{
        .x = x,
        .y = y,
        .shift = std.mem.indexOf(u8, body, "\"shift\"") != null,
        .ctrl = std.mem.indexOf(u8, body, "\"ctrl\"") != null,
        .alt = std.mem.indexOf(u8, body, "\"alt\"") != null,
        .super = std.mem.indexOf(u8, body, "\"super\"") != null or
            std.mem.indexOf(u8, body, "\"cmd\"") != null,
    };
}

fn parseMousePoint(body: []const u8, comptime kind: enum { mouse_down, mouse_move, mouse_up }) ?TestCommand {
    const payload = parseMousePayload(body) orelse return null;
    return switch (kind) {
        .mouse_down => .{ .mouse_down = payload },
        .mouse_move => .{ .mouse_move = payload },
        .mouse_up => .{ .mouse_up = payload },
    };
}

fn parseTextInput(body: []const u8, allocator: std.mem.Allocator) ?TestCommand {
    const text = findJsonStringLarge(body, "text") orelse return null;
    defer allocator.free(text);
    const payload = TextPayload.initFromText(allocator, text) catch return null;
    return .{ .text_input = payload };
}

fn parseRecordingStart(body: []const u8) ?TestCommand {
    const path = findJsonStringLarge(body, "path") orelse return null;
    defer std.heap.page_allocator.free(path);
    if (path.len == 0 or path.len > RecordingStartPayload.PATH_CAP) return null;

    const raw_fps = findJsonNumber(body, "fps") orelse 60;
    if (raw_fps < 1 or raw_fps > 120) return null;

    var payload: RecordingStartPayload = .{};
    @memcpy(payload.path[0..path.len], path);
    payload.path_len = @intCast(path.len);
    payload.fps = @intFromFloat(raw_fps);
    return .{ .recording_start = payload };
}

fn parseImePreedit(body: []const u8, allocator: std.mem.Allocator) ?TestCommand {
    const text = findJsonStringLarge(body, "text") orelse return null;
    defer allocator.free(text);
    return .{
        .ime_preedit = .{
            .text = TextPayload.initFromText(allocator, text) catch return null,
            .cursor_utf8_offset = blk: {
                const off = findJsonNumber(body, "cursor_utf8_offset") orelse 0;
                break :blk @as(u32, @intFromFloat(@max(off, 0)));
            },
        },
    };
}

fn parseImeCommit(body: []const u8, allocator: std.mem.Allocator) ?TestCommand {
    const text = findJsonStringLarge(body, "text") orelse return null;
    defer allocator.free(text);
    const payload = TextPayload.initFromText(allocator, text) catch return null;
    return .{ .ime_commit = payload };
}

fn parseKeyDown(body: []const u8) ?TestCommand {
    const key_name = findJsonString(body, "key") orelse return null;
    var payload = KeyPayload{};
    const copy_len = @min(key_name.len, payload.key_name.len);
    @memcpy(payload.key_name[0..copy_len], key_name[0..copy_len]);
    payload.key_len = @intCast(copy_len);

    if (std.mem.indexOf(u8, body, "\"cmd\"") != null or
        std.mem.indexOf(u8, body, "\"super\"") != null) payload.super = true;
    if (std.mem.indexOf(u8, body, "\"shift\"") != null) payload.shift = true;
    if (std.mem.indexOf(u8, body, "\"alt\"") != null) payload.alt = true;
    if (std.mem.indexOf(u8, body, "\"ctrl\"") != null) payload.ctrl = true;
    return .{ .key_down = payload };
}

/// phase defaults to mouse wheel (none). Trackpad gestures require explicit may_begin/began
/// -> changed... -> ended/cancelled matching real device; inertia after release uses
/// "momentum": "began" | "changed" | "ended". Unknown names return 400.
fn parseScroll(body: []const u8) ?TestCommand {
    const x = findJsonNumber(body, "x") orelse return null;
    const y = findJsonNumber(body, "y") orelse return null;
    const dx = findJsonNumber(body, "dx") orelse 0;
    const dy = findJsonNumber(body, "dy") orelse 0;
    const phase: ui.events.ScrollPhase = if (findJsonString(body, "phase")) |name|
        std.meta.stringToEnum(ui.events.ScrollPhase, name) orelse return null
    else
        .none;
    const momentum: ui.events.MomentumPhase = if (findJsonString(body, "momentum")) |name|
        std.meta.stringToEnum(ui.events.MomentumPhase, name) orelse return null
    else
        .none;
    return .{ .scroll = .{
        .x = x,
        .y = y,
        .dx = dx,
        .dy = dy,
        .phase = @backingInt(phase),
        .momentum = @backingInt(momentum),
        .shift = std.mem.indexOf(u8, body, "\"shift\"") != null,
        .ctrl = std.mem.indexOf(u8, body, "\"ctrl\"") != null,
        .alt = std.mem.indexOf(u8, body, "\"alt\"") != null,
        .super = std.mem.indexOf(u8, body, "\"cmd\"") != null or std.mem.indexOf(u8, body, "\"super\"") != null,
    } };
}

fn parseMagnify(body: []const u8) ?TestCommand {
    const x = findJsonNumber(body, "x") orelse return null;
    const y = findJsonNumber(body, "y") orelse return null;
    const magnification = findJsonNumber(body, "magnification") orelse 0;
    const phase = findJsonNumber(body, "phase") orelse 1;
    return .{ .magnify = .{
        .x = x,
        .y = y,
        .magnification = magnification,
        .phase = @intFromFloat(phase),
    } };
}

fn parseDrag(body: []const u8, allocator: std.mem.Allocator) ?TestCommand {
    const x = findJsonNumber(body, "x") orelse return null;
    const y = findJsonNumber(body, "y") orelse return null;
    const kind = findJsonNumber(body, "kind") orelse return null;
    var payload = command_queue.DragPayload{ .x = x, .y = y, .kind = @intFromFloat(kind) };
    // Must use escape-aware Large variant: multi-file drag paths are '\n'-separated,
    // findJsonString doesn't unescape, returns literal "\\n" as-is -> treated as single
    // path, only last basename shown (empirically loses first file).
    if (findJsonStringLarge(body, "paths")) |paths| {
        defer std.heap.page_allocator.free(paths);
        payload.paths = TextPayload.initFromText(allocator, paths) catch return null;
    }
    return .{ .drag = payload };
}

fn parseQuery(body: []const u8, allocator: std.mem.Allocator) ?TestCommand {
    const test_id = findJsonString(body, "test_id") orelse return null;
    const payload = TextPayload.initFromText(allocator, test_id) catch return null;
    return .{ .query_selector = payload };
}

// ── helpers ──

fn copyTestId(text: []const u8, payload: *TestIdPayload) void {
    const copy_len = @min(text.len, payload.buf.len);
    @memcpy(payload.buf[0..copy_len], text[0..copy_len]);
    payload.len = @intCast(copy_len);
}

fn findJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const key_pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, body, key_pattern) orelse return null;
    var pos = key_pos + key_pattern.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) pos += 1;
    if (pos >= body.len or body[pos] != '"') return null;
    pos += 1;
    const end = std.mem.indexOfPos(u8, body, pos, "\"") orelse return null;
    return body[pos..end];
}

fn findJsonStringLarge(body: []const u8, key: []const u8) ?[]u8 {
    var search_buf: [64]u8 = undefined;
    const key_pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, body, key_pattern) orelse return null;
    var scan = key_pos + key_pattern.len;
    while (scan < body.len and (body[scan] == ' ' or body[scan] == '\t')) scan += 1;
    if (scan >= body.len or body[scan] != '"') return null;
    const start = scan + 1;

    var end = start;
    while (end < body.len) {
        if (body[end] == '"') break;
        if (body[end] == '\\') {
            end += 2;
            continue;
        }
        end += 1;
    }
    if (end >= body.len) return null;

    const raw = body[start..end];
    const alloc = std.heap.page_allocator;

    if (std.mem.indexOf(u8, raw, "\\") == null) {
        const result = alloc.alloc(u8, raw.len) catch return null;
        @memcpy(result, raw);
        return result;
    }

    const result = alloc.alloc(u8, raw.len) catch return null;
    var out: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            const decoded: u8 = switch (next) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                '/' => '/',
                else => {
                    result[out] = raw[i];
                    out += 1;
                    i += 1;
                    continue;
                },
            };
            result[out] = decoded;
            out += 1;
            i += 2;
        } else {
            result[out] = raw[i];
            out += 1;
            i += 1;
        }
    }

    if (out < result.len) {
        const exact = alloc.alloc(u8, out) catch return result[0..out];
        @memcpy(exact, result[0..out]);
        alloc.free(result);
        return exact;
    }
    return result;
}

fn findJsonBool(body: []const u8, key: []const u8) ?bool {
    var search_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    var pos = (std.mem.indexOf(u8, body, pattern) orelse return null) + pattern.len;
    while (pos < body.len and body[pos] == ' ') pos += 1;
    if (std.mem.startsWith(u8, body[pos..], "true")) return true;
    if (std.mem.startsWith(u8, body[pos..], "false")) return false;
    return null;
}

fn findJsonNumber(body: []const u8, key: []const u8) ?f32 {
    return if (findJsonNumber64(body, key)) |v| @floatCast(v) else null;
}

fn findJsonNumber64(body: []const u8, key: []const u8) ?f64 {
    var search_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = (std.mem.indexOf(u8, body, pattern) orelse return null) + pattern.len;
    var pos = start;
    while (pos < body.len and body[pos] == ' ') pos += 1;
    if (pos >= body.len) return null;

    var end = pos;
    if (end < body.len and (body[end] == '-' or body[end] == '+')) end += 1;
    while (end < body.len and (body[end] >= '0' and body[end] <= '9' or body[end] == '.')) end += 1;
    if (end == pos) return null;

    return std.fmt.parseFloat(f64, body[pos..end]) catch null;
}

test "recording start parser validates path and target fps" {
    const cmd = parseRecordingStart("{\"path\":\"/tmp/demo recording.mp4\",\"fps\":60}") orelse
        return error.TestUnexpectedResult;
    switch (cmd) {
        .recording_start => |payload| {
            try std.testing.expectEqualStrings("/tmp/demo recording.mp4", payload.getPath());
            try std.testing.expectEqual(@as(u16, 60), payload.fps);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(parseRecordingStart("{\"path\":\"/tmp/demo.mp4\",\"fps\":0}") == null);
    try std.testing.expect(parseRecordingStart("{\"path\":\"/tmp/demo.mp4\",\"fps\":121}") == null);
}

// ── file-RPC single-owner lock (owner.lock + owner.json) ──

fn testTmpRpcDir(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..len];
}

test "file-RPC owner: 空目录首次 claim 成功并写入自身 pid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try testTmpRpcDir(&tmp, &buf);

    const lock = try claimFileRpcOwnership(std.testing.io, dir_path);
    defer lock.close(std.testing.io);

    const text = try readFileCompat(tmp.dir, std.testing.io, OWNER_FILE, std.testing.allocator);
    defer std.testing.allocator.free(text);
    const pid = parseOwnerPid(text) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(std.c.getpid(), pid);
}

test "file-RPC owner: 活 pid 持有时二次 claim 被拒绝" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try testTmpRpcDir(&tmp, &buf);

    // The first claim's lock stands for another live instance (locks belong to the open
    // file, so a second claim from this process conflicts as well).
    const lock = try claimFileRpcOwnership(std.testing.io, dir_path);
    defer lock.close(std.testing.io);
    try std.testing.expectError(error.FileRpcDirAlreadyOwned, claimFileRpcOwnership(std.testing.io, dir_path));
}

test "file-RPC owner: 持有者退出（锁释放）后可接管" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try testTmpRpcDir(&tmp, &buf);

    // Closing the lock is what process exit or a crash does.
    const first = try claimFileRpcOwnership(std.testing.io, dir_path);
    first.close(std.testing.io);
    const second = try claimFileRpcOwnership(std.testing.io, dir_path);
    defer second.close(std.testing.io);
    try std.testing.expectError(error.FileRpcDirAlreadyOwned, claimFileRpcOwnership(std.testing.io, dir_path));
}

test "file-RPC owner: 死 pid 残留被接管" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try testTmpRpcDir(&tmp, &buf);

    // macOS pid_max = 99998; 4000000 doesn't exist -> kill returns ESRCH -> detected dead.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = OWNER_FILE, .data = "{\"pid\":\"4000000\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = OWNER_LOCK_FILE, .data = "" });
    const lock = try claimFileRpcOwnership(std.testing.io, dir_path);
    defer lock.close(std.testing.io);

    const text = try readFileCompat(tmp.dir, std.testing.io, OWNER_FILE, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(std.c.getpid(), parseOwnerPid(text) orelse return error.TestUnexpectedResult);
}

test "file-RPC owner: 坏 owner.json 被接管" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try testTmpRpcDir(&tmp, &buf);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = OWNER_FILE, .data = "not json at all" });
    const lock = try claimFileRpcOwnership(std.testing.io, dir_path);
    defer lock.close(std.testing.io);
    const text = try readFileCompat(tmp.dir, std.testing.io, OWNER_FILE, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(std.c.getpid(), parseOwnerPid(text) orelse return error.TestUnexpectedResult);
}

fn parseScreenshot(body: []const u8) error{ InvalidPayload, InvalidWindowId }!@import("command_queue.zig").ScreenshotPayload {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, if (body.len == 0) "{}" else body, .{}) catch return error.InvalidPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    var payload: @import("command_queue.zig").ScreenshotPayload = .{};
    const out_path = if (parsed.value.object.get("path")) |value| switch (value) {
        .string => |text| text,
        else => return error.InvalidPayload,
    } else "/tmp/zenit_screenshot.png";
    copyTestId(out_path, &payload.path);
    if (parsed.value.object.get("window_id")) |value| {
        const id = switch (value) {
            .string => |text| text,
            else => return error.InvalidWindowId,
        };
        if (!@import("screenshot_windows.zig").Registry.validToken(id)) return error.InvalidWindowId;
        payload.window_id = .{};
        copyTestId(id, &payload.window_id.?);
    }
    return payload;
}

test "screenshot parser preserves window identity and rejects native or malformed ids" {
    try std.testing.expectEqualStrings("/tmp/zenit_screenshot.png", (try parseScreenshot("")).getText());
    const payload = try parseScreenshot("{\"path\":\"a.png\",\"window_id\":\"ab12-3\"}");
    try std.testing.expectEqualStrings("a.png", payload.getText());
    try std.testing.expectEqualStrings("ab12-3", payload.window_id.?.getText());
    try std.testing.expect((try parseScreenshot("{\"path\":\"a.png\"}")).window_id == null);
    try std.testing.expectError(error.InvalidWindowId, parseScreenshot("{\"window_id\":12}"));
    try std.testing.expectError(error.InvalidWindowId, parseScreenshot("{\"window_id\":null}"));
    try std.testing.expectError(error.InvalidWindowId, parseScreenshot("{\"window_id\":\"12\"}"));
    try std.testing.expectError(error.InvalidWindowId, parseScreenshot("{\"window_id\":\"ab-1-2\"}"));
}
