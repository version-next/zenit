//! Host side of compositor sprites (ui core/compositor_sprite.zig): renders
//! each placement's flipbook once into an atlas with the regular encoder, then
//! keeps native layers above the window surface in sync with the frame's
//! placements.
//!   - macOS Metal: IOSurface atlases in Core Animation layers
//!     (native/macos/compositor_sprites.inc); the frame drops the sprites'
//!     items (Registry.filter_placed).
//!   - Windows Direct3D 12 / 11: composition swap chain atlases in a topmost
//!     DirectComposition target (native/windows/compositor_sprites.cpp),
//!     stepped by DWM. Opaque sprites only, sampled at the display refresh
//!     rate; the frame keeps painting the node under its sprite, and a sprite
//!     that leaves is removed only once the frame painting the node again is
//!     complete (afterPresent), so no presentation shows neither or a stale one.
//! Elsewhere sprites stay disabled and every function is a no-op.
const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const fingerprint = @import("render").PaintFingerprint;
const tiles = @import("sprite_tiles.zig");
const build = @import("sprite_build.zig");
const caret_sprite = @import("caret_sprite.zig");

const macos = builtin.os.tag == .macos and gpu.backend_kind == .metal;
const windows = builtin.os.tag == .windows and gpu.is_direct3d;
pub const supported = macos or windows;

extern fn macos_sprite_atlas_create(layer: *anyopaque, width: c_uint, height: c_uint, texture_out: *?*anyopaque) ?*anyopaque;
extern fn macos_sprite_atlas_release(surface: ?*anyopaque) void;
extern fn macos_sprites_begin(layer: *anyopaque) void;
extern fn macos_sprite_keep(layer: *anyopaque, node_id: c_uint) void;
extern fn macos_sprite_put(
    layer: *anyopaque,
    node_id: c_uint,
    key: u64,
    surface: *anyopaque,
    origin_px: *const [2]c_int,
    cell_px: *const [2]c_uint,
    clip_px: ?*const [4]c_int,
    columns: c_uint,
    frames: c_uint,
    atlas_px: *const [2]c_uint,
    period_s: f64,
    phase_s: f64,
    scale: f64,
    is_opaque: c_int,
) void;
extern fn macos_sprites_end(layer: *anyopaque) c_uint;
extern fn macos_sprites_clear(layer: *anyopaque) void;

extern fn zenit_win_sprites_create(hwnd: *anyopaque, surface_device: ?*anyopaque, surface_root: ?*anyopaque) ?*anyopaque;
extern fn zenit_win_sprites_destroy(host: ?*anyopaque) void;
extern fn zenit_win_sprites_begin(host: *anyopaque) void;
/// native/windows/compositor_sprites.cpp ZenitWinSpriteLayout.
const NativeLayout = extern struct {
    tiles: [*]const tiles.Tile,
    frames: [*]const u32,
    tile_count: u32,
    frame_count: u32,
    columns: u32,
    tiles_top: u32,
    tile_px: u32,
};
extern fn zenit_win_sprite_put(
    host: *anyopaque,
    node_id: c_uint,
    key: u64,
    content: *anyopaque,
    origin_px: *const [2]c_int,
    cell_px: *const [2]c_uint,
    clip_px: ?*const [4]c_int,
    layout: *const NativeLayout,
    period_s: f64,
    phase_s: f64,
    latency_s: f64,
) c_int;
extern fn zenit_win_sprites_set_debug(on: c_int) void;
extern fn zenit_win_sprites_frozen() c_int;
extern fn zenit_win_sprites_end(host: *anyopaque, deferred: c_int) c_uint;
extern fn zenit_win_sprites_leaving(host: *anyopaque) c_uint;
extern fn zenit_win_sprites_flush(host: *anyopaque) c_uint;

var debug_cx: bool = false;
fn debugEnabled() bool {
    if (debug_cx) return true;
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached == null) S.cached = @import("zenit_environment").flag("ZENIT_DEBUG_SPRITES");
    return S.cached.?;
}

/// Windows: upper bound for one flipbook's full size (Registry.max_atlas_bytes).
/// It is never allocated whole (chunked rendering, tile compaction); the bound
/// caps the one-off build work.
pub const max_rendered_atlas_bytes: u64 = 64 * 1024 * 1024;
/// Windows: refreshes between a frame's clock sample and its presentation the
/// sprite assumes (see sync).
const presentation_latency_frames: f64 = 2;
/// Windows: atlas builds in progress at once (sprite_build.zig).
const max_builds = 8;

/// Windows: unshown atlases kept for reuse, at most this many bytes.
const max_spare_bytes: u64 = 4 * 1024 * 1024;

/// Atlases not shown for this many synced frames are released.
const keep_unused_frames: u64 = 600;
const max_atlases = 16;

/// Windows: which dictionary entry each changing tile shows per frame
/// (sprite_tiles.Compact without its pixels, which live in the swap chain).
const Layout = struct {
    tiles: []tiles.Tile,
    frames: []u32,
    frame_count: u32,
    columns: u32,
    tiles_top: u32,
    tile: u32,

    fn native(self: *const Layout) NativeLayout {
        return .{ .tiles = self.tiles.ptr, .frames = self.frames.ptr, .tile_count = @intCast(self.tiles.len), .frame_count = self.frame_count, .columns = self.columns, .tiles_top = self.tiles_top, .tile_px = self.tile };
    }
};

const Atlas = struct {
    key: u64,
    /// macOS: the IOSurface. Windows: the composition swap chain and the
    /// texture rendering into it.
    surface: if (windows) gpu.Backend.SpriteAtlas else *anyopaque,
    texture: if (windows) void else gpu.Backend.Texture,
    layout: if (windows) Layout else void = if (windows) undefined else {},
    size: [2]u32,
    last_used: u64,
    is_opaque: bool,

    /// Memory the atlas keeps (both buffers of a Windows swap chain).
    fn bytes(self: *const Atlas) u64 {
        const one = @as(u64, self.size[0]) * self.size[1] * 4;
        return if (comptime windows) 2 * one else one;
    }
};

