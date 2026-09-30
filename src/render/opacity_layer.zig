/// Opacity layer 子系统 — 从 command_encoder.zig 析出
///
/// 提供 begin/endOpacityLayer：将一段渲染命令重定向到离屏纹理，再以 opacity
/// 混合回当前 RT。也复用为 rounded-clip 容器。所有公共入口接受 encoder: anytype，
/// 避免与 RenderCommandEncoder 形成循环 import。
const std = @import("std");
const gpu = @import("gpu");
const offscreen_texture = @import("offscreen_texture.zig");
const blend_composite = @import("blend_composite.zig");
const debug_env = @import("debug_env.zig");
const TextureLease = offscreen_texture.TextureLease;

/// 合成变换的放大系数（≥ 1，上限 4）。离屏纹理按「父光栅倍率 × 该系数」分配并在
/// 层内以此倍率绘制，放大合成时内容是按目标尺寸重新光栅化的，而不是把 1× 位图
/// 拉伸（实测：scale 2 的文字与描边明显发虚）。缩小不降分辨率（系数取 1）。
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

    // （step 1 的四个 pipeline flush 已移入 beginOpacityLayerInto —— 它必须在
    //  **每条**开层路径上执行，见该函数开头的事故注释。）

    // 2. 计算离屏纹理物理像素尺寸：按有效光栅倍率（放大合成时不拉伸位图）。
    const max_texture_dimension = encoder.sdf_renderer.device.limits.max_texture_dimension_2d;
    var s = encoder.scale * layerMagnification(use_draw_transform, draw_transform, w, h, draw_w, draw_h);
    const texture_size = offscreen_texture.computeOffscreenTextureSize(w, h, s, max_texture_dimension) orelse blk: {
        // 放大后超出纹理上限：退回父倍率（清晰度让位于能画出来）。
        s = encoder.scale;
        break :blk offscreen_texture.computeOffscreenTextureSize(w, h, s, max_texture_dimension) orelse return false;
    };
    const tex_w = texture_size.width;
    const tex_h = texture_size.height;
    // 分配走 64px 尺寸桶（scale 动画期逐帧 ±1px 抖动才能命中池复用）；
    // 内容只占 [0, tex_w/h)，合成时按 used/alloc 裁 UV。
    const alloc_w = offscreen_texture.bucketDimension(tex_w, max_texture_dimension);
    const alloc_h = offscreen_texture.bucketDimension(tex_h, max_texture_dimension);

    // 3. 从池获取离屏纹理
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
        // 开层失败：纹理必须还回池，否则每次失败漏一张。
        _ = encoder.offscreen_pool.release(texture, encoder.frame_index);
        return e;
    };
    if (!pushed) _ = encoder.offscreen_pool.release(texture, encoder.frame_index);
    return pushed;
}

/// 离屏 pass 开启失败后补开一个 load 语义的 pass 回到原目标（父离屏纹理
/// 或主 RT），把状态恢复成"从没开过离屏层"。
///
/// ⚠ 新 pass 的 viewport / scissor 是默认值（整张 alloc 纹理）：父目标是
/// 桶化离屏纹理时必须重新限到 used 区域（+ damage scissor），否则后续内容
/// 被拉伸到桶尺寸、部分重绘层的 scissor 丢失。与 backdrop_blur 的
/// restoreRenderTargetPass 同一套恢复动作。
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

/// 把补开的 pass 挂回栈顶槽位并重新施加 per-pass 状态（viewport/scissor）。
fn adoptRestoredPass(encoder: anytype, restored: anytype) void {
    const slot = if (encoder.offscreen_depth > 0) encoder.offscreen_depth - 1 else 0;
    encoder.offscreen_stack[slot].render_pass = restored;
    encoder.render_pass = &encoder.offscreen_stack[slot].render_pass;
    encoder.applyOffscreenTargetViewport();
}

