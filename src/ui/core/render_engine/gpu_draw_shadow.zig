//! GpuDraw shadow encoding (Stage B-1).
//!
//! At paint pass end, run display_list -> GpuDraw lowering once and assert trivial structural
//! equivalence with the main path product. Debug build only.
//!
//! Goal: without changing the main path, verify display_item_encode loses no info in real scenes,
//! paving the way for Stage B-2/B-3 to land GpuDraw in the main path.
//!
//! Current assertion granularity: drawable command count (push_clip/pop_clip/begin_*_layer etc.
//! are control flow, skipped by lowering and become scissor/blend mode in GpuDraw; that needs
//! state machine rebuild, deferred). Later stages will deepen assertions (pipeline id sequence,
//! texture handle match, batch run length, etc.).

const std = @import("std");
const display_list_mod = @import("../display_list.zig");
const paint_table_mod = @import("../paint_table.zig");
const display_item_encode = @import("../display_item_encode.zig");
const gpu_draw_mod = @import("../gpu_draw.zig");

pub const DisplayItem = display_list_mod.DisplayItem;
pub const PaintItem = paint_table_mod.DisplayItem;
pub const PaintItemKind = paint_table_mod.DisplayItemKind;
pub const GpuDraw = gpu_draw_mod.GpuDraw;

