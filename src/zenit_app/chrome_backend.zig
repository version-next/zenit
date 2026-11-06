//! Native-only bridge; UI uses the shared contract through Cx's window service.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
pub const chrome = @import("system_sdk").window_chrome;
const Window = platform.Window;
pub const HitFn = *const fn (?*anyopaque, f32, f32) callconv(.c) c_int;
extern fn macos_chrome_configure(*anyopaque, c_int, c_int, f32) c_int;
extern fn macos_chrome_hit(*anyopaque, ?HitFn, ?*anyopaque) void;
extern fn macos_chrome_state(*anyopaque, *chrome.NativeState) void;
extern fn macos_chrome_action(*anyopaque, c_int, c_int) c_int;
extern fn macos_fullscreen_header_configure(*anyopaque, c_int, f32) c_int;
extern fn macos_fullscreen_header_layout(*anyopaque, c_int, *f32, *f32) void;
extern fn macos_fullscreen_header_take_frame_request(*anyopaque) c_int;
pub fn takeHeaderFrameRequest(win: *Window) bool {
    if (comptime builtin.os.tag != .macos) return false;
    return macos_fullscreen_header_take_frame_request(handle(win)) != 0;
}
extern fn macos_fullscreen_header_post_pointer(*anyopaque, f32, f32, c_int) c_int;
extern fn macos_fullscreen_header_background(*anyopaque, u8, u8, u8, u8) void;
extern fn macos_fullscreen_header_test_hover(*anyopaque, c_int) c_int;
extern fn macos_fullscreen_header_test_ready(*anyopaque) c_int;
pub fn headerReadyForTesting(win: *Window) bool {
    if (comptime builtin.os.tag != .macos) return false;
    return macos_fullscreen_header_test_ready(handle(win)) == 1;
}
pub fn postHeaderSystemHover(win: *Window, edge: bool) !void {
    if (comptime builtin.os.tag != .macos) return error.UnsupportedNativeHeaderPointer;
    if (macos_fullscreen_header_test_hover(handle(win), @intFromBool(edge)) != 1) return error.NativePointerUnavailable;
}
pub fn headerBackground(win: *Window, color: anytype) void {
    if (comptime builtin.os.tag == .macos) macos_fullscreen_header_background(handle(win), color.r, color.g, color.b, color.a);
}
pub fn postHeaderPointer(win: *Window, x: f32, y: f32, right: bool) !void {
    if (comptime builtin.os.tag != .macos) return error.UnsupportedNativeHeaderPointer;
    if (macos_fullscreen_header_post_pointer(handle(win), x, y, @intFromBool(right)) != 1) return error.HeaderNotVisible;
}
pub fn configureHeader(win: *Window, initial: chrome.State, policy: chrome.HeaderVisibility, height: f32) !void {
    if (policy == .hidden) return;
    if (comptime builtin.os.tag != .macos) return error.UnsupportedFullscreenHeaderHost;
    if (initial.effective_mode != .custom or initial.controls_owner != .native) return error.UnsupportedFullscreenHeaderHost;
    if (macos_fullscreen_header_configure(handle(win), @intCast(@backingInt(policy)), height) != 1) return error.UnsupportedFullscreenHeaderHost;
}
pub fn headerLayout(win: *Window, locked: bool) [2]f32 {
    var result: [2]f32 = .{ 0, 0 };
    if (comptime builtin.os.tag == .macos) macos_fullscreen_header_layout(handle(win), @intFromBool(locked), &result[0], &result[1]);
    return result;
}
extern fn zenit_win_chrome_configure(*anyopaque, c_int, c_int, f32) c_int;
extern fn zenit_win_chrome_hit(*anyopaque, ?HitFn, ?*anyopaque) void;
extern fn zenit_win_chrome_state(*anyopaque, *chrome.NativeState) void;
extern fn zenit_win_chrome_action(*anyopaque, c_int, c_int) c_int;
extern fn zenit_wayland_chrome_configure(*anyopaque, c_int) c_int;
extern fn zenit_wayland_chrome_hit(*anyopaque, ?HitFn, ?*anyopaque) void;
extern fn zenit_wayland_chrome_state(*anyopaque, *chrome.NativeState) void;
extern fn zenit_wayland_chrome_action(*anyopaque, c_int, c_int) c_int;
extern fn macos_chrome_minimum(*anyopaque, u32, u32) c_int;
extern fn macos_chrome_system_titlebar(*anyopaque) c_int;
/// Explicit `.native` chrome on macOS: give the window a real system titlebar.
/// Legacy windows (no `chrome` config) keep the transparent full-size titlebar.
pub fn useSystemTitlebar(win: *Window) !void {
    if (comptime builtin.os.tag != .macos) return;
    if (macos_chrome_system_titlebar(handle(win)) != 1) return error.NativeChromeConfigurationFailed;
}
extern fn zenit_win_chrome_minimum(*anyopaque, u32, u32) c_int;
extern fn zenit_wayland_chrome_minimum(*anyopaque, u32, u32) c_int;
extern fn macos_chrome_maximizable(*anyopaque, c_int) c_int;
pub fn setMaximizable(win: *Window, value: bool) !void {
    if (comptime builtin.os.tag != .macos) {
        // Loud reject over a silent capability lie; same contract as
        // configureHeader's visible policies on unsupported backends.
        if (!value) return error.UnsupportedWindowCapability;
        return;
    }
    if (macos_chrome_maximizable(handle(win), @intFromBool(value)) != 1) return error.NativeChromeConfigurationFailed;
}
extern fn macos_chrome_restorable(*anyopaque, c_int) c_int;
pub fn setRestorable(win: *Window, value: bool) !void {
    // Only macOS runs a window restore pass; "never restore" is trivially
    // true on the other backends, so the flag is accepted there.
    if (comptime builtin.os.tag != .macos) return;
    if (macos_chrome_restorable(handle(win), @intFromBool(value)) != 1) return error.NativeChromeConfigurationFailed;
}
pub fn setMinimumSize(win: *Window, width: u32, height: u32) !void {
    if (width > 16384 or height > 16384) return error.InvalidWindowMinimumSize;
    if (width == 0 and height == 0) return;
    const result = switch (builtin.os.tag) {
        .macos => macos_chrome_minimum(handle(win), width, height),
        .windows => zenit_win_chrome_minimum(handle(win), width, height),
        .linux => zenit_wayland_chrome_minimum(handle(win), width, height),
        else => 0,
    };
    if (result != 1) return error.UnsupportedMinimumWindowSize;
}
fn handle(win: *Window) *anyopaque {
    return switch (builtin.os.tag) {
        .macos => win.window_ptr,
        .windows => win.getNativeSurfaceHandle(),
        .linux => @ptrCast(win.native.handle.?),
        else => unreachable,
    };
}
pub fn configure(win: *Window, config: chrome.Config, height: f32) !chrome.State {
    if (config == .custom and (!std.math.isFinite(height) or height <= 0)) return error.InvalidTitlebarHeight;
    const mode: c_int = @intCast(@backingInt(std.meta.activeTag(config)));
    const automatic: c_int = if (config == .custom and config.custom.controls == .automatic) 1 else 0;
    var supported = true;
    var reason: chrome.FallbackReason = .none;
    switch (builtin.os.tag) {
        .macos => if (macos_chrome_configure(handle(win), mode, automatic, height) != 1) return error.NativeChromeConfigurationFailed,
        .windows => {
            const result = zenit_win_chrome_configure(handle(win), mode, automatic, height);
            if (result == 0) return error.NativeChromeConfigurationFailed;
            supported = result != 2;
            reason = if (result == 2) .high_contrast else .none;
        },
        .linux => {
            const result = zenit_wayland_chrome_configure(handle(win), mode);
            supported = result == 0;
            reason = if (result == 2) .decoration_unverified else if (result != 0) .missing_native_api else .none;
        },
        else => {
            supported = false;
            reason = .unsupported_backend;
        },
    }
    return chrome.resolve(config, supported, reason, builtin.os.tag == .macos or builtin.os.tag == .windows);
}
pub fn setHitCallback(win: *Window, callback: ?HitFn, context: ?*anyopaque) void {
    // The native window can already be gone (Win32 destroys owned windows with
    // their owner); there is no callback left to clear then.
    if (builtin.os.tag == .windows and callback == null and win.closeCompleted()) return;
    switch (builtin.os.tag) {
        .macos => macos_chrome_hit(handle(win), callback, context),
        .windows => zenit_win_chrome_hit(handle(win), callback, context),
        .linux => zenit_wayland_chrome_hit(handle(win), callback, context),
        else => {},
    }
}
pub fn state(win: *Window, initial: chrome.State) chrome.State {
    var native: chrome.NativeState = .{};
    switch (builtin.os.tag) {
        .macos => macos_chrome_state(handle(win), &native),
        .windows => zenit_win_chrome_state(handle(win), &native),
        .linux => zenit_wayland_chrome_state(handle(win), &native),
        else => {},
    }
    var result = initial;
    const size = win.getSize();
    result.width = @floatFromInt(size[0]);
    result.height = @floatFromInt(size[1]);
    result.scale = win.getScaleFactor();
    result.capabilities = @bitCast(@as(u8, @intCast(native.capabilities & 127)));
    result.maximized = native.flags & 1 != 0;
    result.fullscreen = native.flags & 2 != 0;
    result.fullscreen_transitioning = native.flags & 8 != 0;
    result.active = native.flags & 4 != 0;
    result.tiled = native.flags & 32 != 0;
    result.high_contrast = native.flags & 64 != 0;
    result.fullscreen_header_hosted = native.flags & 128 != 0;
    result.fullscreen_header_visible = native.flags & 256 != 0;
    result.fullscreen_header_presented = native.flags & 512 != 0;
    result.appearance = std.enums.fromInt(chrome.Appearance, native.appearance) orelse .generic;
    for (0..3) |i| {
        result.button_layout.left[i] = std.enums.fromInt(chrome.Control, native.button_layout[i]) orelse .none;
        result.button_layout.right[i] = std.enums.fromInt(chrome.Control, native.button_layout[i + 3]) orelse .none;
    }
    result.caption_hover = std.enums.fromInt(chrome.Control, native.caption_hover) orelse .none;
    result.caption_pressed = std.enums.fromInt(chrome.Control, native.caption_pressed) orelse .none;
    result.corner_radius = native.corner_radius;
    result.state_generation = native.state_generation;
    result.wm_capabilities_known = native.flags & 16 != 0;
    result.controls_geometry_known = native.controls_count >= 0;
    result.native_controls_count = @intCast(@max(0, @min(3, native.controls_count)));
    result.native_controls = native.controls;
    if (comptime builtin.os.tag == .linux) {
        if (initial.effective_mode != .native and !result.capabilities.custom) {
            result.effective_mode = .native;
            result.controls_owner = .native;
            result.fallback_reason = .decoration_unverified;
        }
    }
    return result;
}
pub fn perform(win: *Window, action: chrome.Action) !void {
    const command: c_int, const value: c_int = switch (action) {
        .close => .{ 0, 0 },
        .minimize => .{ 1, 0 },
        .maximize => |v| .{ 2, @intFromBool(v) },
        .fullscreen => |v| .{ 3, @intFromBool(v) },
        .toggle_maximize => return error.UnresolvedWindowAction,
    };
    const accepted = switch (builtin.os.tag) {
        .macos => macos_chrome_action(handle(win), command, value),
        .windows => zenit_win_chrome_action(handle(win), command, value),
        .linux => zenit_wayland_chrome_action(handle(win), command, value),
        else => 0,
    };
    if (accepted != 1) return error.UnsupportedWindowAction;
}
