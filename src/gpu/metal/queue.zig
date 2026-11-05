/// Metal Queue implementation
///
/// Used to submit command buffers
const mtl = @import("metal_bindings.zig");

pub const Queue = struct {
    raw: *mtl.MTLCommandQueue,

    pub fn submit(self: *Queue, commands: []const CommandBuffer) void {
        _ = self;
        for (commands) |cmd| {
            mtl.metal_command_buffer_commit(cmd.raw);
        }
    }

    /// Replace the command queue with a fresh one, dropping the pools the
    /// driver keeps per queue (idle trim). Submitted command buffers retain
    /// the old queue until they complete.
    pub fn recreate(self: *Queue, raw_device: *mtl.MTLDevice) bool {
        const fresh = mtl.metal_device_new_command_queue(raw_device) orelse return false;
        mtl.release(self.raw);
        self.raw = fresh;
        return true;
    }

    pub fn deinit(self: *Queue) void {
        mtl.release(self.raw);
    }
};

// Placeholder type (implemented in Phase 4)
pub const CommandBuffer = struct {
    raw: *mtl.MTLCommandBuffer,
};
