//! CPU damage patches. A frame whose visual change is a small region of flat
//! content (typing, a caret move, hover colour) is rasterized on the CPU from
//! the frame's own paint into an opaque IOSurface patch shown above the window
//! surface; no GPU command is submitted. Any in-process GPU submission keeps
//! the driver's per-process working set (~225 MiB on Apple GPUs) resident for
//! about a second, so interactive bursts otherwise pin it continuously.
//!
//! Correctness contract:
//! - Damage is the union of the changed paint between the last presented frame
//!   and this one (index-aligned digests; effect/clip groups collapse into one
//!   entry bounded by the group's draw rectangle).
//! - The patch re-renders its whole rectangle from scratch with every paint
//!   item that reaches it, in order, through the encoder's own instance
//!   batches executed by render/cpu_flat.zig (Metal shader arithmetic). Any
//!   effect, image, path or unsupported primitive reaching the rectangle sends
//!   the frame to the GPU instead.
//! - The next GPU frame presents its drawable and removes all patches in one
//!   Core Animation transaction.
//! - A frame whose paint is identical to the presented one (and has no mutable
//!   external image) presents nothing: the screen already shows it.
//! - Glass needs the GPU, but its composite only depends on the glass token
//!   and what was painted under its capture rect before it. GPU frames copy
//!   each main-target glass result out (Underlay); a patch reaching the glass
//!   reuses the pixels the composite wrote byte for byte, then draws the glass
//!   group's children over them on the CPU. Reuse needs the paint under the
//!   written area unchanged; a change only in the sampled margin around it
//!   (which a wide blur sees, typically below one 8-bit level) is presented
//!   with the previous glass and marks the glass for a GPU refresh frame once
//!   patches stop (glass_refresh_delay_ns): the screen converges to the GPU
//!   image exactly.
const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const render = @import("render");
const fp = render.PaintFingerprint;
const cpu_flat = render.cpu_flat;

pub const supported = builtin.os.tag == .macos and gpu.backend_kind == .metal;

extern fn metal_cpu_flat_cache_create() ?*anyopaque;
extern fn metal_cpu_flat_cache_destroy(?*anyopaque) void;
extern fn metal_cpu_flat_begin_patch(layer: *anyopaque, clear: *const [4]f32, cache: ?*anyopaque, x: c_uint, y: c_uint, w: c_uint, h: c_uint, window_w: c_uint, window_h: c_uint) ?*anyopaque;
extern fn metal_cpu_flat_begin_patch_into(surface: *anyopaque, sx: c_uint, sy: c_uint, clear: *const [4]f32, cache: ?*anyopaque, x: c_uint, y: c_uint, w: c_uint, h: c_uint, window_w: c_uint, window_h: c_uint) ?*anyopaque;
extern fn metal_cpu_flat_end_patch(frame: *anyopaque, keep: bool, out: *?*anyopaque) c_int;
extern fn macos_patch_put(layer: *anyopaque, surface: *anyopaque, x: c_uint, y: c_uint, w: c_uint, h: c_uint, scale: f64) c_uint;
extern fn macos_patches_begin_gpu_handoff(layer: *anyopaque) c_int;
extern fn macos_patches_end_gpu_handoff(layer: *anyopaque, remove: c_int) void;
extern fn macos_patches_clear(layer: *anyopaque) void;
extern fn macos_patch_copy_to_texture(surface: *anyopaque, texture: *anyopaque, x: c_uint, y: c_uint, w: c_uint, h: c_uint) c_int;
extern fn macos_sprite_atlas_release(surface: ?*anyopaque) void;
extern fn metal_glass_clock_trace_patch(w: c_uint, h: c_uint) void;
extern fn metal_glass_clock_trace_line(line: [*]const u8, length: usize) void;
extern fn metal_glass_clock_trace_host_time() f64;
extern fn metal_glass_clock_trace_enabled() bool;
extern fn metal_cpu_flat_blit(frame: *anyopaque, texture: *anyopaque, tx: c_uint, ty: c_uint, x: c_uint, y: c_uint, w: c_uint, h: c_uint) c_int;

/// Largest patch, in device pixels, worth rasterizing on the CPU (about
/// 1-5 ms for flat content; a list viewport scrolls within it).
pub const max_patch_pixels: u64 = 1 << 20;
/// Patches stacked above the surface before a GPU frame consolidates them.
pub const max_patches: u32 = 24;

/// A patch is worth it only when it costs the CPU no more than the GPU path
/// would for the same frame (its encode and submit), and never more than a
/// third of a refresh period. Everything else goes to the GPU: a CPU-presented
/// scroll at 30 fps and 95% CPU is worse than a GPU one at 60 fps and 15%.
const frame_budget_share = 1.0 / 3.0;
const seed_gpu_frame_ns: f64 = 1.5e6;

/// Patch cost = fixed + per pixel. Small patches (a caret) are almost all
/// fixed cost (surface, hand-off) and teach only that; larger ones teach the
/// per-pixel rate net of it. A single per-pixel rate learned from a caret
/// would price a text line at tens of milliseconds.
const PatchCost = struct {
    const small_pixels: u64 = 16 * 1024;
    fixed_ns: f64 = 250e3,
    ns_per_pixel: f64 = 6.0,

    fn predict(self: PatchCost, pixels: u64) f64 {
        return self.fixed_ns + self.ns_per_pixel * @as(f64, @floatFromInt(pixels));
    }

    fn learn(self: *PatchCost, ns: u64, pixels: u64) void {
        const total: f64 = @floatFromInt(ns);
        if (pixels < small_pixels) {
            self.fixed_ns = self.fixed_ns * 0.6 + total * 0.4;
        } else {
            const sample = @max(total - self.fixed_ns, 0) / @as(f64, @floatFromInt(pixels));
            self.ns_per_pixel = self.ns_per_pixel * 0.6 + sample * 0.4;
        }
    }
};

fn budgetNs(gpu_frame_ns: f64, refresh_hz: f64) f64 {
    if (budgetOverrideUs()) |us| return @as(f64, @floatFromInt(us)) * 1e3;
    return @min(gpu_frame_ns, 1e9 / @max(refresh_hz, 1.0) * frame_budget_share);
}

/// ZENIT_CPU_PATCH_BUDGET_US: fixed budget (raster-correctness checks that
/// patch regions the default policy hands to the GPU).
fn budgetOverrideUs() ?u64 {
    const S = struct {
        var read = false;
        var value: ?u64 = null;
    };
    if (!S.read) {
        S.read = true;
        if (std.c.getenv("ZENIT_CPU_PATCH_BUDGET_US")) |v| S.value = std.fmt.parseInt(u64, std.mem.span(v), 10) catch null;
    }
    return S.value;
}

fn maxPatchPixels() u64 {
    const S = struct {
        var cached: ?u64 = null;
    };
    if (S.cached == null) S.cached = if (std.c.getenv("ZENIT_CPU_PATCH_MAX_PIXELS")) |v| std.fmt.parseInt(u64, std.mem.span(v), 10) catch max_patch_pixels else max_patch_pixels;
    return S.cached.?;
}

/// `first`: index of the entry's first paint item (diagnostics).
pub const Entry = struct { digest: u64, bounds: [4]f32, first: u32 = 0 };

pub const Outcome = enum { presented, gpu };

/// Copy of a glass composite's capture rect from a GPU frame. Kept volatile
/// (outside the footprint) except while the GPU writes it or a patch reads it.
pub const Underlay = struct {
    texture: gpu.Backend.Texture,
    /// Capture rect (device px); texel (0,0) is its origin.
    rect: [4]u32,
    /// Pixels the composite writes (device px, inside `rect`).
    write_rect: [4]u32,
    /// underlayKey over `rect` (everything sampled) and over `write_rect`.
    key: u64,
    key_core: u64,
    /// GPU frame (Patcher.gpu_frames) that last wrote or confirmed it.
    frame: u64,
};

