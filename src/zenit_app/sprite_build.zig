//! Windows compositor sprite atlas builds (sprite_host.zig), spread over the
//! frames that run anyway while a sprite settles: a 120 Hz loop has hundreds
//! of flipbook frames, and rendering them all at once stalled the animation
//! for tens of milliseconds per sprite. After each presented frame a build
//! queues a chunk of flipbook frames (renderSpriteFrames, at the sprite's own
//! window position; outside the frame's encoding, behind its GPU work), and a
//! later frame takes the read-back cells into the tile compaction
//! (sprite_tiles.zig). The node keeps being painted by the GPU meanwhile.
const std = @import("std");
const gpu = @import("gpu");
const tiles = @import("sprite_tiles.zig");

/// Cells read back per chunk, at most this many bytes and frames. The frame
/// bound also bounds the command list: one render pass and copy per flipbook
/// frame (a chunk of hundreds of thin cells grew the driver's command storage
/// by tens of megabytes it kept).
const chunk_bytes: u64 = 512 * 1024;
const chunk_frames: u64 = 8;
/// Main-thread time per frame for submitting chunks (a flipbook frame costs
/// about 0.1 ms to encode): the GPU path keeps its frame rate while sprites
/// are being built.
pub const budget_ns: u64 = 1500 * std.time.ns_per_us;

/// The render target every build rasterizes in, shared (builds submit one
/// chunk after another on the queue, each copied out before the next draws):
/// frames rasterize at their own window coordinates, so it spans the window.
/// One allocation of one size while builds are in progress, released when none
/// is left (growing it per cell made the driver keep every size it had seen).
pub const Scratch = struct {
    texture: ?gpu.Backend.Texture = null,

    pub fn cover(self: *Scratch, renderer: anytype, corner: [2]u32) !*gpu.Backend.Texture {
        const config = renderer.surface.config orelse return error.SpriteOffscreen;
        if (corner[0] > config.width or corner[1] > config.height) return error.SpriteOffscreen;
        if (self.texture) |*t| {
            if (t.size.width == config.width and t.size.height == config.height) return t;
            // The window was resized: submitted chunks keep their own reference.
            t.destroy();
            self.texture = null;
        }
        self.texture = try renderer.device.createTexture(renderer.allocator, .{
            .label = "Zenit.Sprite.Scratch",
            .size = .{ .width = config.width, .height = config.height },
            .format = gpu.color_format,
            .usage = .{ .copy_src = true, .texture_binding = true, .render_attachment = true },
            .memory = .device_local,
        });
        return &self.texture.?;
    }

    pub fn release(self: *Scratch) void {
        if (self.texture) |*t| t.destroy();
        self.texture = null;
    }
};

/// A build as the host keeps it: its concrete type depends on the UI's
/// placement and paint item types (see Build), which the host only sees
/// through a Cx.
pub const Entry = struct {
    ptr: *anyopaque,
    key: u64,
    /// Host clock of the last frame that asked for it.
    seen: u64,
    destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void,

    pub fn destroy(self: Entry, allocator: std.mem.Allocator) void {
        self.destroy_fn(self.ptr, allocator);
    }
};