/// Downgrade display_list's union DisplayItem to paint_table's simplified struct for
/// display_item_encode.encodeStream. Output now carries geom (x/y/w/h) + color + radii so
/// shadow path and cx.syncPaintToTable writes to PaintTable are **field-wise identical**,
/// basis for content validation when encoder switches to paint_table.DisplayItem.
pub fn lowerDisplayItem(item: DisplayItem) PaintItem {
    const kind: PaintItemKind = switch (item) {
        .fill_rect, .stroke_rect, .border_side, .border_per_side, .outline_rect, .noise_rect => .rect,
        .text_run => .text,
        .image_quad, .icon_rep => .image,
        .fill_path, .stroke_path, .arc => .path,
        .shadow_rect, .inset_shadow_rect, .shadow_dual_rect => .shadow,
        .gradient_rect, .multi_gradient_rect => .gradient,
        .push_clip, .pop_clip, .begin_opacity_layer, .end_opacity_layer, .begin_blur_layer, .end_blur_layer, .begin_rounded_clip, .end_rounded_clip => .control,
    };
    // resource_handle only meaningful for text/image/icon; rest 0
    const resource: u64 = switch (item) {
        .text_run => |t| t.blob_id,
        .image_quad => |i| i.texture_id,
        .icon_rep => |i| i.icon_id,
        else => 0,
    };
    // geom + color + radii + local_bounds: rect-family kind extracts full geometry/color
    var out: PaintItem = .{ .kind = kind, .resource_handle = resource };
    switch (item) {
        .fill_rect => |r| {
            out.local_bounds = .{ .min_x = r.x, .min_y = r.y, .max_x = r.x + r.w, .max_y = r.y + r.h };
            out.geom = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
            out.color = .{ .r = r.color.r, .g = r.color.g, .b = r.color.b, .a = r.color.a };
            out.radii = .{ .tl = r.radius[0], .tr = r.radius[1], .br = r.radius[2], .bl = r.radius[3] };
            out.shape_kind = r.shape;
        },
        .stroke_rect => |r| {
            out.local_bounds = .{ .min_x = r.x, .min_y = r.y, .max_x = r.x + r.w, .max_y = r.y + r.h };
            out.geom = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
            out.color = .{ .r = r.color.r, .g = r.color.g, .b = r.color.b, .a = r.color.a };
            out.radii = .{ .tl = r.radius[0], .tr = r.radius[1], .br = r.radius[2], .bl = r.radius[3] };
            out.stroke_width = r.width;
            out.shape_kind = r.shape;
        },
        .border_side => |b| {
            out.local_bounds = .{ .min_x = b.x, .min_y = b.y, .max_x = b.x + b.w, .max_y = b.y + b.h };
            out.geom = .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
            out.color = .{ .r = b.color.r, .g = b.color.g, .b = b.color.b, .a = b.color.a };
            out.radii = .{ .tl = b.radius[0], .tr = b.radius[1], .br = b.radius[2], .bl = b.radius[3] };
            out.stroke_width = b.width;
        },
        .border_per_side => |b| {
            out.local_bounds = .{ .min_x = b.x, .min_y = b.y, .max_x = b.x + b.w, .max_y = b.y + b.h };
            out.geom = .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
            out.color = .{ .r = b.color.r, .g = b.color.g, .b = b.color.b, .a = b.color.a };
            out.radii = .{ .tl = b.radius[0], .tr = b.radius[1], .br = b.radius[2], .bl = b.radius[3] };
            out.border_widths = b.widths;
        },
        .outline_rect => |o| {
            out.local_bounds = .{ .min_x = o.x, .min_y = o.y, .max_x = o.x + o.w, .max_y = o.y + o.h };
            out.geom = .{ .x = o.x, .y = o.y, .w = o.w, .h = o.h };
            out.color = .{ .r = o.color.r, .g = o.color.g, .b = o.color.b, .a = o.color.a };
            out.radii = .{ .tl = o.radius[0], .tr = o.radius[1], .br = o.radius[2], .bl = o.radius[3] };
            out.stroke_width = o.width;
        },
        .shadow_rect => |s| {
            out.local_bounds = .{ .min_x = s.x, .min_y = s.y, .max_x = s.x + s.w, .max_y = s.y + s.h };
            out.geom = .{ .x = s.x, .y = s.y, .w = s.w, .h = s.h };
            out.color = .{ .r = s.color.r, .g = s.color.g, .b = s.color.b, .a = s.color.a };
            // radius must pass through, else shadow always right-angle rectangle (rounded node
            // shows
            // rectangular chunks at corners)
            out.radii = .{ .tl = s.radius[0], .tr = s.radius[1], .br = s.radius[2], .bl = s.radius[3] };
            out.shadow_blur = s.blur;
            out.shadow_offset_x = s.offset_x;
            out.shadow_offset_y = s.offset_y;
            out.shadow_spread = s.spread;
        },
        .text_run => |t| {
            out.local_bounds = .{ .min_x = t.x, .min_y = t.y, .max_x = t.x + 1, .max_y = t.y + 1 };
            out.geom = .{ .x = t.x, .y = t.y, .w = 0, .h = 0 };
            out.color = .{ .r = t.color.r, .g = t.color.g, .b = t.color.b, .a = t.color.a };
            out.text_font_size = t.font_size;
            out.text_font_weight = t.font_weight;
            out.text_font_family = t.font_family;
            var flags: u8 = 0;
            if (t.use_italic_font) flags |= paint_table_mod.TextFontFlag.italic;
            if (t.use_monospace_font) flags |= paint_table_mod.TextFontFlag.monospace;
            if (t.use_symbols_font) flags |= paint_table_mod.TextFontFlag.symbols;
            if (!t.font_smoothing) flags |= paint_table_mod.TextFontFlag.no_smoothing;
            out.text_font_flags = flags;
            out.text_monospace_char_width = t.monospace_char_width;
            out.text_blob_byte_start = t.blob_byte_start;
            out.text_blob_byte_end = t.blob_byte_end;
            out.text_content = t.content;
            out.text_spans = t.spans;
            // Three-state pass as-is (exhaustive: new strategy must explicitly pick wire value).
            // Was collapsed to 0/1 here, encoder never got surface_cached; source of
            // "policy name does not guarantee cached semantics". Don't revert.
            out.text_raster_policy = switch (t.raster_policy) {
                .static_crisp => 0,
                .animated_stable => 1,
                .surface_cached => 2,
            };
            out.text_fade_dx0 = t.fade_dx0;
            out.text_fade_dx1 = t.fade_dx1;
        },
        .image_quad => |i| {
            out.local_bounds = .{ .min_x = i.x, .min_y = i.y, .max_x = i.x + i.w, .max_y = i.y + i.h };
            out.geom = .{ .x = i.x, .y = i.y, .w = i.w, .h = i.h };
            out.image_opacity = i.opacity;
            out.image_tint = .{ .r = i.tint.r, .g = i.tint.g, .b = i.tint.b, .a = i.tint.a };
            out.image_corner_radius = i.corner_radius;
            out.rotate = i.rotate;
        },
        .icon_rep => |ic| {
            out.local_bounds = .{ .min_x = ic.x, .min_y = ic.y, .max_x = ic.x + ic.w, .max_y = ic.y + ic.h };
            out.geom = .{ .x = ic.x, .y = ic.y, .w = ic.w, .h = ic.h };
            out.image_opacity = ic.opacity;
            out.icon_tint = .{ .r = ic.tint.r, .g = ic.tint.g, .b = ic.tint.b, .a = ic.tint.a };
            out.icon_corner_clip_radius = ic.corner_clip_radius;
            out.icon_rep_size = ic.rep_size;
            out.icon_snap = ic.snap;
            out.rotate = ic.rotate;
            // icon_rep_ptr from cx.lowerForEncoderPaintTable indexes from source ArrayList
            // (captured ic is
            // stack temporary, &ic.rep becomes invalid)
        },
        .multi_gradient_rect => |mg| {
            out.local_bounds = .{ .min_x = mg.x, .min_y = mg.y, .max_x = mg.x + mg.w, .max_y = mg.y + mg.h };
            out.geom = .{ .x = mg.x, .y = mg.y, .w = mg.w, .h = mg.h };
            out.radii = .{ .tl = mg.radius[0], .tr = mg.radius[1], .br = mg.radius[2], .bl = mg.radius[3] };
            out.gradient_direction = @backingInt(mg.direction);
            out.gradient_extend_mode = @backingInt(mg.extend_mode);
            out.gradient_radial_center_x = mg.radial_center_x;
            out.gradient_radial_center_y = mg.radial_center_y;
            out.gradient_radial_radius_x = mg.radial_radius_x;
            out.gradient_radial_radius_y = mg.radial_radius_y;
            out.gradient_conic_start_angle = mg.conic_start_angle;
            out.shape_kind = mg.shape;
            out.mg_stop_count = mg.stop_count;
            for (0..mg.stop_count) |i| {
                out.mg_stop_colors[i] = .{
                    .r = mg.stop_colors[i].r,
                    .g = mg.stop_colors[i].g,
                    .b = mg.stop_colors[i].b,
                    .a = mg.stop_colors[i].a,
                };
                out.mg_stop_positions[i] = mg.stop_positions[i];
            }
        },
        .fill_path => |fp| {
            out.color = .{ .r = fp.color.r, .g = fp.color.g, .b = fp.color.b, .a = fp.color.a };
            out.geom = .{ .x = fp.offset_x, .y = fp.offset_y, .w = 0, .h = 0 };
            out.image_opacity = fp.opacity;
            // fp.geometry already *const PathGeometry pointing to stable heap object held by scene
            // runtime (not stack value), safe to copy directly
            out.path_geometry_ptr = fp.geometry;
            // gradient reuses existing mg_* slots on PaintItem (same as multi_gradient_rect),
            // encoder
            // reads these fields uniformly.
            out.gradient_direction = fp.gradient_direction;
            out.mg_stop_count = fp.gradient_stop_count;
            for (0..@min(@as(usize, fp.gradient_stop_count), 16)) |i| {
                out.mg_stop_colors[i] = .{
                    .r = fp.gradient_stop_colors[i].r,
                    .g = fp.gradient_stop_colors[i].g,
                    .b = fp.gradient_stop_colors[i].b,
                    .a = fp.gradient_stop_colors[i].a,
                };
                out.mg_stop_positions[i] = fp.gradient_stop_positions[i];
            }
            out.gradient_radial_center_x = fp.gradient_center_x;
            out.gradient_radial_center_y = fp.gradient_center_y;
            out.gradient_conic_start_angle = fp.gradient_start_angle;
        },
        .stroke_path => |sp| {
            out.color = .{ .r = sp.color.r, .g = sp.color.g, .b = sp.color.b, .a = sp.color.a };
            out.geom = .{ .x = sp.offset_x, .y = sp.offset_y, .w = 0, .h = 0 };
            out.image_opacity = sp.opacity;
            out.stroke_width = sp.width;
            out.path_line_join = @backingInt(sp.line_join);
            out.path_geometry_ptr = sp.geometry;
        },
        .gradient_rect => |g| {
            out.local_bounds = .{ .min_x = g.x, .min_y = g.y, .max_x = g.x + g.w, .max_y = g.y + g.h };
            out.geom = .{ .x = g.x, .y = g.y, .w = g.w, .h = g.h };
            out.color = .{ .r = g.from.r, .g = g.from.g, .b = g.from.b, .a = g.from.a };
            out.gradient_to_color = .{ .r = g.to.r, .g = g.to.g, .b = g.to.b, .a = g.to.a };
            out.radii = .{ .tl = g.radius[0], .tr = g.radius[1], .br = g.radius[2], .bl = g.radius[3] };
            out.gradient_direction = @backingInt(g.direction);
            out.gradient_extend_mode = @backingInt(g.extend_mode);
            out.gradient_radial_center_x = g.radial_center_x;
            out.gradient_radial_center_y = g.radial_center_y;
            out.gradient_conic_start_angle = g.conic_start_angle;
            out.shape_kind = g.shape;
        },
        .noise_rect => |nr| {
            out.local_bounds = .{ .min_x = nr.x, .min_y = nr.y, .max_x = nr.x + nr.w, .max_y = nr.y + nr.h };
            out.geom = .{ .x = nr.x, .y = nr.y, .w = nr.w, .h = nr.h };
            out.color = .{ .r = nr.fill.r, .g = nr.fill.g, .b = nr.fill.b, .a = nr.fill.a };
            out.radii = .{ .tl = nr.radius[0], .tr = nr.radius[1], .br = nr.radius[2], .bl = nr.radius[3] };
            out.noise_mode = nr.mode;
            out.noise_scale = nr.scale;
            out.noise_intensity = nr.intensity;
            out.noise_seed = nr.seed;
        },
        .inset_shadow_rect => |is| {
            out.local_bounds = .{ .min_x = is.x, .min_y = is.y, .max_x = is.x + is.w, .max_y = is.y + is.h };
            out.geom = .{ .x = is.x, .y = is.y, .w = is.w, .h = is.h };
            out.color = .{ .r = is.fill.r, .g = is.fill.g, .b = is.fill.b, .a = is.fill.a };
            out.radii = .{ .tl = is.radius[0], .tr = is.radius[1], .br = is.radius[2], .bl = is.radius[3] };
            out.shadow_secondary_color = .{ .r = is.shadow_color.r, .g = is.shadow_color.g, .b = is.shadow_color.b, .a = is.shadow_color.a };
            out.shadow_blur = is.blur;
            out.shadow_offset_x = is.offset_x;
            out.shadow_offset_y = is.offset_y;
        },
        .shadow_dual_rect => |sd| {
            out.local_bounds = .{ .min_x = sd.x, .min_y = sd.y, .max_x = sd.x + sd.w, .max_y = sd.y + sd.h };
            out.geom = .{ .x = sd.x, .y = sd.y, .w = sd.w, .h = sd.h };
            out.color = .{ .r = sd.fill.r, .g = sd.fill.g, .b = sd.fill.b, .a = sd.fill.a };
            out.radii = .{ .tl = sd.radius[0], .tr = sd.radius[1], .br = sd.radius[2], .bl = sd.radius[3] };
            out.shadow_secondary_color = .{ .r = sd.shadow1_color.r, .g = sd.shadow1_color.g, .b = sd.shadow1_color.b, .a = sd.shadow1_color.a };
            out.shadow_blur = sd.shadow1_blur;
            out.shadow_offset_x = sd.shadow1_offset_x;
            out.shadow_offset_y = sd.shadow1_offset_y;
            out.shadow2_color = .{ .r = sd.shadow2_color.r, .g = sd.shadow2_color.g, .b = sd.shadow2_color.b, .a = sd.shadow2_color.a };
            out.shadow2_blur = sd.shadow2_blur;
            out.shadow2_offset_x = sd.shadow2_offset_x;
            out.shadow2_offset_y = sd.shadow2_offset_y;
        },
        .arc => |ar| {
            // arc geometry has no rect bounds, use (cx-r, cy-r, 2r, 2r) as conservative AABB
            const r = ar.outer_radius;
            out.local_bounds = .{ .min_x = ar.cx - r, .min_y = ar.cy - r, .max_x = ar.cx + r, .max_y = ar.cy + r };
            out.geom = .{ .x = ar.cx, .y = ar.cy, .w = 0, .h = 0 };
            out.color = .{ .r = ar.color.r, .g = ar.color.g, .b = ar.color.b, .a = ar.color.a };
            out.stroke_width = ar.stroke_width;
            out.arc_outer_radius = ar.outer_radius;
            out.arc_start_angle = ar.start_angle;
            out.arc_end_angle = ar.end_angle;
        },
        // B-7-C: 8 control kinds, kind = .control + control_kind distinguishes token
        .push_clip => |pc| {
            out.geom = .{ .x = pc.x, .y = pc.y, .w = pc.w, .h = pc.h };
            out.radii = .{ .tl = pc.radii[0], .tr = pc.radii[1], .br = pc.radii[2], .bl = pc.radii[3] };
            out.control_kind = .push_clip;
            out.clip_shape_kind = @backingInt(pc.shape_kind);
            // polygon shape field via cx.lowerForEncoderPaintTable allocs
            // paint_table.ClipPolygonMirror
            // copy in frame_arena, writes extra_ptr (B-7 main path switch). Here lowerDisplayItem
            // is stateless
            // fn, no alloc; shadow path does not read polygon yet.
        },
        .pop_clip => {
            out.control_kind = .pop_clip;
        },
        .begin_opacity_layer => |bo| {
            out.geom = .{ .x = bo.x, .y = bo.y, .w = bo.w, .h = bo.h };
            out.radii = .{ .tl = bo.corner_radii[0], .tr = bo.corner_radii[1], .br = bo.corner_radii[2], .bl = bo.corner_radii[3] };
            out.opacity = bo.opacity;
            out.rotate = bo.rotate;
            out.draw_x = bo.draw_x;
            out.draw_y = bo.draw_y;
            out.draw_w = bo.draw_w;
            out.draw_h = bo.draw_h;
            out.use_draw_transform = bo.use_draw_transform;
            out.surface_rest_origin = bo.surface_rest_origin;
            out.draw_transform = .{
                bo.draw_transform.a,  bo.draw_transform.b,
                bo.draw_transform.c,  bo.draw_transform.d,
                bo.draw_transform.tx, bo.draw_transform.ty,
            };
            out.blend_mode = @backingInt(bo.blend_mode);
            out.warp = bo.warp;
            out.surface_stable_id = bo.surface_stable_id;
            out.surface_content_version = bo.surface_content_version;
            out.control_kind = .begin_opacity_layer;
        },
        .end_opacity_layer => {
            out.control_kind = .end_opacity_layer;
        },
        .begin_blur_layer => |bb| {
            out.glass_owner_id = bb.owner_node;
            out.geom = .{ .x = bb.x, .y = bb.y, .w = bb.w, .h = bb.h };
            out.radii = .{ .tl = bb.corner_radii[0], .tr = bb.corner_radii[1], .br = bb.corner_radii[2], .bl = bb.corner_radii[3] };
            out.rotate = bb.rotate;
            out.draw_x = bb.draw_x;
            out.draw_y = bb.draw_y;
            out.draw_w = bb.draw_w;
            out.draw_h = bb.draw_h;
            out.use_draw_transform = bb.use_draw_transform;
            out.surface_rest_origin = bb.surface_rest_origin;
            out.draw_transform = .{
                bb.draw_transform.a,  bb.draw_transform.b,
                bb.draw_transform.c,  bb.draw_transform.d,
                bb.draw_transform.tx, bb.draw_transform.ty,
            };
            out.control_kind = .begin_blur_layer;
            // glass: ResolvedGlassParams via cx.lowerForEncoderPaintTable allocs
            // paint_table.GlassParamsMirror copy in frame_arena, writes extra_ptr (B-7 main path
            // switch).
            // lowerDisplayItem stateless, no alloc.
        },
        .end_blur_layer => {
            out.control_kind = .end_blur_layer;
        },
        .begin_rounded_clip => |br| {
            out.geom = .{ .x = br.x, .y = br.y, .w = br.w, .h = br.h };
            out.radii = .{ .tl = br.radii[0], .tr = br.radii[1], .br = br.radii[2], .bl = br.radii[3] };
            out.rotate = br.rotate;
            out.draw_x = br.draw_x;
            out.draw_y = br.draw_y;
            out.draw_w = br.draw_w;
            out.draw_h = br.draw_h;
            out.use_draw_transform = br.use_draw_transform;
            out.surface_rest_origin = br.surface_rest_origin;
            out.draw_transform = .{
                br.draw_transform.a,  br.draw_transform.b,
                br.draw_transform.c,  br.draw_transform.d,
                br.draw_transform.tx, br.draw_transform.ty,
            };
            out.control_kind = .begin_rounded_clip;
        },
        .end_rounded_clip => {
            out.control_kind = .end_rounded_clip;
        },
    }
    return out;
}

