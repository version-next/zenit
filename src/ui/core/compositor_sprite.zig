//! Compositor sprites: periodic custom draws handed to the system compositor.
//!
//! A canvas whose picture is a pure function of time with a known period (a
//! Spinner) otherwise keeps the whole window presenting every display frame.
//! Any in-process render pass keeps the GPU driver's per-process working set
//! (~225 MiB on Apple GPUs) resident, and the frame loop costs CPU. While a
//! sprite is *active* its node's paint items are removed from the Metal frame
//! and the host shows a flipbook of the same picture (rendered once by the GPU
//! with the regular encoder) in a native layer above the window surface; the
//! system compositor steps it. Nothing in-process runs per frame.
//!
//! Admission is re-evaluated on every rendered frame from that frame's own
//! paint, so the result is never stale:
//!   - the node painted this frame with contiguous, non-control items only;
//!   - no effect (opacity / blur / composited group) and a translation-only
//!     world transform;
//!   - every clip on the chain either contains the sprite or is a plain rect;
//!   - nothing painted later overlaps it (the native layer sits on top);
//!   - its position was stable for a frame (scrolling stays on the GPU path).
//! On exit the sprite stays up for the frame that detected it (its Metal items
//! from the active period are stale); the node is repainted on the next frame.
const std = @import("std");
const Allocator = std.mem.Allocator;
const paint_table = @import("paint_table.zig");
const display_list_mod = @import("display_list.zig");
const property_tree_mod = @import("property_tree.zig");
const scene_runtime_mod = @import("scene_runtime.zig");
const types = @import("types.zig");
const gpu_draw_shadow = @import("render_engine/gpu_draw_shadow.zig");

const INVALID_ID = property_tree_mod.INVALID_ID;
const DisplayItem = display_list_mod.DisplayItem;
const PaintItem = paint_table.DisplayItem;
const ComputedRect = types.ComputedRect;

pub const DrawContext = @import("render_engine/mod.zig").DrawContext;
/// Draws the source's picture at an arbitrary frame-clock time.
pub const DrawAtFn = *const fn (ctx: DrawContext, context: ?*anyopaque, now_ms: f64) anyerror!void;
/// Marks the source's node for repaint at the current frame time.
pub const RepaintFn = *const fn (context: ?*anyopaque) void;
/// Current position in the loop (ms in [0, period)), for sources timed by
/// their own clock rather than the frame clock.
pub const PhaseFn = *const fn (context: ?*anyopaque) f64;

pub const Options = struct {
    /// Flipbook frames per period; 0 samples at the host's flipbook rate.
    frame_count: u32 = 0,
    phase: ?PhaseFn = null,
    /// The node's items are repainted on every rendered frame even while it is
    /// a sprite (only its timing is handed over), so leaving needs no overlap.
    fresh_on_exit: bool = false,
};

/// Device pixels of transparent margin around each flipbook cell (AA fringe).
pub const cell_pad_px: u32 = 2;
/// Default flipbook sampling rate. The compositor steps the layer at the
/// rate a host passes in FrameInputs.flipbook_hz (a host that composes at the
/// display refresh rate passes that rate: the flipbook then shows a new
/// picture every refresh, as the GPU path does).
pub const frames_per_second: f64 = 60;
/// Default upper bound for one flipbook (BGRA8) as rendered. Larger sprites
/// stay on the GPU path. A host that keeps a compacted copy of the flipbook
/// (Windows) raises it: the full rendering is then transient.
pub const max_atlas_bytes: u64 = 8 * 1024 * 1024;
pub const max_sources = 64;
/// How long a placement must stay still before the compositor takes it over.
/// Building an atlas renders the whole flipbook, which only pays off when the
/// window would otherwise go idle; intermittent movement (a scroll with gaps
/// between events) keeps the GPU drawing the node instead of rebuilding an
/// atlas at every pause. Time, not frames: a blinking caret renders twice a
/// second, a spinner sixty times.
pub const settle_ms: f64 = 500;
/// And at least this many still frames (a single frame proves nothing).
pub const settle_frames: u8 = 2;

pub const Source = struct {
    node_id: u32,
    period_ms: f64,
    context: ?*anyopaque,
    draw_at: DrawAtFn,
    repaint: RepaintFn,
    options: Options = .{},
    active: bool = false,
    stable_frames: u8 = 0,
    /// Time the placement has been still (settle clock).
    still_ms: f64 = 0,
    last_rect: [4]f32 = .{ 0, 0, -1, -1 },
    // Lowering probe for the current frame.
    paint_first: u32 = 0,
    paint_count: u32 = 0,
    paint_broken: bool = false,
    /// Why admission last failed (diagnostics).
    last_reject: []const u8 = "",
};

pub const Placement = struct {
    node_id: u32,
    /// Identity of the flipbook pixels (picture, size, subpixel phase, scale).
    key: u64,
    /// Window-space device-pixel origin and size of one cell (padding included).
    origin_px: [2]i32,
    cell_px: [2]u32,
    /// Window-space device-pixel clip, or null when nothing clips the sprite.
    clip_px: ?[4]i32,
    columns: u32,
    frame_count: u32,
    period_ms: f64,
    /// Frame-clock time this placement was computed for (phase reference).
    frame_time_ms: f64,
    scale: f32,
    /// The sprite is leaving: the host keeps the current layer for this frame.
    exiting: bool = false,
    // Generation inputs.
    /// The node's window-space origin (logical units).
    logical_origin: [2]f32 = .{ 0, 0 },
    subpixel: [2]f32,
    logical_size: [2]f32,
    source_index: u32,

    pub fn atlasSizePx(self: Placement) [2]u32 {
        const rows = (self.frame_count + self.columns - 1) / self.columns;
        return .{ self.columns * self.cell_px[0], rows * self.cell_px[1] };
    }
};

