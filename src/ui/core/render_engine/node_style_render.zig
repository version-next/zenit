/// 节点样式渲染：阴影、背景、边框、大纲、媒体（图像/图标）
/// 负责将节点的可视样式属性转换为 lowered DisplayItem（lowering_buffer）和显示列表（display_list）项
const std = @import("std");
const types = @import("../types.zig");
const node_mod = @import("../node.zig");
const display_list_mod = @import("../display_list.zig");
const geometry = @import("geometry.zig");
const node_state = @import("node_state.zig");
const render_context_mod = @import("render_context.zig");

const Node = node_mod.Node;
const NodeExecutionState = node_state.NodeExecutionState;

pub fn makeDisplayItemHeader(exec_state: NodeExecutionState) display_list_mod.ItemHeader {
    return .{
        .transform_id = exec_state.retained_ids.transform_id,
        .clip_id = exec_state.retained_ids.clip_id,
        .effect_id = exec_state.retained_ids.effect_id,
        .node_id = exec_state.retained_runtime.node_id,
        .paint_order = exec_state.retained_runtime.paint_order,
    };
}

pub fn scaleLocalRadii(radii: [4]f32, scale: f32) [4]f32 {
    return .{ radii[0] * scale, radii[1] * scale, radii[2] * scale, radii[3] * scale };
}

pub fn computeEffectiveBackdropFill(node: *Node, draw_opacity: f32) ?types.Color {
    var bg = geometry.modulateColorOpacity(node.getBackground(), draw_opacity);
    if (bg.a == 0) return null;

    if (node.style.glass_params()) |gp| {
        if (gp.backdrop_blur >= 0.5 and gp.glass_tint != null and gp.glass_intensity > 0.01) {
            const alpha_scale: f32 = if (gp.glass_intensity >= 1.25)
                0.18
            else if (gp.glass_intensity >= 1.0)
                0.24
            else
                0.32;
            const scaled_alpha = @as(f32, @floatFromInt(bg.a)) * alpha_scale;
            bg.a = @intFromFloat(@round(std.math.clamp(scaled_alpha, 0.0, 255.0)));
            if (bg.a == 0) return null;
        }
    }

    return bg;
}

pub fn computeEffectiveBackdropBorderColor(node: *Node, color: types.Color, draw_opacity: f32) types.Color {
    var result = geometry.modulateColorOpacity(color, draw_opacity);
    if (result.a == 0) return result;

    if (node.style.glass_params()) |gp| {
        if (gp.backdrop_blur >= 0.5 and gp.glass_tint != null and gp.glass_intensity > 0.01) {
            const alpha_scale: f32 = if (gp.glass_intensity >= 1.25)
                0.48
            else if (gp.glass_intensity >= 1.0)
                0.58
            else
                0.7;
            const scaled_alpha = @as(f32, @floatFromInt(result.a)) * alpha_scale;
            result.a = @intFromFloat(@round(std.math.clamp(scaled_alpha, 0.0, 255.0)));
        }
    }

    return result;
}