pub const ShadowResult = struct {
    /// display_list total items
    display_item_count: usize,
    /// drawable commands in lowering_buffer (control flow not counted)
    drawable_command_count: usize,
    /// GpuDraw count after instance batching (<= display_item_count)
    gpu_draw_count: usize,
    /// Equivalence: display_item_count == drawable_command_count (lowering is 1:1)
    counts_match: bool,
    /// pipeline sequence equivalence: display_list lowering pipeline id sequence matches caller's
    /// drawable command pipeline id sequence exactly. Computed only when counts_match and caller
    /// supplies sequence; else false.
    pipelines_match: bool,
    /// longest mergeable batch run (same pipeline + same blend + same texture consecutive span)
    max_batch_run: u32,
    /// field value equivalence check: paint_table.DisplayItem geom (x/y/w/h) matches
    /// display_list fill_rect (x/y/w/h) field. Fail = lowerDisplayItem field mapping bug
    /// (future rename / type change catch). 0 = all pass; > 0 = count of fill_rect lowering
    /// field mismatch.
    field_value_mismatches: u32,
};

/// main entry: lowering + encode from display_list, return structural equivalence info.
/// caller responsible for out_draws capacity >= display_items.len. expected_pipelines (optional):
/// drawable command pipeline id sequence; when provided, compute pipelines_match field.
pub fn encodeShadow(
    display_items: []const DisplayItem,
    drawable_render_commands: usize,
    out_draws: []GpuDraw,
    expected_pipelines: ?[]const display_item_encode.PipelineId,
) ShadowResult {
    const n = display_items.len;
    if (n == 0) {
        return .{
            .display_item_count = 0,
            .drawable_command_count = drawable_render_commands,
            .gpu_draw_count = 0,
            .counts_match = drawable_render_commands == 0,
            .pipelines_match = if (expected_pipelines) |ep| ep.len == 0 else false,
            .max_batch_run = 0,
            .field_value_mismatches = 0,
        };
    }
    std.debug.assert(out_draws.len >= n);

    // field equivalence self-check: paint_table.DisplayItem.geom should match display_list
    // each kind's (x,y,w,h) field.
    var field_mismatches: u32 = 0;
    for (display_items) |it| {
        const lowered = lowerDisplayItem(it);
        const expected_geom: ?struct { x: f32, y: f32, w: f32, h: f32 } = switch (it) {
            .fill_rect => |r| .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h },
            .stroke_rect => |r| .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h },
            .border_side => |b| .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h },
            .border_per_side => |b| .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h },
            .outline_rect => |o| .{ .x = o.x, .y = o.y, .w = o.w, .h = o.h },
            .shadow_rect => |s| .{ .x = s.x, .y = s.y, .w = s.w, .h = s.h },
            .gradient_rect => |g| .{ .x = g.x, .y = g.y, .w = g.w, .h = g.h },
            .image_quad => |im| .{ .x = im.x, .y = im.y, .w = im.w, .h = im.h },
            .noise_rect => |nr| .{ .x = nr.x, .y = nr.y, .w = nr.w, .h = nr.h },
            .inset_shadow_rect => |is| .{ .x = is.x, .y = is.y, .w = is.w, .h = is.h },
            .shadow_dual_rect => |sd| .{ .x = sd.x, .y = sd.y, .w = sd.w, .h = sd.h },
            else => null,
        };
        if (expected_geom) |e| {
            if (lowered.geom.x != e.x or lowered.geom.y != e.y or
                lowered.geom.w != e.w or lowered.geom.h != e.h)
            {
                field_mismatches += 1;
            }
        }
    }

    // Lower all items
    var lowered_buf: [256]PaintItem = undefined;
    var total_draws: usize = 0;
    var max_run: u32 = 0;
    if (n <= lowered_buf.len) {
        for (display_items, 0..) |it, i| {
            lowered_buf[i] = lowerDisplayItem(it);
        }
        total_draws = display_item_encode.encodeStream(lowered_buf[0..n], 0, out_draws);
        max_run = display_item_encode.maxBatchableRun(lowered_buf[0..n], 0);
    } else {
        // When > stack buffer, process in segments (don't merge cross-segment batches, conservative
        // early approach)
        var i: usize = 0;
        while (i < n) {
            const chunk = @min(lowered_buf.len, n - i);
            for (display_items[i .. i + chunk], 0..) |it, k| {
                lowered_buf[k] = lowerDisplayItem(it);
            }
            total_draws += display_item_encode.encodeStream(
                lowered_buf[0..chunk],
                0,
                out_draws[total_draws..],
            );
            const run = display_item_encode.maxBatchableRun(lowered_buf[0..chunk], 0);
            if (run > max_run) max_run = run;
            i += chunk;
        }
    }

    const counts_match = n == drawable_render_commands;
    const pipelines_match = if (expected_pipelines) |ep| blk: {
        if (!counts_match or ep.len != n) break :blk false;
        for (display_items, 0..) |it, idx| {
            const lowered_kind = lowerDisplayItem(it).kind;
            const lowered_pl = display_item_encode.pipelineForKind(lowered_kind);
            if (lowered_pl != ep[idx]) break :blk false;
        }
        break :blk true;
    } else false;

    return .{
        .display_item_count = n,
        .drawable_command_count = drawable_render_commands,
        .gpu_draw_count = total_draws,
        .counts_match = counts_match,
        .pipelines_match = pipelines_match,
        .field_value_mismatches = field_mismatches,
        .max_batch_run = max_run,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const types = @import("../types.zig");
const Color = types.Color;

fn dummyHeader() display_list_mod.ItemHeader {
    return .{ .transform_id = 0, .node_id = 0 };
}

test "lowerDisplayItem: 渐变的 shape 透传（椭圆的渐变不能铺满包围盒）" {
    // gradient uses .gradient kind, separate lowering branch from fill_rect. shape omitted =>
    // ellipse/circle gradient drawn as gradient-fill bbox.
    var mg: DisplayItem = .{ .multi_gradient_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 200,
        .h = 400,
        .stop_count = 2,
        .shape = 1,
    } };
    mg.multi_gradient_rect.stop_colors[0] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    mg.multi_gradient_rect.stop_colors[1] = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    try testing.expectEqual(@as(u8, 1), lowerDisplayItem(mg).shape_kind);

    const g: DisplayItem = .{ .gradient_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 200,
        .h = 400,
        .from = Color.WHITE,
        .to = Color.BLACK,
        .shape = 1,
    } };
    try testing.expectEqual(@as(u8, 1), lowerDisplayItem(g).shape_kind);
}