pub const Host = struct {
    atlases: std.ArrayList(Atlas) = .empty,
    /// Owns atlas bookkeeping (set at the first atlas build).
    allocator: std.mem.Allocator = undefined,
    clock: u64 = 0,
    shown: u32 = 0,
    /// Everything the last native update was given (sync): an equal frame
    /// leaves the layers as they are without touching them.
    last_signature: ?u64 = null,
    /// Windows: the DirectComposition sprite tree (created on first use).
    win: ?*anyopaque = null,
    /// Windows: sprites wait for the frame now being presented (afterPresent).
    leaving: bool = false,
    /// Windows: atlases being built over frames, and their render target.
    builds: if (windows) std.ArrayList(build.Entry) else void = if (windows) .empty else {},
    scratch: if (windows) build.Scratch else void = if (windows) .{} else {},
    /// Windows: atlas keys whose build failed (not retried; ring).
    failed_keys: [8]u64 = @splat(0),
    failed_next: u8 = 0,
    /// Windows: the atlas key each node asked for last (a build starts once
    /// a key is asked for twice in a row).
    candidates: [16]struct { node_id: u32 = 0, key: u64 = 0 } = @splat(.{}),
    candidate_next: u8 = 0,

    /// Record `key` as the node's candidate; true when it already was.
    fn noteCandidate(self: *Host, node_id: u32, key: u64) bool {
        for (&self.candidates) |*c| if (c.node_id == node_id) {
            const same = c.key == key;
            c.key = key;
            return same;
        };
        self.candidates[self.candidate_next] = .{ .node_id = node_id, .key = key };
        self.candidate_next = @intCast((self.candidate_next + 1) % self.candidates.len);
        return false;
    }

    fn noteFailed(self: *Host, key: u64) void {
        self.failed_keys[self.failed_next] = key;
        self.failed_next = @intCast((self.failed_next + 1) % self.failed_keys.len);
    }

    pub fn deinit(self: *Host, allocator: std.mem.Allocator, renderer: anytype) void {
        if (comptime macos) macos_sprites_clear(@ptrCast(renderer.surface.layer));
        if (comptime windows) {
            zenit_win_sprites_destroy(self.win);
            for (self.builds.items) |b| b.destroy(allocator);
            self.builds.deinit(allocator);
            self.scratch.release();
        }
        if (comptime supported) for (self.atlases.items) |*atlas| release(allocator, atlas);
        self.atlases.deinit(allocator);
        self.* = .{};
    }

    /// Idle: only atlases shown by the latest sync are needed. (Shown layers
    /// retain their atlas themselves; this drops cached spares.)
    pub fn trimIdle(self: *Host) void {
        if (comptime !supported) return;
        var i: usize = 0;
        while (i < self.atlases.items.len) {
            const atlas = &self.atlases.items[i];
            if (atlas.last_used != self.clock) {
                release(self.allocator, atlas);
                _ = self.atlases.swapRemove(i);
            } else i += 1;
        }
    }

    /// Bytes held by atlases (diagnostics).
    pub fn atlasBytes(self: *const Host) u64 {
        var total: u64 = 0;
        if (comptime supported) for (self.atlases.items) |*atlas| {
            total += atlas.bytes();
        };
        return total;
    }

    fn release(allocator: std.mem.Allocator, atlas: *Atlas) void {
        if (comptime windows) {
            atlas.surface.destroy();
            allocator.free(atlas.layout.tiles);
            allocator.free(atlas.layout.frames);
        } else if (comptime macos) {
            atlas.texture.destroy();
            macos_sprite_atlas_release(atlas.surface);
        }
    }

    fn evict(self: *Host) void {
        var i: usize = 0;
        while (i < self.atlases.items.len) {
            const atlas = &self.atlases.items[i];
            const stale = self.clock -| atlas.last_used > keep_unused_frames;
            if (stale or (self.atlases.items.len > max_atlases and atlas.last_used != self.clock)) {
                release(self.allocator, atlas);
                _ = self.atlases.swapRemove(i);
            } else i += 1;
        }
        if (comptime windows) {
            // Nothing composited: the frame loop may now stop for good (this
            // host has no idle trim), so drop every spare.
            if (self.shown == 0) return self.trimIdle();
            // Spares (a loading button's other hover state) up to a small
            // budget, least recently shown first out.
            while (true) {
                var spare: u64 = 0;
                var oldest: ?usize = null;
                for (self.atlases.items, 0..) |*atlas, k| {
                    if (atlas.last_used == self.clock) continue;
                    spare += atlas.bytes();
                    if (oldest == null or atlas.last_used < self.atlases.items[oldest.?].last_used) oldest = k;
                }
                if (spare <= max_spare_bytes) break;
                release(self.allocator, &self.atlases.items[oldest.?]);
                _ = self.atlases.swapRemove(oldest.?);
            }
        }
    }
};

