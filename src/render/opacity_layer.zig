/// Opacity layer subsystem (extracted from command_encoder.zig). Provides
/// begin/endOpacityLayer: redirect render commands to offscreen texture, composite
/// back with opacity blending. Also reused for rounded-clip containers. Public entry
/// points accept encoder: anytype to avoid circular imports.
const std = @import("std");
const gpu = @import("gpu");
const offscreen_texture = @import("offscreen_texture.zig");
const blend_composite = @import("blend_composite.zig");
const debug_env = @import("debug_env.zig");
const TextureLease = offscreen_texture.TextureLease;

/// Upscale magnification factor of the composite transform (>= 1, max 4). The offscreen texture
/// is allocated at parent raster scale x this factor and drawn at that scale inside the layer,
/// so upscaled composites re-rasterize at target size instead of stretching a 1x bitmap
/// (measured: text and strokes at scale 2 looked blurry). Downscaling does not lower resolution
/// (factor stays 1).
pub fn layerMagnification(use_draw_transform: bool, draw_transform: [6]f32, w: f32, h: f32, draw_w: f32, draw_h: f32) f32 {
    const m: f32 = if (use_draw_transform)
        @max(@sqrt(draw_transform[0] * draw_transform[0] + draw_transform[1] * draw_transform[1]), @sqrt(draw_transform[2] * draw_transform[2] + draw_transform[3] * draw_transform[3]))
    else blk: {
        const sx = if (w > 0 and draw_w > 0 and !std.math.isNan(draw_w)) draw_w / w else 1;
        const sy = if (h > 0 and draw_h > 0 and !std.math.isNan(draw_h)) draw_h / h else 1;
        break :blk @max(sx, sy);
    };
    if (!std.math.isFinite(m)) return 1;
    return std.math.clamp(m, 1, 4);
}

/// Composite UVs of a layer texture: the content's own extent (w x raster scale), not the
/// rounded-up texel count. The texture holds ceil(w * s) texels of which the content covers
/// w * s; mapping all of them onto the w-wide quad compresses the content by up to one texel
/// across the layer, so the texel grid drifts off the target's pixel grid toward the middle
/// (a half-pixel resample: a magnified layer's glyphs and icons came out blurry). The extra
/// texel is cleared padding, never sampled.
pub fn contentUv(w: f32, h: f32, raster_scale: f32, used_w: u32, used_h: u32, alloc_w: u32, alloc_h: u32) [2]f32 {
    const ext_w: f32 = if (raster_scale > 0 and w > 0) @min(w * raster_scale, @as(f32, @floatFromInt(used_w))) else @floatFromInt(used_w);
    const ext_h: f32 = if (raster_scale > 0 and h > 0) @min(h * raster_scale, @as(f32, @floatFromInt(used_h))) else @floatFromInt(used_h);
    return .{
        if (alloc_w > 0) ext_w / @as(f32, @floatFromInt(alloc_w)) else 1,
        if (alloc_h > 0) ext_h / @as(f32, @floatFromInt(alloc_h)) else 1,
    };
}

/// Where a layer's texture goes in the composite: the quad (logical size), its texel sub-rect,
/// and its placement (the localized surface matrix, or a draw rect). Without a quad
/// (OffscreenLayer.quad w = 0) the whole layer; with one, the quad's own rect (a rounded
/// layer's mask) out of the grid-aligned texture: the matrix moves by A x inset, the UVs start
/// at the inset's texels, so each target pixel centre still lands on a texel centre.
pub const CompositeQuad = struct {
    w: f32,
    h: f32,
    uv: [4]f32,
    transform: [6]f32,
    draw: [4]f32,
};

pub fn compositeQuad(layer: anytype, raster_scale: f32, localized: [6]f32) CompositeQuad {
    const full = contentUv(layer.w, layer.h, raster_scale, layer.used_tex_w, layer.used_tex_h, layer.alloc_tex_w, layer.alloc_tex_h);
    const dw = if (layer.draw_w > 0) layer.draw_w else layer.w;
    const dh = if (layer.draw_h > 0) layer.draw_h else layer.h;
    if (!(layer.quad[2] > 0 and layer.quad[3] > 0 and layer.w > 0 and layer.h > 0 and layer.alloc_tex_w > 0 and layer.alloc_tex_h > 0)) {
        return .{ .w = layer.w, .h = layer.h, .uv = .{ 0, 0, full[0], full[1] }, .transform = localized, .draw = .{ layer.draw_x, layer.draw_y, dw, dh } };
    }
    const q = layer.quad;
    // texels per logical unit along each axis
    const rx = full[0] * @as(f32, @floatFromInt(layer.alloc_tex_w)) / layer.w;
    const ry = full[1] * @as(f32, @floatFromInt(layer.alloc_tex_h)) / layer.h;
    const aw: f32 = @floatFromInt(layer.alloc_tex_w);
    const ah: f32 = @floatFromInt(layer.alloc_tex_h);
    var t = localized;
    t[4] += localized[0] * q[0] + localized[2] * q[1];
    t[5] += localized[1] * q[0] + localized[3] * q[1];
    const sx = dw / layer.w;
    const sy = dh / layer.h;
    return .{
        .w = q[2],
        .h = q[3],
        .uv = .{ q[0] * rx / aw, q[1] * ry / ah, (q[0] + q[2]) * rx / aw, (q[1] + q[3]) * ry / ah },
        .transform = t,
        .draw = .{ layer.draw_x + q[0] * sx, layer.draw_y + q[1] * sy, q[2] * sx, q[3] * sy },
    };
}

/// Zero is a safety sentinel from the retained planner: backdrop-dependent
/// and untracked layers cannot be cached. Never turn that sentinel into a key.
pub fn rasterContentHash(content_hash: u64, geometry: anytype, scale: f32) u64 {
    if (content_hash == 0) return 0;
    var h = std.hash.Wyhash.init(content_hash);
    h.update(std.mem.asBytes(&geometry));
    h.update(std.mem.asBytes(&scale));
    return h.final();
}

/// Keep translation-only and axis-aligned scaled, unrounded surfaces on the parent pixel grid.
/// Fractional padding (e.g. -2 logical at 175% = -3.5 pixels) otherwise
/// resamples already-rasterized glyphs when the surface is composed at rest.
/// The phase that matters is where the texture origin lands in the current
/// target: the surface matrix translation for transformed surfaces (equal to
/// geom only for identity surfaces), else the draw origin. Expand bounds, and
/// translate the composite origin by the same amount; no content geometry,
/// opacity, easing, rounded mask or screen placement changes. A scaled surface
/// (matrix diag(a, d), a, d > 0) moves its bounds by the target shift / a, so it
/// composes like the direct draw as the scale returns to 1 (a magnified copy
/// otherwise lands off the grid and snaps sharp the frame it stops scaling). A rounded surface
/// is aligned the same way; its caller composites the original rect from it (the rounded mask
/// stays put, see OffscreenLayer.quad and compositeQuad).
///
/// A surface that knows its rest origin (`surface_rest_origin`: where the matrix translation
/// lands with the owner's scale back at 1 and its transient motion removed) anchors the grid
/// there instead of at the current matrix. The texture-local frame then stays put for the whole
/// animation: content snapped to its pixels (static text) rasterizes to the same texels every
/// frame, and once the animation settles the texture lands texel-for-pixel on the direct-draw
/// grid. Anchoring to the moving matrix instead shifts the texture-local frame by a fraction of a
/// pixel each frame, so snapped glyphs re-round one by one.
pub fn alignTranslationSurface(it: anytype, scale: f32, offset: [2]f32) @TypeOf(it) {
    var out = it;
    if (!std.math.isFinite(scale) or scale <= 0 or it.rotate != 0) return out;
    var lin = [2]f32{ 1, 1 };
    if (it.use_draw_transform) {
        if (it.draw_transform[1] != 0 or it.draw_transform[2] != 0) return out;
        lin = .{ it.draw_transform[0], it.draw_transform[3] };
        if (!std.math.isFinite(lin[0]) or !std.math.isFinite(lin[1]) or !(lin[0] > 0) or !(lin[1] > 0)) return out;
    } else {
        if ((!std.math.isNan(it.draw_w) and it.draw_w > 0 and it.draw_w != it.geom.w) or
            (!std.math.isNan(it.draw_h) and it.draw_h > 0 and it.draw_h != it.geom.h)) return out;
    }
    const size = [2]f32{ it.geom.w, it.geom.h };
    const rest: ?[2]f32 = if (comptime @hasField(@TypeOf(it), "surface_rest_origin"))
        (if (it.use_draw_transform) it.surface_rest_origin else null)
    else
        null;
    if (rest) |r| return alignToRestOrigin(it, scale, offset, lin, r);
    const origin: [2]f32 = if (it.use_draw_transform)
        .{ it.draw_transform[4], it.draw_transform[5] }
    else
        .{ if (std.math.isNan(it.draw_x)) it.geom.x else it.draw_x, if (std.math.isNan(it.draw_y)) it.geom.y else it.draw_y };
    for ([_]f32{ it.geom.x, it.geom.y, size[0], size[1], origin[0], origin[1] }) |v| if (!std.math.isFinite(v)) return out;
    if (size[0] <= 0 or size[1] <= 0) return out;
    // per axis: the shift of the texture origin in the target, and the bounds' shift and
    // extent in surface-local units (target / matrix scale)
    var shift: [2]f32 = undefined;
    var delta: [2]f32 = undefined;
    var extent: [2]f32 = undefined;
    for (0..2) |axis| {
        const target = origin[axis] + offset[axis];
        const lo = @floor(target * scale);
        const hi = @ceil((target + size[axis] * lin[axis]) * scale);
        if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return out;
        shift[axis] = lo / scale - target;
        delta[axis] = shift[axis] / lin[axis];
        extent[axis] = (hi - lo) / scale / lin[axis];
    }
    out.geom.x = it.geom.x + delta[0];
    out.geom.y = it.geom.y + delta[1];
    out.geom.w = extent[0];
    out.geom.h = extent[1];
    out.draw_x = (if (std.math.isNan(it.draw_x)) it.geom.x else it.draw_x) + delta[0];
    out.draw_y = (if (std.math.isNan(it.draw_y)) it.geom.y else it.draw_y) + delta[1];
    out.draw_w = extent[0];
    out.draw_h = extent[1];
    out.draw_transform[4] += shift[0];
    out.draw_transform[5] += shift[1];
    return out;
}

