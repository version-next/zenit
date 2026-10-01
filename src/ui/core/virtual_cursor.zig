//! Draw-only cursor used by the automation harness.
//!
//! The native cursor is not part of the app render target, so screenshots and
//! future frame capture cannot see it.  This overlay is appended after normal
//! UI and inspector paint.  It never participates in layout or hit testing.

const std = @import("std");
const icon_ir = @import("icon_ir");
const icons = @import("zenit_system_icons");
const paint = @import("paint_table.zig");
const types = @import("types.zig");

const CursorShape = types.CursorShape;
const Asset = icon_ir.Asset;
const RGBA = paint.RGBA;

const ink: RGBA = .{ .r = 19, .g = 23, .b = 31, .a = 255 };
const halo: RGBA = .{ .r = 255, .g = 255, .b = 255, .a = 250 };
const active: RGBA = .{ .r = 37, .g = 132, .b = 255, .a = 235 };
const click_pulse_ms: f64 = 180;

pub const VirtualCursor = struct {
    visible: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    pressed: bool = false,
    shape: CursorShape = .default,
    click_pulse_start_ms: f64 = 0,
    click_pulse_end_ms: f64 = 0,

    /// Update the cursor after an automation event. `pressed=null` preserves
    /// the current button state (mouse move, scroll, magnify).
    pub fn update(
        self: *VirtualCursor,
        x: f32,
        y: f32,
        pressed: ?bool,
        shape: CursorShape,
        now_ms: f64,
    ) bool {
        const old = self.*;
        const next_pressed = pressed orelse self.pressed;
        if (self.pressed and !next_pressed) {
            self.click_pulse_start_ms = now_ms;
            self.click_pulse_end_ms = now_ms + click_pulse_ms;
        } else if (next_pressed) {
            self.click_pulse_start_ms = 0;
            self.click_pulse_end_ms = 0;
        }
        self.visible = true;
        self.x = x;
        self.y = y;
        self.pressed = next_pressed;
        self.shape = if (shape == .inherit) .default else shape;
        return !std.meta.eql(old, self.*);
    }

    pub fn setShape(self: *VirtualCursor, shape: CursorShape) bool {
        const resolved = if (shape == .inherit) CursorShape.default else shape;
        if (self.shape == resolved) return false;
        self.shape = resolved;
        return true;
    }

    /// Returns true while the cursor needs another animation frame.
    pub fn renderOverlay(self: *VirtualCursor, cx: anytype, now_ms: f64) bool {
        if (!self.visible) return false;
        if (self.shape == .none) return false;

        var wants_animation = false;
        if (self.pressed) {
            appendRing(cx, self.x, self.y, 9, active, 2.5);
        } else if (self.click_pulse_end_ms > now_ms) {
            const elapsed = @max(0, now_ms - self.click_pulse_start_ms);
            const t: f32 = @floatCast(std.math.clamp(elapsed / click_pulse_ms, 0, 1));
            const alpha_f = @round(220.0 * (1.0 - t));
            const pulse = RGBA{ .r = active.r, .g = active.g, .b = active.b, .a = @intFromFloat(alpha_f) };
            appendRing(cx, self.x, self.y, 8 + 10 * t, pulse, 2.5);
            wants_animation = true;
        } else {
            self.click_pulse_start_ms = 0;
            self.click_pulse_end_ms = 0;
        }

        wants_animation = renderShape(cx, self.*, now_ms) or wants_animation;
        return wants_animation;
    }
};