/// Underlay capture contract for one GPU frame (command_encoder.GlassCapture).
pub fn GlassCaptureContext(comptime Item: type) type {
    return struct {
        patcher: *Patcher,
        device: *gpu.Backend.Device,
        allocator: std.mem.Allocator,
        items: []const Item,
        scale: f32,

        pub fn target(ctx: *anyopaque, item: *const anyopaque, rect: [4]u32) ?gpu.Backend.TextureBinding {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const offset = @intFromPtr(item) -% @intFromPtr(self.items.ptr);
            if (offset % @sizeOf(Item) != 0 or offset / @sizeOf(Item) >= self.items.len) return null;
            const index = offset / @sizeOf(Item);
            const write_rect = writeRect(self.items[index], rect, self.scale);
            const key = underlayKey(self.items, index, rect, self.scale);
            const key_core = underlayKey(self.items, index, write_rect, self.scale);
            return self.patcher.captureSlot(self.device, self.allocator, key, key_core, rect, write_rect);
        }
    };
}

pub const Patcher = struct {
    enabled: bool = false,
    previous: std.ArrayList(Entry) = .empty,
    current: std.ArrayList(Entry) = .empty,
    previous_valid: bool = false,
    previous_key: u64 = 0,
    cache: ?*anyopaque = null,
    shown: u32 = 0,
    /// Window device-pixel rectangles of the patches shown (mirrors the
    /// native container: a new patch drops the ones it fully covers).
    shown_rects: [max_patches][4]u32 = undefined,
    shown_count: u32 = 0,
    handoff: bool = false,
    cpu_frames: u64 = 0,
    gpu_frames: u64 = 0,
    unchanged_frames: u64 = 0,
    consolidations: u64 = 0,
    last_reason: []const u8 = "",
    underlays: std.ArrayList(Underlay) = .empty,
    /// A patch reused glass whose sampled margin changed: a GPU frame must
    /// recomposite it once patches stop (runtime schedules it).
    glass_stale: bool = false,
    /// Set by the runtime: the next frame goes to the GPU.
    /// The next frame goes to the GPU (glass refresh, caret handoff); cleared
    /// once a GPU frame is presented.
    force_gpu: bool = false,
    /// Whether this GPU frame copies glass underlays for later patches (see
    /// capturesAfter).
    capture_underlays: bool = true,
    /// patchOps met glass without a usable underlay.
    missing_underlay: bool = false,
    /// GPU frames in a row ending with the previous frame, and when that
    /// frame started (see inMotion).
    gpu_run: u32 = 0,
    last_frame_at: ?@import("zenit_time").Instant = null,
    /// Last layer-motion generation seen (Cx.layerMotionGen) and when it
    /// last advanced (see inMotion).
    motion_gen: u64 = 0,
    last_motion_at: ?@import("zenit_time").Instant = null,
    /// Measured CPU cost of presenting a patch (raster and hand-off), smoothed.
    cost: PatchCost = .{},
    /// CPU time the GPU path spends on a frame beyond layout and paint
    /// (encode + submit), smoothed over recent GPU frames.
    gpu_frame_ns: f64 = seed_gpu_frame_ns,
    gpu_frame_seen: u64 = 0,

    pub fn deinit(self: *Patcher, allocator: std.mem.Allocator, layer: *anyopaque) void {
        if (comptime supported) {
            if (self.shown != 0) macos_patches_clear(layer);
            if (self.cache) |cache| metal_cpu_flat_cache_destroy(cache);
        }
        for (self.underlays.items) |*u| u.texture.destroy();
        self.underlays.deinit(allocator);
        self.previous.deinit(allocator);
        self.current.deinit(allocator);
        self.* = .{};
    }

    /// Destination for this GPU frame's copy of a glass result; null when an
    /// identical one is already held (nothing to copy) or on failure.
    fn captureSlot(self: *Patcher, device: *gpu.Backend.Device, allocator: std.mem.Allocator, key: u64, key_core: u64, rect: [4]u32, write_rect: [4]u32) ?gpu.Backend.TextureBinding {
        if (rect[2] == 0 or rect[3] == 0) return null;
        // Always copy, even under an unchanged key: GPU-side glass state
        // (blur level hysteresis) may differ between GPU frames, and the copy
        // must match the latest presented one. Reuse a slot of the same size.
        for (self.underlays.items) |*u| if (u.frame != self.gpu_frames and u.rect[2] == rect[2] and u.rect[3] == rect[3]) {
            _ = u.texture.setVolatile(false);
            u.* = .{ .texture = u.texture, .rect = rect, .write_rect = write_rect, .key = key, .key_core = key_core, .frame = self.gpu_frames };
            return u.texture.binding();
        };
        const texture = device.createTexture(allocator, .{
            .label = "Zenit.CpuPatch.GlassUnderlay",
            .size = .{ .width = rect[2], .height = rect[3] },
            .format = gpu.color_format,
            .usage = .{ .copy_dst = true },
            .memory = .host_upload,
        }) catch return null;
        self.underlays.append(allocator, .{ .texture = texture, .rect = rect, .write_rect = write_rect, .key = key, .key_core = key_core, .frame = self.gpu_frames }) catch {
            var t = texture;
            t.destroy();
            return null;
        };
        return texture.binding();
    }

    /// After a presented GPU frame: glass no longer composited is dropped.
    fn retireUnderlays(self: *Patcher) void {
        var i: usize = 0;
        while (i < self.underlays.items.len) {
            if (self.underlays.items[i].frame != self.gpu_frames) {
                self.underlays.items[i].texture.destroy();
                _ = self.underlays.swapRemove(i);
            } else i += 1;
        }
    }

    /// Underlay reusable for the glass token at `items[index]`, made resident.
    /// `stale`: only the sampled margin changed since it was written.
    fn underlayFor(self: *Patcher, items: anytype, index: usize, scale: f32, stale: *bool) ?usize {
        for (self.underlays.items, 0..) |*u, i| {
            if (u.key_core == 0 or u.key_core != underlayKey(items, index, u.write_rect, scale)) continue;
            stale.* = u.key != underlayKey(items, index, u.rect, scale);
            // Contents discarded while volatile: the GPU must redraw it.
            if (u.texture.setVolatile(false)) {
                u.key = 0;
                u.key_core = 0;
                return null;
            }
            return i;
        }
        return null;
    }

    pub fn trimIdle(self: *Patcher) void {
        for (self.underlays.items) |*u| _ = u.texture.setVolatile(true);
    }

    /// The frame is going to the GPU. Its paint becomes the baseline once it
    /// is presented; patches are removed in the same CA transaction.
    pub fn beginGpuFrame(self: *Patcher, layer: *anyopaque) void {
        if (comptime !supported) return;
        self.gpu_frames += 1;
        self.handoff = self.shown != 0 and macos_patches_begin_gpu_handoff(layer) != 0;
    }

    pub fn endGpuFrame(self: *Patcher, layer: *anyopaque, presented: bool) void {
        if (comptime !supported) return;
        if (self.handoff) {
            macos_patches_end_gpu_handoff(layer, @intFromBool(presented));
            if (presented) {
                self.shown = 0;
                self.shown_count = 0;
            }
            self.handoff = false;
        }
        if (presented) {
            self.commitBaseline();
            self.retireUnderlays();
            // Every glass was recomposited from the current paint.
            self.glass_stale = false;
            self.force_gpu = false;
        } else {
            self.previous_valid = false;
            // A failed frame may have left partial copies.
            for (self.underlays.items) |*u| {
                if (u.frame == self.gpu_frames) {
                    u.key = 0;
                    u.key_core = 0;
                }
            }
        }
    }

    fn noteShown(self: *Patcher, rect: [4]u32) void {
        var kept: usize = 0;
        for (self.shown_rects[0..self.rectCount()]) |r| {
            const covered = r[0] >= rect[0] and r[1] >= rect[1] and r[0] + r[2] <= rect[0] + rect[2] and r[1] + r[3] <= rect[1] + rect[3];
            if (covered) continue;
            self.shown_rects[kept] = r;
            kept += 1;
        }
        self.shown_rects[kept] = rect;
        self.shown_count = @intCast(kept + 1);
    }

    pub fn rectCount(self: *const Patcher) usize {
        return @min(self.shown_count, self.shown);
    }

    fn commitBaseline(self: *Patcher) void {
        std.mem.swap(std.ArrayList(Entry), &self.previous, &self.current);
        self.previous_valid = true;
    }

    fn reject(self: *Patcher, comptime reason: []const u8) Outcome {
        self.last_reason = reason;
        self.capture_underlays = comptime capturesAfter(reason);
        if (debugEnabled()) {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            std.debug.print("[cpu-patch] gpu: {s} t={d}.{d:0>3}\n", .{ reason, ts.sec, @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000))) });
        }
        return .gpu;
    }
};