pub const Registry = struct {
    sources: std.ArrayList(Source) = .empty,
    placements: std.ArrayList(Placement) = .empty,
    filtered: std.ArrayList(PaintItem) = .empty,
    filtered_valid: bool = false,
    /// The host enables sprites only where it can present them (macOS Metal,
    /// Windows Direct3D, outside drawable-readback test runs).
    enabled: bool = false,
    /// Remove placed sprites' items from the GPU frame (the native layer
    /// replaces them). A host whose sprites are opaque and stacked above the
    /// frame clears this: the frame keeps painting the node (refreshActive
    /// repaints it on every rendered frame), so whatever frame is on screen
    /// when the native layer comes or goes already shows the node at its
    /// current time and place, and no overlap frame is needed on exit.
    filter_placed: bool = true,
    /// Flipbook rate the host composes at (see FrameInputs.flipbook_hz).
    flipbook_hz: f64 = frames_per_second,
    /// Bytes the host keeps in flipbook atlases (diagnostics, host-written).
    host_atlas_bytes: u64 = 0,
    /// Why the host last failed to present a placement (diagnostics, host-written).
    host_error: []const u8 = "",
    /// Atlases the host is still building (diagnostics, host-written).
    host_building: u32 = 0,
    /// Upper bound for one rendered flipbook (FrameInputs.max_atlas_bytes).
    max_atlas_bytes: u64 = max_atlas_bytes,
    /// The host renders each flipbook frame in place among the frame's own
    /// items over the cell (inside the same clips, under the items painted
    /// after the node) and shows opaque cells: clips and later items do not
    /// keep a sprite on the GPU path.
    replay_in_place: bool = false,
    scratch: display_list_mod.DisplayList = undefined,
    scratch_ready: bool = false,
    scratch_dead: std.ArrayList(DisplayItem) = .empty,
    /// Settle clock of the previous frame; elapsed time is accumulated per
    /// frame so a clock change (a harness locking the clock) cannot stall or
    /// skip settling.
    last_settle_clock_ms: ?f64 = null,
    settle_dt_ms: f64 = 0,
    /// Per-frame occlusion index (see Occlusion), reset by afterLowering.
    occlusion: Occlusion = .{},

    pub fn deinit(self: *Registry, allocator: Allocator) void {
        self.sources.deinit(allocator);
        self.placements.deinit(allocator);
        self.filtered.deinit(allocator);
        self.scratch_dead.deinit(allocator);
        self.occlusion.deinit(allocator);
        if (self.scratch_ready) self.scratch.deinit();
        self.* = .{};
    }

    pub fn register(self: *Registry, allocator: Allocator, node_id: u32, period_ms: f64, context: ?*anyopaque, draw_at: DrawAtFn, repaint: RepaintFn) !void {
        return self.registerWith(allocator, node_id, period_ms, context, draw_at, repaint, .{});
    }

    pub fn registerWith(self: *Registry, allocator: Allocator, node_id: u32, period_ms: f64, context: ?*anyopaque, draw_at: DrawAtFn, repaint: RepaintFn, options: Options) !void {
        if (self.sources.items.len >= max_sources) return;
        for (self.sources.items) |*source| if (source.context == context) {
            source.node_id = node_id;
            source.period_ms = period_ms;
            source.options = options;
            return;
        };
        try self.sources.append(allocator, .{ .node_id = node_id, .period_ms = period_ms, .context = context, .draw_at = draw_at, .repaint = repaint, .options = options });
    }

    pub fn isRegistered(self: *const Registry, context: ?*anyopaque) bool {
        for (self.sources.items) |source| if (source.context == context) return true;
        return false;
    }

    /// Remove the source registered with `context` (its owner is going away).
    pub fn unregister(self: *Registry, context: ?*anyopaque) void {
        var i: usize = 0;
        while (i < self.sources.items.len) {
            if (self.sources.items[i].context == context) {
                _ = self.sources.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn isActive(self: *const Registry, node_id: u32) bool {
        for (self.sources.items) |source| if (source.node_id == node_id) return source.active;
        return false;
    }

    /// Sprite diagnostics are on (hosts print their own decisions too).
    pub fn debugOn(_: *const Registry) bool {
        return debugEnabled();
    }

    pub fn setDebug(_: *Registry, on: bool) void {
        debug_forced = on;
    }

    pub fn hasSources(self: *const Registry) bool {
        return self.sources.items.len != 0;
    }

    /// Any source currently presented by the compositor (its animation keeps
    /// running while the window renders nothing).
    pub fn anyActive(self: *const Registry) bool {
        for (self.sources.items) |source| if (source.active) return true;
        return false;
    }

    /// Call once per rendered frame before the paint walk. Without filtering,
    /// an active source's node stays in the frame and must be painted at the
    /// frame's time (its own tick stops marking it while the compositor
    /// animates it, so nothing else would refresh it).
    pub fn refreshActive(self: *Registry) void {
        if (self.filter_placed or !self.enabled) return;
        for (self.sources.items) |source| if (source.active) source.repaint(source.context);
    }

    /// Lowering probe: called for every item appended to the main paint list.
    pub fn noteLowered(self: *Registry, node_id: u32, index: usize, is_control: bool) void {
        for (self.sources.items) |*source| {
            if (source.node_id != node_id) continue;
            const at: u32 = @intCast(index);
            if (source.paint_count == 0) {
                source.paint_first = at;
            } else if (at != source.paint_first + source.paint_count) source.paint_broken = true;
            source.paint_count += 1;
            if (is_control) source.paint_broken = true;
        }
    }

    pub fn beginLowering(self: *Registry) void {
        self.filtered_valid = false;
        self.placements.clearRetainingCapacity();
        for (self.sources.items) |*source| {
            source.paint_count = 0;
            source.paint_broken = false;
        }
    }

    pub const FrameInputs = struct {
        scene_runtime: *const scene_runtime_mod.SceneRuntime,
        property_tree: *const property_tree_mod.PropertyTree,
        display_list: []const DisplayItem,
        scale: f32,
        frame_time_ms: f64,
        /// Clock for settle_ms (ms, any origin).
        settle_clock_ms: f64 = 0,
        /// Flipbook frames per second (sources without a fixed frame count).
        flipbook_hz: f64 = frames_per_second,
        max_atlas_bytes: u64 = max_atlas_bytes,
        /// See Registry.replay_in_place.
        replay_in_place: bool = false,
        reduced_motion: bool,
    };

    /// Decide this frame's placements from its own paint. Allocation failure
    /// only skips sprites for the frame (the GPU path remains correct).
    /// Returns true when a sprite left the active state: its node was marked
    /// for repaint and the caller must render one more frame.
    pub fn afterLowering(self: *Registry, allocator: Allocator, in: Registry.FrameInputs) bool {
        var exited = false;
        self.settle_dt_ms = if (self.last_settle_clock_ms) |last| std.math.clamp(in.settle_clock_ms - last, 0, settle_ms) else 0;
        self.last_settle_clock_ms = in.settle_clock_ms;
        self.occlusion.reset(allocator, in.display_list.len, self.sources.items);
        for (self.sources.items, 0..) |*source, index| {
            const placement = if (self.enabled and !in.reduced_motion) self.admit(allocator, source, @intCast(index), in) else null;
            if (placement) |p| {
                self.placements.append(allocator, p) catch {
                    if (source.active) {
                        source.repaint(source.context);
                        exited = true;
                    }
                    source.active = false;
                    continue;
                };
                source.active = true;
            } else if (source.active) {
                source.active = false;
                source.stable_frames = 0;
                // Unfiltered: this frame painted the node fresh (refreshActive)
                // and the host removes the layer once the frame is on screen.
                // One more frame still: the node's own tick (quiet while the
                // compositor animated it) drives it again from then on.
                if (!self.filter_placed) {
                    exited = true;
                    continue;
                }
                // Keep the presented sprite for this frame: the node's Metal
                // items are from before activation.
                if (!source.options.fresh_on_exit and source.paint_count != 0 and !source.paint_broken) {
                    if (self.exitPlacement(source, @intCast(index), in)) |p| {
                        self.placements.append(allocator, p) catch {};
                    }
                }
                source.repaint(source.context);
                exited = true;
            }
        }
        return exited;
    }

    /// The host could not present a placement (atlas allocation or GPU
    /// failure): paint the node normally from the next frame on.
    pub fn reject(self: *Registry, node_id: u32) void {
        for (self.sources.items) |*source| {
            if (source.node_id == node_id) {
                if (source.active) source.repaint(source.context);
                source.active = false;
                source.stable_frames = 0;
            }
        }
        var i: usize = 0;
        while (i < self.placements.items.len) {
            if (self.placements.items[i].node_id == node_id) _ = self.placements.orderedRemove(i) else i += 1;
        }
        self.filtered_valid = false;
    }

    /// The host cannot present the placement yet (its atlas is being built
    /// over the next frames): no sprite this frame, but its settle state is
    /// kept so it is placed again as soon as the host is ready. Returns true
    /// when it was active (the host showed an older atlas): it is repainted,
    /// and the caller renders one more frame so its own tick drives it again.
    pub fn postpone(self: *Registry, node_id: u32) bool {
        var was_active = false;
        for (self.sources.items) |*source| {
            if (source.node_id != node_id) continue;
            if (source.active) {
                source.repaint(source.context);
                was_active = true;
            }
            source.active = false;
        }
        var i: usize = 0;
        while (i < self.placements.items.len) {
            if (self.placements.items[i].node_id == node_id) _ = self.placements.orderedRemove(i) else i += 1;
        }
        self.filtered_valid = false;
        return was_active;
    }

    /// The paint list the encoder consumes: placed sprites' items removed.
    pub fn paintItems(self: *Registry, allocator: Allocator, main: []const PaintItem) []const PaintItem {
        if (self.placements.items.len == 0 or !self.filter_placed) return main;
        if (self.filtered_valid) return self.filtered.items;
        self.filtered.clearRetainingCapacity();
        self.filtered.ensureTotalCapacity(allocator, main.len) catch return main;
        var cursor: usize = 0;
        while (cursor < main.len) {
            var skip_to: ?usize = null;
            for (self.placements.items) |p| {
                const source = self.sources.items[p.source_index];
                if (source.paint_first == cursor and source.paint_count != 0) skip_to = cursor + source.paint_count;
            }
            if (skip_to) |end| {
                cursor = end;
                continue;
            }
            self.filtered.appendAssumeCapacity(main[cursor]);
            cursor += 1;
        }
        self.filtered_valid = true;
        return self.filtered.items;
    }

    /// Only identifies the node and its paint range; the host keeps the
    /// layer it already shows.
    fn exitPlacement(self: *Registry, source: *Source, index: u32, in: Registry.FrameInputs) ?Placement {
        _ = self;
        return .{
            .node_id = source.node_id,
            .key = 0,
            .origin_px = .{ 0, 0 },
            .cell_px = .{ 0, 0 },
            .clip_px = null,
            .columns = 1,
            .frame_count = 0,
            .period_ms = source.period_ms,
            .frame_time_ms = in.frame_time_ms,
            .scale = in.scale,
            .exiting = true,
            .subpixel = .{ 0, 0 },
            .logical_size = .{ 0, 0 },
            .source_index = index,
        };
    }

    fn admit(self: *Registry, allocator: Allocator, source: *Source, index: u32, in: Registry.FrameInputs) ?Placement {
        if (source.period_ms <= 0) return rejected(source, "period");
        if (source.paint_count == 0) return rejected(source, "paint: not lowered this frame");
        if (source.paint_broken) return rejected(source, "paint: split or carries a control item");
        const rt = in.scene_runtime.getPtr(source.node_id) orelse return rejected(source, "scene");
        if (rt.effect_id != INVALID_ID) return rejected(source, "effect");
        const transforms = in.property_tree.transforms.items;
        if (rt.transform_id >= transforms.len) return rejected(source, "transform-id");
        const world = transforms[rt.transform_id].world;
        if (@abs(world.a - 1) > 1e-4 or @abs(world.d - 1) > 1e-4 or @abs(world.b) > 1e-4 or @abs(world.c) > 1e-4) return rejected(source, "transform");
        const bounds = rt.world_bounds;
        if (bounds.w <= 0 or bounds.h <= 0) return rejected(source, "empty");
        const rect: [4]f32 = .{ bounds.x, bounds.y, bounds.w, bounds.h };

        const moved = !std.meta.eql(rect, source.last_rect);
        source.last_rect = rect;
        if (moved) {
            source.stable_frames = 0;
            source.still_ms = 0;
            return rejected(source, "moved");
        }
        if (!source.active) {
            source.stable_frames +|= 1;
            source.still_ms += self.settle_dt_ms;
            if (source.stable_frames < settle_frames or source.still_ms < settle_ms) return rejected(source, "settling");
        }

        // A host replaying frames in place reproduces clips and later items
        // in its (opaque) cells itself.
        const clip: ?ComputedRect = if (in.replay_in_place) null else (clipFor(in.property_tree, rt, bounds) orelse return rejected(source, "clip")).rect;
        if (!in.replay_in_place and self.occlusion.occluded(in, source.node_id, inflate(bounds, 1))) return rejected(source, "occluded");
        var p = placementFor(source, index, rect, clip, in) orelse return rejected(source, "size");
        p.key = self.contentKey(allocator, source, p) catch return rejected(source, "draw");
        return p;
    }

    fn contentKey(self: *Registry, allocator: Allocator, source: *Source, p: Placement) !u64 {
        var hasher = std.hash.Wyhash.init(0x5b1e);
        hasher.update(std.mem.asBytes(&p.cell_px));
        hasher.update(std.mem.asBytes(&p.subpixel));
        hasher.update(std.mem.asBytes(&p.scale));
        hasher.update(std.mem.asBytes(&p.period_ms));
        hasher.update(std.mem.asBytes(&p.frame_count));
        const items = try self.drawFrame(allocator, source, p, 0);
        for (items) |item| hashItem(&hasher, item);
        return hasher.final();
    }

    pub const Frames = struct {
        /// Every frame's paint items in window space (logical units), as the
        /// node would be painted at that time; frame i is items[ends[i-1]..ends[i]].
        items: []PaintItem,
        ends: []u32,
    };

    /// Paint items for every flipbook frame. Unsupported draw output returns
    /// an error and the caller rejects the sprite.
    pub fn generate(self: *Registry, allocator: Allocator, frame_allocator: Allocator, p: Placement) !Frames {
        const source = &self.sources.items[p.source_index];
        var out: std.ArrayList(PaintItem) = .empty;
        const ends = try frame_allocator.alloc(u32, p.frame_count);
        for (0..p.frame_count) |frame| {
            const items = try self.drawFrame(allocator, source, p, frame);
            for (items) |item| try out.append(frame_allocator, try translated(item, p.logical_origin[0], p.logical_origin[1]));
            ends[frame] = @intCast(out.items.len);
        }
        return .{ .items = out.items, .ends = ends };
    }

    fn drawFrame(self: *Registry, allocator: Allocator, source: *Source, p: Placement, frame: usize) ![]const DisplayItem {
        if (!self.scratch_ready) {
            self.scratch = display_list_mod.DisplayList.init(allocator);
            // contentKey hashes the supported draw fields itself; generate
            // lowers them directly, without consuming retained identities.
            self.scratch.record_content_fingerprints = false;
            self.scratch_ready = true;
        }
        self.scratch.clear();
        const t = @as(f64, @floatFromInt(frame)) * p.period_ms / @as(f64, @floatFromInt(p.frame_count));
        try source.draw_at(.{
            .lowering_buffer = &self.scratch_dead,
            .display_list = &self.scratch,
            .display_header = .{ .transform_id = INVALID_ID, .node_id = source.node_id },
            .allocator = allocator,
            .frame_allocator = allocator,
            .render_x = 0,
            .render_y = 0,
            .render_w = p.logical_size[0],
            .render_h = p.logical_size[1],
            .local_w = p.logical_size[0],
            .local_h = p.logical_size[1],
            .clip = null,
        }, source.context, t);
        return self.scratch.items.items;
    }
};

fn rejected(source: *Source, comptime why: []const u8) ?Placement {
    source.last_reject = why;
    if (debugEnabled()) std.debug.print("[sprite] node={d} not admitted: {s}\n", .{ source.node_id, why });
    return null;
}

/// Diagnostics switch for hosts without an environment to set (test harness
/// `/sprites {"debug":true}`); ZENIT_DEBUG_SPRITES does the same.
pub var debug_forced: bool = false;

fn debugEnabled() bool {
    if (debug_forced) return true;
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached == null) S.cached = @import("zenit_environment").flag("ZENIT_DEBUG_SPRITES");
    return S.cached.?;
}

fn placementFor(source: *const Source, index: u32, rect: [4]f32, clip: ?ComputedRect, in: Registry.FrameInputs) ?Placement {
    const s = in.scale;
    if (!(s > 0)) return null;
    const x_px = rect[0] * s;
    const y_px = rect[1] * s;
    const fx = @floor(x_px);
    const fy = @floor(y_px);
    const pad: f32 = @floatFromInt(cell_pad_px);
    const w_px: u32 = @intFromFloat(@ceil(rect[2] * s + (x_px - fx)) + 2 * pad);
    const h_px: u32 = @intFromFloat(@ceil(rect[3] * s + (y_px - fy)) + 2 * pad);
    const hz = if (in.flipbook_hz > 0) in.flipbook_hz else frames_per_second;
    const frame_count: u32 = if (source.options.frame_count != 0) source.options.frame_count else @intFromFloat(@max(1, @round(source.period_ms * hz / 1000)));
    const per_frame: u64 = @as(u64, w_px) * h_px * 4;
    if (per_frame * frame_count > in.max_atlas_bytes) return null;
    // Near-square atlas within the 16K texture limit.
    var columns: u32 = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(frame_count)) * @as(f64, @floatFromInt(h_px)) / @as(f64, @floatFromInt(w_px)))));
    if (w_px > 16384 or h_px > 16384) return null;
    columns = std.math.clamp(columns, 1, @min(frame_count, 16384 / w_px));
    const rows = (frame_count + columns - 1) / columns;
    if (rows * h_px > 16384) return null;
    const origin: [2]i32 = .{ @as(i32, @intFromFloat(fx)) - @as(i32, @intCast(cell_pad_px)), @as(i32, @intFromFloat(fy)) - @as(i32, @intCast(cell_pad_px)) };
    const clip_px: ?[4]i32 = if (clip) |c| blk: {
        const l: i32 = @intFromFloat(@round(c.x * s));
        const t: i32 = @intFromFloat(@round(c.y * s));
        const r: i32 = @intFromFloat(@round((c.x + c.w) * s));
        const b: i32 = @intFromFloat(@round((c.y + c.h) * s));
        break :blk .{ l, t, r - l, b - t };
    } else null;
    return .{
        .node_id = source.node_id,
        .key = 0,
        .origin_px = origin,
        .cell_px = .{ w_px, h_px },
        .clip_px = clip_px,
        .columns = columns,
        .frame_count = frame_count,
        .period_ms = source.period_ms,
        .frame_time_ms = if (source.options.phase) |phase| phase(source.context) else in.frame_time_ms,
        .scale = s,
        .logical_origin = .{ rect[0], rect[1] },
        .subpixel = .{ x_px - fx, y_px - fy },
        .logical_size = .{ rect[2], rect[3] },
        .source_index = index,
    };
}

