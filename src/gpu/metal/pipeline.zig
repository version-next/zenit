/// Metal Pipeline 实现
///
/// 提供 ShaderModule 和 RenderPipeline 封装
const std = @import("std");
const gpu = @import("../gpu.zig");
const mtl = @import("metal_bindings.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;

/// ShaderModule - 着色器模块
///
/// 封装 MTLLibrary，包含编译后的着色器函数
pub const ShaderModule = struct {
    library: *mtl.MTLLibrary,

    /// 从 Metal Shading Language 源码创建
    pub fn initFromSource(
        device: *Device,
        source: []const u8,
    ) !ShaderModule {
        var pool = mtl.AutoreleasePool.init();
        defer pool.deinit();

        // 需要 null-terminated 字符串（shader 源码较大，使用 page_allocator）
        const source_z = try std.heap.page_allocator.dupeZ(u8, source);
        defer std.heap.page_allocator.free(source_z);

        var compile_error: ?[*:0]u8 = null;
        const library = mtl.metal_device_new_library_from_source(
            device.raw_device,
            source_z.ptr,
            &compile_error,
        ) orelse {
            if (compile_error) |msg| {
                defer std.c.free(msg);
                std.log.err("Metal shader compilation failed: {s}", .{std.mem.span(msg)});
            } else {
                std.log.err("Metal shader compilation failed (no diagnostic returned)", .{});
            }
            return error.ShaderCompilationFailed;
        };

        return ShaderModule{
            .library = library,
        };
    }

    /// 获取函数
    pub fn getFunction(self: *ShaderModule, name: []const u8) !ShaderFunction {
        // 函数名通常很短（< 128 字节），使用栈缓冲区避免 page_allocator 的 mmap 开销
        var buf: [128]u8 = undefined;
        if (name.len < buf.len) {
            @memcpy(buf[0..name.len], name);
            buf[name.len] = 0;
            const raw = mtl.metal_library_new_function(self.library, @ptrCast(buf[0..name.len :0])) orelse
                return error.FunctionNotFound;
            return .{ .raw = raw };
        }
        // 超长名称回退到 page_allocator
        const name_z = try std.heap.page_allocator.dupeZ(u8, name);
        defer std.heap.page_allocator.free(name_z);
        const raw = mtl.metal_library_new_function(self.library, name_z.ptr) orelse
            return error.FunctionNotFound;
        return .{ .raw = raw };
    }

    pub fn deinit(self: *ShaderModule) void {
        mtl.release(self.library);
    }
};

/// Backend-owned shader entry point.
///
/// Renderer code owns this wrapper and never handles or releases a native
/// `MTLFunction`. The raw handle is consumed only inside this backend module.
pub const ShaderFunction = struct {
    raw: *mtl.MTLFunction,

    pub fn deinit(self: *ShaderFunction) void {
        mtl.release(self.raw);
        self.* = undefined;
    }
};

/// RenderPipeline - 渲染管线
///
/// 封装 MTLRenderPipelineState
pub const RenderPipeline = struct {
    raw: *mtl.MTLRenderPipelineState,

    pub fn deinit(self: *RenderPipeline) void {
        mtl.release(self.raw);
    }
};

/// RenderPipelineDescriptor - 渲染管线描述符
///
/// 用于创建 RenderPipeline 的配置
pub const RenderPipelineDescriptor = struct {
    vertex_function: ?*const ShaderFunction = null,
    fragment_function: ?*const ShaderFunction = null,
    color_attachment_formats: []const gpu.TextureFormat = &.{},
    depth_attachment_format: ?gpu.TextureFormat = null,
    stencil_attachment_format: ?gpu.TextureFormat = null,
    sample_count: u32 = 1,
    vertex_buffers: []const VertexBufferLayoutDescriptor = &.{},
    blend_state: ?BlendState = null,
};

/// 顶点缓冲区布局描述符
pub const VertexBufferLayoutDescriptor = struct {
    stride: u64,
    step_mode: gpu.VertexStepMode = .vertex,
    attributes: []const VertexAttributeDescriptor,
};

/// 顶点属性描述符
pub const VertexAttributeDescriptor = struct {
    format: gpu.VertexFormat,
    offset: u64,
    shader_location: u32,
};

/// 混合状态
pub const BlendState = struct {
    source_rgb: BlendFactor = .one,
    destination_rgb: BlendFactor = .zero,
    rgb_operation: BlendOperation = .add,
    source_alpha: BlendFactor = .one,
    destination_alpha: BlendFactor = .zero,
    alpha_operation: BlendOperation = .add,

    pub const ALPHA_BLENDING = BlendState{
        .source_rgb = .src_alpha,
        .destination_rgb = .one_minus_src_alpha,
        .rgb_operation = .add,
        .source_alpha = .one,
        .destination_alpha = .one_minus_src_alpha,
        .alpha_operation = .add,
    };
};

pub const BlendFactor = enum(c_ulong) {
    zero = 0,
    one = 1,
    src_color = 2,
    one_minus_src_color = 3,
    src_alpha = 4,
    one_minus_src_alpha = 5,
    dst_color = 6,
    one_minus_dst_color = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
    src_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
};

pub const BlendOperation = enum(c_ulong) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
};