test "lowerDisplayItem: fill_rect/stroke_rect 的 shape 透传（椭圆不能退回矩形）" {
    // shape omitted = ellipse silently drawn as rounded_rect ("capsule" when aspect ratio large),
    // while layer/geometry assertions all pass; this assertion targets that silent-fail point.
    const fill: DisplayItem = .{ .fill_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 200,
        .h = 60,
        .color = Color.WHITE,
        .shape = 1,
    } };
    try testing.expectEqual(@as(u8, 1), lowerDisplayItem(fill).shape_kind);

    const stroke: DisplayItem = .{ .stroke_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 200,
        .h = 60,
        .color = Color.WHITE,
        .width = 2,
        .shape = 1,
    } };
    try testing.expectEqual(@as(u8, 1), lowerDisplayItem(stroke).shape_kind);

    // default must be 0 (rounded_rect), existing callers not writing shape unchanged
    const plain: DisplayItem = .{ .fill_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
        .color = Color.WHITE,
    } };
    try testing.expectEqual(@as(u8, 0), lowerDisplayItem(plain).shape_kind);
}

test "lowerDisplayItem: fill_rect → rect kind" {
    const item: DisplayItem = .{ .fill_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
        .color = Color.WHITE,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.rect, lowered.kind);
}

test "lowerDisplayItem: fill_rect 字段无损 (geom + color + radii)" {
    const item: DisplayItem = .{ .fill_rect = .{
        .header = dummyHeader(),
        .x = 12.5,
        .y = 7.25,
        .w = 100,
        .h = 50,
        .color = .{ .r = 200, .g = 150, .b = 100, .a = 255 },
        .radius = .{ 4, 8, 16, 0 },
    } };
    const lowered = lowerDisplayItem(item);
    // verify lowerDisplayItem lossless, true takeover has no info loss
    try testing.expectEqual(@as(f32, 12.5), lowered.geom.x);
    try testing.expectEqual(@as(f32, 7.25), lowered.geom.y);
    try testing.expectEqual(@as(f32, 100), lowered.geom.w);
    try testing.expectEqual(@as(f32, 50), lowered.geom.h);
    try testing.expectEqual(@as(u8, 200), lowered.color.r);
    try testing.expectEqual(@as(u8, 150), lowered.color.g);
    try testing.expectEqual(@as(u8, 100), lowered.color.b);
    try testing.expectEqual(@as(u8, 255), lowered.color.a);
    try testing.expectEqual(@as(f32, 4), lowered.radii.tl);
    try testing.expectEqual(@as(f32, 8), lowered.radii.tr);
    try testing.expectEqual(@as(f32, 16), lowered.radii.br);
    try testing.expectEqual(@as(f32, 0), lowered.radii.bl);
}

