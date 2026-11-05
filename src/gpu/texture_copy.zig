//! Render-engine pixel copy on Metal; other backends retain their blit path.
const gpu = @import("gpu.zig");
pub const PassAudit = struct {
    pass_count: *u32,
    pass_sites: *[8]u32,
};

pub fn copyTextureRegion(
    encoder: *gpu.Backend.CommandEncoder,
    source: gpu.Backend.TextureBinding,
    sx: u32,
    sy: u32,
    width: u32,
    height: u32,
    destination: gpu.Backend.TextureBinding,
    dx: u32,
    dy: u32,
    clear: bool,
) !void {
    return copyTextureRegionAudited(encoder, source, sx, sy, width, height, destination, dx, dy, clear, null);
}

/// Renderer callers supply their audit counters; low-level copies keep the
/// original API. Count the clear as soon as its pass exists, even if blit fails.
pub fn copyTextureRegionAudited(
    encoder: *gpu.Backend.CommandEncoder,
    source: gpu.Backend.TextureBinding,
    sx: u32,
    sy: u32,
    width: u32,
    height: u32,
    destination: gpu.Backend.TextureBinding,
    dx: u32,
    dy: u32,
    clear: bool,
    audit: ?PassAudit,
) !void {
    if (comptime gpu.backend_kind == .metal) {
        return encoder.copyTextureRegionRender(source, sx, sy, width, height, destination, dx, dy, clear);
    } else {
        if (clear) {
            var view = destination.createView();
            defer view.destroy();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{
                .view = view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            }} });
            if (audit) |counters| {
                counters.pass_count.* += 1;
                counters.pass_sites[4] += 1; // clear_texture
            }
            pass.end();
        }
        var blit = try encoder.beginBlitPass();
        defer blit.end();
        try blit.copyTextureRegion(source, sx, sy, width, height, destination, dx, dy);
    }
}

test "texture copy clear audit includes a clear before a failed blit" {
    // SKIP-REASON: drives the null backend's fake GPU objects; real backends cover this path in their own suites.
    if (comptime gpu.backend_kind != .null_backend) return error.SkipZigTest;
    const t = @import("std").testing;
    var queue: gpu.Backend.Queue = .{};
    var encoder = try gpu.Backend.CommandEncoder.init(&queue);
    defer encoder.deinit();
    const src = gpu.Backend.TextureBinding.testBinding(1, 4, 4);
    const dst = gpu.Backend.TextureBinding.testBinding(2, 4, 4);
    var count: u32 = 0;
    var sites: [8]u32 = @splat(0);
    const audit: PassAudit = .{ .pass_count = &count, .pass_sites = &sites };
    try copyTextureRegionAudited(&encoder, src, 0, 0, 4, 4, dst, 0, 0, true, audit);
    try t.expectEqual(@as(u32, 1), count);
    try t.expectEqual(@as(u32, 1), sites[4]);
    try t.expectError(error.InvalidTextureRegion, copyTextureRegionAudited(&encoder, src, 4, 0, 4, 4, dst, 0, 0, true, audit));
    try t.expectEqual(@as(u32, 2), count);
    try copyTextureRegionAudited(&encoder, src, 0, 0, 4, 4, dst, 0, 0, false, audit);
    try t.expectEqual(@as(u32, 2), count);
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{} });
    try t.expectError(error.InvalidEncoderState, copyTextureRegionAudited(&encoder, src, 0, 0, 4, 4, dst, 0, 0, true, audit));
    pass.end();
    try t.expectEqual(@as(u32, 2), count);
    try t.expectEqual([8]u32{ 0, 0, 0, 0, 2, 0, 0, 0 }, sites);
}
