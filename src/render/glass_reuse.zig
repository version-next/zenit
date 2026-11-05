//! Cross-frame reuse of a glass composite whose backdrop did not change.
//!
//! A glass composite (backdrop_blur.tryBackdropBlur) is a pure function of the
//! pixels in its capture rect and of its own paint item. When neither changed
//! since the frame that rendered it, the composite texture that frame produced
//! is bit-identical to what a new pass would produce, so the frame draws that
//! texture again instead of ending the render pass for the capture, bank and
//! composite passes (six encoders per glass on Metal).
//!
//! `backdropKey` names that input: the glass token, every item painted before
//! it that can reach the capture rect, and the keys of earlier glass it reads.
//! An item whose pixels are not described by the paint item (an external image
//! texture) makes the glass ineligible.
const std = @import("std");
const fp = @import("command_encoder/paint_fingerprint.zig");

/// Keys of the glass composites already encoded this frame, by paint index:
/// a later glass that samples an earlier one depends on everything the earlier
/// one sampled, which lies partly outside the later capture rect.
pub const FrameKeys = struct {
    pub const capacity = 32;
    index: [capacity]u32 = undefined,
    key: [capacity]u64 = undefined,
    count: u32 = 0,

    pub fn put(self: *FrameKeys, index: usize, key: ?u64) void {
        if (self.count == capacity) return;
        self.index[self.count] = @intCast(index);
        // 0 marks an earlier glass without a key: whatever samples it cannot be keyed either.
        self.key[self.count] = key orelse 0;
        self.count += 1;
    }

    fn get(self: *const FrameKeys, index: usize) ?u64 {
        for (self.index[0..self.count], self.key[0..self.count]) |i, k| {
            if (i == index) return if (k == 0) null else k;
        }
        return null;
    }
};

/// Encoder hook (RenderCommandEncoder.glass_reuse): finds the glass token
/// being encoded in the frame's paint table and keys its backdrop. null when
/// the token is not in that table.
pub const Hook = struct {
    ctx: *anyopaque,
    key: *const fn (ctx: *anyopaque, item: *const anyopaque, capture: [4]u32, scale: f32, earlier: *const FrameKeys) ?Found,

    pub const Found = struct { index: usize, key: ?u64 };

    /// Hook over a paint table whose element type is `Item`.
    pub fn Table(comptime Item: type) type {
        return struct {
            items: []const Item,
            /// Per-frame scratch for `scan` (the frame arena).
            allocator: std.mem.Allocator,
            /// Item fingerprints the frame already computed (FrameDamage), if any.
            hashes: ?[]const u64 = null,
            scan: ?Scan = null,
            scan_failed: bool = false,

            pub fn hook(self: *@This()) Hook {
                return .{ .ctx = self, .key = keyFn };
            }

            fn keyFn(ctx: *anyopaque, item: *const anyopaque, capture: [4]u32, scale: f32, earlier: *const FrameKeys) ?Found {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                const offset = @intFromPtr(item) -% @intFromPtr(self.items.ptr);
                if (offset % @sizeOf(Item) != 0 or offset / @sizeOf(Item) >= self.items.len) return null;
                const index = offset / @sizeOf(Item);
                if (self.scan == null and !self.scan_failed) {
                    self.scan = Scan.init(self.allocator, self.items, self.hashes) catch blk: {
                        self.scan_failed = true;
                        break :blk null;
                    };
                }
                const scan = if (self.scan) |*sc| sc else return .{ .index = index, .key = null };
                return .{ .index = index, .key = backdropKey(self.items, index, capture, scale, earlier, scan) };
            }
        };
    }
};

