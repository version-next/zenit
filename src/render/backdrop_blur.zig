/// Backdrop blur 子系统，从 command_encoder.zig 析出
///
/// 包含 Dual Kawase 模糊管线 + Liquid Glass composite。所有公共入口都接受
/// `encoder: anytype`，避免与 RenderCommandEncoder 形成循环 import。
const std = @import("std");
const gpu = @import("gpu");
const TextureLease = @import("offscreen_texture.zig").TextureLease;
const debug_env = @import("debug_env.zig");

/// 资源缺失导致 pass 被跳过时打一次警告（每种资源一条，避免逐帧刷屏），
/// 恒返回 false 供 `orelse return warnPassSkipped(...)` 内联使用。
fn warnPassSkipped(comptime what: []const u8) bool {
    const S = struct {
        var warned: bool = false;
    };
    if (!S.warned) {
        std.log.warn("[backdrop-blur] " ++ what ++ " unavailable; pass skipped (degraded output)", .{});
        S.warned = true;
    }
    return false;
}

const blur_shader_source: []const u8 = @embedFile("shaders/blur.metal");
const glass_shader_source: []const u8 = @embedFile("shaders/glass.metal");

/// backdrop blur 链深上调所需的连续成功帧数（帧间迟滞，见
/// PersistentGpuCache.blur_level_slots）。
///
/// 定这个数的两端约束：
/// - 下限：观测到的振荡周期是 3 帧，offscreen_texture.zig 的
///   `REUSE_LAG_FRAMES = 3` 决定（retained miss 的层「画一帧 -> 被拒两帧」）。
///   N 必须 **≥ 3** 才能跨过一整个周期；N=1/2 时「被拒两帧」中间那次成功
///   仍会把级数顶上去，迟滞形同虚设。
/// - 上限：N 帧是「窗口变大/玻璃变少之后模糊迟迟不变清晰」的可见延迟。
///   60Hz 下 N=6 ≈ 100ms，属于「渐进式画质回升」而非瑕疵（对比：级数跳变
///   是**周期性**闪，任何幅度都可见）。再大就会在拖拽缩放窗口时出现肉眼
///   可辨的「糊了一下才恢复」。
///
/// 取 6 = 2 个完整 REUSE_LAG 周期，留一倍余量对抗相位对齐的巧合。
pub const BLUR_LEVEL_RAISE_FRAMES: u32 = 6;

/// 迟滞状态的纯值形式（与 PersistentGpuCache.BlurLevelSlot 的三个计数字段
/// 一一对应）。抽出来是为了让状态机可单测，真机路径要 GPU 池。
pub const BlurLevelState = struct { committed: u32 = 0, streak: u32 = 0, backoff: u32 = 0 };

/// 本帧允许的链深上限。
/// - committed == 0：无历史（首帧 / 槽换主）-> 不设限，一次到位。
/// - streak 到达阈值 -> 放行一次「上调尝试」（允许到 max_levels）。
/// - 否则压在上一帧实际提交的级数（降级立即生效已由 committed 天然承载）。
///
/// 上调尝试的间隔：基准 BLUR_LEVEL_RAISE_FRAMES，每次尝试失败翻倍
/// （上限 8× ≈ 48 帧 / 0.8s）。硬饱和（池永远给不出下一级）时若不退避，
/// 就从「每 3 帧闪」变成「每 N 帧闪」，频率降了但仍是可见的周期性跳变。
pub fn levelCap(committed: u32, streak: u32, backoff: u32, max_levels: u32) u32 {
    if (committed == 0) return max_levels;
    const threshold = BLUR_LEVEL_RAISE_FRAMES *| (@as(u32, 1) << @intCast(@min(backoff, 3)));
    if (streak +| 1 >= threshold) return max_levels;
    return @min(max_levels, committed);
}

/// 一帧结束后推进迟滞状态。`cap` 是本帧用过的上限，`actual` 是实际跑出的级数。
pub fn levelSettle(prev: BlurLevelState, cap: u32, actual: u32, max_levels: u32) BlurLevelState {
    var next = prev;
    next.committed = actual;
    if (cap < max_levels) {
        // 被迟滞压住：跑满上限就累计，没跑满说明池连当前级数都给不出 -> 清零
        // （连续性是迟滞的全部意义）。
        next.streak = if (actual >= cap) prev.streak +| 1 else 0;
        return next;
    }
    // 本帧放行到 max_levels：要么是一次上调尝试，要么本来就没被压住。
    next.streak = 0;
    if (prev.committed != 0 and prev.committed < max_levels) {
        next.backoff = if (actual > prev.committed) 0 else prev.backoff +| 1;
    } else if (actual >= max_levels) {
        next.backoff = 0;
    }
    return next;
}

pub const max_kawase_uniform_updates: u32 = 512;
// 512 × 128B = 64KB，一次性分配。旧值 128 偏低：超限后每个 glass composite
// 都在渲染热路径上 createBuffer+destroy（driver 分配 + page_allocator mmap）。
pub const max_glass_uniform_updates: u32 = 512;
comptime {
    // uniform 走 setFragmentBytes，Metal 规范上限 4 KiB。
    std.debug.assert(@sizeOf(KawaseUniforms) <= 4096);
    std.debug.assert(@sizeOf(GlassUniforms) <= 4096);
}

pub const KawaseUniforms = extern struct {
    texel_size: [2]f32,
    offset_scale: f32,
    _padding: f32 = 0,
    /// 源纹理内"真实背板"的 uv 子矩形 {x0, y0, x1, y1}。默认全 1 = 整张有效。
    ///
    /// capture 纹理按 64px 桶分配（池复用所需），实际只 blit 进
    /// copy_w×copy_h，右/下那圈 pad 被 clear 成透明黑且永不写入。不钳的话
    /// Kawase 会把这圈黑逐级糊进有效内容（半径 180 -> 链深 6 级，污染极远），
    /// 表现为背板被冲淡 + 边缘糊出一团灰。钳进有效区 = 对边界做 clamp-to-edge
    /// 延展，与 CSS backdrop-filter / Core Image 的边界语义一致。
    valid_uv: [4]f32 = .{ 0, 0, 1, 1 },
};

comptime {
    // Metal 侧 KawaseUniforms 的 valid_uv 必须落在 float4 对齐位（16B）。
    if (@offsetOf(KawaseUniforms, "valid_uv") != 16) @compileError("KawaseUniforms.valid_uv must match Metal layout");
}

pub const GlassUniforms = extern struct {
    texel_size: [2]f32,
    corner_radius: f32,
    glass_intensity: f32,
    rect_size: [2]f32,
    scale_factor: f32,
    _padding0: f32 = 0,
    glass_tint: [4]f32,
    specular_params: [4]f32 = .{ 0.35, 6.0, 1.0, 1.0 },
    optic_params: [4]f32 = .{ 1.0, 4.0, 0.0, 0.0 },
    surface_params: [4]f32 = .{ 2.0, 0.18, -std.math.pi / 3.0, 0.0 },
    bottom_surface_params: [4]f32 = .{ 0.0, 0.12, 0.0, 0.0 },
    lens_params: [4]f32 = .{ 0.58, 2.2, 1.0, 1.0 },
    /// 玻璃矩形在 padded capture 纹理内的 uv 子区（off_x, off_y, scale_x, scale_y）
    content_uv: [4]f32 = .{ 0, 0, 1, 1 },
    /// blur 渐变：{direction(0=off/1=to_bottom/2=to_top/3=to_right/4=to_left), 保留, 全局强度 0~1, stop 个数}
    edge_params: [4]f32 = .{ 0, 0, 0, 0 },
    /// blur 渐变 stop 位置（0~1 占节点沿渐变轴尺寸百分比，升序，尾部填末值）
    edge_stop_pos: [4]f32 = .{ 0, 1, 1, 1 },
    /// blur 渐变 stop 强度（0~1）
    edge_stop_str: [4]f32 = .{ 1, 0, 0, 0 },
    /// capture 纹理内"真实背板"uv 子矩形 {x0, y0, x1, y1}。pad 越出窗口 RT 的
    /// 部分是透明黑，采样必须钳进该区，否则贴边 glass 的 rim 位移采到纯黑。
    valid_uv: [4]f32 = .{ 0, 0, 1, 1 },
};

