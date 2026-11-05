/// Blend Composite: offscreen layer composite for non-normal blend modes.
///
/// Non-normal blend reads dst: fixed-function blend factors only approximate
/// multiply/screen, and overlay/soft_light are inexpressible. So this uses the W3C
/// generic path:
///  1. Apple GPUs read the loaded color attachment directly. Other Metal GPUs
///     render-copy the restore target; other backends retain their blit copy;
///  2. In the restore pass draw a fullscreen triangle: fragment unpremul -> B(Cd,Cs)
///     -> SrcOver composite -> premul for pixels in rect; outside rect passes dst
///     through unchanged; pipeline has no blend state (replace).
///
/// The composite rect can be an arbitrary affine (rotate / draw_transform): the
/// fragment uses the inverse matrix to map target pixels to layer-local physical px,
/// then does the rect test, UV and rounded clip mask; a non-invertible (degenerate)
/// matrix falls back to normal composite.
///
/// Known boundaries (all fall back to normal composite, not error):
/// - The GPU retained cache declines non-normal blend outright (redraw every frame):
///   the result depends on dst, and this avoids pass-switch complexity;
/// - Blending is computed on sRGB-encoded values (non-_sRGB texture, samples are
///   encoded; matches CSS / Core Graphics, see docs/SRGB_BLENDING_PLAN.md); slight
///   hue difference from the CSS spec's nonlinear space.
const std = @import("std");
const gpu = @import("gpu");
const corner_radii = @import("zenit_corner_radii");
const offscreen_texture = @import("offscreen_texture.zig");

pub var blend_pipeline_compile_count: u64 = 0;

comptime {
    // setFragmentBytes limit 4 KiB (Metal spec).
    std.debug.assert(@sizeOf(BlendUniforms) <= 4096);
}

pub const BlendUniforms = extern struct {
    /// Restore target physical pixel size (fragcoord -> uv).
    target_size: [2]f32,
    /// Layer rect in **layer-local** space physical pixel size (quad w*h * scale).
    rect_size: [2]f32,
    /// src texture UV scale (used/alloc, 64px bucket allocation crop).
    src_uv_scale: [2]f32,
    /// Target physical pixel -> layer-local physical pixel: local = inv . pixel +
    /// inv_offset.
    inv_offset: [2]f32,
    /// 2x2 of above (a, b, c, d: local.x = a*px + c*py + ..., local.y = b*px +
    /// d*py + ...).
    inv: [4]f32,
    /// x = opacity, y = blend_mode (as float), z unused (see `corner_radii`), w = mask inset
    /// (physical px: the clip rect inside the quad).
    params: [4]f32,
    /// Layer rounded mask radii TL, TR, BR, BL (layer-local physical px).
    corner_radii: [4]f32,
    /// Composite rect clip (target physical px; w < 0 = none), same as other
    /// pipelines' rect_clip.
    clip_rect: [4]f32,
    /// Shape clip: x = kind (0 none / 1 rounded rect / 2 ellipse), yzw unused; rect in
    /// clip_shape_rect, corner radii in clip_shape_radii.
    clip_shape: [4]f32,
    clip_shape_rect: [4]f32,
    /// Shape clip corner radii TL, TR, BR, BL (target physical px; kind 1 only).
    clip_shape_radii: [4]f32,
    /// Lens warp (physical px): x = shift across the rounded ends, y = across the long edges
    /// (+ = toward the centre), z = fade start inset, w = fade width; x = y = 0 -> none.
    warp: [4]f32,
    /// xy = src texture UV of the quad's origin (a rounded layer composites its own rect out of
    /// its grid-aligned texture, opacity_layer.compositeQuad); zw = last used texel center.
    src_uv_origin: [4]f32,
    /// Second shape clip (shape_clip_pair.zig; kind in `clip_shape[1]`), target physical px.
    /// Zero-sized off Metal.
    clip2_rect: PartnerField = partner_none,
    clip2_radii: PartnerField = partner_none,
};

const PartnerField = if (gpu.backend_kind == .metal) [4]f32 else [0]f32;
const partner_none: PartnerField = if (gpu.backend_kind == .metal) .{ 0, 0, 0, 0 } else .{};

comptime {
    std.debug.assert(@sizeOf(BlendUniforms) == if (gpu.backend_kind == .metal) 208 else 176);
    std.debug.assert(@offsetOf(BlendUniforms, "corner_radii") == 64);
    std.debug.assert(@offsetOf(BlendUniforms, "clip_shape_radii") == 128);
}