const ClipResult = struct { rect: ?ComputedRect };

/// Walk the node's clip chain. A clip that fully contains the sprite (away
/// from rounded corners) is irrelevant; a plain rect clip is applied by the
/// native layer; anything else keeps the sprite on the GPU path.
fn clipFor(tree: *const property_tree_mod.PropertyTree, rt: *const scene_runtime_mod.SceneNodeRuntime, bounds: ComputedRect) ?ClipResult {
    const clips = tree.clips.items;
    var id = rt.clip_id;
    if (id != INVALID_ID and id < clips.len and clips[id].owner_content_exempt and clips[id].node_id == rt.node_id) id = clips[id].parent;
    var result: ?ComputedRect = null;
    var guard: usize = 0;
    while (id != INVALID_ID and id < clips.len) : (guard += 1) {
        if (guard > 256) return null;
        const clip = clips[id];
        const box = clip.world_aabb;
        const radius = @max(@max(clip.radii[0], clip.radii[1]), @max(clip.radii[2], clip.radii[3]));
        const safe = inflate(box, -radius);
        if (contains(safe, bounds)) {
            // Irrelevant for the sprite.
        } else if (clip.shape_kind == .rect and !clip.bounds_fallback) {
            result = if (result) |r| intersect(r, box) else box;
        } else return null;
        id = clip.parent;
    }
    if (result) |r| if (r.w <= 0 or r.h <= 0) return null;
    return .{ .rect = result };
}