/// Bring native sprite layers in line with this frame's placements. Call after
/// `cx.render()` and before anything reads `cx.lowerForEncoderPaintTable()`:
/// a placement the host cannot present is rejected here, so the node is
/// painted by the GPU in this same frame.
pub fn sync(renderer: anytype, cx: anytype) void {
    if (comptime !supported) return;
    const host = &renderer.sprite_host;
    // Windows: the compositor-blinked caret (caret_sprite.zig) rides along.
    const caret: ?*caret_sprite.State = if (comptime windows) (if (renderer.caret_sprite.active) &renderer.caret_sprite else null) else null;
    if (cx.sprites.placements.items.len == 0 and host.shown == 0 and pendingBuilds(host) == 0 and caret == null) return;
    debug_cx = cx.sprites.debugOn();
    if (comptime windows) zenit_win_sprites_set_debug(@intFromBool(debug_cx));
    host.clock += 1;
    defer {
        cx.sprites.host_atlas_bytes = host.atlasBytes();
        cx.sprites.host_building = @intCast(pendingBuilds(host));
    }
    const layer: *anyopaque = if (comptime windows) host.win orelse blk: {
        const tree = renderer.surface.compositionTree();
        const created = zenit_win_sprites_create(renderer.surface.hwnd, tree[0], tree[1]) orelse {
            rejectAll(cx);
            return;
        };
        host.win = created;
        break :blk created;
    } else @ptrCast(renderer.surface.layer);

    var rejected: [64]u32 = undefined;
    var rejected_count: usize = 0;
    var postponed: [64]u32 = undefined;
    var postponed_count: usize = 0;
    // Lowered once for every placement: the encoder will consume this same
    // list (sprite items removed), so backgrounds are read from it.
    const paint = cx.lowerForEncoderPaintTable();
    var bounds = BoundsCache.init(cx.frame_arena.allocator(), paint);
    // The atlas by value: a later placement's atlas build can grow the list.
    const Put = struct { p: @TypeOf(cx.sprites.placements.items[0]), atlas: Atlas };
    var puts = std.ArrayList(Put).initCapacity(cx.frame_arena.allocator(), cx.sprites.placements.items.len) catch {
        host.last_signature = null;
        rejectAll(cx);
        return;
    };
    // The native update is a pure function of these values. The phase only
    // seeds a new flipbook animation (on either platform a put of an
    // unchanged sprite keeps its running animation), except in freeze mode,
    // where every put shows the frame for its phase. Windows: what a put
    // depends on beyond this (visiblePart, the window) is in `p` and the
    // extent; build progress and postponed sprites only decide which
    // placements are put; leaving sprites are flushed after the present of
    // the frame that changed the puts (afterPresent).
    var sig = std.hash.Wyhash.init(0x7370);
    const extent: [2]u32 = if (comptime windows)
        (if (renderer.surface.config) |c| .{ c.width, c.height } else .{ 0, 0 })
    else
        .{ renderer.surface.extent.width, renderer.surface.extent.height };
    sig.update(std.mem.sliceAsBytes(&extent));
    const layer_id = @intFromPtr(layer);
    sig.update(std.mem.asBytes(&layer_id));
    const frozen = spriteFreeze();
    sig.update(std.mem.asBytes(&frozen));
    for (cx.sprites.placements.items) |placement| {
        if (placement.exiting) {
            sig.update("k");
            sig.update(std.mem.asBytes(&placement.node_id));
            continue;
        }
        // Windows: the part of the cell inside the window (a ring scrolled
        // half out of view); flipbook frames render at window coordinates.
        // A cell wholly outside the window shows nothing either way: it stays
        // placed without a visual (as a Core Animation layer outside the
        // window would), so the node's animation does not keep the frame
        // loop running for pixels nobody sees. Moving into view moves the
        // cell, which hands the node back to the GPU paint (Registry.admit).
        const p = if (comptime windows) visiblePart(renderer, placement) orelse {
            sig.update("o");
            sig.update(std.mem.asBytes(&placement.node_id));
            continue;
        } else placement;
        // Digest only: the items are collected for an atlas build alone.
        const background = backgroundOf(null, paint, &bounds, p, ownRange(cx, p)) catch null;
        // Windows: the frame keeps painting the node beneath, so only a
        // sprite that covers its whole cell can stand in for it; its atlas is
        // built over the next frames (postponed until then).
        const found = if (comptime windows)
            (if (background) |bg| windowsAtlas(renderer, cx, p, bg, paint, &bounds) else .failed)
        else if (atlasFor(renderer, cx, p, background, paint, &bounds)) |a| AtlasLookup{ .ready = a } else .failed;
        const atlas = switch (found) {
            .ready => |a| a,
            .pending => {
                if (postponed_count < postponed.len) {
                    postponed[postponed_count] = p.node_id;
                    postponed_count += 1;
                }
                continue;
            },
            .failed => {
                if (rejected_count < rejected.len) {
                    rejected[rejected_count] = p.node_id;
                    rejected_count += 1;
                }
                continue;
            },
        };
        puts.appendAssumeCapacity(.{ .p = p, .atlas = atlas.* });
        const clip: [4]i32 = if (p.clip_px) |c| .{ c[0], c[1], c[2], c[3] } else .{ 0, 0, -1, -1 };
        // Windows: the swap chain object the visuals show (an atlas rebuilt
        // under the same key is a new one).
        const surface_id: usize = if (comptime windows) @intFromPtr(atlas.surface.content()) else @intFromPtr(atlas.surface);
        const ints = [_]u64{ p.node_id, atlas.key, surface_id, @bitCast(@as(i64, p.origin_px[0])), @bitCast(@as(i64, p.origin_px[1])), p.cell_px[0], p.cell_px[1], p.columns, p.frame_count, atlas.size[0], atlas.size[1], @intFromBool(atlas.is_opaque) };
        sig.update(std.mem.sliceAsBytes(&ints));
        sig.update(std.mem.asBytes(&clip));
        const floats = [_]f64{ p.period_ms, p.scale, if (frozen) @mod(p.frame_time_ms, p.period_ms) else 0 };
        sig.update(std.mem.sliceAsBytes(&floats));
    }
    if (caret) |c| {
        // Its loop phase only seeds the animation (an unchanged put keeps it).
        const atlas_id: usize = @intFromPtr(c.atlas.?.content());
        const ints = [_]u64{ caret_sprite.node_id, c.key, atlas_id, @bitCast(@as(i64, c.rect[0])), @bitCast(@as(i64, c.rect[1])), c.layout.cell[0], c.layout.cell[1] };
        sig.update("caret");
        sig.update(std.mem.sliceAsBytes(&ints));
    }
    // Not native state: applied every frame, whether or not the layers change.
    defer {
        for (rejected[0..rejected_count]) |node_id| cx.sprites.reject(node_id);
        for (postponed[0..postponed_count]) |node_id| {
            if (cx.sprites.postpone(node_id)) cx.needs_redraw = true;
        }
        if (postponed_count != 0) cx.needs_redraw = true;
    }
    if (comptime windows) {
        // Builds no placement asked for this frame are abandoned.
        var i: usize = 0;
        while (i < host.builds.items.len) {
            const b = host.builds.items[i];
            if (b.seen != host.clock) {
                b.destroy(renderer.allocator);
                _ = host.builds.swapRemove(i);
            } else i += 1;
        }
        if (host.builds.items.len == 0) host.scratch.release();
    }
    const signature = sig.final();
    if (host.last_signature == signature) return;
    host.last_signature = signature;

    if (comptime windows) zenit_win_sprites_begin(layer) else macos_sprites_begin(layer);
    if (comptime macos) for (cx.sprites.placements.items) |p| if (p.exiting) macos_sprite_keep(layer, p.node_id);
    for (puts.items) |entry| {
        const p = entry.p;
        const atlas = entry.atlas;
        const origin: [2]c_int = .{ p.origin_px[0], p.origin_px[1] };
        const cell: [2]c_uint = .{ p.cell_px[0], p.cell_px[1] };
        var clip: [4]c_int = undefined;
        if (p.clip_px) |c| clip = .{ c[0], c[1], c[2], c[3] };
        const phase_s = @mod(p.frame_time_ms, p.period_ms) / 1000;
        if (comptime windows) {
            // The phase now, not at the frame's clock sample: a put can follow
            // a long atlas step. (A locked test clock has no wall time.)
            const late_s: f64 = if (cx.test_frame_step_ms == null) if (cx.last_frame_instant) |sample|
                @as(f64, @floatFromInt((@import("zenit_time").Instant.now(cx.io) catch sample).since(sample))) / std.time.ns_per_s
            else
                0 else 0;
            // A frame painted by the application reaches the screen some
            // refreshes after its clock sample: about one and a half when it
            // starts from idle (the frame after a hand-back) and three to four
            // once presents queue up (the frames before a hand-over). The
            // sprite lags its clock by two, which keeps both hand-overs within
            // a frame or two of the GPU path's own latency.
            const hz: f64 = if (cx.display_refresh_hz > 0) @floatCast(cx.display_refresh_hz) else 60;
            const layout = atlas.layout.native();
            const ok = if (atlas.surface.content()) |object| zenit_win_sprite_put(layer, p.node_id, atlas.key, object, &origin, &cell, if (p.clip_px != null) &clip else null, &layout, p.period_ms / 1000, phase_s + late_s, presentation_latency_frames / hz) == 0 else false;
            if (!ok) {
                cx.sprites.host_error = "DirectComposition put failed";
                // The tree no longer matches the signature: put again next frame.
                host.last_signature = null;
            }
            if (!ok and rejected_count < rejected.len) {
                rejected[rejected_count] = p.node_id;
                rejected_count += 1;
            }
        } else {
            const atlas_px: [2]c_uint = .{ atlas.size[0], atlas.size[1] };
            macos_sprite_put(
                layer,
                p.node_id,
                atlas.key,
                atlas.surface,
                &origin,
                &cell,
                if (p.clip_px != null) &clip else null,
                p.columns,
                p.frame_count,
                &atlas_px,
                p.period_ms / 1000,
                phase_s,
                p.scale,
                @intFromBool(atlas.is_opaque),
            );
        }
    }
    if (comptime windows) if (caret) |c| {
        if (!putCaret(layer, cx, c)) {
            cx.sprites.host_error = "DirectComposition caret put failed";
            host.last_signature = null;
            // The runtime sees the sprite inactive and paints the caret again.
            c.deactivate();
            cx.needs_redraw = true;
        }
    };
    if (comptime windows) {
        // Leaving sprites stay up until this frame, which paints their nodes
        // again, is complete (afterPresent).
        host.shown = zenit_win_sprites_end(layer, 1);
        host.leaving = zenit_win_sprites_leaving(layer) != 0;
    } else host.shown = macos_sprites_end(layer);
    host.evict();
}

