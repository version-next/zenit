//! Idle-time GPU storage policy. While a window is not presenting, storage
//! that is rewritten every frame (per-slot instance/uniform buffers) or can be
//! regenerated (atlases, mask caches) is marked volatile: it leaves the process
//! footprint and the system may reclaim it under memory pressure. The next
//! frame makes it non-volatile before any use; regenerable storage whose
//! contents were discarded is rebuilt by its owner.
const gpu = @import("gpu");

pub const supported = @hasDecl(gpu.Backend.Buffer, "setVolatile");

/// Toggle a slot array of buffers (`[N]Buffer` or `[N]?Buffer`). Scratch
/// contents are never read across frames, so discarded data is irrelevant.
pub fn setBuffersVolatile(buffers: anytype, make_volatile: bool) void {
    if (comptime !supported) return;
    for (buffers) |*slot| {
        if (comptime @typeInfo(@TypeOf(slot.*)) == .optional) {
            if (slot.*) |*buffer| _ = buffer.setVolatile(make_volatile);
        } else _ = slot.setVolatile(make_volatile);
    }
}

/// Returns true when making a texture non-volatile found its contents gone.
pub fn setTextureVolatile(texture: *gpu.Backend.Texture, make_volatile: bool) bool {
    if (comptime !supported) return false;
    return texture.setVolatile(make_volatile);
}
