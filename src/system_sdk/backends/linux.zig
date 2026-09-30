const std = @import("std");
const Allocator = std.mem.Allocator;

const backend_mod = @import("../vtable.zig");
const capabilities_mod = @import("../capabilities.zig");
const events_mod = @import("../events.zig");
const WindowId = @import("../events.zig").WindowId;
const SystemSdk = @import("../api.zig").SystemSdk;
const SdkError = @import("../errors.zig").SdkError;

const CAPS = capabilities_mod.Capabilities{
    .request_redraw = true,
    .multi_window = false,
};

/// Linux backend (minimal).
///
/// 当前实现提供:
/// - 事件泵 `pump`
/// - window resize 事件
/// - mouse move 事件
/// - quit 事件
/// - requestRedraw
///
/// 未来可扩展:
/// - X11/Wayland 原生事件
/// - 剪贴板
/// - 文件对话框
pub const LinuxBackend = struct {
    pub fn initSystemSdk(allocator: Allocator, window: anytype, window_id: WindowId) !SystemSdk {
        const WindowType = @TypeOf(window);

        const Impl = struct {
            const Context = struct {
                window: WindowType,
                window_id: WindowId,
                last_width: u32,
                last_height: u32,
                last_scale: f32,
                has_last_mouse: bool = false,
                last_mouse_x: f32,
                last_mouse_y: f32,
            };

            fn deinitImpl(ctx: *anyopaque, allocator_: Allocator) void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                allocator_.destroy(self);
            }

            fn requestRedrawImpl(ctx: *anyopaque) SdkError!void {
                const self: *Context = @ptrCast(@alignCast(ctx));
                self.window.requestRedraw();
            }

            fn pumpEventsImpl(ctx: *anyopaque, queue: *events_mod.EventQueue, timeout_ms: u32) SdkError!backend_mod.PumpResult {
                _ = timeout_ms;
                const self: *Context = @ptrCast(@alignCast(ctx));

                const should_continue = self.window.pollEvents();

                const size = self.window.getSize();
                const scale = self.window.getScaleFactor();
                if (size[0] != self.last_width or size[1] != self.last_height or scale != self.last_scale) {
                    try pushEvent(queue, .{
                        .window_resized = .{
                            .window_id = self.window_id,
                            .width = size[0],
                            .height = size[1],
                            .scale_factor = scale,
                        },
                    });
                    self.last_width = size[0];
                    self.last_height = size[1];
                    self.last_scale = scale;
                }

                const pos = self.window.getMousePosition();
                const mx = pos[0];
                const my = pos[1];
                if (!self.has_last_mouse or mx != self.last_mouse_x or my != self.last_mouse_y) {
                    try pushEvent(queue, .{
                        .mouse_move = .{
                            .window_id = self.window_id,
                            .x = mx,
                            .y = my,
                            .dx = if (self.has_last_mouse) mx - self.last_mouse_x else 0,
                            .dy = if (self.has_last_mouse) my - self.last_mouse_y else 0,
                        },
                    });
                    self.last_mouse_x = mx;
                    self.last_mouse_y = my;
                    self.has_last_mouse = true;
                }

                if (!should_continue) {
                    try pushEvent(queue, .{ .quit = {} });
                }

                return .{
                    .should_continue = should_continue,
                };
            }

            pub const VTABLE = backend_mod.BackendVTable{
                .name = "linux-minimal",
                .deinit = deinitImpl,
                .pump_events = pumpEventsImpl,
                .request_redraw = requestRedrawImpl,
            };
        };

        const size = window.getSize();
        const scale = window.getScaleFactor();
        const mouse = window.getMousePosition();

        const ctx = try allocator.create(Impl.Context);
        ctx.* = .{
            .window = window,
            .window_id = window_id,
            .last_width = size[0],
            .last_height = size[1],
            .last_scale = scale,
            .last_mouse_x = mouse[0],
            .last_mouse_y = mouse[1],
        };

        return SystemSdk.init(allocator, ctx, &Impl.VTABLE, CAPS);
    }
};

fn pushEvent(queue: *events_mod.EventQueue, event: events_mod.Event) SdkError!void {
    queue.push(event) catch return SdkError.OutOfMemory;
}

const MockWindow = struct {
    frame: u32 = 0,
    redraw_requests: u32 = 0,

    fn pollEvents(self: *MockWindow) bool {
        self.frame += 1;
        return self.frame < 3;
    }

    fn getSize(self: *MockWindow) [2]u32 {
        return if (self.frame >= 2) .{ 900, 700 } else .{ 800, 600 };
    }

    fn getScaleFactor(_: *MockWindow) f32 {
        return 1.0;
    }

    fn getMousePosition(self: *MockWindow) [2]f32 {
        return switch (self.frame) {
            0 => .{ 10, 10 },
            1 => .{ 10, 10 },
            else => .{ 12, 15 },
        };
    }

    fn requestRedraw(self: *MockWindow) void {
        self.redraw_requests += 1;
    }
};

test "LinuxBackend minimal: pump events + redraw" {
    var win = MockWindow{};
    var sdk = try LinuxBackend.initSystemSdk(std.testing.allocator, &win, 9);
    defer sdk.deinit();

    try sdk.requestRedraw();
    try std.testing.expectEqual(@as(u32, 1), win.redraw_requests);

    const p1 = try sdk.pump(0);
    try std.testing.expect(p1.should_continue);
    try std.testing.expectEqual(@as(usize, 0), sdk.events().len);

    const p2 = try sdk.pump(0);
    try std.testing.expect(p2.should_continue);
    try std.testing.expectEqual(@as(usize, 2), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .window_resized);
    try std.testing.expect(sdk.events()[1] == .mouse_move);

    const p3 = try sdk.pump(0);
    try std.testing.expect(!p3.should_continue);
    try std.testing.expectEqual(@as(usize, 1), sdk.events().len);
    try std.testing.expect(sdk.events()[0] == .quit);
}