/// Windows: put the caret sprite, its loop seeded at the caret's current
/// phase (the shown picture first; caret_sprite.phaseSeconds).
fn putCaret(layer: *anyopaque, cx: anytype, c: *caret_sprite.State) bool {
    if (comptime !windows) return false;
    const atlas = c.atlas orelse return false;
    const content = atlas.content() orelse return false;
    const now = @import("zenit_time").monotonicTimestamp(cx.io);
    const remaining: u64 = @intCast(@max(0, cx.caret_next_ns - now));
    const phase_s = caret_sprite.phaseSeconds(cx.caret_visible, remaining, cx.caret_half_ns);
    const period_s = 2 * @as(f64, @floatFromInt(cx.caret_half_ns)) / std.time.ns_per_s;
    const origin: [2]c_int = .{ c.rect[0], c.rect[1] };
    const cell: [2]c_uint = .{ c.layout.cell[0], c.layout.cell[1] };
    const layout: NativeLayout = .{
        .tiles = &c.tiles_buf,
        .frames = &c.frames_buf,
        .tile_count = c.tiles_buf.len,
        .frame_count = caret_sprite.frame_count,
        .columns = c.layout.columns,
        .tiles_top = c.layout.tiles_top,
        .tile_px = c.layout.tile,
    };
    // No presentation-latency lead: the phase is the caret's own, sampled now.
    return zenit_win_sprite_put(layer, caret_sprite.node_id, c.key, content, &origin, &cell, null, &layout, period_s, phase_s, 0) == 0;
}

/// Sprites show the frame for each put's phase instead of animating (tests).
fn spriteFreeze() bool {
    if (comptime windows) return zenit_win_sprites_frozen() != 0;
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached == null) S.cached = std.c.getenv("ZENIT_DEBUG_SPRITE_FREEZE") != null;
    return S.cached.?;
}

fn pendingBuilds(host: *const Host) usize {
    return if (comptime windows) host.builds.items.len else 0;
}

fn rejectAll(cx: anytype) void {
    var ids: [64]u32 = undefined;
    var n: usize = 0;
    for (cx.sprites.placements.items) |p| if (n < ids.len) {
        ids[n] = p.node_id;
        n += 1;
    };
    for (ids[0..n]) |id| cx.sprites.reject(id);
}

/// Windows: after the frame's present, queue the next chunk of atlas builds
/// (behind the frame's own GPU work, outside its encoding).
pub fn advanceBuilds(renderer: anytype, cx: anytype) void {
    if (comptime !windows) return;
    const host = &renderer.sprite_host;
    if (host.builds.items.len == 0) return;
    const Instant = @import("zenit_time").Instant;
    const start = Instant.now(renderer.io) catch return;
    // Round robin over the builds, one chunk each per pass, within the budget.
    var progressed = true;
    while (progressed) {
        progressed = false;
        var i: usize = 0;
        while (i < host.builds.items.len) {
            const elapsed = (Instant.now(renderer.io) catch return).since(start);
            if (elapsed >= build.budget_ns) return;
            const b = host.builds.items[i];
            const scratch = if (host.scratch.texture) |*t| t else return;
            const submitted = BuildFor(@TypeOf(cx)).of(b).submit(renderer, scratch) catch |err| {
                if (debugEnabled()) std.debug.print("[sprite] build chunk failed: {s}\n", .{@errorName(err)});
                host.noteFailed(b.key);
                _ = host.builds.swapRemove(i);
                b.destroy(renderer.allocator);
                continue;
            };
            if (submitted) progressed = true;
            i += 1;
        }
    }
}

/// Windows: call once the frame's present call returned. Sprites leaving in
/// this frame are removed when its GPU work is complete: the swap chain then
/// flips to it at the next composition, together with this commit, so no
/// composition shows the frame from before the sprite took over.
pub fn afterPresent(renderer: anytype, command: anytype) void {
    if (comptime !windows) return;
    const host = &renderer.sprite_host;
    if (!host.leaving) return;
    const win = host.win orelse return;
    command.waitChecked(1000) catch {};
    host.shown = zenit_win_sprites_flush(win);
    host.leaving = false;
    if (host.shown == 0) host.trimIdle();
}

