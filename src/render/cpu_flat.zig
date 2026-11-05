//! CPU raster of the encoder's own instance batches into a damage patch
//! (native/macos/cpu_flat.inc). The encoder routes `flushAllPending` here when
//! a CPU target is set, so geometry, clipping and colour come from exactly the
//! instances the GPU would draw. Unsupported instances fail the whole patch;
//! the caller then renders the frame on the GPU. Ported from the
//! cooperative-frame experiment (drawable targets replaced by patches).
const std = @import("std");

extern fn metal_cpu_flat_damage_rect(*anyopaque, ?*const [4]u32) c_int;
extern fn metal_cpu_flat_rect_rounded(*anyopaque, *const [4]f32, *const [4]f32, *const [4]f32, *const [4]f32, c_uint, *const [4]f32, f32) c_int;
extern fn metal_cpu_flat_border_rect(*anyopaque, *const [4]f32, *const [4]f32, *const [4]f32, *const [4]f32, f32, *const [4]f32, *const [4]f32, f32) c_int;
extern fn metal_cpu_flat_glyph(*anyopaque, *const anyopaque, *anyopaque, f32, u32) c_int;
extern fn metal_cpu_flat_shadow(*anyopaque, *const [4]f32, *const [4]f32, *const [4]f32, *const [4]f32, f32, f32, f32, f32, *const [4]f32, f32) c_int;
extern fn metal_cpu_flat_icon(*anyopaque, *const anyopaque, *anyopaque, f32) c_int;
extern fn metal_cpu_flat_rect_stops(*anyopaque, *const [4]f32, *const [4]f32, *const anyopaque, c_uint, c_uint, *const [4]f32, f32) c_int;
extern fn metal_cpu_flat_rounded_shape_clip(*anyopaque, *const [4]f32, *const [4]f32, f32, bool) c_int;

/// Physical write scissor within the patch (null: the whole patch).
pub fn setDamage(target: *anyopaque, rect: ?[4]u32) !void {
    const value = rect;
    if (metal_cpu_flat_damage_rect(target, if (value) |*v| v else null) != 0) return error.CpuDamageUnavailable;
}

fn supportedClip(renderer: anytype) bool {
    // The raster applies one rounded shape clip; a partner (shape_clip_pair.zig) declines.
    if (renderer.clip2.kind != 0) return false;
    if (renderer.clip_shape_kind == 0) return true;
    if (renderer.clip_shape_kind != 1) return false;
    for (renderer.clip_radii) |r| if (!std.math.isFinite(r) or r < 0) return false;
    return true;
}

// `raster` false: check the batch is supported and consume it without
// drawing (a validation pass before the patch raster; the native raster can
// still decline a glyph or icon format it alone inspects).
//
// Per-renderer flushes mirror the encoder's GPU flush granularity
// (flushAllPending / flushIfTextPending / flushIfIconPending), so batches are
// drawn in exactly the GPU's order. Any error fails the whole patch; the caller
// then renders on the GPU, so partial writes are never presented.

