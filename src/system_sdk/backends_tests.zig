const macos = @import("backends/macos.zig");

test {
    _ = macos;
}

// ── cursor vtable 的可选 set_custom 契约 ────────────────────────────────
// set_custom 是可选字段：缺失时 customCursorSupported()==false，
// setCustomCursor 返回 NotSupported（UI 层据此降级到固定形状）。

const std = @import("std");
const api = @import("api.zig");
const vtable_mod = @import("vtable.zig");
const events_mod = @import("events.zig");
const errors_mod = @import("errors.zig");

const CursorOnlyBackend = struct {
    shape_calls: u32 = 0,

    fn deinitFn(_: *anyopaque, _: std.mem.Allocator) void {}

    fn pump(_: *anyopaque, _: *events_mod.EventQueue, _: u32) errors_mod.SdkError!vtable_mod.PumpResult {
        return .{};
    }

    fn setShape(ctx_: *anyopaque, _: events_mod.WindowId, _: u8) errors_mod.SdkError!void {
        const self: *@This() = @ptrCast(@alignCast(ctx_));
        self.shape_calls += 1;
    }
};

test "SystemSdk: custom cursor degrades when vtable lacks set_custom" {
    var backend = CursorOnlyBackend{};
    const vt = vtable_mod.BackendVTable{
        .name = "cursor-only-mock",
        .deinit = CursorOnlyBackend.deinitFn,
        .pump_events = CursorOnlyBackend.pump,
        .cursor = .{ .set_shape = CursorOnlyBackend.setShape },
    };
    var sdk = api.SystemSdk.init(std.testing.allocator, &backend, &vt, .{ .cursor = true });
    defer sdk.deinit();

    try std.testing.expect(!sdk.customCursorSupported());
    const pixels = [_]u8{0} ** 16;
    try std.testing.expectError(
        error.NotSupported,
        sdk.setCustomCursor(1, .{ .rgba = &pixels, .width = 2, .height = 2, .scale = 2, .hot_x = 0, .hot_y = 0, .key = 7 }),
    );
    // 固定形状路径不受影响
    try sdk.setCursorShape(1, 4);
    try std.testing.expectEqual(@as(u32, 1), backend.shape_calls);
}