/// Rest-anchored variant of alignTranslationSurface: the texture origin sits on the target grid
/// at the rest pose (matrix scale 1, translation `rest`), so at rest it is pixel-exact and while
/// the owner scales or slides the texture-local frame (and every texel) stays the same. Bounds
/// are surface-local units, which equal target units at rest; the composite translation moves by
/// the current linear part times the bounds shift so the content keeps its place.
fn alignToRestOrigin(it: anytype, scale: f32, offset: [2]f32, lin: [2]f32, rest: [2]f32) @TypeOf(it) {
    var out = it;
    var delta: [2]f32 = undefined;
    var extent: [2]f32 = undefined;
    const size = [2]f32{ it.geom.w, it.geom.h };
    for (0..2) |axis| {
        const target = rest[axis] + offset[axis];
        const lo = @floor(target * scale);
        const hi = @ceil((target + size[axis]) * scale);
        if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return it;
        delta[axis] = lo / scale - target;
        extent[axis] = (hi - lo) / scale;
    }
    out.geom.x = it.geom.x + delta[0];
    out.geom.y = it.geom.y + delta[1];
    out.geom.w = extent[0];
    out.geom.h = extent[1];
    // draw_x/w stay the damage/cull envelope in the target frame: widen it by the scaled shift.
    out.draw_x = (if (std.math.isNan(it.draw_x)) it.geom.x else it.draw_x) + delta[0] * lin[0];
    out.draw_y = (if (std.math.isNan(it.draw_y)) it.geom.y else it.draw_y) + delta[1] * lin[1];
    out.draw_w = extent[0] * lin[0];
    out.draw_h = extent[1] * lin[1];
    out.draw_transform[4] += delta[0] * lin[0];
    out.draw_transform[5] += delta[1] * lin[1];
    return out;
}

/// The mask rect a rounded layer composites from its aligned texture: the source rect in
/// aligned-layer-local units, or the whole layer (w = 0) when alignment moved nothing.
pub fn maskQuad(src: anytype, aligned: anytype) [4]f32 {
    if (aligned.geom.x == src.geom.x and aligned.geom.y == src.geom.y and aligned.geom.w == src.geom.w and aligned.geom.h == src.geom.h)
        return .{ 0, 0, 0, 0 };
    return .{ src.geom.x - aligned.geom.x, src.geom.y - aligned.geom.y, src.geom.w, src.geom.h };
}

pub fn beginOpacityLayer(
    encoder: anytype,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opacity: f32,
    rotate: f32,
    draw_x: f32,
    draw_y: f32,
    draw_w: f32,
    draw_h: f32,
    use_draw_transform: bool,
    draw_transform: [6]f32,
    blend_mode: anytype,
) !bool {
    if (encoder.render_pass == null) return false;
    if (encoder.offscreen_depth >= 8) return false;
    if (encoder.gpu_command_encoder == null) return false;

    // (Step 1 four pipeline flushes moved into beginOpacityLayerInto; must run on
    // every open path; see that function's incident comment.)

    // 2. Calculate offscreen physical pixel size at effective raster scale.
    const max_texture_dimension = encoder.sdf_renderer.device.limits.max_texture_dimension_2d;
    var s = encoder.scale * layerMagnification(use_draw_transform, draw_transform, w, h, draw_w, draw_h);
    const texture_size = offscreen_texture.computeOffscreenTextureSize(w, h, s, max_texture_dimension) orelse blk: {
        // Upscale exceeds texture limit: revert to parent scale (clarity trades for drawable).
        s = encoder.scale;
        break :blk offscreen_texture.computeOffscreenTextureSize(w, h, s, max_texture_dimension) orelse return false;
    };
    const tex_w = texture_size.width;
    const tex_h = texture_size.height;
    // Allocate from 64px bucket (geometry animation ±1px jitter hits pool reuse);
    // content occupies [0, tex_w/h), composite clips UV by used/alloc.
    const alloc_w = offscreen_texture.bucketDimension(tex_w, max_texture_dimension);
    const alloc_h = offscreen_texture.bucketDimension(tex_h, max_texture_dimension);

    // 3. Acquire offscreen texture from pool.
    const device = encoder.sdf_renderer.device;
    const texture = encoder.offscreen_pool.acquire(device, alloc_w, alloc_h, encoder.frame_index) orelse return false;

    const pushed = beginOpacityLayerInto(
        encoder,
        texture,
        x,
        y,
        w,
        h,
        opacity,
        rotate,
        draw_x,
        draw_y,
        draw_w,
        draw_h,
        use_draw_transform,
        draw_transform,
        blend_mode,
        tex_w,
        tex_h,
        alloc_w,
        alloc_h,
        null,
        s,
    ) catch |e| {
        // Layer begin fails: return texture to pool (leaks one per fail otherwise).
        _ = encoder.offscreen_pool.release(texture, encoder.frame_index);
        return e;
    };
    if (!pushed) _ = encoder.offscreen_pool.release(texture, encoder.frame_index);
    return pushed;
}

/// After failed offscreen pass, open load-semantic pass back to original target
/// (parent offscreen or main RT) to restore state. WARNING: new pass viewport/scissor
/// default to full alloc texture; when parent is bucketed, must re-clip to used region
/// (+ damage scissor), else later content stretched to bucket size & partial-repaint
/// scissor lost. Same recovery pattern as backdrop_blur.restoreRenderTargetPass.
fn reopenRestoreTargetPass(encoder: anytype, restore_target: anytype) bool {
    var restore_view = restore_target.createView();
    defer restore_view.destroy();
    const restored = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = restore_view,
            .load_op = .load,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch return false;
    encoder.pass_count += 1;
    encoder.pass_sites[0] += 1;
    adoptRestoredPass(encoder, restored);
    return true;
}

/// Hang recovery pass onto stack top slot & reapply per-pass state (viewport/scissor).
fn adoptRestoredPass(encoder: anytype, restored: anytype) void {
    const slot = if (encoder.offscreen_depth > 0) encoder.offscreen_depth - 1 else 0;
    encoder.offscreen_stack[slot].render_pass = restored;
    encoder.render_pass = &encoder.offscreen_stack[slot].render_pass;
    encoder.applyOffscreenTargetViewport();
}

/// Damage-rect partial-repaint parameters (texture-local physical pixels).
pub const PartialRepaint = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// beginOpacityLayer second half; texture from caller. Normal path borrows from pool
/// by size; GPU retained path uses layer's dedicated texture. When partial != null:
/// load preserves old pixels, scissor limits to dirty region, pre-clear dirty with
/// no-blend to erase old, let content redraw within scissor; outside untouched.
fn beginOpacityLayerInto(
    encoder: anytype,
    texture: TextureLease,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opacity: f32,
    rotate: f32,
    draw_x: f32,
    draw_y: f32,
    draw_w: f32,
    draw_h: f32,
    use_draw_transform: bool,
    draw_transform: anytype,
    blend_mode: anytype,
    tex_w: u32,
    tex_h: u32,
    alloc_w: u32,
    alloc_h: u32,
    partial: ?PartialRepaint,
    /// This layer's raster scale (normal=parent x magnification; retained=parent).
    raster_scale: f32,
) !bool {
    const s = raster_scale;

    // 1. Flush current pipeline to current render pass. CRITICAL: must be here (not just
    // beginOpacityLayer): GPU retained miss path calls this directly. Without a flush before
    // the layer opens, un-flushed batches (panel bg, buttons, dim) discharge into the next
    // pass's offscreen texture and get cached by markRetainedPrimed, showing page content +
    // dim duplicated in the overlay surface rectangle.
    try flushLayerBoundaryPipelines(encoder);

    // 4. Pre-resolve all non-owning bindings; fail before resource registration or pass switch.
    const texture_binding = encoder.offscreen_pool.binding(texture) orelse return false;
    const restore_target: gpu.Backend.TextureBinding = if (encoder.offscreen_depth > 0)
        encoder.offscreen_pool.binding(encoder.offscreen_stack[encoder.offscreen_depth - 1].texture) orelse return false
    else
        (encoder.main_render_target orelse return false);
    const tex_id = if (encoder.image_renderer) |ir|
        ir.registerTextureBinding(texture_binding, alloc_w, alloc_h) catch return false
    else
        return false;

    if (comptime gpu.backend_kind == .metal and @hasDecl(@TypeOf(encoder.image_renderer.?.*), "setTextureSamplingExtent")) {
        encoder.image_renderer.?.setTextureSamplingExtent(tex_id, tex_w, tex_h);
    }

    // 6. End current render pass.
    encoder.render_pass.?.end();
    // Ended pass must never stay on encoder.render_pass: Obj-C reuses address for next
    // encoder (maybe blit); same GlassBox crash invariant as backdrop_blur. Success
    // path resets after push.
    encoder.render_pass = null;

    // 7. Open offscreen render pass in same command buffer.
    var offscreen_view = texture_binding.createView();
    const offscreen_pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = offscreen_view,
            // partial: load preserves outside-damage pixels; inside erased by clear draw below.
            .load_op = if (partial != null) .load else .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch {
        // Prior line ended current pass; early return leaves encoder.render_pass pointing to
        // ended pass, all downstream draws silently lost. Open load pass back to original to
        // restore state.
        offscreen_view.destroy();
        if (encoder.image_renderer) |ir| ir.unregisterTextureBinding(tex_id);
        _ = reopenRestoreTargetPass(encoder, restore_target);
        return false;
    };
    encoder.pass_count += 1; // v0.9-§D audit
    encoder.pass_sites[1] += 1;
    offscreen_view.destroy();

    // 8. Save state + push (re-localize coordinates to outer-local).
    const outer_off = encoder.offscreenOffset();
    const local_x = x + outer_off[0];
    const local_y = y + outer_off[1];
    const local_draw_x = if (std.math.isNan(draw_x)) draw_x else draw_x + outer_off[0];
    const local_draw_y = if (std.math.isNan(draw_y)) draw_y else draw_y + outer_off[1];
    encoder.offscreen_stack[encoder.offscreen_depth] = .{
        .texture = texture,
        .render_pass = offscreen_pass,
        .restore_target = restore_target,
        .saved_clip_depth = encoder.clip_depth,
        .saved_clip_overflow_depth = encoder.clip_overflow_depth,
        .saved_logical_clip_stack = encoder.logical_clip_stack,
        .saved_effective_rect_clip_stack = encoder.effective_rect_clip_stack,
        .saved_viewport_width = encoder.viewport_width,
        .saved_viewport_height = encoder.viewport_height,
        .x = local_x,
        .y = local_y,
        .w = w,
        .h = h,
        .opacity = opacity,
        .saved_scale = encoder.scale,
        .raster_scale = s,
        .rotate = rotate,
        .use_draw_transform = use_draw_transform,
        .draw_transform = draw_transform,
        .draw_x = local_draw_x,
        .draw_y = local_draw_y,
        .draw_w = draw_w,
        .draw_h = draw_h,
        .texture_id = tex_id,
        .blend_mode = blend_mode,
        .used_tex_w = tex_w,
        .used_tex_h = tex_h,
        .alloc_tex_w = alloc_w,
        .alloc_tex_h = alloc_h,
        .damage_scissor = partial,
    };
    encoder.offscreen_depth += 1;
    // Draw at this layer's raster scale (pop restores saved_scale on exit).
    encoder.scale = s;

    // 9. Switch render state to offscreen.
    encoder.render_pass = &encoder.offscreen_stack[encoder.offscreen_depth - 1].render_pass;
    encoder.clip_depth = 0;
    encoder.clip_overflow_depth = 0;
    encoder.viewport_width = w;
    encoder.viewport_height = h;

    // 10. Reconfigure three pipelines' viewport.
    encoder.sdf_renderer.setViewport(w, h, s);
    encoder.text_renderer.setViewport(w, h, s);
    if (encoder.image_renderer) |ir| ir.setViewport(w, h, s);
    if (encoder.icon_renderer) |ir| ir.setViewport(w, h, s);
    if (encoder.persistent.path_renderer) |*pr| {
        pr.setViewport(w, h, s);
        pr.setOffscreenViewport();
    }
    // NDC fills alloc texture by default; the viewport is the content's exact extent (w x s,
    // fractional) so content lands 1:1 on texels in [0, w * s), neither stretched to the bucket
    // nor to the rounded-up texel count (contentUv composites the same extent back).
    encoder.render_pass.?.setViewport(0, 0, w * s, h * s, 0, 1);
    if (partial) |p| {
        // Scissor limits to dirty region (rasterize clipped to damage, untouched outside),
        // pre-clear dirty pixels with no-blend (Metal loadAction can't clear sub-rect).
        // Scissor is per-pass state: nested passes (child opacity layers) end & restore
        // via applyOffscreenTargetViewport; path renderer manages scissor via damage_scissor.
        // caller (tryBeginRetainedOpacityLayer) pre-checked via ensureDamageClearPipeline;
        // pass/stack ready, can't fail.
        encoder.render_pass.?.setScissorRect(p.x, p.y, p.w, p.h);
        if (encoder.persistent.path_renderer) |*pr| pr.damage_scissor = .{ p.x, p.y, p.w, p.h };
        _ = drawDamageClear(encoder);
    } else {
        encoder.render_pass.?.setScissorRect(0, 0, tex_w, tex_h);
        if (encoder.persistent.path_renderer) |*pr| pr.damage_scissor = null;
    }
    encoder.syncRectClipState();
    encoder.syncRendererClipMask();
    encoder.syncTextClipX();
    return true;
}