/// What occluded() derives from the frame's display list, shared by every sprite of the frame:
/// each source node's last item (one backward scan) and the items' world bounds (computed on
/// first use). Without it each sprite rescanned the list and recomputed every later item's bounds.
const Occlusion = struct {
    /// Last display item of each source (by Registry.sources index), or null.
    last: std.ArrayList(?usize) = .empty,
    bounds: std.ArrayList(?ComputedRect) = .empty,
    known: std.DynamicBitSetUnmanaged = .{},
    /// False when reset could not allocate: occluded() then scans as before.
    ready: bool = false,
    scanned: bool = false,
    sources: []const Source = &.{},

    fn deinit(self: *Occlusion, allocator: Allocator) void {
        self.last.deinit(allocator);
        self.bounds.deinit(allocator);
        self.known.deinit(allocator);
        self.* = .{};
    }

    fn reset(self: *Occlusion, allocator: Allocator, items: usize, sources: []const Source) void {
        self.ready = false;
        self.scanned = false;
        self.sources = sources;
        self.last.resize(allocator, sources.len) catch return;
        self.bounds.resize(allocator, items) catch return;
        self.known.resize(allocator, items, false) catch return;
        self.known.unsetAll();
        self.ready = true;
    }

    fn lastItem(self: *Occlusion, in: Registry.FrameInputs, node_id: u32) ?usize {
        if (!self.scanned) {
            @memset(self.last.items, null);
            var remaining = self.sources.len;
            var i = in.display_list.len;
            while (i > 0 and remaining > 0) {
                i -= 1;
                const id = in.display_list[i].header().node_id;
                for (self.sources, 0..) |src, k| if (src.node_id == id and self.last.items[k] == null) {
                    self.last.items[k] = i;
                    remaining -= 1;
                };
            }
            self.scanned = true;
        }
        for (self.sources, 0..) |src, k| if (src.node_id == node_id) return self.last.items[k];
        return lastItemScan(in, node_id);
    }

    fn itemBounds(self: *Occlusion, in: Registry.FrameInputs, i: usize) ?ComputedRect {
        if (self.known.isSet(i)) return self.bounds.items[i];
        const b = itemWorldBounds(in, &in.display_list[i]);
        self.bounds.items[i] = b;
        self.known.set(i);
        return b;
    }

    /// Anything painted after the sprite's node that may overlap it.
    fn occluded(self: *Occlusion, in: Registry.FrameInputs, node_id: u32, rect: ComputedRect) bool {
        if (!self.ready or self.bounds.items.len != in.display_list.len) return occludedScan(in, node_id, rect);
        const start = (self.lastItem(in, node_id) orelse return true) + 1;
        for (in.display_list[start..], start..) |*item, i| {
            switch (item.*) {
                .push_clip, .pop_clip, .end_opacity_layer, .end_blur_layer, .end_rounded_clip => continue,
                else => {},
            }
            const h = item.header();
            if (h.node_id == node_id) continue;
            const bounds = self.itemBounds(in, i) orelse return true;
            if (intersects(bounds, rect)) {
                if (debugEnabled()) std.debug.print("[sprite] node={d} ({d:.1},{d:.1} {d:.1}x{d:.1}) occluded by node={d} {s} ({d:.1},{d:.1} {d:.1}x{d:.1})\n", .{ node_id, rect.x, rect.y, rect.w, rect.h, h.node_id, @tagName(item.*), bounds.x, bounds.y, bounds.w, bounds.h });
                return true;
            }
        }
        return false;
    }
};