/// damage-rect 部分重绘参数（texture-local 物理像素）。
pub const PartialRepaint = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// beginOpacityLayer 的后半段，纹理由 caller 提供。
/// 普通路径传池里按尺寸借的临时纹理；GPU retained 路径传该 layer 的专属纹理。
/// `partial != null` 时：load 保留旧像素，scissor 限到脏区，先发一个禁混合的
/// clear draw 抹掉脏区旧像素，再让内容命令在 scissor 内重画 —— 脏区外像素
/// 原样保留（= damage-rect 级部分重绘）。
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
    /// 本层的光栅倍率（普通层 = 父倍率 × 放大系数；retained 层 = 父倍率）。
    raster_scale: f32,
) !bool {
    const s = raster_scale;

    // 1. flush 当前 pipeline 到当前 render pass。
    //
    // ⚠️ 必须在这里（而不是只在 beginOpacityLayer 里）：GPU retained 的 miss
    // 路径直接调本函数。2026-07-30 事故：拆分时 flush 留在了外层，miss 路径
    // 开层前不 flush —— 层外已批未刷的实例（面板背景、按钮、overlay dim）在
    // end pass 后被下一次 flush 冲进**离屏纹理**里，还被 markRetainedPrimed
    // 缓存住 —— 画面上表现为"整块页面内容连同 dim 被复制到 overlay surface
    // 的矩形里"，且因为缓存命中而帧帧如此。
    try flushLayerBoundaryPipelines(encoder);

    // 4. 先解析全部非拥有型 binding；解析失败时尚未注册资源或切换 pass。
    const texture_binding = encoder.offscreen_pool.binding(texture) orelse return false;
    const restore_target: gpu.Backend.TextureBinding = if (encoder.offscreen_depth > 0)
        encoder.offscreen_pool.binding(encoder.offscreen_stack[encoder.offscreen_depth - 1].texture) orelse return false
    else
        (encoder.main_render_target orelse return false);
    const tex_id = if (encoder.image_renderer) |ir|
        ir.registerTextureBinding(texture_binding, alloc_w, alloc_h) catch return false
    else
        return false;

    // 6. end 当前 render pass
    encoder.render_pass.?.end();
    // 已结束的 pass 绝不能留在 encoder.render_pass 上：Obj-C 会立刻把这个
    // 地址复用给下一个（可能是 blit）encoder —— 与 backdrop_blur 同一条
    // GlassBox 崩溃不变式。成功路径在压栈后重新赋值。
    encoder.render_pass = null;

    // 7. 在同一 command buffer 中开启离屏 render pass
    var offscreen_view = texture_binding.createView();
    const offscreen_pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = offscreen_view,
            // partial：load 保留脏区外旧像素；脏区内由下方 clear draw 抹除。
            .load_op = if (partial != null) .load else .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch {
        // 上一行已经 end 了当前 pass，这里再直接 return 会让 encoder.render_pass
        // 指向一个已结束的 pass —— 后续所有绘制静默丢失。补开一个 load 语义的
        // pass 回到原目标，把状态恢复成"从没开过离屏层"。
        offscreen_view.destroy();
        if (encoder.image_renderer) |ir| ir.unregisterTextureBinding(tex_id);
        _ = reopenRestoreTargetPass(encoder, restore_target);
        return false;
    };
    encoder.pass_count += 1; // v0.9-§D audit
    encoder.pass_sites[1] += 1;
    offscreen_view.destroy();

    // 8. 保存状态 + 压栈（入栈坐标转 outer-local）
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
    // 层内以本层光栅倍率绘制（退栈时恢复 saved_scale）。
    encoder.scale = s;

    // 9. 切换渲染状态到离屏
    encoder.render_pass = &encoder.offscreen_stack[encoder.offscreen_depth - 1].render_pass;
    encoder.clip_depth = 0;
    encoder.clip_overflow_depth = 0;
    encoder.viewport_width = w;
    encoder.viewport_height = h;

    // 10. 重配三 pipeline 的 viewport
    encoder.sdf_renderer.setViewport(w, h, s);
    encoder.text_renderer.setViewport(w, h, s);
    if (encoder.image_renderer) |ir| ir.setViewport(w, h, s);
    if (encoder.icon_renderer) |ir| ir.setViewport(w, h, s);
    if (encoder.persistent.path_renderer) |*pr| pr.setViewport(w, h, s);
    // NDC 默认铺满整个 alloc 纹理；viewport 显式限到 used 区域，内容才落在
    // [0, tex_w/h) 而不是被拉伸到桶尺寸。
    encoder.render_pass.?.setViewport(0, 0, @floatFromInt(tex_w), @floatFromInt(tex_h), 0, 1);
    if (partial) |p| {
        // scissor 限到脏区（内容命令的光栅化被硬裁剪，脏区外像素不被触碰），
        // 先用禁混合 clear draw 抹掉脏区旧像素（Metal 的 loadAction 无法只清
        // 一个子矩形）。scissor 是 per-pass 状态：嵌套 pass（子 opacity 层）
        // end 恢复本 pass 时由 applyOffscreenTargetViewport 从 damage_scissor
        // 重新取交；path renderer 自管的 scissor 经 damage_scissor 字段取交。
        // caller（tryBeginRetainedOpacityLayer）已用 ensureDamageClearPipeline
        // 预检过 —— 此处 pass/栈都已就位，不能失败。
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

// ----------------------------------------------------------------------------
// damage-rect：脏区 clear draw（Metal loadAction 只能整纹理清；子矩形清除 =
// scissor + 禁混合全屏三角形输出 (0,0,0,0)）。
// ----------------------------------------------------------------------------

const damage_clear_shader_source: []const u8 = @embedFile("shaders/damage_clear.metal");

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
        .color_attachment_formats = &[_]gpu.TextureFormat{.bgra8_unorm_srgb},
        // 禁混合：输出即最终像素 —— (0,0,0,0) 直写 = 清除。
        .blend_state = null,
    }) catch {
        encoder.persistent.damage_clear_pipeline_failed = true;
        return false;
    };
    return true;
}