// Damage-rect: dirty-region clear draw (Metal loadAction whole-texture only;
// sub-rect clear = scissor + no-blend full-screen triangle outputting (0,0,0,0)).

const damage_clear_shader_source: []const u8 = @import("shader_sources.zig").damage_clear;

fn ensureDamageClearPipeline(encoder: anytype) bool {
    if (encoder.persistent.damage_clear_pipeline != null) return true;
    if (encoder.persistent.damage_clear_pipeline_failed) return false;

    const device = encoder.sdf_renderer.device;
    var shader = gpu.Backend.ShaderModule.initFromSource(device, damage_clear_shader_source) catch |e| {
        std.log.err("[damage-clear] shader compile failed: {}", .{e});
        encoder.persistent.damage_clear_pipeline_failed = true;
        return false;
    };
    defer shader.deinit();
    var vtx = shader.getFunction("damage_clear_vertex_main") catch {
        encoder.persistent.damage_clear_pipeline_failed = true;
        return false;
    };
    defer vtx.deinit();
    var frag = shader.getFunction("damage_clear_fragment_main") catch {
        encoder.persistent.damage_clear_pipeline_failed = true;
        return false;
    };
    defer frag.deinit();

    encoder.persistent.damage_clear_pipeline = gpu.Backend.createRenderPipeline(device, .{
        .vertex_function = &vtx,
        .fragment_function = &frag,
        .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
        // No blend: output is final pixel, (0,0,0,0) direct write = clear.
        .blend_state = null,
    }) catch {
        encoder.persistent.damage_clear_pipeline_failed = true;
        return false;
    };
    return true;
}

/// Fill the main target's damage rect (the current scissor) with the frame's
/// clear colour: a full frame starts from that colour by its load action, a
/// damage-scissored one keeps the presented pixels around the rect.
pub fn fillFrameDamage(encoder: anytype, color: [4]f32) bool {
    if (comptime gpu.backend_kind != .metal) return false;
    const pass = encoder.render_pass orelse return false;
    const pipeline = frameDamagePipeline(encoder, &encoder.persistent.damage_fill_pipeline, "damage_fill_fragment_main") orelse return false;
    pass.setPipeline(pipeline);
    pass.setFragmentBytes(0, std.mem.asBytes(&color));
    pass.draw(3, 1, 0, 0);
    return true;
}

/// Draw the kept copy of the presented frame over the whole main target
/// (texel for texel, no blending): what a damage-scissored frame keeps
/// outside its damage rect. Restores the frame's own scissor afterwards.
pub fn copyFrameForward(encoder: anytype, presented: gpu.Backend.TextureBinding) bool {
    if (comptime gpu.backend_kind != .metal) return false;
    const pass = encoder.render_pass orelse return false;
    const pipeline = frameDamagePipeline(encoder, &encoder.persistent.damage_copy_pipeline, "damage_copy_fragment_main") orelse return false;
    pass.setScissorRect(0, 0, encoder.drawable_extent[0], encoder.drawable_extent[1]);
    pass.setPipeline(pipeline);
    pass.setFragmentTextureBinding(0, presented);
    pass.draw(3, 1, 0, 0);
    encoder.applyOffscreenTargetViewport();
    return true;
}

fn frameDamagePipeline(encoder: anytype, slot: *?gpu.Backend.RenderPipeline, fragment: [:0]const u8) ?*const gpu.Backend.RenderPipeline {
    if (slot.* == null) {
        if (encoder.persistent.damage_fill_pipeline_failed) return null;
        const device = encoder.sdf_renderer.device;
        const built: ?gpu.Backend.RenderPipeline = build: {
            var shader = gpu.Backend.ShaderModule.initFromSource(device, damage_clear_shader_source) catch break :build null;
            defer shader.deinit();
            var vtx = shader.getFunction("damage_clear_vertex_main") catch break :build null;
            defer vtx.deinit();
            var frag = shader.getFunction(fragment) catch break :build null;
            defer frag.deinit();
            break :build gpu.Backend.createRenderPipeline(device, .{
                .vertex_function = &vtx,
                .fragment_function = &frag,
                .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
                .blend_state = null,
            }) catch null;
        };
        slot.* = built orelse {
            encoder.persistent.damage_fill_pipeline_failed = true;
            return null;
        };
    }
    return &slot.*.?;
}

/// Largest of TL, TR, BR, BL: a layer has a rounded mask when any corner is rounded.
fn maxRadius(radii: [4]f32) f32 {
    return @max(@max(radii[0], radii[1]), @max(radii[2], radii[3]));
}

/// Issue one clear draw in current pass within current scissor.
fn drawDamageClear(encoder: anytype) bool {
    if (!ensureDamageClearPipeline(encoder)) return false;
    const pass = encoder.render_pass.?;
    pass.setPipeline(&encoder.persistent.damage_clear_pipeline.?);
    pass.draw(3, 1, 0, 0);
    return true;
}

/// End offscreen opacity layer. 1. Flush offscreen pipeline -> end offscreen pass,
/// 2. BeginRenderPass back to restore target (load preserves), 3. Image pipeline
/// composite offscreen texture with opacity blending. Rects/shape clips active on
/// restore target in its physical pixels.
fn compositeClips(encoder: anytype) blend_composite.CompositeClips {
    const s = encoder.scale;
    var clips: blend_composite.CompositeClips = .{};
    if (encoder.currentRectClip()) |rc| clips.rect = .{ rc[0] * s, rc[1] * s, rc[2] * s, rc[3] * s };
    if (encoder.activeRoundedClip()) |shape| {
        clips.shape_kind = @backingInt(shape.shape_kind);
        clips.shape_rect = .{ shape.x * s, shape.y * s, shape.w * s, shape.h * s };
        clips.shape_radii = .{ shape.radii[0] * s, shape.radii[1] * s, shape.radii[2] * s, shape.radii[3] * s };
        if (shape.partner) |p| {
            clips.partner_kind = if (p.shape_kind == .ellipse) 2 else 1;
            clips.partner_rect = .{ p.x * s, p.y * s, p.w * s, p.h * s };
            clips.partner_radii = .{ p.radii[0] * s, p.radii[1] * s, p.radii[2] * s, p.radii[3] * s };
        }
    }
    return clips;
}