fn lastItemScan(in: Registry.FrameInputs, node_id: u32) ?usize {
    var last: ?usize = null;
    for (in.display_list, 0..) |*item, i| {
        if (item.header().node_id == node_id) last = i;
    }
    return last;
}

/// Anything painted after the sprite's node that may overlap it (uncached reference path).
fn occludedScan(in: Registry.FrameInputs, node_id: u32, rect: ComputedRect) bool {
    // By pointer: items are large unions (a push_clip carries a polygon); copying each one per
    // sprite per frame dominated cx.render with a dozen sprites on screen.
    var last: ?usize = null;
    for (in.display_list, 0..) |*item, i| {
        if (item.header().node_id == node_id) last = i;
    }
    const start = (last orelse return true) + 1;
    for (in.display_list[start..]) |*item| {
        switch (item.*) {
            .push_clip, .pop_clip, .end_opacity_layer, .end_blur_layer, .end_rounded_clip => continue,
            else => {},
        }
        const h = item.header();
        if (h.node_id == node_id) continue;
        const bounds = itemWorldBounds(in, item) orelse return true;
        if (intersects(bounds, rect)) {
            if (debugEnabled()) std.debug.print("[sprite] node={d} ({d:.1},{d:.1} {d:.1}x{d:.1}) occluded by node={d} {s} ({d:.1},{d:.1} {d:.1}x{d:.1})\n", .{ node_id, rect.x, rect.y, rect.w, rect.h, h.node_id, @tagName(item.*), bounds.x, bounds.y, bounds.w, bounds.h });
            return true;
        }
    }
    return false;
}

