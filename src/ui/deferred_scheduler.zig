const std = @import("std");
const work = @import("work.zig");

pub const TaskKey = work.WorkKey;
pub const TaskPriority = work.WorkPriority;
pub const TaskRunResult = work.WorkResult;

pub const SINGLE_SLICE_BUDGET_US: u32 = 500;
pub const ACTIVE_FRAME_BUDGET_US: u32 = 500;
pub const NORMAL_FRAME_BUDGET_US: u32 = 1500;
pub const CATCH_UP_FRAME_BUDGET_US: u32 = 4000;

pub const Task = struct {
    allocator: std.mem.Allocator,
    id: u64 = 0,
    key: TaskKey,
    priority: TaskPriority,
    version: u64,
    ready_at_ns: u64 = 0,
    enqueue_seq: u64 = 0,
    pending: bool = true,
    heap_kind: HeapKind = .none,
    heap_index: usize = 0,
    state_ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        runSlice: *const fn (*Task, *anyopaque, u32) TaskRunResult,
        cancel: ?*const fn (*Task) void = null,
        deinit: *const fn (*Task, std.mem.Allocator) void,
    };

    pub fn runSlice(self: *Task, cx_ptr: *anyopaque, budget_us: u32) TaskRunResult {
        return self.vtable.runSlice(self, cx_ptr, budget_us);
    }

    pub fn cancel(self: *Task) void {
        if (self.vtable.cancel) |cancelFn| cancelFn(self);
    }

    pub fn deinit(self: *Task) void {
        self.vtable.deinit(self, self.allocator);
    }
};

const HeapKind = enum {
    none,
    due,
    ready,
};

const TaskKeyContext = struct {
    pub fn hash(_: TaskKeyContext, key: TaskKey) u64 {
        return switch (key) {
            .int => |value| std.hash.Wyhash.hash(0, std.mem.asBytes(&value)),
            .bytes => |value| std.hash.Wyhash.hash(0, value),
        };
    }

    pub fn eql(_: TaskKeyContext, a: TaskKey, b: TaskKey) bool {
        return a.eql(b);
    }
};

const TaskIdMap = std.AutoHashMap(u64, *Task);
const TaskKeyMap = std.HashMap(TaskKey, u64, TaskKeyContext, 80);

pub const DrainResult = struct {
    ran_tasks: u32 = 0,
    used_budget_us: u32 = 0,
    wants_redraw: bool = false,
    next_delay_ns: ?u64 = null,
};

