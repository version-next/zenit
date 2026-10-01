/// Blend Composite，非 normal 混合模式的离屏图层合成
///
/// 2026-07-30 接线。此前 blend_mode 的管线状态是"两头都断"：
/// - 生产端：没有任何公共 API 能设出非 normal（本次在 StyleExt 补 blend_mode）；
/// - 消费端：OffscreenLayer.blend_mode 存了但从未被读取，endOpacityLayer 的
///   image pipeline 合成只有单一 SrcOver blend state, multiply/screen 等
///   全部静默退化成 normal。
/// 下游编辑器（source of truth）同样停在"shader 写了但没接线"，它的
/// shaders/composite.metal 是孤儿文件，本模块的混合函数从它移植。
///
/// 方案：非 normal 混合需要读 dst（固定功能 blend factor 只能表达 multiply/
/// screen 的近似，overlay/soft_light 等根本表达不了），走 W3C 通用路径：
///   1. 离屏内容 pass 结束后、恢复 pass 重开前，把整个恢复目标 blit 一份
///      副本（dst copy，从池借临时纹理）；
///   2. 恢复 pass 里画一个全屏三角形：fragment 对 rect 内的像素做
///      unpremul -> B(Cd,Cs) -> SrcOver 复合 -> premul，rect 外原样回写 dst
///      （等价 passthrough，不改变像素）；pipeline 无 blend state（replace）。
///
/// 已知边界（v1，均回退 normal 合成而不是出错）：
/// - use_draw_transform / rotate ≠ 0：合成矩形非轴对齐，全屏 UV 映射不成立；
/// - GPU retained 缓存对非 normal blend 直接 decline（每帧重画），混合结果
///   依赖 dst，缓存 src 内容虽仍成立，但为省 pass 切换复杂度 v1 不做。
/// - 混合计算在采样后的线性空间进行（bgra8_unorm_srgb 采样自动去 sRGB），
///   与 CSS 规范的非线性空间略有色差，与下游编辑器参考实现一致，不单独校正。
const std = @import("std");
const gpu = @import("gpu");
const offscreen_texture = @import("offscreen_texture.zig");

pub var blend_pipeline_compile_count: u64 = 0;

comptime {
    // setFragmentBytes 上限 4 KiB（Metal 规范）。
    std.debug.assert(@sizeOf(BlendUniforms) <= 4096);
}

pub const BlendUniforms = extern struct {
    /// 恢复目标物理像素尺寸（fragcoord -> uv 用）
    target_size: [2]f32,
    /// 图层矩形在目标上的物理像素 origin/size
    rect_origin: [2]f32,
    rect_size: [2]f32,
    /// src 纹理 UV 缩放（used/alloc，64px 桶分配的裁剪）
    src_uv_scale: [2]f32,
    /// x = opacity, y = blend_mode（as float）, z = corner_radius(物理px), w 备用
    params: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(BlendUniforms) == 48);
}

const blend_shader_source: []const u8 = @embedFile("shaders/composite.metal");

/// lazy 编译 blend composite pipeline（模式同 backdrop_blur.ensureBlurPipeline）。
pub fn ensureBlendPipeline(encoder: anytype) bool {
    if (encoder.persistent.blend_pipeline != null) return true;
    if (encoder.persistent.blend_pipeline_failed) return false;
    blend_pipeline_compile_count += 1;

    const device = encoder.sdf_renderer.device;
    var shader = gpu.Backend.ShaderModule.initFromSource(device, blend_shader_source) catch |e| {
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
        .color_attachment_formats = &[_]gpu.TextureFormat{.bgra8_unorm_srgb},
        // 无 blend state：shader 输出即最终像素（rect 外 passthrough dst）。
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

/// 在**当前已打开的 render pass** 里画 blend composite 全屏三角形。
/// caller 负责：dst_copy 已含恢复目标当前内容、pass attach 的就是恢复目标。
pub fn drawBlendComposite(
    encoder: anytype,
    src_texture: gpu.Backend.TextureBinding,
    dst_copy: gpu.Backend.TextureBinding,
    target_w: u32,
    target_h: u32,
    rect_origin_px: [2]f32,
    rect_size_px: [2]f32,
    src_uv_scale: [2]f32,
    opacity: f32,
    blend_mode_raw: u8,
    corner_radius_px: f32,
) bool {
    if (encoder.render_pass == null) return false;
    var pipeline = encoder.persistent.blend_pipeline orelse return false;
    var sampler_state = encoder.persistent.blur_sampler orelse return false;

    encoder.persistent.blend_uniform_write_offset += 1;

    const uniforms = BlendUniforms{
        .target_size = .{ @floatFromInt(target_w), @floatFromInt(target_h) },
        .rect_origin = rect_origin_px,
        .rect_size = rect_size_px,
        .src_uv_scale = src_uv_scale,
        .params = .{ opacity, @floatFromInt(blend_mode_raw), corner_radius_px, 0 },
    };

    var pass = encoder.render_pass.?;
    pass.setPipeline(&pipeline);
    // setFragmentBytes：encode 时拷贝，在飞帧不会被下一帧覆写（曾是单个共享
    // buffer + 每帧偏移归零的 CPU/GPU 竞争）。
    pass.setFragmentBytes(0, std.mem.asBytes(&uniforms));
    pass.setFragmentTextureBinding(0, src_texture);
    pass.setFragmentTextureBinding(1, dst_copy);
    pass.setFragmentSampler(0, &sampler_state);
    pass.draw(3, 1, 0, 0);
    return true;
}
