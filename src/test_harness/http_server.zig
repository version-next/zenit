/// http_server — 测试 HTTP 服务器（file RPC 模式）
///
/// 监听 file RPC dir，TS 客户端写 req-XXX.json，server 读后写 res-XXX.json。
/// 不用真 TCP socket 因为 zig 0.15 stdlib 上 TCP server API 不稳定。
const std = @import("std");
const build_options = @import("build_options");
const command_queue = @import("command_queue.zig");
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

const RequestResult = struct {
    status: u16,
    body: []const u8,
};

fn readFileCompat(dir: std.fs.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const f = @typeInfo(@TypeOf(std.fs.Dir.readFileAlloc)).@"fn";
    if (f.params.len >= 3 and f.params[1].type == std.mem.Allocator) {
        return dir.readFileAlloc(allocator, path, MAX_BODY_SIZE);
    } else {
        return dir.readFileAlloc(path, allocator, .limited(MAX_BODY_SIZE));
    }
}

fn fileRpcDirFromEnv() []const u8 {
    const raw = std.c.getenv("ZENIT_E2E_FILE_RPC_DIR") orelse return "";
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

/// 单主锁：一个 file-RPC 目录同一时刻只允许一个 server 实例应答。
///
/// 背景（2026-08-16 实测事故）：两份 e2e 并发共用默认目录时，server 用
/// `rename(req→wrk)` 原子抢单——每个请求被**随机一个**实例应答，query 打到
/// 另一实例的树，呈现为大面积 "test_id not found" 假失败。泄漏的旧实例
/// 同理。冲突必须显式失败，不能静默错答。
///
/// 协议：启动时以 O_EXCL 原子创建 owner.json（pid + 时间戳）。已存在则
/// 探活 owner pid：活着 → 返回 error.FileRpcDirAlreadyOwned（调用方拒绝
/// 服务并大声报错）；死了 → 视为 crash 残留，删除后重新竞争。owner.json
/// 不匹配 req-*.json 前缀，对请求扫描零干扰；进程退出不删（crash 留痕，
/// 由下一个实例探活接管）。
fn claimFileRpcOwnership(rpc_dir: []const u8) !void {
    var dir = try std.fs.cwd().openDir(rpc_dir, .{});
    defer dir.close();

    var attempts: u8 = 0;
    while (attempts < 4) : (attempts += 1) {
        if (dir.createFile(OWNER_FILE, .{ .exclusive = true })) |f| {
            defer f.close();
            var buf: [128]u8 = undefined;
            // pid 写成 JSON 字符串以复用 findJsonString（本文件的极简解析器只认字符串值）。
            const body = std.fmt.bufPrint(&buf, "{{\"pid\":\"{d}\",\"claimed_at_ns\":\"{d}\"}}", .{
                std.c.getpid(),
                std.time.nanoTimestamp(),
            }) catch unreachable;
            try f.writeAll(body);
            return;
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                const text = readFileCompat(dir, OWNER_FILE, std.heap.page_allocator) catch {
                    // 读失败（如恰好被删）：下一轮重新竞争创建。
                    continue;
                };
                defer std.heap.page_allocator.free(text);
                const pid = parseOwnerPid(text) orelse {
                    // 坏 owner.json：视为残留，接管。
                    dir.deleteFile(OWNER_FILE) catch {};
                    continue;
                };
                if (pidIsAlive(pid)) return error.FileRpcDirAlreadyOwned;
                dir.deleteFile(OWNER_FILE) catch {};
                continue;
            },
            else => return err,
        }
    }
    return error.FileRpcOwnershipRace;
}

fn parseOwnerPid(text: []const u8) ?std.c.pid_t {
    const pid_str = findJsonString(text, "pid") orelse return null;
    return std.fmt.parseInt(std.c.pid_t, pid_str, 10) catch null;
}