comptime {
    if (@offsetOf(GlassUniforms, "glass_tint") != 32) @compileError("GlassUniforms.glass_tint must match Metal layout");
    if (@offsetOf(GlassUniforms, "specular_params") != 48) @compileError("GlassUniforms.specular_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "optic_params") != 64) @compileError("GlassUniforms.optic_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "surface_params") != 80) @compileError("GlassUniforms.surface_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "bottom_surface_params") != 96) @compileError("GlassUniforms.bottom_surface_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "lens_params") != 112) @compileError("GlassUniforms.lens_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "content_uv") != 128) @compileError("GlassUniforms.content_uv must match Metal layout");
    if (@offsetOf(GlassUniforms, "edge_params") != 144) @compileError("GlassUniforms.edge_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "edge_stop_pos") != 160) @compileError("GlassUniforms.edge_stop_pos must match Metal layout");
    if (@offsetOf(GlassUniforms, "edge_stop_str") != 176) @compileError("GlassUniforms.edge_stop_str must match Metal layout");
    if (@offsetOf(GlassUniforms, "valid_uv") != 192) @compileError("GlassUniforms.valid_uv must match Metal layout");
    if (@sizeOf(GlassUniforms) != 208) @compileError("GlassUniforms size must match Metal layout");
}

pub const KawasePassKind = enum { downsample, upsample };

pub var blur_pipeline_compile_count: u64 = 0;

pub fn ensureBlurPipeline(encoder: anytype) bool {
    // 粘性失败标记：只试一次。否则持久失败（Metal 编译器异常/源码回归）时
    // 每个 blur 帧重新 newLibraryWithSource 编译整份源码（十毫秒级）+ 刷屏。
    // 样板同 opacity_layer.ensureDamageClearPipeline。
    if (encoder.persistent.blur_pipeline_failed) return false;
    if (encoder.persistent.blur_downsample_pipeline == null) {
        blur_pipeline_compile_count += 1;
        if (!buildBlurPipeline(encoder)) {
            encoder.persistent.blur_pipeline_failed = true;
            return false;
        }
    }
    // glass 有独立失败标记：blur 建好后 glass 持久失败同样不能每帧重编译。
    // glass 失败不影响返回值，调用方可以继续走纯 blur+tint 退化路径。
    if (encoder.persistent.glass_pipeline == null and !encoder.persistent.glass_pipeline_failed) {
        if (!buildGlassPipeline(encoder)) {
            encoder.persistent.glass_pipeline_failed = true;
            std.log.err("[glass] pipeline setup failed — glass 节点退化为纯 blur+tint（本消息只报一次）", .{});
        }
    }
    return true;
}

fn buildBlurPipeline(encoder: anytype) bool {
    const device = encoder.sdf_renderer.device;
    var shader = gpu.Backend.ShaderModule.initFromSource(device, blur_shader_source) catch |e| {
        std.log.err("[blur] shader compile failed: {} — backdrop blur 永久停用（本消息只报一次）", .{e});
        return false;
    };
    defer shader.deinit();

    var vertex_func = shader.getFunction("kawase_vertex_main") catch |e| {
        std.log.err("[blur] getFunction(kawase_vertex_main) failed: {}", .{e});
        return false;
    };
    defer vertex_func.deinit();
    var down_func = shader.getFunction("kawase_downsample") catch |e| {
        std.log.err("[blur] getFunction(kawase_downsample) failed: {}", .{e});
        return false;
    };
    defer down_func.deinit();
    var up_func = shader.getFunction("kawase_upsample") catch |e| {
        std.log.err("[blur] getFunction(kawase_upsample) failed: {}", .{e});
        return false;
    };
    defer up_func.deinit();

    encoder.persistent.blur_downsample_pipeline = gpu.Backend.createRenderPipeline(device, .{
        .vertex_function = &vertex_func,
        .fragment_function = &down_func,
        .color_attachment_formats = &[_]gpu.TextureFormat{.bgra8_unorm_srgb},
        .blend_state = null,
    }) catch |e| {
        std.log.err("[blur] downsample PSO failed: {}", .{e});
        return false;
    };

    encoder.persistent.blur_upsample_pipeline = gpu.Backend.createRenderPipeline(device, .{
        .vertex_function = &vertex_func,
        .fragment_function = &up_func,
        .color_attachment_formats = &[_]gpu.TextureFormat{.bgra8_unorm_srgb},
        .blend_state = null,
    }) catch |e| {
        std.log.err("[blur] upsample PSO failed: {}", .{e});
        return false;
    };

    encoder.persistent.blur_sampler = device.createSampler(std.heap.page_allocator, .{
        .label = "Zenit.Kawase.LinearSampler",
        .min_filter = .linear,
        .mag_filter = .linear,
    }) catch |e| {
        // sampler 失败不只影响 blur：applyGlass 也依赖它，缺 sampler 时 glass
        // 整体 no-op（透出清晰背景）。按整体失败处理，别留半残状态。
        std.log.err("[blur] sampler create failed: {}", .{e});
        return false;
    };
    return true;
}

fn buildGlassPipeline(encoder: anytype) bool {
    const device = encoder.sdf_renderer.device;
    var glass_shader = gpu.Backend.ShaderModule.initFromSource(device, glass_shader_source) catch |e| {
        std.log.err("[glass] shader compile failed: {}", .{e});
        return false;
    };
    defer glass_shader.deinit();
    var glass_vtx = glass_shader.getFunction("glass_vertex_main") catch |e| {
        std.log.err("[glass] getFunction(glass_vertex_main) failed: {}", .{e});
        return false;
    };
    defer glass_vtx.deinit();
    var glass_frag = glass_shader.getFunction("glass_fragment_main") catch |e| {
        std.log.err("[glass] getFunction(glass_fragment_main) failed: {}", .{e});
        return false;
    };
    defer glass_frag.deinit();
    encoder.persistent.glass_pipeline = gpu.Backend.createRenderPipeline(device, .{
        .vertex_function = &glass_vtx,
        .fragment_function = &glass_frag,
        .color_attachment_formats = &[_]gpu.TextureFormat{.bgra8_unorm_srgb},
        .blend_state = null,
    }) catch |e| {
        std.log.err("[glass] PSO failed: {}", .{e});
        return false;
    };
    return true;
}

/// 分配一个 Kawase uniform 槽；耗尽返回 null。
/// 不能钳到最后一格复用：draw 已 encode 未提交，后写会覆盖前一个 pass 的
/// uniform（texel_size/valid_uv 错乱的静默坏帧）。调用方拿到 null 应当
/// 终止本条模糊链（executeKawasePass 返回 false 即是该语义,
/// 两条 down/up 链对 false 都是 break 并以最后完成级为输出）。
pub fn acquireKawaseUniformSlot(encoder: anytype) ?u32 {
    if (encoder.persistent.blur_uniform_write_offset >= max_kawase_uniform_updates) return null;
    const slot = encoder.persistent.blur_uniform_write_offset;
    encoder.persistent.blur_uniform_write_offset += 1;
    return slot;
}

pub fn acquireGlassUniformSlot(encoder: anytype) u32 {
    const slot = @min(encoder.persistent.glass_uniform_write_offset, max_glass_uniform_updates - 1);
    encoder.persistent.glass_uniform_write_offset += 1;
    return slot;
}

pub fn resetDynamicUniformOffsets(encoder: anytype) void {
    encoder.persistent.blur_uniform_write_offset = 0;
    encoder.persistent.glass_uniform_write_offset = 0;
    encoder.persistent.glass_uniform_overflow_warned = false;
}

/// Re-open the render target after backdrop work temporarily switches the
/// command buffer through render/blit passes.  Keeping this in one helper is a
/// lifetime invariant: once the old pass has ended, every exit path must
/// either install a fresh pass or leave `render_pass == null`.
/// 排障（ZENIT_DEBUG_GLASS）：把某级中间纹理的中心 64×64 blit 进
/// persistent.debug_glass_slots[slot_idx] 的 staging，renderer 下一帧回读
/// 打 RGB 均值。用于二分滚动闪烁的分叉阶段（capture vs composite）。
fn debugGlassBlit(
    encoder: anytype,
    src: gpu.Backend.TextureBinding,
    src_x: u32,
    src_y: u32,
    w: u32,
    h: u32,
    slot_idx: usize,
) void {
    if (std.posix.getenv("ZENIT_DEBUG_GLASS") == null) return;
    const slot = &encoder.persistent.debug_glass_slots[slot_idx];
    const dw = @min(w, 64);
    const dh = @min(h, 64);
    if (dw == 0 or dh == 0) return;
    if (slot.staging == null) {
        slot.staging = encoder.sdf_renderer.device.createTexture(std.heap.page_allocator, .{
            .label = "Zenit.GlassDebugStaging",
            .size = .{ .width = 64, .height = 64 },
            .format = .bgra8_unorm_srgb,
            .usage = .{ .copy_dst = true },
            .memory = .host_upload,
        }) catch null;
    }
    if (slot.staging) |*staging| {
        var blit = (encoder.gpu_command_encoder.?.beginBlitPass() catch null) orelse return;
        const copied = blk: {
            blit.copyTextureRegion(src, src_x, src_y, dw, dh, staging.binding(), 0, 0) catch break :blk false;
            break :blk true;
        };
        blit.end();
        if (copied) {
            slot.cur_pending = true;
            slot.cur_w = dw;
            slot.cur_h = dh;
            slot.last_used_frame = encoder.frame_index;
        }
    }
}

fn restoreRenderTargetPass(
    encoder: anytype,
    restore_rt: gpu.Backend.TextureBinding,
    image_renderer: anytype,
    scale: f32,
) bool {
    if (encoder.render_pass != null) return true;

    var rt_view = restore_rt.createView();
    defer rt_view.destroy();
    const restored_pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = rt_view,
            .load_op = .load,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch return false;
    encoder.pass_count += 1;
    encoder.pass_sites[5] += 1;

    const slot = if (encoder.offscreen_depth > 0) encoder.offscreen_depth - 1 else 0;
    encoder.offscreen_stack[slot].render_pass = restored_pass;
    encoder.render_pass = &encoder.offscreen_stack[slot].render_pass;

    encoder.sdf_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
    encoder.text_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
    image_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
    if (encoder.icon_renderer) |icon_renderer| icon_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
    if (encoder.persistent.path_renderer) |*pr| pr.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
    encoder.applyOffscreenTargetViewport();
    encoder.syncRectClipState();
    encoder.syncRendererClipMask();
    encoder.syncTextClipX();
    return true;
}

/// 执行一遍 Kawase pass（downsample 或 upsample）。
/// 返回 false = 资源缺失被跳过（dst 内容未写入，caller 不得把它当模糊结果用）。
/// 曾经是静默 void return, caller 用 try 期待错误传播，拿到的却是"成功但
/// 什么都没做"，下游把未渲染的垃圾纹理当最深模糊层用进了亮度采样。
/// 把"有效像素尺寸 + 纹理分配尺寸"换算成采样用的 uv 子矩形。
///
/// 内缩半个 texel：钳到边界像素**中心**而非边界线，否则双线性会在
/// 有效/pad 交界处各取一半，仍把透明黑混进来（钳制就形同虚设）。
/// 纯函数，便于单测。
pub fn validUv(off_x: u32, off_y: u32, valid_w: u32, valid_h: u32, tex_w: u32, tex_h: u32) [4]f32 {
    if (tex_w == 0 or tex_h == 0) return .{ 0, 0, 1, 1 };
    const tw: f32 = @floatFromInt(tex_w);
    const th: f32 = @floatFromInt(tex_h);
    const half_x = 0.5 / tw;
    const half_y = 0.5 / th;
    // 起点不能恒当 0：贴窗口边的 glass（GlassEdge/下游应用 header）pad 越出屏幕
    // 被裁掉，有效内容从 dst_x/dst_y 开始（实测 dst=(160,160)）。漏掉偏移会
    // 把那段空白 pad 也当成有效区，映射整体错位，表现为背景被拉伸糊开。
    const x0: f32 = @as(f32, @floatFromInt(@min(off_x, tex_w))) / tw + half_x;
    const y0: f32 = @as(f32, @floatFromInt(@min(off_y, tex_h))) / th + half_y;
    const x1_raw: f32 = @as(f32, @floatFromInt(@min(off_x + valid_w, tex_w))) / tw - half_x;
    const y1_raw: f32 = @as(f32, @floatFromInt(@min(off_y + valid_h, tex_h))) / th - half_y;
    return .{ x0, y0, @max(x0, x1_raw), @max(y0, y1_raw) };
}

pub fn executeKawasePass(
    encoder: anytype,
    kind: KawasePassKind,
    src_texture: gpu.Backend.TextureBinding,
    src_w: u32,
    src_h: u32,
    dst_texture: gpu.Backend.TextureBinding,
    dst_w: u32,
    dst_h: u32,
    offset_scale: f32,
    /// 源纹理内有效背板的 uv 子矩形（见 KawaseUniforms.valid_uv）
    src_valid_uv: [4]f32,
) !bool {
    var pipeline = switch (kind) {
        .downsample => encoder.persistent.blur_downsample_pipeline orelse return warnPassSkipped("kawase pipeline"),
        .upsample => encoder.persistent.blur_upsample_pipeline orelse return warnPassSkipped("kawase pipeline"),
    };
    var sampler_state = encoder.persistent.blur_sampler orelse return warnPassSkipped("kawase sampler");

    const uniforms = KawaseUniforms{
        .texel_size = .{ 1.0 / @as(f32, @floatFromInt(src_w)), 1.0 / @as(f32, @floatFromInt(src_h)) },
        .offset_scale = offset_scale,
        .valid_uv = src_valid_uv,
    };
    // 槽位只作单帧模糊链预算；数据走 setFragmentBytes（encode 时拷贝，
    // 在飞帧不会被下一帧覆写）。
    _ = acquireKawaseUniformSlot(encoder) orelse return warnPassSkipped("kawase uniform slots exhausted");

    var dst_view = dst_texture.createView();
    const pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = dst_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch {
        dst_view.destroy();
        return warnPassSkipped("kawase render pass");
    };
    encoder.pass_count += 1; // v0.9-§D audit
    encoder.pass_sites[6] += 1;
    dst_view.destroy();

    var mutable_pass = pass;
    mutable_pass.setPipeline(&pipeline);
    mutable_pass.setFragmentBytes(0, std.mem.asBytes(&uniforms));
    mutable_pass.setFragmentTextureBinding(0, src_texture);
    mutable_pass.setFragmentSampler(0, &sampler_state);
    mutable_pass.setViewport(0, 0, @floatFromInt(dst_w), @floatFromInt(dst_h), 0, 1);
    mutable_pass.draw(3, 1, 0, 0);
    mutable_pass.end();
    return true;
}

/// Glass composite pass：在 blur 纹理上叠加折射 + Fresnel 高光
/// 输入 src（blur 结果），输出 dst（glass 合成结果）
pub fn executeGlassComposite(
    encoder: anytype,
    sharp_texture: gpu.Backend.TextureBinding,
    src_texture: gpu.Backend.TextureBinding,
    dst_texture: gpu.Backend.TextureBinding,
    tex_w: u32,
    tex_h: u32,
    rect_w: f32,
    rect_h: f32,
    corner_radius: f32,
    glass_tint: [4]f32,
    glass_intensity: f32,
    specular_opacity: f32,
    specular_saturation: f32,
    refraction_level: f32,
    blur_level: f32,
    warp_gain: f32,
    center_thickness: f32,
    surface_kind: f32,
    bezel_width: f32,
    bottom_surface_kind: f32,
    bottom_bezel_width: f32,
    specular_angle: f32,
    magnification: f32,
    scale_ratio: f32,
    edge_field_strength: f32,
    center_zoom_radius: f32,
    center_zoom_falloff: f32,
    backdrop_distance: f32,
    content_uv: [4]f32,
    edge_params: [4]f32,
    edge_stop_pos: [4]f32,
    edge_stop_str: [4]f32,
    valid_uv: [4]f32,
    /// 背景 saturate / brightness（CSS backdrop-filter）；{1,1} = 不调整。
    backdrop_adjust: [2]f32,
    /// 捕获纹理的物理/逻辑倍率（main RT 倍率；不是离屏层的放大光栅倍率）。
    capture_scale: f32,
) !bool {
    // 返回 false = 被跳过（dst 未写入）。caller 必须回退 blur_tex 合成，
    // 不能把这张未渲染的 glass_tex 当结果，否则玻璃区域是垃圾像素。
    var pipeline = encoder.persistent.glass_pipeline orelse return warnPassSkipped("glass pipeline");
    var sampler_state = encoder.persistent.blur_sampler orelse return warnPassSkipped("glass sampler");

    const uniforms = GlassUniforms{
        .texel_size = .{ 1.0 / @as(f32, @floatFromInt(tex_w)), 1.0 / @as(f32, @floatFromInt(tex_h)) },
        .corner_radius = corner_radius,
        .glass_intensity = glass_intensity,
        .rect_size = .{ rect_w, rect_h },
        .scale_factor = capture_scale,
        .glass_tint = glass_tint,
        .specular_params = .{ specular_opacity, specular_saturation, refraction_level, blur_level },
        .optic_params = .{ warp_gain, center_thickness, backdrop_distance, 0.0 },
        .surface_params = .{ surface_kind, bezel_width, specular_angle, magnification },
        .bottom_surface_params = .{ bottom_surface_kind, bottom_bezel_width, backdrop_adjust[0], backdrop_adjust[1] },
        .lens_params = .{ center_zoom_radius, center_zoom_falloff, edge_field_strength, scale_ratio },
        .content_uv = content_uv,
        .edge_params = edge_params,
        .edge_stop_pos = edge_stop_pos,
        .edge_stop_str = edge_stop_str,
        .valid_uv = valid_uv,
    };
    // 数据走 setFragmentBytes（encode 时拷贝）：不存在「槽位耗尽」，也不存在
    // 下一帧覆写在飞帧 uniform 的竞争。计数仅保留作诊断。
    _ = acquireGlassUniformSlot(encoder);

    var dst_view = dst_texture.createView();
    const pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = dst_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch {
        dst_view.destroy();
        return warnPassSkipped("glass render pass");
    };
    encoder.pass_count += 1; // v0.9-§D audit
    encoder.pass_sites[7] += 1;
    dst_view.destroy();

    var mutable_pass = pass;
    mutable_pass.setPipeline(&pipeline);
    mutable_pass.setFragmentBytes(0, std.mem.asBytes(&uniforms));
    mutable_pass.setFragmentTextureBinding(0, src_texture);
    mutable_pass.setFragmentTextureBinding(1, sharp_texture);
    mutable_pass.setFragmentSampler(0, &sampler_state);
    mutable_pass.setViewport(0, 0, @floatFromInt(tex_w), @floatFromInt(tex_h), 0, 1);
    mutable_pass.draw(3, 1, 0, 0);
    mutable_pass.end();
    return true;
}

/// Backdrop blur 入口参数，比裸 30+ float 更可读
pub const BackdropBlurParams = struct {
    /// glass 拥有者 node id（亮度区域槽的稳定 key；maxInt = 未知）
    glass_owner_id: u32 = std.math.maxInt(u32),
    /// blur 渐变（类 CSS linear-gradient）：方向 0=off 1=to_bottom 2=to_top
    /// 3=to_right 4=to_left / 全局强度 0~1 / stops（pos 0~1 占节点尺寸百分比，
    /// 升序）/ 有效个数
    blur_gradient_direction: f32 = 0,
    blur_gradient_strength: f32 = 0,
    blur_gradient_stop_pos: [4]f32 = .{ 0, 1, 1, 1 },
    blur_gradient_stop_str: [4]f32 = .{ 1, 0, 0, 0 },
    blur_gradient_stop_count: f32 = 2,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    blur_radius: f32,
    corner_radius: f32,
    glass_tint: [4]f32,
    glass_intensity: f32,
    specular_opacity: f32,
    specular_saturation: f32,
    refraction_level: f32,
    blur_level: f32,
    warp_gain: f32,
    center_thickness: f32,
    surface_kind: f32,
    bezel_width: f32,
    bottom_surface_kind: f32,
    bottom_bezel_width: f32,
    backdrop_saturation: f32 = 1.0,
    backdrop_brightness: f32 = 1.0,
    specular_angle: f32,
    magnification: f32,
    scale_ratio: f32,
    edge_field_strength: f32,
    center_zoom_radius: f32,
    center_zoom_falloff: f32,
    backdrop_distance: f32,
    draw_x: f32,
    draw_y: f32,
    draw_w: f32,
    draw_h: f32,
    use_draw_transform: bool,
    draw_transform: [6]f32,
    rotate: f32,
};

/// 离屏 surface 内的局部矩形 -> 世界（main RT）坐标 AABB。
///
/// 当前目标的纹理局部坐标 = 局部坐标 + offscreenOffset()（与内容绘制同一换算）。
/// 然后逐层向外：用 draw_transform 的层，其矩阵把纹理局部坐标映到「弹栈后目标帧
/// 未本地化」的坐标，再加上该层之下各层的累积偏移得到父纹理局部坐标；不用矩阵的
/// 层按 draw 矩形（已是父纹理局部坐标）比例映射。栈底即 main RT 坐标。四角取 AABB，
/// 旋转 / 斜切时也覆盖完整。
pub fn offscreenLocalRectToWorld(encoder: anytype, x: f32, y: f32, w: f32, h: f32) [4]f32 {
    const off = encoder.offscreenOffset();
    var pts = [4][2]f32{
        .{ x + off[0], y + off[1] },
        .{ x + w + off[0], y + off[1] },
        .{ x + off[0], y + h + off[1] },
        .{ x + w + off[0], y + h + off[1] },
    };
    var depth: usize = encoder.offscreen_depth;
    while (depth > 0) {
        depth -= 1;
        const layer = encoder.offscreen_stack[depth];
        // 该层弹栈后目标（depth 层之下）的累积偏移。
        var below_dx: f32 = 0;
        var below_dy: f32 = 0;
        for (encoder.offscreen_stack[0..depth]) |l| {
            below_dx -= l.x;
            below_dy -= l.y;
        }
        for (&pts) |*pt| {
            if (layer.use_draw_transform) {
                const t = layer.draw_transform;
                const nx = t[0] * pt[0] + t[2] * pt[1] + t[4] + below_dx;
                const ny = t[1] * pt[0] + t[3] * pt[1] + t[5] + below_dy;
                pt.* = .{ nx, ny };
            } else {
                const sx = if (layer.w > 0 and layer.draw_w > 0) layer.draw_w / layer.w else 1;
                const sy = if (layer.h > 0 and layer.draw_h > 0) layer.draw_h / layer.h else 1;
                const ox = if (std.math.isNan(layer.draw_x)) layer.x else layer.draw_x;
                const oy = if (std.math.isNan(layer.draw_y)) layer.y else layer.draw_y;
                pt.* = .{ ox + pt[0] * sx, oy + pt[1] * sy };
            }
        }
    }
    var x0: f32 = std.math.inf(f32);
    var y0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var y1: f32 = -std.math.inf(f32);
    for (pts) |pt| {
        x0 = @min(x0, pt[0]);
        y0 = @min(y0, pt[1]);
        x1 = @max(x1, pt[0]);
        y1 = @max(y1, pt[1]);
    }
    return .{ x0, y0, x1 - x0, y1 - y0 };
}

/// blur_radius（逻辑 px）-> Kawase 链参数。抽成纯函数以便单测连续性/DPI 无关性。
///
/// blur_radius 连续可调（同 CSS backdrop-filter: blur(px)），量程 [0, 96]
/// （types.zig resolve 已 clamp 并写明）：
/// - 链深 n = ceil(log2(r_phys/3))：offset 以各级纹理 texel（物理 px）计，
///   故级数按物理 px 算，等效物理足迹 ∝ r_phys -> 视觉糊度 DPI 无关；
/// - 小数级插值：余量 r_phys/(3·2^n) ∈ (0.5, 1] 作为全链 offset 缩放 ->
///   档位边界两侧糊度连续，不再阶梯跳变；n=1 段（r_phys ≤ 6）scale 一路
///   降到 0，曲线从 0 起连续；
/// - 级数上限 6：覆盖 2x 屏满量程（96 逻辑 = 192 物理 px）。3x 屏 64
///   逻辑 px 以上开始饱和。
pub const BlurChainParams = struct { levels: u32, offset_scale: f32 };
pub fn blurChainParams(radius_logical: f32, scale: f32) BlurChainParams {
    const radius_phys = @min(radius_logical, 96.0) * scale;
    const levels: u32 = if (radius_phys <= 6.0)
        1
    else
        @min(@max(@as(u32, @intFromFloat(@ceil(std.math.log2(radius_phys / 3.0)))), 1), 6);
    return .{
        .levels = levels,
        .offset_scale = radius_phys / (3.0 * std.math.pow(f32, 2.0, @floatFromInt(levels))),
    };
}

/// Backdrop blur: Dual Kawase 降采样链 + 升采样链
///
/// 语义：模糊节点区域下方的已渲染背景，子节点之后正常渲染（保持清晰）
/// 流程：blit 区域复制 -> downsample chain -> upsample chain -> composite 回 RT
pub fn applyBackdropBlur(encoder: anytype, p: BackdropBlurParams) !void {
    // 诊断开关：全关 backdrop blur（含 Kawase 链与 glass composite）。
    // blur 每个 glass 区域要花 ~10 个 render pass + 1 个 blit，是每帧 pass 数
    // 的绝对大头（86 中占 69），排查 GPU 侧内存/性能归属时用它做对照组。
    if (debug_env.flag("ZENIT_NO_BLUR")) return;
    if (p.blur_radius < 0.5) return;
    if (encoder.render_pass == null) return;
    if (encoder.gpu_command_encoder == null) return;
    if (!ensureBlurPipeline(encoder)) return;

    const ir = encoder.image_renderer orelse return;
    // s = 当前目标（可能是放大光栅的离屏层）的倍率，只用于恢复 pass；
    // cap_s = 捕获源（main RT）的倍率，层内的玻璃永远从 main RT 采样，捕获区域、
    // 模糊链、content_uv 与形状蒙版都按 main RT 的物理像素计算。
    const s = encoder.scale;
    const cap_s: f32 = if (encoder.offscreen_depth > 0) encoder.offscreen_stack[0].saved_scale else s;
    const device = encoder.sdf_renderer.device;

    const chain = blurChainParams(p.blur_radius, cap_s);
    const max_levels = chain.levels;
    const offset_boost = chain.offset_scale;

    // Resolve every resource needed to recover the active target *before*
    // ending it.  Returning between end() and recovery used to leave a stale
    // RenderPass pointer in RenderCommandEncoder.
    const active_rt: gpu.Backend.TextureBinding = if (encoder.offscreen_depth > 0)
        encoder.offscreen_pool.binding(encoder.offscreen_stack[encoder.offscreen_depth - 1].texture) orelse return
    else
        (encoder.main_render_target orelse return);
    const restore_rt = active_rt;
    const sampling_main = encoder.offscreen_depth > 0;
    const current_rt: gpu.Backend.TextureBinding = if (sampling_main)
        (encoder.main_render_target orelse active_rt)
    else
        active_rt;

    // ---- 1. Flush + end 当前 render pass ----
    if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) {
        const pending_paths: usize = if (encoder.persistent.path_renderer) |*pr| pr.vertices.items.len else 0;
        const pending_img: usize = if (encoder.image_renderer) |imr| imr.instances.items.len else 0;
        const pending_icon: usize = if (encoder.icon_renderer) |icr| icr.instances.items.len else 0;
        std.debug.print("[glasspend] frame={d} owner={d} sdf={d} img={d} icon={d} txt={d} path={d} dt=({d:.3},{d:.3},{d:.3},{d:.3},{d:.2},{d:.2})\n", .{
            encoder.frame_index, p.glass_owner_id,    encoder.sdf_renderer.instances.items.len, pending_img,         pending_icon,        encoder.text_renderer.getPendingInstanceCount(), pending_paths,
            p.draw_transform[0], p.draw_transform[1], p.draw_transform[2],                      p.draw_transform[3], p.draw_transform[4], p.draw_transform[5],
        });
    }
    try encoder.sdf_renderer.flush(encoder.render_pass.?);
    if (encoder.image_renderer) |imr| try imr.flush(encoder.render_pass.?);
    if (encoder.icon_renderer) |icr| try icr.flush(encoder.render_pass.?);
    try encoder.text_renderer.flush(encoder.render_pass.?);
    encoder.render_pass.?.end();
    // Never retain an ended pass. Objective-C may immediately reuse that raw
    // address for the next blit encoder, which was the GlassBox crash.
    encoder.render_pass = null;
    defer if (encoder.render_pass == null) {
        _ = restoreRenderTargetPass(encoder, restore_rt, ir, s);
    };

    // capture 源永远是 main RT：glass 落在 overlay/composited surface 内时
    // （absolute 节点、动画 promote 等），surface 自己的纹理里只有该子树内容，
    // 采它得不到玻璃身后的背板。overlay 在主内容之后合成，main RT 此刻正是
    // 玻璃下方的真实画面，用 world 坐标直接采、不加 offscreen offset。
    if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) {
        std.debug.print("[glassenc] frame={d} owner={d} depth={d}\n", .{ encoder.frame_index, p.glass_owner_id, encoder.offscreen_depth });
    }
    const blur_off: [2]f32 = if (sampling_main) .{ 0, 0 } else encoder.offscreenOffset();
    // capture 必须在 world 帧采样父 RT。CA-pure 统一路径下 p.x/p.y 是
    // owner-local src 坐标（恒 ≈0），只有 draw_x/draw_y 才是世界 AABB，用
    // src 采样会永远从 RT 左上角抓背景（黑底 + 错位内容）。
    const local_x = if (std.math.isNan(p.draw_x)) p.x else p.draw_x;
    const local_y = if (std.math.isNan(p.draw_y)) p.y else p.draw_y;
    const local_w = if (p.draw_w > 0) p.draw_w else p.w;
    const local_h = if (p.draw_h > 0) p.draw_h else p.h;
    // 玻璃在离屏 surface 内（opacity 渐隐 / scale / composited group）：参数是
    // surface 内坐标，而采样源是 main RT，必须沿离屏栈把节点矩形映射到世界
    // （屏幕）坐标再捕获。否则永远从 RT 左上角抓背景（透出窗口另一处内容）。
    // 捕获按世界尺寸进行，合回时 content_uv 把这块区域画进局部矩形，缩放自然抵消。
    const world = if (sampling_main)
        offscreenLocalRectToWorld(encoder, local_x, local_y, local_w, local_h)
    else
        [4]f32{ local_x, local_y, local_w, local_h };
    if (debug_env.flag("ZENIT_DEBUG_GLASSCAP") and sampling_main) {
        const L = encoder.offscreen_stack[encoder.offscreen_depth - 1];
        std.debug.print("[glassworld] local=({d:.1},{d:.1},{d:.1},{d:.1}) world=({d:.1},{d:.1},{d:.1},{d:.1}) depth={d} L.x={d:.1} L.w={d:.1} udt={} dt=({d:.3},{d:.3},{d:.3},{d:.3},{d:.1},{d:.1}) draw=({d:.1},{d:.1},{d:.1},{d:.1}) off={any}\n", .{ local_x, local_y, local_w, local_h, world[0], world[1], world[2], world[3], encoder.offscreen_depth, L.x, L.w, L.use_draw_transform, L.draw_transform[0], L.draw_transform[1], L.draw_transform[2], L.draw_transform[3], L.draw_transform[4], L.draw_transform[5], L.draw_x, L.draw_y, L.draw_w, L.draw_h, encoder.offscreenOffset() });
    }
    const node_x = world[0];
    const node_y = world[1];
    const node_w = world[2];
    const node_h = world[3];
    // 世界 / 局部尺寸比：形状蒙版（圆角、bezel）在捕获纹理的世界像素里生成。
    const world_scale: f32 = if (local_w > 0 and local_h > 0) 0.5 * (node_w / local_w + node_h / local_h) else 1;
    // padded capture：比玻璃矩形大一圈。magnification / 边缘位移都会把采样点
    // 推到节点矩形之外，只截节点大小时要么 clamp 拉丝、要么小纹理插值放大
    // 导致画质糊。多截的边距让位移/放大采到真实全分辨率背板。
    // pad 必须同时覆盖两件事：
    //   (a) magnification/边缘位移把采样点推出节点矩形，与节点尺寸相关
    //   (b) blur kernel 本身的采样触达，与 blur_radius 相关
    // 只算 (a) 会让大半径 blur 的 kernel 采出有效区，被 valid_uv clamp 成
    // 边界像素的无限延展：表现为节点外的颜色被"拉"进来（便签色漫到空白
    // 画布上）+ 整体发灰（同一条边界色被反复混入）。取两者较大者。
    const geom_pad = std.math.clamp(0.35 * @min(node_w, node_h) + 8, 12, 80);
    const blur_pad = @min(p.blur_radius, 96.0);
    const pad: f32 = if (debug_env.flag("ZENIT_GLASS_NOPAD")) 0 else @max(geom_pad, blur_pad);
    const cap_x = node_x - pad;
    const cap_y = node_y - pad;
    const cap_w = node_w + pad * 2;
    const cap_h = node_h + pad * 2;
    const sample_x = cap_x + blur_off[0];
    const sample_y = cap_y + blur_off[1];
    // clip 帧要与采样源一致：采 main RT 时 currentRectClip 是 surface-local
    // 帧，不可用，改用整个 viewport。
    // sampling_main 时 encoder.viewport_* 已被 offscreen layer 改成 surface
    // 尺寸；真实屏幕 viewport 在 stack[0] 进层时保存的字段里。
    const capture_clip: ?[4]f32 = if (sampling_main)
        .{ 0, 0, encoder.offscreen_stack[0].saved_viewport_width, encoder.offscreen_stack[0].saved_viewport_height }
    else
        encoder.currentRectClip();
    if (debug_env.flag("ZENIT_DEBUG_GLASSCAP")) {
        const clip = capture_clip;
        std.debug.print("[glasscap] p=({d:.0},{d:.0},{d:.0},{d:.0}) draw=({d:.0},{d:.0},{d:.0},{d:.0}) udt={} off=({d:.0},{d:.0}) depth={d} clip={?any}\n", .{
            p.x, p.y, p.w, p.h, p.draw_x, p.draw_y, p.draw_w, p.draw_h, p.use_draw_transform, blur_off[0], blur_off[1], encoder.offscreen_depth, clip,
        });
    }
    const capture_region = @TypeOf(encoder.*).computeBackdropCaptureRegion(sample_x, sample_y, cap_w, cap_h, cap_s, capture_clip, current_rt.width, current_rt.height) orelse {
        _ = restoreRenderTargetPass(encoder, restore_rt, ir, s);
        return;
    };
    const tex_w = capture_region.tex_w;
    const tex_h = capture_region.tex_h;

    const level0 = encoder.offscreen_pool.acquire(device, tex_w, tex_h, encoder.frame_index) orelse return;
    const level0_binding = encoder.offscreen_pool.binding(level0) orelse {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
        return;
    };

    // ---- 2. Blit 区域复制 ----
    {
        if (!capture_region.coversFullTexture() and !encoder.clearTextureToTransparent(level0_binding)) {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
            return;
        }
        var blit = encoder.gpu_command_encoder.?.beginBlitPass() catch {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
            return;
        };
        blit.copyTextureRegion(
            current_rt,
            capture_region.src_x,
            capture_region.src_y,
            capture_region.copy_w,
            capture_region.copy_h,
            level0_binding,
            capture_region.dst_x,
            capture_region.dst_y,
        ) catch {
            blit.end();
            _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
            return;
        };
        blit.end();
    }
    // 排障：capture 内容中心区 -> debug slot 0
    debugGlassBlit(
        encoder,
        level0_binding,
        capture_region.dst_x + (capture_region.copy_w -| 64) / 2,
        capture_region.dst_y + (capture_region.copy_h -| 64) / 2,
        capture_region.copy_w,
        capture_region.copy_h,
        0,
    );

    // ---- 3. Downsample chain ----
    var tex_chain: [7]TextureLease = undefined;
    var w_chain: [7]u32 = undefined;
    var h_chain: [7]u32 = undefined;
    // 每级纹理内**真实内容**的像素尺寸。与 w_chain/h_chain（纹理分配尺寸）
    // 的区别只出现在 level0：纹理按 64px 桶分配，实际 blit 进来的只有
    // copy_w×copy_h，其余是透明黑 pad。往下每级 dst 纹理都按 lw×lh 精确
    // 分配，故有效尺寸与分配尺寸同步减半，比例保持不变。
    var vw_chain: [7]u32 = undefined;
    var vh_chain: [7]u32 = undefined;
    tex_chain[0] = level0;
    w_chain[0] = tex_w;
    h_chain[0] = tex_h;
    var ox_chain: [7]u32 = undefined;
    var oy_chain: [7]u32 = undefined;
    ox_chain[0] = capture_region.dst_x;
    oy_chain[0] = capture_region.dst_y;
    vw_chain[0] = capture_region.copy_w;
    vh_chain[0] = capture_region.copy_h;

    // actual_levels 只在该级 downsample **真的执行**之后才 +1：曾经先计数
    // 后执行，中途 break/skip 会让 tex_chain[actual_levels] 指向一张从未
    // 渲染的垃圾纹理，直接被 blit 进亮度采样。失败时已 acquire 的纹理立即
    // 还池（否则每次失败漏一张）。
    var actual_levels: u32 = 0;

    // ---- 链深帧间迟滞 ----
    // 池压力临界时，同一个岛的 actual_levels 会逐帧在 n 与 n-1 之间摆动，
    // 用户看到的是「闪」，**跳变**才是缺陷，恒定 n-1 与恒定 n 视觉上几乎无差。
    // 故：降级立即生效（拿不到就用少的），升级需连续 BLUR_LEVEL_RAISE_FRAMES
    // 帧都拿得到。槽按 glass_owner_id 匹配，逻辑与下方 luminance_slots 同构。
    // 找不到槽（槽满 / owner 未知）-> level_slot = null -> 完全退化为原行为。
    // 槽类型从 encoder 反推，避免 backdrop_blur ↔ command_encoder 循环 import。
    const LevelSlot = @typeInfo(@TypeOf(&encoder.persistent.blur_level_slots[0])).pointer.child;
    const level_slot: ?*LevelSlot = blk: {
        if (p.glass_owner_id == std.math.maxInt(u32)) break :blk null;
        var lru_idx: usize = 0;
        var lru_frame: u64 = std.math.maxInt(u64);
        for (&encoder.persistent.blur_level_slots, 0..) |*slot, i| {
            if (slot.key == p.glass_owner_id) break :blk slot;
            if (slot.last_used_frame < lru_frame) {
                lru_frame = slot.last_used_frame;
                lru_idx = i;
            }
        }
        // 无匹配：LRU 复用。只有当被复用的槽**确实陈旧**（上一帧没用过）才
        // 抢占，否则本帧岛数已超过槽数，抢占会让两个岛互相清空对方的历史，
        // 迟滞退化成噪声，这种情况下宁可不迟滞。
        const victim = &encoder.persistent.blur_level_slots[lru_idx];
        if (victim.last_used_frame + 1 >= encoder.frame_index and victim.key != std.math.maxInt(u32)) break :blk null;
        victim.key = p.glass_owner_id;
        victim.committed_levels = 0; // 换主后旧历史作废（首帧不设限）
        victim.raise_streak = 0;
        break :blk victim;
    };
    // 排障/对照：关掉迟滞退回原行为（变异验证用，见 commit message 的实测数据）
    const level_cap: u32 = if (debug_env.flag("ZENIT_NO_BLUR_HYSTERESIS")) max_levels else if (level_slot) |slot|
        levelCap(slot.committed_levels, slot.raise_streak, slot.raise_backoff, max_levels)
    else
        max_levels;

    for (0..level_cap) |i| {
        const lw = @max(1, w_chain[i] / 2);
        const lh = @max(1, h_chain[i] / 2);
        if (lw < 2 or lh < 2) break;
        const src_binding = encoder.offscreen_pool.binding(tex_chain[i]) orelse break;
        const tex = encoder.offscreen_pool.acquire(device, lw, lh, encoder.frame_index) orelse break;
        const dst_binding = encoder.offscreen_pool.binding(tex) orelse {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(tex);
            break;
        };
        // src 的有效区（归一化）。半个 texel 的内缩避免双线性在有效/pad
        // 边界上跨采到黑：钳到边界像素**中心**而不是边界线。
        const src_valid = validUv(ox_chain[i], oy_chain[i], vw_chain[i], vh_chain[i], w_chain[i], h_chain[i]);
        const ran = try executeKawasePass(
            encoder,
            .downsample,
            src_binding,
            w_chain[i],
            h_chain[i],
            dst_binding,
            lw,
            lh,
            (1.5 + @as(f32, @floatFromInt(i)) * 1.0) * offset_boost,
            src_valid,
        );
        if (!ran) {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(tex);
            break;
        }
        tex_chain[i + 1] = tex;
        w_chain[i + 1] = lw;
        h_chain[i + 1] = lh;
        // dst 按 lw×lh 精确分配且 viewport 满铺，故整张 dst 都是有效内容
        // 但它的内容源自 src 的有效区，比例随之继承（向上取整避免丢边）。
        // dst 满铺且内容源自 src 有效区 -> dst 整张有效，偏移归零。
        ox_chain[i + 1] = 0;
        oy_chain[i + 1] = 0;
        vw_chain[i + 1] = lw;
        vh_chain[i + 1] = lh;
        actual_levels += 1;
    }
    if (level_slot) |slot| {
        slot.last_used_frame = encoder.frame_index;
        const next = levelSettle(
            .{ .committed = slot.committed_levels, .streak = slot.raise_streak, .backoff = slot.raise_backoff },
            level_cap,
            actual_levels,
            max_levels,
        );
        slot.committed_levels = next.committed;
        slot.raise_streak = next.streak;
        slot.raise_backoff = next.backoff;
    }
    if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) {
        const dbg_streak: u32 = if (level_slot) |ls| ls.raise_streak else 0;
        const dbg_backoff: u32 = if (level_slot) |ls| ls.raise_backoff else 0;
        std.debug.print("[glasschain] frame={d} owner={d} levels={d}/{d} cap={d} streak={d} backoff={d} boost={d:.2}\n", .{ encoder.frame_index, p.glass_owner_id, actual_levels, max_levels, level_cap, dbg_streak, dbg_backoff, offset_boost });
    }

    // ---- 3.5 backdrop 亮度自适应：最深层 blit 进本 glass 区域的专属槽 ----
    // 最深 Kawase 层已经是重度模糊的低分辨率均值近似，取其中 ≤64px 区域
    // 拷进槽内固定尺寸 shared 纹理，CPU 下一帧 getBytes 求平均 luminance。
    // 槽按 draw rect 量化 key 匹配（无匹配则 LRU 复用最久未用槽），单张
    // 共享 staging 的"最后编码者覆盖"是滚动换装 bug 的根源。
    if (actual_levels > 0) lum: {
        const deep = tex_chain[actual_levels];
        // 循环里刚校验过，但不许 unreachable（ReleaseFast UB）：缺失就跳过
        // 亮度采样，槽保留上一帧值。
        const deep_binding = encoder.offscreen_pool.binding(deep) orelse break :lum;
        const dw = @min(w_chain[actual_levels], 64);
        const dh = @min(h_chain[actual_levels], 64);
        // 槽 key = glass 拥有者 node id：滚动/布局变化下恒定（几何 key 会随
        // 滚动逐帧变化 -> 12 槽全体 churn -> 值清空 -> 回退全局均值 -> 滚动闪变）。
        const key = p.glass_owner_id;
        var slot_idx: ?usize = null;
        var lru_idx: usize = 0;
        var lru_frame: u64 = std.math.maxInt(u64);
        for (&encoder.persistent.luminance_slots, 0..) |*slot, i| {
            if (slot.key == key and key != std.math.maxInt(u32)) {
                slot_idx = i;
                break;
            }
            if (slot.last_used_frame < lru_frame) {
                lru_frame = slot.last_used_frame;
                lru_idx = i;
            }
        }
        const idx = slot_idx orelse blk: {
            const slot = &encoder.persistent.luminance_slots[lru_idx];
            slot.key = key;
            slot.value = null; // 换主后旧值作废
            slot.cur_pending = false;
            slot.prev_pending = false;
            break :blk lru_idx;
        };
        const slot = &encoder.persistent.luminance_slots[idx];
        if (slot.staging == null) {
            // BGRA8Unorm_sRGB 与源一致（blit 要求同 format）；storageMode
            // Shared 才能 getBytes；固定 64x64、槽内创建一次。
            slot.staging = encoder.sdf_renderer.device.createTexture(std.heap.page_allocator, .{
                .label = "Zenit.LuminanceStaging",
                .size = .{ .width = 64, .height = 64 },
                .format = .bgra8_unorm_srgb,
                .usage = .{ .copy_dst = true },
                .memory = .host_upload,
            }) catch null;
        }
        if (slot.staging) |*staging| {
            if (encoder.gpu_command_encoder.?.beginBlitPass() catch null) |blit_value| {
                var blit = blit_value;
                const copied = blk: {
                    blit.copyTextureRegion(deep_binding, 0, 0, dw, dh, staging.binding(), 0, 0) catch break :blk false;
                    break :blk true;
                };
                blit.end();
                if (copied) {
                    slot.cur_pending = true;
                    slot.cur_w = dw;
                    slot.cur_h = dh;
                    slot.last_used_frame = encoder.frame_index;
                }
            }
        }
    }

    // ---- 4. Upsample chain ----
    // 终点停在 tex_chain[1]（半分辨率）：glass shader 全程 normalized UV 采样
    // 且模糊内容低频，半分辨率视觉差异极小，省掉回全尺寸的最后一级 pass。
    // level0 全程保持清晰内容，直接充当 composite 的 sharp 输入（不再单独 blit）。
    var upsample_ran: u32 = 0;
    if (actual_levels > 0) {
        var lvl: u32 = actual_levels;
        while (lvl > 1) : (lvl -= 1) {
            // binding 缺失/pass 被跳过 -> 停止上采样：tex_chain[1] 保持
            // 已有内容（模糊程度降级但不是垃圾像素）。
            const src_binding = encoder.offscreen_pool.binding(tex_chain[lvl]) orelse break;
            const dst_binding = encoder.offscreen_pool.binding(tex_chain[lvl - 1]) orelse break;
            const ran = try executeKawasePass(
                encoder,
                .upsample,
                src_binding,
                w_chain[lvl],
                h_chain[lvl],
                dst_binding,
                w_chain[lvl - 1],
                h_chain[lvl - 1],
                (1.2 + @as(f32, @floatFromInt(actual_levels - lvl)) * 0.8) * offset_boost,
                validUv(ox_chain[lvl], oy_chain[lvl], vw_chain[lvl], vh_chain[lvl], w_chain[lvl], h_chain[lvl]),
            );
            if (!ran) break;
            upsample_ran += 1;
        }
    }
    if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null) {
        std.debug.print("[glassup] frame={d} owner={d} up={d}/{d}\n", .{ encoder.frame_index, p.glass_owner_id, upsample_ran, if (actual_levels > 0) actual_levels - 1 else 0 });
    }
    // actual_levels==0 退化：无降采样级，sharp 和 blur 同为 level0（Metal 同
    // 纹理绑两个只读采样 slot 合法，mix 结果一致）。
    const blur_tex: TextureLease = if (actual_levels > 0) tex_chain[1] else level0;

    // tex_chain[1] 是 composite 的 blur 输入，存活到 composite/flush 之后再放；
    // 更深的中间级此刻已编码完所有使用，先放回池。
    for (2..actual_levels + 1) |i| {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(tex_chain[i]);
    }

    // ---- 6. Glass composite ----
    // fallback（无 glass pipeline / glass_tex 获取失败）时 composite 回 RT 的
    // 必须是模糊结果 blur_tex（半分辨率拉伸绘制）。
    const tex_w_f: f32 = @floatFromInt(tex_w);
    const tex_h_f: f32 = @floatFromInt(tex_h);
    const content_uv: [4]f32 = .{
        pad * cap_s / tex_w_f,
        pad * cap_s / tex_h_f,
        node_w * cap_s / tex_w_f,
        node_h * cap_s / tex_h_f,
    };
    var composite_tex = blur_tex;
    var composite_tint = p.glass_tint;
    var composite_has_baked_shape_mask = false;
    // level0 是否已提前归还（见下方"池压力下的公平性"注释）。
    var level0_released = false;
    if (encoder.persistent.glass_pipeline != null) glass: {
        if (encoder.offscreen_pool.acquire(device, tex_w, tex_h, encoder.frame_index)) |glass_tex| {
            // binding 缺失或 composite 被跳过 -> 释放 glass_tex 并回退 blur_tex
            // 合成；绝不能把未渲染的 glass_tex 当结果。
            const blur_binding = encoder.offscreen_pool.binding(blur_tex) orelse {
                _ = encoder.offscreen_pool.releaseForReuseInFrame(glass_tex);
                if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null)
                    std.debug.print("[glass-fallback] blur_binding missing owner={d}\n", .{p.glass_owner_id});
                break :glass;
            };
            const glass_binding = encoder.offscreen_pool.binding(glass_tex) orelse {
                _ = encoder.offscreen_pool.releaseForReuseInFrame(glass_tex);
                if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null)
                    std.debug.print("[glass-fallback] glass_binding missing owner={d}\n", .{p.glass_owner_id});
                break :glass;
            };
            const ran = try executeGlassComposite(
                encoder,
                level0_binding,
                blur_binding,
                glass_binding,
                tex_w,
                tex_h,
                node_w,
                node_h,
                p.corner_radius * world_scale,
                p.glass_tint,
                p.glass_intensity,
                p.specular_opacity,
                p.specular_saturation,
                p.refraction_level,
                p.blur_level,
                p.warp_gain,
                p.center_thickness,
                p.surface_kind,
                p.bezel_width * world_scale,
                p.bottom_surface_kind,
                p.bottom_bezel_width * world_scale,
                p.specular_angle,
                p.magnification,
                p.scale_ratio,
                p.edge_field_strength,
                p.center_zoom_radius,
                p.center_zoom_falloff,
                p.backdrop_distance,
                content_uv,
                .{ p.blur_gradient_direction, 0, p.blur_gradient_strength, p.blur_gradient_stop_count },
                p.blur_gradient_stop_pos,
                p.blur_gradient_stop_str,
                .{
                    @as(f32, @floatFromInt(capture_region.dst_x)) / tex_w_f,
                    @as(f32, @floatFromInt(capture_region.dst_y)) / tex_h_f,
                    @as(f32, @floatFromInt(capture_region.dst_x + capture_region.copy_w)) / tex_w_f,
                    @as(f32, @floatFromInt(capture_region.dst_y + capture_region.copy_h)) / tex_h_f,
                },
                .{ p.backdrop_saturation, p.backdrop_brightness },
                cap_s,
            );
            if (!ran) {
                _ = encoder.offscreen_pool.releaseForReuseInFrame(glass_tex);
                if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null)
                    std.debug.print("[glass-fallback] composite not ran owner={d}\n", .{p.glass_owner_id});
                break :glass;
            }
            if (!blur_tex.eql(level0)) {
                _ = encoder.offscreen_pool.releaseForReuseInFrame(blur_tex);
            }
            composite_tex = glass_tex;
            composite_tint = .{ 1, 1, 1, 1 };
            composite_has_baked_shape_mask = true;
            // 排障：composite 输出中心区 -> debug slot 1
            debugGlassBlit(encoder, glass_binding, (tex_w -| 64) / 2, (tex_h -| 64) / 2, tex_w, tex_h, 1);
        } else {
            if (std.posix.getenv("ZENIT_DEBUG_GLASS") != null)
                std.debug.print("[glass-fallback] glass_tex acquire failed owner={d} {d}x{d}\n", .{ p.glass_owner_id, tex_w, tex_h });
        }
    }
    // ⚠ 池压力下的**公平性**：走到这里说明 composite 要么成功、要么已降级。
    // 两种情况下 level0（capture 全尺寸，本函数最大的一张）都不再需要,
    // 成功路径的 composite 已经采样完毕，fallback 路径压根不用它。
    //
    // 不在这里放而是拖到函数末尾（原行为），会让**失败的岛比成功的岛占用更久**：
    // 成功路径 :1098 会提前归还 blur_tex，失败路径却把 level0 + blur_tex 一起
    // 攥到最后。于是最大的那个岛一旦 composite 失败，就把池吃干，**排在它后面
    // 的小岛整帧画不出来**（实测：owner=831 申请 896x1984 失败 40 次，
    // owner=1429 工具栏就缺席 40 帧，一一对应）。这正是 issue 33 里用户看到的
    // "Inspector 和工具栏一起闪"，两者是同一条合成序列上的先后两环。
    //
    // releaseForReuseInFrame 会把 reusable_after_frame 清零 ⇒ **同帧立即可复用**，
    // 所以提前归还能直接惠及后面的岛。
    if (!composite_tex.eql(level0)) {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
        level0_released = true;
    }
    // composite_tex==level0 仅在 actual_levels==0 且走 fallback 时成立，
    // 此时 level0 由末尾统一释放，这里不能重复放。
    if (!level0_released and !composite_tex.eql(level0)) {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
    }

    // ---- 7. 恢复 render pass ----
    if (!restoreRenderTargetPass(encoder, restore_rt, ir, s)) {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(composite_tex);
        return;
    }

    // ---- 8. Composite 回 RT ----
    const comp_draw_x = if (encoder.offscreen_depth > 0)
        p.draw_x - encoder.offscreen_stack[encoder.offscreen_depth - 1].x
    else
        p.draw_x;
    const comp_draw_y = if (encoder.offscreen_depth > 0)
        p.draw_y - encoder.offscreen_stack[encoder.offscreen_depth - 1].y
    else
        p.draw_y;
    const composite_binding = encoder.offscreen_pool.binding(composite_tex) orelse {
        // pass 已恢复；缺 binding 只能放弃本帧 blur 合成（区域保持背景）。
        _ = encoder.offscreen_pool.releaseForReuseInFrame(composite_tex);
        std.log.warn("[backdrop-blur] composite binding lost; dropping blur composite this frame", .{});
        return;
    };
    const comp_id = ir.registerTextureBinding(composite_binding, tex_w, tex_h) catch {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(composite_tex);
        return;
    };
    const composite_corner_radius: f32 = if (composite_has_baked_shape_mask) 0 else p.corner_radius;
    const comp_uv: [4]f32 = .{
        content_uv[0],
        content_uv[1],
        content_uv[0] + content_uv[2],
        content_uv[1] + content_uv[3],
    };
    if (p.use_draw_transform) {
        try ir.addImageUVWithTransform(
            comp_id,
            p.w,
            p.h,
            comp_uv,
            composite_tint,
            composite_corner_radius,
            1.0,
            encoder.localizeDrawTransformForCurrentTarget(p.draw_transform),
            true,
        );
    } else {
        try ir.addImageUVPremultiplied(
            comp_id,
            comp_draw_x,
            comp_draw_y,
            if (p.draw_w > 0) p.draw_w else p.w,
            if (p.draw_h > 0) p.draw_h else p.h,
            comp_uv,
            composite_tint,
            composite_corner_radius,
            1.0,
            p.rotate,
        );
    }
    try ir.flush(encoder.render_pass.?);
    ir.unregisterTextureBinding(comp_id);
    _ = encoder.offscreen_pool.releaseForReuseInFrame(composite_tex);
}

