//! Stage B-1: GpuDraw shadow encoding
//!
//! 在 paint pass 末尾跑一遍 display_list -> GpuDraw 的 lowering，与主路径产物
//! 做 trivial 结构等价断言。debug build only。
//!
//! 目标：在不改主路径的前提下，验证 display_item_encode 在真场景下不丢信息，
//! 为后续 Stage B-2/B-3 把 GpuDraw 真正接入主路径铺路。
//!
//! 当前断言粒度：drawable command count 等价（push_clip/pop_clip/begin_*_layer
//! 等控制流不算 drawable，会被 lowering 跳过，它们在 GpuDraw 层会变成 scissor
//! 或 blend mode 字段，需要状态机重建，本阶段不做）。
//!
//! 后续阶段会逐步加深断言（pipeline id 序列、texture handle 一致、batch run 长度等）。

const std = @import("std");
const display_list_mod = @import("../display_list.zig");
const paint_table_mod = @import("../paint_table.zig");
const display_item_encode = @import("../display_item_encode.zig");
const gpu_draw_mod = @import("../gpu_draw.zig");

pub const DisplayItem = display_list_mod.DisplayItem;
pub const PaintItem = paint_table_mod.DisplayItem;
pub const PaintItemKind = paint_table_mod.DisplayItemKind;
pub const GpuDraw = gpu_draw_mod.GpuDraw;