/// Whether this frame goes to the GPU without a patch decision. Inside a
/// sustained run of GPU frames (`run`: GPU frames in a row before this one,
/// each at most three refresh periods after the previous, so a late frame does
/// not end it) whose last frame could not be a patch (`unpatchable`: a scroll
/// or an animation over the budget, content the CPU cannot draw), the next
/// one cannot either; digesting the paint and diffing it costs every scroll
/// frame 50-100 us for nothing.
///
/// It also renders the frames whose paint equals the presented one there (a
/// scroll whose two coalesced wheel events cancel at a reversal, a scroll
/// pinned at its end). Skipping one would drain the presentation queue: the
/// frames after it reach the screen a vsync earlier than before, until one
/// slower frame slips back to the old depth and the screen holds an image for
/// two vsyncs (measured: 11-34 late frames per 10 s of a 120 Hz scroll under
/// load). Rendering it keeps the queue as the GPU path always did; the GPU is
/// busy anyway, so skipping it saves nothing.
///
/// `moving`: a layer moved (a scroll offset changed) within the last three
/// refresh periods, so a reversal frame whose offset did not change still
/// counts. Without it a run of over-budget keystrokes or animation frames
/// would latch: every later keystroke would skip the decision although its
/// damage may well fit a patch.
fn inMotion(run: u32, unpatchable: bool, moving: bool) bool {
    return moving and unpatchable and run >= sustained_gpu_run;
}

const sustained_gpu_run: u32 = 3;

/// Whether the last layer motion is at most three refresh periods old.
fn recentlyMoved(since_motion_ns: ?u64, period_ns: f64) bool {
    const since = since_motion_ns orelse return false;
    return @as(f64, @floatFromInt(since)) <= period_ns * 3;
}

/// GPU frames in a row before this frame: `run` ends when the previous frame
/// started more than three refresh periods ago.
fn runBefore(run: u32, gap_ns: ?u64, period_ns: f64) u32 {
    const gap = gap_ns orelse return 0;
    return if (@as(f64, @floatFromInt(gap)) <= period_ns * 3) run else 0;
}

/// Whether a GPU frame rejected for `reason` copies glass underlays. A frame
/// whose change could not be a patch (a scroll or an animation too large for
/// the budget, content the CPU cannot draw, live images) is usually followed by
/// more such frames, and copying every glass on each of them only costs GPU
/// time and memory. The first patch that then meets glass without an underlay
/// is rejected ("no glass underlay"), and that GPU frame copies them again.
fn capturesAfter(comptime reason: []const u8) bool {
    const no_patch_follows = [_][]const u8{ "damage too large", "over frame budget", "unsupported content", "mutable image", "undescribed paint", "in motion" };
    for (no_patch_follows) |r| if (std.mem.eql(u8, r, reason)) return false;
    return true;
}

fn debugEnabled() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached == null) S.cached = std.c.getenv("ZENIT_DEBUG_CPU_PATCH") != null;
    return S.cached.?;
}

/// Distance past a shadow shape where coverage drops below half an 8-bit step
/// (SDF shader: smoothstep(blur, -blur, sdf), coverage <= 3t^2 near the edge).
fn shadowReach(blur: f32, alpha_u8: u8) f32 {
    if (blur <= 0) return 0;
    const a = @as(f32, @floatFromInt(alpha_u8)) / 255;
    if (a <= 0) return -blur;
    const t = @sqrt((0.5 / 255.0) / (3 * a));
    return blur * (1 - 2 * @min(t, 0.5));
}

/// Where an item can change pixels. Shadows use their exact ink extent (the
/// generic damage bound pads by twice the blur); everything else the shared
/// conservative bound.
fn inkBounds(it: anytype) [4]f32 {
    if (it.kind == .shadow and it.shadow_secondary_color.a == 0 and it.shadow2_color.a == 0) {
        const reach = @max(0, it.shadow_spread) + shadowReach(it.shadow_blur, it.color.a) + 1;
        if (!it.use_draw_transform) return .{ it.geom.x + it.shadow_offset_x - reach, it.geom.y + it.shadow_offset_y - reach, it.geom.w + 2 * reach, it.geom.h + 2 * reach };
    }
    return fp.inkWorldBounds(it);
}

/// inkBounds, with a text command bounded by its exact glyph ink where known
/// (`text_ink`: AppRenderer.textInkBounds of the frame's items, by index).
fn itemInk(it: anytype, text_ink: ?[]const ?[4]f32, index: usize) [4]f32 {
    if (text_ink) |ink| if (ink[index]) |b| return b;
    return inkBounds(it);
}

fn unionBounds(a: [4]f32, b: [4]f32) [4]f32 {
    if (b[2] <= 0 or b[3] <= 0) return a;
    if (a[2] <= 0 or a[3] <= 0) return b;
    const x = @min(a[0], b[0]);
    const y = @min(a[1], b[1]);
    return .{ x, y, @max(a[0] + a[2], b[0] + b[2]) - x, @max(a[1] + a[3], b[1] + b[3]) - y };
}

fn unionRect(a: [4]u32, b: [4]u32) [4]u32 {
    const x = @min(a[0], b[0]);
    const y = @min(a[1], b[1]);
    return .{ x, y, @max(a[0] + a[2], b[0] + b[2]) - x, @max(a[1] + a[3], b[1] + b[3]) - y };
}

fn intersects(a: [4]f32, b: [4]f32) bool {
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3];
}