/// Distance past the shadow shape where its coverage falls below half an 8-bit
/// step. The SDF shader uses `smoothstep(blur, -blur, sdf)`: with
/// t = (blur - sdf) / (2 * blur), coverage = 3t^2 - 2t^3 <= 3t^2. Below that
/// threshold swapping the compositing order with a sprite is not observable.
fn shadowReach(blur: f32, alpha_u8: u8) f32 {
    if (blur <= 0) return 0;
    const a = @as(f32, @floatFromInt(alpha_u8)) / 255;
    if (a <= 0) return -blur;
    const t = @sqrt((0.5 / 255.0) / (3 * a));
    return blur * (1 - 2 * @min(t, 0.5));
}

/// Conservative world-space ink bounds of a display item, or null when unknown.
fn itemWorldBounds(in: Registry.FrameInputs, item: *const DisplayItem) ?ComputedRect {
    const h = item.header();
    const local: ?ComputedRect = switch (item.*) {
        .shadow_rect => |*it| inflate(ComputedRect.init(it.x + it.offset_x, it.y + it.offset_y, it.w, it.h), @max(0, it.spread) + shadowReach(it.blur, it.color.a)),
        .arc => |*it| ComputedRect.init(it.cx - it.outer_radius - 1, it.cy - it.outer_radius - 1, 2 * it.outer_radius + 2, 2 * it.outer_radius + 2),
        .text_run, .fill_path, .stroke_path, .icon_rep, .shadow_dual_rect => null,
        inline else => |*it| if (@hasField(@TypeOf(it.*), "w") and @hasField(@TypeOf(it.*), "h") and @hasField(@TypeOf(it.*), "x") and @hasField(@TypeOf(it.*), "y"))
            inflate(ComputedRect.init(it.x, it.y, it.w, it.h), 1)
        else
            null,
    };
    if (local) |r| {
        if (h.already_lowered or h.transform_id == INVALID_ID) return r;
        const transforms = in.property_tree.transforms.items;
        if (h.transform_id < transforms.len) return transforms[h.transform_id].world.transformRect(r);
    }
    // No item geometry (text, paths, icons): the owning node's box plus a margin.
    const owner = in.scene_runtime.getPtr(h.node_id) orelse return null;
    const margin: f32 = if (item.* == .shadow_dual_rect) 64 else 4;
    return inflate(owner.world_bounds, margin);
}

fn translated(item: DisplayItem, ox: f32, oy: f32) !PaintItem {
    var moved = item;
    switch (moved) {
        .arc => |*it| {
            it.cx += ox;
            it.cy += oy;
        },
        .fill_rect => |*it| {
            it.x += ox;
            it.y += oy;
        },
        .stroke_rect => |*it| {
            it.x += ox;
            it.y += oy;
        },
        else => return error.UnsupportedSpriteItem,
    }
    return gpu_draw_shadow.lowerDisplayItem(moved);
}