test "validUv: 满幅纹理钳到边界像素中心" {
    // 有效区 == 纹理尺寸时仍内缩半 texel：双线性在最外圈像素上取样才不会
    // 越到纹理外（Metal clamp-to-edge 会兜底，但内缩让语义显式且与部分
    // 捕获路径一致）。
    const uv = validUv(0, 0, 64, 64, 64, 64);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 / 64.0), uv[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - 0.5 / 64.0), uv[2], 1e-6);
}

test "validUv: 部分捕获时上界收在有效区内（pad 被排除）" {
    // 这是本函数存在的理由：纹理按 64px 桶分配 960，实际只有 934 有效。
    // 若上界给到 1.0，Kawase 会把右侧 26px 的透明黑糊进有效内容。
    const uv = validUv(0, 0, 934, 183, 960, 192);
    const expect_x1 = 934.0 / 960.0 - 0.5 / 960.0;
    const expect_y1 = 183.0 / 192.0 - 0.5 / 192.0;
    try std.testing.expectApproxEqAbs(@as(f32, expect_x1), uv[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, expect_y1), uv[3], 1e-6);
    // 反向断言：上界必须**严格小于** 1.0，否则 pad 仍会被采样到。
    try std.testing.expect(uv[2] < 1.0);
    try std.testing.expect(uv[3] < 1.0);
    // 且不能过度内缩到把有效内容也切掉。
    try std.testing.expect(uv[2] > 0.96);
}