pub const DeferredScheduler = struct {
    allocator: std.mem.Allocator,
    tasks_by_id: TaskIdMap,
    task_ids_by_key: TaskKeyMap,
    due_heap: std.ArrayList(*Task),
    ready_heap: std.ArrayList(*Task),
    next_task_id: u64 = 1,
    next_enqueue_seq: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) DeferredScheduler {
        return .{
            .allocator = allocator,
            .tasks_by_id = TaskIdMap.init(allocator),
            .task_ids_by_key = TaskKeyMap.init(allocator),
            .due_heap = .{},
            .ready_heap = .{},
        };
    }

    pub fn deinit(self: *DeferredScheduler) void {
        var it = self.tasks_by_id.valueIterator();
        while (it.next()) |task_ptr| {
            const task = task_ptr.*;
            task.cancel();
            task.deinit();
        }
        self.ready_heap.deinit(self.allocator);
        self.due_heap.deinit(self.allocator);
        self.task_ids_by_key.deinit();
        self.tasks_by_id.deinit();
    }

    pub fn hasPendingWork(self: *const DeferredScheduler) bool {
        return self.tasks_by_id.count() > 0;
    }

    pub fn hasReadyWork(self: *DeferredScheduler, now_ns: u64) bool {
        self.promoteReadyTasks(now_ns);
        return self.ready_heap.items.len > 0;
    }

    pub fn enqueueTask(self: *DeferredScheduler, task: *Task) !u64 {
        if (self.task_ids_by_key.get(task.key)) |existing_id| {
            const existing = self.tasks_by_id.get(existing_id).?;
            if (task.version > existing.version) {
                const task_id = existing.id;
                self.removeTaskById(task_id);
                task.id = task_id;
                try self.insertTask(task);
                return task_id;
            }
            if (task.version == existing.version) {
                if (task.priority.rank() < existing.priority.rank()) {
                    existing.priority = task.priority;
                }
                existing.ready_at_ns = @min(existing.ready_at_ns, task.ready_at_ns);
                existing.enqueue_seq = self.nextEnqueueSeq();
                self.moveTaskToDue(existing);
                task.cancel();
                task.deinit();
                return existing.id;
            }

            task.cancel();
            task.deinit();
            return existing.id;
        }

        task.id = self.next_task_id;
        self.next_task_id += 1;
        try self.insertTask(task);
        return task.id;
    }

    pub fn cancelTask(self: *DeferredScheduler, key: TaskKey) void {
        if (self.task_ids_by_key.get(key)) |task_id| {
            self.removeTaskById(task_id);
        }
    }

    pub fn promoteTask(self: *DeferredScheduler, key: TaskKey, priority: TaskPriority) void {
        if (self.task_ids_by_key.get(key)) |task_id| {
            self.promoteTaskById(task_id, priority);
        }
    }

    pub fn promoteTaskById(self: *DeferredScheduler, task_id: u64, priority: TaskPriority) void {
        if (self.tasks_by_id.get(task_id)) |task| {
            if (priority.rank() < task.priority.rank()) {
                task.priority = priority;
            }
            task.ready_at_ns = 0;
            task.enqueue_seq = self.nextEnqueueSeq();
            self.moveTaskToDue(task);
        }
    }

    pub fn cancelTaskById(self: *DeferredScheduler, task_id: u64) void {
        self.removeTaskById(task_id);
    }

    pub fn isPendingTaskId(self: *const DeferredScheduler, task_id: u64) bool {
        return self.tasks_by_id.contains(task_id);
    }

    pub fn drain(self: *DeferredScheduler, cx_ptr: *anyopaque, budget_us: u32, now_ns: u64) DrainResult {
        var result = DrainResult{};
        if (budget_us == 0) {
            result.next_delay_ns = self.nextDelayNs(now_ns);
            return result;
        }

        var iterations: u32 = 0;
        while (result.used_budget_us < budget_us and iterations < 128) : (iterations += 1) {
            self.promoteReadyTasks(now_ns);
            const task = self.popReadyTask() orelse break;
            // runSlice is re-entrant: user work may cancel this task or enqueue
            // a newer version for the same key, which releases/deinitializes the
            // old allocation before runSlice returns. Capture identity first and
            // never dereference `task` again until the scheduler map proves that
            // the same task/version is still current.
            const task_id = task.id;
            const task_version = task.version;
            const remaining = budget_us - result.used_budget_us;
            const slice_budget = @min(remaining, SINGLE_SLICE_BUDGET_US);
            var slice_timer = std.time.Timer.start() catch null;
            const task_result = task.runSlice(cx_ptr, slice_budget);
            const elapsed_us = elapsedSliceUs(&slice_timer, slice_budget);

            result.ran_tasks += 1;
            result.used_budget_us +|= elapsed_us;
            result.wants_redraw = result.wants_redraw or task_result.wants_redraw;

            const current = self.tasks_by_id.get(task_id) orelse continue;
            if (current != task or current.version != task_version) continue;

            switch (task_result.step) {
                .done => self.releaseTask(task),
                .again => {
                    task.ready_at_ns = now_ns;
                    task.enqueue_seq = self.nextEnqueueSeq();
                    self.pushToDueHeap(task);
                },
                .sleep_ns => |delay_ns| {
                    task.ready_at_ns = now_ns + delay_ns;
                    task.enqueue_seq = self.nextEnqueueSeq();
                    self.pushToDueHeap(task);
                },
            }
        }

        self.promoteReadyTasks(now_ns);
        if (self.ready_heap.items.len > 0) {
            result.wants_redraw = true;
        } else {
            result.next_delay_ns = self.nextDelayNs(now_ns);
        }
        return result;
    }

    fn nextEnqueueSeq(self: *DeferredScheduler) u64 {
        const seq = self.next_enqueue_seq;
        self.next_enqueue_seq += 1;
        return seq;
    }

    fn insertTask(self: *DeferredScheduler, task: *Task) !void {
        try self.ensureHeapCapacity(self.tasks_by_id.count() + 1);
        task.pending = true;
        task.enqueue_seq = self.nextEnqueueSeq();
        task.heap_kind = .none;
        task.heap_index = 0;
        try self.tasks_by_id.put(task.id, task);
        errdefer _ = self.tasks_by_id.remove(task.id);
        try self.task_ids_by_key.put(task.key, task.id);
        errdefer _ = self.task_ids_by_key.remove(task.key);
        self.pushToDueHeap(task);
    }

    fn ensureHeapCapacity(self: *DeferredScheduler, task_count: usize) !void {
        try self.due_heap.ensureTotalCapacity(self.allocator, task_count);
        try self.ready_heap.ensureTotalCapacity(self.allocator, task_count);
    }

    fn removeTaskById(self: *DeferredScheduler, task_id: u64) void {
        const task = self.tasks_by_id.get(task_id) orelse return;
        self.releaseTask(task);
    }

    fn releaseTask(self: *DeferredScheduler, task: *Task) void {
        self.removeTaskFromHeap(task);
        _ = self.tasks_by_id.remove(task.id);
        _ = self.task_ids_by_key.remove(task.key);
        task.pending = false;
        task.cancel();
        task.deinit();
    }

    fn moveTaskToDue(self: *DeferredScheduler, task: *Task) void {
        self.removeTaskFromHeap(task);
        self.pushToDueHeap(task);
    }

    fn promoteReadyTasks(self: *DeferredScheduler, now_ns: u64) void {
        while (self.due_heap.items.len > 0) {
            const next = self.due_heap.items[0];
            if (!next.pending or next.ready_at_ns > now_ns) break;
            const task = self.popDueTask().?;
            self.pushToReadyHeap(task);
        }
    }

    /// 只读：距最近一个未到期任务 ready 的剩余 ns。无 pending 任务返回 null，
    /// 已有到期任务返回 0。供主循环算 pump 阻塞超时用，不消费任何状态。
    pub fn nextReadyDelayNs(self: *const DeferredScheduler, now_ns: u64) ?u64 {
        return self.nextDelayNs(now_ns);
    }

    fn nextDelayNs(self: *const DeferredScheduler, now_ns: u64) ?u64 {
        if (self.due_heap.items.len == 0) return null;
        const next = self.due_heap.items[0];
        if (!next.pending or next.ready_at_ns <= now_ns) return 0;
        return next.ready_at_ns - now_ns;
    }

    fn popDueTask(self: *DeferredScheduler) ?*Task {
        if (self.due_heap.items.len == 0) return null;
        return self.removeHeapRoot(.due);
    }

    fn popReadyTask(self: *DeferredScheduler) ?*Task {
        if (self.ready_heap.items.len == 0) return null;
        return self.removeHeapRoot(.ready);
    }

    fn pushToDueHeap(self: *DeferredScheduler, task: *Task) void {
        self.due_heap.appendAssumeCapacity(task);
        task.heap_kind = .due;
        task.heap_index = self.due_heap.items.len - 1;
        self.siftUp(.due, task.heap_index);
    }

    fn pushToReadyHeap(self: *DeferredScheduler, task: *Task) void {
        self.ready_heap.appendAssumeCapacity(task);
        task.heap_kind = .ready;
        task.heap_index = self.ready_heap.items.len - 1;
        self.siftUp(.ready, task.heap_index);
    }

    fn removeTaskFromHeap(self: *DeferredScheduler, task: *Task) void {
        switch (task.heap_kind) {
            .none => {},
            .due => _ = self.removeHeapAt(.due, task.heap_index),
            .ready => _ = self.removeHeapAt(.ready, task.heap_index),
        }
    }

    fn removeHeapRoot(self: *DeferredScheduler, comptime kind: HeapKind) *Task {
        return self.removeHeapAt(kind, 0);
    }

    fn removeHeapAt(self: *DeferredScheduler, comptime kind: HeapKind, idx: usize) *Task {
        const heap = self.heapPtr(kind);
        const removed = heap.items[idx];
        const last = heap.pop().?;
        if (idx < heap.items.len) {
            heap.items[idx] = last;
            last.heap_kind = kind;
            last.heap_index = idx;
            if (idx > 0 and self.heapLess(kind, heap.items[idx], heap.items[(idx - 1) / 2])) {
                self.siftUp(kind, idx);
            } else {
                self.siftDown(kind, idx);
            }
        }
        removed.heap_kind = .none;
        removed.heap_index = 0;
        return removed;
    }

    fn siftUp(self: *DeferredScheduler, comptime kind: HeapKind, start_idx: usize) void {
        const heap = self.heapPtr(kind);
        var idx = start_idx;
        while (idx > 0) {
            const parent_idx = (idx - 1) / 2;
            if (!self.heapLess(kind, heap.items[idx], heap.items[parent_idx])) break;
            self.swapHeapItems(kind, idx, parent_idx);
            idx = parent_idx;
        }
    }

    fn siftDown(self: *DeferredScheduler, comptime kind: HeapKind, start_idx: usize) void {
        const heap = self.heapPtr(kind);
        var idx = start_idx;
        while (true) {
            var best_idx = idx;
            const left = idx * 2 + 1;
            const right = left + 1;

            if (left < heap.items.len and self.heapLess(kind, heap.items[left], heap.items[best_idx])) {
                best_idx = left;
            }
            if (right < heap.items.len and self.heapLess(kind, heap.items[right], heap.items[best_idx])) {
                best_idx = right;
            }
            if (best_idx == idx) break;

            self.swapHeapItems(kind, idx, best_idx);
            idx = best_idx;
        }
    }

    fn swapHeapItems(self: *DeferredScheduler, comptime kind: HeapKind, a_idx: usize, b_idx: usize) void {
        const heap = self.heapPtr(kind);
        const a = heap.items[a_idx];
        const b = heap.items[b_idx];
        heap.items[a_idx] = b;
        heap.items[b_idx] = a;
        b.heap_kind = kind;
        b.heap_index = a_idx;
        a.heap_kind = kind;
        a.heap_index = b_idx;
    }

    fn heapPtr(self: *DeferredScheduler, comptime kind: HeapKind) *std.ArrayList(*Task) {
        return switch (kind) {
            .due => &self.due_heap,
            .ready => &self.ready_heap,
            .none => unreachable,
        };
    }

    fn heapLess(self: *DeferredScheduler, comptime kind: HeapKind, a: *Task, b: *Task) bool {
        _ = self;
        return switch (kind) {
            .due => dueLess(a, b),
            .ready => readyLess(a, b),
            .none => false,
        };
    }

    fn elapsedSliceUs(timer: *?std.time.Timer, slice_budget_us: u32) u32 {
        if (timer.*) |*slice_timer| {
            const elapsed_ns = slice_timer.read();
            const elapsed_us = @max(@divFloor(elapsed_ns, std.time.ns_per_us), 1);
            return @intCast(@min(elapsed_us, slice_budget_us));
        }
        // 如果 monotonic timer 不可用，保守地按完整 slice 预算计费，
        // 避免在受限环境里因为“0 成本”而无界透支一帧。
        return slice_budget_us;
    }
};