/// Rasterize and consume the pending SDF batch.
pub fn flushSdf(target: *anyopaque, sdf: anytype, raster: bool) !void {
    if (sdf.instances.items.len == 0) return;
    if (!supportedClip(sdf)) return error.CpuFlatUnsupportedClip;
    if (raster and metal_cpu_flat_rounded_shape_clip(target, &sdf.clip_rect, &sdf.clip_radii, sdf.scale_factor, sdf.clip_shape_kind == 1) != 0)
        return error.CpuFlatUnsupportedClip;
    for (sdf.instances.items) |*inst| {
        if (inst.shadow_blur > 0) {
            // Single outer shadow (bit 28: spread in noise_scale) under a plain fill.
            const spread_flag: u32 = 1 << 28;
            var bordered = inst.border_width != 0;
            for (inst.border_widths) |width| bordered = bordered or width != 0;
            if (inst.shape_type != 0 or inst.packed_flags & ~spread_flag != 0 or inst.gradient_stop_count != 0 or bordered)
                return error.CpuFlatUnsupportedSdf;
            const spread = if (inst.packed_flags & spread_flag != 0) inst.noise_scale else 0;
            if (raster and metal_cpu_flat_shadow(target, &inst.rect, &inst.corner_radii, &inst.fill_color, &inst.shadow_color, inst.shadow_blur, inst.shadow_offset_x, inst.shadow_offset_y, spread, &inst.rect_clip, sdf.scale_factor) != 0)
                return error.CpuFlatRasterFailure;
            continue;
        }
        if (inst.gradient_stop_count != 0) {
            // Multi-stop linear PAD gradient fill: no border/shadow/noise.
            var bordered = inst.border_width != 0;
            for (inst.border_widths) |width| bordered = bordered or width != 0;
            const direction = inst.packed_flags & 0xff;
            if (inst.shape_type != 0 or inst.packed_flags > 3 or direction == 0 or bordered or inst.shadow_color[3] != 0 or
                inst.gradient_stop_offset + inst.gradient_stop_count > sdf.grad_stops.items.len)
                return error.CpuFlatUnsupportedSdf;
            const stops = sdf.grad_stops.items[inst.gradient_stop_offset..][0..inst.gradient_stop_count];
            if (raster and metal_cpu_flat_rect_stops(target, &inst.rect, &inst.corner_radii, @ptrCast(stops.ptr), @intCast(stops.len), direction, &inst.rect_clip, sdf.scale_factor) != 0)
                return error.CpuFlatUnsupportedSdf;
            continue;
        }
        if (inst.shape_type != 0 or inst.shadow_blur != 0 or
            inst.packed_flags > 3 or inst.shadow_color[3] != 0 or
            inst.shadow_offset_x != 0 or inst.shadow_offset_y != 0)
            return error.CpuFlatUnsupportedSdf;
        var bordered = inst.border_width != 0;
        for (inst.border_widths) |width| bordered = bordered or width != 0;
        if (bordered) {
            if (inst.packed_flags != 0) return error.CpuFlatUnsupportedBorderGradient;
            if (raster and metal_cpu_flat_border_rect(target, &inst.rect, &inst.corner_radii, &inst.fill_color, &inst.border_color, inst.border_width, &inst.border_widths, &inst.rect_clip, sdf.scale_factor) != 0)
                return error.CpuFlatRasterFailure;
            continue;
        }
        if (raster and metal_cpu_flat_rect_rounded(target, &inst.rect, &inst.corner_radii, &inst.fill_color, &inst.gradient_to_color, inst.packed_flags, &inst.rect_clip, sdf.scale_factor) != 0)
            return error.CpuFlatRasterFailure;
    }
    sdf.instances.clearRetainingCapacity();
}

/// Rasterize and consume the pending icon batch (null renderer: nothing).
pub fn flushIcons(target: *anyopaque, icons: anytype, raster: bool) !void {
    const ir = icons orelse return;
    if (ir.instances.items.len == 0) return;
    if (ir.clip_shape_kind > 1 or ir.clip2.kind != 0) return error.CpuFlatUnsupportedClip;
    if (raster and metal_cpu_flat_rounded_shape_clip(target, &ir.clip_rect, &ir.clip_radii, ir.scale_factor, ir.clip_shape_kind == 1) != 0)
        return error.CpuFlatUnsupportedClip;
    for (ir.instances.items, ir.instance_texture_ids.items) |*inst, id| {
        if (id >= ir.textures.items.len) return error.CpuFlatMissingAtlas;
        const slot = ir.textures.items[id] orelse return error.CpuFlatMissingAtlas;
        if (!raster) continue;
        switch (metal_cpu_flat_icon(target, inst, @ptrCast(slot.texture.raw), ir.scale_factor)) {
            0 => {},
            4 => return error.OutOfMemory,
            else => return error.CpuFlatUnsupportedIcon,
        }
    }
    ir.instances.clearRetainingCapacity();
    ir.instance_texture_ids.clearRetainingCapacity();
    ir.pending_generation +%= 1;
}

/// Rasterize and consume the pending glyph batch.
pub fn flushText(target: *anyopaque, text: anytype, raster: bool) !void {
    if (text.instances_linear.items.len > 0) return error.CpuFlatUnsupportedLinearText;
    if (text.instances_nearest.items.len == 0) return;
    if (!supportedClip(text)) return error.CpuFlatUnsupportedClip;
    if (raster and metal_cpu_flat_rounded_shape_clip(target, &text.clip_rect, &text.clip_radii, text.scale_factor, text.clip_shape_kind == 1) != 0)
        return error.CpuFlatUnsupportedClip;
    for (text.instances_nearest.items) |*inst| {
        const page: u8 = @truncate(inst.metadata.flags & 255);
        const atlas = text.atlas.getPageTexture(page) orelse return error.CpuFlatMissingAtlas;
        if (!raster) continue;
        switch (metal_cpu_flat_glyph(target, inst, @ptrCast(atlas.raw), text.scale_factor, text.atlas.gc_generation)) {
            0 => {},
            1 => return error.CpuFlatUnsupportedGlyphFormat,
            2 => return error.CpuFlatUnsupportedGlyphClip,
            3 => return error.CpuFlatUnsupportedGlyphGeometry,
            4 => return error.OutOfMemory,
            else => return error.CpuFlatGlyphRasterFailure,
        }
    }
    text.instances_nearest.clearRetainingCapacity();
    text.pending_generation +%= 1;
}