/// 当前 render pass 内、当前 scissor 范围下发一个 clear draw。
fn drawDamageClear(encoder: anytype) bool {
    if (!ensureDamageClearPipeline(encoder)) return false;
    const pass = encoder.render_pass.?;
    pass.setPipeline(&encoder.persistent.damage_clear_pipeline.?);
    pass.draw(3, 1, 0, 0);
    return true;
}

/// 结束离屏 opacity 图层
/// 1. flush 离屏 pipeline → end 离屏 pass
/// 2. 重新 beginRenderPass 回到恢复目标（load 保留内容）
/// 3. 用 image pipeline 把离屏纹理以 opacity 混合回来
pub fn endOpacityLayer(encoder: anytype) !void {
    if (encoder.offscreen_depth == 0) return;
    if (encoder.gpu_command_encoder == null) return;
    encoder.offscreen_depth -= 1;
    const layer = encoder.offscreen_stack[encoder.offscreen_depth];
    // 池条目丢失属于状态错乱，但不能 unreachable（ReleaseFast 下是 UB）：
    // 缺 binding 时跳过 gutter blit 与 blend composite，仍走 image pipeline
    // 合成（texture_id 在开层时已注册）并正常恢复 pass。
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

    // 1. flush 离屏 pipeline。失败时本层已出栈、后面的第 7 步不会再跑 ——
    // 开层时注册的 texture_id 必须在这里注销，否则每次失败永久占一个 image
    // store 槽位。（retained 纹理此时未 markRetainedPrimed，下一帧必重画。）
    flushLayerBoundaryPipelines(encoder) catch |e| {
        if (encoder.image_renderer) |ir| ir.unregisterTextureBinding(layer.texture_id);
        return e;
    };

    // 2. end 离屏 render pass
    encoder.render_pass.?.end();
    // 同 begin 侧不变式：end 之后、restore pass 赋回之前（中间还要开 1-2 个
    // blit pass），encoder.render_pass 必须为 null，任何提前 return 都不能
    // 留下 stale 指针。
    encoder.render_pass = null;

    // 2.5 桶填充 gutter：把 used 边缘 1px 复制进相邻 padding，精确复现
    // clamp-to-edge 语义 —— 否则合成 bilinear 在 uv 裁剪边界会把贴边内容
    // （blur/rounded 容器的内容一直画到 used 边缘）与透明 padding 混合，
    // 露出一行 ≤3/255 的暗边。1px 足够：bilinear 只取相邻 texel。
    const pad_w = layer.alloc_tex_w > layer.used_tex_w and layer.used_tex_w > 0;
    const pad_h = layer.alloc_tex_h > layer.used_tex_h and layer.used_tex_h > 0;
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

    // 2.7 非 normal blend：合成需要读 dst。趁 restore pass 还没重开（blit 不能
    // 与 render pass 并存），把整个恢复目标 blit 一份副本。任何一步拿不到就
    // 保持 blend_dst_copy = null —— 下面第 7 步回退 normal 合成（语义降级，
    // 不出错、不丢内容）。use_draw_transform / rotate 的合成矩形非轴对齐，
    // v1 不支持，同样回退。
    var blend_dst_copy: ?TextureLease = null;
    var blend_target_w: u32 = 0;
    var blend_target_h: u32 = 0;
    const blend_mode_raw: u8 = @intCast(@intFromEnum(layer.blend_mode));
    // 轴对齐判定：促升 surface 统一走 draw_transform 合成，静态内容的矩阵其实
    // 只是 平移(+缩放)（b=c=0）。这类矩阵折算成矩形后 blend composite 照样支持；
    // 只有真旋转/斜切（b/c ≠ 0）才回退 normal。
    const blend_axis_aligned = !layer.use_draw_transform or
        (layer.draw_transform[1] == 0 and layer.draw_transform[2] == 0 and
            layer.draw_transform[0] > 0 and layer.draw_transform[3] > 0);
    if (blend_mode_raw != 0 and blend_axis_aligned and layer.rotate == 0 and
        layer_binding_opt != null and blend_composite.ensureBlendPipeline(encoder))
    {
        const tw = layer.restore_target.width;
        const th = layer.restore_target.height;
        if (tw > 0 and th > 0) {
            const device2 = encoder.sdf_renderer.device;
            const max_dim = encoder.sdf_renderer.device.limits.max_texture_dimension_2d;
            const copy_w = offscreen_texture.bucketDimension(tw, max_dim);
            const copy_h = offscreen_texture.bucketDimension(th, max_dim);
            if (encoder.offscreen_pool.acquire(device2, copy_w, copy_h, encoder.frame_index)) |copy| {
                if (encoder.offscreen_pool.binding(copy)) |copy_binding| {
                    if (encoder.gpu_command_encoder.?.beginBlitPass() catch null) |blit_value| {
                        var blit = blit_value;
                        const copied = blk: {
                            blit.copyTextureRegion(
                                layer.restore_target,
                                0,
                                0,
                                tw,
                                th,
                                copy_binding,
                                0,
                                0,
                            ) catch break :blk false;
                            break :blk true;
                        };
                        blit.end();
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
                } else {
                    _ = encoder.offscreen_pool.release(copy, encoder.frame_index);
                }
            }
        }
    }

    // 3. 重新 beginRenderPass 回到恢复目标
    var restore_view = layer.restore_target.createView();
    const restored_pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = restore_view,
            .load_op = .load,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch {
        // 恢复 pass 开不出来：render_pass 保持 null（上游按"未开层"跳过绘制），
        // 但资源必须收干净，否则每次失败漏一张纹理 + 一个 texture_id。
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

    // 4. 恢复状态
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

    // 5. 恢复父层光栅倍率与三 pipeline viewport
    encoder.scale = layer.saved_scale;
    const s = encoder.scale;
    encoder.sdf_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, s);
    encoder.text_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, s);
    if (encoder.image_renderer) |ir| ir.setViewport(encoder.viewport_width, encoder.viewport_height, s);
    if (encoder.icon_renderer) |ir| ir.setViewport(encoder.viewport_width, encoder.viewport_height, s);
    if (encoder.persistent.path_renderer) |*pr| pr.setViewport(encoder.viewport_width, encoder.viewport_height, s);

    // 恢复目标可能本身是按桶分配的离屏纹理 → viewport/scissor 限到其 used 区域
    encoder.applyOffscreenTargetViewport();
    encoder.syncRectClipState();
    encoder.syncRendererClipMask();
    encoder.syncTextClipX();

    // 纹理按桶分配、内容只占 [0, used)：合成按 used/alloc 裁 UV
    const uv_u: f32 = if (layer.alloc_tex_w > 0)
        @as(f32, @floatFromInt(layer.used_tex_w)) / @as(f32, @floatFromInt(layer.alloc_tex_w))
    else
        1;
    const uv_v: f32 = if (layer.alloc_tex_h > 0)
        @as(f32, @floatFromInt(layer.used_tex_h)) / @as(f32, @floatFromInt(layer.alloc_tex_h))
    else
        1;

    // 6.5 非 normal blend：用 blend composite pipeline 合成（全屏三角形，
    // rect 外 passthrough dst），跳过下面的 image pipeline 路径。
    var blend_done = false;
    if (blend_dst_copy) |copy| blend: {
        // copy 是几行前刚 acquire+binding 校验过的，但这里仍不许 unreachable
        // （ReleaseFast UB）：查不到就放弃 blend，走 normal 合成降级。
        const copy_binding = encoder.offscreen_pool.binding(copy) orelse {
            _ = encoder.offscreen_pool.release(copy, encoder.frame_index);
            std.log.warn("[opacity-layer] blend dst copy binding lost; falling back to normal composite", .{});
            break :blend;
        };
        const layer_binding = layer_binding_opt.?;
        // 合成矩形：transform 路径把 w×h 的 quad 经仿射映射到目标（轴对齐时
        // origin=(tx,ty)、size=(a·w, d·h)，先 localize 到当前目标帧）；
        // 非 transform 路径直接用 draw_x/y/w/h。均为逻辑单位 × scale → 物理 px。
        var rect_origin: [2]f32 = undefined;
        var rect_size: [2]f32 = undefined;
        var cr_scale: f32 = 1.0;
        if (layer.use_draw_transform) {
            const lt = encoder.localizeDrawTransformForCurrentTarget(layer.draw_transform);
            rect_origin = .{ lt[4] * encoder.scale, lt[5] * encoder.scale };
            rect_size = .{ lt[0] * layer.w * encoder.scale, lt[3] * layer.h * encoder.scale };
            cr_scale = (lt[0] + lt[3]) * 0.5;
        } else {
            rect_origin = .{ layer.draw_x * encoder.scale, layer.draw_y * encoder.scale };
            rect_size = .{
                (if (layer.draw_w > 0) layer.draw_w else layer.w) * encoder.scale,
                (if (layer.draw_h > 0) layer.draw_h else layer.h) * encoder.scale,
            };
        }
        blend_done = blend_composite.drawBlendComposite(
            encoder,
            layer_binding,
            copy_binding,
            blend_target_w,
            blend_target_h,
            rect_origin,
            rect_size,
            .{ uv_u, uv_v },
            layer.opacity,
            blend_mode_raw,
            layer.corner_radius * cr_scale * encoder.scale,
        );
        // 副本本帧被 GPU 采样，走带 REUSE_LAG 保护的正常归还。
        _ = encoder.offscreen_pool.release(copy, encoder.frame_index);
    }
    if (blend_done) {
        if (encoder.image_renderer) |ir| ir.unregisterTextureBinding(layer.texture_id);
    } else
    // 7. 用 image pipeline 把离屏纹理以 opacity 混合回恢复目标
    if (encoder.image_renderer) |ir| {
        if (layer.use_draw_transform) {
            try ir.addImageUVWithTransform(
                layer.texture_id,
                layer.w,
                layer.h,
                .{ 0, 0, uv_u, uv_v },
                .{ 1, 1, 1, 1 },
                layer.corner_radius,
                layer.opacity,
                encoder.localizeDrawTransformForCurrentTarget(layer.draw_transform),
                true,
            );
        } else {
            try ir.addImageUVPremultiplied(
                layer.texture_id,
                layer.draw_x,
                layer.draw_y,
                if (layer.draw_w > 0) layer.draw_w else layer.w,
                if (layer.draw_h > 0) layer.draw_h else layer.h,
                .{ 0, 0, uv_u, uv_v },
                .{ 1, 1, 1, 1 },
                layer.corner_radius,
                layer.opacity,
                layer.rotate,
            );
        }
        try ir.flush(encoder.render_pass.?);
        ir.unregisterTextureBinding(layer.texture_id);
    }
    if (encoder.icon_renderer) |ir| try ir.flush(encoder.render_pass.?);

    // 8. 纹理归还
    if (layer.retained_id != INVALID_SURFACE_ID) {
        // GPU retained：这张纹理归本 layer 独占持有，**不还回池**。内容刚刚画完，
        // 标记 primed —— 下一帧同 content_version 就能直接命中、跳过整个内容 pass。
        _ = encoder.offscreen_pool.markRetainedPrimed(layer.texture);
        // damage-rect：把本帧的 per-item 基线写进条目，供下一帧 miss 时 diff。
        // 捕获不完整（非平坦层/溢出/序号超界）就置 invalid —— 下一帧整层重画。
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

// ============================================================================
// GPU retained 合成
// ----------------------------------------------------------------------------
// 目标（审查报告「仍未做」第 2 项）：**内容未变时只做 transform/opacity 合成**。
//
// 在此之前：即便 CPU 侧命令来自缓存（render_engine 直接 splice 上一帧命令区段）、
// 纹理来自池（按尺寸复用），beginOpacityLayer 仍会把这些命令**重新光栅化**进
// 那张复用的纹理 —— 内容没变也照画一遍。省的只是 CPU，GPU 一点没省。
//
// 现在：按 **layer 身份**（surface_stable_id，跨帧稳定、含 generation ABA 防护）
// 持有专属纹理，配合 content_version 判断内容是否变化。命中时整段内容命令被
// dispatchCommand 跳过，只留一次带 transform/opacity 的合成 draw。
//
// **安全方向**：任何不确定都必须判为未命中（多画一遍），因为判错的后果是画面
// 显示上一帧的陈旧内容。以下情况一律不走 retained：
//   - surface_stable_id == INVALID（该 layer 没有稳定身份）
//   - 尺寸变化（旧像素无意义）
//   - 纹理还没被画过（retained_primed == false）
//   - content_version 不等
//   - 池满、拿不到跨帧持有的槽位
// ============================================================================

/// display_list.INVALID_SURFACE_ID 的镜像。encoder 侧不引 ui-side type，
/// 这里按值重复一份；两边必须一致（有 comptime 断言在 command_encoder 里对不上）。
pub const INVALID_SURFACE_ID: u32 = std.math.maxInt(u32);

comptime {
    // 两个哨兵必须完全一致：encoder 侧不引 ui-side type，这份是手抄的副本。
    // 对不上会让"不参与 retained"的 layer 被当成合法身份，全部共用一张纹理
    // 互相覆写 —— 画面级 bug 且难查。这里在编译期钉死。
    std.debug.assert(INVALID_SURFACE_ID == offscreen_texture.NO_RETAINED_OWNER);
}

/// `tryBeginRetainedOpacityLayer` 的三种结果。
///
/// 曾经用 bool 表达，导致一个真实 bug：miss 分支**已经开好了离屏层**（画进专属
/// 纹理），但返回 false 被 caller 当成"retained 没接手"，于是又调一次普通
/// `beginOpacityLayer` —— 同一段内容套了两层离屏，Modal/Sheet 整块画不出来。
/// 三态把"我已经接手了"和"你自己来"彻底分开。
pub const RetainedBegin = enum {
    /// 命中：内容 pass 整个跳过，caller 在配对的 end 处调 `compositeRetainedLayer`。
    hit,
    /// 未命中但**本函数已经开好了离屏层**（画进专属纹理）。caller 什么都不用做，
    /// 内容命令照常编码，走普通 endOpacityLayer 收尾。
    opened_for_repaint,
    /// 没接手。caller 走原来的 beginOpacityLayer（每帧重画）。
    declined,
};

/// 尝试走 GPU retained 路径。返回值语义见 `RetainedBegin`。
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
    corner_radius: f32,
    surface_stable_id: u32,
    surface_content_version: u64,
    content_seq: usize,
) !RetainedBegin {
    if (surface_stable_id == INVALID_SURFACE_ID) return .declined;
    // 诊断逃生阀：ZENIT_NO_RETAINED=1 全部走每帧重画路径
    if (debug_env.flag("ZENIT_NO_RETAINED")) return .declined;
    if (encoder.render_pass == null) return .declined;
    // 非 normal blend 不走 retained：混合结果依赖 dst（背景每帧可变），
    // 且 hit 路径的合成要做 dst blit + pass 切换，v1 不值得为罕见场景做。
    if (@intFromEnum(blend_mode) != 0) return .declined;
    // 只在**顶层**走 retained。嵌套在别的离屏层里时，本层内容的光栅化结果依赖
    // 外层的 viewport/clip/坐标系；跨帧复用一张在不同外层上下文里画出来的纹理
    // 不安全。顶层之外一律降级为每帧重画。
    if (encoder.offscreen_depth != 0) return .declined;
    // 放大合成的层按放大后的倍率光栅化（见 layerMagnification）；retained 纹理按父倍率
    // 固定尺寸，缩放动画期间倍率每帧在变——一律走普通路径。
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
        // 认领成功但内容要重画。走普通 begin 路径，但**画进这张专属纹理**，
        // 画完在 end 处 markRetainedPrimed —— 下一帧同版本就能命中。
        encoder.retained_misses += 1;

        // damage-rect：旧像素仍有效（primed + 同尺寸）且本层是"平坦层"
        // （捕获完整、无嵌套 pass/path/clip）时，diff 出脏区只重画脏区。
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
        // 只有真的压栈成功才打 retained 标记 —— 否则会把标记盖到**外层**
        // 那个无关的 layer 上，导致它的临时纹理被当成 retained 永不归还。
        if (pushed and encoder.offscreen_depth > 0) {
            // layer_tree 写回：本层实际决策（1=整层重画 2=部分重绘，local space）
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
            if (corner_radius >= 0.5) {
                encoder.offscreen_stack[encoder.offscreen_depth - 1].corner_radius = corner_radius;
            }
            return .opened_for_repaint;
        }
        // 没开成层：这张专属纹理本帧没被画，撤销认领避免下帧误判 primed，
        // 并让 caller 走普通路径重新开层。
        encoder.offscreen_pool.dropRetained(surface_stable_id, encoder.frame_index);
        return .declined;
    }

    // 命中：内容像素已经是本帧要的，整个内容 pass 都不用跑。
    encoder.retained_hits += 1;
    // layer_tree 写回：cache hit，本帧零重绘。
    encoder.recordLayerOutcome(surface_stable_id, 0, .{ 0, 0, 0, 0 });
    // 坐标按 **outer-local** 存（与 OffscreenLayer 的 x/y 同语义）：
    // 普通路径 endOpacityLayer 是在 `offscreen_depth -= 1` **之后**合成的，
    // 那时 offscreenOffset() 已经回到父层视角；这里我们压根没压栈，当前
    // offset 本来就是父层视角 —— 所以合成时 localizeDrawTransformForCurrentTarget
    // 会再加一次 offset。存的时候不能预先加，否则**偏移算两遍**。
    // （这正是 Modal 首次接线时对话框画不出来的原因：scale-fade 的
    //   draw_transform 被平移了两倍，整个内容飞出了可见区域。）
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
        .corner_radius = corner_radius,
        .used_tex_w = tex_w,
        .used_tex_h = tex_h,
        .alloc_tex_w = alloc_w,
        .alloc_tex_h = alloc_h,
    };
    encoder.retained_pending_depth += 1;
    return .hit;
}

