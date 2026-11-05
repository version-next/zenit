//! Per-frame-slot scratch buffers sized by demand. Renderers rotate through
//! `slot_count` CPU-written buffers; each slot starts at `min_bytes` and grows
//! geometrically when a frame needs more, so resident GPU memory follows what
//! the UI actually draws instead of a worst-case constant.
//!
//! Growing mid-frame replaces the slot's buffer. Draws already encoded this
//! frame still reference the old one, so it is retired with the slot and
//! destroyed when the slot begins its next frame (its previous frame has then
//! completed on the GPU, the same guarantee that lets renderers overwrite a
//! slot). Callers must not assume earlier contents survive a replacement.
const std = @import("std");
const gpu = @import("gpu");
const idle_storage = @import("idle_storage.zig");

pub fn SlotBuffer(comptime slot_count: usize) type {
    return struct {
        const Self = @This();

        label: [:0]const u8,
        min_bytes: usize,
        buffers: [slot_count]?gpu.Backend.Buffer = @as([slot_count]?gpu.Backend.Buffer, @splat(null)),
        capacities: [slot_count]usize = @as([slot_count]usize, @splat(0)),
        retired: [slot_count]std.ArrayList(gpu.Backend.Buffer) = @as([slot_count]std.ArrayList(gpu.Backend.Buffer), @splat(.empty)),

        pub const Ensured = struct {
            buffer: *gpu.Backend.Buffer,
            /// The slot got a new, empty buffer: data written earlier this
            /// frame lives only in the retired one.
            replaced: bool,
        };

        pub fn init(label: [:0]const u8, min_bytes: usize) Self {
            std.debug.assert(min_bytes > 0);
            return .{ .label = label, .min_bytes = min_bytes };
        }

        /// `slot` starts a new frame; its previous frame finished on the GPU.
        pub fn beginSlot(self: *Self, slot: usize) void {
            for (self.retired[slot].items) |*buffer| buffer.destroy();
            self.retired[slot].clearRetainingCapacity();
        }

        /// A buffer for `slot` holding at least `bytes`.
        pub fn ensure(self: *Self, allocator: std.mem.Allocator, device: *gpu.Backend.Device, slot: usize, bytes: usize) !Ensured {
            if (self.buffers[slot] != null and self.capacities[slot] >= bytes) return .{ .buffer = &self.buffers[slot].?, .replaced = false };
            var size = @max(self.min_bytes, self.capacities[slot]);
            while (size < bytes) size = try std.math.mul(usize, size, 2);
            try self.retired[slot].ensureUnusedCapacity(allocator, 1);
            // The owned buffer stays valid if the replacement cannot be created.
            const replacement = try device.createBuffer(allocator, .{
                .label = self.label,
                .size = size,
                .usage = .{ .vertex = true, .map_write = true },
            });
            if (self.buffers[slot]) |old| self.retired[slot].appendAssumeCapacity(old);
            self.buffers[slot] = replacement;
            self.capacities[slot] = size;
            return .{ .buffer = &self.buffers[slot].?, .replaced = true };
        }

        pub fn capacity(self: *const Self, slot: usize) usize {
            return if (self.buffers[slot] != null) self.capacities[slot] else 0;
        }

        pub fn setVolatile(self: *Self, make_volatile: bool) void {
            idle_storage.setBuffersVolatile(&self.buffers, make_volatile);
        }

        /// Drop every buffer; the next frame regrows from `min_bytes`. Only
        /// valid while no submitted frame is still executing.
        pub fn release(self: *Self) void {
            for (0..slot_count) |slot| {
                self.beginSlot(slot);
                if (self.buffers[slot]) |*buffer| buffer.destroy();
                self.buffers[slot] = null;
                self.capacities[slot] = 0;
            }
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.release();
            for (&self.retired) |*list| list.deinit(allocator);
        }
    };
}

test "slot buffer grows by demand, retires replaced storage until its slot returns" {
    // SKIP-REASON: counts the null backend's fake buffers; real backends allocate through the same calls.
    if (gpu.backend_kind != .null_backend) return error.SkipZigTest;
    const stats = &gpu.Backend.stats;
    const created0 = stats.buffers_created;
    const destroyed0 = stats.buffers_destroyed;
    var device = gpu.Backend.Device{};
    var slots = SlotBuffer(3).init("test", 64);
    defer slots.deinit(std.testing.allocator);

    slots.beginSlot(0);
    const first = try slots.ensure(std.testing.allocator, &device, 0, 10);
    try std.testing.expect(first.replaced);
    try std.testing.expectEqual(@as(usize, 64), slots.capacity(0));
    try std.testing.expect(!(try slots.ensure(std.testing.allocator, &device, 0, 64)).replaced);
    // Growing mid-frame keeps the old buffer alive for draws already encoded.
    const grown = try slots.ensure(std.testing.allocator, &device, 0, 300);
    try std.testing.expect(grown.replaced);
    try std.testing.expectEqual(@as(usize, 512), slots.capacity(0));
    try std.testing.expectEqual(@as(usize, 1), slots.retired[0].items.len);
    try std.testing.expectEqual(destroyed0, stats.buffers_destroyed);
    // Other slots are untouched and stay empty until used.
    try std.testing.expectEqual(@as(usize, 0), slots.capacity(1));

    slots.beginSlot(0);
    try std.testing.expectEqual(@as(usize, 0), slots.retired[0].items.len);
    try std.testing.expectEqual(destroyed0 + 1, stats.buffers_destroyed);
    try std.testing.expect(!(try slots.ensure(std.testing.allocator, &device, 0, 200)).replaced);

    slots.release();
    try std.testing.expectEqual(@as(usize, 0), slots.capacity(0));
    try std.testing.expectEqual(stats.buffers_created - created0, stats.buffers_destroyed - destroyed0);
}
