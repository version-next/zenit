//! An allocator that maps large blocks straight from the system and unmaps
//! them when they are freed, passing everything else to a backing allocator.
//!
//! macOS libmalloc keeps freed large blocks in its large cache for reuse,
//! resident and dirty: they stay in the process footprint until a later large
//! allocation reuses them, and malloc_zone_pressure_relief does not release
//! them (measured: an editor that opened and parsed five 300k-line documents
//! held 31-50 MiB of "MALLOC_LARGE (empty)" for good; with MallocLargeCache=0
//! it held none, at the same CPU). Blocks this size are rare and transient
//! (reading or reparsing a whole document), so mapping them directly costs
//! nothing measurable, while per-frame scratch stays well below the threshold
//! and keeps the backing allocator's reuse.
//!
//! A block is mapped directly exactly when its length is at least
//! `threshold`; the Allocator contract passes free/resize the current length,
//! so a resize that would cross the threshold fails and the caller moves the
//! block (allocate, copy, free) to the side that owns the new length.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const LargeBlockAllocator = struct {
    backing: Allocator,
    /// Lengths from here on are mapped directly.
    threshold: usize = default_threshold,
    /// Where large blocks come from (tests substitute a counting allocator).
    large: Allocator = std.heap.page_allocator,
    /// Diagnostics: print each large allocation's length.
    trace: bool = false,
    /// With `trace`: and the allocating stack.
    trace_stacks: bool = false,

    pub const default_threshold: usize = 8 << 20;

    pub fn allocator(self: *LargeBlockAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn side(self: *LargeBlockAllocator, len: usize) Allocator {
        return if (len >= self.threshold) self.large else self.backing;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LargeBlockAllocator = @ptrCast(@alignCast(ctx));
        if (self.trace and len >= self.threshold) {
            std.debug.print("[large-block] alloc {d}\n", .{len});
            if (self.trace_stacks) std.debug.dumpCurrentStackTrace(.{ .first_address = ret_addr });
        }
        return self.side(len).rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LargeBlockAllocator = @ptrCast(@alignCast(ctx));
        if ((memory.len >= self.threshold) != (new_len >= self.threshold)) return false;
        return self.side(memory.len).rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LargeBlockAllocator = @ptrCast(@alignCast(ctx));
        if ((memory.len >= self.threshold) != (new_len >= self.threshold)) return null;
        return self.side(memory.len).rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *LargeBlockAllocator = @ptrCast(@alignCast(ctx));
        self.side(memory.len).rawFree(memory, alignment, ret_addr);
    }
};

test "large blocks come from the large side and return to it; small ones stay on the backing side" {
    var large_side = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var small_side = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var lba: LargeBlockAllocator = .{ .backing = small_side.allocator(), .large = large_side.allocator(), .threshold = 4096 };
    const a = lba.allocator();

    const small = try a.alloc(u8, 100);
    const big = try a.alloc(u8, 4096);
    try std.testing.expectEqual(@as(usize, 1), small_side.allocations);
    try std.testing.expectEqual(@as(usize, 1), large_side.allocations);
    a.free(big);
    try std.testing.expectEqual(@as(usize, 1), large_side.deallocations);
    a.free(small);
    try std.testing.expectEqual(@as(usize, 1), small_side.deallocations);
}

test "a block that grows or shrinks across the threshold moves to the other side" {
    var large_side = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var small_side = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var lba: LargeBlockAllocator = .{ .backing = small_side.allocator(), .large = large_side.allocator(), .threshold = 4096 };
    const a = lba.allocator();

    var list: std.ArrayList(u8) = .empty;
    try list.appendNTimes(a, 'x', 1000);
    try list.appendNTimes(a, 'y', 9000); // crosses: moved, not resized in place
    try std.testing.expectEqual(@as(usize, 1), large_side.allocations);
    try std.testing.expectEqual(small_side.allocations, small_side.deallocations);
    try std.testing.expectEqual(@as(u8, 'x'), list.items[999]);
    try std.testing.expectEqual(@as(u8, 'y'), list.items[9999]);

    const shrunk = try a.realloc(list.allocatedSlice(), 200); // back below
    try std.testing.expectEqual(@as(usize, 1), large_side.deallocations);
    try std.testing.expectEqual(@as(u8, 'x'), shrunk[199]);
    a.free(shrunk);
    try std.testing.expectEqual(small_side.allocations, small_side.deallocations);
}