/// 把主路径 display_list 的 union DisplayItem 降级为 paint_table 的简化 struct，
/// 给 display_item_encode.encodeStream 消费。
///
/// 输出现在带 geom (x/y/w/h) + color + radii，让
/// shadow 路径与 cx.syncPaintToTable 写入的 PaintTable 数据**逐字段等价**，
/// 为后续 encoder 切到 paint_table.DisplayItem 真接管做内容验证基础。
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
    // resource_handle 仅 text/image/icon 有意义；其余 0
    const resource: u64 = switch (item) {
        .text_run => |t| t.blob_id,
        .image_quad => |i| i.texture_id,
        .icon_rep => |i| i.icon_id,
        else => 0,
    };
    // geom + color + radii + local_bounds: rect-family kind 提取完整几何/颜色信息
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
            // radius 必须透传，否则外阴影恒为直角矩形（圆角节点四角露出矩形切块）
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
            out.text_font_flags = flags;
            out.text_monospace_char_width = t.monospace_char_width;
            out.text_blob_byte_start = t.blob_byte_start;
            out.text_blob_byte_end = t.blob_byte_end;
            out.text_content = t.content;
            out.text_spans = t.spans;
            // 三态原样过线（exhaustive：新增策略必须显式选 wire 值）。
            // 曾在此折叠成 0/1，encoder 因此永远拿不到 surface_cached，那是
            // "policy 名称不保证 cached 语义" 的源头，勿回退。
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
            out.rotate = ic.rotate;
            // icon_rep_ptr 由 cx.lowerForEncoderPaintTable 从 source ArrayList 索引取地址
            // (capture-by-value 的 ic 是栈临时，&ic.rep 会失效)
        },
        .multi_gradient_rect => |mg| {
            out.local_bounds = .{ .min_x = mg.x, .min_y = mg.y, .max_x = mg.x + mg.w, .max_y = mg.y + mg.h };
            out.geom = .{ .x = mg.x, .y = mg.y, .w = mg.w, .h = mg.h };
            out.radii = .{ .tl = mg.radius[0], .tr = mg.radius[1], .br = mg.radius[2], .bl = mg.radius[3] };
            out.gradient_direction = @intFromEnum(mg.direction);
            out.gradient_extend_mode = @intFromEnum(mg.extend_mode);
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
            // fp.geometry 已是 *const PathGeometry，指向 scene runtime 持有的稳定堆对象
            // (不是栈值地址)，安全直接复制
            out.path_geometry_ptr = fp.geometry;
            // 渐变复用 PaintItem 上既有的 mg_* 槽位（与 multi_gradient_rect
            // 同一套），encoder 侧统一读这些字段。
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
            out.path_line_join = @intFromEnum(sp.line_join);
            out.path_geometry_ptr = sp.geometry;
        },
        .gradient_rect => |g| {
            out.local_bounds = .{ .min_x = g.x, .min_y = g.y, .max_x = g.x + g.w, .max_y = g.y + g.h };
            out.geom = .{ .x = g.x, .y = g.y, .w = g.w, .h = g.h };
            out.color = .{ .r = g.from.r, .g = g.from.g, .b = g.from.b, .a = g.from.a };
            out.gradient_to_color = .{ .r = g.to.r, .g = g.to.g, .b = g.to.b, .a = g.to.a };
            out.radii = .{ .tl = g.radius[0], .tr = g.radius[1], .br = g.radius[2], .bl = g.radius[3] };
            out.gradient_direction = @intFromEnum(g.direction);
            out.gradient_extend_mode = @intFromEnum(g.extend_mode);
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
            // arc 几何无 rect bounds，用 (cx-r, cy-r, 2r, 2r) 作 conservative AABB
            const r = ar.outer_radius;
            out.local_bounds = .{ .min_x = ar.cx - r, .min_y = ar.cy - r, .max_x = ar.cx + r, .max_y = ar.cy + r };
            out.geom = .{ .x = ar.cx, .y = ar.cy, .w = 0, .h = 0 };
            out.color = .{ .r = ar.color.r, .g = ar.color.g, .b = ar.color.b, .a = ar.color.a };
            out.stroke_width = ar.stroke_width;
            out.arc_outer_radius = ar.outer_radius;
            out.arc_start_angle = ar.start_angle;
            out.arc_end_angle = ar.end_angle;
        },
        // B-7-C: 8 control kinds, kind = .control + control_kind 区分 token
        .push_clip => |pc| {
            out.geom = .{ .x = pc.x, .y = pc.y, .w = pc.w, .h = pc.h };
            out.radii = .{ .tl = pc.radius, .tr = pc.radius, .br = pc.radius, .bl = pc.radius };
            out.control_kind = .push_clip;
            out.clip_shape_kind = @intFromEnum(pc.shape_kind);
            // polygon shape 字段通过 cx.lowerForEncoderPaintTable 在 frame_arena
            // 里 alloc paint_table.ClipPolygonMirror 副本写 extra_ptr (B-7 主路径切换)。
            // 这里 lowerDisplayItem 是无状态 fn 不分配；shadow path 暂不读 polygon。
        },
        .pop_clip => {
            out.control_kind = .pop_clip;
        },
        .begin_opacity_layer => |bo| {
            out.geom = .{ .x = bo.x, .y = bo.y, .w = bo.w, .h = bo.h };
            out.radii = .{ .tl = bo.corner_radius, .tr = bo.corner_radius, .br = bo.corner_radius, .bl = bo.corner_radius };
            out.opacity = bo.opacity;
            out.rotate = bo.rotate;
            out.draw_x = bo.draw_x;
            out.draw_y = bo.draw_y;
            out.draw_w = bo.draw_w;
            out.draw_h = bo.draw_h;
            out.use_draw_transform = bo.use_draw_transform;
            out.draw_transform = .{
                bo.draw_transform.a,  bo.draw_transform.b,
                bo.draw_transform.c,  bo.draw_transform.d,
                bo.draw_transform.tx, bo.draw_transform.ty,
            };
            out.blend_mode = @intFromEnum(bo.blend_mode);
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
            out.radii = .{ .tl = bb.corner_radius, .tr = bb.corner_radius, .br = bb.corner_radius, .bl = bb.corner_radius };
            out.rotate = bb.rotate;
            out.draw_x = bb.draw_x;
            out.draw_y = bb.draw_y;
            out.draw_w = bb.draw_w;
            out.draw_h = bb.draw_h;
            out.use_draw_transform = bb.use_draw_transform;
            out.draw_transform = .{
                bb.draw_transform.a,  bb.draw_transform.b,
                bb.draw_transform.c,  bb.draw_transform.d,
                bb.draw_transform.tx, bb.draw_transform.ty,
            };
            out.control_kind = .begin_blur_layer;
            // glass: ResolvedGlassParams 通过 cx.lowerForEncoderPaintTable 在 frame_arena
            // 里 alloc paint_table.GlassParamsMirror 副本写 extra_ptr (B-7 主路径切换)。
            // lowerDisplayItem 是无状态 fn 不分配。
        },
        .end_blur_layer => {
            out.control_kind = .end_blur_layer;
        },
        .begin_rounded_clip => |br| {
            out.geom = .{ .x = br.x, .y = br.y, .w = br.w, .h = br.h };
            out.radii = .{ .tl = br.radius, .tr = br.radius, .br = br.radius, .bl = br.radius };
            out.rotate = br.rotate;
            out.draw_x = br.draw_x;
            out.draw_y = br.draw_y;
            out.draw_w = br.draw_w;
            out.draw_h = br.draw_h;
            out.use_draw_transform = br.use_draw_transform;
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
    /// display_list 总条目数
    display_item_count: usize,
    /// lowering_buffer 中 drawable commands 数（控制流不计）
    drawable_command_count: usize,
    /// 按 instance batching 后的 GpuDraw 数（≤ display_item_count）
    gpu_draw_count: usize,
    /// 等价性：display_item_count == drawable_command_count（lowering 是 1:1）
    counts_match: bool,
    /// pipeline 序列等价：display_list lowering 后的 pipeline id 序列
    /// 与 caller 提供的 drawable command pipeline id 序列内容完全相同。
    /// 仅当 counts_match 且 caller 传入序列时计算；否则 false。
    pipelines_match: bool,
    /// 最长可合并 batch run（同 pipeline + 同 blend + 同 texture 连续段）
    max_batch_run: u32,
    /// 字段值等价检查，paint_table.DisplayItem 的
    /// geom (x/y/w/h) 转回与 display_list 的 fill_rect (x/y/w/h) 字段相同。
    /// 失败 = lowerDisplayItem 字段映射 bug (未来 rename / 类型变更 catch)。
    /// 0 = 全部通过；> 0 = 该数量 fill_rect lowering 字段值不一致。
    field_value_mismatches: u32,
};

