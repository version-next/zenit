//! Windows caret blink handed to DirectComposition (the macOS equivalent is the
//! Core Animation caret patch, see runtime.zig enterCaretFlip).
//!
//! A focused editor otherwise renders the whole window twice a second just to
//! blink its caret, which also keeps the window from ever reaching idle trim.
//! Once the caret has been quiet for the admission delay, the runtime renders
//! two frames, one with the caret hidden and one with it shown, and copies the
//! caret's patch out of each composed back buffer into a small atlas. A
//! compositor sprite (sprite_host.zig) then shows those two pictures in turn,
//! stepped by DWM: the application renders nothing until something else
//! changes, which hands the caret back to the regular frame.
//!
//! The pictures are the composed frames themselves, so whatever covers the
//! caret (a popup, a selection, glass) is already in them; a covered caret has
//! two equal pictures and simply does not visibly blink.
//!
//! This file holds the platform-independent parts: patch geometry, the atlas
//! layout the sprite host shows, and the blink phase.
const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const tiles = @import("sprite_tiles.zig");

/// Windows Direct3D: the sprite host's DirectComposition tree. Elsewhere the
/// caret blinks through the regular frame (macOS has its own patch).
pub const supported = builtin.os.tag == .windows and gpu.is_direct3d;

/// Sprite node id reserved for the caret (no UI node has it).
pub const node_id: u32 = std.math.maxInt(u32) - 1;

/// Pixels added around the caret rectangles: antialiased caret edges spill
/// into the neighbouring pixel at fractional positions.
pub const outset_px: i32 = 2;

/// Sprite frames: the caret shown, then hidden (one half period each).
pub const frame_visible: u32 = 0;
pub const frame_hidden: u32 = 1;
pub const frame_count: u32 = 2;

/// The caret's patch in window device pixels: the union of the declared
/// caret rectangles (logical units), outset and clamped to the drawable.
/// Null when nothing of it is inside the window.
pub fn patchRect(rects: []const [4]f32, scale: f32, drawable: [2]u32) ?[4]i32 {
    if (rects.len == 0 or !(scale > 0)) return null;
    var x0: f32 = std.math.inf(f32);
    var y0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var y1: f32 = -std.math.inf(f32);
    for (rects) |r| {
        if (!(r[2] > 0 and r[3] > 0)) continue;
        x0 = @min(x0, r[0]);
        y0 = @min(y0, r[1]);
        x1 = @max(x1, r[0] + r[2]);
        y1 = @max(y1, r[1] + r[3]);
    }
    if (!(x1 > x0 and y1 > y0)) return null;
    const left: i32 = @as(i32, @intFromFloat(@floor(x0 * scale))) - outset_px;
    const top: i32 = @as(i32, @intFromFloat(@floor(y0 * scale))) - outset_px;
    const right: i32 = @as(i32, @intFromFloat(@ceil(x1 * scale))) + outset_px;
    const bottom: i32 = @as(i32, @intFromFloat(@ceil(y1 * scale))) + outset_px;
    const cl = @max(left, 0);
    const ct = @max(top, 0);
    const cr = @min(right, @as(i32, @intCast(drawable[0])));
    const cb = @min(bottom, @as(i32, @intCast(drawable[1])));
    if (cr <= cl or cb <= ct) return null;
    return .{ cl, ct, cr - cl, cb - ct };
}

/// Where each picture goes in the atlas, in the sprite host's compact layout
/// (sprite_tiles.Compact): the base cell at (0, 0) shows the hidden caret, and
/// one tile covering the whole cell steps through two dictionary entries
/// (shown, hidden) in a row from `tiles_top`.
pub const Layout = struct {
    cell: [2]u32,
    /// Square dictionary tile edge (covers the cell).
    tile: u32,
    tiles_top: u32,
    columns: u32,
    atlas: [2]u32,

    pub fn init(cell: [2]u32) Layout {
        const tile = @max(cell[0], cell[1]);
        const columns: u32 = frame_count;
        return .{
            .cell = cell,
            .tile = tile,
            .tiles_top = cell[1],
            .columns = columns,
            .atlas = .{
                std.mem.alignForward(u32, @max(cell[0], columns * tile), tiles.edge_align),
                std.mem.alignForward(u32, cell[1] + tile, tiles.edge_align),
            },
        };
    }

    /// Atlas origin of the picture for `frame` (frame_visible / frame_hidden).
    pub fn entryOrigin(self: Layout, frame: u32) [2]u32 {
        return .{ (frame % self.columns) * self.tile, self.tiles_top + (frame / self.columns) * self.tile };
    }

    /// The one changing tile (the whole cell).
    pub fn tile0(self: Layout) tiles.Tile {
        return .{ .x = 0, .y = 0, .w = @intCast(self.cell[0]), .h = @intCast(self.cell[1]) };
    }

    /// Dictionary entry tile 0 shows per frame (tile-major, one tile).
    pub const frames = [frame_count]u32{ frame_visible, frame_hidden };

    pub fn fits(self: Layout) bool {
        return self.atlas[0] <= tiles.max_edge and self.atlas[1] <= tiles.max_edge and
            self.cell[0] <= std.math.maxInt(u16) and self.cell[1] <= std.math.maxInt(u16);
    }
};