/// Per-frame structure of a paint table shared by every glass key of the
/// frame: each opener's matching close (to skip a subtree in one step), group
/// paint bounds and item fingerprints, each computed at most once.
pub const Scan = struct {
    /// Index of the item closing the group or clip opened at i (items.len
    /// when unbalanced); undefined for other items.
    ends: []u32,
    bounds: [][4]f32,
    bounds_known: std.DynamicBitSetUnmanaged,
    hashes: []u64,
    hashes_known: std.DynamicBitSetUnmanaged,
    shared: ?[]const u64 = null,

    pub fn init(a: std.mem.Allocator, items: anytype, hashes: ?[]const u64) !Scan {
        const n = items.len;
        const ends = try a.alloc(u32, n);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(a);
        for (items, 0..) |it, i| {
            if (it.kind != .control) continue;
            if (it.control_kind == .push_clip or isBegin(it.control_kind)) {
                ends[i] = @intCast(n);
                try stack.append(a, @intCast(i));
            } else if (it.control_kind == .pop_clip or isEnd(it.control_kind)) {
                if (stack.pop()) |open| ends[open] = @intCast(i);
            }
        }
        return .{
            .ends = ends,
            .bounds = try a.alloc([4]f32, n),
            .bounds_known = try std.DynamicBitSetUnmanaged.initEmpty(a, n),
            .hashes = try a.alloc(u64, n),
            .hashes_known = try std.DynamicBitSetUnmanaged.initEmpty(a, n),
            .shared = if (hashes) |h| (if (h.len == n) h else null) else null,
        };
    }

    fn hash(self: *Scan, items: anytype, i: usize) u64 {
        if (self.shared) |h| return h[i];
        if (self.hashes_known.isSet(i)) return self.hashes[i];
        self.hashes[i] = fp.itemDigest(&items[i]);
        self.hashes_known.set(i);
        return self.hashes[i];
    }

    /// Pixels the group or clip opened at `items[i]` can change. A glass
    /// writes only its composite (glassWrittenBounds) and its children; what
    /// it reads is accounted for by its own key, mixed in by hashReaching.
    fn paintBounds(self: *Scan, items: anytype, i: usize) [4]f32 {
        if (self.bounds_known.isSet(i)) return self.bounds[i];
        const first = items[i];
        var b = fp.inkWorldBounds(first);
        if (first.control_kind == .begin_blur_layer) {
            b = fp.glassWrittenBounds(first);
            const end = @min(self.ends[i], items.len);
            var j = i + 1;
            while (j < end) : (j += 1) {
                const it = items[j];
                if (it.kind == .control and it.control_kind == .begin_blur_layer) {
                    b = unite(b, self.paintBounds(items, j));
                    j = @min(self.ends[j], items.len);
                    continue;
                }
                b = unite(b, fp.inkWorldBounds(it));
            }
        }
        self.bounds[i] = b;
        self.bounds_known.set(i);
        return b;
    }
};

/// What the composite of the glass token at `items[index]` reads inside
/// `capture` (device px): null when that cannot be described by paint items.
pub fn backdropKey(items: anytype, index: usize, capture: [4]u32, scale: f32, earlier: *const FrameKeys, scan: *Scan) ?u64 {
    if (index >= items.len or !(scale > 0)) return null;
    const region: [4]f32 = .{
        @as(f32, @floatFromInt(capture[0])) / scale,
        @as(f32, @floatFromInt(capture[1])) / scale,
        @as(f32, @floatFromInt(capture[2])) / scale,
        @as(f32, @floatFromInt(capture[3])) / scale,
    };
    const debug = debugEnabled();
    if (debug) std.debug.print("[glass-reuse] index={d} capture={any} self:{x}", .{ index, capture, scan.hash(items, index) & 0xffffff });
    defer if (debug) std.debug.print("\n", .{});
    var h = std.hash.Wyhash.init(0x676c_7275);
    h.update(std.mem.asBytes(&capture));
    h.update(std.mem.asBytes(&scale));
    const self_hash = scan.hash(items, index);
    h.update(std.mem.asBytes(&self_hash));
    // A reached effect group (opacity, rounded clip, glass) is hashed whole: its
    // contents may be laid out in the group's own space. A reached clip keeps
    // per-item tests (its contents are in window space). A group or clip that
    // cannot reach the region is skipped with everything inside it.
    var i: usize = 0;
    while (i < index) : (i += 1) {
        const it = items[i];
        const clip_opens = it.kind == .control and it.control_kind == .push_clip;
        const group_opens = it.kind == .control and isBegin(it.control_kind);
        if (clip_opens or group_opens) {
            const reach = if (group_opens) scan.paintBounds(items, i) else fp.inkWorldBounds(it);
            if (!intersects(reach, region)) {
                // Its close (or the end of the table) is the next item considered.
                i = @min(scan.ends[i], index);
                continue;
            }
            if (group_opens) {
                // Hash the group whole, up to its close or to the glass inside it.
                const end = @min(scan.ends[i] + 1, index);
                while (i < end) : (i += 1) if (!hashReaching(&h, items, i, earlier, scan)) return null;
                i -= 1;
                continue;
            }
            if (!hashReaching(&h, items, i, earlier, scan)) return null;
            continue;
        }
        if (it.kind == .control) {
            // Ends a reached clip: structure.
            const v = scan.hash(items, i);
            h.update(std.mem.asBytes(&v));
            continue;
        }
        if (intersects(fp.inkWorldBounds(it), region) and !hashReaching(&h, items, i, earlier, scan)) return null;
    }
    const key = h.final();
    // 0 is the pool's "no fingerprint".
    return if (key == 0) 1 else key;
}