pub fn endOpacityLayer(encoder: anytype) !void {
    if (encoder.offscreen_depth == 0) return;
    if (encoder.gpu_command_encoder == null) return;
    encoder.offscreen_depth -= 1;
    const layer = encoder.offscreen_stack[encoder.offscreen_depth];
    // Missing pool entry is state corruption, but can't unreachable (ReleaseFast UB):
    // skip gutter blit & blend composite if binding lost; still composite via image
    // pipeline (texture_id registered at open) & restore pass normally.
    const layer_binding_opt = encoder.offscreen_pool.binding(layer.texture);
    if (layer_binding_opt == null) {
        std.log.warn("[opacity-layer] offscreen binding lost at end; skipping gutter/blend composite", .{});
    }

    if (debug_env.flag("ZENIT_DEBUG_SURFDUMP")) {
        std.debug.print("[surfgpu] end layer x={d:.1} y={d:.1} w={d:.1} h={d:.1} op={d:.2} txt_n={d} txt_l={d} sdf={d} dt=({d:.2},{d:.2},{d:.2},{d:.2},{d:.1},{d:.1})\n", .{
            layer.x,                                           layer.y,                                          layer.w,                                  layer.h,                 layer.opacity,
            encoder.text_renderer.instances_nearest.items.len, encoder.text_renderer.instances_linear.items.len, encoder.sdf_renderer.instances.items.len, layer.draw_transform[0], layer.draw_transform[1],
            layer.draw_transform[2],                           layer.draw_transform[3],                          layer.draw_transform[4],                  layer.draw_transform[5],
        });
    }

    // 1. Flush offscreen pipeline. On fail, this layer already popped, step 7 won't run;
    // texture_id registered at open must unregister here else slot lost forever (retained
    // texture not markRetainedPrimed yet; next frame total redraw).
    flushLayerBoundaryPipelines(encoder) catch |e| {
        if (encoder.image_renderer) |ir| ir.unregisterTextureBinding(layer.texture_id);
        return e;
    };

    // 2. End offscreen render pass.
    encoder.render_pass.?.end();
    // Same invariant as begin: after end, before restore pass assigned (blit passes in
    // between), encoder.render_pass must be null; any early return leaves stale pointer.
    encoder.render_pass = null;

    // 2.5 Metal clamps to used texel centers in the image/blend shaders. Other
    // backends fill the gutter: copy used edge 1px into adjacent padding to mirror clamp-to-edge,
    // else composite bilinear at UV clamp boundary mixes edge content (blur/rounded
    // container to edge) with transparent padding -> <=3/255 dark fringe. 1px enough:
    // bilinear samples adjacent texel only.
    const pad_w = layer.alloc_tex_w > layer.used_tex_w and layer.used_tex_w > 0;
    const pad_h = layer.alloc_tex_h > layer.used_tex_h and layer.used_tex_h > 0;
    if (comptime gpu.backend_kind != .metal) {
        if ((pad_w or pad_h) and layer_binding_opt != null) {
            const layer_binding = layer_binding_opt.?;
            if (encoder.gpu_command_encoder.?.beginBlitPass() catch null) |blit_value| {
                var blit = blit_value;
                defer blit.end();
                if (pad_w) {
                    blit.copyTextureRegion(
                        layer_binding,
                        layer.used_tex_w - 1,
                        0,
                        1,
                        layer.used_tex_h,
                        layer_binding,
                        layer.used_tex_w,
                        0,
                    ) catch {};
                }
                if (pad_h) {
                    blit.copyTextureRegion(
                        layer_binding,
                        0,
                        layer.used_tex_h - 1,
                        layer.used_tex_w,
                        1,
                        layer_binding,
                        0,
                        layer.used_tex_h,
                    ) catch {};
                }
                if (pad_w and pad_h) {
                    blit.copyTextureRegion(
                        layer_binding,
                        layer.used_tex_w - 1,
                        layer.used_tex_h - 1,
                        1,
                        1,
                        layer_binding,
                        layer.used_tex_w,
                        layer.used_tex_h,
                    ) catch {};
                }
            }
        }
    }

    // 2.7 Non-normal blend: Apple GPUs read the loaded destination attachment.
    // Other Metal devices render-copy a backup; other backends keep blit.
    // Return null if any backup step fails;
    // step 7 falls back to normal composite (semantic downgrade, no error/content loss).
    // Composite rect can be arbitrary affine (rotate/draw_transform): fragment inverts
    // back to layer-local space; only degenerate matrix fails.
    var blend_dst_copy: ?TextureLease = null;
    var blend_fetch = false;
    var blend_target_w: u32 = 0;
    var blend_target_h: u32 = 0;
    const blend_mode_raw: u8 = @intCast(@backingInt(layer.blend_mode));
    // A lens warp samples the layer surface off its pixel grid: composite through the blend
    // pipeline (which reads dst), like a non-normal blend.
    const warp_active = layer.warp[0] != 0 or layer.warp[1] != 0;
    // Layer quad (local w x h, logical units) to current restore target affine:
    // consistent with step 7 image pipeline paths: draw_transform (localize to target
    // frame) or draw rect rotated around center.
    const cq = compositeQuad(layer, layer.raster_scale, if (layer.use_draw_transform) encoder.localizeDrawTransformForCurrentTarget(layer.draw_transform) else .{ 1, 0, 0, 1, 0, 0 });
    const blend_quad: [2]f32 = if (layer.use_draw_transform) .{ cq.w, cq.h } else .{ cq.draw[2], cq.draw[3] };
    const blend_affine: [6]f32 = if (layer.use_draw_transform)
        cq.transform
    else
        blend_composite.rectRotateAffine(cq.draw[0], cq.draw[1], blend_quad[0], blend_quad[1], layer.rotate);
    // the target's scale (encoder.scale is still this layer's raster scale here)
    const blend_map = blend_composite.inverseLayerMap(blend_affine, layer.saved_scale);
    // Clips in force where the layer is composited (the saved clip state is
    // restored before the composite): a polygon clip is not supported by the
    // blend composite and falls back to normal compositing.
    // Like the other pipelines the composite honours the active shape clip and its
    // partner, the target's whole shape clip (see pushClipCommand); a polygon clip is
    // not expressible and declines.
    const blend_clips_ok = blk: {
        for (layer.saved_logical_clip_stack[0..layer.saved_clip_depth]) |clip| {
            if (clip.shape_kind == .polygon) break :blk false;
        }
        break :blk true;
    };
    if ((blend_mode_raw != 0 or warp_active) and blend_map != null and blend_clips_ok and
        layer_binding_opt != null and blend_composite.ensureBlendPipeline(encoder))
    {
        const tw = layer.restore_target.width;
        const th = layer.restore_target.height;
        if (tw > 0 and th > 0) {
            if (blend_composite.usesFramebufferFetch(encoder)) {
                blend_fetch = true;
                blend_target_w = tw;
                blend_target_h = th;
            } else {
                const device2 = encoder.sdf_renderer.device;
                const max_dim = encoder.sdf_renderer.device.limits.max_texture_dimension_2d;
                const copy_w = offscreen_texture.bucketDimension(tw, max_dim);
                const copy_h = offscreen_texture.bucketDimension(th, max_dim);
                if (encoder.offscreen_pool.acquire(device2, copy_w, copy_h, encoder.frame_index)) |copy| {
                    if (encoder.offscreen_pool.binding(copy)) |copy_binding| {
                        const copied = blk: {
                            encoder.copyTextureRegion(layer.restore_target, 0, 0, tw, th, copy_binding, 0, 0, false) catch break :blk false;
                            break :blk true;
                        };
                        if (copied) {
                            blend_dst_copy = copy;
                            blend_target_w = tw;
                            blend_target_h = th;
                        } else {
                            _ = encoder.offscreen_pool.release(copy, encoder.frame_index);
                        }
                    } else {
                        _ = encoder.offscreen_pool.release(copy, encoder.frame_index);
                    }
                }
            }
        }
    }

    // 3. BeginRenderPass back to restore target.
    var restore_view = layer.restore_target.createView();
    const restored_pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = restore_view,
            .load_op = .load,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch {
        // Restore pass open fails: render_pass stays null (upstream skips drawing as 'no
        // layer open'), but clean up resources else leak texture + texture_id per fail.
        restore_view.destroy();
        if (encoder.image_renderer) |ir| ir.unregisterTextureBinding(layer.texture_id);
        if (blend_dst_copy) |copy| _ = encoder.offscreen_pool.release(copy, encoder.frame_index);
        if (layer.retained_id != INVALID_SURFACE_ID) {
            encoder.offscreen_pool.dropRetained(layer.retained_id, encoder.frame_index);
        } else {
            _ = encoder.offscreen_pool.release(layer.texture, encoder.frame_index);
        }
        std.log.warn("[opacity-layer] restore render pass failed; dropping layer composite this frame", .{});
        return;
    };
    encoder.pass_count += 1; // v0.9-§D audit
    encoder.pass_sites[2] += 1;
    restore_view.destroy();

    // 4. Restore state.
    if (encoder.offscreen_depth > 0) {
        encoder.offscreen_stack[encoder.offscreen_depth - 1].render_pass = restored_pass;
        encoder.render_pass = &encoder.offscreen_stack[encoder.offscreen_depth - 1].render_pass;
    } else {
        encoder.offscreen_stack[0].render_pass = restored_pass;
        encoder.render_pass = &encoder.offscreen_stack[0].render_pass;
    }
    encoder.restoreSavedClipState(layer);
    encoder.viewport_width = layer.saved_viewport_width;
    encoder.viewport_height = layer.saved_viewport_height;

    // 5. Restore parent raster scale & three pipeline viewport.
    encoder.scale = layer.saved_scale;
    const s = encoder.scale;
    encoder.sdf_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, s);
    encoder.text_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, s);
    if (encoder.image_renderer) |ir| ir.setViewport(encoder.viewport_width, encoder.viewport_height, s);
    if (encoder.icon_renderer) |ir| ir.setViewport(encoder.viewport_width, encoder.viewport_height, s);
    if (encoder.persistent.path_renderer) |*pr| {
        pr.setViewport(encoder.viewport_width, encoder.viewport_height, s);
        if (encoder.offscreen_depth > 0) pr.setOffscreenViewport();
    }

    // Restore target may itself be bucketed offscreen texture -> clip viewport/scissor
    // to its used region.
    encoder.applyOffscreenTargetViewport();
    encoder.syncRectClipState();
    encoder.syncRendererClipMask();
    encoder.syncTextClipX();

    // Texture bucketed, content [0, w * raster scale): composite clips UV to it (compositeQuad).

    // 6.5 Non-normal blend: composite via blend pipeline (full-screen triangle,
    // passthrough dst outside rect), skip image pipeline path below.
    var blend_done = false;
    if (blend_fetch or blend_dst_copy != null) blend: {
        // copy just validated few lines up, but can't unreachable (ReleaseFast UB): on
        // lookup fail, abandon blend, fall back to normal composite.
        const copy_binding = if (blend_fetch) layer.restore_target else encoder.offscreen_pool.binding(blend_dst_copy.?) orelse {
            _ = encoder.offscreen_pool.release(blend_dst_copy.?, encoder.frame_index);
            std.log.warn("[opacity-layer] blend dst copy binding lost; falling back to normal composite", .{});
            break :blend;
        };
        const layer_binding = layer_binding_opt.?;
        // Rect test, UV & rounded mask in layer-local physical px (quad w x h x scale);
        // target pixel inverts via blend_map to local; affine scale/rotate via matrix inverse.
        blend_done = blend_composite.drawBlendComposite(
            encoder,
            layer_binding,
            copy_binding,
            blend_target_w,
            blend_target_h,
            blend_map.?,
            .{ blend_quad[0] * encoder.scale, blend_quad[1] * encoder.scale },
            .{ cq.uv[0], cq.uv[1] },
            .{ cq.uv[2] - cq.uv[0], cq.uv[3] - cq.uv[1] },
            layer.opacity,
            blend_mode_raw,
            .{ layer.corner_radii[0] * encoder.scale, layer.corner_radii[1] * encoder.scale, layer.corner_radii[2] * encoder.scale, layer.corner_radii[3] * encoder.scale },
            compositeClips(encoder),
            .{ layer.warp[0] * encoder.scale, layer.warp[1] * encoder.scale, layer.warp[2] * encoder.scale, layer.warp[3] * encoder.scale },
            // A warp moves content into the folded clip's 2 pt pad and its square corners, where
            // the padded mask lets it through: mask the true clip rect instead.
            if (warp_active and maxRadius(layer.corner_radii) >= 0.5) 2 * encoder.scale else 0,
            .{ (@as(f32, @floatFromInt(layer.used_tex_w)) - 0.5) / @as(f32, @floatFromInt(layer.alloc_tex_w)), (@as(f32, @floatFromInt(layer.used_tex_h)) - 0.5) / @as(f32, @floatFromInt(layer.alloc_tex_h)) },
        );
        // Copy this frame GPU-sampled, normal return with REUSE_LAG protection.
        if (blend_dst_copy) |copy| _ = encoder.offscreen_pool.release(copy, encoder.frame_index);
    }
    if (blend_done) {
        if (encoder.image_renderer) |ir| ir.unregisterTextureBinding(layer.texture_id);
    } else
    // 7. Composite offscreen texture with opacity blending to restore target via image
    // pipeline.
    if (encoder.image_renderer) |ir| {
        if (layer.use_draw_transform) {
            try ir.addImageUVWithTransform(layer.texture_id, cq.w, cq.h, cq.uv, .{ 1, 1, 1, 1 }, layer.corner_radii, layer.opacity, cq.transform, true);
        } else {
            try ir.addImageUVPremultiplied(layer.texture_id, cq.draw[0], cq.draw[1], cq.draw[2], cq.draw[3], cq.uv, .{ 1, 1, 1, 1 }, layer.corner_radii, layer.opacity, layer.rotate);
        }
        try ir.flush(encoder.render_pass.?);
        ir.unregisterTextureBinding(layer.texture_id);
    }
    if (encoder.icon_renderer) |ir| try ir.flush(encoder.render_pass.?);

    // 8. Return texture.
    if (layer.retained_id != INVALID_SURFACE_ID) {
        // GPU retained: this texture exclusively owned by this layer, **not returned to
        // pool**. Content just drawn, mark primed; next frame same content_version hits cache,
        // skip entire content pass.
        _ = encoder.offscreen_pool.markRetainedPrimed(layer.texture);
        // Damage-rect: write per-item baseline to entry for next frame miss diff. If
        // capture incomplete (non-flat layer/overflow/index overflow), mark invalid,
        // next frame full redraw.
        if (layer.retained_seq < encoder.damage_ranges.len) {
            const range = encoder.damage_ranges[layer.retained_seq];
            if (range.captured and range.safe and !range.overflow) {
                encoder.offscreen_pool.storeRetainedDamageItems(
                    layer.retained_id,
                    encoder.damage_scratch[range.start .. range.start + range.len],
                );
            } else {
                encoder.offscreen_pool.storeRetainedDamageItems(layer.retained_id, null);
            }
        } else {
            encoder.offscreen_pool.storeRetainedDamageItems(layer.retained_id, null);
        }
    } else {
        _ = encoder.offscreen_pool.release(layer.texture, encoder.frame_index);
    }
}

