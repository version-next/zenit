//! Conservative damage between the presented frame and this one. No textures or
//! borrowed paint data are retained here. Commit only after the matching pixels
//! have been submitted.
//!
//! `prepare` covers flat frames only (any effect redraws everything).
//! `prepareEffects` also covers effect groups and glass, and lists the paint
//! items a damage-scissored encode may skip (`skip`).
const std = @import("std");
const paint = @import("command_encoder/paint_fingerprint.zig");
const Item = @import("command_encoder/retained_plan.zig").DamageItem;
pub const PixelRect = [4]u32;
pub const FrameDamage = struct {
    previous: std.ArrayList(Item) = .empty,
    current: std.ArrayList(Item) = .empty,
    valid: bool = false,
    pending_valid: bool = false,
    key: u64 = 0,
    pending_key: u64 = 0,
    /// prepareEffects: paint index range [first, last] of each current entry.
    ranges: std.ArrayList([2]u32) = .empty,
    /// prepareEffects: what every glass of the frame samples and writes.
    glass: std.ArrayList(Glass) = .empty,
    /// prepareEffects: entries whose pixels no paint digest describes (an
    /// external image texture can change under an unchanged item).
    volatile_bounds: std.ArrayList([4]f32) = .empty,
    /// prepareEffects: paint_fingerprint.hashCaretPaintItemInto of every item
    /// (unseeded), shared with the glass reuse keys of the same frame.
    item_hashes: std.ArrayList(u64) = .empty,
    /// prepareEffects, with a damage rect: paint index ranges [first, last]
    /// (ascending) entirely outside it. Valid until the next prepare.
    skip: std.ArrayList([2]u32) = .empty,

    /// Why the last prepareEffects returned null (full redraw).
    full_reason: FullReason = .none,
    /// prepareEffects with a damage rect: paint items in `skip`.
    skipped_items: u32 = 0,

    /// Geometry of each paint item of the last prepared frame, by digest
    /// (paint_fingerprint.itemDigest: equal digests are equal items, so equal
    /// geometry). This frame's items reuse the previous frame's value for the
    /// same digest and compute only the others (geo_cur becomes geo_prev at
    /// the next prepare, committed or not).
    geo_prev: std.ArrayList(Geo) = .empty,
    geo_cur: std.ArrayList(Geo) = .empty,
    geo_cursor: usize = 0,
    /// Items whose geometry was computed (not reused) by the last prepare.
    geo_computed: u32 = 0,
    /// Set by the host: compute every item's geometry anyway and count the
    /// reused values that differ (geo_violations).
    verify_geometry: bool = false,
    geo_violations: u64 = 0,

    pub const Glass = struct { read: [4]f32, write: [4]f32 };
    /// The bounds buildEntries reads from one item: `main` is its ink bounds
    /// (damage bounds for push_clip, written bounds for glass), `read` the
    /// pixels a glass samples.
    pub const Geo = struct { digest: u64, main: [4]f32, read: [4]f32 };
    pub const FullReason = enum { none, undescribable, no_baseline, too_large };
    /// ranges[i][1] of an entry the encoder must not skip.
    const no_skip = std.math.maxInt(u32);

    pub fn deinit(self: *FrameDamage, a: std.mem.Allocator) void {
        self.previous.deinit(a);
        self.current.deinit(a);
        self.ranges.deinit(a);
        self.glass.deinit(a);
        self.volatile_bounds.deinit(a);
        self.skip.deinit(a);
        self.item_hashes.deinit(a);
        self.geo_prev.deinit(a);
        self.geo_cur.deinit(a);
    }
    pub fn invalidate(self: *FrameDamage) void {
        self.valid = false;
        self.pending_valid = false;
    }
    pub fn commit(self: *FrameDamage) void {
        std.mem.swap(std.ArrayList(Item), &self.previous, &self.current);
        self.valid = self.pending_valid;
        self.key = self.pending_key;
    }
    /// Last balanced clip boundary before an offscreen/control effect. The
    /// candidate still needs prepare() validation before its pixels are reused.
    pub fn flatPrefixEnd(commands: anytype) usize {
        var depth: usize = 0;
        var end: usize = 0;
        for (commands, 0..) |it, i| {
            if (it.kind == .control) switch (it.control_kind) {
                .push_clip => depth += 1,
                .pop_clip => {
                    if (depth == 0) return 0;
                    depth -= 1;
                },
                else => return end,
            };
            if (depth == 0) end = i + 1;
        }
        return 0; // Entire flat frames already use frame damage.
    }
    /// null means full redraw; zero extent means copy-only. Unknown effects,
    /// mutable textures, transformed groups and dynamic noise always redraw.
    pub fn prepare(self: *FrameDamage, a: std.mem.Allocator, commands: anytype, width: u32, height: u32, scale: f32, context_key: u64) !?PixelRect {
        self.pending_valid = false;
        self.current.clearRetainingCapacity();
        if (width == 0 or height == 0 or !std.math.isFinite(scale) or scale <= 0) return null;
        var kh = std.hash.Wyhash.init(context_key);
        kh.update(std.mem.asBytes(&width));
        kh.update(std.mem.asBytes(&height));
        kh.update(std.mem.asBytes(&scale));
        self.pending_key = kh.final();
        var clips: [32][4]f32 = undefined;
        var clip_hashes: [32]u64 = undefined;
        var depth: usize = 0;
        for (commands) |it| {
            if (it.use_draw_transform or it.blend_mode != 0 or it.noise_intensity > 0) return null;
            const geom = [4]f32{ it.geom.x, it.geom.y, it.geom.w, it.geom.h };
            for (geom) |v| if (!std.math.isFinite(v)) return null;
            if (it.kind == .control) {
                switch (it.control_kind) {
                    .push_clip => {
                        if (depth == clips.len or it.clip_shape_kind > 2 or geom[2] < 0 or geom[3] < 0) return null;
                        const pad = 2 / scale;
                        var bounds = [4]f32{ geom[0] - pad, geom[1] - pad, geom[2] + 2 * pad, geom[3] + 2 * pad };
                        var h = std.hash.Wyhash.init(if (depth == 0) 0 else clip_hashes[depth - 1]);
                        paint.hashPaintItemInto(&h, it);
                        if (depth > 0) bounds = intersection(bounds, clips[depth - 1]);
                        clips[depth] = bounds;
                        clip_hashes[depth] = h.final();
                        depth += 1;
                    },
                    .pop_clip => {
                        if (depth == 0) return null;
                        depth -= 1;
                    },
                    else => return null,
                }
                continue;
            }
            switch (it.kind) {
                .rect, .shadow, .gradient => {},
                .text => {
                    if (it.text_font_family != 0 or it.text_spans != null or std.mem.indexOfAny(u8, it.text_content, "\r\n") != null) return null;
                },
                // Icon representations are immutable; external image textures
                // can change without changing a paint item and cannot be reused.
                .image => if (it.icon_rep_ptr == null) return null,
                else => return null,
            }
            var bounds = paint.damageItemBounds(it);
            for (bounds) |v| if (!std.math.isFinite(v)) return null;
            if (bounds[2] < 0 or bounds[3] < 0) return null;
            if (depth > 0) bounds = intersection(bounds, clips[depth - 1]);
            var h = std.hash.Wyhash.init(if (depth == 0) 0 else clip_hashes[depth - 1]);
            paint.hashPaintItemInto(&h, it);
            try self.current.append(a, .{ .digest = h.final(), .bounds = bounds });
        }
        if (depth != 0) return null;
        self.pending_valid = true;
        if (!self.valid or self.key != self.pending_key) return null;
        return diff(self.previous.items, self.current.items, width, height, scale);
    }

    /// Damage of a frame with effect groups and glass, in device pixels: null
    /// = full redraw, zero extent = nothing changed. Every group (opacity,
    /// rounded clip, glass) is one entry: its digest covers everything inside
    /// it, its bounds every pixel it can paint (a glass: what its composite
    /// writes and its children). Unchanged entries are found by a patience
    /// diff, so an insertion damages only itself. The rect then grows until it
    /// holds the whole backdrop of every glass it touches (sampled or
    /// written): a glass composited again under the damage scissor captures
    /// from the target, whose pixels outside the rect still show the presented
    /// frame. On success `skip` lists the entries outside the rect.
    /// `a` owns the entry lists across frames; `scratch` is per call.
    pub fn prepareEffects(self: *FrameDamage, a: std.mem.Allocator, scratch: std.mem.Allocator, commands: anytype, width: u32, height: u32, scale: f32, context_key: u64) !?PixelRect {
        self.pending_valid = false;
        self.current.clearRetainingCapacity();
        self.ranges.clearRetainingCapacity();
        self.glass.clearRetainingCapacity();
        self.volatile_bounds.clearRetainingCapacity();
        self.skip.clearRetainingCapacity();
        self.item_hashes.clearRetainingCapacity();
        self.skipped_items = 0;
        self.full_reason = .undescribable;
        std.mem.swap(std.ArrayList(Geo), &self.geo_prev, &self.geo_cur);
        self.geo_cur.clearRetainingCapacity();
        self.geo_cursor = 0;
        self.geo_computed = 0;
        if (width == 0 or height == 0 or !std.math.isFinite(scale) or scale <= 0) return null;
        var kh = std.hash.Wyhash.init(context_key ^ 0x6566);
        kh.update(std.mem.asBytes(&width));
        kh.update(std.mem.asBytes(&height));
        kh.update(std.mem.asBytes(&scale));
        self.pending_key = kh.final();
        if (!try self.buildEntries(a, commands)) {
            debugReason("unbalanced or unbounded paint", null);
            return null;
        }
        self.pending_valid = true;
        if (!self.valid or self.key != self.pending_key) {
            debugReason(if (!self.valid) "no baseline" else "context changed", null);
            self.full_reason = .no_baseline;
            return null;
        }
        self.full_reason = .none;

        var rect = changedBounds(scratch, self.previous.items, self.current.items);
        for (self.volatile_bounds.items) |b| rect = unite(rect, b);
        const changed = rect;
        if (rect[2] <= 0 or rect[3] <= 0) {
            self.skipped_items = @intCast(commands.len);
            return .{ 0, 0, 0, 0 };
        }
        // Fixpoint: rect only grows, so this ends within glass-count rounds.
        var grew = true;
        while (grew) {
            grew = false;
            for (self.glass.items) |g| {
                if (!intersects(rect, g.read) and !intersects(rect, g.write)) continue;
                const next = unite(unite(rect, g.read), g.write);
                if (!std.mem.eql(f32, &next, &rect)) {
                    rect = next;
                    grew = true;
                }
            }
        }
        var px: PixelRect = undefined;
        for ([_]u32{ width, height }, 0..) |extent, axis| {
            const maximum: f32 = @floatFromInt(extent);
            px[axis] = @intFromFloat(@floor(std.math.clamp(rect[axis] * scale - 1, 0, maximum)));
            const end: u32 = @intFromFloat(@ceil(std.math.clamp((rect[axis] + rect[axis + 2]) * scale + 1, 0, maximum)));
            px[axis + 2] = end -| px[axis];
        }
        // A rect this large repaints about as much as a full frame.
        if (@as(u64, px[2]) * px[3] * 5 > @as(u64, width) * height * 3) {
            debugReason("too large", .{ changed, rect });
            self.full_reason = .too_large;
            return null;
        }
        debugReason("partial", .{ changed, rect });
        const scissor: [4]f32 = .{
            @as(f32, @floatFromInt(px[0])) / scale,
            @as(f32, @floatFromInt(px[1])) / scale,
            @as(f32, @floatFromInt(px[2])) / scale,
            @as(f32, @floatFromInt(px[3])) / scale,
        };
        for (self.current.items, self.ranges.items) |e, r| {
            if (r[1] == no_skip or intersects(e.bounds, scissor)) continue;
            self.skipped_items += r[1] - r[0] + 1;
            if (self.skip.items.len > 0 and self.skip.items[self.skip.items.len - 1][1] + 1 == r[0]) {
                self.skip.items[self.skip.items.len - 1][1] = r[1];
            } else try self.skip.append(a, r);
        }
        return px;
    }

    /// Geometry of `item` (digest `digest`): the previous frame's value for
    /// the same digest when there is one near where the walk through the
    /// previous frame has got to, else computed.
    fn geometry(self: *FrameDamage, item: anytype, digest: u64) Geo {
        const geo = self.reused(digest) orelse computed: {
            self.geo_computed += 1;
            break :computed computeGeometry(item, digest);
        };
        if (self.verify_geometry) {
            const fresh = computeGeometry(item, digest);
            if (!std.mem.eql(f32, &fresh.main, &geo.main) or !std.mem.eql(f32, &fresh.read, &geo.read)) {
                self.geo_violations += 1;
                std.log.err("[paint-digest] digest {x} ({s}/{s}) reused geometry main={any} read={any} for an item whose geometry is main={any} read={any} (bits {x} vs {x})", .{ digest, @tagName(item.kind), @tagName(item.control_kind), geo.main, geo.read, fresh.main, fresh.read, @as(u128, @bitCast(geo.main)), @as(u128, @bitCast(fresh.main)) });
            }
        }
        self.geo_cur.appendAssumeCapacity(geo);
        return geo;
    }

    /// Previous-frame geometry with `digest`, searched from the walk position
    /// (a few entries back for insertions, further ahead for removals). On a
    /// miss the walk still advances: a changed item usually replaces one.
    fn reused(self: *FrameDamage, digest: u64) ?Geo {
        const prev = self.geo_prev.items;
        const at = self.geo_cursor;
        if (at < prev.len and prev[at].digest == digest) {
            self.geo_cursor = at + 1;
            return prev[at];
        }
        const lo = at -| 8;
        const hi = @min(prev.len, at + 33);
        var k = lo;
        while (k < hi) : (k += 1) if (prev[k].digest == digest) {
            self.geo_cursor = k + 1;
            return prev[k];
        };
        self.geo_cursor = at + 1;
        return null;
    }

    /// One entry per top-level paint item and per effect group (opacity,
    /// rounded clip, glass) with everything inside it. Clips form one stack
    /// across group boundaries (a group may pop a clip opened before it).
    /// An entry whose clip pushes and pops do not balance inside it is never
    /// skipped by the encoder: that would unbalance the encoder's clip stack.
    fn buildEntries(self: *FrameDamage, a: std.mem.Allocator, commands: anytype) !bool {
        var clips: [64][4]f32 = undefined;
        var clip_hashes: [64]u64 = undefined;
        var depth: usize = 0;
        const infinite: [4]f32 = .{ -1e9, -1e9, 2e9, 2e9 };
        // Open group (group_depth > 0): its entry under construction.
        var group_depth: usize = 0;
        var group_hash: u64 = 0;
        var group_bounds: [4]f32 = .{ 0, 0, 0, 0 };
        var group_clip: [4]f32 = infinite;
        var group_first: usize = 0;
        var group_start_depth: usize = 0;
        var group_min_depth: usize = 0;
        var group_glass = false;
        var group_volatile = false;
        // Inside a glass: nested opacity/rounded-clip groups are bounded by
        // their begin token (their content may be in their own space).
        var sealed: usize = 0;
        try self.item_hashes.ensureTotalCapacity(a, commands.len);
        try self.geo_cur.ensureTotalCapacity(a, commands.len);
        for (commands, 0..) |*item, i| {
            const it = item;
            const clip = if (depth == 0) infinite else clips[depth - 1];
            const seed: u64 = if (depth == 0) 0 else clip_hashes[depth - 1];
            const item_hash = paint.itemDigest(item);
            self.item_hashes.appendAssumeCapacity(item_hash);
            const geo = self.geometry(item, item_hash);
            if (group_depth > 0) {
                group_hash = mix(group_hash, item_hash);
                if (it.kind == .image and it.icon_rep_ptr == null) group_volatile = true;
                if (it.kind == .control and it.control_kind == .begin_blur_layer) {
                    try self.glass.append(a, .{ .read = geo.read, .write = geo.main });
                }
                if (group_glass and sealed == 0) {
                    if (it.kind != .control) {
                        group_bounds = unite(group_bounds, intersection(geo.main, clip));
                    } else switch (it.control_kind) {
                        .begin_blur_layer => group_bounds = unite(group_bounds, intersection(geo.main, clip)),
                        .begin_opacity_layer, .begin_rounded_clip => {
                            group_bounds = unite(group_bounds, intersection(geo.main, clip));
                            sealed = 1;
                        },
                        else => {},
                    }
                } else if (sealed > 0 and it.kind == .control) switch (it.control_kind) {
                    .begin_opacity_layer, .begin_blur_layer, .begin_rounded_clip => sealed += 1,
                    .end_opacity_layer, .end_blur_layer, .end_rounded_clip => sealed -= 1,
                    else => {},
                };
            }
            if (it.kind == .control) {
                switch (it.control_kind) {
                    .push_clip => {
                        if (depth == clips.len) return debugFail("clip stack full", i);
                        // Inside an opacity/rounded-clip group the clip is in the
                        // group's own space: it bounds nothing in window space.
                        clips[depth] = if (group_depth > 0 and (!group_glass or sealed > 0)) clip else intersection(geo.main, clip);
                        for (clips[depth]) |v| if (!std.math.isFinite(v)) return debugFail("clip bounds", i);
                        clip_hashes[depth] = mix(seed, item_hash);
                        depth += 1;
                    },
                    .pop_clip => {
                        if (depth == 0) return debugFail("pop_clip at depth 0", i);
                        depth -= 1;
                        if (group_depth > 0) group_min_depth = @min(group_min_depth, depth);
                    },
                    .begin_opacity_layer, .begin_blur_layer, .begin_rounded_clip => {
                        if (group_depth == 0) {
                            group_hash = mix(seed, item_hash);
                            group_glass = it.control_kind == .begin_blur_layer;
                            group_bounds = geo.main;
                            group_clip = clip;
                            group_first = i;
                            group_start_depth = depth;
                            group_min_depth = depth;
                            group_volatile = false;
                            sealed = 0;
                            if (group_glass) try self.glass.append(a, .{ .read = geo.read, .write = geo.main });
                        }
                        group_depth += 1;
                    },
                    .end_opacity_layer, .end_blur_layer, .end_rounded_clip => {
                        if (group_depth == 0) return debugFail("group end outside a group", i);
                        group_depth -= 1;
                        if (group_depth == 0) {
                            const bounds = intersection(group_bounds, group_clip);
                            for (bounds) |v| if (!std.math.isFinite(v)) return debugFail("group bounds", group_first);
                            if (group_volatile) try self.volatile_bounds.append(a, bounds);
                            try self.current.append(a, .{ .digest = group_hash, .bounds = bounds });
                            const balanced = depth == group_start_depth and group_min_depth == group_start_depth;
                            try self.ranges.append(a, .{ @intCast(group_first), if (balanced) @intCast(i) else no_skip });
                        }
                    },
                    .none => {},
                }
                continue;
            }
            if (group_depth > 0) continue;
            var bounds = intersection(geo.main, clip);
            for (bounds) |v| if (!std.math.isFinite(v)) return debugFail("item bounds", i);
            if (bounds[2] < 0 or bounds[3] < 0) bounds = .{ 0, 0, 0, 0 };
            if (it.kind == .image and it.icon_rep_ptr == null) try self.volatile_bounds.append(a, bounds);
            try self.current.append(a, .{ .digest = mix(seed, item_hash), .bounds = bounds });
            try self.ranges.append(a, .{ @intCast(i), @intCast(i) });
        }
        if (depth != 0 or group_depth != 0) return debugFail("unbalanced paint", commands.len);
        return true;
    }
};
/// The bounds buildEntries needs from one item (see Geo).
fn computeGeometry(it: anytype, digest: u64) FrameDamage.Geo {
    var geo: FrameDamage.Geo = .{ .digest = digest, .main = .{ 0, 0, 0, 0 }, .read = .{ 0, 0, 0, 0 } };
    if (it.kind != .control) {
        geo.main = paint.inkWorldBounds(it);
    } else switch (it.control_kind) {
        .push_clip => geo.main = paint.damageItemBounds(it),
        .begin_blur_layer => {
            geo.main = paint.glassWrittenBounds(it);
            geo.read = paint.glassReadBounds(it);
        },
        .begin_opacity_layer, .begin_rounded_clip => geo.main = paint.inkWorldBounds(it),
        else => {},
    }
    return geo;
}