/// Renderer-owned caret sprite (Windows). Lifecycle, driven by the runtime:
///   begin (atlas sized for the patch) -> capture .hidden frame -> capture
///   .visible frame -> activate (the next sync puts the sprite) -> deactivate
///   (the next sync no longer puts it; the host removes it once the frame
///   painting the caret again is presented).
pub const State = struct {
    pub const Capture = enum { none, hidden, visible };

    atlas: if (supported) ?gpu.Backend.SpriteAtlas else void = if (supported) null else {},
    layout: Layout = Layout.init(.{ 1, 1 }),
    /// Window device-pixel patch (x, y, w, h).
    rect: [4]i32 = .{ 0, 0, 0, 0 },
    /// The picture the next submitted frame copies out of its back buffer.
    capture: Capture = .none,
    captured_hidden: bool = false,
    captured_visible: bool = false,
    /// The sprite host puts the caret sprite while set.
    active: bool = false,
    /// Identity of the current pictures (a new patch is a new sprite).
    key: u64 = 0,
    tiles_buf: [1]tiles.Tile = undefined,
    frames_buf: [frame_count]u32 = Layout.frames,

    /// Create the atlas for `rect` and forget
    /// earlier pictures. The sprite must not be active.
    pub fn begin(self: *State, device: anytype, rect: [4]i32) !void {
        if (comptime !supported) return error.Unsupported;
        std.debug.assert(!self.active);
        const cell: [2]u32 = .{ @intCast(rect[2]), @intCast(rect[3]) };
        const layout = Layout.init(cell);
        if (!layout.fits()) return error.CaretPatchTooLarge;
        // A new composition swap chain per entry: the atlas wraps the back
        // buffer that was current when it was created, and after activate()
        // presents it that buffer is on screen. Writing it again is invalid
        // (D3D12: a command list may only write the current back buffer; the
        // device is removed with DXGI_ERROR_ACCESS_DENIED). The previous
        // sprite left the composition tree frames ago, and a visual keeps its
        // own reference to the content it shows.
        if (self.atlas) |*atlas| atlas.destroy();
        self.atlas = null;
        self.atlas = try gpu.Backend.SpriteAtlas.create(device, layout.atlas[0], layout.atlas[1], gpu.color_format);
        self.layout = layout;
        self.rect = rect;
        self.tiles_buf = .{layout.tile0()};
        self.captured_hidden = false;
        self.captured_visible = false;
        self.capture = .none;
        self.key +%= 1;
    }

    /// Encode the pending capture into the frame about to be submitted:
    /// copy the patch out of `back_buffer` into the atlas.
    pub fn encodeCapture(self: *State, encoder: *gpu.Backend.CommandEncoder, back_buffer: gpu.Backend.TextureBinding) !void {
        if (comptime !supported) return;
        if (self.capture == .none) return;
        const atlas = &(self.atlas orelse return error.CaretAtlasMissing);
        const x: u32 = @intCast(self.rect[0]);
        const y: u32 = @intCast(self.rect[1]);
        const w = self.layout.cell[0];
        const h = self.layout.cell[1];
        if (x + w > back_buffer.width or y + h > back_buffer.height) return error.CaretPatchOutsideFrame;
        const target = atlas.texture.binding();
        const frame = if (self.capture == .visible) frame_visible else frame_hidden;
        const entry = self.layout.entryOrigin(frame);
        try gpu.copyTextureRegion(encoder, back_buffer, x, y, w, h, target, entry[0], entry[1], false);
        if (self.capture == .hidden) {
            // The base cell (under the stepping tile) shows the hidden caret too.
            try gpu.copyTextureRegion(encoder, back_buffer, x, y, w, h, target, 0, 0, false);
            self.captured_hidden = true;
        } else self.captured_visible = true;
        self.capture = .none;
    }

    /// Both pictures are in the atlas (after their frames were submitted):
    /// show the atlas and let the next sync put the sprite.
    pub fn activate(self: *State) !void {
        if (comptime !supported) return error.Unsupported;
        if (!self.captured_hidden or !self.captured_visible) return error.CaretPatchUnavailable;
        try (self.atlas orelse return error.CaretAtlasMissing).present();
        self.active = true;
    }

    /// The next sync stops putting the sprite.
    pub fn deactivate(self: *State) void {
        self.active = false;
        self.capture = .none;
    }

    /// Release the atlas (the sprite must have left the composition tree).
    pub fn deinit(self: *State) void {
        if (comptime supported) if (self.atlas) |*atlas| atlas.destroy();
        self.* = .{};
    }
};