test "lowerDisplayItem: shadow_rect 字段无损 (geom + color + blur + offset)" {
    const item: DisplayItem = .{ .shadow_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 50,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 128 },
        .blur = 12,
        .offset_x = 2,
        .offset_y = 4,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.shadow, lowered.kind);
    try testing.expectEqual(@as(f32, 100), lowered.geom.w);
    try testing.expectEqual(@as(u8, 128), lowered.color.a);
    // B-5+ extended fields lossless
    try testing.expectEqual(@as(f32, 12), lowered.shadow_blur);
    try testing.expectEqual(@as(f32, 2), lowered.shadow_offset_x);
    try testing.expectEqual(@as(f32, 4), lowered.shadow_offset_y);
}

test "lowerDisplayItem: stroke_rect 字段无损 (geom + color + radii + width)" {
    const item: DisplayItem = .{ .stroke_rect = .{
        .header = dummyHeader(),
        .x = 5,
        .y = 10,
        .w = 100,
        .h = 50,
        .color = .{ .r = 50, .g = 100, .b = 150, .a = 200 },
        .width = 2.5,
        .radius = .{ 4, 4, 4, 4 },
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.rect, lowered.kind);
    try testing.expectEqual(@as(f32, 2.5), lowered.stroke_width);
    try testing.expectEqual(@as(f32, 4), lowered.radii.tl);
}

test "lowerDisplayItem: border_per_side 字段无损 (widths)" {
    const item: DisplayItem = .{ .border_per_side = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 50,
        .color = .{ .r = 100, .g = 100, .b = 100, .a = 255 },
        .widths = .{ 1, 2, 3, 4 },
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(@as(f32, 1), lowered.border_widths[0]);
    try testing.expectEqual(@as(f32, 2), lowered.border_widths[1]);
    try testing.expectEqual(@as(f32, 3), lowered.border_widths[2]);
    try testing.expectEqual(@as(f32, 4), lowered.border_widths[3]);
}

test "lowerDisplayItem: image_quad 字段无损 (geom + opacity)" {
    const item: DisplayItem = .{ .image_quad = .{
        .header = dummyHeader(),
        .x = 100,
        .y = 50,
        .w = 64,
        .h = 64,
        .texture_id = 42,
        .opacity = 0.75,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.image, lowered.kind);
    try testing.expectEqual(@as(u64, 42), lowered.resource_handle);
    try testing.expectEqual(@as(f32, 0.75), lowered.image_opacity);
}

test "lowerDisplayItem: gradient_rect 字段无损 (from + to + direction + extend)" {
    const item: DisplayItem = .{ .gradient_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 50,
        .from = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .to = .{ .r = 0, .g = 0, .b = 255, .a = 255 },
        .direction = .diagonal,
        .extend_mode = .reflect,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.gradient, lowered.kind);
    try testing.expectEqual(@as(u8, 255), lowered.color.r);
    try testing.expectEqual(@as(u8, 255), lowered.gradient_to_color.b);
    // diagonal = 2, reflect = 2
    try testing.expectEqual(@as(u8, 2), lowered.gradient_direction);
    try testing.expectEqual(@as(u8, 2), lowered.gradient_extend_mode);
}

test "lowerDisplayItem: text_run 字段无损 (font + flags + blob range)" {
    const item: DisplayItem = .{ .text_run = .{
        .header = dummyHeader(),
        .x = 10,
        .y = 20,
        .content = "hello",
        .color = Color.WHITE,
        .font_size = 14,
        .font_weight = 700,
        .use_italic_font = true,
        .use_monospace_font = true,
        .blob_id = 5,
        .blob_byte_start = 0,
        .blob_byte_end = 5,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.text, lowered.kind);
    try testing.expectEqual(@as(f32, 14), lowered.text_font_size);
    try testing.expectEqual(@as(u16, 700), lowered.text_font_weight);
    // italic + monospace bit 0 + 1 = 3
    try testing.expect((lowered.text_font_flags & paint_table_mod.TextFontFlag.italic) != 0);
    try testing.expect((lowered.text_font_flags & paint_table_mod.TextFontFlag.monospace) != 0);
    try testing.expectEqual(@as(u32, 5), lowered.text_blob_byte_end);
}

test "lowerDisplayItem: noise_rect 字段无损 (mode + scale + intensity + seed)" {
    const item: DisplayItem = .{ .noise_rect = .{
        .header = dummyHeader(),
        .x = 5,
        .y = 6,
        .w = 80,
        .h = 40,
        .fill = .{ .r = 100, .g = 110, .b = 120, .a = 255 },
        .mode = 2,
        .scale = 3.5,
        .intensity = 0.12,
        .seed = 7,
        .radius = .{ 4, 4, 4, 4 },
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.rect, lowered.kind);
    try testing.expectEqual(@as(f32, 5), lowered.geom.x);
    try testing.expectEqual(@as(f32, 80), lowered.geom.w);
    try testing.expectEqual(@as(u8, 100), lowered.color.r);
    try testing.expectEqual(@as(u8, 2), lowered.noise_mode);
    try testing.expectEqual(@as(f32, 3.5), lowered.noise_scale);
    try testing.expectEqual(@as(f32, 0.12), lowered.noise_intensity);
    try testing.expectEqual(@as(u8, 7), lowered.noise_seed);
    try testing.expectEqual(@as(f32, 4), lowered.radii.tl);
}

test "lowerDisplayItem: push_clip rect → control kind + clip_shape_kind=0" {
    const item: DisplayItem = .{ .push_clip = .{
        .header = dummyHeader(),
        .x = 10,
        .y = 20,
        .w = 100,
        .h = 50,
        .radii = .{ 8, 8, 8, 8 },
        .shape_kind = .rect,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.control, lowered.kind);
    try testing.expectEqual(paint_table_mod.ControlKind.push_clip, lowered.control_kind);
    try testing.expectEqual(@as(u8, 0), lowered.clip_shape_kind);
    try testing.expectApproxEqAbs(@as(f32, 10), lowered.geom.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8), lowered.radii.tl, 0.001);
    // rect shape clip_polygon_ptr from cx.lowerForEncoderPaintTable indexes source ArrayList
    // (lowerDisplayItem layer does not set), unit test expects null
    try testing.expect(lowered.clip_polygon_ptr == null);
}

test "lowerDisplayItem: push_clip rounded_rect keeps each corner radius (TL, TR, BR, BL)" {
    const item: DisplayItem = .{ .push_clip = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 120,
        .h = 32,
        .radii = .{ 8, 0, 3, 5 },
        .shape_kind = .rounded_rect,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(@as(u8, 1), lowered.clip_shape_kind);
    try testing.expectEqual(@as(f32, 8), lowered.radii.tl);
    try testing.expectEqual(@as(f32, 0), lowered.radii.tr);
    try testing.expectEqual(@as(f32, 3), lowered.radii.br);
    try testing.expectEqual(@as(f32, 5), lowered.radii.bl);
}

test "lowerDisplayItem: push_clip polygon → control_kind/clip_shape_kind 标识" {
    var item: DisplayItem = .{ .push_clip = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 50,
        .h = 50,
        .shape_kind = .polygon,
    } };
    var polygon: display_list_mod.ClipPolygon = .{};
    polygon.point_count = 3;
    polygon.points[0] = .{ 0, 0 };
    polygon.points[1] = .{ 50, 0 };
    polygon.points[2] = .{ 25, 50 };
    item.push_clip.polygon = &polygon;
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(paint_table_mod.ControlKind.push_clip, lowered.control_kind);
    try testing.expectEqual(@as(u8, 3), lowered.clip_shape_kind);
    // clip_polygon_ptr not set at lowerDisplayItem stage, written by cx.lowerForEncoderPaintTable
}

test "lowerDisplayItem: pop_clip / end_*_layer / end_rounded_clip → control_kind only" {
    const items = [_]DisplayItem{
        .{ .pop_clip = .{ .header = dummyHeader() } },
        .{ .end_opacity_layer = .{ .header = dummyHeader() } },
        .{ .end_blur_layer = .{ .header = dummyHeader() } },
        .{ .end_rounded_clip = .{ .header = dummyHeader() } },
    };
    const expected = [_]paint_table_mod.ControlKind{
        .pop_clip, .end_opacity_layer, .end_blur_layer, .end_rounded_clip,
    };
    for (items, expected) |it, exp| {
        const lowered = lowerDisplayItem(it);
        try testing.expectEqual(PaintItemKind.control, lowered.kind);
        try testing.expectEqual(exp, lowered.control_kind);
    }
}

test "lowerDisplayItem: begin_opacity_layer 字段无损 (geom + opacity + draw_transform + blend_mode)" {
    const types_mod = @import("../types.zig");
    const item: DisplayItem = .{ .begin_opacity_layer = .{
        .header = dummyHeader(),
        .x = 10,
        .y = 20,
        .w = 100,
        .h = 80,
        .opacity = 0.5,
        .rotate = 0.25,
        .use_draw_transform = true,
        .draw_transform = types_mod.Transform2D{ .a = 1.5, .b = 0, .c = 0, .d = 1.5, .tx = 5, .ty = 6 },
        .blend_mode = .multiply,
        .warp = .{ 6, 2, 4, 14 },
        .corner_radii = .{ 0, 12, 12, 0 },
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(paint_table_mod.ControlKind.begin_opacity_layer, lowered.control_kind);
    // Folded rounded clip mask keeps per-corner radii (attached group item: square left side).
    try testing.expectEqual(@as(f32, 0), lowered.radii.tl);
    try testing.expectEqual(@as(f32, 12), lowered.radii.tr);
    try testing.expectEqual(@as(f32, 12), lowered.radii.br);
    try testing.expectEqual(@as(f32, 0), lowered.radii.bl);
    try testing.expectEqual([4]f32{ 6, 2, 4, 14 }, lowered.warp);
    try testing.expectApproxEqAbs(@as(f32, 0.5), lowered.opacity, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.5), lowered.draw_transform[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), lowered.draw_transform[4], 0.001);
    try testing.expect(lowered.use_draw_transform);
    // multiply position in BlendMode (see types.zig:611) = 1
    try testing.expect(lowered.blend_mode != 0);
}

test "lowerDisplayItem: begin_blur_layer extra_ptr 透传 source variant" {
    const item: DisplayItem = .{ .begin_blur_layer = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 200,
        .h = 100,
        .corner_radii = .{ 12, 12, 12, 12 },
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(paint_table_mod.ControlKind.begin_blur_layer, lowered.control_kind);
    try testing.expectApproxEqAbs(@as(f32, 12), lowered.radii.tl, 0.001);
    // glass_ptr written by cx.lowerForEncoderPaintTable (lowerDisplayItem does not set)
}

test "lowerDisplayItem: begin_blur_layer 四角半径逐角透传（同心圆角玻璃）" {
    const item: DisplayItem = .{ .begin_blur_layer = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 60,
        .h = 60,
        .corner_radii = .{ 12, 0, 0, 0 },
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectApproxEqAbs(@as(f32, 12), lowered.radii.tl, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), lowered.radii.bl, 0.001);
}

test "lowerDisplayItem: begin_blur_layer never substitutes a uniform radius for odd corners" {
    // A negative / NaN first corner used to read as the old "uniform" sentinel and turn the glass
    // into an all-round shape while the owner's clip and hit shape kept the four corners. The
    // lowering passes the corners through untouched; the encoder normalises them.
    const item: DisplayItem = .{ .begin_blur_layer = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 40,
        .corner_radii = .{ -4, 20, 0, 0 },
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(@as(f32, -4), lowered.radii.tl);
    try testing.expectEqual(@as(f32, 20), lowered.radii.tr);
    try testing.expectEqual(@as(f32, 0), lowered.radii.br);
    try testing.expectEqual(@as(f32, 0), lowered.radii.bl);
}

test "lowerDisplayItem: begin_rounded_clip 字段无损 (geom + radius + draw fields)" {
    const types_mod = @import("../types.zig");
    const item: DisplayItem = .{ .begin_rounded_clip = .{
        .header = dummyHeader(),
        .x = 5,
        .y = 6,
        .w = 80,
        .h = 60,
        .radii = .{ 10, 0, 0, 10 },
        .rotate = 0,
        .draw_x = 1,
        .draw_y = 2,
        .draw_w = 80,
        .draw_h = 60,
        .use_draw_transform = false,
        .draw_transform = types_mod.Transform2D.identity(),
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(paint_table_mod.ControlKind.begin_rounded_clip, lowered.control_kind);
    try testing.expectApproxEqAbs(@as(f32, 10), lowered.radii.tl, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), lowered.radii.tr, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), lowered.radii.br, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), lowered.radii.bl, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), lowered.draw_x, 0.001);
    try testing.expectEqual(false, lowered.use_draw_transform);
}

test "lowerDisplayItem: inset_shadow_rect 字段无损 (fill + shadow_color + blur + offset)" {
    const item: DisplayItem = .{ .inset_shadow_rect = .{
        .header = dummyHeader(),
        .x = 1,
        .y = 2,
        .w = 50,
        .h = 30,
        .fill = .{ .r = 200, .g = 200, .b = 200, .a = 255 },
        .shadow_color = .{ .r = 0, .g = 0, .b = 0, .a = 128 },
        .blur = 8,
        .offset_x = 2,
        .offset_y = 3,
        .radius = .{ 6, 6, 6, 6 },
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.shadow, lowered.kind);
    try testing.expectEqual(@as(u8, 200), lowered.color.r);
    try testing.expectEqual(@as(u8, 128), lowered.shadow_secondary_color.a);
    try testing.expectApproxEqAbs(@as(f32, 8), lowered.shadow_blur, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2), lowered.shadow_offset_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 6), lowered.radii.tl, 0.001);
}

test "lowerDisplayItem: shadow_dual_rect 字段无损 (fill + shadow1 + shadow2)" {
    const item: DisplayItem = .{ .shadow_dual_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 50,
        .fill = .{ .r = 250, .g = 250, .b = 250, .a = 255 },
        .shadow1_color = .{ .r = 0, .g = 0, .b = 0, .a = 64 },
        .shadow1_blur = 4,
        .shadow1_offset_x = 0,
        .shadow1_offset_y = 1,
        .shadow2_color = .{ .r = 0, .g = 0, .b = 0, .a = 32 },
        .shadow2_blur = 12,
        .shadow2_offset_x = 0,
        .shadow2_offset_y = 4,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.shadow, lowered.kind);
    try testing.expectEqual(@as(u8, 250), lowered.color.r);
    // shadow1 uses secondary slot
    try testing.expectEqual(@as(u8, 64), lowered.shadow_secondary_color.a);
    try testing.expectApproxEqAbs(@as(f32, 4), lowered.shadow_blur, 0.001);
    // shadow2 separate slot
    try testing.expectEqual(@as(u8, 32), lowered.shadow2_color.a);
    try testing.expectApproxEqAbs(@as(f32, 12), lowered.shadow2_blur, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4), lowered.shadow2_offset_y, 0.001);
}

test "lowerDisplayItem: arc 字段无损 (center + radius + stroke + angle)" {
    const item: DisplayItem = .{ .arc = .{
        .header = dummyHeader(),
        .cx = 50,
        .cy = 60,
        .outer_radius = 20,
        .stroke_width = 2,
        .start_angle = 0,
        .end_angle = std.math.pi,
        .color = .{ .r = 200, .g = 50, .b = 100, .a = 255 },
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.path, lowered.kind);
    // geom.x/y = center
    try testing.expectApproxEqAbs(@as(f32, 50), lowered.geom.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 60), lowered.geom.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), lowered.arc_outer_radius, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2), lowered.stroke_width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi), lowered.arc_end_angle, 0.001);
    try testing.expectEqual(@as(u8, 200), lowered.color.r);
    // local_bounds is (cx-r, cy-r, 2r, 2r) AABB
    try testing.expectApproxEqAbs(@as(f32, 30), lowered.local_bounds.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 80), lowered.local_bounds.max_y, 0.001);
}

