/// command_queue，测试命令 SPSC 环形缓冲区
///
/// HTTP 线程写入命令 -> 主线程消费执行。
/// (zenit 最小子集，只支持 IME / click / type / key / query / screenshot / focused)
const std = @import("std");

pub const QUEUE_SIZE = 16;
pub const RESULT_BUF_SIZE = 256 * 1024; // 256KB JSON result

pub const TestCommand = union(enum) {
    health: void,
    /// `/click` 同样走 MousePayload，它内部合成 down+up，若不带修饰键，
    /// "⇧ 点第二个对象"这类用例会静默退化成独占选中（宿主最常用的正是本路由）。
    click: MousePayload,
    click_test_id: TestIdPayload,
    /// 修饰键随指针事件一起送：⇧ 加选、⌘ 深选、ctrl 框选反转这类交互
    /// 只有带修饰键的指针事件才测得到。默认全 false ⇒ 老用例不受影响。
    mouse_down: MousePayload,
    mouse_move: MousePayload,
    mouse_up: MousePayload,
    key_down: KeyPayload,
    text_input: TextPayload,
    ime_preedit: ImePayload,
    ime_commit: TextPayload,
    query_tree: void,
    query_selector: TextPayload,
    get_focused: void,
    screen_pos: TestIdPayload,
    screenshot: TestIdPayload,
    recording_start: RecordingStartPayload,
    recording_status: void,
    recording_stop: void,
    /// 查询 input/textarea 内部 state (buffer / cursor / preedit / phase)
    input_state: TestIdPayload,
    /// 宿主自定义路由（`/app/...`）。harness 不解释语义，
    /// 原样把 path+body 交给宿主注册的 handler，由它写回 JSON。
    /// 让下游应用这类宿主能暴露自己的诊断/夹具接口，而不必把应用逻辑塞进 zenit。
    app_route: AppRoutePayload,
    /// 查询上一帧 FrameStats（retained hits/misses/partial_repaints 等）
    frame_stats: void,
    /// 清空跨帧计时采样环，性能门禁在进入重场景后调用，
    /// 使 P95 只统计该场景自己的帧（否则会混入上一个 story 的样本）
    reset_timing: void,
    /// Incremental per-Cx Console snapshot. after_seq=0 starts at the oldest
    /// retained event; limit is clamped by the executor.
    console_query: ConsoleQueryPayload,
    console_clear: void,
    /// 滚轮事件（带修饰键）
    /// phase / momentum 按 ui.events.ScrollPhase / MomentumPhase 的序号；默认 0 = none（鼠标滚轮）
    scroll: struct { x: f32, y: f32, dx: f32, dy: f32, phase: u8 = 0, momentum: u8 = 0, shift: bool = false, ctrl: bool = false, alt: bool = false, super: bool = false },
    /// 触控板捏合事件。phase: 0=began 1=changed 2=ended 3=cancelled
    magnify: struct { x: f32, y: f32, magnification: f32, phase: u8 },
    /// 拖放事件。kind: 0=entered 1=updated 2=exited 3=dropped；paths 换行分隔
    drag: DragPayload,
    /// 调整窗口逻辑尺寸（点）。回归锚点：resize 触发 surface 重配，
    /// test-mode 下重配必须保留 CPU readback 能力，否则后续 /screenshot 全花。
    resize_window: struct { width: u32, height: u32 },
};