test "resizes on one side of the threshold stay on that side" {
    var large_side = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var small_side = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var lba: LargeBlockAllocator = .{ .backing = small_side.allocator(), .large = large_side.allocator(), .threshold = 4096 };
    const a = lba.allocator();

    var big = try a.alloc(u8, 8192);
    big = try a.realloc(big, 16384);
    try std.testing.expectEqual(@as(usize, 0), small_side.allocations);
    a.free(big);
    try std.testing.expectEqual(large_side.allocations, large_side.deallocations);
}

test "neither resize nor remap crosses the threshold in place" {
    // Both sides would accept these in place (pages resize within a page):
    // only the threshold check refuses them.
    var lba: LargeBlockAllocator = .{ .backing = std.heap.page_allocator, .large = std.heap.page_allocator, .threshold = 4096 };
    const a = lba.allocator();

    const big = try a.alloc(u8, 8192);
    defer a.free(big);
    try std.testing.expect(!a.resize(big, 100));
    try std.testing.expect(a.remap(big, 100) == null);
    const small = try a.alloc(u8, 100);
    defer a.free(small);
    try std.testing.expect(!a.resize(small, 8192));
    try std.testing.expect(a.remap(small, 8192) == null);
}

/// The same policy for C libraries with their own allocator hooks
/// (tree-sitter's ts_set_allocator, SQLite's SQLITE_CONFIG_MALLOC): large
/// blocks are mapped and unmapped directly, everything else is libc's.
/// C frees carry no length, so the mapped blocks are kept in a small table;
/// while it is empty (nearly always) a free costs one atomic load more.
/// macOS only; elsewhere these are libc's functions.
pub const c_heap = struct {
    pub const threshold: usize = LargeBlockAllocator.default_threshold;
    const enabled = @import("builtin").os.tag == .macos;
    const page = std.heap.page_size_min;

    const Entry = struct { ptr: usize = 0, len: usize = 0 };
    var table: [32]Entry = @splat(.{});
    var live = std.atomic.Value(u32).init(0);
    // os_unfair_lock: a free on the main thread may wait for a parser thread
    // holding it, and must donate priority rather than spin.
    var lock: if (enabled) std.c.os_unfair_lock else void = if (enabled) .{} else {};

    extern "c" fn malloc_size(ptr: ?*const anyopaque) usize;

    fn acquire() void {
        if (enabled) std.c.os_unfair_lock_lock(&lock);
    }

    fn release() void {
        if (enabled) std.c.os_unfair_lock_unlock(&lock);
    }

    /// Length of a mapped block, null when `ptr` is libc's.
    fn mappedLen(ptr: *anyopaque) ?usize {
        if (live.load(.acquire) == 0) return null;
        acquire();
        defer release();
        for (table) |e| if (e.ptr == @intFromPtr(ptr)) return e.len;
        return null;
    }

    fn mapBlock(len: usize) ?*anyopaque {
        // A garbage size (malloc(SIZE_MAX)) would wrap when rounded to pages.
        if (len > std.math.maxInt(usize) / 2) return null;
        const mem = std.posix.mmap(null, std.mem.alignForward(usize, len, page), .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return null;
        acquire();
        defer release();
        for (&table) |*e| if (e.ptr == 0) {
            e.* = .{ .ptr = @intFromPtr(mem.ptr), .len = len };
            _ = live.fetchAdd(1, .release);
            return mem.ptr;
        };
        // Table full: give the pages back and let libc have this one.
        std.posix.munmap(mem);
        return null;
    }

    fn unmapBlock(ptr: *anyopaque, len: usize) void {
        {
            acquire();
            defer release();
            for (&table) |*e| if (e.ptr == @intFromPtr(ptr)) {
                e.* = .{};
                _ = live.fetchSub(1, .release);
                break;
            };
        }
        const base: [*]align(page) u8 = @ptrCast(@alignCast(ptr));
        std.posix.munmap(base[0..std.mem.alignForward(usize, len, page)]);
    }

    fn setLen(ptr: *anyopaque, len: usize) void {
        acquire();
        defer release();
        for (&table) |*e| if (e.ptr == @intFromPtr(ptr)) {
            e.len = len;
            return;
        };
    }

    pub fn malloc(size: usize) callconv(.c) ?*anyopaque {
        if (enabled and size >= threshold) if (mapBlock(size)) |p| return p;
        return std.c.malloc(size);
    }

    pub fn calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
        const total = std.math.mul(usize, count, size) catch return null;
        // Fresh anonymous pages are zero.
        if (enabled and total >= threshold) if (mapBlock(total)) |p| return p;
        return std.c.calloc(count, size);
    }

    pub fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const old = ptr orelse return malloc(size);
        if (!enabled) return std.c.realloc(old, size);
        if (mappedLen(old)) |len| {
            if (size >= threshold and std.mem.alignForward(usize, size, page) == std.mem.alignForward(usize, len, page)) {
                setLen(old, size);
                return old;
            }
            const new = malloc(size) orelse return null;
            @memcpy(@as([*]u8, @ptrCast(new))[0..@min(len, size)], @as([*]const u8, @ptrCast(old))[0..@min(len, size)]);
            unmapBlock(old, len);
            return new;
        }
        if (size >= threshold) {
            const new = mapBlock(size) orelse return std.c.realloc(old, size);
            const keep = @min(malloc_size(old), size);
            @memcpy(@as([*]u8, @ptrCast(new))[0..keep], @as([*]const u8, @ptrCast(old))[0..keep]);
            std.c.free(old);
            return new;
        }
        return std.c.realloc(old, size);
    }

    pub fn free(ptr: ?*anyopaque) callconv(.c) void {
        const p = ptr orelse return;
        if (enabled) if (mappedLen(p)) |len| return unmapBlock(p, len);
        std.c.free(p);
    }

    /// Usable size of a block from these functions (SQLite's xSize).
    pub fn usableSize(ptr: ?*anyopaque) callconv(.c) usize {
        const p = ptr orelse return 0;
        if (enabled) if (mappedLen(p)) |len| return len;
        return if (enabled) malloc_size(p) else 0;
    }
};

