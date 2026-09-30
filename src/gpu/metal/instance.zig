/// Metal Instance 实现
///
/// Metal 不需要显式的 Instance 对象，这里主要用于设备枚举
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const Adapter = @import("adapter.zig").Adapter;

pub const Instance = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, desc: gpu.InstanceDescriptor) !Instance {
        _ = desc;
        return Instance{
            .allocator = allocator,
        };
    }

    pub fn enumerateAdapters(self: *Instance) ![]Adapter {
        // 使用 autorelease pool 防止内存峰值
        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // 首先查询设备数量
        var count: usize = 0;
        _ = mtl.metal_copy_all_devices(&count, null, 0);

        if (count == 0) {
            // 如果没有设备，尝试获取系统默认设备
            const default_device = mtl.createSystemDefaultDevice() orelse {
                return error.NoMetalDevices;
            };

            const adapters = try self.allocator.alloc(Adapter, 1);
            adapters[0] = Adapter{
                .device = default_device,
            };
            return adapters;
        }

        // 分配设备指针数组
        const devices = try self.allocator.alloc(?*anyopaque, count);
        defer self.allocator.free(devices);

        // 获取所有设备。两次调用间设备数可能变化（热插拔 eGPU/唤醒独显）：
        // 桥按 capacity 钳写入，这里只信"实际写入数"，不信第一次的 count
        var total: usize = 0;
        const written = mtl.metal_copy_all_devices(&total, devices.ptr, devices.len);
        if (written == 0) return error.NoMetalDevices;

        const adapters = try self.allocator.alloc(Adapter, written);

        for (0..written) |i| {
            const device: *mtl.MTLDevice = @ptrCast(devices[i].?);
            // 注意: metal_copy_all_devices 已经 retained，不需要再次 retain
            adapters[i] = Adapter{
                .device = device,
            };
        }

        return adapters;
    }

    pub fn deinit(self: *Instance) void {
        _ = self;
    }
};
