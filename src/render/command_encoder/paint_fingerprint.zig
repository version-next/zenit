//! command_encoder/paint_fingerprint.zig, paint 命令的**纯函数**工具集
//!
//! 从 command_encoder.zig 析出（2026-07-31）。这一簇的共同特征是
//! **零 encoder 实例状态依赖**：全部是 `fn(anytype) -> value` 的纯函数，
//! 只依赖传入的 paint 命令本身。放在 2600 行的 RenderCommandEncoder
//! 内部除了撑大文件没有别的作用。
//!
//! 三组职责：
//! 1. **damage bounds**，单条命令影响的像素范围，供 damage-rect 部分
//!    重绘求脏区并集。合同是**宁大勿小**：漏一像素 = 保留到陈旧内容。
//! 2. **内容指纹**，把命令里影响像素的字段喂进 hasher，供 retained
//!    层判命中。合同是**宁可多喂**：漏喂 = 内容变了却判命中 = 画面陈旧。
//! 3. **结构折叠**，识别空的 begin/end 结构块，整块跳过。
//!
//! ⚠ 改这里任何一个函数前先读上面两条合同：它们的失效模式是**画面陈旧**
//! 而非崩溃，e2e 未必抓得到。

const std = @import("std");

// 结构 token 分类，与 tryFindNoOpStructuralBlock 同簇的纯函数。
pub const StructuralToken = enum {
    none,
    begin_clip,
    end_clip,
    begin_rounded_clip,
    end_rounded_clip,
    begin_blur_layer,
    end_blur_layer,
    begin_opacity_layer,
    end_opacity_layer,
};

pub inline fn structuralToken(it: anytype) StructuralToken {
    if (it.kind != .control) return .none;
    return switch (it.control_kind) {
        .push_clip => .begin_clip,
        .pop_clip => .end_clip,
        .begin_rounded_clip => .begin_rounded_clip,
        .end_rounded_clip => .end_rounded_clip,
        .begin_blur_layer => .begin_blur_layer,
        .end_blur_layer => .end_blur_layer,
        .begin_opacity_layer => .begin_opacity_layer,
        .end_opacity_layer => .end_opacity_layer,
        else => .none,
    };
}

pub inline fn isBeginStructuralToken(tok: StructuralToken) bool {
    return switch (tok) {
        .begin_clip, .begin_rounded_clip, .begin_blur_layer, .begin_opacity_layer => true,
        else => false,
    };
}

pub inline fn matchingEndStructuralToken(begin_tok: StructuralToken) StructuralToken {
    return switch (begin_tok) {
        .begin_clip => .end_clip,
        .begin_rounded_clip => .end_rounded_clip,
        .begin_blur_layer => .end_blur_layer,
        .begin_opacity_layer => .end_opacity_layer,
        else => .none,
    };
}