// GPU retained composite: only composite transform/opacity when content unchanged.
// Even when CPU commands are cached (render_engine splices prior frame) and the texture is
// pooled, beginOpacityLayer would **re-rasterize**, saving CPU only. Instead, by **layer
// identity** (surface_stable_id, cross-frame stable with ABA gen), hold a dedicated texture
// with content_version check. Hit: skip entire content command range, one composite draw.
//
// Safety: any doubt -> miss (redundant draw safer than stale content display).
// Never retained if: surface_stable_id == INVALID, size changed, not yet primed,
// content_version mismatch, pool exhausted.

/// display_list.INVALID_SURFACE_ID mirror. Encoder doesn't import ui-side type;
/// duplicated by value here; both must match (comptime assert in command_encoder).
pub const INVALID_SURFACE_ID: u32 = std.math.maxInt(u32);

comptime {
    // Both sentinels must exactly match: encoder copy not importing ui-side type.
    // Mismatch lets non-retained layers pose as valid, share one texture & overwrite
    // each other—frame-level bug, hard to debug. Compile-time pinned.
    std.debug.assert(INVALID_SURFACE_ID == offscreen_texture.NO_RETAINED_OWNER);
}

/// tryBeginRetainedOpacityLayer has three outcomes (not bool). With a bool, the miss branch
/// had already opened the layer (writing to the dedicated texture) but returned false; the
/// caller read that as "retained declined" and called normal beginOpacityLayer again, so
/// the same content was double-wrapped in offscreen and Modal/Sheet could not render.
/// Three states split "already handling" from "your turn".
pub const RetainedBegin = enum {
    /// Hit: content pass completely skipped, call compositeRetainedLayer at paired end.
    hit,
    /// Miss but **this function already opened layer** (wrote to dedicated texture).
    /// Caller does nothing; content encodes normally, normal endOpacityLayer finishes.
    opened_for_repaint,
    /// Didn't engage. Caller uses normal beginOpacityLayer (per-frame redraw).
    declined,
};

/// Try GPU retained path. Return semantics in RetainedBegin.
pub fn tryBeginRetainedOpacityLayer(
    encoder: anytype,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opacity: f32,
    rotate: f32,
    draw_x: f32,
    draw_y: f32,
    draw_w: f32,
    draw_h: f32,
    use_draw_transform: bool,
    draw_transform: anytype,
    blend_mode: anytype,
    corner_radii: [4]f32,
    surface_stable_id: u32,
    surface_content_version: u64,
    content_seq: usize,
) !RetainedBegin {
    if (surface_stable_id == INVALID_SURFACE_ID) return .declined;
    // Diagnostic escape: ZENIT_NO_RETAINED=1 forces all per-frame redraw.
    if (!encoder.retained_enabled or debug_env.flag("ZENIT_NO_RETAINED")) return .declined;
    if (encoder.render_pass == null) return .declined;
    // Non-normal blend not retained: result depends on dst (background per-frame
    // variable); hit composite needs dst blit + pass switch, v1 not worth rare case.
    if (@backingInt(blend_mode) != 0) return .declined;
    // Only **top-level** retained. Nested in other offscreen layers: content
    // rasterization depends on outer viewport/clip/coords; cross-frame reuse of texture
    // from different outer contexts unsafe. Below top level, downgrade to per-frame.
    if (encoder.offscreen_depth != 0) return .declined;
    // Upscale layers rasterize at post-magnification scale (see layerMagnification);
    // retained texture fixed post-parent scale; scale animation changes scale each frame,
    // always per-frame path.
    if (layerMagnification(use_draw_transform, draw_transform, w, h, draw_w, draw_h) > 1.001) return .declined;
    if (encoder.gpu_command_encoder == null) return .declined;
    if (encoder.retained_pending_depth >= encoder.retained_pending.len) return .declined;

    const s = encoder.scale;
    const max_texture_dimension = encoder.sdf_renderer.device.limits.max_texture_dimension_2d;
    const texture_size = offscreen_texture.computeOffscreenTextureSize(w, h, s, max_texture_dimension) orelse return .declined;
    const tex_w = texture_size.width;
    const tex_h = texture_size.height;
    const alloc_w = offscreen_texture.bucketDimension(tex_w, max_texture_dimension);
    const alloc_h = offscreen_texture.bucketDimension(tex_h, max_texture_dimension);

    const device = encoder.sdf_renderer.device;
    const got = encoder.offscreen_pool.acquireRetained(
        device,
        surface_stable_id,
        surface_content_version,
        alloc_w,
        alloc_h,
        encoder.frame_index,
    ) orelse return .declined;

    if (!got.content_matches) {
        // Claimed but needs redraw. Use normal begin path but **into this dedicated
        // texture**; end marks markRetainedPrimed, next same version hits.
        encoder.retained_misses += 1;

        // Damage-rect: old pixels valid (primed + same size) & layer 'flat'
        // (complete capture, no nested pass/path/clip) -> diff to dirty region.
        const damage: ?PartialRepaint = if (got.was_primed)
            computePartialDamage(encoder, surface_stable_id, content_seq, x, y, w, h, s, tex_w, tex_h)
        else
            null;
        if (damage != null) encoder.retained_partial_repaints += 1;
        if (debug_env.flag("ZENIT_DEBUG_SURFDUMP") and damage == null) {
            const range_info: [3]bool = if (content_seq < encoder.damage_ranges.len) .{
                encoder.damage_ranges[content_seq].captured,
                encoder.damage_ranges[content_seq].safe,
                encoder.damage_ranges[content_seq].overflow,
            } else .{ false, false, false };
            std.debug.print("[damage] full repaint id={d} primed={} captured={} safe={} overflow={} prev_baseline={}\n", .{
                surface_stable_id, got.was_primed,
                range_info[0],     range_info[1],
                range_info[2],     encoder.offscreen_pool.retainedDamageItems(surface_stable_id) != null,
            });
        }

        const pushed = try beginOpacityLayerInto(
            encoder,
            got.lease,
            x,
            y,
            w,
            h,
            opacity,
            rotate,
            draw_x,
            draw_y,
            draw_w,
            draw_h,
            use_draw_transform,
            draw_transform,
            blend_mode,
            tex_w,
            tex_h,
            alloc_w,
            alloc_h,
            damage,
            encoder.scale,
        );
        // Only mark retained if stack push succeeded; else marks **outer layer's**
        // unrelated texture, skipping return forever.
        if (pushed and encoder.offscreen_depth > 0) {
            // layer_tree writeback: this layer's actual decision (1=full redraw, 2=partial,
            // local space).
            if (damage) |d| {
                encoder.recordLayerOutcome(surface_stable_id, 2, .{
                    @as(f32, @floatFromInt(d.x)) / s,
                    @as(f32, @floatFromInt(d.y)) / s,
                    @as(f32, @floatFromInt(d.x + d.w)) / s,
                    @as(f32, @floatFromInt(d.y + d.h)) / s,
                });
            } else {
                encoder.recordLayerOutcome(surface_stable_id, 1, .{ 0, 0, w, h });
            }
            encoder.offscreen_stack[encoder.offscreen_depth - 1].retained_id = surface_stable_id;
            encoder.offscreen_stack[encoder.offscreen_depth - 1].retained_seq = content_seq;
            if (maxRadius(corner_radii) >= 0.5) {
                encoder.offscreen_stack[encoder.offscreen_depth - 1].corner_radii = corner_radii;
            }
            return .opened_for_repaint;
        }
        // Layer didn't open: dedicated texture undrawn this frame, undo claim to avoid
        // next frame false prime; caller uses normal path to re-open.
        encoder.offscreen_pool.dropRetained(surface_stable_id, encoder.frame_index);
        return .declined;
    }

    // Hit: content pixels already this frame's target, entire content pass elided.
    encoder.retained_hits += 1;
    // layer_tree writeback: cache hit, zero repaint this frame.
    encoder.recordLayerOutcome(surface_stable_id, 0, .{ 0, 0, 0, 0 });
    // Coords stored **outer-local** (same semantics as OffscreenLayer x/y):
    // normal endOpacityLayer composites in after `offscreen_depth -= 1` when
    // offscreenOffset() is back at parent view; we never pushed, so the current offset is already
    // parent view and composite's localizeDrawTransformForCurrentTarget adds it again.
    // Can't pre-add, or the offset is applied twice.
    const outer_off = encoder.offscreenOffset();
    encoder.retained_pending[encoder.retained_pending_depth] = .{
        .texture = got.lease,
        .x = x + outer_off[0],
        .y = y + outer_off[1],
        .w = w,
        .h = h,
        .opacity = opacity,
        .rotate = rotate,
        .use_draw_transform = use_draw_transform,
        .draw_transform = draw_transform,
        .draw_x = if (std.math.isNan(draw_x)) draw_x else draw_x + outer_off[0],
        .draw_y = if (std.math.isNan(draw_y)) draw_y else draw_y + outer_off[1],
        .draw_w = draw_w,
        .draw_h = draw_h,
        .corner_radii = corner_radii,
        .used_tex_w = tex_w,
        .used_tex_h = tex_h,
        .alloc_tex_w = alloc_w,
        .alloc_tex_h = alloc_h,
    };
    encoder.retained_pending_depth += 1;
    return .hit;
}