/// Clips active at composite time, all in target physical pixels.
pub const CompositeClips = struct {
    rect: [4]f32 = .{ 0, 0, -1, -1 },
    shape_kind: u32 = 0,
    shape_rect: [4]f32 = .{ 0, 0, 0, 0 },
    /// TL, TR, BR, BL.
    shape_radii: [4]f32 = .{ 0, 0, 0, 0 },
    /// Second shape clip (shape_clip_pair.zig): kind 0 none / 1 rounded rect / 2 ellipse.
    partner_kind: u32 = 0,
    partner_rect: [4]f32 = .{ 0, 0, 0, 0 },
    partner_radii: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Inverse map target pixel to layer-local pixel. `affine` = (a, b, c, d, tx,
/// ty) logical units; map layer-local (x, y) in [0,w]x[0,h] to target:
/// (a*x + c*y + tx, b*x + d*y + ty); target physical px = logical * scale. Degenerate
/// (non-invertible) returns null.
pub const InverseMap = struct { inv: [4]f32, inv_offset: [2]f32 };
pub fn inverseLayerMap(affine: [6]f32, scale: f32) ?InverseMap {
    const det = affine[0] * affine[3] - affine[1] * affine[2];
    if (!std.math.isFinite(det) or @abs(det) < 1e-6) return null;
    for (affine) |v| if (!std.math.isFinite(v)) return null;
    // A⁻¹ for A = [a c; b d]
    const ia = affine[3] / det;
    const ib = -affine[1] / det;
    const ic = -affine[2] / det;
    const id = affine[0] / det;
    // local_px = scale · A⁻¹ · (pixel / scale − t) = A⁻¹ · pixel − scale · A⁻¹ · t
    return .{
        .inv = .{ ia, ib, ic, id },
        .inv_offset = .{ -scale * (ia * affine[4] + ic * affine[5]), -scale * (ib * affine[4] + id * affine[5]) },
    };
}

/// Quad (x, y, w, h) rotated by `rotate` about its centre: the affine the
/// image pipeline draws the normal composite with, so both paths agree.
pub fn rectRotateAffine(x: f32, y: f32, w: f32, h: f32, rotate: f32) [6]f32 {
    return @import("image_renderer.zig").ImageRenderer.affineRectRotate(x, y, w, h, rotate);
}

test "inverseLayerMap maps rotated target pixels back to layer-local pixels" {
    // 40x20 quad at (10, 10) rotated 90° at scale 2: its local top-left corner
    // lands at target (10+40, 10-... ) per the image pipeline's affine.
    const affine = rectRotateAffine(10, 10, 40, 20, std.math.pi / 2.0);
    const map = inverseLayerMap(affine, 2).?;
    // Forward-map local (40, 20) (bottom-right corner) and invert it.
    const tx = (affine[0] * 40 + affine[2] * 20 + affine[4]) * 2;
    const ty = (affine[1] * 40 + affine[3] * 20 + affine[5]) * 2;
    const lx = map.inv[0] * tx + map.inv[2] * ty + map.inv_offset[0];
    const ly = map.inv[1] * tx + map.inv[3] * ty + map.inv_offset[1];
    try std.testing.expectApproxEqAbs(@as(f32, 80), lx, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 40), ly, 1e-3);
    try std.testing.expect(inverseLayerMap(.{ 1, 2, 2, 4, 0, 0 }, 1) == null);
}

const blend_shader_source: []const u8 = @import("shader_sources.zig").composite;

pub fn usesFramebufferFetch(encoder: anytype) bool {
    if (comptime gpu.backend_kind == .metal) return encoder.sdf_renderer.device.supportsFramebufferFetch();
    return false;
}

/// Lazy compile blend composite pipeline (pattern same as
/// backdrop_blur.ensureBlurPipeline).
pub fn ensureBlendPipeline(encoder: anytype) bool {
    if (encoder.persistent.blend_pipeline != null) return true;
    if (encoder.persistent.blend_pipeline_failed) return false;
    blend_pipeline_compile_count += 1;

    const device = encoder.sdf_renderer.device;
    const source = if (comptime gpu.backend_kind == .metal)
        if (usesFramebufferFetch(encoder)) blend_shader_source else "#define ZENIT_FRAMEBUFFER_FETCH 0\n" ++ @embedFile("shaders/composite.metal")
    else
        blend_shader_source;
    var shader = gpu.Backend.ShaderModule.initFromSource(device, source) catch |e| {
        std.log.err("[blend] shader compile failed: {}", .{e});
        encoder.persistent.blend_pipeline_failed = true;
        return false;
    };
    defer shader.deinit();

    var vtx = shader.getFunction("blend_vertex_main") catch {
        encoder.persistent.blend_pipeline_failed = true;
        return false;
    };
    defer vtx.deinit();
    var frag = shader.getFunction("blend_fragment_main") catch {
        encoder.persistent.blend_pipeline_failed = true;
        return false;
    };
    defer frag.deinit();

    encoder.persistent.blend_pipeline = gpu.Backend.createRenderPipeline(device, .{
        .vertex_function = &vtx,
        .fragment_function = &frag,
        .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
        // No blend state: shader output is final pixel (rect outside passthrough dst).
        .blend_state = null,
    }) catch {
        encoder.persistent.blend_pipeline_failed = true;
        return false;
    };
    if (encoder.persistent.blur_sampler == null) {
        encoder.persistent.blur_sampler = device.createSampler(std.heap.page_allocator, .{
            .label = "Zenit.Composite.LinearSampler",
            .min_filter = .linear,
            .mag_filter = .linear,
        }) catch null;
    }
    return true;
}

/// Draw blend composite fullscreen triangle in **currently open render pass**.
/// Caller responsible: dst_copy contains restore target current content, pass attach
/// is restore target.
pub fn drawBlendComposite(
    encoder: anytype,
    src_texture: gpu.Backend.TextureBinding,
    dst_copy: gpu.Backend.TextureBinding,
    target_w: u32,
    target_h: u32,
    map: InverseMap,
    rect_size_px: [2]f32,
    src_uv_origin: [2]f32,
    src_uv_scale: [2]f32,
    opacity: f32,
    blend_mode_raw: u8,
    /// TL, TR, BR, BL (layer-local physical px).
    corner_radii_px: [4]f32,
    clips: CompositeClips,
    warp: [4]f32,
    /// Inset (physical px) of the true clip rect inside the quad: the rounded mask and the warp's
    /// contour distance use the rect shrunk by it (a folded rounded clip's layer is padded 2 pt)
    mask_inset_px: f32,
    src_uv_max: [2]f32,
) bool {
    if (encoder.render_pass == null) return false;
    var pipeline = encoder.persistent.blend_pipeline orelse return false;
    var sampler_state = encoder.persistent.blur_sampler orelse return false;

    encoder.persistent.blend_uniform_write_offset += 1;

    const uniforms = BlendUniforms{
        .target_size = .{ @floatFromInt(target_w), @floatFromInt(target_h) },
        .rect_size = rect_size_px,
        .src_uv_scale = src_uv_scale,
        .inv_offset = map.inv_offset,
        .inv = map.inv,
        .params = .{ opacity, @floatFromInt(blend_mode_raw), 0, mask_inset_px },
        // The mask is the quad shrunk by the inset (zb_rounded_rect_mask): fit the radii to it.
        .corner_radii = corner_radii.normalize(corner_radii_px, rect_size_px[0] - 2 * mask_inset_px, rect_size_px[1] - 2 * mask_inset_px),
        .clip_rect = clips.rect,
        .clip_shape = .{ @floatFromInt(clips.shape_kind), @floatFromInt(clips.partner_kind), 0, 0 },
        .clip_shape_rect = clips.shape_rect,
        .clip_shape_radii = clips.shape_radii,
        .warp = warp,
        .src_uv_origin = .{ src_uv_origin[0], src_uv_origin[1], src_uv_max[0], src_uv_max[1] },
        .clip2_rect = if (comptime gpu.backend_kind == .metal) clips.partner_rect else .{},
        .clip2_radii = if (comptime gpu.backend_kind == .metal) clips.partner_radii else .{},
    };

    var pass = encoder.render_pass.?;
    pass.setPipeline(&pipeline);
    // setFragmentBytes: copy on encode, in-flight frames not overwritten by next frame
    // (was single shared buffer + per-frame zero offset CPU/GPU race).
    pass.setFragmentBytes(0, std.mem.asBytes(&uniforms));
    pass.setFragmentTextureBinding(0, src_texture);
    if (!usesFramebufferFetch(encoder)) pass.setFragmentTextureBinding(1, dst_copy);
    pass.setFragmentSampler(0, &sampler_state);
    pass.draw(3, 1, 0, 0);
    return true;
}