/// damage-rect：单条命令的保守外扩 bounds。
/// 宁大勿小，漏一像素脏区 = 保留到陈旧像素。
pub fn damageItemBounds(it: anytype) [4]f32 {
    const sh1 = it.shadow_blur * 2 + @max(@abs(it.shadow_offset_x), @abs(it.shadow_offset_y)) + @max(0, it.shadow_spread);
    const sh2 = it.shadow2_blur * 2 + @max(@abs(it.shadow2_offset_x), @abs(it.shadow2_offset_y));
    var pad: f32 = 2 + it.stroke_width + @max(sh1, sh2);
    // 文本 glyph 可能溢出测量框（斜体 overhang / 下伸部），额外让步。
    if (it.kind == .text) pad += 8;
    var y = it.geom.y;
    var w = it.geom.w;
    var h = it.geom.h;
    if (it.kind == .text) {
        // ⚠️ text 命令的 geom.w/h **恒为 0**（lowering 只填绘制原点，见
        // render_engine/gpu_draw_shadow.zig 的 .text_run 分支）。直接用它算
        // damage bounds，脏区就只有原点周围 pad×2 ≈ 20px 的一小块,
        // 于是同一行里只有开头一两个字进了脏区、后面的字保留上一帧像素。
        //
        // 实测（下游编辑器插入菜单表格尺寸标签，等宽 11px）：内容从 "3 × 4"
        // 换成 "3 × 5"，脏区 x∈[331,351] 只盖住 x=341 的首字形，末尾 x=368
        // 的 '5' 落在脏区外，屏幕上永远停在 "3 × 4"。首段更新、后段陈旧
        // 的分段式残影就是这么来的，与字体回退分段无关（× 只是恰好让
        // 变化落在尾段）。
        //
        // 这里按内容长度给一个**保守上界**：每字节最多 1 个 em 宽
        // （font_size），等宽显式给 cell 宽时用 cell 宽。合同是宁大勿小,
        // 高估只是多重绘几个像素，低估就是陈旧像素。
        const per_byte = if (it.text_monospace_char_width > 0)
            it.text_monospace_char_width
        else
            it.text_font_size;
        const n: f32 = @floatFromInt(it.text_content.len);
        w = @max(w, n * per_byte);
        // ⚠️ text 的 geom.y 是**基线**（text_item_render 各 .text_run 分支都填
        // baseline_y），字形画在基线**上方**（glyph_y = cursor_y - bearing_y）。
        // 此前按 [y, y+2fs] 算，上伸部整个落在脏区外：fs≥14 时 retained 层里
        // 变化文本的顶部保留陈旧像素 / 新字顶被裁。上方取 1.3em（覆盖 CJK /
        // emoji / 带重音大写的 ascent），下方取 0.6em（下伸部 + 行内装饰）。
        const fs = @max(it.text_font_size, 0);
        y -= fs * 1.3;
        h = @max(h, fs * 1.9);
    }
    // 旋转（image / icon 绕中心旋转，见 addImage/addIcon 的 rotate 参数）：
    // 轴对齐 geom 盖不住旋转后的四角，旋转动画会在角上留下拖影。与
    // local_sort.localSortImageLikeBounds 同法取外接圆。
    if (it.kind != .text and @abs(it.rotate) > 0.0001) {
        const cx = it.geom.x + w * 0.5;
        const cy = it.geom.y + h * 0.5;
        const r = 0.5 * @sqrt(w * w + h * h) + pad;
        return .{ cx - r, cy - r, r * 2, r * 2 };
    }
    return .{
        it.geom.x - pad,
        y - pad,
        w + pad * 2,
        h + pad * 2,
    };
}

/// damage-rect：path 命令的保守 bounds。path 的 geom.w/h 恒 0（lowering 只填
/// offset），bounds 必须从点集算，quad/cubic 的控制点是曲线的凸包上界，
/// 直接并入即可（过量但安全）。
pub fn pathItemBounds(it: anytype) [4]f32 {
    // arc（spinner / 进度环）复用 `.path` kind 但**没有** path_geometry_ptr，
    // geom 是圆心、w/h 恒 0。不单独处理的话脏区只有圆心一个点，retained
    // 层（Modal/Sheet/Popover）里的 Spinner 做部分重绘时 scissor 把整个环
    // 裁掉，屏幕上转圈冻结。判据与 isArcCommand / localSortArcBounds 同源
    // （只看 arc_outer_radius）；外扩 stroke_width + 2px AA 余量（宁大勿小）。
    if (it.arc_outer_radius > 0) {
        const r = it.arc_outer_radius + @max(it.stroke_width, 0) + 2;
        return .{ it.geom.x - r, it.geom.y - r, r * 2, r * 2 };
    }
    const pg = it.path_geometry_ptr orelse
        return .{ it.geom.x, it.geom.y, 0, 0 };
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var any = false;
    for (pg.commands) |cmd| {
        switch (cmd) {
            .move_to, .line_to => |pt| {
                min_x = @min(min_x, pt.x);
                min_y = @min(min_y, pt.y);
                max_x = @max(max_x, pt.x);
                max_y = @max(max_y, pt.y);
                any = true;
            },
            .quad_to => |q| {
                min_x = @min(min_x, @min(q.ctrl.x, q.end.x));
                min_y = @min(min_y, @min(q.ctrl.y, q.end.y));
                max_x = @max(max_x, @max(q.ctrl.x, q.end.x));
                max_y = @max(max_y, @max(q.ctrl.y, q.end.y));
                any = true;
            },
            .cubic_to => |c| {
                min_x = @min(min_x, @min(c.ctrl1.x, @min(c.ctrl2.x, c.end.x)));
                min_y = @min(min_y, @min(c.ctrl1.y, @min(c.ctrl2.y, c.end.y)));
                max_x = @max(max_x, @max(c.ctrl1.x, @max(c.ctrl2.x, c.end.x)));
                max_y = @max(max_y, @max(c.ctrl1.y, @max(c.ctrl2.y, c.end.y)));
                any = true;
            },
            .close => {},
        }
    }
    if (!any) return .{ it.geom.x, it.geom.y, 0, 0 };
    // stroke 以线宽的一半向外扩，join/cap 再让 1 倍；+2 基础 pad
    const pad: f32 = 2 + it.stroke_width * 1.5;
    return .{
        it.geom.x + min_x - pad,
        it.geom.y + min_y - pad,
        (max_x - min_x) + pad * 2,
        (max_y - min_y) + pad * 2,
    };
}

