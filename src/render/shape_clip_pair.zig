//! Second shader shape clip. A render target may hold two shape clips in force: the primary
//! (any kind, including polygons) and this partner (rounded rect or ellipse). Every pipeline
//! multiplies both coverages per fragment, so two nested shapes that genuinely cross clip
//! exactly without an isolation layer (an offscreen pass plus a composite pass per crossing).
//!
//! Only the Metal shaders read the partner. Other backends keep a zero-sized field, so their
//! uniform ABI is unchanged and the encoder isolates crossing shapes as before.
const std = @import("std");
const gpu = @import("gpu");

/// The encoder may pair two shape clips. The null backend has no shaders but runs the same
/// encoder logic in unit tests.
pub const supported = gpu.backend_kind == .metal or gpu.backend_kind == .null_backend;

/// Partner clip as the Metal shaders read it: `rect` (x, y, w, h) and `radii` (TL, TR, BR, BL)
/// in logical px of the current target; `kind` 0 = none, 1 = rounded rect, 2 = ellipse.
pub const Uniform = extern struct {
    rect: [4]f32 align(16) = .{ 0, 0, 0, 0 },
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    kind: u32 = 0,
    _pad: [3]u32 = .{ 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(Uniform) == 48);
    std.debug.assert(@offsetOf(Uniform, "kind") == 32);
}

/// Field type appended to each pipeline's uniforms.
pub const Field = if (gpu.backend_kind == .metal) Uniform else [0]u8;
pub const none: Field = if (gpu.backend_kind == .metal) .{} else .{};

pub fn field(clip: Uniform) Field {
    return if (comptime gpu.backend_kind == .metal) clip else .{};
}