test "lowerDisplayItem: multi_gradient_rect 字段无损 (4 stops + radial center + extend)" {
    var item: DisplayItem = .{ .multi_gradient_rect = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 100,
        .h = 50,
        .direction = .radial,
        .radius = .{ 6, 6, 6, 6 },
        .stop_count = 4,
        .radial_center_x = 0.25,
        .radial_center_y = 0.5,
        .extend_mode = .repeat,
    } };
    item.multi_gradient_rect.stop_colors[0] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    item.multi_gradient_rect.stop_colors[1] = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    item.multi_gradient_rect.stop_colors[2] = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    item.multi_gradient_rect.stop_colors[3] = .{ .r = 255, .g = 255, .b = 0, .a = 200 };
    item.multi_gradient_rect.stop_positions[0] = 0;
    item.multi_gradient_rect.stop_positions[1] = 0.33;
    item.multi_gradient_rect.stop_positions[2] = 0.66;
    item.multi_gradient_rect.stop_positions[3] = 1.0;
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.gradient, lowered.kind);
    try testing.expectEqual(@as(u8, 4), lowered.mg_stop_count);
    try testing.expectEqual(@as(u8, 255), lowered.mg_stop_colors[0].r);
    try testing.expectEqual(@as(u8, 200), lowered.mg_stop_colors[3].a);
    try testing.expectApproxEqAbs(@as(f32, 0.33), lowered.mg_stop_positions[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), lowered.gradient_radial_center_x, 0.001);
    // radial = 3, repeat = 1
    try testing.expectEqual(@as(u8, 3), lowered.gradient_direction);
    try testing.expectEqual(@as(u8, 1), lowered.gradient_extend_mode);
}