test "validUv: 退化输入不产生非法区间" {
    const zero = validUv(0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(f32, 1.0), zero[2]);
    // valid 超过 tex 时钳回 tex（防越界 uv > 1）
    const over = validUv(0, 0, 999, 999, 64, 64);
    try std.testing.expect(over[2] <= 1.0);
    // 极小纹理不能出现 x1 < x0 的反向区间
    const tiny = validUv(0, 0, 1, 1, 1, 1);
    try std.testing.expect(tiny[2] >= tiny[0]);
}

test "validUv: 非零起点（贴窗口边）—— 下界必须跟着偏移走" {
    // GlassEdge / 下游应用 header 贴窗口边时 pad 越出屏幕被裁，有效内容从
    // dst=(160,160) 开始（实测值）。曾把下界恒当 0，于是那 160px 空白 pad
    // 被当成有效区，映射整体错位 -> 背景被拉伸糊开、侧栏文字糊成一片。
    const uv = validUv(160, 160, 640, 2000, 832, 2368);
    try std.testing.expectApproxEqAbs(@as(f32, 160.0 / 832.0 + 0.5 / 832.0), uv[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 160.0 / 2368.0 + 0.5 / 2368.0), uv[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 800.0 / 832.0 - 0.5 / 832.0), uv[2], 1e-6);
    // 反向断言：下界必须显著大于 0，否则就是漏掉了偏移。
    try std.testing.expect(uv[0] > 0.18);
    try std.testing.expect(uv[1] > 0.06);
}

