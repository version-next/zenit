//! Hash maps keyed by 32-bit ids (node ids, raw ElementIds).
//!
//! `std.AutoHashMap(u32, V)` hashes the key with Wyhash over its four bytes.
//! The per-frame render/sync passes look ids up several times per node
//! (scene runtime, interaction table, cache boundary set, ...), and in a Debug
//! build each Wyhash call is an un-inlined init/update/final chain with safety
//! checks. Ids need no keyed or streaming hash, only good bit
//! diffusion (std.HashMap takes the slot from the low bits and the fingerprint
//! from the top 7 bits), which the SplitMix64 finalizer gives in five
//! arithmetic ops.

const std = @import("std");

pub const U32Context = struct {
    pub fn hash(_: U32Context, key: u32) u64 {
        var x: u64 = key;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        return x ^ (x >> 31);
    }

    pub fn eql(_: U32Context, a: u32, b: u32) bool {
        return a == b;
    }
};

pub fn U32HashMap(comptime V: type) type {
    return std.HashMap(u32, V, U32Context, std.hash_map.default_max_load_percentage);
}

pub fn U32HashMapUnmanaged(comptime V: type) type {
    return std.HashMapUnmanaged(u32, V, U32Context, std.hash_map.default_max_load_percentage);
}

/// Removal budget for a long-lived std hash map whose keys are never reused,
/// such as node ids from the monotonic `Cx.nextId` counter.
///
/// std.HashMap deletes with tombstones and never reclaims them on its own: a
/// remove returns insert budget, so the table neither grows nor rehashes while
/// new ids keep replacing removed ones. Tombstones fill the free slots, and
/// every lookup or insert of an absent key probes until it reaches a free
/// slot, eventually the whole capacity. Storybook switches between Controls and
/// Button slowed by 2x within 40 round trips this way.
///
/// Call `noteRemoval` after each actual removal and rehash the map (which
/// clears every tombstone) when it returns true. Removals bound the tombstone
/// count from above, so rehashing once they reach half of the non-live slots
/// keeps at least half of those slots free. Load stays at most 80%, so a
/// rehash costs O(capacity) per at least capacity/10 removals: amortized O(1).
pub const TombstoneBudget = struct {
    removed: usize = 0,

    pub fn noteRemoval(self: *TombstoneBudget, live: usize, capacity: usize) bool {
        self.removed += 1;
        if (self.removed * 2 < capacity -| live) return false;
        self.removed = 0;
        return true;
    }

    /// The map was cleared or rehashed elsewhere; no tombstones remain.
    pub fn reset(self: *TombstoneBudget) void {
        self.removed = 0;
    }
};

/// Number of tombstone slots in a std.HashMap or std.HashMapUnmanaged (tests).
pub fn tombstoneCount(map: anytype) usize {
    const unmanaged = if (@hasField(@TypeOf(map.*), "unmanaged")) &map.unmanaged else map;
    const metadata = unmanaged.metadata orelse return 0;
    var n: usize = 0;
    for (metadata[0..unmanaged.capacity()]) |slot| {
        if (slot.isTombstone()) n += 1;
    }
    return n;
}

/// Test check: at least half of the slots not holding live entries are free.
pub fn expectFewTombstones(map: anytype) !void {
    const unmanaged = if (@hasField(@TypeOf(map.*), "unmanaged")) &map.unmanaged else map;
    try std.testing.expect(tombstoneCount(map) * 2 <= unmanaged.capacity() - unmanaged.count());
}

test "TombstoneBudget keeps a churned id map free of tombstone buildup" {
    var map = U32HashMapUnmanaged(u32){};
    defer map.deinit(std.testing.allocator);
    var budget = TombstoneBudget{};
    // Ids are never reused and pages of them come and go, as when stories
    // mount and unmount next to a long-lived part of the tree.
    for (1..301) |id| try map.put(std.testing.allocator, @intCast(id), 0);
    var next: u32 = 1000;
    for (0..200) |_| {
        const first = next;
        for (0..80) |_| {
            try map.put(std.testing.allocator, next, next);
            next += 1;
        }
        for (first..next) |id| {
            if (map.remove(@intCast(id)) and budget.noteRemoval(map.count(), map.capacity())) map.rehash(U32Context{});
            try expectFewTombstones(&map);
        }
    }
    try std.testing.expectEqual(@as(u32, 300), map.count());
}

test "U32Context spreads sequential ids over slots and fingerprints" {
    const ctx = U32Context{};
    var low_bits = std.StaticBitSet(256).empty;
    var fingerprints = std.StaticBitSet(128).empty;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const h = ctx.hash(i);
        low_bits.set(@intCast(h & 0xff));
        fingerprints.set(@intCast(h >> 57));
    }
    // A bijective mixer keeps sequential ids distinct in the slot bits and
    // reaches most fingerprint values; a weak hash (identity, plain multiply)
    // fails the fingerprint half.
    try std.testing.expect(low_bits.count() > 150);
    try std.testing.expect(fingerprints.count() > 100);
}

test "U32HashMap round-trips ids including generation-tagged raw values" {
    var map = U32HashMap(u32).init(std.testing.allocator);
    defer map.deinit();
    var i: u32 = 0;
    while (i < 2000) : (i += 1) try map.put((i << 8) | 0x5a, i);
    i = 0;
    while (i < 2000) : (i += 1) try std.testing.expectEqual(@as(?u32, i), map.get((i << 8) | 0x5a));
    try std.testing.expect(map.remove((7 << 8) | 0x5a));
    try std.testing.expectEqual(@as(?u32, null), map.get((7 << 8) | 0x5a));
}
