//! The tab lens's measured field table (tab_lens_field_table.zig) as a GPU buffer: the glass
//! composite reads it from fragment buffer `slot` (glass.metal `tab_lens_table`, HLSL
//! StructuredBuffer t1). Uploaded once per device and never written again, so every frame in
//! flight reads the same bytes. The table is not compiled into the shader: FXC's compile time
//! grows with an embedded constant array (25 s for this one on D3D12; D3D11 timed out).
const std = @import("std");
const gpu = @import("gpu");

pub const table = @import("tab_lens_field_table.zig");

/// Fragment buffer slot of glass_fragment_main's table.
pub const slot: u32 = 1;

pub const bytes: []const u8 = std.mem.sliceAsBytes(&table.table);

pub fn create(allocator: std.mem.Allocator, device: *gpu.Backend.Device) !gpu.Backend.Buffer {
    var buffer = try device.createBuffer(allocator, .{
        .label = "Zenit.Glass.TabLensField",
        .size = bytes.len,
        .usage = .{ .vertex = true, .map_write = true },
    });
    errdefer buffer.destroy();
    @memcpy(try buffer.getMappedRange(0, bytes.len), bytes);
    return buffer;
}

test "the table matches glass.metal's layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf([4]f32));
    try std.testing.expectEqual(@as(usize, (31 * 73 + 91) * 16), bytes.len);
    // The fold edges follow the sheets; the long edges' band is open, the caps' closed.
    const caps = table.table[table.fold_base];
    const long = table.table[table.fold_base + 90];
    try std.testing.expectEqual(caps[0], caps[1]);
    try std.testing.expect(long[0] < long[1]);
}