fn pidIsAlive(pid: std.c.pid_t) bool {
    std.posix.kill(pid, 0) catch |err| switch (err) {
        // EPERM：进程存在但无权限发信号 —— 算活着。
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

fn runFileRpcServer(queue: *CommandQueue, rpc_dir: []const u8) !void {
    try std.fs.cwd().makePath(rpc_dir);
    claimFileRpcOwnership(rpc_dir) catch |err| switch (err) {
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
    std.debug.print("[test_harness] File RPC server listening at {s} (owner pid {d})\n", .{ rpc_dir, std.c.getpid() });

    while (true) {
        try processFileRpcRequests(queue, rpc_dir);
        std.posix.nanosleep(0, FILE_RPC_POLL_MS * std.time.ns_per_ms);
    }
}

fn processFileRpcRequests(queue: *CommandQueue, rpc_dir: []const u8) !void {
    var dir = try std.fs.cwd().openDir(rpc_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
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

    var dir = try std.fs.cwd().openDir(rpc_dir, .{});
    defer dir.close();

    var work_name_buf: [128]u8 = undefined;
    const work_name = try std.fmt.bufPrint(&work_name_buf, "wrk-{s}.json", .{id});
    dir.rename(entry_name, work_name) catch return;
    defer dir.deleteFile(work_name) catch {};

    const req_text = try readFileCompat(dir, work_name, std.heap.page_allocator);
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
    dir.deleteFile(res_tmp_name) catch {};
    errdefer dir.deleteFile(res_tmp_name) catch {};
    try dir.writeFile(.{
        .sub_path = res_tmp_name,
        .data = result.body,
    });
    try dir.rename(res_tmp_name, res_name);
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
        if (std.mem.eql(u8, path, "/mouse_up")) {
            if (parseMousePoint(body, .mouse_up)) |cmd| {
                const result = queue.submitAndWait(cmd);
                return .{ .status = 200, .body = result.getData() };
            }
            return .{ .status = 400, .body = "{\"error\":\"invalid payload\"}" };
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
            const out_path = findJsonString(body, "path") orelse "/tmp/zenit_screenshot.png";
            var payload = TestIdPayload{};
            copyTestId(out_path, &payload);
            const result = queue.submitAndWait(.{ .screenshot = payload });
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

    // 宿主自定义路由：任何未被内建路由认领的 `/app/...` 或宿主前缀路径，
    // 原样转交给宿主注册的 handler（GET/POST 都接受）。
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
    return .{ .click = parseMousePayload(body) orelse return null };
}

/// x/y + 四个修饰键。`/click` 与 `/mouse_*` 共用，避免两份判定逻辑漂移。
fn parseMousePayload(body: []const u8) ?MousePayload {
    const x = findJsonNumber(body, "x") orelse return null;
    const y = findJsonNumber(body, "y") orelse return null;
    // 修饰键沿用 key_down 的约定：字段出现即为 true（值不参与判定）。
    // 省略时全 false ⇒ 与旧的 `{x, y}` 请求行为完全一致。
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

fn parseScroll(body: []const u8) ?TestCommand {
    const x = findJsonNumber(body, "x") orelse return null;
    const y = findJsonNumber(body, "y") orelse return null;
    const dx = findJsonNumber(body, "dx") orelse 0;
    const dy = findJsonNumber(body, "dy") orelse 0;
    return .{ .scroll = .{
        .x = x,
        .y = y,
        .dx = dx,
        .dy = dy,
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
    // 必须走 escape-aware 的 Large 变体：多文件拖放的 paths 是 '\n' 分隔的，
    // findJsonString 不解转义，会把字面 "\\n" 原样交出去 —— 于是整串被当成
    // 单个路径，只有最后一段的 basename 显示出来（实测丢掉第一个文件）。
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

fn findJsonNumber(body: []const u8, key: []const u8) ?f32 {
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

    return std.fmt.parseFloat(f32, body[pos..end]) catch null;
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

// ── file-RPC 单主锁（owner.json）──

fn testTmpRpcDir(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const real = try tmp.dir.realpath(".", buf);
    return real;
}

test "file-RPC owner: 空目录首次 claim 成功并写入自身 pid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try testTmpRpcDir(&tmp, &buf);

    try claimFileRpcOwnership(dir_path);

    const text = try readFileCompat(tmp.dir, OWNER_FILE, std.testing.allocator);
    defer std.testing.allocator.free(text);
    const pid = parseOwnerPid(text) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(std.c.getpid(), pid);
}

test "file-RPC owner: 活 pid 持有时二次 claim 被拒绝" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try testTmpRpcDir(&tmp, &buf);

    // 第一次 claim 写入的是本进程 pid —— 必然活着，模拟"另一个活实例持有"。
    try claimFileRpcOwnership(dir_path);
    try std.testing.expectError(error.FileRpcDirAlreadyOwned, claimFileRpcOwnership(dir_path));
}

test "file-RPC owner: 死 pid 残留被接管" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try testTmpRpcDir(&tmp, &buf);

    // macOS pid_max = 99998，4000000 必不存在 → kill 得 ESRCH → 判死。
    try tmp.dir.writeFile(.{ .sub_path = OWNER_FILE, .data = "{\"pid\":\"4000000\"}" });
    try claimFileRpcOwnership(dir_path);

    const text = try readFileCompat(tmp.dir, OWNER_FILE, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(std.c.getpid(), parseOwnerPid(text) orelse return error.TestUnexpectedResult);
}

test "file-RPC owner: 坏 owner.json 被接管" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try testTmpRpcDir(&tmp, &buf);

    try tmp.dir.writeFile(.{ .sub_path = OWNER_FILE, .data = "not json at all" });
    try claimFileRpcOwnership(dir_path);
    const text = try readFileCompat(tmp.dir, OWNER_FILE, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(std.c.getpid(), parseOwnerPid(text) orelse return error.TestUnexpectedResult);
}