/// Paint bounds of each paint item, computed on first use within one sync
/// (shared by every placement: a glass group's bounds scan its whole group).
const BoundsCache = struct {
    bounds: ?[][4]f32,
    known: ?std.DynamicBitSetUnmanaged,
    /// Index of the item closing the clip or group opened at i (null: not
    /// computed, then every subtree is walked item by item).
    ends: ?[]u32 = null,

    fn init(allocator: std.mem.Allocator, paint: anytype) BoundsCache {
        const n = paint.len;
        const b = allocator.alloc([4]f32, n) catch return .{ .bounds = null, .known = null };
        const k = std.DynamicBitSetUnmanaged.initEmpty(allocator, n) catch return .{ .bounds = null, .known = null };
        return .{ .bounds = b, .known = k, .ends = closingIndices(allocator, paint) catch null };
    }

    fn closingIndices(allocator: std.mem.Allocator, paint: anytype) ![]u32 {
        const ends = try allocator.alloc(u32, paint.len);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(allocator);
        for (paint, 0..) |it, i| {
            if (it.kind != .control) continue;
            switch (it.control_kind) {
                .push_clip, .begin_opacity_layer, .begin_blur_layer, .begin_rounded_clip => {
                    ends[i] = @intCast(paint.len);
                    try stack.append(allocator, @intCast(i));
                },
                .pop_clip, .end_opacity_layer, .end_blur_layer, .end_rounded_clip => if (stack.pop()) |open| {
                    ends[open] = @intCast(i);
                },
                .none => {},
            }
        }
        return ends;
    }

    fn get(self: *BoundsCache, paint: anytype, index: usize, it: anytype) [4]f32 {
        const compute = struct {
            fn f(all: anytype, i: usize, item: anytype) [4]f32 {
                return if (item.kind == .control) groupPaintBounds(all, i, item.*) else fingerprint.inkWorldBounds(item.*);
            }
        }.f;
        const b = self.bounds orelse return compute(paint, index, it);
        if (self.known.?.isSet(index)) return b[index];
        b[index] = compute(paint, index, it);
        self.known.?.set(index);
        return b[index];
    }
};

/// What the sprite covers: the frame's paint items under the sprite cell (in
/// order, clip structure kept), so each flipbook frame can be rendered opaque
/// exactly as the GPU frame composes it. Null when an effect (glass, opacity
/// layer, ...) reaches the cell: the sprite is then transparent and composited
/// by the system over the surface.
fn Background(comptime Item: type) type {
    return struct {
        items: []const Item,
        digest: u64,
        /// Where the sprite's own items sit among `items` (Windows: frames
        /// are rendered in place, inside the clips and under the items the
        /// frame paints over them). The end when the frame drops them.
        own_at: usize,
    };
}

/// With a null `allocator` only the digest is computed (items stay empty):
/// the items are needed only to build a missing atlas.
/// When the frame keeps the placement's own items (Registry.filter_placed
/// off): their paint range (the sprite, not its background), and the other
/// sources, whose animated items must not be baked into this cell.
const Own = struct {
    range: [2]usize,
    /// Paint ranges of the other sources' items.
    others: [64][2]usize = undefined,
    other_count: usize = 0,

    fn isOther(self: *const Own, index: usize) bool {
        for (self.others[0..self.other_count]) |r| if (index >= r[0] and index < r[1]) return true;
        return false;
    }
};

fn ownRange(cx: anytype, p: anytype) ?Own {
    if (cx.sprites.filter_placed) return null;
    const source = cx.sprites.sources.items[p.source_index];
    var own: Own = .{ .range = .{ source.paint_first, source.paint_first + source.paint_count } };
    for (cx.sprites.sources.items) |other| {
        if (other.node_id == p.node_id or other.paint_count == 0 or own.other_count == own.others.len) continue;
        own.others[own.other_count] = .{ other.paint_first, other.paint_first + other.paint_count };
        own.other_count += 1;
    }
    return own;
}

fn backgroundOf(allocator: ?std.mem.Allocator, paint: anytype, bounds: *BoundsCache, p: anytype, own_opt: ?Own) !?Background(@typeInfo(@TypeOf(paint)).pointer.child) {
    const Item = @typeInfo(@TypeOf(paint)).pointer.child;
    const s = p.scale;
    const cell = [4]f32{
        @as(f32, @floatFromInt(p.origin_px[0])) / s,
        @as(f32, @floatFromInt(p.origin_px[1])) / s,
        @as(f32, @floatFromInt(p.cell_px[0])) / s,
        @as(f32, @floatFromInt(p.cell_px[1])) / s,
    };
    var out: std.ArrayList(Item) = .empty;
    var hasher = std.hash.Wyhash.init(0x6267);
    var skipped_depth: usize = 0;
    var own_at: ?usize = null;
    var kept: usize = 0;
    var index: usize = 0;
    while (index < paint.len) : (index += 1) {
        const it = &paint[index];
        if (own_opt) |own| if (index >= own.range[0] and index < own.range[1]) {
            if (index == own.range[0]) {
                if (skipped_depth > 0) return null;
                own_at = kept;
                hasher.update("own");
            }
            continue;
        };
        if (it.kind == .control) {
            switch (it.control_kind) {
                .push_clip => if (skipped_depth == 0) {
                    // Nothing inside a clip that misses the cell reaches it
                    // (the sprite's own items, rendered in place, are walked).
                    if (bounds.ends) |ends| if (!intersects(bounds.get(paint, index, it), cell) and !ownWithin(own_opt, index, ends[index])) {
                        index = ends[index];
                        continue;
                    };
                    if (allocator) |a| try out.append(a, it.*);
                    kept += 1;
                    hashRelative(&hasher, it, cell);
                },
                .pop_clip => if (skipped_depth == 0) {
                    if (allocator) |a| try out.append(a, it.*);
                    kept += 1;
                    hashRelative(&hasher, it, cell);
                },
                .begin_opacity_layer, .begin_blur_layer, .begin_rounded_clip => {
                    if (skipped_depth > 0) {
                        skipped_depth += 1;
                    } else if (intersects(bounds.get(paint, index, it), cell)) {
                        return null;
                    } else if (bounds.ends) |ends| {
                        // The sprite inside a skipped group: as when walked.
                        if (ownWithin(own_opt, index, ends[index])) return null;
                        index = ends[index];
                    } else skipped_depth = 1;
                },
                .end_opacity_layer, .end_blur_layer, .end_rounded_clip => {
                    if (skipped_depth == 0) return null;
                    skipped_depth -= 1;
                },
                .none => {},
            }
            continue;
        }
        if (skipped_depth > 0) continue;
        if (!intersects(bounds.get(paint, index, it), cell)) continue;
        // Mutable external images may change without a paint change.
        if (it.kind == .image and it.icon_rep_ptr == null) return null;
        // Another sprite's animation would be baked in still.
        if (own_opt) |own| if (own.isOther(index)) return null;
        if (allocator) |a| try out.append(a, it.*);
        kept += 1;
        hashRelative(&hasher, it, cell);
        if (debugEnabled()) {
            var one = std.hash.Wyhash.init(0);
            fingerprint.hashCaretPaintItemInto(&one, it);
            std.debug.print("[sprite] bg item {s} geom=({d:.1},{d:.1},{d:.1},{d:.1}) hash={x}\n", .{ @tagName(it.kind), it.geom.x, it.geom.y, it.geom.w, it.geom.h, one.final() });
        }
    }
    return .{ .items = out.items, .digest = hasher.final(), .own_at = own_at orelse kept };
}

