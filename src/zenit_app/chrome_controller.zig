const std = @import("std");
const native = @import("chrome_backend.zig");
const chrome = native.chrome;
pub const Controller = struct {
    initial: chrome.State,
    pending_maximized: ?bool = null,
    pending_maximized_generation: u32 = 0,
    desired_fullscreen: ?bool = null,
    inflight_fullscreen: ?bool = null,
    inflight_fullscreen_generation: u32 = 0,
    checking_close: bool = false,
    /// Corner radius currently applied to the root node (client-shaped windows).
    applied_corner_radius: f32 = 0,
    /// Root (element id, generation-tagged) the radius was applied to; a remount gets the shape again.
    applied_corner_root: ?u32 = null,
    /// Clear color before the corners were made transparent, restored when the shape ends.
    saved_clear: ?@import("renderer.zig").ClearColor = null,
};
pub fn chromeState(self: anytype) chrome.State {
    return native.state(&self.win, self.chrome.initial);
}
pub fn windowCapabilities(self: anytype) chrome.Capabilities {
    return chromeState(self).capabilities;
}
pub fn syncChrome(self: anytype) void {
    syncChromeWithBackend(self, native);
}

/// Internal backend seam for exercising chrome sync without a native window.
pub fn syncChromeWithBackend(self: anytype, comptime backend: type) void {
    if (self.cx.window_header_node) |header| backend.headerBackground(&self.win, header.getBackground());
    var header_lock = self.cx.window_header_reveal_leases > 0 or self.cx.windowHeaderOwns(self.cx.focused_node) or self.cx.windowHeaderOwns(self.cx.pressed_node);
    var header_overlay_open = false;
    for (self.cx.overlay_stack.layers.items) |slot| {
        if (slot) |layer| {
            // Generation-checked: the trigger may have been freed while its layer stays stacked.
            if (!layer.suspended and self.cx.windowHeaderOwns(self.cx.overlay_stack.resolveTrigger(&layer))) {
                header_lock = true;
                if (layer.state != .exiting) header_overlay_open = true;
            }
        }
    }
    // AppKit moves the titlebar accessory over the body when the menu bar
    // drops. Keep content layout fixed. An open header overlay needs a frame
    // to reposition its anchor when the offset changes, even with no input;
    // without one, native reveal/retraction needs no extra UI frame.
    const offset = backend.headerLayout(&self.win, header_lock);
    // Native prewarm/first-paint requests survive renderer idle gating. Ordinary
    // menu reveal still adds no frame when there is no header overlay.
    if (comptime @hasDecl(backend, "takeHeaderFrameRequest")) {
        if (backend.takeHeaderFrameRequest(&self.win)) self.cx.needs_redraw = true;
    }
    if (header_overlay_open and !std.meta.eql(self.cx.window_header_offset, offset)) self.cx.needs_redraw = true;
    self.cx.window_header_offset = offset;
    const state = backend.state(&self.win, self.chrome.initial);
    if (self.chrome.pending_maximized) |desired| {
        if (state.maximized == desired or state.state_generation != self.chrome.pending_maximized_generation) self.chrome.pending_maximized = null;
    }
    if (self.chrome.inflight_fullscreen) |inflight| {
        if (!state.fullscreen_transitioning and (state.fullscreen == inflight or state.state_generation != self.chrome.inflight_fullscreen_generation)) {
            self.chrome.inflight_fullscreen = null;
            // A refused request completes too; only a newer desired value is retried.
            if (self.chrome.desired_fullscreen == inflight) self.chrome.desired_fullscreen = null;
        }
    }
    if (self.chrome.inflight_fullscreen == null) {
        if (self.chrome.desired_fullscreen) |desired| {
            if (state.fullscreen != desired) {
                if (backend.perform(&self.win, .{ .fullscreen = desired })) |_| {
                    self.chrome.inflight_fullscreen = desired;
                    self.chrome.inflight_fullscreen_generation = state.state_generation;
                } else |_| {
                    self.chrome.desired_fullscreen = null;
                }
            } else self.chrome.desired_fullscreen = null;
        }
    }
    // Client-side decorated windows paint their own corners: clip the root to the
    // platform radius and clear to transparent so the corners show the desktop.
    const root_id: ?u32 = if (self.cx.root) |root| root.element_id_raw else null;
    if (state.corner_radius != self.chrome.applied_corner_radius or (state.corner_radius > 0 and root_id != self.chrome.applied_corner_root)) {
        apply: {
            const root = self.cx.root orelse break :apply;
            const r = state.corner_radius;
            // OOM leaves the root as it was and the radius unrecorded: the next sync retries
            root.setStyleInlineFallible(self.cx.allocator, .{ .corner_radii = .{ .each = .{ r, r, r, r } }, .overflow_hidden = r > 0 }) catch {
                self.cx.needs_redraw = true;
                break :apply;
            };
            // The Windows painter composes through DWM and has no GPU clear color.
            // Wayland composites premultiplied: a transparent corner must clear to
            // (0,0,0,0), not to the opaque background color with alpha 0.
            if (comptime @hasField(@TypeOf(self.renderer.*), "config")) {
                if (r > 0) {
                    if (self.chrome.saved_clear == null) self.chrome.saved_clear = self.renderer.config.clear_color;
                    self.renderer.config.clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
                } else if (self.chrome.saved_clear) |saved| {
                    self.renderer.config.clear_color = saved;
                    self.chrome.saved_clear = null;
                }
            }
            self.chrome.applied_corner_radius = r;
            self.chrome.applied_corner_root = root_id;
            self.cx.needs_redraw = true;
        }
    }
    if (self.cx.window_chrome_signal) |signal| {
        if (!std.meta.eql(signal.peek(), state)) {
            signal.set(state);
            self.cx.needs_redraw = true;
        }
    }
}
pub fn requestClose(self: anytype) !void {
    if (self.destroying or self.should_quit or self.chrome.checking_close) return;
    self.chrome.checking_close = true;
    defer self.chrome.checking_close = false;
    self.win.resetShouldClose();
    if (self.config.on_close_request) |callback| {
        if (!callback(self)) return;
    }
    // Retired by the application loop, never inside the UI/native callback.
    self.should_quit = true;
    self.cx.needs_redraw = true;
}
pub fn minimize(self: anytype) !void {
    if (!windowCapabilities(self).minimize) return error.UnsupportedWindowAction;
    try native.perform(&self.win, .minimize);
}
pub fn setMaximized(self: anytype, value: bool) !void {
    if (!windowCapabilities(self).maximize) return error.UnsupportedWindowAction;
    const state = chromeState(self);
    try native.perform(&self.win, .{ .maximize = value });
    self.chrome.pending_maximized = value;
    self.chrome.pending_maximized_generation = state.state_generation;
    self.cx.needs_redraw = true;
}
pub fn toggleMaximize(self: anytype) !void {
    const current = self.chrome.pending_maximized orelse chromeState(self).maximized;
    try setMaximized(self, !current);
}
pub fn setFullscreen(self: anytype, value: bool) !void {
    const state = chromeState(self);
    if (!state.capabilities.fullscreen) return error.UnsupportedWindowAction;
    if (!state.fullscreen_transitioning and (state.fullscreen != value or self.chrome.inflight_fullscreen != null)) {
        try native.perform(&self.win, .{ .fullscreen = value });
        self.chrome.inflight_fullscreen = value;
        self.chrome.inflight_fullscreen_generation = state.state_generation;
    }
    self.chrome.desired_fullscreen = value;
    self.cx.needs_redraw = true;
}
pub fn performWindowAction(self: anytype, action: chrome.Action) !void {
    switch (action) {
        .close => try requestClose(self),
        .minimize => try minimize(self),
        .maximize => |value| try setMaximized(self, value),
        .toggle_maximize => try toggleMaximize(self),
        .fullscreen => |value| try setFullscreen(self, value),
    }
}