/// damage-rect：miss 时 diff 上一帧基线与本帧捕获，算出 texture-local 脏区。
/// 返回 null = 不满足部分重绘条件（整层重画，永远安全的降级方向）。
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
    // 逃生阀：ZENIT_DISABLE_PARTIAL_REPAINT=1 强制整层重画（下方注释：
    // "永远安全的降级方向"）。下游应用 Layers 面板实测:行重建(虚拟列表
    // rebind,大量 item 插入/删除)+滚动 translate+opacity 高频变化组合下,
    // 部分重绘把悬停键画到错位位置(残影);禁用后消失。定位/修复期间用。
    if (debug_env.flag("ZENIT_DISABLE_PARTIAL_REPAINT")) return null;
    if (content_seq >= encoder.damage_ranges.len) return null;
    const range = encoder.damage_ranges[content_seq];
    if (!range.captured or !range.safe or range.overflow) return null;
    const prev = encoder.offscreen_pool.retainedDamageItems(surface_stable_id) orelse return null;
    const cur = encoder.damage_scratch[range.start .. range.start + range.len];
    const dbg = debug_env.flag("ZENIT_DEBUG_SURFDUMP");
    // clear draw pipeline 不可用就没有部分重绘（脏区旧像素抹不掉）。
    if (!ensureDamageClearPipeline(encoder)) {
        if (dbg) std.debug.print("[damage] null: clear pipeline unavailable id={d}\n", .{surface_stable_id});
        return null;
    }

    // index 对齐 diff：插入/删除会造成后缀整体位移 —— 位移条目全部计入脏区
    // （过量但安全）。
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
        // digest 或 bounds 任一变化都算脏：digest 不含位置的条目在
        // "内容没变但布局位移"时（例如兄弟层动画后回位）必须重画，
        // 否则旧纹理残留旧位置像素，与重画条目拼成错位画面（实锤：
        // 面板 morph 后对面 Inspector 的行错位/丢行）。
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
    // 指纹变了但 item diff 为空：变化在 item 之外（scale/合成参数等），
    // 无法定位脏区 —— 整层重画。
    if (!any) {
        if (dbg) std.debug.print("[damage] null: empty item diff id={d} prev_n={d} cur_n={d}\n", .{ surface_stable_id, prev.len, cur.len });
        return null;
    }

    // layer_tree damage 通路合流：生产端（addDamage）为本层显式申报的脏区
    // 并入（local space → 全局逻辑坐标）。安全方向 —— 只放大脏区。
    var k: usize = 0;
    while (k < encoder.layer_damage_count) : (k += 1) {
        if (encoder.layer_damage_ids[k] != surface_stable_id) continue;
        const r = encoder.layer_damage_rects[k];
        unionBounds(&min_x, &min_y, &max_x, &max_y, .{ x + r[0], y + r[1], r[2] - r[0], r[3] - r[1] });
        break;
    }

    // 转 texture-local 物理像素（+1px 安全 pad），clamp 到 used 区域。
    const lx = @max((min_x - x) * s - 1, 0);
    const ly = @max((min_y - y) * s - 1, 0);
    const hx = @min((max_x - x) * s + 1, @as(f32, @floatFromInt(tex_w)));
    const hy = @min((max_y - y) * s + 1, @as(f32, @floatFromInt(tex_h)));
    if (hx <= lx or hy <= ly) {
        if (dbg) std.debug.print("[damage] null: degenerate rect id={d}\n", .{surface_stable_id});
        return null; // 脏区完全在层外（bounds 异常）→ 保守整层重画
    }
    const px: u32 = @intFromFloat(@floor(lx));
    const py: u32 = @intFromFloat(@floor(ly));
    const pw: u32 = @intFromFloat(@ceil(hx - lx));
    const ph: u32 = @intFromFloat(@ceil(hy - ly));

    // 脏区太大（>60% 层面积）就不值得：整层重画省掉 clear draw 与 diff 复杂度。
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