pub fn appendNodeShadowAndBackground(
    cx: *render_context_mod.RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
) !void {
    const header = makeDisplayItemHeader(exec_state);
    const local_radii = node.style.effectiveRadii();
    // 从 World.LayoutTable 读 rect（shadow-sync 保证与 node.rect 一致）。
    const local_rect = cx.rectFromWorld(node);
    const render_x = exec_state.render_x;
    const render_y = exec_state.render_y;
    const render_w = exec_state.render_w;
    const render_h = exec_state.render_h;
    const scale_x_abs = exec_state.scale_x_abs;
    const scale_y_abs = exec_state.scale_y_abs;
    const scale_min = exec_state.scale_min;
    const radii = exec_state.radii;
    _ = render_x;
    _ = render_y;
    _ = render_w;
    _ = render_h;
    _ = scale_x_abs;
    _ = scale_y_abs;
    _ = scale_min;
    _ = radii;
    const draw_opacity = if (exec_state.use_opacity_layer) 1.0 else exec_state.node_opacity;
    const effective_bg = computeEffectiveBackdropFill(node, draw_opacity);

    // 外阴影：1 层用 shadow，2 层用 shadow_dual
    const shadow_slice = node.style.shadowSlice();
    var any_spread = false;
    for (shadow_slice) |sh| {
        if (sh.spread != 0) any_spread = true;
    }
    if (shadow_slice.len >= 3 or any_spread) {
        // CSS 多重 box-shadow：逐层发射，列表第一项在最上层 → 从最后一项画起。
        // 每层都是纯阴影（本体下方挖空），背景填充由下面的常规路径绘制。
        var i = shadow_slice.len;
        while (i > 0) {
            i -= 1;
            const sh = shadow_slice[i];
            try cx.display_list.append(.{
                .shadow_rect = .{
                    .header = header,
                    .x = 0,
                    .y = 0,
                    .w = local_rect.w,
                    .h = local_rect.h,
                    .color = geometry.modulateColorOpacity(sh.color, draw_opacity),
                    .blur = sh.blur,
                    .offset_x = sh.offset_x,
                    .offset_y = sh.offset_y,
                    .spread = sh.spread,
                    .radius = local_radii,
                },
            });
        }
    } else if (shadow_slice.len >= 2) {
        const s1 = shadow_slice[0];
        const s2 = shadow_slice[1];
        const fill = geometry.modulateColorOpacity(node.getBackground(), draw_opacity);
        try cx.display_list.append(.{
            .shadow_dual_rect = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .fill = fill,
                .shadow1_color = geometry.modulateColorOpacity(s1.color, draw_opacity),
                .shadow1_blur = s1.blur,
                .shadow1_offset_x = s1.offset_x,
                .shadow1_offset_y = s1.offset_y,
                .shadow2_color = geometry.modulateColorOpacity(s2.color, draw_opacity),
                .shadow2_blur = s2.blur,
                .shadow2_offset_x = s2.offset_x,
                .shadow2_offset_y = s2.offset_y,
                .radius = local_radii,
            },
        });
    } else if (shadow_slice.len == 1) {
        const s1 = shadow_slice[0];
        if (std.posix.getenv("ZENIT_DEBUG_SHADOW") != null) {
            std.debug.print("[shadow] node={d} comp={s} rect=({d:.0},{d:.0},{d:.0},{d:.0}) r={d:.0} blur={d:.0} a={d}\n", .{
                node.id, node.meta.ownership.meta.component_name orelse "?", local_rect.x, local_rect.y, local_rect.w, local_rect.h, local_radii[0], s1.blur, s1.color.a,
            });
        }
        try cx.display_list.append(.{
            .shadow_rect = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .color = geometry.modulateColorOpacity(s1.color, draw_opacity),
                .blur = s1.blur,
                .offset_x = s1.offset_x,
                .offset_y = s1.offset_y,
                .radius = local_radii,
            },
        });
    }

    // 有矢量填充路径的节点：背景/渐变由 `fill_path` 画（逐顶点着色），
    // 这里的矩形分支必须整段跳过 —— 否则会在多边形背后垫一个铺满包围盒的
    // 渐变方块（用户实测截图：三角外面一圈渐变底）。
    // 下面 fill_rect 分支早就有同名守卫（`vector.fill.path == null`），
    // 但 gradient 两支漏了，所以只有渐变态露馅。
    const has_vector_fill = if (node.layoutOutputPtr()) |lo_vf|
        lo_vf.vector.fill.path != null
    else
        false;

    if (has_vector_fill) {
        // 交给下面的矢量填充分支
    } else if (node.style.multi_gradient()) |mg| {
        // 多色渐变（优先级高于旧两色 gradient）
        var stop_colors: [16]types.Color = [_]types.Color{types.Color.rgba(0, 0, 0, 0)} ** 16;
        var stop_positions: [16]f32 = [_]f32{0} ** 16;
        const cnt = mg.stop_count;
        for (0..cnt) |i| {
            stop_colors[i] = geometry.modulateColorOpacity(mg.stops[i].color, draw_opacity);
            stop_positions[i] = mg.stops[i].position;
        }
        try cx.display_list.append(.{
            .multi_gradient_rect = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .direction = mg.direction,
                .radius = local_radii,
                .stop_colors = stop_colors,
                .stop_positions = stop_positions,
                .stop_count = cnt,
                // 圆心在着色器里是相对 (0.5,0.5) 的 UV 偏移。
                .radial_center_x = mg.radial_center[0] - 0.5,
                .radial_center_y = mg.radial_center[1] - 0.5,
                .radial_radius_x = mg.radial_radius[0],
                .radial_radius_y = mg.radial_radius[1],
                .shape = @intFromEnum(node.style.shape()),
            },
        });
    } else if (node.style.gradient()) |grad| {
        try cx.display_list.append(.{
            .gradient_rect = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .from = geometry.modulateColorOpacity(grad.from, draw_opacity),
                .to = geometry.modulateColorOpacity(grad.to, draw_opacity),
                .direction = grad.direction,
                .radius = local_radii,
                .shape = @intFromEnum(node.style.shape()),
            },
        });
    } else if (effective_bg) |bg| {
        // path_geometry 节点用 fill_path 命令渲染，跳过背景矩形
        if (node.getLayoutOutput().vector.fill.path == null) {
            try cx.display_list.append(.{
                .fill_rect = .{
                    .header = header,
                    .x = 0,
                    .y = 0,
                    .w = local_rect.w,
                    .h = local_rect.h,
                    .color = bg,
                    .radius = local_radii,
                    .shape = @intFromEnum(node.style.shape()),
                },
            });
        }
    }

    // ── 噪声纹理（叠加在背景上）──
    if (node.style.noise()) |np| {
        const fill = geometry.modulateColorOpacity(node.getBackground(), draw_opacity);
        try cx.display_list.append(.{
            .noise_rect = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .fill = fill,
                .mode = @intFromEnum(np.mode),
                .scale = np.scale,
                .intensity = np.intensity,
                .seed = np.seed,
                .radius = local_radii,
            },
        });
    }

    // ── Inset Shadow 内阴影（叠加在背景上）──
    // 填充一律透明：底色已由上面的 fill_rect / 渐变画过，着色器画内阴影只看几何
    // 覆盖率。旧实现在这里再填一次背景，半透明底（玻璃）会被叠深（BulkQuad 路径
    // 早已按此修正，见 tests.zig 的 inset fill 断言）。多层按 CSS 顺序从最后一层画起。
    if (node.style.inset_shadow()) |first| {
        const extras = node.style.extraInsetShadows();
        var i: usize = extras.len + 1;
        while (i > 0) {
            i -= 1;
            const is = if (i == 0) first else extras[i - 1];
            try cx.display_list.append(.{
                .inset_shadow_rect = .{
                    .header = header,
                    .x = 0,
                    .y = 0,
                    .w = local_rect.w,
                    .h = local_rect.h,
                    .fill = types.Color.rgba(0, 0, 0, 0),
                    .shadow_color = geometry.modulateColorOpacity(is.color, draw_opacity),
                    .blur = is.blur,
                    .offset_x = is.offset_x,
                    .offset_y = is.offset_y,
                    .radius = local_radii,
                },
            });
        }
    }

    // layoutOutputPtr 给 World slot 稳定地址；display_list
    // 存 geometry 指针，帧内消费前必须保持有效（slot dense by element_id，
    // 帧内稳定）。
    if (node.layoutOutputPtr()) |lo| {
        // 矢量路径填充
        if (lo.vector.fill.path) |*geom| {
            // 渐变优先于纯色背景：矢量填充的渐变由 path_renderer 逐顶点着色。
            // 注意判据是 `渐变有效 or 背景不透明` —— 设了渐变的节点背景常是
            // 透明的（容器不该垫色），只看 background.a 会把渐变整条跳过。
            const mg = node.style.multi_gradient();
            const has_grad = mg != null and mg.?.stop_count >= 2;
            if (has_grad or node.getBackground().a > 0) {
                const fill_color = geometry.modulateColorOpacity(node.getBackground(), draw_opacity);
                var g_colors: [16]types.Color = [_]types.Color{types.Color.rgba(0, 0, 0, 0)} ** 16;
                var g_positions: [16]f32 = [_]f32{0} ** 16;
                var g_dir: u8 = 0;
                var g_cnt: u8 = 0;
                var g_cx: f32 = 0.5;
                var g_cy: f32 = 0.5;
                var g_ang: f32 = 0;
                if (has_grad) {
                    const g = mg.?;
                    g_cnt = g.stop_count;
                    for (0..g_cnt) |i| {
                        g_colors[i] = geometry.modulateColorOpacity(g.stops[i].color, draw_opacity);
                        g_positions[i] = g.stops[i].position;
                    }
                    g_dir = @intFromEnum(g.direction);
                    // MultiGradient 只带 stops + direction；radial/conic 的
                    // 中心与起始角不在这个结构里，用几何中心的默认值。
                    g_cx = 0.5;
                    g_cy = 0.5;
                    g_ang = 0;
                }
                try cx.display_list.append(.{
                    .fill_path = .{
                        .header = header,
                        .geometry = geom,
                        .color = fill_color,
                        .offset_x = 0,
                        .offset_y = 0,
                        .opacity = 1.0,
                        .gradient_direction = g_dir,
                        .gradient_stop_colors = g_colors,
                        .gradient_stop_positions = g_positions,
                        .gradient_stop_count = g_cnt,
                        .gradient_center_x = g_cx,
                        .gradient_center_y = g_cy,
                        .gradient_start_angle = g_ang,
                    },
                });
            }
        }

        // 矢量路径描边
        if (lo.vector.stroke.geometry) |*geom| {
            if (lo.vector.stroke.color.a > 0 and lo.vector.stroke.width > 0) {
                const stroke_color = geometry.modulateColorOpacity(lo.vector.stroke.color, draw_opacity);
                try cx.display_list.append(.{
                    .stroke_path = .{
                        .header = header,
                        .geometry = geom,
                        .color = stroke_color,
                        .width = lo.vector.stroke.width,
                        .line_join = lo.vector.stroke.line_join,
                        .offset_x = 0,
                        .offset_y = 0,
                        .opacity = 1.0,
                    },
                });
            }
        }
    }
}