// ---- 链深帧间迟滞（issue 33：Inspector/工具栏每帧振荡）----
//
// 模型：`pool_ok(n)` 表示离屏池本帧能否供到第 n 级。实测症状是池在临界线上
// 以 REUSE_LAG_FRAMES=3 为周期放行/拒绝第 5 级，于是 actual_levels 逐帧
// 5/4/4/5/4/4… 摆动，用户看到的就是「闪」。

/// 跑一段迟滞状态机，返回逐帧的 actual_levels 序列。
/// `achievable(frame)` 模拟池本帧最多能给到的级数。
fn simulateLevels(
    comptime achievable: fn (u64) u32,
    max_levels: u32,
    frames: u64,
    out: []u32,
) void {
    var st: BlurLevelState = .{};
    for (0..frames) |f| {
        const cap = levelCap(st.committed, st.streak, st.backoff, max_levels);
        const actual = @min(cap, achievable(f));
        out[f] = actual;
        st = levelSettle(st, cap, actual, max_levels);
    }
}

test "levelCap: 无历史不设限（首帧/换主一次到位）" {
    try std.testing.expectEqual(@as(u32, 5), levelCap(0, 0, 0, 5));
    try std.testing.expectEqual(@as(u32, 6), levelCap(0, 99, 3, 6));
}