/// layer 边界（begin / end / retained 合成点）的 pipeline 落盘。
/// 同一 render pass 内 draw 顺序 = flush 顺序，必须与 RenderCommandEncoder.flush
/// 的规范顺序 sdf → image → icon → text 一致；三处调用点共用这一份，避免
/// 某一处顺序漂移（retained hit 路径曾是 sdf→icon→text，漏 image）。
pub fn flushLayerBoundaryPipelines(encoder: anytype) !void {
    const rp = encoder.render_pass.?;
    try encoder.sdf_renderer.flush(rp);
    if (encoder.image_renderer) |ir| try ir.flush(rp);
    if (encoder.icon_renderer) |ir| try ir.flush(rp);
    try encoder.text_renderer.flush(rp);
}

/// retained 命中时的合成：把缓存纹理以 transform/opacity 混合回当前目标。
/// 等价于 endOpacityLayer 的第 7 步，但不需要 end/begin render pass ——
/// 我们从没离开过当前 pass（内容 pass 整个被跳过了）。
pub fn compositeRetainedLayer(encoder: anytype) !void {
    if (encoder.retained_pending_depth == 0) return;
    encoder.retained_pending_depth -= 1;
    const layer = encoder.retained_pending[encoder.retained_pending_depth];
    if (encoder.render_pass == null) return;

    // 先把 layer 之下已批入但尚未 flush 的实例落盘（2026-07-30 审查修正）。
    // 同一 render pass 内 draw 顺序 = flush 顺序：不先 flush 的话，这些本应
    // 垫底的 sdf/text/icon 内容会在 layer 合成**之后**才画 —— 被画到 retained
    // layer 上面，paint-order 反转。普通路径的 beginOpacityLayer 第 1 步就是
    // 这四个 flush，hit 路径跳过了 begin，必须在合成点补上。
    // ⚠ 顺序必须与普通路径一致（sdf→image→icon→text）：此前这里少了 image
    // 且把 icon 提到 text 前 —— 层下方待刷的图片会被画在待刷文本**之上**，
    // hit 帧与 miss 帧 z 序不同（闪烁）。统一走同一个 helper。
    try flushLayerBoundaryPipelines(encoder);

    const ir = encoder.image_renderer orelse return;
    const texture_binding = encoder.offscreen_pool.binding(layer.texture) orelse return;
    const tex_id = ir.registerTextureBinding(texture_binding, layer.alloc_tex_w, layer.alloc_tex_h) catch return;
    defer ir.unregisterTextureBinding(tex_id);

    const uv_u: f32 = if (layer.alloc_tex_w > 0)
        @as(f32, @floatFromInt(layer.used_tex_w)) / @as(f32, @floatFromInt(layer.alloc_tex_w))
    else
        1;
    const uv_v: f32 = if (layer.alloc_tex_h > 0)
        @as(f32, @floatFromInt(layer.used_tex_h)) / @as(f32, @floatFromInt(layer.alloc_tex_h))
    else
        1;

    if (layer.use_draw_transform) {
        // draw_transform 存的是**未本地化**的原值：普通路径也是在弹栈后才
        // localize，此处当前 offscreen 视角与那时一致，所以这里 localize 一次
        // 即可。存的时候若已加过 offset 就会算两遍（Modal 空白的真因）。
        try ir.addImageUVWithTransform(
            tex_id,
            layer.w,
            layer.h,
            .{ 0, 0, uv_u, uv_v },
            .{ 1, 1, 1, 1 },
            layer.corner_radius,
            layer.opacity,
            encoder.localizeDrawTransformForCurrentTarget(layer.draw_transform),
            true,
        );
    } else {
        try ir.addImageUVPremultiplied(
            tex_id,
            layer.draw_x,
            layer.draw_y,
            if (layer.draw_w > 0) layer.draw_w else layer.w,
            if (layer.draw_h > 0) layer.draw_h else layer.h,
            .{ 0, 0, uv_u, uv_v },
            .{ 1, 1, 1, 1 },
            layer.corner_radius,
            layer.opacity,
            layer.rotate,
        );
    }
    try ir.flush(encoder.render_pass.?);
}