/// Whether the sprite's own items start inside the subtree opened at `open`
/// and closed at `close`.
fn ownWithin(own_opt: ?Own, open: usize, close: usize) bool {
    const own = own_opt orelse return false;
    return own.range[0] > open and own.range[0] < close;
}

/// Hash a background item relative to the cell origin, so identical
/// backgrounds at different positions share one atlas (a page of identical
/// loading buttons). Cell origins are whole device pixels, so a translated
/// item rasterizes identically. Items whose pixels depend on more than their
/// geometry (free paths, transforms, noise patterns tied to screen position)
/// keep their absolute position in the key.
fn hashRelative(hasher: *std.hash.Wyhash, it: anytype, cell: [4]f32) void {
    const relative = !it.use_draw_transform and it.noise_mode == 0 and switch (it.kind) {
        .path => it.arc_outer_radius > 0,
        else => true,
    };
    var geom = it.geom;
    if (relative) {
        geom.x -= cell[0];
        geom.y -= cell[1];
    } else hasher.update(std.mem.asBytes(&cell));
    fingerprint.hashCaretPaintItemWithGeomInto(hasher, it, geom);
}

/// What a group paints over the cell. Glass samples a margin around it but
/// paints only its written area and children (cpu_patch.glassPaintBounds).
fn groupPaintBounds(paint: anytype, index: usize, it: anytype) [4]f32 {
    if (it.control_kind == .begin_blur_layer) return @import("cpu_patch.zig").glassPaintBounds(paint, index);
    return fingerprint.inkWorldBounds(it);
}

fn intersects(a: [4]f32, b: [4]f32) bool {
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3];
}

fn atlasFor(renderer: anytype, cx: anytype, p: anytype, background: anytype, paint: anytype, bounds: *BoundsCache) ?*Atlas {
    const host = &renderer.sprite_host;
    const key = if (background) |bg| std.hash.Wyhash.hash(bg.digest, std.mem.asBytes(&p.key)) else p.key;
    for (host.atlases.items) |*atlas| {
        if (atlas.key == key) {
            atlas.last_used = host.clock;
            return atlas;
        }
    }
    if (debugEnabled()) std.debug.print("[sprite] node={d} atlas build key={x} opaque={} frames={d}\n", .{ p.node_id, key, background != null, p.frame_count });
    const frames = cx.sprites.generate(cx.allocator, cx.frame_arena.allocator(), p) catch return null;
    // The digest pass kept no items; collect them now for the one build.
    const items = if (background != null) blk: {
        const full = (backgroundOf(cx.frame_arena.allocator(), paint, bounds, p, ownRange(cx, p)) catch null) orelse return null;
        std.debug.assert(full.digest == background.?.digest);
        break :blk full.items;
    } else null;
    var atlas = buildMacos(renderer, p, frames, items, key) catch |err| {
        cx.sprites.host_error = @errorName(err);
        if (debugEnabled()) std.debug.print("[sprite] node={d} atlas failed: {s}\n", .{ p.node_id, @errorName(err) });
        return null;
    };
    atlas.last_used = host.clock;
    atlas.is_opaque = background != null;
    host.allocator = renderer.allocator;
    host.atlases.append(renderer.allocator, atlas) catch {
        Host.release(renderer.allocator, &atlas);
        return null;
    };
    return &host.atlases.items[host.atlases.items.len - 1];
}

fn buildMacos(renderer: anytype, p: anytype, frames: anytype, items: anytype, key: u64) !Atlas {
    const size = p.atlasSizePx();
    var texture_raw: ?*anyopaque = null;
    const surface = macos_sprite_atlas_create(@ptrCast(renderer.surface.layer), size[0], size[1], &texture_raw) orelse return error.SpriteAtlasUnavailable;
    var atlas: Atlas = .{
        .key = key,
        .surface = surface,
        .texture = .{
            .raw = @ptrCast(@alignCast(texture_raw orelse {
                macos_sprite_atlas_release(surface);
                return error.SpriteAtlasUnavailable;
            })),
            .format = .bgra8_unorm,
            .size = .{ .width = size[0], .height = size[1], .depth = 1 },
            .mip_level_count = 1,
            .dimension = .@"2d",
            .memory = .host_upload,
        },
        .size = size,
        .last_used = 0,
        .is_opaque = false,
    };
    errdefer Host.release(renderer.allocator, &atlas);
    try renderer.renderSpriteAtlas(&atlas.texture, atlas.surface, frames, items, p);
    return atlas;
}

const AtlasLookup = union(enum) { ready: *Atlas, pending, failed };

fn atlasKey(digest: u64, p: anytype) u64 {
    var h = std.hash.Wyhash.init(digest);
    h.update(std.mem.asBytes(&p.key));
    h.update(std.mem.asBytes(&p.cell_px));
    const tile = tileSize();
    h.update(std.mem.asBytes(&tile));
    return h.final();
}

/// Test harness: tile edge for new atlases (0: sprite_tiles.tile_px).
pub var tile_override: u32 = 0;
fn tileSize() u32 {
    return if (tile_override != 0) tile_override else tiles.tile_px;
}