fn hashItem(hasher: *std.hash.Wyhash, item: DisplayItem) void {
    switch (item) {
        .arc => |it| {
            hasher.update("arc");
            hasher.update(std.mem.asBytes(&.{ it.cx, it.cy, it.outer_radius, it.stroke_width, it.start_angle, it.end_angle }));
            hasher.update(std.mem.asBytes(&it.color));
        },
        .fill_rect => |it| {
            hasher.update("fill");
            hasher.update(std.mem.asBytes(&.{ it.x, it.y, it.w, it.h }));
            hasher.update(std.mem.asBytes(&it.color));
            hasher.update(std.mem.asBytes(&it.radius));
        },
        .stroke_rect => |it| {
            hasher.update("stroke");
            hasher.update(std.mem.asBytes(&.{ it.x, it.y, it.w, it.h }));
            hasher.update(std.mem.asBytes(&it.color));
        },
        else => hasher.update(@tagName(item)),
    }
}

fn inflate(r: ComputedRect, d: f32) ComputedRect {
    return ComputedRect.init(r.x - d, r.y - d, r.w + 2 * d, r.h + 2 * d);
}

fn contains(outer: ComputedRect, inner: ComputedRect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.w <= outer.x + outer.w and inner.y + inner.h <= outer.y + outer.h;
}

fn intersects(a: ComputedRect, b: ComputedRect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

fn intersect(a: ComputedRect, b: ComputedRect) ComputedRect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return ComputedRect.init(x0, y0, @max(0, x1 - x0), @max(0, y1 - y0));
}

test "placement keeps the subpixel phase and pads every cell" {
    const source: Source = .{ .node_id = 7, .period_ms = 1000, .context = null, .draw_at = undefined, .repaint = undefined };
    var tree: property_tree_mod.PropertyTree = undefined;
    var scene: scene_runtime_mod.SceneRuntime = undefined;
    const in: Registry.FrameInputs = .{ .scene_runtime = &scene, .property_tree = &tree, .display_list = &.{}, .scale = 2, .frame_time_ms = 0, .reduced_motion = false };
    const p = placementFor(&source, 0, .{ 10.25, 4, 20, 20 }, null, in).?;
    try std.testing.expectEqual([2]i32{ 18, 6 }, p.origin_px);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.subpixel[0], 1e-6);
    try std.testing.expectEqual([2]u32{ 45, 44 }, p.cell_px);
    try std.testing.expectEqual(@as(u32, 60), p.frame_count);
    const atlas = p.atlasSizePx();
    try std.testing.expect(atlas[0] >= p.cell_px[0] and atlas[1] >= p.cell_px[1]);
    try std.testing.expect(p.columns * ((p.frame_count + p.columns - 1) / p.columns) >= p.frame_count);
}

test "shadow reach stops where coverage is below half an 8-bit step" {
    try std.testing.expectEqual(@as(f32, 0), shadowReach(0, 255));
    // Opaque shadow: almost the full smoothstep band counts.
    try std.testing.expect(shadowReach(30, 255) > 28);
    // A faint shadow reaches much less far than its nominal blur.
    try std.testing.expect(shadowReach(30, 20) < shadowReach(30, 255));
    try std.testing.expect(shadowReach(30, 20) > 0);
}

test "paint items skip only placed sprites' contiguous ranges" {
    const allocator = std.testing.allocator;
    var reg: Registry = .{ .enabled = true };
    defer reg.deinit(allocator);
    try reg.register(allocator, 3, 1000, null, undefined, undefined);
    reg.beginLowering();
    reg.noteLowered(1, 0, false);
    reg.noteLowered(3, 1, false);
    reg.noteLowered(3, 2, false);
    reg.noteLowered(1, 3, false);
    try reg.placements.append(allocator, .{ .node_id = 3, .key = 1, .origin_px = .{ 0, 0 }, .cell_px = .{ 1, 1 }, .clip_px = null, .columns = 1, .frame_count = 1, .period_ms = 1, .frame_time_ms = 0, .scale = 1, .subpixel = .{ 0, 0 }, .logical_size = .{ 1, 1 }, .source_index = 0 });
    const main = [_]PaintItem{ .{ .kind = .rect, .stroke_width = 0 }, .{ .kind = .path, .stroke_width = 1 }, .{ .kind = .path, .stroke_width = 2 }, .{ .kind = .rect, .stroke_width = 3 } };
    const out = reg.paintItems(allocator, &main);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(f32, 0), out[0].stroke_width);
    try std.testing.expectEqual(@as(f32, 3), out[1].stroke_width);
}

test "an unfiltered registry hands the encoder the whole paint list" {
    const allocator = std.testing.allocator;
    var reg: Registry = .{ .enabled = true, .filter_placed = false };
    defer reg.deinit(allocator);
    try reg.register(allocator, 3, 1000, null, undefined, undefined);
    reg.beginLowering();
    reg.noteLowered(3, 0, false);
    try reg.placements.append(allocator, .{ .node_id = 3, .key = 1, .origin_px = .{ 0, 0 }, .cell_px = .{ 1, 1 }, .clip_px = null, .columns = 1, .frame_count = 1, .period_ms = 1, .frame_time_ms = 0, .scale = 1, .subpixel = .{ 0, 0 }, .logical_size = .{ 1, 1 }, .source_index = 0 });
    const main = [_]PaintItem{ .{ .kind = .path, .stroke_width = 1 }, .{ .kind = .rect, .stroke_width = 2 } };
    try std.testing.expectEqual(@as(usize, 2), reg.paintItems(allocator, &main).len);
}

test "a broken or control-carrying range is never filtered" {
    var reg: Registry = .{};
    defer reg.deinit(std.testing.allocator);
    try reg.register(std.testing.allocator, 3, 1000, null, undefined, undefined);
    reg.beginLowering();
    reg.noteLowered(3, 1, false);
    reg.noteLowered(3, 4, false);
    try std.testing.expect(reg.sources.items[0].paint_broken);
    reg.beginLowering();
    reg.noteLowered(3, 1, true);
    try std.testing.expect(reg.sources.items[0].paint_broken);
}