// ============================================================================
// 回归守卫
// ============================================================================

test "RetainedBegin: three distinct outcomes (bool would conflate two)" {
    // 这条测试守的是一个真实 bug（2026-07-30）：本函数曾返回 bool。
    // miss 分支**已经开好了离屏层**（内容画进专属纹理）却返回 false，caller 把
    // false 当成"retained 没接手"，于是又调一次普通 beginOpacityLayer ——
    // 同一段内容被套了两层离屏，Modal / Sheet 整块渲染不出来（e2e 逮到）。
    //
    // 三个值必须互不相等，且 `opened_for_repaint` 必须与 `declined` 分开 ——
    // 前者的语义是"caller 什么都别做"，后者是"caller 自己开层"。
    const testing = std.testing;
    try testing.expect(RetainedBegin.hit != RetainedBegin.opened_for_repaint);
    try testing.expect(RetainedBegin.opened_for_repaint != RetainedBegin.declined);
    try testing.expect(RetainedBegin.hit != RetainedBegin.declined);
}

test "INVALID_SURFACE_ID matches the pool's no-owner sentinel" {
    // comptime 已经钉过一次；这里再给一条运行时断言，改动时更容易看懂失败原因。
    try std.testing.expectEqual(offscreen_texture.NO_RETAINED_OWNER, INVALID_SURFACE_ID);
}