/// The placement cut to the window's pixels, or null when none is visible.
fn visiblePart(renderer: anytype, p: anytype) ?@TypeOf(p) {
    const config = renderer.surface.config orelse return null;
    const x0 = @max(p.origin_px[0], 0);
    const y0 = @max(p.origin_px[1], 0);
    const x1 = @min(p.origin_px[0] + @as(i32, @intCast(p.cell_px[0])), @as(i32, @intCast(config.width)));
    const y1 = @min(p.origin_px[1] + @as(i32, @intCast(p.cell_px[1])), @as(i32, @intCast(config.height)));
    if (x1 <= x0 or y1 <= y0) return null;
    var out = p;
    out.origin_px = .{ x0, y0 };
    out.cell_px = .{ @intCast(x1 - x0), @intCast(y1 - y0) };
    return out;
}

/// Windows: the placement's atlas, or its build advanced by this frame's share.
fn windowsAtlas(renderer: anytype, cx: anytype, p: anytype, background: anytype, paint: anytype, bounds: *BoundsCache) AtlasLookup {
    const host = &renderer.sprite_host;
    const key = atlasKey(background.digest, p);
    for (host.atlases.items) |*atlas| {
        if (atlas.key == key) {
            atlas.last_used = host.clock;
            return .{ .ready = atlas };
        }
    }
    host.allocator = renderer.allocator;
    // A build that failed fails again: keep the node on the GPU path.
    for (host.failed_keys) |failed| if (failed == key) return .failed;
    const Kind = BuildFor(@TypeOf(cx));
    const entry: *build.Entry = for (host.builds.items) |*b| {
        if (b.key == key) break b;
    } else blk: {
        if (host.builds.items.len >= max_builds) return .pending;
        // Only content that held still for a frame: a background that keeps
        // changing (an animation under the cell) would restart a build every
        // frame.
        if (!host.noteCandidate(p.node_id, key)) return .pending;
        if (debugEnabled()) std.debug.print("[sprite] node={d} atlas build key={x} frames={d}\n", .{ p.node_id, key, p.frame_count });
        const frames = cx.sprites.generate(cx.allocator, cx.frame_arena.allocator(), p) catch |err| return fail(cx, err);
        // The digest pass kept no items; collect them now for the build.
        const full = (backgroundOf(cx.frame_arena.allocator(), paint, bounds, p, ownRange(cx, p)) catch |err| return fail(cx, err)) orelse return .failed;
        std.debug.assert(full.digest == background.digest);
        const config = renderer.surface.config orelse return .failed;
        const corner: [2]u32 = .{ @as(u32, @intCast(p.origin_px[0])) + p.cell_px[0], @as(u32, @intCast(p.origin_px[1])) + p.cell_px[1] };
        if (corner[0] > config.width or corner[1] > config.height) return .failed;
        const scratch = host.scratch.cover(renderer, corner) catch |err| return fail(cx, err);
        const started = Kind.start(renderer, scratch, key, p, frames, full.items, full.own_at, tileSize(), host.clock) catch |err| {
            host.noteFailed(key);
            return fail(cx, err);
        };
        host.builds.append(renderer.allocator, started) catch {
            started.destroy(renderer.allocator);
            return .failed;
        };
        break :blk &host.builds.items[host.builds.items.len - 1];
    };
    entry.seen = host.clock;
    const b = Kind.of(entry.*);
    const done = b.collect() catch |err| {
        removeBuild(renderer, key);
        host.noteFailed(key);
        return fail(cx, err);
    };
    if (!done) return .pending;
    defer removeBuild(renderer, key);
    var compacted = b.finish() catch |err| {
        host.noteFailed(key);
        return fail(cx, err);
    };
    const atlas = uploadAtlas(renderer, &compacted, key, p) catch |err| {
        compacted.deinit(renderer.allocator);
        host.noteFailed(key);
        return fail(cx, err);
    };
    renderer.allocator.free(compacted.pixels);
    host.atlases.append(renderer.allocator, atlas) catch {
        var dropped = atlas;
        Host.release(renderer.allocator, &dropped);
        return .failed;
    };
    const stored = &host.atlases.items[host.atlases.items.len - 1];
    stored.last_used = host.clock;
    return .{ .ready = stored };
}

var fail_text: [160]u8 = undefined;

fn fail(cx: anytype, err: anyerror) AtlasLookup {
    // A rejected draw is counted, not returned: name it.
    const detail: []const u8 = if (comptime windows) gpu.Backend.RenderPass.last_error else "";
    cx.sprites.host_error = std.fmt.bufPrint(&fail_text, "{s}{s}{s}", .{ @errorName(err), if (detail.len != 0) ": " else "", detail }) catch @errorName(err);
    if (debugEnabled()) std.debug.print("[sprite] atlas failed: {s}\n", .{cx.sprites.host_error});
    return .failed;
}

fn removeBuild(renderer: anytype, key: u64) void {
    const host = &renderer.sprite_host;
    for (host.builds.items, 0..) |entry, i| if (entry.key == key) {
        _ = host.builds.swapRemove(i);
        entry.destroy(renderer.allocator);
        break;
    };
    if (host.builds.items.len == 0) host.scratch.release();
}

/// The build type for a Cx (its registry's placement and paint item types).
fn BuildFor(comptime CxPtr: type) type {
    const Cx = @typeInfo(CxPtr).pointer.child;
    return build.Build(@FieldType(Cx, "sprites"));
}

/// Windows: put a compacted flipbook in a composition swap chain. Takes the
/// layout arrays on success (the caller frees the pixels).
fn uploadAtlas(renderer: anytype, compacted: *tiles.Compact, key: u64, p: anytype) !Atlas {
    dumpCompact(renderer, compacted, p);
    var surface = try gpu.Backend.SpriteAtlas.create(renderer.device, compacted.width, compacted.height, gpu.color_format);
    errdefer surface.destroy();
    try surface.texture.writeRegion(0, 0, 0, compacted.width, compacted.height, compacted.pixels, compacted.width * 4);
    // Submit the recorded upload; the present is queued behind it.
    var encoder = try gpu.Backend.CommandEncoder.init(renderer.queue);
    var command = encoder.finish() catch |err| {
        encoder.deinit();
        return err;
    };
    defer command.deinit();
    try command.submitChecked();
    try surface.present();
    if (debugEnabled()) std.debug.print("[sprite] node={d} compact {d}x{d} ({d} KiB, flipbook {d} KiB) tiles={d} entries={d}\n", .{ p.node_id, compacted.width, compacted.height, compacted.bytes() / 1024, @as(u64, p.cell_px[0]) * p.cell_px[1] * 4 * p.frame_count / 1024, compacted.tiles.len, compacted.entries });
    return .{
        .key = key,
        .surface = surface,
        .texture = {},
        .size = .{ compacted.width, compacted.height },
        .last_used = 0,
        .is_opaque = true,
        .layout = .{
            .tiles = compacted.tiles,
            .frames = compacted.frames,
            .frame_count = compacted.frame_count,
            .columns = compacted.columns,
            .tiles_top = compacted.tiles_top,
            .tile = compacted.tile,
        },
    };
}