test "lowerDisplayItem: icon_rep → image kind, extra_ptr 透传 *const Rep" {
    const icon_ir_mod = @import("icon_ir");
    const rep: icon_ir_mod.Rep = .{ .size = 24, .shapes = &.{} };
    const item: DisplayItem = .{ .icon_rep = .{
        .header = dummyHeader(),
        .icon_id = 42,
        .rep_size = 24,
        .rep = rep,
        .x = 10,
        .y = 20,
        .w = 24,
        .h = 24,
        .tint = .{ .r = 200, .g = 100, .b = 50, .a = 255 },
        .corner_clip_radius = 4,
        .opacity = 0.8,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.image, lowered.kind);
    try testing.expectEqual(@as(u64, 42), lowered.resource_handle);
    try testing.expectEqual(@as(u8, 24), lowered.icon_rep_size);
    try testing.expectEqual(@as(u8, 200), lowered.icon_tint.r);
    try testing.expectApproxEqAbs(@as(f32, 4), lowered.icon_corner_clip_radius, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), lowered.image_opacity, 0.001);
    // icon_rep_ptr written by cx.lowerForEncoderPaintTable (lowerDisplayItem does not set)
}

test "lowerDisplayItem: fill_path / stroke_path → path kind, extra_ptr 透传 *const PathGeometry" {
    const types_mod = @import("../types.zig");
    const geo: types_mod.PathGeometry = .{ .commands = &.{} };
    const fill_item: DisplayItem = .{ .fill_path = .{
        .header = dummyHeader(),
        .geometry = &geo,
        .color = .{ .r = 50, .g = 100, .b = 150, .a = 255 },
        .offset_x = 5,
        .offset_y = 6,
        .opacity = 0.5,
    } };
    const fill_lo = lowerDisplayItem(fill_item);
    try testing.expectEqual(PaintItemKind.path, fill_lo.kind);
    try testing.expectEqual(@as(f32, 5), fill_lo.geom.x);
    try testing.expectEqual(@as(u8, 100), fill_lo.color.g);
    try testing.expectApproxEqAbs(@as(f32, 0.5), fill_lo.image_opacity, 0.001);
    try testing.expect(fill_lo.path_geometry_ptr != null);

    const stroke_item: DisplayItem = .{ .stroke_path = .{
        .header = dummyHeader(),
        .geometry = &geo,
        .color = .{ .r = 200, .g = 0, .b = 0, .a = 255 },
        .width = 2.5,
        .line_join = .round,
        .offset_x = 1,
        .offset_y = 2,
    } };
    const stroke_lo = lowerDisplayItem(stroke_item);
    try testing.expectEqual(PaintItemKind.path, stroke_lo.kind);
    try testing.expectApproxEqAbs(@as(f32, 2.5), stroke_lo.stroke_width, 0.001);
    // miter=0, bevel=1, round=2
    try testing.expectEqual(@as(u8, 2), stroke_lo.path_line_join);
}

