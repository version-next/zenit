//! Tile compaction of a compositor sprite flipbook (Windows host, see
//! sprite_host.zig). A flipbook sampled at the display refresh rate holds
//! hundreds of cells (a spinner: 672 at 120 Hz), but most of each cell does
//! not change between neighbouring frames: a spinner's arc body covers the
//! same pixels until a cap passes, and the background never changes. The cell
//! is cut into tiles; tiles that are the same in every frame come from one
//! base copy of the cell, and the others from a dictionary of their distinct
//! contents, each shown by its own compositor visual that steps through the
//! dictionary entries frame by frame. Contents are compared byte for byte, so
//! every composed frame is exactly the rendered one.
const std = @import("std");

/// Default tile edge (device pixels).
pub const tile_px: u32 = 8;
/// Compact atlas edges are multiples of this.
pub const edge_align: u32 = 16;
/// Largest compact atlas edge (Direct3D texture limit).
pub const max_edge: u32 = 16384;

/// A tile position inside the cell (edge tiles may be smaller).
pub const Tile = extern struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub const Compact = struct {
    /// Compact atlas: the base cell at (0, 0), then dictionary tiles in rows
    /// of `columns` from y = `tiles_top`. BGRA, `width * 4` bytes per row.
    width: u32,
    height: u32,
    pixels: []u8,
    columns: u32,
    tiles_top: u32,
    /// Positions whose content changes over the loop.
    tiles: []Tile,
    /// Dictionary entry shown by tiles[i] in frame f: frames[i * frame_count + f].
    frames: []u32,
    frame_count: u32,
    /// Dictionary size.
    entries: u32,
    /// Tile edge.
    tile: u32,

    pub fn deinit(self: *Compact, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        allocator.free(self.tiles);
        allocator.free(self.frames);
        self.* = undefined;
    }

    /// Atlas pixel origin of dictionary entry `index`.
    pub fn entryOrigin(self: *const Compact, index: u32) [2]u32 {
        return .{ (index % self.columns) * self.tile, self.tiles_top + (index / self.columns) * self.tile };
    }

    pub fn bytes(self: *const Compact) u64 {
        return @as(u64, self.width) * self.height * 4;
    }
};