pub const FlipbookInfo = struct { origin: [2]i32, cell: [2]u32, columns: u32, frames: u32, period_ms: f64 };

/// Test harness (Windows): write active placement `index`'s flipbook, as the
/// atlas build renders it, to an RGBA PNG (frame f's cell at
/// ((f % columns) * cell[0], (f / columns) * cell[1])).
pub fn writeFlipbookPng(renderer: anytype, cx: anytype, index: u32, chunk: u32, path: [:0]const u8) !FlipbookInfo {
    if (comptime !windows) return error.Unsupported;
    var seen: u32 = 0;
    const p = for (cx.sprites.placements.items) |p| {
        if (p.exiting) continue;
        if (seen == index) break p;
        seen += 1;
    } else return error.NoSuchSprite;
    const paint = cx.lowerForEncoderPaintTable();
    var bounds = BoundsCache.init(cx.frame_arena.allocator(), paint);
    const background = (try backgroundOf(cx.frame_arena.allocator(), paint, &bounds, p, ownRange(cx, p))) orelse return error.TransparentSprite;
    const frames = try cx.sprites.generate(cx.allocator, cx.frame_arena.allocator(), p);
    const allocator = renderer.allocator;
    const corner: [2]u32 = .{ @as(u32, @intCast(p.origin_px[0])) + p.cell_px[0], @as(u32, @intCast(p.origin_px[1])) + p.cell_px[1] };
    var scratch = try renderer.device.createTexture(allocator, .{
        .label = "Zenit.Sprite.FlipbookProbe",
        .size = .{ .width = corner[0], .height = corner[1] },
        .format = gpu.color_format,
        .usage = .{ .copy_src = true, .texture_binding = true, .render_attachment = true },
        .memory = .device_local,
    });
    defer scratch.destroy();
    const layout = try scratch.inner.copyLayout(.{ .x = @intCast(p.origin_px[0]), .y = @intCast(p.origin_px[1]), .width = p.cell_px[0], .height = p.cell_px[1] }, 0);
    const frame_stride = std.mem.alignForward(u64, layout.required_bytes, 512);
    // `chunk` frames per submission through one reused buffer, as atlas builds
    // do (0: every frame at once).
    const per: u32 = if (chunk == 0) p.frame_count else @min(chunk, p.frame_count);
    var readback = try renderer.device.createBuffer(allocator, .{ .size = frame_stride * per, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    const all = try allocator.alloc(u8, frame_stride * p.frame_count);
    defer allocator.free(all);
    var first: u32 = 0;
    while (first < p.frame_count) {
        const count = @min(per, p.frame_count - first);
        var command = try renderer.renderSpriteFrames(&scratch, &readback, layout.row_pitch, frame_stride, frames, background.items, background.own_at, p, first, count);
        defer command.deinit();
        try command.waitChecked(renderer.device.context.timeout_ms);
        const part = try readback.getMappedRange(0, frame_stride * per);
        @memcpy(all[first * frame_stride ..][0 .. count * frame_stride], part[0 .. count * frame_stride]);
        first += count;
    }
    const mapped = all;
    const size = p.atlasSizePx();
    const stride = size[0] * 4;
    const pixels = try allocator.alloc(u8, @as(usize, stride) * size[1]);
    defer allocator.free(pixels);
    @memset(pixels, 0);
    const cw = p.cell_px[0];
    for (0..p.frame_count) |f| {
        const x = (f % p.columns) * cw;
        const y = (f / p.columns) * p.cell_px[1];
        for (0..p.cell_px[1]) |row| {
            const src = mapped[f * frame_stride + row * layout.row_pitch ..][0 .. cw * 4];
            const dst = pixels[(y + row) * stride + x * 4 ..][0 .. cw * 4];
            for (0..cw) |i| dst[i * 4 ..][0..4].* = .{ src[i * 4 + 2], src[i * 4 + 1], src[i * 4], src[i * 4 + 3] };
        }
    }
    if (!gpu.Backend.writePngRgba(path, pixels, size[0], size[1], stride)) return error.PngWriteFailed;
    return .{ .origin = p.origin_px, .cell = p.cell_px, .columns = p.columns, .frames = p.frame_count, .period_ms = p.period_ms };
}

/// Test harness (Windows): when set, every compacted atlas is also written
/// as `<dir>/atlas-<node>.png` (RGBA) with its tile layout in `.json`.
pub var dump_dir_buf: [512]u8 = undefined;
pub var dump_dir: ?[]const u8 = null;

fn dumpCompact(renderer: anytype, compacted: *const tiles.Compact, p: anytype) void {
    const dir = dump_dir orelse return;
    const allocator = renderer.allocator;
    const rgba = allocator.dupe(u8, compacted.pixels) catch return;
    defer allocator.free(rgba);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) std.mem.swap(u8, &rgba[i], &rgba[i + 2]);
    var name_buf: [600]u8 = undefined;
    const png = std.fmt.bufPrintSentinel(&name_buf, "{s}/atlas-{d}.png", .{ dir, p.node_id }, 0) catch return;
    _ = gpu.Backend.writePngRgba(png, rgba, compacted.width, compacted.height, compacted.width * 4);
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    std.json.Stringify.value(.{ .width = compacted.width, .height = compacted.height, .cell = p.cell_px, .columns = compacted.columns, .tiles_top = compacted.tiles_top, .tile_px = compacted.tile, .frame_count = compacted.frame_count, .tiles = compacted.tiles, .frames = compacted.frames }, .{}, &json.writer) catch return;
    var json_name: [600]u8 = undefined;
    const json_path = std.fmt.bufPrint(&json_name, "{s}/atlas-{d}.json", .{ dir, p.node_id }) catch return;
    std.Io.Dir.cwd().writeFile(renderer.io, .{ .sub_path = json_path, .data = json.written() }) catch {};
}