/// Order-dependent combination of two 64-bit digests (wyhash's multiply-fold
/// core): entry and clip digests chain item digests with it, once per item.
fn mix(a: u64, b: u64) u64 {
    const m = @as(u128, a ^ 0xa0761d6478bd642f) * @as(u128, b ^ 0xe7037ed1a0b428db);
    return @as(u64, @truncate(m)) ^ @as(u64, @truncate(m >> 64));
}

fn debugFail(reason: []const u8, index: usize) bool {
    if (debugEnabled()) std.debug.print("[frame-damage] cannot describe: {s} at {d}\n", .{ reason, index });
    return false;
}

fn debugEnabled() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached == null) S.cached = @import("zenit_environment").flag("ZENIT_DEBUG_FRAME_DAMAGE");
    return S.cached.?;
}

fn debugReason(reason: []const u8, rects: ?[2][4]f32) void {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached == null) S.cached = @import("zenit_environment").flag("ZENIT_DEBUG_FRAME_DAMAGE");
    if (!S.cached.?) return;
    if (rects) |r| {
        std.debug.print("[frame-damage] {s} changed=({d:.0},{d:.0},{d:.0}x{d:.0}) grown=({d:.0},{d:.0},{d:.0}x{d:.0})\n", .{ reason, r[0][0], r[0][1], r[0][2], r[0][3], r[1][0], r[1][1], r[1][2], r[1][3] });
    } else std.debug.print("[frame-damage] {s}\n", .{reason});
}