fn intersection(a: [4]f32, b: [4]f32) [4]f32 {
    const x = @max(a[0], b[0]);
    const y = @max(a[1], b[1]);
    return .{ x, y, @max(0, @min(a[0] + a[2], b[0] + b[2]) - x), @max(0, @min(a[1] + a[3], b[1] + b[3]) - y) };
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

/// Digest/bounds per top-level paint entry. Returns false when the list
/// cannot be described (unbalanced, too deep, non-finite geometry).
fn buildEntries(out: *std.ArrayList(Entry), allocator: std.mem.Allocator, items: anytype, text_ink: ?[]const ?[4]f32) !bool {
    out.clearRetainingCapacity();
    var clips: [64][4]f32 = undefined;
    var clip_hashes: [64]u64 = undefined;
    var depth: usize = 0;
    var group_depth: usize = 0;
    var group_hash = std.hash.Wyhash.init(0);
    var group_bounds: [4]f32 = .{ 0, 0, 0, 0 };
    var group_first: u32 = 0;
    var group_clips: [64][4]f32 = undefined;
    var group_clip_depth: usize = 0;
    var group_glass = false;
    const infinite: [4]f32 = .{ -1e9, -1e9, 2e9, 2e9 };
    for (items, 0..) |it, index| {
        if (group_depth > 0) {
            group_hash.update(std.mem.asBytes(&fp.itemDigest(it)));
            // Glass draws its children unclipped over the composite: a change
            // reaches their ink as well as the written area.
            if (group_glass) {
                if (it.kind != .control) {
                    group_bounds = unionBounds(group_bounds, intersection(itemInk(it, text_ink, index), group_clips[group_clip_depth]));
                } else if (it.control_kind == .push_clip and group_clip_depth + 1 < group_clips.len) {
                    group_clips[group_clip_depth + 1] = intersection(fp.damageItemBounds(it), group_clips[group_clip_depth]);
                    group_clip_depth += 1;
                } else if (it.control_kind == .pop_clip and group_clip_depth > 0) {
                    group_clip_depth -= 1;
                }
            }
            if (it.kind == .control and isBegin(it.control_kind)) group_depth += 1;
            if (it.kind == .control and isEnd(it.control_kind)) {
                group_depth -= 1;
                if (group_depth == 0) try out.append(allocator, .{ .digest = group_hash.final(), .bounds = group_bounds, .first = group_first });
            }
            continue;
        }
        const clip = if (depth == 0) infinite else clips[depth - 1];
        const seed: u64 = if (depth == 0) 0 else clip_hashes[depth - 1];
        if (it.kind == .control) {
            switch (it.control_kind) {
                .push_clip => {
                    if (depth == clips.len) return false;
                    var h = std.hash.Wyhash.init(seed);
                    h.update(std.mem.asBytes(&fp.itemDigest(it)));
                    clips[depth] = intersection(fp.damageItemBounds(it), clip);
                    clip_hashes[depth] = h.final();
                    depth += 1;
                },
                .pop_clip => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .begin_opacity_layer, .begin_blur_layer, .begin_rounded_clip => {
                    group_hash = std.hash.Wyhash.init(seed);
                    group_hash.update(std.mem.asBytes(&fp.itemDigest(it)));
                    group_glass = it.control_kind == .begin_blur_layer;
                    group_clips[0] = clip;
                    group_clip_depth = 0;
                    // Opacity/rounded-clip groups composite inside their draw
                    // rect; glass writes its written area (its sampled margin
                    // is handled by Underlay keys, not damage).
                    group_bounds = intersection(if (group_glass) fp.glassWrittenBounds(it) else fp.inkWorldBounds(it), clip);
                    group_depth = 1;
                    group_first = @intCast(index);
                },
                else => return false,
            }
            continue;
        }
        const bounds = itemInk(it, text_ink, index);
        for (bounds) |v| if (!std.math.isFinite(v)) return false;
        var h = std.hash.Wyhash.init(seed);
        h.update(std.mem.asBytes(&fp.itemDigest(it)));
        try out.append(allocator, .{ .digest = h.final(), .bounds = intersection(bounds, clip), .first = @intCast(index) });
    }
    return depth == 0 and group_depth == 0;
}

fn same(a: Entry, b: Entry) bool {
    return a.digest == b.digest and std.mem.eql(f32, &a.bounds, &b.bounds);
}

/// Patience diff of entries (shared with the GPU frame damage).
const markKept = render.frame_damage.markKept;

/// Union of changed entries in device pixels; null when nothing changed.
/// Common prefix/suffix are skipped; the rest is diffed (markKept), so an
/// unchanged entry between two edits, or an insertion, damages nothing else.
fn damage(allocator: std.mem.Allocator, previous: []const Entry, current: []const Entry, scale: f32, extent: [2]u32) ?[4]u32 {
    var prefix: usize = 0;
    while (prefix < previous.len and prefix < current.len and same(previous[prefix], current[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < previous.len - prefix and suffix < current.len - prefix and
        same(previous[previous.len - 1 - suffix], current[current.len - 1 - suffix])) suffix += 1;
    const middle = [_][]const Entry{ previous[prefix .. previous.len - suffix], current[prefix .. current.len - suffix] };
    var kept: [2][]bool = .{ &.{}, &.{} };
    defer for (kept) |k| allocator.free(k);
    diff: {
        for (middle, 0..) |side, i| {
            kept[i] = allocator.alloc(bool, side.len) catch break :diff;
            @memset(kept[i], false);
        }
        // Out of memory: every middle entry counts as changed (conservative).
        markKept(allocator, middle[0], middle[1], kept[0], kept[1]) catch {
            @memset(kept[0], false);
            @memset(kept[1], false);
        };
    }
    var lo: [2]f32 = @splat(std.math.inf(f32));
    var hi: [2]f32 = @splat(-std.math.inf(f32));
    for (middle, 0..) |changed, side| {
        for (changed, 0..) |e, i| {
            if (i < kept[side].len and kept[side][i]) continue;
            if (e.bounds[2] <= 0 or e.bounds[3] <= 0) continue;
            for (0..2) |axis| {
                lo[axis] = @min(lo[axis], e.bounds[axis]);
                hi[axis] = @max(hi[axis], e.bounds[axis] + e.bounds[axis + 2]);
            }
        }
    }
    if (!std.math.isFinite(lo[0])) return null;
    var rect: [4]u32 = undefined;
    for (extent, 0..) |limit, axis| {
        const maximum: f32 = @floatFromInt(limit);
        const start: u32 = @intFromFloat(@floor(std.math.clamp(lo[axis] * scale - 1, 0, maximum)));
        const end: u32 = @intFromFloat(@ceil(std.math.clamp(hi[axis] * scale + 1, 0, maximum)));
        rect[axis] = start;
        rect[axis + 2] = end -| start;
    }
    return rect;
}

/// Device-pixel rect a glass composite writes, inside its capture rect.
fn writeRect(it: anytype, capture: [4]u32, scale: f32) [4]u32 {
    const w = fp.glassWrittenBounds(it);
    const x0 = @max(@as(f32, @floatFromInt(capture[0])), @floor(w[0] * scale));
    const y0 = @max(@as(f32, @floatFromInt(capture[1])), @floor(w[1] * scale));
    const x1 = @min(@as(f32, @floatFromInt(capture[0] + capture[2])), @ceil((w[0] + w[2]) * scale));
    const y1 = @min(@as(f32, @floatFromInt(capture[1] + capture[3])), @ceil((w[1] + w[3]) * scale));
    if (!(x1 > x0 and y1 > y0)) return .{ capture[0], capture[1], 0, 0 };
    return .{ @intFromFloat(x0), @intFromFloat(y0), @intFromFloat(x1 - x0), @intFromFloat(y1 - y0) };
}

fn regionOf(rect: [4]u32, scale: f32) [4]f32 {
    return .{
        @as(f32, @floatFromInt(rect[0])) / scale,
        @as(f32, @floatFromInt(rect[1])) / scale,
        @as(f32, @floatFromInt(rect[2])) / scale,
        @as(f32, @floatFromInt(rect[3])) / scale,
    };
}

/// What a glass composite at `items[index]` produced inside `rect` (device
/// px) depends on: the token itself and every item painted before it that can
/// reach the rect (clips and groups reaching it with all their contents).
fn underlayKey(items: anytype, index: usize, rect: [4]u32, scale: f32) u64 {
    const region = regionOf(rect, scale);
    var h = std.hash.Wyhash.init(0x676c);
    h.update(std.mem.asBytes(&rect));
    h.update(std.mem.asBytes(&scale));
    h.update(std.mem.asBytes(&fp.itemDigest(items[index])));
    // 0: walking; >0: inside a reaching group/clip (hash everything) or a
    // skipped one (hash nothing), by `skipping`.
    var depth: usize = 0;
    var skipping = false;
    for (items[0..index]) |it| {
        const opens = it.kind == .control and (it.control_kind == .push_clip or isBegin(it.control_kind));
        const closes = it.kind == .control and (it.control_kind == .pop_clip or isEnd(it.control_kind));
        if (depth > 0) {
            if (!skipping) h.update(std.mem.asBytes(&fp.itemDigest(it)));
            if (opens) depth += 1;
            if (closes) depth -= 1;
            continue;
        }
        if (opens) {
            const bounds = fp.inkWorldBounds(it);
            skipping = !intersects(bounds, region);
            if (!skipping) h.update(std.mem.asBytes(&fp.itemDigest(it)));
            depth = 1;
            // A group still open at `index` contains the glass: the token
            // itself is hashed above (its clip shapes the composite).
            continue;
        }
        if (closes) {
            // Closes a clip/group opened before the walk window started:
            // structure changes are content changes.
            h.update(std.mem.asBytes(&fp.itemDigest(it)));
            continue;
        }
        if (intersects(inkBounds(it), region)) h.update(std.mem.asBytes(&fp.itemDigest(it)));
    }
    return h.final();
}

/// Pixels a glass group at `items[begin]` paints: what its composite writes
/// and its children's ink (drawn unclipped over it).
pub fn glassPaintBounds(items: anytype, begin: usize) [4]f32 {
    var bounds = fp.glassWrittenBounds(items[begin]);
    var depth: usize = 0;
    var clips: [64][4]f32 = undefined;
    clips[0] = .{ -1e9, -1e9, 2e9, 2e9 };
    var clip_depth: usize = 0;
    for (items[begin..]) |it| {
        if (it.kind == .control) {
            if (isBegin(it.control_kind)) depth += 1;
            if (isEnd(it.control_kind)) {
                depth -= 1;
                if (depth == 0) break;
            }
            if (it.control_kind == .push_clip) {
                if (clip_depth + 1 == clips.len) return .{ -1e9, -1e9, 2e9, 2e9 };
                clips[clip_depth + 1] = intersection(fp.damageItemBounds(it), clips[clip_depth]);
                clip_depth += 1;
            } else if (it.control_kind == .pop_clip and clip_depth > 0) clip_depth -= 1;
            continue;
        }
        bounds = unionBounds(bounds, intersection(inkBounds(it), clips[clip_depth]));
    }
    return bounds;
}

fn PatchOp(comptime Item: type) type {
    return union(enum) {
        items: []const Item,
        /// Index into Patcher.underlays.
        underlay: usize,
    };
}

/// Paint operations a patch over `region` (logical) must run, in order, with
/// the clip structure that reaches it. Null when something reaching it cannot
/// be drawn on the CPU.
fn patchOps(self: *Patcher, allocator: std.mem.Allocator, items: anytype, text_ink: ?[]const ?[4]f32, region: [4]f32, scale: f32) !?[]const PatchOp(@typeInfo(@TypeOf(items)).pointer.child) {
    const Item = @typeInfo(@TypeOf(items)).pointer.child;
    var out: std.ArrayList(Item) = .empty;
    var ops: std.ArrayList(PatchOp(Item)) = .empty;
    var segment: usize = 0;
    var skip_depth: usize = 0; // inside an effect group or a clip outside the region
    var glass_open: usize = 0; // glass groups whose underlay was reused
    var owners: [32]u32 = undefined;
    var owner_count: usize = 0;
    for (items, 0..) |it, index| {
        if (it.kind == .control) {
            if (it.control_kind == .begin_blur_layer) {
                // The encoder composites one glass per owner per frame.
                const owner: u32 = if (@hasField(Item, "glass_owner_id")) it.glass_owner_id else std.math.maxInt(u32);
                if (owner != std.math.maxInt(u32)) {
                    for (owners[0..owner_count]) |o| if (o == owner and skip_depth == 0 and intersects(fp.inkWorldBounds(it), region)) {
                        noteUnsupported(it);
                        return null;
                    };
                    if (owner_count < owners.len) {
                        owners[owner_count] = owner;
                        owner_count += 1;
                    }
                }
            }
            const opens = it.control_kind == .push_clip or isBegin(it.control_kind);
            const closes = it.control_kind == .pop_clip or isEnd(it.control_kind);
            if (skip_depth > 0) {
                if (opens) skip_depth += 1;
                if (closes) skip_depth -= 1;
                continue;
            }
            if (it.control_kind == .end_blur_layer and glass_open > 0) {
                glass_open -= 1;
                continue;
            }
            if (isBegin(it.control_kind)) {
                // Glass sampling the region without painting into it: the
                // region's paint is final, the glass may be stale.
                if (it.control_kind == .begin_blur_layer and intersects(fp.inkWorldBounds(it), region) and
                    !intersects(glassPaintBounds(items, index), region))
                {
                    self.glass_stale = true;
                    skip_depth = 1;
                    continue;
                }
                if (intersects(fp.inkWorldBounds(it), region)) {
                    var stale = false;
                    if (it.control_kind == .begin_blur_layer) {
                        if (self.underlayFor(items, index, scale, &stale)) |u| {
                            if (stale) self.glass_stale = true;
                            if (out.items.len > segment) try ops.append(allocator, .{ .items = out.items[segment..] });
                            try ops.append(allocator, .{ .underlay = u });
                            segment = out.items.len;
                            glass_open += 1;
                            continue;
                        }
                        self.missing_underlay = true;
                    }
                    noteUnsupported(it);
                    return null;
                }
                skip_depth = 1;
                continue;
            }
            if (it.control_kind == .push_clip and !intersects(fp.damageItemBounds(it), region)) {
                skip_depth = 1;
                continue;
            }
            if (!cpu_flat.supportedItem(it)) {
                noteUnsupported(it);
                return null;
            }
            try out.append(allocator, it);
            continue;
        }
        if (skip_depth > 0) continue;
        if (!intersects(itemInk(it, text_ink, index), region)) continue;
        if (!cpu_flat.supportedItem(it)) {
            noteUnsupported(it);
            return null;
        }
        try out.append(allocator, it);
    }
    // Segments slice `out` only once it stopped growing.
    var fixed: std.ArrayList(PatchOp(Item)) = .empty;
    var start: usize = 0;
    for (ops.items) |op| switch (op) {
        .items => |seg| {
            try fixed.append(allocator, .{ .items = out.items[start..][0..seg.len] });
            start += seg.len;
        },
        .underlay => try fixed.append(allocator, op),
    };
    if (out.items.len > start) try fixed.append(allocator, .{ .items = out.items[start..] });
    return fixed.items;
}

fn noteUnsupported(it: anytype) void {
    if (debugEnabled()) std.debug.print("[cpu-patch] unsupported {s}/{s} geom=({d:.1},{d:.1},{d:.1},{d:.1}) shadow={d} stroke={d} shape={d} clip_shape={d}\n", .{
        @tagName(it.kind), @tagName(it.control_kind), it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.shadow_blur, it.stroke_width, it.shape_kind, it.clip_shape_kind,
    });
}

/// Diagnostic (ZENIT_CPU_PATCH_SURVEY=1): one line per paint item the CPU
/// path cannot draw anywhere in the frame, keyed by its feature signature.
fn survey(items: anytype) void {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached == null) S.cached = std.c.getenv("ZENIT_CPU_PATCH_SURVEY") != null;
    if (!S.cached.?) return;
    for (items) |it| {
        if (it.kind == .control and !isBegin(it.control_kind)) continue;
        if (it.kind != .control and cpu_flat.supportedItem(it)) continue;
        std.debug.print("[cpu-survey] {s}/{s} blur={} shadow2={} inset={} spread={} grad={d}/{d}/{d} stroke={} shape={d} xform={} blend={d} noise={d} icon={} rotate={} area={d:.0}\n", .{
            @tagName(it.kind),                @tagName(it.control_kind), it.shadow_blur > 0,      it.shadow2_color.a != 0,
            it.shadow_secondary_color.a != 0, it.shadow_spread != 0,     it.gradient_direction,   it.gradient_extend_mode,
            it.mg_stop_count,                 it.stroke_width > 0,       it.shape_kind,           it.use_draw_transform,
            it.blend_mode,                    it.noise_mode,             it.icon_rep_ptr != null, it.rotate != 0,
            it.geom.w * it.geom.h,
        });
    }
}

/// Present this frame as a CPU patch when possible. `.gpu` leaves every
/// renderer resource as it was; the caller renders the frame normally.
pub fn tryPresent(renderer: anytype, cx: anytype, viewport_width: f32, viewport_height: f32, scale: f32) Outcome {
    if (comptime !supported) return .gpu;
    const self = &renderer.cpu_patch;
    if (!self.enabled) return .gpu;
    const now = @import("zenit_time").Instant.now(cx.io) catch null;
    const gap_ns: ?u64 = if (now) |n| if (self.last_frame_at) |last| n.since(last) else null else null;
    const period_ns = 1e9 / @max(@as(f64, @floatCast(cx.display_refresh_hz)), 1.0);
    const run = runBefore(self.gpu_run, gap_ns, period_ns);
    self.last_frame_at = now;
    self.gpu_run = run + 1;
    const motion_gen = cx.layerMotionGen();
    if (motion_gen != self.motion_gen) {
        self.motion_gen = motion_gen;
        self.last_motion_at = now;
    }
    const since_motion_ns: ?u64 = if (now) |n| if (self.last_motion_at) |m| n.since(m) else null else null;
    const outcome = decide(self, renderer, cx, viewport_width, viewport_height, scale, run, recentlyMoved(since_motion_ns, period_ns));
    if (outcome == .presented) self.gpu_run = 0;
    return outcome;
}

fn decide(self: *Patcher, renderer: anytype, cx: anytype, viewport_width: f32, viewport_height: f32, scale: f32, run: u32, moving: bool) Outcome {
    if (self.force_gpu) return self.reject("forced GPU frame");
    if (inMotion(run, !self.capture_underlays, moving)) {
        // No digest: the next frame after the motion stops has no baseline
        // and goes to the GPU, which sets one.
        self.previous_valid = false;
        return self.reject("in motion");
    }
    const items = cx.lowerForEncoderPaintTable();
    survey(items);
    const extent: [2]u32 = .{ renderer.surface.extent.width, renderer.surface.extent.height };
    var key = std.hash.Wyhash.init(0x7063);
    key.update(std.mem.asBytes(&extent));
    key.update(std.mem.asBytes(&scale));
    key.update(std.mem.asBytes(&renderer.text_renderer.atlas.gc_generation));
    key.update(std.mem.asBytes(&renderer.config.clear_color));
    const frame_key = key.final();
    // Text commands bounded by their glyphs, not the generic envelope (one
    // keystroke would otherwise damage whole em-wide lines above and below).
    const text_ink: ?[]const ?[4]f32 = renderer.textInkBounds(cx.frame_arena.allocator(), items, scale) catch null;
    const described = buildEntries(&self.current, renderer.allocator, items, text_ink) catch false;
    if (!described) {
        self.previous_valid = false;
        return self.reject("undescribed paint");
    }
    if (!self.previous_valid or self.previous_key != frame_key) {
        self.previous_key = frame_key;
        return self.reject("no baseline");
    }
    // External image textures change without a paint change; their pixels
    // can only be refreshed by the GPU.
    for (items) |it| if (it.kind == .image and it.icon_rep_ptr == null) return self.reject("mutable image");
    if (renderer.pending_screenshot_path != null or renderer.recording_active or renderer.has_external_encoder or
        renderer.caret_patch_capture or renderer.caret_background_capture)
        return self.reject("host capture");
    var rect = damage(cx.frame_arena.allocator(), self.previous.items, self.current.items, scale, extent) orelse {
        // Identical paint is the presented image already. External image
        // textures may change without a paint change, so they still render.
        self.unchanged_frames += 1;
        traceUnchanged(renderer.frame_count + 1);
        self.commitBaseline();
        return .presented;
    };
    if (rect[2] == 0 or rect[3] == 0) return self.reject("empty damage");
    // Patch budget: fold every shown patch into this one; covering them all,
    // it replaces them (macos_patch_put drops covered patches).
    if (self.shown >= max_patches) {
        for (self.shown_rects[0..self.rectCount()]) |r| rect = unionRect(rect, r);
        self.consolidations += 1;
    }
    if (@as(u64, rect[2]) * rect[3] > maxPatchPixels()) {
        if (debugEnabled()) std.debug.print("[cpu-patch] damage {d}x{d}@{d},{d}\n", .{ rect[2], rect[3], rect[0], rect[1] });
        return self.reject("damage too large");
    }
    if (renderer.frame_count != self.gpu_frame_seen) {
        self.gpu_frame_seen = renderer.frame_count;
        const st = renderer.last_frame_stats;
        const encode_us = st.cpu_frame_us -| st.layout_us -| st.render_gen_us;
        if (encode_us > 0) self.gpu_frame_ns = self.gpu_frame_ns * 0.8 + @as(f64, @floatFromInt(encode_us)) * 1e3 * 0.2;
    }
    const budget = budgetNs(self.gpu_frame_ns, @floatCast(cx.display_refresh_hz));
    if (self.cost.predict(@as(u64, rect[2]) * rect[3]) > budget) {
        if (debugEnabled()) std.debug.print("[cpu-patch] over budget {d}x{d}: {d:.0} us fixed + {d:.1} ns/px, budget {d:.0} us\n", .{ rect[2], rect[3], self.cost.fixed_ns / 1e3, self.cost.ns_per_pixel, budget / 1e3 });
        return self.reject("over frame budget");
    }
    const region: [4]f32 = .{
        @as(f32, @floatFromInt(rect[0])) / scale,
        @as(f32, @floatFromInt(rect[1])) / scale,
        @as(f32, @floatFromInt(rect[2])) / scale,
        @as(f32, @floatFromInt(rect[3])) / scale,
    };
    const arena = cx.frame_arena.allocator();
    self.missing_underlay = false;
    const patch = (patchOps(self, arena, items, text_ink, region, scale) catch return self.reject("oom")) orelse {
        if (debugEnabled()) std.debug.print("[cpu-patch] region ({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ region[0], region[1], region[2], region[3] });
        if (self.missing_underlay) return self.reject("no glass underlay");
        return self.reject("unsupported content");
    };
    if (@import("zenit_environment").flag("ZENIT_DEBUG_CPU_PATCH_ITEMS")) {
        for (self.previous.items, 0..) |e, i| if (i >= self.current.items.len or e.digest != self.current.items[i].digest) {
            if (i < self.current.items.len) {
                const it = items[self.current.items[i].first];
                std.debug.print("[cpu-patch] changed entry {d} {s}/{s} geom=({d:.1},{d:.1},{d:.1},{d:.1}) color={any}\n", .{ i, @tagName(it.kind), @tagName(it.control_kind), it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.color });
            }
        };
    }
    var uses_underlay = false;
    for (patch) |op| if (op == .underlay) {
        uses_underlay = true;
    };
    // Underlays are written by the latest GPU frame; read them once it ran.
    if (uses_underlay) if (renderer.prev_frame_cmd_buffer) |*command| command.waitUntilCompleted();
    // CPU cost only: the wait above blocks without working.
    const cost_start = @import("zenit_time").Instant.now(cx.io) catch null;
    defer if (uses_underlay) for (patch) |op| if (op == .underlay) {
        _ = self.underlays.items[op.underlay].texture.setVolatile(true);
    };
    if (self.cache == null) self.cache = metal_cpu_flat_cache_create() orelse return self.reject("cache oom");
    // Encode once without drawing: content the CPU raster declines is found
    // before it rasterizes most of a large patch (a nested rounded clip met
    // late cost every keystroke ~20 ms, then the GPU frame).
    renderer.validateCpuPatchOps(patch, viewport_width, viewport_height, scale) catch |err| {
        if (debugEnabled()) std.debug.print("[cpu-patch] validate: {s}\n", .{@errorName(err)});
        // Content the CPU cannot draw stays so for the frames that follow; a
        // transient failure (an atlas page not resident, memory) does not.
        const name = @errorName(err);
        return if (std.mem.startsWith(u8, name, "CpuFlatUnsupported") or err == error.CpuPatchClipDegraded)
            self.reject("unsupported content")
        else
            self.reject("raster");
    };
    const cc = renderer.config.clear_color;
    const clear = [4]f32{ cc.r, cc.g, cc.b, cc.a };
    const layer: *anyopaque = @ptrCast(renderer.surface.layer);
    const target = metal_cpu_flat_begin_patch(layer, &clear, self.cache, rect[0], rect[1], rect[2], rect[3], extent[0], extent[1]) orelse
        return self.reject("patch target");
    var keep = false;
    defer if (!keep) {
        var none: ?*anyopaque = null;
        _ = metal_cpu_flat_end_patch(target, false, &none);
    };
    const t0 = if (debugEnabled()) @import("zenit_time").Instant.now(cx.io) catch null else null;
    renderer.encodeCpuPatchOps(target, patch, viewport_width, viewport_height, scale) catch |err| {
        if (debugEnabled()) std.debug.print("[cpu-patch] raster: {s}\n", .{@errorName(err)});
        return self.reject("raster");
    };
    keep = true;
    var surface: ?*anyopaque = null;
    if (metal_cpu_flat_end_patch(target, true, &surface) != 0 or surface == null) return self.reject("patch finish");
    self.shown = macos_patch_put(layer, surface.?, rect[0], rect[1], rect[2], rect[3], scale);
    metal_glass_clock_trace_patch(rect[2], rect[3]);
    self.noteShown(rect);
    // Test harness screenshots read the retained presented frame: keep it
    // equal to what the window shows.
    if (renderer.retain_present_copy and renderer.retained_valid) if (renderer.retained_tex) |*tex| {
        if (renderer.prev_frame_cmd_buffer) |*command| command.waitUntilCompleted();
        if (renderer.retained_w == extent[0] and renderer.retained_h == extent[1])
            _ = macos_patch_copy_to_texture(surface.?, @ptrCast(tex.raw), rect[0], rect[1], rect[2], rect[3]);
    };
    macos_sprite_atlas_release(surface);
    if (cost_start) |start| if (@import("zenit_time").Instant.now(cx.io) catch null) |end| {
        self.cost.learn(end.since(start), @as(u64, rect[2]) * rect[3]);
    };
    self.cpu_frames += 1;
    if (debugEnabled()) {
        const us = if (t0) |start| if (@import("zenit_time").Instant.now(cx.io) catch null) |end| end.since(start) / 1000 else 0 else 0;
        std.debug.print("[cpu-patch] cpu {d}x{d}@{d},{d} ops={d} underlay={} shown={d} us={d}\n", .{ rect[2], rect[3], rect[0], rect[1], patch.len, uses_underlay, self.shown, us });
    }
    self.commitBaseline();
    return .presented;
}

/// A frame whose paint equals the presented one shows nothing new and submits
/// nothing: the screen already holds its image for this vsync. Pacing
/// analysis counts it as shown on time (a GPU path would present an identical
/// drawable); without the record such frames read as dropped.
fn traceUnchanged(frame: u64) void {
    if (!metal_glass_clock_trace_enabled()) return;
    var line: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{{\"kind\":\"unchanged\",\"frame\":{d},\"host_time\":{d:.9}}}", .{ frame, metal_glass_clock_trace_host_time() }) catch return;
    metal_glass_clock_trace_line(text.ptr, text.len);
}

/// Copy an underlay into a patch target (window device px, clipped to the patch).
pub fn blitUnderlay(self: *Patcher, target: *anyopaque, index: usize) !void {
    const u = &self.underlays.items[index];
    const r = u.write_rect;
    if (metal_cpu_flat_blit(target, @ptrCast(u.texture.raw), u.rect[0], u.rect[1], r[0], r[1], r[2], r[3]) != 0) return error.CpuPatchUnderlay;
}

fn allSupported(items: anytype) bool {
    for (items) |it| if (!cpu_flat.supportedItem(it)) {
        noteUnsupported(it);
        return false;
    };
    return true;
}

/// Rasterize an opaque flipbook (sprite_host) into its IOSurface atlas on the
/// CPU. False leaves the atlas undefined; the caller renders it on the GPU.
pub fn rasterSpriteAtlas(renderer: anytype, surface: *anyopaque, frames: anytype, background: anytype, p: anytype, origin: [2]u32) bool {
    if (comptime !supported) return false;
    const self = &renderer.cpu_patch;
    if (!self.enabled) return false;
    if (!allSupported(background) or !allSupported(frames.items)) return false;
    if (self.cache == null) self.cache = metal_cpu_flat_cache_create() orelse return false;
    const cc = renderer.config.clear_color;
    const clear = [4]f32{ cc.r, cc.g, cc.b, cc.a };
    const extent = renderer.surface.extent;
    var start: usize = 0;
    for (frames.ends, 0..) |end, index| {
        const col: u32 = @intCast(index % p.columns);
        const row: u32 = @intCast(index / p.columns);
        const target = metal_cpu_flat_begin_patch_into(surface, col * p.cell_px[0], row * p.cell_px[1], &clear, self.cache, origin[0], origin[1], p.cell_px[0], p.cell_px[1], extent.width, extent.height) orelse return false;
        const ok = if (renderer.encodeCpuPatch(target, .{ background, frames.items[start..end] }, renderer.pool_viewport[0], renderer.pool_viewport[1], p.scale)) |_| true else |err| blk: {
            if (debugEnabled()) std.debug.print("[cpu-patch] sprite raster: {s}\n", .{@errorName(err)});
            break :blk false;
        };
        var none: ?*anyopaque = null;
        if (metal_cpu_flat_end_patch(target, false, &none) != 0 or !ok) return false;
        start = end;
    }
    if (debugEnabled()) std.debug.print("[cpu-patch] sprite atlas cpu {d} frames {d}x{d}\n", .{ frames.ends.len, p.cell_px[0], p.cell_px[1] });
    return true;
}

test "an unchanged entry between two edits is not damaged; a reorder is" {
    const t = std.testing;
    const big: [4]f32 = .{ 0, 0, 1000, 1000 };
    const a = [_]Entry{ .{ .digest = 1, .bounds = .{ 10, 10, 2, 2 } }, .{ .digest = 2, .bounds = big }, .{ .digest = 3, .bounds = .{ 50, 50, 2, 2 } } };
    const b = [_]Entry{ .{ .digest = 4, .bounds = .{ 10, 10, 2, 2 } }, .{ .digest = 2, .bounds = big }, .{ .digest = 5, .bounds = .{ 50, 50, 2, 2 } } };
    try t.expectEqual([4]u32{ 19, 19, 86, 86 }, damage(t.allocator, &a, &b, 2, .{ 4000, 4000 }).?);
    // Swapping two overlapping entries changes the picture: both are damaged.
    const c = [_]Entry{ .{ .digest = 1, .bounds = .{ 10, 10, 2, 2 } }, .{ .digest = 2, .bounds = big }, .{ .digest = 9, .bounds = .{ 0, 0, 1, 1 } } };
    const d = [_]Entry{ .{ .digest = 2, .bounds = big }, .{ .digest = 1, .bounds = .{ 10, 10, 2, 2 } }, .{ .digest = 9, .bounds = .{ 0, 0, 1, 1 } } };
    const r = damage(t.allocator, &c, &d, 2, .{ 4000, 4000 }).?;
    try t.expect(r[2] >= 2000 or (r[0] <= 19 and r[0] + r[2] >= 25));
}

test "an inserted entry damages only itself" {
    const a = [_]Entry{ .{ .digest = 1, .bounds = .{ 0, 0, 100, 100 } }, .{ .digest = 2, .bounds = .{ 0, 0, 500, 500 } } };
    const b = [_]Entry{ .{ .digest = 1, .bounds = .{ 0, 0, 100, 100 } }, .{ .digest = 9, .bounds = .{ 10, 10, 1, 10 } }, .{ .digest = 2, .bounds = .{ 0, 0, 500, 500 } } };
    try std.testing.expectEqual([4]u32{ 19, 19, 4, 22 }, damage(std.testing.allocator, &a, &b, 2, .{ 2000, 2000 }).?);
    try std.testing.expectEqual([4]u32{ 19, 19, 4, 22 }, damage(std.testing.allocator, &b, &a, 2, .{ 2000, 2000 }).?);
}

test "damage covers changed entries only and reports no change as null" {
    const a = [_]Entry{ .{ .digest = 1, .bounds = .{ 0, 0, 10, 10 } }, .{ .digest = 2, .bounds = .{ 20, 20, 5, 5 } } };
    const b = [_]Entry{ .{ .digest = 1, .bounds = .{ 0, 0, 10, 10 } }, .{ .digest = 3, .bounds = .{ 21, 20, 5, 5 } } };
    try std.testing.expect(damage(std.testing.allocator, &a, &a, 2, .{ 200, 200 }) == null);
    const r = damage(std.testing.allocator, &a, &b, 2, .{ 200, 200 }).?;
    // Union of the old and new bounds of the changed entry, padded by a pixel.
    try std.testing.expectEqual([4]u32{ 39, 39, 14, 12 }, r);
}

test "underlays are copied only by GPU frames after which a patch can follow" {
    var p: Patcher = .{};
    // A scroll, an animation, content the CPU cannot draw, live images, or
    // a frame inside a scroll: no copies until a patch needs them.
    inline for (.{ "over frame budget", "damage too large", "unsupported content", "mutable image", "undescribed paint", "in motion" }) |reason| {
        _ = p.reject("no baseline");
        try std.testing.expect(p.capture_underlays);
        try std.testing.expectEqual(Outcome.gpu, p.reject(reason));
        try std.testing.expect(!p.capture_underlays);
    }
    // The patch that met glass without an underlay sends its frame to the
    // GPU, which copies them for the next one; so does a forced GPU frame.
    inline for (.{ "no glass underlay", "forced GPU frame", "host capture" }) |reason| {
        _ = p.reject("over frame budget");
        _ = p.reject(reason);
        try std.testing.expect(p.capture_underlays);
    }
}

test "a sustained run of unpatchable GPU frames skips the patch decision" {
    // The fourth scroll frame on; not the first ones, not a keystroke after
    // a GPU frame, not a run of frames that could still be patches.
    try std.testing.expect(inMotion(14, true, true));
    try std.testing.expect(inMotion(3, true, true));
    try std.testing.expect(!inMotion(2, true, true));
    try std.testing.expect(!inMotion(0, true, true));
    try std.testing.expect(!inMotion(14, false, true));
    // Over-budget keystrokes or animation frames: no layer moved, so every
    // frame still gets a patch decision.
    try std.testing.expect(!inMotion(14, true, false));
    const period = 1e9 / 60.0;
    // A reversal frame whose offset did not change is still inside the
    // motion; a motion older than three periods is not.
    try std.testing.expect(recentlyMoved(16_700_000, period));
    try std.testing.expect(recentlyMoved(40_000_000, period));
    try std.testing.expect(!recentlyMoved(60_000_000, period));
    try std.testing.expect(!recentlyMoved(null, period));
    // A late frame (two periods) does not end a run; a pause does.
    try std.testing.expectEqual(@as(u32, 14), runBefore(14, 16_700_000, period));
    try std.testing.expectEqual(@as(u32, 14), runBefore(14, 40_000_000, period));
    try std.testing.expectEqual(@as(u32, 0), runBefore(14, 120_000_000, period));
    try std.testing.expectEqual(@as(u32, 0), runBefore(14, null, period));
}

test "patch cost budget: only patches cheaper than a GPU frame stay on the CPU" {
    const b60 = budgetNs(seed_gpu_frame_ns, 60);
    const seed: PatchCost = .{};
    // A caret or a short text edit fits; a quarter-window region does not.
    try std.testing.expect(seed.predict(40 * 60) <= b60);
    try std.testing.expect(seed.predict(600 * 200) <= b60);
    try std.testing.expect(seed.predict(1184 * 412) > b60);
    try std.testing.expect(seed.predict(1725 * 2000) > b60);
    // The refresh period caps the budget even if GPU frames are expensive.
    try std.testing.expectApproxEqRel(@as(f64, 1e9 / 240.0 / 3.0), budgetNs(10e6, 240), 1e-9);
    try std.testing.expectEqual(@as(f64, 1.5e6), budgetNs(1.5e6, 60));
}

test "patch cost: carets teach the fixed cost, larger patches the per-pixel rate" {
    var cost: PatchCost = .{};
    // Slow carets (0.6 ms for 528 px) raise only the fixed part: a text line
    // still fits instead of being priced at ~1 us per pixel.
    for (0..6) |_| cost.learn(600_000, 12 * 44);
    try std.testing.expectApproxEqRel(@as(f64, 6.0), cost.ns_per_pixel, 1e-9);
    try std.testing.expect(cost.predict(276 * 48) < 1.5e6);
    // A slow region (25 ms for 480x2000) raises the rate net of the fixed cost.
    cost.learn(25_000_000, 480 * 2000);
    try std.testing.expect(cost.predict(480 * 2000) > 1.5e6);
    try std.testing.expect(cost.predict(200 * 100) < 1.5e6);
    // A patch faster than the fixed estimate never yields a negative rate.
    cost.learn(1_000, 200 * 100);
    try std.testing.expect(cost.ns_per_pixel >= 0);
}
