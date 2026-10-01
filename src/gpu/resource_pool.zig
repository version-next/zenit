//! GPU ResourcePool, Phase 0 地基
//!
//! 跨帧 GPU 资源持有 + epoch retirement queue。配合 FrameSync 使用：
//! - 每帧 `beginFrame(epoch)` 后做工作；释放走 `release(handle)` 推进 retire 队列
//! - 队列按 ring buffer 模式，到 epoch+MAX_FRAMES_IN_FLIGHT 时真正销毁
//!
//! 不持有具体后端资源类型，payload 是 type-erased `*anyopaque`，
//! 由 caller 提供 `deinit_fn(*anyopaque)`。一个 pool 可以管理多种资源
//! （Texture/Buffer/Pipeline），handle 内带 `kind` tag 区分。
//!
//! 历史债避免（吸取 Chromium cc 经验）：
//! 1. handle 是 generational, freed 后 ABA 安全
//! 2. 释放永远延迟到 GPU 帧完成后（DISPATCH_QUEUE_FOREVER 等过）
//! 3. 不引入 atomic refcount, GUI 单线程足够；多线程用例后续再扩
//! 4. pool 自身可以被 drain（关窗时），同步等所有 retire 完成
//!
//! 用法：
//! ```
//! var pool = ResourcePool.init(allocator, 3); // 3 = MAX_FRAMES_IN_FLIGHT
//! defer pool.deinit();
//!
//! const tex_ptr = backend.createTexture(...);
//! const handle = try pool.alloc(.texture, tex_ptr, &textureDeinit);
//!
//! // 每帧：
//! pool.beginFrame();
//! ...
//! pool.release(handle); // 不立即销毁
//! pool.endFrame(); // 推进 ring；epoch-N 的 retire 真正执行 deinit_fn
//! ```

const std = @import("std");
const testing = std.testing;

pub const MAX_FRAMES_IN_FLIGHT_DEFAULT: u8 = 3;

/// 资源类型 tag，用于调试/统计；不影响 pool 行为。
pub const ResourceKind = enum(u8) {
    texture,
    buffer,
    sampler,
    pipeline,
    bind_group,
    shader,
    other,
};

pub const DeinitFn = *const fn (payload: *anyopaque) void;

/// Generational handle。32-bit index + 8-bit gen + 8-bit kind = 48 bit；pad 到 u64 对齐。
pub const ResourceHandle = packed struct(u64) {
    index: u32,
    generation: u16,
    kind: u8,
    _pad: u8 = 0,

    pub const NULL: ResourceHandle = .{ .index = 0xFFFFFFFF, .generation = 0xFFFF, .kind = 0xFF };

    pub fn isNull(self: ResourceHandle) bool {
        return self.index == 0xFFFFFFFF;
    }

    pub fn eql(a: ResourceHandle, b: ResourceHandle) bool {
        const ar: u64 = @bitCast(a);
        const br: u64 = @bitCast(b);
        return ar == br;
    }
};

const Slot = struct {
    generation: u16,
    occupied: bool,
    kind: ResourceKind,
    payload: ?*anyopaque,
    deinit_fn: ?DeinitFn,
    /// 当 occupied=false 时，此字段是 free list 链。
    next_free: u32,
};

const PendingRelease = struct {
    index: u32,
    generation: u16,
};