fn intersects(a: [4]f32, b: [4]f32) bool {
    return a[2] > 0 and a[3] > 0 and b[2] > 0 and b[3] > 0 and
        a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3];
}

fn unite(a: [4]f32, b: [4]f32) [4]f32 {
    if (b[2] <= 0 or b[3] <= 0) return a;
    if (a[2] <= 0 or a[3] <= 0) return b;
    const x = @min(a[0], b[0]);
    const y = @min(a[1], b[1]);
    return .{ x, y, @max(a[0] + a[2], b[0] + b[2]) - x, @max(a[1] + a[3], b[1] + b[3]) - y };
}

fn sameEntry(a: anytype, b: anytype) bool {
    return a.digest == b.digest and std.mem.eql(f32, &a.bounds, &b.bounds);
}

fn entryKey(e: anytype) u64 {
    var h = std.hash.Wyhash.init(e.digest);
    h.update(std.mem.asBytes(&e.bounds));
    return h.final();
}

/// Union (logical px) of the entries of `previous`/`current` that are not
/// unchanged-and-kept: common prefix/suffix skipped, the middle diffed by
/// markKept, so an insertion or an unchanged entry between two edits damages
/// nothing else. Out of memory: every middle entry counts as changed.
pub fn changedBounds(allocator: std.mem.Allocator, previous: anytype, current: anytype) [4]f32 {
    var prefix: usize = 0;
    while (prefix < previous.len and prefix < current.len and sameEntry(previous[prefix], current[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < previous.len - prefix and suffix < current.len - prefix and
        sameEntry(previous[previous.len - 1 - suffix], current[current.len - 1 - suffix])) suffix += 1;
    const old = previous[prefix .. previous.len - suffix];
    const new = current[prefix .. current.len - suffix];
    var kept_old: []bool = &.{};
    var kept_new: []bool = &.{};
    defer allocator.free(kept_old);
    defer allocator.free(kept_new);
    diff: {
        kept_old = allocator.alloc(bool, old.len) catch break :diff;
        // Initialize before the next fallible allocation: the conservative
        // fallback below reads every successfully allocated flag.
        @memset(kept_old, false);
        kept_new = allocator.alloc(bool, new.len) catch break :diff;
        @memset(kept_new, false);
        markKept(allocator, old, new, kept_old, kept_new) catch {
            @memset(kept_old, false);
            @memset(kept_new, false);
        };
    }
    var rect: [4]f32 = .{ 0, 0, 0, 0 };
    for (old, 0..) |e, i| if (i >= kept_old.len or !kept_old[i]) {
        rect = unite(rect, e.bounds);
        if (debugEnabled()) std.debug.print("[frame-damage]   old#{d} ({d:.0},{d:.0},{d:.0}x{d:.0})\n", .{ prefix + i, e.bounds[0], e.bounds[1], e.bounds[2], e.bounds[3] });
    };
    for (new, 0..) |e, i| if (i >= kept_new.len or !kept_new[i]) {
        rect = unite(rect, e.bounds);
        if (debugEnabled()) std.debug.print("[frame-damage]   new#{d} ({d:.0},{d:.0},{d:.0}x{d:.0})\n", .{ prefix + i, e.bounds[0], e.bounds[1], e.bounds[2], e.bounds[3] });
    };
    return rect;
}

/// Marks the entries of `previous`/`current` that are unchanged and kept in
/// the same relative order (patience diff: entries unique on both sides,
/// longest increasing run of their old positions). Everything unmarked was
/// inserted, removed, changed or moved past another entry.
pub fn markKept(allocator: std.mem.Allocator, previous: anytype, current: anytype, kept_prev: []bool, kept_cur: []bool) !void {
    const Slot = struct { p: i64 = -1, c: i64 = -1 };
    var slots: std.AutoHashMapUnmanaged(u64, Slot) = .empty;
    defer slots.deinit(allocator);
    try slots.ensureTotalCapacity(allocator, @intCast(previous.len + current.len));
    for (previous, 0..) |e, i| {
        const gop = slots.getOrPutAssumeCapacity(entryKey(e));
        if (!gop.found_existing) gop.value_ptr.* = .{ .p = @intCast(i) } else gop.value_ptr.p = -2;
    }
    for (current, 0..) |e, j| {
        const gop = slots.getOrPutAssumeCapacity(entryKey(e));
        if (!gop.found_existing) gop.value_ptr.* = .{ .p = -1, .c = @intCast(j) } else gop.value_ptr.c = if (gop.value_ptr.c == -1) @intCast(j) else -2;
    }
    // Old positions of uniquely matched entries, in current order.
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(allocator);
    for (current, 0..) |e, j| {
        const slot = slots.get(entryKey(e)).?;
        if (slot.p >= 0 and slot.c == @as(i64, @intCast(j))) try pairs.append(allocator, .{ @intCast(slot.p), @intCast(j) });
    }
    // Longest increasing subsequence of the old positions (patience sorting).
    const tails = try allocator.alloc(u32, pairs.items.len);
    defer allocator.free(tails);
    const back = try allocator.alloc(u32, pairs.items.len);
    defer allocator.free(back);
    var len: usize = 0;
    for (pairs.items, 0..) |pair, k| {
        var lo: usize = 0;
        var hi: usize = len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (pairs.items[tails[mid]][0] < pair[0]) lo = mid + 1 else hi = mid;
        }
        back[k] = if (lo > 0) tails[lo - 1] else std.math.maxInt(u32);
        tails[lo] = @intCast(k);
        if (lo == len) len += 1;
    }
    if (len == 0) return;
    var k: u32 = tails[len - 1];
    while (true) {
        kept_prev[pairs.items[k][0]] = true;
        kept_cur[pairs.items[k][1]] = true;
        if (back[k] == std.math.maxInt(u32)) break;
        k = back[k];
    }
}

fn intersection(a: [4]f32, b: [4]f32) [4]f32 {
    const x = @max(a[0], b[0]);
    const y = @max(a[1], b[1]);
    return .{ x, y, @max(0, @min(a[0] + a[2], b[0] + b[2]) - x), @max(0, @min(a[1] + a[3], b[1] + b[3]) - y) };
}
fn diff(previous: []const Item, current: []const Item, width: u32, height: u32, scale: f32) ?PixelRect {
    var lo: [2]f32 = @splat(std.math.inf(f32));
    var hi: [2]f32 = @splat(-std.math.inf(f32));
    const count = @max(previous.len, current.len);
    for (0..count) |i| {
        if (i < previous.len and i < current.len and previous[i].digest == current[i].digest and std.mem.eql(f32, &previous[i].bounds, &current[i].bounds)) continue;
        for ([_]?Item{ if (i < previous.len) previous[i] else null, if (i < current.len) current[i] else null }) |entry| {
            const item = entry orelse continue;
            if (item.bounds[2] <= 0 or item.bounds[3] <= 0) continue;
            for (0..2) |axis| {
                lo[axis] = @min(lo[axis], item.bounds[axis]);
                hi[axis] = @max(hi[axis], item.bounds[axis] + item.bounds[axis + 2]);
            }
        }
    }
    if (!std.math.isFinite(lo[0])) return .{ 0, 0, 0, 0 };
    var rect: PixelRect = undefined;
    for ([_]u32{ width, height }, 0..) |extent, axis| {
        const maximum: f32 = @floatFromInt(extent);
        rect[axis] = @intFromFloat(@floor(std.math.clamp(lo[axis] * scale - 1, 0, maximum)));
        const end: u32 = @intFromFloat(@ceil(std.math.clamp(hi[axis] * scale + 1, 0, maximum)));
        rect[axis + 2] = end -| rect[axis];
    }
    // Large changes are cheaper to clear/repaint directly than copy and clip.
    if (@as(u64, rect[2]) * rect[3] * 5 > @as(u64, width) * height * 3) return null;
    return rect;
}
test "frame damage includes old and new positions, removal and context invalidation" {
    const old = [_]Item{.{ .digest = 1, .bounds = .{ 20, 30, 40, 10 } }};
    const moved = [_]Item{.{ .digest = 1, .bounds = .{ 25, 35, 40, 10 } }};
    try std.testing.expectEqual(PixelRect{ 0, 0, 0, 0 }, diff(&old, &old, 200, 100, 1).?);
    try std.testing.expectEqual(PixelRect{ 19, 29, 47, 17 }, diff(&old, &moved, 200, 100, 1).?);
    try std.testing.expectEqual(PixelRect{ 19, 29, 42, 12 }, diff(&old, &.{}, 200, 100, 1).?);
    var plan: FrameDamage = .{};
    plan.pending_valid = true;
    plan.pending_key = 5;
    plan.commit();
    try std.testing.expect(plan.valid and plan.key == 5);
    plan.invalidate();
    try std.testing.expect(!plan.valid and !plan.pending_valid);
}

test "frame damage includes removed pixels when the second diff allocation fails" {
    const old = [_]Item{.{ .digest = 1, .bounds = .{ 10, 20, 30, 40 } }};
    const new = [_]Item{.{ .digest = 2, .bounds = .{ 100, 200, 30, 40 } }};
    // One byte lets kept_old allocate but makes kept_new fail. Reused scratch
    // memory may contain `true`: an uninitialized kept_old must not hide the
    // old item's pixels when we fall back to conservative damage.
    var memory = [_]u8{1};
    var scratch = std.heap.FixedBufferAllocator.init(&memory);
    try std.testing.expectEqual([4]f32{ 10, 20, 120, 220 }, changedBounds(scratch.allocator(), &old, &new));
}