/// damage-rect：嵌套 opacity 子层的合成矩形（geom ∪ draw rect ∪ 轴对齐
/// transform rect，外扩 4px 容忍合成 bilinear/圆角边缘）。
/// 旋转 / 非轴对齐 transform 返回 null -> 该顶层 layer 判 unsafe。
pub fn nestedCompositeBounds(it: anytype) ?[4]f32 {
    if (it.rotate != 0) return null;
    var min_x = it.geom.x;
    var min_y = it.geom.y;
    var max_x = it.geom.x + it.geom.w;
    var max_y = it.geom.y + it.geom.h;
    if (it.use_draw_transform) {
        const t = it.draw_transform;
        if (t[1] != 0 or t[2] != 0 or t[0] <= 0 or t[3] <= 0) return null;
        // dt 合成：geom.xy 是嵌套-local 的内容包络原点，与父坐标无关,
        // 合成矩形只由 transform 决定（t4,t5,a·w,d·h）。
        min_x = t[4];
        min_y = t[5];
        max_x = t[4] + t[0] * it.geom.w;
        max_y = t[5] + t[3] * it.geom.h;
    } else if (!std.math.isNan(it.draw_x) and it.draw_w > 0 and it.draw_h > 0) {
        min_x = @min(min_x, it.draw_x);
        min_y = @min(min_y, it.draw_y);
        max_x = @max(max_x, it.draw_x + it.draw_w);
        max_y = @max(max_y, it.draw_y + it.draw_h);
    }
    const pad: f32 = 4;
    return .{ min_x - pad, min_y - pad, (max_x - min_x) + pad * 2, (max_y - min_y) + pad * 2 };
}