pub const ResourcePool = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(Slot),
    free_head: u32, // 0xFFFFFFFF = empty
    /// ring buffer，每帧一桶；endFrame 时 advance current；advance 后老桶里的资源销毁。
    pending: []std.ArrayListUnmanaged(PendingRelease),
    current_bucket: u8,
    max_frames_in_flight: u8,
    /// 累积的统计
    stats_alloc_count: u64 = 0,
    stats_release_count: u64 = 0,
    stats_deinit_count: u64 = 0,
    stats_live_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, max_frames_in_flight: u8) !ResourcePool {
        std.debug.assert(max_frames_in_flight >= 1 and max_frames_in_flight <= 8);
        const buckets = try allocator.alloc(std.ArrayListUnmanaged(PendingRelease), max_frames_in_flight);
        for (buckets) |*b| b.* = .{};
        return .{
            .allocator = allocator,
            .slots = .{},
            .free_head = 0xFFFFFFFF,
            .pending = buckets,
            .current_bucket = 0,
            .max_frames_in_flight = max_frames_in_flight,
        };
    }

    pub fn deinit(self: *ResourcePool) void {
        // 关闭：drain 所有 pending（任何顺序，反正帧已停）
        for (self.pending) |*bucket| {
            self.flushBucket(bucket);
            bucket.deinit(self.allocator);
        }
        self.allocator.free(self.pending);

        // 同时销毁仍 occupied 的资源，用户没主动 release 的也清了
        for (self.slots.items) |*slot| {
            if (slot.occupied) {
                if (slot.deinit_fn) |f| {
                    if (slot.payload) |p| f(p);
                }
                slot.occupied = false;
                self.stats_deinit_count += 1;
            }
        }
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    /// 分配 handle。
    /// payload 与 deinit_fn 都可以为 null（占位 handle）。
    pub fn alloc(
        self: *ResourcePool,
        kind: ResourceKind,
        payload_ptr: ?*anyopaque,
        deinit_fn: ?DeinitFn,
    ) !ResourceHandle {
        if (self.free_head != 0xFFFFFFFF) {
            const idx = self.free_head;
            const slot = &self.slots.items[idx];
            std.debug.assert(!slot.occupied);
            self.free_head = slot.next_free;
            slot.occupied = true;
            slot.kind = kind;
            slot.payload = payload_ptr;
            slot.deinit_fn = deinit_fn;
            self.stats_alloc_count += 1;
            self.stats_live_count += 1;
            return .{
                .index = idx,
                .generation = slot.generation,
                .kind = @intFromEnum(kind),
            };
        }

        const idx = self.slots.items.len;
        if (idx >= 0xFFFFFFFE) return error.ResourcePoolFull;
        try self.slots.append(self.allocator, .{
            .generation = 0,
            .occupied = true,
            .kind = kind,
            .payload = payload_ptr,
            .deinit_fn = deinit_fn,
            .next_free = 0xFFFFFFFF,
        });
        self.stats_alloc_count += 1;
        self.stats_live_count += 1;
        return .{
            .index = @intCast(idx),
            .generation = 0,
            .kind = @intFromEnum(kind),
        };
    }

    pub fn isValid(self: *const ResourcePool, handle: ResourceHandle) bool {
        if (handle.isNull()) return false;
        if (handle.index >= self.slots.items.len) return false;
        const slot = &self.slots.items[handle.index];
        return slot.occupied and slot.generation == handle.generation;
    }

    pub fn payload(self: *ResourcePool, handle: ResourceHandle) ?*anyopaque {
        if (!self.isValid(handle)) return null;
        return self.slots.items[handle.index].payload;
    }

    /// 提交 handle 进入 retire 队列。frame+max_frames_in_flight 后真正销毁。
    /// 重复 release / 已失效 handle 在 debug 触发断言；release 一律 no-op 容错。
    pub fn release(self: *ResourcePool, handle: ResourceHandle) void {
        if (!self.isValid(handle)) {
            std.debug.assert(false);
            return;
        }
        const idx = handle.index;
        // 立即标记 occupied=false 避免双重释放被认成有效；
        // 但 generation 在真正 deinit 后才 ++（这样 ABA 在 retire 期保持安全）。
        // 实际我们这里要立刻 ++ 才能让旧 handle isValid=false；
        // 真正的资源 payload 留在 slot 里到 retire 时再 deinit。
        const slot = &self.slots.items[idx];
        slot.generation +%= 1; // wrap allowed; gen=0xFFFF => 0 重新分配，与 fresh slot 同步
        // 注意：占位仍 true，使 retire 阶段能找到 payload；用 isValid 区分需 generation 匹配
        // 所以 handle 此刻已无效（generation 不匹配），即使 occupied=true 也不会通过 isValid。
        self.pending[self.current_bucket].append(self.allocator, .{
            .index = idx,
            .generation = slot.generation,
        }) catch {
            // OOM 时降级：立即销毁；不影响正确性，只是失去延迟保护
            self.flushSlot(idx);
        };
        self.stats_release_count += 1;
        self.stats_live_count -= 1;
    }

    /// 推进一帧：当前 bucket 内的资源还要等 max_frames_in_flight-1 帧才销毁。
    /// 调用顺序：endFrame 后再开始下一帧的工作。
    pub fn endFrame(self: *ResourcePool) void {
        // 前进 current_bucket；新 current 上的 bucket 是 max_frames_in_flight-1 帧前的，
        // 那一帧的 GPU 工作此刻已完成，可以安全销毁。
        self.current_bucket = (self.current_bucket + 1) % self.max_frames_in_flight;
        const bucket = &self.pending[self.current_bucket];
        self.flushBucket(bucket);
    }

    /// 强制回收所有 pending（关窗、设备 lost 时）
    pub fn drainAll(self: *ResourcePool) void {
        for (self.pending) |*bucket| {
            self.flushBucket(bucket);
        }
    }

    fn flushBucket(self: *ResourcePool, bucket: *std.ArrayListUnmanaged(PendingRelease)) void {
        for (bucket.items) |entry| {
            self.flushSlot(entry.index);
        }
        bucket.clearRetainingCapacity();
    }

    fn flushSlot(self: *ResourcePool, idx: u32) void {
        const slot = &self.slots.items[idx];
        if (!slot.occupied) return; // 已经销毁
        if (slot.deinit_fn) |f| {
            if (slot.payload) |p| f(p);
        }
        slot.occupied = false;
        slot.payload = null;
        slot.deinit_fn = null;
        slot.next_free = self.free_head;
        self.free_head = idx;
        self.stats_deinit_count += 1;
    }

    pub fn liveCount(self: *const ResourcePool) u32 {
        return self.stats_live_count;
    }
};