pub fn appendNodeBorder(
    cx: *render_context_mod.RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
) !void {
    const header = makeDisplayItemHeader(exec_state);
    const local_radii = node.style.effectiveRadii();
    // World.LayoutTable 读 rect。
    const local_rect = cx.rectFromWorld(node);
    const render_x = exec_state.render_x;
    const render_y = exec_state.render_y;
    const render_w = exec_state.render_w;
    const render_h = exec_state.render_h;
    const scale_x_abs = exec_state.scale_x_abs;
    const scale_y_abs = exec_state.scale_y_abs;
    const radii = exec_state.radii;
    _ = render_x;
    _ = render_y;
    _ = radii;
    const draw_opacity = if (exec_state.use_opacity_layer) 1.0 else exec_state.node_opacity;

    const border_widths_raw = node.style.border.resolvedWidths();
    const border_widths = [4]f32{
        border_widths_raw[types.Border.SIDE_TOP] * scale_y_abs,
        border_widths_raw[types.Border.SIDE_RIGHT] * scale_x_abs,
        border_widths_raw[types.Border.SIDE_BOTTOM] * scale_y_abs,
        border_widths_raw[types.Border.SIDE_LEFT] * scale_x_abs,
    };
    const border_colors = if (node.style.border_side_colors()) |sc|
        sc.resolved(node.style.border.color)
    else
        [_]types.Color{ node.style.border.color, node.style.border.color, node.style.border.color, node.style.border.color };
    const border_has_visible =
        (border_widths[types.Border.SIDE_TOP] > 0 and border_colors[types.Border.SIDE_TOP].a > 0) or
        (border_widths[types.Border.SIDE_RIGHT] > 0 and border_colors[types.Border.SIDE_RIGHT].a > 0) or
        (border_widths[types.Border.SIDE_BOTTOM] > 0 and border_colors[types.Border.SIDE_BOTTOM].a > 0) or
        (border_widths[types.Border.SIDE_LEFT] > 0 and border_colors[types.Border.SIDE_LEFT].a > 0);
    if (!border_has_visible) return;

    const colors_uniform =
        types.Color.eql(border_colors[types.Border.SIDE_TOP], border_colors[types.Border.SIDE_RIGHT]) and
        types.Color.eql(border_colors[types.Border.SIDE_TOP], border_colors[types.Border.SIDE_BOTTOM]) and
        types.Color.eql(border_colors[types.Border.SIDE_TOP], border_colors[types.Border.SIDE_LEFT]);
    if (node.style.border.isUniformWidth() and colors_uniform) {
        const effective_uniform_border = computeEffectiveBackdropBorderColor(node, border_colors[types.Border.SIDE_TOP], draw_opacity);
        try cx.display_list.append(.{
            .stroke_rect = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .color = effective_uniform_border,
                .width = border_widths_raw[types.Border.SIDE_TOP],
                .radius = local_radii,
                .shape = @intFromEnum(node.style.shape()),
            },
        });
        return;
    }

    // Per-side border: 使用 border_per_side 命令，shader 内计算内轮廓，无需 clip
    if (colors_uniform) {
        const effective_uniform_border = computeEffectiveBackdropBorderColor(node, border_colors[types.Border.SIDE_TOP], draw_opacity);
        // 颜色一致，宽度不同 → 单个 draw call
        try cx.display_list.append(.{
            .border_per_side = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .color = effective_uniform_border,
                .widths = .{
                    border_widths_raw[types.Border.SIDE_TOP],
                    border_widths_raw[types.Border.SIDE_RIGHT],
                    border_widths_raw[types.Border.SIDE_BOTTOM],
                    border_widths_raw[types.Border.SIDE_LEFT],
                },
                .radius = local_radii,
            },
        });
        return;
    }

    // 颜色不同 → 每边一个 draw call，只设该边宽度非零
    const tw = border_widths[types.Border.SIDE_TOP];
    const rw = border_widths[types.Border.SIDE_RIGHT];
    const bw = border_widths[types.Border.SIDE_BOTTOM];
    const lw = border_widths[types.Border.SIDE_LEFT];

    if (tw > 0 and border_colors[types.Border.SIDE_TOP].a > 0 and render_w > 0 and render_h > 0) {
        const effective_top_border = computeEffectiveBackdropBorderColor(node, border_colors[types.Border.SIDE_TOP], draw_opacity);
        try cx.display_list.append(.{
            .border_per_side = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .color = effective_top_border,
                .widths = .{ border_widths_raw[types.Border.SIDE_TOP], 0, 0, 0 },
                .radius = local_radii,
            },
        });
    }

    if (rw > 0 and border_colors[types.Border.SIDE_RIGHT].a > 0 and render_w > 0 and render_h > 0) {
        const effective_right_border = computeEffectiveBackdropBorderColor(node, border_colors[types.Border.SIDE_RIGHT], draw_opacity);
        try cx.display_list.append(.{
            .border_per_side = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .color = effective_right_border,
                .widths = .{ 0, border_widths_raw[types.Border.SIDE_RIGHT], 0, 0 },
                .radius = local_radii,
            },
        });
    }

    if (bw > 0 and border_colors[types.Border.SIDE_BOTTOM].a > 0 and render_w > 0 and render_h > 0) {
        const effective_bottom_border = computeEffectiveBackdropBorderColor(node, border_colors[types.Border.SIDE_BOTTOM], draw_opacity);
        try cx.display_list.append(.{
            .border_per_side = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .color = effective_bottom_border,
                .widths = .{ 0, 0, border_widths_raw[types.Border.SIDE_BOTTOM], 0 },
                .radius = local_radii,
            },
        });
    }

    if (lw > 0 and border_colors[types.Border.SIDE_LEFT].a > 0 and render_w > 0 and render_h > 0) {
        const effective_left_border = computeEffectiveBackdropBorderColor(node, border_colors[types.Border.SIDE_LEFT], draw_opacity);
        try cx.display_list.append(.{
            .border_per_side = .{
                .header = header,
                .x = 0,
                .y = 0,
                .w = local_rect.w,
                .h = local_rect.h,
                .color = effective_left_border,
                .widths = .{ 0, 0, 0, border_widths_raw[types.Border.SIDE_LEFT] },
                .radius = local_radii,
            },
        });
    }
}

