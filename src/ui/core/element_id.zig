//! Generational ElementId, Phase 0 地基
//!
//! 替代跨帧持有 *Node 的 use-after-free 风险源。每个 ElementId 是
//! u32（高 8 位 generation + 低 24 位 index）。free 时 generation++，
//! 陈旧持有者下一帧解引用即检测到。
//!
//! 设计参考：Bevy ECS Entity / generational_arena / slotmap 模式。
//! 不绑定具体 payload, SlotMap(T) 在外层 wrap。
//!
//! 容量：24-bit index = 16M slot；8-bit generation = 256 次复用后回卷
//! （回卷时该 slot 永久失效，避免 ABA）。

const std = @import("std");
const testing = std.testing;

const INDEX_BITS: u5 = 24;
const GEN_BITS: u5 = 8;
const INDEX_MASK: u32 = (1 << INDEX_BITS) - 1;
const GEN_MASK: u32 = ((1 << GEN_BITS) - 1) << INDEX_BITS;

pub const MAX_INDEX: u32 = INDEX_MASK; // 16,777,215
pub const MAX_GEN: u8 = (1 << GEN_BITS) - 1; // 255

/// 32-bit generational handle。NULL = std.math.maxInt(u32)（generation=255, index=MAX_INDEX）。
/// 实践中 index=MAX_INDEX 永不被分配（capacity check），所以 NULL 与有效 id 不会碰撞。
pub const ElementId = packed struct(u32) {
    index: u24,
    generation: u8,

    pub const NULL: ElementId = .{ .index = @as(u24, @intCast(MAX_INDEX)), .generation = MAX_GEN };

    pub fn raw(self: ElementId) u32 {
        return @bitCast(self);
    }

    pub fn fromRaw(value: u32) ElementId {
        return @bitCast(value);
    }

    pub fn eql(a: ElementId, b: ElementId) bool {
        return a.raw() == b.raw();
    }

    pub fn isNull(self: ElementId) bool {
        return self.eql(NULL);
    }
};

/// SlotMap(T)，按 ElementId 索引的稀疏存储。free 后 generation++，旧 id get() 返回 null。
///
/// 实现：
/// - `slots`: 紧凑数组，每个 slot 持 (generation, value | next_free)
/// - `free_head`: free list 头（u24 index，sentinel = MAX_INDEX）
///
/// 复杂度：alloc/free/get/isValid 均 O(1)。
pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            /// 当前一代号。alloc 时 occupied=true 且使用此 generation；free 时 ++ 且 occupied=false。
            generation: u8,
            occupied: bool,
            data: union {
                value: T,
                next_free: u32, // index of next free slot, MAX_INDEX = sentinel
            },
        };

        allocator: std.mem.Allocator,
        slots: std.ArrayListUnmanaged(Slot),
        free_head: u32, // MAX_INDEX = empty
        live_count: u32,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .slots = .{},
                .free_head = MAX_INDEX,
                .live_count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        /// 分配一个 slot，返回 ElementId。
        /// 失败：OOM 或 slot 数量达到 MAX_INDEX。
        pub fn alloc(self: *Self, value: T) !ElementId {
            if (self.free_head != MAX_INDEX) {
                const idx = self.free_head;
                const slot = &self.slots.items[idx];
                std.debug.assert(!slot.occupied);
                self.free_head = slot.data.next_free;
                slot.occupied = true;
                slot.data = .{ .value = value };
                self.live_count += 1;
                return .{
                    .index = @intCast(idx),
                    .generation = slot.generation,
                };
            }

            // free list 空，append 新 slot
            const idx = self.slots.items.len;
            if (idx >= MAX_INDEX) return error.SlotMapFull;

            try self.slots.append(self.allocator, .{
                .generation = 0,
                .occupied = true,
                .data = .{ .value = value },
            });
            self.live_count += 1;
            return .{
                .index = @intCast(idx),
                .generation = 0,
            };
        }

        /// 释放一个 slot。再次用同 id get 返回 null。
        /// 已释放/无效 id 调用是 no-op（容错），但 debug 下断言。
        pub fn free(self: *Self, id: ElementId) void {
            if (!self.isValid(id)) {
                std.debug.assert(false);
                return;
            }
            const idx: u32 = id.index;
            const slot = &self.slots.items[idx];
            slot.occupied = false;
            // generation 回卷到 MAX_GEN 时，该 slot 永久死亡（不再加入 free list）以避免 ABA。
            if (slot.generation == MAX_GEN) {
                // 永久退役该 slot：不入 free list；live_count-- 但其内存仍占用。
                self.live_count -= 1;
                return;
            }
            slot.generation += 1;
            slot.data = .{ .next_free = self.free_head };
            self.free_head = idx;
            self.live_count -= 1;
        }

        pub fn isValid(self: *const Self, id: ElementId) bool {
            if (id.isNull()) return false;
            const idx: u32 = id.index;
            if (idx >= self.slots.items.len) return false;
            const slot = &self.slots.items[idx];
            return slot.occupied and slot.generation == id.generation;
        }

        pub fn get(self: *Self, id: ElementId) ?*T {
            if (!self.isValid(id)) return null;
            return &self.slots.items[id.index].data.value;
        }

        pub fn getConst(self: *const Self, id: ElementId) ?*const T {
            if (!self.isValid(id)) return null;
            return &self.slots.items[id.index].data.value;
        }

        pub fn count(self: *const Self) u32 {
            return self.live_count;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ElementId pack/unpack" {
    const id: ElementId = .{ .index = 12345, .generation = 7 };
    const r = id.raw();
    const id2 = ElementId.fromRaw(r);
    try testing.expectEqual(id.index, id2.index);
    try testing.expectEqual(id.generation, id2.generation);
}