/// Builds a Compact from the frames of a loop, fed in order one cell at a
/// time (the host renders and reads back a few frames at a time).
pub const Builder = struct {
    allocator: std.mem.Allocator,
    cell: [2]u32,
    frame_count: u32,
    positions: []Tile,
    /// Dictionary entry per (position, frame): seq[position * frame_count + frame].
    seq: []u32,
    /// Frame 0's whole cell.
    base: []u8,
    /// Dictionary: tile * tile * 4 bytes per entry (zero padded) and its size.
    entries: std.ArrayList(u8) = .empty,
    entry_size: std.ArrayList([2]u16) = .empty,
    by_hash: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    next_frame: u32 = 0,
    tile: u32,
    entry_bytes: usize,
    scratch: []u8,

    pub fn init(allocator: std.mem.Allocator, cell: [2]u32, frame_count: u32, tile: u32) !Builder {
        const cw = cell[0];
        const ch = cell[1];
        if (cw == 0 or ch == 0 or frame_count == 0 or cw > max_edge or ch > max_edge or tile == 0 or tile > 1024) return error.InvalidFlipbook;
        const tile_px_ = tile;
        const nx = (cw + tile_px_ - 1) / tile_px_;
        const ny = (ch + tile_px_ - 1) / tile_px_;
        const positions = try allocator.alloc(Tile, nx * ny);
        errdefer allocator.free(positions);
        for (0..ny) |ty| for (0..nx) |tx| {
            positions[ty * nx + tx] = .{
                .x = @intCast(tx * tile_px_),
                .y = @intCast(ty * tile_px_),
                .w = @intCast(@min(tile_px_, cw - tx * tile_px_)),
                .h = @intCast(@min(tile_px_, ch - ty * tile_px_)),
            };
        };
        const seq = try allocator.alloc(u32, positions.len * frame_count);
        errdefer allocator.free(seq);
        const base = try allocator.alloc(u8, @as(usize, cw) * ch * 4);
        errdefer allocator.free(base);
        const entry_bytes = @as(usize, tile) * tile * 4;
        const scratch = try allocator.alloc(u8, entry_bytes);
        return .{ .allocator = allocator, .cell = cell, .frame_count = frame_count, .positions = positions, .seq = seq, .base = base, .tile = tile, .entry_bytes = entry_bytes, .scratch = scratch };
    }

    pub fn deinit(self: *Builder) void {
        self.allocator.free(self.positions);
        self.allocator.free(self.seq);
        self.allocator.free(self.base);
        self.allocator.free(self.scratch);
        self.entries.deinit(self.allocator);
        self.entry_size.deinit(self.allocator);
        self.by_hash.deinit(self.allocator);
        self.* = undefined;
    }

    /// The next frame's cell: rows of `cell[0] * 4` bytes, `stride` apart.
    pub fn add(self: *Builder, pixels: []const u8, stride: usize) !void {
        if (self.next_frame >= self.frame_count) return error.TooManyFrames;
        const cw = self.cell[0];
        const ch = self.cell[1];
        if (stride < @as(usize, cw) * 4 or pixels.len < stride * (ch - 1) + @as(usize, cw) * 4) return error.InvalidFlipbook;
        const f = self.next_frame;
        if (f == 0) for (0..ch) |row| @memcpy(self.base[row * cw * 4 ..][0 .. cw * 4], pixels[row * stride ..][0 .. cw * 4]);
        const tile = self.scratch;
        const entry_bytes = self.entry_bytes;
        const row_bytes = @as(usize, self.tile) * 4;
        for (self.positions, 0..) |t, i| {
            @memset(tile, 0);
            for (0..t.h) |row| {
                const src = pixels[(t.y + row) * stride + @as(usize, t.x) * 4 ..][0 .. @as(usize, t.w) * 4];
                @memcpy(tile[row * row_bytes ..][0..src.len], src);
            }
            var key = std.hash.Wyhash.hash(@as(u64, t.w) << 16 | t.h, tile);
            const index: u32 = while (true) : (key = key *% 0x9e3779b97f4a7c15 +% 1) {
                const slot = try self.by_hash.getOrPut(self.allocator, key);
                if (!slot.found_existing) {
                    const n: u32 = @intCast(self.entry_size.items.len);
                    try self.entries.appendSlice(self.allocator, tile);
                    try self.entry_size.append(self.allocator, .{ t.w, t.h });
                    slot.value_ptr.* = n;
                    break n;
                }
                const e = slot.value_ptr.*;
                const size = self.entry_size.items[e];
                if (size[0] == t.w and size[1] == t.h and std.mem.eql(u8, self.entries.items[@as(usize, e) * entry_bytes ..][0..entry_bytes], tile)) break e;
                // Hash collision: probe the next key.
            };
            self.seq[i * self.frame_count + f] = index;
        }
        self.next_frame += 1;
    }

    /// Every frame added: keep the tiles that change and the entries they use.
    pub fn finish(self: *Builder) !Compact {
        if (self.next_frame != self.frame_count) return error.MissingFrames;
        const allocator = self.allocator;
        const n_frames = self.frame_count;
        const cw = self.cell[0];
        const ch = self.cell[1];
        const remap = try allocator.alloc(u32, self.entry_size.items.len);
        defer allocator.free(remap);
        @memset(remap, std.math.maxInt(u32));
        var tiles: std.ArrayList(Tile) = .empty;
        defer tiles.deinit(allocator);
        var frames: std.ArrayList(u32) = .empty;
        defer frames.deinit(allocator);
        var used: std.ArrayList(u32) = .empty;
        defer used.deinit(allocator);
        for (self.positions, 0..) |t, i| {
            const s = self.seq[i * n_frames ..][0..n_frames];
            const varies = for (s[1..]) |e| {
                if (e != s[0]) break true;
            } else false;
            // Same in every frame: the base cell (frame 0) shows it.
            if (!varies) continue;
            try tiles.append(allocator, t);
            for (s) |e| {
                if (remap[e] == std.math.maxInt(u32)) {
                    remap[e] = @intCast(used.items.len);
                    try used.append(allocator, e);
                }
                try frames.append(allocator, remap[e]);
            }
        }
        const n: u32 = @intCast(used.items.len);
        // Near-square dictionary block, at least as wide as the base cell.
        const want_columns: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(@max(n, 1))))))));
        const t_px = self.tile;
        const width = std.mem.alignForward(u32, @max(cw, want_columns * t_px), edge_align);
        const columns = width / t_px;
        const rows = (n + columns - 1) / columns;
        // Whole multiples of 16: on Intel's Direct3D 11 driver DWM showed the
        // last rows of a 405-row composition swap chain as black.
        const height = std.mem.alignForward(u32, ch + rows * t_px, edge_align);
        if (width > max_edge or height > max_edge) return error.FlipbookTooLarge;
        const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);
        const stride = @as(usize, width) * 4;
        for (0..ch) |row| @memcpy(pixels[row * stride ..][0 .. @as(usize, cw) * 4], self.base[row * cw * 4 ..][0 .. cw * 4]);
        for (used.items, 0..) |e, i| {
            const ox = (@as(u32, @intCast(i)) % columns) * t_px;
            const oy = ch + (@as(u32, @intCast(i)) / columns) * t_px;
            const src = self.entries.items[@as(usize, e) * self.entry_bytes ..][0..self.entry_bytes];
            for (0..t_px) |row| @memcpy(pixels[(oy + row) * stride + @as(usize, ox) * 4 ..][0 .. t_px * 4], src[row * t_px * 4 ..][0 .. t_px * 4]);
        }
        const owned_tiles = try tiles.toOwnedSlice(allocator);
        errdefer allocator.free(owned_tiles);
        const owned_frames = try frames.toOwnedSlice(allocator);
        return .{ .width = width, .height = height, .pixels = pixels, .columns = columns, .tiles_top = ch, .tiles = owned_tiles, .frames = owned_frames, .frame_count = n_frames, .entries = n, .tile = t_px };
    }
};