test "levelCap: 有历史时压在上一帧提交的级数" {
    try std.testing.expectEqual(@as(u32, 4), levelCap(4, 0, 0, 5));
    try std.testing.expectEqual(@as(u32, 4), levelCap(4, BLUR_LEVEL_RAISE_FRAMES - 2, 0, 5));
    // streak 达阈值 -> 放行一次上调尝试
    try std.testing.expectEqual(@as(u32, 5), levelCap(4, BLUR_LEVEL_RAISE_FRAMES - 1, 0, 5));
}

test "levelCap: 退避把上调间隔按 2^backoff 拉长，封顶 8×" {
    const base = BLUR_LEVEL_RAISE_FRAMES;
    // backoff=1 时 base-1 已不够放行，2*base-1 才够
    try std.testing.expectEqual(@as(u32, 4), levelCap(4, base - 1, 1, 5));
    try std.testing.expectEqual(@as(u32, 5), levelCap(4, 2 * base - 1, 1, 5));
    // 封顶：backoff 3 与 9 同阈值
    try std.testing.expectEqual(levelCap(4, 8 * base - 1, 3, 5), levelCap(4, 8 * base - 1, 9, 5));
    try std.testing.expectEqual(@as(u32, 5), levelCap(4, 8 * base - 1, 9, 5));
}