/// Paint-item level admission for items a patch must draw. Icons are admitted
/// here when snapped and unrotated; the raster still rejects a mask that does
/// not land 1:1 on the pixel grid. Clips may be rect
/// or rounded rect; single outer box shadows are drawn; effects, images,
/// paths, dual/inset shadows and noise are rejected.
pub fn supportedItem(item: anytype) bool {
    if (item.use_draw_transform or item.blend_mode != 0) return false;
    return switch (item.kind) {
        .none => true,
        .rect, .gradient => blk: {
            if (!std.math.isFinite(item.stroke_width) or item.stroke_width < 0 or item.noise_intensity != 0 or
                item.shadow_blur != 0 or item.shape_kind != 0) break :blk false;
            var bordered = item.stroke_width > 0;
            for (item.border_widths) |width| {
                if (!std.math.isFinite(width) or width < 0) break :blk false;
                bordered = bordered or width > 0;
            }
            if (bordered and item.kind == .gradient) break :blk false;
            if (item.kind == .gradient and (item.gradient_direction > 2 or item.gradient_extend_mode != 0 or item.mg_stop_count > 16)) break :blk false;
            break :blk true;
        },
        .image => item.icon_rep_ptr != null and item.icon_snap and item.rotate == 0 and item.icon_corner_clip_radius == 0 and
            item.image_opacity >= 0 and item.image_opacity <= 1,
        .shadow => item.shadow_blur > 0 and std.math.isFinite(item.shadow_blur) and item.shape_kind == 0 and
            item.shadow2_color.a == 0 and item.shadow_secondary_color.a == 0 and item.noise_mode == 0 and item.stroke_width == 0,
        .text => std.math.isFinite(item.text_fade_dx0) and std.math.isFinite(item.text_fade_dx1) and
            item.text_raster_policy == 0,
        .control => switch (item.control_kind) {
            .push_clip => item.clip_shape_kind <= 1,
            .pop_clip => true,
            else => false,
        },
        else => false,
    };
}

test "a validation flush checks clips and consumes batches without touching the target" {
    const Inst = struct {
        shape_type: u32 = 0,
        shadow_blur: f32 = 0,
        packed_flags: u32 = 0,
        shadow_color: [4]f32 = .{ 0, 0, 0, 0 },
        shadow_offset_x: f32 = 0,
        shadow_offset_y: f32 = 0,
        gradient_stop_count: u32 = 0,
        gradient_stop_offset: u32 = 0,
        border_width: f32 = 0,
        border_widths: [4]f32 = .{ 0, 0, 0, 0 },
        noise_scale: f32 = 0,
        rect: [4]f32 = .{ 0, 0, 10, 10 },
        corner_radii: [4]f32 = .{ 0, 0, 0, 0 },
        fill_color: [4]f32 = .{ 1, 1, 1, 1 },
        gradient_to_color: [4]f32 = .{ 1, 1, 1, 1 },
        border_color: [4]f32 = .{ 0, 0, 0, 0 },
        rect_clip: [4]f32 = .{ 0, 0, -1, -1 },
    };
    const Sdf = struct {
        instances: std.ArrayList(Inst) = .empty,
        grad_stops: std.ArrayList(u32) = .empty,
        clip_shape_kind: u32 = 1,
        clip_radii: [4]f32 = .{ 10, 10, 10, 10 },
        clip_rect: [4]f32 = .{ 0, 0, 100, 100 },
        clip2: struct { kind: u32 = 0 } = .{},
        scale_factor: f32 = 2,
    };
    const a = std.testing.allocator;
    var sdf: Sdf = .{};
    defer sdf.instances.deinit(a);
    // A raster would dereference it.
    const bogus: *anyopaque = @ptrFromInt(0x10);
    try sdf.instances.append(a, .{});
    try sdf.instances.append(a, .{ .border_width = 1 });
    try flushSdf(bogus, &sdf, false);
    try std.testing.expectEqual(@as(usize, 0), sdf.instances.items.len);
    // A crossing pair of shape clips is declined before any drawing.
    sdf.clip2.kind = 1;
    try sdf.instances.append(a, .{});
    try std.testing.expectError(error.CpuFlatUnsupportedClip, flushSdf(bogus, &sdf, false));
    // Unsupported instance features are found the same way.
    sdf.clip2.kind = 0;
    sdf.instances.items[0].shape_type = 3;
    try std.testing.expectError(error.CpuFlatUnsupportedSdf, flushSdf(bogus, &sdf, false));
}