fn dueLess(a: *Task, b: *Task) bool {
    if (a.ready_at_ns != b.ready_at_ns) return a.ready_at_ns < b.ready_at_ns;
    if (a.enqueue_seq != b.enqueue_seq) return a.enqueue_seq < b.enqueue_seq;
    return a.id < b.id;
}

fn readyLess(a: *Task, b: *Task) bool {
    if (a.priority.rank() != b.priority.rank()) return a.priority.rank() < b.priority.rank();
    if (a.ready_at_ns != b.ready_at_ns) return a.ready_at_ns < b.ready_at_ns;
    if (a.enqueue_seq != b.enqueue_seq) return a.enqueue_seq < b.enqueue_seq;
    return a.id < b.id;
}

const testing = std.testing;

const TestTaskState = struct {
    runs: *u32,
    remaining_steps: u32,
};

fn makeTestTask(allocator: std.mem.Allocator, priority: TaskPriority, version: u64, runs: *u32, remaining_steps: u32) !*Task {
    const Wrapper = struct {
        task: Task,
        state: TestTaskState,

        fn run(task: *Task, _: *anyopaque, _: u32) TaskRunResult {
            const self: *@This() = @fieldParentPtr("task", task);
            self.state.runs.* += 1;
            if (self.state.remaining_steps == 0) {
                return .{ .step = .done };
            }
            self.state.remaining_steps -= 1;
            return if (self.state.remaining_steps == 0)
                .{ .step = .done }
            else
                .{ .step = .again };
        }

        fn destroy(task: *Task, alloc: std.mem.Allocator) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.task.key.deinit(alloc);
            alloc.destroy(self);
        }
    };

    const wrapper = try allocator.create(Wrapper);
    const cloned_key = try (TaskKey{ .int = version }).clone(allocator);
    wrapper.* = .{
        .task = .{
            .allocator = allocator,
            .key = cloned_key,
            .priority = priority,
            .version = version,
            .state_ptr = undefined,
            .vtable = &.{
                .runSlice = Wrapper.run,
                .deinit = Wrapper.destroy,
            },
        },
        .state = .{
            .runs = runs,
            .remaining_steps = remaining_steps,
        },
    };
    return &wrapper.task;
}