/// Damage-rect: miss diffs prior frame baseline vs this frame capture, yields
/// texture-local dirty region. null=partial repaint conditions unmet (full redraw,
/// always safe fallback).
fn computePartialDamage(
    encoder: anytype,
    surface_stable_id: u32,
    content_seq: usize,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    s: f32,
    tex_w: u32,
    tex_h: u32,
) ?PartialRepaint {
    // Escape: ZENIT_DISABLE_PARTIAL_REPAINT=1 force full redraw. (Real app Layers
    // panel: hover key drawn wrong (partial repaint ghosting in virtlist rebind +
    // heavy item insert/delete + scroll translate + high-freq opacity); disabled clears it.
    if (debug_env.flag("ZENIT_DISABLE_PARTIAL_REPAINT")) return null;
    if (content_seq >= encoder.damage_ranges.len) return null;
    const range = encoder.damage_ranges[content_seq];
    if (!range.captured or !range.safe or range.overflow) return null;
    const prev = encoder.offscreen_pool.retainedDamageItems(surface_stable_id) orelse return null;
    const cur = encoder.damage_scratch[range.start .. range.start + range.len];
    const dbg = debug_env.flag("ZENIT_DEBUG_SURFDUMP");
    // Clear draw pipeline unavailable -> no partial repaint (can't erase dirty old).
    if (!ensureDamageClearPipeline(encoder)) {
        if (dbg) std.debug.print("[damage] null: clear pipeline unavailable id={d}\n", .{surface_stable_id});
        return null;
    }

    // Index alignment diff: insert/delete shifts suffix; shifted items all dirty
    // (over-inclusive, safe).
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var any = false;
    var diff_count: usize = 0;
    var first_diff: usize = std.math.maxInt(usize);
    const common = @min(prev.len, cur.len);
    var i: usize = 0;
    while (i < common) : (i += 1) {
        // digest or bounds change = dirty: digest omits position; 'content unchanged but
        // layout shifted' (e.g., sibling animation resolves) must redraw, else old texture
        // residue at old position + redrawn item misaligned. (Proof: panel morph then
        // opposite Inspector row misaligned/missing.)
        const b_prev = prev[i].bounds;
        const b_cur = cur[i].bounds;
        const moved = b_prev[0] != b_cur[0] or b_prev[1] != b_cur[1] or
            b_prev[2] != b_cur[2] or b_prev[3] != b_cur[3];
        if (prev[i].digest != cur[i].digest or moved) {
            unionBounds(&min_x, &min_y, &max_x, &max_y, prev[i].bounds);
            unionBounds(&min_x, &min_y, &max_x, &max_y, cur[i].bounds);
            any = true;
            diff_count += 1;
            if (first_diff == std.math.maxInt(usize)) first_diff = i;
        }
    }
    if (dbg) std.debug.print("[damage] diffstat id={d} prev_n={d} cur_n={d} common_diffs={d} first={d}\n", .{ surface_stable_id, prev.len, cur.len, diff_count, first_diff });
    for (prev[common..]) |it| {
        unionBounds(&min_x, &min_y, &max_x, &max_y, it.bounds);
        any = true;
    }
    for (cur[common..]) |it| {
        unionBounds(&min_x, &min_y, &max_x, &max_y, it.bounds);
        any = true;
    }
    // Fingerprint changed but item diff empty: change outside items (scale/composite
    // params etc.), can't locate dirty region, full redraw.
    if (!any) {
        if (dbg) std.debug.print("[damage] null: empty item diff id={d} prev_n={d} cur_n={d}\n", .{ surface_stable_id, prev.len, cur.len });
        return null;
    }

    // layer_tree damage convergence: production explicit damage (addDamage) merged in
    // (local -> global logical); safe direction, only enlarges dirty region.
    var k: usize = 0;
    while (k < encoder.layer_damage_count) : (k += 1) {
        if (encoder.layer_damage_ids[k] != surface_stable_id) continue;
        const r = encoder.layer_damage_rects[k];
        unionBounds(&min_x, &min_y, &max_x, &max_y, .{ x + r[0], y + r[1], r[2] - r[0], r[3] - r[1] });
        break;
    }

    // Convert to texture-local physical px (+ 1px safety pad), clamp to used region.
    const lx = @max((min_x - x) * s - 1, 0);
    const ly = @max((min_y - y) * s - 1, 0);
    const hx = @min((max_x - x) * s + 1, @as(f32, @floatFromInt(tex_w)));
    const hy = @min((max_y - y) * s + 1, @as(f32, @floatFromInt(tex_h)));
    if (hx <= lx or hy <= ly) {
        if (dbg) std.debug.print("[damage] null: degenerate rect id={d}\n", .{surface_stable_id});
        return null; // Dirty region fully outside layer (abnormal bounds) -> conservative full redraw.
    }
    const px: u32 = @intFromFloat(@floor(lx));
    const py: u32 = @intFromFloat(@floor(ly));
    const pw: u32 = @intFromFloat(@ceil(hx - lx));
    const ph: u32 = @intFromFloat(@ceil(hy - ly));

    // Dirty too large (>60% layer area) not worth it: full redraw saves clear draw &
    // diff complexity.
    const damage_area: f32 = @floatFromInt(pw * ph);
    const layer_area = @max(w * s * h * s, 1);
    if (damage_area > layer_area * 0.6) {
        if (dbg) std.debug.print("[damage] null: area {d:.0}% > 60% id={d} rect=({d},{d},{d}x{d})\n", .{ damage_area / layer_area * 100, surface_stable_id, px, py, pw, ph });
        return null;
    }

    if (debug_env.flag("ZENIT_DEBUG_SURFDUMP")) {
        std.debug.print("[damage] partial repaint id={d} rect=({d},{d},{d}x{d}) of tex {d}x{d} ({d:.0}% of layer)\n", .{
            surface_stable_id, px, py, pw, ph, tex_w, tex_h, damage_area / layer_area * 100,
        });
    }
    return .{ .x = px, .y = py, .w = @min(pw, tex_w - px), .h = @min(ph, tex_h - py) };
}

inline fn unionBounds(min_x: *f32, min_y: *f32, max_x: *f32, max_y: *f32, b: [4]f32) void {
    min_x.* = @min(min_x.*, b[0]);
    min_y.* = @min(min_y.*, b[1]);
    max_x.* = @max(max_x.*, b[0] + b[2]);
    max_y.* = @max(max_y.*, b[1] + b[3]);
}

/// Layer boundary (begin/end/retained composite) pipeline discharge. Within one
/// pass, draw order = flush order, must match RenderCommandEncoder.flush canonical
/// order (sdf -> image -> icon -> text); three call sites share this to prevent
/// drift (retained hit was sdf->icon->text, missed image).
pub fn flushLayerBoundaryPipelines(encoder: anytype) !void {
    const rp = encoder.render_pass.?;
    try encoder.sdf_renderer.flush(rp);
    if (encoder.image_renderer) |ir| try ir.flush(rp);
    if (encoder.icon_renderer) |ir| try ir.flush(rp);
    try encoder.text_renderer.flush(rp);
}

/// Retained hit composite: cache texture with transform/opacity back to current
/// target. Equivalent to endOpacityLayer step 7, but no end/begin pass switch;
/// content pass completely skipped, never left current pass.
pub fn compositeRetainedLayer(encoder: anytype) !void {
    if (encoder.retained_pending_depth == 0) return;
    encoder.retained_pending_depth -= 1;
    const layer = encoder.retained_pending[encoder.retained_pending_depth];
    if (encoder.render_pass == null) return;

    // Flush layer-below batched instances before composite. Within a pass, draw order = flush
    // order: un-flushed sdf/text/icon would draw after the layer composite, atop the retained
    // layer, reversing paint order. Normal begin's step 1 is four flushes; hit skips begin, so
    // must flush here.
    // WARNING: order must match normal (sdf->image->icon->text); a mismatch makes hit vs miss
    // frames differ in z-order (flicker). Use the shared helper.
    try flushLayerBoundaryPipelines(encoder);

    const ir = encoder.image_renderer orelse return;
    const texture_binding = encoder.offscreen_pool.binding(layer.texture) orelse return;
    const tex_id = ir.registerTextureBinding(texture_binding, layer.alloc_tex_w, layer.alloc_tex_h) catch return;
    defer ir.unregisterTextureBinding(tex_id);
    if (comptime gpu.backend_kind == .metal and @hasDecl(@TypeOf(ir.*), "setTextureSamplingExtent")) ir.setTextureSamplingExtent(tex_id, layer.used_tex_w, layer.used_tex_h);

    // retained layers rasterize at the parent scale (no magnification); draw_transform stored
    // **un-localized** original: normal path also localizes after pop; current offscreen
    // context = that point, one localize here. Pre-adding offset would calculate twice (Modal
    // blank root cause).
    const cq = compositeQuad(layer, encoder.scale, if (layer.use_draw_transform) encoder.localizeDrawTransformForCurrentTarget(layer.draw_transform) else .{ 1, 0, 0, 1, 0, 0 });
    if (layer.use_draw_transform) {
        try ir.addImageUVWithTransform(tex_id, cq.w, cq.h, cq.uv, .{ 1, 1, 1, 1 }, layer.corner_radii, layer.opacity, cq.transform, true);
    } else {
        try ir.addImageUVPremultiplied(tex_id, cq.draw[0], cq.draw[1], cq.draw[2], cq.draw[3], cq.uv, .{ 1, 1, 1, 1 }, layer.corner_radii, layer.opacity, layer.rotate);
    }
    try ir.flush(encoder.render_pass.?);
}