fn renderShape(cx: anytype, cursor: VirtualCursor, now_ms: f64) bool {
    const x = cursor.x;
    const y = cursor.y;
    switch (cursor.shape) {
        // .custom 的真实位图（NSCursor 等）在系统合成层，自动化虚拟指针
        // 这里画不出位图内容，用默认箭头兜底；e2e 断言走状态探针而非视觉。
        .inherit, .default, .custom => {
            if (cursor.pressed) {
                appendIconWithHalo(cx, icons.cursor_click, x - 9, y - 9, 24, 0);
            } else {
                // cursor-01's vector tip starts at (3.4, 3.4).
                appendIconWithHalo(cx, icons.cursor_default, x - 3.4, y - 3.4, 24, 0);
            }
        },
        .pointer => {
            if (cursor.pressed) {
                appendIconWithHalo(cx, icons.cursor_click, x - 9, y - 9, 24, 0);
            } else {
                // A raised index finger, not the open palm `hand` that `grab`
                // uses, the two shapes must stay visually distinct.  The
                // fingertip sits at (12, 2) in the 24px viewBox and is the
                // hotspot.
                appendIconWithHalo(cx, icons.pointer, x - 12, y - 2, 24, 0);
            }
        },
        .text => appendIBeam(cx, x, y),
        .crosshair => appendCrosshair(cx, x, y),
        .move => appendIconWithHalo(cx, icons.move, x - 12, y - 12, 24, 0),
        .not_allowed => appendIconWithHalo(cx, icons.not_allowed, x - 12, y - 12, 24, 0),
        .grab, .grabbing => appendIconWithHalo(cx, icons.grab, x - 12, y - 12 + @as(f32, if (cursor.pressed) 1 else 0), 24, 0),
        .ew_resize, .col_resize => appendIconWithHalo(cx, icons.resize_horizontal, x - 12, y - 12, 24, 0),
        .ns_resize, .row_resize => appendIconWithHalo(cx, icons.resize_vertical, x - 12, y - 12, 24, 0),
        .nwse_resize => appendIconWithHalo(cx, icons.resize_diagonal, x - 12, y - 12, 24, std.math.pi / 2.0),
        .nesw_resize => appendIconWithHalo(cx, icons.resize_diagonal, x - 12, y - 12, 24, 0),
        .wait => appendIconWithHalo(cx, icons.wait, x - 12, y - 12, 24, 0),
        .progress => {
            const rotation: f32 = @floatCast(@mod(now_ms, 700) / 700.0 * std.math.tau);
            appendIconWithHalo(cx, icons.progress, x - 12, y - 12, 24, rotation);
            return true;
        },
        .help => {
            appendIconWithHalo(cx, icons.cursor_default, x - 3.4, y - 3.4, 24, 0);
            appendIconWithHalo(cx, icons.help, x + 8, y + 8, 13, 0);
        },
        .none, .uncontrolled => {},
    }
    return false;
}

fn appendIBeam(cx: anytype, x: f32, y: f32) void {
    // White geometry first gives the cursor a recording-safe halo on both
    // light and dark content.
    appendRect(cx, x - 2.5, y - 12, 5, 24, halo, 2.5, 0);
    appendRect(cx, x - 6, y - 12, 12, 4, halo, 2, 0);
    appendRect(cx, x - 6, y + 8, 12, 4, halo, 2, 0);
    appendRect(cx, x - 1, y - 11, 2, 22, ink, 1, 0);
    appendRect(cx, x - 5, y - 11, 10, 2, ink, 1, 0);
    appendRect(cx, x - 5, y + 9, 10, 2, ink, 1, 0);
}

fn appendCrosshair(cx: anytype, x: f32, y: f32) void {
    appendRect(cx, x - 12, y - 2.5, 24, 5, halo, 2.5, 0);
    appendRect(cx, x - 2.5, y - 12, 5, 24, halo, 2.5, 0);
    appendRect(cx, x - 11, y - 1, 22, 2, ink, 1, 0);
    appendRect(cx, x - 1, y - 11, 2, 22, ink, 1, 0);
}

fn appendRing(cx: anytype, x: f32, y: f32, radius: f32, color: RGBA, width: f32) void {
    appendRect(cx, x - radius, y - radius, radius * 2, radius * 2, color, radius, width);
}

fn appendIconWithHalo(cx: anytype, asset: Asset, x: f32, y: f32, size: f32, rotation: f32) void {
    const offsets = [_][2]f32{
        .{ -1.25, 0 },
        .{ 1.25, 0 },
        .{ 0, -1.25 },
        .{ 0, 1.25 },
    };
    for (offsets) |offset| {
        appendIcon(cx, asset, x + offset[0], y + offset[1], size, halo, rotation);
    }
    appendIcon(cx, asset, x, y, size, ink, rotation);
}