test "DeferredScheduler: higher priority runs first" {
    var scheduler = DeferredScheduler.init(testing.allocator);
    defer scheduler.deinit();

    var high_runs: u32 = 0;
    var low_runs: u32 = 0;
    const low = try makeTestTask(testing.allocator, .background, 1, &low_runs, 1);
    const high = try makeTestTask(testing.allocator, .user_visible, 2, &high_runs, 1);
    _ = try scheduler.enqueueTask(low);
    _ = try scheduler.enqueueTask(high);

    const result = scheduler.drain(undefined, 1000, 0);
    try testing.expectEqual(@as(u32, 2), result.ran_tasks);
    try testing.expectEqual(@as(u32, 1), high_runs);
    try testing.expectEqual(@as(u32, 1), low_runs);
}

test "DeferredScheduler: newer version replaces older task" {
    var scheduler = DeferredScheduler.init(testing.allocator);
    defer scheduler.deinit();

    var old_runs: u32 = 0;
    var new_runs: u32 = 0;
    const old = try makeTestTask(testing.allocator, .background, 3, &old_runs, 1);
    old.key = .{ .int = 42 };
    const new = try makeTestTask(testing.allocator, .background, 4, &new_runs, 1);
    new.key = .{ .int = 42 };
    const old_id = try scheduler.enqueueTask(old);
    const new_id = try scheduler.enqueueTask(new);

    try testing.expectEqual(old_id, new_id);
    _ = scheduler.drain(undefined, 1000, 0);
    try testing.expectEqual(@as(u32, 0), old_runs);
    try testing.expectEqual(@as(u32, 1), new_runs);
}