pub fn hashPaintItemInto(hasher: *std.hash.Wyhash, it: anytype) void {
    hasher.update(std.mem.asBytes(&it.kind));
    hasher.update(std.mem.asBytes(&it.control_kind));
    hasher.update(std.mem.asBytes(&it.geom));
    hasher.update(std.mem.asBytes(&it.color));
    hasher.update(std.mem.asBytes(&it.radii));
    hasher.update(std.mem.asBytes(&it.opacity));
    hasher.update(std.mem.asBytes(&it.rotate));
    hasher.update(std.mem.asBytes(&it.blend_mode));
    hasher.update(std.mem.asBytes(&it.use_draw_transform));
    hasher.update(std.mem.asBytes(&it.draw_transform));
    hasher.update(std.mem.asBytes(&it.stroke_width));
    hasher.update(std.mem.asBytes(&it.clip_shape_kind));
    // 绘制形状（rounded_rect / ellipse）换的是距离场本身，geom 不变也改像素。
    hasher.update(std.mem.asBytes(&it.shape_kind));
    // 文本横向渐隐（marquee / 截断淡出）：fade 区间动画时内容字节不变。
    hasher.update(std.mem.asBytes(&it.text_fade_dx0));
    hasher.update(std.mem.asBytes(&it.text_fade_dx1));
    // 阴影全套参数（2026-07-30 审查补：blur/offset 动画时 geom 不变）。
    hasher.update(std.mem.asBytes(&it.shadow_blur));
    hasher.update(std.mem.asBytes(&it.shadow_offset_x));
    hasher.update(std.mem.asBytes(&it.shadow_offset_y));
    hasher.update(std.mem.asBytes(&it.shadow_spread));
    hasher.update(std.mem.asBytes(&it.shadow_secondary_color));
    hasher.update(std.mem.asBytes(&it.shadow2_blur));
    hasher.update(std.mem.asBytes(&it.shadow2_offset_x));
    hasher.update(std.mem.asBytes(&it.shadow2_offset_y));
    // 渐变全套（终点色/方向/radial 中心/conic 角度 + multi-stop）。
    hasher.update(std.mem.asBytes(&it.gradient_to_color));
    hasher.update(std.mem.asBytes(&it.gradient_direction));
    hasher.update(std.mem.asBytes(&it.gradient_extend_mode));
    hasher.update(std.mem.asBytes(&it.gradient_radial_center_x));
    hasher.update(std.mem.asBytes(&it.gradient_radial_center_y));
    hasher.update(std.mem.asBytes(&it.gradient_radial_radius_x));
    hasher.update(std.mem.asBytes(&it.gradient_radial_radius_y));
    hasher.update(std.mem.asBytes(&it.gradient_conic_start_angle));
    hasher.update(std.mem.asBytes(&it.mg_stop_count));
    if (it.mg_stop_count > 0) {
        const n = @min(@as(usize, it.mg_stop_count), it.mg_stop_colors.len);
        hasher.update(std.mem.sliceAsBytes(it.mg_stop_colors[0..n]));
        hasher.update(std.mem.sliceAsBytes(it.mg_stop_positions[0..n]));
    }
    // glass 参数（begin_blur_layer）：只有指针，内容必须逐字段喂,
    // scroll_edge_strength / interactive boost 等逐帧变化不进指纹的话，
    // retained 层会 stale hit（既有缺口，2026-07-30 补）。
    if (it.glass_ptr) |gp| {
        const g = gp.*;
        if (@typeInfo(@TypeOf(g)) == .@"struct") {
            inline for (@typeInfo(@TypeOf(g)).@"struct".fields) |f| {
                hasher.update(std.mem.asBytes(&@field(g, f.name)));
            }
        }
    }
    // arc：spinner / 进度环的角度逐帧变而 geom（中心）不变，不喂必陈旧。
    hasher.update(std.mem.asBytes(&it.arc_start_angle));
    hasher.update(std.mem.asBytes(&it.arc_end_angle));
    hasher.update(std.mem.asBytes(&it.arc_outer_radius));
    // 边框 / noise。
    hasher.update(std.mem.asBytes(&it.border_widths));
    hasher.update(std.mem.asBytes(&it.noise_mode));
    hasher.update(std.mem.asBytes(&it.noise_scale));
    hasher.update(std.mem.asBytes(&it.noise_intensity));
    hasher.update(std.mem.asBytes(&it.noise_seed));
    hasher.update(std.mem.asBytes(&it.path_line_join));
    // 文本：内容 + 字号/字重/字体标志都影响像素。
    hasher.update(it.text_content);
    hasher.update(std.mem.asBytes(&it.text_font_size));
    hasher.update(std.mem.asBytes(&it.text_font_weight));
    // 字体族必须进指纹:换字体但字号字重不变时,不进指纹就不重绘。
    hasher.update(std.mem.asBytes(&it.text_font_family));
    hasher.update(std.mem.asBytes(&it.text_font_flags));
    hasher.update(std.mem.asBytes(&it.text_raster_policy));
    // 图像/图标身份。text 的 resource_handle 是 blob_id（shaping 缓存句柄）
    // 像素由 content+字体参数完全决定，blob 身份**不进指纹**：overlay
    // 子树重建会给内容相同的文本重新分配 blob，喂进去会造成"内容没变却
    // 帧帧 miss"（既废掉 retained hit 又把 per-item diff 冲成 100% 脏）。
    if (it.kind != .text) hasher.update(std.mem.asBytes(&it.resource_handle));
    hasher.update(std.mem.asBytes(&it.text_monospace_char_width));
    hasher.update(std.mem.asBytes(&it.image_opacity));
    hasher.update(std.mem.asBytes(&it.image_tint));
    hasher.update(std.mem.asBytes(&it.image_corner_radius));
    hasher.update(std.mem.asBytes(&it.icon_tint));
    hasher.update(std.mem.asBytes(&it.icon_rep_size));
    hasher.update(std.mem.asBytes(&it.icon_corner_clip_radius));
    // 阴影 / 渐变 也影响像素。
    hasher.update(std.mem.asBytes(&it.shadow2_color));
    // text_spans：span 着色/字重变化（选区高亮、语法色）不改文本字节,
    // 逐字段喂（struct 直接按字节 hash 会读到 padding，不稳定）。
    if (it.text_spans) |spans| {
        var span_len: usize = spans.len;
        hasher.update(std.mem.asBytes(&span_len));
        for (spans) |sp| {
            hasher.update(std.mem.asBytes(&sp.start));
            hasher.update(std.mem.asBytes(&sp.end));
            hashOptionalColor(hasher, sp.color);
            if (sp.font_weight) |fw| hasher.update(std.mem.asBytes(&fw)) else hasher.update("n");
            const flags = [_]bool{ sp.use_italic_font, sp.use_monospace_font, sp.strikethrough };
            hasher.update(std.mem.asBytes(&flags));
            hashOptionalColor(hasher, sp.bg_color);
        }
    }
    // path 几何：**必须喂顶点内容**。只喂指针值的话，frame_arena 每帧 reset
    // 后分配顺序相同时地址必然复用，同指针新内容 = 误命中陈旧路径（P0）。
    // PathCommand 是 union，按字节整体 hash 会读到 padding，逐 tag 喂 payload。
    if (it.path_geometry_ptr) |pg| {
        hasher.update(std.mem.asBytes(&pg.fill_rule));
        var cmd_len: usize = pg.commands.len;
        hasher.update(std.mem.asBytes(&cmd_len));
        for (pg.commands) |cmd| {
            const tag: u8 = @intFromEnum(cmd);
            hasher.update(std.mem.asBytes(&tag));
            switch (cmd) {
                .move_to, .line_to => |pt| hasher.update(std.mem.asBytes(&pt)),
                .quad_to => |q| hasher.update(std.mem.asBytes(&q)),
                .cubic_to => |c| hasher.update(std.mem.asBytes(&c)),
                .close => {},
            }
        }
    }
    // polygon clip：点集活在 frame_arena，每帧 reset 后地址相同，只喂指针
    // 等于"同指针新内容"误命中（与 path 几何同一类 P0）。按内容逐字段喂
    // （整体 asBytes 会读到 padding）；有效区间外的点不影响像素，不喂。
    if (it.clip_polygon_ptr) |cp| {
        const pc: usize = @min(@as(usize, cp.point_count), cp.points.len);
        const cc: usize = @min(@as(usize, cp.contour_count), cp.contour_end_points.len);
        hasher.update(std.mem.asBytes(&cp.point_count));
        hasher.update(std.mem.asBytes(&cp.contour_count));
        const fr: u8 = @intFromEnum(cp.fill_rule);
        hasher.update(std.mem.asBytes(&fr));
        hasher.update(std.mem.sliceAsBytes(cp.contour_end_points[0..cc]));
        hasher.update(std.mem.sliceAsBytes(cp.points[0..pc]));
    } else {
        hasher.update("np");
    }
    // 其余指针 payload（glass/icon_rep）：喂指针值。glass 内容已在上面逐字段
    // 喂过；icon rep 由 icon_id 静态生成不就地改写，指针值只作同帧内区分。
    // ⚠️ 隐含合同：resource_handle 指向的 GPU 纹理内容必须不可变（动图/视频
    // 就地更新纹理的路径若将来出现，必须给它引入版本号并喂进指纹）。
    hasher.update(std.mem.asBytes(&@intFromPtr(it.glass_ptr)));
    hasher.update(std.mem.asBytes(&@intFromPtr(it.icon_rep_ptr)));
}