pub fn appendNodeOutline(
    cx: *render_context_mod.RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
) !void {
    const out = node.style.outline() orelse return;
    const header = makeDisplayItemHeader(exec_state);
    const local_radii = node.style.effectiveRadii();
    // World.LayoutTable 读 rect。
    const local_rect = cx.rectFromWorld(node);
    const render_x = exec_state.render_x;
    const render_y = exec_state.render_y;
    const render_w = exec_state.render_w;
    const render_h = exec_state.render_h;
    const scale_min = exec_state.scale_min;
    const radii = exec_state.radii;
    const outline_width = out.width * scale_min;
    const total_offset = (out.offset + out.width) * scale_min;
    _ = render_x;
    _ = render_y;
    _ = render_w;
    _ = render_h;
    _ = radii;
    _ = outline_width;
    _ = total_offset;
    const draw_opacity = if (exec_state.use_opacity_layer) 1.0 else exec_state.node_opacity;

    try cx.display_list.append(.{
        .outline_rect = .{
            .header = header,
            .x = -(out.offset + out.width),
            .y = -(out.offset + out.width),
            .w = local_rect.w + (out.offset + out.width) * 2,
            .h = local_rect.h + (out.offset + out.width) * 2,
            .color = geometry.modulateColorOpacity(out.color, draw_opacity),
            .width = out.width,
            .radius = .{
                local_radii[0] + out.offset + out.width,
                local_radii[1] + out.offset + out.width,
                local_radii[2] + out.offset + out.width,
                local_radii[3] + out.offset + out.width,
            },
        },
    });
}