// ============================================================================
// Tests
// ============================================================================

const TestResource = struct {
    value: u32,
    deinited: *bool,

    fn deinitCb(ptr: *anyopaque) void {
        const r: *TestResource = @ptrCast(@alignCast(ptr));
        r.deinited.* = true;
    }
};

test "ResourceHandle is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(ResourceHandle));
}

test "ResourcePool alloc + isValid + payload" {
    var pool = try ResourcePool.init(testing.allocator, 3);
    defer pool.deinit();

    var deinited = false;
    var resource = TestResource{ .value = 42, .deinited = &deinited };
    const h = try pool.alloc(.texture, &resource, &TestResource.deinitCb);
    try testing.expect(pool.isValid(h));
    const p = pool.payload(h).?;
    const got: *TestResource = @ptrCast(@alignCast(p));
    try testing.expectEqual(@as(u32, 42), got.value);
    try testing.expectEqual(@as(u32, 1), pool.liveCount());

    // 释放但还没到 epoch，资源不应该 deinit
    pool.release(h);
    try testing.expect(!deinited);
    try testing.expect(!pool.isValid(h));
    try testing.expectEqual(@as(u32, 0), pool.liveCount());
}

test "ResourcePool epoch-N retirement: deinit happens after N endFrame calls" {
    var pool = try ResourcePool.init(testing.allocator, 3);
    defer pool.deinit();

    var deinited = false;
    var resource = TestResource{ .value = 1, .deinited = &deinited };
    const h = try pool.alloc(.texture, &resource, &TestResource.deinitCb);

    pool.release(h);

    // 第 1 帧 endFrame：推进到 bucket 1，bucket 1 之前是空（还没人用过），不销毁
    pool.endFrame();
    try testing.expect(!deinited);

    // 第 2 帧 endFrame：推进到 bucket 2，仍空
    pool.endFrame();
    try testing.expect(!deinited);

    // 第 3 帧 endFrame：推进回 bucket 0（即 release 时所在的 bucket），销毁
    pool.endFrame();
    try testing.expect(deinited);
}