/// Hash an item that can reach the region; false when its pixels are not a
/// function of the item.
fn hashReaching(h: *std.hash.Wyhash, items: anytype, i: usize, earlier: *const FrameKeys, scan: *Scan) bool {
    const it = items[i];
    const v = scan.hash(items, i);
    if (debugEnabled()) std.debug.print(" {d}:{s}/{s}:{x}", .{ i, @tagName(it.kind), @tagName(it.control_kind), v & 0xffffff });
    // External image textures can change in place under an unchanged item
    // (frame_damage treats them the same way); icon representations cannot.
    if (it.kind == .image and it.icon_rep_ptr == null) return false;
    h.update(std.mem.asBytes(&v));
    if (it.kind == .control and it.control_kind == .begin_blur_layer) {
        const k = earlier.get(i) orelse return false;
        h.update(std.mem.asBytes(&k));
    }
    return true;
}

fn unite(a: [4]f32, b: [4]f32) [4]f32 {
    if (b[2] <= 0 or b[3] <= 0) return a;
    if (a[2] <= 0 or a[3] <= 0) return b;
    const x = @min(a[0], b[0]);
    const y = @min(a[1], b[1]);
    return .{ x, y, @max(a[0] + a[2], b[0] + b[2]) - x, @max(a[1] + a[3], b[1] + b[3]) - y };
}

pub fn debugEnabled() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached == null) S.cached = @import("zenit_environment").flag("ZENIT_DEBUG_GLASS_REUSE");
    return S.cached.?;
}

fn intersects(a: [4]f32, b: [4]f32) bool {
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3];
}

fn isBegin(kind: anytype) bool {
    return switch (kind) {
        .begin_opacity_layer, .begin_blur_layer, .begin_rounded_clip => true,
        else => false,
    };
}

fn isEnd(kind: anytype) bool {
    return switch (kind) {
        .end_opacity_layer, .end_blur_layer, .end_rounded_clip => true,
        else => false,
    };
}

/// Per-glass backdrop key over the last frames that encoded it. A composite
/// is kept for reuse only once its key held for `settle_frames` consecutive
/// encodes: a glass over moving content never pins or copies a texture, nor
/// does one whose backdrop merely repeats at the turn of a scroll.
pub const History = struct {
    pub const capacity = 16;
    pub const settle_frames = 3;
    owner: [capacity]u32 = @splat(std.math.maxInt(u32)),
    key: [capacity]u64 = @splat(0),
    frame: [capacity]u64 = @splat(0),
    streak: [capacity]u32 = @splat(0),

    /// Records `key` for `owner`; whether it is the same key as the last
    /// `settle_frames - 1` encodes of this glass.
    pub fn settled(self: *History, owner: u32, key: u64, frame_index: u64) bool {
        var lru: usize = 0;
        for (0..capacity) |i| {
            if (self.owner[i] == owner) {
                self.streak[i] = if (self.key[i] == key) self.streak[i] +| 1 else 1;
                self.key[i] = key;
                self.frame[i] = frame_index;
                return self.streak[i] >= settle_frames;
            }
            if (self.frame[i] < self.frame[lru]) lru = i;
        }
        self.owner[lru] = owner;
        self.key[lru] = key;
        self.frame[lru] = frame_index;
        self.streak[lru] = 1;
        return false;
    }
};

const testing = std.testing;

test "History keeps a composite only once its key settled" {
    var hist: History = .{};
    try testing.expect(!hist.settled(7, 100, 1));
    try testing.expect(!hist.settled(7, 100, 2));
    try testing.expect(hist.settled(7, 100, 3));
    try testing.expect(hist.settled(7, 100, 4));
    // A scroll turning around shows one backdrop twice: not settled.
    try testing.expect(!hist.settled(7, 101, 5));
    try testing.expect(!hist.settled(7, 101, 6));
    try testing.expect(!hist.settled(7, 102, 7));
    // Another glass evicts the least recently encoded entry, never a live one.
    for (0..History.capacity - 1) |i| _ = hist.settled(@intCast(100 + i), 1, 8 + i);
    _ = hist.settled(999, 1, 40);
    _ = hist.settled(999, 1, 41);
    try testing.expect(hist.settled(999, 1, 42));
    try testing.expect(!hist.settled(7, 102, 43));
}

test "FrameKeys reports a keyless earlier glass as unknown" {
    var keys: FrameKeys = .{};
    keys.put(3, 42);
    keys.put(5, null);
    try testing.expectEqual(@as(?u64, 42), keys.get(3));
    try testing.expectEqual(@as(?u64, null), keys.get(5));
    try testing.expectEqual(@as(?u64, null), keys.get(9));
}
