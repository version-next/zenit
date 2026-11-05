//! Minimal single-threaded I/O for a freestanding wasm host. All non-clock
//! operations use std.Io.failing. Native diagnostic output is explicitly
//! unsupported, rather than silently dropping messages.
const std = @import("std");
extern "zenit" fn now_ns() u64;

fn now(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    if (clock != .awake) @panic("unsupported freestanding clock");
    return .{ .nanoseconds = now_ns() };
}
fn resolution(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    if (clock != .awake) return error.ClockUnavailable;
    return .{ .nanoseconds = 1 };
}
fn unsupportedCancel(_: ?*anyopaque, _: std.Io.CancelProtection) std.Io.CancelProtection {
    @panic("freestanding cancellation/diagnostic I/O is unsupported");
}
fn unsupportedWait(_: ?*anyopaque, _: *const u32, _: u32) void {
    @panic("freestanding I/O cannot wait for another thread");
}
const vtable: std.Io.VTable = blk: {
    var table = std.Io.failing.vtable.*;
    table.swapCancelProtection = unsupportedCancel;
    table.futexWaitUncancelable = unsupportedWait;
    table.now = now;
    table.clockResolution = resolution;
    break :blk table;
};
pub const io: std.Io = .{ .userdata = null, .vtable = &vtable };
