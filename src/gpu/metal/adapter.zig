/// Metal Adapter 实现
///
/// 代表一个 Metal 设备，用于查询能力和创建 Device
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const Device = @import("device.zig").Device;
const Queue = @import("queue.zig").Queue;

pub const Adapter = struct {
    device: *mtl.MTLDevice,

    pub fn requestDevice(self: *Adapter, allocator: std.mem.Allocator, desc: gpu.DeviceDescriptor) !struct { device: Device, queue: Queue } {
        _ = allocator;

        // 创建命令队列
        const command_queue = mtl.metal_device_new_command_queue(self.device) orelse {
            return error.FailedToCreateCommandQueue;
        };

        return .{
            .device = Device{
                .raw_device = mtl.retain(self.device),
                .features = desc.required_features,
                .limits = desc.required_limits,
            },
            .queue = Queue{
                .raw = command_queue,
            },
        };
    }

    pub fn deinit(self: *Adapter) void {
        mtl.release(self.device);
    }
};