/// 创建 RenderPipeline
///
/// ⚠️ 别加 descriptor-hash PSO 缓存（GPU 评审 §B3 建议过）。2026-08-07 实测
/// 翻车：descriptor 里的 shader 函数只能按 `MTLFunction` **对象地址**指纹，
/// 而调用点（ensureBlurPipeline / buildGlassPipeline 等）建完 PSO 就
/// `defer func.deinit()` 释放函数与 ShaderModule。地址随即被 ObjC 回收复用，
/// 于是 glass 的 descriptor 与先建的 Kawase blur descriptor **指纹相同**,
/// 缓存把 blur PSO 当成 glass PSO 返回，玻璃退化成一坨不折射的乳白圆盘。
///
/// 关键教训：e2e 当时仍报 87/87 全绿（像素断言抓不住"用错 shader"），
/// 是逐张看截图才发现的。
///
/// **更重要的是：这个缓存本来就没有收益。** 2026-08-07 在本函数插桩实测
/// 整个 storybook 生命周期（41 组件 / 87 个 e2e 场景 / 全部 glass+blur 场景）：
///   PSO 累计只建 **10 次、总计 1.26ms**（单次最贵 0.44ms，其余 0.03~0.15ms），
///   且**零次重复**。
/// 评审 §B3 假设的"同一组合在多个 renderer 里重复编译"不成立，各调用点
/// 早有 `if (pipeline != null) return` + PersistentGpuCache 跨帧持久去重
/// （见 command_encoder.zig 的 PersistentGpuCache）。缓存的收益上限是这
/// 一次性的 1.26ms（不在帧路径上），代价却是整块 glass 渲染错误：负收益。
///
/// 真要重开此议题，先复现出"PSO 重复编译"的实测证据，再谈实现。
pub fn createRenderPipeline(
    device: *Device,
    desc: RenderPipelineDescriptor,
) !RenderPipeline {
    var pool = mtl.AutoreleasePool.init();
    defer pool.deinit();

    // 创建 pipeline descriptor
    const pipeline_desc = mtl.metal_render_pipeline_descriptor_new();
    defer mtl.release(pipeline_desc);

    // 设置顶点和片段函数
    mtl.metal_render_pipeline_descriptor_set_vertex_function(
        pipeline_desc,
        if (desc.vertex_function) |function| function.raw else null,
    );
    mtl.metal_render_pipeline_descriptor_set_fragment_function(
        pipeline_desc,
        if (desc.fragment_function) |function| function.raw else null,
    );

    // 设置颜色附件格式
    for (desc.color_attachment_formats, 0..) |format, i| {
        const mtl_format = conv.toMetalPixelFormat(format);
        mtl.metal_render_pipeline_descriptor_set_color_attachment_format(
            pipeline_desc,
            @intCast(i),
            @intFromEnum(mtl_format),
        );

        // 设置混合状态
        if (desc.blend_state) |blend| {
            mtl.metal_render_pipeline_color_attachment_set_blending_enabled(pipeline_desc, @intCast(i), 1);
            mtl.metal_render_pipeline_color_attachment_set_source_rgb_blend_factor(pipeline_desc, @intCast(i), @intFromEnum(blend.source_rgb));
            mtl.metal_render_pipeline_color_attachment_set_destination_rgb_blend_factor(pipeline_desc, @intCast(i), @intFromEnum(blend.destination_rgb));
            mtl.metal_render_pipeline_color_attachment_set_rgb_blend_operation(pipeline_desc, @intCast(i), @intFromEnum(blend.rgb_operation));
            mtl.metal_render_pipeline_color_attachment_set_source_alpha_blend_factor(pipeline_desc, @intCast(i), @intFromEnum(blend.source_alpha));
            mtl.metal_render_pipeline_color_attachment_set_destination_alpha_blend_factor(pipeline_desc, @intCast(i), @intFromEnum(blend.destination_alpha));
            mtl.metal_render_pipeline_color_attachment_set_alpha_blend_operation(pipeline_desc, @intCast(i), @intFromEnum(blend.alpha_operation));
        }
    }

    // 设置深度附件格式
    if (desc.depth_attachment_format) |format| {
        const mtl_format = conv.toMetalPixelFormat(format);
        mtl.metal_render_pipeline_descriptor_set_depth_attachment_format(
            pipeline_desc,
            @intFromEnum(mtl_format),
        );
    }

    // 设置模板附件格式
    if (desc.stencil_attachment_format) |format| {
        const mtl_format = conv.toMetalPixelFormat(format);
        mtl.metal_render_pipeline_descriptor_set_stencil_attachment_format(
            pipeline_desc,
            @intFromEnum(mtl_format),
        );
    }

    // 设置采样数
    mtl.metal_render_pipeline_descriptor_set_sample_count(pipeline_desc, desc.sample_count);

    // 设置顶点描述符
    if (desc.vertex_buffers.len > 0) {
        const vertex_desc = mtl.metal_vertex_descriptor_new();
        defer mtl.release(vertex_desc);

        for (desc.vertex_buffers, 0..) |buffer_layout, buffer_index| {
            // 设置布局
            mtl.metal_vertex_descriptor_set_layout_stride(
                vertex_desc,
                @intCast(buffer_index),
                buffer_layout.stride,
            );

            const step_function: c_ulong = switch (buffer_layout.step_mode) {
                .vertex => 1, // MTLVertexStepFunctionPerVertex
                .instance => 2, // MTLVertexStepFunctionPerInstance
            };
            mtl.metal_vertex_descriptor_set_layout_step_function(
                vertex_desc,
                @intCast(buffer_index),
                step_function,
            );
            mtl.metal_vertex_descriptor_set_layout_step_rate(
                vertex_desc,
                @intCast(buffer_index),
                1,
            );

            // 设置属性
            for (buffer_layout.attributes) |attr| {
                const mtl_format = vertexFormatToMetal(attr.format);
                mtl.metal_vertex_descriptor_set_attribute_format(
                    vertex_desc,
                    attr.shader_location,
                    @intFromEnum(mtl_format),
                );
                mtl.metal_vertex_descriptor_set_attribute_offset(
                    vertex_desc,
                    attr.shader_location,
                    attr.offset,
                );
                mtl.metal_vertex_descriptor_set_attribute_buffer_index(
                    vertex_desc,
                    attr.shader_location,
                    @intCast(buffer_index),
                );
            }
        }

        mtl.metal_render_pipeline_descriptor_set_vertex_descriptor(pipeline_desc, vertex_desc);
    }

    // 创建 pipeline state（不使用 error_out，简化实现）
    const pipeline_state = mtl.metal_device_new_render_pipeline_state(
        device.raw_device,
        pipeline_desc,
        null,
    ) orelse {
        std.log.err(
            "Metal render pipeline creation failed (color_attachments={d} sample_count={d})",
            .{ desc.color_attachment_formats.len, desc.sample_count },
        );
        return error.PipelineCreationFailed;
    };

    return RenderPipeline{
        .raw = pipeline_state,
    };
}

