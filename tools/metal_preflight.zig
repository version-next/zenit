//! Infrastructure preflight for the live-device Metal test contract.
//! A missing device fails before any integration test starts.

const std = @import("std");
const gpu = @import("gpu");

pub fn main() !void {
    const mtl = gpu.Backend.metal_bindings;
    const device = mtl.metal_create_system_default_device() orelse {
        std.debug.print(
            "METAL_PREFLIGHT BLOCKED: no system Metal device is visible; " ++
                "run test-metal in a logged-in Metal-capable macOS session\n",
            .{},
        );
        return error.MetalDeviceUnavailable;
    };
    defer mtl.release(device);

    const name = std.mem.span(mtl.metal_device_get_name(device));
    std.debug.print("METAL_PREFLIGHT PASS: device={s}\n", .{name});
}