pub const RecordingStartPayload = struct {
    pub const PATH_CAP = 768;

    path: [PATH_CAP]u8 = undefined,
    path_len: u16 = 0,
    fps: u16 = 60,

    pub fn getPath(self: *const RecordingStartPayload) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const ConsoleQueryPayload = struct {
    after_seq: u64 = 0,
    limit: u16 = 100,
};

pub const DragPayload = struct {
    x: f32,
    y: f32,
    kind: u8,
    paths: TextPayload = .{},

    pub fn deinit(self: *DragPayload, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
    }
};

pub const ImePayload = struct {
    text: TextPayload,
    cursor_utf8_offset: u32 = 0,

    pub fn deinit(self: *ImePayload, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
    }
};

pub const TestIdPayload = struct {
    buf: [256]u8 = undefined,
    len: u16 = 0,

    pub fn getText(self: *const TestIdPayload) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const TextPayload = struct {
    inline_buf: [256]u8 = undefined,
    heap_ptr: ?[*]u8 = null,
    len: u32 = 0,

    pub fn getText(self: *const TextPayload) []const u8 {
        if (self.heap_ptr) |ptr| {
            return ptr[0..self.len];
        }
        return self.inline_buf[0..@min(self.len, 256)];
    }

    pub fn deinit(self: *TextPayload, allocator: std.mem.Allocator) void {
        if (self.heap_ptr) |ptr| {
            allocator.free(ptr[0..self.len]);
            self.heap_ptr = null;
        }
    }

    pub fn initFromText(allocator: std.mem.Allocator, text: []const u8) !TextPayload {
        var payload = TextPayload{};
        payload.len = @intCast(text.len);
        if (text.len <= 256) {
            @memcpy(payload.inline_buf[0..text.len], text);
        } else {
            const heap = try allocator.alloc(u8, text.len);
            @memcpy(heap, text);
            payload.heap_ptr = heap.ptr;
        }
        return payload;
    }
};

/// 指针事件负载。修饰键默认 false，与旧的 `{x, y}` 形态行为一致。
/// 宿主自定义路由负载。path/body 都是定长内联，避免 RPC 线程与主线程
/// 之间的所有权纠纷（与 TestIdPayload 同一取舍）。
pub const AppRoutePayload = struct {
    pub const PATH_CAP = 96;
    pub const BODY_CAP = 512;

    path: [PATH_CAP]u8 = undefined,
    path_len: u8 = 0,
    body: [BODY_CAP]u8 = undefined,
    body_len: u16 = 0,

    pub fn getPath(self: *const AppRoutePayload) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn getBody(self: *const AppRoutePayload) []const u8 {
        return self.body[0..self.body_len];
    }
    pub fn init(path: []const u8, body: []const u8) ?AppRoutePayload {
        if (path.len > PATH_CAP or body.len > BODY_CAP) return null;
        var p: AppRoutePayload = .{};
        @memcpy(p.path[0..path.len], path);
        p.path_len = @intCast(path.len);
        @memcpy(p.body[0..body.len], body);
        p.body_len = @intCast(body.len);
        return p;
    }
};

pub const MousePayload = struct {
    x: f32 = 0,
    y: f32 = 0,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn modifiers(self: *const MousePayload) @import("ui").events.Modifiers {
        return .{ .shift = self.shift, .ctrl = self.ctrl, .alt = self.alt, .super = self.super };
    }
};

pub const KeyPayload = struct {
    key_name: [32]u8 = undefined,
    key_len: u8 = 0,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn getKeyName(self: *const KeyPayload) []const u8 {
        return self.key_name[0..self.key_len];
    }
};

pub const CommandResult = struct {
    buf: [RESULT_BUF_SIZE]u8 = undefined,
    len: usize = 0,
    success: bool = true,

    pub fn getData(self: *const CommandResult) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn setJson(self: *CommandResult, json: []const u8) void {
        // 装不下显式报错：截断的 JSON 会被客户端当成功结果吞掉。
        if (json.len > self.buf.len) {
            self.setError("result JSON exceeds RESULT_BUF_SIZE");
            return;
        }
        @memcpy(self.buf[0..json.len], json);
        self.len = json.len;
        self.success = true;
    }

    pub fn setError(self: *CommandResult, msg: []const u8) void {
        const prefix = "{\"error\":\"";
        const suffix = "\"}";
        var pos: usize = 0;
        const total = prefix.len + msg.len + suffix.len;
        if (total <= self.buf.len) {
            @memcpy(self.buf[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            @memcpy(self.buf[pos..][0..msg.len], msg);
            pos += msg.len;
            @memcpy(self.buf[pos..][0..suffix.len], suffix);
            pos += suffix.len;
        }
        self.len = pos;
        self.success = false;
    }
};

pub const CommandQueue = struct {
    commands: [QUEUE_SIZE]TestCommand = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    done_event: std.Thread.ResetEvent = if (@typeInfo(std.Thread.ResetEvent) == .@"enum") .unset else .{},

    result: CommandResult = .{},

    allocator: std.mem.Allocator = std.heap.page_allocator,

    /// Called by the RPC producer immediately after publishing a command.
    /// The app main loop may be asleep in a native event pump while the
    /// display link is stopped, so polling alone is not a reliable wakeup.
    wake_fn: ?*const fn () void = null,

    pub fn setWakeCallback(self: *CommandQueue, wake_fn: *const fn () void) void {
        self.wake_fn = wake_fn;
    }

    pub fn submitAndWait(self: *CommandQueue, cmd: TestCommand) *const CommandResult {
        const tail = self.tail.load(.acquire);
        self.commands[tail % QUEUE_SIZE] = cmd;
        self.tail.store(tail + 1, .release);
        if (self.wake_fn) |wake| wake();

        self.done_event.wait();
        self.done_event.reset();

        return &self.result;
    }

    pub fn hasCommand(self: *CommandQueue) bool {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return head != tail;
    }

    pub fn dequeue(self: *CommandQueue) ?TestCommand {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        if (head == tail) return null;
        const cmd = self.commands[head % QUEUE_SIZE];
        self.head.store(head + 1, .release);
        return cmd;
    }

    pub fn signalDone(self: *CommandQueue) void {
        self.done_event.set();
    }
};

var test_wake_count = std.atomic.Value(u32).init(0);

fn countTestWake() void {
    _ = test_wake_count.fetchAdd(1, .monotonic);
}

fn consumeOneForTest(queue: *CommandQueue) void {
    while (queue.dequeue() == null) std.Thread.yield() catch {};
    queue.result.setJson("{\"ok\":true}");
    queue.signalDone();
}

test "submit publishes command and wakes event pump before waiting" {
    test_wake_count.store(0, .monotonic);
    var queue = CommandQueue{};
    queue.setWakeCallback(countTestWake);

    const consumer = try std.Thread.spawn(.{}, consumeOneForTest, .{&queue});
    const result = queue.submitAndWait(.{ .health = {} });
    consumer.join();

    try std.testing.expectEqual(@as(u32, 1), test_wake_count.load(.monotonic));
    try std.testing.expectEqualStrings("{\"ok\":true}", result.getData());
}