test "ElementId NULL distinct from any valid id" {
    try testing.expect(ElementId.NULL.isNull());
    const id: ElementId = .{ .index = 0, .generation = 0 };
    try testing.expect(!id.isNull());
}

test "SlotMap alloc/get/free roundtrip" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();

    const a = try sm.alloc(100);
    const b = try sm.alloc(200);
    try testing.expectEqual(@as(u32, 100), sm.get(a).?.*);
    try testing.expectEqual(@as(u32, 200), sm.get(b).?.*);
    try testing.expectEqual(@as(u32, 2), sm.count());

    sm.free(a);
    try testing.expect(sm.get(a) == null);
    try testing.expectEqual(@as(u32, 1), sm.count());
}

test "SlotMap ABA detection — old id rejected after slot reuse" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();

    const a = try sm.alloc(100);
    sm.free(a);
    const b = try sm.alloc(200);

    // b 与 a 共享同一 slot index，但 generation 不同
    try testing.expectEqual(a.index, b.index);
    try testing.expect(a.generation != b.generation);

    // 旧 id 解引用安全失败
    try testing.expect(sm.get(a) == null);
    try testing.expect(!sm.isValid(a));

    // 新 id 正常工作
    try testing.expectEqual(@as(u32, 200), sm.get(b).?.*);
    try testing.expect(sm.isValid(b));
}

test "SlotMap free list reuses slots in LIFO order" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();

    const a = try sm.alloc(1);
    const b = try sm.alloc(2);
    const c = try sm.alloc(3);

    sm.free(a);
    sm.free(c);

    const d = try sm.alloc(4);
    const e = try sm.alloc(5);

    // free 顺序 a,c -> free_head=c -> 先复用 c 再复用 a
    try testing.expectEqual(c.index, d.index);
    try testing.expectEqual(a.index, e.index);
    _ = b;
}

test "SlotMap generation overflow retires slot permanently" {
    var sm = SlotMap(u32).init(testing.allocator);
    defer sm.deinit();

    var id = try sm.alloc(1);
    // 推 generation 到 MAX_GEN
    var i: u32 = 0;
    while (i < MAX_GEN) : (i += 1) {
        sm.free(id);
        id = try sm.alloc(@intCast(i + 2));
    }
    // 此时 id.generation == MAX_GEN
    try testing.expectEqual(MAX_GEN, id.generation);

    // 再 free，slot 应永久退役
    sm.free(id);

    // 下一个 alloc 应使用新 slot index，而非复用退役的
    const next = try sm.alloc(999);
    try testing.expect(next.index != id.index);
}

test "SlotMap rejects invalid id from another map" {
    var sm1 = SlotMap(u32).init(testing.allocator);
    defer sm1.deinit();
    var sm2 = SlotMap(u32).init(testing.allocator);
    defer sm2.deinit();

    const a = try sm1.alloc(1);
    // sm2 里无任何 slot，a 在 sm2 中应失效
    try testing.expect(sm2.get(a) == null);
    try testing.expect(!sm2.isValid(a));
}

test "ElementId is exactly 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(ElementId));
}