/// Seconds into the sprite's loop (shown half first, then hidden half) for a
/// caret that is `visible` now and changes in `remaining_ns`.
pub fn phaseSeconds(visible: bool, remaining_ns: u64, half_ns: u64) f64 {
    const half: f64 = @floatFromInt(half_ns);
    const left: f64 = @floatFromInt(@min(remaining_ns, half_ns));
    const into_half = half - left;
    const into_loop = if (visible) into_half else half + into_half;
    return into_loop / std.time.ns_per_s;
}

test "patch covers every caret rectangle at device pixels, outset and clamped" {
    // A 2x18 caret at a fractional x on a 1.5x display.
    const r = patchRect(&.{.{ 100.3, 40, 2, 18 }}, 1.5, .{ 800, 600 }).?;
    try std.testing.expectEqual(@as(i32, 150 - outset_px), r[0]);
    try std.testing.expectEqual(@as(i32, 60 - outset_px), r[1]);
    try std.testing.expectEqual(@as(i32, 154 + outset_px) - r[0], r[2]);
    try std.testing.expectEqual(@as(i32, 87 + outset_px) - r[1], r[3]);
    // Two rectangles (a caret drawn in two parts) make one patch.
    const u = patchRect(&.{ .{ 10, 10, 2, 10 }, .{ 30, 12, 2, 10 } }, 1, .{ 800, 600 }).?;
    try std.testing.expectEqual([4]i32{ 8, 8, 26, 16 }, u);
    // Clamped at the window edge; wholly outside is nothing.
    try std.testing.expectEqual([4]i32{ 0, 0, 3, 13 }, patchRect(&.{.{ 0, 0, 1, 11 }}, 1, .{ 800, 600 }).?);
    try std.testing.expect(patchRect(&.{.{ 900, 10, 2, 10 }}, 1, .{ 800, 600 }) == null);
    try std.testing.expect(patchRect(&.{}, 1, .{ 800, 600 }) == null);
    try std.testing.expect(patchRect(&.{.{ 10, 10, 0, 10 }}, 1, .{ 800, 600 }) == null);
}

test "layout puts the hidden base cell and both pictures inside the atlas" {
    const l = Layout.init(.{ 7, 31 });
    try std.testing.expect(l.fits());
    try std.testing.expectEqual(@as(u32, 31), l.tile);
    try std.testing.expectEqual([2]u32{ 0, 31 }, l.entryOrigin(frame_visible));
    try std.testing.expectEqual([2]u32{ 31, 31 }, l.entryOrigin(frame_hidden));
    for ([_]u32{ frame_visible, frame_hidden }) |f| {
        const o = l.entryOrigin(f);
        try std.testing.expect(o[0] + l.cell[0] <= l.atlas[0] and o[1] + l.cell[1] <= l.atlas[1]);
    }
    try std.testing.expect(l.cell[0] <= l.atlas[0] and l.cell[1] <= l.atlas[1]);
    try std.testing.expectEqual(@as(u32, 0), l.atlas[0] % tiles.edge_align);
    try std.testing.expectEqual(@as(u32, 0), l.atlas[1] % tiles.edge_align);
}

test "phase starts the loop at the caret's current half" {
    const half: u64 = 530 * std.time.ns_per_ms;
    // Just turned visible: start of the loop.
    try std.testing.expectApproxEqAbs(@as(f64, 0), phaseSeconds(true, half, half), 1e-9);
    // Visible, 130 ms left: 400 ms into the shown half.
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), phaseSeconds(true, 130 * std.time.ns_per_ms, half), 1e-9);
    // Hidden, 30 ms left: 500 ms into the hidden half.
    try std.testing.expectApproxEqAbs(@as(f64, 1.03), phaseSeconds(false, 30 * std.time.ns_per_ms, half), 1e-9);
    // An overdue change counts as due now.
    try std.testing.expectApproxEqAbs(@as(f64, 0.53), phaseSeconds(true, 0, half), 1e-9);
}