/// The full flipbook as rendered: frame f's cell at
/// ((f % columns) * cell[0], (f / columns) * cell[1]).
pub const Flipbook = struct {
    pixels: []const u8,
    stride: u32,
    cell: [2]u32,
    columns: u32,
    frame_count: u32,
};

pub fn compact(allocator: std.mem.Allocator, book: Flipbook) !Compact {
    return compactWith(allocator, book, tile_px);
}

pub fn compactWith(allocator: std.mem.Allocator, book: Flipbook, tile: u32) !Compact {
    var b = try Builder.init(allocator, book.cell, book.frame_count, tile);
    defer b.deinit();
    for (0..book.frame_count) |f| {
        const x = (f % book.columns) * book.cell[0];
        const y = (f / book.columns) * book.cell[1];
        try b.add(book.pixels[y * book.stride + x * 4 ..], book.stride);
    }
    return b.finish();
}

/// Frame `frame` as the compositor composes it (tests and pixel checks):
/// the base cell with every varying tile's entry for that frame on top.
pub fn compose(c: *const Compact, cell: [2]u32, frame: u32, out: []u8) void {
    const stride = @as(usize, c.width) * 4;
    const out_stride = @as(usize, cell[0]) * 4;
    for (0..cell[1]) |row| @memcpy(out[row * out_stride ..][0..out_stride], c.pixels[row * stride ..][0..out_stride]);
    for (c.tiles, 0..) |t, i| {
        const o = c.entryOrigin(c.frames[i * c.frame_count + frame]);
        for (0..t.h) |row| {
            const src = c.pixels[(o[1] + row) * stride + @as(usize, o[0]) * 4 ..][0 .. @as(usize, t.w) * 4];
            @memcpy(out[(t.y + row) * out_stride + @as(usize, t.x) * 4 ..][0..src.len], src);
        }
    }
}