/// 转换顶点格式到 Metal
fn vertexFormatToMetal(format: gpu.VertexFormat) mtl.MTLVertexFormat {
    return switch (format) {
        .uint8x2 => .UChar2,
        .uint8x4 => .UChar4,
        .sint8x2 => .Char2,
        .sint8x4 => .Char4,
        .unorm8x2 => .UChar2Normalized,
        .unorm8x4 => .UChar4Normalized,
        .snorm8x2 => .Char2Normalized,
        .snorm8x4 => .Char4Normalized,
        .uint16x2 => .UShort2,
        .uint16x4 => .UShort4,
        .sint16x2 => .Short2,
        .sint16x4 => .Short4,
        .unorm16x2 => .UShort2Normalized,
        .unorm16x4 => .UShort4Normalized,
        .snorm16x2 => .Short2Normalized,
        .snorm16x4 => .Short4Normalized,
        .float16x2 => .Half2,
        .float16x4 => .Half4,
        .float32 => .Float,
        .float32x2 => .Float2,
        .float32x3 => .Float3,
        .float32x4 => .Float4,
        .uint32 => .UInt,
        .uint32x2 => .UInt2,
        .uint32x3 => .UInt3,
        .uint32x4 => .UInt4,
        .sint32 => .Int,
        .sint32x2 => .Int2,
        .sint32x3 => .Int3,
        .sint32x4 => .Int4,
    };
}