// Regression guards.

test "RetainedBegin: three distinct outcomes (bool would conflate two)" {
    // Regression guard: the three values must stay distinct. opened_for_repaint (layer already
    // opened, content -> dedicated texture; caller does nothing) must differ from declined
    // (caller opens the layer itself). Conflating them (the old bool return) made the caller
    // call normal beginOpacityLayer after a miss, double-wrapping content so Modal/Sheet
    // could not render.
    const testing = std.testing;
    try testing.expect(RetainedBegin.hit != RetainedBegin.opened_for_repaint);
    try testing.expect(RetainedBegin.opened_for_repaint != RetainedBegin.declined);
    try testing.expect(RetainedBegin.hit != RetainedBegin.declined);
}

test "INVALID_SURFACE_ID matches the pool's no-owner sentinel" {
    // Comptime pinned once; runtime assert here clearer on fail.
    try std.testing.expectEqual(offscreen_texture.NO_RETAINED_OWNER, INVALID_SURFACE_ID);
}

test "compositeRetainedLayer: hit 路径 flush 顺序与普通路径一致（sdf→image→icon→text）" {
    // Regression: hit path once flushed sdf->icon->text, missed image; un-flushed
    // pics drawn after un-flushed text, z-order inverted between hit/miss frames.
    const Log = struct {
        buf: [8]u8 = undefined,
        n: usize = 0,
        fn push(self: *@This(), c: u8) void {
            self.buf[self.n] = c;
            self.n += 1;
        }
    };
    const Rp = struct {};
    const Flusher = struct {
        log: *Log,
        tag: u8,
        pub fn flush(self: *@This(), _: *Rp) !void {
            self.log.push(self.tag);
        }
    };
    const ImgFlusher = struct {
        log: *Log,
        pub fn flush(self: *@This(), _: *Rp) !void {
            self.log.push('i');
        }
        pub fn registerTextureBinding(_: *@This(), _: u8, _: u32, _: u32) !u32 {
            return error.Unreachable;
        }
        pub fn unregisterTextureBinding(_: *@This(), _: u32) void {}
        pub fn addImageUVWithTransform(_: *@This(), _: u32, _: f32, _: f32, _: [4]f32, _: [4]f32, _: [4]f32, _: f32, _: [6]f32, _: bool) !void {}
        pub fn addImageUVPremultiplied(_: *@This(), _: u32, _: f32, _: f32, _: f32, _: f32, _: [4]f32, _: [4]f32, _: [4]f32, _: f32, _: f32) !void {}
    };
    const Pool = struct {
        pub fn binding(_: *@This(), _: u8) ?u8 {
            return null; // Early exit before composite: test only checks flush order.
        }
    };
    const Pending = struct {
        texture: u8 = 0,
        w: f32 = 0,
        h: f32 = 0,
        opacity: f32 = 1,
        rotate: f32 = 0,
        use_draw_transform: bool = false,
        draw_transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
        draw_x: f32 = 0,
        draw_y: f32 = 0,
        draw_w: f32 = 0,
        draw_h: f32 = 0,
        corner_radii: [4]f32 = .{ 0, 0, 0, 0 },
        used_tex_w: u32 = 0,
        used_tex_h: u32 = 0,
        alloc_tex_w: u32 = 0,
        alloc_tex_h: u32 = 0,
        quad: [4]f32 = .{ 0, 0, 0, 0 },
    };
    var log = Log{};
    var rp = Rp{};
    var sdf = Flusher{ .log = &log, .tag = 's' };
    var icon = Flusher{ .log = &log, .tag = 'c' };
    var text = Flusher{ .log = &log, .tag = 't' };
    var img = ImgFlusher{ .log = &log };
    var pool = Pool{};
    const Enc = struct {
        retained_pending_depth: usize = 1,
        retained_pending: [1]Pending = .{.{}},
        scale: f32 = 2,
        render_pass: ?*Rp,
        sdf_renderer: *Flusher,
        image_renderer: ?*ImgFlusher,
        icon_renderer: ?*Flusher,
        text_renderer: *Flusher,
        offscreen_pool: *Pool,
        pub fn localizeDrawTransformForCurrentTarget(_: *@This(), t: [6]f32) [6]f32 {
            return t;
        }
    };
    var enc = Enc{
        .render_pass = &rp,
        .sdf_renderer = &sdf,
        .image_renderer = &img,
        .icon_renderer = &icon,
        .text_renderer = &text,
        .offscreen_pool = &pool,
    };
    try compositeRetainedLayer(&enc);
    try std.testing.expectEqualStrings("sict", log.buf[0..log.n]);
}

test "adoptRestoredPass: 补开的父 pass 重新施加 offscreen viewport/scissor" {
    // Regression: failed offscreen beginRenderPass's backup parent pass used default
    // viewport (full bucketed alloc), parent content stretched, damage scissor lost.
    // backdrop_blur.restoreRenderTargetPass fixed this long ago.
    const Pass = struct { id: u32 = 0 };
    const Layer = struct { render_pass: Pass = .{} };
    const Enc = struct {
        offscreen_depth: usize = 1,
        offscreen_stack: [2]Layer = .{ .{}, .{} },
        render_pass: ?*Pass = null,
        viewport_applied: u32 = 0,
        pub fn applyOffscreenTargetViewport(self: *@This()) void {
            // Must call after new pass hung (reads from render_pass for target).
            if (self.render_pass != null) self.viewport_applied += 1;
        }
    };
    var enc = Enc{};
    adoptRestoredPass(&enc, Pass{ .id = 7 });
    try std.testing.expectEqual(@as(u32, 7), enc.render_pass.?.id);
    try std.testing.expect(enc.render_pass.? == &enc.offscreen_stack[0].render_pass);
    try std.testing.expectEqual(@as(u32, 1), enc.viewport_applied);
}

test "translation surface grid keeps content placement and leaves rotated/skewed surfaces unchanged" {
    const Item = struct {
        geom: struct { x: f32, y: f32, w: f32, h: f32 },
        radii: struct { tl: f32 = 0, tr: f32 = 0, br: f32 = 0, bl: f32 = 0 } = .{},
        rotate: f32 = 0,
        use_draw_transform: bool = true,
        draw_transform: [6]f32 = .{ 1, 0, 0, 1, 778, -2 },
        draw_x: f32 = 778,
        draw_y: f32 = -2,
        draw_w: f32 = 324,
        draw_h: f32 = 100,
    };
    const source = Item{ .geom = .{ .x = -2, .y = -2, .w = 324, .h = 100 } };
    for ([_]f32{ 1, 1.25, 1.5, 1.75, 2 }) |scale| {
        for ([_][2]f32{ .{ 0, 0 }, .{ 0.3, -0.7 } }) |offset| {
            const actual = alignTranslationSurface(source, scale, offset);
            // The texture origin lands on the target pixel grid (the surface
            // matrix translation, localized by the parent offset).
            try std.testing.expectApproxEqAbs(@round((actual.draw_transform[4] + offset[0]) * scale), (actual.draw_transform[4] + offset[0]) * scale, 0.001);
            try std.testing.expectApproxEqAbs(@round((actual.draw_transform[5] + offset[1]) * scale), (actual.draw_transform[5] + offset[1]) * scale, 0.001);
            try std.testing.expect(actual.geom.x <= source.geom.x + 0.0001 and actual.geom.y <= source.geom.y + 0.0001);
            try std.testing.expect(actual.geom.x + actual.geom.w >= source.geom.x + source.geom.w - 0.0001);
            try std.testing.expectApproxEqAbs(source.draw_transform[4] + 16 - source.geom.x, actual.draw_transform[4] + 16 - actual.geom.x, 0.0001);
            try std.testing.expectApproxEqAbs(source.draw_transform[5] + 16 - source.geom.y, actual.draw_transform[5] + 16 - actual.geom.y, 0.0001);
        }
    }
    // A nested surface whose matrix translation and envelope differ in pixel
    // phase (geom -8 at 175% is on the grid, translation -6 + parent offset is
    // not): aligning by geom left the composite on a half pixel and resampled
    // the layer twice (glass inside a fading parent lost ~10 levels of contrast).
    var nested = source;
    nested.geom = .{ .x = -8, .y = -8, .w = 44, .h = 44 };
    nested.draw_transform[4] = -6;
    nested.draw_transform[5] = -6;
    const parent_offset = [2]f32{ 2.2857144, 2.2857144 };
    const nested_aligned = alignTranslationSurface(nested, 1.75, parent_offset);
    try std.testing.expectApproxEqAbs(@round((nested_aligned.draw_transform[4] + parent_offset[0]) * 1.75), (nested_aligned.draw_transform[4] + parent_offset[0]) * 1.75, 0.001);
    try std.testing.expectApproxEqAbs(nested.draw_transform[4] - nested.geom.x, nested_aligned.draw_transform[4] - nested_aligned.geom.x, 0.0001);
    try std.testing.expect(nested_aligned.geom.x + nested_aligned.geom.w >= nested.geom.x + nested.geom.w - 0.0001);
    var protected = source;
    protected.rotate = 0.1;
    try std.testing.expectEqualDeep(protected, alignTranslationSurface(protected, 1.75, .{ 0, 0 }));
    protected = source;
    protected.draw_transform[1] = 0.1;
    try std.testing.expectEqualDeep(protected, alignTranslationSurface(protected, 1.75, .{ 0, 0 }));
}