test "shared occlusion index answers like the per-sprite scan" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x0cc1);
    const random = prng.random();
    var tree: property_tree_mod.PropertyTree = undefined;
    var scene: scene_runtime_mod.SceneRuntime = undefined;
    var occ: Occlusion = .{};
    defer occ.deinit(allocator);
    var sources: [4]Source = undefined;
    for (&sources, 0..) |*s, k| s.* = .{ .node_id = @intCast(k + 1), .period_ms = 1000, .context = null, .draw_at = undefined, .repaint = undefined };
    for (0..300) |_| {
        var items: [40]DisplayItem = undefined;
        for (&items) |*it| {
            const node: u32 = random.uintLessThan(u32, 8) + 1;
            it.* = if (random.uintLessThan(u8, 6) == 0)
                .{ .pop_clip = .{ .header = .{ .already_lowered = true, .transform_id = INVALID_ID, .node_id = node } } }
            else
                .{ .fill_rect = .{ .header = .{ .already_lowered = true, .transform_id = INVALID_ID, .node_id = node }, .x = random.float(f32) * 200, .y = random.float(f32) * 200, .w = random.float(f32) * 40, .h = random.float(f32) * 40, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } } };
        }
        const in: Registry.FrameInputs = .{ .scene_runtime = &scene, .property_tree = &tree, .display_list = &items, .scale = 1, .frame_time_ms = 0, .reduced_motion = false };
        occ.reset(allocator, items.len, &sources);
        for (0..6) |_| {
            const node: u32 = random.uintLessThan(u32, 4) + 1;
            const rect = ComputedRect.init(random.float(f32) * 200, random.float(f32) * 200, 1 + random.float(f32) * 30, 1 + random.float(f32) * 30);
            try std.testing.expectEqual(occludedScan(in, node, rect), occ.occluded(in, node, rect));
        }
    }
}

test "sprite flipbook scratch skips unused fingerprints without changing keys or paint" {
    const Probe = struct {
        draws: usize = 0,
        fingerprinted: usize = 0,

        fn draw(ctx: DrawContext, raw: ?*anyopaque, now_ms: f64) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.draws += 1;
            const list = ctx.display_list.?;
            const header = ctx.display_header.?;
            const phase: f32 = @floatCast(now_ms / 1000);
            try list.append(.{ .arc = .{
                .header = header,
                .cx = 10,
                .cy = 11,
                .outer_radius = 8,
                .stroke_width = 2,
                .start_angle = phase,
                .end_angle = phase + 1,
                .color = .{ .r = 33, .g = 66, .b = 99, .a = 255 },
            } });
            try list.append(.{ .fill_rect = .{
                .header = header,
                .x = 1,
                .y = 2,
                .w = 3,
                .h = 4,
                .radius = .{ 1, 1, 1, 1 },
                .color = .{ .r = 100, .g = 200, .b = 50, .a = 127 },
            } });
            try list.append(.{ .stroke_rect = .{
                .header = header,
                .x = 5,
                .y = 6,
                .w = 7,
                .h = 8,
                .width = 1,
                .color = .{ .r = 20, .g = 40, .b = 60, .a = 255 },
            } });
            // Inspect every emitted item before the next scratch.clear():
            // restoring the old drawFrame initialization makes this nonzero.
            for (list.items.items) |item| {
                if (item.header().local_fp != 0) self.fingerprinted += 1;
            }
        }
    };
    const a = std.testing.allocator;
    var scratch_probe: Probe = .{};
    var reference_probe: Probe = .{};
    var reg: Registry = .{};
    defer reg.deinit(a);
    var reference: Registry = .{};
    defer reference.deinit(a);
    try reg.register(a, 3, 5600, &scratch_probe, Probe.draw, undefined);
    try reference.register(a, 3, 5600, &reference_probe, Probe.draw, undefined);
    // Ordinary DisplayList defaults: an independent oracle for the old
    // fingerprinted path, including its key and every generated paint field.
    reference.scratch = display_list_mod.DisplayList.init(a);
    reference.scratch_ready = true;
    const p: Placement = .{
        .node_id = 3,
        .key = 0,
        .origin_px = .{ 20, 40 },
        .cell_px = .{ 44, 44 },
        .clip_px = null,
        .columns = 24,
        .frame_count = 336,
        .period_ms = 5600,
        .frame_time_ms = 0,
        .scale = 2,
        .logical_origin = .{ 10, 20 },
        .subpixel = .{ 0, 0 },
        .logical_size = .{ 20, 20 },
        .source_index = 0,
    };
    const key = try reg.contentKey(a, &reg.sources.items[0], p);
    try std.testing.expectEqual(key, try reference.contentKey(a, &reference.sources.items[0], p));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // Repeated atlas attempts must also stay transient after scratch.clear().
    for (0..2) |_| {
        const frames = try reg.generate(a, arena.allocator(), p);
        const expected = try reference.generate(a, arena.allocator(), p);
        try std.testing.expectEqualSlices(u32, expected.ends, frames.ends);
        try std.testing.expectEqual(@as(usize, p.frame_count) * 3, frames.items.len);
        for (expected.items, frames.items) |want, got| try std.testing.expectEqualDeep(want, got);
    }
    const draws = 1 + 2 * @as(usize, p.frame_count);
    try std.testing.expectEqual(draws, scratch_probe.draws);
    try std.testing.expectEqual(draws, reference_probe.draws);
    try std.testing.expectEqual(draws * 3, reference_probe.fingerprinted);
    try std.testing.expectEqual(@as(usize, 0), scratch_probe.fingerprinted);
}