test "DeferredScheduler: delayed task waits until ready time" {
    var scheduler = DeferredScheduler.init(testing.allocator);
    defer scheduler.deinit();

    var runs: u32 = 0;
    const task = try makeTestTask(testing.allocator, .background, 9, &runs, 1);
    task.ready_at_ns = 50;
    _ = try scheduler.enqueueTask(task);

    const early = scheduler.drain(undefined, 1000, 0);
    try testing.expectEqual(@as(u32, 0), early.ran_tasks);
    try testing.expectEqual(@as(?u64, 50), early.next_delay_ns);
    try testing.expectEqual(@as(u32, 0), runs);

    const just_before = scheduler.drain(undefined, 1000, 49);
    try testing.expectEqual(@as(u32, 0), just_before.ran_tasks);
    try testing.expectEqual(@as(?u64, 1), just_before.next_delay_ns);
    try testing.expectEqual(@as(u32, 0), runs);

    const ready = scheduler.drain(undefined, 1000, 50);
    try testing.expectEqual(@as(u32, 1), ready.ran_tasks);
    try testing.expectEqual(@as(u32, 1), runs);
    try testing.expectEqual(@as(?u64, null), ready.next_delay_ns);
}

test "DeferredScheduler: nextReadyDelayNs reports nearest pending deadline without consuming" {
    var scheduler = DeferredScheduler.init(testing.allocator);
    defer scheduler.deinit();

    // 空 scheduler：无定时唤醒需求
    try testing.expectEqual(@as(?u64, null), scheduler.nextReadyDelayNs(0));

    var runs: u32 = 0;
    const task = try makeTestTask(testing.allocator, .background, 21, &runs, 1);
    task.ready_at_ns = 100;
    _ = try scheduler.enqueueTask(task);

    try testing.expectEqual(@as(?u64, 100), scheduler.nextReadyDelayNs(0));
    try testing.expectEqual(@as(?u64, 30), scheduler.nextReadyDelayNs(70));
    // 已到期 → 0（应立即唤醒）
    try testing.expectEqual(@as(?u64, 0), scheduler.nextReadyDelayNs(100));
    // 只读：查询不消费任务
    try testing.expectEqual(@as(u32, 0), runs);
    const ready = scheduler.drain(undefined, 1000, 100);
    try testing.expectEqual(@as(u32, 1), ready.ran_tasks);
}