fn appendIcon(cx: anytype, asset: Asset, x: f32, y: f32, size: f32, tint: RGBA, rotation: f32) void {
    if (asset.reps.len == 0) return;
    const rep = &asset.reps[0];
    _ = cx.lowering.main_paint.append(cx.allocator, .{
        .kind = .image,
        .local_bounds = .{ .min_x = x, .min_y = y, .max_x = x + size, .max_y = y + size },
        .resource_handle = asset.icon_id orelse 0,
        .geom = .{ .x = x, .y = y, .w = size, .h = size },
        .image_opacity = 1,
        .icon_rep_ptr = rep,
        .icon_tint = tint,
        .icon_rep_size = rep.size,
        .rotate = rotation,
    }) catch {};
}

fn appendRect(
    cx: anytype,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: RGBA,
    radius: f32,
    stroke_width: f32,
) void {
    _ = cx.lowering.main_paint.append(cx.allocator, .{
        .kind = .rect,
        .local_bounds = .{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h },
        .geom = .{ .x = x, .y = y, .w = w, .h = h },
        .color = color,
        .radii = .{ .tl = radius, .tr = radius, .br = radius, .bl = radius },
        .stroke_width = stroke_width,
    }) catch {};
}

test "virtual cursor is draw-only until automation makes it visible" {
    const FakeCx = struct {
        allocator: std.mem.Allocator,
        lowering: struct {
            main_paint: std.ArrayListUnmanaged(paint.DisplayItem) = .{},
        } = .{},
    };
    var cx = FakeCx{ .allocator = std.testing.allocator };
    defer cx.lowering.main_paint.deinit(cx.allocator);
    var cursor = VirtualCursor{};

    try std.testing.expect(!cursor.renderOverlay(&cx, 0));
    try std.testing.expectEqual(@as(usize, 0), cx.lowering.main_paint.items.len);
}

test "pointer and grab draw distinct art" {
    // Regression: both shapes used to resolve to `icons.hand` (an open palm),
    // so hovering a clickable control looked like a pending drag.
    const FakeCx = struct {
        allocator: std.mem.Allocator,
        lowering: struct {
            main_paint: std.ArrayListUnmanaged(paint.DisplayItem) = .{},
        } = .{},

        fn iconIdFor(self: *@This(), shape: CursorShape) !u64 {
            self.lowering.main_paint.clearRetainingCapacity();
            var cursor = VirtualCursor{};
            _ = cursor.update(40, 50, false, shape, 0);
            _ = cursor.renderOverlay(self, 0);
            for (self.lowering.main_paint.items) |item| {
                if (item.kind == .image) return item.resource_handle;
            }
            return error.NoIconEmitted;
        }
    };
    var cx = FakeCx{ .allocator = std.testing.allocator };
    defer cx.lowering.main_paint.deinit(cx.allocator);

    const pointer_icon = try cx.iconIdFor(.pointer);
    const grab_icon = try cx.iconIdFor(.grab);
    const grabbing_icon = try cx.iconIdFor(.grabbing);

    try std.testing.expect(pointer_icon != grab_icon);
    try std.testing.expect(pointer_icon != grabbing_icon);
    try std.testing.expectEqual(icons.pointer.icon_id.?, pointer_icon);
    try std.testing.expectEqual(icons.grab.icon_id.?, grab_icon);
}

test "virtual cursor renders text shape and animates release pulse" {
    const FakeCx = struct {
        allocator: std.mem.Allocator,
        lowering: struct {
            main_paint: std.ArrayListUnmanaged(paint.DisplayItem) = .{},
        } = .{},
    };
    var cx = FakeCx{ .allocator = std.testing.allocator };
    defer cx.lowering.main_paint.deinit(cx.allocator);
    var cursor = VirtualCursor{};

    _ = cursor.update(40, 50, true, .text, 10);
    _ = cursor.update(40, 50, false, .text, 10);
    try std.testing.expect(cursor.renderOverlay(&cx, 20));
    try std.testing.expect(cx.lowering.main_paint.items.len >= 7);
    try std.testing.expectEqual(CursorShape.text, cursor.shape);
}