test "scaled surface grid: texture origin on the grid, screen placement unchanged" {
    const Item = struct {
        geom: struct { x: f32, y: f32, w: f32, h: f32 },
        radii: struct { tl: f32 = 0, tr: f32 = 0, br: f32 = 0, bl: f32 = 0 } = .{},
        rotate: f32 = 0,
        use_draw_transform: bool = true,
        draw_transform: [6]f32,
        draw_x: f32 = 0,
        draw_y: f32 = 0,
        draw_w: f32 = 121,
        draw_h: f32 = 61,
    };
    // a tab-bar accent copy magnified about its centre (GlassTabBar), lens at y 449.2
    for ([_]f32{ 1.0001, 1.23 }) |k| {
        const src = Item{ .geom = .{ .x = -10, .y = -2, .w = 121, .h = 61 }, .draw_transform = .{ k, 0, 0, k, 353.97, 447.31 } };
        const out = alignTranslationSurface(src, 2, .{ 0, 0 });
        try std.testing.expectApproxEqAbs(@round(out.draw_transform[4] * 2), out.draw_transform[4] * 2, 0.001);
        try std.testing.expectApproxEqAbs(@round(out.draw_transform[5] * 2), out.draw_transform[5] * 2, 0.001);
        // every surface-local point lands where it did: t - A * geom is invariant
        try std.testing.expectApproxEqAbs(src.draw_transform[4] - k * src.geom.x, out.draw_transform[4] - k * out.geom.x, 0.0001);
        try std.testing.expectApproxEqAbs(src.draw_transform[5] - k * src.geom.y, out.draw_transform[5] - k * out.geom.y, 0.0001);
        try std.testing.expect(out.geom.x <= src.geom.x and out.geom.x + out.geom.w >= src.geom.x + src.geom.w - 0.0001);
        try std.testing.expect(out.geom.y <= src.geom.y and out.geom.y + out.geom.h >= src.geom.y + src.geom.h - 0.0001);
    }
}

test "rest-anchored surface grid: one texture frame for the whole scale/slide, pixel-exact at rest" {
    const Item = struct {
        geom: struct { x: f32, y: f32, w: f32, h: f32 },
        radii: struct { tl: f32 = 0, tr: f32 = 0, br: f32 = 0, bl: f32 = 0 } = .{},
        rotate: f32 = 0,
        use_draw_transform: bool = true,
        draw_transform: [6]f32,
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
        surface_rest_origin: ?[2]f32,
    };
    // A popover panel resting at (263.35, 184.8) (off the 2x grid), opening with scale about its
    // top-left anchor (8, 0) and a dropdown slide of up to 6 pt.
    const rest = [2]f32{ 263.35, 184.8 };
    const geom = .{ .x = -12.0, .y = -8.0, .w = 260.0, .h = 120.0 };
    const anchor = [2]f32{ 8, 0 };
    const scale: f32 = 2;
    var frame0: ?Item = null;
    for ([_]f32{ 0.95, 0.97, 0.99, 0.9995, 1 }) |k| {
        for ([_]f32{ 0, -2.7, -6 }) |slide| {
            if (k == 1 and slide != 0) continue;
            // M = T(rest + slide) * S_anchor(k) * T(geom): the quad origin maps to
            // rest + slide + anchor + k * (geom - anchor).
            const src = Item{
                .geom = .{ .x = geom.x, .y = geom.y, .w = geom.w, .h = geom.h },
                .draw_transform = .{ k, 0, 0, k, rest[0] + anchor[0] + k * (geom.x - anchor[0]), rest[1] + slide + anchor[1] + k * (geom.y - anchor[1]) },
                .surface_rest_origin = .{ rest[0] + geom.x, rest[1] + geom.y },
            };
            const out = alignTranslationSurface(src, scale, .{ 0, 0 });
            // The texture-local frame does not depend on the pose: same bounds every frame.
            if (frame0) |f| {
                try std.testing.expectEqual(f.geom.x, out.geom.x);
                try std.testing.expectEqual(f.geom.y, out.geom.y);
                try std.testing.expectEqual(f.geom.w, out.geom.w);
                try std.testing.expectEqual(f.geom.h, out.geom.h);
            } else frame0 = out;
            // Its origin sits on the grid at rest, and texels are whole target pixels there.
            try std.testing.expectApproxEqAbs(@round((rest[0] + out.geom.x) * scale), (rest[0] + out.geom.x) * scale, 0.001);
            try std.testing.expectApproxEqAbs(@round((rest[1] + out.geom.y) * scale), (rest[1] + out.geom.y) * scale, 0.001);
            // Every surface-local point composites where it did: t - k * geom is invariant.
            try std.testing.expectApproxEqAbs(src.draw_transform[4] - k * src.geom.x, out.draw_transform[4] - k * out.geom.x, 0.0001);
            try std.testing.expectApproxEqAbs(src.draw_transform[5] - k * src.geom.y, out.draw_transform[5] - k * out.geom.y, 0.0001);
            try std.testing.expect(out.geom.x <= src.geom.x and out.geom.x + out.geom.w >= src.geom.x + src.geom.w - 0.0001);
            try std.testing.expect(out.geom.y <= src.geom.y and out.geom.y + out.geom.h >= src.geom.y + src.geom.h - 0.0001);
            // At rest the composite origin is on the target grid (texel-for-pixel).
            if (k == 1) try std.testing.expectApproxEqAbs(@round(out.draw_transform[4] * scale), out.draw_transform[4] * scale, 0.001);
        }
    }
    // Without a rest origin (null) the grid follows the current matrix, as before.
    var unknown = Item{
        .geom = .{ .x = geom.x, .y = geom.y, .w = geom.w, .h = geom.h },
        .draw_transform = .{ 1, 0, 0, 1, rest[0] + geom.x, rest[1] + geom.y },
        .surface_rest_origin = null,
    };
    const followed = alignTranslationSurface(unknown, scale, .{ 0, 0 });
    unknown.surface_rest_origin = .{ rest[0] + geom.x, rest[1] + geom.y };
    const anchored = alignTranslationSurface(unknown, scale, .{ 0, 0 });
    try std.testing.expectEqual(followed.geom.x, anchored.geom.x);
    try std.testing.expectEqual(followed.geom.y, anchored.geom.y);
    try std.testing.expectApproxEqAbs(followed.draw_transform[4], anchored.draw_transform[4], 0.0001);
    try std.testing.expectApproxEqAbs(followed.draw_transform[5], anchored.draw_transform[5], 0.0001);
}

test "compositeQuad: a rounded layer composites its own rect from the grid-aligned texture" {
    // GlassTabBar portal: rounded (36.74), at x 349.954 / y 249.456 (2x): aligned to the grid,
    // its texture starts 0.954 / 0.456 pt earlier; the quad keeps the original rect.
    const Item = struct {
        geom: struct { x: f32, y: f32, w: f32, h: f32 },
        radii: struct { tl: f32 = 36.74, tr: f32 = 36.74, br: f32 = 36.74, bl: f32 = 36.74 } = .{},
        rotate: f32 = 0,
        use_draw_transform: bool = true,
        draw_transform: [6]f32 = .{ 1, 0, 0, 1, 349.954, 249.456 },
        draw_x: f32 = 0,
        draw_y: f32 = 0,
        draw_w: f32 = 128.09,
        draw_h: f32 = 77.49,
    };
    const src = Item{ .geom = .{ .x = -2, .y = -2, .w = 128.09, .h = 77.49 } };
    const scale: f32 = 2;
    const al = alignTranslationSurface(src, scale, .{ 0, 0 });
    try std.testing.expectApproxEqAbs(@round(al.draw_transform[4] * scale), al.draw_transform[4] * scale, 0.001);
    const used_w: u32 = @intFromFloat(@ceil(al.geom.w * scale));
    const used_h: u32 = @intFromFloat(@ceil(al.geom.h * scale));
    const Layer = struct { w: f32, h: f32, draw_x: f32 = 0, draw_y: f32 = 0, draw_w: f32 = 0, draw_h: f32 = 0, used_tex_w: u32, used_tex_h: u32, alloc_tex_w: u32, alloc_tex_h: u32, quad: [4]f32 };
    const layer = Layer{
        .w = al.geom.w,
        .h = al.geom.h,
        .used_tex_w = used_w,
        .used_tex_h = used_h,
        .alloc_tex_w = 320,
        .alloc_tex_h = 192,
        .quad = .{ src.geom.x - al.geom.x, src.geom.y - al.geom.y, src.geom.w, src.geom.h },
    };
    const cq = compositeQuad(layer, scale, al.draw_transform);
    // the quad sits exactly where the unaligned layer was
    try std.testing.expectApproxEqAbs(src.draw_transform[4], cq.transform[4], 1e-4);
    try std.testing.expectApproxEqAbs(src.draw_transform[5], cq.transform[5], 1e-4);
    try std.testing.expectApproxEqAbs(src.geom.w, cq.w, 1e-4);
    // a target pixel centre maps to a texel centre: texel = (pixel - aligned origin)
    for ([_]f32{ 700.5, 720.5, 954.5 }) |px| {
        const along = (px / scale - cq.transform[4]) / cq.w; // 0..1 across the quad
        const texel = (cq.uv[0] + along * (cq.uv[2] - cq.uv[0])) * 320;
        try std.testing.expectApproxEqAbs(@floor(texel) + 0.5, texel, 0.002);
    }
}

test "raster content key preserves the non-cacheable sentinel" {
    const bounds = [4]f32{ -2, -2, 228, 100 };
    try std.testing.expectEqual(@as(u64, 0), rasterContentHash(0, bounds, 1.75));
    try std.testing.expect(rasterContentHash(42, bounds, 1.75) != rasterContentHash(42, bounds, 2));
}

test "rounded clip at a fractional origin: texture on the pixel grid, mask on the original rect" {
    // Settled notification card at 1x: GlassBox content clip (radius 18) at a fractional
    // surface origin. Composited unaligned, every glyph inside went through a half-pixel
    // bilinear resample.
    const Item = struct {
        geom: struct { x: f32, y: f32, w: f32, h: f32 },
        rotate: f32 = 0,
        use_draw_transform: bool = true,
        draw_transform: [6]f32 = .{ 1, 0, 0, 1, 354.3, 861.6 },
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
    };
    const src = Item{ .geom = .{ .x = 0, .y = 0, .w = 392, .h = 117 } };
    const al = alignTranslationSurface(src, 1, .{ 0, 0 });
    try std.testing.expectEqual(@as(f32, 354), al.draw_transform[4]);
    try std.testing.expectEqual(@as(f32, 861), al.draw_transform[5]);
    const q = maskQuad(src, al);
    // mask origin in the world is unchanged: aligned origin + quad offset = source origin
    try std.testing.expectApproxEqAbs(src.draw_transform[4], al.draw_transform[4] + q[0], 1e-4);
    try std.testing.expectApproxEqAbs(src.draw_transform[5], al.draw_transform[5] + q[1], 1e-4);
    try std.testing.expectEqual(src.geom.w, q[2]);
    try std.testing.expectEqual(src.geom.h, q[3]);
    // already on the grid: nothing moves, whole-layer mask
    const grid = Item{ .geom = .{ .x = 0, .y = 0, .w = 392, .h = 117 }, .draw_transform = .{ 1, 0, 0, 1, 354, 861 } };
    const same = alignTranslationSurface(grid, 1, .{ 0, 0 });
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, maskQuad(grid, same));
}