test "ResourcePool ABA: old handle invalid after release+realloc" {
    var pool = try ResourcePool.init(testing.allocator, 3);
    defer pool.deinit();

    var d1 = false;
    var r1 = TestResource{ .value = 1, .deinited = &d1 };
    const h1 = try pool.alloc(.texture, &r1, &TestResource.deinitCb);
    pool.release(h1);

    // 立即重新 alloc，不会复用 h1 的 slot（slot 还在 pending 里），但若 free_head 有 slot 则会复用
    // 这里 h1 release 时 slot 没回 free list（要等 endFrame），所以下面 alloc 会用新 slot
    var d2 = false;
    var r2 = TestResource{ .value = 2, .deinited = &d2 };
    const h2 = try pool.alloc(.texture, &r2, &TestResource.deinitCb);

    try testing.expect(!pool.isValid(h1));
    try testing.expect(pool.isValid(h2));
    try testing.expect(!ResourceHandle.eql(h1, h2));
}

test "ResourcePool slot reuse after retire — generation differs" {
    var pool = try ResourcePool.init(testing.allocator, 2);
    defer pool.deinit();

    var d1 = false;
    var r1 = TestResource{ .value = 1, .deinited = &d1 };
    const h1 = try pool.alloc(.buffer, &r1, &TestResource.deinitCb);
    const idx1 = h1.index;
    pool.release(h1);
    pool.endFrame();
    pool.endFrame(); // 现在 slot 已回 free list

    var d2 = false;
    var r2 = TestResource{ .value = 2, .deinited = &d2 };
    const h2 = try pool.alloc(.buffer, &r2, &TestResource.deinitCb);

    try testing.expectEqual(idx1, h2.index); // 复用 slot
    try testing.expect(h1.generation != h2.generation);
    try testing.expect(!pool.isValid(h1));
    try testing.expect(pool.isValid(h2));
    try testing.expect(d1); // 第一次的资源已销毁
}

test "ResourcePool drainAll forces immediate cleanup" {
    var pool = try ResourcePool.init(testing.allocator, 4);
    defer pool.deinit();

    var d = false;
    var r = TestResource{ .value = 1, .deinited = &d };
    const h = try pool.alloc(.pipeline, &r, &TestResource.deinitCb);
    pool.release(h);
    try testing.expect(!d);

    pool.drainAll();
    try testing.expect(d);
}

test "ResourcePool deinit cleans live resources" {
    var d1 = false;
    var d2 = false;
    var r1 = TestResource{ .value = 1, .deinited = &d1 };
    var r2 = TestResource{ .value = 2, .deinited = &d2 };
    {
        var pool = try ResourcePool.init(testing.allocator, 3);
        defer pool.deinit();
        _ = try pool.alloc(.texture, &r1, &TestResource.deinitCb);
        _ = try pool.alloc(.buffer, &r2, &TestResource.deinitCb);
        // 不主动 release, deinit 应负责清理
    }
    try testing.expect(d1);
    try testing.expect(d2);
}

test "ResourcePool null payload + null deinit_fn allowed" {
    var pool = try ResourcePool.init(testing.allocator, 2);
    defer pool.deinit();

    const h = try pool.alloc(.other, null, null);
    try testing.expect(pool.isValid(h));
    try testing.expect(pool.payload(h) == null);
    pool.release(h);
    pool.endFrame();
    pool.endFrame();
    // 没崩
}