test "降级立即生效：池掉一级，下一帧就压到低值（不留垃圾纹理）" {
    const st = levelSettle(.{ .committed = 5, .streak = 0, .backoff = 0 }, 5, 4, 5);
    try std.testing.expectEqual(@as(u32, 4), st.committed);
    try std.testing.expectEqual(@as(u32, 4), levelCap(st.committed, st.streak, st.backoff, 5));
}

test "回归 issue 33：3 帧周期的池振荡不再让 levels 逐帧跳变" {
    // 池以 3 帧为周期供 5/4/4（REUSE_LAG_FRAMES=3 的实测相位）。
    const Osc = struct {
        fn f(frame: u64) u32 {
            return if (frame % 3 == 0) 5 else 4;
        }
    };
    var seq: [60]u32 = undefined;
    simulateLevels(Osc.f, 5, seq.len, &seq);

    // 首帧不设限 -> 5；此后必须收敛。稳态段（跳过前 12 帧的收敛期）内
    // 相邻帧不得再有跳变，这正是用户看到的「闪」。
    var changes: u32 = 0;
    for (seq[12..], 13..) |v, i| {
        if (v != seq[i - 1]) changes += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), changes);
    // 稳定在低值是可接受的（视觉上与恒 5 几乎无差），但不能是 0。
    try std.testing.expect(seq[seq.len - 1] > 0);

    // 变异验证（负对照）：没有迟滞就是原行为，同样的池必然逐帧跳。
    var raw_changes: u32 = 0;
    for (13..seq.len) |i| {
        if (Osc.f(i) != Osc.f(i - 1)) raw_changes += 1;
    }
    try std.testing.expect(raw_changes > 20);
}