pub fn appendNodeMedia(
    cx: *render_context_mod.RenderContext,
    node: *Node,
    exec_state: NodeExecutionState,
) !void {
    const header = makeDisplayItemHeader(exec_state);
    // World.LayoutTable 读 rect。
    const local_rect = cx.rectFromWorld(node);
    const render_x = exec_state.render_x;
    const render_y = exec_state.render_y;
    const render_w = exec_state.render_w;
    const render_h = exec_state.render_h;
    const pad_left = exec_state.pad_left;
    const pad_right = exec_state.pad_right;
    const pad_top = exec_state.pad_top;
    const pad_bottom = exec_state.pad_bottom;
    const radius = exec_state.radius;
    _ = radius;
    const draw_opacity = if (exec_state.use_opacity_layer) 1.0 else exec_state.node_opacity;

    if (node.getImage()) |im| {
        const image_x = render_x + pad_left;
        const image_y = render_y + pad_top;
        const image_w = @max(0, render_w - pad_left - pad_right);
        const image_h = @max(0, render_h - pad_top - pad_bottom);
        _ = image_x;
        _ = image_y;
        if (image_w > 0 and image_h > 0) {
            try cx.display_list.append(.{
                .image_quad = .{
                    .header = header,
                    .x = node.style.padding.left,
                    .y = node.style.padding.top,
                    .w = @max(0, local_rect.w - node.style.padding.left - node.style.padding.right),
                    .h = @max(0, local_rect.h - node.style.padding.top - node.style.padding.bottom),
                    .texture_id = im.texture_id,
                    .tint = im.tint,
                    .corner_radius = node.style.effectiveRadius(),
                    .opacity = draw_opacity,
                },
            });
        }
    }

    if (node.getIcon()) |ic| {
        const icon_x = render_x + pad_left;
        const icon_y = render_y + pad_top;
        _ = icon_x;
        _ = icon_y;
        const icon_w = @max(0, render_w - pad_left - pad_right);
        const icon_h = @max(0, render_h - pad_top - pad_bottom);
        if (icon_w > 0 and icon_h > 0) {
            try cx.display_list.append(.{
                .icon_rep = .{
                    .header = header,
                    .icon_id = ic.icon_id,
                    .rep_size = ic.rep.size,
                    .rep = ic.rep,
                    .x = node.style.padding.left,
                    .y = node.style.padding.top,
                    .w = @max(0, local_rect.w - node.style.padding.left - node.style.padding.right),
                    .h = @max(0, local_rect.h - node.style.padding.top - node.style.padding.bottom),
                    .tint = ic.tint,
                    .corner_clip_radius = node.style.effectiveRadius(),
                    .opacity = draw_opacity,
                },
            });
        }
    }
}