test "c_heap maps large blocks, keeps small ones in libc, and moves blocks across the threshold" {
    if (!c_heap.enabled) return error.SkipZigTest;
    const t = c_heap.threshold;
    const small: [*]u8 = @ptrCast(c_heap.malloc(64).?);
    try std.testing.expect(c_heap.mappedLen(small) == null);
    small[63] = 7;

    const big: [*]u8 = @ptrCast(c_heap.calloc(1, t).?);
    try std.testing.expectEqual(@as(?usize, t), c_heap.mappedLen(big));
    try std.testing.expectEqual(@as(u8, 0), big[t - 1]);
    try std.testing.expectEqual(t, c_heap.usableSize(big));

    // Small -> large: the bytes move into a mapped block.
    const grown: [*]u8 = @ptrCast(c_heap.realloc(small, t + 1).?);
    try std.testing.expectEqual(@as(?usize, t + 1), c_heap.mappedLen(grown));
    try std.testing.expectEqual(@as(u8, 7), grown[63]);
    // Large -> small: back to libc, contents kept.
    const shrunk: [*]u8 = @ptrCast(c_heap.realloc(grown, 64).?);
    try std.testing.expect(c_heap.mappedLen(shrunk) == null);
    try std.testing.expectEqual(@as(u8, 7), shrunk[63]);

    c_heap.free(shrunk);
    c_heap.free(big);
    try std.testing.expectEqual(@as(u32, 0), c_heap.live.load(.acquire));
}