pub fn hashOptionalColor(hasher: *std.hash.Wyhash, c: anytype) void {
    if (c) |v| {
        hasher.update("c");
        hasher.update(std.mem.asBytes(&v));
    } else {
        hasher.update("n");
    }
}

pub const NoOpStructuralBlock = struct {
    end_index: usize,
    pair_count: u32,
};

pub fn tryFindNoOpStructuralBlock(commands: anytype, start: usize) ?NoOpStructuralBlock {
    if (start >= commands.len) return null;
    const begin_tok = structuralToken(commands[start]);
    if (!isBeginStructuralToken(begin_tok)) return null;
    const expected_end = matchingEndStructuralToken(begin_tok);
    if (expected_end == .none) return null;

    var pair_count: u32 = 1;
    var i = start + 1;
    while (i < commands.len) {
        const tok = structuralToken(commands[i]);
        if (tok == .none) return null; // 遇到真实绘制命令，非空结构块
        if (tok == expected_end) {
            return .{
                .end_index = i,
                .pair_count = pair_count,
            };
        }
        if (isBeginStructuralToken(tok)) {
            const nested = tryFindNoOpStructuralBlock(commands, i) orelse return null;
            pair_count +|= nested.pair_count;
            i = nested.end_index + 1;
            continue;
        }
        // 非预期的 end token（结构不平衡）或其他结构噪音，不做折叠
        return null;
    }
    return null; // 未找到匹配 end
}