test "compaction keeps every frame byte for byte and stores changing tiles once" {
    const allocator = std.testing.allocator;
    // 29x21 cells (edge tiles are partial), 24 frames in 5 columns: a static
    // background with a 3x3 dot orbiting, so most tiles never change and the
    // ones on its path take a few distinct contents.
    const cell = [2]u32{ 29, 21 };
    const frame_count: u32 = 24;
    const columns: u32 = 5;
    const rows = (frame_count + columns - 1) / columns;
    const stride = columns * cell[0] * 4;
    const pixels = try allocator.alloc(u8, stride * rows * cell[1]);
    defer allocator.free(pixels);
    for (0..frame_count) |f| {
        const fx = (f % columns) * cell[0];
        const fy = (f / columns) * cell[1];
        const angle = @as(f32, @floatFromInt(f)) / @as(f32, @floatFromInt(frame_count)) * std.math.tau;
        const dx: usize = @intFromFloat(@round(6 + 3 * @cos(angle)));
        const dy: usize = @intFromFloat(@round(6 + 3 * @sin(angle)));
        for (0..cell[1]) |y| for (0..cell[0]) |x| {
            const p = pixels[(fy + y) * stride + (fx + x) * 4 ..][0..4];
            const dot = x >= dx and x < dx + 3 and y >= dy and y < dy + 3;
            p.* = if (dot) .{ 30, 60, 200, 255 } else .{ @intCast(x * 7), @intCast(y * 11), 77, 255 };
        };
    }
    const book: Flipbook = .{ .pixels = pixels, .stride = stride, .cell = cell, .columns = columns, .frame_count = frame_count };
    const out = try allocator.alloc(u8, cell[0] * cell[1] * 4);
    defer allocator.free(out);
    // Tiles from a few pixels to larger than the cell (one tile: the plain flipbook).
    for ([_]u32{ 3, 8, 16, 64 }) |tile| {
        var c = try compactWith(allocator, book, tile);
        defer c.deinit(allocator);
        if (tile == 8) {
            // 4x3 positions; only those on the dot's path change.
            try std.testing.expect(c.tiles.len > 0 and c.tiles.len < 12);
            try std.testing.expect(c.entries < c.tiles.len * frame_count);
            try std.testing.expect(c.bytes() < @as(u64, stride) * rows * cell[1]);
        }
        try std.testing.expect(c.width % edge_align == 0 and c.height % edge_align == 0);
        for (0..frame_count) |f| {
            compose(&c, cell, @intCast(f), out);
            for (0..cell[1]) |y| {
                const want = pixels[((f / columns) * cell[1] + y) * stride + (f % columns) * cell[0] * 4 ..][0 .. cell[0] * 4];
                try std.testing.expectEqualSlices(u8, want, out[y * cell[0] * 4 ..][0 .. cell[0] * 4]);
            }
        }
    }
}

test "a still flipbook needs no tiles" {
    const allocator = std.testing.allocator;
    const cell = [2]u32{ 9, 9 };
    const pixels = try allocator.alloc(u8, 4 * cell[0] * 4 * cell[1]);
    defer allocator.free(pixels);
    @memset(pixels, 0x5a);
    var c = try compact(allocator, .{ .pixels = pixels, .stride = 4 * cell[0] * 4, .cell = cell, .columns = 4, .frame_count = 4 });
    defer c.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), c.tiles.len);
    try std.testing.expectEqual(@as(u32, 0), c.entries);
}