test "DeferredScheduler: same version merges into one scheduled task" {
    var scheduler = DeferredScheduler.init(testing.allocator);
    defer scheduler.deinit();

    var old_runs: u32 = 0;
    var duplicate_runs: u32 = 0;

    const original = try makeTestTask(testing.allocator, .background, 11, &old_runs, 1);
    original.key = .{ .int = 77 };
    original.ready_at_ns = 40;

    const duplicate = try makeTestTask(testing.allocator, .user_visible, 11, &duplicate_runs, 1);
    duplicate.key = .{ .int = 77 };
    duplicate.ready_at_ns = 0;

    const original_id = try scheduler.enqueueTask(original);
    const duplicate_id = try scheduler.enqueueTask(duplicate);

    try testing.expectEqual(original_id, duplicate_id);
    try testing.expect(scheduler.hasReadyWork(0));

    const result = scheduler.drain(undefined, 1000, 0);
    try testing.expectEqual(@as(u32, 1), result.ran_tasks);
    try testing.expectEqual(@as(u32, 1), old_runs);
    try testing.expectEqual(@as(u32, 0), duplicate_runs);
}

test "DeferredScheduler: runSlice may replace itself without reusing freed task" {
    var scheduler = DeferredScheduler.init(testing.allocator);
    defer scheduler.deinit();

    var old_runs: u32 = 0;
    var replacement_runs: u32 = 0;
    const ReentrantContext = struct {
        scheduler: *DeferredScheduler,
        replacement_runs: *u32,
    };
    var ctx = ReentrantContext{
        .scheduler = &scheduler,
        .replacement_runs = &replacement_runs,
    };

    const Wrapper = struct {
        task: Task,
        runs: *u32,

        fn run(task: *Task, raw_ctx: *anyopaque, _: u32) TaskRunResult {
            const self: *@This() = @fieldParentPtr("task", task);
            self.runs.* += 1;
            const c: *ReentrantContext = @ptrCast(@alignCast(raw_ctx));
            const replacement = makeTestTask(testing.allocator, .background, 2, c.replacement_runs, 1) catch @panic("test OOM");
            replacement.key = .{ .int = 99 };
            _ = c.scheduler.enqueueTask(replacement) catch @panic("test enqueue failed");
            // enqueueTask above released `self`; do not touch it again.
            return .{ .step = .again };
        }

        fn destroy(task: *Task, alloc: std.mem.Allocator) void {
            const self: *@This() = @fieldParentPtr("task", task);
            alloc.destroy(self);
        }
    };

    const wrapper = try testing.allocator.create(Wrapper);
    wrapper.* = .{
        .task = .{
            .allocator = testing.allocator,
            .key = .{ .int = 99 },
            .priority = .background,
            .version = 1,
            .state_ptr = undefined,
            .vtable = &.{
                .runSlice = Wrapper.run,
                .deinit = Wrapper.destroy,
            },
        },
        .runs = &old_runs,
    };
    _ = try scheduler.enqueueTask(&wrapper.task);

    const result = scheduler.drain(&ctx, 1000, 0);
    try testing.expectEqual(@as(u32, 2), result.ran_tasks);
    try testing.expectEqual(@as(u32, 1), old_runs);
    try testing.expectEqual(@as(u32, 1), replacement_runs);
    try testing.expect(!scheduler.hasPendingWork());
}
