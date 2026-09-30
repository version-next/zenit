/// Metal Queue 实现
///
/// 用于提交命令缓冲区
const mtl = @import("metal_bindings.zig");

pub const Queue = struct {
    raw: *mtl.MTLCommandQueue,

    pub fn submit(self: *Queue, commands: []const CommandBuffer) void {
        _ = self;
        for (commands) |cmd| {
            mtl.metal_command_buffer_commit(cmd.raw);
        }
    }

    pub fn deinit(self: *Queue) void {
        mtl.release(self.raw);
    }
};

// 占位类型（在阶段 4 实现）
pub const CommandBuffer = struct {
    raw: *mtl.MTLCommandBuffer,
};