/// 主入口：从 display_list 跑 lowering + encode，返回结构等价信息。
/// 调用方负责 out_draws 容量 ≥ display_items.len。
/// expected_pipelines（可选）：drawable command 的 pipeline id 序列；
/// 提供时计算 pipelines_match 字段。
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

    // 字段值等价 self-check
    // paint_table.DisplayItem.geom 应与 display_list 各 kind 的 (x,y,w,h) 字段一致。
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

    // Lower 全部 items
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
        // 大于 stack buffer 时分段处理（不合并跨段 batch，仅起步阶段保守做法）
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
    // 渐变走的是 .gradient kind，与 fill_rect 是两条独立的 lowering 分支。
    // shape 漏传 ⇒ 椭圆/正圆的渐变画成一个铺满 bbox 的渐变方块。
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
    // shape 漏传 = 椭圆静默画成圆角矩形（宽高比大时是"胶囊"），而层数/几何
    // 断言全都正常，这条断言的就是那个静默失效点。
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

    // 默认必须是 0（rounded_rect），不写 shape 的既有调用方行为不变
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
    // 验证 lowering 字段无损，真接管时无信息丢失。
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
    // B-5+ 扩展字段无损
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
        .radius = 8,
        .shape_kind = .rect,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(PaintItemKind.control, lowered.kind);
    try testing.expectEqual(paint_table_mod.ControlKind.push_clip, lowered.control_kind);
    try testing.expectEqual(@as(u8, 0), lowered.clip_shape_kind);
    try testing.expectApproxEqAbs(@as(f32, 10), lowered.geom.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8), lowered.radii.tl, 0.001);
    // rect shape clip_polygon_ptr 由 cx.lowerForEncoderPaintTable 在 source ArrayList
    // 取地址写入 (lowerDisplayItem 这层不设)，所以 unit test 期望 null
    try testing.expect(lowered.clip_polygon_ptr == null);
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
    item.push_clip.polygon.point_count = 3;
    item.push_clip.polygon.points[0] = .{ 0, 0 };
    item.push_clip.polygon.points[1] = .{ 50, 0 };
    item.push_clip.polygon.points[2] = .{ 25, 50 };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(paint_table_mod.ControlKind.push_clip, lowered.control_kind);
    try testing.expectEqual(@as(u8, 3), lowered.clip_shape_kind);
    // clip_polygon_ptr 不在 lowerDisplayItem 阶段写，由 cx.lowerForEncoderPaintTable 写
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
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(paint_table_mod.ControlKind.begin_opacity_layer, lowered.control_kind);
    try testing.expectApproxEqAbs(@as(f32, 0.5), lowered.opacity, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.5), lowered.draw_transform[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), lowered.draw_transform[4], 0.001);
    try testing.expect(lowered.use_draw_transform);
    // multiply 在 BlendMode 中的位置 (查 types.zig:611) = 1
    try testing.expect(lowered.blend_mode != 0);
}

test "lowerDisplayItem: begin_blur_layer extra_ptr 透传 source variant" {
    const item: DisplayItem = .{ .begin_blur_layer = .{
        .header = dummyHeader(),
        .x = 0,
        .y = 0,
        .w = 200,
        .h = 100,
        .corner_radius = 12,
    } };
    const lowered = lowerDisplayItem(item);
    try testing.expectEqual(paint_table_mod.ControlKind.begin_blur_layer, lowered.control_kind);
    try testing.expectApproxEqAbs(@as(f32, 12), lowered.radii.tl, 0.001);
    // glass_ptr 由 cx.lowerForEncoderPaintTable 写入 (lowerDisplayItem 不设)
}

test "lowerDisplayItem: begin_rounded_clip 字段无损 (geom + radius + draw fields)" {
    const types_mod = @import("../types.zig");
    const item: DisplayItem = .{ .begin_rounded_clip = .{
        .header = dummyHeader(),
        .x = 5,
        .y = 6,
        .w = 80,
        .h = 60,
        .radius = 10,
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
    // shadow1 占 secondary 槽
    try testing.expectEqual(@as(u8, 64), lowered.shadow_secondary_color.a);
    try testing.expectApproxEqAbs(@as(f32, 4), lowered.shadow_blur, 0.001);
    // shadow2 独立槽
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
    // local_bounds 是 (cx-r, cy-r, 2r, 2r) AABB
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
    // icon_rep_ptr 由 cx.lowerForEncoderPaintTable 写入 (lowerDisplayItem 不设)
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
    // field 等价 = 0, lowerDisplayItem 字段映射无误
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
    // 期望序列：rect(1), text(2), image(3)，与 pipelineForKind 一致
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
    // 期望 text(2) 但实际是 rect(1)
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
    try testing.expectEqual(@as(u32, 3), r.max_batch_run); // 3 text_run 连续段
}