test "compositeRetainedLayer: hit 路径 flush 顺序与普通路径一致（sdf→image→icon→text）" {
    // 回归：hit 路径曾按 sdf→icon→text 落盘、漏 image —— 层下方待刷图片被
    // 画在待刷文本之上，hit 帧与 miss 帧 z 序不同。
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
        pub fn addImageUVWithTransform(_: *@This(), _: u32, _: f32, _: f32, _: [4]f32, _: [4]f32, _: f32, _: f32, _: [6]f32, _: bool) !void {}
        pub fn addImageUVPremultiplied(_: *@This(), _: u32, _: f32, _: f32, _: f32, _: f32, _: [4]f32, _: [4]f32, _: f32, _: f32, _: f32) !void {}
    };
    const Pool = struct {
        pub fn binding(_: *@This(), _: u8) ?u8 {
            return null; // 合成前就退出：本测试只看 flush 顺序
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
        corner_radius: f32 = 0,
        used_tex_w: u32 = 0,
        used_tex_h: u32 = 0,
        alloc_tex_w: u32 = 0,
        alloc_tex_h: u32 = 0,
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
    // 回归：离屏 beginRenderPass 失败后补开的父 pass 用默认 viewport（整张
    // 桶化 alloc 纹理），父层后续内容被拉伸、damage scissor 丢失。
    // backdrop_blur.restoreRenderTargetPass 早就调 applyOffscreenTargetViewport。
    const Pass = struct { id: u32 = 0 };
    const Layer = struct { render_pass: Pass = .{} };
    const Enc = struct {
        offscreen_depth: usize = 1,
        offscreen_stack: [2]Layer = .{ .{}, .{} },
        render_pass: ?*Pass = null,
        viewport_applied: u32 = 0,
        pub fn applyOffscreenTargetViewport(self: *@This()) void {
            // 必须在新 pass 挂上之后调用（它从 render_pass 取目标）
            if (self.render_pass != null) self.viewport_applied += 1;
        }
    };
    var enc = Enc{};
    adoptRestoredPass(&enc, Pass{ .id = 7 });
    try std.testing.expectEqual(@as(u32, 7), enc.render_pass.?.id);
    try std.testing.expect(enc.render_pass.? == &enc.offscreen_stack[0].render_pass);
    try std.testing.expectEqual(@as(u32, 1), enc.viewport_applied);
}