test "lowerDisplayItem: text_run → text kind, resource = blob_id" {
    const item: DisplayItem = .{ .text_run = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .content = "hi",
        .color = Color.WHITE,
        .font_size = 12,
        .blob_id = 42,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.text, lowered.kind);
    try testing.expectEqual(@as(u64, 42), lowered.resource_handle);
}

test "lowerDisplayItem: image_quad → image kind, resource = texture_id" {
    const item: DisplayItem = .{ .image_quad = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
        .texture_id = 7,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.image, lowered.kind);
    try testing.expectEqual(@as(u64, 7), lowered.resource_handle);
}

test "encodeShadow: empty input" {
    const items: []const DisplayItem = &.{};
    var out: [1]GpuDraw = undefined;
    const r = encodeShadow(items, 0, &out, null);
    try testing.expectEqual(@as(usize, 0), r.display_item_count);
    try testing.expectEqual(@as(usize, 0), r.gpu_draw_count);
    try testing.expect(r.counts_match);
    try testing.expectEqual(@as(u32, 0), r.max_batch_run);
    try testing.expectEqual(@as(u32, 0), r.field_value_mismatches);
}

test "encodeShadow: field_value_mismatches == 0 for fill_rect/text/image mix" {
    const items = [_]DisplayItem{
        .{ .fill_rect = .{ .header = dummyHeader(), .x = 1.5, .y = 2.25, .w = 10, .h = 20, .color = Color.WHITE } },
        .{ .text_run = .{ .header = dummyHeader(), .x = 5, .y = 8, .content = "x", .color = Color.WHITE, .font_size = 12 } },
        .{ .image_quad = .{ .header = dummyHeader(), .x = 100, .y = 50, .w = 64, .h = 64, .texture_id = 1 } },
        .{ .shadow_rect = .{ .header = dummyHeader(), .x = 0, .y = 0, .w = 100, .h = 100, .color = Color.WHITE, .blur = 4, .offset_x = 1, .offset_y = 1 } },
    };
    var out: [4]GpuDraw = undefined;
    const r = encodeShadow(&items, 4, &out, null);
    // field equivalence = 0, lowerDisplayItem field mapping correct
    try testing.expectEqual(@as(u32, 0), r.field_value_mismatches);
}

test "encodeShadow: 3 fill_rect → batched to 1 GpuDraw, max_run=3" {
    const items = [_]DisplayItem{
        .{ .fill_rect = .{ .header = dummyHeader(), .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.WHITE } },
        .{ .fill_rect = .{ .header = dummyHeader(), .x = 10, .y = 0, .w = 10, .h = 10, .color = Color.WHITE } },
        .{ .fill_rect = .{ .header = dummyHeader(), .x = 20, .y = 0, .w = 10, .h = 10, .color = Color.WHITE } },
    };
    var out: [3]GpuDraw = undefined;
    const r = encodeShadow(&items, 3, &out, null);
    try testing.expectEqual(@as(usize, 3), r.display_item_count);
    try testing.expectEqual(@as(usize, 1), r.gpu_draw_count); // batched
    try testing.expect(r.counts_match); // 3 items vs 3 drawable commands
    try testing.expectEqual(@as(u32, 3), r.max_batch_run);
}

test "encodeShadow: counts mismatch when display != drawable" {
    const items = [_]DisplayItem{
        .{ .fill_rect = .{ .header = dummyHeader(), .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.WHITE } },
    };
    var out: [1]GpuDraw = undefined;
    const r = encodeShadow(&items, 5, &out, null);
    try testing.expect(!r.counts_match);
    try testing.expect(!r.pipelines_match);
}

test "encodeShadow: pipelines_match when pipeline sequence matches" {
    const items = [_]DisplayItem{
        .{ .fill_rect = .{ .header = dummyHeader(), .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.WHITE } },
        .{ .text_run = .{ .header = dummyHeader(), .x = 0, .y = 0, .content = "x", .color = Color.WHITE, .font_size = 12 } },
        .{ .image_quad = .{ .header = dummyHeader(), .x = 0, .y = 0, .w = 10, .h = 10, .texture_id = 1 } },
    };
    var out: [3]GpuDraw = undefined;
    // expected sequence: rect(1), text(2), image(3), matches pipelineForKind
    const expected = [_]display_item_encode.PipelineId{ 1, 2, 3 };
    const r = encodeShadow(&items, 3, &out, &expected);
    try testing.expect(r.counts_match);
    try testing.expect(r.pipelines_match);
}

test "encodeShadow: pipelines_match false when sequence diverges" {
    const items = [_]DisplayItem{
        .{ .fill_rect = .{ .header = dummyHeader(), .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.WHITE } },
    };
    var out: [1]GpuDraw = undefined;
    // expected text(2) but got rect(1)
    const expected = [_]display_item_encode.PipelineId{2};
    const r = encodeShadow(&items, 1, &out, &expected);
    try testing.expect(r.counts_match);
    try testing.expect(!r.pipelines_match);
}

test "encodeShadow: max_batch_run reflects longest same-kind run" {
    const items = [_]DisplayItem{
        .{ .fill_rect = .{ .header = dummyHeader(), .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.WHITE } },
        .{ .text_run = .{ .header = dummyHeader(), .x = 0, .y = 0, .content = "x", .color = Color.WHITE, .font_size = 12 } },
        .{ .text_run = .{ .header = dummyHeader(), .x = 0, .y = 0, .content = "y", .color = Color.WHITE, .font_size = 12 } },
        .{ .text_run = .{ .header = dummyHeader(), .x = 0, .y = 0, .content = "z", .color = Color.WHITE, .font_size = 12 } },
        .{ .fill_rect = .{ .header = dummyHeader(), .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.WHITE } },
    };
    var out: [5]GpuDraw = undefined;
    const r = encodeShadow(&items, 5, &out, null);
    try testing.expectEqual(@as(u32, 3), r.max_batch_run); // 3 text_run consecutive segments
}
