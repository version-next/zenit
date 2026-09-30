const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const WindowId = @import("../events.zig").WindowId;
const SystemSdk = @import("../api.zig").SystemSdk;
const SdkError = @import("../errors.zig").SdkError;

pub const macos = if (builtin.target.os.tag == .macos)
    @import("macos.zig")
else
    struct {};
pub const linux = @import("linux.zig");
pub const windows = @import("windows.zig");

/// Native backend selector.
///
/// 统一入口:
/// - 调用方只依赖 `backends.initSystemSdk`
/// - 具体平台实现者在此处分发
pub fn initSystemSdk(allocator: Allocator, window: anytype, window_id: WindowId) !SystemSdk {
    return switch (comptime builtin.target.os.tag) {
        .macos => macos.MacOSBackend.initSystemSdk(allocator, window, window_id),
        .linux => linux.LinuxBackend.initSystemSdk(allocator, window, window_id),
        .windows => windows.WindowsBackend.initSystemSdk(allocator, window, window_id),
        else => SdkError.NotSupported,
    };
}