test "池恢复后链深会回升（迟滞不是单向锁死）" {
    const Recover = struct {
        fn f(frame: u64) u32 {
            return if (frame < 10) 4 else 5;
        }
    };
    var seq: [80]u32 = undefined;
    simulateLevels(Recover.f, 5, seq.len, &seq);
    try std.testing.expectEqual(@as(u32, 4), seq[9]);
    // 恢复后应在 O(BLUR_LEVEL_RAISE_FRAMES) 帧内升回 5 并保持
    try std.testing.expectEqual(@as(u32, 5), seq[seq.len - 1]);
    var rise_at: usize = seq.len;
    for (seq[10..], 10..) |v, i| {
        if (v == 5) {
            rise_at = i;
            break;
        }
    }
    try std.testing.expect(rise_at - 10 <= 2 * BLUR_LEVEL_RAISE_FRAMES);
}

test "硬饱和：第 5 级永远给不出时，退避让尝试频率收敛（不退化为低频闪）" {
    const Hard = struct {
        fn f(_: u64) u32 {
            return 4;
        }
    };
    var seq: [200]u32 = undefined;
    simulateLevels(Hard.f, 5, seq.len, &seq);
    // 池恒给 4，cap 放行到 5 也只跑出 4 -> 序列全程恒 4，零跳变。
    for (seq[1..]) |v| try std.testing.expectEqual(@as(u32, 4), v);
}