/// `Registry`: the UI's compositor sprite registry type.
pub fn Build(comptime Registry: type) type {
    const Placement = @typeInfo(@FieldType(@FieldType(Registry, "placements"), "items")).pointer.child;
    const PaintItem = @typeInfo(@FieldType(@FieldType(Registry, "filtered"), "items")).pointer.child;
    return struct {
        const Self = @This();
        p: Placement,
        /// Flipbook frames' paint items (frame f: items[ends[f-1]..ends[f]]) and
        /// the frame's items under the cell, owned.
        items: []PaintItem,
        ends: []u32,
        background: []PaintItem,
        own_at: usize,
        readback: gpu.Backend.Buffer,
        row_pitch: u32,
        frame_stride: u64,
        chunk: u32,
        builder: tiles.Builder,
        next: u32 = 0,
        in_flight: ?InFlight = null,

        const InFlight = struct { count: u32, command: gpu.Backend.CommandBuffer };

        /// `scratch`: the host's shared render target, already covering the
        /// cell's bottom-right corner (see Scratch).
        pub fn start(renderer: anytype, scratch: *gpu.Backend.Texture, key: u64, p: Placement, frames: Registry.Frames, background: []const PaintItem, own_at: usize, tile: u32, clock: u64) !Entry {
            const allocator = renderer.allocator;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const items = try allocator.dupe(PaintItem, frames.items);
            errdefer allocator.free(items);
            const ends = try allocator.dupe(u32, frames.ends);
            errdefer allocator.free(ends);
            const owned_background = try allocator.dupe(PaintItem, background);
            errdefer allocator.free(owned_background);
            const layout = try scratch.inner.copyLayout(.{ .x = @intCast(p.origin_px[0]), .y = @intCast(p.origin_px[1]), .width = p.cell_px[0], .height = p.cell_px[1] }, 0);
            const frame_stride = std.mem.alignForward(u64, layout.required_bytes, 512);
            const chunk: u32 = @intCast(std.math.clamp(chunk_bytes / frame_stride, 1, @min(chunk_frames, p.frame_count)));
            var readback = try renderer.device.createBuffer(allocator, .{ .size = frame_stride * chunk, .usage = .{ .map_read = true, .copy_dst = true } });
            errdefer readback.destroy();
            const builder = try tiles.Builder.init(allocator, p.cell_px, p.frame_count, tile);
            self.* = .{
                .p = p,
                .items = items,
                .ends = ends,
                .background = owned_background,
                .own_at = own_at,
                .readback = readback,
                .row_pitch = layout.row_pitch,
                .frame_stride = frame_stride,
                .chunk = chunk,
                .builder = builder,
            };
            return .{ .ptr = self, .key = key, .seen = clock, .destroy_fn = destroyErased };
        }

        pub fn of(entry: Entry) *Self {
            return @ptrCast(@alignCast(entry.ptr));
        }

        fn destroyErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.destroy(allocator);
        }

        /// Take the finished chunk into the builder. True once every frame is in.
        pub fn collect(self: *Self) !bool {
            if (self.in_flight) |*flight| {
                if (!flight.command.isCompleted()) return false;
                const mapped = try self.readback.getMappedRange(0, self.frame_stride * self.chunk);
                for (0..flight.count) |i| try self.builder.add(mapped[i * self.frame_stride ..], self.row_pitch);
                flight.command.deinit();
                self.in_flight = null;
            }
            return self.next == self.p.frame_count and self.in_flight == null;
        }

        /// Submit the next chunk (after the frame's own work: call once the frame
        /// is presented). False when there is nothing to submit now.
        pub fn submit(self: *Self, renderer: anytype, scratch: *gpu.Backend.Texture) !bool {
            if (self.in_flight != null or self.next >= self.p.frame_count) return false;
            const count = @min(self.chunk, self.p.frame_count - self.next);
            const frames: Registry.Frames = .{ .items = self.items, .ends = self.ends };
            const background: []const PaintItem = self.background;
            const command = try renderer.renderSpriteFrames(scratch, &self.readback, self.row_pitch, self.frame_stride, frames, background, self.own_at, self.p, self.next, count);
            self.in_flight = .{ .count = count, .command = command };
            self.next += count;
            return true;
        }

        pub fn finish(self: *Self) !tiles.Compact {
            return self.builder.finish();
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            if (self.in_flight) |*flight| {
                // Its copy still writes the readback buffer.
                flight.command.waitChecked(5000) catch {};
                flight.command.deinit();
            }
            self.builder.deinit();
            self.readback.destroy();
            allocator.free(self.items);
            allocator.free(self.ends);
            allocator.free(self.background);
            allocator.destroy(self);
        }
    };
}
